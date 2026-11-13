# MMLM.Fetch.psm1 - part of Modern Media Library Manager. No windows, no UI: safe to load in any runspace.
#   Online metadata: TMDB, OMDb and the IMDb ratings file (Fetch info).
# Rules (DashLauncher contract): imported by full path; every exported name carries 'Mmlm'; no global state;
# settings, cache and logs live under %LOCALAPPDATA%. Scripts stay ASCII-only for Windows PowerShell 5.1.
# Shared values (progress hashtable, folders, field list ...) arrive through Set-MmlmContextFetch.

Import-Module (Join-Path $PSScriptRoot 'MMLM.Library.psm1')        # shared helpers (an already loaded copy is reused)

function Set-MmlmFetchContext {
    # Copies the shared values (Sync, CacheFolder, Fields ...) into this module's scope.
    param([hashtable]$Values)
    foreach ($k in @($Values.Keys)) { Set-Variable -Scope Script -Name $k -Value $Values[$k] }
}

function Add-MmlmOmdbUse {
    # Counts OMDb requests per day (free keys allow about 1,000 a day) for Settings > Data > Traffic details.
    # Kept in <AppData>\metadata\omdb-usage.json: { "date": "yyyy-MM-dd", "count": n, "limitHit": false }.
    param([switch]$LimitHit)
    try {
        $f = Join-Path (Join-Path $script:AppData 'metadata') 'omdb-usage.json'
        $day = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
        $u = @{ date = $day; count = 0; limitHit = $false }
        if (Test-Path -LiteralPath $f) { $o = [IO.File]::ReadAllText($f) | ConvertFrom-Json; if ([string]$o.date -eq $day) { $u.count = [int]$o.count; $u.limitHit = [bool]$o.limitHit } }
        if ($LimitHit) { $u.limitHit = $true } else { $u.count++ }
        $dir = Split-Path -Parent $f; if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllText($f, (ConvertTo-Json -InputObject $u -Compress))
    } catch { }
}

function Invoke-MmlmJsonGet {
    # One polite GET. $null for 404; waits and retries on 429 / 5xx; throws 'KEYREJECT' when the service refuses the key.
    param([string]$Url, [hashtable]$Headers = @{}, [int]$TimeoutMs = 20000)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    for ($try = 1; $try -le 4; $try++) {
        if (Test-MmlmScanCancelled) { return $null }
        Assert-MmlmTrafficAllowed
        try {
            $req = [Net.HttpWebRequest]::Create($Url)
            $req.Method = 'GET'; $req.Timeout = $TimeoutMs; $req.ReadWriteTimeout = $TimeoutMs
            $req.UserAgent = 'ModernMediaLibraryManager/1.0'; $req.Accept = 'application/json'
            foreach ($k in $Headers.Keys) { $req.Headers[$k] = [string]$Headers[$k] }
            $resp = $req.GetResponse()
            try {
                $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
                try { $txt = $sr.ReadToEnd() } finally { $sr.Dispose() }
            }
            finally { $resp.Close() }
            Add-MmlmTraffic -Bytes $txt.Length
            return ($txt | ConvertFrom-Json)
        }
        catch [Net.WebException] {
            Add-MmlmTraffic -Failed
            $r    = $_.Exception.Response
            $code = if ($null -ne $r) { [int]$r.StatusCode } else { 0 }
            if ($code -eq 404) { return $null }
            if ($code -eq 401 -or $code -eq 403) { throw 'KEYREJECT' }
            if ($try -ge 4) { throw }
            $wait = 2 * $try
            if ($code -eq 429 -and $null -ne $r) {
                $ra = 0; if ([int]::TryParse([string]$r.Headers['Retry-After'], [ref]$ra) -and $ra -gt 0) { $wait = [Math]::Min(30, $ra) }
            }
            Start-Sleep -Seconds $wait
        }
    }
}

