# Plex scan: "records must not change" (golden files) and speed, against tests\plex-mock.py.
#   Part A  small library (port 32499) and a varied generated one (port 32501, PLEX_MOCK_SCALE=240): every record is
#           compared with tests\golden\*.txt. A missing golden file is written (do that only from known-good code).
#   Part B  a rescan with the first scan's records as -Prior gives the same records with far fewer requests.
#   Part C  only with MMLM_SPEED_TEST=1: a 55,000-episode library (port 32502, 40 ms per reply) is timed.
# The mocks are started here when they are not already listening.
# Run: pwsh -File tests\Test-MmlmScanSpeed.ps1
$root = Split-Path -Parent $PSScriptRoot
foreach ($m in 'MMLM.Library.psm1', 'MMLM.Plex.psm1', 'MMLM.Jellyfin.psm1', 'MMLM.Server.psm1') { Import-Module (Join-Path $root "modules\$m") -DisableNameChecking }
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Modern-Media-Library-Manager.ps1'), [ref]$null, [ref]$null)
$fa = $ast.Find({ param($x) $x -is [Management.Automation.Language.AssignmentStatementAst] -and $x.Left.Extent.Text -eq '$script:FieldDefs' }, $true)
$fields = @(foreach ($line in (& ([scriptblock]::Create($fa.Right.Extent.Text)))) { $p = $line -split '\|'; [pscustomobject]@{ Name = $p[0]; Type = $p[1]; Group = $p[2]; Show = [bool][int]$p[3] } })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('mmlm-speed-' + [guid]::NewGuid().ToString('N'))
$fail = 0
function Check($ok, $what) { if ($ok) { "  ok    $what" } else { "  FAIL  $what"; $script:fail++ } }

function Start-Mock {
    param([int]$Port, [hashtable]$Env = @{})
    try { $c = New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $Port); $c.Close(); return } catch { }
    $py = @('python3', 'python') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
    $old = @{}
    $all = @{ PLEX_MOCK_PORT = [string]$Port } + $Env
    foreach ($k in $all.Keys) { $old[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, [string]$all[$k]) }
    try { Start-Process -FilePath $py -ArgumentList ('"' + (Join-Path $PSScriptRoot 'plex-mock.py') + '"') -WindowStyle Hidden | Out-Null }
    catch { Start-Process -FilePath $py -ArgumentList ('"' + (Join-Path $PSScriptRoot 'plex-mock.py') + '"') | Out-Null }      # no -WindowStyle off Windows
    finally { foreach ($k in $all.Keys) { [Environment]::SetEnvironmentVariable($k, $old[$k]) } }
    for ($i = 0; $i -lt 50; $i++) { try { $c = New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $Port); $c.Close(); return } catch { Start-Sleep -Milliseconds 200 } }
    throw "the mock on port $Port did not start"
}
function Get-MockStats { param([int]$Port) (New-Object Net.WebClient).DownloadString("http://127.0.0.1:$Port/__stats") | ConvertFrom-Json }
function Reset-Mock { param([int]$Port) [void](New-Object Net.WebClient).DownloadString("http://127.0.0.1:$Port/__reset") }

function New-TestContext {
    # a fresh context (own cache and thumbnail folders), as the host builds one for a scan
    param([string]$Name, [hashtable]$Extra = @{})
    $dir = Join-Path $tmp $Name
    $ctx = @{ Sync = [hashtable]::Synchronized(@{ Text = ''; Value = 0; Max = 0; Total = 0; Cancel = $false; PhaseLo = 0.0; PhaseHi = 1.0 })
        Traffic = [hashtable]::Synchronized(@{ Requests = 0; Bytes = 0; Errors = 0; Halted = $false }); CacheFolder = (Join-Path $dir 'Cache'); ThumbFolder = (Join-Path $dir 'Thumbs')
        AppRoot = $root; AppData = (Join-Path $tmp 'AppData'); AppVersion = 'test'
        CacheVersion = 4; Culture = [Globalization.CultureInfo]::InvariantCulture; PlexTimeoutMs = 30000; PlexClientId = 'mmlm-test'; Fields = $fields; TypeMap = @{ string = [string]; int = [int]; long = [long]; double = [double]; bool = [bool] }
        NoItemCache = $false; ScanCheckpoint = $null; NativeConvert = $null; PlexParallel = 0 }
    foreach ($k in $Extra.Keys) { $ctx[$k] = $Extra[$k] }
    foreach ($d in $ctx.CacheFolder, $ctx.ThumbFolder, $ctx.AppData) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    Set-MmlmContext -Values $ctx; Set-MmlmServerContext -Values $ctx
    $ctx
}

