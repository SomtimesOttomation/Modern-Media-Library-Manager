<#
    MMLM.Host.psm1 - the backend of Modern Media Library Manager in DashLauncher's dash contract (version 1).

    Whoever hosts it (the app itself later, or DashLauncher) creates the window and the WebView2 and calls these functions.
    This module never creates a window and never loads WebView2. Everything slow (Plex, online lookups, disk scans) runs
    in one worker runspace that loads MMLM.Library / MMLM.Plex / MMLM.Fetch by full path.

    Contract functions: Initialize-Dash, Start-DashWorker, Suspend-DashWorker, Invoke-DashCommand, Receive-DashEvents,
    Get-DashStatus, Stop-DashTraffic, Stop-Dash, and the optional Invoke-DashSync.

    Page commands (bridge.request): init, scan.start { tab: 'movies'|'tv', rebuild }, scan.cancel, summary.get,
    traffic.get, traffic.stop, traffic.resume.

    The data comes from the person's own Plex server, only when asked. Nothing refreshes on a timer, so Suspend-DashWorker
    has nothing to stop; a scan the person started keeps running while the tab is hidden and shows on the rail through
    Get-DashStatus (Syncing / SyncPct). The kill switch (Stop-DashTraffic) cancels it.
    Scripts stay ASCII-only for Windows PowerShell 5.1.
#>

# One dash id; the lock, the app-data folder and the log are named from it.
$script:DashId = 'mmlm'
$script:AppName = 'Modern-Media-Library-Manager'
$script:Ctx = $null
$script:Root = Split-Path $PSScriptRoot
$script:Mutex = $null
$script:Version = '0.0.0'
$script:AppData = Join-Path $env:LOCALAPPDATA $script:AppName
$script:MetaStore = Join-Path $script:AppData 'metadata\store.json'      # fetched + hand-typed values (shared with the window app)
$script:CacheDir = ''
$script:WebViewDataDir = ''
$script:Settings = $null
$script:Traffic = $null
$script:Sync = $null            # the running (or last) scan: progress, cancel, results
$script:ScanPs = $null
$script:ScanAsync = $null
$script:ScanTab = ''
$script:Out = $null             # the one event queue: every page event goes through it and Receive-DashEvents
$script:LastScanJson = ''
$script:Badge = 0               # titles new since the person last looked at the tab
$script:Visible = $false
$script:Exports = @{}
$script:PageSettings = $null
$script:UpdProc = $null
$script:Series = $null
$script:Tool = $null

# the data modules, by full path (an already loaded copy is reused)
foreach ($m0 in @('MMLM.Library.psm1', 'MMLM.Plex.psm1', 'MMLM.Jellyfin.psm1', 'MMLM.Server.psm1', 'MMLM.Fetch.psm1', 'MMLM.Doctor.psm1')) { Import-Module (Join-Path $PSScriptRoot $m0) -DisableNameChecking }

function Write-HostLog {
    # failures go to %LOCALAPPDATA%\<app>\Logs\host.log instead of disappearing (kept under 1 MB)
    param([string]$Where, $Err)
    try {
        $dir = Join-Path $script:AppData 'Logs'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $f = Join-Path $dir 'host.log'
        if ((Test-Path -LiteralPath $f) -and (Get-Item -LiteralPath $f).Length -gt 1MB) { Move-Item -LiteralPath $f -Destination ($f + '.old') -Force }
        $msg = $(if ($Err -is [Management.Automation.ErrorRecord]) { $Err.Exception.Message } else { [string]$Err })
        [IO.File]::AppendAllText($f, ('{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Where, $msg) + [Environment]::NewLine)
    } catch { }   # the log itself failing must never break the dash
}
function Send-Page { param([string]$Json) if ($script:Ctx -and $script:Ctx.Post) { & $script:Ctx.Post $Json } }
function ConvertTo-PageJson { param($Object) ConvertTo-Json -InputObject $Object -Depth 6 -Compress }
function Reply { param($Id, [string]$DataJson = 'null') Send-Page ('{"id":' + (ConvertTo-PageJson $Id) + ',"ok":true,"data":' + $DataJson + '}') }
function ReplyError { param($Id, [string]$Message) Send-Page ('{"id":' + (ConvertTo-PageJson $Id) + ',"ok":false,"error":' + (ConvertTo-PageJson $Message) + '}') }
# The traffic on/off event skips the queue (the dash contract wants it on the page at once); everything else is queued.
function Send-HostEventNow { param([string]$Name, $Data) Send-Page (ConvertTo-PageJson ([ordered]@{ event = $Name; data = $Data })) }
function Push-HostEvent { param([string]$Name, $Data) if ($script:Out) { $script:Out.Enqueue((ConvertTo-PageJson ([ordered]@{ event = $Name; data = $Data }))) } }

function Get-HostModuleFiles {
    @('MMLM.Library.psm1', 'MMLM.Plex.psm1', 'MMLM.Jellyfin.psm1', 'MMLM.Server.psm1', 'MMLM.Fetch.psm1', 'MMLM.Doctor.psm1') | ForEach-Object { Join-Path (Join-Path $script:Root 'modules') $_ }
}

function Read-HostSettings {
    # The same settings file the app writes (%LOCALAPPDATA%\Modern-Media-Library-Manager\settings.json); read only here.
    $p = Join-Path $script:AppData 'settings.json'
    # server keys: Plex (shared with the window app), Jellyfin, and which server each library comes from
    $s = @{ PlexUrl = ''; PlexTokenProtected = ''; JellyfinUrl = ''; JellyfinKeyProtected = ''; MoviesServer = 'plex'; TvServer = 'plex' }
    if (Test-Path -LiteralPath $p) {
        try { $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json; foreach ($k in @($s.Keys)) { if ($j.PSObject.Properties[$k] -and $j.$k) { $s[$k] = [string]$j.$k } } } catch { Write-HostLog 'settings' $_ }
    }
    $s
}

function Save-HostServerSettings {
    # Writes only the given server keys into the app's settings.json; every other key there stays as it was.
    param([hashtable]$Values)
    $p = Join-Path $script:AppData 'settings.json'
    $o = [ordered]@{}
    if (Test-Path -LiteralPath $p) {
        try { $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json; foreach ($pr in $j.PSObject.Properties) { $o[$pr.Name] = $pr.Value } } catch { Write-HostLog 'settings read' $_ }
    }
    foreach ($k in $Values.Keys) { $o[$k] = $Values[$k] }
    [IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject $o -Depth 6), (New-Object Text.UTF8Encoding($false)))
}
function Save-HostPlexSettings {
    # Writes only PlexUrl / PlexTokenProtected into the app's settings.json; every other key there stays as it was.
    param([string]$Url, [string]$TokenProtected, [switch]$KeepToken)
    $p = Join-Path $script:AppData 'settings.json'
    $o = [ordered]@{}
    if (Test-Path -LiteralPath $p) {
        try { $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json; foreach ($pr in $j.PSObject.Properties) { $o[$pr.Name] = $pr.Value } } catch { Write-HostLog 'settings read' $_ }
    }
    $o['PlexUrl'] = $Url
    if (-not $KeepToken) { $o['PlexTokenProtected'] = $TokenProtected }
    [IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject $o -Depth 6), (New-Object Text.UTF8Encoding($false)))
}

# The page's own settings (theme, view and sort per tab, grid columns), kept apart from the app's settings.json.
$script:PageDefaults = [ordered]@{ theme = 'system'; updateCheck = $false; moviesView = 'posters'; tvView = 'posters'; moviesSort = 'added'; tvSort = 'title'; moviesSortRev = $false; tvSortRev = $false
    columns = @(); hideDupes = $false; detectFel = $false; posterScale = 100; tvScale = 100; clearScale = 100; bannerScale = 100;
    doctorFreq = 'off'; doctorAck = $false; doctorDay = 0; doctorTime = '03:00'; doctorStyle = 'compact'; doctorChecks = @('unreadable', 'unmatched', 'wrongmatch', 'gaps', 'poster', 'dupes', 'av1'); widthPreset = 'full'; customWidth = $false; contentWidth = 0
    artLogo = $false; artBackground = $false; artBanner = $false
    fxLeft = 'auto'; fxRight = 'auto'; fxMotion = 'full'; vsStyle = 'arcade'; cmpTally = $true; cmpInflation = $false; cmpWalkover = $true; cmpImdb = $true }
function Read-PageSettings {
    $s = [ordered]@{}; foreach ($k in $script:PageDefaults.Keys) { $s[$k] = $script:PageDefaults[$k] }
    $p = Join-Path $script:AppData 'page-settings.json'
    if (Test-Path -LiteralPath $p) {
        try { $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json; foreach ($k in @($s.Keys)) { if ($null -ne $j.$k) { $s[$k] = $j.$k } } } catch { Write-HostLog 'page settings' $_ }
    }
    $s
}
function Set-PageSetting {
    param([string]$Key, $Value)
    $views = @('posters', 'grid', 'dashboard', 'compare')
    $fx = @('auto', 'fire', 'lightning', 'specter', 'poster', 'off')
    $ok = switch ($Key) {
        'theme'       { @('system', 'light', 'dark') -contains [string]$Value }
        'updateCheck' { $Value = [bool]$Value; $true }
        'hideDupes'   { $Value = [bool]$Value; $true }
        'moviesSortRev' { $Value = [bool]$Value; $true }
        'tvSortRev'   { $Value = [bool]$Value; $true }
        'customWidth' { $Value = [bool]$Value; $true }
        'detectFel'   { $Value = [bool]$Value; $true }
        'cmpTally'    { $Value = [bool]$Value; $true }
        'artLogo'     { $Value = [bool]$Value; $true }
        'artBackground' { $Value = [bool]$Value; $true }
        'artBanner'   { $Value = [bool]$Value; $true }
        'cmpWalkover' { $Value = [bool]$Value; $true }
        'cmpImdb'     { $Value = [bool]$Value; $true }
        'cmpInflation' { $Value = [bool]$Value; $true }
        'fxLeft'      { $fx -contains [string]$Value }
        'fxRight'     { $fx -contains [string]$Value }
        'fxMotion'    { @('still', 'calm', 'full') -contains [string]$Value }
        'vsStyle'     { @('arcade', 'plain', 'off') -contains [string]$Value }
        'doctorFreq'  { @('off', 'weekly', 'biweekly', 'monthly') -contains [string]$Value }
        'doctorDay'   { $n = 0; if ([int]::TryParse([string]$Value, [ref]$n) -and $n -ge 0 -and $n -le 6) { $Value = $n; $true } else { $false } }
        'doctorTime'  { [string]$Value -match '^([01]\d|2[0-3]):[0-5]\d$' }
        'doctorAck'   { $Value = [bool]$Value; $true }
        'doctorStyle' { @('compact', 'verbose') -contains [string]$Value }
        'doctorChecks' { $ok = @(Get-MmlmDoctorCheckIds); $Value = @(@($Value) | ForEach-Object { [string]$_ } | Where-Object { $ok -contains $_ } | Select-Object -Unique); $true }
        { $_ -in @('clearScale', 'bannerScale') } { $n = 0; if ([int]::TryParse([string]$Value, [ref]$n) -and $n -ge 50 -and $n -le 200) { $Value = $n; $true } else { $false } }
        'tvScale'     { $n = 0; if ([int]::TryParse([string]$Value, [ref]$n) -and $n -ge 50 -and $n -le 200) { $Value = $n; $true } else { $false } }
        'posterScale' { $n = 0; if ([int]::TryParse([string]$Value, [ref]$n) -and $n -ge 50 -and $n -le 200) { $Value = $n; $true } else { $false } }
        'contentWidth' { $n = 0; if ([int]::TryParse([string]$Value, [ref]$n) -and $n -ge 0 -and $n -le 20000) { $Value = $n; $true } else { $false } }
        'widthPreset' { @('full', '16:9', '21:9', '32:9') -contains [string]$Value }
        'moviesView'  { $views -contains [string]$Value }
        'tvView'      { @('posters', 'clear', 'banners', 'grid', 'dashboard') -contains [string]$Value }
        'moviesSort'  { [string]$Value -match '^[a-zA-Z]{1,30}$' }
        'tvSort'      { [string]$Value -match '^[a-zA-Z]{1,30}$' }
        'columns'     { $Value = @(@($Value) | Where-Object { [string]$_ -match '^[A-Za-z]{1,40}$' } | Select-Object -First 80); $true }
        default       { $false }
    }
    if (-not $ok) { throw ('Unknown or invalid setting: ' + $Key) }
    $script:PageSettings[$Key] = $Value
    [IO.File]::WriteAllText((Join-Path $script:AppData 'page-settings.json'), (ConvertTo-Json -InputObject $script:PageSettings -Depth 4), (New-Object Text.UTF8Encoding($false)))
}

function Get-PlexInfo {
    # the page's view of the servers (no secrets): Plex, Jellyfin, and which one each library comes from
    $set = Read-HostSettings
    @{ url = [string]$set.PlexUrl; hasToken = [bool]$set.PlexTokenProtected
        jellyfin = @{ url = [string]$set.JellyfinUrl; hasKey = [bool]$set.JellyfinKeyProtected }
        use = @{ movies = [string]$set.MoviesServer; tv = [string]$set.TvServer } }
}

