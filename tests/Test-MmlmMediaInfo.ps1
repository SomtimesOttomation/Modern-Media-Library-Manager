# MediaInfo brightness (Compare): finding the program, reading MaxCLL / MaxFALL, mapping server paths, and the saved
# results (only new or changed files are read again). Uses a stand-in MediaInfo: a small script that answers like the
# real command-line program, reading the "brightness" from the test file's own text.
# Run: pwsh -File tests\Test-MmlmMediaInfo.ps1
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'modules\MMLM.MediaInfo.psm1') -DisableNameChecking -Force
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('mmlm-mi-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$fail = 0
function Check($ok, $what) { if ($ok) { "  ok    $what" } else { "  FAIL  $what"; $script:fail++ } }

# the stand-in: "--Version" gives a version line; otherwise it prints the last argument's file content (or fails)
$onWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'
if ($onWindows) {
    $cli = Join-Path $tmp 'mediainfo.cmd'
    [IO.File]::WriteAllText($cli, "@echo off`r`nif ""%~1""==""--Version"" (echo MediaInfo Command line,& echo MediaInfoLib - v24.06& exit /b 0)`r`nif not exist ""%~2"" (echo Unable to open %2 1>&2& exit /b 1)`r`ntype ""%~2""`r`n")
}
else {
    $cli = Join-Path $tmp 'mediainfo'
    [IO.File]::WriteAllText($cli, "#!/bin/sh`nif [ ""`$1"" = ""--Version"" ]; then printf 'MediaInfo Command line,\nMediaInfoLib - v24.06\n'; exit 0; fi`nfor a; do f=""`$a""; done`n[ -f ""`$f"" ] || { echo ""Unable to open `$f"" >&2; exit 1; }`ncat ""`$f""`n")
    & chmod +x $cli
}

Check ((Find-MmlmMediaInfoCli -Custom $cli -AppRoot $tmp) -eq (Resolve-Path $cli).ProviderPath) 'a MediaInfo location set by hand is used'
$found = Find-MmlmMediaInfoCli -Custom (Join-Path $tmp 'nope.exe') -AppRoot (Join-Path $tmp 'app')
$onPath = "$(Get-Command mediainfo -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)"
Check ([string]$found -ceq $onPath) "a wrong location falls back to the PATH, nothing is downloaded ([$found] vs [$onPath])"
Check ((Get-MmlmMediaInfoVersion $cli) -eq '24.06') 'the version is read'

$movies = Join-Path $tmp 'Movies'; New-Item -ItemType Directory -Path $movies | Out-Null
$f1 = Join-Path $movies 'Bright One (2020).mkv'; [IO.File]::WriteAllText($f1, "1000 cd/m2|400 cd/m2`n")
$f2 = Join-Path $movies 'Plain SDR (1999).mkv'; [IO.File]::WriteAllText($f2, "|`n")
$f3 = Join-Path $movies 'Odd.mkv'; [IO.File]::WriteAllText($f3, "4000.6 cd/m2 (measured)|1201 cd/m2`nsecond stream|`n")
$b = Read-MmlmBrightness -Cli $cli -Path $f1
Check ($b.Cll -eq 1000 -and $b.Fall -eq 400) 'MaxCLL and MaxFALL are read: 1000 and 400'
$b = Read-MmlmBrightness -Cli $cli -Path $f2
Check ($b.Cll -eq 0 -and $b.Fall -eq 0) 'a file with no brightness gives 0 (no winner on that row)'
$b = Read-MmlmBrightness -Cli $cli -Path $f3
Check ($b.Cll -eq 4001 -and $b.Fall -eq 1201) 'decimals are rounded and only the first video stream counts'
$err = ''; try { [void](Read-MmlmBrightness -Cli $cli -Path (Join-Path $tmp 'missing.mkv')) } catch { $err = $_.Exception.Message }
Check ($err -like 'MediaInfo could not read the file*') "an unreadable file is an error ($err)"

# server path -> this PC
Check ((Resolve-MmlmLocalPath '/data/movies/A (2020)/A.mkv' '/data/movies' '\\NAS\movies') -eq '\\NAS\movies\A (2020)\A.mkv') 'a Linux server path maps to a network share'
Check ((Resolve-MmlmLocalPath '/DATA/movies/A.mkv' '/data/movies' 'M:\') -eq 'M:\\A.mkv' -or (Resolve-MmlmLocalPath '/DATA/movies/A.mkv' '/data/movies' 'M:') -eq 'M:\A.mkv') 'the prefix matches without regard to case'
Check ((Resolve-MmlmLocalPath 'D:\Movies\A.mkv' 'D:\Movies' '\\PLEXPC\Movies') -eq '\\PLEXPC\Movies\A.mkv') 'a Windows server path maps to that PC''s share'
Check ((Resolve-MmlmLocalPath 'C:\Films\A.mkv' '' '') -eq 'C:\Films\A.mkv') 'with no map the path is used as it is'
Check ((Resolve-MmlmLocalPath '/other/A.mkv' '/data/movies' 'M:') -eq '/other/A.mkv') 'a path outside the mapped folder is left alone'

# reading the library: saved results, unchanged files skipped, unreachable files noted
$store = Join-Path $tmp 'Library\mediainfo-movies.json'
$srv = '/srv/films'
$titles = @(@{ Key = 'p:1'; Path = "$srv/Bright One (2020).mkv" }, @{ Key = 'p:2'; Path = "$srv/Plain SDR (1999).mkv" }, @{ Key = 'p:3'; Path = "$srv/Gone.mkv" })
$sync = [hashtable]::Synchronized(@{ Text = ''; Value = 0; Max = 0; Cancel = $false })
$r = Update-MmlmBrightness -Cli $cli -Titles $titles -StoreFile $store -MapFrom $srv -MapTo $movies -Sync $sync
Check ($r.Read -eq 2 -and $r.Unreachable -eq 1 -and $r.Skipped -eq 0 -and $sync.Text -eq 'MediaInfo: 3 of 3') "first read: 2 read, 1 not reachable ($($r.Read)/$($r.Unreachable)/$($r.Skipped))"
$s = Read-MmlmBrightnessStore $store
Check ($s['p:1'].cll -eq 1000 -and $s['p:1'].fall -eq 400 -and $s['p:2'].cll -eq 0 -and $s['p:3'].err -eq 'unreachable') 'the results are saved per title'
$r = Update-MmlmBrightness -Cli $cli -Titles $titles -StoreFile $store -MapFrom $srv -MapTo $movies
Check ($r.Read -eq 0 -and $r.Skipped -eq 2) 'a second read skips files that have not changed'
[IO.File]::WriteAllText($f1, "1500 cd/m2|500 cd/m2`n")
$r = Update-MmlmBrightness -Cli $cli -Titles $titles -StoreFile $store -MapFrom $srv -MapTo $movies
Check ($r.Read -eq 1 -and (Read-MmlmBrightnessStore $store)['p:1'].cll -eq 1500) 'a changed file is read again'
$r = Update-MmlmBrightness -Cli $cli -Titles $titles -StoreFile $store -MapFrom $srv -MapTo $movies -Force
Check ($r.Read -eq 2) '"Read every file again" reads them all'
$sync.Cancel = $true
$r = Update-MmlmBrightness -Cli $cli -Titles $titles -StoreFile $store -MapFrom $srv -MapTo $movies -Force -Sync $sync
Check ($r.Read -eq 0) 'Stop ends the read'

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
"Done: $fail problem(s)."
