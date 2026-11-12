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
        tv-template.html           TV Shows page (posters and the show / season / episode grid)
        modules\MMLM.*.psm1        the data logic with no UI: Library (records, local scan), Plex, Fetch (online info)
        src\Mmlm.Native.cs         small C# helper (TV page data, library snapshot), compiled on first use
        lib\                       WebView2 DLLs - created automatically on first use of the Dashboard view
                                   (or copy Microsoft.Web.WebView2.Core.dll, ...WinForms.dll and WebView2Loader.dll in yourself)
        Run-ModernMediaLibraryManager.cmd  optional double-click launcher

    Adding a metadata field = add one line to $script:FieldDefs below, then one assignment in
    Get-MmlmMediaInfoRecord. The grid, detail view, CSV and dashboard JSON pick it up automatically.

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
$script:AppVersion      = '0.14.0'    # must match the release tag (vX.Y.Z); the release workflow checks it
$script:CacheVersion    = 4          # bump when the record schema changes
$script:AppData         = Join-Path $env:LOCALAPPDATA 'Modern-Media-Library-Manager'
$script:CacheFolder     = Join-Path $script:AppData 'Cache'
$script:ThumbFolder     = Join-Path $script:AppData 'Thumbs'
$script:LibFolder       = Join-Path $script:AppRoot 'lib'                          # WebView2 DLLs live here (auto-downloaded)
$script:SettingsPath    = Join-Path $script:AppData 'settings.json'
$script:MetaStorePath   = Join-Path $script:AppData 'metadata\store.json'      # fetched + hand-typed values
$script:CollectionsPath = Join-Path $script:AppData 'collections.json'         # custom title lists (collections)
$script:DataFolder      = Join-Path $script:AppData 'datasets'                 # IMDb ratings file
$script:InformFolder     = Join-Path $script:AppData 'Inform'                       # full MediaInfo text per file (source-clue research)
$script:LiveFolder      = Join-Path $script:AppData 'Dashboard'                    # dashboard shown inside the app
$script:SnapshotFolder  = Join-Path $script:AppData 'Library'                      # last scan of each tab (movies.mmls / tv.mmls), loaded at start
$script:LiveDashboard   = Join-Path $script:LiveFolder 'index.html'
$script:Culture         = [Globalization.CultureInfo]::InvariantCulture

# runtime state
$script:DashboardStale  = $true      # set after every scan so the dashboard is rebuilt on demand
$script:DashboardUrl    = ''
$script:CurrentView     = 'grid'
$script:Tab             = 'Movies'          # library tab: 'Movies' (default) or 'TV'
$script:TabCounts       = @{ Movies = 0; TV = 0 }
$script:Scanning        = $false            # a scan is running (it owns one tab; the other tab stays usable)
$script:ScanTab         = ''
$script:EmptyText       = $null
$script:DetailStale     = $true
$script:CardReturn      = $null             # view to go back to when a card opened from the posters is closed
$script:TabView         = @{ Movies = 'grid'; TV = 'poster' }   # each tab remembers its own view; TV opens on posters
$script:MovieTable      = $null             # grid table for the Movies tab (TV has no WinForms grid: its views are tv.html in the embedded browser)
$script:TvRecords       = @()               # this scan's episodes
$script:TvPageStale     = $true             # tvdata.js needs writing again
$script:TvPageTicks     = 0                 # cache-buster for tv.html after a rewrite
$script:WebShowing      = ''                # what the embedded browser shows: 'tv:<ticks>' or 'dash'
$script:TvTemplatePath  = Join-Path $script:AppRoot 'tv-template.html'
$script:TvFromDisk      = $false            # the TV page is showing last session's tvdata.js while the TV records load
$script:TvLoad          = $null             # background load of tv.mmls: @{ Ps; Async }
$script:SnapJobs        = New-Object System.Collections.ArrayList     # background snapshot saves still running
$script:WebView2Ready   = $false
$script:WebView2Failed  = $false
$script:WebView2Error   = ''
$script:WebView2Notified = $false
$script:wv              = $null

$script:VideoExtensions = @('264','265','asf','avc','avi','divx','flv','h264','h265','hevc','m2ts','m2v','m4v','mkv','mov','mp4','mpeg','mpg','mpv','mts','ts','vob','webm','wmv')
$script:AudioExtensions = @('aac','ac3','dts','dtshd','dtshr','dtsma','eac3','flac','m4a','mka','mp2','mp3','mpa','ogg','opus','thd','w64','wav')
$script:PosterNames     = @('poster','folder','cover','movie','thumb')     # besides "<filename>-poster"
$script:ImageExtensions = @('jpg','jpeg','png','bmp')