function Get-SnapshotFile { param([string]$Tab) Join-Path (Join-Path $script:AppData 'Library') ($(if ($Tab -eq 'tv') { 'tv.mmls' } else { 'movies.mmls' })) }

function Get-SnapshotCount {
    # the record count from a snapshot's header ("count|date"), without loading it
    param([string]$Tab)
    $p = Get-SnapshotFile $Tab
    if (-not (Test-Path -LiteralPath $p)) { return @{ count = 0; when = '' } }
    try {
        $fs = [IO.File]::OpenRead($p); $br = New-Object IO.BinaryReader($fs, [Text.Encoding]::UTF8)
        try { [void]$br.ReadInt32(); $meta = $br.ReadString() } finally { $br.Close() }
        $parts = $meta -split '\|'
        $n = 0; [void][int]::TryParse($parts[0], [ref]$n)
        return @{ count = $n; when = [string]$parts[-1] }
    } catch { Write-HostLog 'snapshot header' $_; return @{ count = 0; when = '' } }
}

# ---------------------------------------------------------------- the scan worker (one runspace per scan)
$script:ScanScript = @'
param($Modules, $Ctx, $Job)
foreach ($m in $Modules) { Import-Module $m -DisableNameChecking }
Set-MmlmContext -Values $Ctx; Set-MmlmServerContext -Values $Ctx; Set-MmlmFetchContext -Values $Ctx
$S = $Ctx.Sync

function Export-PageLibrary {
    # The page's copy of a library: Dashboard\library-<tab>.json (no file paths) and its posters in Dashboard\thumbs.
    param([object[]]$Recs, [string]$Tab)
    $thumbs = Join-Path $Job.CacheDir 'thumbs'
    if (-not (Test-Path -LiteralPath $thumbs)) { New-Item -Path $thumbs -ItemType Directory -Force | Out-Null }
    $urls = @{}; $n = 0
    foreach ($r in $Recs) {
        $n++
        if (($n % 500) -eq 0) { Set-MmlmProgress -Text ('Preparing posters ({0} of {1})...' -f $n, $Recs.Count) }
        $pp = [string]$r.PosterPath
        if (-not $pp -or $urls.ContainsKey($pp)) { continue }
        $urls[$pp] = ''
        if (-not (Test-Path -LiteralPath $pp)) { continue }
        $leaf = $(if ($pp.StartsWith($Ctx.ThumbFolder, [StringComparison]::OrdinalIgnoreCase)) { [IO.Path]::GetFileName($pp) } else { (Get-MmlmStringHash $pp) + [IO.Path]::GetExtension($pp).ToLowerInvariant() })
        $dest = Join-Path $thumbs $leaf
        try { if (-not (Test-Path -LiteralPath $dest)) { Copy-Item -LiteralPath $pp -Destination $dest }; $urls[$pp] = 'thumbs/' + $leaf } catch { }
    }
    $names = New-Object System.Collections.Generic.List[string]
    $defs = New-Object System.Collections.Generic.List[object]
    foreach ($f in $Ctx.Fields) {
        if ($Job.Hidden -contains $f.Name) { continue }
        $names.Add([string]$f.Name); $defs.Add([ordered]@{ n = [string]$f.Name; t = [string]$f.Type; g = [string]$f.Group; s = [bool]$f.Show })
    }
    $names.Add('Poster'); $defs.Add([ordered]@{ n = 'Poster'; t = 'string'; g = 'Library'; s = $false })
    # artwork from Settings > Artwork, when it has been saved: art\<kind>-<Plex key>.<ext> (an episode uses its show's)
    $artDir = Join-Path $Job.CacheDir 'art'
    $have = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $ver = @{}   # ?v=<last write> so a refreshed picture is not served from the page's image cache
    if (Test-Path -LiteralPath $artDir) { foreach ($f in (New-Object IO.DirectoryInfo $artDir).GetFiles()) { [void]$have.Add($f.Name); $ver[$f.Name] = $f.LastWriteTimeUtc.Ticks } }
    foreach ($k in @(@('Art', 'art', 'jpg'), @('Logo', 'clogo', 'png'), @('Banner', 'tvbanner', 'jpg'))) {
        $names.Add($k[0]); $defs.Add([ordered]@{ n = $k[0]; t = 'string'; g = 'Library'; s = $false })
        foreach ($r in $Recs) {
            $u = ''
            $aid = Get-MmlmArtworkFileId ([string]$r.PlexThumb)
            if ($aid) { $leaf = '{0}-{1}.{2}' -f $k[1], $aid, $k[2]; if ($have.Contains($leaf)) { $u = 'art/' + $leaf + '?v=' + $ver[$leaf] } }
            $r.PSObject.Properties.Remove($k[0]); $r.PSObject.Properties.Add((New-Object Management.Automation.PSNoteProperty($k[0], $u)))
        }
    }
    # collection ids: Plex titles keep "p:<key>"; a local file gets "h:<hash of its path>", and the path behind each hash is
    # kept in Library\idmap-<tab>.json (never in the folder the page can read) so collections saved from the page keep the window app's ids
    $names.Add('Rid'); $defs.Add([ordered]@{ n = 'Rid'; t = 'string'; g = 'Library'; s = $false })
    $local = @{}; $idmap = [ordered]@{}
    foreach ($r in $Recs) {
        if ([string]$r.PlexKey -or -not [string]$r.FullPath) { continue }
        $fp = [string]$r.FullPath
        if (-not $local.ContainsKey($fp)) { $h = 'h:' + (Get-MmlmStringHash $fp).Substring(0, 16); $local[$fp] = $h; $idmap[$h] = 'f:' + $fp }
    }
    try { [IO.File]::WriteAllText((Join-Path (Split-Path $Job.Snapshot) ('idmap-' + $Tab + '.json')), (ConvertTo-Json -InputObject $idmap -Compress), (New-Object Text.UTF8Encoding($false))) } catch { }
    $json = [Mmlm.Native.PageData]::Rows([object[]]$Recs, $names.ToArray(), $urls, (ConvertTo-Json -InputObject $defs.ToArray() -Compress), $local)
    $file = Join-Path $Job.CacheDir ('library-' + $Tab + '.json')
    [IO.File]::WriteAllText($file + '.tmp', $json, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    Move-Item -LiteralPath ($file + '.tmp') -Destination $file
}

try {
    Initialize-MmlmNative
    $tv = ($Job.Tab -eq 'tv')
    if ($Job.Kind -eq 'export') {
        # no scan: turn the saved snapshot into the page's copy
        Set-MmlmProgress -Text 'Opening the library...'
        $recs = @([Mmlm.Native.Snapshot]::Load($Job.Snapshot))
        try { Merge-MmlmMetaStore -Records $recs -Path $Job.MetaStore } catch { }      # scores fetched or typed in since the scan
        Export-PageLibrary -Recs $recs -Tab $Job.Tab
        $S.Count = $recs.Count
        return
    }
    # last scan of this tab: unchanged Plex items are reused, and new ones are counted for the badge
    $prior = @{}
    if (Test-Path -LiteralPath $Job.Snapshot) {
        Set-MmlmProgress -Text 'Loading the last scan...'
        foreach ($r in [Mmlm.Native.Snapshot]::Load($Job.Snapshot)) { if ($r.PlexKey) { $prior[[string]$r.PlexKey] = $r } }
    }
    $use = $(if ($Job.Rebuild) { @{} } else { $prior })
    $recs = @(Invoke-MmlmServerScan -Server $Job.Server -Movies (-not $tv) -Shows $tv -Rebuild ([bool]$Job.Rebuild) -DetectFel ([bool]$Job.DetectFel) -Prior $use)
    if ($S.Cancel) { $S.Cancelled = $true; return }
    $new = @($recs | Where-Object { -not $prior.ContainsKey([string]$_.PlexKey) })
    Set-MmlmProgress -Text 'Saving...'
    $dir = Split-Path -Parent $Job.Snapshot
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    try { Merge-MmlmMetaStore -Records $recs -Path $Job.MetaStore } catch { }          # fetched scores (Metacritic, RT, box office) and hand edits
    [Mmlm.Native.Snapshot]::Save([object[]]$recs, $Job.Snapshot, ('{0}|{1}' -f $recs.Count, (Get-Date).ToString('yyyy-MM-dd HH:mm')))
    if (@($Job.ArtKinds).Count -gt 0) {          # Settings > Artwork: fetched like posters, from your Plex server only
        Set-MmlmScanPhase -Lo 0.0 -Hi 1.0
        try { [void](Sync-MmlmServerArtwork -Server $Job.Server -Recs $recs -Kinds @($Job.ArtKinds) -Folder (Join-Path $Job.CacheDir 'art') -Retry:([bool]$Job.Rebuild)) } catch { }
    }
    Export-PageLibrary -Recs $recs -Tab $Job.Tab
    # Today-page card: the six most recently added titles (episodes collapse to their show), posters copied into the cache dir
    $thumbs = Join-Path $Job.CacheDir 'thumbs'
    if (-not (Test-Path -LiteralPath $thumbs)) { New-Item -Path $thumbs -ItemType Directory -Force | Out-Null }
    $items = New-Object System.Collections.Generic.List[object]; $seen = @{}
    foreach ($r in @($recs | Sort-Object { [string]$_.Added } -Descending)) {
        if ($items.Count -ge 6) { break }
        $name = $(if ($r.Show) { [string]$r.Show } else { [string]$r.Title })
        if ($seen.ContainsKey($name)) { continue }; $seen[$name] = $true
        $img = ''
        if ($r.PosterPath -and (Test-Path -LiteralPath $r.PosterPath)) {
            $leaf = [IO.Path]::GetFileName([string]$r.PosterPath); $dest = Join-Path $thumbs $leaf
            if (-not (Test-Path -LiteralPath $dest)) { Copy-Item -LiteralPath $r.PosterPath -Destination $dest }
            $img = 'https://mmlm.cache/thumbs/' + $leaf
        }
        $sub = $(if ($r.Show) { 'S{0:00}E{1:00}' -f [int]$r.Season, [int]$r.Episode } elseif ([int]$r.Year -gt 0) { [string]$r.Year } else { '' })
        $lab = $(if ($name.Length -gt 60) { $name.Substring(0, 60) } else { $name })
        $items.Add(@{ label = $lab; sub = $sub; image = $img })
    }
    $card = @{ title = $(if ($tv) { 'Recently added TV' } else { 'Recently added movies' }); items = $items.ToArray(); updatedAt = (Get-Date).ToString('o') }
    [IO.File]::WriteAllText((Join-Path $Job.CacheDir ('summary-' + $Job.Tab + '.json')), (ConvertTo-Json -InputObject $card -Depth 5 -Compress), (New-Object Text.UTF8Encoding($false)))
    $S.Count = $recs.Count; $S.New = $new.Count
}
catch { $S.Error = $_.Exception.Message }
finally { $S.Done = $true }
'@

function New-WorkerContext {
    param($Sync)
    @{
        Sync = $Sync; Traffic = $script:Traffic; AppRoot = $script:Root; AppData = $script:AppData; AppVersion = $script:Version
        CacheFolder = (Join-Path $script:AppData 'Cache'); ThumbFolder = (Join-Path $script:AppData 'Thumbs'); LibFolder = (Join-Path $script:Root 'lib')
        CacheVersion = 4; Culture = [Globalization.CultureInfo]::InvariantCulture; PlexTimeoutMs = 30000; PlexClientId = 'mmlm-' + $env:COMPUTERNAME
        Fields = $script:Fields; TypeMap = @{ string = [string]; int = [int]; long = [long]; double = [double]; bool = [bool] }
        InformFolder = (Join-Path $script:AppData 'Inform')
    }
}

# Fields that are never sent to the page: file locations stay inside the app.
$script:HiddenFields = @('FullPath', 'Directory', 'PosterPath', 'InformFile')

function Start-HostExport {
    # Builds the page's copy of a tab from its saved snapshot, in the background. No network.
    param([ValidateSet('movies', 'tv')][string]$Tab)
    if ($script:Exports.ContainsKey($Tab)) { return }
    $sync = [hashtable]::Synchronized(@{ Text = 'Opening the library...'; Value = 0; Max = 0; Cancel = $false; Done = $false; Error = $null; PhaseLo = 0.0; PhaseHi = 1.0; Count = 0; New = 0; Cancelled = $false })
    $job = @{ Kind = 'export'; Tab = $Tab; Snapshot = (Get-SnapshotFile $Tab); CacheDir = $script:CacheDir; Hidden = $script:HiddenFields; MetaStore = $script:MetaStore }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:ScanScript).AddArgument(@(Get-HostModuleFiles)).AddArgument((New-WorkerContext $sync)).AddArgument($job)
    $script:Exports[$Tab] = @{ Ps = $ps; Async = $ps.BeginInvoke(); Sync = $sync }
}

