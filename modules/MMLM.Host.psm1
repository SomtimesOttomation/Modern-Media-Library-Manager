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

$script:Ctx = $null
$script:Root = Split-Path $PSScriptRoot
$script:Mutex = $null
$script:Version = '0.0.0'
$script:AppData = Join-Path $env:LOCALAPPDATA 'Modern-Media-Library-Manager'
$script:CacheDir = ''
$script:WebViewDataDir = ''
$script:Settings = $null
$script:Traffic = $null
$script:Sync = $null            # the running (or last) scan: progress, cancel, results
$script:ScanPs = $null
$script:ScanAsync = $null
$script:ScanTab = ''
$script:Out = $null             # JSON messages waiting for Receive-DashEvents
$script:LastScanJson = ''
$script:Badge = 0               # titles new since the person last looked at the tab
$script:Visible = $false

# the data modules, by full path (an already loaded copy is reused)
foreach ($m0 in @('MMLM.Library.psm1', 'MMLM.Plex.psm1', 'MMLM.Fetch.psm1')) { Import-Module (Join-Path $PSScriptRoot $m0) -DisableNameChecking }

function Send-Page { param([string]$Json) if ($script:Ctx -and $script:Ctx.Post) { & $script:Ctx.Post $Json } }
function Reply { param($Id, [string]$DataJson = 'null') Send-Page ('{{"id":{0},"ok":true,"data":{1}}}' -f [int]$Id, $DataJson) }
function ReplyError { param($Id, [string]$Message) Send-Page ('{{"id":{0},"ok":false,"error":{1}}}' -f [int]$Id, (ConvertTo-Json -InputObject $Message -Compress)) }
function ConvertTo-PageJson { param($Object) ConvertTo-Json -InputObject $Object -Depth 6 -Compress }

function Get-HostModuleFiles {
    @('MMLM.Library.psm1', 'MMLM.Plex.psm1', 'MMLM.Fetch.psm1') | ForEach-Object { Join-Path (Join-Path $script:Root 'modules') $_ }
}

function Read-HostSettings {
    # The same settings file the app writes (%LOCALAPPDATA%\Modern-Media-Library-Manager\settings.json); read only here.
    $p = Join-Path $script:AppData 'settings.json'
    $s = @{ PlexUrl = ''; PlexTokenProtected = '' }
    if (Test-Path -LiteralPath $p) {
        try { $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json; foreach ($k in 'PlexUrl', 'PlexTokenProtected') { if ($j.$k) { $s[$k] = [string]$j.$k } } } catch { }
    }
    $s
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
    } catch { return @{ count = 0; when = '' } }
}

