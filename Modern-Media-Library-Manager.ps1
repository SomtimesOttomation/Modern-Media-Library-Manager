<#
.SYNOPSIS
    Modern Media Library Manager - MediaInfo + NFO + artwork scanner with a dark WinForms UI and an
    interactive HTML dashboard.

.DESCRIPTION
    - Scans a folder (recursively) for video/audio files.
    - Reads technical metadata with MediaInfo, descriptive metadata from Kodi/Plex-style .nfo files,
      and finds poster artwork sitting next to each file.
    - Caches every record on disk so re-scans are fast (tick "Rebuild cache" to force a re-read).
    - Shows results in a sortable grid or a per-title detail view (with poster).
    - "Dashboard" builds an HTML report (KPIs, charts, poster wall) from the scan and shows it inside
      the window using the Edge WebView2 control (falls back to your default browser if unavailable).
    - "Save HTML" writes the dashboard to a file you choose (tick "Embed posters" for a single portable file).
    - "Export CSV" dumps every field for pivoting in Excel / Power BI.
    - Every scan collects ALL fields. Hiding a column only affects the grid; your column choices, folder and
      options are remembered in %LOCALAPPDATA%\Modern-Media-Library-Manager\settings.json.

    Folder layout (keep these together):
        Modern-Media-Library-Manager.ps1  this script
        dashboard-template.html    dashboard page the script fills with your data
        lib\                       WebView2 DLLs - created automatically on first use of the Dashboard view
                                   (or copy Microsoft.Web.WebView2.Core.dll, ...WinForms.dll and WebView2Loader.dll in yourself)
        Run-ModernMediaLibraryManager.cmd  optional double-click launcher

    Adding a metadata field = add one line to $script:FieldDefs below, then one assignment in
    Get-MediaInfoRecord. The grid, detail view, CSV and dashboard JSON pick it up automatically.

.NOTES
    Requires Windows PowerShell 5.1+ and the "Get-MediaInfo" module (auto-installed on first run).
    NOTE: this file is intentionally ASCII-only so Windows PowerShell 5.1 reads it correctly.
#>

#requires -Version 5.1

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Data
[System.Windows.Forms.Application]::EnableVisualStyles()

#region ---------------------------------------------------------------- Configuration
$script:AppRoot         = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:TemplatePath    = Join-Path $script:AppRoot 'dashboard-template.html'
$script:CacheVersion    = 4          # bump when the record schema changes
$script:AppData         = Join-Path $env:LOCALAPPDATA 'Modern-Media-Library-Manager'
$script:CacheFolder     = Join-Path $script:AppData 'Cache'
$script:ThumbFolder     = Join-Path $script:AppData 'Thumbs'
$script:LibFolder       = Join-Path $script:AppRoot 'lib'                          # WebView2 DLLs live here (auto-downloaded)
$script:SettingsPath    = Join-Path $script:AppData 'settings.json'
$script:MetaStorePath   = Join-Path $script:AppData 'metadata\store.json'      # fetched + hand-typed values
$script:DataFolder      = Join-Path $script:AppData 'datasets'                 # IMDb ratings file
$script:InformFolder     = Join-Path $script:AppData 'Inform'                       # full MediaInfo text per file (source-clue research)
$script:LiveFolder      = Join-Path $script:AppData 'Dashboard'                    # dashboard shown inside the app
$script:LiveDashboard   = Join-Path $script:LiveFolder 'index.html'
$script:Culture         = [Globalization.CultureInfo]::InvariantCulture

# runtime state
$script:DashboardStale  = $true      # set after every scan so the dashboard is rebuilt on demand
$script:DashboardUrl    = ''
$script:CurrentView     = 'grid'
$script:WebView2Ready   = $false
$script:WebView2Failed  = $false
$script:WebView2Error   = ''
$script:WebView2Notified = $false
$script:wv              = $null

$script:VideoExtensions = @('264','265','asf','avc','avi','divx','flv','h264','h265','hevc','m2ts','m2v','m4v','mkv','mov','mp4','mpeg','mpg','mpv','mts','ts','vob','webm','wmv')
$script:AudioExtensions = @('aac','ac3','dts','dtshd','dtshr','dtsma','eac3','flac','m4a','mka','mp2','mp3','mpa','ogg','opus','thd','w64','wav')
$script:PosterNames     = @('poster','folder','cover','movie','thumb')     # besides "<filename>-poster"
$script:ImageExtensions = @('jpg','jpeg','png','bmp')

foreach ($dir in @($script:CacheFolder, $script:ThumbFolder, $script:LiveFolder)) {
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
}

# Single source of truth for the record layout:  Name | Type | Group | ShownInGridByDefault
$script:FieldDefs = @(
    'Title|string|Overview|1',         'Library|string|Overview|1',        'Show|string|Overview|1',
    'Season|int|Overview|0',           'Episode|int|Overview|0',
    'Year|int|Overview|1',             'Genre|string|Overview|1',
    'MPAARating|string|Overview|1',    'Rating|double|Overview|1',         'Votes|int|Overview|0',
    'RuntimeMin|double|Overview|1',    'Studio|string|Overview|1',         'Director|string|Overview|0',
    'Cast|string|Overview|0',          'Collection|string|Overview|0',     'Country|string|Overview|0',
    'Tagline|string|Overview|0',       'Plot|string|Overview|0',           'ReleaseDate|string|Overview|0',
    'IMDBID|string|Overview|0',        'TMDBID|string|Overview|0',

    'Resolution|string|Video|0',       'ResolutionClass|string|Video|1',   'Width|int|Video|0',
    'Height|int|Video|0',              'DAR|double|Video|0',               'VideoCodec|string|Video|1',
    'FormatProfile|string|Video|0',    'VideoCodecID|string|Video|0',      'VideoBitRateMbps|double|Video|1',
    'BitsPerPixel|double|Video|0',     'FrameRate|double|Video|1',         'FrameRateMode|string|Video|0',
    'ScanType|string|Video|0',         'BitDepth|int|Video|1',             'ChromaSubsampling|string|Video|0',
    'ColorRange|string|Video|0',       'Encoder|string|Video|0',

    'HDRType|string|HDR|1',            'HDRStack|string|HDR|0',            'DVProfile|string|HDR|1',
    'DVLayer|string|HDR|1',            'DVBase|string|HDR|0',              'HasHDR10Plus|bool|HDR|0',
    'HDRFormat|string|HDR|0',
    'HDRFormatProfile|string|HDR|0',   'HDRFormatLevel|string|HDR|0',      'HDRFormatSettings|string|HDR|0',
    'HDRFormatCompat|string|HDR|0',    'MaxCLL|string|HDR|0',              'MaxFALL|string|HDR|0',
    'MasteringDisplay|string|HDR|0',   'Primaries|string|HDR|0',           'Transfer|string|HDR|0',
    'Matrix|string|HDR|0',

    'AudioFormat|string|Audio|1',      'ObjectAudio|string|Audio|1',       'AudioTitle|string|Audio|0',
    'AudioCompression|string|Audio|0', 'AudioBitRateMode|string|Audio|0',  'AudioBitRateKbps|int|Audio|0',
    'AudioChannels|int|Audio|0',       'AudioLayout|string|Audio|1',       'AudioSamplingRate|string|Audio|0',
    'AudioBitDepth|string|Audio|0',    'AudioLanguages|string|Audio|1',    'AudioTracks|int|Audio|0',

    'SubtitleTracks|int|Subtitles|1',  'SubtitleLanguages|string|Subtitles|0', 'SubtitleFormats|string|Subtitles|0',

    'FileName|string|File|1',          'Container|string|File|1',          'Ext|string|File|0',
    'Type|string|File|0',              'FileSizeGB|double|File|1',         'OverallBitRateMbps|double|File|0',
    'Source|string|File|1',            'Added|string|File|1',              'Modified|string|File|0',
    'Directory|string|File|0',         'FullPath|string|File|0',

    'HasNfo|bool|Library|0',           'HasPoster|bool|Library|0',         'PosterPath|string|Library|0',
    'ViewCount|int|Library|0',         'LastViewed|string|Library|0',      'PlexKey|string|Library|0',
    'PlexThumb|string|Library|0',       'MetaSources|string|Library|0',

    # Scores and money (filled by Fetch info or typed by hand; whole US dollars)
    'RTCritic|int|Ratings|1',          'RTAudience|int|Ratings|1',         'CinemaScore|string|Ratings|1',
    'BoxOfficeDomestic|double|Box office|1', 'BoxOfficeWorldwide|double|Box office|1',
    'OpeningDomestic|double|Box office|0',   'OpeningWorldwide|double|Box office|0',

    # Source clues: where did this file come from? (filled by the local MediaInfo scan; hidden by default)
    'WritingApp|string|Clues|0',       'WritingLib|string|Clues|0',        'EmbeddedTitle|string|Clues|0',
    'EmbeddedComment|string|Clues|0',  'OriginalMedia|string|Clues|0',     'EncodedDate|string|Clues|0',
    'Chapters|int|Clues|0',            'VideoTitle|string|Clues|0',        'VideoEncLib|string|Clues|0',
    'VideoEncSettings|string|Clues|0', 'AudioTrackList|string|Clues|0',    'AudioFormatList|string|Clues|0',
    'InformFile|string|Clues|0'
)

$script:Fields = foreach ($line in $script:FieldDefs) {
    $p = $line -split '\|'
    [pscustomobject]@{ Name = $p[0]; Type = $p[1]; Group = $p[2]; Show = ($p[3] -eq '1') }
}
$script:ClueNames = @($script:Fields | Where-Object { $_.Group -eq 'Clues' } | ForEach-Object { $_.Name })
$script:TypeMap = @{ string = [string]; int = [int]; long = [long]; double = [double]; bool = [bool] }
#endregion

#region ---------------------------------------------------------------- Small helpers
function ConvertTo-SafeInt {
    param($Value)
    $r = 0
    if ([int]::TryParse([string]$Value, [Globalization.NumberStyles]::Any, $script:Culture, [ref]$r)) { $r } else { 0 }
}
function ConvertTo-SafeDouble {
    param($Value)
    $r = 0.0
    if ([double]::TryParse([string]$Value, [Globalization.NumberStyles]::Any, $script:Culture, [ref]$r)) { $r } else { 0.0 }
}

function Join-UniqueList {
    # "English / English / French" (one entry per track) -> "English; French"
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $parts = @($Text -split '\s*/\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    $parts -join '; '
}

function Get-StringHash {
    param([Parameter(Mandatory)][string]$Text)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try   { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function New-EmptyRecord {
    $rec = [ordered]@{}
    foreach ($f in $script:Fields) {
        $rec[$f.Name] = switch ($f.Type) {
            'string' { '' }
            'int'    { 0 }
            'long'   { [long]0 }
            'double' { 0.0 }
            'bool'   { $false }
        }
    }
    $rec
}

function Get-ResolutionClass {
    param([int]$Width, [int]$Height)
    if ($Width -le 0 -and $Height -le 0) { return 'Unknown' }
    if     ($Width -ge 3400 -or $Height -ge 2000) { '4K' }
    elseif ($Width -ge 2400 -or $Height -ge 1300) { '1440p' }
    elseif ($Width -ge 1800 -or $Height -ge 1000) { '1080p' }
    elseif ($Width -ge 1200 -or $Height -ge 700)  { '720p' }
    else                                          { 'SD' }
}

function Get-HdrType {
    param([string]$HdrFormat, [string]$Compat, [string]$Transfer)
    if ($HdrFormat -match 'Dolby Vision')                                   { return 'Dolby Vision' }
    if ($HdrFormat -match 'SMPTE ST 2094|HDR10\+' -or $Compat -match 'HDR10\+') { return 'HDR10+' }
    if ($HdrFormat -match 'SMPTE ST 2086|HDR10'   -or $Compat -match 'HDR10')   { return 'HDR10' }
    if ($Transfer  -match 'HLG|ARIB STD-B67')                               { return 'HLG' }
    if ($Transfer  -match 'PQ|SMPTE ST 2084')                               { return 'HDR10' }
    'SDR'
}

function Get-DolbyVisionInfo {
    # Works out the Dolby Vision profile (5, 7, 8.1, 8.2, 8.4 ...), single vs dual layer and the base-layer
    # compatibility from the several MediaInfo fields that describe it. MediaInfo cannot tell FEL from MEL -
    # a dual-layer file is reported as 'Dual layer' until the optional dovi_tool probe has looked at it.
    param([string]$Format, [string]$ProfileRaw, [string]$Settings, [string]$Compat, [string]$InfoString)

    $r = [pscustomobject]@{ Profile = ''; Layer = ''; Base = '' }
    if ($Format -notmatch 'Dolby Vision') { return $r }

    $num = 0; $sub = 0
    if ($ProfileRaw -match 'dv(?:he|h1|av1|a1)\.0*(\d+)') { $num = [int]$Matches[1] }
    if ($InfoString -match 'Profile\s+(\d+)(?:\.(\d))?') {
        if ($num -eq 0) { $num = [int]$Matches[1] }
        if ($Matches[2]) { $sub = [int]$Matches[2] }
    }

    # what a player without Dolby Vision would show (the "base layer")
    $base = 'None'
    if     ($Compat -match 'HLG')           { $base = 'HLG' }
    elseif ($Compat -match 'SDR')           { $base = 'SDR' }
    elseif ($Compat -match 'HDR10|Blu-ray') { $base = 'HDR10' }
    elseif ($sub -eq 1)                     { $base = 'HDR10' }
    elseif ($sub -eq 2)                     { $base = 'SDR' }
    elseif ($sub -eq 4)                     { $base = 'HLG' }
    if ($num -eq 5) { $base = 'None' }               # profile 5 has no backwards-compatible fallback

    $profile = ''
    if ($num -gt 0) {
        $profile = "$num"
        if ($num -in 8, 10) {
            switch ($base) {
                'HDR10' { $profile = "$num.1" }
                'SDR'   { $profile = "$num.2" }
                'HLG'   { $profile = "$num.4" }
            }
        }
    }

    $dual = ($Settings -match '\bEL\b') -or ($num -in 4, 7)
    $r.Profile = $profile
    $r.Layer   = if ($dual) { 'Dual layer' } else { 'Single layer' }
    $r.Base    = $base
    $r
}

function Get-HdrStack {
    # One readable label for the whole HDR picture, e.g. "Dolby Vision P8.1 + HDR10" or "Dolby Vision P7 FEL + HDR10".
    param([string]$HdrType, $Dv, [bool]$HasHdr10Plus)
    if ($HdrType -ne 'Dolby Vision') { return $HdrType }

    $label = 'Dolby Vision'
    if ($Dv.Profile) { $label += " P$($Dv.Profile)" }
    if     ($Dv.Layer -eq 'FEL')        { $label += ' FEL' }
    elseif ($Dv.Layer -eq 'MEL')        { $label += ' MEL' }
    elseif ($Dv.Layer -eq 'Dual layer') { $label += ' (dual layer)' }

    $fallback = @()
    if ($Dv.Base -in 'HDR10', 'HLG', 'SDR') { $fallback += $Dv.Base }
    if ($HasHdr10Plus)                      { $fallback += 'HDR10+' }
    if ($fallback.Count -gt 0) { $label += ' + ' + ($fallback -join ' + ') }
    $label
}

function Find-Tool {
    # Looks for an executable in the lib folder next to the script first, then on PATH.
    param([Parameter(Mandatory)][string]$Name)
    $local = Join-Path $script:LibFolder $Name
    if (Test-Path -LiteralPath $local) { return $local }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $null
}

function Get-DolbyVisionLayerType {
    # Optional: tells FEL from MEL by pulling ~20 seconds of video through ffmpeg and reading the Dolby Vision
    # RPU with dovi_tool. Needs ffmpeg.exe and dovi_tool.exe (lib folder or PATH). Returns 'FEL', 'MEL' or ''.
    param([Parameter(Mandatory)][string]$Path, [int]$DurationSec = 0)

    $ffmpeg = Find-Tool 'ffmpeg.exe'
    $dovi   = Find-Tool 'dovi_tool.exe'
    if (-not $ffmpeg -or -not $dovi) { return '' }

    Set-WorkerStage 'FEL probe: waiting for a free slot' 0 4
    $work = Join-Path ([IO.Path]::GetTempPath()) ('dvprobe-' + [guid]::NewGuid().ToString('N'))
    New-Item -Path $work -ItemType Directory -Force | Out-Null
    # During a parallel scan only a couple of probes may run at once (ffmpeg reads a lot of video).
    $gate = $script:FelGate
    if ($gate) { [void]$gate.Wait() }
    try {
        $hevc = Join-Path $work 'sample.hevc'
        $rpu  = Join-Path $work 'rpu.bin'
        $seek = if ($DurationSec -gt 900) { 300 } else { 0 }      # skip studio logos on feature-length files

        Set-WorkerStage 'FEL probe: sampling video (ffmpeg)' 1 4
        & $ffmpeg -v error -nostdin -y -ss $seek -i $Path -map 0:v:0 -c:v copy -bsf:v hevc_mp4toannexb -t 20 -f hevc $hevc 2>$null
        if (-not (Test-Path -LiteralPath $hevc) -or (Get-Item -LiteralPath $hevc).Length -eq 0) { return '' }

        Set-WorkerStage 'FEL probe: extracting RPU' 2 4
        & $dovi extract-rpu -i $hevc -o $rpu 2>$null | Out-Null
        if (-not (Test-Path -LiteralPath $rpu)) { return '' }

        Set-WorkerStage 'FEL probe: analyzing RPU' 3 4
        $summary = (& $dovi info -i $rpu --summary 2>&1 | Out-String)
        if ($summary -match '\bFEL\b') { return 'FEL' }
        if ($summary -match '\bMEL\b') { return 'MEL' }
        $frame = (& $dovi info -i $rpu -f 0 2>&1 | Out-String)
        if ($frame -match '\bFEL\b') { return 'FEL' }
        if ($frame -match '\bMEL\b') { return 'MEL' }
        return ''
    }
    catch { return '' }
    finally {
        if ($gate) { [void]$gate.Release() }
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-AudioLabel {
    param([string]$Format, [string]$Commercial)
    $c = ($Commercial -replace '(?i)\s+with\s+Dolby\s+Atmos', '').Trim()
    if ($c) { return $c }
    switch ($Format) {
        'AC-3'    { 'Dolby Digital' }
        'E-AC-3'  { 'Dolby Digital Plus' }
        'MLP FBA' { 'Dolby TrueHD' }
        default   { if ($Format) { $Format } else { 'Unknown' } }
    }
}

function Get-AudioLayout {
    param([int]$Channels)
    switch ($Channels) {
        0       { 'Unknown' }
        1       { 'Mono' }
        2       { 'Stereo' }
        6       { '5.1' }
        7       { '6.1' }
        8       { '7.1' }
        default { "$Channels ch" }
    }
}

function Get-SourceFromName {
    param([string]$Name)
    if     ($Name -match '(?i)\bhybrid\b')                  { 'DV/HDR Hybrid' }      # e.g. a UHD remux with a Dolby Vision layer from a WEB-DL
    elseif ($Name -match '(?i)remux')                      { 'Remux' }
    elseif ($Name -match '(?i)blu-?ray|bdrip|brrip|\bbd\b'){ 'Blu-ray' }
    elseif ($Name -match '(?i)web[-. ]?dl|\bamzn\b|\bnf\b|\bdsnp\b') { 'WEB-DL' }
    elseif ($Name -match '(?i)web[-. ]?rip')               { 'WEBRip' }
    elseif ($Name -match '(?i)\bweb\b')                    { 'WEB-DL' }
    elseif ($Name -match '(?i)hdtv|pdtv')                  { 'HDTV' }
    elseif ($Name -match '(?i)dvdrip|\bdvd\b')             { 'DVD' }
    else                                                   { 'Unknown' }
}

function Resolve-SourceLabel {
    # Fine-tunes an 'Unknown' source from the Dolby Vision profile (the file name always wins):
    #   P7   -> UHD Blu-ray   (dual-layer is a disc format)
    #   P5   -> WEB-DL        (streaming, no HDR10 fallback)
    #   P8.1 -> DV/HDR Hybrid        (typically a UHD remux with the Dolby Vision layer taken from a WEB-DL)
    # Guessed values carry "(inferred)" so they are never mistaken for facts.
    param([string]$Source, [string]$FileName, [string]$HdrType, [string]$DvProfile)
    if ($FileName -match '(?i)\bhybrid\b') { return 'DV/HDR Hybrid' }
    if ($Source -like 'Hybrid*') { $Source = $Source -replace '^Hybrid', 'DV/HDR Hybrid' }      # label used by earlier builds
    if ($Source -and $Source -ne 'Unknown') { return $Source }
    if ($HdrType -ne 'Dolby Vision') { return 'Unknown' }
    switch ($DvProfile) {
        '7'   { 'UHD Blu-ray (inferred)' }
        '5'   { 'WEB-DL (inferred)' }
        '8.1' { 'DV/HDR Hybrid (inferred)' }
        default { 'Unknown' }
    }
}
#endregion

#region ---------------------------------------------------------------- MediaInfo bootstrap
$script:MediaInfoInitialized = $false
$script:CurrentMi            = $null

function Initialize-MediaInfoModule {
    if ($script:MediaInfoInitialized) { return }

    if (-not (Get-Module -ListAvailable -Name Get-MediaInfo)) {
        Install-Module Get-MediaInfo -Scope CurrentUser -Force -ErrorAction Stop
    }
    $moduleInfo = Get-Module -ListAvailable -Name Get-MediaInfo | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $moduleInfo) { throw 'Get-MediaInfo module could not be found or installed.' }

    $dllPath = Join-Path $moduleInfo.ModuleBase 'MediaInfoSharp.dll'
    if (-not (Test-Path -LiteralPath $dllPath)) { throw "MediaInfoSharp.dll not found at '$dllPath'." }

    Add-Type -Path $dllPath
    $script:MediaInfoInitialized = $true
}

function Get-MiFirst {
    # First non-empty value among several candidate parameter names, flattened to one line (for CSV-friendly clue columns).
    param([string]$Kind, [string[]]$Names, [int]$Index = 0)
    foreach ($n in $Names) {
        $v = Get-Mi $Kind $n $Index
        if ($v) { return (($v -replace '\s+', ' ').Trim()) }
    }
    ''
}

function Save-MediaInfoText {
    # Keeps MediaInfo's complete text for one file, so tags we do not know about yet can be found by reading it.
    # Best effort: if this MediaInfo wrapper exposes no Inform method, nothing is written.
    param($Mi, [string]$Leaf)
    try {
        if (-not $script:InformFolder) { return '' }
        if (-not (Test-Path -LiteralPath $script:InformFolder)) { New-Item -Path $script:InformFolder -ItemType Directory -Force | Out-Null }
        try { [void]$Mi.Option('Complete', '1') } catch { }
        $text = ''
        foreach ($m in @('Inform', 'Get_Inform')) {
            try { $text = [string]$Mi.$m(); if ($text) { break } } catch { }
        }
        if (-not $text) { return '' }
        $bad  = [IO.Path]::GetInvalidFileNameChars()
        $safe = -join ($Leaf.ToCharArray() | ForEach-Object { if ($bad -contains $_) { '_' } else { $_ } })
        $path = Join-Path $script:InformFolder ($safe + '.txt')
        [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
        $path
    }
    catch { '' }
}

function Get-Mi {
    # Reads one value from the MediaInfo object currently being processed.
    param([string]$Kind, [string]$Param, [int]$Index = 0)
    try   { $val = $script:CurrentMi.GetInfo($Kind, $Index, $Param) }
    catch { return '' }
    if ($null -eq $val) { return '' }
    ([string]$val).Trim()
}
#endregion

#region ---------------------------------------------------------------- Sidecar files (NFO + poster) and NFO parsing
function Get-ExternalAudioFiles {
    # Audio files that sit beside a video and share its name ("Movie.flac", "Movie.en.dts", "Movie - 5.1.flac").
    # They belong to that video; they are not separate titles.
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)
    $found = @()
    try {
        $base = $File.BaseName.ToLowerInvariant()
        foreach ($p in [IO.Directory]::GetFiles($File.DirectoryName)) {
            $e = [IO.Path]::GetExtension($p).TrimStart('.').ToLowerInvariant()
            if ($script:AudioExtensions -notcontains $e) { continue }
            if ($script:VideoExtensions -contains $e) { continue }
            if ([IO.Path]::GetFileNameWithoutExtension($p).ToLowerInvariant().StartsWith($base)) { $found += (New-Object IO.FileInfo($p)) }
        }
    }
    catch { }
    , $found
}

function Get-SidecarFiles {
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)

    $result = [pscustomobject]@{ Nfo = ''; Poster = '' }
    try {
        $names = @{}
        foreach ($p in [IO.Directory]::GetFiles($File.DirectoryName)) {
            $names[[IO.Path]::GetFileName($p).ToLowerInvariant()] = $p
        }
        $base = $File.BaseName.ToLowerInvariant()

        # NFO: "<file>.nfo" first, then movie.nfo, then any .nfo in the folder
        foreach ($cand in @("$base.nfo", 'movie.nfo')) {
            if ($names.ContainsKey($cand)) { $result.Nfo = $names[$cand]; break }
        }
        if (-not $result.Nfo) {
            $anyNfo = $names.Keys | Where-Object { $_ -like '*.nfo' } | Sort-Object | Select-Object -First 1
            if ($anyNfo) { $result.Nfo = $names[$anyNfo] }
        }

        # Poster: "<file>-poster.ext", "<file>.ext", then poster/folder/cover/movie/thumb.ext
        $stems = @("$base-poster", $base) + $script:PosterNames
        :search foreach ($stem in $stems) {
            foreach ($ext in $script:ImageExtensions) {
                $key = "$stem.$ext"
                if ($names.ContainsKey($key)) { $result.Poster = $names[$key]; break search }
            }
        }
    }
    catch { }
    $result
}

function Read-NfoRoot {
    param([string]$NfoPath)
    if (-not $NfoPath) { return $null }
    try {
        $raw = [IO.File]::ReadAllText($NfoPath, [Text.Encoding]::UTF8)
        # The leading comma stops PowerShell from unrolling the XmlElement into its child nodes.
        try { $xml = New-Object System.Xml.XmlDocument; $xml.LoadXml($raw); return ,$xml.DocumentElement }
        catch {
            # Some NFOs have junk (e.g. a URL) before/after the XML - grab the first element block.
            $m = [regex]::Match($raw, '<(movie|episodedetails|tvshow)\b.*</\1>', 'Singleline')
            if ($m.Success) { $xml = New-Object System.Xml.XmlDocument; $xml.LoadXml($m.Value); return ,$xml.DocumentElement }
        }
    }
    catch { }
    $null
}

function Get-NfoText {
    param($Root, [string]$XPath, [int]$Max = 100)
    if ($null -eq $Root) { return '' }
    try {
        $nodes = $Root.SelectNodes($XPath)
        if ($null -eq $nodes -or $nodes.Count -eq 0) { return '' }
        $vals = foreach ($n in $nodes) { $t = $n.InnerText.Trim(); if ($t) { $t } }
        (@($vals) | Select-Object -First $Max) -join '; '
    }
    catch { '' }
}
#endregion

#region ---------------------------------------------------------------- Record builder (with cache)
function Get-MediaInfoCachePath {
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)
    $key = '{0}|{1}|{2}' -f $File.FullName, $File.Length, $script:CacheVersion
    Join-Path $script:CacheFolder ((Get-StringHash $key) + '.json')
}

function Repair-CachedRecord {
    # PowerShell 7's ConvertFrom-Json turns ISO date strings into DateTime; keep them as plain text.
    param($Rec)
    foreach ($f in $script:Fields) {
        if ($f.Type -eq 'string') {
            $v = $Rec.($f.Name)
            if ($v -is [datetime]) { $Rec.($f.Name) = $v.ToString('yyyy-MM-dd') }
        }
    }
    $Rec.Source = Resolve-SourceLabel -Source ([string]$Rec.Source) -FileName ([string]$Rec.FileName) -HdrType ([string]$Rec.HDRType) -DvProfile ([string]$Rec.DVProfile)
    $Rec
}

function Get-MediaInfoRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][System.IO.FileInfo]$File,
        [switch]$RebuildCache,
        [switch]$DetectFel          # probe dual-layer Dolby Vision files with ffmpeg + dovi_tool to tell FEL from MEL
    )

    begin { Initialize-MediaInfoModule }

    process {
        $ext     = $File.Extension.TrimStart('.').ToLowerInvariant()
        $isVideo = $script:VideoExtensions -contains $ext
        $isAudio = (-not $isVideo) -and ($script:AudioExtensions -contains $ext)
        if (-not $isVideo -and -not $isAudio) { return }

        $cacheFile = Get-MediaInfoCachePath -File $File
        Set-WorkerStage 'Checking cache' 1 4
        if ($RebuildCache) { Remove-Item -LiteralPath $cacheFile -Force -ErrorAction SilentlyContinue }

        if (Test-Path -LiteralPath $cacheFile) {
            try {
                Set-WorkerStage 'Reading cache' 2 4
                $cached = [IO.File]::ReadAllText($cacheFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
                # Records saved before the clue columns existed are read again once (the file is re-opened below).
                if ($cached -and ($null -ne $cached.PSObject.Properties['WritingApp'])) {
                    $cached = Repair-CachedRecord $cached
                    # A cached dual-layer file can be upgraded to FEL/MEL later, when the probe is switched on.
                    if ($DetectFel -and $cached.DVLayer -eq 'Dual layer') {
                        $layer = Get-DolbyVisionLayerType -Path $File.FullName -DurationSec ([int]([double]$cached.RuntimeMin * 60))
                        if ($layer) {
                            $cached.DVLayer  = $layer
                            $cached.HDRStack = ([string]$cached.HDRStack) -replace '\(dual layer\)', $layer
                            try { [IO.File]::WriteAllText($cacheFile, ($cached | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding($false))) } catch { }
                        }
                    }
                    return $cached
                }
            }
            catch { }   # corrupt cache entry - rebuild below
        }

        $mi = $null
        try {
            Set-WorkerStage 'Opening file (MediaInfo)' 2 4
            $mi = New-Object MediaInfoSharp -ArgumentList $File.FullName
            $script:CurrentMi = $mi
            Set-WorkerStage 'Reading streams and tags' 3 4

            $rec   = New-EmptyRecord
            $kind  = if ($isVideo) { 'Video' } else { 'Audio' }
            $side  = Get-SidecarFiles -File $File
            $root  = if ($isVideo) { Read-NfoRoot -NfoPath $side.Nfo } else { $null }

            # ---- file / container ------------------------------------------------
            $rec.FileName           = $File.Name
            $rec.Ext                = $ext
            $rec.Type               = $kind
            $rec.Container          = Get-Mi 'General' 'Format'
            $rec.FileSizeGB         = [math]::Round($File.Length / 1GB, 2)
            $rec.RuntimeMin         = [math]::Round((ConvertTo-SafeDouble (Get-Mi 'General' 'Duration')) / 60000, 2)
            $overall                = ConvertTo-SafeDouble (Get-Mi 'General' 'OverallBitRate')
            $rec.OverallBitRateMbps = [math]::Round($overall / 1000000, 2)
            $rec.Source             = Get-SourceFromName $File.BaseName
            $rec.Added              = $File.CreationTime.ToString('yyyy-MM-dd')
            $rec.Modified           = $File.LastWriteTime.ToString('yyyy-MM-dd')
            $rec.Directory          = $File.DirectoryName
            $rec.FullPath           = $File.FullName
            $rec.HasNfo             = [bool]$side.Nfo
            $rec.HasPoster          = [bool]$side.Poster
            $rec.PosterPath         = $side.Poster

            # ---- source clues -------------------------------------------------------
            $rec.WritingApp      = Get-MiFirst 'General' @('Encoded_Application/String', 'Encoded_Application')
            $rec.WritingLib      = Get-MiFirst 'General' @('Encoded_Library/String', 'Encoded_Library')
            $rec.EmbeddedTitle   = Get-MiFirst 'General' @('Movie', 'Title')
            $rec.EmbeddedComment = Get-MiFirst 'General' @('Comment', 'Description')
            $rec.OriginalMedia   = Get-MiFirst 'General' @('OriginalSourceMedium', 'Original_Source_Medium', 'ORIGINAL_MEDIA_TYPE', 'OriginalMediaType', 'Source')
            $rec.EncodedDate     = Get-MiFirst 'General' @('Encoded_Date', 'Tagged_Date')
            $chBegin = ConvertTo-SafeInt (Get-Mi 'Menu' 'Chapters_Pos_Begin'); $chEnd = ConvertTo-SafeInt (Get-Mi 'Menu' 'Chapters_Pos_End')
            $rec.Chapters        = if ($chEnd -gt $chBegin) { $chEnd - $chBegin } else { 0 }
            $rec.AudioFormatList = Join-UniqueList (Get-Mi 'General' 'Audio_Format_List')
            $trackLabels = @()
            $trackCount  = [math]::Min((ConvertTo-SafeInt (Get-Mi 'General' 'AudioCount')), 8)
            for ($ti = 0; $ti -lt $trackCount; $ti++) {
                $tc  = Get-Mi 'Audio' 'Format_Commercial_IfAny' $ti
                $tl  = Get-AudioLabel -Format (Get-Mi 'Audio' 'Format' $ti) -Commercial $tc
                $tch = ConvertTo-SafeInt (Get-Mi 'Audio' 'Channels' $ti)
                if ($tc -match 'Atmos') { $tl += ' Atmos' }
                $trackLabels += ('{0} {1}' -f $tl, (Get-AudioLayout -Channels $tch))
            }
            if ($isVideo) {
                # external audio beside the video (e.g. Movie.flac next to Movie.mkv) is listed, marked "(external)"
                foreach ($extAudio in @(Get-ExternalAudioFiles -File $File)) {
                    $mi2 = $null; $savedMi = $script:CurrentMi
                    try {
                        $mi2 = New-Object MediaInfoSharp -ArgumentList $extAudio.FullName
                        $script:CurrentMi = $mi2
                        $xf  = Get-Mi 'Audio' 'Format'
                        $xl  = Get-AudioLabel -Format $xf -Commercial (Get-Mi 'Audio' 'Format_Commercial_IfAny')
                        $xch = ConvertTo-SafeInt (Get-Mi 'Audio' 'Channels')
                        $trackLabels += ('{0} {1} (external)' -f $xl, (Get-AudioLayout -Channels $xch))
                        $rec.AudioFormatList = (@($rec.AudioFormatList, ($xf + ' (external)')) | Where-Object { $_ }) -join '; '
                    }
                    catch { }
                    finally { $script:CurrentMi = $savedMi; if ($mi2) { $mi2.Dispose() } }
                }
            }
            $rec.AudioTrackList  = $trackLabels -join '; '
            $rec.InformFile      = Save-MediaInfoText -Mi $mi -Leaf ([IO.Path]::GetFileNameWithoutExtension($File.Name) + '-' + (Get-StringHash $File.FullName).Substring(0, 6))

            # ---- video -----------------------------------------------------------
            if ($isVideo) {
                $w   = ConvertTo-SafeInt (Get-Mi 'Video' 'Width')
                $h   = ConvertTo-SafeInt (Get-Mi 'Video' 'Height')
                $fps = ConvertTo-SafeDouble (Get-Mi 'Video' 'FrameRate')
                $vbr = ConvertTo-SafeDouble (Get-Mi 'Video' 'BitRate')
                if ($vbr -le 0) { $vbr = ConvertTo-SafeDouble (Get-Mi 'Video' 'BitRate_Nominal') }
                if ($vbr -le 0) { $vbr = $overall }

                $codec = Get-Mi 'Video' 'Format'
                if ($codec -eq 'MPEG Video') { $codec = 'MPEG' }

                $rec.Width             = $w
                $rec.Height            = $h
                $rec.Resolution        = if ($w -gt 0) { "${w}x${h}" } else { '' }
                $rec.ResolutionClass   = Get-ResolutionClass -Width $w -Height $h
                $rec.DAR               = ConvertTo-SafeDouble (Get-Mi 'Video' 'DisplayAspectRatio')
                $rec.VideoCodec        = $codec
                $rec.FormatProfile     = Get-Mi 'Video' 'Format_Profile'
                $rec.VideoCodecID      = Get-Mi 'Video' 'CodecID'
                $rec.VideoBitRateMbps  = [math]::Round($vbr / 1000000, 2)
                $rec.FrameRate         = $fps
                $rec.FrameRateMode     = Get-Mi 'Video' 'FrameRate_Mode'
                $rec.BitsPerPixel      = if (($w * $h * $fps) -gt 0 -and $vbr -gt 0) { [math]::Round($vbr / ($w * $h * $fps), 3) } else { 0.0 }
                $rec.ScanType          = Get-Mi 'Video' 'ScanType'
                $rec.BitDepth          = ConvertTo-SafeInt (Get-Mi 'Video' 'BitDepth')
                $rec.ChromaSubsampling = Get-Mi 'Video' 'ChromaSubsampling'
                $rec.ColorRange        = Get-Mi 'Video' 'colour_range'
                $enc = Get-Mi 'Video' 'Encoded_Library_Name'
                if (-not $enc) { $enc = Get-Mi 'General' 'Encoded_Library_Name' }
                $rec.Encoder           = $enc
                $rec.VideoTitle        = Get-Mi 'Video' 'Title'
                $rec.VideoEncLib       = Get-MiFirst 'Video' @('Encoded_Library/String', 'Encoded_Library')
                $encSettings           = Get-MiFirst 'Video' @('Encoded_Library_Settings')
                $rec.VideoEncSettings  = if ($encSettings.Length -gt 300) { $encSettings.Substring(0, 300) } else { $encSettings }

                $hdrFormat   = Get-Mi 'Video' 'HDR_Format'
                $hdrCompat   = Get-Mi 'Video' 'HDR_Format_Compatibility'
                $hdrProfRaw  = Get-Mi 'Video' 'HDR_Format_Profile'
                $hdrSettings = Get-Mi 'Video' 'HDR_Format_Settings'
                $hdrString   = Get-Mi 'Video' 'HDR_Format/String'
                $transfer    = Get-Mi 'Video' 'transfer_characteristics'

                $rec.HDRType           = Get-HdrType -HdrFormat $hdrFormat -Compat $hdrCompat -Transfer $transfer
                $dvInfo                = Get-DolbyVisionInfo -Format $hdrFormat -ProfileRaw $hdrProfRaw -Settings $hdrSettings -Compat $hdrCompat -InfoString $hdrString
                $hasHdr10Plus          = [bool](($hdrFormat -match 'SMPTE ST 2094|HDR10\+') -or ($hdrCompat -match 'HDR10\+'))
                if ($DetectFel -and $dvInfo.Layer -eq 'Dual layer') {
                    $probe = Get-DolbyVisionLayerType -Path $File.FullName -DurationSec ([int]($rec.RuntimeMin * 60))
                    if ($probe) { $dvInfo.Layer = $probe }
                }
                $rec.DVProfile         = $dvInfo.Profile
                $rec.DVLayer           = $dvInfo.Layer
                $rec.DVBase            = $dvInfo.Base
                $rec.HasHDR10Plus      = $hasHdr10Plus
                $rec.HDRStack          = Get-HdrStack -HdrType $rec.HDRType -Dv $dvInfo -HasHdr10Plus $hasHdr10Plus
                $rec.Source            = Resolve-SourceLabel -Source $rec.Source -FileName $File.Name -HdrType $rec.HDRType -DvProfile $rec.DVProfile
                $rec.HDRFormat         = $hdrFormat
                $hdrProfile            = $hdrProfRaw -replace '/', ''
                $rec.HDRFormatProfile  = $hdrProfile
                $rec.HDRFormatLevel    = (Get-Mi 'Video' 'HDR_Format_Level') -replace '/', ''
                $rec.HDRFormatSettings = (Get-Mi 'Video' 'HDR_Format_Settings') -replace '/', ''
                $rec.HDRFormatCompat   = $hdrCompat
                $rec.MaxCLL            = Get-Mi 'Video' 'MaxCLL'
                $rec.MaxFALL           = Get-Mi 'Video' 'MaxFALL'
                $rec.MasteringDisplay  = Get-Mi 'Video' 'MasteringDisplay_Luminance'
                $rec.Primaries         = Get-Mi 'Video' 'colour_primaries'
                $rec.Transfer          = $transfer
                $rec.Matrix            = Get-Mi 'Video' 'matrix_coefficients'
            }

            # ---- audio (first track) ---------------------------------------------
            $aFormat = Get-Mi 'Audio' 'Format'
            $aComm   = Get-Mi 'Audio' 'Format_Commercial_IfAny'
            $aAddl   = Get-Mi 'Audio' 'Format_AdditionalFeatures'
            $ch      = ConvertTo-SafeInt (Get-Mi 'Audio' 'Channels')
            if ($ch -le 0) { $ch = ConvertTo-SafeInt (Get-Mi 'Audio' 'Channel(s)') }

            $rec.AudioFormat       = Get-AudioLabel -Format $aFormat -Commercial $aComm
            $rec.ObjectAudio       = if ($aComm -match 'Atmos' -or $aAddl -match 'JOC') { 'Dolby Atmos' }
                                     elseif ($aAddl -match 'XLL X' -or $aComm -match 'DTS:X') { 'DTS:X' }
                                     else { '' }
            $rec.AudioTitle        = Get-Mi 'Audio' 'Title'
            $rec.AudioCompression  = Get-Mi 'Audio' 'Compression_Mode'
            $rec.AudioBitRateMode  = Get-Mi 'Audio' 'BitRate_Mode'
            $rec.AudioBitRateKbps  = [int][math]::Round((ConvertTo-SafeDouble (Get-Mi 'Audio' 'BitRate')) / 1000)
            $rec.AudioChannels     = $ch
            $rec.AudioLayout       = Get-AudioLayout -Channels $ch
            $rec.AudioSamplingRate = Get-Mi 'Audio' 'SamplingRate'
            $rec.AudioBitDepth     = Get-Mi 'Audio' 'BitDepth'
            $rec.AudioLanguages    = Join-UniqueList (Get-Mi 'General' 'Audio_Language_List')
            $rec.AudioTracks       = ConvertTo-SafeInt (Get-Mi 'General' 'AudioCount')

            # ---- subtitles --------------------------------------------------------
            $rec.SubtitleTracks    = ConvertTo-SafeInt (Get-Mi 'General' 'TextCount')
            $rec.SubtitleLanguages = Join-UniqueList (Get-Mi 'General' 'Text_Language_List')
            $rec.SubtitleFormats   = Join-UniqueList (Get-Mi 'General' 'Text_Format_List')

            # ---- descriptive metadata (NFO, falling back to file tags / file name) -
            $title = Get-NfoText $root 'title'
            if (-not $title) { $title = Get-Mi 'General' 'Title' }
            if (-not $title) { $title = $File.BaseName }
            $rec.Title       = $title
            $rec.ReleaseDate = Get-NfoText $root 'premiered'
            if (-not $rec.ReleaseDate) { $rec.ReleaseDate = Get-NfoText $root 'releasedate' }
            $year = ConvertTo-SafeInt (Get-NfoText $root 'year')
            if ($year -le 0 -and $rec.ReleaseDate.Length -ge 4) { $year = ConvertTo-SafeInt $rec.ReleaseDate.Substring(0, 4) }
            $rec.Year        = $year
            $rec.Genre       = Get-NfoText $root 'genre'
            $mpaa            = (Get-NfoText $root 'mpaa') -replace '(?i)^\s*(rated|usa?)[:\s]+', ''
            $rec.MPAARating  = $mpaa.Trim()
            $rating = Get-NfoText $root "ratings/rating[@name='imdb']/value"
            if (-not $rating) { $rating = (Get-NfoText $root 'ratings/rating/value') -split ';' | Select-Object -First 1 }
            if (-not $rating) { $rating = Get-NfoText $root 'rating' }
            $rec.Rating      = ConvertTo-SafeDouble $rating
            $votes = Get-NfoText $root "ratings/rating[@name='imdb']/votes"
            if (-not $votes) { $votes = Get-NfoText $root 'votes' }
            $rec.Votes       = ConvertTo-SafeInt $votes
            $rec.Studio      = Get-NfoText $root 'studio' 1
            $rec.Director    = Get-NfoText $root 'director'
            $rec.Cast        = Get-NfoText $root 'actor/name' 6
            $coll = Get-NfoText $root 'set/name'
            if (-not $coll) { $coll = Get-NfoText $root 'set[not(*)]' }
            $rec.Collection  = $coll
            $rec.Country     = Get-NfoText $root 'country'
            $rec.Tagline     = Get-NfoText $root 'tagline'
            $rec.Plot        = (Get-NfoText $root 'plot') -replace '\s+', ' '
            $imdb = Get-NfoText $root "uniqueid[@type='imdb']"
            if (-not $imdb) { $imdb = Get-NfoText $root 'imdbid' }
            if (-not $imdb) { $idTxt = Get-NfoText $root 'id'; if ($idTxt -match '^tt\d+$') { $imdb = $idTxt } }
            $rec.IMDBID      = $imdb
            $tmdb = Get-NfoText $root "uniqueid[@type='tmdb']"
            if (-not $tmdb) { $tmdb = Get-NfoText $root 'tmdbid' }
            $rec.TMDBID      = $tmdb

            $result = [pscustomobject]$rec
            Set-WorkerStage 'Writing cache' 4 4
            [IO.File]::WriteAllText($cacheFile, ($result | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding($false)))
            $result
        }
        catch {
            Write-Warning "Failed to read media info for '$($File.FullName)': $_"
        }
        finally {
            $script:CurrentMi = $null
            if ($mi) { $mi.Dispose() }
        }
    }
}
#endregion

