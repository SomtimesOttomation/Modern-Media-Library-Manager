# The Jellyfin scan (MMLM.Jellyfin through MMLM.Server) against tests\jellyfin-mock.py on port 8099 (API key tok).
# Run: start python tests\jellyfin-mock.py, then pwsh -File tests\Test-MmlmJellyfin.ps1
$root = Split-Path -Parent $PSScriptRoot
foreach ($m in 'MMLM.Library.psm1', 'MMLM.Plex.psm1', 'MMLM.Jellyfin.psm1', 'MMLM.Server.psm1') { Import-Module (Join-Path $root "modules\$m") -DisableNameChecking }
# the record field list, read from the main script's table as the host does
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Modern-Media-Library-Manager.ps1'), [ref]$null, [ref]$null)
$fa = $ast.Find({ param($x) $x -is [Management.Automation.Language.AssignmentStatementAst] -and $x.Left.Extent.Text -eq '$script:FieldDefs' }, $true)
$fields = @(foreach ($line in (& ([scriptblock]::Create($fa.Right.Extent.Text)))) { $p = $line -split '\|'; [pscustomobject]@{ Name = $p[0]; Type = $p[1]; Group = $p[2]; Show = [bool][int]$p[3] } })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('mmlm-jf-' + [guid]::NewGuid().ToString('N'))
$ctx = @{ Sync = [hashtable]::Synchronized(@{ Text = ''; Value = 0; Max = 0; Cancel = $false; PhaseLo = 0.0; PhaseHi = 1.0 })
    Traffic = [hashtable]::Synchronized(@{ Requests = 0; Bytes = 0; Errors = 0; Halted = $false }); CacheFolder = (Join-Path $tmp 'Cache'); ThumbFolder = (Join-Path $tmp 'Thumbs')
    CacheVersion = 4; Culture = [Globalization.CultureInfo]::InvariantCulture; PlexTimeoutMs = 30000; PlexClientId = 'mmlm-test'; Fields = $fields; TypeMap = @{ string = [string]; int = [int]; long = [long]; double = [double]; bool = [bool] } }
foreach ($d in $ctx.CacheFolder, $ctx.ThumbFolder) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
Set-MmlmContext -Values $ctx; Set-MmlmServerContext -Values $ctx
$fail = 0
function Check($ok, $what) { if ($ok) { "  ok    $what" } else { "  FAIL  $what"; $script:fail++ } }
$srv = New-MmlmServer -Kind jellyfin -BaseUrl 'http://127.0.0.1:8099' -Token 'tok'
Check ($srv.Name -eq 'Jellyfin') 'Jellyfin is a server kind'
$t = Test-MmlmServer $srv
Check ($t.name -eq 'Test Jellyfin' -and @($t.libraries).Count -eq 2) 'Test: server name and its movie / TV libraries (music left out)'
$bad = $null; try { [void](Test-MmlmServer (New-MmlmServer -Kind jellyfin -BaseUrl 'http://127.0.0.1:8099' -Token 'wrong')) } catch { $bad = $_.Exception.Message }
Check ($bad -match 'refused the API key') 'a wrong API key gets a plain message'