function Get-ArtKinds {
    # the artwork kinds ticked in Settings > Artwork
    @(if ($script:PageSettings.artBackground) { 'art' }; if ($script:PageSettings.artLogo) { 'logo' }; if ($script:PageSettings.artBanner) { 'banner' })
}
function Update-OldArtwork {
    # v0.10.0 saved TV banners and clear logos cropped (art\banner-*, art\logo-*). Once per session: when any are left
    # and artwork is ticked, fetch them again uncropped (Settings > Artwork's own run; it drops the old files and the
    # libraries refresh when it finishes). Not while traffic is paused or another tool runs; then it waits for next time.
    if ($script:ArtChecked) { return }
    $dir = Join-Path $script:CacheDir 'art'
    if (-not (Test-Path -LiteralPath $dir)) { $script:ArtChecked = $true; return }
    $old = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(logo|banner)-\d+\.(png|jpg|none)$' })
    if ($old.Count -eq 0 -or @(Get-ArtKinds).Count -eq 0) { $script:ArtChecked = $true; return }
    if ($script:Traffic.Halted -or ($script:Tool -and -not $script:Tool.Sync.Done)) { return }
    $script:ArtChecked = $true
    try { [void](Start-HostTool @{ kind = 'artwork'; tab = 'tv'; rids = @() }) } catch { Write-HostLog 'artwork refresh' $_ }
}
function Get-LibraryState {
    # 'ready' (the page copy is at least as new as the snapshot), 'stale' (needs building) or 'empty' (never scanned)
    param([string]$Tab)
    $snap = Get-SnapshotFile $Tab
    $page = Join-Path $script:CacheDir ('library-' + $Tab + '.json')
    if (-not (Test-Path -LiteralPath $snap)) { return $(if (Test-Path -LiteralPath $page) { 'ready' } else { 'empty' }) }
    # stale when the scan or the saved scores (Fetch info, Edit info in the window app) are newer than the page's copy
    $newest = (Get-Item -LiteralPath $snap).LastWriteTimeUtc
    if (Test-Path -LiteralPath $script:MetaStore) { $m = (Get-Item -LiteralPath $script:MetaStore).LastWriteTimeUtc; if ($m -gt $newest) { $newest = $m } }
    $st = Join-Path $script:CacheDir 'art\stamp.txt'                     # artwork saved since (Settings > Artwork)
    if (Test-Path -LiteralPath $st) { $m = (Get-Item -LiteralPath $st).LastWriteTimeUtc; if ($m -gt $newest) { $newest = $m } }
    if ((Test-Path -LiteralPath $page) -and (Get-Item -LiteralPath $page).LastWriteTimeUtc -ge $newest) { return 'ready' }
    'stale'
}

function Get-HostServer {
    # The media server a library comes from (Settings > Servers), as MMLM.Server describes one: kind, address and the
    # decrypted token / API key. Every job that talks to a server gets it from here. Throws a plain message when
    # something is missing. -Kind picks a server directly (Settings > Servers > Test).
    param([ValidateSet('movies', 'tv')][string]$Tab = 'movies', [string]$Kind)
    $set = Read-HostSettings
    if (-not $Kind) { $Kind = $(if ($Tab -eq 'tv') { [string]$set.TvServer } else { [string]$set.MoviesServer }) }
    if (-not $Kind) { $Kind = 'plex' }
    $secret = ''
    try { $secret = Unprotect-MmlmSecret $(if ($Kind -eq 'jellyfin') { $set.JellyfinKeyProtected } else { $set.PlexTokenProtected }) } catch { Write-HostLog 'token' $_ }
    # test hook for tests\Test-MmlmHost.ps1 only: honoured only when the host was started with Debug on
    if ($script:Ctx.Debug -and $env:MMLM_HOST_TEST_TOKEN) { $secret = $env:MMLM_HOST_TEST_TOKEN }
    New-MmlmServer -Kind $Kind -BaseUrl $(if ($Kind -eq 'jellyfin') { [string]$set.JellyfinUrl } else { [string]$set.PlexUrl }) -Token $secret
}
function Start-HostScan {
    param([ValidateSet('movies', 'tv')][string]$Tab, [bool]$Rebuild = $false)
    if ($script:ScanPs -and -not $script:Sync.Done) { throw 'A scan is already running.' }
    if ($script:Traffic.Halted) { throw 'Traffic is paused. Resume it first.' }
    $server = Get-HostServer -Tab $Tab
    Stop-HostScan -Wait 0
    $script:Sync = [hashtable]::Synchronized(@{ Text = 'Starting...'; Value = 0; Max = 0; Cancel = $false; Done = $false; Error = $null; PhaseLo = 0.0; PhaseHi = 1.0; Count = 0; New = 0; Cancelled = $false })
    $ctx = New-WorkerContext $script:Sync
    foreach ($d in $ctx.CacheFolder, $ctx.ThumbFolder) { if (-not (Test-Path -LiteralPath $d)) { New-Item -Path $d -ItemType Directory -Force | Out-Null } }
    $job = @{ Kind = 'scan'; Tab = $Tab; Rebuild = $Rebuild; DetectFel = [bool]$script:PageSettings.detectFel; ArtKinds = @(Get-ArtKinds); Server = $server; Snapshot = (Get-SnapshotFile $Tab); CacheDir = $script:CacheDir; Hidden = $script:HiddenFields; MetaStore = $script:MetaStore }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:ScanScript).AddArgument(@(Get-HostModuleFiles)).AddArgument($ctx).AddArgument($job)
    $script:ScanPs = $ps
    $script:ScanAsync = $ps.BeginInvoke()
    $script:ScanTab = $Tab
    $script:LastScanJson = ''
}

function Stop-HostScan {
    # asks a running scan to stop; with -Wait, gives it up to that many milliseconds and then drops it
    param([int]$Wait = 0)
    if (-not $script:ScanPs) { return }
    if ($script:Sync -and -not $script:Sync.Done) {
        $script:Sync.Cancel = $true
        if ($Wait -gt 0) {
            if (-not $script:ScanAsync.AsyncWaitHandle.WaitOne($Wait)) { try { [void]$script:ScanPs.BeginStop($null, $null) } catch { Write-HostLog 'scan stop' $_ } }
        }
        else { return }
    }
    try { $script:ScanPs.Dispose() } catch { Write-HostLog 'scan dispose' $_ }
    $script:ScanPs = $null; $script:ScanAsync = $null
}

function Get-ScanPct {
    $s = $script:Sync
    if (-not $s -or $s.Done) { return $null }
    $f = 0.0
    if ([int]$s.Max -gt 0) { $f = [double]$s.Value / [double]$s.Max }
    $lo = [double]$s.PhaseLo; $hi = [double]$s.PhaseHi
    [int][Math]::Round(100 * ($lo + ($hi - $lo) * [Math]::Min(1.0, [Math]::Max(0.0, $f))))
}

# ---------------------------------------------------------------- updates (Update-MMLM.ps1 / Apply-Update.ps1, unchanged)
# Update checks talk to GitHub only, so the pause switch leaves them alone. Same work folder as the window app.
function Read-UpdateJson {
    param([string]$Name)
    $p = Join-Path $script:UpdDir $Name
    if (Test-Path -LiteralPath $p) { try { return ([IO.File]::ReadAllText($p) | ConvertFrom-Json) } catch { Write-HostLog ('update ' + $Name) $_ } }
    $null
}
function Get-ChildProgress {
    param([string]$Path)
    $r = @{ pct = 0; text = '' }
    if (-not (Test-Path -LiteralPath $Path)) { return $r }
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite'); $sr = New-Object IO.StreamReader($fs)
        while ($null -ne ($l = $sr.ReadLine())) { if ($l.Trim() -match '^##PROGRESS (\d+)\|(.*)$') { $r.pct = [int]$Matches[1]; $r.text = $Matches[2] } }
        $sr.Close(); $fs.Close()
    } catch { Write-HostLog 'update progress' $_ }
    $r
}
function Start-Updater {
    param([ValidateSet('Check', 'Stage', 'StageZip')][string]$Action, [string]$ZipPath = '')
    if ($script:UpdProc -and -not $script:UpdProc.HasExited) { return $false }
    $tool = Join-Path $script:Root 'Update-MMLM.ps1'
    if (-not (Test-Path -LiteralPath $tool)) { throw 'Update-MMLM.ps1 is missing from the program folder.' }
    if (-not (Test-Path -LiteralPath $script:UpdDir)) { New-Item -ItemType Directory -Path $script:UpdDir -Force | Out-Null }
    Remove-Item -LiteralPath (Join-Path $script:UpdDir 'update-result.json'), $script:UpdOut -Force -ErrorAction SilentlyContinue
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $tool), '-Action', $Action, '-CurrentVersion', $script:Version, '-WorkDir', ('"{0}"' -f $script:UpdDir))
    if ($ZipPath) { $a += '-ZipPath'; $a += ('"{0}"' -f $ZipPath) }
    if ($script:Ctx.Debug -and $env:MMLM_UPDATE_API) { $a += '-ApiBase'; $a += $env:MMLM_UPDATE_API }       # test hook (Debug only)
    $exe = $(if ($script:Ctx.Debug -and $env:MMLM_PS) { $env:MMLM_PS } else { 'powershell.exe' })          # test hook (Debug only)
    $sp = @{ FilePath = $exe; ArgumentList = $a; PassThru = $true; RedirectStandardOutput = $script:UpdOut }
    if ($IsWindows -ne $false) { $sp.WindowStyle = 'Hidden' }       # $IsWindows is $null in Windows PowerShell 5.1
    $script:UpdProc = Start-Process @sp
    $script:UpdAction = $Action
    $script:LastUpdJson = ''
    Push-HostEvent 'update' @{ running = $true; action = $Action; pct = 0; text = 'Starting...' }
    $true
}
function Get-UpdateEvents {
    if (-not $script:UpdProc) { return }
    if ($script:UpdProc.HasExited) {
        $res = Read-UpdateJson 'update-result.json'
        if (-not $res) { $res = [pscustomobject]@{ status = 'error'; error = 'The update check ended without an answer.' } }
        $script:UpdProc = $null
        if (@('available', 'staged') -contains [string]$res.status) { $script:UpdateAvailable = [string]$res.latest }
        elseif ([string]$res.status -eq 'current') { $script:UpdateAvailable = $null }
        Push-HostEvent 'update' @{ running = $false; action = $script:UpdAction; result = $res }
    }
    else {
        $prog = Get-ChildProgress $script:UpdOut
        $json = ConvertTo-PageJson ([ordered]@{ event = 'update'; data = @{ running = $true; action = $script:UpdAction; pct = $prog.pct; text = $prog.text } })
        if ($json -ne $script:LastUpdJson) { $script:LastUpdJson = $json; $script:Out.Enqueue($json) }
    }
}
function Invoke-UpdateApply {
    $st = Read-UpdateJson 'staged.json'
    $stage = Join-Path $script:UpdDir 'stage'
    if (-not $st -or -not (Test-Path -LiteralPath (Join-Path $stage 'Modern-Media-Library-Manager.ps1'))) { throw 'There is no downloaded update to install. Check for updates again.' }
    if ($script:ScanPs -and $script:Sync -and -not $script:Sync.Done) { throw 'A scan is still running. Let it finish (or cancel it), then install the update.' }
    $runDir = Join-Path $script:UpdDir 'run'             # the helper runs from a copy, so replacing the app files cannot touch it
    if (-not (Test-Path -LiteralPath $runDir)) { New-Item -ItemType Directory -Path $runDir -Force | Out-Null }
    $helper = Join-Path $runDir 'Apply-Update.ps1'
    Copy-Item -LiteralPath (Join-Path $script:Root 'Apply-Update.ps1') -Destination $helper -Force
    $relaunch = $(if ($script:Ctx.Relaunch) { [string]$script:Ctx.Relaunch } else { '"' + (Join-Path $script:Root 'Start-MMLM.bat') + '"' })
    $b64 = [Convert]::ToBase64String((New-Object Text.UTF8Encoding($false)).GetBytes($relaunch))
    $hostPid = $(if ($script:Ctx.HostPid) { [int]$script:Ctx.HostPid } else { $PID })
    $h = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $helper), '-AppDir', ('"{0}"' -f $script:Root), '-StageDir', ('"{0}"' -f $stage),
           '-WorkDir', ('"{0}"' -f $script:UpdDir), '-ParentPid', [string]$hostPid, '-RelaunchB64', $b64, '-OldVersion', $script:Version, '-NewVersion', [string]$st.version)
    Start-Process -FilePath 'powershell.exe' -ArgumentList $h -WindowStyle Hidden | Out-Null
}
function Get-ZipVersion {
    # VERSION at the zip's root or inside its one top folder; $null when there is none
    param([string]$Zip)
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead($Zip)
        try {
            $e = @($z.Entries | Where-Object { $_.FullName -match '^([^/\\]+[/\\])?VERSION$' }) | Select-Object -First 1
            if ($null -eq $e) { return $null }
            $rd = New-Object IO.StreamReader($e.Open())
            try { $t = $rd.ReadToEnd().Trim() } finally { $rd.Dispose() }
            if ($t -match '^\d+\.\d+\.\d+$') { return $t }
        } finally { $z.Dispose() }
    } catch { Write-HostLog 'drop-in zip' $_ }
    $null
}
function Watch-DropFolder {
    # Standalone only (in the launcher, DashLauncher's own drop-in handles updates): offers a newer zip saved into <app>\updates.
    if ($script:Ctx.Mode -ne 'standalone' -or $script:UpdProc) { return }
    if (((Get-Date) - $script:DropLook).TotalSeconds -lt 3) { return }
    $script:DropLook = Get-Date
    $dir = Join-Path $script:Root 'updates'
    if (-not (Test-Path -LiteralPath $dir)) { return }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.zip' -File -ErrorAction SilentlyContinue)) {
        if ($script:DropAsked.ContainsKey($f.FullName)) { continue }
        $sig = '{0}|{1}' -f $f.Length, $f.LastWriteTimeUtc.Ticks
        if ($script:DropSeen[$f.FullName] -ne $sig) { $script:DropSeen[$f.FullName] = $sig; continue }       # still being written
        try { $x = [IO.File]::Open($f.FullName, 'Open', 'Read', 'None'); $x.Dispose() } catch { continue }     # still open elsewhere
        $script:DropAsked[$f.FullName] = $true
        $v = Get-ZipVersion $f.FullName
        if (-not $v) { continue }
        try { if ([version]$v -le [version]$script:Version) { continue } } catch { continue }
        Push-HostEvent 'update.dropped' @{ file = $f.Name; version = $v }
        return
    }
}

