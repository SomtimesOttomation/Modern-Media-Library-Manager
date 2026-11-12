#Requires -Version 5.1
<#
    MMLM.Doctor - PlexDoctor's check-up: reads the scanned libraries (the snapshots, as Plex last reported them) and lists
    what quietly went wrong. Read only: it never changes Plex, the files or the library data.

    A report: at, late, counts, issues (id, check, sev, title, detail, rid / show, firstSeen), clean (checks with nothing
    found), skipped (checks turned off), newCount / fixedCount against the previous report.
#>
Set-StrictMode -Version 2.0

$script:DoctorChecks = [ordered]@{
    unreadable = @{ Name = "Plex couldn't read the file"; Sev = 'important' }
    unmatched  = @{ Name = 'Not matched';                 Sev = 'important' }
    wrongmatch = @{ Name = 'Possible wrong match';        Sev = 'minor' }
    gaps       = @{ Name = 'Gaps in a season';            Sev = 'minor' }
    poster     = @{ Name = 'Missing poster';              Sev = 'minor' }
    dupes      = @{ Name = 'Duplicate copies';            Sev = 'minor' }
    av1        = @{ Name = "Won't play on Shield (AV1)";  Sev = 'minor' }
    subs       = @{ Name = 'No English subtitles';        Sev = 'minor' }
}
function Get-MmlmDoctorCheckIds { @($script:DoctorChecks.Keys) }

function Get-MmlmDoctorRid {
    param($r)
    if ([string]$r.PlexKey) { 'p:' + [string]$r.PlexKey } elseif ([string]$r.FullPath) { 'h:' + (Get-MmlmStringHash ([string]$r.FullPath)).Substring(0, 16) } else { '' }
}