# ---------------------------------------------------------------- the scan worker (one runspace per scan)
$script:ScanScript = @'
param($Modules, $Ctx, $Job)
foreach ($m in $Modules) { Import-Module $m -DisableNameChecking }
Set-MmlmContext -Values $Ctx; Set-MmlmPlexContext -Values $Ctx; Set-MmlmFetchContext -Values $Ctx
$S = $Ctx.Sync
try {
    Initialize-MmlmNative
    $tv = ($Job.Tab -eq 'tv')
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
    [Mmlm.Native.Snapshot]::Save([object[]]$recs, $Job.Snapshot, ('{0}|{1}' -f $recs.Count, (Get-Date).ToString('yyyy-MM-dd HH:mm')))
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

function Start-HostScan {
    param([ValidateSet('movies', 'tv')][string]$Tab, [bool]$Rebuild = $false)
    if ($script:ScanPs -and -not $script:Sync.Done) { throw 'A scan is already running.' }
    if ($script:Traffic.Halted) { throw 'Traffic is paused. Resume it first.' }
    $set = Read-HostSettings
    if (-not $set.PlexUrl) { throw 'No Plex server address is set yet.' }
    $token = ''
    try { $token = Unprotect-MmlmPlexToken $set.PlexTokenProtected } catch { }
    if ($env:MMLM_HOST_TEST_TOKEN) { $token = $env:MMLM_HOST_TEST_TOKEN }          # test hook (headless tests, no DPAPI)
    if (-not $token) { throw 'No Plex token is saved yet.' }
    Stop-HostScan -Wait 0
    $script:Sync = [hashtable]::Synchronized(@{ Text = 'Starting...'; Value = 0; Max = 0; Cancel = $false; Done = $false; Error = $null; PhaseLo = 0.0; PhaseHi = 1.0; Count = 0; New = 0; Cancelled = $false })
    $ctx = @{
        Sync = $script:Sync; Traffic = $script:Traffic; AppRoot = $script:Root; AppData = $script:AppData; AppVersion = $script:Version
        CacheFolder = (Join-Path $script:AppData 'Cache'); ThumbFolder = (Join-Path $script:AppData 'Thumbs'); LibFolder = (Join-Path $script:Root 'lib')
        CacheVersion = 4; Culture = [Globalization.CultureInfo]::InvariantCulture; PlexTimeoutMs = 30000; PlexClientId = 'mmlm-' + $env:COMPUTERNAME
        Fields = $script:Fields; TypeMap = @{ string = [string]; int = [int]; long = [long]; double = [double]; bool = [bool] }
        InformFolder = (Join-Path $script:AppData 'Inform')
    }
    foreach ($d in $ctx.CacheFolder, $ctx.ThumbFolder) { if (-not (Test-Path -LiteralPath $d)) { New-Item -Path $d -ItemType Directory -Force | Out-Null } }
    $job = @{ Tab = $Tab; Rebuild = $Rebuild; BaseUrl = $set.PlexUrl; Token = $token; Snapshot = (Get-SnapshotFile $Tab); CacheDir = $script:CacheDir }
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
            if (-not $script:ScanAsync.AsyncWaitHandle.WaitOne($Wait)) { try { [void]$script:ScanPs.BeginStop($null, $null) } catch { } }
        }
        else { return }
    }
    try { $script:ScanPs.Dispose() } catch { }
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