# ---------------------------------------------------------------- series view (one show's details from Plex, on demand)
# Opening a show in the page asks your Plex server for what a scan does not keep: episode stills, summaries, watched
# marks, cast and related shows. Saved in Dashboard\series (the page reads it from there); opening it again uses the
# saved copy until you press Refresh. Counts as data traffic, so the pause switch stops it.
$script:SeriesScript = {
    param($ModuleFiles, $Ctx, $Job)
    foreach ($m in $ModuleFiles) { Import-Module $m -DisableNameChecking }
    Set-MmlmContext -Values $Ctx; Set-MmlmServerContext -Values $Ctx
    $S = $Ctx.Sync
    try {
        $res = Get-MmlmServerSeries -Server $Job.Server -ShowKey ([string]$Job.ShowKey) -EpKey ([string]$Job.EpKey) -ImageFolder (Join-Path $Job.CacheDir 'series\img') -Sync $S
        if ($S.Cancel -or $null -eq $res) { $S.Cancelled = $true; return }
        $file = Join-Path (Join-Path $Job.CacheDir 'series') ($res.Key + '.json')
        [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $res.Data -Depth 6 -Compress), (New-Object Text.UTF8Encoding($false)))
        $S.ShowKey = $res.Key
    }
    catch { $S.Error = $_.Exception.Message }
    finally { $S.Done = $true }
}

# Settings > Servers > Test runs in the background: the host's own calls never wait on the network.
$script:ServerTest = $null
$script:ServerTestScript = {
    param($ModuleFiles, $Ctx, $Server)
    foreach ($m in $ModuleFiles) { Import-Module $m -DisableNameChecking }
    Set-MmlmContext -Values $Ctx; Set-MmlmServerContext -Values $Ctx
    try { @{ ok = $true; info = (Test-MmlmServer $Server) } } catch { @{ ok = $false; error = $_.Exception.Message } }
}
function Start-HostServerTest {
    param([string]$Kind)
    if ($script:ServerTest) { throw 'A test is already running.' }
    $server = Get-HostServer -Kind $Kind
    $sync = [hashtable]::Synchronized(@{ Text = ''; Value = 0; Max = 0; Cancel = $false; Done = $false; PhaseLo = 0.0; PhaseHi = 1.0 })
    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:ServerTestScript).AddArgument(@(Get-HostModuleFiles)).AddArgument((New-WorkerContext $sync)).AddArgument($server)
    $script:ServerTest = @{ Ps = $ps; Async = $ps.BeginInvoke(); Kind = $Kind }
}
function Get-ServerTestEvents {
    $x = $script:ServerTest
    if (-not $x -or -not $x.Async.IsCompleted) { return }
    $script:ServerTest = $null
    $res = $null
    try { $res = @($x.Ps.EndInvoke($x.Async)) | Select-Object -Last 1 } catch { $res = @{ ok = $false; error = $_.Exception.Message } }
    finally { $x.Ps.Dispose() }
    if ($null -eq $res) { $res = @{ ok = $false; error = 'No answer.' } }
    Push-HostEvent 'servertest' ([ordered]@{ kind = $x.Kind; ok = [bool]$res.ok; info = $res.info; error = [string]$res.error })
}

function Get-SeriesIndex {
    # show name -> Plex show key, learnt on the first open (Library\series-index.json)
    $p = Join-Path (Split-Path (Get-SnapshotFile 'tv')) 'series-index.json'
    $o = @{}
    if (Test-Path -LiteralPath $p) { try { foreach ($pr in ([IO.File]::ReadAllText($p) | ConvertFrom-Json).PSObject.Properties) { $o[$pr.Name] = [string]$pr.Value } } catch { Write-HostLog 'series index' $_ } }
    $o
}
function Start-HostSeries {
    param([string]$Show, [string]$EpKey, [bool]$Refresh)
    if ($script:Series -and -not $script:Series.Sync.Done) {
        if ($script:Series.Show -eq $Show) { return 'loading' }
        $script:Series.Sync.Cancel = $true
    }
    $idx = Get-SeriesIndex
    $key = [string]$idx[$Show]
    if ($key -and -not $Refresh) {
        $f = Join-Path $script:CacheDir ('series\' + $key + '.json')
        if (Test-Path -LiteralPath $f) { return [IO.File]::ReadAllText($f) }
    }
    if ($script:Traffic.Halted) { throw 'Traffic is paused. Resume it first.' }
    if (-not $EpKey -and -not $key) { throw 'This show was not scanned from Plex, so there is nothing more to fetch.' }
    $server = $null
    try { $server = Get-HostServer -Tab 'tv' } catch { throw 'Add your server in Settings > Servers first.' }
    $sync = [hashtable]::Synchronized(@{ Text = 'Starting...'; Pct = 0; Cancel = $false; Done = $false; Error = $null; Cancelled = $false; ShowKey = ''; Value = 0; Max = 0; PhaseLo = 0.0; PhaseHi = 1.0 })
    $job = @{ Server = $server; EpKey = $EpKey; ShowKey = $key; CacheDir = $script:CacheDir }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:SeriesScript).AddArgument(@(Get-HostModuleFiles)).AddArgument((New-WorkerContext $sync)).AddArgument($job)
    $script:Series = @{ Ps = $ps; Async = $ps.BeginInvoke(); Sync = $sync; Show = $Show; Last = '' }
    'loading'
}
function Get-SeriesEvents {
    $x = $script:Series
    if (-not $x) { return }
    $s = $x.Sync
    if ($s.Done) {
        $script:Series = $null
        try { $x.Ps.Dispose() } catch { Write-HostLog 'series dispose' $_ }
        if ($s.ShowKey) {
            $idx = Get-SeriesIndex; $idx[$x.Show] = $s.ShowKey
            try { [IO.File]::WriteAllText((Join-Path (Split-Path (Get-SnapshotFile 'tv')) 'series-index.json'), (ConvertTo-Json -InputObject $idx -Compress), (New-Object Text.UTF8Encoding($false))) } catch { Write-HostLog 'series index' $_ }
        }
        Push-HostEvent 'series' ([ordered]@{ show = $x.Show; running = $false; error = $s.Error; cancelled = [bool]$s.Cancelled })
        return
    }
    $d = [ordered]@{ show = $x.Show; running = $true; pct = [int]$s.Pct; text = [string]$s.Text }
    $j = ConvertTo-PageJson $d
    if ($j -ne $x.Last) { $x.Last = $j; Push-HostEvent 'series' $d }
}

