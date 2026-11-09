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
# a Metacritic score saved the way Fetch info saves it, for "Movie 1" (2001)
New-Item -ItemType Directory -Path (Join-Path $data 'metadata') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $data 'metadata\store.json'), '{"t:movie 1|2001":{"Manual":{},"Scraped":{"Metascore":74},"Sources":{"Metascore":"OMDb"},"Force":[],"At":"2026-11-08"}}')
# the window app's collections: one hand-picked (a Plex movie and a local file), one rule
[IO.File]::WriteAllText((Join-Path $data 'collections.json'), '{"Version":1,"Collections":[{"Name":"Faves","Type":"manual","Items":[{"Ids":["p:101"],"Title":"Movie 1","Year":2001},{"Ids":["f:D:\\Films\\Local.mkv"],"Title":"Local","Year":1999}],"Query":"","SortBy":"","SortDesc":false,"ByDate":false,"Limit":0,"Created":"2026-10-21 10:00","Modified":"2026-10-21 10:00"},{"Name":"Old","Type":"rule","Items":[],"Query":"year:<2003","SortBy":"","SortDesc":false,"ByDate":false,"Limit":0,"Created":"2026-10-21","Modified":"2026-10-21"}]}')
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
$lib = Cmd 9 'library.get' @{ tab = 'movies' }
Check ($lib -match '"rows":\[\[' -and $lib -match '"Poster"') 'library.get sends the movie rows with poster links'
Check ($lib -notmatch 'FullPath|PosterPath|Directory') 'no file paths reach the page'
$fn = @(($lib | ConvertFrom-Json).data.fields.n); $mi = [array]::IndexOf($fn, 'Metascore'); $ti = [array]::IndexOf($fn, 'Title')
function Find-Row($json, $title) { foreach ($r in ($json | ConvertFrom-Json).data.rows) { if ($r[$ti] -eq $title) { return , $r } } }
$m1 = Find-Row $lib 'Movie 1'
Check ($m1[$mi] -eq 74) 'fetched Metacritic score reaches the page after a scan'
Start-Sleep -Milliseconds 1100; [IO.File]::WriteAllText((Join-Path $data 'metadata\store.json'), '{"t:movie 1|2001":{"Manual":{"Metascore":81},"Scraped":{"Metascore":74},"Sources":{"Metascore":"OMDb"},"Force":[],"At":"2026-11-08"}}')
Check ((Cmd 16 'library.get' @{ tab = 'movies' }) -match '"pending":true') 'a score edited in the window app makes the page copy rebuild'
$ev = ''; for ($k = 0; $k -lt 300 -and $ev -notmatch '"event":"library"'; $k++) { $ev += (@(Receive-DashEvents) -join ''); Start-Sleep -Milliseconds 100 }
$lib2 = Cmd 17 'library.get' @{ tab = 'movies' }
$m1 = Find-Row $lib2 'Movie 1'
Check ($m1[$mi] -eq 81) 'and the edited score shows'
Remove-Item -LiteralPath (Join-Path $data 'Dashboard\library-movies.json') -Force
Check ((Cmd 10 'library.get' @{ tab = 'movies' }) -match '"pending":true') 'a missing page copy is rebuilt from the snapshot'
$ev = ''; for ($k = 0; $k -lt 300 -and $ev -notmatch '"event":"library"'; $k++) { $ev += (@(Receive-DashEvents) -join ''); Start-Sleep -Milliseconds 100 }
Check ($ev -match '"ready":true') 'the rebuilt library is announced'
Check ((Cmd 11 'library.get' @{ tab = 'movies' }) -match '"rows":\[\[') 'and then sent'
Check ((Cmd 12 'settings.set' @{ key = 'moviesView'; value = 'grid' }) -match '"moviesView":"grid"') 'page settings are saved'
Check ((Cmd 13 'settings.set' @{ key = 'moviesView'; value = 'bogus' }) -match '"ok":false') 'bad setting values are refused'
Check ((Cmd 14 'open.url' @{ url = 'http://example.com/' }) -match 'Only https') 'open.url refuses plain http'
Check ((Cmd 15 'open.url' @{ url = 'https://evil.example/' }) -match 'not opened') 'open.url refuses unknown sites'
$cg = Cmd 18 'collections.get'
Check ($cg -match '"name":"Faves"' -and $cg -match '"p:101"' -and $cg -match '"h:[0-9A-F]{16}"' -and $cg -notmatch 'Local\.mkv"\]|D:') 'collections reach the page with local paths hashed'
Check ($lib -match '"p:10\d"') 'each title carries its collection id'
$cols = ($cg | ConvertFrom-Json).data
$cols[0].items += [pscustomobject]@{ ids = @('p:102'); title = 'Movie 2'; year = 2002 }
$saved = Cmd 19 'collections.save' @{ collections = $cols }
$file = [IO.File]::ReadAllText((Join-Path $data 'collections.json'))
Check ($file -match 'D:\\\\Films\\\\Local.mkv' -and $file -match 'p:102' -and $file -match '"Type":\s*"rule"') 'saving from the page keeps the window app''s ids and format'
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