$sha = [Security.Cryptography.SHA1]::Create()
function ConvertTo-StableText {
    # One block per record, in library order: its key, a fingerprint of every property's name and type, then each
    # property that is not empty / 0 / False as name=value. PosterPath is left out (a temp path); HasPoster is kept.
    param([object[]]$Recs)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $sb = New-Object Text.StringBuilder
    foreach ($r in $Recs) {
        $props = @($r.PSObject.Properties | Where-Object { $_.Name -ne 'PosterPath' } | Sort-Object Name)
        $sig = ($props | ForEach-Object { $_.Name + ':' + $(if ($null -eq $_.Value) { 'null' } else { $_.Value.GetType().Name }) }) -join ';'
        $h = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($sig)))).Replace('-', '').Substring(0, 12)
        [void]$sb.Append('== ').Append([string]$r.PlexKey).Append(' types=').Append($h).Append("`n")
        foreach ($p in $props) {
            $v = $p.Value
            if ($null -eq $v) { continue }
            if ($v -is [string]) { if ($v -eq '') { continue }; $t = $v.Replace("`r", '\r').Replace("`n", '\n') }
            elseif ($v -is [bool]) { if (-not $v) { continue }; $t = 'True' }
            elseif ($v -is [double] -or $v -is [single]) { if ($v -eq 0) { continue }; $t = ([double]$v).ToString('R', $inv) }
            else { if ($v -eq 0) { continue }; $t = [Convert]::ToString($v, $inv) }
            [void]$sb.Append($p.Name).Append('=').Append($t).Append("`n")
        }
    }
    $sb.ToString()
}
function Compare-Golden {
    param([string]$Name, [string]$Text, [string]$What)
    $dir = Join-Path $PSScriptRoot 'golden'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $file = Join-Path $dir ($Name + '.txt')
    if (-not (Test-Path -LiteralPath $file)) { [IO.File]::WriteAllText($file, $Text, (New-Object Text.UTF8Encoding($false))); "  ..    golden written: $Name"; return }
    $want = [IO.File]::ReadAllText($file)
    if ($want -ceq $Text) { Check $true $What; return }
    Check $false $What
    $a = $want -split "`n"; $b = $Text -split "`n"; $shown = 0; $key = ''
    for ($i = 0; $i -lt [Math]::Max($a.Count, $b.Count) -and $shown -lt 12; $i++) {
        if ($i -lt $b.Count -and $b[$i].StartsWith('== ')) { $key = $b[$i] }
        if ($a[$i] -cne $b[$i]) { "          line $($i + 1) in $key`n            was: $($a[$i])`n            now: $($b[$i])"; $shown++ }
    }
}
function Invoke-Scan {
    param($Server, [bool]$Tv, [hashtable]$Prior = @{}, [bool]$Rebuild = $false)
    @(Invoke-MmlmServerScan -Server $Server -Movies (-not $Tv) -Shows $Tv -Rebuild $Rebuild -DetectFel $false -Prior $Prior)
}
function ConvertTo-PriorMap { param([object[]]$Recs) $h = @{}; foreach ($r in $Recs) { $h[[string]$r.PlexKey] = $r }; $h }

# the compiled scan helper must build as C# 5 (what Windows PowerShell 5.1 compiles) with no warnings
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $err = ''
    try { Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $root 'src/Mmlm.Scan.cs')).Replace('namespace Mmlm.Scan', 'namespace Mmlm.ScanCheck')) -Language CSharp -CompilerOptions '-langversion:5', '-warnaserror+' -ErrorAction Stop }
    catch { $err = [string]$_.Exception.Message }
    Check (-not $err) "src/Mmlm.Scan.cs compiles as C# 5 with no warnings $err"
}
$null = New-TestContext 'init'
Check (Initialize-MmlmScanNative) "the compiled scan helper loads $(Get-MmlmScanNativeError)"

Start-Mock 32499
Start-Mock 32501 @{ PLEX_MOCK_SCALE = '240' }
$small = New-MmlmServer -Kind plex -BaseUrl 'http://127.0.0.1:32499' -Token 'tok'
$rich  = New-MmlmServer -Kind plex -BaseUrl 'http://127.0.0.1:32501' -Token 'tok'