# ---------------------------------------------------------------- tools: Fetch info, FEL/MEL probe, CSV and HTML export
# One background job at a time. Each works on the titles the page names (its current view) or the whole tab.
#   fetch: ratings, Metacritic, RT and box office from TMDB / OMDb / IMDb (your keys) into metadata\store.json, as the
#          window app's Fetch info does. Only when you start it. Counts as data traffic.
#   fel:   tells Dolby Vision FEL from MEL with ffmpeg + dovi_tool (lib folder), for dual-layer files this PC can open.
#   csv / html: the titles as a spreadsheet, or as the old standalone dashboard page (posters inside), in
#          Documents\Modern Media Library Manager. File locations are left out of both.
$script:ToolScript = {
    param($ModuleFiles, $Ctx, $Job)
    foreach ($m in $ModuleFiles) { Import-Module $m -DisableNameChecking }
    Set-MmlmContext -Values $Ctx; Set-MmlmServerContext -Values $Ctx; Set-MmlmFetchContext -Values $Ctx
    $S = $Ctx.Sync
    try {
        Initialize-MmlmNative
        Set-MmlmProgress -Text 'Opening the library...'
        $recs = @([Mmlm.Native.Snapshot]::Load($Job.Snapshot))
        try { Merge-MmlmMetaStore -Records $recs -Path $Job.MetaStore } catch { }
        $rid = { param($r) if ([string]$r.PlexKey) { 'p:' + [string]$r.PlexKey } elseif ([string]$r.FullPath) { 'h:' + (Get-MmlmStringHash ([string]$r.FullPath)).Substring(0, 16) } else { '' } }
        $want = $null
        if (@($Job.Rids).Count -gt 0) { $want = New-Object 'System.Collections.Generic.HashSet[string]'; foreach ($x in $Job.Rids) { [void]$want.Add([string]$x) } }
        $idx = New-Object System.Collections.Generic.List[int]
        for ($i = 0; $i -lt $recs.Count; $i++) { if ($null -eq $want -or $want.Contains((& $rid $recs[$i]))) { $idx.Add($i) } }
        $outDir = [Environment]::GetFolderPath('MyDocuments')
        $outDir = $(if ($outDir) { Join-Path $outDir 'Modern Media Library Manager' } else { Join-Path $Ctx.AppData 'Exports' })
        $safe = (([string]$Job.Name) -replace '[^A-Za-z0-9 ._()-]', '').Trim(); if (-not $safe) { $safe = 'Library' }
        switch ($Job.Kind) {
            'doctor' {
                # PlexDoctor: a read-only check-up of what the last scans saw; the report goes to AppData\PlexDoctor\reports
                $mv = @(); $ep = @()
                if (Test-Path -LiteralPath $Job.Snapshots[0]) { $mv = @([Mmlm.Native.Snapshot]::Load($Job.Snapshots[0])) }
                if (Test-Path -LiteralPath $Job.Snapshots[1]) { $ep = @([Mmlm.Native.Snapshot]::Load($Job.Snapshots[1])) }
                if (-not (Test-Path -LiteralPath $Job.ReportDir)) { New-Item -ItemType Directory -Force -Path $Job.ReportDir | Out-Null }
                $old = @(Get-ChildItem -LiteralPath $Job.ReportDir -Filter 'report-*.json' -File | Sort-Object Name)
                $prev = $null
                if ($old.Count) { try { $prev = [IO.File]::ReadAllText($old[-1].FullName) | ConvertFrom-Json } catch { } }
                $rep = Invoke-MmlmDoctor -Movies $mv -Episodes $ep -Checks @($Job.Checks) -Previous $prev -Late $Job.Late -Notes @($Job.Notes)
                $file = Join-Path $Job.ReportDir ('report-{0}.json' -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
                [IO.File]::WriteAllText($file, ($rep | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
                foreach ($f in @($old | Select-Object -SkipLast 9)) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }   # keep the last 10
                $S.Path = $file
                $S.Summary = $(if ($rep.issues.Count) { ('PlexDoctor found {0} issue{1}.' -f $rep.issues.Count, $(if ($rep.issues.Count -eq 1) { '' } else { 's' })) } else { 'PlexDoctor: no issues found.' })
            }
            'artwork' {
                # Settings > Artwork was ticked: fetch it now for every scanned tab instead of waiting for the next scan
                $res = @{ Saved = 0; Failed = 0; Stopped = $false }
                foreach ($t0 in 'movies', 'tv') {
                    $snap = $Job.Snapshots[$(if ($t0 -eq 'tv') { 1 } else { 0 })]
                    if ($res.Stopped -or -not $Job.Servers.ContainsKey($t0) -or -not (Test-Path -LiteralPath $snap)) { continue }
                    $part = Sync-MmlmServerArtwork -Server $Job.Servers[$t0] -Recs @([Mmlm.Native.Snapshot]::Load($snap)) -Kinds @($Job.ArtKinds) -Folder (Join-Path $Job.CacheDir 'art') -Force:([bool]$Job.Force)
                    $res.Saved += $part.Saved; $res.Failed += $part.Failed; $res.Stopped = $part.Stopped
                }
                $S.Summary = $(if ($res.Stopped) { 'Artwork stopped: the server did not answer three times in a row. Try again later.' } elseif ($Job.Force) { ('Artwork refreshed from your server: {0} picture{1}.' -f $res.Saved, $(if ($res.Saved -eq 1) { '' } else { 's' })) } else { ('Artwork: {0} new picture{1}.' -f $res.Saved, $(if ($res.Saved -eq 1) { '' } else { 's' })) })
                if ($res.Stopped) { $S.Error = $S.Summary }
                $S.Library = ($res.Saved -gt 0 -or [bool]$Job.Force)
            }
            'fetch' {
                if ($Job.Tab -eq 'tv') {      # TV Shows: whether each show is still running (TMDB)
                    $S.Summary = Invoke-MmlmShowStatusFetch -Records $recs -Indexes $idx.ToArray() -TmdbKey $Job.TmdbKey -StorePath $Job.StatusStore -Overwrite ([bool]$Job.Overwrite)
                    $S.Library = $true
                    break
                }
                $S.Partial = New-Object System.Collections.ArrayList
                Invoke-MmlmMetadataScrape -Records $recs -Indexes $idx.ToArray() -TmdbKey $Job.TmdbKey -OmdbKey $Job.OmdbKey -Overwrite ([bool]$Job.Overwrite) -DataFolder $Job.DataFolder -StorePath $Job.MetaStore
                $S.Summary = [string]$S.Summary
                $S.Library = $true
            }
            'fel' {
                $targets = @($idx | Where-Object { [string]$recs[$_].DVLayer -eq 'Dual layer' })
                $tools = (Find-MmlmTool 'ffmpeg.exe') -and (Find-MmlmTool 'dovi_tool.exe')
                if (-not $tools) { throw 'The FEL/MEL check needs ffmpeg.exe and dovi_tool.exe in the lib folder (or on PATH).' }
                $fel = 0; $mel = 0; $unk = 0; $away = 0; $n = 0
                foreach ($i in $targets) {
                    if ($S.Cancel) { break }
                    $n++; $r = $recs[$i]
                    Set-MmlmProgress -Text ('Checking {0} of {1}: {2}' -f $n, $targets.Count, $r.Title) -Value $n -Max $targets.Count
                    if (-not [string]$r.FullPath -or -not (Test-Path -LiteralPath ([string]$r.FullPath) -ErrorAction SilentlyContinue)) { $away++; continue }
                    $t = Get-MmlmDolbyVisionLayerType -Path ([string]$r.FullPath) -DurationSec ([int]([double]$r.RuntimeMin * 60))
                    if ($t) {
                        Set-MmlmRecField $r 'DVLayer' $t
                        Set-MmlmRecField $r 'HDRStack' (([string]$r.HDRStack) -replace ' \(dual layer\)', (' ' + $t))
                        if ($t -eq 'FEL') { $fel++ } else { $mel++ }
                    } else { $unk++ }
                }
                if ($fel + $mel -gt 0) { [Mmlm.Native.Snapshot]::Save([object[]]$recs, $Job.Snapshot, ('{0}|{1}' -f $recs.Count, (Get-Date).ToString('yyyy-MM-dd HH:mm'))) }
                $S.Summary = $(if ($targets.Count -eq 0) { 'No dual-layer Dolby Vision titles here: nothing to check.' } else {
                    ('Checked {0}: {1} FEL, {2} MEL, {3} could not tell{4}.' -f ($n - $away), $fel, $mel, $unk, $(if ($away) { ", $away not reachable from this PC" } else { '' })) })
                $S.Library = ($fel + $mel -gt 0)
            }
            'csv' {
                if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
                $cols = @(@($Job.Columns) | Where-Object { $Job.Hidden -notcontains $_ -and ($Ctx.Fields | Where-Object Name -eq $_) })
                if ($cols.Count -eq 0) { $cols = @($Ctx.Fields | Where-Object { $_.Group -ne 'Clues' -and $Job.Hidden -notcontains $_.Name } | ForEach-Object { $_.Name }) }
                if ($cols -notcontains 'Title') { $cols = @('Title') + $cols }
                $file = Join-Path $outDir ($safe + '.csv'); $k = 2
                while (Test-Path -LiteralPath $file) { $file = Join-Path $outDir ('{0} ({1}).csv' -f $safe, $k); $k++ }
                @($idx | ForEach-Object { $recs[$_] | Select-Object -Property $cols }) | Export-Csv -LiteralPath $file -NoTypeInformation -Encoding UTF8
                $S.Path = $file; $S.Summary = ('{0} titles saved.' -f $idx.Count)
            }
            'html' {
                if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
                $tpl = Join-Path $Ctx.AppRoot 'dashboard-template.html'
                if (-not (Test-Path -LiteralPath $tpl)) { throw 'dashboard-template.html is missing from the program folder.' }
                $clues = @($Ctx.Fields | Where-Object { $_.Group -eq 'Clues' } | ForEach-Object { $_.Name })
                $rows = New-Object System.Collections.Generic.List[object]; $n = 0
                foreach ($i in $idx) {
                    $n++; $r = $recs[$i]
                    if (($n % 25) -eq 0) { Set-MmlmProgress -Text ('Building the page: {0} of {1}' -f $n, $idx.Count) -Value $n -Max $idx.Count }
                    $row = [ordered]@{}
                    foreach ($p in $r.PSObject.Properties) { if ($Job.Hidden -notcontains $p.Name -and $clues -notcontains $p.Name) { $row[$p.Name] = $p.Value } }
                    $row['Poster'] = ''
                    $pp = [string]$r.PosterPath
                    if ($pp) {
                        $leaf = $(if ($pp.StartsWith($Ctx.ThumbFolder, [StringComparison]::OrdinalIgnoreCase)) { [IO.Path]::GetFileName($pp) } else { (Get-MmlmStringHash $pp) + [IO.Path]::GetExtension($pp).ToLowerInvariant() })
                        $th = Join-Path $Job.CacheDir ('thumbs\' + $leaf)
                        if (Test-Path -LiteralPath $th) { $row['Poster'] = 'data:image/jpeg;base64,' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($th)) }
                    }
                    $rows.Add([pscustomobject]$row)
                }
                $json = (ConvertTo-Json -InputObject $rows.ToArray() -Depth 4 -Compress).Replace('</', '<\/')
                $meta = ConvertTo-Json -Compress -InputObject @{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); library = [string]$Job.Library; collection = [string]$Job.Name; dateOrder = $false }
                $html = [IO.File]::ReadAllText($tpl, [Text.Encoding]::UTF8).Replace('__META__', $meta).Replace('__DATA__', $json)
                $file = Join-Path $outDir ($safe + '.html'); $k = 2
                while (Test-Path -LiteralPath $file) { $file = Join-Path $outDir ('{0} ({1}).html' -f $safe, $k); $k++ }
                [IO.File]::WriteAllText($file, $html, (New-Object Text.UTF8Encoding($false)))
                $S.Path = $file; $S.Summary = ('{0} titles in one page (posters included).' -f $idx.Count)
            }
        }
    }
    catch { $S.Error = $_.Exception.Message }
    finally { $S.Done = $true }
}

function Read-HostKeys {
    # the TMDB / OMDb keys the window app saved (or the page's Settings > Data)
    $p = Join-Path $script:AppData 'settings.json'
    $k = @{ Tmdb = ''; Omdb = '' }
    if (Test-Path -LiteralPath $p) {
        try {
            $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json
            if ($j.TmdbKeyProtected) { $k.Tmdb = Unprotect-MmlmSecret ([string]$j.TmdbKeyProtected) }
            if ($j.OmdbKeyProtected) { $k.Omdb = Unprotect-MmlmSecret ([string]$j.OmdbKeyProtected) }
        } catch { Write-HostLog 'keys' $_ }
    }
    $k
}
function Save-HostKeys {
    # Writes only the two key fields (encrypted for this Windows user, as the window app does); other keys stay.
    param([string]$Tmdb, [string]$Omdb)
    $p = Join-Path $script:AppData 'settings.json'
    $o = [ordered]@{}
    if (Test-Path -LiteralPath $p) { try { foreach ($pr in ([IO.File]::ReadAllText($p) | ConvertFrom-Json).PSObject.Properties) { $o[$pr.Name] = $pr.Value } } catch { Write-HostLog 'settings read' $_ } }
    if ($null -ne $Tmdb) { $o['TmdbKeyProtected'] = $(if ($Tmdb) { Protect-MmlmSecret $Tmdb } else { '' }) }
    if ($null -ne $Omdb) { $o['OmdbKeyProtected'] = $(if ($Omdb) { Protect-MmlmSecret $Omdb } else { '' }) }
    [IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject $o -Depth 6), (New-Object Text.UTF8Encoding($false)))
}
function Start-HostTool {
    param($A)
    $kind = [string]$A.kind
    if (@('fetch', 'fel', 'csv', 'html', 'artwork', 'doctor') -notcontains $kind) { throw 'Unknown tool.' }
    if ($script:Tool -and -not $script:Tool.Sync.Done) { throw 'Another tool is still running. Wait for it or cancel it.' }
    $tab = $(if ([string]$A.tab -eq 'tv') { 'tv' } else { 'movies' })
    if ($kind -eq 'doctor' -and -not (Test-Path -LiteralPath (Get-SnapshotFile 'movies')) -and (Test-Path -LiteralPath (Get-SnapshotFile 'tv'))) { $tab = 'tv' }
    if ($kind -ne 'artwork' -and -not (Test-Path -LiteralPath (Get-SnapshotFile $tab))) { throw 'Scan this tab first.' }
    if (@('fetch', 'fel', 'artwork') -contains $kind -and $script:Traffic.Halted) { throw 'Traffic is paused. Resume it first.' }
    $job = @{ Kind = $kind; Tab = $tab; Snapshot = (Get-SnapshotFile $tab); CacheDir = $script:CacheDir; Hidden = $script:HiddenFields; MetaStore = $script:MetaStore
        Rids = @(@($A.rids) | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^(p|h):' }); Columns = @(@($A.columns) | ForEach-Object { [string]$_ })
        Name = [string]$A.name; Library = $(if ($tab -eq 'tv') { 'TV Shows' } else { 'Movies' }); Overwrite = [bool]$A.overwrite; DataFolder = (Join-Path $script:AppData 'datasets') }
    if ($kind -eq 'doctor') {
        $job.Snapshots = @((Get-SnapshotFile 'movies'), (Get-SnapshotFile 'tv'))
        $job.Checks = @($script:PageSettings.doctorChecks)
        $job.ReportDir = Join-Path $script:AppData 'PlexDoctor\reports'
        $job.Late = [string]$A.late; $job.Notes = @($A.notes)
    }
    if ($kind -eq 'artwork') {
        $job.ArtKinds = @(Get-ArtKinds)
        $job.Force = [bool]$a.force          # Settings > Artwork > Refresh artwork: everything again from Plex
        if ($job.ArtKinds.Count -eq 0) { throw 'Tick an artwork option first.' }
        $job.Snapshots = @((Get-SnapshotFile 'movies'), (Get-SnapshotFile 'tv'))
        # each library from its own server (Settings > Servers); a library with no server set up is skipped
        $job.Servers = @{}
        foreach ($t0 in 'movies', 'tv') { try { $job.Servers[$t0] = Get-HostServer -Tab $t0 } catch { } }
        if ($job.Servers.Count -eq 0) { throw 'Add your server in Settings > Servers first.' }
    }
    if ($kind -eq 'fetch') {
        $k = Read-HostKeys
        if ($tab -eq 'tv' -and -not $k.Tmdb) { throw 'Show status comes from TMDB: add a TMDB key in Settings > Data first.' }
        if (-not $k.Tmdb -and -not $k.Omdb) { throw 'Add a TMDB or OMDb key in Settings > Data first.' }
        $job.StatusStore = Join-Path $script:AppData 'Library\show-status.json'
        $job.TmdbKey = $k.Tmdb; $job.OmdbKey = $k.Omdb
    }
    $sync = [hashtable]::Synchronized(@{ Text = 'Starting...'; Value = 0; Max = 0; Cancel = $false; Done = $false; Error = $null; PhaseLo = 0.0; PhaseHi = 1.0; Summary = ''; Path = ''; Library = $false; Total = 0; Partial = $null })
    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:ToolScript).AddArgument(@(Get-HostModuleFiles)).AddArgument((New-WorkerContext $sync)).AddArgument($job)
    $script:Tool = @{ Ps = $ps; Async = $ps.BeginInvoke(); Sync = $sync; Kind = $kind; Tab = $tab; Last = '' }
    $true
}
# ---------------------------------------------------------------- PlexDoctor (Settings > PlexDoctor)
# A check-up: a scan of each library that has been scanned before (so it sees what Plex has now), then the read-only
# checks (MMLM.Doctor) as a tool run. On a schedule (only while MMLM is open; a missed one runs when it is next opened)
# or from Run check-up now. State and the last 10 reports live in AppData\PlexDoctor.
$script:Doctor = $null
$script:DoctorTick = [datetime]::MinValue
$script:LastScanResult = $null
function Get-DoctorDir { Join-Path $script:AppData 'PlexDoctor' }
function Read-DoctorState {
    $p = Join-Path (Get-DoctorDir) 'state.json'
    $o = [ordered]@{ lastSlot = ''; lastRun = ''; unseen = $false; schedule = '' }
    if (Test-Path -LiteralPath $p) { try { $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json; foreach ($k in @($o.Keys)) { if ($null -ne $j.$k) { $o[$k] = $j.$k } } } catch { Write-HostLog 'doctor state' $_ } }
    $o
}
function Save-DoctorState {
    param($State)
    $d = Get-DoctorDir; if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    [IO.File]::WriteAllText((Join-Path $d 'state.json'), ($State | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
}
function Get-DoctorScheduleKey { $p = $script:PageSettings; '{0}|{1}|{2}' -f $p.doctorFreq, $p.doctorDay, $p.doctorTime }
function Get-LatestDoctorReport {
    $d = Join-Path (Get-DoctorDir) 'reports'
    if (-not (Test-Path -LiteralPath $d)) { return $null }
    $f = @(Get-ChildItem -LiteralPath $d -Filter 'report-*.json' -File | Sort-Object Name | Select-Object -Last 1)
    if ($f.Count) { $f[0].FullName } else { $null }
}
function Start-HostDoctor {
    param([string]$Late = '', [switch]$Manual)
    if ($script:Doctor) { throw 'A check-up is already running.' }
    $have = @(@('movies', 'tv') | Where-Object { Test-Path -LiteralPath (Get-SnapshotFile $_) })
    if ($have.Count -eq 0) { throw 'Scan Movies or TV Shows first: PlexDoctor checks what the scans saw.' }
    $script:Doctor = @{ Queue = [System.Collections.Generic.List[string]]$have; Scanning = ''; Late = $Late; Notes = (New-Object System.Collections.Generic.List[string]); Manual = [bool]$Manual; Checking = $false }
    Push-HostEvent 'doctor' ([ordered]@{ running = $true; text = 'Starting the check-up...' })
    $true
}
function Step-HostDoctor {
    # every poll: the schedule (twice a minute), then the next step of a running check-up
    $now = Get-Date
    if (-not $script:Doctor -and ($now - $script:DoctorTick).TotalSeconds -ge 30) {
        $script:DoctorTick = $now
        $p = $script:PageSettings
        # a schedule runs only once it has been turned on with its warning acknowledged (DASH-CONTRACT fetching rule 2)
        if ($p -and [string]$p.doctorFreq -ne 'off' -and [bool]$p.doctorAck) {
            $st = Read-DoctorState
            $slot = Get-MmlmDoctorSlot -Now $now -Freq ([string]$p.doctorFreq) -Day ([int]$p.doctorDay) -Time ([string]$p.doctorTime)
            if (-not $st.lastSlot -or $st.schedule -ne (Get-DoctorScheduleKey)) {
                # first time, or the schedule was changed: start counting from now (no surprise run)
                $st.lastSlot = $slot.ToString('s'); $st.schedule = (Get-DoctorScheduleKey); Save-DoctorState $st
            }
            elseif (-not $script:Traffic.Halted -and (Test-MmlmDoctorDue -Now $now -Freq ([string]$p.doctorFreq) -Day ([int]$p.doctorDay) -Time ([string]$p.doctorTime) -Last ([datetime]$st.lastSlot))) {
                $late = $(if (($now - $slot).TotalMinutes -gt 15) { 'Ran late: missed ' + $slot.ToString('dddd MMM d, h:mm tt') } else { '' })
                $st.lastSlot = $slot.ToString('s'); Save-DoctorState $st
                try { [void](Start-HostDoctor -Late $late) } catch { Write-HostLog 'doctor schedule' $_ }
            }
        }
    }
    $d = $script:Doctor
    if (-not $d -or $d.Checking) { return }
    if ($script:ScanPs -and -not $script:Sync.Done) { return }                   # a scan is running (ours or yours): wait
    if ($d.Scanning) {
        $res = $script:LastScanResult
        if ($res -and $res.Tab -eq $d.Scanning -and ($res.Error -or $res.Cancelled)) { $d.Notes.Add(('{0} could not be scanned ({1}); checked the last scan instead.' -f $(if ($d.Scanning -eq 'tv') { 'TV Shows' } else { 'Movies' }), $(if ($res.Error) { $res.Error } else { 'cancelled' }))) }
        $d.Scanning = ''
    }
    if ($d.Queue.Count) {
        $tab = $d.Queue[0]; $d.Queue.RemoveAt(0)
        if ($script:Traffic.Halted) { $d.Notes.Add('Traffic was paused, so nothing was scanned; checked the last scans.'); $d.Queue.Clear(); return }
        try { $script:LastScanResult = $null; [void](Start-HostScan -Tab $tab); $d.Scanning = $tab }
        catch { $d.Notes.Add(('{0} could not be scanned ({1}); checked the last scan instead.' -f $(if ($tab -eq 'tv') { 'TV Shows' } else { 'Movies' }), $_.Exception.Message)) }
        return
    }
    if ($script:Tool -and -not $script:Tool.Sync.Done) { return }                # another tool is running: wait
    $d.Checking = $true
    try { [void](Start-HostTool @{ kind = 'doctor'; late = $d.Late; notes = @($d.Notes) }) }
    catch { $script:Doctor = $null; Push-HostEvent 'doctor' ([ordered]@{ running = $false; done = $true; error = $_.Exception.Message }) }
}
function Complete-HostDoctor {
    param($Err, [bool]$Cancelled)
    $script:Doctor = $null
    $sum = Get-DoctorSummary
    $st = Read-DoctorState
    $st.lastRun = (Get-Date).ToString('s')
    $st.unseen = [bool]($sum -and $sum.issues -gt 0 -and -not $Err -and -not $Cancelled)
    Save-DoctorState $st
    Push-HostEvent 'doctor' ([ordered]@{ running = $false; done = $true; error = $Err; cancelled = $Cancelled; summary = $sum })
}
function Get-DoctorSummary {
    $f = Get-LatestDoctorReport
    if (-not $f) { return $null }
    try { $r = [IO.File]::ReadAllText($f) | ConvertFrom-Json } catch { return $null }
    $byCheck = [ordered]@{}
    $short = @{ unreadable = @('unreadable file', 'unreadable files'); unmatched = @('not matched', 'not matched') }
    foreach ($i in @($r.issues)) { if ($i.sev -eq 'important') { $n = [string]$i.check; if (-not $byCheck.Contains($n)) { $byCheck[$n] = 0 }; $byCheck[$n]++ } }
    [ordered]@{ at = [string]$r.at; late = [string]$r.late; issues = @($r.issues).Count; important = [int]$r.important; minor = [int]$r.minor
        importantText = (@($byCheck.Keys | ForEach-Object { $w = $short[$_]; '{0} {1}' -f $byCheck[$_], $(if ($w) { $w[[int]($byCheck[$_] -ne 1)] } else { [string]$r.names.$_ }) }) -join ', ')
        counts = $r.counts; newCount = [int]$r.newCount; fixedCount = [int]$r.fixedCount; compared = [bool]$r.compared }
}
function Get-DoctorStatus {
    $p = $script:PageSettings; $st = Read-DoctorState
    $next = ''
    if ([string]$p.doctorFreq -ne 'off' -and [bool]$p.doctorAck) {
        $last = $(if ($st.lastSlot -and $st.schedule -eq (Get-DoctorScheduleKey)) { [datetime]$st.lastSlot } else { $null })
        $next = (Get-MmlmDoctorNext -Now (Get-Date) -Freq ([string]$p.doctorFreq) -Day ([int]$p.doctorDay) -Time ([string]$p.doctorTime) -Last $last).ToString('s')
    }
    ConvertTo-PageJson ([ordered]@{ running = [bool]$script:Doctor; next = $next; unseen = [bool]$st.unseen; last = (Get-DoctorSummary); checks = @(foreach ($k in Get-MmlmDoctorCheckIds) { $k }) })
}

function Get-ToolEvents {
    $x = $script:Tool
    if (-not $x) { return }
    $s = $x.Sync
    if ($s.Done) {
        $script:Tool = $null
        try { $x.Ps.Dispose() } catch { Write-HostLog 'tool dispose' $_ }
        Push-HostEvent 'tool' ([ordered]@{ kind = $x.Kind; tab = $x.Tab; running = $false; error = $s.Error; summary = [string]$s.Summary; path = $(if ($x.Kind -eq 'doctor') { '' } else { [string]$s.Path }); cancelled = [bool]$s.Cancel })
        if ($x.Kind -eq 'doctor') { Complete-HostDoctor -Err $s.Error -Cancelled ([bool]$s.Cancel) }
        if ($s.Library -and -not $s.Error) { foreach ($t in $(if ($x.Kind -eq 'artwork') { @('movies', 'tv') } else { @($x.Tab) })) { Push-HostEvent 'library' @{ tab = $t; ready = $true; error = $null } } }
        return
    }
    $pct = $(if ($s.Max -gt 0) { [int](100 * $s.Value / $s.Max) } else { 0 })
    $d = [ordered]@{ kind = $x.Kind; tab = $x.Tab; running = $true; pct = $pct; text = [string]$s.Text }
    $j = ConvertTo-PageJson $d
    if ($j -ne $x.Last) { $x.Last = $j; Push-HostEvent 'tool' $d }
}
function Show-HostExport {
    # "Show in folder": only files in the export folder.
    param([string]$Path)
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $dir = $(if ($docs) { Join-Path $docs 'Modern Media Library Manager' } else { Join-Path $script:AppData 'Exports' })
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($dir + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $full)) { throw 'Only exported files can be shown.' }
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $full)
}

