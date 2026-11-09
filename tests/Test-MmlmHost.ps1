<#
    Headless test of the dash backend (modules\MMLM.Host.psm1) against tests\plex-mock.py. No window, no real Plex.
    Run:  python3 tests/plex-mock.py &      then
          $env:LOCALAPPDATA = <scratch folder>; $env:MMLM_HOST_TEST_TOKEN = 'tok'
          pwsh -File tests/Test-MmlmHost.ps1
    It writes settings.json with the mock's address into <LOCALAPPDATA>\Modern-Media-Library-Manager first.
#>
$root = Split-Path $PSScriptRoot
$data = Join-Path $env:LOCALAPPDATA 'Modern-Media-Library-Manager'
Remove-Item -LiteralPath (Join-Path $data 'Library') -Recurse -Force -ErrorAction SilentlyContinue   # start from an empty library every run
New-Item -ItemType Directory -Path $data -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $data 'settings.json'), '{"PlexUrl":"http://127.0.0.1:32499","PlexTokenProtected":""}')
Import-Module (Join-Path $root 'modules\MMLM.Host.psm1') -DisableNameChecking
$posted = New-Object System.Collections.Generic.List[string]
$ctx = [pscustomobject]@{ Mode = 'standalone'; Root = $root; Post = { param($j) $posted.Add($j) }.GetNewClosure(); Close = { }; Relaunch = ''; HostPid = $PID; Theme = ''; LauncherVersion = ''; Debug = $true }
$fail = 0
function Check([bool]$Ok, [string]$Text) { if ($Ok) { "  ok    $Text" } else { $script:fail++; "  FAIL  $Text" } }
function Cmd($id, $cmd, $a = @{}) { Invoke-DashCommand -Message ([pscustomobject]@{ id = $id; cmd = $cmd; args = [pscustomobject]$a }); $posted[$posted.Count - 1] }
function Wait-Scan { $all = ''; for ($k = 0; $k -lt 300; $k++) { $all += (@(Receive-DashEvents) -join ''); if ($all -match '"running":false') { return $all }; Start-Sleep -Milliseconds 100 }; $all }
$i = Initialize-Dash -Context $ctx
Check $i.Ok 'Initialize-Dash'
Suspend-DashWorker
[void](Cmd 1 'scan.start' @{ tab = 'movies' }); $e = Wait-Scan
Check ($e -match '"count":7') 'movie scan finished with 7 titles'
Check ((Get-DashStatus).Badge.Count -eq 7) 'badge counts 7 new while the tab is hidden'
Check ((Cmd 2 'summary.get' @{ tab = 'movies' }) -match 'mmlm.cache/thumbs/') 'summary.get lists posters from the cache'
[void](Cmd 3 'scan.start' @{ tab = 'tv' }); $e = Wait-Scan
Check ($e -match '"count":10') 'TV scan finished with 10 episodes'
Start-DashWorker
Check ($null -eq (Get-DashStatus).Badge.Count) 'badge clears when the tab is shown'
[void](Cmd 4 'scan.start' @{ tab = 'movies'; rebuild = $true }); Start-Sleep -Milliseconds 150; Stop-DashTraffic; $e = Wait-Scan
Check ($e -match '"cancelled":true') 'kill switch cancels a running scan'
Check ((($posted -join '') -replace '\s', '') -match '"event":"traffic","data":\{"stopped":true\}') 'kill switch tells the page at once'
Check ((Cmd 5 'scan.start' @{ tab = 'movies' }) -match 'paused') 'no new scan while traffic is paused'
Check ((Cmd 7 'summary.get' @{ tab = 'tv' }) -match '"ok":true') 'non-fetching commands still answer while paused'
Check ((Cmd 8 'nope') -match 'unknown command') 'unknown command is refused'
Check ((Cmd 'a-1' 'traffic.get') -match '"id":"a-1"') 'string request id is echoed as JSON'
[void](Cmd 6 'traffic.resume')
Check ((Get-DashStatus).Live -eq 0) 'Live stays 0 for a library'
$sw = [Diagnostics.Stopwatch]::StartNew(); Stop-Dash
Check ($sw.ElapsedMilliseconds -lt 2000) 'Stop-Dash within 2 seconds'
"Done: $fail problem(s)."
exit ([int]($fail -gt 0))
