#Requires -Version 5.1
<#
    MMLM.Server - the media server layer. The host and its workers talk only to these functions; each one passes the
    work to the server kind's own module (MMLM.Plex today). A server is described by one hashtable:

        @{ Kind = 'plex'; Name = 'Plex'; BaseUrl = 'http://...:32400'; Token = '<decrypted token>' }

    Adding a server kind (Jellyfin, step 2) means a module with the same jobs and one more branch in each switch below;
    nothing in the host or the page has to know which server it is.
#>
Set-StrictMode -Version 2.0
# each server kind's module, loaded here so this layer can reach it wherever it is imported (host or worker)
foreach ($m0 in @('MMLM.Library.psm1', 'MMLM.Plex.psm1', 'MMLM.Jellyfin.psm1')) { Import-Module (Join-Path $PSScriptRoot $m0) -DisableNameChecking }

$script:ServerKinds = [ordered]@{
    plex     = @{ Name = 'Plex' }
    jellyfin = @{ Name = 'Jellyfin' }
}

function Set-MmlmServerContext {
    # Hands the shared context (traffic counters, progress, settings) to every server kind's module.
    param([hashtable]$Values)
    Set-MmlmPlexContext -Values $Values
    Set-MmlmJellyfinContext -Values $Values
}
function Get-MmlmServerKinds { @($script:ServerKinds.Keys) }
function Get-MmlmServerName {
    param([string]$Kind)
    if ($script:ServerKinds.Contains($Kind)) { [string]$script:ServerKinds[$Kind].Name } else { 'media server' }
}
function New-MmlmServer {
    # Checks a server description and returns it complete. Throws a plain message the page can show.
    param([string]$Kind = 'plex', [string]$BaseUrl, [string]$Token)
    if (-not $Kind) { $Kind = 'plex' }
    if (-not $script:ServerKinds.Contains($Kind)) { throw ('Unknown media server kind: {0}.' -f $Kind) }
    $name = Get-MmlmServerName $Kind
    if (-not $BaseUrl) { throw ('No {0} server address is set yet. Add it in Settings.' -f $name) }
    if (-not $Token) { throw ('No {0} {1} is saved yet. Add it in Settings.' -f $name, $(if ($Kind -eq 'jellyfin') { 'API key' } else { 'token' })) }
    @{ Kind = $Kind; Name = $name; BaseUrl = $BaseUrl; Token = $Token }
}
function Assert-MmlmServer {
    param($Server)
    if ($null -eq $Server -or -not $Server.Kind -or -not $script:ServerKinds.Contains([string]$Server.Kind)) { throw 'No media server is set up.' }
}

# Secrets (server tokens, API keys) are kept encrypted for this Windows user. One place for every kind.
function Protect-MmlmSecret { param([string]$Text) Protect-MmlmPlexToken $Text }
function Unprotect-MmlmSecret { param([string]$Text) Unprotect-MmlmPlexToken $Text }

function Invoke-MmlmServerScan {
    # The library's records, in MMLM's own record shape, for movies or TV shows.
    param($Server, [bool]$Movies, [bool]$Shows, [bool]$Rebuild, [bool]$DetectFel, $Prior)
    Assert-MmlmServer $Server
    switch ([string]$Server.Kind) {
        'plex'     { Invoke-MmlmPlexScan -BaseUrl $Server.BaseUrl -Token $Server.Token -Movies $Movies -Shows $Shows -Rebuild $Rebuild -DetectFel $DetectFel -Prior $Prior }
        'jellyfin' { Invoke-MmlmJellyfinScan -BaseUrl $Server.BaseUrl -Token $Server.Token -Movies $Movies -Shows $Shows -Rebuild $Rebuild -DetectFel $DetectFel -Prior $Prior }
    }
}

function Save-MmlmServerArtwork {
    # One picture (art, logo or banner) for the title behind a record; returns 'saved', 'have', 'none' or 'failed'.
    param($Server, $Record, [string]$Kind, [string]$Folder, [switch]$Retry, [switch]$Force)
    Assert-MmlmServer $Server
    switch ([string]$Server.Kind) {
        'plex'     { Save-MmlmPlexArtwork -BaseUrl $Server.BaseUrl -Token $Server.Token -Thumb ([string]$Record.PlexThumb) -Kind $Kind -Folder $Folder -Retry:$Retry -Force:$Force }
        'jellyfin' { Save-MmlmJellyfinArtwork -BaseUrl $Server.BaseUrl -Token $Server.Token -Thumb ([string]$Record.PlexThumb) -Kind $Kind -Folder $Folder -Retry:$Retry -Force:$Force }
    }
}
function Get-MmlmServerArtworkKey {
    # What identifies a title's pictures on the server (an episode shares its show's), so each is fetched once.
    param($Server, $Record)
    switch ([string]$Server.Kind) {
        default { [string]$Record.PlexThumb }
    }
}
function Get-MmlmArtworkFileId {
    # The id in a title's artwork file names (art-<id>.jpg): Plex's number, or 'jf' + Jellyfin's item id. From the
    # record's thumb alone, so the page export needs no server.
    param([string]$Thumb)
    if ($Thumb -match '^/library/metadata/(\d+)(/|$)') { return $Matches[1] }
    Get-MmlmJellyfinArtworkId $Thumb
}