$mv = @(Invoke-MmlmServerScan -Server $srv -Movies $true -Shows $false -Rebuild $false -DetectFel $false -Prior @{})
$by = @{}; foreach ($r in $mv) { $by[$r.Title] = $r }
Check ($mv.Count -eq 4 -and $by.Contains('Jelly Dawn')) 'movies: every movie, by title'
$a = $by['Jelly Dawn']
Check ($a.Year -eq 2019 -and $a.Library -eq 'Films' -and $a.IMDBID -eq 'tt0000001' -and $a.TMDBID -eq '501' -and $a.Genre -eq 'Drama, Thriller' -and $a.Director -eq 'Dee Rector') 'movies: year, library, ids, genres, director'
Check ($a.PlexKey -eq ('jf-' + ('{0:x32}' -f 0xa001)) -and $a.PlexThumb -eq ('/Items/{0:x32}/Images/Primary' -f 0xa001) -and $a.PlexUpdated -eq 'etag1') 'movies: Jellyfin id, picture and change marker'
Check ($a.ResolutionClass -eq '4K' -and $a.VideoCodec -eq 'HEVC' -and $a.HDRType -eq 'Dolby Vision' -and $a.DVProfile -eq '8.1' -and $a.DVLayer -eq 'Single layer' -and $a.BitDepth -eq 10) 'movies: 4K HEVC Dolby Vision 8.1, single layer'
Check ($a.AudioFormat -match 'TrueHD' -and $a.ObjectAudio -match 'Atmos' -and $a.AudioChannels -eq 8 -and $a.SubtitleLanguages -eq 'eng') 'movies: TrueHD Atmos 7.1, English subtitles'
Check ($a.RTCritic -eq 81 -and $a.Rating -eq 7.2 -and $a.RuntimeMin -eq 120 -and $a.FileSizeGB -gt 7) 'movies: critics score, rating, runtime, size'
Check ($a.HasPoster -and (Test-Path -LiteralPath $a.PosterPath)) 'movies: poster saved'
Check ($by['Old Reel'].HDRType -eq 'SDR' -and $by['Old Reel'].ResolutionClass -eq '1080p' -and $by['Old Reel'].VideoCodec -eq 'AVC' -and $by['Old Reel'].AudioFormat -match 'DTS') '1080p SDR AVC with DTS-HD MA'
Check ($by['Bright Plus'].HDRType -eq 'HDR10' -and $by['Bright Plus'].HasHDR10Plus) 'HDR10+'
Check ($by['Two Layers'].DVLayer -eq 'Dual layer' -and $by['Two Layers'].DVProfile -eq '7' -and -not $by['Two Layers'].IMDBID) 'Dolby Vision profile 7, dual layer; no ids'

$tv = @(Invoke-MmlmServerScan -Server $srv -Movies $false -Shows $true -Rebuild $false -DetectFel $false -Prior @{})
$j = @($tv | Where-Object { $_.Show -eq 'Show J' })
Check ($tv.Count -eq 6 -and $j.Count -eq 3) 'TV: every episode, by show'
$e1 = $j | Where-Object { $_.Episode -eq 1 }
Check ($e1.Title -eq 'Show J - S01E01 - Ep 1' -and $e1.Season -eq 1 -and $e1.Genre -eq 'Comedy' -and $e1.IMDBID -eq 'tt0900001' -and $e1.MPAARating -eq 'TV-14' -and $e1.Rating -eq 8.4) "TV: episode title and the show's genres, ids, rating"
Check ($e1.PlexThumb -eq ('/Items/{0:x32}/Images/Primary' -f 0xb001)) "TV: episodes use the show's poster"
$k = @($tv | Where-Object { $_.Show -eq 'Show K' })[0]
Check ($k.PlexThumb -match ('^/Items/' + $k.PlexKey.Substring(3) + '/Images/Primary$') -and $k.HasPoster) 'TV: a show with no poster falls back to the episode picture (as with Plex)'

# second scan: nothing changed, nothing re-read
$prior = @{}; foreach ($r in $mv) { $prior[[string]$r.PlexKey] = $r }
$before = $ctx.Traffic.Requests
$mv2 = @(Invoke-MmlmServerScan -Server $srv -Movies $true -Shows $false -Rebuild $false -DetectFel $false -Prior $prior)
Check ($mv2.Count -eq 4 -and ($ctx.Traffic.Requests - $before) -le 3) 'a second scan reuses unchanged titles (only the lists are asked for)'

# artwork
$art = Join-Path $tmp 'art'
$res = Sync-MmlmServerArtwork -Server $srv -Recs ($mv + $tv) -Kinds @('art', 'logo', 'banner') -Folder $art
$aid = Get-MmlmArtworkFileId $a.PlexThumb
Check ((Test-Path (Join-Path $art "art-$aid.jpg")) -and (Test-Path (Join-Path $art "clogo-$aid.png")) -and -not (Test-Path (Join-Path $art "tvbanner-$aid.jpg"))) 'artwork: background and logo for a movie, no banner (movies have none)'
$sid = Get-MmlmArtworkFileId $e1.PlexThumb
Check ((Test-Path (Join-Path $art "tvbanner-$sid.jpg")) -and $res.Saved -ge 5 -and -not $res.Stopped) "artwork: the show's banner"
Check ((Test-Path (Join-Path $art ('art-{0}.none' -f (Get-MmlmArtworkFileId $by['Old Reel'].PlexThumb))))) 'artwork: a title Jellyfin has none for is remembered'
Check ((Get-MmlmArtworkFileId '/library/metadata/42/thumb/1') -eq '42') 'artwork ids: Plex unchanged'
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
"Done: $fail problem(s)."
exit ([int]($fail -gt 0))