# ---------------------------------------------------------------- collections (the window app's collections.json, shared)
# A file path never reaches the page: local ids ("f:<path>") go out as "h:<hash>" and come back through the id maps.
function ConvertTo-PageId { param([string]$Id) if ($Id.StartsWith('f:')) { 'h:' + (Get-MmlmStringHash $Id.Substring(2)).Substring(0, 16) } else { $Id } }
function Read-HostCollections {
    $p = Join-Path $script:AppData 'collections.json'
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    try { return @(([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json).Collections) } catch { Write-HostLog 'collections read' $_; return @() }
}
function Get-PageCollections {
    $out = @()
    foreach ($c in (Read-HostCollections)) {
        if ($null -eq $c -or -not $c.Name) { continue }
        $items = @(foreach ($it in @($c.Items)) { if ($it -and $it.Ids) { [ordered]@{ ids = @(@($it.Ids) | ForEach-Object { ConvertTo-PageId ([string]$_) }); title = [string]$it.Title; year = [int]$it.Year } } })
        $out += [ordered]@{ name = [string]$c.Name; tab = $(if (@('movies', 'tv') -contains [string]$c.Tab) { [string]$c.Tab } else { '' }); type = $(if ([string]$c.Type -eq 'rule') { 'rule' } else { 'manual' }); query = [string]$c.Query; sortBy = [string]$c.SortBy
            sortDesc = [bool]$c.SortDesc; byDate = [bool]$c.ByDate; limit = [int]$c.Limit; items = $items; created = [string]$c.Created; modified = [string]$c.Modified }
    }
    , $out
}
function Save-PageCollections {
    param($List)
    # every hashed id we know: from both libraries' id maps and from the collections already saved
    $back = @{}
    foreach ($tab in 'movies', 'tv') {
        $m = Join-Path (Split-Path (Get-SnapshotFile $tab)) ('idmap-' + $tab + '.json')
        if (Test-Path -LiteralPath $m) { try { foreach ($pr in ([IO.File]::ReadAllText($m) | ConvertFrom-Json).PSObject.Properties) { $back[$pr.Name] = [string]$pr.Value } } catch { Write-HostLog 'idmap' $_ } }
    }
    foreach ($c in (Read-HostCollections)) { foreach ($it in @($c.Items)) { foreach ($id in @($it.Ids)) { $id = [string]$id; if ($id.StartsWith('f:')) { $back[(ConvertTo-PageId $id)] = $id } } } }
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    $out = New-Object System.Collections.Generic.List[object]
    $names = @{}
    foreach ($c in @($List)) {
        $name = ([string]$c.name).Trim()
        # the same name may exist once per list (a Movies "Favourites" and a TV "Favourites")
        $nk = ([string]$c.tab) + '|' + $name.ToLowerInvariant()
        if (-not $name -or $name.Length -gt 80 -or $names.ContainsKey($nk)) { continue }
        $names[$nk] = $true
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($it in @($c.items)) {
            $ids = @(foreach ($id in @($it.ids)) { $id = [string]$id; if ($id.StartsWith('h:')) { if ($back.ContainsKey($id)) { $back[$id] } } elseif ($id -match '^(p|s):') { $id } })
            if ($ids.Count -gt 0) { $items.Add([ordered]@{ Ids = $ids; Title = [string]$it.title; Year = [int]$it.year }) }
        }
        # Tab: which list it belongs to (Movies or TV Shows); empty for collections made before lists were separate
        $out.Add([ordered]@{ Name = $name; Tab = $(if (@('movies', 'tv') -contains [string]$c.tab) { [string]$c.tab } else { '' }); Type = $(if ([string]$c.type -eq 'rule') { 'rule' } else { 'manual' }); Items = $items.ToArray(); Query = [string]$c.query
            SortBy = [string]$c.sortBy; SortDesc = [bool]$c.sortDesc; ByDate = [bool]$c.byDate; Limit = [int]$c.limit
            Created = $(if ($c.created) { [string]$c.created } else { $now }); Modified = $now })
    }
    $p = Join-Path $script:AppData 'collections.json'
    [IO.File]::WriteAllText($p + '.tmp', (ConvertTo-Json -InputObject @{ Version = 1; Collections = $out.ToArray() } -Depth 6), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath ($p + '.tmp') -Destination $p -Force
}

# ---------------------------------------------------------------- page helpers
$script:AllowedLinkHosts = @('imdb.com', 'themoviedb.org', 'rottentomatoes.com', 'metacritic.com', 'github.com', 'plex.tv', 'youtube.com')
function Open-HostUrl {
    # Opens a link in the default browser: https only, and only to the sites the page links to.
    param([string]$Url)
    $u = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u) -or $u.Scheme -ne 'https') { throw 'Only https links can be opened.' }
    $hostName = $u.Host.ToLowerInvariant()
    $ok = $false; foreach ($d in $script:AllowedLinkHosts) { if ($hostName -eq $d -or $hostName.EndsWith('.' + $d)) { $ok = $true } }
    if (-not $ok) { throw ('Links to ' + $hostName + ' are not opened from here.') }
    Start-Process $u.AbsoluteUri
}
function Save-HostPicture {
    # "Save as picture": the page sends a PNG (base64, under 15 MB); it goes to Pictures\Modern Media Library Manager.
    param([string]$Name, [string]$Base64)
    if ($Base64.Length -gt 20MB) { throw 'The picture is too large.' }
    $bytes = [Convert]::FromBase64String($Base64)
    if ($bytes.Length -lt 8 -or $bytes[0] -ne 0x89 -or $bytes[1] -ne 0x50) { throw 'That is not a PNG picture.' }
    $safe = ($Name -replace '[^A-Za-z0-9 ._()-]', '').Trim()
    if (-not $safe) { $safe = 'card' }
    if ($safe.Length -gt 80) { $safe = $safe.Substring(0, 80) }
    $pics = [Environment]::GetFolderPath('MyPictures'); if (-not $pics) { $pics = Join-Path $script:AppData 'Pictures' }
    $dir = Join-Path $pics 'Modern Media Library Manager'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir ($safe + '.png'); $i = 2
    while (Test-Path -LiteralPath $path) { $path = Join-Path $dir ('{0} ({1}).png' -f $safe, $i); $i++ }
    [IO.File]::WriteAllBytes($path, $bytes)
    $path
}