#region ---------------------------------------------------------------- Plex source
# Reads the library straight from a Plex Media Server instead of opening every file. Plex has already analysed
# each file, so this is mostly a handful of HTTP calls. XML is used (not JSON): Windows PowerShell 5.1 cannot
# parse JSON larger than 2 MB with its built-in serializer.
$script:PlexToken     = ''
$script:PlexRemember  = $true
$script:PlexTimeoutMs = 30000
$script:PlexClientId  = 'get-mediainfogui-' + $env:COMPUTERNAME
# Shared with the background scan worker (a synchronized hashtable is safe to touch from both threads).
$script:Sync = [hashtable]::Synchronized(@{ Text = ''; Value = 0; Max = 0; Total = 0; Cancel = $false; Done = $false; Error = $null; Results = $null; Partial = $null; PhaseLo = 0.0; PhaseHi = 1.0 })
function Test-ScanCancelled { [bool]$script:Sync.Cancel }
function Get-NowMs { [Diagnostics.Stopwatch]::GetTimestamp() * 1000.0 / [Diagnostics.Stopwatch]::Frequency }
function Set-WorkerStage {
    # Tells the Workers pane what this reader is doing right now (no-op outside a parallel scan).
    param([string]$Text, [int]$Step = 0, [int]$Of = 0)
    $w = $script:WStat
    if ($w) { $w.Stage = $Text; $w.Step = $Step; $w.Of = $Of }
}
function Set-ScanPhase {
    # Starts a new step (reading details, posters, fetching info...): the STEP bar goes back to 0 % and its ETA starts over.
    # Lo..Hi is the slice (0..1) of the OVERALL bar that this step covers.
    param([double]$Lo = 0.0, [double]$Hi = 1.0)
    $sy = $script:Sync
    $sy.Max = 0; $sy.Value = 0
    $sy.PhaseLo = $Lo; $sy.PhaseHi = $Hi
    $sy.PhaseId = 1 + [int]$sy.PhaseId
}

function Protect-PlexToken {
    # DPAPI: only this Windows user, on this computer, can decrypt the result.
    param([string]$Plain)
    if ([string]::IsNullOrEmpty($Plain)) { return '' }
    ConvertFrom-SecureString -SecureString (ConvertTo-SecureString -String $Plain -AsPlainText -Force)
}

