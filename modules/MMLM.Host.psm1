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

# the data modules, by full path (an already loaded copy is reused)
foreach ($m0 in @('MMLM.Library.psm1', 'MMLM.Plex.psm1', 'MMLM.Fetch.psm1')) { Import-Module (Join-Path $PSScriptRoot $m0) -DisableNameChecking }

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
    @('MMLM.Library.psm1', 'MMLM.Plex.psm1', 'MMLM.Fetch.psm1') | ForEach-Object { Join-Path (Join-Path $script:Root 'modules') $_ }
}

function Read-HostSettings {
    # The same settings file the app writes (%LOCALAPPDATA%\Modern-Media-Library-Manager\settings.json); read only here.
    $p = Join-Path $script:AppData 'settings.json'
    $s = @{ PlexUrl = ''; PlexTokenProtected = '' }
    if (Test-Path -LiteralPath $p) {
        try { $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json; foreach ($k in 'PlexUrl', 'PlexTokenProtected') { if ($j.$k) { $s[$k] = [string]$j.$k } } } catch { Write-HostLog 'settings' $_ }
    }
    $s
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
    columns = @(); hideDupes = $false; posterScale = 100; widthPreset = 'full'; customWidth = $false; contentWidth = 0 }
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
    $views = @('posters', 'grid', 'dashboard')
    $ok = switch ($Key) {
        'theme'       { @('system', 'light', 'dark') -contains [string]$Value }
        'updateCheck' { $Value = [bool]$Value; $true }
        'hideDupes'   { $Value = [bool]$Value; $true }
        'moviesSortRev' { $Value = [bool]$Value; $true }
        'tvSortRev'   { $Value = [bool]$Value; $true }
        'customWidth' { $Value = [bool]$Value; $true }
        'posterScale' { $n = 0; if ([int]::TryParse([string]$Value, [ref]$n) -and $n -ge 50 -and $n -le 200) { $Value = $n; $true } else { $false } }
        'contentWidth' { $n = 0; if ([int]::TryParse([string]$Value, [ref]$n) -and $n -ge 0 -and $n -le 20000) { $Value = $n; $true } else { $false } }
        'widthPreset' { @('full', '16:9', '21:9', '32:9') -contains [string]$Value }
        'moviesView'  { $views -contains [string]$Value }
        'tvView'      { $views -contains [string]$Value }
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
    $set = Read-HostSettings
    @{ url = [string]$set.PlexUrl; hasToken = [bool]$set.PlexTokenProtected }
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
Set-MmlmContext -Values $Ctx; Set-MmlmPlexContext -Values $Ctx; Set-MmlmFetchContext -Values $Ctx
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
    $recs = @(Invoke-MmlmPlexScan -BaseUrl $Job.BaseUrl -Token $Job.Token -Movies (-not $tv) -Shows $tv -Rebuild ([bool]$Job.Rebuild) -DetectFel $false -Prior $use)
    if ($S.Cancel) { $S.Cancelled = $true; return }
    $new = @($recs | Where-Object { -not $prior.ContainsKey([string]$_.PlexKey) })
    Set-MmlmProgress -Text 'Saving...'
    $dir = Split-Path -Parent $Job.Snapshot
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    try { Merge-MmlmMetaStore -Records $recs -Path $Job.MetaStore } catch { }          # fetched scores (Metacritic, RT, box office) and hand edits
    [Mmlm.Native.Snapshot]::Save([object[]]$recs, $Job.Snapshot, ('{0}|{1}' -f $recs.Count, (Get-Date).ToString('yyyy-MM-dd HH:mm')))
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

function Get-LibraryState {
    # 'ready' (the page copy is at least as new as the snapshot), 'stale' (needs building) or 'empty' (never scanned)
    param([string]$Tab)
    $snap = Get-SnapshotFile $Tab
    $page = Join-Path $script:CacheDir ('library-' + $Tab + '.json')
    if (-not (Test-Path -LiteralPath $snap)) { return $(if (Test-Path -LiteralPath $page) { 'ready' } else { 'empty' }) }
    # stale when the scan or the saved scores (Fetch info, Edit info in the window app) are newer than the page's copy
    $newest = (Get-Item -LiteralPath $snap).LastWriteTimeUtc
    if (Test-Path -LiteralPath $script:MetaStore) { $m = (Get-Item -LiteralPath $script:MetaStore).LastWriteTimeUtc; if ($m -gt $newest) { $newest = $m } }
    if ((Test-Path -LiteralPath $page) -and (Get-Item -LiteralPath $page).LastWriteTimeUtc -ge $newest) { return 'ready' }
    'stale'
}

function Start-HostScan {
    param([ValidateSet('movies', 'tv')][string]$Tab, [bool]$Rebuild = $false)
    if ($script:ScanPs -and -not $script:Sync.Done) { throw 'A scan is already running.' }
    if ($script:Traffic.Halted) { throw 'Traffic is paused. Resume it first.' }
    $set = Read-HostSettings
    if (-not $set.PlexUrl) { throw 'No Plex server address is set yet. Add it in Settings.' }
    $token = ''
    try { $token = Unprotect-MmlmPlexToken $set.PlexTokenProtected } catch { Write-HostLog 'token' $_ }
    # test hook for tests\Test-MmlmHost.ps1 only: honoured only when the host was started with Debug on
    if ($script:Ctx.Debug -and $env:MMLM_HOST_TEST_TOKEN) { $token = $env:MMLM_HOST_TEST_TOKEN }
    if (-not $token) { throw 'No Plex token is saved yet. Add it in Settings.' }
    Stop-HostScan -Wait 0
    $script:Sync = [hashtable]::Synchronized(@{ Text = 'Starting...'; Value = 0; Max = 0; Cancel = $false; Done = $false; Error = $null; PhaseLo = 0.0; PhaseHi = 1.0; Count = 0; New = 0; Cancelled = $false })
    $ctx = New-WorkerContext $script:Sync
    foreach ($d in $ctx.CacheFolder, $ctx.ThumbFolder) { if (-not (Test-Path -LiteralPath $d)) { New-Item -Path $d -ItemType Directory -Force | Out-Null } }
    $job = @{ Kind = 'scan'; Tab = $Tab; Rebuild = $Rebuild; BaseUrl = $set.PlexUrl; Token = $token; Snapshot = (Get-SnapshotFile $Tab); CacheDir = $script:CacheDir; Hidden = $script:HiddenFields; MetaStore = $script:MetaStore }
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
        $out += [ordered]@{ name = [string]$c.Name; type = $(if ([string]$c.Type -eq 'rule') { 'rule' } else { 'manual' }); query = [string]$c.Query; sortBy = [string]$c.SortBy
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
        if (-not $name -or $name.Length -gt 80 -or $names.ContainsKey($name.ToLowerInvariant())) { continue }
        $names[$name.ToLowerInvariant()] = $true
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($it in @($c.items)) {
            $ids = @(foreach ($id in @($it.ids)) { $id = [string]$id; if ($id.StartsWith('h:')) { if ($back.ContainsKey($id)) { $back[$id] } } elseif ($id -match '^(p|s):') { $id } })
            if ($ids.Count -gt 0) { $items.Add([ordered]@{ Ids = $ids; Title = [string]$it.title; Year = [int]$it.year }) }
        }
        $out.Add([ordered]@{ Name = $name; Type = $(if ([string]$c.type -eq 'rule') { 'rule' } else { 'manual' }); Items = $items.ToArray(); Query = [string]$c.query
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
    Set-MmlmContext -Values $v; Set-MmlmPlexContext -Values $v; Set-MmlmFetchContext -Values $v
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
            switch (Get-LibraryState $tab) {
                'ready' { [IO.File]::ReadAllText((Join-Path $script:CacheDir ('library-' + $tab + '.json'))) }
                'empty' { '{"empty":true}' }
                default { Start-HostExport $tab; '{"pending":true}' }
            } } }
    'settings.set'   = @{ Fetch = $false; Run = { param($a) Set-PageSetting ([string]$a.key) $a.value; ConvertTo-PageJson $script:PageSettings } }
    'plex.set'       = @{ Fetch = $false; Run = {
            # Plex address and token (the token is stored encrypted for this Windows user, as the window app does)
            param($a)
            $url = ([string]$a.url).Trim().TrimEnd('/')
            if ($url -and $url -notmatch '^https?://[^\s/]+(:\d+)?$') { throw 'The Plex address looks like http://server:32400' }
            $tok = ([string]$a.token).Trim()
            if ($tok) { Save-HostPlexSettings -Url $url -TokenProtected (Protect-MmlmPlexToken $tok) } else { Save-HostPlexSettings -Url $url -KeepToken }
            ConvertTo-PageJson (Get-PlexInfo) } }
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