# ---------------------------------------------------------------- contract
function Initialize-Dash {
    <# Takes the host lock, reads the version and makes folders. Fetches nothing. #>
    param([Parameter(Mandatory)]$Context)
    if ($script:Ctx) { return @{ Ok = $true; Reason = ''; CacheDir = $script:CacheDir; WebViewDataDir = $script:WebViewDataDir } }
    $created = $false
    # Local\ = one lock per Windows session. Windows frees it if the process dies. Release it from the same thread (Stop-Dash).
    try { $m = New-Object System.Threading.Mutex($true, ('Local\DashHost-' + $script:DashId), [ref]$created) } catch { Write-HostLog 'lock' $_; $m = $null }
    if (-not $m -or -not $created) {
        if ($m) { $m.Dispose() }
        return @{ Ok = $false; Reason = 'locked'; CacheDir = ''; WebViewDataDir = '' }
    }
    $script:Mutex = $m
    $script:Ctx = $Context
    if ($Context.Root) { $script:Root = [string]$Context.Root }
    try { $script:Version = ([IO.File]::ReadAllText((Join-Path $script:Root 'VERSION'))).Trim() } catch { Write-HostLog 'version' $_ }
    $script:CacheDir = Join-Path $script:AppData 'Dashboard'          # served as https://mmlm.cache/ (pages, posters for the page)
    $script:WebViewDataDir = Join-Path $script:AppData 'WebView2Page'      # its own browser profile (the window app uses WebView2Data)
    foreach ($d in @($script:AppData, $script:CacheDir, $script:WebViewDataDir)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
    $script:Traffic = [hashtable]::Synchronized(@{ Requests = 0; Bytes = [long]0; Errors = 0; Halted = $false })
    $script:Out = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $script:Fields = Get-HostFields
    $v = @{ AppRoot = $script:Root; AppData = $script:AppData; AppVersion = $script:Version; Traffic = $script:Traffic; Fields = $script:Fields }
    Set-MmlmContext -Values $v; Set-MmlmServerContext -Values $v; Set-MmlmFetchContext -Values $v
    $script:Badge = 0
    $script:Started = Get-Date
    $script:Exports = @{}
    $script:PageSettings = Read-PageSettings
    $script:UpdDir = Join-Path $script:AppData 'Update'
    $script:UpdOut = Join-Path $script:UpdDir 'update.out'
    $script:UpdProc = $null; $script:UpdateAvailable = $null; $script:LastUpdJson = ''
    $script:DropSeen = @{}; $script:DropAsked = @{}; $script:DropLook = [datetime]::MinValue
    # After an update Apply-Update.ps1 leaves a "pending" note: report it once; the page loading confirms the new version works.
    $script:UpdateNote = $null
    $pend = Read-UpdateJson 'update-pending.json'
    if ($pend -and [string]$pend.to -eq $script:Version) { $script:UpdateNote = @{ ok = $true; from = [string]$pend.from; to = [string]$pend.to } }
    $failed = Read-UpdateJson 'update-failed.json'
    if ($failed) {
        $script:UpdateNote = @{ ok = $false; from = [string]$failed.from; to = [string]$failed.to; reason = [string]$failed.reason }
        Remove-Item -LiteralPath (Join-Path $script:UpdDir 'update-failed.json'), (Join-Path $script:UpdDir 'update-pending.json') -Force -ErrorAction SilentlyContinue
    }
    return @{ Ok = $true; Reason = ''; CacheDir = $script:CacheDir; WebViewDataDir = $script:WebViewDataDir }
}

function Get-HostFields {
    # The record field list, read from the main script's field table so the two never drift apart.
    $main = Join-Path $script:Root ($script:AppName + '.ps1')
    $errs = $null; $tok = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($main, [ref]$tok, [ref]$errs)
    $a = $ast.Find({ param($x) $x -is [Management.Automation.Language.AssignmentStatementAst] -and $x.Left.Extent.Text -eq '$script:FieldDefs' }, $true)
    if ($null -eq $a) { return @() }
    $defs = & ([scriptblock]::Create($a.Right.Extent.Text))
    foreach ($line in $defs) {
        $p = $line -split '\|'
        [pscustomobject]@{ Name = $p[0]; Type = $p[1]; Group = $p[2]; Show = [bool][int]$p[3] }
    }
}

function Start-DashWorker {
    <# Tab visible. Nothing runs on a timer here; the person has now seen what was new. #>
    $script:Visible = $true
    $script:Badge = 0
}

function Suspend-DashWorker {
    <# Tab hidden. No timed fetching exists to stop; a scan the person started keeps running. #>
    $script:Visible = $false
}

# Compare: the two main colours of a cached poster (for the "poster colours" border and Auto). Reads the local file
# only; the page cannot read a poster's pixels itself because the cache is another origin.
function Get-PosterColours {
    param([string]$Url)
    $rel = [string]$Url -replace '^https://mmlm\.cache/', ''
    if (-not $rel -or $rel -match '\.\.' -or $rel -match '^[a-z]+:' ) { throw 'Not a cached poster' }
    $path = Join-Path $script:CacheDir ($rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $path)) { throw 'Poster not found' }
    Add-Type -AssemblyName System.Drawing
    $src = $null; $bmp = $null; $g = $null
    try {
        $src = [Drawing.Image]::FromFile($path)
        $bmp = New-Object Drawing.Bitmap 24, 36
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.DrawImage($src, 0, 0, 24, 36)
        $bins = @{}
        for ($y = 0; $y -lt 36; $y++) { for ($x = 0; $x -lt 24; $x++) {
            $c = $bmp.GetPixel($x, $y); $sat = $c.GetSaturation(); $bri = $c.GetBrightness()
            if ($bri -lt 0.12 -or $bri -gt 0.92) { continue }
            $w = $sat * (1 - [Math]::Abs($bri - 0.5)); if ($w -le 0.05) { continue }
            $k = [int]([Math]::Floor($c.GetHue() / 20))
            if (-not $bins.ContainsKey($k)) { $bins[$k] = @{ w = 0.0; r = 0.0; g = 0.0; b = 0.0 } }
            $o = $bins[$k]; $o.w += $w; $o.r += $c.R * $w; $o.g += $c.G * $w; $o.b += $c.B * $w
        } }
        $top = @($bins.Values | Sort-Object { $_.w } -Descending | Select-Object -First 2)
        $hex = @($top | ForEach-Object { '#{0:x2}{1:x2}{2:x2}' -f [int]($_.r / $_.w), [int]($_.g / $_.w), [int]($_.b / $_.w) })
        ConvertTo-PageJson ([ordered]@{ colours = $hex })
    } finally { if ($g) { $g.Dispose() }; if ($bmp) { $bmp.Dispose() }; if ($src) { $src.Dispose() } }
}