function Sync-MmlmServerArtwork {
    # Fetches the chosen artwork kinds for every distinct title behind these records, into $Folder. The failed-request
    # rule: three failures in a row stop the run. Returns @{ Saved; Failed; Stopped }.
    param($Server, [object[]]$Recs, [string[]]$Kinds, [string]$Folder, [switch]$Retry, [switch]$Force)
    Assert-MmlmServer $Server
    $res = @{ Saved = 0; Failed = 0; Stopped = $false }
    if (-not $Kinds -or $Kinds.Count -eq 0) { return $res }
    if (-not (Test-Path -LiteralPath $Folder)) { New-Item -Path $Folder -ItemType Directory -Force | Out-Null }
    # the first version saved cropped logos and banners (logo-*, banner-*): drop them so they are fetched again uncropped
    Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(logo|banner)-\d+\.(png|jpg|none)$' } | Remove-Item -Force -ErrorAction SilentlyContinue
    $seen = @{}; $jobs = New-Object System.Collections.Generic.List[object]
    foreach ($r in $Recs) {
        $key = Get-MmlmServerArtworkKey -Server $Server -Record $r
        if (-not $key -or $seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $tv = [bool][string]$r.Show
        foreach ($k in $Kinds) { if ($k -eq 'banner' -and -not $tv) { continue }; $jobs.Add(@($r, $k)) }
    }
    $n = 0; $row = 0
    foreach ($j in $jobs) {
        if (Test-MmlmScanCancelled) { break }
        $n++
        if (($n % 5) -eq 0 -or $n -eq $jobs.Count) { Set-MmlmProgress -Text ('Artwork: {0} of {1}' -f $n, $jobs.Count) -Value $n -Max $jobs.Count }
        $r = Save-MmlmServerArtwork -Server $Server -Record $j[0] -Kind $j[1] -Folder $Folder -Retry:$Retry -Force:$Force
        if ($r -eq 'saved') { $res.Saved++ }
        if ($r -eq 'failed') { $res.Failed++; $row++; if ($row -ge 3) { $res.Stopped = $true; break } } else { $row = 0 }
    }
    if ($res.Saved -gt 0 -or $Force) { [IO.File]::WriteAllText((Join-Path $Folder 'stamp.txt'), (Get-Date).ToString('o')) }
    $res
}

function Test-MmlmServer {
    # Settings > Servers > Test: the server's name, version and its movie / TV libraries.
    param($Server)
    Assert-MmlmServer $Server
    switch ([string]$Server.Kind) {
        'plex'     { [ordered]@{ name = 'Plex'; version = ''; libraries = @(Get-MmlmPlexSections -BaseUrl $Server.BaseUrl -Token $Server.Token | ForEach-Object { [ordered]@{ name = [string]$_.Title; type = [string]$_.Type } }) } }
        'jellyfin' { Get-MmlmJellyfinInfo -BaseUrl $Server.BaseUrl -Token $Server.Token }
    }
}
function Get-MmlmServerSeries {
    # One show's page (seasons, episodes with stills and watched marks, cast, related shows), pictures saved under
    # $ImageFolder. Returns @{ Key = <the show's key on the server>; Data = <the page's JSON object> }.
    param($Server, [string]$ShowKey, [string]$EpKey, [string]$ImageFolder, $Sync)
    Assert-MmlmServer $Server
    switch ([string]$Server.Kind) {
        'plex'     { Get-MmlmPlexSeries -BaseUrl $Server.BaseUrl -Token $Server.Token -ShowKey $ShowKey -EpKey $EpKey -ImageFolder $ImageFolder -Sync $Sync }
        'jellyfin' { Get-MmlmJellyfinSeries -BaseUrl $Server.BaseUrl -Token $Server.Token -ShowKey $ShowKey -EpKey $EpKey -ImageFolder $ImageFolder -Sync $Sync }
    }
}

Export-ModuleMember -Function @(
    'Set-MmlmServerContext',
    'Get-MmlmServerKinds',
    'Get-MmlmServerName',
    'New-MmlmServer',
    'Assert-MmlmServer',
    'Protect-MmlmSecret',
    'Unprotect-MmlmSecret',
    'Invoke-MmlmServerScan',
    'Save-MmlmServerArtwork',
    'Get-MmlmServerArtworkKey',
    'Get-MmlmArtworkFileId',
    'Test-MmlmServer',
    'Sync-MmlmServerArtwork',
    'Get-MmlmServerSeries'
)