function Get-MmlmImdbRatingMap {
    # IMDb publishes daily rating files for personal, non-commercial use. Download once a week, keep only the ids we need.
    param([string]$DataFolder, $Wanted)
    $map = @{}
    if (-not (Test-Path -LiteralPath $DataFolder)) { New-Item -Path $DataFolder -ItemType Directory -Force | Out-Null }
    $gz = Join-Path $DataFolder 'title.ratings.tsv.gz'
    $stale = (-not (Test-Path -LiteralPath $gz)) -or (((Get-Date) - (Get-Item -LiteralPath $gz).LastWriteTime).TotalDays -gt 7)
    if ($stale) {
        Set-MmlmProgress -Text 'Downloading IMDb ratings (refreshed weekly)...'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $wc = New-Object Net.WebClient
        try {
            $wc.Headers['User-Agent'] = 'ModernMediaLibraryManager/1.0'
            Assert-MmlmTrafficAllowed
            $wc.DownloadFile('https://datasets.imdbws.com/title.ratings.tsv.gz', $gz + '.tmp')
            try { Add-MmlmTraffic -Bytes (Get-Item -LiteralPath ($gz + '.tmp')).Length } catch { }
            Move-Item -LiteralPath ($gz + '.tmp') -Destination $gz -Force
        }
        catch { Remove-Item -LiteralPath ($gz + '.tmp') -Force -ErrorAction SilentlyContinue }
        finally { $wc.Dispose() }
    }
    if (-not (Test-Path -LiteralPath $gz)) { return $map }
    Set-MmlmProgress -Text 'Reading IMDb ratings...'
    $fs = [IO.File]::OpenRead($gz)
    $gs = New-Object IO.Compression.GZipStream($fs, [IO.Compression.CompressionMode]::Decompress)
    $sr = New-Object IO.StreamReader($gs)
    try {
        [void]$sr.ReadLine()
        $n = 0
        while ($null -ne ($line = $sr.ReadLine())) {
            $n++
            if (($n % 200000) -eq 0 -and (Test-MmlmScanCancelled)) { break }
            $tab = $line.IndexOf("`t")
            if ($tab -lt 1) { continue }
            $id = $line.Substring(0, $tab)
            if ($Wanted.Contains($id)) {
                $p = $line.Split("`t")
                $map[$id] = @{ Rating = (ConvertTo-MmlmSafeDouble $p[1]); Votes = (ConvertTo-MmlmSafeInt $p[2]) }
            }
        }
    }
    finally { $sr.Dispose(); $gs.Dispose(); $fs.Dispose() }
    $map
}