function Invoke-MmlmDoctor {
    param([object[]]$Movies = @(), [object[]]$Episodes = @(), [string[]]$Checks, $Previous = $null, [string]$Late = '', [string[]]$Notes = @())
    $on = @{}; foreach ($c in $Checks) { $on[$c] = $true }
    $issues = New-Object System.Collections.Generic.List[object]
    $add = {
        param($check, $key, $title, $detail, $rid, $show)
        $issues.Add([ordered]@{ id = $check + '|' + $key; check = $check; sev = $script:DoctorChecks[$check].Sev; title = $title; detail = $detail; rid = $rid; show = $show; firstSeen = '' })
    }
    $label = { param($r) $(if ([int]$r.Year -gt 0) { '{0} ({1})' -f $r.Title, $r.Year } else { [string]$r.Title }) }
    $n = 0; $total = $Movies.Count + $Episodes.Count
    Set-MmlmProgress -Text 'PlexDoctor: checking movies...' -Value 0 -Max ([Math]::Max(1, $total))

    # ---- movies, one by one
    $dupe = @{}
    foreach ($r in $Movies) {
        $n++; if (($n % 500) -eq 0) { Set-MmlmProgress -Text ('PlexDoctor: movies {0} of {1}' -f $n, $Movies.Count) -Value $n -Max $total }
        $rid = Get-MmlmDoctorRid $r; $t = & $label $r
        if ($on['unreadable'] -and -not [string]$r.VideoCodec -and [double]$r.RuntimeMin -le 0) { & $add 'unreadable' $rid $t 'Plex found no video or audio in it, so it will not play.' $rid '' }
        # unmatched: no IMDb/TMDB link AND none of what a match brings (genres, a plot). Older agents (TheTVDB) leave no
        # IMDb/TMDB link on a matched title, so a missing link alone is not enough.
        if ($on['unmatched'] -and -not [string]$r.IMDBID -and -not [string]$r.TMDBID -and -not [string]$r.Genre -and -not [string]$r.Plot) { & $add 'unmatched' $rid $t 'Plex did not match it: no IMDb or TMDB link, no genres or plot.' $rid '' }
        if ($on['wrongmatch'] -and [int]$r.Year -gt 0) {
            $src = ([string]$r.Directory) + ' ' + ([string]$r.FileName)
            $m = [regex]::Matches($src, '[\(\[](19\d\d|20\d\d)[\)\]]')
            if ($m.Count -gt 0) {
                $fy = [int]$m[$m.Count - 1].Groups[1].Value
                if ([Math]::Abs($fy - [int]$r.Year) -gt 1) { & $add 'wrongmatch' $rid ([string]$r.Title) ('The folder says {0}, Plex says {1}.' -f $fy, $r.Year) $rid '' }
            }
        }
        if ($on['poster'] -and -not [string]$r.PlexThumb) { & $add 'poster' $rid $t 'No poster in Plex.' $rid '' }
        if ($on['av1'] -and [string]$r.VideoCodec -match 'av1|av01') { & $add 'av1' $rid $t ('AV1 {0}' -f [string]$r.ResolutionClass).Trim() $rid '' }
        if ($on['subs'] -and [string]$r.SubtitleLanguages -notmatch '(?i)\b(english|eng|en)\b') { & $add 'subs' $rid $t $(if ([int]$r.SubtitleTracks -gt 0) { 'Subtitles, but none in English: ' + [string]$r.SubtitleLanguages } else { 'No subtitles at all.' }) $rid '' }
        if ($on['dupes']) {
            $k = $(if ([string]$r.IMDBID) { 'i' + $r.IMDBID } elseif ([string]$r.TMDBID) { 't' + $r.TMDBID } else { 'n' + ((([string]$r.Title).ToLowerInvariant() -replace '[^a-z0-9]+', ' ').Trim()) + '|' + $r.Year })
            if (-not $dupe.ContainsKey($k)) { $dupe[$k] = New-Object System.Collections.Generic.List[object] }
            $dupe[$k].Add($r)
        }
    }
    if ($on['dupes']) {
        foreach ($k in $dupe.Keys) {
            $g = $dupe[$k]; if ($g.Count -lt 2) { continue }
            $copies = @($g | Sort-Object { [double]$_.FileSizeGB } -Descending | ForEach-Object { ('{0} {1:0.#} GB' -f ([string]$_.ResolutionClass), [double]$_.FileSizeGB).Trim() })
            $r0 = $g[0]; $rid0 = Get-MmlmDoctorRid $r0
            & $add 'dupes' $k (& $label $r0) ('{0} copies: {1}' -f $g.Count, ($copies -join ', ')) $rid0 ''
        }
    }

    # ---- TV, by show (one line per show, not per episode)
    $shows = [ordered]@{}
    foreach ($e in $Episodes) {
        $s = [string]$e.Show; if (-not $s) { continue }
        if (-not $shows.Contains($s)) { $shows[$s] = New-Object System.Collections.Generic.List[object] }
        $shows[$s].Add($e)
    }
    $si = 0
    foreach ($s in $shows.Keys) {
        $si++; if (($si % 50) -eq 0) { Set-MmlmProgress -Text ('PlexDoctor: shows {0} of {1}' -f $si, $shows.Count) -Value ($Movies.Count + [int]($Episodes.Count * $si / [Math]::Max(1, $shows.Count))) -Max $total }
        $eps = $shows[$s]
        if ($on['unreadable']) {
            $bad = @($eps | Where-Object { -not [string]$_.VideoCodec -and [double]$_.RuntimeMin -le 0 })
            if ($bad.Count) {
                $list = (@($bad | Select-Object -First 4 | ForEach-Object { 'S{0:00}E{1:00}' -f [int]$_.Season, [int]$_.Episode }) -join ', ') + $(if ($bad.Count -gt 4) { " and $($bad.Count - 4) more" } else { '' })
                & $add 'unreadable' ('s:' + $s) $s ($list + ': no video or audio in the file.') '' $s
            }
        }
        if ($on['unmatched'] -and -not @($eps | Where-Object { [string]$_.IMDBID -or [string]$_.TMDBID -or [string]$_.Genre -or [string]$_.Plot }).Count) { & $add 'unmatched' ('s:' + $s) $s 'Plex did not match the show: no IMDb or TMDB link, no genres or plot.' '' $s }
        if ($on['poster'] -and -not @($eps | Where-Object { [string]$_.PlexThumb }).Count) { & $add 'poster' ('s:' + $s) $s 'No show poster in Plex.' '' $s }
        if ($on['av1']) {
            $a = @($eps | Where-Object { [string]$_.VideoCodec -match 'av1|av01' }).Count
            if ($a) { & $add 'av1' ('s:' + $s) $s ('{0} of {1} episodes are AV1.' -f $a, $eps.Count) '' $s }
        }
        if ($on['subs']) {
            $ns = @($eps | Where-Object { [string]$_.SubtitleLanguages -notmatch '(?i)\b(english|eng|en)\b' }).Count
            if ($ns) { & $add 'subs' ('s:' + $s) $s ('{0} of {1} episodes have no English subtitles.' -f $ns, $eps.Count) '' $s }
        }
        if ($on['gaps']) {
            foreach ($grp in @($eps | Where-Object { [int]$_.Season -gt 0 -and [int]$_.Episode -gt 0 } | Group-Object { [int]$_.Season })) {
                $have = @{}; foreach ($e in $grp.Group) { $have[[int]$e.Episode] = $true }
                if ($have.Count -lt 2) { continue }
                $max = ($have.Keys | Measure-Object -Maximum).Maximum
                $miss = @(for ($x = 1; $x -le $max; $x++) { if (-not $have.ContainsKey($x)) { $x } })
                if ($miss.Count) {
                    $list = (($miss | Select-Object -First 6 | ForEach-Object { 'E{0:00}' -f $_ }) -join ', ') + $(if ($miss.Count -gt 6) { " and $($miss.Count - 6) more" } else { '' })
                    & $add 'gaps' ('s:' + $s + '|' + $grp.Name) ('{0}, Season {1}' -f $s, $grp.Name) ('Missing {0} (has {1} of {2}).' -f $list, $have.Count, $max) '' $s
                }
            }
        }
    }

    # ---- against the previous report: how long each issue has been there, what is new, what was fixed
    $prev = @{}
    if ($Previous -and $Previous.issues) { foreach ($p in @($Previous.issues)) { $prev[[string]$p.id] = $p } }
    $now = (Get-Date).ToString('yyyy-MM-dd')
    $newCount = 0
    foreach ($i in $issues) {
        $p = $prev[$i.id]
        if ($p) { $i.firstSeen = $(if ([string]$p.firstSeen) { [string]$p.firstSeen } else { $now }) } else { $i.firstSeen = $now; if ($Previous) { $newCount++ } }
    }
    $ids = @{}; foreach ($i in $issues) { $ids[$i.id] = $true }
    $fixed = 0; foreach ($k in $prev.Keys) { if (-not $ids.ContainsKey($k)) { $fixed++ } }
    $found = @{}; foreach ($i in $issues) { $found[$i.check] = $true }
    $names = [ordered]@{}; foreach ($k in $script:DoctorChecks.Keys) { $names[$k] = $script:DoctorChecks[$k].Name }
    $sevRank = @{ important = 0; minor = 1 }
    $order = @{}; $o = 0; foreach ($k in $script:DoctorChecks.Keys) { $order[$k] = $o++ }
    [ordered]@{
        at        = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
        late      = $Late
        notes     = @($Notes)
        counts    = [ordered]@{ movies = $Movies.Count; shows = $shows.Count; episodes = $Episodes.Count }
        issues    = @($issues | Sort-Object { $sevRank[$_.sev] }, { $order[$_.check] }, { $_.title })
        important = @($issues | Where-Object { $_.sev -eq 'important' }).Count
        minor     = @($issues | Where-Object { $_.sev -eq 'minor' }).Count
        clean     = @($script:DoctorChecks.Keys | Where-Object { $on[$_] -and -not $found[$_] })
        skipped   = @($script:DoctorChecks.Keys | Where-Object { -not $on[$_] })
        names     = $names
        compared  = [bool]$Previous
        newCount  = $newCount
        fixedCount = $(if ($Previous) { $fixed } else { 0 })
    }
}