function Unprotect-PlexToken {
    param([string]$Protected)
    if ([string]::IsNullOrEmpty($Protected)) { return '' }
    try {
        $sec  = ConvertTo-SecureString -String $Protected
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    catch { '' }
}

function New-PlexRequest {
    param([string]$BaseUrl, [string]$Path, [hashtable]$Query = @{}, [string]$Token, [string]$Accept = 'application/xml')
    $parts = @()
    foreach ($k in $Query.Keys) { $parts += ('{0}={1}' -f [Uri]::EscapeDataString([string]$k), [Uri]::EscapeDataString([string]$Query[$k])) }
    $url = $BaseUrl.TrimEnd('/') + $Path
    if ($parts.Count -gt 0) { $url += '?' + ($parts -join '&') }

    $req = [Net.HttpWebRequest]::Create($url)
    $req.Method           = 'GET'
    $req.Timeout          = $script:PlexTimeoutMs
    $req.ReadWriteTimeout = $script:PlexTimeoutMs
    $req.Accept           = $Accept
    $req.Headers.Add('X-Plex-Token', $Token)                       # header, not query string, so it never lands in a URL log
    $req.Headers.Add('X-Plex-Client-Identifier', $script:PlexClientId)
    $req.Headers.Add('X-Plex-Product', 'Modern Media Library Manager')
    $req
}

function Get-PlexXml {
    param([string]$BaseUrl, [string]$Path, [hashtable]$Query = @{}, [string]$Token)
    $req  = New-PlexRequest -BaseUrl $BaseUrl -Path $Path -Query $Query -Token $Token
    $resp = $null
    $text = ''
    try {
        $resp = $req.GetResponse()
        $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        try { $text = $sr.ReadToEnd() } finally { $sr.Dispose() }
    }
    catch [Net.WebException] {
        $we = $_.Exception
        if ($we.Response) {
            $code = [int]$we.Response.StatusCode
            if ($code -eq 401) { throw 'Plex rejected the token (401 Unauthorized).' }
            throw ("Plex returned HTTP {0} for {1}" -f $code, $Path)
        }
        throw ("Could not reach Plex at {0}: {1}" -f $BaseUrl, $we.Message)
    }
    finally { if ($resp) { $resp.Close() } }

    $doc = New-Object Xml.XmlDocument
    $doc.LoadXml($text)
    , $doc                                  # the comma stops PowerShell from unrolling the document into its child nodes
}

function Get-PlexSections {
    param([string]$BaseUrl, [string]$Token)
    $doc = Get-PlexXml -BaseUrl $BaseUrl -Path '/library/sections' -Token $Token
    foreach ($d in $doc.SelectNodes('/MediaContainer/Directory')) {
        [pscustomobject]@{ Key = $d.GetAttribute('key'); Title = $d.GetAttribute('title'); Type = $d.GetAttribute('type') }
    }
}

function Get-PlexStubs {
    # One light-weight entry (ratingKey + updatedAt) per movie / episode in a library section.
    param([string]$BaseUrl, [string]$Token, $Section)
    $stubs = New-Object System.Collections.Generic.List[object]
    $start = 0; $total = [int]::MaxValue
    while ($start -lt $total) {
        if (Test-ScanCancelled) { break }
        $q = @{ 'X-Plex-Container-Start' = $start; 'X-Plex-Container-Size' = 200 }
        if ($Section.Type -eq 'show') { $q['type'] = 4 }                 # 4 = episodes
        $doc   = Get-PlexXml -BaseUrl $BaseUrl -Path ('/library/sections/' + $Section.Key + '/all') -Query $q -Token $Token
        $t     = $doc.DocumentElement.GetAttribute('totalSize')
        if ($t) { $total = [int]$t }
        $nodes = @($doc.SelectNodes('/MediaContainer/Video'))
        if ($nodes.Count -eq 0) { break }
        foreach ($n in $nodes) {
            $stubs.Add([pscustomobject]@{ Key = $n.GetAttribute('ratingKey'); Updated = $n.GetAttribute('updatedAt'); Section = $Section.Title; Kind = $Section.Type })
        }
        $start += $nodes.Count
        if (-not $t) { break }                                           # no paging info: one page is all there is
        Set-UiProgress -Text ("Listing {0}: {1} of {2}" -f $Section.Title, [math]::Min($start, $total), $total)
    }
    $stubs
}

function Get-PlexMetadataMap {
    # ratingKey -> full <Video> element (streams, tags, guids). One batched request, with single requests as a fallback.
    param([string]$BaseUrl, [string]$Token, [string[]]$Keys)
    $map = @{}
    try {
        $doc = Get-PlexXml -BaseUrl $BaseUrl -Path ('/library/metadata/' + ($Keys -join ',')) -Query @{ includeGuids = 1 } -Token $Token
        foreach ($v in $doc.SelectNodes('/MediaContainer/Video')) { $map[$v.GetAttribute('ratingKey')] = $v }
    }
    catch { if ($_.Exception.Message -match 'rejected|Could not reach') { throw } }

    foreach ($k in $Keys) {
        if ($map.ContainsKey($k)) { continue }
        try {
            $doc = Get-PlexXml -BaseUrl $BaseUrl -Path ('/library/metadata/' + $k) -Query @{ includeGuids = 1 } -Token $Token
            $v = $doc.SelectSingleNode('/MediaContainer/Video')
            if ($null -ne $v) { $map[$k] = $v }
        }
        catch { if ($_.Exception.Message -match 'rejected|Could not reach') { throw } }
    }
    $map
}

function Get-PlexShowNode {
    param([string]$BaseUrl, [string]$Token, [string]$ShowKey, [hashtable]$Cache)
    if (-not $ShowKey) { return $null }
    if ($Cache.ContainsKey($ShowKey)) { return , $Cache[$ShowKey] }      # comma: an XmlElement would otherwise be unrolled into its children
    $node = $null
    try {
        $doc  = Get-PlexXml -BaseUrl $BaseUrl -Path ('/library/metadata/' + $ShowKey) -Query @{ includeGuids = 1 } -Token $Token
        $node = $doc.SelectSingleNode('/MediaContainer/Directory')
    }
    catch { if ($_.Exception.Message -match 'rejected|Could not reach') { throw } }
    $Cache[$ShowKey] = $node
    , $node
}

function Save-PlexPoster {
    # Downloads a small (240x360) poster through Plex's own image resizer and keeps it in the thumbnail folder.
    param([string]$BaseUrl, [string]$Token, [string]$ThumbPath)
    if ([string]::IsNullOrWhiteSpace($ThumbPath)) { return '' }
    $dest = Join-Path $script:ThumbFolder ('plex-' + (Get-StringHash ($BaseUrl.ToLowerInvariant() + '|' + $ThumbPath)) + '.jpg')
    if ((Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Length -gt 0)) { return $dest }

    $resp = $null
    try {
        $req  = New-PlexRequest -BaseUrl $BaseUrl -Path '/photo/:/transcode' -Token $Token -Accept 'image/jpeg,image/*' `
                    -Query @{ width = 240; height = 360; minSize = 1; upscale = 1; url = $ThumbPath }
        $resp = $req.GetResponse()
        $ms   = New-Object IO.MemoryStream
        try {
            $rs = $resp.GetResponseStream()
            $rs.CopyTo($ms)
            if ($ms.Length -gt 0) { [IO.File]::WriteAllBytes($dest, $ms.ToArray()); return $dest }
        }
        finally { $ms.Dispose() }
    }
    catch { }
    finally { if ($resp) { $resp.Close() } }
    ''
}

function Convert-PlexEpoch {
    param([string]$Seconds)
    $n = [long]0
    if ([long]::TryParse($Seconds, [ref]$n) -and $n -gt 0) {
        try { return [DateTimeOffset]::FromUnixTimeSeconds($n).LocalDateTime.ToString('yyyy-MM-dd') } catch { }
    }
    ''
}

function Get-PlexTags {
    param($Node, [string]$Child, [int]$Max = 0)
    if ($null -eq $Node) { return '' }
    $v = @($Node.SelectNodes($Child) | ForEach-Object { $_.GetAttribute('tag') } | Where-Object { $_ })
    if ($Max -gt 0) { $v = @($v | Select-Object -First $Max) }
    $v -join '; '
}

function Get-PlexRating {
    param($Node)
    if ($null -eq $Node) { return 0.0 }
    $imdb = @($Node.SelectNodes('Rating') | Where-Object { $_.GetAttribute('image') -like 'imdb://*' }) | Select-Object -First 1
    if ($null -ne $imdb) { $r = ConvertTo-SafeDouble $imdb.GetAttribute('value'); if ($r -gt 0) { return $r } }
    $r = ConvertTo-SafeDouble $Node.GetAttribute('audienceRating'); if ($r -gt 0) { return $r }
    ConvertTo-SafeDouble $Node.GetAttribute('rating')
}

function Get-PlexAudioFormat {
    # -> @{ Label; Object } using the same names the MediaInfo path produces
    param([string]$Codec, [string]$Profile, [string]$Display)
    $c = $Codec.ToLowerInvariant(); $p = $Profile.ToLowerInvariant()
    $label = switch -Regex ($c) {
        '^truehd'     { 'Dolby TrueHD' }
        '^eac3'       { 'Dolby Digital Plus' }
        '^ac3'        { 'Dolby Digital' }
        '^(dca|dts)'  {
            if     ($p -match 'ma|dts-x|dtsx')  { 'DTS-HD Master Audio' }
            elseif ($p -match 'hra')            { 'DTS-HD High Resolution Audio' }
            elseif ($p -match 'es')             { 'DTS-ES' }
            else                                { 'DTS' }
        }
        '^aac'        { 'AAC' }
        '^flac'       { 'FLAC' }
        '^mp3'        { 'MP3' }
        '^opus'       { 'Opus' }
        '^vorbis'     { 'Vorbis' }
        '^pcm'        { 'PCM' }
        default       { if ($c) { $c.ToUpperInvariant() } else { 'Unknown' } }
    }
    $obj = ''
    if     ($Display -match 'Atmos')                    { $obj = 'Dolby Atmos' }
    elseif ($p -match 'dts-x|dtsx' -or $Display -match 'DTS[-: ]X') { $obj = 'DTS:X' }
    @{ Label = $label; Object = $obj }
}

function ConvertFrom-PlexVideo {
    # Turns one Plex <Video> (movie or episode) into a record with the same fields the MediaInfo path fills.
    param([Parameter(Mandatory)]$Video, [string]$LibraryName, $Show = $null)

    $rec  = New-EmptyRecord
    $isEp = ($Video.GetAttribute('type') -eq 'episode')
    $meta = if ($isEp -and $null -ne $Show) { $Show } else { $Video }          # tags (genre, cast, ...) live on the show for episodes

    # ---- best media version -> first part -> streams -------------------------
    $media = @($Video.SelectNodes('Media')) |
        Sort-Object @{ Expression = { ConvertTo-SafeInt $_.GetAttribute('width') }; Descending = $true },
                    @{ Expression = { ConvertTo-SafeInt $_.GetAttribute('bitrate') }; Descending = $true } |
        Select-Object -First 1
    $parts = @(); $part = $null; $streams = @()
    if ($null -ne $media) {
        $parts = @($media.SelectNodes('Part'))
        $part  = $parts | Select-Object -First 1
        if ($null -ne $part) { $streams = @($part.SelectNodes('Stream')) }
    }
    $vs       = $streams | Where-Object { $_.GetAttribute('streamType') -eq '1' } | Select-Object -First 1
    $audio    = @($streams | Where-Object { $_.GetAttribute('streamType') -eq '2' })
    $subs     = @($streams | Where-Object { $_.GetAttribute('streamType') -eq '3' })
    $as       = $audio | Where-Object { $_.GetAttribute('selected') -eq '1' } | Select-Object -First 1
    if ($null -eq $as) { $as = $audio | Select-Object -First 1 }

    # ---- titles / descriptive metadata ---------------------------------------
    $title = $Video.GetAttribute('title')
    $rec.Library = $LibraryName
    if ($isEp) {
        $season = ConvertTo-SafeInt $Video.GetAttribute('parentIndex')
        $epNum  = ConvertTo-SafeInt $Video.GetAttribute('index')
        $showTitle = $Video.GetAttribute('grandparentTitle')
        $rec.Show    = $showTitle
        $rec.Season  = $season
        $rec.Episode = $epNum
        $rec.Title   = ('{0} - S{1:00}E{2:00} - {3}' -f $showTitle, $season, $epNum, $title)
    }
    else { $rec.Title = $title }

    $rec.ReleaseDate = $Video.GetAttribute('originallyAvailableAt')
    $year = ConvertTo-SafeInt $Video.GetAttribute('year')
    if ($year -le 0 -and $rec.ReleaseDate.Length -ge 4) { $year = ConvertTo-SafeInt $rec.ReleaseDate.Substring(0, 4) }
    if ($year -le 0 -and $null -ne $Show) { $year = ConvertTo-SafeInt $Show.GetAttribute('year') }
    $rec.Year       = $year
    $rec.Genre      = Get-PlexTags $meta 'Genre'
    $mpaa = $Video.GetAttribute('contentRating')
    if (-not $mpaa -and $null -ne $Show) { $mpaa = $Show.GetAttribute('contentRating') }
    $rec.MPAARating = $mpaa
    $rating = Get-PlexRating $Video
    if ($rating -le 0 -and $null -ne $Show) { $rating = Get-PlexRating $Show }
    $rec.Rating     = $rating
    $rec.Studio     = $meta.GetAttribute('studio')
    $rec.Director   = Get-PlexTags $Video 'Director' 3
    $rec.Cast       = Get-PlexTags $meta 'Role' 6
    $rec.Collection = Get-PlexTags $Video 'Collection' 1
    $rec.Country    = Get-PlexTags $meta 'Country'
    $rec.Tagline    = $Video.GetAttribute('tagline')
    $rec.Plot       = ($Video.GetAttribute('summary')) -replace '\s+', ' '
    foreach ($g in @($meta.SelectNodes('Guid'))) {
        $id = $g.GetAttribute('id')
        if     ($id -match '^imdb://(tt\d+)') { $rec.IMDBID = $Matches[1] }
        elseif ($id -match '^tmdb://(\d+)')   { $rec.TMDBID = $Matches[1] }
    }
    if (-not $rec.IMDBID -and $meta.GetAttribute('guid') -match 'imdb://(tt\d+)') { $rec.IMDBID = $Matches[1] }
    if (-not $rec.TMDBID -and $meta.GetAttribute('guid') -match 'themoviedb://(\d+)') { $rec.TMDBID = $Matches[1] }

    # ---- file / container ------------------------------------------------------
    $file = if ($null -ne $part) { $part.GetAttribute('file') } else { '' }
    $durMs = if ($null -ne $media) { ConvertTo-SafeDouble $media.GetAttribute('duration') } else { 0.0 }
    if ($durMs -le 0) { $durMs = ConvertTo-SafeDouble $Video.GetAttribute('duration') }
    $sizeBytes = 0.0
    foreach ($p in $parts) { $sizeBytes += (ConvertTo-SafeDouble $p.GetAttribute('size')) }
    $overallKbps = if ($null -ne $media) { ConvertTo-SafeDouble $media.GetAttribute('bitrate') } else { 0.0 }
    $cont = if ($null -ne $media) { $media.GetAttribute('container') } else { '' }

    $rec.RuntimeMin         = [math]::Round($durMs / 60000, 2)
    $rec.FileName           = if ($file) { [IO.Path]::GetFileName($file) } else { '' }
    $rec.Ext                = if ($file) { [IO.Path]::GetExtension($file).TrimStart('.').ToLowerInvariant() } else { $cont }
    $rec.Type               = 'Video'
    $rec.Container          = switch -Regex ($cont.ToLowerInvariant()) {
        '^mkv'           { 'Matroska' }
        '^(mp4|m4v|mov)' { 'MPEG-4' }
        '^avi'           { 'AVI' }
        '^(ts|mpegts)'   { 'MPEG-TS' }
        '^m2ts'          { 'BDAV' }
        default          { if ($cont) { $cont.ToUpperInvariant() } else { '' } }
    }
    $rec.FileSizeGB         = [math]::Round($sizeBytes / 1GB, 2)
    $rec.OverallBitRateMbps = [math]::Round($overallKbps / 1000, 2)
    $rec.Source             = if ($file) { Get-SourceFromName ([IO.Path]::GetFileNameWithoutExtension($file)) } else { 'Unknown' }
    $rec.Added              = Convert-PlexEpoch $Video.GetAttribute('addedAt')
    $rec.Modified           = Convert-PlexEpoch $Video.GetAttribute('updatedAt')
    if ($file) {
        $cut = $file.LastIndexOfAny([char[]]@('\', '/'))
        $rec.Directory = if ($cut -gt 0) { $file.Substring(0, $cut) } else { '' }
    }
    $rec.FullPath           = $file
    $rec.HasNfo             = $true          # Plex already holds the metadata (keeps the "Missing NFO" health tile honest)
    $rec.ViewCount          = ConvertTo-SafeInt $Video.GetAttribute('viewCount')
    $rec.LastViewed         = Convert-PlexEpoch $Video.GetAttribute('lastViewedAt')
    $rec.PlexKey            = $Video.GetAttribute('ratingKey')
    $thumb = if ($isEp -and $Video.GetAttribute('grandparentThumb')) { $Video.GetAttribute('grandparentThumb') } else { $Video.GetAttribute('thumb') }
    $rec.PlexThumb          = $thumb

    # ---- video -------------------------------------------------------------------
    $w = if ($null -ne $media) { ConvertTo-SafeInt $media.GetAttribute('width') }  else { 0 }
    $h = if ($null -ne $media) { ConvertTo-SafeInt $media.GetAttribute('height') } else { 0 }
    if ($null -ne $vs) {
        if ($w -le 0) { $w = ConvertTo-SafeInt $vs.GetAttribute('width') }
        if ($h -le 0) { $h = ConvertTo-SafeInt $vs.GetAttribute('height') }
    }
    $codecRaw = if ($null -ne $vs) { $vs.GetAttribute('codec') } elseif ($null -ne $media) { $media.GetAttribute('videoCodec') } else { '' }
    $codec = switch -Regex ($codecRaw.ToLowerInvariant()) {
        '^(hevc|h265)'  { 'HEVC' }
        '^(h264|avc)'   { 'AVC' }
        '^vc1'          { 'VC-1' }
        '^mpeg2'        { 'MPEG' }
        '^mpeg4'        { 'MPEG-4 Visual' }
        '^av1'          { 'AV1' }
        '^vp9'          { 'VP9' }
        default         { if ($codecRaw) { $codecRaw.ToUpperInvariant() } else { '' } }
    }
    $fps = if ($null -ne $vs) { ConvertTo-SafeDouble $vs.GetAttribute('frameRate') } else { 0.0 }
    if ($fps -le 0 -and $media -and $media.GetAttribute('videoFrameRate') -match '^(\d+(\.\d+)?)') { $fps = ConvertTo-SafeDouble $Matches[1] }
    $vbr = if ($null -ne $vs) { (ConvertTo-SafeDouble $vs.GetAttribute('bitrate')) * 1000 } else { 0.0 }
    if ($vbr -le 0) { $vbr = $overallKbps * 1000 }

    $rec.Width            = $w
    $rec.Height           = $h
    $rec.Resolution       = if ($w -gt 0) { "${w}x${h}" } else { '' }
    $rec.ResolutionClass  = Get-ResolutionClass -Width $w -Height $h
    $rec.DAR              = if ($null -ne $media) { ConvertTo-SafeDouble $media.GetAttribute('aspectRatio') } else { 0.0 }
    $rec.VideoCodec       = $codec
    if ($null -ne $vs) { $rec.FormatProfile = (Get-Culture).TextInfo.ToTitleCase($vs.GetAttribute('profile')) }
    $rec.VideoBitRateMbps = [math]::Round($vbr / 1000000, 2)
    $rec.FrameRate        = $fps
    $rec.BitsPerPixel     = if (($w * $h * $fps) -gt 0 -and $vbr -gt 0) { [math]::Round($vbr / ($w * $h * $fps), 3) } else { 0.0 }
    if ($null -ne $vs) {
        $scan = $vs.GetAttribute('scanType')
        $rec.ScanType          = if ($scan) { (Get-Culture).TextInfo.ToTitleCase($scan) } else { '' }
        $rec.BitDepth          = ConvertTo-SafeInt $vs.GetAttribute('bitDepth')
        $rec.ChromaSubsampling = $vs.GetAttribute('chromaSubsampling')
        $range = $vs.GetAttribute('colorRange')
        $rec.ColorRange        = switch ($range) { 'tv' { 'Limited' } 'pc' { 'Full' } default { $range } }
    }

    # ---- HDR / Dolby Vision (Plex exposes the DOVI* flags on the video stream) -----
    $trc     = if ($null -ne $vs) { $vs.GetAttribute('colorTrc') } else { '' }
    $display = if ($null -ne $vs) { ($vs.GetAttribute('displayTitle') + ' ' + $vs.GetAttribute('extendedDisplayTitle')) } else { '' }
    $doviOn  = $false
    if ($null -ne $vs) {
        $doviOn = ($vs.GetAttribute('DOVIPresent') -in '1', 'true') -or ($display -match 'Dolby Vision|DoVi')
    }
    $hdrType = if ($doviOn) { 'Dolby Vision' }
               elseif ($trc -eq 'smpte2084')    { 'HDR10' }
               elseif ($trc -eq 'arib-std-b67') { 'HLG' }
               else { 'SDR' }

    $dv = [pscustomobject]@{ Profile = ''; Layer = ''; Base = '' }
    if ($doviOn) {
        $num  = ConvertTo-SafeInt $vs.GetAttribute('DOVIProfile')
        $base = switch ($vs.GetAttribute('DOVIBLCompatID')) { '1' { 'HDR10' } '6' { 'HDR10' } '2' { 'SDR' } '4' { 'HLG' } default { 'None' } }
        if ($num -eq 5) { $base = 'None' }
        $prof = ''
        if ($num -gt 0) {
            $prof = "$num"
            if ($num -in 8, 10) {
                switch ($base) { 'HDR10' { $prof = "$num.1" } 'SDR' { $prof = "$num.2" } 'HLG' { $prof = "$num.4" } }
            }
        }
        $dual = ($vs.GetAttribute('DOVIELPresent') -in '1', 'true') -or ($num -in 4, 7)
        $dv.Profile = $prof
        $dv.Base    = $base
        $dv.Layer   = if ($num -le 0) { '' } elseif ($dual) { 'Dual layer' } else { 'Single layer' }
    }
    $rec.HDRType           = $hdrType
    $rec.DVProfile         = $dv.Profile
    $rec.DVLayer           = $dv.Layer
    $rec.DVBase            = $dv.Base
    $rec.HasHDR10Plus      = $false         # Plex does not report HDR10+ (dynamic metadata)
    $rec.HDRStack          = Get-HdrStack -HdrType $hdrType -Dv $dv -HasHdr10Plus $false
    $rec.Source            = Resolve-SourceLabel -Source $rec.Source -FileName $rec.FileName -HdrType $hdrType -DvProfile $dv.Profile
    $rec.HDRFormat         = switch ($hdrType) { 'Dolby Vision' { 'Dolby Vision' } 'HDR10' { 'SMPTE ST 2084' } 'HLG' { 'HLG' } default { '' } }
    if ($doviOn) {
        $rec.HDRFormatLevel    = $vs.GetAttribute('DOVILevel')
        $rec.HDRFormatSettings = if ($dv.Layer -eq 'Dual layer') { 'BL+EL+RPU' } else { 'BL+RPU' }
        $rec.HDRFormatCompat   = $dv.Base
    }
    if ($null -ne $vs) {
        $rec.Primaries = $vs.GetAttribute('colorPrimaries')
        $rec.Transfer  = $trc
        $rec.Matrix    = $vs.GetAttribute('colorSpace')
    }

    # ---- audio (the selected / first track) ----------------------------------------
    if ($null -ne $as) {
        $ch   = ConvertTo-SafeInt $as.GetAttribute('channels')
        $adis = $as.GetAttribute('displayTitle') + ' ' + $as.GetAttribute('extendedDisplayTitle')
        $af   = Get-PlexAudioFormat -Codec $as.GetAttribute('codec') -Profile $as.GetAttribute('profile') -Display $adis
        $rec.AudioFormat       = $af.Label
        $rec.ObjectAudio       = $af.Object
        $rec.AudioTitle        = $as.GetAttribute('title')
        $rec.AudioBitRateKbps  = [int](ConvertTo-SafeDouble $as.GetAttribute('bitrate'))
        $rec.AudioChannels     = $ch
        $rec.AudioLayout       = Get-AudioLayout -Channels $ch
        $rec.AudioSamplingRate = $as.GetAttribute('samplingRate')
        $rec.AudioBitDepth     = $as.GetAttribute('bitDepth')
    }
    elseif ($null -ne $media) {
        $ch = ConvertTo-SafeInt $media.GetAttribute('audioChannels')
        $rec.AudioFormat   = (Get-PlexAudioFormat -Codec $media.GetAttribute('audioCodec') -Profile $media.GetAttribute('audioProfile') -Display '').Label
        $rec.AudioChannels = $ch
        $rec.AudioLayout   = Get-AudioLayout -Channels $ch
    }
    $rec.AudioTracks    = $audio.Count
    $rec.AudioLanguages = (@($audio | ForEach-Object { $_.GetAttribute('language') } | Where-Object { $_ } | Select-Object -Unique)) -join '; '

    # ---- subtitles --------------------------------------------------------------------
    $rec.SubtitleTracks    = $subs.Count
    $rec.SubtitleLanguages = (@($subs | ForEach-Object { $_.GetAttribute('language') } | Where-Object { $_ } | Select-Object -Unique)) -join '; '
    $rec.SubtitleFormats   = (@($subs | ForEach-Object { $_.GetAttribute('codec') } | Where-Object { $_ } | ForEach-Object { $_.ToUpperInvariant() } | Select-Object -Unique)) -join '; '

    [pscustomobject]$rec
}

function Invoke-PlexScan {
    param([string]$BaseUrl, [string]$Token, [bool]$Movies, [bool]$Shows, [bool]$Rebuild, [bool]$DetectFel)

    Set-UiProgress -Text 'Connecting to Plex...'
    $sections = @(Get-PlexSections -BaseUrl $BaseUrl -Token $Token | Where-Object {
        ($_.Type -eq 'movie' -and $Movies) -or ($_.Type -eq 'show' -and $Shows) })
    if ($sections.Count -eq 0) { throw 'This Plex server has no movie / TV libraries matching your selection.' }

    # 1) list every item (cheap) ---------------------------------------------------------
    $stubs = New-Object System.Collections.Generic.List[object]
    foreach ($sec in $sections) {
        foreach ($s in @(Get-PlexStubs -BaseUrl $BaseUrl -Token $Token -Section $sec)) { $stubs.Add($s) }
    }
    $script:Sync.Total = $stubs.Count
    if ($stubs.Count -eq 0) { return @() }

    # 2) reuse cached records whose Plex 'updatedAt' has not changed ------------------------
    $byKey = @{}
    $todo  = New-Object System.Collections.Generic.List[object]
    foreach ($s in $stubs) {
        $ck = Join-Path $script:CacheFolder ((Get-StringHash ('plex|{0}|{1}|{2}|{3}' -f $BaseUrl.ToLowerInvariant(), $s.Key, $s.Updated, $script:CacheVersion)) + '.json')
        $s | Add-Member -NotePropertyName CacheFile -NotePropertyValue $ck -Force
        if ($Rebuild) { Remove-Item -LiteralPath $ck -Force -ErrorAction SilentlyContinue }
        $hit = $null
        if (Test-Path -LiteralPath $ck) {
            try { $hit = Repair-CachedRecord ([IO.File]::ReadAllText($ck, [Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { $hit = $null }
        }
        if ($hit) { $byKey[$s.Key] = $hit } else { $todo.Add($s) }
    }

    # 3) fetch full details for the rest, in batches ----------------------------------------
    $showCache = @{}
    $done = $stubs.Count - $todo.Count
    $postLo = if ($todo.Count -gt 0) { 0.8 } else { 0.0 }       # the overall bar: details 0-80 %, posters 80-100 % (all of it when everything was cached)
    Set-ScanPhase -Lo 0.0 -Hi $postLo
    for ($i = 0; $i -lt $todo.Count; $i += 25) {
        if (Test-ScanCancelled) { break }
        $batch = @($todo | Select-Object -Skip $i -First 25)
        Set-UiProgress -Text ("Reading Plex metadata: {0} of {1}" -f ($done + 1), $stubs.Count) -Value $done -Max $stubs.Count
        $map = Get-PlexMetadataMap -BaseUrl $BaseUrl -Token $Token -Keys @($batch | ForEach-Object { $_.Key })
        foreach ($s in $batch) {
            $v = $map[$s.Key]
            if ($null -eq $v) { $done++; continue }
            $showNode = $null
            if ($v.GetAttribute('type') -eq 'episode') {
                $showNode = Get-PlexShowNode -BaseUrl $BaseUrl -Token $Token -ShowKey $v.GetAttribute('grandparentRatingKey') -Cache $showCache
            }
            try {
                $rec = ConvertFrom-PlexVideo -Video $v -LibraryName $s.Section -Show $showNode
                $byKey[$s.Key] = $rec
                [IO.File]::WriteAllText($s.CacheFile, ($rec | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding($false)))
            }
            catch { Write-Warning "Skipped Plex item $($s.Key): $_" }
            $done++
        }
    }

    # 4) posters + optional FEL/MEL probe, then put everything back in library order ----------
    $out = New-Object System.Collections.Generic.List[object]
    $n = 0
    Set-ScanPhase -Lo $postLo -Hi 1.0
    foreach ($s in $stubs) {
        if (Test-ScanCancelled) { break }
        $n++
        $rec = $byKey[$s.Key]
        if ($null -eq $rec) { continue }
        if (($n % 5) -eq 0 -or $n -eq $stubs.Count) { Set-UiProgress -Text ("Fetching posters: {0} of {1}" -f $n, $stubs.Count) -Value $n -Max $stubs.Count }

        if (-not $rec.PosterPath -or -not (Test-Path -LiteralPath $rec.PosterPath)) {
            $poster = Save-PlexPoster -BaseUrl $BaseUrl -Token $Token -ThumbPath ([string]$rec.PlexThumb)
            $rec.PosterPath = $poster
            $rec.HasPoster  = [bool]$poster
        }
        if ($DetectFel -and $rec.DVLayer -eq 'Dual layer' -and $rec.FullPath -and (Test-Path -LiteralPath $rec.FullPath -ErrorAction SilentlyContinue)) {
            $layer = Get-DolbyVisionLayerType -Path $rec.FullPath -DurationSec ([int]([double]$rec.RuntimeMin * 60))
            if ($layer) {
                $rec.DVLayer  = $layer
                $rec.HDRStack = ([string]$rec.HDRStack) -replace '\(dual layer\)', $layer
                try { [IO.File]::WriteAllText($s.CacheFile, ($rec | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding($false))) } catch { }
            }
        }
        $out.Add($rec)
    }
    $out.ToArray()
}
#endregion

#region ---------------------------------------------------------------- Metadata store + online lookups (TMDB, IMDb ratings file, OMDb)
# Fetched and hand-typed values live in one small JSON store, NOT in the media files and not in the scan cache:
#   manual values always win, fetched values fill empty fields (or replace them when "Replace existing values" was ticked).
function Set-RecField {
    # Cached records are plain objects that may predate a field - add the property when it is missing.
    param($Rec, [string]$Name, $Value)
    if ($null -ne $Rec.PSObject.Properties[$Name]) { $Rec.$Name = $Value }
    else { $Rec | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}

function Test-ValueEmpty {
    param($Value)
    if ($null -eq $Value) { return $true }
    if ($Value -is [string]) { return [string]::IsNullOrWhiteSpace($Value) }
    if ($Value -is [ValueType]) { return ([double]$Value -eq 0) }
    $false
}

function Get-MetaKeys {
    # Every key a title can be filed under, best first (an IMDb id survives renames; title+year is the fallback).
    param($Rec)
    $keys = @()
    if ($Rec.IMDBID)  { $keys += ('imdb:' + [string]$Rec.IMDBID) }
    if ($Rec.TMDBID)  { $keys += ('tmdb:' + [string]$Rec.TMDBID) }
    $keys += ('t:' + ([string]$Rec.Title).ToLowerInvariant() + '|' + [string]$Rec.Year)
    $keys
}

function Read-MetaStore {
    param([string]$Path)
    $store = @{}
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $store }
    try {
        $j = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) {
            $e = @{ Manual = @{}; Scraped = @{}; Force = @(); Sources = @{}; At = [string]$p.Value.At }
            if ($p.Value.Manual)  { foreach ($q in $p.Value.Manual.PSObject.Properties)  { $e.Manual[$q.Name]  = $q.Value } }
            if ($p.Value.Scraped) { foreach ($q in $p.Value.Scraped.PSObject.Properties) { $e.Scraped[$q.Name] = $q.Value } }
            if ($p.Value.Sources) { foreach ($q in $p.Value.Sources.PSObject.Properties) { $e.Sources[$q.Name] = [string]$q.Value } }
            if ($p.Value.Force)   { $e.Force = @($p.Value.Force) }
            $store[$p.Name] = $e
        }
    }
    catch { }
    $store
}

function Write-MetaStore {
    param([string]$Path, [hashtable]$Store)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $tmp = $Path + '.tmp'
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $Store -Depth 6), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Merge-MetaStore {
    # Applies the store to freshly scanned records (called on the UI thread right after every scan).
    # A title can be filed under several keys (IMDb id, TMDB id, title+year): all of them apply, fetched values first, typed-in values last.
    param([object[]]$Records, [string]$Path)
    $store = Read-MetaStore -Path $Path
    if ($store.Count -eq 0) { return }
    foreach ($rec in $Records) {
        $entries = @()
        foreach ($k in (Get-MetaKeys $rec)) { if ($store.ContainsKey($k)) { $entries += , $store[$k] } }
        if ($entries.Count -eq 0) { continue }
        [array]::Reverse($entries)                      # weakest key first, so the best key has the last word
        $manualNames = @{}
        foreach ($entry in $entries) { foreach ($n in $entry.Manual.Keys) { $manualNames[$n] = $true } }
        $notes = @()
        foreach ($entry in $entries) {
            foreach ($name in @($entry.Scraped.Keys)) {
                if ($manualNames.ContainsKey($name)) { continue }
                $cur = $rec.$name
                if ((Test-ValueEmpty $cur) -or ($entry.Force -contains $name)) {
                    $f = $script:Fields | Where-Object { $_.Name -eq $name } | Select-Object -First 1
                    if ($null -eq $f) { continue }
                    try { Set-RecField $rec $name ([Convert]::ChangeType($entry.Scraped[$name], $script:TypeMap[$f.Type])) } catch { continue }
                    $notes += ('{0}: {1}' -f $name, $entry.Sources[$name])
                }
            }
        }
        foreach ($entry in $entries) {
            foreach ($name in @($entry.Manual.Keys)) {
                $f = $script:Fields | Where-Object { $_.Name -eq $name } | Select-Object -First 1
                if ($null -eq $f) { continue }
                try { Set-RecField $rec $name ([Convert]::ChangeType($entry.Manual[$name], $script:TypeMap[$f.Type])) } catch { continue }
                $notes += ('{0}: manual' -f $name)
            }
        }
        if ($notes.Count -gt 0) { Set-RecField $rec 'MetaSources' ($notes -join '; ') }
    }
}

function Invoke-JsonGet {
    # One polite GET. $null for 404; waits and retries on 429 / 5xx; throws 'KEYREJECT' when the service refuses the key.
    param([string]$Url, [hashtable]$Headers = @{}, [int]$TimeoutMs = 20000)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    for ($try = 1; $try -le 4; $try++) {
        if (Test-ScanCancelled) { return $null }
        try {
            $req = [Net.HttpWebRequest]::Create($Url)
            $req.Method = 'GET'; $req.Timeout = $TimeoutMs; $req.ReadWriteTimeout = $TimeoutMs
            $req.UserAgent = 'ModernMediaLibraryManager/1.0'; $req.Accept = 'application/json'
            foreach ($k in $Headers.Keys) { $req.Headers[$k] = [string]$Headers[$k] }
            $resp = $req.GetResponse()
            try {
                $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
                try { $txt = $sr.ReadToEnd() } finally { $sr.Dispose() }
            }
            finally { $resp.Close() }
            return ($txt | ConvertFrom-Json)
        }
        catch [Net.WebException] {
            $r    = $_.Exception.Response
            $code = if ($null -ne $r) { [int]$r.StatusCode } else { 0 }
            if ($code -eq 404) { return $null }
            if ($code -eq 401 -or $code -eq 403) { throw 'KEYREJECT' }
            if ($try -ge 4) { throw }
            $wait = 2 * $try
            if ($code -eq 429 -and $null -ne $r) {
                $ra = 0; if ([int]::TryParse([string]$r.Headers['Retry-After'], [ref]$ra) -and $ra -gt 0) { $wait = [Math]::Min(30, $ra) }
            }
            Start-Sleep -Seconds $wait
        }
    }
}

function Get-ImdbRatingMap {
    # IMDb publishes daily rating files for personal, non-commercial use. Download once a week, keep only the ids we need.
    param([string]$DataFolder, $Wanted)
    $map = @{}
    if (-not (Test-Path -LiteralPath $DataFolder)) { New-Item -Path $DataFolder -ItemType Directory -Force | Out-Null }
    $gz = Join-Path $DataFolder 'title.ratings.tsv.gz'
    $stale = (-not (Test-Path -LiteralPath $gz)) -or (((Get-Date) - (Get-Item -LiteralPath $gz).LastWriteTime).TotalDays -gt 7)
    if ($stale) {
        Set-UiProgress -Text 'Downloading IMDb ratings (refreshed weekly)...'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $wc = New-Object Net.WebClient
        try {
            $wc.Headers['User-Agent'] = 'ModernMediaLibraryManager/1.0'
            $wc.DownloadFile('https://datasets.imdbws.com/title.ratings.tsv.gz', $gz + '.tmp')
            Move-Item -LiteralPath ($gz + '.tmp') -Destination $gz -Force
        }
        catch { Remove-Item -LiteralPath ($gz + '.tmp') -Force -ErrorAction SilentlyContinue }
        finally { $wc.Dispose() }
    }
    if (-not (Test-Path -LiteralPath $gz)) { return $map }
    Set-UiProgress -Text 'Reading IMDb ratings...'
    $fs = [IO.File]::OpenRead($gz)
    $gs = New-Object IO.Compression.GZipStream($fs, [IO.Compression.CompressionMode]::Decompress)
    $sr = New-Object IO.StreamReader($gs)
    try {
        [void]$sr.ReadLine()
        $n = 0
        while ($null -ne ($line = $sr.ReadLine())) {
            $n++
            if (($n % 200000) -eq 0 -and (Test-ScanCancelled)) { break }
            $tab = $line.IndexOf("`t")
            if ($tab -lt 1) { continue }
            $id = $line.Substring(0, $tab)
            if ($Wanted.Contains($id)) {
                $p = $line.Split("`t")
                $map[$id] = @{ Rating = (ConvertTo-SafeDouble $p[1]); Votes = (ConvertTo-SafeInt $p[2]) }
            }
        }
    }
    finally { $sr.Dispose(); $gs.Dispose(); $fs.Dispose() }
    $map
}