function Add-MmlmFetchDetail {
    # Remembers why one title did not get fetched, for the "Details" link in the status bar.
    param($Rec, [string]$Kind, [string]$Reason)
    if ($null -eq $script:Sync.Details) { return }
    $yr = if ([int]$Rec.Year -gt 0) { ' (' + [int]$Rec.Year + ')' } else { '' }
    [void]$script:Sync.Details.Add(('{0}{1}  [{2}]{3}    {4}' -f [string]$Rec.Title, $yr, $Kind, "`
`
", $Reason))
}

function Get-MmlmTitleKey {
    # Normalises a title for comparing: lower case, accents and punctuation gone, "&" = "and", leading "the" and a trailing "(year)" dropped.
    param([string]$Title)
    $t = ([string]$Title).Normalize([Text.NormalizationForm]::FormD)
    $t = [regex]::Replace($t, '\p{Mn}', '')
    $t = $t.ToLowerInvariant() -replace '\s*\(\d{4}\)\s*$', '' -replace '&', ' and '
    $t = ($t -replace "[^a-z0-9 ]", ' ') -replace '\s+', ' '
    $t = $t.Trim() -replace '^(the|a|an) ', ''
    return $t
}

function Find-MmlmTmdbMovieId {
    # Looks a movie up by title (and year) when no ID is known. Tries the exact year, then a looser search, and scores the candidates
    # so a well-known title is not lost to a year that is off by one or a title with different punctuation.
    param([string]$Title, [int]$Year, [string]$KeyQuery, [hashtable]$Headers)
    $want = Get-MmlmTitleKey $Title
    if (-not $want) { return '' }
    $plain = ([string]$Title) -replace '\s*\(\d{4}\)\s*$', ''
    $queries = New-Object System.Collections.Generic.List[string]
    $base = 'https://api.themoviedb.org/3/search/movie?query=' + [Uri]::EscapeDataString($plain) + '&include_adult=false'
    if ($Year -gt 0) { $queries.Add($base + '&year=' + $Year) }
    $queries.Add($base)
    if ($plain -match '^(.+?)\s*[:\-]\s+.+$') { $queries.Add('https://api.themoviedb.org/3/search/movie?query=' + [Uri]::EscapeDataString($Matches[1]) + '&include_adult=false') }
    $best = $null; $bestScore = 0
    foreach ($qq in $queries) {
        $f = Invoke-MmlmJsonGet -Url ($qq + $KeyQuery) -Headers $Headers
        Start-Sleep -Milliseconds 250
        if (-not $f) { continue }
        foreach ($h in @($f.results)) {
            $score = 0
            $names = @((Get-MmlmTitleKey ([string]$h.title)), (Get-MmlmTitleKey ([string]$h.original_title)))
            if ($names -contains $want) { $score += 100 }
            elseif ($names | Where-Object { $_ -and ($_.StartsWith($want) -or $want.StartsWith($_)) }) { $score += 40 }
            else { continue }
            $hy = 0
            if ($h.release_date -and ([string]$h.release_date).Length -ge 4) { $hy = [int]([string]$h.release_date).Substring(0, 4) }
            if ($Year -gt 0 -and $hy -gt 0) {
                $d = [Math]::Abs($hy - $Year)
                if ($d -eq 0) { $score += 50 } elseif ($d -eq 1) { $score += 35 } elseif ($d -le 3) { $score += 10 } else { $score -= 40 }
            }
            $score += [Math]::Min(10, [Math]::Log10(1 + [double]$h.vote_count) * 2.5)
            if ($score -gt $bestScore) { $bestScore = $score; $best = $h }
        }
        if ($bestScore -ge 150) { break }                  # exact title and year: no need to widen the search
    }
    if ($best -and $bestScore -ge 60) { return [string]$best.id }
    return ''
}

function Invoke-MmlmShowStatusFetch {
    # TV Shows > Fetch info: whether each show is still running, from TMDB (your key). One request per show, using the show's
    # TMDB id from Plex, or a title + year search when Plex has none. Saved in $StorePath (show name -> status), which the
    # page reads; shows already known as ended are skipped unless -Overwrite (an ended show does not come back often).
    param([object[]]$Records, [int[]]$Indexes, [string]$TmdbKey, [string]$StorePath, [bool]$Overwrite)
    $headers = @{}; $keyQ = ''
    if ($TmdbKey.Length -gt 60) { $headers['Authorization'] = 'Bearer ' + $TmdbKey } else { $keyQ = '&api_key=' + [Uri]::EscapeDataString($TmdbKey) }
    $store = [ordered]@{}
    if (Test-Path -LiteralPath $StorePath) {
        try { $o = Get-Content -LiteralPath $StorePath -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($p in $o.PSObject.Properties) { $store[$p.Name] = $p.Value } } catch { }
    }
    $shows = [ordered]@{}
    foreach ($i in $Indexes) {
        $r = $Records[$i]; $name = [string]$r.Show
        if (-not $name -or $shows.Contains($name)) { continue }
        $shows[$name] = @{ Tmdb = [string]$r.TMDBID; Year = [int]$r.Year }
    }
    $done = 0; $ended = 0; $going = 0; $miss = 0; $n = 0
    foreach ($name in @($shows.Keys)) {
        if (Test-MmlmScanCancelled) { break }
        $n++
        Set-MmlmProgress -Text ('Show status {0} of {1}: {2}' -f $n, $shows.Count, $name) -Value $n -Max $shows.Count
        $old = $store[$name]
        if (-not $Overwrite -and $null -ne $old -and [string]$old.state -eq 'Ended') { continue }
        $id = $shows[$name].Tmdb
        if (-not $id) {
            $q = 'https://api.themoviedb.org/3/search/tv?query=' + [Uri]::EscapeDataString(($name -replace '\s*\(\d{4}\)\s*$', '')) + '&include_adult=false'
            $f = Invoke-MmlmJsonGet -Url ($q + $keyQ) -Headers $headers
            Start-Sleep -Milliseconds 250
            $want = Get-MmlmTitleKey $name
            $hit = @($f.results) | Where-Object { (Get-MmlmTitleKey ([string]$_.name)) -eq $want -or (Get-MmlmTitleKey ([string]$_.original_name)) -eq $want } | Select-Object -First 1
            if ($hit) { $id = [string]$hit.id }
        }
        if (-not $id) { $miss++; continue }
        $d = Invoke-MmlmJsonGet -Url ('https://api.themoviedb.org/3/tv/' + $id + '?language=en-US' + $keyQ) -Headers $headers
        Start-Sleep -Milliseconds 250
        if (-not $d -or -not [string]$d.status) { $miss++; continue }
        $st = [string]$d.status                                   # Returning Series, In Production, Planned, Pilot, Ended, Canceled
        $state = $(if ($st -eq 'Ended' -or $st -eq 'Canceled') { 'Ended' } else { 'Ongoing' })
        if ($state -eq 'Ended') { $ended++ } else { $going++ }
        $store[$name] = [ordered]@{ state = $state; tmdb = $st; lastAir = [string]$d.last_air_date; tmdbId = $id; at = (Get-Date).ToString('yyyy-MM-dd') }
        $done++
        if (($done % 20) -eq 0) { $store | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StorePath -Encoding UTF8 }
    }
    $store | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StorePath -Encoding UTF8
    ('Show status: {0} looked up ({1} ongoing, {2} ended){3}.' -f $done, $going, $ended, $(if ($miss) { ", $miss not found on TMDB" } else { '' }))
}

function Invoke-MmlmMetadataScrape {
    # Fills Year, Genre, certification, rating, studio, director, Rotten Tomatoes critic score and box office for the given titles.
    param([object[]]$Records, [int[]]$Indexes, [string]$TmdbKey, [string]$OmdbKey, [bool]$Overwrite, [string]$DataFolder, [string]$StorePath)

    $script:Sync.Total = $Indexes.Count
    foreach ($r in $Records) { [void]$script:Sync.Partial.Add($r) }      # so an abandoned run still returns every title
    $targets = @($Indexes | ForEach-Object { $Records[$_] } | Where-Object { -not [string]$_.Show })
    $skippedTv = $Indexes.Count - $targets.Count
    if ($targets.Count -eq 0) { $script:Sync.Summary = 'Nothing to fetch: only movies are supported for now (TV titles were skipped).'; return }

    $wanted = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($t in $targets) { if ($t.IMDBID) { [void]$wanted.Add([string]$t.IMDBID) } }
    Set-MmlmScanPhase -Lo 0.0 -Hi 0.1
    $imdb = Get-MmlmImdbRatingMap -DataFolder $DataFolder -Wanted $wanted

    $headers = @{}; $keyQ = ''
    if ($TmdbKey.Length -gt 60) { $headers['Authorization'] = 'Bearer ' + $TmdbKey } else { $keyQ = '&api_key=' + [Uri]::EscapeDataString($TmdbKey) }
    $store = Read-MmlmMetaStore -Path $StorePath
    $stats = @{ Done = 0; Found = 0; Missing = 0; Failed = 0 }
    $tmdbOff = (-not $TmdbKey); $omdbOff = (-not $OmdbKey); $omdbLimit = $false; $keyBad = ''
    Set-MmlmScanPhase -Lo 0.1 -Hi 1.0
    $i = 0
    foreach ($rec in $targets) {
        if (Test-MmlmScanCancelled) { break }
        $i++
        Set-MmlmProgress -Text ('Fetching info {0} of {1}: {2}' -f $i, $targets.Count, $rec.Title) -Value $i -Max $targets.Count
        $keys  = Get-MmlmMetaKeys $rec
        $entry = $null
        foreach ($k in $keys) { if ($store.ContainsKey($k)) { $entry = $store[$k]; break } }
        if ($null -eq $entry) { $entry = @{ Manual = @{}; Scraped = @{}; Force = @(); Sources = @{}; At = '' } }
        $got = @{}                                   # field -> @{ Value; Source }
        $imdbId = [string]$rec.IMDBID
        try {
            # ---- TMDB ---------------------------------------------------------------
            if (-not $tmdbOff) {
                $tid = [string]$rec.TMDBID
                if (-not $tid -and $imdbId) {
                    $f = Invoke-MmlmJsonGet -Url ('https://api.themoviedb.org/3/find/' + $imdbId + '?external_source=imdb_id' + $keyQ) -Headers $headers
                    Start-Sleep -Milliseconds 250
                    if ($f -and @($f.movie_results).Count -gt 0) { $tid = [string]@($f.movie_results)[0].id }
                }
                if (-not $tid) { $tid = Find-MmlmTmdbMovieId -Title ([string]$rec.Title) -Year ([int]$rec.Year) -KeyQuery $keyQ -Headers $headers }
                if ($tid) {
                    $d = Invoke-MmlmJsonGet -Url ('https://api.themoviedb.org/3/movie/' + $tid + '?append_to_response=credits,release_dates' + $keyQ) -Headers $headers
                    Start-Sleep -Milliseconds 250
                    if ($d) {
                        if (-not $imdbId -and $d.imdb_id) { $imdbId = [string]$d.imdb_id }
                        if ($d.release_date -and ([string]$d.release_date).Length -ge 4) { $got['Year'] = @{ Value = [int]([string]$d.release_date).Substring(0, 4); Source = 'TMDB' } }
                        $g = @($d.genres | ForEach-Object { $_.name } | Where-Object { $_ })
                        if ($g.Count -gt 0) { $got['Genre'] = @{ Value = ($g -join '; '); Source = 'TMDB' } }
                        $co = @($d.production_companies | ForEach-Object { $_.name } | Where-Object { $_ }) | Select-Object -First 1
                        if ($co) { $got['Studio'] = @{ Value = [string]$co; Source = 'TMDB' } }
                        $dir = @($d.credits.crew | Where-Object { $_.job -eq 'Director' } | ForEach-Object { $_.name } | Select-Object -Unique)
                        if ($dir.Count -gt 0) { $got['Director'] = @{ Value = ($dir -join '; '); Source = 'TMDB' } }
                        $us = @($d.release_dates.results | Where-Object { $_.iso_3166_1 -eq 'US' }) | Select-Object -First 1
                        if ($us) {
                            $c = @($us.release_dates | Where-Object { $_.certification } | Sort-Object { if ($_.type -eq 3) { 0 } else { 1 } })
                            if ($c.Count -gt 0) { $got['MPAARating'] = @{ Value = [string]$c[0].certification; Source = 'TMDB' } }
                        }
                        if ([double]$d.revenue -gt 0) { $got['BoxOfficeWorldwide'] = @{ Value = [double]$d.revenue; Source = 'TMDB' } }
                        if ([double]$d.vote_average -gt 0) { $got['Rating'] = @{ Value = [Math]::Round([double]$d.vote_average, 1); Source = 'TMDB' }; $got['Votes'] = @{ Value = [int]$d.vote_count; Source = 'TMDB' } }
                        if (-not $rec.TMDBID) { $got['TMDBID'] = @{ Value = $tid; Source = 'TMDB' } }
                    }
                }
            }
            if ($imdbId -and -not $rec.IMDBID) { $got['IMDBID'] = @{ Value = $imdbId; Source = 'TMDB' } }

            # ---- IMDb ratings file (beats TMDB's own score) --------------------------------
            if ($imdbId -and $imdb.ContainsKey($imdbId)) {
                $m = $imdb[$imdbId]
                if ($m.Rating -gt 0) { $got['Rating'] = @{ Value = [double]$m.Rating; Source = 'IMDb' }; $got['Votes'] = @{ Value = [int]$m.Votes; Source = 'IMDb' } }
            }

            # ---- OMDb: Rotten Tomatoes critic score, Metacritic Metascore, domestic box office ---------------------
            if (-not $omdbOff -and -not $omdbLimit -and $imdbId) {
                $o = Invoke-MmlmJsonGet -Url ('https://www.omdbapi.com/?apikey=' + [Uri]::EscapeDataString($OmdbKey) + '&i=' + $imdbId)
                Add-MmlmOmdbUse
                if ($o) {
                    if ($o.Response -eq 'False' -and ([string]$o.Error) -match 'limit') { $omdbLimit = $true; Add-MmlmOmdbUse -LimitHit }
                    elseif ($o.Response -eq 'True') {
                        $rt = @($o.Ratings | Where-Object { $_.Source -eq 'Rotten Tomatoes' }) | Select-Object -First 1
                        if ($rt -and ([string]$rt.Value) -match '^(\d+)%') { $got['RTCritic'] = @{ Value = [int]$Matches[1]; Source = 'OMDb' } }
                        if (([string]$o.Metascore) -match '^\d+$' -and [int]$o.Metascore -gt 0) { $got['Metascore'] = @{ Value = [int]$o.Metascore; Source = 'OMDb' } }
                        $bo = [string]$o.BoxOffice
                        if ($bo -match '^\$([\d,]+)$') { $got['BoxOfficeDomestic'] = @{ Value = [double]($Matches[1] -replace ',', ''); Source = 'OMDb' } }
                    }
                }
            }
        }
        catch {
            if ($_.Exception.Message -eq 'KEYREJECT') { $keyBad = 'An API key was rejected - check the keys under the gear button.'; Add-MmlmFetchDetail $rec 'Failed' 'A service rejected the API key (HTTP 401/403). Check the TMDB and OMDb keys under the gear button.'; break }
            $why = [string]$_.Exception.Message
            $inner = $_.Exception.InnerException
            if ($null -ne $inner -and $inner.Message -and $why -notmatch [regex]::Escape($inner.Message)) { $why += ' / ' + $inner.Message }
            Add-MmlmFetchDetail $rec 'Failed' ('Error while looking it up: ' + $why)
            $stats.Failed++; continue
        }

        # ---- apply: manual values always win; empty fields are filled; Replace ticked => overwrite ----
        $changed = $false
        foreach ($name in @($got.Keys)) {
            if ($entry.Manual.ContainsKey($name)) { continue }
            $f = $script:Fields | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if ($null -eq $f) { continue }
            $v = $got[$name].Value
            $cur = $rec.$name
            if ((Test-MmlmValueEmpty $cur) -or ($Overwrite -and "$cur" -ne "$v")) {
                Set-MmlmRecField $rec $name ([Convert]::ChangeType($v, $script:TypeMap[$f.Type]))
                if ($name -eq 'Rating') { Set-MmlmRecField $rec 'RatingSource' ([string]$got[$name].Source) }
                $changed = $true
            }
            $entry.Scraped[$name] = $v
            $entry.Sources[$name] = $got[$name].Source
            if ($Overwrite -and $entry.Force -notcontains $name) { $entry.Force = @($entry.Force) + $name }
        }
        if ($got.Count -gt 0) {
            $entry.At = (Get-Date).ToString('yyyy-MM-dd')
            foreach ($k in (Get-MmlmMetaKeys $rec)) { $store[$k] = $entry }
            $stats.Found++
        }
        else {
            $stats.Missing++
            $why = if ($tmdbOff) { 'No TMDB key is set, so nothing could be looked up (add one under the gear button).' }
                   elseif ($tid) { 'TMDB found the movie (id ' + $tid + ') but returned no usable fields.' }
                   elseif ($imdbId) { 'TMDB has no movie for IMDb id ' + $imdbId + ', and a search by title found no close match.' }
                   else { 'No IMDb/TMDB id on this title, and a TMDB search for "' + [string]$rec.Title + '"' + $(if ([int]$rec.Year -gt 0) { ' (' + [int]$rec.Year + ')' } else { '' }) + ' found no close match.' }
            Add-MmlmFetchDetail $rec 'Not found' $why
        }
        if ($changed) { $notes = @($entry.Sources.Keys | Sort-Object | ForEach-Object { '{0}: {1}' -f $_, $entry.Sources[$_] }); Set-MmlmRecField $rec 'MetaSources' ($notes -join '; ') }
        $stats.Done++
        if (($i % 25) -eq 0) { try { Write-MmlmMetaStore -Path $StorePath -Store $store } catch { } }
    }
    try { Write-MmlmMetaStore -Path $StorePath -Store $store } catch { }

    $sum = 'Fetched info for {0} of {1} title(s)' -f $stats.Found, $targets.Count
    if ($stats.Missing -gt 0) { $sum += ", $($stats.Missing) not found" }
    if ($stats.Failed  -gt 0) { $sum += ", $($stats.Failed) failed" }
    if ($skippedTv     -gt 0) { $sum += ", $skippedTv TV title(s) skipped" }
    $sum += '.'
    if ($omdbLimit) { $sum += ' OMDb daily limit reached - run again tomorrow for the rest.' }
    if ($keyBad)    { $sum += ' ' + $keyBad }
    if ($tmdbOff)   { $sum += ' (No TMDB key set.)' }
    $script:Sync.Summary = $sum
}

Export-ModuleMember -Function @(
    'Set-MmlmFetchContext',
    'Invoke-MmlmJsonGet',
    'Get-MmlmImdbRatingMap',
    'Add-MmlmFetchDetail',
    'Get-MmlmTitleKey',
    'Find-MmlmTmdbMovieId',
    'Invoke-MmlmMetadataScrape',
    'Invoke-MmlmShowStatusFetch'
)
