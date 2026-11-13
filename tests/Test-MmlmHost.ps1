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
# dash.json as DashLauncher checks it (a bad one stops the whole module from loading)
$dj = Get-Content (Join-Path $root 'dash.json') -Raw | ConvertFrom-Json
Check (@($dj.dataSources | Where-Object { $_.name -match 'TMDB|OMDb|IMDb' }).Count -eq 3) 'dash.json: every outside source Fetch info uses is listed'
Check (@($dj.dataSources | Where-Object { -not $_.name -or ([string]$_.name).Length -gt 80 -or [string]$_.terms -notmatch '^https://' }).Count -eq 0) 'dash.json: each data source has a name of 1-80 characters and an https terms link'
Check ([string]$dj.name -and [string]$dj.title -and [int]$dj.contract -eq 1) 'dash.json: name, title and contract'
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
Check ((Cmd 56 'settings.set' @{ key = 'tvView'; value = 'clear' }) -match '"tvView":"clear"') 'Clear is a TV view'
[void](Cmd 57 'settings.set' @{ key = 'tvView'; value = 'posters' })
Check ((Cmd 58 'shows.status' @{}) -match '"data":\{\}') 'show status is empty until fetched'
Check ((Cmd 59 'tools.start' @{ kind = 'fetch'; tab = 'tv' }) -match 'TMDB key|Scan this tab') 'TV Fetch info (show status) needs a TMDB key'
Check ((Cmd 50 'settings.set' @{ key = 'moviesView'; value = 'compare' }) -match '"moviesView":"compare"') 'Compare is a movies view'
Check ((Cmd 51 'settings.set' @{ key = 'fxLeft'; value = 'lightning' }) -match '"fxLeft":"lightning"') 'Fun: a border effect saves'
Check ((Cmd 52 'settings.set' @{ key = 'fxLeft'; value = 'rainbow' }) -match '"ok":false') 'Fun: an unknown effect is refused'
[void](Cmd 54 'settings.set' @{ key = 'moviesView'; value = 'posters' }); [void](Cmd 55 'settings.set' @{ key = 'fxLeft'; value = 'auto' })
# Compare: metrics, Fun mode and MediaInfo settings; MediaInfo commands answer at once (no MediaInfo here)
Check ((Cmd 58 'settings.set' @{ key = 'cmpMetrics'; value = @('ww', 'rtc', 'vbr', 'cll') }) -match '"cmpMetrics":\["ww","rtc","vbr","cll"\]') 'Compare: chosen metrics save'
Check ((Cmd 59 'settings.set' @{ key = 'cmpFun'; value = $true }) -match '"cmpFun":true') 'Compare: Fun mode saves'
Check ((Cmd 60 'settings.set' @{ key = 'miPath'; value = 'C:\Tools\notepad.exe' }) -match '"ok":false') 'MediaInfo location: only a MediaInfo program is accepted'
Check ((Cmd 61 'settings.set' @{ key = 'miFrom'; value = '/data/movies' }) -match '"miFrom":"/data/movies"') 'MediaInfo: the server path saves'
$sw0 = [Diagnostics.Stopwatch]::StartNew()
$st0 = Cmd 62 'mediainfo.status' @{ path = '' }
Check ($st0 -match '"ok":true' -and $st0 -match '\\"found\\":false|"found":false' -and $sw0.ElapsedMilliseconds -lt 3000) "MediaInfo status answers quickly ($($sw0.ElapsedMilliseconds) ms)"
Check ((Cmd 63 'mediainfo.values') -match '"ok":true') 'MediaInfo values answer (none yet)'
Check ((Cmd 64 'mediainfo.read' @{ rids = @('p:1') }) -match 'MediaInfo was not found') 'MediaInfo read: a plain message when it is not installed (nothing is downloaded)'
[void](Cmd 65 'settings.set' @{ key = 'cmpFun'; value = $false }); [void](Cmd 66 'settings.set' @{ key = 'cmpMetrics'; value = @('ww', 'dom', 'open', 'rtc', 'rta', 'meta', 'imdb') }); [void](Cmd 67 'settings.set' @{ key = 'miFrom'; value = '' })
Check ((Cmd 53 'poster.colours' @{ url = 'https://mmlm.cache/../settings.json' }) -match '"ok":false') 'poster.colours stays inside the cache'
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
function Wait-Tool { $all = ''; for ($k = 0; $k -lt 300; $k++) { $all += (@(Receive-DashEvents) -join ''); if ($all -match '"event":"tool","data":\{[^}]*"running":false') { return $all }; Start-Sleep -Milliseconds 100 }; $all }
$env:USERPROFILE = $data; $env:HOME = $data
Check ((Cmd 24 'tools.start' @{ kind = 'csv'; tab = 'movies'; rids = @('p:101', 'p:102'); name = 'Two films'; columns = @('Year', 'Genre', 'FullPath') }) -match '"ok":true') 'CSV export starts'
$te = Wait-Tool
$csvPath = ([regex]::Match($te, '"path":"([^"]+)"').Groups[1].Value) -replace '\\\\', '\'
$csv = $(if ($csvPath -and (Test-Path -LiteralPath $csvPath)) { [IO.File]::ReadAllText($csvPath) } else { '' })
Check ($csv -match 'Movie 1' -and $csv -match 'Movie 2' -and $csv -notmatch 'Movie 3' -and $csv -notmatch 'FullPath|/m/') 'CSV has the chosen titles and columns, no file paths'
Check ((Cmd 25 'tools.start' @{ kind = 'html'; tab = 'movies'; name = 'All films' }) -match '"ok":true') 'HTML export starts'
$te = Wait-Tool
$htmlPath = ([regex]::Match($te, '"path":"([^"]+)"').Groups[1].Value) -replace '\\\\', '\'
$html = $(if ($htmlPath -and (Test-Path -LiteralPath $htmlPath)) { [IO.File]::ReadAllText($htmlPath) } else { '' })
Check ($html -match 'Movie 7' -and $html -match 'data:image/jpeg;base64' -and $html -notmatch '__DATA__|/m/Movie') 'HTML dashboard has every title with posters inside, no file paths'
Check ((Cmd 26 'tools.start' @{ kind = 'fetch'; tab = 'movies' }) -match 'Add a TMDB or OMDb key') 'Fetch info asks for a key first'
[void](Cmd 27 'tools.start' @{ kind = 'fel'; tab = 'movies' }); $te = Wait-Tool
Check ($te -match 'No dual-layer|needs ffmpeg') 'FEL/MEL check runs (nothing to check here)'
$dash = @{ movies = @(@{ id = 'a1'; name = 'Mine'; widgets = @(@{ id = 'w1'; type = 'bar'; field = 'Genre'; op = 'count' }) }); tv = @() }
[void](Cmd 28 'dashboards.save' @{ data = $dash })
Check ((Cmd 29 'dashboards.get') -match '"name":"Mine"' -and (Test-Path -LiteralPath (Join-Path $data 'dashboards.json'))) 'your own dashboards are saved'
[void](Cmd 3 'scan.start' @{ tab = 'tv' }); $e = Wait-Scan
Check ($e -match '"count":10') 'TV scan finished with 10 episodes'
# Settings > Artwork: ticking fetches it now for both tabs; a title Plex has none for gets a marker, not a retry
Check ((Cmd 60 'tools.start' @{ kind = 'artwork'; tab = 'movies' }) -match 'Tick an artwork option') 'Artwork needs an option ticked'
foreach ($k in 'artBackground', 'artLogo', 'artBanner') { [void](Cmd 61 'settings.set' @{ key = $k; value = $true }) }
New-Item -ItemType Directory -Force -Path (Join-Path $data 'Dashboard\art') | Out-Null
[IO.File]::WriteAllText((Join-Path $data 'Dashboard\art\banner-2.jpg'), 'old cropped banner')
Check ((Cmd 62 'tools.start' @{ kind = 'artwork'; tab = 'movies' }) -match '"ok":true') 'Artwork starts'
$te = Wait-Tool
$art = Join-Path $data 'Dashboard\art'
Check ($te -match 'new picture' -and (Test-Path -LiteralPath (Join-Path $art 'art-101.jpg')) -and (Test-Path -LiteralPath (Join-Path $art 'clogo-101.png'))) 'background art and clear logos saved in the cache'
Check ((Test-Path -LiteralPath (Join-Path $art 'clogo-102.none')) -and -not (Test-Path -LiteralPath (Join-Path $art 'clogo-102.png'))) 'a missing clear logo is remembered, not asked for again'
Check (-not (Test-Path -LiteralPath (Join-Path $art 'banner-2.jpg'))) 'the old cropped banners are dropped'
Check ((Test-Path -LiteralPath (Join-Path $art 'tvbanner-2.jpg')) -and -not (Test-Path -LiteralPath (Join-Path $art 'tvbanner-101.jpg'))) 'banners for TV shows only'
$lj = ''; for ($k = 0; $k -lt 100; $k++) { $lj = Cmd 63 'library.get' @{ tab = 'movies' }; if ($lj -match '"rows"') { break }; [void](@(Receive-DashEvents)); Start-Sleep -Milliseconds 200 }
Check ($lj -match 'art/art-101\.jpg' -and $lj -match 'art/clogo-101\.png' -and $lj -notmatch 'art/clogo-102') 'the library carries the artwork it has'
# an old cropped banner left from v0.10.0 is fetched again by itself when the page next asks for a library
$script:Mod = Get-Module MMLM.Host
& $script:Mod { $script:ArtChecked = $false }
[IO.File]::WriteAllText((Join-Path $art 'banner-3.jpg'), 'old cropped banner')
[void](Cmd 66 'library.get' @{ tab = 'tv' }); $te = Wait-Tool
Check ($te -match '"kind":"artwork"' -and -not (Test-Path -LiteralPath (Join-Path $art 'banner-3.jpg')) -and (Test-Path -LiteralPath (Join-Path $art 'tvbanner-3.jpg'))) 'cropped artwork from v0.10.0 is replaced by itself'
# Refresh artwork: fetches again what is already saved (a picture changed in Plex), and the library points at the new copy
$before = (Get-Item -LiteralPath (Join-Path $art 'art-101.jpg')).LastWriteTimeUtc
Start-Sleep -Milliseconds 1100
Check ((Cmd 67 'tools.start' @{ kind = 'artwork'; tab = 'movies'; force = $true }) -match '"ok":true') 'Refresh artwork starts'
$te = Wait-Tool
Check ($te -match 'refreshed from your server' -and (Get-Item -LiteralPath (Join-Path $art 'art-101.jpg')).LastWriteTimeUtc -gt $before -and (Test-Path -LiteralPath (Join-Path $art 'clogo-102.none'))) 'Refresh artwork fetches saved pictures again'
foreach ($k in 'artBackground', 'artLogo', 'artBanner') { [void](Cmd 65 'settings.set' @{ key = $k; value = $false }) }
$sr = Cmd 20 'series.open' @{ show = 'Show A'; ep = '1001' }
Check ($sr -match '"loading":true') 'opening a show fetches it from Plex'
$ev = ''; for ($k = 0; $k -lt 300 -and $ev -notmatch '"event":"series","data":\{"show":"Show A","running":false'; $k++) { $ev += (@(Receive-DashEvents) -join ''); Start-Sleep -Milliseconds 100 }
Check ($ev -match '"running":false,"error":null') 'the show fetch finishes'
$sr = Cmd 21 'series.open' @{ show = 'Show A'; ep = '1001' }
$sd = ($sr | ConvertFrom-Json).data
Check ($sd.seasons.Count -eq 2 -and $sd.episodes.Count -eq 5 -and $sd.cast.Count -eq 5 -and $sd.related.Count -eq 2) 'seasons, episodes, cast and related shows'
Check ($sd.episodes[0].watched -eq $true -and $sd.episodes[4].watched -eq $false -and $sd.episodes[0].thumb -match '^series/img/') 'watched marks and episode stills'
Check (Test-Path -LiteralPath (Join-Path $data ('Dashboard\' + ($sd.cast[0].photo -replace '/', '\')))) 'cast photos saved in the cache'
Check ((Cmd 22 'image.data' @{ path = $sd.seasons[0].poster }) -match 'data:image/jpeg;base64') 'a season poster can be read for its colours'
Check ((Cmd 23 'image.data' @{ path = '..\settings.json' }) -match '"ok":false') 'image.data only reads cached pictures'
# PlexDoctor: settings, a check-up (scans each scanned tab, then the read-only checks), the report and the alert flag
Check ((Cmd 70 'settings.set' @{ key = 'doctorFreq'; value = 'fortnightly' }) -match '"ok":false') 'PlexDoctor: an unknown schedule is refused'
Check ((Cmd 71 'settings.set' @{ key = 'doctorChecks'; value = @('gaps', 'nope', 'unmatched', 'subs') }) -match '"doctorChecks":\["gaps","unmatched","subs"\]') 'PlexDoctor: only known checks are kept'
Check ((Cmd 82 'settings.set' @{ key = 'clearScale'; value = 160 }) -match '"clearScale":160' -and (Cmd 83 'settings.set' @{ key = 'bannerScale'; value = 300 }) -match '"ok":false') 'each view keeps its own size (50-200%)'
Check ((Cmd 78 'doctor.status' @{}) -match '"next":""') 'PlexDoctor: no schedule by default (opt-in)'
[void](Cmd 79 'settings.set' @{ key = 'doctorFreq'; value = 'weekly' })
Check ((Cmd 80 'doctor.status' @{}) -match '"next":""') 'PlexDoctor: a schedule stays off until its warning is acknowledged'
[void](Cmd 81 'settings.set' @{ key = 'doctorAck'; value = $true })
$dsj = Cmd 72 'doctor.status' @{}
Check ($dsj -match '"next":"\d{4}-\d\d-\d\dT03:00:00"' -and $dsj -match '"last":null') 'PlexDoctor: once acknowledged, the next run is shown'
Check ((Cmd 73 'doctor.run' @{}) -match '"ok":true') 'PlexDoctor: Run check-up now starts'
Check ((Cmd 74 'doctor.run' @{}) -match 'already running') 'PlexDoctor: one check-up at a time'
$ev = ''; for ($k = 0; $k -lt 600 -and $ev -notmatch '"event":"doctor","data":\{"running":false,"done":true'; $k++) { $ev += (@(Receive-DashEvents) -join ''); Start-Sleep -Milliseconds 100 }
Check ($ev -match '"event":"scan","data":\{[^}]*"tab":"movies"' -and $ev -match '"event":"scan","data":\{[^}]*"tab":"tv"') 'PlexDoctor: it scans both libraries first'
Check ($ev -match '"event":"doctor","data":\{"running":false,"done":true,"error":null') 'PlexDoctor: the check-up finishes'
$rep = ((Cmd 75 'doctor.report' @{}) | ConvertFrom-Json).data
Check ($rep.counts.movies -eq 7 -and $rep.counts.shows -eq 2 -and @($rep.skipped) -contains 'av1' -and @($rep.issues | Where-Object { $_.check -notin @('gaps', 'unmatched', 'subs') }).Count -eq 0) 'PlexDoctor: the report counts the library and runs only the ticked checks'
Check (@(Get-ChildItem (Join-Path $data 'PlexDoctor\reports') -Filter 'report-*.json').Count -eq 1) 'PlexDoctor: the report is saved'
$ds = ((Cmd 76 'doctor.status' @{}) | ConvertFrom-Json).data
Check ($ds.unseen -eq $false -and $ds.last.issues -eq @($rep.issues).Count) 'PlexDoctor: opening the report clears the alert'
[void](Cmd 77 'settings.set' @{ key = 'doctorChecks'; value = @('unreadable', 'unmatched', 'wrongmatch', 'gaps', 'poster', 'dupes', 'av1') })
Start-DashWorker
Check ($null -eq (Get-DashStatus).Badge.Count) 'badge clears when the tab is shown'
[void](Cmd 4 'scan.start' @{ tab = 'movies'; rebuild = $true }); Start-Sleep -Milliseconds 20; Stop-DashTraffic; $e = Wait-Scan
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