foreach ($dir in @($script:CacheFolder, $script:ThumbFolder, $script:LiveFolder, $script:SnapshotFolder)) {
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
    'Source|string|File|1',            'SourceWhy|string|File|0',          'Added|string|File|1',              'Modified|string|File|0',
    'Directory|string|File|0',         'FullPath|string|File|0',

    'HasNfo|bool|Library|0',           'HasPoster|bool|Library|0',         'PosterPath|string|Library|0',
    'ViewCount|int|Library|0',         'LastViewed|string|Library|0',      'PlexKey|string|Library|0',
    'PlexThumb|string|Library|0',       'MetaSources|string|Library|0',

    # Scores and money (filled by Fetch info or typed by hand; whole US dollars)
    'RTCritic|int|Ratings|1',          'RTAudience|int|Ratings|1',         'Metascore|int|Ratings|1',        'CinemaScore|string|Ratings|1',   'RatingSource|string|Ratings|0',
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
# ---- Source labels, worked out from the measurements (file names are NOT used) -------------------------
# Six plain labels plus DV/HDR Hybrid. Movies only: TV episodes keep the older name-based label until TV support is finished.
$script:SourceLabels  = @('4K Remux', '4K Web-DL', 'Blu-ray Remux', 'Blu-ray Encode', 'DVD', 'DV/HDR Hybrid', 'Unknown')
$script:Uhd4kMinGB    = 30      # a 4K file below this is a Web-DL (size decides first)
$script:Fhd1080MinGB  = 15      # a 1080p stream copy below this is an encode
$script:Uhd4kMinMbps  = 35      # a 4K HEVC file at or above this video bitrate is remux-class even when it is small (short films)

function Get-SourceClass {
    # Returns @{ Label; Why } for one record.
    param($Rec)
    $rc    = [string]$Rec.ResolutionClass
    $codec = [string]$Rec.VideoCodec
    $gb    = 0.0; try { $gb = [double]$Rec.FileSizeGB } catch { }
    $gbT   = '{0:N1} GB' -f $gb
    $dvp   = [string]$Rec.DVProfile
    $hasDV = ([string]$Rec.HDRType -eq 'Dolby Vision') -or ($dvp -ne '')
    $enc   = ([string]$Rec.VideoEncLib + ' ' + [string]$Rec.Encoder)
    $x     = ''; if ($enc -match '(?i)(x26[45])') { $x = $Matches[1].ToLowerInvariant() }
    $ff    = ''; if ($enc -match '(?i)(hevc_nvenc|h264_nvenc|hevc_qsv|h264_qsv|hevc_amf|h264_amf|libx26[45]|Lavc)') { $ff = 'ffmpeg' }     # re-encoded with ffmpeg: never a disc remux
    $mbps  = 0.0; try { $mbps = [double]$Rec.VideoBitRateMbps } catch { }

    if (-not $codec -or @('4K', '1440p', '1080p', '720p', 'SD') -notcontains $rc) {
        return @{ Label = 'Unknown'; Why = 'No usable video stream or resolution' }
    }
    if ($rc -eq 'SD') { return @{ Label = 'DVD'; Why = '480p/576p or below' } }

    if ($hasDV -and $x) {
        $pt = if ($dvp) { "profile $dvp" } else { 'profile unknown' }
        return @{ Label = 'DV/HDR Hybrid'; Why = "Dolby Vision ($pt) with an $x encoder tag, $rc, $gbT" }
    }

    if ($rc -eq '4K') {
        if ($codec -ne 'HEVC') { return @{ Label = '4K Web-DL'; Why = "4K but $codec - UHD discs are HEVC, $gbT" } }
        if ($ff)               { return @{ Label = '4K Web-DL'; Why = "4K re-encoded with ffmpeg, $gbT" } }
        if ($dvp -match '^5')  { return @{ Label = '4K Web-DL'; Why = "Dolby Vision profile 5 is streaming-only, $gbT" } }
        if ($dvp -match '^7')  { return @{ Label = '4K Remux';  Why = "Dolby Vision profile 7 (dual layer) is a disc format, $gbT" } }
        if ($gb -ge $script:Uhd4kMinGB) {
            $w = "4K HEVC, $gbT ($($script:Uhd4kMinGB) GB or more)"
            if ($x) { $w += ", $x tag" }
            return @{ Label = '4K Remux'; Why = $w }
        }
        if ((-not $x) -and $mbps -ge $script:Uhd4kMinMbps) {
            return @{ Label = '4K Remux'; Why = ('4K HEVC, {0} but {1:N0} Mbps video (remux-class bitrate, short film)' -f $gbT, $mbps) }
        }
        $w = "4K HEVC, $gbT (under $($script:Uhd4kMinGB) GB)"
        if ($x) { $w += ", $x re-encode" }
        return @{ Label = '4K Web-DL'; Why = $w }
    }

    if ($rc -eq '1080p') {
        $disc = ($codec -eq 'VC-1') -or ($codec -eq 'MPEG') -or ([string]$Rec.Container -eq 'BDAV')
        $copy = (@('AVC', 'VC-1', 'MPEG') -contains $codec) -and (-not $x) -and (-not $ff)
        if ($copy -and ($disc -or $gb -ge $script:Fhd1080MinGB)) {
            return @{ Label = 'Blu-ray Remux'; Why = "1080p $codec, no encoder tag, $gbT" }
        }
        $w = if ($x) { "1080p, $x re-encode" } else { "1080p $codec, $gbT" }
        if ($copy) { $w += " (stream copy but under $($script:Fhd1080MinGB) GB)" }
        return @{ Label = 'Blu-ray Encode'; Why = $w }
    }
    @{ Label = 'Blu-ray Encode'; Why = "$rc, $codec, $gbT" }
}

function Set-SourceLabels {
    param([object[]]$Records)
    foreach ($rec in $Records) {
        if ([string]$rec.Show) { continue }               # TV episodes: not yet
        if ([string]$rec.Type -eq 'Audio') { continue }
        $c = Get-SourceClass $rec
        Set-MmlmRecField $rec 'Source' $c.Label
        Set-MmlmRecField $rec 'SourceWhy' $c.Why
    }
}
#endregion

#region ---------------------------------------------------------------- MediaInfo bootstrap
$script:MediaInfoInitialized = $false
$script:CurrentMi            = $null

#endregion

#region ---------------------------------------------------------------- Sidecar files (NFO + poster) and NFO parsing
#endregion

#region ---------------------------------------------------------------- Record builder (with cache)
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


#endregion

#region ---------------------------------------------------------------- Metadata store + online lookups (TMDB, IMDb ratings file, OMDb)
function Merge-MetaStore {
    # Applies fetched and hand-typed values to freshly scanned records (the work is in modules\MMLM.Library.psm1).
    param([object[]]$Records, [string]$Path)
    Merge-MmlmMetaStore -Records $Records -Path $Path
}

#endregion

#region ---------------------------------------------------------------- Modules (the data logic, no UI)
# requests to data sources this session (Plex, TMDB, OMDb, IMDb); counted by the modules, GitHub update checks are not included
$script:Traffic = [hashtable]::Synchronized(@{ Requests = 0; Bytes = [long]0; Errors = 0; Halted = $false })
$script:ModuleFiles = @('MMLM.Library.psm1', 'MMLM.Plex.psm1', 'MMLM.Fetch.psm1') | ForEach-Object { Join-Path (Join-Path $script:AppRoot 'modules') $_ }
foreach ($m in $script:ModuleFiles) { Import-Module $m -DisableNameChecking }

function Get-MmlmModulePreamble {
    # Script text that loads the modules by full path and hands them the shared values ($WorkerVars) inside a runspace.
    $lines = foreach ($m in $script:ModuleFiles) { "Import-Module '{0}' -DisableNameChecking" -f ($m -replace "'", "''") }
    ($lines -join "`r`n") + "`r`nSet-MmlmContext -Values `$WorkerVars; Set-MmlmPlexContext -Values `$WorkerVars; Set-MmlmFetchContext -Values `$WorkerVars`r`n"
}

function Update-MmlmContext {
    # The values the modules read, for calls made on this (UI) thread. Called again whenever $script:Sync is replaced.
    $v = @{
        Sync = $script:Sync; AppRoot = $script:AppRoot; CacheVersion = $script:CacheVersion; CacheFolder = $script:CacheFolder
        ThumbFolder = $script:ThumbFolder; LibFolder = $script:LibFolder; Culture = $script:Culture
        VideoExtensions = $script:VideoExtensions; AudioExtensions = $script:AudioExtensions
        PosterNames = $script:PosterNames; ImageExtensions = $script:ImageExtensions
        Fields = $script:Fields; TypeMap = $script:TypeMap
        PlexTimeoutMs = $script:PlexTimeoutMs; PlexClientId = $script:PlexClientId; InformFolder = $script:InformFolder
        AppData = $script:AppData; AppVersion = $script:AppVersion; Traffic = $script:Traffic
    }
    Set-MmlmContext -Values $v; Set-MmlmPlexContext -Values $v; Set-MmlmFetchContext -Values $v
}
Update-MmlmContext
#endregion

#region ---------------------------------------------------------------- Background scan (keeps the window responsive)
# The worker is a separate runspace (a second PowerShell on its own thread). It loads the same three modules by full path
# (modules\MMLM.*.psm1) and gets the shared values through Set-MmlmContext*; readers of a parallel folder scan do the same.
function Start-ScanWorker {
    param([ValidateSet('Plex', 'Folder', 'Scrape')][string]$Mode, [hashtable]$ScanArgs)

    $code = New-Object Text.StringBuilder
    [void]$code.AppendLine((Get-MmlmModulePreamble))
    $functionCode = $code.ToString()      # reader threads of a parallel folder scan start with exactly this
    [void]$code.AppendLine(@'
try {
    if ($Mode -eq 'Plex') { $script:Sync.Results = @(Invoke-MmlmPlexScan @ScanArgs) }
    elseif ($Mode -eq 'Scrape') { Invoke-MmlmMetadataScrape @ScanArgs; $script:Sync.Results = @($ScanArgs.Records) }
    else {
        Invoke-MmlmFolderScan @ScanArgs
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
        AppData = $script:AppData; AppVersion = $script:AppVersion; Traffic = $script:Traffic
    }
    $workerVars = @{}
    foreach ($k in $vars.Keys) { if ($k -ne 'Mode' -and $k -ne 'ScanArgs') { $workerVars[$k] = $vars[$k] } }
    $vars['FunctionCode'] = $functionCode
    $vars['WorkerVars']   = $workerVars
    $workerVars['FunctionCode'] = $functionCode; $workerVars['WorkerVars'] = $workerVars        # the modules' context in the worker
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
            if ($c.Name.StartsWith('_')) { continue }
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

$script:HasTv = $false
# File locations are never shown (grid, detail view, dashboard card, saved HTML, CSV); the app still uses them internally.
$script:HiddenFields = @('FullPath', 'Directory', 'PosterPath', 'InformFile')
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
        if ($f.Name -eq 'Show' -or $f.Name -eq 'Season' -or $f.Name -eq 'Episode') { $col.Visible = (($script:Tab -eq 'TV') -and ($hid -notcontains $f.Name)) }      # TV-only columns
        if ($script:HiddenFields -contains $f.Name) { $col.Visible = $false }
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
        $dest = Join-Path $script:ThumbFolder ((Get-MmlmStringHash $key) + '.jpg')
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
        [string]$CollectionName = '',
        [switch]$DateOrder,
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
        foreach ($p in $r.PSObject.Properties) { if ($script:HiddenFields -notcontains $p.Name -and $script:ClueNames -notcontains $p.Name) { $row[$p.Name] = $p.Value } }
        $row['Key'] = Get-CardKey (Get-RecordId $r)       # lets the app open this card without putting the file path in the page
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
    $meta = ConvertTo-Json -Compress -InputObject @{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); library = $LibraryName; collection = $CollectionName; dateOrder = [bool]$DateOrder }

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
    $fields = @($script:Fields); $nf = $fields.Count
    $names  = New-Object string[] $nf; $types = New-Object 'System.Type[]' $nf
    for ($i = 0; $i -lt $nf; $i++) { $names[$i] = $fields[$i].Name; $types[$i] = $script:TypeMap[$fields[$i].Type] }
    $t.BeginLoadData()
    foreach ($r in $Records) {
        $arr = New-Object object[] $nf
        for ($i = 0; $i -lt $nf; $i++) {
            $val = $r.($names[$i])
            if ($null -eq $val) { $arr[$i] = [DBNull]::Value }
            elseif ($val -is $types[$i]) { $arr[$i] = $val }
            else { try { $arr[$i] = [Convert]::ChangeType($val, $types[$i]) } catch { $arr[$i] = [DBNull]::Value } }
        }
        [void]$t.Rows.Add($arr)
    }
    $t.EndLoadData()
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

    # TLS 1.2 (plus 1.3 where this Windows has it); some networks close the connection when older protocols are offered
    try { [Net.ServicePointManager]::SecurityProtocol = ([Net.SecurityProtocolType]3072 -bor [Net.SecurityProtocolType]12288) }
    catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]3072 }
    try { [Net.WebRequest]::DefaultWebProxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials } catch { }
    $oldProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'          # the progress bar makes Invoke-WebRequest very slow in 5.1
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('webview2-' + [guid]::NewGuid().ToString('N') + '.nupkg')
    try {
        $base  = 'https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2'
        $ver = $null
        for ($try = 1; $try -le 3; $try++) {          # a dropped connection is common on the first try; the CDN answers on the next
            try {
                if (-not $ver) {
                    $index = Invoke-RestMethod -Uri "$base/index.json"
                    $ver   = @($index.versions | Where-Object { $_ -notmatch '-' }) | Select-Object -Last 1
                    if (-not $ver) { throw 'No stable WebView2 package version was found on nuget.org.' }
                }
                Invoke-WebRequest -Uri "$base/$ver/microsoft.web.webview2.$ver.nupkg" -OutFile $tmp -UseBasicParsing
                break
            }
            catch { if ($try -ge 3) { throw }; Start-Sleep -Seconds (2 * $try) }
        }

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

$script:WvMapped = $false
function Get-DashboardNavUrl {
    # The live dashboard is opened through the mapped address when there is one; any other address is used as given.
    param([string]$Url)
    $base = ([Uri]((Split-Path -Parent $script:LiveDashboard).TrimEnd('\') + '\')).AbsoluteUri      # the live folder: index.html, tv.html, thumbs
    if ($script:WvMapped -and $Url.StartsWith($base)) { return ('https://mmlm.dashboard/' + $Url.Substring($base.Length)) }
    $Url
}

function Save-CardPng {
    # The dashboard hands over an exported card; ask where to keep it and write it out.
    param([string]$Name, [string]$Base64)
    try {
        $bytes = [Convert]::FromBase64String($Base64)
        $dlg = New-Object Windows.Forms.SaveFileDialog
        $dlg.Filter = 'PNG image (*.png)|*.png'
        $dlg.FileName = ($Name -replace '[\\/:*?"<>|]', '_')
        $dlg.InitialDirectory = [Environment]::GetFolderPath('MyPictures')
        if ($dlg.ShowDialog($form) -ne [Windows.Forms.DialogResult]::OK) { return }
        [IO.File]::WriteAllBytes($dlg.FileName, $bytes)
        Set-UiProgress -Text "Card saved: $($dlg.FileName)"
    }
    catch { [Windows.Forms.MessageBox]::Show("Could not save the card image:`n$_", 'Export Card to PNG', 'OK', 'Error') | Out-Null }
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
            if ($e.IsSuccess) {
                # Serve the dashboard folder under its own address so the page can read its poster files (needed to export a card as PNG)
                try {
                    $sender.CoreWebView2.SetVirtualHostNameToFolderMapping('mmlm.dashboard', (Split-Path -Parent $script:LiveDashboard), [Microsoft.Web.WebView2.Core.CoreWebView2HostResourceAccessKind]::Allow)
                    $script:WvMapped = $true
                } catch { $script:WvMapped = $false }
                try {
                    $sender.CoreWebView2.add_WebMessageReceived({
                        param($s2, $e2)
                        try { $m = $e2.TryGetWebMessageAsString() } catch { return }
                        if ($m -eq 'cardclosed') {          # a card opened from the posters was closed: back to the posters
                            if ($script:CardReturn) { $v = $script:CardReturn; $script:CardReturn = $null; Set-View $v }
                            return
                        }
                        if ($m -and $m.StartsWith('tvview|')) {
                            $v = $m.Substring(7)
                            if ($script:Tab -eq 'TV' -and ($v -eq 'grid' -or $v -eq 'poster') -and $script:CurrentView -ne $v) { Set-View $v }
                            return
                        }
                        if ($m -and $m.StartsWith('savepng|')) {
                            $bits = $m.Split([char[]]@('|'), 3)
                            if ($bits.Count -eq 3) { Save-CardPng -Name $bits[1] -Base64 $bits[2] }
                        }
                    })
                } catch { }
                $sender.CoreWebView2.Navigate((Get-DashboardNavUrl $script:DashboardUrl))
            }
            else { Switch-ToExternalDashboard -Reason $e.InitializationException.Message }
        })
        $dashHost.Controls.Add($wv)
        $script:wv = $wv
        [void]$wv.EnsureCoreWebView2Async($null)
    }
    elseif ($null -ne $script:wv.CoreWebView2) {
        $script:wv.CoreWebView2.Navigate((Get-DashboardNavUrl $Url))
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

# ---- library tabs (Movies | TV Shows) above the header --------------------
$tabBar = New-Object Windows.Forms.Panel
$tabBar.Dock = 'Top'; $tabBar.Height = 40; $tabBar.Width = 1280; $tabBar.BackColor = $script:cBg
function New-LibraryTab {
    param([string]$Text, [string]$Key, [int]$X, [int]$W)
    $t = New-Object Windows.Forms.Label
    $t.Text = $Text; $t.Tag = $Key; $t.AutoSize = $false; $t.TextAlign = 'MiddleCenter'
    $t.Location = New-Object Drawing.Point($X, 0); $t.Size = New-Object Drawing.Size($W, 40)
    $t.Font = $script:fontBold; $t.Cursor = [Windows.Forms.Cursors]::Hand; $t.BackColor = [Drawing.Color]::Transparent
    $t.Add_Paint({
        param($s, $e)
        $on = ([string]$s.Tag -eq $script:Tab)
        $s.ForeColor = $(if ($on) { $script:cText } else { $script:cMuted })
        if ($on) {
            $br = New-Object Drawing.SolidBrush($script:cAccent)
            $e.Graphics.FillRectangle($br, 10, $s.Height - 3, $s.Width - 20, 3)
            $br.Dispose()
        }
    })
    $t
}
$tabMovies = New-LibraryTab 'Movies' 'Movies' 14 90
$tabTv     = New-LibraryTab 'TV Shows' 'TV' 104 100
$tabBar.Controls.AddRange(@($tabMovies, $tabTv))
function Update-TabLabels {
    # The tab being scanned says so; widths follow the text.
    $x = 14
    foreach ($t in @($tabMovies, $tabTv)) {
        $name = $(if ([string]$t.Tag -eq 'TV') { 'TV Shows' } else { 'Movies' })
        $n = [int]$script:TabCounts[[string]$t.Tag]
        $t.Text = $(if ($script:Scanning -and $script:ScanTab -eq [string]$t.Tag) { "$name (scanning...)" } elseif ($n -gt 0) { '{0} ({1:N0})' -f $name, $n } else { $name })
        $w = [Windows.Forms.TextRenderer]::MeasureText($t.Text, $script:fontBold).Width + 40
        $t.Location = New-Object Drawing.Point($x, 0); $t.Size = New-Object Drawing.Size($w, 40)
        $x += $w + 4
        $t.Invalidate()
    }
}

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
$txtFolder.Size = New-Object Drawing.Size(916, 28)
$txtFolder.Anchor = 'Top,Left,Right'
$txtFolder.BackColor = $script:cPanel2; $txtFolder.ForeColor = $script:cText
$txtFolder.BorderStyle = 'FixedSingle'; $txtFolder.Font = New-Object Drawing.Font('Segoe UI', 11)
$btnBrowse = New-FlatButton 'Browse...' 110 'secondary'
$btnBrowse.Location = New-Object Drawing.Point(1138, 35); $btnBrowse.Anchor = 'Top,Right'

# Local scans read several files at once; this is how many (Plex scans do not use it).
$lblPar = New-Label 'PARALLEL FILES' 916 13 $script:cMuted $script:fontSmall
$lblPar.Anchor = 'Top,Right'
$nudPar = New-Object Windows.Forms.NumericUpDown
$nudPar.Minimum = 1; $nudPar.Maximum = 12; $nudPar.Value = 4
$nudPar.Location = New-Object Drawing.Point(1032, 8); $nudPar.Size = New-Object Drawing.Size(90, 24)
$nudPar.Anchor = 'Top,Right'
$nudPar.BackColor = $script:cPanel2; $nudPar.ForeColor = $script:cText; $nudPar.BorderStyle = 'FixedSingle'
$btnWorkers = New-FlatButton 'Workers' 110 'secondary'
$btnWorkers.Size = New-Object Drawing.Size(110, 24); $btnWorkers.Font = $script:fontSmall
$btnWorkers.Location = New-Object Drawing.Point(1138, 8); $btnWorkers.Anchor = 'Top,Right'

$chkRebuild = New-FlatCheckBox 'Rebuild local cache' 24 82
$chkVideo   = New-FlatCheckBox 'Video' 190 82 $true
$chkAudio   = New-FlatCheckBox 'Audio' 262 82 $true
$chkEmbed   = New-FlatCheckBox 'Embed posters' 334 82
$chkFel     = New-FlatCheckBox 'FEL / MEL probe' 470 82
$tip = New-Object Windows.Forms.ToolTip
$tip.SetToolTip($chkFel, "MediaInfo and Plex cannot tell Dolby Vision FEL from MEL.`nWith this on, dual-layer files are sampled with ffmpeg + dovi_tool.`nPut ffmpeg.exe and dovi_tool.exe in the lib folder (or on PATH).`nWith Plex, the file must also be reachable from this PC at the path Plex reports (e.g. a UNC share).")
$tip.SetToolTip($chkEmbed, 'Saved HTML dashboards carry their posters inside the file (bigger, but a single file).')
$tip.SetToolTip($chkRebuild, 'Ignore everything saved from earlier scans and read it all again.')
$tip.SetToolTip($btnGear, 'Settings')
$tip.SetToolTip($radPlex, 'Read the library from your Plex server (fast: Plex has already analysed every file).')
$tip.SetToolTip($radLocal, 'Scan a folder with MediaInfo (slower: every file is opened).')

$btnScan     = New-FlatButton 'Scan Movies' 130 'primary'
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
$controls.Controls.AddRange(@($lblSource, $radPlex, $radLocal, $lblFolder, $txtFolder, $btnBrowse, $chkRebuild, $chkVideo, $chkAudio, $chkEmbed, $chkFel, $lblPar, $nudPar, $btnWorkers, $btnScan, $btnDash, $btnSaveHtml, $btnExport, $btnCancel))

# remembered options (the cache-rebuild box is deliberately NOT remembered)
$chkVideo.Checked  = [bool]$script:Settings['Video']
$chkAudio.Checked  = [bool]$script:Settings['Audio']
$chkEmbed.Checked  = [bool]$script:Settings['EmbedPosters']
$chkFel.Checked    = [bool]$script:Settings['DetectFel']
try { $nudPar.Value = [Math]::Max(1, [Math]::Min(12, [int]$script:Settings['Parallel'])) } catch { $nudPar.Value = 4 }
$tip.SetToolTip($nudPar, "How many files a local scan reads at the same time (can be changed during a scan).`n4 suits most NAS shares; raise it while watching the progress speed, or use 1 if the share struggles.")
$script:PlexToken  = Unprotect-MmlmPlexToken ([string]$script:Settings['PlexTokenProtected'])
$script:TmdbKey    = Unprotect-MmlmPlexToken ([string]$script:Settings['TmdbKeyProtected'])
$script:OmdbKey    = Unprotect-MmlmPlexToken ([string]$script:Settings['OmdbKeyProtected'])

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
    $lbl2  = New-Label 'OMDb API key (optional: Rotten Tomatoes, Metacritic and domestic box office; free tier is 1,000 requests a day)' 24 216 $script:cMuted $script:fontSmall
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
        $script:Settings['TmdbKeyProtected'] = Protect-MmlmPlexToken $script:TmdbKey
        $script:Settings['OmdbKeyProtected'] = Protect-MmlmPlexToken $script:OmdbKey
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
    $msg.Text = "The $Scope will be looked up on TMDB (year, genre, rating, studio, director, certification, worldwide box office), the IMDb ratings file $omdb.`nIt runs in the background and can be cancelled. Movies only for now; TV episodes are skipped."
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

function Show-FetchDetails {
    $dlg = New-DialogForm 'Fetch info - what happened' 760 440
    $head = New-Label ('{0} title(s) were not fetched. The reason for each is below.' -f @($script:FetchDetails).Count) 24 16 $script:cText $script:fontBold
    $box = New-Object Windows.Forms.TextBox
    $box.Multiline = $true; $box.ReadOnly = $true; $box.ScrollBars = 'Vertical'; $box.WordWrap = $true
    $box.Location = New-Object Drawing.Point(24, 48); $box.Size = New-Object Drawing.Size(712, 290)
    $box.BackColor = $script:cPanel2; $box.ForeColor = $script:cText; $box.BorderStyle = 'FixedSingle'; $box.Font = $script:fontBase
    $box.Text = (@($script:FetchDetails) -join ("`
`
`
`
"))
    $copy  = New-FlatButton 'Copy' 100 'secondary'
    $close = New-FlatButton 'Close' 100 'primary'
    $copy.Location  = New-Object Drawing.Point(526, 356); $close.Location = New-Object Drawing.Point(636, 356)
    $close.DialogResult = [Windows.Forms.DialogResult]::OK
    $copy.Add_Click({ try { [Windows.Forms.Clipboard]::SetText($box.Text) } catch { } }.GetNewClosure())
    $dlg.Controls.AddRange(@($head, $box, $copy, $close))
    $box.TabStop = $false; $dlg.ActiveControl = $close
    $dlg.AcceptButton = $close; $dlg.CancelButton = $close
    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
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
    $list = if ($Plex) { @($chkRebuild, $chkEmbed, $chkFel) } else { @($chkRebuild, $chkVideo, $chkAudio, $chkEmbed, $chkFel) }
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
    $lblPar.Visible = -not $Plex;   $nudPar.Visible = -not $Plex;   $btnWorkers.Visible = -not $Plex
    Update-OptionLayout -Plex $Plex
    $script:DashboardStale = $true
}

# ---- status bar -----------------------------------------------------------
$statusBar = New-Object Windows.Forms.Panel
$statusBar.Dock = 'Bottom'; $statusBar.Height = 76; $statusBar.Width = 1280; $statusBar.BackColor = $script:cPanel
$lblStatus = New-Label 'Ready. Pick a source and click Scan.' 24 7 $script:cMuted $script:fontBase
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
$lnkDetails = New-Object Windows.Forms.LinkLabel
$lnkDetails.Text = 'See details'; $lnkDetails.AutoSize = $true; $lnkDetails.Location = New-Object Drawing.Point(24, 7)
$lnkDetails.LinkColor = $script:cAccent; $lnkDetails.ActiveLinkColor = $script:cAccent2; $lnkDetails.BackColor = [Drawing.Color]::Transparent
$lnkDetails.Font = $script:fontBase; $lnkDetails.Visible = $false
$script:FetchDetails = @()
$lnkDetails.Add_LinkClicked({ Show-FetchDetails })
$statusBar.Controls.AddRange(@($lblStatus, $lnkDetails, $progTrack, $lblProg, $ovTrack, $lblOv))

# ---- content: toolbar + grid / detail views -------------------------------
$content = New-Object Windows.Forms.Panel
$content.Dock = 'Fill'; $content.BackColor = $script:cBg

$toolbar = New-Object Windows.Forms.Panel
$toolbar.Dock = 'Top'; $toolbar.Height = 54; $toolbar.Width = 1280; $toolbar.BackColor = $script:cBg
$btnViewGrid   = New-FlatButton 'Grid view' 110 'primary'
$btnViewDetail = New-FlatButton 'Detail view' 110 'secondary'
$btnViewPoster = New-FlatButton 'Poster view' 110 'secondary'
$btnViewDash   = New-FlatButton 'Dashboard' 110 'secondary'
$btnViewGrid.Location   = New-Object Drawing.Point(24, 10)
$btnViewDetail.Location = New-Object Drawing.Point(142, 10)
$btnViewPoster.Location = New-Object Drawing.Point(260, 10)
$btnViewDash.Location   = New-Object Drawing.Point(378, 10)
$lblFilter = New-Label 'Filter:' 518 18 $script:cMuted $script:fontBase
$txtFilter = New-Object Windows.Forms.TextBox
$txtFilter.Location = New-Object Drawing.Point(566, 13); $txtFilter.Size = New-Object Drawing.Size(230, 26)
$txtFilter.BackColor = $script:cPanel2; $txtFilter.ForeColor = $script:cText; $txtFilter.BorderStyle = 'FixedSingle'
$lblCount = New-Label '' 812 18 $script:cMuted $script:fontBase
$btnCols = New-FlatButton 'Columns' 90 'secondary'
$btnCols.Location = New-Object Drawing.Point(1166, 10); $btnCols.Anchor = 'Top,Right'
$btnFetch = New-FlatButton 'Fetch info' 100 'secondary'
$btnFetch.Location = New-Object Drawing.Point(1056, 10); $btnFetch.Anchor = 'Top,Right'
$btnEdit = New-FlatButton 'Edit info' 100 'secondary'
$btnEdit.Location = New-Object Drawing.Point(946, 10); $btnEdit.Anchor = 'Top,Right'
$toolbar.Controls.AddRange(@($btnViewGrid, $btnViewDetail, $btnViewPoster, $btnViewDash, $lblFilter, $txtFilter, $lblCount, $btnEdit, $btnFetch, $btnCols))

# collection bar: sits under the toolbar once a scan has results
$collBar = New-Object Windows.Forms.Panel
$collBar.Location = New-Object Drawing.Point(0, 54); $collBar.Size = New-Object Drawing.Size(1280, 78); $collBar.Anchor = 'Top,Left,Right'
$collBar.BackColor = $script:cBg; $collBar.Visible = $false
$lblColl = New-Label 'Collection:' 24 15 $script:cMuted $script:fontBase
$cboColl = New-Object Windows.Forms.ComboBox
$cboColl.DropDownStyle = 'DropDownList'; $cboColl.FlatStyle = 'Flat'
$cboColl.Location = New-Object Drawing.Point(104, 11); $cboColl.Size = New-Object Drawing.Size(250, 28)
$cboColl.BackColor = $script:cPanel2; $cboColl.ForeColor = $script:cText
$btnCollNew  = New-FlatButton 'New...' 76 'secondary';           $btnCollNew.Location  = New-Object Drawing.Point(366, 8)
$btnCollEdit = New-FlatButton 'Edit...' 76 'secondary';          $btnCollEdit.Location = New-Object Drawing.Point(448, 8)
$btnCollDel  = New-FlatButton 'Delete' 76 'secondary';           $btnCollDel.Location  = New-Object Drawing.Point(530, 8)
$btnCollAdd  = New-FlatButton 'Add selected...' 130 'secondary'; $btnCollAdd.Location  = New-Object Drawing.Point(612, 8)
$lblCollInfo = New-Object Windows.Forms.Label
$lblCollInfo.AutoSize = $false; $lblCollInfo.AutoEllipsis = $true; $lblCollInfo.TextAlign = 'MiddleLeft'
$lblCollInfo.Location = New-Object Drawing.Point(24, 48); $lblCollInfo.Size = New-Object Drawing.Size(920, 22); $lblCollInfo.Anchor = 'Top,Left,Right'
# Sort By (Movies): right-hand end of the collection bar
$script:SortChoices = [ordered]@{
    'Title'                 = '[Title] ASC, [Year] ASC'
    'Date Added'            = '[Added] DESC, [Title] ASC'
    'Release Date'          = '[ReleaseDate] DESC, [Year] DESC, [Title] ASC'
    'Rating (RT Critics)'   = '[RTCritic] DESC, [Title] ASC'
    'Metacritic'            = '[Metascore] DESC, [Title] ASC'
    'Box Office Domestic'   = '[BoxOfficeDomestic] DESC, [Title] ASC'
    'Box Office Worldwide'  = '[BoxOfficeWorldwide] DESC, [Title] ASC'
    'Runtime'               = '[RuntimeMin] DESC, [Title] ASC'
}
$lblSort = New-Object Windows.Forms.Label
$lblSort.Text = 'Sort by:'; $lblSort.AutoSize = $false; $lblSort.TextAlign = 'MiddleRight'
$lblSort.Location = New-Object Drawing.Point(950, 43); $lblSort.Size = New-Object Drawing.Size(76, 26); $lblSort.Anchor = 'Top,Right'
$lblSort.ForeColor = $script:cMuted; $lblSort.BackColor = [Drawing.Color]::Transparent; $lblSort.Font = $script:fontBase
$cboSort = New-Object Windows.Forms.ComboBox
$cboSort.DropDownStyle = 'DropDownList'; $cboSort.FlatStyle = 'Flat'; $cboSort.TabStop = $false
$cboSort.Location = New-Object Drawing.Point(1036, 43); $cboSort.Size = New-Object Drawing.Size(220, 28); $cboSort.Anchor = 'Top,Right'
$cboSort.BackColor = $script:cPanel2; $cboSort.ForeColor = $script:cText; $cboSort.Font = $script:fontBase
# drawn by us so the chosen sort is always readable on the dark theme (the stock flat list can paint it as an empty highlight)
$cboSort.DrawMode = 'OwnerDrawFixed'; $cboSort.ItemHeight = 20
$cboSort.Add_DrawItem({
    param($s, $e)
    if ($e.Index -lt 0) { return }
    $sel = (($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0) -and (($e.State -band [Windows.Forms.DrawItemState]::ComboBoxEdit) -eq 0)
    $bg = New-Object Drawing.SolidBrush($(if ($sel) { $script:cAccent } else { $script:cPanel2 }))
    $e.Graphics.FillRectangle($bg, $e.Bounds); $bg.Dispose()
    $r = New-Object Drawing.Rectangle(($e.Bounds.X + 6), $e.Bounds.Y, ($e.Bounds.Width - 6), $e.Bounds.Height)
    [Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$s.Items[$e.Index], $s.Font, $r, $script:cText, ([Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::EndEllipsis))
})
foreach ($k in $script:SortChoices.Keys) { [void]$cboSort.Items.Add($k) }
$cboSort.SelectedIndex = 0
$lblCollInfo.ForeColor = $script:cMuted; $lblCollInfo.BackColor = [Drawing.Color]::Transparent; $lblCollInfo.Font = $script:fontSmall
$collBar.Controls.AddRange(@($lblColl, $cboColl, $btnCollNew, $btnCollEdit, $btnCollDel, $btnCollAdd, $lblCollInfo, $lblSort, $cboSort))
$toolbar.Controls.Add($collBar)

# empty-state message
$lblEmpty = New-Object Windows.Forms.Label
$lblEmpty.Dock = 'Fill'; $lblEmpty.TextAlign = 'MiddleCenter'; $lblEmpty.ForeColor = $script:cMuted
$lblEmpty.Font = New-Object Drawing.Font('Segoe UI', 12)
$lblEmpty.Text = "Pick a source (Plex server or a local folder), then click Scan (it scans the tab you are on).`r`nTick 'Rebuild local cache' to ignore previously saved results."

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
$lblDPlot.Location = New-Object Drawing.Point(206, 82); $lblDPlot.Size = New-Object Drawing.Size(660, 104)
$lblDPlot.Anchor = 'Top,Left,Right'; $lblDPlot.ForeColor = $script:cMuted; $lblDPlot.AutoEllipsis = $true
# Ratings and box office strip along the bottom of the header (rows without a value are left out)
$pnlScores = New-Object Windows.Forms.Panel
$pnlScores.Location = New-Object Drawing.Point(206, 194); $pnlScores.Size = New-Object Drawing.Size(660, 72)
$pnlScores.Anchor = 'Top,Left,Right'; $pnlScores.BackColor = $script:cPanel
$lblScoreCap1 = New-Label 'RATINGS' 12 11 $script:cAccent $script:fontSmall
$lblScoreCap2 = New-Label 'BOX OFFICE' 12 41 $script:cAccent $script:fontSmall
$lblScores = New-Object Windows.Forms.Panel       # custom painted: label, tomato / splat and value for each score
$lblScores.Location = New-Object Drawing.Point(104, 8); $lblScores.Size = New-Object Drawing.Size(540, 24); $lblScores.Anchor = 'Top,Left,Right'
$lblScores.BackColor = [Drawing.Color]::Transparent; $lblScores.Tag = @()
$lblScores.Add_Paint({
    param($s, $e)
    $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
    $items = @($s.Tag)
    if ($items.Count -eq 0) { return }
    $x = 0
    $flags = [Windows.Forms.TextFormatFlags]::NoPadding -bor [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::Left
    foreach ($it in $items) {
        if ($null -eq $it) { continue }
        if ($it.L) {
            $w = [Windows.Forms.TextRenderer]::MeasureText($g, $it.L, $script:fontBase, (New-Object Drawing.Size(2000, 24)), $flags).Width
            [Windows.Forms.TextRenderer]::DrawText($g, $it.L, $script:fontBase, (New-Object Drawing.Rectangle($x, 0, ($w + 4), $s.Height)), $script:cMuted, $flags)
            $x += $w + 8
        }
        if ($it.I -ge 0) {
            $iy = [int](($s.Height - 16) / 2)
            if ($it.I -eq 1) {
                $br = New-Object Drawing.SolidBrush((RGB 230 52 40)); $g.FillEllipse($br, $x, $iy + 2, 15, 14); $br.Dispose()
                $lf = New-Object Drawing.SolidBrush((RGB 70 170 70))
                $g.FillPolygon($lf, [Drawing.Point[]]@((New-Object Drawing.Point(($x + 7), ($iy + 4))), (New-Object Drawing.Point(($x + 3), ($iy + 1))), (New-Object Drawing.Point(($x + 7), ($iy + 2))), (New-Object Drawing.Point(($x + 11), ($iy + 0))), (New-Object Drawing.Point(($x + 9), ($iy + 4)))))
                $lf.Dispose()
            }
            else {
                $br = New-Object Drawing.SolidBrush((RGB 112 168 44))
                $g.FillEllipse($br, $x + 1, $iy + 6, 14, 9); $g.FillEllipse($br, $x + 4, $iy + 2, 8, 8); $g.FillEllipse($br, $x - 1, $iy + 9, 5, 5); $g.FillEllipse($br, $x + 11, $iy + 8, 5, 5)
                $br.Dispose()
            }
            $x += 20
        }
        if ($it.MC -gt 0) { Draw-MetascoreBadge $g $it.MC $x ([int](($s.Height - 22) / 2)) 30 22; $x += 30 + 26; continue }
        $w = [Windows.Forms.TextRenderer]::MeasureText($g, $it.T, $script:fontBold, (New-Object Drawing.Size(2000, 24)), $flags).Width
        [Windows.Forms.TextRenderer]::DrawText($g, $it.T, $script:fontBold, (New-Object Drawing.Rectangle($x, 0, ($w + 4), $s.Height)), $script:cText, $flags)
        $x += $w + 26
    }
})
$lblMoney = New-Object Windows.Forms.Label
$lblMoney.Location = New-Object Drawing.Point(104, 38); $lblMoney.Size = New-Object Drawing.Size(540, 24); $lblMoney.Anchor = 'Top,Left,Right'
$lblMoney.ForeColor = $script:cText; $lblMoney.BackColor = [Drawing.Color]::Transparent; $lblMoney.AutoEllipsis = $true; $lblMoney.TextAlign = 'MiddleLeft'
$pnlScores.Controls.AddRange(@($lblScoreCap1, $lblScoreCap2, $lblScores, $lblMoney))
$headPanel.Controls.AddRange(@($picPoster, $lblDTitle, $lblDMeta, $lblDPlot, $pnlScores))
$rightPane.Controls.Add($attrGrid)         # Fill first, then Top
$rightPane.Controls.Add($headPanel)
$detailHost.Controls.Add($rightPane)       # Fill first, then Left
$detailHost.Controls.Add($leftPane)

# poster view: a scrolling wall of posters, painted by hand so a library of thousands stays quick (only what is on screen is drawn)
$script:PosterItems = New-Object System.Collections.Generic.List[object]
$script:PosterImgs  = New-Object 'System.Collections.Generic.Dictionary[string,object]'
$script:PosterW = 150; $script:PosterH = 225; $script:PosterCap = 44; $script:PosterGapX = 20; $script:PosterGapY = 16
$script:PosterHover = -1
$posterHost = New-Object Windows.Forms.Panel
$posterHost.Dock = 'Fill'; $posterHost.Padding = New-Object Windows.Forms.Padding(24, 0, 24, 12); $posterHost.Visible = $false
$posterCanvas = New-Object BufferedPanel
$posterCanvas.Dock = 'Fill'; $posterCanvas.BackColor = $script:cBg
$posterScroll = New-Object Windows.Forms.VScrollBar
$posterScroll.Dock = 'Right'; $posterScroll.Enabled = $false
$posterHost.Controls.Add($posterCanvas)      # Fill first, then Right
$posterHost.Controls.Add($posterScroll)
try {   # a plain panel does not take the keyboard focus, which the mouse wheel needs
    [Windows.Forms.Control].GetMethod('SetStyle', [Reflection.BindingFlags]'Instance,NonPublic').Invoke($posterCanvas, @([Windows.Forms.ControlStyles]::Selectable, $true))
} catch { }

# dashboard view: the WebView2 control is created lazily inside this panel (see Show-DashboardPane)
$dashHost = New-Object Windows.Forms.Panel
$dashHost.Dock = 'Fill'; $dashHost.BackColor = $script:cBg; $dashHost.Visible = $false

$content.Controls.Add($lblEmpty)
$content.Controls.Add($gridHost)
$content.Controls.Add($detailHost)
$content.Controls.Add($posterHost)
$content.Controls.Add($dashHost)
$content.Controls.Add($toolbar)            # Top docked last so it sits above the Fill controls

# Fill control first, then bottom/top bars (WinForms docks later-added controls first)
$form.Controls.Add($content)
$form.Controls.Add($statusBar)
$form.Controls.Add($controls)
$form.Controls.Add($header)
$form.Controls.Add($tabBar)             # added last, so it docks above the header
#endregion

#region ---------------------------------------------------------------- View helpers
function Set-View {
    param([ValidateSet('grid', 'detail', 'poster', 'dashboard')][string]$View)
    $scanHere = ($script:Scanning -and $script:Tab -eq $script:ScanTab)      # the tab being scanned shows a notice; the other tab works normally
    $hasData = (($script:ScanResults.Count -gt 0) -or $script:TvFromDisk) -and -not $scanHere
    $script:CurrentView = $View
    $script:TabView[$script:Tab] = $View
    if ($scanHere) {
        if ($null -eq $script:EmptyText) { $script:EmptyText = $lblEmpty.Text }
        $lblEmpty.Text = "Scanning $(if ($script:Tab -eq 'TV') { 'TV Shows' } else { 'Movies' })...`r`nProgress is shown at the bottom of the window.`r`nThe other tab stays usable while this runs."
    }
    elseif ($null -ne $script:EmptyText) { $lblEmpty.Text = $script:EmptyText; $script:EmptyText = $null }
    $lblEmpty.Visible   = -not $hasData
    $tvPage = $hasData -and ($script:Tab -eq 'TV') -and ($View -eq 'grid' -or $View -eq 'poster')     # TV posters / grid are tv.html
    if ($tvPage -and @($script:TvRecords).Count -eq 0 -and -not $script:TvFromDisk) { $tvPage = $false; $hasData = $false; $lblEmpty.Visible = $true }
    $gridHost.Visible   = $hasData -and ($View -eq 'grid') -and -not $tvPage
    $detailHost.Visible = $hasData -and ($View -eq 'detail')
    if ($hasData -and ($View -eq 'detail') -and $script:DetailStale) { Update-DetailList -Filter $txtFilter.Text.Trim(); $script:DetailStale = $false }
    $posterHost.Visible = $hasData -and ($View -eq 'poster') -and -not $tvPage
    if ($posterHost.Visible) { Update-PosterList }
    $dashHost.Visible   = $hasData -and (($View -eq 'dashboard') -or $tvPage)
    if ($tvPage) { Show-TvPage -View $(if ($View -eq 'grid') { 'grid' } else { 'posters' }) }
    # filter + column picker only make sense for the table views
    $showFilter = $hasData -and ($View -ne 'dashboard') -and -not $tvPage          # the TV page has its own filter
    $lblFilter.Visible = $showFilter; $txtFilter.Visible = $showFilter; $lblCount.Visible = $showFilter
    if (-not $showFilter) { Hide-FilterSuggest $txtFilter }
    $movieGrid = $hasData -and ($View -eq 'grid') -and ($script:Tab -ne 'TV')
    $btnCols.Visible   = $movieGrid
    $btnFetch.Visible  = $movieGrid
    $btnEdit.Visible   = $movieGrid
    $collBar.Visible   = $hasData -and ($script:Tab -ne 'TV')                     # collections are for movies for now
    $toolbar.Height    = $(if ($collBar.Visible) { 132 } else { 54 })          # the collection bar is the toolbar's second row
    $btnCollAdd.Visible = $movieGrid
    $lblSort.Visible = $collBar.Visible -and ($View -eq 'grid' -or $View -eq 'poster'); $cboSort.Visible = $lblSort.Visible
    foreach ($pair in @(@($btnViewGrid, 'grid'), @($btnViewDetail, 'detail'), @($btnViewPoster, 'poster'), @($btnViewDash, 'dashboard'))) {
        $btn = $pair[0]
        if ($pair[1] -eq $View) {
            $btn.BackColor = $script:cAccent; $btn.ForeColor = [Drawing.Color]::White; $btn.FlatAppearance.BorderSize = 0
        }
        else {
            $btn.BackColor = $script:cPanel2; $btn.ForeColor = $script:cText; $btn.FlatAppearance.BorderSize = 1
        }
    }
}

function Get-PosterGeometry {
    $cw = $script:PosterW + $script:PosterGapX; $ch = $script:PosterH + $script:PosterCap + $script:PosterGapY
    $w = [Math]::Max($posterCanvas.ClientSize.Width, 1)
    $cols = [Math]::Max(1, [int][Math]::Floor(($w + $script:PosterGapX) / $cw))
    $x0 = [Math]::Max(0, [int][Math]::Floor(($w - ($cols * $cw - $script:PosterGapX)) / 2))
    $rows = [int][Math]::Ceiling($script:PosterItems.Count / [double]$cols)
    @{ CW = $cw; CH = $ch; Cols = $cols; X0 = $x0; Rows = $rows; Total = ($rows * $ch) }
}

function Update-PosterScroll {
    $g = Get-PosterGeometry
    $vh = [Math]::Max($posterCanvas.ClientSize.Height, 1)
    if ($g.Total -gt $vh) {
        $posterScroll.Enabled = $true
        $posterScroll.SmallChange = [int]($g.CH / 3)
        $posterScroll.Maximum = $g.Total
        $posterScroll.LargeChange = $vh
        $maxV = $g.Total - $vh + 1
        if ($posterScroll.Value -gt $maxV) { $posterScroll.Value = $maxV }
    }
    else { $posterScroll.Value = 0; $posterScroll.Enabled = $false }
    $posterCanvas.Invalidate()
}

function Update-PosterList {
    try {
        # Same titles, same order as the grid (its filter, collection and sorting all carry over).
        $list = New-Object System.Collections.Generic.List[object]
        if ($grid.DataSource -is [System.Data.DataTable]) {
            $view = $grid.DataSource.DefaultView
            for ($i = 0; $i -lt $view.Count; $i++) {
                $d = $view[$i]
                $y = 0; if ($d['Year'] -isnot [DBNull]) { $y = [int]$d['Year'] }
                $pk = [string]$d['PlexKey']; $id = $(if ($pk) { 'p:' + $pk } else { 'f:' + [string]$d['FullPath'] })
                $list.Add([pscustomobject]@{ Title = [string]$d['Title']; Year = $y; Path = [string]$d['PosterPath']; FullPath = [string]$d['FullPath']; Key = (Get-CardKey $id) })
            }
        }
        $script:PosterItems = $list
        $script:PosterHover = -1
        $posterScroll.Value = 0
        Update-PosterScroll
    }
    catch { Show-UiError 'Update-PosterList' $_ }
}

function Get-PosterImage {
    # Small cached copy of a poster (the same thumbnails the dashboard uses); $null when there is none.
    param([string]$Path)
    if (-not $Path) { return $null }
    if ($script:PosterImgs.ContainsKey($Path)) { return $script:PosterImgs[$Path] }
    $bmp = $null
    try {
        if (Test-Path -LiteralPath $Path) {
            $th = Get-PosterThumbnail -Source $Path
            if ($th) {
                $ms = New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($th))
                try { $img = [Drawing.Image]::FromStream($ms); try { $bmp = New-Object Drawing.Bitmap($img) } finally { $img.Dispose() } } finally { $ms.Dispose() }
            }
        }
    } catch { $bmp = $null }
    if ($script:PosterImgs.Count -ge 400) {
        foreach ($v in @($script:PosterImgs.Values)) { if ($null -ne $v) { $v.Dispose() } }
        $script:PosterImgs.Clear()
    }
    $script:PosterImgs[$Path] = $bmp
    $bmp
}

function Get-PosterIndexAt {
    param([int]$X, [int]$Y)
    $g = Get-PosterGeometry
    $px = $X - $g.X0; $py = $Y + $posterScroll.Value
    if ($px -lt 0 -or $py -lt 0) { return -1 }
    $c = [int][Math]::Floor($px / $g.CW); $r = [int][Math]::Floor($py / $g.CH)
    if ($c -ge $g.Cols) { return -1 }
    if (($px - $c * $g.CW) -gt $script:PosterW -or ($py - $r * $g.CH) -gt ($script:PosterH + $script:PosterCap)) { return -1 }
    $i = $r * $g.Cols + $c
    if ($i -ge $script:PosterItems.Count) { return -1 }
    $i
}

function Format-MoneyShort {
    param([double]$V)
    if ($V -le 0) { return '' }
    if ($V -ge 1e9) { return '$' + ($V / 1e9).ToString('0.00', $script:Culture) + 'B' }
    if ($V -ge 1e6) { return '$' + ($V / 1e6).ToString($(if ($V -ge 1e8) { '0' } else { '0.0' }), $script:Culture) + 'M' }
    return '$' + $V.ToString('N0', $script:Culture)
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

    $sc = @()
    if ($Record.Rating -gt 0) {
        $rl = switch ([string]$Record.RatingSource) { 'IMDb' { 'IMDB Rating' } 'TMDB' { 'TMDB Rating' } default { 'Rating' } }
        $sc += @{ L = $rl; T = (('{0:N1}' -f $Record.Rating) + $(if ($Record.Votes -gt 0) { ' (' + ([int]$Record.Votes).ToString('N0', $script:Culture) + ' votes)' } else { '' })); I = -1 }
    }
    if ($Record.RTCritic   -gt 0) { $sc += @{ L = 'RT Critics';  T = ('{0}%' -f $Record.RTCritic);   I = $(if ($Record.RTCritic   -ge 60) { 1 } else { 0 }) } }
    if ($Record.RTAudience -gt 0) { $sc += @{ L = 'RT Audience'; T = ('{0}%' -f $Record.RTAudience); I = $(if ($Record.RTAudience -ge 60) { 1 } else { 0 }) } }
    if ($Record.Metascore -gt 0) { $sc += @{ L = 'Metacritic'; T = ''; I = -1; MC = [int]$Record.Metascore } }
    if ($Record.CinemaScore) { $sc += @{ L = 'CinemaScore'; T = [string]$Record.CinemaScore; I = -1 } }
    $mn = @()
    $v = Format-MoneyShort ([double]$Record.BoxOfficeDomestic);  if ($v) { $mn += "Domestic $v" }
    $v = Format-MoneyShort ([double]$Record.BoxOfficeWorldwide); if ($v) { $mn += "Worldwide $v" }
    $v = Format-MoneyShort ([double]$Record.OpeningDomestic);    if ($v) { $mn += "Opening $v" }
    if ($sc.Count -eq 0) { $sc += @{ L = ''; T = 'None yet'; I = -1 } }
    $lblScores.Tag = $sc; $lblScores.Invalidate()
    $lblMoney.Text  = $(if ($mn.Count -gt 0) { $mn -join '   |   ' } else { 'None yet' })

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
            if ($script:HiddenFields -contains $f.Name) { continue }
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
    # Built from lists and one AddRange: adding 50,000+ episodes one at a time (or growing an array with +=) takes minutes.
    $items  = New-Object 'System.Collections.Generic.List[object]'
    $labels = New-Object 'System.Collections.Generic.List[object]'
    $needle = $Filter.ToLowerInvariant()
    $scoped = ($null -ne $script:ScopeIds)
    foreach ($r in (Get-OrderedResults)) {
        if ($scoped -and -not $script:ScopeIds.Contains((Get-RecordId $r))) { continue }
        if ($needle) {
            $hay = ('{0} {1} {2} {3} {4}' -f $r.Title, $r.FileName, $r.Genre, $r.Studio, $r.Cast).ToLowerInvariant()
            if (-not $hay.Contains($needle)) { continue }
        }
        $label = [string]$r.Title
        if ($r.Year -gt 0) { $label = "$label ($($r.Year))" }
        $labels.Add($label)
        $items.Add($r)
    }
    $script:DetailItems = $items.ToArray()
    $listFiles.BeginUpdate()
    try {
        $listFiles.Items.Clear()
        if ($labels.Count -gt 0) { $listFiles.Items.AddRange($labels.ToArray()) }
    }
    finally { $listFiles.EndUpdate() }
}

function Get-LikeEscaped {
    param([string]$Text)
    $Text.Replace("'", "''").Replace('[', '[[]').Replace('%', '[%]').Replace('*', '[*]')
}

function Get-TermExpression {
    # One  field:value  term as a DataView filter expression, or $null when it is not a usable term.
    # Text columns match "contains"; number columns take  7.5   >=7.5   <2000   1980-1989.
    param($Table, [string]$Name, [string]$Value)
    $col = $Table.Columns[$Name]
    if ($null -eq $col) { return $null }
    $v = $Value.Trim()
    $c = $col.ColumnName
    if ($col.DataType -eq [string]) { return ("[{0}] LIKE '%{1}%'" -f $c, (Get-LikeEscaped $v)) }
    if (-not ($col.DataType -eq [int] -or $col.DataType -eq [double] -or $col.DataType -eq [long])) { return $null }
    $num = '(-?\d+(?:\.\d+)?)'
    $ci  = [Globalization.CultureInfo]::InvariantCulture
    if ($v -match ('^' + $num + '\s*-\s*' + $num + '$')) {
        $a = [double]::Parse($Matches[1], $ci); $b = [double]::Parse($Matches[2], $ci)
        if ($a -gt $b) { $t = $a; $a = $b; $b = $t }
        return ('[{0}] >= {1} AND [{0}] <= {2}' -f $c, $a.ToString($ci), $b.ToString($ci))
    }
    if ($v -match ('^(>=|<=|>|<|=)?\s*' + $num + '$')) {
        $op = if ($Matches[1]) { $Matches[1] } else { '=' }
        $n  = [double]::Parse($Matches[2], $ci)
        return ('[{0}] {1} {2}' -f $c, $op, $n.ToString($ci))
    }
    $null
}

function Get-FilterExpression {
    # The filter box text as a DataView filter expression ('' = no filter).
    # "genre:Horror year:1980-1989" = several field:value terms that must all match; anything else is a free-text search.
    param($Table, [string]$Text)
    $text = $Text.Trim()
    if (-not $text) { return '' }
    $exprs = @(); $ok = $true
    foreach ($p in @([regex]::Split($text, '\s+(?=[A-Za-z]\w*\s*:)'))) {
        if ($p -match '^(\w+)\s*:\s*(.+)$') {
            $x = Get-TermExpression $Table $Matches[1] $Matches[2]
            if ($x) { $exprs += $x } else { $ok = $false; break }
        }
        else { $ok = $false; break }
    }
    if ($ok -and $exprs.Count -gt 0) { return (($exprs | ForEach-Object { '(' + $_ + ')' }) -join ' AND ') }
    $e = Get-LikeEscaped $text
    "[Title] LIKE '%$e%' OR [FileName] LIKE '%$e%' OR [Genre] LIKE '%$e%' OR [Studio] LIKE '%$e%' OR [Cast] LIKE '%$e%' OR [Director] LIKE '%$e%'"
}

function Get-UnionExpression {
    # Dynamic collections: several filters separated by commas. A title is included when it matches ANY of them;
    # inside one part, field:value terms still all have to match ("genre:Horror year:1980-1989, title:Alien").
    param($Table, [string]$Text)
    $parts = @(([string]$Text) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($parts.Count -eq 0) { return '' }
    if ($parts.Count -eq 1) { return (Get-FilterExpression $Table $parts[0]) }
    ($parts | ForEach-Object { '(' + (Get-FilterExpression $Table $_) + ')' }) -join ' OR '
}

function Get-CardKey {
    param([string]$Id)
    (Get-MmlmStringHash $Id).Substring(0, 16)
}

function Get-RecordId {
    # One stable id per scanned item: the Plex key, else the file path.
    param($Rec)
    $pk = [string]$Rec.PlexKey
    if ($pk) { 'p:' + $pk } else { 'f:' + [string]$Rec.FullPath }
}

function Get-RowId {
    param($Row)
    $pk = [string]$Row['PlexKey']
    if ($pk) { 'p:' + $pk } else { 'f:' + [string]$Row['FullPath'] }
}

function Get-ScopeExpression {
    # Restricts the grid to the active collection ('' = no collection active).
    if ($null -eq $script:ScopeIds) { return '' }
    $p = @(); $f = @()
    foreach ($id in $script:ScopeIds) {
        $q = "'" + $id.Substring(2).Replace("'", "''") + "'"
        if ($id.StartsWith('p:')) { $p += $q } else { $f += $q }
    }
    $parts = @()
    if ($p.Count -gt 0) { $parts += ('[PlexKey] IN (' + ($p -join ',') + ')') }
    if ($f.Count -gt 0) { $parts += ('[FullPath] IN (' + ($f -join ',') + ')') }
    if ($parts.Count -eq 0) { return '1 = 0' }
    '(' + ($parts -join ' OR ') + ')'
}

function Test-ActiveByDate {
    if (-not $script:ActiveCollection) { return $false }
    $c = Get-CollectionByName $script:ActiveCollection
    [bool]($null -ne $c -and $c.ByDate)
}

function Get-DateOrdered {
    # Oldest first: by year, then by the exact release date where there is one, then by title. Unknown years go last.
    param($Records)
    @($Records | Sort-Object @{ Expression = { if ([int]$_.Year -gt 0) { [int]$_.Year } else { 9999 } } }, @{ Expression = { [string]$_.ReleaseDate } }, @{ Expression = { [string]$_.Title } })
}

function Get-TabRecords {
    # Only the records that belong to the active tab: TV rows have a Show name, movies do not.
    $tv = ($script:Tab -eq 'TV')
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in $script:ScanResults) { if ([bool][string]$r.Show -eq $tv) { $out.Add($r) } }
    $out.ToArray()
}

function Get-OrderedResults {
    $recs = @(Get-TabRecords)
    if (Test-ActiveByDate) { return (Get-DateOrdered $recs) }
    $recs
}

function Get-ScopedRecords {
    if ($script:Tab -eq 'TV') { return (Get-TvShowRecords) }
    $recs = @(Get-TabRecords)
    if ($null -ne $script:ScopeIds) { $recs = @($recs | Where-Object { $script:ScopeIds.Contains((Get-RecordId $_)) }) }
    if (Test-ActiveByDate) { $recs = Get-DateOrdered $recs }
    $recs
}

$script:OrderApplied = $false
function Set-CollectionOrder {
    # Puts the grid in release order while a "by release date" collection is active; leaves your own column sorting alone otherwise.
    if ($grid.DataSource -isnot [System.Data.DataTable]) { return }
    if (Test-ActiveByDate) { $grid.DataSource.DefaultView.Sort = '[Year] ASC, [ReleaseDate] ASC'; $script:OrderApplied = $true }
    elseif ($script:OrderApplied) { $grid.DataSource.DefaultView.Sort = ''; $script:OrderApplied = $false; Set-MovieSort }
}

function Update-Filter {
    try {
        $text = $txtFilter.Text.Trim()
        if ($grid.DataSource -is [System.Data.DataTable]) {
            $parts = @()
            $fx = Get-FilterExpression $grid.DataSource $text
            if ($fx) { $parts += ('(' + $fx + ')') }
            $sx = Get-ScopeExpression
            if ($sx) { $parts += $sx }
            $grid.DataSource.DefaultView.RowFilter = ($parts -join ' AND ')
            $total = if ($null -ne $script:ScopeIds) { $script:ScopeIds.Count } else { [int]$script:TabCounts[$script:Tab] }
            $lblCount.Text = '{0} of {1} titles' -f $grid.DataSource.DefaultView.Count, $total
        }
        # the detail list is rebuilt only while it is on screen (with 50,000+ episodes it is not free)
        if ($detailHost.Visible) { Update-DetailList -Filter $text; $script:DetailStale = $false } else { $script:DetailStale = $true }
        if ($posterHost.Visible) { Update-PosterList }
    }
    catch { Show-UiError 'Update-Filter' $_ }
}
#endregion

#region ---------------------------------------------------------------- Events
$script:UiErrShown = @{}
function Show-UiError {
    # A failure in a view is shown once per place (with the line), and every one is logged to %TEMP%\MMLM-errors.log.
    param([string]$Where, $Err)
    $msg = "{0}: {1}`n{2}" -f $Where, $Err, $Err.InvocationInfo.PositionMessage
    try { Add-Content -LiteralPath (Join-Path $env:TEMP 'MMLM-errors.log') -Value ((Get-Date).ToString('s') + ' ' + $msg) } catch { }
    if ($script:UiErrShown.ContainsKey($Where)) { return }
    $script:UiErrShown[$Where] = $true
    [Windows.Forms.MessageBox]::Show("Something went wrong in $Where (shown once; also logged to %TEMP%\MMLM-errors.log):`n`n$msg", 'Modern Media Library Manager', 'OK', 'Error') | Out-Null
}

# The C# helper's source is src\Mmlm.Native.cs (namespace Mmlm.Native: TvData, Snapshot); see Initialize-MmlmNative.

function Get-TvShowRecords {
    # The dashboard on the TV tab: one card per show (a copy of its first episode, named after the show, earliest year).
    if (@($script:TvRecords).Count -eq 0) { return @() }
    Initialize-MmlmNative
    $idx = [Mmlm.Native.TvData]::Index([object[]]$script:TvRecords)
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($show in [Mmlm.Native.TvData]::ShowOrder($idx)) {
        $first = [Mmlm.Native.TvData]::FirstEpisode($idx[$show])
        if ($null -eq $first) { continue }
        $c = $first.PSObject.Copy()
        $c.Title = $show
        $y = [Mmlm.Native.TvData]::MinYear($idx[$show])
        if ($y -gt 0) { $c.Year = $y }
        $out.Add($c)
    }
    $out.ToArray()
}

function Write-TvPage {
    # tv.html + tvdata.js + show posters in the live dashboard folder. Returns $false when there is nothing to show.
    if (@($script:TvRecords).Count -eq 0) { return $false }
    if (-not (Test-Path -LiteralPath $script:TvTemplatePath)) { throw "The TV page needs tv-template.html next to this script.`nLooked for: $($script:TvTemplatePath)" }
    Set-UiProgress -Text 'Preparing the TV page...'
    Initialize-MmlmNative
    $idx = [Mmlm.Native.TvData]::Index([object[]]$script:TvRecords)
    $thumbDir = Join-Path $script:LiveFolder 'thumbs'
    if (-not (Test-Path -LiteralPath $thumbDir)) { New-Item -Path $thumbDir -ItemType Directory -Force | Out-Null }
    $posters = @{}
    foreach ($show in $idx.Keys) {
        $first = [Mmlm.Native.TvData]::FirstEpisode($idx[$show])
        $src = [string]$first.PosterPath
        if (-not $src -or -not (Test-Path -LiteralPath $src)) { continue }
        try {
            # Plex posters are already small copies in the thumbnail folder; only other images need resizing
            $thumb = $(if ($src.StartsWith($script:ThumbFolder, [StringComparison]::OrdinalIgnoreCase)) { $src } else { Get-PosterThumbnail -Source $src })
            if ($thumb) {
                $leaf = [IO.Path]::GetFileName($thumb)
                $dest = Join-Path $thumbDir $leaf
                if (-not (Test-Path -LiteralPath $dest)) { Copy-Item -LiteralPath $thumb -Destination $dest }
                $posters[$show] = 'thumbs/' + $leaf
            }
        } catch { }
    }
    $js = [Mmlm.Native.TvData]::BuildJs($idx, $posters, (Get-LibraryName), (Get-Date).ToString('yyyy-MM-dd HH:mm'))
    [IO.File]::WriteAllText((Join-Path $script:LiveFolder 'tvdata.js'), $js, (New-Object Text.UTF8Encoding($false)))
    Copy-Item -LiteralPath $script:TvTemplatePath -Destination (Join-Path $script:LiveFolder 'tv.html') -Force
    $script:TvPageStale = $false
    $script:TvPageTicks = [DateTime]::Now.Ticks
    $true
}


function Get-SnapshotPath { param([string]$Which) Join-Path $script:SnapshotFolder ($(if ($Which -eq 'TV') { 'tv.mmls' } else { 'movies.mmls' })) }

function Save-LibrarySnapshot {
    # Writes one tab's records to its snapshot file on a background thread, so the window does not freeze on 50,000+ episodes.
    param([string]$Which, [object[]]$Records)
    try {
        Initialize-MmlmNative
        $path = Get-SnapshotPath $Which
        $meta = '{0}|{1}' -f $Records.Count, (Get-Date).ToString('yyyy-MM-dd HH:mm')
        $ps = [powershell]::Create()
        [void]$ps.AddScript({ param($r, $p, $m) [Mmlm.Native.Snapshot]::Save($r, $p, $m) }).AddArgument($Records).AddArgument($path).AddArgument($meta)
        [void]$script:SnapJobs.Add(@{ Ps = $ps; Async = $ps.BeginInvoke() })
        $script:SnapTimer.Start()
    }
    catch { Show-UiError 'Save-LibrarySnapshot' $_ }
}

function Import-LibrarySnapshot {
    # At start: movies load straight away; the TV page shows last session's page at once while the episodes load in the background.
    try {
        $mp = Get-SnapshotPath 'Movies'; $tp = Get-SnapshotPath 'TV'
        $haveM = Test-Path -LiteralPath $mp; $haveT = Test-Path -LiteralPath $tp
        if (-not $haveM -and -not $haveT) { return }
        Initialize-MmlmNative
        $movies = @(); $when = ''
        if ($haveM) {
            $movies = @([Mmlm.Native.Snapshot]::Load($mp)); $when = ([Mmlm.Native.Snapshot]::LastMeta -split '\|')[-1]
            try { Merge-MetaStore -Records $movies -Path $script:MetaStorePath } catch { }
        }
        $tvCount = 0
        if ($haveT) {
            $meta = ''
            try { $fs = [IO.File]::OpenRead($tp); $br = New-Object IO.BinaryReader($fs, [Text.Encoding]::UTF8); [void]$br.ReadInt32(); $meta = $br.ReadString(); $br.Close() } catch { }
            $tvCount = 0; [void][int]::TryParse(($meta -split '\|')[0], [ref]$tvCount)
            if (-not $when) { $when = ($meta -split '\|')[-1] }
            $js = Join-Path $script:LiveFolder 'tvdata.js'
            if (Test-Path -LiteralPath $js) {
                if (Test-Path -LiteralPath $script:TvTemplatePath) { Copy-Item -LiteralPath $script:TvTemplatePath -Destination (Join-Path $script:LiveFolder 'tv.html') -Force }
                $script:TvFromDisk = $true; $script:TvPageStale = $false; $script:TvPageTicks = (Get-Item -LiteralPath $js).LastWriteTime.Ticks
            }
            $ps = [powershell]::Create()
            [void]$ps.AddScript({ param($p) , [Mmlm.Native.Snapshot]::Load($p) }).AddArgument($tp)
            $script:TvLoad = @{ Ps = $ps; Async = $ps.BeginInvoke() }
            $script:SnapTimer.Start()
        }
        $script:ScanResults = $movies
        $script:TabCounts = @{ Movies = $movies.Count; TV = $tvCount }
        $script:MovieTable = ConvertTo-DataTable -Records $movies
        $grid.DataSource = $null
        Set-GridTable
        Update-Filter
        Update-TabLabels
        $lblStatus.Text = "Showing your last scan ($when)$(if ($haveT) { '; TV episodes are still loading' }). Scan checks Plex for changes."
        Set-View ([string]$script:TabView[$script:Tab])
    }
    catch { Show-UiError 'Import-LibrarySnapshot' $_ }
}

function Receive-SnapshotWork {
    # Timer tick: picks up the background TV load and finished saves.
    if ($null -ne $script:TvLoad -and $script:TvLoad.Async.IsCompleted) {
        $job = $script:TvLoad; $script:TvLoad = $null
        try {
            $tv = @($job.Ps.EndInvoke($job.Async) | ForEach-Object { $_ })
            if ($job.Ps.HadErrors -or $tv.Count -eq 0) { throw ($(if ($job.Ps.Streams.Error.Count) { $job.Ps.Streams.Error[0] } else { 'The TV snapshot was empty.' })) }
            $script:TvRecords = $tv
            $script:ScanResults = @($script:ScanResults) + $tv
            $script:HasTv = $true
            $script:TabCounts = @{ Movies = [int]$script:TabCounts['Movies']; TV = $tv.Count }
            Update-TabLabels
            $lblStatus.Text = $lblStatus.Text -replace '; TV episodes are still loading', ''
            if ($script:Tab -eq 'TV' -and $detailHost.Visible) { Update-DetailList -Filter $txtFilter.Text.Trim() }
        }
        catch {
            $lblStatus.Text = 'Could not load the last TV scan; scan TV Shows again.'
            try { Add-Content -LiteralPath (Join-Path $env:TEMP 'MMLM-errors.log') -Value ((Get-Date).ToString('s') + ' TV snapshot: ' + $_) } catch { }
        }
        finally { try { $job.Ps.Dispose() } catch { } }
    }
    foreach ($j in @($script:SnapJobs)) {
        if (-not $j.Async.IsCompleted) { continue }
        try { [void]$j.Ps.EndInvoke($j.Async) } catch { try { Add-Content -LiteralPath (Join-Path $env:TEMP 'MMLM-errors.log') -Value ((Get-Date).ToString('s') + ' snapshot save: ' + $_) } catch { } }
        try { $j.Ps.Dispose() } catch { }
        $script:SnapJobs.Remove($j)
    }
    if ($null -eq $script:TvLoad -and $script:SnapJobs.Count -eq 0) { $script:SnapTimer.Stop() }
}
$script:SnapTimer = New-Object Windows.Forms.Timer
$script:SnapTimer.Interval = 400
$script:SnapTimer.Add_Tick({ Receive-SnapshotWork })

function Show-TvPage {
    # Shows tv.html (posters or grid) in the embedded browser. Switching between the two only changes the page's #hash, so nothing reloads.
    param([ValidateSet('posters', 'grid')][string]$View)
    try {
        if ($script:TvPageStale) { if (-not (Write-TvPage)) { return } }
        $file = Join-Path $script:LiveFolder 'tv.html'
        $url  = ([Uri]$file).AbsoluteUri + '?t=' + $script:TvPageTicks + '#' + $View
        if (-not (Initialize-WebView2)) { Start-Process $url; return }
        $tag = 'tv:' + $script:TvPageTicks
        if ($script:WebShowing -eq $tag -and $null -ne $script:wv -and $null -ne $script:wv.CoreWebView2) {
            [void]$script:wv.CoreWebView2.ExecuteScriptAsync("if (location.hash !== '#$View') location.hash = '#$View';")
        }
        else {
            $script:WebShowing = $tag
            Show-DashboardPane -Url $url
        }
        Set-UiProgress -Text 'TV page ready.'
    }
    catch { Show-UiError 'Show-TvPage' $_ }
}

function Set-MovieSort {
    # Applies the Sort By choice to the Movies grid (Poster view follows the grid's order). A date-ordered collection keeps its own order.
    if ($null -eq $script:MovieTable -or -not [object]::ReferenceEquals($grid.DataSource, $script:MovieTable)) { return }
    if (Test-ActiveByDate) { return }
    $k = [string]$cboSort.SelectedItem
    if (-not $script:SortChoices.Contains($k)) { $k = 'Title' }
    $script:MovieTable.DefaultView.Sort = $script:SortChoices[$k]
    if ($posterHost.Visible) { Update-PosterList }
}

function Set-GridTable {
    try {
        # Movies use the WinForms grid; the TV tab's grid and posters are tv.html, so the grid is left empty there.
        # plain assignment on purpose: $( ) would unroll a DataTable into its rows and the grid would get an array of DataRows
        if ($script:Tab -eq 'TV') { $want = $null } else { $want = $script:MovieTable }
        if (-not [object]::ReferenceEquals($grid.DataSource, $want)) { $grid.DataSource = $want }
        if ($null -ne $want) { Set-GridColumnLayout; Set-MovieSort }
    }
    catch { Show-UiError 'Set-GridTable' $_ }
}

function Set-LibraryTab {
    param([string]$Name)
    if ($script:Tab -eq $Name) { return }
    $script:Tab = $Name
    $script:DashboardStale = $true            # the dashboard is built for one tab at a time
    $tabMovies.Invalidate(); $tabTv.Invalidate()
    $btnScan.Text = $(if ($Name -eq 'TV') { 'Scan TV Shows' } else { 'Scan Movies' })
    try {
        Set-GridTable
        if ($grid.DataSource -is [System.Data.DataTable]) { Update-Filter; $grid.ClearSelection() }
        Set-View ([string]$script:TabView[$Name])
    }
    catch {
        [Windows.Forms.MessageBox]::Show(("Could not switch tabs:`n{0}`n`n{1}" -f $_, $_.InvocationInfo.PositionMessage), 'Modern Media Library Manager', 'OK', 'Error') | Out-Null
    }
    if ($script:CurrentView -eq 'dashboard' -and $script:ScanResults.Count -gt 0 -and -not $script:Scanning) { Show-DashboardView }
}
$cboSort.Add_SelectedIndexChanged({ $script:Settings['SortBy'] = [string]$cboSort.SelectedItem; Set-MovieSort })
if ($script:Settings['SortBy'] -and $cboSort.Items.Contains([string]$script:Settings['SortBy'])) { $cboSort.SelectedItem = [string]$script:Settings['SortBy'] }
$tabMovies.Add_Click({ Set-LibraryTab 'Movies' })
$tabTv.Add_Click({ Set-LibraryTab 'TV' })
$btnViewGrid.Add_Click({ Set-View 'grid' })
$btnViewDetail.Add_Click({ Set-View 'detail' })
$btnViewPoster.Add_Click({ Set-View 'poster' })
$posterScroll.Add_ValueChanged({ $posterCanvas.Invalidate() })
$posterCanvas.Add_Resize({ if ($posterHost.Visible) { Update-PosterScroll } })
$posterCanvas.Add_MouseEnter({ [void]$posterCanvas.Focus() })
$posterCanvas.Add_MouseWheel({
    param($s, $e)
    if (-not $posterScroll.Enabled) { return }
    $maxV = $posterScroll.Maximum - $posterScroll.LargeChange + 1
    $v = $posterScroll.Value - [int]($e.Delta / 120.0 * $posterScroll.SmallChange * 1.5)
    $posterScroll.Value = [Math]::Max(0, [Math]::Min($maxV, $v))
})
$posterCanvas.Add_MouseMove({
    param($s, $e)
    $i = Get-PosterIndexAt $e.X $e.Y
    if ($i -ne $script:PosterHover) {
        $script:PosterHover = $i
        $txt = ''
        if ($i -ge 0) { $it = $script:PosterItems[$i]; $txt = $it.Title; if ($it.Year -gt 0) { $txt = "$txt ($($it.Year))" } }
        $tip.SetToolTip($posterCanvas, $txt)
    }
})
$posterCanvas.Add_MouseClick({
    param($s, $e)
    # Clicking a poster opens that title's card, the same card as the dashboard's View Library (with Export Card to PNG).
    # Closing the card comes back to the posters.
    if ($e.Button -ne [Windows.Forms.MouseButtons]::Left) { return }
    $i = Get-PosterIndexAt $e.X $e.Y
    if ($i -lt 0) { return }
    $it = $script:PosterItems[$i]
    $script:CardReturn = 'poster'
    Show-DashboardView -Card ('k:' + $it.Key)
})
$posterCanvas.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.Clear($script:cBg)
    $flagsC = [Windows.Forms.TextFormatFlags]::NoPadding -bor [Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [Windows.Forms.TextFormatFlags]::EndEllipsis -bor [Windows.Forms.TextFormatFlags]::SingleLine
    if ($script:PosterItems.Count -eq 0) {
        [Windows.Forms.TextRenderer]::DrawText($g, 'Nothing matches the current filter', $script:fontBase, (New-Object Drawing.Rectangle(0, 40, $s.ClientSize.Width, 30)), $script:cMuted, ($flagsC -bor [Windows.Forms.TextFormatFlags]::VerticalCenter))
        return
    }
    $geo = Get-PosterGeometry
    $top = $posterScroll.Value
    $r0 = [int][Math]::Floor($top / $geo.CH); $r1 = [int][Math]::Ceiling(($top + $s.ClientSize.Height) / $geo.CH)
    $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
    $bgPh = New-Object Drawing.SolidBrush($script:cPanel2)
    $flagsW = [Windows.Forms.TextFormatFlags]::NoPadding -bor [Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::WordBreak -bor [Windows.Forms.TextFormatFlags]::EndEllipsis
    try {
        for ($r = $r0; $r -le $r1; $r++) {
            for ($c = 0; $c -lt $geo.Cols; $c++) {
                $i = $r * $geo.Cols + $c
                if ($i -ge $script:PosterItems.Count) { break }
                $it = $script:PosterItems[$i]
                $x = $geo.X0 + $c * $geo.CW; $y = $r * $geo.CH - $top
                $rect = New-Object Drawing.Rectangle($x, $y, $script:PosterW, $script:PosterH)
                $img = Get-PosterImage $it.Path
                if ($null -ne $img) { $g.DrawImage($img, $rect) }
                else {
                    $g.FillRectangle($bgPh, $rect)
                    [Windows.Forms.TextRenderer]::DrawText($g, $it.Title, $script:fontBase, (New-Object Drawing.Rectangle(($x + 10), ($y + 10), ($script:PosterW - 20), ($script:PosterH - 20))), $script:cMuted, $flagsW)
                }
                $tr = New-Object Drawing.Rectangle(($x - 8), ($y + $script:PosterH + 4), ($script:PosterW + 16), 18)
                [Windows.Forms.TextRenderer]::DrawText($g, $it.Title, $script:fontSmall, $tr, $script:cText, $flagsC)
                if ($it.Year -gt 0) {
                    $yr = New-Object Drawing.Rectangle(($x - 8), ($y + $script:PosterH + 22), ($script:PosterW + 16), 16)
                    [Windows.Forms.TextRenderer]::DrawText($g, [string]$it.Year, $script:fontSmall, $yr, $script:cMuted, $flagsC)
                }
            }
        }
    }
    finally { $bgPh.Dispose() }
})
$txtFilter.Add_TextChanged({ Update-Filter })
$tip.SetToolTip($txtFilter, "Type to search title, file, genre, studio, cast or director.`nSuggestions appear as you type (Down, then Enter, picks one).`nOr filter columns with  field:value  - for example  source:unknown  or  resolution:1080p.`nNumber columns take ranges and comparisons:  year:1980-1989   rating:>=7.5.  Combine several terms to narrow further.`nExport CSV then saves only the rows shown.")

# Runtime is stored as minutes (so it sorts numerically) but always displayed as H:MM:SS
$grid.Add_CellFormatting({
    param($s, $e)
    if ($e.ColumnIndex -lt 0) { return }
    $cn = $s.Columns[$e.ColumnIndex].Name
    if ($cn -eq 'Season' -or $cn -eq 'Episode') {
        $isTv = $false; try { $isTv = [bool][string]$s.Rows[$e.RowIndex].Cells['Show'].Value } catch { }
        $e.Value = if ($isTv) { [string]$e.Value } else { '' }
        $e.FormattingApplied = $true
    }
    elseif ($cn -eq 'RuntimeMin') {
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
    elseif ($cn -eq 'Metascore') {
        $v = 0; if ($e.Value -isnot [DBNull] -and $null -ne $e.Value) { $v = [int]$e.Value }
        $e.Value = if ($v -gt 0) { "$v" } else { '' }
        $e.FormattingApplied = $true
    }
})

function Get-MetascoreColors {
    # Metacritic's bands: green 61-100, yellow 40-60, red 0-39 (dark text on yellow, white on the others)
    param([int]$Score)
    if ($Score -ge 61) { return @((RGB 102 204 51), (RGB 255 255 255)) }
    if ($Score -ge 40) { return @((RGB 255 204 51), (RGB 34 34 34)) }
    @((RGB 255 0 0), (RGB 255 255 255))
}

function Draw-MetascoreBadge {
    # A Metacritic-coloured square with the score on it.
    param($G, [int]$Score, [int]$X, [int]$Y, [int]$W, [int]$H)
    $c = Get-MetascoreColors $Score
    $G.SmoothingMode = 'AntiAlias'
    $br = New-Object Drawing.SolidBrush($c[0]); $G.FillRectangle($br, $X, $Y, $W, $H); $br.Dispose()
    $f = New-Object Drawing.Font($script:fontBold.FontFamily, 9, [Drawing.FontStyle]::Bold)
    [Windows.Forms.TextRenderer]::DrawText($G, [string]$Score, $f, (New-Object Drawing.Rectangle($X, $Y, $W, $H)), $c[1], ([Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::NoPadding))
    $f.Dispose()
}

# Rotten Tomatoes style scores: a tomato (critics) or popcorn bucket (audience) drawn by us, fresh at 60 % and up, splat / spilled below.
$grid.Add_CellPainting({
    param($s, $e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
    $cn = $s.Columns[$e.ColumnIndex].Name
    if ($cn -eq 'Metascore') {
        $e.Handled = $true
        $e.PaintBackground($e.ClipBounds, ($e.State -band [Windows.Forms.DataGridViewElementStates]::Selected) -ne 0)
        $txt = [string]$e.FormattedValue
        if ($txt) { Draw-MetascoreBadge $e.Graphics ([int]$txt) ($e.CellBounds.X + 8) ($e.CellBounds.Y + [int](($e.CellBounds.Height - 20) / 2)) 26 20 }
        return
    }
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
            $grn = New-Object Drawing.SolidBrush((RGB 112 168 44))
            $g.FillEllipse($yel, $ix + 11, $iy + 11, 5, 5); $g.FillEllipse($yel, $ix + 14, $iy + 8, 4, 4)
            $g.FillPolygon($grn, [Drawing.Point[]]@((New-Object Drawing.Point(($ix + 0), ($iy + 4))), (New-Object Drawing.Point(($ix + 12), ($iy + 8))), (New-Object Drawing.Point(($ix + 9), ($iy + 15))), (New-Object Drawing.Point(($ix + 2), ($iy + 12)))))
            $g.FillRectangle($wht, $ix + 5, $iy + 7, 3, 5)
            $grn.Dispose()
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
            $secs = @(Get-MmlmPlexSections -BaseUrl $url -Token $tok)
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
    $script:Settings['PlexTokenProtected'] = if ($script:PlexRemember) { Protect-MmlmPlexToken $script:PlexToken } else { '' }
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
    Update-DetailList; $script:DetailStale = $false
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
    foreach ($c in $grid.Columns) { if ($script:HiddenFields -notcontains $c.Name) { [void]$clb.Items.Add($c.Name, $c.Visible) } }
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
        Details = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
        Partial = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
    })
    Update-MmlmContext
    $script:ScanUsePlex = $false
    $script:ScanMode    = 'Scrape'
    $script:KeepRecords = @()
    $script:ScanWatch   = [Diagnostics.Stopwatch]::StartNew()
    $script:CancelAt    = $null
    $script:RateT = $null; $script:RateV = 0; $script:RateVal = $null
    $script:EtaStep = @{ T = $null; F = 0.0; R = $null }; $script:EtaAll = @{ T = $null; F = 0.0; R = $null }; $script:LastPhase = 0
    $btnScan.Enabled = $false; $btnBrowse.Enabled = $false; $btnDash.Enabled = $false; $btnSaveHtml.Enabled = $false; $btnExport.Enabled = $false; $btnCancel.Enabled = $true; $btnFetch.Enabled = $false
    Set-OverallProgress -Fraction 0.0
    $script:DashboardStale = $true
    $lblStatus.Text = 'Starting...'
    $lnkDetails.Visible = $false; $script:FetchDetails = @()
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
    @{ N = 'Source';            L = 'Source';                        K = 'source'; H = 'e.g. 4K Remux' },
    @{ N = 'RTCritic';          L = 'Rotten Tomatoes - critics';     K = 'int';    Min = 0; Max = 100; H = '% (0 - 100)' },
    @{ N = 'RTAudience';        L = 'Rotten Tomatoes - audience';    K = 'int';    Min = 0; Max = 100; H = '% (0 - 100)' },
    @{ N = 'Metascore';         L = 'Metacritic Metascore';          K = 'int';    Min = 0; Max = 100; H = '0 - 100' },
    @{ N = 'CinemaScore';       L = 'CinemaScore';                   K = 'grade';  H = 'A+ to F' },
    @{ N = 'BoxOfficeDomestic'; L = 'All-time domestic';             K = 'money';  H = '$ or 12.5M' },
    @{ N = 'BoxOfficeWorldwide';L = 'All-time worldwide';            K = 'money';  H = '$ or 1.2B' },
    @{ N = 'OpeningDomestic';   L = 'Opening weekend - domestic';    K = 'money';  H = '$ or 12.5M' },
    @{ N = 'OpeningWorldwide';  L = 'Opening weekend - worldwide';   K = 'money';  H = '$ or 12.5M' }
)

function Get-EditText {
    param($Spec, $Value)
    if (Test-MmlmValueEmpty $Value) { return '' }
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
        'source' {
            $hit = $script:SourceLabels | Where-Object { $_ -eq $Text.Trim() } | Select-Object -First 1
            if (-not $hit) { throw "${L}: use one of " + ($script:SourceLabels -join ', ') + '.' }
            return $hit
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
    foreach ($k in (Get-MmlmMetaKeys $Rec)) { if ($Store.ContainsKey($k)) { return @{ Key = $k; Entry = $Store[$k] } } }
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

    $store = Read-MmlmMetaStore -Path $script:MetaStorePath
    $found = Find-MetaEntry $store $rec
    $manual = if ($found) { $found.Entry.Manual } else { @{} }
    $res = Show-MetaEditor -Rec $rec -Manual $manual
    if ($null -eq $res -or ($res.Put.Count -eq 0 -and $res.Del.Count -eq 0)) { return }

    # 1) the store file
    if ($found) { $key = $found.Key; $entry = $found.Entry }
    else { $key = (Get-MmlmMetaKeys $rec)[0]; $entry = @{ Manual = @{}; Scraped = @{}; Force = @(); Sources = @{}; At = '' } }
    foreach ($n in $res.Put.Keys) { $entry.Manual[$n] = $res.Put[$n] }
    foreach ($n in $res.Del) { $entry.Manual.Remove($n) }
    $entry.At = (Get-Date).ToString('s')
    if ($entry.Manual.Count -eq 0 -and $entry.Scraped.Count -eq 0) { $store.Remove($key) } else { $store[$key] = $entry }
    try { Write-MmlmMetaStore -Path $script:MetaStorePath -Store $store }
    catch { [Windows.Forms.MessageBox]::Show("Could not save the changes:`n$_", 'Edit info', 'OK', 'Error') | Out-Null; return }

    # 2) what is on screen right now (the next scan re-applies the store by itself)
    $note = @()
    foreach ($n in $res.Put.Keys) {
        $f = $script:Fields | Where-Object { $_.Name -eq $n } | Select-Object -First 1
        $typed = [Convert]::ChangeType($res.Put[$n], $script:TypeMap[$f.Type])
        Set-MmlmRecField $rec $n $typed
        $drv.Row[$n] = $typed
    }
    foreach ($n in $res.Del) {
        if ($n -eq 'Source') {
            $c = Get-SourceClass $rec
            Set-MmlmRecField $rec 'Source' $c.Label; Set-MmlmRecField $rec 'SourceWhy' $c.Why
            $drv.Row['Source'] = $c.Label; $drv.Row['SourceWhy'] = $c.Why
        }
        elseif ($entry.Scraped.ContainsKey($n)) {
            $f = $script:Fields | Where-Object { $_.Name -eq $n } | Select-Object -First 1
            try { $typed = [Convert]::ChangeType($entry.Scraped[$n], $script:TypeMap[$f.Type]); Set-MmlmRecField $rec $n $typed; $drv.Row[$n] = $typed } catch { }
        }
        else { $note += $n }
    }
    $names = @($res.Put.Keys) + @($res.Del)
    $keep = @(([string]$rec.MetaSources -split '; ') | Where-Object { $t = $_; $_ -and -not ($res.Put.Keys -contains ($t -split ':')[0]) -and -not ($res.Del -contains ($t -split ':')[0]) })
    $keep += @($res.Put.Keys | ForEach-Object { '{0}: manual' -f $_ })
    Set-MmlmRecField $rec 'MetaSources' ($keep -join '; ')
    $drv.Row['MetaSources'] = [string]$rec.MetaSources
    $script:DashboardStale = $true
    $lblStatus.Text = 'Saved {0} change(s) for {1}.' -f $names.Count, $rec.Title
    if ($note.Count -gt 0) { $lblStatus.Text += ' The original value for ' + ($note -join ', ') + ' comes back on the next scan.' }
}

$btnEdit.Add_Click({ Edit-SelectedMetadata })
$tip.SetToolTip($btnEdit, "Type in values the online sources do not have (Rotten Tomatoes audience, CinemaScore, opening weekend...)`nfor the selected title. Saved in this app's data file only - never in your media files or Plex.")

#region ---------------------------------------------------------------- Collections (custom title lists for the views and the dashboard)
# A collection is a named list of titles. "Hand-picked" ones hold the titles you added; "rule" ones are a saved filter (+ sort + limit)
# that is re-evaluated against every scan. They live ONLY in this app's own data file (collections.json); nothing is written to Plex or to media files.
# Picking one in the Collection box scopes the grid, detail view, dashboard and exports to its titles.
$script:Collections      = New-Object System.Collections.ArrayList
$script:ActiveCollection = ''
$script:ScopeIds         = $null
$script:CollGuard        = $false

function Import-Collections {
    $script:Collections = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $script:CollectionsPath)) { return }
    try {
        $j = [IO.File]::ReadAllText($script:CollectionsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($c in @($j.Collections)) {
            if ($null -eq $c -or -not $c.Name) { continue }
            $items = New-Object System.Collections.ArrayList
            foreach ($it in @($c.Items)) {
                if ($null -eq $it -or -not $it.Ids) { continue }
                [void]$items.Add(@{ Ids = @($it.Ids | ForEach-Object { [string]$_ }); Title = [string]$it.Title; Year = [int]$it.Year })
            }
            $type = if ([string]$c.Type -eq 'rule') { 'rule' } else { 'manual' }
            [void]$script:Collections.Add(@{
                Name = [string]$c.Name; Type = $type; Items = $items; Query = [string]$c.Query; SortBy = [string]$c.SortBy
                SortDesc = [bool]$c.SortDesc; ByDate = [bool]$c.ByDate; Limit = [int]$c.Limit; Created = [string]$c.Created; Modified = [string]$c.Modified })
        }
    }
    catch { }
}

function Save-Collections {
    try {
        $dir = Split-Path -Parent $script:CollectionsPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        $tmp = $script:CollectionsPath + '.tmp'
        $doc = @{ Version = 1; Collections = @($script:Collections.ToArray()) }
        [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $doc -Depth 6), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $script:CollectionsPath -Force
        return $true
    }
    catch {
        [Windows.Forms.MessageBox]::Show("Could not save the collections:`n$_", 'Collections', 'OK', 'Error') | Out-Null
        return $false
    }
}

function Get-CollectionByName {
    param([string]$Name)
    foreach ($c in $script:Collections) { if ([string]$c.Name -ieq $Name) { return $c } }
    $null
}

function Resolve-Collection {
    # The ids of the records in this collection, against the scan that is on screen. Returns a HashSet.
    param($Col)
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    if ($null -eq $Col -or $script:ScanResults.Count -eq 0) { return ,$set }
    if ([string]$Col.Type -eq 'rule') {
        $tbl = $grid.DataSource
        if ($tbl -isnot [System.Data.DataTable]) { return ,$set }
        try {
            $expr = Get-UnionExpression $tbl ([string]$Col.Query)
            $sort = ''
            if ($Col.SortBy -and $null -ne $tbl.Columns[[string]$Col.SortBy]) { $sort = '[{0}] {1}' -f $Col.SortBy, $(if ($Col.SortDesc) { 'DESC' } else { 'ASC' }) }
            $rows = @($tbl.Select($expr, $sort))
            if ([int]$Col.Limit -gt 0) { $rows = @($rows | Select-Object -First ([int]$Col.Limit)) }
            foreach ($r in $rows) { [void]$set.Add((Get-RowId $r)) }
        }
        catch { }
        return ,$set
    }
    $want = @{}
    foreach ($it in $Col.Items) { foreach ($k in $it.Ids) { $want[[string]$k] = $true } }
    foreach ($r in $script:ScanResults) {
        foreach ($k in (Get-MmlmMetaKeys $r)) { if ($want.ContainsKey($k)) { [void]$set.Add((Get-RecordId $r)); break } }
    }
    return ,$set
}

function Update-CollectionBar {
    $script:CollGuard = $true
    try {
        $cboColl.BeginUpdate()
        $cboColl.Items.Clear()
        [void]$cboColl.Items.Add('All titles')
        foreach ($c in @($script:Collections | Sort-Object { [string]$_.Name })) { [void]$cboColl.Items.Add([string]$c.Name) }
        $i = 0
        if ($script:ActiveCollection) { $j = $cboColl.Items.IndexOf($script:ActiveCollection); if ($j -ge 0) { $i = $j } }
        $cboColl.SelectedIndex = $i
        $cboColl.EndUpdate()
    }
    finally { $script:CollGuard = $false }
    $col = $null
    if ($script:ActiveCollection) { $col = Get-CollectionByName $script:ActiveCollection }
    $btnCollEdit.Enabled = ($null -ne $col); $btnCollDel.Enabled = ($null -ne $col)
    if ($null -eq $col) {
        $lblCollInfo.Text = 'Create or Select a Collection'
        return
    }
    $n = if ($null -ne $script:ScopeIds) { $script:ScopeIds.Count } else { 0 }
    if ([string]$col.Type -eq 'rule') {
        $bits = @()
        if ($col.Query) { $bits += [string]$col.Query }
        if ($col.SortBy) { $bits += ('sorted by {0}{1}' -f $col.SortBy, $(if ($col.SortDesc) { ' (highest first)' } else { '' })) }
        if ([int]$col.Limit -gt 0) { $bits += ('top {0}' -f $col.Limit) }
        if ($col.ByDate) { $bits += 'in release order' }
        $lblCollInfo.Text = ('Dynamic: {0}   -   {1} title(s) in this scan' -f ($bits -join ', '), $n)
    }
    else { $lblCollInfo.Text = ('Static: {0} saved, {1} found in this scan{2}' -f $col.Items.Count, $n, $(if ($col.ByDate) { ', in release order' } else { '' })) }
}

function Update-CollectionScope {
    # Re-resolves the active collection (after a scan, or after its contents changed). Does not repaint the views.
    $script:ScopeIds = $null
    if ($script:ActiveCollection) {
        $col = Get-CollectionByName $script:ActiveCollection
        if ($null -eq $col) { $script:ActiveCollection = '' }
        else { $script:ScopeIds = Resolve-Collection $col }
    }
    $script:DashboardStale = $true
    Update-CollectionBar
}

function Set-CollectionScope {
    param([string]$Name)
    $script:ActiveCollection = ''
    if ($Name) { $col = Get-CollectionByName $Name; if ($null -ne $col) { $script:ActiveCollection = [string]$col.Name } }
    Update-CollectionScope
    Set-CollectionOrder
    Update-Filter
    if ($script:CurrentView -eq 'dashboard' -and $script:ScanResults.Count -gt 0) { Show-DashboardView }
}

function Get-SelectedRecords {
    # The records behind the rows selected in the grid (nothing when no row is selected).
    $out = New-Object System.Collections.Generic.List[object]
    if ($grid.DataSource -isnot [System.Data.DataTable]) { return @() }
    $byId = @{}
    foreach ($r in $script:ScanResults) { $byId[(Get-RecordId $r)] = $r }
    foreach ($row in @($grid.SelectedRows)) {
        $d = $row.DataBoundItem
        if ($null -eq $d) { continue }
        $id = Get-RowId $d.Row
        if ($byId.ContainsKey($id)) { $out.Add($byId[$id]) }
    }
    $out.ToArray()
}

function Get-RecordsById {
    # The scanned records behind a list of record ids (the Add button in the collection editor collects ids).
    param([string[]]$Ids)
    $want = @{}
    foreach ($i in @($Ids)) { $want[[string]$i] = $true }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in $script:ScanResults) { if ($want.ContainsKey((Get-RecordId $r))) { $out.Add($r) } }
    $out.ToArray()
}

function Add-RecordsToCollection {
    # Adds titles to a Static (hand-picked) collection (skipping ones already in it). Returns how many were new.
    param($Col, $Records)
    $have = @{}
    foreach ($it in $Col.Items) { foreach ($k in $it.Ids) { $have[[string]$k] = $true } }
    $added = 0
    foreach ($r in @($Records)) {
        $ids = @(Get-MmlmMetaKeys $r)
        $dup = $false
        foreach ($k in $ids) { if ($have.ContainsKey($k)) { $dup = $true; break } }
        if ($dup) { continue }
        [void]$Col.Items.Add(@{ Ids = $ids; Title = [string]$r.Title; Year = [int]$r.Year })
        foreach ($k in $ids) { $have[$k] = $true }
        $added++
    }
    if ($added -gt 0) { $Col.Modified = (Get-Date).ToString('s') }
    $added
}

function Show-AddToCollectionDialog {
    # Returns the collection name to add to (an existing Static one, or a new name), or $null.
    param([int]$Count)
    $dlg  = New-DialogForm 'Add to collection' 480 226
    $head = New-Label ("Add {0} title(s) to:" -f $Count) 24 18 $script:cText $script:fontBold
    $cbo  = New-Object Windows.Forms.ComboBox
    $cbo.DropDownStyle = 'DropDown'; $cbo.FlatStyle = 'Flat'
    $cbo.Location = New-Object Drawing.Point(24, 50); $cbo.Size = New-Object Drawing.Size(432, 26)
    $cbo.BackColor = $script:cPanel2; $cbo.ForeColor = $script:cText
    foreach ($c in @($script:Collections | Sort-Object { [string]$_.Name })) { if ([string]$c.Type -eq 'manual') { [void]$cbo.Items.Add([string]$c.Name) } }
    if ($script:ActiveCollection) {
        $a = Get-CollectionByName $script:ActiveCollection
        if ($null -ne $a -and [string]$a.Type -eq 'manual') { $cbo.Text = [string]$a.Name }
    }
    $note = New-Object Windows.Forms.Label
    $note.Location = New-Object Drawing.Point(24, 86); $note.Size = New-Object Drawing.Size(432, 36)
    $note.ForeColor = $script:cMuted; $note.BackColor = [Drawing.Color]::Transparent; $note.Font = $script:fontSmall
    $note.Text = 'Pick a Static collection, or type a new name to create one. Dynamic collections fill themselves from their filter.'
    $err = New-Object Windows.Forms.Label
    $err.Location = New-Object Drawing.Point(24, 130); $err.Size = New-Object Drawing.Size(432, 20)
    $err.ForeColor = (RGB 255 107 129); $err.BackColor = [Drawing.Color]::Transparent
    $script:AcCbo = $cbo; $script:AcErr = $err; $script:AcDlg = $dlg; $script:AcResult = $null
    $ok = New-FlatButton 'Add' 100 'primary'; $ok.Location = New-Object Drawing.Point(250, 172)
    $cancel = New-FlatButton 'Cancel' 100 'secondary'; $cancel.Location = New-Object Drawing.Point(356, 172)
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    $ok.Add_Click({
        $name = $script:AcCbo.Text.Trim()
        if (-not $name) { $script:AcErr.Text = 'Pick a collection or type a name.'; return }
        $ex = Get-CollectionByName $name
        if ($null -ne $ex -and [string]$ex.Type -eq 'rule') { $script:AcErr.Text = 'That is a Dynamic collection; it fills itself from its filter.'; return }
        $script:AcResult = $name
        $script:AcDlg.DialogResult = [Windows.Forms.DialogResult]::OK
    })
    $dlg.Controls.AddRange(@($head, $cbo, $note, $err, $ok, $cancel))
    $res = $dlg.ShowDialog($form)
    $dlg.Dispose()
    if ($res -ne [Windows.Forms.DialogResult]::OK) { return $null }
    $script:AcResult
}

function Show-CollectionEditor {
    # New or edit. Returns @{ Name; Type; Query; SortBy; SortDesc; Limit; AddSelected; Picked } or $null (Picked = ids gathered with the Add button).
    param($Col = $null, [string]$DefaultQuery = '', [int]$SelectedCount = 0)
    $isNew = ($null -eq $Col)
    $ttl = if ($isNew) { 'New collection' } else { 'Edit collection' }
    $dlg = New-DialogForm $ttl 540 596

    $lblN = New-Label 'NAME' 24 18 $script:cMuted $script:fontSmall
    $txtN = New-Object Windows.Forms.TextBox
    $txtN.Location = New-Object Drawing.Point(24, 40); $txtN.Size = New-Object Drawing.Size(492, 26)
    $txtN.BackColor = $script:cPanel2; $txtN.ForeColor = $script:cText; $txtN.BorderStyle = 'FixedSingle'; $txtN.MaxLength = 80

    $lblK  = New-Label 'FILTER' 24 82 $script:cMuted $script:fontSmall
    $isRule = if ($isNew) { [bool]$DefaultQuery } else { [string]$Col.Type -eq 'rule' }
    $rbMan  = New-FlatRadio 'Static (manual additions)' 24 104 (-not $isRule)
    $rbRule = New-FlatRadio 'Dynamic (grows with library changes)' 24 130 $isRule
    $lblKindHelp = New-Object Windows.Forms.Label
    $lblKindHelp.Location = New-Object Drawing.Point(24, 158); $lblKindHelp.Size = New-Object Drawing.Size(492, 40)
    $lblKindHelp.ForeColor = $script:cMuted; $lblKindHelp.BackColor = [Drawing.Color]::Transparent; $lblKindHelp.Font = $script:fontSmall

    $lblQ = New-Label 'FILTER TERMS' 24 172 $script:cMuted $script:fontSmall
    $txtQ = New-Object Windows.Forms.TextBox
    $txtQ.Location = New-Object Drawing.Point(24, 194); $txtQ.Size = New-Object Drawing.Size(398, 26)
    $btnAddQ = New-FlatButton 'Add' 84 'secondary'; $btnAddQ.Location = New-Object Drawing.Point(432, 190); $btnAddQ.Height = 32
    $txtQ.BackColor = $script:cPanel2; $txtQ.ForeColor = $script:cText; $txtQ.BorderStyle = 'FixedSingle'
    $hq = New-Object Windows.Forms.Label
    $hq.Location = New-Object Drawing.Point(24, 224); $hq.Size = New-Object Drawing.Size(492, 34)
    $hq.ForeColor = $script:cMuted; $hq.BackColor = [Drawing.Color]::Transparent; $hq.Font = $script:fontSmall
    $hq.Text = ''

    $lblS = New-Label 'SORT BY' 24 268 $script:cMuted $script:fontSmall
    $cboS = New-Object Windows.Forms.ComboBox
    $cboS.DropDownStyle = 'DropDownList'; $cboS.FlatStyle = 'Flat'
    $cboS.Location = New-Object Drawing.Point(24, 290); $cboS.Size = New-Object Drawing.Size(220, 26)
    $cboS.BackColor = $script:cPanel2; $cboS.ForeColor = $script:cText
    [void]$cboS.Items.Add('(none)')
    [void]$cboS.Items.Add('Title')
    foreach ($f in $script:Fields) { if ($f.Show -and ($f.Type -eq 'int' -or $f.Type -eq 'double' -or $f.Type -eq 'long') -and $cboS.Items.IndexOf($f.Name) -lt 0) { [void]$cboS.Items.Add($f.Name) } }
    $chkDesc = New-FlatCheckBox 'Highest first' 262 292
    $lblL = New-Label 'LIMIT (0 = ALL)' 400 268 $script:cMuted $script:fontSmall
    $nudL = New-Object Windows.Forms.NumericUpDown
    $nudL.Location = New-Object Drawing.Point(400, 290); $nudL.Size = New-Object Drawing.Size(116, 26)
    $nudL.Minimum = 0; $nudL.Maximum = 5000; $nudL.Value = 0
    $nudL.BackColor = $script:cPanel2; $nudL.ForeColor = $script:cText; $nudL.BorderStyle = 'FixedSingle'
    $hs = New-Object Windows.Forms.Label
    $hs.Location = New-Object Drawing.Point(24, 324); $hs.Size = New-Object Drawing.Size(492, 34)
    $hs.ForeColor = $script:cMuted; $hs.BackColor = [Drawing.Color]::Transparent; $hs.Font = $script:fontSmall
    $hs.Text = ''

    $chkDate = New-FlatCheckBox 'By release date (oldest first)' 24 366
    $chkAdd = New-FlatCheckBox ("Add the {0} selected title(s) now" -f $SelectedCount) 24 398 $true
    $chkAdd.Visible = ($isNew -and $SelectedCount -gt 0)
    $lblPicked = New-Object Windows.Forms.Label
    $lblPicked.Location = New-Object Drawing.Point(24, 432); $lblPicked.Size = New-Object Drawing.Size(420, 20)
    $lblPicked.ForeColor = $script:cText; $lblPicked.BackColor = [Drawing.Color]::Transparent; $lblPicked.Font = $script:fontBase
    $lnkClear = New-Object Windows.Forms.LinkLabel
    $lnkClear.Text = 'Clear'; $lnkClear.AutoSize = $true; $lnkClear.Location = New-Object Drawing.Point(452, 433); $lnkClear.Visible = $false
    $lnkClear.LinkColor = $script:cAccent; $lnkClear.ActiveLinkColor = $script:cAccent2; $lnkClear.BackColor = [Drawing.Color]::Transparent

    if ($isNew) { $txtQ.Text = $DefaultQuery; $cboS.SelectedIndex = 0 }
    else {
        $txtN.Text = [string]$Col.Name; $txtQ.Text = [string]$Col.Query
        $si = if ($Col.SortBy) { $cboS.Items.IndexOf([string]$Col.SortBy) } else { 0 }
        $cboS.SelectedIndex = [math]::Max(0, $si)
        $chkDesc.Checked = [bool]$Col.SortDesc
        $chkDate.Checked = [bool]$Col.ByDate
        $nudL.Value = [math]::Min(5000, [math]::Max(0, [int]$Col.Limit))
        $rbMan.Enabled = $false; $rbRule.Enabled = $false          # the kind is fixed once it exists
    }

    Enable-FilterSuggest -TextBox $txtQ -Owner $dlg -GetTable { , $grid.DataSource }
    $script:CeKindHelp = $lblKindHelp; $script:CeQBox = $txtQ
    $script:CeRb = $rbRule; $script:CeAdd = $chkAdd; $script:CeAddQ = $btnAddQ; $script:CeHq = $hq; $script:CeHs = $hs
    $script:CePicked = New-Object 'System.Collections.Generic.List[string]'
    $script:CeHave = New-Object 'System.Collections.Generic.HashSet[string]'          # titles already in the collection (editing)
    if (-not $isNew) { $have = Resolve-Collection $Col; if ($null -ne $have) { $script:CeHave = $have } }
    $script:CePickLbl = $lblPicked; $script:CeClear = $lnkClear
    $apply = {
        $rule = [bool]$script:CeRb.Checked
        $script:CeKindHelp.Text = if ($rule) { 'Dynamic: a saved filter that is re-checked on every scan. New matches join by themselves and titles that stop matching drop out. Only the filter is stored.' } else { 'Static: a fixed list. Titles stay in it until you remove them. Fill it with the Add button (every title a filter finds) or by selecting titles in the grid.' }
        $script:CeAdd.Enabled = -not $rule
        $script:CeAddQ.Enabled = -not $rule
        $script:CeQBox.Tag.Commas = $rule
        if ($rule) {
            $script:CeHq.Text = 'Combine filters with commas, e.g.  title:harry potter, title:fantastic beasts  (a title matching any part is included). One filter:  genre:Horror year:1980-1989'
            $script:CeHs.Text = 'A top 10 is: sort by Rating, highest first, limit 10. A sort and limit with an empty filter ranks the whole library.'
        }
        else {
            $script:CeHq.Text = 'Type a filter, then click Add to put every matching title in the collection. Change the filter and click Add again to build it up.'
            $script:CeHs.Text = 'Sort and limit choose which titles Add takes: for a top 10, sort by Rating (highest first) with a limit of 10, then click Add.'
        }
    }
    $rbRule.Add_CheckedChanged($apply)
    & $apply

    $err = New-Object Windows.Forms.Label
    $err.Location = New-Object Drawing.Point(24, 462); $err.Size = New-Object Drawing.Size(492, 20)
    $err.ForeColor = (RGB 255 107 129); $err.BackColor = [Drawing.Color]::Transparent
    $okText = if ($isNew) { 'Create' } else { 'Save' }
    $ok = New-FlatButton $okText 100 'primary'; $ok.Location = New-Object Drawing.Point(310, 496)
    $cancel = New-FlatButton 'Cancel' 100 'secondary'; $cancel.Location = New-Object Drawing.Point(416, 496)
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel

    $script:CeDlg = $dlg; $script:CeErr = $err; $script:CeName = $txtN; $script:CeQ = $txtQ; $script:CeSort = $cboS; $script:CeDesc = $chkDesc; $script:CeLimit = $nudL
    $script:CeCol = $Col; $script:CeResult = $null; $script:CeDate = $chkDate
    $ok.Add_Click({
        $name = $script:CeName.Text.Trim()
        if (-not $name) { $script:CeErr.Text = 'Give the collection a name.'; return }
        $ex = Get-CollectionByName $name
        if ($null -ne $ex -and -not [object]::ReferenceEquals($ex, $script:CeCol)) { $script:CeErr.Text = 'A collection with that name already exists.'; return }
        $kind = if ($script:CeRb.Checked) { 'rule' } else { 'manual' }
        $q = $script:CeQ.Text.Trim()
        $s = if ($script:CeSort.SelectedIndex -gt 0) { [string]$script:CeSort.SelectedItem } else { '' }
        $lim = [int]$script:CeLimit.Value
        if ($kind -eq 'rule' -and -not ($q -replace '[,\s]', '') -and -not $s -and $lim -le 0) { $script:CeErr.Text = 'A Dynamic collection needs a filter, or a sort and a limit.'; return }
        $script:CeResult = @{ Name = $name; Type = $kind; Query = $(if ($kind -eq 'rule') { $q } else { '' }); SortBy = $(if ($kind -eq 'rule') { $s } else { '' })
                              SortDesc = [bool]($kind -eq 'rule' -and $script:CeDesc.Checked); ByDate = [bool]$script:CeDate.Checked; Limit = $(if ($kind -eq 'rule') { $lim } else { 0 }); AddSelected = [bool]$script:CeAdd.Checked; Picked = @($script:CePicked.ToArray()) }
        $script:CeDlg.DialogResult = [Windows.Forms.DialogResult]::OK
    })
    $script:CeOk = $ok; $script:CeTitle = $isNew
    $tip.SetToolTip($btnAddQ, 'For Static collections: adds every title the filter finds. A Dynamic collection is the filter itself, so Add is off for it.')
    # Add: everything the filter (with its sort and limit) finds goes into the pending list; a later Create / Save puts the list in the collection.
    $btnAddQ.Add_Click({
        $script:CeErr.Text = ''
        $tbl = $grid.DataSource
        if ($tbl -isnot [System.Data.DataTable]) { $script:CeErr.Text = 'Scan a library first.'; return }
        $q = $script:CeQ.Text.Trim()
        $lim = [int]$script:CeLimit.Value
        $sortBy = if ($script:CeSort.SelectedIndex -gt 0) { [string]$script:CeSort.SelectedItem } else { '' }
        try {
            $expr = Get-FilterExpression $tbl $q
            $sort = ''
            if ($sortBy -and $null -ne $tbl.Columns[$sortBy]) { $sort = '[{0}] {1}' -f $sortBy, $(if ($script:CeDesc.Checked) { 'DESC' } else { 'ASC' }) }
            $rows = @($tbl.Select($expr, $sort))
        }
        catch { $script:CeErr.Text = 'That filter could not be read. Check it and try again.'; return }
        if ($lim -gt 0) { $rows = @($rows | Select-Object -First $lim) }
        if ($rows.Count -eq 0) { $script:CeErr.Text = 'No titles match that filter.'; return }
        if (-not $q -and $lim -le 0) {
            $ask = [Windows.Forms.MessageBox]::Show(('The filter is empty, so this adds all {0} titles in the library. Add them all?' -f $rows.Count), 'Add', 'YesNo', 'Question')
            if ($ask -ne [Windows.Forms.DialogResult]::Yes) { return }
        }
        $new = 0; $already = 0
        $inList = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($x in $script:CePicked) { [void]$inList.Add($x) }
        foreach ($r in $rows) {
            $id = Get-RowId $r
            if ($inList.Contains($id) -or $script:CeHave.Contains($id)) { $already++; continue }
            $script:CePicked.Add($id); [void]$inList.Add($id); $new++
        }
        $msg = '{0} title(s) ready to add' -f $script:CePicked.Count
        $msg += $(if ($new -gt 0) { " (+$new just now)" } else { ' (nothing new from that filter)' })
        if ($already -gt 0 -and $new -gt 0) { $msg += ", $already already in" }
        $script:CePickLbl.Text = $msg + '.'
        $script:CeClear.Visible = ($script:CePicked.Count -gt 0)
    })
    $lnkClear.Add_LinkClicked({
        $script:CePicked.Clear(); $script:CePickLbl.Text = ''; $script:CeClear.Visible = $false
    })
    # Enter in the filter box means Add for a hand-picked collection (it would otherwise press Create).
    $txtQ.Add_Enter({ if (-not [bool]$script:CeRb.Checked) { $script:CeDlg.AcceptButton = $script:CeAddQ } })
    $txtQ.Add_Leave({ $script:CeDlg.AcceptButton = $script:CeOk })
    foreach ($c in @($lblQ, $txtQ, $btnAddQ, $hq, $lblS, $cboS, $chkDesc, $lblL, $nudL, $hs, $chkDate, $chkAdd, $lblPicked, $lnkClear, $err, $ok, $cancel)) { $c.Top += 48 }
    $dlg.Controls.AddRange(@($lblN, $txtN, $lblK, $rbMan, $rbRule, $lblKindHelp, $lblQ, $txtQ, $btnAddQ, $hq, $lblS, $cboS, $chkDesc, $lblL, $nudL, $hs, $chkDate, $chkAdd, $lblPicked, $lnkClear, $err, $ok, $cancel))
    $res = $dlg.ShowDialog($form)
    $dlg.Dispose()
    if ($res -ne [Windows.Forms.DialogResult]::OK) { return $null }
    $script:CeResult
}

function New-CollectionFromUi {
    if ($script:ScanResults.Count -eq 0) { return }
    $sel = @(Get-SelectedRecords)
    $res = Show-CollectionEditor -Col $null -DefaultQuery $txtFilter.Text.Trim() -SelectedCount $sel.Count
    if ($null -eq $res) { return }
    $now = (Get-Date).ToString('s')
    $col = @{ Name = $res.Name; Type = $res.Type; Items = (New-Object System.Collections.ArrayList); Query = $res.Query; SortBy = $res.SortBy
              SortDesc = $res.SortDesc; ByDate = $res.ByDate; Limit = $res.Limit; Created = $now; Modified = $now }
    $added = 0
    if ($res.Type -eq 'manual' -and $res.AddSelected) { $added = Add-RecordsToCollection $col $sel }
    if ($res.Type -eq 'manual' -and @($res.Picked).Count -gt 0) { $added += (Add-RecordsToCollection $col (Get-RecordsById $res.Picked)) }
    [void]$script:Collections.Add($col)
    [void](Save-Collections)
    Set-CollectionScope $col.Name
    $lblStatus.Text = if ($res.Type -eq 'manual') { $(if ($added -gt 0) { 'Created "{0}" with {1} title(s).' -f $col.Name, $added } else { 'Created "{0}". Select titles and use Add selected, or build it with the Add button in Edit.' -f $col.Name }) } else { 'Created the rule collection "{0}".' -f $col.Name }
}

function Edit-ActiveCollection {
    $col = $null
    if ($script:ActiveCollection) { $col = Get-CollectionByName $script:ActiveCollection }
    if ($null -eq $col) { return }
    $res = Show-CollectionEditor -Col $col
    if ($null -eq $res) { return }
    $col.Name = $res.Name
    if ([string]$col.Type -eq 'rule') { $col.Query = $res.Query; $col.SortBy = $res.SortBy; $col.SortDesc = $res.SortDesc; $col.Limit = $res.Limit }
    $col.ByDate = $res.ByDate
    $added = 0
    if ([string]$col.Type -ne 'rule' -and @($res.Picked).Count -gt 0) { $added = Add-RecordsToCollection $col (Get-RecordsById $res.Picked) }
    $col.Modified = (Get-Date).ToString('s')
    [void](Save-Collections)
    Set-CollectionScope $col.Name
    $lblStatus.Text = if ($added -gt 0) { 'Saved "{0}" and added {1} title(s).' -f $col.Name, $added } else { 'Saved "{0}".' -f $col.Name }
}

function Remove-ActiveCollection {
    $col = $null
    if ($script:ActiveCollection) { $col = Get-CollectionByName $script:ActiveCollection }
    if ($null -eq $col) { return }
    $ans = [Windows.Forms.MessageBox]::Show(('Delete the collection "{0}"?' -f $col.Name) + "`n`nYour titles and files are not affected; only this saved list is removed.", 'Delete collection', 'YesNo', 'Question')
    if ($ans -ne [Windows.Forms.DialogResult]::Yes) { return }
    $name = [string]$col.Name
    $script:Collections.Remove($col)
    [void](Save-Collections)
    Set-CollectionScope ''
    $lblStatus.Text = 'Deleted "{0}".' -f $name
}

function Add-SelectedToCollection {
    if ($script:ScanResults.Count -eq 0) { return }
    $recs = @(Get-SelectedRecords)
    if ($recs.Count -eq 0) {
        [Windows.Forms.MessageBox]::Show('Select one or more titles in the grid first (Ctrl-click or Shift-click to pick several), then click Add selected.', 'Add to collection', 'OK', 'Information') | Out-Null; return
    }
    $name = Show-AddToCollectionDialog -Count $recs.Count
    if (-not $name) { return }
    $col = Get-CollectionByName $name
    if ($null -eq $col) {
        $now = (Get-Date).ToString('s')
        $col = @{ Name = $name; Type = 'manual'; Items = (New-Object System.Collections.ArrayList); Query = ''; SortBy = ''; SortDesc = $false; ByDate = $false; Limit = 0; Created = $now; Modified = $now }
        [void]$script:Collections.Add($col)
    }
    $added = Add-RecordsToCollection $col $recs
    [void](Save-Collections)
    if ($script:ActiveCollection -ieq [string]$col.Name) { Set-CollectionScope $col.Name } else { Update-CollectionBar }
    $lblStatus.Text = 'Added {0} title(s) to "{1}"{2}.' -f $added, $col.Name, $(if ($added -lt $recs.Count) { " ($($recs.Count - $added) already in it)" } else { '' })
}

function Remove-SelectedFromCollection {
    $col = $null
    if ($script:ActiveCollection) { $col = Get-CollectionByName $script:ActiveCollection }
    if ($null -eq $col -or [string]$col.Type -ne 'manual') { return }
    $recs = @(Get-SelectedRecords)
    if ($recs.Count -eq 0) { return }
    $drop = @{}
    foreach ($r in $recs) { foreach ($k in (Get-MmlmMetaKeys $r)) { $drop[$k] = $true } }
    $removed = 0
    for ($i = $col.Items.Count - 1; $i -ge 0; $i--) {
        $hit = $false
        foreach ($k in $col.Items[$i].Ids) { if ($drop.ContainsKey([string]$k)) { $hit = $true; break } }
        if ($hit) { $col.Items.RemoveAt($i); $removed++ }
    }
    if ($removed -gt 0) { $col.Modified = (Get-Date).ToString('s'); [void](Save-Collections) }
    Set-CollectionScope $col.Name
    $lblStatus.Text = 'Removed {0} title(s) from "{1}".' -f $removed, $col.Name
}

$cboColl.Add_SelectedIndexChanged({
    if ($script:CollGuard) { return }
    if ($cboColl.SelectedIndex -le 0) { Set-CollectionScope '' } else { Set-CollectionScope ([string]$cboColl.SelectedItem) }
})
$btnCollNew.Add_Click({ New-CollectionFromUi })
$btnCollEdit.Add_Click({ Edit-ActiveCollection })
$btnCollDel.Add_Click({ Remove-ActiveCollection })
$btnCollAdd.Add_Click({ Add-SelectedToCollection })
$tip.SetToolTip($btnCollNew, "Make a collection: a Static list you add to, or a Dynamic one such as  genre:Horror year:1980-1989.`nIf the filter box has text, it is offered as a Dynamic collection.")
$tip.SetToolTip($btnCollAdd, "Add the titles selected in the grid to a Static collection (or start a new one).")
$tip.SetToolTip($cboColl, "Show only the titles in a collection - in the grid, detail view, dashboard and exports.")

Import-Collections
Update-CollectionBar
#endregion

#region ---------------------------------------------------------------- Filter suggestions (drop-down while typing field:value terms)
# Works for the main filter box and the collection editor. Suggests field names, then the values that really exist in the library
# (with counts), and for number fields ranges and comparisons. Keys: Down / Up pick, Enter or Tab accept, Esc closes; or click.
$script:SugCache      = @{ Table = $null; Cols = @{} }
$script:SugSkipValues = @('Plot', 'Tagline', 'FileName', 'FullPath', 'Directory', 'MetaSources', 'SourceWhy', 'PosterPath', 'InformFile')

function Get-FilterFieldNames {
    # The columns the filter box understands: text and number columns (not the technical "clue" columns).
    param($Table)
    foreach ($f in $script:Fields) {
        if ($f.Group -eq 'Clues') { continue }
        $col = $Table.Columns[$f.Name]
        if ($null -eq $col) { continue }
        if ($col.DataType -eq [string]) { [pscustomobject]@{ Name = $f.Name; Kind = 'text' } }
        elseif ($col.DataType -eq [int] -or $col.DataType -eq [double] -or $col.DataType -eq [long]) { [pscustomobject]@{ Name = $f.Name; Kind = 'number' } }
    }
}

function Get-ColumnStats {
    # Distinct values with counts (text; lists such as genres are split on ';') or the sorted non-zero numbers. Cached per table.
    param($Table, [string]$Name)
    if (-not [object]::ReferenceEquals($script:SugCache.Table, $Table)) { $script:SugCache = @{ Table = $Table; Cols = @{} } }
    if ($script:SugCache.Cols.ContainsKey($Name)) { return $script:SugCache.Cols[$Name] }
    $col = $Table.Columns[$Name]
    $st = @{ Kind = ''; Counts = $null; Nums = $null }
    if ($null -ne $col) {
        if ($col.DataType -eq [string]) {
            $st.Kind = 'text'
            $d = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([StringComparer]::OrdinalIgnoreCase)
            if ($script:SugSkipValues -notcontains $Name) {
                foreach ($row in $Table.Rows) {
                    $raw = $row[$Name]
                    if ($raw -is [DBNull] -or $null -eq $raw) { continue }
                    foreach ($p in ([string]$raw -split ';')) {
                        $t = $p.Trim()
                        if ($t) { if ($d.ContainsKey($t)) { $d[$t] = $d[$t] + 1 } else { $d[$t] = 1 } }
                    }
                }
            }
            $st.Counts = $d
        }
        else {
            $st.Kind = 'number'
            $l = New-Object 'System.Collections.Generic.List[double]'
            foreach ($row in $Table.Rows) {
                $raw = $row[$Name]
                if ($raw -is [DBNull] -or $null -eq $raw) { continue }
                $x = [double]$raw
                if ($x -gt 0) { $l.Add($x) }
            }
            $l.Sort()
            $st.Nums = $l
        }
    }
    $script:SugCache.Cols[$Name] = $st
    $st
}

function Get-NumberSuggestions {
    param([string]$Name, $Nums, [string]$Typed)
    $out = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Nums -or $Nums.Count -eq 0) { return @() }
    $ci  = [Globalization.CultureInfo]::InvariantCulture
    $fmt = { param($x) ([double]$x).ToString('0.##', $ci) }
    $min = $Nums[0]; $max = $Nums[$Nums.Count - 1]
    if ($Name -eq 'Year') {
        $dec = @{}
        foreach ($y in $Nums) { $dd = [int]([math]::Floor($y / 10) * 10); $dec[$dd] = 1 + [int]$dec[$dd] }
        foreach ($dd in @($dec.Keys | Sort-Object)) {
            $out.Add(@{ Label = ('{0}-{1}   ({2})' -f $dd, ($dd + 9), $dec[$dd]); Text = ('{0}-{1}' -f $dd, ($dd + 9)) })
        }
    }
    else {
        $q1 = $Nums[[int][math]::Floor(($Nums.Count - 1) * 0.25)]
        $q3 = $Nums[[int][math]::Floor(($Nums.Count - 1) * 0.75)]
        $out.Add(@{ Label = ('>={0}   (top quarter)' -f (& $fmt $q3)); Text = ('>=' + (& $fmt $q3)) })
        $out.Add(@{ Label = ('<={0}   (bottom quarter)' -f (& $fmt $q1)); Text = ('<=' + (& $fmt $q1)) })
        $out.Add(@{ Label = ('{0}-{1}   (whole range)' -f (& $fmt $min), (& $fmt $max)); Text = ('{0}-{1}' -f (& $fmt $min), (& $fmt $max)) })
    }
    if ($Typed) { return @($out | Where-Object { ([string]$_.Text).StartsWith($Typed, [StringComparison]::OrdinalIgnoreCase) }) }
    @($out.ToArray())
}

function Get-FilterSuggestions {
    # -> @{ Start = index in $Text that an accepted item replaces from; Items = @(@{ Label; Text }) }, or $null for no suggestions.
    param($Table, [string]$Text)
    if ($Table -isnot [System.Data.DataTable]) { return $null }
    $fields = @(Get-FilterFieldNames $Table)
    if ($fields.Count -eq 0) { return $null }

    $fieldItems = {
        param([string]$Word)
        $r = New-Object System.Collections.Generic.List[object]
        foreach ($f in $fields) {
            if ($Word -eq '' -or $f.Name.StartsWith($Word, [StringComparison]::OrdinalIgnoreCase)) {
                $r.Add(@{ Label = ('{0}:   {1}' -f $f.Name, $f.Kind); Text = ($f.Name + ':') })
            }
        }
        , $r
    }

    $lw   = $Text.LastIndexOfAny([char[]]@(' ', "`t")) + 1
    $word = $Text.Substring($lw)
    $ms   = [regex]::Matches($Text, '(?:^|\s)([A-Za-z]\w*)\s*:')

    if ($ms.Count -eq 0) {
        if ($word -notmatch '^\w+$') { return $null }
        $items = & $fieldItems $word
        if ($items.Count -eq 0) { return $null }
        return @{ Start = $lw; Items = @($items.ToArray()) }
    }

    $m     = $ms[$ms.Count - 1]
    $field = $m.Groups[1].Value
    $stat  = Get-ColumnStats $Table $field
    if ($stat.Kind -eq '') { return $null }
    $vs = $m.Index + $m.Length
    while ($vs -lt $Text.Length -and [char]::IsWhiteSpace($Text[$vs])) { $vs++ }
    $typed = $Text.Substring($vs)

    # "genre:Horror " (a space after a finished value): offer the next field
    if ($typed.Trim() -ne '' -and [char]::IsWhiteSpace($typed[$typed.Length - 1])) {
        $items = & $fieldItems ''
        return @{ Start = $Text.Length; Items = @($items.ToArray()) }
    }

    $items = New-Object System.Collections.Generic.List[object]
    if ($stat.Kind -eq 'text') {
        $rows = foreach ($kv in $stat.Counts.GetEnumerator()) {
            if ($typed -eq '' -or $kv.Key.IndexOf($typed, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $sw = 1; if ($typed -ne '' -and $kv.Key.StartsWith($typed, [StringComparison]::OrdinalIgnoreCase)) { $sw = 0 }
                [pscustomobject]@{ Key = [string]$kv.Key; N = [int]$kv.Value; S = $sw }
            }
        }
        $rows = @($rows | Sort-Object @{ Expression = 'S'; Descending = $false }, @{ Expression = 'N'; Descending = $true }, @{ Expression = 'Key'; Descending = $false } | Select-Object -First 12)
        foreach ($r in $rows) {
            $lab = if ($field -eq 'Title') { $r.Key } else { '{0}   ({1})' -f $r.Key, $r.N }       # every title is unique: a count of 1 is just noise
            $items.Add(@{ Label = $lab; Text = $r.Key })
        }
        # first row: what the text typed so far matches, so a rule such as  title:Star  shows how many titles it will pick up
        if ($typed.Length -ge 2 -and @($rows).Count -gt 1 -and -not ($rows | Where-Object { $_.Key -ieq $typed })) {
            $hits = 0
            foreach ($row in $Table.Rows) {
                $raw = $row[$field]
                if ($raw -isnot [DBNull] -and $null -ne $raw -and ([string]$raw).IndexOf($typed, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hits++ }
            }
            if ($hits -gt 0) { $items.Insert(0, @{ Label = ('"{0}"   (matches {1} title{2})' -f $typed, $hits, $(if ($hits -eq 1) { '' } else { 's' })); Text = $typed }) }
        }
    }
    else {
        foreach ($x in @(Get-NumberSuggestions $field $stat.Nums $typed)) { $items.Add($x) }
    }

    # nothing fits the value, but the last word may be the start of another field ("genre:Horror ye" -> year:)
    if ($items.Count -eq 0 -and $lw -gt $vs -and $word -match '^\w+$') {
        $fi = & $fieldItems $word
        if ($fi.Count -gt 0) { return @{ Start = $lw; Items = @($fi.ToArray()) } }
    }
    if ($items.Count -eq 0) { return $null }
    if ($items.Count -eq 1 -and ([string]$items[0].Text) -ieq $typed.Trim()) { return $null }       # already typed in full
    @{ Start = $vs; Items = @($items.ToArray()) }
}

function Hide-FilterSuggest {
    param($Tb)
    $st = $Tb.Tag
    if ($null -eq $st -or $null -eq $st.LB) { return }
    $st.LB.Visible = $false
    $f = $Tb.FindForm()
    if ($null -ne $f -and $st.Locked) { $f.AcceptButton = $st.SavedAccept; $f.CancelButton = $st.SavedCancel }
    $st.Locked = $false; $st.SavedAccept = $null; $st.SavedCancel = $null
}

function Show-FilterSuggest {
    param($Tb, $Sug)
    $st = $Tb.Tag; $lb = $st.LB
    $st.Items = @($Sug.Items); $st.Start = [int]$Sug.Start
    $lb.BeginUpdate()
    $lb.Items.Clear()
    foreach ($it in $st.Items) { [void]$lb.Items.Add([string]$it.Label) }
    $lb.EndUpdate()
    $lb.Width  = [math]::Max($Tb.Width, 300)
    $lb.Height = ([math]::Min(10, $lb.Items.Count) * $lb.ItemHeight) + 6
    $lb.Location = $st.Owner.PointToClient($Tb.Parent.PointToScreen((New-Object Drawing.Point($Tb.Left, ($Tb.Bottom + 1)))))
    $lb.SelectedIndex = -1
    if (-not $lb.Visible) {
        # while the list is open, Enter and Esc belong to the list rather than to the dialog's default buttons
        $f = $Tb.FindForm()
        if ($null -ne $f -and -not $st.Locked) { $st.SavedAccept = $f.AcceptButton; $st.SavedCancel = $f.CancelButton; $f.AcceptButton = $null; $f.CancelButton = $null; $st.Locked = $true }
        $lb.Visible = $true
    }
    $lb.BringToFront()
}

function Update-FilterSuggest {
    param($Tb)
    $st = $Tb.Tag
    if ($null -eq $st -or $st.Busy) { return }
    if (-not $Tb.Focused -or $Tb.Text.Trim().Length -eq 0) { Hide-FilterSuggest $Tb; return }
    $sug = $null
    try {
        $tbl = & $st.GetTable
        if ($tbl -is [object[]] -and $tbl.Count -gt 0 -and $tbl[0] -is [System.Data.DataRow]) { $tbl = $tbl[0].Table }       # belt and braces: rows came back instead of the table
        if ($st.Commas) {            # several filters separated by commas: suggest for the part being typed
            $txt = [string]$Tb.Text
            $ci = $txt.LastIndexOf(',') + 1
            $seg = $txt.Substring($ci)
            $lead = $seg.Length - $seg.TrimStart().Length
            if ($seg.Trim().Length -gt 0) {
                $sug = Get-FilterSuggestions $tbl $seg.TrimStart()
                if ($null -ne $sug) { $sug.Start = [int]$sug.Start + $ci + $lead }
            }
        }
        else { $sug = Get-FilterSuggestions $tbl $Tb.Text }
    }
    catch { $sug = $null }
    if ($null -eq $sug -or @($sug.Items).Count -eq 0) { Hide-FilterSuggest $Tb; return }
    Show-FilterSuggest $Tb $sug
}

function Complete-FilterSuggest {
    param($Tb, [int]$Index)
    $st = $Tb.Tag
    if ($Index -lt 0 -or $Index -ge @($st.Items).Count) { return }
    $it = $st.Items[$Index]
    $st.Busy = $true
    try {
        $keep = $Tb.Text.Substring(0, [math]::Min([int]$st.Start, $Tb.Text.Length))
        $Tb.Text = $keep + [string]$it.Text
        $Tb.SelectionStart = $Tb.Text.Length; $Tb.SelectionLength = 0
    }
    finally { $st.Busy = $false }
    Hide-FilterSuggest $Tb
    $Tb.Focus()
    if (([string]$it.Text).EndsWith(':')) { Update-FilterSuggest $Tb }           # picked a field: go straight on to its values
}

function Enable-FilterSuggest {
    # Adds the drop-down to a text box. $Owner is the form or dialog that hosts the list; $GetTable returns the DataTable to learn values from.
    param($TextBox, $Owner, [scriptblock]$GetTable)
    $lb = New-Object Windows.Forms.ListBox
    $lb.BorderStyle = 'FixedSingle'; $lb.IntegralHeight = $false; $lb.TabStop = $false; $lb.Visible = $false
    $lb.BackColor = $script:cPanel2; $lb.ForeColor = $script:cText; $lb.Font = $script:fontBase
    $lb.Tag = $TextBox
    $TextBox.Tag = @{ LB = $lb; Items = @(); Start = 0; GetTable = $GetTable; Owner = $Owner; Busy = $false; Locked = $false; SavedAccept = $null; SavedCancel = $null; Commas = $false }
    $Owner.Controls.Add($lb)

    $TextBox.Add_TextChanged({ param($s, $e) Update-FilterSuggest $s })
    $TextBox.Add_PreviewKeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [Windows.Forms.Keys]::Tab -and $s.Tag.LB.Visible) { $e.IsInputKey = $true }
    })
    $TextBox.Add_KeyDown({
        param($s, $e)
        $st = $s.Tag; $lb2 = $st.LB
        if (-not $lb2.Visible) {
            if ($e.KeyCode -eq [Windows.Forms.Keys]::Down -and $s.Text.Trim().Length -gt 0) {
                Update-FilterSuggest $s
                if ($lb2.Visible) { $lb2.SelectedIndex = 0; $e.Handled = $true; $e.SuppressKeyPress = $true }
            }
            return
        }
        switch ($e.KeyCode) {
            'Down'   { if ($lb2.SelectedIndex -lt ($lb2.Items.Count - 1)) { $lb2.SelectedIndex = $lb2.SelectedIndex + 1 }; $e.Handled = $true; $e.SuppressKeyPress = $true }
            'Up'     { if ($lb2.SelectedIndex -gt 0) { $lb2.SelectedIndex = $lb2.SelectedIndex - 1 } else { $lb2.SelectedIndex = -1 }; $e.Handled = $true; $e.SuppressKeyPress = $true }
            'Tab'    { $i = $lb2.SelectedIndex; if ($i -lt 0) { $i = 0 }; Complete-FilterSuggest $s $i; $e.Handled = $true; $e.SuppressKeyPress = $true }
            'Return' {
                if ($lb2.SelectedIndex -ge 0) { Complete-FilterSuggest $s $lb2.SelectedIndex; $e.Handled = $true; $e.SuppressKeyPress = $true }
                else { Hide-FilterSuggest $s }
            }
            'Escape' { Hide-FilterSuggest $s; $e.Handled = $true; $e.SuppressKeyPress = $true }
        }
    })
    $TextBox.Add_Leave({
        param($s, $e)
        $st = $s.Tag
        if ($null -eq $st -or -not $st.LB.Visible) { return }
        $r = $st.LB.RectangleToScreen($st.LB.ClientRectangle)
        if (-not $r.Contains([Windows.Forms.Cursor]::Position)) { Hide-FilterSuggest $s }          # a click on the list itself keeps it open
    })
    $lb.Add_MouseClick({
        param($s, $e)
        $i = $s.IndexFromPoint($e.Location)
        if ($i -ge 0) { Complete-FilterSuggest $s.Tag $i }
    })
    $lb.Add_Leave({
        param($s, $e)
        if (-not $s.Tag.Focused) { Hide-FilterSuggest $s.Tag }
    })
}
#endregion

Enable-FilterSuggest -TextBox $txtFilter -Owner $form -GetTable { , $grid.DataSource }

# right-click a row for the same editor (and to add titles to a collection)
$gridMenu = New-Object Windows.Forms.ContextMenuStrip
$miEdit = $gridMenu.Items.Add('Edit info...')
$miEdit.Add_Click({ Edit-SelectedMetadata })
$miAddColl = $gridMenu.Items.Add('Add to collection...')
$miAddColl.Add_Click({ Add-SelectedToCollection })
$miRemColl = $gridMenu.Items.Add('Remove from this collection')
$miRemColl.Add_Click({ Remove-SelectedFromCollection })
$gridMenu.Add_Opening({
    $c = $null
    if ($script:ActiveCollection) { $c = Get-CollectionByName $script:ActiveCollection }
    $miRemColl.Visible = ($null -ne $c -and [string]$c.Type -eq 'manual')
})
$grid.Add_CellMouseDown({
    param($s, $e)
    if ($e.Button -eq [Windows.Forms.MouseButtons]::Right -and $e.RowIndex -ge 0) {
        if (-not $grid.Rows[$e.RowIndex].Selected) {      # keep a multi-row selection when right-clicking inside it
            $grid.ClearSelection(); $grid.Rows[$e.RowIndex].Selected = $true; $grid.CurrentCell = $grid.Rows[$e.RowIndex].Cells[$e.ColumnIndex]
        }
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
        if ($view -and ($txtFilter.Text.Trim() -or $null -ne $script:ScopeIds) -and $view.Count -ne $script:ScanResults.Count) {
            # a filter is active: export exactly the rows currently shown
            $names = @($grid.DataSource.Columns | ForEach-Object { $_.ColumnName })
            $out = foreach ($drv in $view) {
                $o = [ordered]@{}
                foreach ($n in $names) {
                    if ($script:HiddenFields -contains $n) { continue }
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
                    if ($script:HiddenFields -contains $p.Name) { continue }
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
    if ($script:ActiveCollection) { return $script:ActiveCollection }
    if ($radPlex.Checked) { return 'Plex Library' }
    $n = Split-Path -Leaf ($txtFolder.Text.Trim().TrimEnd('\'))
    if ($n) { $n } else { 'Media Library' }
}

function Test-DashboardReady {
    if ($script:ScanResults.Count -eq 0) {
        [Windows.Forms.MessageBox]::Show('Run a scan first - the dashboard is built from the scan results.', 'Dashboard', 'OK', 'Information') | Out-Null
        return $false
    }
    if ($null -ne $script:ScopeIds -and $script:ScopeIds.Count -eq 0) {
        [Windows.Forms.MessageBox]::Show("The collection '$($script:ActiveCollection)' has no titles in this scan yet.`n`nAdd titles to it, change its rule, or pick 'All titles'.", 'Dashboard', 'OK', 'Information') | Out-Null
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
    # -Card opens one title's card straight away ('k:<card key>' or 't:<title>|<year>').
    param([string]$Card = '')
    if ($script:Scanning) {
        [Windows.Forms.MessageBox]::Show('The dashboard is available when the scan has finished.', 'Dashboard', 'OK', 'Information') | Out-Null; return
    }
    if (-not (Test-DashboardReady)) { return }

    $btnDash.Enabled = $false; $btnScan.Enabled = $false; $btnSaveHtml.Enabled = $false
    try {
        if ($script:DashboardStale -or -not (Test-Path -LiteralPath $script:LiveDashboard)) {
            New-MediaDashboard -Records @(Get-ScopedRecords) -OutFile $script:LiveDashboard -LibraryName (Get-LibraryName) -CollectionName ([string]$script:ActiveCollection) -DateOrder:(Test-ActiveByDate)
            $script:DashboardStale = $false
        }
        $url = ([Uri]$script:LiveDashboard).AbsoluteUri + '?t=' + [DateTime]::Now.Ticks
        if ($Card) { $url += '#card=' + [Uri]::EscapeDataString($Card) }

        if (Initialize-WebView2) {
            $script:WebShowing = 'dash'
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
    if ($script:ActiveCollection) { $dlg.FileName = (([string]$script:ActiveCollection) -replace '[\\/:*?"<>|]', '_') + '.html' }
    $dlg.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
    if ($dlg.ShowDialog($form) -ne [Windows.Forms.DialogResult]::OK) { return }

    $btnDash.Enabled = $false; $btnScan.Enabled = $false; $btnSaveHtml.Enabled = $false
    try {
        New-MediaDashboard -Records @(Get-ScopedRecords) -OutFile $dlg.FileName -LibraryName (Get-LibraryName) -CollectionName ([string]$script:ActiveCollection) -DateOrder:(Test-ActiveByDate) -EmbedPosters:$chkEmbed.Checked
        Set-UiProgress -Text "Dashboard saved: $($dlg.FileName)" -Value 1 -Max 1
        Start-Process $dlg.FileName
    }
    catch { [Windows.Forms.MessageBox]::Show("Could not save the dashboard:`n$_", 'Save HTML', 'OK', 'Error') | Out-Null }
    finally { $btnDash.Enabled = $true; $btnScan.Enabled = $true; $btnSaveHtml.Enabled = $true }
})

$btnScan.Add_Click({
    if ($null -ne $script:TvLoad) {
        [Windows.Forms.MessageBox]::Show('Your last TV scan is still loading (a few seconds). Try again once the status bar says it is done.', 'Scan', 'OK', 'Information') | Out-Null; return
    }
    $usePlex = [bool]$radPlex.Checked
    $folder  = $txtFolder.Text.Trim()

    if ($usePlex) {
        if (-not (Confirm-PlexToken -BaseUrl $folder)) { return }
        $folder = $txtFolder.Text.Trim()           # the connect dialog may have changed the address
    }
    else {
        if ($script:Tab -eq 'TV') {
            [Windows.Forms.MessageBox]::Show('TV Shows are scanned from Plex for now. Switch the source to Plex server, or use the Movies tab for a local folder.', 'Modern Media Library Manager', 'OK', 'Information') | Out-Null; return
        }
        if ([string]::IsNullOrWhiteSpace($folder)) {
            [Windows.Forms.MessageBox]::Show('Please choose a folder to scan (a UNC path such as \\server\share\Movies works).', 'Modern Media Library Manager', 'OK', 'Warning') | Out-Null; return
        }
        if (-not $chkVideo.Checked -and -not $chkAudio.Checked) {
            [Windows.Forms.MessageBox]::Show('Select at least one media type (Video or Audio).', 'Modern Media Library Manager', 'OK', 'Warning') | Out-Null; return
        }
        try { Initialize-MmlmMediaInfoModule }
        catch {
            [Windows.Forms.MessageBox]::Show("Could not initialize the MediaInfo module:`n$_", 'Modern Media Library Manager', 'OK', 'Error') | Out-Null; return
        }
    }

    if ($chkFel.Checked -and -not ((Find-MmlmTool 'ffmpeg.exe') -and (Find-MmlmTool 'dovi_tool.exe'))) {
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
    Update-MmlmContext
    $script:ScanUsePlex = $usePlex
    $script:ScanMode    = 'Scan'
    $script:ScanWatch   = [Diagnostics.Stopwatch]::StartNew()
    $script:CancelAt    = $null
    $script:RateT = $null; $script:RateV = 0; $script:RateVal = $null
    $script:EtaStep = @{ T = $null; F = 0.0; R = $null }; $script:EtaAll = @{ T = $null; F = 0.0; R = $null }; $script:LastPhase = 0
    $script:WkT = $null; $script:WkPrev = @{}; $script:WkRate = @{}; $script:WkBusy = @{}; $script:WkOvPrev = 0; $script:WkOvRate = $null; $script:WkCpu = $null; $script:WkCpuPrev = 0.0

    $btnScan.Enabled = $false; $btnBrowse.Enabled = $false; $btnDash.Enabled = $false; $btnSaveHtml.Enabled = $false; $btnExport.Enabled = $false; $btnCancel.Enabled = $true; $btnFetch.Enabled = $false
    Set-OverallProgress -Fraction 0.0
    # A scan covers the active tab only; the other tab's titles are kept and put back when the scan finishes.
    $scopeTv = ($usePlex -and $script:Tab -eq 'TV')
    $script:KeepRecords = @($script:ScanResults | Where-Object { ([bool][string]$_.Show) -ne $scopeTv })     # the other tab's titles stay on screen
    $script:DashboardStale = $true
    $lblStatus.Text = 'Starting...'

    try {
        if ($usePlex) {
            # what this tab had last time, by Plex key: unchanged items are reused without reading anything from disk
            $prior = @{}
            if (-not $chkRebuild.Checked) { foreach ($r0 in $script:ScanResults) { if (([bool][string]$r0.Show) -eq $scopeTv -and $r0.PlexKey -and $r0.PlexUpdated) { $prior[[string]$r0.PlexKey] = $r0 } } }
            Start-ScanWorker -Mode 'Plex' -ScanArgs @{
                BaseUrl = $folder; Token = $script:PlexToken; Movies = ($script:Tab -eq 'Movies'); Shows = ($script:Tab -eq 'TV')
                Rebuild = [bool]$chkRebuild.Checked; DetectFel = [bool]$chkFel.Checked; Prior = $prior }
        }
        else {
            Start-ScanWorker -Mode 'Folder' -ScanArgs @{
                Folder = $folder; Video = [bool]$chkVideo.Checked; Audio = [bool]$chkAudio.Checked
                Rebuild = [bool]$chkRebuild.Checked; DetectFel = [bool]$chkFel.Checked; Parallel = [int]$nudPar.Value }
        }
        $script:ScanTimer.Start()
        $script:Scanning = $true; $script:ScanTab = $(if ($scopeTv) { 'TV' } else { 'Movies' })
        Update-TabLabels; Set-View $script:CurrentView
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
    $script:Scanning = $false
    if ($null -ne $script:EmptyText) { $lblEmpty.Text = $script:EmptyText; $script:EmptyText = $null }
    Update-TabLabels
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
        $scanned = $results.Count
        $fresh   = @($results)                                    # just this scan's records
        if ($script:ScanMode -ne 'Scrape') { $results = $fresh + @($script:KeepRecords) }
        $script:ScanResults = $results
        $nTv = 0; foreach ($r0 in $results) { if ([string]$r0.Show) { $nTv++ } }
        $script:HasTv = ($nTv -gt 0)
        $script:TabCounts = @{ Movies = ($results.Count - $nTv); TV = $nTv }
        # if the tab you are looking at has nothing but the other one does (for example a TV scan finished while you were on an empty Movies tab), go there
        if ($script:TabCounts[$script:Tab] -eq 0 -and $script:TabCounts[$(if ($script:Tab -eq 'TV') { 'Movies' } else { 'TV' })] -gt 0) { $script:Tab = $(if ($script:Tab -eq 'TV') { 'Movies' } else { 'TV' }) }
        $btnScan.Text = $(if ($script:Tab -eq 'TV') { 'Scan TV Shows' } else { 'Scan Movies' })
        Update-TabLabels
        $cancelled = [bool]$s.Cancel
        if ($results.Count -eq 0 -and -not $cancelled) {
            $lblStatus.Text = 'Nothing found.'
            $lblEmpty.Text = if ($script:ScanUsePlex) { 'Plex returned nothing for that selection.' } else { 'No matching media files were found in that folder.' }
            return
        }
        if ($results.Count -gt 0) {
            try { Set-SourceLabels -Records $(if ($script:ScanMode -eq 'Scrape') { $results } else { $fresh }) } catch { }          # measured labels first, then fetched / typed-in values on top
            try { Merge-MetaStore -Records $(if ($script:ScanMode -eq 'Scrape') { $results } else { $fresh }) -Path $script:MetaStorePath } catch { }
            try {
                $mov = New-Object 'System.Collections.Generic.List[object]'; $tvr = New-Object 'System.Collections.Generic.List[object]'
                foreach ($r0 in $results) { if ([string]$r0.Show) { $tvr.Add($r0) } else { $mov.Add($r0) } }
                $script:MovieTable = ConvertTo-DataTable -Records $mov.ToArray()
                $script:TvRecords = $tvr.ToArray(); $script:TvPageStale = $true; $script:WebShowing = ''; $script:TvFromDisk = $false
                if (-not [bool]$s.Cancel) {           # a finished scan (or fetch) becomes what the app opens on next time
                    if ($script:ScanMode -eq 'Scrape' -or $script:ScanTab -ne 'TV') { Save-LibrarySnapshot -Which 'Movies' -Records $mov.ToArray() }
                    if ($script:ScanMode -ne 'Scrape' -and $script:ScanTab -eq 'TV') { Save-LibrarySnapshot -Which 'TV' -Records $tvr.ToArray() }
                }
                $grid.DataSource = $null
                Set-GridTable            # this tab's table, remembered visibility/widths
            }
            catch {
                [Windows.Forms.MessageBox]::Show(("Could not show the results:`n{0}`n`n{1}" -f $_, $_.InvocationInfo.PositionMessage), 'Modern Media Library Manager', 'OK', 'Error') | Out-Null
            }
            try { Update-CollectionScope; $script:OrderApplied = $false; Set-CollectionOrder } catch { }          # the active collection is re-evaluated against this scan
            $grid.ClearSelection()
            Update-Filter
        }
        $state = if ($cancelled) { 'Cancelled' } else { 'Done' }
        $total = [int]$s.Total
        $took  = ' in {0:N0}s' -f $script:ScanWatch.Elapsed.TotalSeconds
        $lblStatus.Text = "$state. $scanned of $total item(s) processed$took."
        if ($script:ScanMode -eq 'Scrape') {
            $lblStatus.Text = "$state. $([string]$s.Summary)"
            $script:FetchDetails = @($s.Details)
            if ($script:FetchDetails.Count -gt 0) {
                $lnkDetails.Visible = $true
                Update-StatusLinks
            }
        }
        if (-not $cancelled) { Set-OverallProgress -Fraction 1.0 }
    }
    finally {
        $btnScan.Enabled = $true; $btnBrowse.Enabled = $true; $btnDash.Enabled = $true; $btnSaveHtml.Enabled = $true; $btnExport.Enabled = $true; $btnCancel.Enabled = $false; $btnFetch.Enabled = $true
        Set-View ([string]$script:TabView[$script:Tab])
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
    if ($sw -lt 1100 -or $sh -lt 600) { $sw = 1600; $sh = 975 }           # first start: 25 % larger than the original 1280 x 780
    $form.ClientSize = New-Object Drawing.Size($sw, $sh)
    if ($form.Width -gt $wa.Width -or $form.Height -gt $wa.Height) {          # does not fit this screen: shrink to what does
        $padW = $form.Width - $form.ClientSize.Width; $padH = $form.Height - $form.ClientSize.Height
        $form.ClientSize = New-Object Drawing.Size([math]::Max(1200 - $padW, [math]::Min($sw, $wa.Width - $padW)), [math]::Max(680 - $padH, [math]::Min($sh, $wa.Height - $padH)))
    }
    $x = $wa.X + [int](($wa.Width  - $form.Width)  / 2)
    $y = $wa.Y + [int](($wa.Height - $form.Height) / 2)
    $form.Location = New-Object Drawing.Point([math]::Max($wa.X, $x), [math]::Max($wa.Y, $y))

    # First launch with Plex as the source: ask for the token right away (it is stored encrypted afterwards).
    if ($radPlex.Checked -and -not $script:PlexToken) {
        [void](Show-PlexTokenDialog -BaseUrl $txtFolder.Text.Trim())
    }
    # Open on the last scan of each tab (no Plex calls). Started just after the window has painted, so it never shows up blank.
    $lblStatus.Text = 'Loading your last scan...'
    $script:StartTimer = New-Object Windows.Forms.Timer
    $script:StartTimer.Interval = 60
    $script:StartTimer.Add_Tick({
        $script:StartTimer.Stop(); $form.Cursor = [Windows.Forms.Cursors]::AppStarting
        try { Import-LibrarySnapshot } finally { $form.Cursor = [Windows.Forms.Cursors]::Default }
        Receive-UpdateNote              # after an update: confirm it worked (the "ok" marker) and say so once
        try { if (-not (Test-Path -LiteralPath $script:DropFolder)) { New-Item -Path $script:DropFolder -ItemType Directory -Force | Out-Null } } catch { }
        $script:DropTimer.Start()
    })
    $script:StartTimer.Start()
    $env:MMLM_RESUME = ''              # set by updaters before v0.4.0; the library snapshot makes a re-scan unnecessary
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

    $now    = Get-MmlmNowMs
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

#region ---------------------------------------------------------------- Updates (checked only when you click; nothing installs without your say-so)
$script:UpdateRepo   = 'SomtimesOttomation/Modern-Media-Library-Manager'
$script:UpdateFolder = Join-Path $script:AppData 'Update'
$script:Upd = @{ State = 'idle'; Info = $null; Job = $null; Stage = '' }
$script:UpdTimer = New-Object Windows.Forms.Timer
$script:UpdTimer.Interval = 400

# The updater is two files next to this script, the same design as the dash modules (NBADash / DashLauncher):
#   Update-MMLM.ps1  - hidden child process: Check (asks GitHub), Stage (download, SHA-256, unpack, checks), StageZip (a dropped zip)
#   Apply-Update.ps1 - run from a copy after the app closes: back up, copy, relaunch, wait for the "ok" marker, roll back if it never comes
# Only api.github.com and its release download hosts are contacted, and only when you ask.
$script:UpdOut    = Join-Path $script:UpdateFolder 'update.out'
$script:UpdResult = Join-Path $script:UpdateFolder 'update-result.json'
$script:DropFolder = Join-Path $script:AppRoot 'updates'

function Test-NewerVersion {
    param([string]$Tag, [string]$Current)
    try {
        $a = [version](([string]$Tag).TrimStart('v', 'V') -replace '[-+].*$', '')
        $b = [version](([string]$Current).TrimStart('v', 'V') -replace '[-+].*$', '')
        return ($a -gt $b)
    }
    catch { return $false }
}

# --- status bar links ---
$lnkVer = New-Object Windows.Forms.LinkLabel
$lnkVer.AutoSize = $false; $lnkVer.Size = New-Object Drawing.Size(220, 20); $lnkVer.Location = New-Object Drawing.Point(1036, 4)
$lnkVer.Anchor = 'Top,Right'; $lnkVer.TextAlign = 'MiddleRight'; $lnkVer.BackColor = [Drawing.Color]::Transparent
$lnkVer.LinkColor = $script:cMuted; $lnkVer.ActiveLinkColor = $script:cAccent2; $lnkVer.LinkBehavior = 'HoverUnderline'; $lnkVer.Font = $script:fontSmall
$lnkVer.Text = 'v' + $script:AppVersion + '   |   Check for updates'
$lnkUpdate = New-Object Windows.Forms.LinkLabel
$lnkUpdate.AutoSize = $true; $lnkUpdate.Location = New-Object Drawing.Point(24, 7); $lnkUpdate.Visible = $false
$lnkUpdate.LinkColor = $script:cAccent; $lnkUpdate.ActiveLinkColor = $script:cAccent2; $lnkUpdate.BackColor = [Drawing.Color]::Transparent; $lnkUpdate.Font = $script:fontBase
$statusBar.Controls.AddRange(@($lnkVer, $lnkUpdate))

function Update-StatusLinks {
    # Keeps the little links right after the status text, wherever that text ends.
    $x = 24 + $lblStatus.PreferredWidth + 12
    if ($lnkDetails.Visible) { $lnkDetails.Location = New-Object Drawing.Point($x, 7); $x += $lnkDetails.PreferredWidth + 14 }
    if ($lnkUpdate.Visible)  { $lnkUpdate.Location  = New-Object Drawing.Point($x, 7) }
}
$lblStatus.Add_TextChanged({ Update-StatusLinks })

function Set-UpdateLink {
    param([string]$Text)
    if ($Text) { $lnkUpdate.Text = $Text; $lnkUpdate.Visible = $true } else { $lnkUpdate.Visible = $false }
    Update-StatusLinks
}

# --- background job plumbing ---
$script:UpdProg = @{ Percent = 0; Text = '' }
$script:UpdWin = $null
$script:UpdQuit = $false
$script:UpdPulse = 0

function Start-Updater {
    # Starts Update-MMLM.ps1 hidden. Returns $false when one is already running.
    param([ValidateSet('Check', 'Stage', 'StageZip')][string]$Action, [string]$ZipPath = '')
    if ($null -ne $script:Upd.Job -and -not $script:Upd.Job.Proc.HasExited) { return $false }
    $tool = Join-Path $script:AppRoot 'Update-MMLM.ps1'
    if (-not (Test-Path -LiteralPath $tool)) { $script:Upd.Msg = 'Update-MMLM.ps1 is missing from the program folder; download the latest release by hand.'; return $false }
    if (-not (Test-Path -LiteralPath $script:UpdateFolder)) { New-Item -Path $script:UpdateFolder -ItemType Directory -Force | Out-Null }
    Remove-Item -LiteralPath $script:UpdResult, $script:UpdOut -Force -ErrorAction SilentlyContinue
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $tool), '-Action', $Action,
           '-CurrentVersion', $script:AppVersion, '-WorkDir', ('"{0}"' -f $script:UpdateFolder))
    if ($ZipPath) { $a += '-ZipPath'; $a += ('"{0}"' -f $ZipPath) }
    if ($env:MMLM_UPDATE_API) { $a += '-ApiBase'; $a += $env:MMLM_UPDATE_API }          # test hook
    try { $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $a -WindowStyle Hidden -PassThru -RedirectStandardOutput $script:UpdOut }
    catch { $script:Upd.Msg = 'The updater could not start: ' + $_.Exception.Message; return $false }
    $script:Upd.Job = @{ Kind = $Action; Proc = $p }
    $script:UpdTimer.Start()
    $true
}

function Read-UpdateJson {
    param([string]$Name)
    $p = Join-Path $script:UpdateFolder $Name
    if (Test-Path -LiteralPath $p) { try { return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json) } catch { } }
    $null
}

function Read-UpdateProgress {
    # the last "##PROGRESS pct|text" line the updater printed
    try {
        $fs = New-Object IO.FileStream($script:UpdOut, 'Open', 'Read', 'ReadWrite')
        try { $txt = (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
        $m = [regex]::Matches($txt, '##PROGRESS (\d+)\|([^\r\n]*)')
        if ($m.Count -gt 0) { $last = $m[$m.Count - 1]; $script:UpdProg.Percent = [int]$last.Groups[1].Value; $script:UpdProg.Text = $last.Groups[2].Value }
    } catch { }
}

function Complete-UpdateJob {
    param([string]$Kind, $Res)
    $st = [string]$Res.status
    $info = @{ Tag = [string]$Res.tag; Notes = [string]$Res.notes; Url = [string]$Res.htmlUrl; Installable = [bool]$Res.installable }
    switch ($st) {
        'none' {
            # GitHub answers "not found" both when nothing is published and when the repository is private
            $script:Upd.State = 'idle'
            $script:Upd.Msg = 'No release was found. The repository may be private right now: save the release zip into the updates folder instead.'
            $lblStatus.Text = 'No release found on GitHub.'
        }
        { $_ -eq 'current' -or $_ -eq 'ahead' } {
            $script:Upd.State = 'idle'; $script:Upd.Msg = 'You are on the latest version (v' + $script:AppVersion + ').'; $lblStatus.Text = $script:Upd.Msg
        }
        'available' {
            $script:Upd.Info = $info
            if (-not $info.Installable) { $script:Upd.State = 'page'; $lblStatus.Text = 'Version ' + $info.Tag + ' is out, but its release has no update package yet.' }
            else { $script:Upd.State = 'available'; $lblStatus.Text = 'Update available: ' + $info.Tag + '.'; if ($null -eq $script:UpdWin) { Set-UpdateLink "What's new / Update" } }
        }
        'staged' {
            if ($Kind -eq 'StageZip' -or -not $script:Upd.Info) { $script:Upd.Info = $info }
            $script:Upd.State = 'ready'
            $lblStatus.Text = 'Update ' + $info.Tag + ' downloaded and checked.'
            if ($Kind -eq 'StageZip') { Move-DroppedZip; Update-UpdateWindow; Invoke-UpdateRestartFlow -NoAsk; return }
            Update-UpdateWindow
            if ($null -ne $script:UpdWin) { Invoke-UpdateRestartFlow } else { Set-UpdateLink 'Restart to finish updating' }
            return
        }
        default {
            $why = [string]$Res.error; if (-not $why) { $why = 'The updater ended without an answer.' }
            $script:Upd.State = $(if ($Kind -eq 'Stage' -and $script:Upd.Info) { 'available' } else { 'idle' })
            $script:Upd.Msg = $why
            $lblStatus.Text = 'Update: ' + $why
            if ($Kind -ne 'Check') {
                $owner = $(if ($null -ne $script:UpdWin) { $script:UpdWin.Dlg } else { $form })
                [void][Windows.Forms.MessageBox]::Show($owner, "The update was not installed:`n`n$why", 'Update', 'OK', 'Warning')
            }
        }
    }
    Update-UpdateWindow
}

$script:UpdTimer.Add_Tick({
    if ($null -ne $script:UpdWin) { Update-UpdateWindow }
    $j = $script:Upd.Job
    if ($null -eq $j) { $script:UpdTimer.Stop(); return }
    Read-UpdateProgress
    if (-not $j.Proc.HasExited) { return }
    $script:Upd.Job = $null
    if ($null -eq $script:UpdWin) { $script:UpdTimer.Stop() }
    $res = Read-UpdateJson 'update-result.json'
    if ($null -eq $res) { $res = [pscustomobject]@{ status = 'error'; error = 'The updater ended without an answer.' } }
    try { Complete-UpdateJob $j.Kind $res } catch { $lblStatus.Text = 'Update error: ' + $_.Exception.Message }
})

function Start-UpdateCheck {
    if ($null -ne $script:Upd.Job) { return }
    $script:Upd.State = 'checking'; $script:Upd.Msg = ''
    Set-UpdateLink ''
    $lblStatus.Text = 'Checking for updates...'
    if (-not (Start-Updater 'Check')) { $script:Upd.State = 'idle'; $lblStatus.Text = [string]$script:Upd.Msg }
    Update-UpdateWindow
}

function Start-UpdateDownload {
    if ($null -ne $script:Upd.Job -or $null -eq $script:Upd.Info) { return }
    $script:Upd.State = 'downloading'; Set-UpdateLink ''
    $script:UpdProg.Percent = 0; $script:UpdProg.Text = 'Connecting...'
    $lblStatus.Text = 'Downloading ' + $script:Upd.Info.Tag + '...'
    if (-not (Start-Updater 'Stage')) { $script:Upd.State = 'available'; $lblStatus.Text = [string]$script:Upd.Msg }
    Update-UpdateWindow
}

function Get-ReleaseNotesText {
    # Only what you wrote in the release description: the automatic "Verify this download" block is cut off.
    param([string]$Body)
    $t = ([string]$Body) -replace "`r?`n", "`r`n"
    $m = [regex]::Match($t, '(?im)^\s*#{1,6}\s*Verify this download.*$')
    if ($m.Success) { $t = $t.Substring(0, $m.Index) }
    $t = $t.Trim()
    if (-not $t) { $t = '(This release has no description.)' }
    $t
}

function Update-UpdateWindow {
    # Brings the update window in line with the current state (called after every state change and while a job runs).
    $w = $script:UpdWin
    if ($null -eq $w) { return }
    $st = [string]$script:Upd.State
    $trackW = $w.Track.Width
    $status = ''; $detail = ''; $pct = 0; $btn = ''; $btnOn = $true; $showNotes = $false
    switch ($st) {
        'checking'    { $status = 'Connecting to the update server...'; $detail = 'Looking for the latest release on GitHub.'; $btn = 'Check for updates'; $btnOn = $false }
        'available'   { $status = ('Version {0} is available (you have v{1}).' -f $script:Upd.Info.Tag, $script:AppVersion); $detail = 'Read what is new, then download it. Nothing is installed until you restart.'; $btn = 'Download update'; $showNotes = $true }
        'downloading' { $pct = [int]$script:UpdProg.Percent; $status = ('Downloading {0}...  {1}%' -f $script:Upd.Info.Tag, $pct); $detail = [string]$script:UpdProg.Text; $btn = 'Downloading...'; $btnOn = $false; $showNotes = $true }
        'ready'       { $pct = 100; $status = ('Update {0} is downloaded and checked.' -f $script:Upd.Info.Tag); $detail = 'Restart to finish. Your settings, cache and library are kept; the old version is put back if the new one does not start.'; $btn = 'Restart now'; $showNotes = $true }
        'page'        { $status = ('Version {0} is out, but it has no installable files.' -f $script:Upd.Info.Tag); $detail = 'The release page can be opened to download it by hand.'; $btn = 'Open release page' }
        default       { $status = [string]$script:Upd.Msg; if (-not $status) { $status = 'Check whether a newer version is available.' }; $detail = ''; $btn = 'Check for updates' }
    }
    $w.Status.Text = $status
    $w.Detail.Text = $detail
    if ($st -eq 'checking') {         # no percentage to show: a block slides along the track
        $script:UpdPulse = ($script:UpdPulse + 1) % 20
        $bw = [int]($trackW * 0.25)
        $w.Fill.Left = [int](($trackW - $bw) * ($script:UpdPulse / 19.0)); $w.Fill.Width = $bw
    }
    else { $w.Fill.Left = 0; $w.Fill.Width = [int]($trackW * $pct / 100.0) }
    $w.Main.Text = $btn; $w.Main.Enabled = $btnOn
    $w.Notes.Visible = $showNotes; $w.NotesCap.Visible = $showNotes
    if ($showNotes -and $script:Upd.Info -and $w.Notes.Tag -ne [string]$script:Upd.Info.Tag) {
        $w.Notes.Text = Get-ReleaseNotesText ([string]$script:Upd.Info.Notes); $w.Notes.Tag = [string]$script:Upd.Info.Tag
        $w.Notes.SelectionStart = 0; $w.Notes.SelectionLength = 0
    }
}

function Show-UpdateWindow {
    # One window for the whole update: checks as soon as it opens, shows progress and the release description, then asks about the restart.
    if ($null -ne $script:UpdWin) { return }
    $dlg = New-DialogForm 'Software update' 640 560
    $status = New-Object Windows.Forms.Label
    $status.Location = New-Object Drawing.Point(24, 18); $status.Size = New-Object Drawing.Size(592, 24); $status.AutoEllipsis = $true
    $status.ForeColor = $script:cText; $status.BackColor = [Drawing.Color]::Transparent; $status.Font = $script:fontBold
    $track = New-Object Windows.Forms.Panel
    $track.Location = New-Object Drawing.Point(24, 50); $track.Size = New-Object Drawing.Size(592, 10); $track.BackColor = $script:cPanel2
    $fill = New-Object Windows.Forms.Panel
    $fill.Location = New-Object Drawing.Point(0, 0); $fill.Size = New-Object Drawing.Size(0, 10); $fill.BackColor = $script:cAccent
    $track.Controls.Add($fill)
    $detail = New-Object Windows.Forms.Label
    $detail.Location = New-Object Drawing.Point(24, 66); $detail.Size = New-Object Drawing.Size(592, 20); $detail.AutoEllipsis = $true
    $detail.ForeColor = $script:cMuted; $detail.BackColor = [Drawing.Color]::Transparent; $detail.Font = $script:fontSmall
    $cap = New-Label "WHAT'S NEW" 24 102 $script:cMuted $script:fontSmall
    $notes = New-Object Windows.Forms.TextBox
    $notes.Multiline = $true; $notes.ReadOnly = $true; $notes.ScrollBars = 'Vertical'; $notes.WordWrap = $true; $notes.TabStop = $false
    $notes.Location = New-Object Drawing.Point(24, 124); $notes.Size = New-Object Drawing.Size(592, 316)
    $notes.BackColor = $script:cPanel2; $notes.ForeColor = $script:cText; $notes.BorderStyle = 'FixedSingle'; $notes.Font = $script:fontBase
    $hint = New-Label 'Downloads are checked against the release checksum. Your settings and scan cache are kept.' 24 452 $script:cMuted $script:fontSmall
    $bx = [int](($dlg.ClientSize.Width - (170 + 16 + 100)) / 2)                          # the two buttons sit side by side, centred
    $main  = New-FlatButton 'Check for updates' 170 'primary'; $main.Location = New-Object Drawing.Point($bx, 506)
    $close = New-FlatButton 'Close' 100 'secondary'; $close.Location = New-Object Drawing.Point(($bx + 170 + 16), 506); $close.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.AddRange(@($status, $track, $detail, $cap, $notes, $hint, $main, $close))
    $dlg.CancelButton = $close; $dlg.ActiveControl = $main
    $script:UpdWin = @{ Dlg = $dlg; Status = $status; Track = $track; Fill = $fill; Detail = $detail; NotesCap = $cap; Notes = $notes; Main = $main }
    $main.Add_Click({
        switch ($script:Upd.State) {
            'available' { Start-UpdateDownload }
            'ready'     { Invoke-UpdateRestartFlow }
            'page'      { try { Start-Process ([string]$script:Upd.Info.Url) } catch { } }
            'checking'  { }
            'downloading' { }
            default     { Start-UpdateCheck }
        }
    })
    $dlg.Add_Shown({
        $script:UpdWin.Notes.SelectionStart = 0; $script:UpdWin.Notes.SelectionLength = 0; $script:UpdWin.Main.Focus()
        if ($script:Upd.State -eq 'idle' -and $null -eq $script:Upd.Job) { Start-UpdateCheck }
        $script:UpdTimer.Start()
    })
    Update-UpdateWindow
    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
    $script:UpdWin = $null
    if ($null -eq $script:Upd.Job) { $script:UpdTimer.Stop() }
    # closed while the download ran: it carries on, and the status bar link offers the restart when it is done
    if ($script:Upd.State -eq 'ready') { Set-UpdateLink 'Restart to finish updating' }
    elseif ($script:Upd.State -eq 'available') { Set-UpdateLink "What's new / Update" }
    if ($script:UpdQuit) { $script:UpdQuit = $false; $form.Close() }
}

function Invoke-UpdateApply {
    # Starts Apply-Update.ps1 (from a copy) and returns $true when the app should close now.
    param([switch]$NoAsk)
    $st = Read-UpdateJson 'staged.json'
    $stage = Join-Path $script:UpdateFolder 'stage'
    $owner = if ($null -ne $script:UpdWin) { $script:UpdWin.Dlg } else { $form }
    if (-not $st -or -not (Test-Path -LiteralPath (Join-Path $stage 'Modern-Media-Library-Manager.ps1'))) {
        $script:Upd.State = 'idle'; $script:Upd.Msg = 'There is no downloaded update to install. Check for updates again.'; Update-UpdateWindow; return $false
    }
    if (-not $btnScan.Enabled) { [void][Windows.Forms.MessageBox]::Show($owner, 'A scan or fetch is still running. Let it finish (or cancel it), then install the update.', 'Update', 'OK', 'Information'); return $false }
    $probe = Join-Path $script:AppRoot '.write-test'
    try { [IO.File]::WriteAllText($probe, 'x'); Remove-Item -LiteralPath $probe -Force }
    catch {
        [void][Windows.Forms.MessageBox]::Show($owner, "This folder is protected, so the app cannot update itself here:`n$($script:AppRoot)`n`nThe release page will open so you can download it by hand.", 'Update', 'OK', 'Warning')
        try { if ($script:Upd.Info.Url) { Start-Process ([string]$script:Upd.Info.Url) } } catch { }
        return $false
    }
    if (-not $NoAsk) {
        $ask = [Windows.Forms.MessageBox]::Show($owner, "The app will close and reopen on v$($st.version).`n`nYour current files are backed up first; if the new version does not start, they are put back automatically.", 'Update', 'YesNo', 'Question')
        if ($ask -ne [Windows.Forms.DialogResult]::Yes) { return $false }
    }
    $runDir = Join-Path $script:UpdateFolder 'run'          # the helper runs from a copy, so replacing the app files cannot touch it
    if (-not (Test-Path -LiteralPath $runDir)) { New-Item -Path $runDir -ItemType Directory -Force | Out-Null }
    $helper = Join-Path $runDir 'Apply-Update.ps1'
    try { Copy-Item -LiteralPath (Join-Path $script:AppRoot 'Apply-Update.ps1') -Destination $helper -Force }
    catch { [void][Windows.Forms.MessageBox]::Show($owner, 'Apply-Update.ps1 is missing from the program folder: ' + $_.Exception.Message, 'Update', 'OK', 'Error'); return $false }
    $relaunch = '"' + (Join-Path $script:AppRoot 'Run-ModernMediaLibraryManager.cmd') + '"'
    $b64 = [Convert]::ToBase64String((New-Object Text.UTF8Encoding($false)).GetBytes($relaunch))
    $h = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $helper), '-AppDir', ('"{0}"' -f $script:AppRoot), '-StageDir', ('"{0}"' -f $stage),
           '-WorkDir', ('"{0}"' -f $script:UpdateFolder), '-ParentPid', [string]$PID, '-RelaunchB64', $b64,
           '-OldVersion', $script:AppVersion, '-NewVersion', [string]$st.version)
    try { Start-Process -FilePath 'powershell.exe' -ArgumentList $h -WindowStyle Hidden | Out-Null }
    catch { [void][Windows.Forms.MessageBox]::Show($owner, 'The updater could not start: ' + $_.Exception.Message, 'Update', 'OK', 'Error'); return $false }
    $true
}

function Receive-UpdateNote {
    # After an update: say once how it went. Called when the window is up and the last scan has loaded,
    # which is also when the "ok" marker is written so Apply-Update.ps1 keeps the new version.
    try {
        $pend = Read-UpdateJson 'update-pending.json'
        if ($pend -and [string]$pend.to -eq $script:AppVersion) {
            [IO.File]::WriteAllText((Join-Path $script:UpdateFolder 'update-ok.json'), '{"ok":true}', (New-Object Text.UTF8Encoding($false)))
            Remove-Item -LiteralPath (Join-Path $script:UpdateFolder 'update-pending.json') -Force -ErrorAction SilentlyContinue
            $lblStatus.Text = 'Updated from v' + [string]$pend.from + ' to v' + $script:AppVersion + '.'
        }
        $failed = Read-UpdateJson 'update-failed.json'
        if ($failed) {
            Remove-Item -LiteralPath (Join-Path $script:UpdateFolder 'update-failed.json'), (Join-Path $script:UpdateFolder 'update-pending.json') -Force -ErrorAction SilentlyContinue
            [void][Windows.Forms.MessageBox]::Show($form, ("The update from v{0} to v{1} did not start, so the previous version was put back.`n`nReason: {2}" -f $failed.from, $failed.to, $failed.reason), 'Update', 'OK', 'Warning')
        }
    } catch { }
}

# ---- drop-in updates: save Modern-Media-Library-Manager-vX.Y.Z.zip (and its .sha256) into the updates folder ----
$script:DropSeen = @{}            # zip path -> 'size|time' last tick; a zip is used once it stops changing
$script:DropAsked = @{}           # zips already offered this session ("Not now" asks again next start)
$script:DropZip = ''

function Get-ZipVersion {
    # VERSION at the zip's root or inside its one top folder; $null when there is none (an older-style zip, or not ours)
    param([string]$Zip)
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead($Zip)
        try {
            $e = @($z.Entries | Where-Object { $_.FullName -match '^([^/\\]+[/\\])?VERSION$' }) | Select-Object -First 1
            if ($null -eq $e) { return $null }
            $r = New-Object IO.StreamReader($e.Open())
            try { $t = $r.ReadToEnd().Trim() } finally { $r.Dispose() }
            if ($t -match '^\d+\.\d+\.\d+$') { return $t }
        } finally { $z.Dispose() }
    } catch { }
    $null
}

function Watch-DropFolder {
    if ($null -ne $script:Upd.Job -or $script:Upd.State -eq 'ready' -or -not (Test-Path -LiteralPath $script:DropFolder)) { return }
    foreach ($f in @(Get-ChildItem -LiteralPath $script:DropFolder -Filter '*.zip' -File -ErrorAction SilentlyContinue)) {
        if ($script:DropAsked.ContainsKey($f.FullName)) { continue }
        $sig = '{0}|{1}' -f $f.Length, $f.LastWriteTimeUtc.Ticks
        if ($script:DropSeen[$f.FullName] -ne $sig) { $script:DropSeen[$f.FullName] = $sig; continue }      # still being written
        try { $x = [IO.File]::Open($f.FullName, 'Open', 'Read', 'None'); $x.Dispose() } catch { continue }      # still open elsewhere
        $script:DropAsked[$f.FullName] = $true
        $v = Get-ZipVersion $f.FullName
        if (-not $v) { $lblStatus.Text = 'Ignored ' + $f.Name + ' in the updates folder: it is not an update package with a VERSION file.'; continue }
        if (-not (Test-NewerVersion $v $script:AppVersion)) { continue }
        $ask = [Windows.Forms.MessageBox]::Show($form, ("{0} (v{1}) is in the updates folder.`n`nInstall it now? The app closes and reopens on v{1}; your current files are backed up and put back if it does not start." -f $f.Name, $v), 'Update', 'YesNo', 'Question')
        if ($ask -ne [Windows.Forms.DialogResult]::Yes) { $lblStatus.Text = 'Not installed; the app asks again the next time it starts.'; continue }
        $script:DropZip = $f.FullName
        $script:Upd.State = 'downloading'; $script:UpdProg.Percent = 0; $script:UpdProg.Text = 'Checking the package...'
        $script:Upd.Info = @{ Tag = 'v' + $v; Notes = ''; Url = ''; Installable = $true }
        $lblStatus.Text = 'Checking ' + $f.Name + '...'
        if (-not (Start-Updater 'StageZip' $f.FullName)) { $script:Upd.State = 'idle'; $lblStatus.Text = [string]$script:Upd.Msg }
        return
    }
}

function Move-DroppedZip {
    # an installed drop-in zip (and its .sha256) goes to updates\applied
    try {
        if (-not $script:DropZip) { return }
        $dest = Join-Path $script:DropFolder 'applied'
        if (-not (Test-Path -LiteralPath $dest)) { New-Item -Path $dest -ItemType Directory -Force | Out-Null }
        foreach ($p in @($script:DropZip, ($script:DropZip + '.sha256'))) { if (Test-Path -LiteralPath $p) { Move-Item -LiteralPath $p -Destination $dest -Force } }
        $script:DropZip = ''
    } catch { }
}

$script:DropTimer = New-Object Windows.Forms.Timer
$script:DropTimer.Interval = 5000
$script:DropTimer.Add_Tick({ try { Watch-DropFolder } catch { } })

function Invoke-UpdateRestartFlow {
    param([switch]$NoAsk)
    if (Invoke-UpdateApply -NoAsk:$NoAsk) {
        if ($null -ne $script:UpdWin) { $script:UpdQuit = $true; $script:UpdWin.Dlg.Close() }      # the window closes first, then the app
        else { $form.Close() }
    }
}

$lnkUpdate.Add_LinkClicked({
    if ($script:Upd.State -eq 'ready') { Invoke-UpdateRestartFlow } else { Show-UpdateWindow }
})
$lnkVer.Add_LinkClicked({ Show-UpdateWindow })
$tip.SetToolTip($lnkVer, 'Opens the update window: checks GitHub for a newer release. Nothing is downloaded until you choose to.')
#endregion


if ($script:Settings['Source'] -eq 'Local') { $radLocal.Checked = $true } else { $radPlex.Checked = $true }
Set-SourceMode ([bool]$radPlex.Checked)
$radPlex.Add_CheckedChanged({ Set-SourceMode ([bool]$radPlex.Checked) })
# The reader count can be changed while a local scan is running; the scan picks it up within a second.
$nudPar.Add_ValueChanged({ $script:Sync.Workers = [int]$nudPar.Value })

Set-View 'grid'
[void]$form.ShowDialog()