# ---- Part A: records must not change ------------------------------------------------------------------------------------
foreach ($mode in $(if ($env:MMLM_SCAN_MODES) { $env:MMLM_SCAN_MODES -split ',' } else { @('default') })) {
    # 'default' is what the page's scan uses once every phase is in; the others pin one path each
    $extra = switch ($mode) {
        'classic'   { @{ PlexParallel = 1; NoItemCache = $false; NativeConvert = $false } }
        'ps'        { @{ NoItemCache = $true; NativeConvert = $false } }
        default     { @{ NoItemCache = $true } }
    }
    "Mode: $mode"
    $ctx = New-TestContext "a-$mode" $extra
    $mv = Invoke-Scan $small $false; $tv = Invoke-Scan $small $true
    Check ($mv.Count -eq 7 -and $tv.Count -eq 10) 'small library: 7 movies and 10 episodes'
    Compare-Golden 'plex-movies' (ConvertTo-StableText $mv) 'small library: movies are unchanged'
    Compare-Golden 'plex-tv' (ConvertTo-StableText $tv) 'small library: episodes are unchanged'
    Check (@($mv + $tv | Where-Object { -not $_.HasPoster -or -not (Test-Path -LiteralPath $_.PosterPath) }).Count -eq 0) 'small library: every title has its poster file'

    Reset-Mock 32501
    $ctx = New-TestContext "r-$mode" $extra
    $rmv = Invoke-Scan $rich $false; $rtv = Invoke-Scan $rich $true
    $st = Get-MockStats 32501
    Check ($rmv.Count -eq 24 -and $rtv.Count -eq 240) 'varied library: 24 movies and 240 episodes'
    Compare-Golden 'plex-rich-movies' (ConvertTo-StableText $rmv) 'varied library: movies are unchanged'
    Compare-Golden 'plex-rich-tv' (ConvertTo-StableText $rtv) 'varied library: episodes are unchanged'
    $tm = $ctx.Sync.Times
    if ($mode -eq 'default') { Check ($tm -and $tm.Contains('convert-fast') -and $tm['convert-fast'].Count -eq 264 -and -not $tm.Contains('convert-retry')) 'every title went through the compiled record builder, none needed the retry' }
    else { Check (-not ($tm -and $tm.Contains('convert-fast'))) 'this mode uses the PowerShell record builder' }
    Check ($st.maxConcurrent -le 6) "never more than 6 requests at once (saw $($st.maxConcurrent))"
    Check ($ctx.Traffic.Requests -eq $st.requests) "every request is counted for the traffic counter ($($ctx.Traffic.Requests) counted, $($st.requests) made)"
    "  ..    first scan of the varied library: $($st.requests) requests"

    # ---- Part B: a rescan reuses everything -----------------------------------------------------------------------------
    Reset-Mock 32501
    $before = $ctx.Traffic.Requests
    $rtv2 = Invoke-Scan $rich $true (ConvertTo-PriorMap $rtv)
    $st2 = Get-MockStats 32501
    Check ((ConvertTo-StableText $rtv2) -ceq (ConvertTo-StableText $rtv)) 'rescan: the same records'
    Check ($st2.requests -le 4 -and ($ctx.Traffic.Requests - $before) -eq $st2.requests) "rescan: only the listing is asked for ($($st2.requests) requests)"

    # a scan that is stopped part-way leaves a checkpoint, and the next scan carries on from it
    if ($extra.NoItemCache) {
        Reset-Mock 32501
        $saved = New-Object System.Collections.Generic.List[object]
        $ctx = New-TestContext "c-$mode" (@{} + $extra + @{ ScanCheckpointEvery = 100; PlexParallel = 1 })
        Set-MmlmServerContext -Values @{ ScanCheckpoint = { param($Records) $saved.Clear(); $saved.AddRange(@($Records)); $ctx.Sync.Cancel = $true }.GetNewClosure() }
        $cut = Invoke-Scan $rich $true
        $firstReq = (Get-MockStats 32501).requests
        Check ($saved.Count -ge 100 -and $saved.Count -lt 240 -and @($saved | Where-Object { -not $_.PlexUpdated }).Count -eq 0) "stopped part-way: $($saved.Count) titles were checkpointed, each with its change marker"
        Initialize-MmlmNative
        $pf = Join-Path $tmp 'ck.partial'
        [Mmlm.Native.Snapshot]::Save([object[]]$saved.ToArray(), $pf, 'partial')
        $back = @([Mmlm.Native.Snapshot]::Load($pf))
        Check ($back.Count -eq $saved.Count -and [string]$back[0].PlexUpdated -eq [string]$saved[0].PlexUpdated -and $back[0].PlexUpdated) 'the checkpoint file keeps each change marker'
        $ctx.Sync.Cancel = $false; Set-MmlmServerContext -Values @{ ScanCheckpoint = $null }
        Reset-Mock 32501
        $resumed = Invoke-Scan $rich $true (ConvertTo-PriorMap $back)
        $st3 = Get-MockStats 32501
        Check ((ConvertTo-StableText $resumed) -ceq (ConvertTo-StableText $rtv)) 'carried on from the checkpoint: the same records as an unbroken scan'
        Check ($st3.requests -lt $st.requests) "carried on from the checkpoint: fewer requests than a first scan ($($st3.requests))"
    }

    # one failed request does not lose titles
    $ctx = New-TestContext "f-$mode" $extra
    [void](New-Object Net.WebClient).DownloadString('http://127.0.0.1:32501/__reset')
    $old = $env:PLEX_MOCK_FAIL_ONCE
    try {
        $req = [Net.HttpWebRequest]::Create('http://127.0.0.1:32501/__failonce?text=' + [Uri]::EscapeDataString('/library/metadata/10000')); [void]$req.GetResponse().Close()
        $rtv3 = Invoke-Scan $rich $true
        Check ($rtv3.Count -eq 240 -and (ConvertTo-StableText $rtv3) -ceq (ConvertTo-StableText $rtv)) 'a details request that fails once is asked again: no title is lost'
    } finally { $env:PLEX_MOCK_FAIL_ONCE = $old }

    # the kill switch stops a scan before any request
    Reset-Mock 32501
    $ctx.Traffic.Halted = $true
    $msg = ''; try { [void](Invoke-Scan $rich $true) } catch { $msg = $_.Exception.Message }
    Check ($msg -eq 'Traffic to data sources is paused.' -and (Get-MockStats 32501).requests -eq 0) 'paused traffic: the scan stops and nothing is requested'
    $ctx.Traffic.Halted = $false

    # a wrong token still gets the plain message
    $msg = ''; try { [void](Invoke-Scan (New-MmlmServer -Kind plex -BaseUrl 'http://127.0.0.1:32501' -Token 'wrong') $true) } catch { $msg = $_.Exception.Message }
    Check ($msg -eq 'Plex rejected the token (401 Unauthorized).') 'a wrong token: the same message as before'
}

