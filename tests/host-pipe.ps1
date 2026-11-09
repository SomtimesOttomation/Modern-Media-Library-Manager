<#
    Test helper: runs the dash backend with stdin/stdout in place of WebView2, for tests/page-e2e.js.
    Each stdin line is one page message (JSON); every message the backend sends to the page is written as "POST <json>".
#>
param([string]$Root = (Split-Path $PSScriptRoot))
Import-Module (Join-Path $Root 'modules\MMLM.Host.psm1') -DisableNameChecking
$ctx = [pscustomobject]@{ Mode = 'standalone'; Root = $Root; Post = { param($j) [Console]::Out.WriteLine('POST ' + ($j -replace '\r?\n', ' ')); [Console]::Out.Flush() }; Close = { }; Relaunch = ''; HostPid = $PID; Theme = ''; LauncherVersion = ''; Debug = $true }
$i = Initialize-Dash -Context $ctx
[Console]::Out.WriteLine('CACHE ' + $i.CacheDir); [Console]::Out.Flush()
Start-DashWorker
# stdin is read on its own thread (Console.In's "async" read blocks), so events keep flowing between page messages
$inbox = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$reader = [powershell]::Create()
[void]$reader.AddScript({ param($q) while ($null -ne ($l = [Console]::In.ReadLine())) { $q.Enqueue($l) }; $q.Enqueue([char]4) }).AddArgument($inbox)
[void]$reader.BeginInvoke()
$done = $false
while (-not $done) {
    $line = $null
    while ($inbox.TryDequeue([ref]$line)) {
        if ($line -eq [string][char]4) { $done = $true; break }
        if ($line.Trim()) { try { Invoke-DashCommand -Message ($line | ConvertFrom-Json) } catch { [Console]::Out.WriteLine('ERR ' + $_.Exception.Message) } }
    }
    foreach ($j in @(Receive-DashEvents)) { if ($j) { [Console]::Out.WriteLine('POST ' + $j); [Console]::Out.Flush() } }
    Start-Sleep -Milliseconds 40
}
Stop-Dash