# ---------------------------------------------------------------- the schedule
function Get-MmlmDoctorSlot {
    # The most recent scheduled time at or before $Now. Weekly and every 2 weeks: the chosen day each week; monthly: the
    # first such day of each month.
    param([datetime]$Now, [string]$Freq, [int]$Day, [string]$Time)
    $h = 3; $m = 0
    if ($Time -match '^(\d{1,2}):(\d{2})$') { $h = [int]$Matches[1]; $m = [int]$Matches[2] }
    if ($Freq -eq 'monthly') {
        foreach ($back in 0, 1) {
            $first = (New-Object DateTime ($Now.Year, $Now.Month, 1)).AddMonths(-$back)
            while ([int]$first.DayOfWeek -ne $Day) { $first = $first.AddDays(1) }
            $slot = $first.AddHours($h).AddMinutes($m)
            if ($slot -le $Now) { return $slot }
        }
    }
    $d = $Now.Date
    while ([int]$d.DayOfWeek -ne $Day) { $d = $d.AddDays(-1) }
    $slot = $d.AddHours($h).AddMinutes($m)
    if ($slot -gt $Now) { $slot = $slot.AddDays(-7) }
    $slot
}
function Get-MmlmDoctorNext {
    # The next scheduled time after the last one that ran ($Last), for the Settings line.
    param([datetime]$Now, [string]$Freq, [int]$Day, [string]$Time, $Last)
    $slot = Get-MmlmDoctorSlot -Now $Now -Freq $Freq -Day $Day -Time $Time
    switch ($Freq) {
        'monthly' { $nx = Get-MmlmDoctorSlot -Now ((New-Object DateTime ($Now.Year, $Now.Month, 1)).AddMonths(1).AddDays(7)) -Freq 'monthly' -Day $Day -Time $Time; if ($Last -and $slot -gt [datetime]$Last) { $slot } else { $nx } }
        'biweekly' { $nx = $slot.AddDays(7); if ($Last) { $due = ([datetime]$Last).AddDays(14); while ($nx -lt $due.AddHours(-12)) { $nx = $nx.AddDays(7) } }; $nx }
        default { if ($Last -and $slot -gt [datetime]$Last) { $slot } else { $slot.AddDays(7) } }
    }
}
function Test-MmlmDoctorDue {
    # Due when a scheduled time has passed since the last run (every 2 weeks: at least 13.5 days since it).
    param([datetime]$Now, [string]$Freq, [int]$Day, [string]$Time, $Last)
    if ($Freq -notin @('weekly', 'biweekly', 'monthly') -or -not $Last) { return $false }
    $slot = Get-MmlmDoctorSlot -Now $Now -Freq $Freq -Day $Day -Time $Time
    if ($Freq -eq 'biweekly') { return ($slot -gt [datetime]$Last -and $slot -ge ([datetime]$Last).AddDays(13.5)) }
    $slot -gt [datetime]$Last
}

Export-ModuleMember -Function @(
    'Get-MmlmDoctorCheckIds',
    'Invoke-MmlmDoctor',
    'Get-MmlmDoctorSlot',
    'Get-MmlmDoctorNext',
    'Test-MmlmDoctorDue'
)