function Invoke-MetadataScrape {
    # Fills Year, Genre, certification, rating, studio, director, Rotten Tomatoes critic score and box office for the given titles.
    param([object[]]$Records, [int[]]$Indexes, [string]$TmdbKey, [string]$OmdbKey, [bool]$Overwrite, [string]$DataFolder, [string]$StorePath)

    $script:Sync.Total = $Indexes.Count
    foreach ($r in $Records) { [void]$script:Sync.Partial.Add($r) }      # so an abandoned run still returns every title
    $targets = @($Indexes | ForEach-Object { $Records[$_] } | Where-Object { -not [string]$_.Show })
    $skippedTv = $Indexes.Count - $targets.Count
    if ($targets.Count -eq 0) { $script:Sync.Summary = 'Nothing to fetch: only movies are supported for now (TV titles were skipped).'; return }

    $wanted = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($t in $targets) { if ($t.IMDBID) { [void]$wanted.Add([string]$t.IMDBID) } }
    Set-ScanPhase -Lo 0.0 -Hi 0.1
    $imdb = Get-ImdbRatingMap -DataFolder $DataFolder -Wanted $wanted

    $headers = @{}; $keyQ = ''
    if ($TmdbKey.Length -gt 60) { $headers['Authorization'] = 'Bearer ' + $TmdbKey } else { $keyQ = '&api_key=' + [Uri]::EscapeDataString($TmdbKey) }
    $store = Read-MetaStore -Path $StorePath
    $stats = @{ Done = 0; Found = 0; Missing = 0; Failed = 0 }
    $tmdbOff = (-not $TmdbKey); $omdbOff = (-not $OmdbKey); $omdbLimit = $false; $keyBad = ''
    Set-ScanPhase -Lo 0.1 -Hi 1.0
    $i = 0
    foreach ($rec in $targets) {
        if (Test-ScanCancelled) { break }
        $i++
        Set-UiProgress -Text ('Fetching info {0} of {1}: {2}' -f $i, $targets.Count, $rec.Title) -Value $i -Max $targets.Count
        $keys  = Get-MetaKeys $rec
        $entry = $null
        foreach ($k in $keys) { if ($store.ContainsKey($k)) { $entry = $store[$k]; break } }
        if ($null -eq $entry) { $entry = @{ Manual = @{}; Scraped = @{}; Force = @(); Sources = @{}; At = '' } }
        $got = @{}                                   # field -> @{ Value; Source }
        $imdbId = [string]$rec.IMDBID
        try {
            # ---- TMDB ---------------------------------------------------------------
            if (-not $tmdbOff) {
                $tid = [string]$rec.TMDBID
                if (-not $tid -and $imdbId) {
                    $f = Invoke-JsonGet -Url ('https://api.themoviedb.org/3/find/' + $imdbId + '?external_source=imdb_id' + $keyQ) -Headers $headers
                    Start-Sleep -Milliseconds 250
                    if ($f -and @($f.movie_results).Count -gt 0) { $tid = [string]@($f.movie_results)[0].id }
                }
                if (-not $tid) {
                    $q = 'https://api.themoviedb.org/3/search/movie?query=' + [Uri]::EscapeDataString([string]$rec.Title) + $keyQ
                    if ([int]$rec.Year -gt 0) { $q += '&year=' + [int]$rec.Year }
                    $f = Invoke-JsonGet -Url $q -Headers $headers
                    Start-Sleep -Milliseconds 250
                    if ($f) {
                        $hits = @($f.results)
                        if ([int]$rec.Year -gt 0) {
                            $hit = $hits | Where-Object { $_.release_date -and [Math]::Abs([int]([string]$_.release_date).Substring(0, 4) - [int]$rec.Year) -le 1 } | Select-Object -First 1
                        }
                        else {
                            $same = @($hits | Where-Object { ([string]$_.title).ToLowerInvariant() -eq ([string]$rec.Title).ToLowerInvariant() })
                            $hit = if ($same.Count -eq 1) { $same[0] } else { $null }
                        }
                        if ($hit) { $tid = [string]$hit.id }
                    }
                }
                if ($tid) {
                    $d = Invoke-JsonGet -Url ('https://api.themoviedb.org/3/movie/' + $tid + '?append_to_response=credits,release_dates' + $keyQ) -Headers $headers
                    Start-Sleep -Milliseconds 250
                    if ($d) {
                        if (-not $imdbId -and $d.imdb_id) { $imdbId = [string]$d.imdb_id }
                        if ($d.release_date -and ([string]$d.release_date).Length -ge 4) { $got['Year'] = @{ Value = [int]([string]$d.release_date).Substring(0, 4); Source = 'TMDB' } }
                        $g = @($d.genres | ForEach-Object { $_.name } | Where-Object { $_ })
                        if ($g.Count -gt 0) { $got['Genre'] = @{ Value = ($g -join '; '); Source = 'TMDB' } }
                        $co = @($d.production_companies | ForEach-Object { $_.name } | Where-Object { $_ }) | Select-Object -First 1
                        if ($co) { $got['Studio'] = @{ Value = [string]$co; Source = 'TMDB' } }
                        $dir = @($d.credits.crew | Where-Object { $_.job -eq 'Director' } | ForEach-Object { $_.name } | Select-Object -Unique)
                        if ($dir.Count -gt 0) { $got['Director'] = @{ Value = ($dir -join '; '); Source = 'TMDB' } }
                        $us = @($d.release_dates.results | Where-Object { $_.iso_3166_1 -eq 'US' }) | Select-Object -First 1
                        if ($us) {
                            $c = @($us.release_dates | Where-Object { $_.certification } | Sort-Object { if ($_.type -eq 3) { 0 } else { 1 } })
                            if ($c.Count -gt 0) { $got['MPAARating'] = @{ Value = [string]$c[0].certification; Source = 'TMDB' } }
                        }
                        if ([double]$d.revenue -gt 0) { $got['BoxOfficeWorldwide'] = @{ Value = [double]$d.revenue; Source = 'TMDB' } }
                        if ([double]$d.vote_average -gt 0) { $got['Rating'] = @{ Value = [Math]::Round([double]$d.vote_average, 1); Source = 'TMDB' }; $got['Votes'] = @{ Value = [int]$d.vote_count; Source = 'TMDB' } }
                        if (-not $rec.TMDBID) { $got['TMDBID'] = @{ Value = $tid; Source = 'TMDB' } }
                    }
                }
            }
            if ($imdbId -and -not $rec.IMDBID) { $got['IMDBID'] = @{ Value = $imdbId; Source = 'TMDB' } }

            # ---- IMDb ratings file (beats TMDB's own score) --------------------------------
            if ($imdbId -and $imdb.ContainsKey($imdbId)) {
                $m = $imdb[$imdbId]
                if ($m.Rating -gt 0) { $got['Rating'] = @{ Value = [double]$m.Rating; Source = 'IMDb' }; $got['Votes'] = @{ Value = [int]$m.Votes; Source = 'IMDb' } }
            }

            # ---- OMDb: Rotten Tomatoes critic score, domestic box office ---------------------
            if (-not $omdbOff -and -not $omdbLimit -and $imdbId) {
                $o = Invoke-JsonGet -Url ('https://www.omdbapi.com/?apikey=' + [Uri]::EscapeDataString($OmdbKey) + '&i=' + $imdbId)
                if ($o) {
                    if ($o.Response -eq 'False' -and ([string]$o.Error) -match 'limit') { $omdbLimit = $true }
                    elseif ($o.Response -eq 'True') {
                        $rt = @($o.Ratings | Where-Object { $_.Source -eq 'Rotten Tomatoes' }) | Select-Object -First 1
                        if ($rt -and ([string]$rt.Value) -match '^(\d+)%') { $got['RTCritic'] = @{ Value = [int]$Matches[1]; Source = 'OMDb' } }
                        $bo = [string]$o.BoxOffice
                        if ($bo -match '^\$([\d,]+)$') { $got['BoxOfficeDomestic'] = @{ Value = [double]($Matches[1] -replace ',', ''); Source = 'OMDb' } }
                    }
                }
            }
        }
        catch {
            if ($_.Exception.Message -eq 'KEYREJECT') { $keyBad = 'An API key was rejected - check the keys under the gear button.'; break }
            $stats.Failed++; continue
        }

        # ---- apply: manual values always win; empty fields are filled; Replace ticked => overwrite ----
        $changed = $false
        foreach ($name in @($got.Keys)) {
            if ($entry.Manual.ContainsKey($name)) { continue }
            $f = $script:Fields | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if ($null -eq $f) { continue }
            $v = $got[$name].Value
            $cur = $rec.$name
            if ((Test-ValueEmpty $cur) -or ($Overwrite -and "$cur" -ne "$v")) {
                Set-RecField $rec $name ([Convert]::ChangeType($v, $script:TypeMap[$f.Type]))
                $changed = $true
            }
            $entry.Scraped[$name] = $v
            $entry.Sources[$name] = $got[$name].Source
            if ($Overwrite -and $entry.Force -notcontains $name) { $entry.Force = @($entry.Force) + $name }
        }
        if ($got.Count -gt 0) {
            $entry.At = (Get-Date).ToString('yyyy-MM-dd')
            foreach ($k in (Get-MetaKeys $rec)) { $store[$k] = $entry }
            $stats.Found++
        }
        else { $stats.Missing++ }
        if ($changed) { $notes = @($entry.Sources.Keys | Sort-Object | ForEach-Object { '{0}: {1}' -f $_, $entry.Sources[$_] }); Set-RecField $rec 'MetaSources' ($notes -join '; ') }
        $stats.Done++
        if (($i % 25) -eq 0) { try { Write-MetaStore -Path $StorePath -Store $store } catch { } }
    }
    try { Write-MetaStore -Path $StorePath -Store $store } catch { }

    $sum = 'Fetched info for {0} of {1} title(s)' -f $stats.Found, $targets.Count
    if ($stats.Missing -gt 0) { $sum += ", $($stats.Missing) not found" }
    if ($stats.Failed  -gt 0) { $sum += ", $($stats.Failed) failed" }
    if ($skippedTv     -gt 0) { $sum += ", $skippedTv TV title(s) skipped" }
    $sum += '.'
    if ($omdbLimit) { $sum += ' OMDb daily limit reached - run again tomorrow for the rest.' }
    if ($keyBad)    { $sum += ' ' + $keyBad }
    if ($tmdbOff)   { $sum += ' (No TMDB key set.)' }
    $script:Sync.Summary = $sum
}
#endregion

#region ---------------------------------------------------------------- Background scan (keeps the window responsive)
function Invoke-FolderScan {
    # Walks a folder (local or UNC), reads every media file and adds each finished record to $script:Sync.Partial.
    # Cancellable between files and between directories; a progress line is published as it goes.
    param([string]$Folder, [bool]$Video, [bool]$Audio, [bool]$Rebuild, [bool]$DetectFel, [int]$Parallel = 1)

    if (-not [IO.Directory]::Exists($Folder)) { throw "The folder was not found or cannot be reached:`n$Folder" }
    Initialize-MediaInfoModule

    $exts = @()
    if ($Video) { $exts += $script:VideoExtensions }
    if ($Audio) { $exts += $script:AudioExtensions }

    $paths = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Folder)
    while ($stack.Count -gt 0) {
        if (Test-ScanCancelled) { return }
        $dir = $stack.Pop()
        try {
            foreach ($f in [IO.Directory]::EnumerateFiles($dir)) {
                $e = [IO.Path]::GetExtension($f).TrimStart('.').ToLowerInvariant()
                if ($exts -contains $e) { $paths.Add($f) }
            }
            foreach ($d in [IO.Directory]::EnumerateDirectories($dir)) { $stack.Push($d) }
        }
        catch { }          # unreadable folder: skip it
        Set-UiProgress -Text ('Enumerating files... {0} found' -f $paths.Count)
    }
    # External audio that belongs to a video in the same folder (Movie.mkv + Movie.flac) is not a title of its own.
    $videoBases = @{}
    foreach ($p in $paths) {
        if ($script:VideoExtensions -contains [IO.Path]::GetExtension($p).TrimStart('.').ToLowerInvariant()) {
            $d = [IO.Path]::GetDirectoryName($p)
            if (-not $videoBases.ContainsKey($d)) { $videoBases[$d] = New-Object System.Collections.Generic.List[string] }
            $videoBases[$d].Add([IO.Path]::GetFileNameWithoutExtension($p).ToLowerInvariant())
        }
    }
    if ($videoBases.Count -gt 0) {
        $kept = New-Object System.Collections.Generic.List[string]
        foreach ($p in $paths) {
            $isCompanion = $false
            if ($script:AudioExtensions -contains [IO.Path]::GetExtension($p).TrimStart('.').ToLowerInvariant()) {
                $d = [IO.Path]::GetDirectoryName($p)
                if ($videoBases.ContainsKey($d)) {
                    $ab = [IO.Path]::GetFileNameWithoutExtension($p).ToLowerInvariant()
                    foreach ($vb in $videoBases[$d]) { if ($ab.StartsWith($vb)) { $isCompanion = $true; break } }
                }
            }
            if (-not $isCompanion) { $kept.Add($p) }
        }
        $paths = $kept
    }
    $script:Sync.Total = $paths.Count
    if ($paths.Count -eq 0) { return }

    $sorted = @($paths | Sort-Object)
    $workers = [Math]::Max(1, [Math]::Min([Math]::Min(12, [int]$Parallel), $sorted.Count))

    if ($sorted.Count -lt 2 -or -not $script:FunctionCode) {
        $i = 0
        foreach ($p in $sorted) {
            if (Test-ScanCancelled) { break }
            $i++
            Set-UiProgress -Text ('Reading {0} of {1}: {2}' -f $i, $sorted.Count, [IO.Path]::GetFileName($p)) -Value $i -Max $sorted.Count
            try {
                $fi  = New-Object IO.FileInfo($p)
                $rec = Get-MediaInfoRecord -File $fi -RebuildCache:$Rebuild -DetectFel:$DetectFel
                if ($rec) { [void]$script:Sync.Partial.Add($rec) }
            }
            catch { }
        }
        return
    }

    # ---- parallel: N reader runspaces pull file numbers from one shared queue ---------------------------
    $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[int]'
    for ($k = 0; $k -lt $sorted.Count; $k++) { $queue.Enqueue($k) }
    $slots  = New-Object 'object[]' $sorted.Count
    $shared = [hashtable]::Synchronized(@{ Done = 0; Error = $null })
    $gate   = New-Object System.Threading.SemaphoreSlim -ArgumentList 4
    $stats  = New-Object 'object[]' 13           # one live status record per reader, shown by the Workers pane
    for ($k = 1; $k -le 12; $k++) {
        $stats[$k] = [hashtable]::Synchronized(@{ No = $k; State = 'Not started'; File = ''; Stage = ''; Step = 0; Of = 4; Since = 0.0; Started = 0.0; Done = 0; BusyMs = 0.0 })
    }
    $script:Sync.WorkerStats = $stats

    $childScript = $script:FunctionCode + @'
try {
    $idx = 0
    if ([double]$WStat.Started -eq 0) { $WStat.Started = Get-NowMs }
    $WStat.State = 'Idle'
    # A reader whose number is above the current target (the box can be changed mid-scan) stops after its file.
    while (-not (Test-ScanCancelled) -and ($WorkerNo -le [int]$script:Sync.Workers) -and $Queue.TryDequeue([ref]$idx)) {
        $p = $Paths[$idx]
        $WStat.File = [IO.Path]::GetFileName($p); $WStat.Stage = 'Starting'; $WStat.Step = 0; $WStat.Of = 4
        $WStat.Since = Get-NowMs; $WStat.State = 'Reading'
        try {
            $fi  = New-Object IO.FileInfo($p)
            $rec = Get-MediaInfoRecord -File $fi -RebuildCache:$Rebuild -DetectFel:$DetectFel
            if ($rec) { $Slots[$idx] = $rec; [void]$script:Sync.Partial.Add($rec) }
        }
        catch { }
        $WStat.BusyMs = [double]$WStat.BusyMs + ((Get-NowMs) - [double]$WStat.Since)
        $WStat.Done = [int]$WStat.Done + 1
        $WStat.State = 'Idle'; $WStat.Stage = 'Finished file'; $WStat.Step = 4
        [System.Threading.Monitor]::Enter($Shared.SyncRoot)
        try {
            $Shared.Done = [int]$Shared.Done + 1
            Set-UiProgress -Text ('Reading {0} of {1}: {2}' -f $Shared.Done, $Paths.Count, [IO.Path]::GetFileName($p)) -Value $Shared.Done -Max $Paths.Count
        }
        finally { [System.Threading.Monitor]::Exit($Shared.SyncRoot) }
    }
    $WStat.State = if (Test-ScanCancelled) { 'Cancelled' } elseif ($WorkerNo -gt [int]$script:Sync.Workers) { 'Stopped' } else { 'Finished' }
    $WStat.Stage = ''
}
catch { $Shared.Error = $_.Exception.Message; $WStat.State = 'Error' }
'@

    $kids    = New-Object System.Collections.Generic.List[object]      # every reader ever started (cleaned up at the end)
    $readers = New-Object 'object[]' 13                                 # the current reader for each number 1..12
    $script:Sync.Workers = [Math]::Max(1, [Math]::Min(12, [int]$Parallel))

    $addReader = {
        param([int]$no)
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'MTA'
        $rs.Open()
        foreach ($key in @($script:WorkerVars.Keys)) { $rs.SessionStateProxy.SetVariable($key, $script:WorkerVars[$key]) }
        $rs.SessionStateProxy.SetVariable('Queue',     $queue)
        $rs.SessionStateProxy.SetVariable('Paths',     $sorted)
        $rs.SessionStateProxy.SetVariable('Slots',     $slots)
        $rs.SessionStateProxy.SetVariable('Shared',    $shared)
        $rs.SessionStateProxy.SetVariable('Rebuild',   $Rebuild)
        $rs.SessionStateProxy.SetVariable('DetectFel', $DetectFel)
        $rs.SessionStateProxy.SetVariable('FelGate',   $gate)
        $rs.SessionStateProxy.SetVariable('WorkerNo',  $no)
        $rs.SessionStateProxy.SetVariable('WStat',     $stats[$no])
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($childScript)
        $kid = [pscustomobject]@{ Ps = $ps; Rs = $rs; Handle = $ps.BeginInvoke() }
        $kids.Add($kid)
        $kid
    }

    try {
        $started = 0
        while ($true) {
            # (re)start readers up to the current target; the box can be raised or lowered while the scan runs
            if (-not (Test-ScanCancelled) -and -not $queue.IsEmpty -and $started -lt 80) {
                $target = [Math]::Max(1, [Math]::Min(12, [int]$script:Sync.Workers))
                for ($no = 1; $no -le $target; $no++) {
                    $cur = $readers[$no]
                    if ($null -eq $cur -or $cur.Handle.IsCompleted) { $readers[$no] = & $addReader $no; $started++ }
                }
            }
            $alive = 0
            for ($no = 1; $no -le 12; $no++) {
                if ($null -ne $readers[$no] -and -not $readers[$no].Handle.IsCompleted) { $alive++ }
            }
            $script:Sync.Active = $alive
            if ($alive -eq 0) { break }
            Start-Sleep -Milliseconds 120
        }
    }
    finally {
        foreach ($kid in $kids) {
            try { if ($kid.Handle.IsCompleted) { $kid.Ps.EndInvoke($kid.Handle) | Out-Null } } catch { }
            try { $kid.Ps.Dispose() } catch { }
            try { $kid.Rs.Dispose() } catch { }
        }
        try { $gate.Dispose() } catch { }
    }

    # put the records back in library (path) order
    $ordered = @($slots | Where-Object { $null -ne $_ })
    if ($ordered.Count -eq 0 -and $shared.Error -and -not (Test-ScanCancelled)) { throw $shared.Error }
    $script:Sync.Partial.Clear()
    foreach ($r in $ordered) { [void]$script:Sync.Partial.Add($r) }
}

# Everything the worker needs, copied into a separate runspace (a second PowerShell on its own thread).
$script:WorkerFunctions = @(
    'Test-ScanCancelled', 'Get-NowMs', 'Set-WorkerStage', 'Set-ScanPhase', 'ConvertTo-SafeInt', 'ConvertTo-SafeDouble', 'Join-UniqueList', 'Get-StringHash', 'New-EmptyRecord',
    'Get-ResolutionClass', 'Get-HdrType', 'Get-DolbyVisionInfo', 'Get-HdrStack', 'Find-Tool', 'Get-DolbyVisionLayerType',
    'Get-AudioLabel', 'Get-AudioLayout', 'Get-SourceFromName', 'Resolve-SourceLabel', 'Initialize-MediaInfoModule', 'Get-Mi', 'Get-MiFirst', 'Save-MediaInfoText', 'Get-SidecarFiles', 'Get-ExternalAudioFiles',
    'Read-NfoRoot', 'Get-NfoText', 'Get-MediaInfoCachePath', 'Repair-CachedRecord', 'Get-MediaInfoRecord',
    'New-PlexRequest', 'Get-PlexXml', 'Get-PlexSections', 'Get-PlexStubs', 'Get-PlexMetadataMap', 'Get-PlexShowNode',
    'Save-PlexPoster', 'Convert-PlexEpoch', 'Get-PlexTags', 'Get-PlexRating', 'Get-PlexAudioFormat', 'ConvertFrom-PlexVideo',
    'Invoke-PlexScan', 'Invoke-FolderScan',
    'Set-RecField', 'Test-ValueEmpty', 'Get-MetaKeys', 'Read-MetaStore', 'Write-MetaStore', 'Invoke-JsonGet', 'Get-ImdbRatingMap', 'Invoke-MetadataScrape'
)

