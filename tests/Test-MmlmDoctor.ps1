# PlexDoctor's checks and schedule (MMLM.Doctor), without Plex. Run: pwsh -File tests\Test-MmlmDoctor.ps1
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'modules\MMLM.Library.psm1') -DisableNameChecking
Import-Module (Join-Path $root 'modules\MMLM.Doctor.psm1') -DisableNameChecking
Set-MmlmContext -Values @{ Sync = [hashtable]::Synchronized(@{ Text = ''; Value = 0; Max = 0; Cancel = $false; PhaseLo = 0.0; PhaseHi = 1.0 }) }
$fail = 0
function Check($ok, $what) { if ($ok) { "  ok    $what" } else { "  FAIL  $what"; $script:fail++ } }
function Rec($h) { [pscustomobject]$h }
$base = @{ Year = 2001; IMDBID = 'tt1'; TMDBID = '1'; Genre = 'Drama'; Plot = 'x'; VideoCodec = 'hevc'; RuntimeMin = 100; PlexThumb = '/t'; FullPath = 'p'; Directory = 'A (2001)'; FileName = 'a.mkv'; SubtitleLanguages = 'English'; SubtitleTracks = 1; ResolutionClass = '4K'; FileSizeGB = 50 }
function M($over) { $h = $base.Clone(); foreach ($k in $over.Keys) { $h[$k] = $over[$k] }; Rec $h }
$mv = @(
    (M @{ Title = 'Good'; PlexKey = '1' })
    (M @{ Title = 'Good'; PlexKey = '2'; ResolutionClass = '1080p'; FileSizeGB = 10; SubtitleLanguages = ''; SubtitleTracks = 0 })
    (M @{ Title = 'Broken'; Year = 2017; PlexKey = '3'; IMDBID = ''; TMDBID = ''; Genre = ''; Plot = ''; VideoCodec = ''; RuntimeMin = 0; PlexThumb = '' })
    (M @{ Title = 'Glass'; Year = 2011; PlexKey = '4'; IMDBID = 'tt9'; VideoCodec = 'av1'; Directory = 'Glass (1995)'; SubtitleLanguages = 'French' })
    (M @{ Title = 'Old agent'; PlexKey = '5'; IMDBID = ''; TMDBID = '' })
)
$ep = @(1, 2, 4, 5 | ForEach-Object { Rec @{ Title = "S - S01E0$_"; Show = 'Show A'; Season = 1; Episode = $_; Year = 2000; IMDBID = ''; TMDBID = ''; Genre = 'Comedy'; Plot = 'x'; VideoCodec = 'h264'; RuntimeMin = 30; PlexThumb = '/x'; PlexKey = "e$_"; FullPath = "e$_"; SubtitleLanguages = 'English'; SubtitleTracks = 1 } })
$r = Invoke-MmlmDoctor -Movies $mv -Episodes $ep -Checks (Get-MmlmDoctorCheckIds)
$by = @{}; foreach ($i in $r.issues) { $by[$i.check + ':' + $i.title] = $i }
Check ($by.Contains('unreadable:Broken (2017)') -and $by.Contains('unmatched:Broken (2017)')) 'an empty, unmatched file is flagged'
Check (-not ($r.issues | Where-Object { $_.check -eq 'unmatched' -and $_.title -match 'Old agent|Show A' })) 'a title matched by an older agent (no IMDb/TMDB link, but genres and plot) is not unmatched'
Check ($by.Contains('wrongmatch:Glass')) 'folder year far from the Plex year'
Check ($by.Contains('gaps:Show A, Season 1') -and $by['gaps:Show A, Season 1'].detail -match 'E03') 'a missing episode in a season'
Check ($by.Contains('dupes:Good (2001)') -and $by['dupes:Good (2001)'].detail -match '2 copies') 'duplicate copies'
Check ($by.Contains('av1:Glass (2011)')) 'AV1'
Check ($r.important -eq 2 -and $r.issues[0].sev -eq 'important') 'important issues come first'
$r2 = Invoke-MmlmDoctor -Movies @($mv[0]) -Episodes $ep -Checks @('gaps', 'unreadable') -Previous $r
Check ($r2.fixedCount -gt 0 -and @($r2.skipped) -contains 'av1' -and @($r2.clean) -contains 'unreadable') 'compared with the previous report; skipped and clean checks'
$now = [datetime]'2026-11-12T09:00'
Check ((Get-MmlmDoctorSlot -Now $now -Freq weekly -Day 0 -Time '03:00') -eq [datetime]'2026-11-08T03:00') 'weekly slot: the last Sunday 3:00'
Check ((Get-MmlmDoctorSlot -Now $now -Freq monthly -Day 0 -Time '03:00') -eq [datetime]'2026-11-01T03:00') 'monthly slot: the first Sunday'
Check ((Test-MmlmDoctorDue -Now $now -Freq weekly -Day 0 -Time '03:00' -Last ([datetime]'2026-11-01T03:00')) -and -not (Test-MmlmDoctorDue -Now $now -Freq weekly -Day 0 -Time '03:00' -Last ([datetime]'2026-11-08T03:00'))) 'weekly: due once per slot'
Check (-not (Test-MmlmDoctorDue -Now $now -Freq biweekly -Day 0 -Time '03:00' -Last ([datetime]'2026-11-01T03:00'))) 'every 2 weeks: not due after one week'
Check ((Get-MmlmDoctorNext -Now $now -Freq monthly -Day 0 -Time '03:00' -Last ([datetime]'2026-11-01T03:00')) -eq [datetime]'2026-12-06T03:00') 'monthly: next is the first Sunday of next month'
Check (-not (Test-MmlmDoctorDue -Now $now -Freq off -Day 0 -Time '03:00' -Last ([datetime]'2026-11-01T03:00'))) 'off: never due'
"Done: $fail problem(s)."
exit ([int]($fail -gt 0))