# ---- compiled and PowerShell record builders agree on a few thousand varied titles (opt-in: needs the big mock) ----------
if ($env:MMLM_COMPARE_BUILDERS -eq '1') {
    $n = $(if ($env:MMLM_SPEED_ITEMS) { [int]$env:MMLM_SPEED_ITEMS } else { 55000 })
    Start-Mock 32502 @{ PLEX_MOCK_SCALE = [string]$n; PLEX_MOCK_DELAY_MS = '40' }
    $big = New-MmlmServer -Kind plex -BaseUrl 'http://127.0.0.1:32502' -Token 'tok'
    $ctx = New-TestContext 'ab-fast' @{ NoItemCache = $true }
    $fast = ConvertTo-StableText (Invoke-Scan $big $false)
    $nFast = $ctx.Sync.Times['convert-fast'].Count
    $ctx = New-TestContext 'ab-ps' @{ NoItemCache = $true; NativeConvert = $false }
    $slow = ConvertTo-StableText (Invoke-Scan $big $false)
    Check ($nFast -gt 1000 -and $fast -ceq $slow) "compiled and PowerShell record builders give identical records for $nFast varied movies"
}

# ---- Part C: speed (opt-in) -----------------------------------------------------------------------------------------------
if ($env:MMLM_SPEED_TEST -eq '1') {
    $n = $(if ($env:MMLM_SPEED_ITEMS) { [int]$env:MMLM_SPEED_ITEMS } else { 55000 })
    Start-Mock 32502 @{ PLEX_MOCK_SCALE = [string]$n; PLEX_MOCK_DELAY_MS = '40' }
    $big = New-MmlmServer -Kind plex -BaseUrl 'http://127.0.0.1:32502' -Token 'tok'
    Reset-Mock 32502
    $ctx = New-TestContext 'speed' @{ NoItemCache = $true }
    if ($env:MMLM_SPEED_CLASSIC -eq '1') { $ctx = New-TestContext 'speed' @{ PlexParallel = 1; NoItemCache = $false; NativeConvert = $false } }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $recs = Invoke-Scan $big $true
    $first = $sw.Elapsed.TotalSeconds; $st = Get-MockStats 32502
    Check ($recs.Count -eq $n) "speed: all $n episodes came back"
    "  ..    FIRST SCAN  {0:0.0} s   {1} requests   {2} at once at most" -f $first, $st.requests, $st.maxConcurrent
    if ($ctx.Sync.Times) { foreach ($k in @($ctx.Sync.Times.Keys)) { "            {0,-12} {1,8:0.00} s {2,8}" -f $k, $ctx.Sync.Times[$k].Seconds, $ctx.Sync.Times[$k].Count } }
    Reset-Mock 32502; $ctx.Sync.Times = $null
    $sw.Restart()
    $again = Invoke-Scan $big $true (ConvertTo-PriorMap $recs)
    "  ..    RESCAN      {0:0.0} s   {1} requests" -f $sw.Elapsed.TotalSeconds, (Get-MockStats 32502).requests
    Check ($again.Count -eq $n) 'speed: the rescan returns every episode'
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
"Done: $fail problem(s)."