# Page commands: name -> handler. Fetch = $true means it reaches Plex or the internet, so it is refused while traffic is paused.
$script:Commands = [ordered]@{
    'init'           = @{ Fetch = $false; Run = {
            param($a)
            $note = $script:UpdateNote
            if ($note -and $note.ok) {
                # the page loaded: tell Apply-Update.ps1 the new version works
                try { [IO.File]::WriteAllText((Join-Path $script:UpdDir 'update-ok.json'), '{"ok":true}') } catch { Write-HostLog 'update ok' $_ }
                Remove-Item -LiteralPath (Join-Path $script:UpdDir 'update-pending.json') -Force -ErrorAction SilentlyContinue
            }
            $script:UpdateNote = $null
            ConvertTo-PageJson @{ version = $script:Version; movies = (Get-SnapshotCount 'movies'); tv = (Get-SnapshotCount 'tv'); halted = [bool]$script:Traffic.Halted
                scanning = [bool]($script:Sync -and $script:ScanPs -and -not $script:Sync.Done); scanTab = $script:ScanTab; mode = [string]$script:Ctx.Mode; theme = [string]$script:Ctx.Theme
                settings = $script:PageSettings; plex = (Get-PlexInfo); updateNote = $note; debug = [bool]$script:Ctx.Debug } } }
    'library.get'    = @{ Fetch = $false; Run = {
            # the page's copy of a tab: sent when ready; otherwise built from the snapshot in the background ('library' event)
            param($a)
            $tab = $(if ([string]$a.tab -eq 'tv') { 'tv' } else { 'movies' })
            Update-OldArtwork
            switch (Get-LibraryState $tab) {
                'ready' { [IO.File]::ReadAllText((Join-Path $script:CacheDir ('library-' + $tab + '.json'))) }
                'empty' { '{"empty":true}' }
                default { Start-HostExport $tab; '{"pending":true}' }
            } } }
    'poster.colours' = @{ Fetch = $false; Run = { param($a) Get-PosterColours ([string]$a.url) } }
    'settings.set'   = @{ Fetch = $false; Run = { param($a) Set-PageSetting ([string]$a.key) $a.value; ConvertTo-PageJson $script:PageSettings } }
    'plex.set'       = @{ Fetch = $false; Run = {
            # Plex address and token (the token is stored encrypted for this Windows user, as the window app does)
            param($a)
            $url = ([string]$a.url).Trim().TrimEnd('/')
            if ($url -and $url -notmatch '^https?://[^\s/]+(:\d+)?$') { throw 'The Plex address looks like http://server:32400' }
            $tok = ([string]$a.token).Trim()
            if ($tok) { Save-HostPlexSettings -Url $url -TokenProtected (Protect-MmlmSecret $tok) } else { Save-HostPlexSettings -Url $url -KeepToken }
            ConvertTo-PageJson (Get-PlexInfo) } }
    'jellyfin.set'   = @{ Fetch = $false; Run = {
            # Jellyfin address and API key (the key is stored encrypted for this Windows user, like the Plex token)
            param($a)
            $url = ([string]$a.url).Trim().TrimEnd('/')
            if ($url -and $url -notmatch '^https?://[^\s/]+(:\d+)?(/[^\s]*)?$') { throw 'The Jellyfin address looks like http://server:8096' }
            $v = @{ JellyfinUrl = $url }
            $key = ([string]$a.key).Trim()
            if ($key) { $v.JellyfinKeyProtected = Protect-MmlmSecret $key }
            Save-HostServerSettings $v
            ConvertTo-PageJson (Get-PlexInfo) } }
    'server.use'     = @{ Fetch = $false; Run = {
            # which server a library comes from. The next scan of that library reads everything from the new server.
            param($a)
            $tab = $(if ([string]$a.tab -eq 'tv') { 'tv' } else { 'movies' })
            $kind = [string]$a.kind
            if (@(Get-MmlmServerKinds) -notcontains $kind) { throw 'Unknown server.' }
            Save-HostServerSettings @{ ($(if ($tab -eq 'tv') { 'TvServer' } else { 'MoviesServer' })) = $kind }
            ConvertTo-PageJson (Get-PlexInfo) } }
    'server.test'    = @{ Fetch = $true; Run = {
            # Settings > Servers > Test: asks the server for its name and libraries in the background (counted as
            # traffic); the answer comes as a 'servertest' event
            param($a)
            Start-HostServerTest -Kind ([string]$a.kind); 'true' } }
    'series.open'    = @{ Fetch = $false; Run = {
            # the saved copy when there is one (no network); otherwise a Plex fetch starts and 'series' events follow
            param($a)
            $r = Start-HostSeries -Show ([string]$a.show) -EpKey ([string]$a.ep) -Refresh ([bool]$a.refresh)
            if ($r -eq 'loading') { '{"loading":true}' } else { $r } } }
    'shows.status'   = @{ Fetch = $false; Run = {
            # show name -> { state: Ongoing|Ended, tmdb, lastAir }, saved by TV Shows > Fetch info (no network here)
            $p = Join-Path $script:AppData 'Library\show-status.json'
            if (Test-Path -LiteralPath $p) { [IO.File]::ReadAllText($p) } else { '{}' } } }
    'doctor.status'  = @{ Fetch = $false; Run = { Get-DoctorStatus } }
    'doctor.run'     = @{ Fetch = $false; Run = { [void](Start-HostDoctor -Manual); 'true' } }
    'doctor.report'  = @{ Fetch = $false; Run = {
            # the latest report (no network); reading it marks the issue alert as seen
            $f = Get-LatestDoctorReport
            $st = Read-DoctorState; if ($st.unseen) { $st.unseen = $false; Save-DoctorState $st }
            if ($f) { [IO.File]::ReadAllText($f) } else { 'null' } } }
    'doctor.seen'    = @{ Fetch = $false; Run = { $st = Read-DoctorState; $st.unseen = $false; Save-DoctorState $st; 'true' } }
    'image.data'     = @{ Fetch = $false; Run = {
            # a cached picture as a data: URL, so the page can read its colours (series view background)
            param($a)
            $rel = ([string]$a.path) -replace '/', '\'
            if ($rel -notmatch '^(series\\img|thumbs|art)\\[A-Za-z0-9._-]+\.(jpg|png)$') { throw 'Not a cached picture.' }
            $f = Join-Path $script:CacheDir $rel
            if (-not (Test-Path -LiteralPath $f) -or (Get-Item -LiteralPath $f).Length -gt 2MB) { return 'null' }
            ConvertTo-PageJson ('data:image/jpeg;base64,' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($f))) } }
    'tools.start'    = @{ Fetch = $false; Run = { param($a) ConvertTo-PageJson (Start-HostTool $a) } }
    'tools.cancel'   = @{ Fetch = $false; Run = { param($a) if ($script:Tool) { $script:Tool.Sync.Cancel = $true }; 'true' } }
    'keys.get'       = @{ Fetch = $false; Run = { param($a) $k = Read-HostKeys; ConvertTo-PageJson @{ tmdb = [bool]$k.Tmdb; omdb = [bool]$k.Omdb } } }
    'keys.set'       = @{ Fetch = $false; Run = {
            param($a)
            $t = $(if ($null -ne $a.tmdb) { ([string]$a.tmdb).Trim() } else { $null }); $o = $(if ($null -ne $a.omdb) { ([string]$a.omdb).Trim() } else { $null })
            Save-HostKeys -Tmdb $t -Omdb $o
            $k = Read-HostKeys; ConvertTo-PageJson @{ tmdb = [bool]$k.Tmdb; omdb = [bool]$k.Omdb } } }
    'folder.show'    = @{ Fetch = $false; Run = { param($a) Show-HostExport ([string]$a.path); 'true' } }
    'dashboards.get' = @{ Fetch = $false; Run = {
            # your own dashboards (charts you built), per tab: AppData\dashboards.json
            param($a)
            $p = Join-Path $script:AppData 'dashboards.json'
            if (Test-Path -LiteralPath $p) { [IO.File]::ReadAllText($p) } else { '{"movies":[],"tv":[]}' } } }
    'dashboards.save' = @{ Fetch = $false; Run = {
            param($a)
            $json = ConvertTo-Json -InputObject ([ordered]@{ movies = @($a.data.movies); tv = @($a.data.tv) }) -Depth 8 -Compress
            if ($json.Length -gt 500KB) { throw 'That is too many charts to save.' }
            $p = Join-Path $script:AppData 'dashboards.json'
            [IO.File]::WriteAllText($p + '.tmp', $json, (New-Object Text.UTF8Encoding($false)))
            Move-Item -LiteralPath ($p + '.tmp') -Destination $p -Force
            $json } }
    'collections.get' = @{ Fetch = $false; Run = { param($a) ConvertTo-Json -InputObject (Get-PageCollections) -Depth 6 -Compress } }
    'collections.save' = @{ Fetch = $false; Run = { param($a) Save-PageCollections $a.collections; ConvertTo-Json -InputObject (Get-PageCollections) -Depth 6 -Compress } }
    'open.url'       = @{ Fetch = $false; Run = { param($a) Open-HostUrl ([string]$a.url); 'true' } }
    'picture.save'   = @{ Fetch = $false; Run = { param($a) ConvertTo-PageJson (Save-HostPicture ([string]$a.name) ([string]$a.png)) } }
    'update.check'   = @{ Fetch = $false; Run = { param($a) ConvertTo-PageJson (Start-Updater 'Check') } }
    'update.stage'   = @{ Fetch = $false; Run = { param($a) ConvertTo-PageJson (Start-Updater 'Stage') } }
    'update.stagezip' = @{ Fetch = $false; Run = {
            param($a)
            $leaf = [IO.Path]::GetFileName([string]$a.file)
            $zip = Join-Path (Join-Path $script:Root 'updates') $leaf
            if (-not $leaf -or -not (Test-Path -LiteralPath $zip)) { throw 'That file is no longer in the updates folder.' }
            ConvertTo-PageJson (Start-Updater 'StageZip' $zip) } }
    'update.cancel'  = @{ Fetch = $false; Run = { param($a) try { if ($script:UpdProc -and -not $script:UpdProc.HasExited) { $script:UpdProc.Kill() } } catch { Write-HostLog 'update cancel' $_ }; 'true' } }
    'update.apply'   = @{ Fetch = $false; Run = {
            param($a)
            Invoke-UpdateApply
            $close = $script:Ctx.Close
            if ($close) { & $close }
            'true' } }
    'scan.start'     = @{ Fetch = $true; Run = {
            param($a)
            $tab = [string]$a.tab
            if ($tab -ne 'movies' -and $tab -ne 'tv') { throw "scan.start: tab must be 'movies' or 'tv'." }
            Start-HostScan -Tab $tab -Rebuild ([bool]$a.rebuild); 'true' } }
    'scan.cancel'    = @{ Fetch = $false; Run = { param($a) Stop-HostScan -Wait 0; 'true' } }
    'summary.get'    = @{ Fetch = $false; Run = {
            # answered from the cache file the last scan wrote: no network, no scanning
            param($a)
            $tab = $(if ([string]$a.tab -eq 'tv') { 'tv' } else { 'movies' })
            $p = Join-Path $script:CacheDir ('summary-' + $tab + '.json')
            if (Test-Path -LiteralPath $p) { [IO.File]::ReadAllText($p) } else { ConvertTo-PageJson @{ title = 'Recently added'; items = @(); updatedAt = $null } } } }
    'traffic.get'    = @{ Fetch = $false; Run = { param($a) ConvertTo-PageJson @{ requests = [int]$script:Traffic.Requests; bytes = [long]$script:Traffic.Bytes; errors = [int]$script:Traffic.Errors; stopped = [bool]$script:Traffic.Halted; uptimeSec = [int]((Get-Date) - $script:Started).TotalSeconds } } }
    'traffic.stop'   = @{ Fetch = $false; Run = { param($a) Stop-DashTraffic; 'true' } }
    'traffic.resume' = @{ Fetch = $false; Run = { param($a) $script:Traffic.Halted = $false; Send-HostEventNow 'traffic' @{ stopped = $false }; 'true' } }
}

function Invoke-DashCommand {
    param([Parameter(Mandatory)]$Message)
    $id = $Message.id
    $name = [string]$Message.cmd
    try {
        $c = $script:Commands[$name]
        if ($null -eq $c) { ReplyError $id ('unknown command: ' + $name); return }
        if ($c.Fetch -and $script:Traffic.Halted) { ReplyError $id 'Traffic is paused. Resume it first.'; return }
        Reply $id ([string](& $c.Run $Message.args))
    }
    catch { Write-HostLog ('command ' + $name) $_; ReplyError $id $_.Exception.Message }
}

function Receive-DashEvents {
    <# Every 250 ms: scan progress and the end of a scan, at most 25 messages. #>
    if (-not $script:Out) { return @() }
    $out = New-Object System.Collections.Generic.List[string]
    $s = $script:Sync
    if ($s -and $script:ScanPs) {
        if ($s.Done) {
            $data = @{ running = $false; tab = $script:ScanTab; count = [int]$s.Count; new = [int]$s.New; cancelled = [bool]($s.Cancelled -or $s.Cancel); error = $s.Error }
            if (-not $data.cancelled -and -not $s.Error -and -not $script:Visible) { $script:Badge += [int]$s.New }
            Push-HostEvent 'scan' $data
            $script:LastScanResult = @{ Tab = $script:ScanTab; Error = $s.Error; Cancelled = $data.cancelled }
            if (-not $data.cancelled -and -not $s.Error) { Push-HostEvent 'library' @{ tab = $script:ScanTab; ready = $true; error = $null } }
            Stop-HostScan
        }
        else {
            $json = ConvertTo-PageJson ([ordered]@{ event = 'scan'; data = @{ running = $true; tab = $script:ScanTab; pct = (Get-ScanPct); text = [string]$s.Text } })
            if ($json -ne $script:LastScanJson) { $script:LastScanJson = $json; $script:Out.Enqueue($json) }
        }
    }
    foreach ($tab in @($script:Exports.Keys)) {
        $x = $script:Exports[$tab]
        if (-not $x.Sync.Done) { continue }
        $script:Exports.Remove($tab)
        try { $x.Ps.Dispose() } catch { Write-HostLog 'export dispose' $_ }
        Push-HostEvent 'library' @{ tab = $tab; ready = (-not $x.Sync.Error); error = $x.Sync.Error }
    }
    try { Get-UpdateEvents; Watch-DropFolder } catch { Write-HostLog 'updates' $_ }
    try { Step-HostDoctor } catch { Write-HostLog 'doctor' $_; $script:Doctor = $null }
    try { Get-ServerTestEvents } catch { Write-HostLog 'server test' $_; $script:ServerTest = $null }
    try { Get-SeriesEvents } catch { Write-HostLog 'series' $_ }
    try { Get-ToolEvents } catch { Write-HostLog 'tools' $_ }
    # one drain for every event source; whatever is over the cap waits for the next call (callers wrap the result in @())
    try {
        $msg = $null
        while ($out.Count -lt 25 -and $script:Out.TryDequeue([ref]$msg)) { $out.Add($msg) }
    } catch { Write-HostLog 'events' $_ }
    return $out.ToArray()
}

function Get-DashStatus {
    <# Every 2 seconds: no network, no disk. A library has nothing live; a scan shows as Syncing. #>
    $t = $script:Traffic
    $running = [bool]($script:Sync -and $script:ScanPs -and -not $script:Sync.Done)
    return @{
        Live            = 0
        Syncing         = $running
        SyncPct         = $(if ($running) { Get-ScanPct } else { $null })
        UpdateAvailable = $(if ($script:UpdateAvailable) { [string]$script:UpdateAvailable } else { $null })
        Error           = $(if ($script:Sync -and $script:Sync.Error) { [string]$script:Sync.Error } else { $null })
        Traffic         = @{ Requests = $(if ($t) { [int]$t.Requests } else { 0 }); Bytes = $(if ($t) { [long]$t.Bytes } else { 0 }); Errors = $(if ($t) { [int]$t.Errors } else { 0 }) }
        Badge           = @{ Count = $(if ($script:Badge -gt 0) { $script:Badge } else { $null }); Label = 'new' }      # proposed launcher field; ignored until built
    }
}

function Stop-DashTraffic {
    <# Kill switch: cancel the running scan (Plex, online lookups, local disks), let nothing new start. Settings are not changed.
       Only traffic.resume from inside the app starts it again. GitHub update checks are not affected. #>
    if (-not $script:Traffic) { return }
    $script:Traffic.Halted = $true
    Stop-HostScan -Wait 0
    if ($script:Series -and $script:Series.Sync) { $script:Series.Sync.Cancel = $true }
    if ($script:Tool -and @('fetch', 'fel') -contains $script:Tool.Kind) { $script:Tool.Sync.Cancel = $true }
    Send-HostEventNow 'traffic' @{ stopped = $true }
}

function Stop-Dash {
    <# Closing: cancel a scan (the last saved snapshot stays as it was) and release the host lock within 2 seconds. #>
    try { Stop-HostScan -Wait 1500 } catch { Write-HostLog 'close scan' $_ }
    # ReleaseMutex throws if called from another thread than Initialize-Dash; Dispose runs regardless, so the handle never leaks
    if ($script:Mutex) {
        try { $script:Mutex.ReleaseMutex() } catch { Write-HostLog 'lock release' $_ }
        finally { try { $script:Mutex.Dispose() } catch { Write-HostLog 'lock dispose' $_ } }
    }
    foreach ($x in @($script:Exports.Values)) { try { $x.Sync.Cancel = $true; $x.Ps.Dispose() } catch { Write-HostLog 'close export' $_ } }
    $script:Exports = @{}
    $script:Mutex = $null
    $script:Ctx = $null
    $script:Out = $null
    $script:Sync = $null
}

function Invoke-DashSync {
    <# Optional (the launcher's master sync, switched off for now): a scan of the Movies library. #>
    param([ValidateSet('quick')][string]$Scope = 'quick')
    if (-not $script:Traffic -or $script:Traffic.Halted) { return $false }
    if ($script:ScanPs -and -not $script:Sync.Done) { return $false }
    try { Start-HostScan -Tab 'movies'; return $true } catch { Write-HostLog 'sync' $_; return $false }
}

Export-ModuleMember -Function Initialize-Dash, Start-DashWorker, Suspend-DashWorker, Invoke-DashCommand, Receive-DashEvents, Get-DashStatus, Stop-DashTraffic, Stop-Dash, Invoke-DashSync