function Start-ScanWorker {
    param([ValidateSet('Plex', 'Folder', 'Scrape')][string]$Mode, [hashtable]$ScanArgs)

    $code = New-Object Text.StringBuilder
    foreach ($name in $script:WorkerFunctions) {
        $cmd = Get-Command -Name $name -CommandType Function -ErrorAction Stop
        [void]$code.AppendLine("function $name {")
        [void]$code.AppendLine($cmd.Definition)
        [void]$code.AppendLine('}')
    }
    [void]$code.AppendLine(@'
function Set-UiProgress {
    param([string]$Text, [int]$Value = -1, [int]$Max = 0)
    if ($Text) { $script:Sync.Text = $Text }
    if ($Max -gt 0 -and $Value -ge 0) { $script:Sync.Value = $Value; $script:Sync.Max = $Max }
}
'@)
    $functionCode = $code.ToString()      # reader threads of a parallel folder scan load exactly this
    [void]$code.AppendLine(@'
try {
    if ($Mode -eq 'Plex') { $script:Sync.Results = @(Invoke-PlexScan @ScanArgs) }
    elseif ($Mode -eq 'Scrape') { Invoke-MetadataScrape @ScanArgs; $script:Sync.Results = @($ScanArgs.Records) }
    else {
        Invoke-FolderScan @ScanArgs
        $script:Sync.Results = @($script:Sync.Partial.ToArray())
    }
}
catch { $script:Sync.Error = $_.Exception.Message }
finally { $script:Sync.Done = $true }
'@)

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.Open()
    $vars = @{
        Sync = $script:Sync; Mode = $Mode; ScanArgs = $ScanArgs
        AppRoot = $script:AppRoot; CacheVersion = $script:CacheVersion; CacheFolder = $script:CacheFolder
        ThumbFolder = $script:ThumbFolder; LibFolder = $script:LibFolder; Culture = $script:Culture
        VideoExtensions = $script:VideoExtensions; AudioExtensions = $script:AudioExtensions
        PosterNames = $script:PosterNames; ImageExtensions = $script:ImageExtensions
        Fields = $script:Fields; TypeMap = $script:TypeMap
        PlexTimeoutMs = $script:PlexTimeoutMs; PlexClientId = $script:PlexClientId; InformFolder = $script:InformFolder
    }
    $workerVars = @{}
    foreach ($k in $vars.Keys) { if ($k -ne 'Mode' -and $k -ne 'ScanArgs') { $workerVars[$k] = $vars[$k] } }
    $vars['FunctionCode'] = $functionCode
    $vars['WorkerVars']   = $workerVars
    foreach ($k in $vars.Keys) { $rs.SessionStateProxy.SetVariable($k, $vars[$k]) }

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($code.ToString())
    $script:ScanRs    = $rs
    $script:ScanPs    = $ps
    $script:ScanAsync = $ps.BeginInvoke()
}
#endregion

#region ---------------------------------------------------------------- Settings (remembered between runs)
function Read-Settings {
    $s = [ordered]@{
        LastFolder     = ''
        Source         = 'Plex'
        PlexUrl        = 'http://plex-server:32400'
        PlexMovies     = $true
        PlexShows      = $true
        PlexTokenProtected = ''
        Video          = $true
        Audio          = $true
        EmbedPosters   = $false
        DetectFel      = $false
        Parallel       = 4
        WarnRebuild    = $true
        TmdbKeyProtected = ''
        OmdbKeyProtected = ''
        ClientWidth    = 1280
        ClientHeight   = 780
        VisibleColumns = @()
        HiddenColumns  = @()
        ColumnWidths   = @{}
    }
    if (Test-Path -LiteralPath $script:SettingsPath) {
        try {
            $j = [IO.File]::ReadAllText($script:SettingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($k in @('LastFolder', 'Source', 'PlexUrl', 'PlexMovies', 'PlexShows', 'PlexTokenProtected', 'Video', 'Audio', 'EmbedPosters', 'DetectFel', 'Parallel', 'WarnRebuild', 'TmdbKeyProtected', 'OmdbKeyProtected', 'ClientWidth', 'ClientHeight')) {
                if ($null -ne $j.$k) { $s[$k] = $j.$k }
            }
            if ($null -ne $j.VisibleColumns) { $s['VisibleColumns'] = @($j.VisibleColumns) }
            if ($null -ne $j.HiddenColumns)  { $s['HiddenColumns']  = @($j.HiddenColumns) }
            if ($null -ne $j.ColumnWidths) {
                $w = @{}
                foreach ($p in $j.ColumnWidths.PSObject.Properties) { $w[$p.Name] = [int]$p.Value }
                $s['ColumnWidths'] = $w
            }
        }
        catch { }    # unreadable settings file: carry on with defaults
    }
    $s
}

function Update-SettingsFromUi {
    $s = $script:Settings
    if ($script:CurrentSource -eq 'Plex') { $s['PlexUrl'] = $txtFolder.Text.Trim() } else { $s['LastFolder'] = $txtFolder.Text.Trim() }
    $s['Source']       = if ($radPlex.Checked) { 'Plex' } else { 'Local' }
    $s['PlexMovies']   = [bool]$chkMovies.Checked
    $s['PlexShows']    = [bool]$chkShows.Checked
    $s['Video']        = [bool]$chkVideo.Checked
    $s['Audio']        = [bool]$chkAudio.Checked
    $s['EmbedPosters'] = [bool]$chkEmbed.Checked
    $s['DetectFel']    = [bool]$chkFel.Checked
    $s['Parallel']     = [int]$nudPar.Value
    if ($form.WindowState -eq 'Normal') { $s['ClientWidth'] = $form.ClientSize.Width; $s['ClientHeight'] = $form.ClientSize.Height }

    # Column layout is only captured while the grid actually has columns (i.e. after a scan).
    if ($grid.Columns.Count -gt 0) {
        $vis = @(); $hid = @(); $w = @{}
        foreach ($c in $grid.Columns) {
            if ($c.Visible) { $vis += $c.Name; $w[$c.Name] = [int]$c.Width } else { $hid += $c.Name }
        }
        foreach ($k in @($s['ColumnWidths'].Keys)) { if (-not $w.ContainsKey($k)) { $w[$k] = $s['ColumnWidths'][$k] } }
        $s['VisibleColumns'] = $vis
        $s['HiddenColumns']  = $hid
        $s['ColumnWidths']   = $w
    }
}

function Save-Settings {
    try {
        Update-SettingsFromUi
        $json = ConvertTo-Json -InputObject $script:Settings -Depth 4
        [IO.File]::WriteAllText($script:SettingsPath, $json, (New-Object Text.UTF8Encoding($false)))
    }
    catch { }
}

function Set-GridColumnLayout {
    # Applies remembered visibility/widths. Columns the settings file has never seen (new fields) use their default.
    $vis    = @($script:Settings['VisibleColumns'])
    $hid    = @($script:Settings['HiddenColumns'])
    $widths = $script:Settings['ColumnWidths']
    foreach ($f in $script:Fields) {
        $col = $grid.Columns[$f.Name]
        if ($null -eq $col) { continue }
        if     ($vis -contains $f.Name) { $col.Visible = $true }
        elseif ($hid -contains $f.Name) { $col.Visible = $false }
        else                            { $col.Visible = $f.Show }
    }
    $grid.AutoResizeColumns('DisplayedCells')
    foreach ($c in $grid.Columns) {
        if ($c.Visible -and $widths.ContainsKey($c.Name) -and $widths[$c.Name] -ge 30) { $c.Width = $widths[$c.Name] }
    }
}
#endregion

#region ---------------------------------------------------------------- Posters, dashboard, export
function Get-PosterThumbnail {
    # Resizes a poster to a small JPEG (cached on disk) and returns the thumbnail path.
    param([Parameter(Mandatory)][string]$Source, [int]$Width = 240)
    try {
        $fi   = Get-Item -LiteralPath $Source -ErrorAction Stop
        $key  = '{0}|{1}|{2}|{3}' -f $fi.FullName, $fi.Length, $fi.LastWriteTimeUtc.Ticks, $Width
        $dest = Join-Path $script:ThumbFolder ((Get-StringHash $key) + '.jpg')
        if (Test-Path -LiteralPath $dest) { return $dest }

        $bytes = [IO.File]::ReadAllBytes($fi.FullName)
        $ms    = New-Object IO.MemoryStream(, $bytes)
        $img   = [Drawing.Image]::FromStream($ms)
        try {
            $h   = [int][math]::Round($img.Height * $Width / [double]$img.Width)
            $bmp = New-Object Drawing.Bitmap($Width, $h)
            try {
                $g = [Drawing.Graphics]::FromImage($bmp)
                try {
                    $g.Clear([Drawing.Color]::Black)
                    $g.InterpolationMode = 'HighQualityBicubic'
                    $g.SmoothingMode     = 'HighQuality'
                    $g.PixelOffsetMode   = 'HighQuality'
                    $g.DrawImage($img, 0, 0, $Width, $h)
                }
                finally { $g.Dispose() }

                $codec = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
                $ep    = New-Object Drawing.Imaging.EncoderParameters(1)
                $ep.Param[0] = New-Object Drawing.Imaging.EncoderParameter([Drawing.Imaging.Encoder]::Quality, [long]80)
                $bmp.Save($dest, $codec, $ep)
            }
            finally { $bmp.Dispose() }
        }
        finally { $img.Dispose(); $ms.Dispose() }
        return $dest
    }
    catch { return $null }
}

function Set-UiProgress {
    param([string]$Text, [int]$Value = -1, [int]$Max = 0)
    $lblStatus.Text = $Text
    if ($Max -gt 0 -and $Value -ge 0) { Set-OverallProgress -Fraction ($Value / [double]$Max) }
    [Windows.Forms.Application]::DoEvents()
}

function Update-ProgressWidths {
    # Fill widths follow the track widths, so the bars keep their proportions when the window is resized.
    $progFill.Width = [int]($progTrack.Width * [double]$script:ProgStep)
    $ovFill.Width   = [int]($ovTrack.Width   * [double]$script:ProgAll)
}
function Set-Progress {
    # Top bar = the current step, thin bar underneath = the whole job. Each label reads "37%   ETA 00:12:34".
    param([double]$Step, [string]$StepEta = '', [double]$Overall = 0.0, [string]$OverallEta = '')
    $script:ProgStep = [Math]::Max(0.0, [Math]::Min(1.0, $Step))
    $script:ProgAll  = [Math]::Max(0.0, [Math]::Min(1.0, $Overall))
    Update-ProgressWidths
    $p1 = [int][Math]::Floor($script:ProgStep * 100); $p2 = [int][Math]::Floor($script:ProgAll * 100)
    $lblProg.Text = if ($StepEta)    { '{0}%   ETA {1}' -f $p1, $StepEta }    else { '{0}%' -f $p1 }
    $lblOv.Text   = if ($OverallEta) { 'Overall {0}%   ETA {1}' -f $p2, $OverallEta } else { 'Overall {0}%' -f $p2 }
}
function Set-OverallProgress {
    # Simple form for moments with only one number to show (start = 0, finished = 1).
    param([double]$Fraction, [string]$Eta = '')
    Set-Progress -Step $Fraction -StepEta $Eta -Overall $Fraction -OverallEta $Eta
}
function Update-EtaState {
    # Smoothed progress speed, re-measured about every 1.5 s so a burst of cache hits does not fool the estimate for long.
    param([hashtable]$St, [double]$Frac, [bool]$Cancelled)
    $tk = [Environment]::TickCount
    if ($null -eq $St.T) { $St.T = $tk; $St.F = $Frac }
    elseif (($tk - $St.T) -ge 1500) {
        $inst = ($Frac - $St.F) / (($tk - $St.T) / 1000.0)
        if ($inst -lt 0) { $inst = 0.0 }
        $St.R = if ($null -eq $St.R) { $inst } else { 0.7 * $St.R + 0.3 * $inst }
        $St.T = $tk; $St.F = $Frac
    }
    if ($Frac -ge 1.0) { return '00:00:00' }
    if ($Cancelled) { return '' }
    if ($Frac -gt 0 -and $null -ne $St.R -and $St.R -gt 1e-7) { return (Format-EtaClock ((1.0 - $Frac) / $St.R)) }
    '--:--:--'
}

function Format-EtaClock {
    param([double]$Seconds)
    if ($Seconds -lt 0 -or [double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds)) { return '--:--:--' }
    $t = [TimeSpan]::FromSeconds([Math]::Round($Seconds))
    '{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds
}

function New-MediaDashboard {
    param(
        [Parameter(Mandatory)][object[]]$Records,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$LibraryName = 'Media Library',
        [switch]$EmbedPosters
    )

    if (-not (Test-Path -LiteralPath $script:TemplatePath)) {
        throw "Dashboard template not found: $($script:TemplatePath)`nKeep dashboard-template.html next to this script."
    }

    $outDir   = Split-Path -Parent $OutFile
    $thumbDir = Join-Path $outDir 'thumbs'
    if (-not $EmbedPosters) { New-Item -Path $thumbDir -ItemType Directory -Force | Out-Null }

    $rows = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($r in $Records) {
        $i++
        if (($i % 10) -eq 0 -or $i -eq $Records.Count) { Set-UiProgress -Text "Preparing dashboard: $i of $($Records.Count)" -Value $i -Max $Records.Count }

        $row = [ordered]@{}
        foreach ($p in $r.PSObject.Properties) { if ($p.Name -ne 'PosterPath' -and $script:ClueNames -notcontains $p.Name) { $row[$p.Name] = $p.Value } }
        $row['Poster'] = ''

        if ($r.PosterPath -and (Test-Path -LiteralPath $r.PosterPath)) {
            $thumb = Get-PosterThumbnail -Source $r.PosterPath
            if ($thumb) {
                if ($EmbedPosters) {
                    $row['Poster'] = 'data:image/jpeg;base64,' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($thumb))
                }
                else {
                    $leaf = [IO.Path]::GetFileName($thumb)
                    $dest = Join-Path $thumbDir $leaf
                    if (-not (Test-Path -LiteralPath $dest)) { Copy-Item -LiteralPath $thumb -Destination $dest }
                    $row['Poster'] = 'thumbs/' + $leaf
                }
            }
        }
        $rows.Add([pscustomobject]$row)
    }

    $json = (ConvertTo-Json -InputObject $rows.ToArray() -Depth 4 -Compress).Replace('</', '<\/')
    $meta = ConvertTo-Json -Compress -InputObject @{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); library = $LibraryName }

    $html = [IO.File]::ReadAllText($script:TemplatePath, [Text.Encoding]::UTF8)
    $html = $html.Replace('__META__', $meta).Replace('__DATA__', $json)
    [IO.File]::WriteAllText($OutFile, $html, (New-Object Text.UTF8Encoding($false)))
}

function ConvertTo-DataTable {
    param([object[]]$Records)
    $t = New-Object System.Data.DataTable
    foreach ($f in $script:Fields) {
        [void]$t.Columns.Add((New-Object System.Data.DataColumn($f.Name, $script:TypeMap[$f.Type])))
    }
    foreach ($r in $Records) {
        $row = $t.NewRow()
        foreach ($f in $script:Fields) {
            $val = $r.($f.Name)
            if ($null -eq $val) { $row[$f.Name] = [DBNull]::Value; continue }
            try { $row[$f.Name] = [Convert]::ChangeType($val, $script:TypeMap[$f.Type]) } catch { $row[$f.Name] = [DBNull]::Value }
        }
        [void]$t.Rows.Add($row)
    }
    , $t
}
#endregion

#region ---------------------------------------------------------------- Embedded browser (WebView2)
function Test-WebView2Folder {
    param([string]$Folder)
    foreach ($n in @('Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.WinForms.dll', 'WebView2Loader.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Folder $n))) { return $false }
    }
    $true
}

function Install-WebView2Package {
    # Downloads the Microsoft.Web.WebView2 NuGet package and extracts the three files we need into $Folder.
    # Entries are matched by pattern (not exact path) so small package layout changes do not break it.
    param([Parameter(Mandatory)][string]$Folder)

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    try { [Net.WebRequest]::DefaultWebProxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials } catch { }
    $oldProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'          # the progress bar makes Invoke-WebRequest very slow in 5.1
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('webview2-' + [guid]::NewGuid().ToString('N') + '.nupkg')
    try {
        $base  = 'https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2'
        $index = Invoke-RestMethod -Uri "$base/index.json"
        $ver   = @($index.versions | Where-Object { $_ -notmatch '-' }) | Select-Object -Last 1
        if (-not $ver) { throw 'No stable WebView2 package version was found on nuget.org.' }
        Invoke-WebRequest -Uri "$base/$ver/microsoft.web.webview2.$ver.nupkg" -OutFile $tmp -UseBasicParsing

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($tmp)
        try {
            $names = @($zip.Entries | ForEach-Object { $_.FullName })
            $core  = $names | Where-Object { $_ -match '^lib/net4\d+/Microsoft\.Web\.WebView2\.Core\.dll$' } | Sort-Object | Select-Object -First 1
            if (-not $core) { throw "Package $ver has no .NET Framework build of WebView2.Core." }
            $wf     = $core.Substring(0, $core.LastIndexOf('/')) + '/Microsoft.Web.WebView2.WinForms.dll'
            $arch   = if ([Environment]::Is64BitProcess) { 'x64' } else { 'x86' }
            $loader = @("runtimes/win-$arch/native/WebView2Loader.dll", "build/native/$arch/WebView2Loader.dll") |
                Where-Object { $names -contains $_ } | Select-Object -First 1
            if (($names -notcontains $wf) -or -not $loader) { throw "Package $ver does not contain the expected WebView2 files." }

            New-Item -Path $Folder -ItemType Directory -Force | Out-Null
            $map = @{}
            $map[$core]   = 'Microsoft.Web.WebView2.Core.dll'
            $map[$wf]     = 'Microsoft.Web.WebView2.WinForms.dll'
            $map[$loader] = 'WebView2Loader.dll'
            foreach ($entry in $zip.Entries) {
                if ($map.ContainsKey($entry.FullName)) {
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $Folder $map[$entry.FullName]), $true)
                }
            }
        }
        finally { $zip.Dispose() }
    }
    finally {
        $ProgressPreference = $oldProgress
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Initialize-WebView2 {
    # Returns $true when the embedded browser can be used. Never throws; the reason is kept in $script:WebView2Error.
    if ($script:WebView2Ready)  { return $true }
    if ($script:WebView2Failed) { return $false }
    try {
        $targets = @($script:LibFolder, (Join-Path $script:AppData 'WebView2'))
        $dir = $targets | Where-Object { Test-WebView2Folder $_ } | Select-Object -First 1
        if (-not $dir) {
            Set-UiProgress -Text 'Downloading the WebView2 components (one-time download, a few MB)...'
            foreach ($t in $targets) {
                try { Install-WebView2Package -Folder $t; if (Test-WebView2Folder $t) { $dir = $t; break } }
                catch { $script:WebView2Error = $_.Exception.Message }
            }
        }
        if (-not $dir) { throw "Could not get the WebView2 components. $($script:WebView2Error)" }

        # Pre-load the native loader so the managed wrapper can find it regardless of search paths.
        $env:PATH = "$dir;$env:PATH"
        if (-not ('Win32.NativeLoader' -as [type])) {
            Add-Type -Namespace Win32 -Name NativeLoader -MemberDefinition '[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern IntPtr LoadLibrary(string path);'
        }
        [void][Win32.NativeLoader]::LoadLibrary((Join-Path $dir 'WebView2Loader.dll'))
        Add-Type -Path (Join-Path $dir 'Microsoft.Web.WebView2.Core.dll')
        Add-Type -Path (Join-Path $dir 'Microsoft.Web.WebView2.WinForms.dll')

        $runtime = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::GetAvailableBrowserVersionString()
        if (-not $runtime) { throw 'The Microsoft Edge WebView2 Runtime is not installed.' }
        $script:WebView2Ready = $true
        return $true
    }
    catch {
        $script:WebView2Failed = $true
        $script:WebView2Error  = $_.Exception.Message
        return $false
    }
}

function Switch-ToExternalDashboard {
    # Called if the embedded browser fails after it was created.
    param([string]$Reason)
    $script:WebView2Failed = $true
    $script:WebView2Error  = $Reason
    if ($null -ne $script:wv) {
        try { $dashHost.Controls.Remove($script:wv); $script:wv.Dispose() } catch { }
        $script:wv = $null
    }
    Set-View 'grid'
    Set-UiProgress -Text 'The embedded view could not start - opened the dashboard in your browser instead.'
    if (Test-Path -LiteralPath $script:LiveDashboard) { Start-Process $script:LiveDashboard }
}

function Show-DashboardPane {
    param([Parameter(Mandatory)][string]$Url)
    $script:DashboardUrl = $Url
    if ($null -eq $script:wv) {
        $wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2
        $wv.Dock = 'Fill'
        try { $wv.DefaultBackgroundColor = $script:cBg } catch { }
        # Without a writable user-data folder WebView2 tries to write next to powershell.exe and fails.
        $props = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
        $props.UserDataFolder = Join-Path $script:AppData 'WebView2Data'
        $wv.CreationProperties = $props
        $wv.Add_CoreWebView2InitializationCompleted({
            param($sender, $e)
            if ($e.IsSuccess) { $sender.CoreWebView2.Navigate($script:DashboardUrl) }
            else { Switch-ToExternalDashboard -Reason $e.InitializationException.Message }
        })
        $dashHost.Controls.Add($wv)
        $script:wv = $wv
        [void]$wv.EnsureCoreWebView2Async($null)
    }
    elseif ($null -ne $script:wv.CoreWebView2) {
        $script:wv.CoreWebView2.Navigate($Url)
    }
    # else: still initialising - the completed handler navigates to the latest $script:DashboardUrl
}
#endregion

#region ---------------------------------------------------------------- Theme + control factories
function RGB { param([int]$r, [int]$g, [int]$b) [Drawing.Color]::FromArgb($r, $g, $b) }

$script:cBg      = RGB 11 14 26
$script:cPanel   = RGB 19 24 48
$script:cPanel2  = RGB 26 32 64
$script:cLine    = RGB 35 43 77
$script:cText    = RGB 232 235 247
$script:cMuted   = RGB 139 147 181
$script:cAccent  = RGB 108 140 255
$script:cAccent2 = RGB 176 108 255

$script:fontBase  = New-Object Drawing.Font('Segoe UI', 9.5)
$script:fontSmall = New-Object Drawing.Font('Segoe UI', 8.5)
$script:fontBold  = New-Object Drawing.Font('Segoe UI Semibold', 9.5)
$script:fontTitle = New-Object Drawing.Font('Segoe UI Semibold', 15)
$script:fontBig   = New-Object Drawing.Font('Segoe UI Semibold', 16)

function New-FlatButton {
    param([string]$Text, [int]$Width, [ValidateSet('primary', 'secondary')][string]$Kind = 'secondary')
    $b = New-Object Windows.Forms.Button
    $b.Text = $Text
    $b.Size = New-Object Drawing.Size($Width, 34)
    $b.FlatStyle = 'Flat'
    $b.Cursor = [Windows.Forms.Cursors]::Hand
    $b.Font = $script:fontBold
    $b.UseVisualStyleBackColor = $false
    if ($Kind -eq 'primary') {
        $b.BackColor = $script:cAccent
        $b.ForeColor = [Drawing.Color]::White
        $b.FlatAppearance.BorderSize = 0
        $b.FlatAppearance.MouseOverBackColor = RGB 132 162 255
        $b.FlatAppearance.MouseDownBackColor = RGB 88 118 235
    }
    else {
        $b.BackColor = $script:cPanel2
        $b.ForeColor = $script:cText
        $b.FlatAppearance.BorderSize = 1
        $b.FlatAppearance.BorderColor = $script:cLine
        $b.FlatAppearance.MouseOverBackColor = RGB 40 49 94
        $b.FlatAppearance.MouseDownBackColor = RGB 32 40 80
    }
    $b
}

function New-Label {
    param([string]$Text, [int]$X, [int]$Y, $Color = $script:cText, $Font = $script:fontBase)
    $l = New-Object Windows.Forms.Label
    $l.Text = $Text; $l.AutoSize = $true; $l.Location = New-Object Drawing.Point($X, $Y)
    $l.ForeColor = $Color; $l.BackColor = [Drawing.Color]::Transparent; $l.Font = $Font
    $l
}

if (-not ('DarkCheckBox' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
public class DarkCheckBox : CheckBox {
    public Color BoxFill = Color.FromArgb(26, 32, 64);
    public Color BoxBorder = Color.FromArgb(120, 130, 170);
    public Color TickColor = Color.FromArgb(118, 185, 0);   // NVIDIA green
    public DarkCheckBox() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
    }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.Clear(Parent != null ? Parent.BackColor : BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        int size = 16, top = (Height - size) / 2;
        Rectangle box = new Rectangle(1, top, size - 1, size - 1);
        using (GraphicsPath gp = new GraphicsPath()) {
            int r = 4, d = r * 2;
            gp.AddArc(box.X, box.Y, d, d, 180, 90);
            gp.AddArc(box.Right - d, box.Y, d, d, 270, 90);
            gp.AddArc(box.Right - d, box.Bottom - d, d, d, 0, 90);
            gp.AddArc(box.X, box.Bottom - d, d, d, 90, 90);
            gp.CloseFigure();
            using (SolidBrush b = new SolidBrush(BoxFill)) g.FillPath(b, gp);
            using (Pen p = new Pen(!Enabled ? Color.FromArgb(70, 78, 110) : (Checked ? TickColor : BoxBorder), 1.5f)) g.DrawPath(p, gp);
        }
        if (Checked) {
            using (Pen p = new Pen(Enabled ? TickColor : Color.FromArgb(90, 98, 130), 2.4f)) {
                p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; p.LineJoin = LineJoin.Round;
                g.DrawLines(p, new PointF[] {
                    new PointF(box.X + 3.5f, top + 8.5f),
                    new PointF(box.X + 6.5f, top + 11.5f),
                    new PointF(box.X + 12.0f, top + 4.5f) });
            }
        }
        TextRenderer.DrawText(g, Text, Font, new Rectangle(size + 7, 0, Width - size - 7, Height), Enabled ? ForeColor : Color.FromArgb(100, 108, 140),
            TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
    }
    public override Size GetPreferredSize(Size proposedSize) {
        Size t = TextRenderer.MeasureText(Text, Font);
        return new Size(t.Width + 16 + 12, Math.Max(t.Height, 18) + 2);
    }
}
public class BufferedPanel : Panel {
    public BufferedPanel() {
        SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
    }
}
public class DarkRadio : RadioButton {
    public Color BoxFill = Color.FromArgb(26, 32, 64);
    public Color BoxBorder = Color.FromArgb(120, 130, 170);
    public Color DotColor = Color.FromArgb(118, 185, 0);    // NVIDIA green
    public DarkRadio() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
    }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.Clear(Parent != null ? Parent.BackColor : BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        int size = 16, top = (Height - size) / 2;
        Rectangle ring = new Rectangle(1, top, size - 1, size - 1);
        using (SolidBrush b = new SolidBrush(BoxFill)) g.FillEllipse(b, ring);
        using (Pen p = new Pen(Checked ? DotColor : BoxBorder, 1.5f)) g.DrawEllipse(p, ring);
        if (Checked) {
            using (SolidBrush b = new SolidBrush(DotColor)) g.FillEllipse(b, new Rectangle(ring.X + 4, ring.Y + 4, ring.Width - 8, ring.Height - 8));
        }
        TextRenderer.DrawText(g, Text, Font, new Rectangle(size + 7, 0, Width - size - 7, Height), ForeColor,
            TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
    }
    public override Size GetPreferredSize(Size proposedSize) {
        Size t = TextRenderer.MeasureText(Text, Font);
        return new Size(t.Width + 16 + 12, Math.Max(t.Height, 18) + 2);
    }
}
'@
}

function New-FlatRadio {
    param([string]$Text, [int]$X, [int]$Y, [bool]$Checked = $false)
    $r = New-Object DarkRadio
    $r.Text = $Text; $r.AutoSize = $true; $r.Location = New-Object Drawing.Point($X, $Y)
    $r.ForeColor = $script:cText; $r.Font = $script:fontBase
    $r.Checked = $Checked; $r.Cursor = [Windows.Forms.Cursors]::Hand
    $r
}

function New-FlatCheckBox {
    param([string]$Text, [int]$X, [int]$Y, [bool]$Checked = $false)
    $c = New-Object DarkCheckBox
    $c.Text = $Text; $c.AutoSize = $true; $c.Location = New-Object Drawing.Point($X, $Y)
    $c.ForeColor = $script:cText; $c.Font = $script:fontBase
    $c.Checked = $Checked; $c.Cursor = [Windows.Forms.Cursors]::Hand
    $c
}

function Set-DarkGridStyle {
    param([Windows.Forms.DataGridView]$Grid, [bool]$ShowHeaders = $true)
    $Grid.BackgroundColor = $script:cBg
    $Grid.BorderStyle = 'None'
    $Grid.GridColor = $script:cLine
    $Grid.CellBorderStyle = 'SingleHorizontal'
    $Grid.EnableHeadersVisualStyles = $false
    $Grid.RowHeadersVisible = $false
    $Grid.AllowUserToAddRows = $false
    $Grid.AllowUserToDeleteRows = $false
    $Grid.AllowUserToResizeRows = $false
    $Grid.ReadOnly = $true
    $Grid.SelectionMode = 'FullRowSelect'
    $Grid.Font = $script:fontBase
    $Grid.RowTemplate.Height = 28
    $Grid.ColumnHeadersVisible = $ShowHeaders
    $Grid.ColumnHeadersBorderStyle = 'None'
    $Grid.ColumnHeadersHeightSizeMode = 'DisableResizing'
    $Grid.ColumnHeadersHeight = 34
    $Grid.ColumnHeadersDefaultCellStyle.BackColor = $script:cPanel2
    $Grid.ColumnHeadersDefaultCellStyle.ForeColor = $script:cMuted
    $Grid.ColumnHeadersDefaultCellStyle.Font = $script:fontBold
    $Grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $script:cPanel2
    $Grid.DefaultCellStyle.BackColor = $script:cBg
    $Grid.DefaultCellStyle.ForeColor = $script:cText
    $Grid.DefaultCellStyle.SelectionBackColor = RGB 49 66 128
    $Grid.DefaultCellStyle.SelectionForeColor = [Drawing.Color]::White
    $Grid.DefaultCellStyle.Padding = New-Object Windows.Forms.Padding(6, 0, 6, 0)
    $Grid.AlternatingRowsDefaultCellStyle.BackColor = RGB 15 19 38
    $Grid.AlternatingRowsDefaultCellStyle.SelectionBackColor = RGB 49 66 128
    # DoubleBuffered is protected - flip it with reflection to stop flicker on big grids
    $prop = $Grid.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic')
    if ($prop) { $prop.SetValue($Grid, $true, $null) }
}

function Format-Runtime {
    # Minutes (double) -> H:MM:SS ; 0 or blank -> empty
    param($Minutes)
    $m = 0.0
    if (-not [double]::TryParse([string]$Minutes, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$m)) { return '' }
    if ($m -le 0) { return '' }
    $total = [int][math]::Round($m * 60)
    '{0}:{1:00}:{2:00}' -f [math]::Floor($total / 3600), [math]::Floor(($total % 3600) / 60), ($total % 60)
}

function Format-RecordValue {
    param($Value, [string]$Name = '')
    if ($null -eq $Value) { return '' }
    if ($Name -eq 'RuntimeMin') { return (Format-Runtime $Value) }
    if ($Value -is [bool]) { if ($Value) { return 'Yes' } else { return 'No' } }
    [string]$Value
}
#endregion

#region ---------------------------------------------------------------- Build the window
$script:ScanResults  = @()
$script:DetailItems  = @()
$script:PosterStream = $null
$script:Settings     = Read-Settings

$form = New-Object Windows.Forms.Form
$form.Text = 'Modern Media Library Manager'
$form.ClientSize = New-Object Drawing.Size(1280, 780)
$form.MinimumSize = New-Object Drawing.Size(1200, 680)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $script:cBg
$form.ForeColor = $script:cText
$form.Font = $script:fontBase

# ---- header ---------------------------------------------------------------
$header = New-Object Windows.Forms.Panel
$header.Dock = 'Top'; $header.Height = 70; $header.Width = 1280; $header.BackColor = $script:cPanel

$logo = New-Object Windows.Forms.Panel
$logo.Location = New-Object Drawing.Point(24, 15); $logo.Size = New-Object Drawing.Size(40, 40)
$logo.Add_Paint({
    param($s, $e)
    $rect = New-Object Drawing.Rectangle(0, 0, $s.Width, $s.Height)
    $brush = New-Object Drawing.Drawing2D.LinearGradientBrush($rect, $script:cAccent, $script:cAccent2, 45.0)
    $e.Graphics.SmoothingMode = 'AntiAlias'
    $e.Graphics.FillEllipse($brush, 0, 0, $s.Width - 1, $s.Height - 1)
    $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $e.Graphics.DrawString('M', $script:fontBig, [Drawing.Brushes]::White, (New-Object Drawing.RectangleF(0, 0, $s.Width, $s.Height)), $sf)
    $brush.Dispose()
})
$lblTitle = New-Label 'Modern Media Library Manager' 76 12 $script:cText $script:fontTitle
$lblSub   = New-Label 'Plex / MediaInfo + artwork  >  interactive dashboard' 78 41 $script:cMuted $script:fontSmall
$btnGear = New-FlatButton ([string][char]0x2699) 40 'secondary'
$btnGear.Font = New-Object Drawing.Font('Segoe UI Symbol', 14)
$btnGear.Padding = New-Object Windows.Forms.Padding(0)
$btnGear.Location = New-Object Drawing.Point(1216, 18); $btnGear.Anchor = 'Top,Right'
$header.Controls.AddRange(@($logo, $lblTitle, $lblSub, $btnGear))

# ---- control card ---------------------------------------------------------
$controls = New-Object Windows.Forms.Panel
# NOTE: every panel that hosts anchored children gets its real width BEFORE the children are added.
# WinForms records anchor distances against the parent's size at that moment; a default 200px-wide panel
# would push right-anchored controls (Browse, Scan, ...) off the edge once the panel stretches.
$controls.Dock = 'Top'; $controls.Height = 122; $controls.Width = 1280; $controls.BackColor = $script:cBg

$lblSource = New-Label 'SOURCE' 24 14 $script:cMuted $script:fontSmall
$radPlex   = New-FlatRadio 'Plex server' 24 32
$radLocal  = New-FlatRadio 'Local folder' 24 54

$lblFolder = New-Label 'LIBRARY FOLDER' 200 14 $script:cMuted $script:fontSmall
$txtFolder = New-Object Windows.Forms.TextBox
$txtFolder.Location = New-Object Drawing.Point(200, 36)
$txtFolder.Size = New-Object Drawing.Size(924, 28)
$txtFolder.Anchor = 'Top,Left,Right'
$txtFolder.BackColor = $script:cPanel2; $txtFolder.ForeColor = $script:cText
$txtFolder.BorderStyle = 'FixedSingle'; $txtFolder.Font = New-Object Drawing.Font('Segoe UI', 11)
$btnBrowse = New-FlatButton 'Browse...' 110 'secondary'
$btnBrowse.Location = New-Object Drawing.Point(1146, 35); $btnBrowse.Anchor = 'Top,Right'

# Local scans read several files at once; this is how many (Plex scans do not use it).
$lblPar = New-Label 'PARALLEL FILES' 924 13 $script:cMuted $script:fontSmall
$lblPar.Anchor = 'Top,Right'
$nudPar = New-Object Windows.Forms.NumericUpDown
$nudPar.Minimum = 1; $nudPar.Maximum = 12; $nudPar.Value = 4
$nudPar.Location = New-Object Drawing.Point(1040, 8); $nudPar.Size = New-Object Drawing.Size(90, 24)
$nudPar.Anchor = 'Top,Right'
$nudPar.BackColor = $script:cPanel2; $nudPar.ForeColor = $script:cText; $nudPar.BorderStyle = 'FixedSingle'
$btnWorkers = New-FlatButton 'Workers' 110 'secondary'
$btnWorkers.Size = New-Object Drawing.Size(110, 24); $btnWorkers.Font = $script:fontSmall
$btnWorkers.Location = New-Object Drawing.Point(1146, 8); $btnWorkers.Anchor = 'Top,Right'

$chkRebuild = New-FlatCheckBox 'Rebuild local cache' 24 82
$chkVideo   = New-FlatCheckBox 'Video' 190 82 $true
$chkAudio   = New-FlatCheckBox 'Audio' 262 82 $true
$chkMovies  = New-FlatCheckBox 'Movies' 190 82 $true
$chkShows   = New-FlatCheckBox 'TV Shows (coming soon)' 270 82 $false
$chkEmbed   = New-FlatCheckBox 'Embed posters' 334 82
$chkFel     = New-FlatCheckBox 'FEL / MEL probe' 470 82
$tip = New-Object Windows.Forms.ToolTip
$tip.SetToolTip($chkFel, "MediaInfo and Plex cannot tell Dolby Vision FEL from MEL.`nWith this on, dual-layer files are sampled with ffmpeg + dovi_tool.`nPut ffmpeg.exe and dovi_tool.exe in the lib folder (or on PATH).`nWith Plex, the file must also be reachable from this PC at the path Plex reports (e.g. a UNC share).")
$tip.SetToolTip($chkEmbed, 'Saved HTML dashboards carry their posters inside the file (bigger, but a single file).')
$tip.SetToolTip($chkRebuild, 'Ignore everything saved from earlier scans and read it all again.')
$tip.SetToolTip($btnGear, 'Settings')
$tip.SetToolTip($radPlex, 'Read the library from your Plex server (fast: Plex has already analysed every file).')
$tip.SetToolTip($radLocal, 'Scan a folder with MediaInfo (slower: every file is opened).')

$btnScan     = New-FlatButton 'Scan Media' 130 'primary'
$btnDash     = New-FlatButton 'Dashboard' 120 'primary'
$btnSaveHtml = New-FlatButton 'Save HTML' 110 'secondary'
$btnExport   = New-FlatButton 'Export CSV' 100 'secondary'
$btnCancel   = New-FlatButton 'Cancel' 80 'secondary'
$btnCancel.Enabled = $false
$x = 1256
foreach ($b in @($btnScan, $btnDash, $btnSaveHtml, $btnExport, $btnCancel)) {
    $x -= ($b.Width + 8)
    $b.Location = New-Object Drawing.Point($x, 76); $b.Anchor = 'Top,Right'
}
$controls.Controls.AddRange(@($lblSource, $radPlex, $radLocal, $lblFolder, $txtFolder, $btnBrowse, $chkRebuild, $chkVideo, $chkAudio, $chkMovies, $chkShows, $chkEmbed, $chkFel, $lblPar, $nudPar, $btnWorkers, $btnScan, $btnDash, $btnSaveHtml, $btnExport, $btnCancel))

# remembered options (the cache-rebuild box is deliberately NOT remembered)
$chkVideo.Checked  = [bool]$script:Settings['Video']
$chkAudio.Checked  = [bool]$script:Settings['Audio']
$chkMovies.Checked = [bool]$script:Settings['PlexMovies']
$chkShows.Checked  = $false; $chkShows.Enabled = $false; $chkShows.Cursor = [Windows.Forms.Cursors]::Default     # greyed out until TV support is finished
$chkEmbed.Checked  = [bool]$script:Settings['EmbedPosters']
$chkFel.Checked    = [bool]$script:Settings['DetectFel']
try { $nudPar.Value = [Math]::Max(1, [Math]::Min(12, [int]$script:Settings['Parallel'])) } catch { $nudPar.Value = 4 }
$tip.SetToolTip($nudPar, "How many files a local scan reads at the same time (can be changed during a scan).`n4 suits most NAS shares; raise it while watching the progress speed, or use 1 if the share struggles.")
$script:PlexToken  = Unprotect-PlexToken ([string]$script:Settings['PlexTokenProtected'])
$script:TmdbKey    = Unprotect-PlexToken ([string]$script:Settings['TmdbKeyProtected'])
$script:OmdbKey    = Unprotect-PlexToken ([string]$script:Settings['OmdbKeyProtected'])

# ---- confirmation before a full cache rebuild, and the gear-button settings --------------------
function New-DialogForm {
    param([string]$Title, [int]$Width, [int]$Height)
    $d = New-Object Windows.Forms.Form
    $d.Text = $Title; $d.ClientSize = New-Object Drawing.Size($Width, $Height)
    $d.StartPosition = 'CenterParent'; $d.BackColor = $script:cPanel; $d.ForeColor = $script:cText; $d.Font = $script:fontBase
    $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false; $d.ShowInTaskbar = $false
    $d
}

function Show-RebuildWarning {
    # Returns $true when the user confirms. "Do not display this message again" is remembered (and can be undone from the gear button).
    $dlg  = New-DialogForm 'Rebuild the cache?' 470 236
    $head = New-Label 'This is a thorough scan' 24 18 $script:cText $script:fontBold
    $msg  = New-Object Windows.Forms.Label
    $msg.AutoSize = $false; $msg.Location = New-Object Drawing.Point(24, 48); $msg.Size = New-Object Drawing.Size(422, 90)
    $msg.ForeColor = $script:cMuted; $msg.BackColor = [Drawing.Color]::Transparent; $msg.Font = $script:fontBase
    $msg.Text = "Rebuilding the cache throws away everything saved from earlier scans and reads every file again from scratch. On a large library this can take a long time to complete.`n`nClick OK only if you are sure."
    $chk  = New-FlatCheckBox 'Do not display this message again' 24 146
    $ok     = New-FlatButton 'OK' 100 'primary'
    $cancel = New-FlatButton 'Cancel' 100 'secondary'
    $ok.Location     = New-Object Drawing.Point(240, 186); $ok.DialogResult     = [Windows.Forms.DialogResult]::OK
    $cancel.Location = New-Object Drawing.Point(350, 186); $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.AddRange(@($head, $msg, $chk, $ok, $cancel))
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    $confirmed = ($dlg.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK)
    if ($confirmed -and $chk.Checked) { $script:Settings['WarnRebuild'] = $false; Save-Settings }
    $dlg.Dispose()
    $confirmed
}

function Show-SettingsDialog {
    $dlg = New-DialogForm 'Settings' 560 560
    $head1 = New-Label 'Warnings' 24 18 $script:cText $script:fontBold
    $chk   = New-FlatCheckBox 'Warn me before rebuilding the cache' 24 46 ([bool]$script:Settings['WarnRebuild'])
    $note  = New-Label 'Shows a confirmation when you tick "Rebuild local cache".' 44 72 $script:cMuted $script:fontSmall

    $head2 = New-Label 'Online lookups (Fetch info)' 24 108 $script:cText $script:fontBold
    $lbl1  = New-Label 'TMDB API key (v3 key or v4 read token)' 24 138 $script:cMuted $script:fontSmall
    $txtT  = New-Object Windows.Forms.TextBox
    $txtT.Location = New-Object Drawing.Point(24, 158); $txtT.Size = New-Object Drawing.Size(512, 26)
    $txtT.BackColor = $script:cPanel2; $txtT.ForeColor = $script:cText; $txtT.BorderStyle = 'FixedSingle'
    $txtT.UseSystemPasswordChar = $true; $txtT.Text = [string]$script:TmdbKey
    $lnk = New-Object Windows.Forms.LinkLabel
    $lnk.Text = 'Get a free TMDB key'; $lnk.AutoSize = $true; $lnk.Location = New-Object Drawing.Point(24, 188)
    $lnk.LinkColor = $script:cAccent; $lnk.ActiveLinkColor = $script:cAccent2; $lnk.BackColor = [Drawing.Color]::Transparent
    $lnk.Add_LinkClicked({ Start-Process 'https://www.themoviedb.org/settings/api' })
    $lbl2  = New-Label 'OMDb API key (optional: Rotten Tomatoes critic score and domestic box office; free tier is 1,000 requests a day)' 24 216 $script:cMuted $script:fontSmall
    $txtO  = New-Object Windows.Forms.TextBox
    $txtO.Location = New-Object Drawing.Point(24, 236); $txtO.Size = New-Object Drawing.Size(512, 26)
    $txtO.BackColor = $script:cPanel2; $txtO.ForeColor = $script:cText; $txtO.BorderStyle = 'FixedSingle'
    $txtO.UseSystemPasswordChar = $true; $txtO.Text = [string]$script:OmdbKey
    $lnk2 = New-Object Windows.Forms.LinkLabel
    $lnk2.Text = 'Get a free OMDb key'; $lnk2.AutoSize = $true; $lnk2.Location = New-Object Drawing.Point(24, 266)
    $lnk2.LinkColor = $script:cAccent; $lnk2.ActiveLinkColor = $script:cAccent2; $lnk2.BackColor = [Drawing.Color]::Transparent
    $lnk2.Add_LinkClicked({ Start-Process 'https://www.omdbapi.com/apikey.aspx' })
    $keyNote = New-Label 'Keys are stored encrypted for this Windows user only.' 160 188 $script:cMuted $script:fontSmall

    $head3 = New-Label 'Credits' 24 306 $script:cText $script:fontBold
    $y = 332; $credX = 24
    $logoPath = Join-Path $script:LibFolder 'tmdb-logo.png'      # drop the official logo from themoviedb.org/about/logos-attribution here
    $pic = $null
    if (Test-Path -LiteralPath $logoPath) {
        try {
            $bytes = [IO.File]::ReadAllBytes($logoPath)
            $pic = New-Object Windows.Forms.PictureBox
            $pic.Image = [Drawing.Image]::FromStream((New-Object IO.MemoryStream(, $bytes)))
            $pic.SizeMode = 'Zoom'; $pic.Location = New-Object Drawing.Point(24, $y); $pic.Size = New-Object Drawing.Size(66, 48)
            $credX = 104
        }
        catch { $pic = $null }
    }
    $cred = New-Object Windows.Forms.Label
    $cred.AutoSize = $false; $cred.Location = New-Object Drawing.Point($credX, $y); $cred.Size = New-Object Drawing.Size((536 - $credX), (480 - $y))
    $cred.ForeColor = $script:cMuted; $cred.BackColor = [Drawing.Color]::Transparent; $cred.Font = $script:fontSmall
    $cred.Text = "This product uses the TMDB API but is not endorsed or certified by TMDB.`nRatings data courtesy of IMDb (imdb.com), used under its non-commercial data licence.`nRotten Tomatoes scores and box office come from the OMDb API (omdbapi.com, CC BY-NC 4.0). Rotten Tomatoes is a trademark of its owners; the tomato and popcorn icons in the grid are our own drawings.`nCinemaScore, audience scores and opening-weekend figures have no free public source - enter them by hand."

    $ok     = New-FlatButton 'OK' 100 'primary'
    $cancel = New-FlatButton 'Cancel' 100 'secondary'
    $ok.Location     = New-Object Drawing.Point(330, 508); $ok.DialogResult     = [Windows.Forms.DialogResult]::OK
    $cancel.Location = New-Object Drawing.Point(436, 508); $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.AddRange(@($head1, $chk, $note, $head2, $lbl1, $txtT, $lnk, $keyNote, $lbl2, $txtO, $lnk2, $head3, $cred, $ok, $cancel))
    if ($null -ne $pic) { $dlg.Controls.Add($pic) }
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    if ($dlg.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) {
        $script:Settings['WarnRebuild'] = [bool]$chk.Checked
        $script:TmdbKey = $txtT.Text.Trim(); $script:OmdbKey = $txtO.Text.Trim()
        $script:Settings['TmdbKeyProtected'] = Protect-PlexToken $script:TmdbKey
        $script:Settings['OmdbKeyProtected'] = Protect-PlexToken $script:OmdbKey
        Save-Settings
    }
    if ($null -ne $pic) { $pic.Image.Dispose() }
    $dlg.Dispose()
}

function Show-FetchDialog {
    # Returns @{ Overwrite = bool } when the user confirms, otherwise $null.
    param([int]$Count, [string]$Scope)
    $dlg  = New-DialogForm 'Fetch info' 500 276
    $head = New-Label ("Fetch info for {0} title(s)?" -f $Count) 24 18 $script:cText $script:fontBold
    $msg  = New-Object Windows.Forms.Label
    $msg.AutoSize = $false; $msg.Location = New-Object Drawing.Point(24, 48); $msg.Size = New-Object Drawing.Size(452, 100)
    $msg.ForeColor = $script:cMuted; $msg.BackColor = [Drawing.Color]::Transparent; $msg.Font = $script:fontBase
    $omdb = if ($script:OmdbKey) { 'and OMDb (Rotten Tomatoes critic score, domestic box office)' } else { '(add an OMDb key under the gear button to also get Rotten Tomatoes and domestic box office)' }
    $msg.Text = "The $Scope will be looked up on TMDB (year, genre, rating, studio, director, certification, worldwide box office), the IMDb ratings file $omdb.`nIt runs in the background and can be cancelled. Movies only for now; TV titles are skipped."
    $chk  = New-FlatCheckBox 'Replace existing values (otherwise only empty fields are filled)' 24 160
    $ok     = New-FlatButton 'Fetch' 100 'primary'
    $cancel = New-FlatButton 'Cancel' 100 'secondary'
    $ok.Location     = New-Object Drawing.Point(274, 222); $ok.DialogResult     = [Windows.Forms.DialogResult]::OK
    $cancel.Location = New-Object Drawing.Point(380, 222); $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.AddRange(@($head, $msg, $chk, $ok, $cancel))
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    $res = $null
    if ($dlg.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) { $res = @{ Overwrite = [bool]$chk.Checked } }
    $dlg.Dispose()
    $res
}

$script:RebuildGuard = $false
$chkRebuild.Add_CheckedChanged({
    if ($script:RebuildGuard -or -not $chkRebuild.Checked) { return }
    if (-not [bool]$script:Settings['WarnRebuild']) { return }
    if (-not (Show-RebuildWarning)) {
        $script:RebuildGuard = $true
        $chkRebuild.Checked = $false
        $script:RebuildGuard = $false
    }
})
$btnGear.Add_Click({ Show-SettingsDialog })

# Source switch: the text box holds the Plex address in Plex mode and the folder path in Local mode.
$script:CurrentSource = ''
function Update-OptionLayout {
    # Lays the visible option boxes out left to right. The list is passed in explicitly because Control.Visible
    # reports $false for every child until the window itself is shown.
    param([bool]$Plex)
    $x = 24
    $list = if ($Plex) { @($chkRebuild, $chkMovies, $chkShows, $chkEmbed, $chkFel) } else { @($chkRebuild, $chkVideo, $chkAudio, $chkEmbed, $chkFel) }
    foreach ($c in $list) {
        $c.Size     = $c.GetPreferredSize([Drawing.Size]::Empty)
        $c.Location = New-Object Drawing.Point($x, 82)
        $x += $c.Width + 12
    }
}
function Set-SourceMode {
    param([bool]$Plex)
    if     ($script:CurrentSource -eq 'Plex')  { $script:Settings['PlexUrl']    = $txtFolder.Text.Trim() }
    elseif ($script:CurrentSource -eq 'Local') { $script:Settings['LastFolder'] = $txtFolder.Text.Trim() }
    $script:CurrentSource = if ($Plex) { 'Plex' } else { 'Local' }

    $lblFolder.Text   = if ($Plex) { 'PLEX SERVER ADDRESS' } else { 'LIBRARY FOLDER' }
    $txtFolder.Text   = if ($Plex) { [string]$script:Settings['PlexUrl'] } else { [string]$script:Settings['LastFolder'] }
    $btnBrowse.Text   = if ($Plex) { 'Token...' } else { 'Browse...' }
    $chkVideo.Visible = -not $Plex; $chkAudio.Visible = -not $Plex
    $chkMovies.Visible = $Plex;     $chkShows.Visible = $Plex
    $lblPar.Visible = -not $Plex;   $nudPar.Visible = -not $Plex;   $btnWorkers.Visible = -not $Plex
    Update-OptionLayout -Plex $Plex
    $script:DashboardStale = $true
}

# ---- status bar -----------------------------------------------------------
$statusBar = New-Object Windows.Forms.Panel
$statusBar.Dock = 'Bottom'; $statusBar.Height = 76; $statusBar.Width = 1280; $statusBar.BackColor = $script:cPanel
$lblStatus = New-Label 'Ready. Pick a source and click Scan Media.' 24 7 $script:cMuted $script:fontBase
$progTrack = New-Object Windows.Forms.Panel
$progTrack.Location = New-Object Drawing.Point(24, 30); $progTrack.Size = New-Object Drawing.Size(1000, 12)
$progTrack.Anchor = 'Top,Left,Right'; $progTrack.BackColor = $script:cPanel2
$progFill = New-Object BufferedPanel
$progFill.Dock = 'None'; $progFill.Location = New-Object Drawing.Point(0, 0); $progFill.Size = New-Object Drawing.Size(0, 12)
$progFill.BackColor = $script:cAccent
# Rainbow: the colours are laid across the WHOLE track and the fill just reveals them, so the bar shifts red -> violet as it grows.
$script:RainbowColors = [Drawing.Color[]]@(
    [Drawing.Color]::FromArgb(255, 59, 48), [Drawing.Color]::FromArgb(255, 149, 0), [Drawing.Color]::FromArgb(255, 214, 10),
    [Drawing.Color]::FromArgb(52, 199, 89), [Drawing.Color]::FromArgb(50, 173, 230), [Drawing.Color]::FromArgb(10, 132, 255),
    [Drawing.Color]::FromArgb(175, 82, 222))
$script:RainbowStops = [single[]]@(0.0, 0.17, 0.33, 0.5, 0.67, 0.83, 1.0)
$script:ProgStep = 0.0; $script:ProgAll = 0.0
$paintRainbow = {
    param($sender, $e)
    if ($sender.Width -le 0) { return }
    $full = [Math]::Max(2, $sender.Parent.Width)
    $rect = New-Object Drawing.Rectangle(0, 0, $full, $sender.Height)
    $br = New-Object Drawing.Drawing2D.LinearGradientBrush($rect, [Drawing.Color]::Red, [Drawing.Color]::Violet, 0.0)
    try {
        $blend = New-Object Drawing.Drawing2D.ColorBlend(7)
        $blend.Colors = $script:RainbowColors; $blend.Positions = $script:RainbowStops
        $br.InterpolationColors = $blend
        $e.Graphics.FillRectangle($br, 0, 0, $sender.Width, $sender.Height)
    }
    finally { $br.Dispose() }
}
$progFill.Add_Paint($paintRainbow)
$progTrack.Controls.Add($progFill)
# thin overall bar under the step bar
$ovTrack = New-Object Windows.Forms.Panel
$ovTrack.Location = New-Object Drawing.Point(24, 52); $ovTrack.Size = New-Object Drawing.Size(1000, 8)
$ovTrack.Anchor = 'Top,Left,Right'; $ovTrack.BackColor = $script:cPanel2
$ovFill = New-Object BufferedPanel
$ovFill.Dock = 'None'; $ovFill.Location = New-Object Drawing.Point(0, 0); $ovFill.Size = New-Object Drawing.Size(0, 8)
$ovFill.BackColor = $script:cAccent
$ovFill.Add_Paint($paintRainbow)
$ovTrack.Controls.Add($ovFill)
$progTrack.Add_Resize({ Update-ProgressWidths; $progFill.Invalidate() })
$ovTrack.Add_Resize({ Update-ProgressWidths; $ovFill.Invalidate() })
$lblOv = New-Object Windows.Forms.Label
$lblOv.AutoSize = $false; $lblOv.Size = New-Object Drawing.Size(220, 20); $lblOv.Location = New-Object Drawing.Point(1036, 46)
$lblOv.Anchor = 'Top,Right'; $lblOv.TextAlign = 'MiddleRight'; $lblOv.BackColor = [Drawing.Color]::Transparent
$lblOv.ForeColor = $script:cMuted; $lblOv.Font = $script:fontSmall; $lblOv.Text = 'Overall 0%'
$lblProg = New-Object Windows.Forms.Label
$lblProg.AutoSize = $false; $lblProg.Size = New-Object Drawing.Size(220, 22); $lblProg.Location = New-Object Drawing.Point(1036, 25)
$lblProg.Anchor = 'Top,Right'; $lblProg.TextAlign = 'MiddleRight'; $lblProg.BackColor = [Drawing.Color]::Transparent
$lblProg.ForeColor = $script:cText; $lblProg.Font = $script:fontBold; $lblProg.Text = '0%'
$statusBar.Controls.AddRange(@($lblStatus, $progTrack, $lblProg, $ovTrack, $lblOv))

# ---- content: toolbar + grid / detail views -------------------------------
$content = New-Object Windows.Forms.Panel
$content.Dock = 'Fill'; $content.BackColor = $script:cBg

$toolbar = New-Object Windows.Forms.Panel
$toolbar.Dock = 'Top'; $toolbar.Height = 54; $toolbar.Width = 1280; $toolbar.BackColor = $script:cBg
$btnViewGrid   = New-FlatButton 'Grid view' 110 'primary'
$btnViewDetail = New-FlatButton 'Detail view' 110 'secondary'
$btnViewDash   = New-FlatButton 'Dashboard' 110 'secondary'
$btnViewGrid.Location   = New-Object Drawing.Point(24, 10)
$btnViewDetail.Location = New-Object Drawing.Point(142, 10)
$btnViewDash.Location   = New-Object Drawing.Point(260, 10)
$lblFilter = New-Label 'Filter:' 400 18 $script:cMuted $script:fontBase
$txtFilter = New-Object Windows.Forms.TextBox
$txtFilter.Location = New-Object Drawing.Point(448, 13); $txtFilter.Size = New-Object Drawing.Size(300, 26)
$txtFilter.BackColor = $script:cPanel2; $txtFilter.ForeColor = $script:cText; $txtFilter.BorderStyle = 'FixedSingle'
$lblCount = New-Label '' 765 18 $script:cMuted $script:fontBase
$btnCols = New-FlatButton 'Columns' 90 'secondary'
$btnCols.Location = New-Object Drawing.Point(1166, 10); $btnCols.Anchor = 'Top,Right'
$btnFetch = New-FlatButton 'Fetch info' 100 'secondary'
$btnFetch.Location = New-Object Drawing.Point(1056, 10); $btnFetch.Anchor = 'Top,Right'
$btnEdit = New-FlatButton 'Edit info' 100 'secondary'
$btnEdit.Location = New-Object Drawing.Point(946, 10); $btnEdit.Anchor = 'Top,Right'
$toolbar.Controls.AddRange(@($btnViewGrid, $btnViewDetail, $btnViewDash, $lblFilter, $txtFilter, $lblCount, $btnEdit, $btnFetch, $btnCols))

# empty-state message
$lblEmpty = New-Object Windows.Forms.Label
$lblEmpty.Dock = 'Fill'; $lblEmpty.TextAlign = 'MiddleCenter'; $lblEmpty.ForeColor = $script:cMuted
$lblEmpty.Font = New-Object Drawing.Font('Segoe UI', 12)
$lblEmpty.Text = "Pick a source (Plex server or a local folder), then click Scan Media.`r`nTick 'Rebuild local cache' to ignore previously saved results."

# grid view
$gridHost = New-Object Windows.Forms.Panel
$gridHost.Dock = 'Fill'; $gridHost.Padding = New-Object Windows.Forms.Padding(24, 0, 24, 12); $gridHost.Visible = $false
$grid = New-Object Windows.Forms.DataGridView
$grid.Dock = 'Fill'; $grid.AutoSizeColumnsMode = 'None'
Set-DarkGridStyle -Grid $grid
$gridHost.Controls.Add($grid)

# detail view (two plain panels instead of a SplitContainer - SplitterDistance throws before first layout)
$detailHost = New-Object Windows.Forms.Panel
$detailHost.Dock = 'Fill'; $detailHost.Padding = New-Object Windows.Forms.Padding(24, 0, 24, 12); $detailHost.Visible = $false
$leftPane = New-Object Windows.Forms.Panel
$leftPane.Dock = 'Left'; $leftPane.Width = 320; $leftPane.BackColor = $script:cPanel
$rightPane = New-Object Windows.Forms.Panel
$rightPane.Dock = 'Fill'; $rightPane.BackColor = $script:cBg
$rightPane.Padding = New-Object Windows.Forms.Padding(14, 0, 0, 0)
$listFiles = New-Object Windows.Forms.ListBox
$listFiles.Dock = 'Fill'; $listFiles.BorderStyle = 'None'; $listFiles.BackColor = $script:cPanel
$listFiles.ForeColor = $script:cText; $listFiles.Font = $script:fontBase; $listFiles.ItemHeight = 20
$leftPane.Controls.Add($listFiles)

$attrGrid = New-Object Windows.Forms.DataGridView
$attrGrid.Dock = 'Fill'
Set-DarkGridStyle -Grid $attrGrid -ShowHeaders $false
$attrGrid.AutoSizeColumnsMode = 'Fill'
$attrGrid.DefaultCellStyle.SelectionBackColor = $script:cBg
$attrGrid.DefaultCellStyle.SelectionForeColor = $script:cText
$attrGrid.DefaultCellStyle.WrapMode = 'True'
$attrGrid.AutoSizeRowsMode = 'AllCells'
[void]$attrGrid.Columns.Add('Property', 'Property')
[void]$attrGrid.Columns.Add('Value', 'Value')
$attrGrid.Columns[0].FillWeight = 30
$attrGrid.Columns[1].FillWeight = 70

$headPanel = New-Object Windows.Forms.Panel
$headPanel.Dock = 'Top'; $headPanel.Height = 280; $headPanel.Width = 900; $headPanel.BackColor = $script:cBg
$headPanel.Padding = New-Object Windows.Forms.Padding(16)
$picPoster = New-Object Windows.Forms.PictureBox
$picPoster.Location = New-Object Drawing.Point(16, 16); $picPoster.Size = New-Object Drawing.Size(170, 250)
$picPoster.SizeMode = 'Zoom'; $picPoster.BackColor = $script:cPanel2
$lblDTitle = New-Object Windows.Forms.Label
$lblDTitle.Location = New-Object Drawing.Point(204, 14); $lblDTitle.Size = New-Object Drawing.Size(660, 34)
$lblDTitle.Anchor = 'Top,Left,Right'; $lblDTitle.Font = $script:fontBig; $lblDTitle.ForeColor = $script:cText
$lblDMeta = New-Object Windows.Forms.Label
$lblDMeta.Location = New-Object Drawing.Point(206, 52); $lblDMeta.Size = New-Object Drawing.Size(660, 22)
$lblDMeta.Anchor = 'Top,Left,Right'; $lblDMeta.ForeColor = $script:cAccent
$lblDPlot = New-Object Windows.Forms.Label
$lblDPlot.Location = New-Object Drawing.Point(206, 82); $lblDPlot.Size = New-Object Drawing.Size(660, 180)
$lblDPlot.Anchor = 'Top,Left,Right,Bottom'; $lblDPlot.ForeColor = $script:cMuted
$headPanel.Controls.AddRange(@($picPoster, $lblDTitle, $lblDMeta, $lblDPlot))
$rightPane.Controls.Add($attrGrid)         # Fill first, then Top
$rightPane.Controls.Add($headPanel)
$detailHost.Controls.Add($rightPane)       # Fill first, then Left
$detailHost.Controls.Add($leftPane)

# dashboard view: the WebView2 control is created lazily inside this panel (see Show-DashboardPane)
$dashHost = New-Object Windows.Forms.Panel
$dashHost.Dock = 'Fill'; $dashHost.BackColor = $script:cBg; $dashHost.Visible = $false

$content.Controls.Add($lblEmpty)
$content.Controls.Add($gridHost)
$content.Controls.Add($detailHost)
$content.Controls.Add($dashHost)
$content.Controls.Add($toolbar)            # Top docked last so it sits above the Fill controls

# Fill control first, then bottom/top bars (WinForms docks later-added controls first)
$form.Controls.Add($content)
$form.Controls.Add($statusBar)
$form.Controls.Add($controls)
$form.Controls.Add($header)
#endregion

#region ---------------------------------------------------------------- View helpers
function Set-View {
    param([ValidateSet('grid', 'detail', 'dashboard')][string]$View)
    $hasData = $script:ScanResults.Count -gt 0
    $script:CurrentView = $View
    $lblEmpty.Visible   = -not $hasData
    $gridHost.Visible   = $hasData -and ($View -eq 'grid')
    $detailHost.Visible = $hasData -and ($View -eq 'detail')
    $dashHost.Visible   = $hasData -and ($View -eq 'dashboard')
    # filter + column picker only make sense for the table views
    $showFilter = $hasData -and ($View -ne 'dashboard')
    $lblFilter.Visible = $showFilter; $txtFilter.Visible = $showFilter; $lblCount.Visible = $showFilter
    $btnCols.Visible   = $hasData -and ($View -eq 'grid')
    $btnFetch.Visible  = $hasData -and ($View -eq 'grid')
    $btnEdit.Visible   = $hasData -and ($View -eq 'grid')
    foreach ($pair in @(@($btnViewGrid, 'grid'), @($btnViewDetail, 'detail'), @($btnViewDash, 'dashboard'))) {
        $btn = $pair[0]
        if ($pair[1] -eq $View) {
            $btn.BackColor = $script:cAccent; $btn.ForeColor = [Drawing.Color]::White; $btn.FlatAppearance.BorderSize = 0
        }
        else {
            $btn.BackColor = $script:cPanel2; $btn.ForeColor = $script:cText; $btn.FlatAppearance.BorderSize = 1
        }
    }
}

function Show-RecordDetail {
    param($Record)
    $attrGrid.Rows.Clear()
    if ($null -eq $Record) { return }

    $title = [string]$Record.Title
    if ($Record.Year -gt 0) { $title = "$title ($($Record.Year))" }
    $lblDTitle.Text = $title
    $bits = @()
    if ($Record.ResolutionClass -and $Record.ResolutionClass -ne 'Unknown') { $bits += $Record.ResolutionClass }
    if ($Record.HDRType -and $Record.HDRType -ne 'SDR') { $bits += $Record.HDRType }
    if ($Record.VideoCodec) { $bits += $Record.VideoCodec }
    if ($Record.AudioFormat -and $Record.AudioFormat -ne 'Unknown') { $bits += $Record.AudioFormat }
    if ($Record.Rating -gt 0) { $bits += ('Rating {0:N1}' -f $Record.Rating) }
    $lblDMeta.Text = ($bits -join '   |   ')
    $plot = [string]$Record.Plot
    if ($Record.Tagline) { $plot = "$($Record.Tagline)`r`n`r`n$plot" }
    $lblDPlot.Text = $plot

    # poster (load from bytes so the file is not locked)
    if ($picPoster.Image) { $picPoster.Image.Dispose(); $picPoster.Image = $null }
    if ($script:PosterStream) { $script:PosterStream.Dispose(); $script:PosterStream = $null }
    if ($Record.PosterPath -and (Test-Path -LiteralPath $Record.PosterPath)) {
        try {
            $script:PosterStream = New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($Record.PosterPath))
            $picPoster.Image = [Drawing.Image]::FromStream($script:PosterStream)
        }
        catch { }
    }

    # attributes, grouped
    foreach ($group in ($script:Fields | Select-Object -ExpandProperty Group -Unique)) {
        $idx = $attrGrid.Rows.Add($group.ToUpper(), '')
        $row = $attrGrid.Rows[$idx]
        $row.DefaultCellStyle.BackColor = $script:cPanel2
        $row.DefaultCellStyle.ForeColor = $script:cAccent
        $row.DefaultCellStyle.Font = $script:fontBold
        foreach ($f in ($script:Fields | Where-Object { $_.Group -eq $group })) {
            $val = $Record.($f.Name)
            if ($null -eq $val) { continue }
            if ($val -is [string]) { if ($val -eq '') { continue } }
            elseif ($val -isnot [bool]) { if ($val -eq 0) { continue } }     # hide empty / zero numbers, keep Yes/No flags
            $r = $attrGrid.Rows.Add($f.Name, (Format-RecordValue $val $f.Name))
            $attrGrid.Rows[$r].Cells[0].Style.ForeColor = $script:cMuted
        }
    }
    $attrGrid.ClearSelection()
}

function Update-DetailList {
    param([string]$Filter = '')
    $listFiles.BeginUpdate()
    $listFiles.Items.Clear()
    $items = @()
    foreach ($r in $script:ScanResults) {
        if ($Filter) {
            $hay = ('{0} {1} {2} {3} {4}' -f $r.Title, $r.FileName, $r.Genre, $r.Studio, $r.Cast).ToLowerInvariant()
            if (-not $hay.Contains($Filter.ToLowerInvariant())) { continue }
        }
        $label = [string]$r.Title
        if ($r.Year -gt 0) { $label = "$label ($($r.Year))" }
        [void]$listFiles.Items.Add($label)
        $items += $r
    }
    $script:DetailItems = $items
    $listFiles.EndUpdate()
}

function Get-LikeEscaped {
    param([string]$Text)
    $Text.Replace("'", "''").Replace('[', '[[]').Replace('%', '[%]').Replace('*', '[*]')
}

function Update-Filter {
    $text = $txtFilter.Text.Trim()
    if ($grid.DataSource -is [System.Data.DataTable]) {
        $fieldTerm = $null
        # "field:value" filters one text column, e.g.  source:unknown   resolution:1080p   hdrtype:dolby
        if ($text -match '^(\w+)\s*:\s*(.+)$') {
            $col = $grid.DataSource.Columns[$Matches[1]]
            if ($null -ne $col -and $col.DataType -eq [string]) { $fieldTerm = @{ Name = $col.ColumnName; Value = $Matches[2].Trim() } }
        }
        if ($fieldTerm) {
            $grid.DataSource.DefaultView.RowFilter = "[$($fieldTerm.Name)] LIKE '%$(Get-LikeEscaped $fieldTerm.Value)%'"
        }
        elseif ($text) {
            $e = Get-LikeEscaped $text
            $grid.DataSource.DefaultView.RowFilter = "[Title] LIKE '%$e%' OR [FileName] LIKE '%$e%' OR [Genre] LIKE '%$e%' OR [Studio] LIKE '%$e%' OR [Cast] LIKE '%$e%' OR [Director] LIKE '%$e%'"
        }
        else { $grid.DataSource.DefaultView.RowFilter = '' }
        $lblCount.Text = '{0} of {1} titles' -f $grid.DataSource.DefaultView.Count, $script:ScanResults.Count
    }
    Update-DetailList -Filter $text
}
#endregion

#region ---------------------------------------------------------------- Events
$btnViewGrid.Add_Click({ Set-View 'grid' })
$btnViewDetail.Add_Click({ Set-View 'detail' })
$txtFilter.Add_TextChanged({ Update-Filter })
$tip.SetToolTip($txtFilter, "Type to search title, file, genre, studio, cast or director.`nOr filter one column with  field:value  - for example  source:unknown  or  resolution:1080p.`nExport CSV then saves only the rows shown.")

# Runtime is stored as minutes (so it sorts numerically) but always displayed as H:MM:SS
$grid.Add_CellFormatting({
    param($s, $e)
    if ($e.ColumnIndex -lt 0) { return }
    $cn = $s.Columns[$e.ColumnIndex].Name
    if ($cn -eq 'RuntimeMin') {
        $e.Value = Format-Runtime $e.Value
        $e.FormattingApplied = $true
    }
    elseif ($cn -like 'BoxOffice*' -or $cn -like 'Opening*') {
        $v = 0.0; if ($e.Value -isnot [DBNull] -and $null -ne $e.Value) { $v = [double]$e.Value }
        $e.Value = if ($v -gt 0) { '$' + $v.ToString('N0', $script:Culture) } else { '' }
        $e.FormattingApplied = $true
    }
    elseif ($cn -eq 'RTCritic' -or $cn -eq 'RTAudience') {
        $v = 0; if ($e.Value -isnot [DBNull] -and $null -ne $e.Value) { $v = [int]$e.Value }
        $e.Value = if ($v -gt 0) { "$v%" } else { '' }
        $e.FormattingApplied = $true
    }
})

# Rotten Tomatoes style scores: a tomato (critics) or popcorn bucket (audience) drawn by us, fresh at 60 % and up, splat / spilled below.
$grid.Add_CellPainting({
    param($s, $e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
    $cn = $s.Columns[$e.ColumnIndex].Name
    if ($cn -ne 'RTCritic' -and $cn -ne 'RTAudience') { return }
    $e.Handled = $true
    $e.PaintBackground($e.ClipBounds, ($e.State -band [Windows.Forms.DataGridViewElementStates]::Selected) -ne 0)
    $txt = [string]$e.FormattedValue
    if (-not $txt) { return }
    $pct  = [int]($txt.TrimEnd('%'))
    $fresh = ($pct -ge 60)
    $g = $e.Graphics
    $g.SmoothingMode = 'AntiAlias'
    $ix = $e.CellBounds.X + 8; $iy = $e.CellBounds.Y + [int](($e.CellBounds.Height - 16) / 2)
    if ($cn -eq 'RTCritic') {
        if ($fresh) {
            $br = New-Object Drawing.SolidBrush((RGB 230 52 40)); $g.FillEllipse($br, $ix, $iy + 2, 15, 14); $br.Dispose()
            $lf = New-Object Drawing.SolidBrush((RGB 70 170 70))
            $g.FillPolygon($lf, [Drawing.Point[]]@((New-Object Drawing.Point(($ix + 7), ($iy + 4))), (New-Object Drawing.Point(($ix + 3), ($iy + 1))), (New-Object Drawing.Point(($ix + 7), ($iy + 2))), (New-Object Drawing.Point(($ix + 11), ($iy + 0))), (New-Object Drawing.Point(($ix + 9), ($iy + 4)))))
            $lf.Dispose()
        }
        else {
            $br = New-Object Drawing.SolidBrush((RGB 112 168 44))
            $g.FillEllipse($br, $ix + 1, $iy + 6, 14, 9); $g.FillEllipse($br, $ix + 4, $iy + 2, 8, 8); $g.FillEllipse($br, $ix - 1, $iy + 9, 5, 5); $g.FillEllipse($br, $ix + 11, $iy + 8, 5, 5)
            $br.Dispose()
        }
    }
    else {
        $red = New-Object Drawing.SolidBrush((RGB 215 48 38)); $wht = New-Object Drawing.SolidBrush((RGB 245 245 245)); $yel = New-Object Drawing.SolidBrush((RGB 250 205 60))
        if ($fresh) {
            $g.FillEllipse($yel, $ix + 1, $iy, 6, 6); $g.FillEllipse($yel, $ix + 6, $iy - 1, 6, 6); $g.FillEllipse($yel, $ix + 10, $iy + 1, 5, 5)
            $g.FillPolygon($red, [Drawing.Point[]]@((New-Object Drawing.Point(($ix + 1), ($iy + 5))), (New-Object Drawing.Point(($ix + 15), ($iy + 5))), (New-Object Drawing.Point(($ix + 12), ($iy + 16))), (New-Object Drawing.Point(($ix + 4), ($iy + 16)))))
            $g.FillRectangle($wht, $ix + 6, $iy + 6, 3, 10)
        }
        else {
            $g.FillEllipse($yel, $ix + 11, $iy + 11, 5, 5); $g.FillEllipse($yel, $ix + 14, $iy + 8, 4, 4)
            $g.FillPolygon($red, [Drawing.Point[]]@((New-Object Drawing.Point(($ix + 0), ($iy + 4))), (New-Object Drawing.Point(($ix + 12), ($iy + 8))), (New-Object Drawing.Point(($ix + 9), ($iy + 15))), (New-Object Drawing.Point(($ix + 2), ($iy + 12)))))
            $g.FillRectangle($wht, $ix + 5, $iy + 7, 3, 5)
        }
        $red.Dispose(); $wht.Dispose(); $yel.Dispose()
    }
    $fc = if (($e.State -band [Windows.Forms.DataGridViewElementStates]::Selected) -ne 0) { $e.CellStyle.SelectionForeColor } else { $e.CellStyle.ForeColor }
    $rect = New-Object Drawing.Rectangle(($e.CellBounds.X + 28), $e.CellBounds.Y, ($e.CellBounds.Width - 30), $e.CellBounds.Height)
    [Windows.Forms.TextRenderer]::DrawText($g, $txt, $e.CellStyle.Font, $rect, $fc, ([Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::Left))
})

function Show-PlexTokenDialog {
    # One popup for the server address and the access token. Proves the pair works, then stores the token encrypted (DPAPI) if asked.
    param([string]$BaseUrl)

    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = 'Connect to Plex'
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.ShowInTaskbar = $false
    $dlg.StartPosition = 'CenterParent'
    $dlg.ClientSize = New-Object Drawing.Size(560, 396)
    $dlg.BackColor = $script:cBg; $dlg.ForeColor = $script:cText; $dlg.Font = $script:fontBase
    $script:TokDlg = $dlg

    $lblHead = New-Label 'Connect to your Plex server' 24 18 $script:cText $script:fontTitle

    $lblSrv = New-Label 'SERVER ADDRESS' 24 62 $script:cMuted $script:fontSmall
    $srv = New-Object Windows.Forms.TextBox
    $srv.Location = New-Object Drawing.Point(24, 84); $srv.Size = New-Object Drawing.Size(512, 28)
    $srv.BorderStyle = 'FixedSingle'
    $srv.BackColor = $script:cPanel2; $srv.ForeColor = $script:cText; $srv.Font = New-Object Drawing.Font('Segoe UI', 11)
    $srv.Text = $BaseUrl
    $script:TokSrv = $srv

    $lblInfo = New-Object Windows.Forms.Label
    $lblInfo.Location = New-Object Drawing.Point(24, 126); $lblInfo.Size = New-Object Drawing.Size(512, 54)
    $lblInfo.ForeColor = $script:cMuted
    $lblInfo.Text = "Use the address of your Plex server, for example http://192.168.1.10:32400 or http://myserver:32400.`r`nThen paste the access token: in Plex Web open any title, click the ... menu, choose Get Info, then View XML, and copy the text after X-Plex-Token= in the address bar."
    $lnk = New-Object Windows.Forms.LinkLabel
    $lnk.Text = 'How do I find my token?'; $lnk.AutoSize = $true; $lnk.Location = New-Object Drawing.Point(24, 186)
    $lnk.LinkColor = $script:cAccent; $lnk.ActiveLinkColor = $script:cAccent2; $lnk.BackColor = [Drawing.Color]::Transparent
    $lnk.Add_LinkClicked({ Start-Process 'https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/' })

    $lblTok = New-Label 'ACCESS TOKEN' 24 220 $script:cMuted $script:fontSmall
    $txt = New-Object Windows.Forms.TextBox
    $txt.Location = New-Object Drawing.Point(24, 242); $txt.Size = New-Object Drawing.Size(512, 28)
    $txt.UseSystemPasswordChar = $true; $txt.BorderStyle = 'FixedSingle'
    $txt.BackColor = $script:cPanel2; $txt.ForeColor = $script:cText; $txt.Font = New-Object Drawing.Font('Segoe UI', 11)
    $script:TokText = $txt

    $chk = New-FlatCheckBox 'Remember on this computer (encrypted for your Windows account)' 24 282 $true
    $script:TokRemember = $chk

    $err = New-Object Windows.Forms.Label
    $err.Location = New-Object Drawing.Point(24, 312); $err.Size = New-Object Drawing.Size(512, 36)
    $err.ForeColor = $script:cMuted
    $script:TokErr = $err

    $ok = New-FlatButton 'Connect' 120 'primary'
    $ok.Location = New-Object Drawing.Point(296, 352)
    $cancel = New-FlatButton 'Cancel' 100 'secondary'
    $cancel.Location = New-Object Drawing.Point(428, 352)
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel

    $ok.Add_Click({
        $url = $script:TokSrv.Text.Trim().TrimEnd('/')
        $tok = $script:TokText.Text.Trim()
        if ($url -notmatch '^https?://\S+') { $script:TokErr.ForeColor = (RGB 255 107 129); $script:TokErr.Text = 'Enter the server address first, starting with http:// or https://'; $script:TokSrv.Focus() | Out-Null; return }
        if (-not $tok) { $script:TokErr.ForeColor = (RGB 255 107 129); $script:TokErr.Text = 'Paste your token first.'; $script:TokText.Focus() | Out-Null; return }
        $script:TokErr.ForeColor = $script:cMuted; $script:TokErr.Text = 'Connecting...'
        $script:TokDlg.Cursor = [Windows.Forms.Cursors]::WaitCursor
        [Windows.Forms.Application]::DoEvents()
        try {
            $secs = @(Get-PlexSections -BaseUrl $url -Token $tok)
            $script:PlexToken    = $tok
            $script:PlexRemember = [bool]$script:TokRemember.Checked
            $script:PlexUrlOut   = $url
            $script:TokDlg.DialogResult = [Windows.Forms.DialogResult]::OK
        }
        catch {
            $script:TokErr.ForeColor = (RGB 255 107 129)
            $script:TokErr.Text = $_.Exception.Message
        }
        finally { $script:TokDlg.Cursor = [Windows.Forms.Cursors]::Default }
    })

    $dlg.Add_Shown({
        # Start in the address box while it still holds the example text, otherwise in the token box.
        if ($script:TokSrv.Text.Trim() -match '^https?://\S+' -and $script:TokSrv.Text -notmatch 'plex-server') { $script:TokText.Focus() | Out-Null }
        else { $script:TokSrv.Focus() | Out-Null; $script:TokSrv.SelectAll() }
    })

    $dlg.Controls.AddRange(@($lblHead, $lblSrv, $srv, $lblInfo, $lnk, $lblTok, $txt, $chk, $err, $ok, $cancel))
    $script:PlexUrlOut = ''
    $result = $dlg.ShowDialog($form)
    $dlg.Dispose()
    if ($result -ne [Windows.Forms.DialogResult]::OK) { return $false }

    if ($script:PlexUrlOut) { $txtFolder.Text = $script:PlexUrlOut }
    $script:Settings['PlexTokenProtected'] = if ($script:PlexRemember) { Protect-PlexToken $script:PlexToken } else { '' }
    Save-Settings
    $true
}

function Confirm-PlexToken {
    # True when a working token is in memory (asks for one when there is none yet).
    param([string]$BaseUrl)
    if ($script:PlexToken -and $BaseUrl -match '^https?://\S+') { return $true }
    Show-PlexTokenDialog -BaseUrl $BaseUrl
}

$btnBrowse.Add_Click({
    if ($radPlex.Checked) {
        [void](Show-PlexTokenDialog -BaseUrl $txtFolder.Text.Trim())
        return
    }
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Select the folder containing your media files'
    if ($txtFolder.Text -and (Test-Path -LiteralPath $txtFolder.Text)) { $dlg.SelectedPath = $txtFolder.Text }
    if ($dlg.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) { $txtFolder.Text = $dlg.SelectedPath }
})

$btnCancel.Add_Click({
    $script:Sync.Cancel = $true
    $script:CancelAt    = Get-Date
    $btnCancel.Enabled  = $false
    $lblStatus.Text     = 'Cancelling...'
})

$listFiles.Add_SelectedIndexChanged({
    $i = $listFiles.SelectedIndex
    if ($i -ge 0 -and $i -lt $script:DetailItems.Count) { Show-RecordDetail $script:DetailItems[$i] }
})

$grid.Add_CellDoubleClick({
    param($s, $e)
    if ($e.RowIndex -lt 0) { return }
    $path = $grid.Rows[$e.RowIndex].Cells['FullPath'].Value
    $txtFilter.Text = ''
    for ($i = 0; $i -lt $script:DetailItems.Count; $i++) {
        if ($script:DetailItems[$i].FullPath -eq $path) { Set-View 'detail'; $listFiles.SelectedIndex = $i; break }
    }
})

$btnCols.Add_Click({
    if ($grid.Columns.Count -eq 0) { return }
    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = 'Visible columns'; $dlg.Size = New-Object Drawing.Size(340, 560)
    $dlg.StartPosition = 'CenterParent'; $dlg.BackColor = $script:cBg; $dlg.ForeColor = $script:cText
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $clb = New-Object Windows.Forms.CheckedListBox
    $clb.Dock = 'Fill'; $clb.CheckOnClick = $true; $clb.BorderStyle = 'None'
    $clb.BackColor = $script:cPanel; $clb.ForeColor = $script:cText; $clb.Font = $script:fontBase
    foreach ($c in $grid.Columns) { [void]$clb.Items.Add($c.Name, $c.Visible) }
    $ok = New-FlatButton 'Apply' 100 'primary'
    $ok.DialogResult = [Windows.Forms.DialogResult]::OK
    $reset = New-FlatButton 'Defaults' 100 'secondary'
    $fieldList = $script:Fields          # captured explicitly: $script: scope is not visible inside a closure
    $listBox   = $clb
    $reset.Add_Click({
        # tick only the columns that are visible by default
        for ($i = 0; $i -lt $listBox.Items.Count; $i++) {
            $fd = $fieldList | Where-Object { $_.Name -eq [string]$listBox.Items[$i] } | Select-Object -First 1
            $listBox.SetItemChecked($i, [bool]$fd.Show)
        }
    }.GetNewClosure())
    $bar = New-Object Windows.Forms.Panel
    $bar.Dock = 'Bottom'; $bar.Height = 50; $bar.BackColor = $script:cPanel
    $reset.Location = New-Object Drawing.Point(100, 8)
    $ok.Location = New-Object Drawing.Point(210, 8); $bar.Controls.Add($reset); $bar.Controls.Add($ok)
    $dlg.Controls.Add($clb); $dlg.Controls.Add($bar); $dlg.AcceptButton = $ok
    if ($dlg.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) {
        for ($i = 0; $i -lt $clb.Items.Count; $i++) { $grid.Columns[[string]$clb.Items[$i]].Visible = $clb.GetItemChecked($i) }
        Save-Settings        # remembered for every future scan and restart
    }
})

$tip.SetToolTip($btnFetch, "Look up year, genre, rating, studio, director, certification, Rotten Tomatoes and box office`nfor the selected titles (or every listed title when none is selected).")

$btnFetch.Add_Click({
    if ($script:ScanResults.Count -eq 0 -or $grid.DataSource -isnot [System.Data.DataTable]) {
        [Windows.Forms.MessageBox]::Show('Scan a library first, then fetch info for its titles.', 'Fetch info', 'OK', 'Information') | Out-Null; return
    }
    if (-not $script:TmdbKey) {
        [Windows.Forms.MessageBox]::Show("Fetch info needs a free TMDB API key.`n`nClick the gear button, paste the key under Online lookups, then try again.", 'Fetch info', 'OK', 'Information') | Out-Null; return
    }
    $dt  = $grid.DataSource
    $idx = New-Object 'System.Collections.Generic.List[int]'
    $scope = 'listed titles'
    if ($grid.SelectedRows.Count -gt 0) {
        $scope = 'selected titles'
        foreach ($r in $grid.SelectedRows) { $drv = $r.DataBoundItem; if ($null -ne $drv) { $idx.Add($dt.Rows.IndexOf($drv.Row)) } }
    }
    else { foreach ($drv in $dt.DefaultView) { $idx.Add($dt.Rows.IndexOf($drv.Row)) } }
    if ($idx.Count -eq 0) { return }
    $choice = Show-FetchDialog -Count $idx.Count -Scope $scope
    if ($null -eq $choice) { return }

    $script:Sync = [hashtable]::Synchronized(@{
        Text = 'Starting...'; Value = 0; Max = 0; Total = 0; Cancel = $false; Done = $false; Error = $null; Results = $null; Summary = ''
        PhaseLo = 0.0; PhaseHi = 1.0; Workers = 1
        Partial = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
    })
    $script:ScanUsePlex = $false
    $script:ScanMode    = 'Scrape'
    $script:ScanWatch   = [Diagnostics.Stopwatch]::StartNew()
    $script:CancelAt    = $null
    $script:RateT = $null; $script:RateV = 0; $script:RateVal = $null
    $script:EtaStep = @{ T = $null; F = 0.0; R = $null }; $script:EtaAll = @{ T = $null; F = 0.0; R = $null }; $script:LastPhase = 0
    $btnScan.Enabled = $false; $btnBrowse.Enabled = $false; $btnDash.Enabled = $false; $btnSaveHtml.Enabled = $false; $btnExport.Enabled = $false; $btnCancel.Enabled = $true; $btnFetch.Enabled = $false
    Set-OverallProgress -Fraction 0.0
    $script:DashboardStale = $true
    $lblStatus.Text = 'Starting...'
    try {
        Start-ScanWorker -Mode 'Scrape' -ScanArgs @{
            Records = @($script:ScanResults); Indexes = [int[]]$idx.ToArray(); TmdbKey = [string]$script:TmdbKey; OmdbKey = [string]$script:OmdbKey
            Overwrite = [bool]$choice.Overwrite; DataFolder = $script:DataFolder; StorePath = $script:MetaStorePath }
        $script:ScanTimer.Start()
    }
    catch {
        [Windows.Forms.MessageBox]::Show("Could not start the lookup:`n$_", 'Fetch info', 'OK', 'Error') | Out-Null
        $btnScan.Enabled = $true; $btnBrowse.Enabled = $true; $btnDash.Enabled = $true; $btnSaveHtml.Enabled = $true; $btnExport.Enabled = $true; $btnCancel.Enabled = $false; $btnFetch.Enabled = $true
    }
})

#region ---------------------------------------------------------------- Metadata editor (typed-in values)
# Typed-in values are saved ONLY in this app's own store (metadata\store.json in the settings folder). Media files, NFO files,
# the scan cache and the Plex server are never touched. They are applied on top of every scan, and always beat fetched values.
$script:EditFields = @(
    @{ N = 'Year';              L = 'Year';                          K = 'int';    Min = 1888; Max = 2100; H = 'e.g. 1999' },
    @{ N = 'Genre';             L = 'Genre';                         K = 'text';   H = 'separate with ;' },
    @{ N = 'MPAARating';        L = 'MPAA rating';                   K = 'text';   H = 'PG, PG-13, R ...' },
    @{ N = 'Rating';            L = 'Rating';                        K = 'double'; Min = 0; Max = 10; H = '0 - 10' },
    @{ N = 'Studio';            L = 'Studio';                        K = 'text';   H = '' },
    @{ N = 'Director';          L = 'Director';                      K = 'text';   H = 'separate with ;' },
    @{ N = 'RTCritic';          L = 'Rotten Tomatoes - critics';     K = 'int';    Min = 0; Max = 100; H = '% (0 - 100)' },
    @{ N = 'RTAudience';        L = 'Rotten Tomatoes - audience';    K = 'int';    Min = 0; Max = 100; H = '% (0 - 100)' },
    @{ N = 'CinemaScore';       L = 'CinemaScore';                   K = 'grade';  H = 'A+ to F' },
    @{ N = 'BoxOfficeDomestic'; L = 'All-time domestic';             K = 'money';  H = '$ or 12.5M' },
    @{ N = 'BoxOfficeWorldwide';L = 'All-time worldwide';            K = 'money';  H = '$ or 1.2B' },
    @{ N = 'OpeningDomestic';   L = 'Opening weekend - domestic';    K = 'money';  H = '$ or 12.5M' },
    @{ N = 'OpeningWorldwide';  L = 'Opening weekend - worldwide';   K = 'money';  H = '$ or 12.5M' }
)

function Get-EditText {
    param($Spec, $Value)
    if (Test-ValueEmpty $Value) { return '' }
    switch ($Spec.K) {
        'money'  { return ('{0:N0}' -f [double]$Value) }
        'double' { return [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.0}', [double]$Value) }
        default  { return [string]$Value }
    }
}

function ConvertFrom-EditText {
    # Text typed into the editor -> a typed value, or throws a message that names the field.
    param($Spec, [string]$Text)
    $L = $Spec.L
    switch ($Spec.K) {
        'text'   { return $Text }
        'int' {
            $v = 0
            if (-not [int]::TryParse($Text.Replace(',', ''), [ref]$v)) { throw "${L}: enter a whole number." }
            if ($v -lt $Spec.Min -or $v -gt $Spec.Max) { throw "${L}: must be between $($Spec.Min) and $($Spec.Max)." }
            return $v
        }
        'double' {
            $v = 0.0
            if (-not [double]::TryParse($Text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { throw "${L}: enter a number such as 7.4." }
            if ($v -lt $Spec.Min -or $v -gt $Spec.Max) { throw "${L}: must be between $($Spec.Min) and $($Spec.Max)." }
            return [Math]::Round($v, 1)
        }
        'grade' {
            $g = $Text.Trim().ToUpperInvariant()
            if ($g -notmatch '^(A\+|A-|A|B\+|B-|B|C\+|C-|C|D\+|D-|D|F)$') { throw "${L}: use a grade from A+ to F." }
            return $g
        }
        'money' {
            $t = $Text.Trim().Replace('$', '').Replace(',', '').Replace(' ', '').ToUpperInvariant()
            $mul = 1.0
            if ($t -match '^(.*?)([KMB])$') {
                $t = $Matches[1]
                $mul = switch ($Matches[2]) { 'K' { 1e3 } 'M' { 1e6 } 'B' { 1e9 } }
            }
            $v = 0.0
            if (-not [double]::TryParse($t, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v) -or $v -lt 0) { throw "${L}: enter dollars, such as 1250000 or 1.25M." }
            return [Math]::Round($v * $mul)
        }
    }
}

function Find-MetaEntry {
    # The store entry a record is filed under (any of its keys), or $null.
    param([hashtable]$Store, $Rec)
    foreach ($k in (Get-MetaKeys $Rec)) { if ($Store.ContainsKey($k)) { return @{ Key = $k; Entry = $Store[$k] } } }
    $null
}

function Show-MetaEditor {
    # Returns @{ Put = @{Field = value}; Del = @(Field,...) } or $null when cancelled.
    param($Rec, [hashtable]$Manual)
    $dlg = New-DialogForm 'Edit info' 600 640
    $title = [string]$Rec.Title; if ($Rec.Year -gt 0) { $title = "$title ($($Rec.Year))" }
    $head = New-Label $title 24 16 $script:cText $script:fontTitle
    $head.AutoSize = $false; $head.Size = New-Object Drawing.Size(552, 28)
    $sub = New-Object Windows.Forms.Label
    $sub.Location = New-Object Drawing.Point(24, 46); $sub.Size = New-Object Drawing.Size(552, 36)
    $sub.ForeColor = $script:cMuted; $sub.BackColor = [Drawing.Color]::Transparent
    $sub.Text = "Typed-in values are saved in this app's own data file only - never in your media files, NFO files or Plex. They win over fetched values and are re-applied on every scan. Empty a field that says 'edited' to go back to the original."

    $pnl = New-Object Windows.Forms.Panel
    $pnl.Location = New-Object Drawing.Point(0, 90); $pnl.Size = New-Object Drawing.Size(600, 456)
    $pnl.AutoScroll = $true; $pnl.BackColor = $script:cPanel
    $script:EdBoxes = @{}; $script:EdInit = @{}; $script:EdSpecs = @{}
    $y = 4
    foreach ($sp in $script:EditFields) {
        if ($sp.N -eq 'RTCritic') {
            $y += 8; $pnl.Controls.Add((New-Label 'SCORES AND MONEY' 24 $y $script:cMuted $script:fontSmall)); $y += 24
        }
        elseif ($sp.N -eq 'Year') { $pnl.Controls.Add((New-Label 'ABOUT THE TITLE' 24 $y $script:cMuted $script:fontSmall)); $y += 24 }
        $lbl = New-Label $sp.L 24 ($y + 4) $script:cText $script:fontBase
        $tb = New-Object Windows.Forms.TextBox
        $tb.Location = New-Object Drawing.Point(230, $y); $tb.Size = New-Object Drawing.Size(200, 26)
        $tb.BorderStyle = 'FixedSingle'; $tb.BackColor = $script:cPanel2; $tb.ForeColor = $script:cText
        $init = Get-EditText $sp $Rec.($sp.N)
        $tb.Text = $init
        $script:EdBoxes[$sp.N] = $tb; $script:EdInit[$sp.N] = $init; $script:EdSpecs[$sp.N] = $sp
        $hint = if ($Manual.ContainsKey($sp.N)) { 'edited' } else { [string]$sp.H }
        $hl = New-Label $hint 440 ($y + 5) $(if ($Manual.ContainsKey($sp.N)) { $script:cAccent } else { $script:cMuted }) $script:fontSmall
        $pnl.Controls.AddRange(@($lbl, $tb, $hl))
        $y += 34
    }
    $err = New-Object Windows.Forms.Label
    $err.Location = New-Object Drawing.Point(24, 552); $err.Size = New-Object Drawing.Size(552, 20)
    $err.ForeColor = (RGB 255 107 129); $err.BackColor = [Drawing.Color]::Transparent
    $script:EdErr = $err; $script:EdDlg = $dlg; $script:EdManual = $Manual; $script:EdResult = $null

    $ok = New-FlatButton 'Save' 100 'primary'; $ok.Location = New-Object Drawing.Point(370, 584)
    $cancel = New-FlatButton 'Cancel' 100 'secondary'; $cancel.Location = New-Object Drawing.Point(476, 584)
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    $ok.Add_Click({
        $set = @{}; $clear = @()
        try {
            foreach ($n in $script:EdBoxes.Keys) {
                $txt = $script:EdBoxes[$n].Text.Trim()
                if ($txt -eq $script:EdInit[$n]) { continue }
                if ($txt -eq '') { if ($script:EdManual.ContainsKey($n)) { $clear += $n }; continue }
                $set[$n] = ConvertFrom-EditText $script:EdSpecs[$n] $txt
            }
        }
        catch { $script:EdErr.Text = $_.Exception.Message; return }
        $script:EdResult = @{ Put = $set; Del = $clear }
        $script:EdDlg.DialogResult = [Windows.Forms.DialogResult]::OK
    })
    $dlg.Controls.AddRange(@($head, $sub, $pnl, $err, $ok, $cancel))
    $res = $dlg.ShowDialog($form)
    $dlg.Dispose()
    if ($res -ne [Windows.Forms.DialogResult]::OK) { return $null }
    $script:EdResult
}

function Edit-SelectedMetadata {
    if ($script:ScanResults.Count -eq 0 -or $grid.DataSource -isnot [System.Data.DataTable]) { return }
    $row = $null
    if ($grid.SelectedRows.Count -eq 1) { $row = $grid.SelectedRows[0] }
    elseif ($grid.SelectedRows.Count -eq 0 -and $null -ne $grid.CurrentRow) { $row = $grid.CurrentRow }
    if ($null -eq $row -or $null -eq $row.DataBoundItem) {
        [Windows.Forms.MessageBox]::Show('Select one title in the grid first (click its row), then click Edit info.', 'Edit info', 'OK', 'Information') | Out-Null; return
    }
    $drv = $row.DataBoundItem
    $rec = $null
    $pk = [string]$drv['PlexKey']; $fp = [string]$drv['FullPath']
    foreach ($r in $script:ScanResults) {
        if (($pk -and [string]$r.PlexKey -eq $pk) -or (-not $pk -and [string]$r.FullPath -eq $fp)) { $rec = $r; break }
    }
    if ($null -eq $rec) { return }

    $store = Read-MetaStore -Path $script:MetaStorePath
    $found = Find-MetaEntry $store $rec
    $manual = if ($found) { $found.Entry.Manual } else { @{} }
    $res = Show-MetaEditor -Rec $rec -Manual $manual
    if ($null -eq $res -or ($res.Put.Count -eq 0 -and $res.Del.Count -eq 0)) { return }

    # 1) the store file
    if ($found) { $key = $found.Key; $entry = $found.Entry }
    else { $key = (Get-MetaKeys $rec)[0]; $entry = @{ Manual = @{}; Scraped = @{}; Force = @(); Sources = @{}; At = '' } }
    foreach ($n in $res.Put.Keys) { $entry.Manual[$n] = $res.Put[$n] }
    foreach ($n in $res.Del) { $entry.Manual.Remove($n) }
    $entry.At = (Get-Date).ToString('s')
    if ($entry.Manual.Count -eq 0 -and $entry.Scraped.Count -eq 0) { $store.Remove($key) } else { $store[$key] = $entry }
    try { Write-MetaStore -Path $script:MetaStorePath -Store $store }
    catch { [Windows.Forms.MessageBox]::Show("Could not save the changes:`n$_", 'Edit info', 'OK', 'Error') | Out-Null; return }

    # 2) what is on screen right now (the next scan re-applies the store by itself)
    $note = @()
    foreach ($n in $res.Put.Keys) {
        $f = $script:Fields | Where-Object { $_.Name -eq $n } | Select-Object -First 1
        $typed = [Convert]::ChangeType($res.Put[$n], $script:TypeMap[$f.Type])
        Set-RecField $rec $n $typed
        $drv.Row[$n] = $typed
    }
    foreach ($n in $res.Del) {
        if ($entry.Scraped.ContainsKey($n)) {
            $f = $script:Fields | Where-Object { $_.Name -eq $n } | Select-Object -First 1
            try { $typed = [Convert]::ChangeType($entry.Scraped[$n], $script:TypeMap[$f.Type]); Set-RecField $rec $n $typed; $drv.Row[$n] = $typed } catch { }
        }
        else { $note += $n }
    }
    $names = @($res.Put.Keys) + @($res.Del)
    $keep = @(([string]$rec.MetaSources -split '; ') | Where-Object { $t = $_; $_ -and -not ($res.Put.Keys -contains ($t -split ':')[0]) -and -not ($res.Del -contains ($t -split ':')[0]) })
    $keep += @($res.Put.Keys | ForEach-Object { '{0}: manual' -f $_ })
    Set-RecField $rec 'MetaSources' ($keep -join '; ')
    $drv.Row['MetaSources'] = [string]$rec.MetaSources
    $script:DashboardStale = $true
    $lblStatus.Text = 'Saved {0} change(s) for {1}.' -f $names.Count, $rec.Title
    if ($note.Count -gt 0) { $lblStatus.Text += ' The original value for ' + ($note -join ', ') + ' comes back on the next scan.' }
}

$btnEdit.Add_Click({ Edit-SelectedMetadata })
$tip.SetToolTip($btnEdit, "Type in values the online sources do not have (Rotten Tomatoes audience, CinemaScore, opening weekend...)`nfor the selected title. Saved in this app's data file only - never in your media files or Plex.")

# right-click a row for the same editor
$gridMenu = New-Object Windows.Forms.ContextMenuStrip
$miEdit = $gridMenu.Items.Add('Edit info...')
$miEdit.Add_Click({ Edit-SelectedMetadata })
$grid.Add_CellMouseDown({
    param($s, $e)
    if ($e.Button -eq [Windows.Forms.MouseButtons]::Right -and $e.RowIndex -ge 0) {
        $grid.ClearSelection(); $grid.Rows[$e.RowIndex].Selected = $true; $grid.CurrentCell = $grid.Rows[$e.RowIndex].Cells[$e.ColumnIndex]
        $gridMenu.Show($grid, $grid.PointToClient([Windows.Forms.Cursor]::Position))
    }
})
#endregion

# right-click a column header to hide it quickly (bring it back with the Columns button)
$grid.Add_ColumnHeaderMouseClick({
    param($s, $e)
    if ($e.Button -eq [Windows.Forms.MouseButtons]::Right) {
        $grid.Columns[$e.ColumnIndex].Visible = $false
        Save-Settings
    }
})

$btnExport.Add_Click({
    if ($script:ScanResults.Count -eq 0) {
        [Windows.Forms.MessageBox]::Show('Run a scan first.', 'Export CSV', 'OK', 'Information') | Out-Null; return
    }
    $dlg = New-Object Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV file (*.csv)|*.csv'; $dlg.FileName = 'MediaLibrary.csv'
    $dlg.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
    if ($dlg.ShowDialog($form) -ne [Windows.Forms.DialogResult]::OK) { return }
    try {
        $view = if ($grid.DataSource -is [System.Data.DataTable]) { $grid.DataSource.DefaultView } else { $null }
        if ($view -and $txtFilter.Text.Trim() -and $view.Count -ne $script:ScanResults.Count) {
            # a filter is active: export exactly the rows currently shown
            $names = @($grid.DataSource.Columns | ForEach-Object { $_.ColumnName })
            $out = foreach ($drv in $view) {
                $o = [ordered]@{}
                foreach ($n in $names) {
                    $v = $drv[$n]; if ($v -is [DBNull]) { $v = $null }
                    if ($n -eq 'RuntimeMin') { $o['Runtime'] = Format-Runtime $v } else { $o[$n] = $v }
                }
                [pscustomobject]$o
            }
            @($out) | Export-Csv -LiteralPath $dlg.FileName -NoTypeInformation -Encoding UTF8
            $lblStatus.Text = "Exported $($view.Count) filtered rows to $($dlg.FileName)"
        }
        else {
            $script:ScanResults | ForEach-Object {
                $o = [ordered]@{}
                foreach ($p in $_.PSObject.Properties) {
                    if ($p.Name -eq 'RuntimeMin') { $o['Runtime'] = Format-Runtime $p.Value } else { $o[$p.Name] = $p.Value }
                }
                [pscustomobject]$o
            } | Export-Csv -LiteralPath $dlg.FileName -NoTypeInformation -Encoding UTF8
            $lblStatus.Text = "Exported $($script:ScanResults.Count) rows to $($dlg.FileName)"
        }
    }
    catch { [Windows.Forms.MessageBox]::Show("Export failed:`n$_", 'Export CSV', 'OK', 'Error') | Out-Null }
})

function Get-LibraryName {
    if ($radPlex.Checked) { return 'Plex Library' }
    $n = Split-Path -Leaf ($txtFolder.Text.Trim().TrimEnd('\'))
    if ($n) { $n } else { 'Media Library' }
}

function Test-DashboardReady {
    if ($script:ScanResults.Count -eq 0) {
        [Windows.Forms.MessageBox]::Show('Run a scan first - the dashboard is built from the scan results.', 'Dashboard', 'OK', 'Information') | Out-Null
        return $false
    }
    if (-not (Test-Path -LiteralPath $script:TemplatePath)) {
        [Windows.Forms.MessageBox]::Show("The dashboard needs dashboard-template.html in the same folder as this script.`n`nLooked for:`n$($script:TemplatePath)`n`nCopy the file into that folder and click Dashboard again.", 'Dashboard', 'OK', 'Warning') | Out-Null
        return $false
    }
    $true
}

function Show-DashboardView {
    # Builds the dashboard (only if the scan changed) and shows it inside the window.
    # Falls back to the default browser if the embedded WebView2 cannot start.
    if (-not (Test-DashboardReady)) { return }

    $btnDash.Enabled = $false; $btnScan.Enabled = $false; $btnSaveHtml.Enabled = $false
    try {
        if ($script:DashboardStale -or -not (Test-Path -LiteralPath $script:LiveDashboard)) {
            New-MediaDashboard -Records $script:ScanResults -OutFile $script:LiveDashboard -LibraryName (Get-LibraryName)
            $script:DashboardStale = $false
        }
        $url = ([Uri]$script:LiveDashboard).AbsoluteUri + '?t=' + [DateTime]::Now.Ticks

        if (Initialize-WebView2) {
            Set-View 'dashboard'                       # make the host visible before the control is created
            Show-DashboardPane -Url $url
            Set-UiProgress -Text 'Dashboard ready.' -Value 1 -Max 1
        }
        else {
            if (-not $script:WebView2Notified) {
                $script:WebView2Notified = $true
                [Windows.Forms.MessageBox]::Show(
                    ("The embedded dashboard needs the Microsoft Edge WebView2 runtime and three small files.`n`nReason: {0}`n`nThe dashboard was opened in your browser instead. To enable the embedded view:`n- install the Evergreen runtime: https://go.microsoft.com/fwlink/p/?LinkId=2124703`n- and/or copy Microsoft.Web.WebView2.Core.dll, Microsoft.Web.WebView2.WinForms.dll and WebView2Loader.dll (from the Microsoft.Web.WebView2 NuGet package) into:`n{1}" -f $script:WebView2Error, $script:LibFolder),
                    'Embedded dashboard unavailable', 'OK', 'Information') | Out-Null
            }
            Start-Process $script:LiveDashboard
            Set-UiProgress -Text 'Dashboard opened in your browser (embedded view unavailable).'
        }
    }
    catch { [Windows.Forms.MessageBox]::Show("Could not build the dashboard:`n$_", 'Dashboard', 'OK', 'Error') | Out-Null }
    finally { $btnDash.Enabled = $true; $btnScan.Enabled = $true; $btnSaveHtml.Enabled = $true }
}

$btnDash.Add_Click({ Show-DashboardView })
$btnViewDash.Add_Click({ Show-DashboardView })

$btnSaveHtml.Add_Click({
    if (-not (Test-DashboardReady)) { return }
    $dlg = New-Object Windows.Forms.SaveFileDialog
    $dlg.Filter = 'HTML dashboard (*.html)|*.html'; $dlg.FileName = 'MediaDashboard.html'
    $dlg.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
    if ($dlg.ShowDialog($form) -ne [Windows.Forms.DialogResult]::OK) { return }

    $btnDash.Enabled = $false; $btnScan.Enabled = $false; $btnSaveHtml.Enabled = $false
    try {
        New-MediaDashboard -Records $script:ScanResults -OutFile $dlg.FileName -LibraryName (Get-LibraryName) -EmbedPosters:$chkEmbed.Checked
        Set-UiProgress -Text "Dashboard saved: $($dlg.FileName)" -Value 1 -Max 1
        Start-Process $dlg.FileName
    }
    catch { [Windows.Forms.MessageBox]::Show("Could not save the dashboard:`n$_", 'Save HTML', 'OK', 'Error') | Out-Null }
    finally { $btnDash.Enabled = $true; $btnScan.Enabled = $true; $btnSaveHtml.Enabled = $true }
})

$btnScan.Add_Click({
    $usePlex = [bool]$radPlex.Checked
    $folder  = $txtFolder.Text.Trim()

    if ($usePlex) {
        if (-not $chkMovies.Checked -and -not $chkShows.Checked) {
            [Windows.Forms.MessageBox]::Show('Select Movies and/or TV Shows.', 'Modern Media Library Manager', 'OK', 'Warning') | Out-Null; return
        }
        if (-not (Confirm-PlexToken -BaseUrl $folder)) { return }
        $folder = $txtFolder.Text.Trim()           # the connect dialog may have changed the address
    }
    else {
        if ([string]::IsNullOrWhiteSpace($folder)) {
            [Windows.Forms.MessageBox]::Show('Please choose a folder to scan (a UNC path such as \\server\share\Movies works).', 'Modern Media Library Manager', 'OK', 'Warning') | Out-Null; return
        }
        if (-not $chkVideo.Checked -and -not $chkAudio.Checked) {
            [Windows.Forms.MessageBox]::Show('Select at least one media type (Video or Audio).', 'Modern Media Library Manager', 'OK', 'Warning') | Out-Null; return
        }
        try { Initialize-MediaInfoModule }
        catch {
            [Windows.Forms.MessageBox]::Show("Could not initialize the MediaInfo module:`n$_", 'Modern Media Library Manager', 'OK', 'Error') | Out-Null; return
        }
    }

    if ($chkFel.Checked -and -not ((Find-Tool 'ffmpeg.exe') -and (Find-Tool 'dovi_tool.exe'))) {
        [Windows.Forms.MessageBox]::Show(
            "FEL / MEL detection needs ffmpeg.exe and dovi_tool.exe.`n`nCopy both into:`n$($script:LibFolder)`n(or put them on your PATH) and scan again.`n`nThis scan will continue without it - dual-layer files will show as 'Dual layer'.",
            'Detect FEL / MEL', 'OK', 'Information') | Out-Null
        $chkFel.Checked = $false
    }

    Save-Settings          # capture folder, options and the current column layout BEFORE the grid is rebuilt

    $script:Sync = [hashtable]::Synchronized(@{
        Text = 'Starting...'; Value = 0; Max = 0; Total = 0; Cancel = $false; Done = $false; Error = $null; Results = $null; Workers = [int]$nudPar.Value
        Partial = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
    })
    $script:ScanUsePlex = $usePlex
    $script:ScanMode    = 'Scan'
    $script:ScanWatch   = [Diagnostics.Stopwatch]::StartNew()
    $script:CancelAt    = $null
    $script:RateT = $null; $script:RateV = 0; $script:RateVal = $null
    $script:EtaStep = @{ T = $null; F = 0.0; R = $null }; $script:EtaAll = @{ T = $null; F = 0.0; R = $null }; $script:LastPhase = 0
    $script:WkT = $null; $script:WkPrev = @{}; $script:WkRate = @{}; $script:WkBusy = @{}; $script:WkOvPrev = 0; $script:WkOvRate = $null; $script:WkCpu = $null; $script:WkCpuPrev = 0.0

    $btnScan.Enabled = $false; $btnBrowse.Enabled = $false; $btnDash.Enabled = $false; $btnSaveHtml.Enabled = $false; $btnExport.Enabled = $false; $btnCancel.Enabled = $true; $btnFetch.Enabled = $false
    Set-OverallProgress -Fraction 0.0
    $script:ScanResults = @()
    $script:DashboardStale = $true
    $grid.DataSource = $null
    $lblCount.Text = ''
    $lblStatus.Text = 'Starting...'

    try {
        if ($usePlex) {
            Start-ScanWorker -Mode 'Plex' -ScanArgs @{
                BaseUrl = $folder; Token = $script:PlexToken; Movies = [bool]$chkMovies.Checked; Shows = [bool]$chkShows.Checked
                Rebuild = [bool]$chkRebuild.Checked; DetectFel = [bool]$chkFel.Checked }
        }
        else {
            Start-ScanWorker -Mode 'Folder' -ScanArgs @{
                Folder = $folder; Video = [bool]$chkVideo.Checked; Audio = [bool]$chkAudio.Checked
                Rebuild = [bool]$chkRebuild.Checked; DetectFel = [bool]$chkFel.Checked; Parallel = [int]$nudPar.Value }
        }
        $script:ScanTimer.Start()
    }
    catch {
        [Windows.Forms.MessageBox]::Show("Could not start the scan:`n$_", 'Modern Media Library Manager', 'OK', 'Error') | Out-Null
        $btnScan.Enabled = $true; $btnBrowse.Enabled = $true; $btnDash.Enabled = $true; $btnSaveHtml.Enabled = $true; $btnExport.Enabled = $true; $btnCancel.Enabled = $false; $btnFetch.Enabled = $true
    }
})

function Complete-Scan {
    # Runs on the UI thread once the background worker has finished (or was abandoned after Cancel).
    param([bool]$Abandoned = $false)
    $script:ScanTimer.Stop()
    $s  = $script:Sync
    $ps = $script:ScanPs
    $results = @()
    if ($Abandoned) {
        # The worker is stuck inside a network call that will not return. Keep what it has finished so far and move on.
        $script:ScanZombie = $ps
        try { [void]$ps.BeginStop($null, $null) } catch { }
        $results = @($s.Partial.ToArray())
    }
    else {
        try { [void]$ps.EndInvoke($script:ScanAsync) } catch { }
        try { $ps.Dispose(); $script:ScanRs.Dispose() } catch { }
        if ($null -ne $s.Results) { $results = @($s.Results) }
    }
    $script:ScanPs = $null; $script:ScanRs = $null; $script:ScanAsync = $null
    $script:ScanWatch.Stop()

    try {
        if ($s.Error) {
            $msg = [string]$s.Error
            if ($msg -match 'rejected the token') { $script:PlexToken = ''; $script:Settings['PlexTokenProtected'] = ''; $msg += "`n`nClick Token... to enter a new one." }
            $lblStatus.Text = 'Scan failed.'
            $title = if ($script:ScanUsePlex) { 'Plex' } else { 'Modern Media Library Manager' }
            [Windows.Forms.MessageBox]::Show("The scan could not finish:`n$msg", $title, 'OK', 'Error') | Out-Null
            return
        }
        $script:ScanResults = $results
        $cancelled = [bool]$s.Cancel
        if ($results.Count -eq 0 -and -not $cancelled) {
            $lblStatus.Text = 'Nothing found.'
            $lblEmpty.Text = if ($script:ScanUsePlex) { 'Plex returned no movies or episodes for that selection.' } else { 'No matching media files were found in that folder.' }
            return
        }
        if ($results.Count -gt 0) {
            try { Merge-MetaStore -Records $results -Path $script:MetaStorePath } catch { }
            $table = ConvertTo-DataTable -Records $results
            $grid.DataSource = $table
            Set-GridColumnLayout     # remembered visibility/widths; brand-new fields fall back to their default
            $grid.ClearSelection()
            Update-Filter
        }
        $state = if ($cancelled) { 'Cancelled' } else { 'Done' }
        $total = [int]$s.Total
        $took  = ' in {0:N0}s' -f $script:ScanWatch.Elapsed.TotalSeconds
        $lblStatus.Text = "$state. $($results.Count) of $total item(s) processed$took."
        if ($script:ScanMode -eq 'Scrape') { $lblStatus.Text = "$state. $([string]$s.Summary)" }
        if (-not $cancelled) { Set-OverallProgress -Fraction 1.0 }
    }
    finally {
        $btnScan.Enabled = $true; $btnBrowse.Enabled = $true; $btnDash.Enabled = $true; $btnSaveHtml.Enabled = $true; $btnExport.Enabled = $true; $btnCancel.Enabled = $false; $btnFetch.Enabled = $true
        Set-View 'grid'
    }
}

function Update-ScanState {
    $s = $script:Sync
    $text = [string]$s.Text
    if ($s.Cancel -and -not $s.Done) { $text = 'Cancelling... ' + $text }
    # Local scans: show how many readers are running and the recent speed (measured over ~1.5 s).
    if ($s.Max -gt 0 -and -not $script:ScanUsePlex -and $null -ne $s.Active) {
        $now = [Environment]::TickCount
        if ($null -eq $script:RateT -or ($now - $script:RateT) -ge 1500) {
            if ($null -ne $script:RateT -and $now -gt $script:RateT) { $script:RateVal = ([int]$s.Value - $script:RateV) * 1000.0 / ($now - $script:RateT) }
            $script:RateT = $now; $script:RateV = [int]$s.Value
        }
        if ($null -ne $script:RateVal -and -not $s.Cancel) { $text += ('   [{0} reader(s), {1:N1} files/s]' -f $s.Active, $script:RateVal) }
    }
    $lblStatus.Text = $text
    # Step bar = the counter of the step now running; overall bar = that step's slice of the whole job.
    $phId = [int]$s.PhaseId
    if ($phId -ne $script:LastPhase) {            # a new step began: its bar and ETA start over
        $script:LastPhase = $phId
        $script:EtaStep = @{ T = $null; F = 0.0; R = $null }
    }
    $stepFrac = 0.0
    if ($s.Max -gt 0) { $stepFrac = [Math]::Min(1.0, ($s.Value / [double]$s.Max)) }
    $lo = [double]$s.PhaseLo; $hi = [double]$s.PhaseHi
    if ($hi -le $lo) { $hi = $lo }
    $allFrac = $lo + ($hi - $lo) * $stepFrac
    $etaStep = Update-EtaState -St $script:EtaStep -Frac $stepFrac -Cancelled ([bool]$s.Cancel)
    $etaAll  = Update-EtaState -St $script:EtaAll  -Frac $allFrac  -Cancelled ([bool]$s.Cancel)
    Set-Progress -Step $stepFrac -StepEta $etaStep -Overall $allFrac -OverallEta $etaAll
    if ($s.Done) { Complete-Scan; return }
    # Cancel was clicked but the worker is stuck in a network call: give it a few seconds, then abandon it.
    if ($s.Cancel -and $null -ne $script:CancelAt -and (((Get-Date) - $script:CancelAt).TotalSeconds -gt 6)) { Complete-Scan -Abandoned $true }
}

$script:ScanTimer = New-Object Windows.Forms.Timer
$script:ScanTimer.Interval = 150
$script:ScanTimer.Add_Tick({ try { Update-ScanState } catch { $lblStatus.Text = 'Scan update error: ' + $_.Exception.Message } })

# Restore the saved window size once the first layout is done (so anchored controls follow the resize).
$form.Add_Shown({
    # (Form.CenterToScreen is a protected method and cannot be called from PowerShell - centre by hand.)
    $wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $sw = [int]$script:Settings['ClientWidth']; $sh = [int]$script:Settings['ClientHeight']
    if ($sw -ge 1100 -and $sh -ge 600) {
        $form.ClientSize = New-Object Drawing.Size($sw, $sh)
        if ($form.Width -gt $wa.Width -or $form.Height -gt $wa.Height) {
            $form.ClientSize = New-Object Drawing.Size(1280, 780)       # saved size no longer fits this screen
        }
    }
    $x = $wa.X + [int](($wa.Width  - $form.Width)  / 2)
    $y = $wa.Y + [int](($wa.Height - $form.Height) / 2)
    $form.Location = New-Object Drawing.Point([math]::Max($wa.X, $x), [math]::Max($wa.Y, $y))

    # First launch with Plex as the source: ask for the token right away (it is stored encrypted afterwards).
    if ($radPlex.Checked -and -not $script:PlexToken) {
        [void](Show-PlexTokenDialog -BaseUrl $txtFolder.Text.Trim())
    }
})

$form.Add_FormClosing({ Save-Settings })

$form.Add_FormClosed({
    # A scan thread stuck in a network call must not keep the process alive after the window is gone.
    if ($script:ScanPs -or $script:ScanZombie) {
        try { if ($script:ScanPs) { [void]$script:ScanPs.BeginStop($null, $null) } } catch { }
        [Environment]::Exit(0)
    }
    if ($picPoster.Image) { $picPoster.Image.Dispose() }
    if ($script:PosterStream) { $script:PosterStream.Dispose() }
    if ($null -ne $script:wv) { try { $script:wv.Dispose() } catch { } }
})
#endregion

#region ---------------------------------------------------------------- Workers pane (live view of the parallel readers)
$script:WkT = $null; $script:WkPrev = @{}; $script:WkRate = @{}; $script:WkBusy = @{}
$script:WkOvPrev = 0; $script:WkOvRate = $null; $script:WkCpu = $null; $script:WkCpuPrev = 0.0
$script:WkRows = @(); $script:WkHead = $null
$script:WkRowH = 84
$script:cGreen = RGB 118 185 0
$script:cAmber = RGB 255 176 64
$script:cRed   = RGB 255 107 107
$script:wkBrText  = New-Object Drawing.SolidBrush($script:cText)
$script:wkBrMuted = New-Object Drawing.SolidBrush($script:cMuted)
$script:wkBrCard  = New-Object Drawing.SolidBrush($script:cPanel)
$script:wkBrTrack = New-Object Drawing.SolidBrush($script:cPanel2)
$script:wkBrAcc   = New-Object Drawing.SolidBrush($script:cAccent)
$script:wkBrAcc2  = New-Object Drawing.SolidBrush($script:cAccent2)
$script:wkBrGreen = New-Object Drawing.SolidBrush($script:cGreen)
$script:wkBrAmber = New-Object Drawing.SolidBrush($script:cAmber)
$script:wkBrRed   = New-Object Drawing.SolidBrush($script:cRed)
$script:wkSfTrim  = New-Object Drawing.StringFormat
$script:wkSfTrim.Trimming = 'EllipsisPath'; $script:wkSfTrim.FormatFlags = 'NoWrap'
$script:wkSfRight = New-Object Drawing.StringFormat
$script:wkSfRight.Alignment = 'Far'; $script:wkSfRight.FormatFlags = 'NoWrap'

function Format-Hms {
    param([double]$Seconds)
    if ($Seconds -lt 0 -or [double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds)) { return '--' }
    $t = [TimeSpan]::FromSeconds([Math]::Round($Seconds))
    '{0}:{1:00}:{2:00}' -f [int][Math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds
}

function Update-WorkersData {
    # Turns the live per-reader status records into what the pane draws. Speeds are measured over ~1.5 s windows.
    $s = $script:Sync
    $stats = $s.WorkerStats
    if ($null -eq $stats) { $script:WkRows = @(); $script:WkHead = $null; return }

    $now    = Get-NowMs
    $dt     = if ($null -ne $script:WkT) { $now - $script:WkT } else { 0 }
    $sample = ($null -eq $script:WkT) -or ($dt -ge 1500)
    $proc   = [Diagnostics.Process]::GetCurrentProcess()
    $cpuMs  = $proc.TotalProcessorTime.TotalMilliseconds
    if ($sample) {
        if ($dt -gt 0) {
            $script:WkOvRate = ([int]$s.Value - $script:WkOvPrev) * 1000.0 / $dt
            $script:WkCpu    = ($cpuMs - $script:WkCpuPrev) * 100.0 / ($dt * [Environment]::ProcessorCount)
        }
        $script:WkOvPrev = [int]$s.Value
        $script:WkCpuPrev = $cpuMs
    }

    $rows = New-Object System.Collections.Generic.List[object]
    for ($no = 1; $no -le 12; $no++) {
        $w = $stats[$no]
        if ($null -eq $w -or $w.State -eq 'Not started') { continue }
        $reading = ($w.State -eq 'Reading')
        $busyNow = [double]$w.BusyMs
        if ($reading) { $busyNow += ($now - [double]$w.Since) }
        $done = [int]$w.Done
        if ($sample) {
            $pv = $script:WkPrev[$no]
            if ($pv -and $dt -gt 0) {
                $script:WkRate[$no] = ($done - $pv.Done) * 1000.0 / $dt
                $script:WkBusy[$no] = [Math]::Max(0.0, [Math]::Min(100.0, ($busyNow - $pv.Busy) * 100.0 / $dt))
            }
            $script:WkPrev[$no] = @{ Done = $done; Busy = $busyNow }
        }
        $of   = [int]$w.Of
        $frac = if ($reading -and $of -gt 0) { [Math]::Min(1.0, [int]$w.Step / [double]$of) } else { 0.0 }
        [void]$rows.Add([pscustomobject]@{
            No = $no; State = [string]$w.State; File = [string]$w.File; Stage = [string]$w.Stage
            Elapsed = $(if ($reading) { ($now - [double]$w.Since) / 1000.0 } else { $null })
            Frac = $frac; Done = $done; Rate = $script:WkRate[$no]; Busy = $script:WkBusy[$no]
        })
    }
    if ($sample) { $script:WkT = $now }
    $script:WkRows = $rows.ToArray()

    $active = @($script:WkRows | Where-Object { $_.State -in @('Reading', 'Idle') }).Count
    $total  = [int]$s.Max
    $value  = [int]$s.Value
    $rate   = $script:WkOvRate
    $eta    = if ($rate -and $rate -gt 0.05 -and $total -gt $value) { ($total - $value) / $rate } else { $null }
    $script:WkHead = @{
        Done = $value; Total = $total; Rate = $rate; Eta = $eta; Readers = $active; Cpu = $script:WkCpu
        Threads = $proc.Threads.Count; Elapsed = $script:ScanWatch.Elapsed.TotalSeconds; Finished = [bool]$s.Done
    }
    $proc.Dispose()
}

function New-RoundRectPath {
    param([float]$X, [float]$Y, [float]$W, [float]$H, [float]$R)
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $d = $R * 2
    $path.AddArc($X, $Y, $d, $d, 180, 90)
    $path.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $path.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
    $path.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $path
}

function Show-WorkersPane {
    if ($null -ne $script:WkForm -and -not $script:WkForm.IsDisposed) { Set-WorkersPanePosition -Force; $script:WkForm.Show($form); Update-WorkersView; return }

    $f = New-Object Windows.Forms.Form
    $f.Text = 'Workers'
    $f.FormBorderStyle = 'SizableToolWindow'
    $f.ShowInTaskbar = $false
    $f.StartPosition = 'Manual'
    $f.BackColor = $script:cBg; $f.ForeColor = $script:cText; $f.Font = $script:fontBase
    $f.MinimumSize = New-Object Drawing.Size(380, 320)
    $f.ClientSize = New-Object Drawing.Size(470, 600)

    $hdr = New-Object BufferedPanel
    $hdr.Dock = 'Top'; $hdr.Height = 104; $hdr.BackColor = $script:cPanel2

    $host2 = New-Object Windows.Forms.Panel
    $host2.Dock = 'Fill'; $host2.AutoScroll = $true; $host2.BackColor = $script:cBg

    $list = New-Object BufferedPanel
    $list.Location = New-Object Drawing.Point(0, 0)
    $list.Width = 470; $list.Height = 200
    $list.BackColor = $script:cBg
    $host2.Controls.Add($list)

    $f.Controls.Add($host2)
    $f.Controls.Add($hdr)
    $script:WkForm = $f; $script:WkHdr = $hdr; $script:WkHost = $host2; $script:WkList = $list

    $host2.Add_Resize({ $script:WkList.Width = [Math]::Max(300, $script:WkHost.ClientSize.Width); $script:WkList.Invalidate() })

    $hdr.Add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $g.TextRenderingHint = 'ClearTypeGridFit'
        $h = $script:WkHead
        $w = $sender.ClientSize.Width
        if ($null -eq $h) {
            $g.DrawString('Workers', $script:fontBig, $script:wkBrText, 16, 12)
            $g.DrawString('Start a local scan to watch the readers work.', $script:fontBase, $script:wkBrMuted, 16, 48)
            return
        }
        $title = if ($h.Total -gt 0) { '{0:N0} of {1:N0} files' -f $h.Done, $h.Total } else { 'Starting...' }
        $g.DrawString($title, $script:fontBig, $script:wkBrText, 16, 8)
        $state = if ($h.Finished) { 'Finished' } else { 'Running' }
        $rect = New-Object Drawing.RectangleF(0, 14, ($w - 16), 20)
        $g.DrawString($state, $script:fontBold, $(if ($h.Finished) { $script:wkBrGreen } else { $script:wkBrAcc }), $rect, $script:wkSfRight)

        $rateTxt = if ($null -ne $h.Rate) { '{0:N1} files/s' -f $h.Rate } else { '... files/s' }
        $etaTxt  = if ($h.Finished) { 'done' } elseif ($null -ne $h.Eta) { 'ETA ' + (Format-Hms $h.Eta) } else { 'ETA --' }
        $g.DrawString(('{0}     {1}     {2} reader(s)' -f $rateTxt, $etaTxt, $h.Readers), $script:fontBase, $script:wkBrText, 16, 42)
        $cpuTxt = if ($null -ne $h.Cpu) { 'CPU {0:N0}%' -f $h.Cpu } else { 'CPU ...' }
        $g.DrawString(('{0}     {1} threads     elapsed {2}' -f $cpuTxt, $h.Threads, (Format-Hms $h.Elapsed)), $script:fontSmall, $script:wkBrMuted, 16, 66)

        $barW = $w - 32
        $g.FillRectangle($script:wkBrCard, 16, 90, $barW, 6)
        if ($h.Total -gt 0) {
            $fw = [int]($barW * [Math]::Min(1.0, $h.Done / [double]$h.Total))
            if ($fw -gt 0) { $g.FillRectangle($script:wkBrAcc, 16, 90, $fw, 6) }
        }
    })

    $list.Add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = 'AntiAlias'
        $g.TextRenderingHint = 'ClearTypeGridFit'
        $rows = @($script:WkRows)
        $w = $sender.ClientSize.Width
        if ($rows.Count -eq 0) {
            $g.DrawString('No readers yet.', $script:fontBase, $script:wkBrMuted, 16, 16)
            return
        }
        $rh = $script:WkRowH
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $r  = $rows[$i]
            $y  = 8 + $i * $rh
            $cw = $w - 24
            $path = New-RoundRectPath 12 $y $cw ($rh - 8) 8
            $g.FillPath($script:wkBrCard, $path)
            $path.Dispose()

            $probing = ($r.Stage -like 'FEL probe*')
            $label = $r.State; $br = $script:wkBrMuted
            switch ($r.State) {
                'Reading'   { $label = if ($probing) { 'Probing FEL / MEL' } else { 'Reading' }; $br = if ($probing) { $script:wkBrAmber } else { $script:wkBrAcc } }
                'Idle'      { $label = 'Idle'; $br = $script:wkBrMuted }
                'Finished'  { $label = 'Finished'; $br = $script:wkBrGreen }
                'Stopped'   { $label = 'Stopped (count lowered)'; $br = $script:wkBrMuted }
                'Cancelled' { $label = 'Cancelled'; $br = $script:wkBrMuted }
                'Error'     { $label = 'Error'; $br = $script:wkBrRed }
            }
            $g.DrawString(('Reader {0}' -f $r.No), $script:fontBold, $script:wkBrText, 24, $y + 8)
            $g.DrawString($label, $script:fontSmall, $br, 104, $y + 10)
            $busyTxt = if ($null -ne $r.Busy) { '{0:N0}% busy' -f $r.Busy } else { '... busy' }
            $g.DrawString($busyTxt, $script:fontSmall, $script:wkBrMuted, (New-Object Drawing.RectangleF(0, ($y + 10), ($w - 24), 18)), $script:wkSfRight)

            $fileTxt = if ($r.File) { $r.File } else { '-' }
            $g.DrawString($fileTxt, $script:fontBase, $(if ($r.State -eq 'Reading') { $script:wkBrText } else { $script:wkBrMuted }), (New-Object Drawing.RectangleF(24, ($y + 29), ($w - 48), 20)), $script:wkSfTrim)

            $stageTxt = $r.Stage
            if ($null -ne $r.Elapsed) { $stageTxt = '{0}  -  {1:N1}s' -f $r.Stage, $r.Elapsed }
            $g.DrawString($stageTxt, $script:fontSmall, $script:wkBrMuted, (New-Object Drawing.RectangleF(24, ($y + 49), ($w - 200), 16)), $script:wkSfTrim)
            $rateTxt = if ($null -ne $r.Rate) { '{0:N1} files/s  -  {1:N0} done' -f $r.Rate, $r.Done } else { '{0:N0} done' -f $r.Done }
            $g.DrawString($rateTxt, $script:fontSmall, $script:wkBrMuted, (New-Object Drawing.RectangleF(0, ($y + 49), ($w - 24), 16)), $script:wkSfRight)

            $bw = $cw - 24
            $g.FillRectangle($script:wkBrTrack, 24, $y + 66, $bw, 5)
            if ($r.Frac -gt 0) { $g.FillRectangle($(if ($probing) { $script:wkBrAmber } else { $script:wkBrAcc }), 24, $y + 66, [int]($bw * $r.Frac), 5) }
            $g.FillRectangle($script:wkBrTrack, 24, $y + 73, $bw, 3)
            if ($null -ne $r.Busy -and $r.Busy -gt 0) { $g.FillRectangle($script:wkBrGreen, 24, $y + 73, [int]($bw * $r.Busy / 100.0), 3) }
        }
    })

    $f.Add_FormClosing({
        param($sender, $e)
        if ($e.CloseReason -eq 'UserClosing') { $e.Cancel = $true; $sender.Hide() }
    })
    $f.Add_VisibleChanged({
        if ($script:WkForm.Visible) { $script:WkTimer.Start() } else { $script:WkTimer.Stop() }
    })

    $script:WkTimer = New-Object Windows.Forms.Timer
    $script:WkTimer.Interval = 250
    $script:WkTimer.Add_Tick({ try { Update-WorkersView } catch { } })

    Set-WorkersPanePosition -Force
    $f.Show($form)
    Update-WorkersView
}

function Update-WorkersView {
    Update-WorkersData
    $need = 8 + (@($script:WkRows).Count * $script:WkRowH) + 8
    if ($script:WkList.Height -ne $need) { $script:WkList.Height = [Math]::Max($need, 60) }
    $script:WkHdr.Invalidate()
    $script:WkList.Invalidate()
}

function Set-WorkersPanePosition {
    # Keeps the pane glued to the right edge of the main window (or on screen if there is no room).
    param([switch]$Force)
    if ($null -eq $script:WkForm -or $script:WkForm.IsDisposed) { return }
    if (-not $Force -and -not $script:WkForm.Visible) { return }
    $wa = [Windows.Forms.Screen]::FromControl($form).WorkingArea
    $b  = $form.Bounds
    $w  = $script:WkForm.Width
    $x  = $b.Right
    if ($x + $w -gt $wa.Right) { $x = [Math]::Max($wa.X, $wa.Right - $w) }
    $script:WkForm.Location = New-Object Drawing.Point($x, $b.Top)
    $script:WkForm.Height = $b.Height
}

$btnWorkers.Add_Click({
    if ($null -ne $script:WkForm -and -not $script:WkForm.IsDisposed -and $script:WkForm.Visible) { $script:WkForm.Hide() }
    else { Show-WorkersPane }
})
$tip.SetToolTip($btnWorkers, 'Show or hide a live panel with every reader: its file, stage, speed and how busy it is.')
$form.Add_LocationChanged({ Set-WorkersPanePosition })
$form.Add_SizeChanged({ Set-WorkersPanePosition })
#endregion

if ($script:Settings['Source'] -eq 'Local') { $radLocal.Checked = $true } else { $radPlex.Checked = $true }
Set-SourceMode ([bool]$radPlex.Checked)
$radPlex.Add_CheckedChanged({ Set-SourceMode ([bool]$radPlex.Checked) })
# The reader count can be changed while a local scan is running; the scan picks it up within a second.
$nudPar.Add_ValueChanged({ $script:Sync.Workers = [int]$nudPar.Value })

Set-View 'grid'
[void]$form.ShowDialog()