# ---------------------------------------------------------------- contract
function Initialize-Dash {
    <# Takes the host lock, reads the version and makes folders. Fetches nothing. #>
    param([Parameter(Mandatory)]$Context)
    if ($script:Ctx) { return @{ Ok = $true; Reason = ''; CacheDir = $script:CacheDir; WebViewDataDir = $script:WebViewDataDir } }
    $created = $false
    try { $m = New-Object System.Threading.Mutex($true, 'Local\DashHost-mmlm', [ref]$created) } catch { $m = $null }
    if (-not $m -or -not $created) {
        if ($m) { $m.Dispose() }
        return @{ Ok = $false; Reason = 'locked'; CacheDir = ''; WebViewDataDir = '' }
    }
    $script:Mutex = $m
    $script:Ctx = $Context
    if ($Context.Root) { $script:Root = [string]$Context.Root }
    try { $script:Version = ([IO.File]::ReadAllText((Join-Path $script:Root 'VERSION'))).Trim() } catch { }
    $script:CacheDir = Join-Path $script:AppData 'Dashboard'          # served as https://mmlm.cache/ (pages, posters for the page)
    $script:WebViewDataDir = Join-Path $script:AppData 'WebView2'
    foreach ($d in @($script:AppData, $script:CacheDir, $script:WebViewDataDir)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
    $script:Traffic = [hashtable]::Synchronized(@{ Requests = 0; Bytes = [long]0; Errors = 0; Halted = $false })
    $script:Out = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $script:Fields = Get-HostFields
    $v = @{ AppRoot = $script:Root; AppData = $script:AppData; AppVersion = $script:Version; Traffic = $script:Traffic; Fields = $script:Fields }
    Set-MmlmContext -Values $v; Set-MmlmPlexContext -Values $v; Set-MmlmFetchContext -Values $v
    $script:Badge = 0
    return @{ Ok = $true; Reason = ''; CacheDir = $script:CacheDir; WebViewDataDir = $script:WebViewDataDir }
}

function Get-HostFields {
    # The record field list, read from the main script's field table so the two never drift apart.
    $main = Join-Path $script:Root 'Modern-Media-Library-Manager.ps1'
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

function Invoke-DashCommand {
    param([Parameter(Mandatory)]$Message)
    $id = $Message.id
    $a = $Message.args
    try {
        switch ([string]$Message.cmd) {
            'init' {
                $m = Get-SnapshotCount 'movies'; $t = Get-SnapshotCount 'tv'
                Reply $id (ConvertTo-PageJson @{ version = $script:Version; movies = $m; tv = $t; stopped = [bool]$script:Traffic.Halted
                    scanning = [bool]($script:Sync -and -not $script:Sync.Done); scanTab = $script:ScanTab })
            }
            'scan.start' {
                $tab = [string]$a.tab
                if ($tab -ne 'movies' -and $tab -ne 'tv') { throw "scan.start: tab must be 'movies' or 'tv'." }
                Start-HostScan -Tab $tab -Rebuild ([bool]$a.rebuild)
                Reply $id 'true'
            }
            'scan.cancel' { Stop-HostScan -Wait 0; Reply $id 'true' }
            'summary.get' {
                # answered from the cache file the last scan wrote: no network, no scanning
                $tab = $(if ([string]$a.tab -eq 'tv') { 'tv' } else { 'movies' })
                $p = Join-Path $script:CacheDir ('summary-' + $tab + '.json')
                if (Test-Path -LiteralPath $p) { Reply $id ([IO.File]::ReadAllText($p)) }
                else { Reply $id (ConvertTo-PageJson @{ title = 'Recently added'; items = @(); updatedAt = $null }) }
            }
            'traffic.get' { Reply $id (ConvertTo-PageJson @{ requests = [int]$script:Traffic.Requests; bytes = [long]$script:Traffic.Bytes; errors = [int]$script:Traffic.Errors; stopped = [bool]$script:Traffic.Halted }) }
            'traffic.stop' { Stop-DashTraffic; Reply $id 'true' }
            'traffic.resume' {
                $script:Traffic.Halted = $false
                Send-Page '{"event":"traffic","data":{"stopped":false}}'
                Reply $id 'true'
            }
            default { ReplyError $id ('unknown command: ' + [string]$Message.cmd) }
        }
    }
    catch { ReplyError $id $_.Exception.Message }
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
            $out.Add((ConvertTo-PageJson @{ event = 'scan'; data = $data }))
            Stop-HostScan
        }
        else {
            $json = ConvertTo-PageJson @{ event = 'scan'; data = @{ running = $true; tab = $script:ScanTab; pct = (Get-ScanPct); text = [string]$s.Text } }
            if ($json -ne $script:LastScanJson) { $script:LastScanJson = $json; $out.Add($json) }
        }
    }
    $msg = $null
    while ($out.Count -lt 25 -and $script:Out.TryDequeue([ref]$msg)) { $out.Add($msg) }
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
        UpdateAvailable = $null
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
    Send-Page '{"event":"traffic","data":{"stopped":true}}'
}

function Stop-Dash {
    <# Closing: cancel a scan (the last saved snapshot stays as it was) and release the host lock within 2 seconds. #>
    try { Stop-HostScan -Wait 1500 } catch { }
    try { if ($script:Mutex) { $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() } } catch { }
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
    try { Start-HostScan -Tab 'movies'; return $true } catch { return $false }
}

Export-ModuleMember -Function Initialize-Dash, Start-DashWorker, Suspend-DashWorker, Invoke-DashCommand, Receive-DashEvents, Get-DashStatus, Stop-DashTraffic, Stop-Dash, Invoke-DashSync
