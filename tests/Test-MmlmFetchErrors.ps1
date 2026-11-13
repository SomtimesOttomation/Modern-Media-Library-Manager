# Fetch info: when TMDB or OMDb refuses or fails, the reason the service gave is kept and shown (Settings > Data >
# Traffic details), and OMDb's daily limit is told apart from a bad key (OMDb answers both with HTTP 401).
# Needs tests\api-mock.py on port 8098 (started here when it is not running).
# Run: pwsh -File tests\Test-MmlmFetchErrors.ps1
$root = Split-Path -Parent $PSScriptRoot
foreach ($m in 'MMLM.Library.psm1', 'MMLM.Fetch.psm1') { Import-Module (Join-Path $root "modules\$m") -DisableNameChecking -Force }
$fail = 0
function Check($ok, $what) { if ($ok) { "  ok    $what" } else { "  FAIL  $what"; $script:fail++ } }
try { $c = New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1', 8098); $c.Close() }
catch {
    $py = @('python3', 'python') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
    Start-Process -FilePath $py -ArgumentList ('"' + (Join-Path $PSScriptRoot 'api-mock.py') + '"') | Out-Null
    Start-Sleep -Seconds 1
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('mmlm-api-' + [guid]::NewGuid().ToString('N'))
$sync = [hashtable]::Synchronized(@{ Text = ''; Value = 0; Max = 0; Cancel = $false })
$ctx = @{ Sync = $sync; Traffic = [hashtable]::Synchronized(@{ Requests = 0; Bytes = 0; Errors = 0; Halted = $false }); AppData = $tmp; Culture = [Globalization.CultureInfo]::InvariantCulture }
Set-MmlmContext -Values $ctx; Set-MmlmFetchContext -Values $ctx
$base = 'http://127.0.0.1:8098'
function Try-Get([string]$Url) { try { [void](Invoke-MmlmJsonGet -Url $Url -TimeoutMs 5000); 'ok' } catch { [string]$_.Exception.Message } }
function Status { (Get-Content -Raw (Join-Path $tmp 'metadata/api-status.json') | ConvertFrom-Json) }

$m = Try-Get "$base/omdbapi.com/?how=limit"
Check ($m -eq 'OMDBLIMIT|OMDb|HTTP 401: Request limit reached!') "OMDb's daily limit is told apart from a bad key ($m)"
Check ((Status).OMDb.ok -eq $false -and (Status).OMDb.reason -eq 'HTTP 401: Request limit reached!') 'the reason is kept for Traffic details'
$m = Try-Get "$base/omdbapi.com/?how=badkey"
Check ($m -eq 'KEYREJECT|OMDb|HTTP 401: Invalid API key!') "a bad OMDb key says so ($m)"
$m = Try-Get "$base/omdbapi.com/?how=limit200"
Check ($m -like 'OMDBLIMIT|OMDb|*') 'OMDb reporting the limit inside a normal reply counts too'
$m = Try-Get "$base/omdbapi.com/?how=notfound"
Check ($m -eq 'ok' -and (Status).OMDb.ok) 'a movie OMDb does not know is not a failure'
$m = Try-Get "$base/themoviedb.org/3/movie/1?how=tmdbkey"
Check ($m -eq 'KEYREJECT|TMDB|HTTP 401: Invalid API key: You must be granted a valid key.') "TMDB's own message is shown ($m)"
$m = Try-Get "$base/themoviedb.org/3/movie/1?how=gone"
Check ($m -eq 'ok' -and (Status).TMDB.ok) 'not found (404) is an answer, not a failure'
$sw = [Diagnostics.Stopwatch]::StartNew()
$m = Try-Get "$base/omdbapi.com/?how=down"
Check ($m -eq 'OMDb did not answer: HTTP 503: Service Unavailable' -and (Status).OMDb.reason -eq 'HTTP 503: Service Unavailable') "a service that is down is retried, then named with its reason ($m, $([int]$sw.Elapsed.TotalSeconds) s)"
$m = Try-Get "$base/omdbapi.com/?how=fine"
$s = Status
Check ($s.OMDb.ok -and -not $s.OMDb.reason -and $s.OMDb.lastFail) 'working again: OK, and the last failure is still listed'
$m = Try-Get 'http://127.0.0.1:1/omdbapi.com/?how=x'
Check ($m -like 'OMDb did not answer: *' -and -not (Status).OMDb.ok) "no connection at all is a failure with the reason ($m)"

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
"Done: $fail problem(s)."
