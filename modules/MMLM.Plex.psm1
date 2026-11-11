# MMLM.Plex.psm1 - part of Modern Media Library Manager. No windows, no UI: safe to load in any runspace.
#   Plex: requests, library listing, metadata, posters, record conversion and the Plex scan.
# Rules (DashLauncher contract): imported by full path; every exported name carries 'Mmlm'; no global state;
# settings, cache and logs live under %LOCALAPPDATA%. Scripts stay ASCII-only for Windows PowerShell 5.1.
# Shared values (progress hashtable, folders, field list ...) arrive through Set-MmlmContextPlex.

Import-Module (Join-Path $PSScriptRoot 'MMLM.Library.psm1')        # shared helpers (an already loaded copy is reused)

function Set-MmlmPlexContext {
    # Copies the shared values (Sync, CacheFolder, Fields ...) into this module's scope.
    param([hashtable]$Values)
    foreach ($k in @($Values.Keys)) { Set-Variable -Scope Script -Name $k -Value $Values[$k] }
}

function New-MmlmPlexRequest {
    param([string]$BaseUrl, [string]$Path, [hashtable]$Query = @{}, [string]$Token, [string]$Accept = 'application/xml')
    $parts = @()
    foreach ($k in $Query.Keys) { $parts += ('{0}={1}' -f [Uri]::EscapeDataString([string]$k), [Uri]::EscapeDataString([string]$Query[$k])) }
    $url = $BaseUrl.TrimEnd('/') + $Path
    if ($parts.Count -gt 0) { $url += '?' + ($parts -join '&') }

    $req = [Net.HttpWebRequest]::Create($url)
    $req.Method           = 'GET'
    $req.Timeout          = $script:PlexTimeoutMs
    $req.ReadWriteTimeout = $script:PlexTimeoutMs
    $req.Accept           = $Accept
    $req.Headers.Add('X-Plex-Token', $Token)                       # header, not query string, so it never lands in a URL log
    $req.Headers.Add('X-Plex-Client-Identifier', $script:PlexClientId)
    $req.Headers.Add('X-Plex-Product', 'Modern Media Library Manager')
    $req
}

function Protect-MmlmPlexToken {
    # DPAPI: only this Windows user, on this computer, can decrypt the result.
    param([string]$Plain)
    if ([string]::IsNullOrEmpty($Plain)) { return '' }
    ConvertFrom-SecureString -SecureString (ConvertTo-SecureString -String $Plain -AsPlainText -Force)
}

function Unprotect-MmlmPlexToken {
    param([string]$Protected)
    if ([string]::IsNullOrEmpty($Protected)) { return '' }
    try {
        $sec  = ConvertTo-SecureString -String $Protected -ErrorAction Stop
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    catch { '' }
}

function Get-MmlmPlexXml {
    param([string]$BaseUrl, [string]$Path, [hashtable]$Query = @{}, [string]$Token)
    Assert-MmlmTrafficAllowed
    $req  = New-MmlmPlexRequest -BaseUrl $BaseUrl -Path $Path -Query $Query -Token $Token
    $resp = $null
    $text = ''
    try {
        $resp = $req.GetResponse()
        $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        try { $text = $sr.ReadToEnd() } finally { $sr.Dispose() }
        Add-MmlmTraffic -Bytes $text.Length
    }
    catch [Net.WebException] {
        Add-MmlmTraffic -Failed
        $we = $_.Exception
        if ($we.Response) {
            $code = [int]$we.Response.StatusCode
            if ($code -eq 401) { throw 'Plex rejected the token (401 Unauthorized).' }
            throw ("Plex returned HTTP {0} for {1}" -f $code, $Path)
        }
        throw ("Could not reach Plex at {0}: {1}" -f $BaseUrl, $we.Message)
    }
    finally { if ($resp) { $resp.Close() } }

    $doc = New-Object Xml.XmlDocument
    $doc.LoadXml($text)
    , $doc                                  # the comma stops PowerShell from unrolling the document into its child nodes
}

function Get-MmlmPlexSections {
    param([string]$BaseUrl, [string]$Token)
    $doc = Get-MmlmPlexXml -BaseUrl $BaseUrl -Path '/library/sections' -Token $Token
    foreach ($d in $doc.SelectNodes('/MediaContainer/Directory')) {
        [pscustomobject]@{ Key = $d.GetAttribute('key'); Title = $d.GetAttribute('title'); Type = $d.GetAttribute('type') }
    }
}

function Get-MmlmPlexStubs {
    # One light-weight entry (ratingKey + updatedAt) per movie / episode in a library section.
    param([string]$BaseUrl, [string]$Token, $Section)
    $stubs = New-Object System.Collections.Generic.List[object]
    $start = 0; $total = [int]::MaxValue
    while ($start -lt $total) {
        if (Test-MmlmScanCancelled) { break }
        $q = @{ 'X-Plex-Container-Start' = $start; 'X-Plex-Container-Size' = 200 }
        if ($Section.Type -eq 'show') { $q['type'] = 4 }                 # 4 = episodes
        $doc   = Get-MmlmPlexXml -BaseUrl $BaseUrl -Path ('/library/sections/' + $Section.Key + '/all') -Query $q -Token $Token
        $t     = $doc.DocumentElement.GetAttribute('totalSize')
        if ($t) { $total = [int]$t }
        $nodes = @($doc.SelectNodes('/MediaContainer/Video'))
        if ($nodes.Count -eq 0) { break }
        foreach ($n in $nodes) {
            $stubs.Add([pscustomobject]@{ Key = $n.GetAttribute('ratingKey'); Updated = $n.GetAttribute('updatedAt'); Section = $Section.Title; Kind = $Section.Type })
        }
        $start += $nodes.Count
        if (-not $t) { break }                                           # no paging info: one page is all there is
        Set-MmlmProgress -Text ("Listing {0}: {1} of {2}" -f $Section.Title, [math]::Min($start, $total), $total) -Value ([math]::Min($start, $total)) -Max $total
    }
    $stubs
}

function Get-MmlmPlexMetadataMap {
    # ratingKey -> full <Video> element (streams, tags, guids). One batched request, with single requests as a fallback.
    param([string]$BaseUrl, [string]$Token, [string[]]$Keys)
    $map = @{}
    try {
        $doc = Get-MmlmPlexXml -BaseUrl $BaseUrl -Path ('/library/metadata/' + ($Keys -join ',')) -Query @{ includeGuids = 1 } -Token $Token
        foreach ($v in $doc.SelectNodes('/MediaContainer/Video')) { $map[$v.GetAttribute('ratingKey')] = $v }
    }
    catch { if ($_.Exception.Message -match 'rejected|Could not reach') { throw } }

    foreach ($k in $Keys) {
        if ($map.ContainsKey($k)) { continue }
        try {
            $doc = Get-MmlmPlexXml -BaseUrl $BaseUrl -Path ('/library/metadata/' + $k) -Query @{ includeGuids = 1 } -Token $Token
            $v = $doc.SelectSingleNode('/MediaContainer/Video')
            if ($null -ne $v) { $map[$k] = $v }
        }
        catch { if ($_.Exception.Message -match 'rejected|Could not reach') { throw } }
    }
    $map
}

function Get-MmlmPlexShowNode {
    param([string]$BaseUrl, [string]$Token, [string]$ShowKey, [hashtable]$Cache)
    if (-not $ShowKey) { return $null }
    if ($Cache.ContainsKey($ShowKey)) { return , $Cache[$ShowKey] }      # comma: an XmlElement would otherwise be unrolled into its children
    $node = $null
    try {
        $doc  = Get-MmlmPlexXml -BaseUrl $BaseUrl -Path ('/library/metadata/' + $ShowKey) -Query @{ includeGuids = 1 } -Token $Token
        $node = $doc.SelectSingleNode('/MediaContainer/Directory')
    }
    catch { if ($_.Exception.Message -match 'rejected|Could not reach') { throw } }
    $Cache[$ShowKey] = $node
    , $node
}

function Save-MmlmPlexPoster {
    # Downloads a small (240x360) poster through Plex's own image resizer and keeps it in the thumbnail folder.
    param([string]$BaseUrl, [string]$Token, [string]$ThumbPath)
    if ([string]::IsNullOrWhiteSpace($ThumbPath)) { return '' }
    $dest = Join-Path $script:ThumbFolder ('plex-' + (Get-MmlmStringHash ($BaseUrl.ToLowerInvariant() + '|' + $ThumbPath)) + '.jpg')
    if ((Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Length -gt 0)) { return $dest }

    $resp = $null
    try {
        Assert-MmlmTrafficAllowed
        $req  = New-MmlmPlexRequest -BaseUrl $BaseUrl -Path '/photo/:/transcode' -Token $Token -Accept 'image/jpeg,image/*' `
                    -Query @{ width = 240; height = 360; minSize = 1; upscale = 1; url = $ThumbPath }
        $resp = $req.GetResponse()
        $ms   = New-Object IO.MemoryStream
        try {
            $rs = $resp.GetResponseStream()
            $rs.CopyTo($ms)
            Add-MmlmTraffic -Bytes $ms.Length
            if ($ms.Length -gt 0) { [IO.File]::WriteAllBytes($dest, $ms.ToArray()); return $dest }
        }
        finally { $ms.Dispose() }
    }
    catch { }
    finally { if ($resp) { $resp.Close() } }
    ''
}

function Save-MmlmPlexArtwork {
    # Background art, clear logo or TV banner for a title, from the same Plex item as its poster (an episode uses its
    # show's). Saved as <Folder>\<kind>-<ratingKey>.<ext>; a title Plex has none for gets a <kind>-<key>.none marker so it
    # is not asked again (Rebuild clears them). Returns 'saved', 'have', 'none' or 'failed'.
    param([string]$BaseUrl, [string]$Token, [string]$Thumb, [ValidateSet('art', 'logo', 'banner')][string]$Kind, [string]$Folder, [switch]$Retry)
    if ([string]$Thumb -notmatch '^/library/metadata/(\d+)(/|$)') { return 'none' }
    $key = $Matches[1]
    $ext = $(if ($Kind -eq 'logo') { 'png' } else { 'jpg' })
    $pre  = @{ art = 'art'; logo = 'clogo'; banner = 'tvbanner' }[$Kind]       # (logo-/banner- were the cropped first version)
    $dest = Join-Path $Folder ('{0}-{1}.{2}' -f $pre, $key, $ext)
    $none = Join-Path $Folder ('{0}-{1}.none' -f $pre, $key)
    if ((Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Length -gt 0)) { return 'have' }
    if ((Test-Path -LiteralPath $none) -and -not $Retry) { return 'none' }
    # the box each picture must fit inside. Logos and banners are never cropped (minSize 0 = fit inside, keep the shape);
    # banners come at their full 1000x185. Background art fills 1280x720 (it is shown as a cover anyway).
    $size = @{ art = @(1280, 720); logo = @(800, 310); banner = @(1000, 185) }[$Kind]
    $path = '/library/metadata/{0}/{1}' -f $key, @{ art = 'art'; logo = 'clearLogo'; banner = 'banner' }[$Kind]
    $q = $(if ($Kind -eq 'art') { @{ width = $size[0]; height = $size[1]; minSize = 1; upscale = 1; url = $path } } else { @{ width = $size[0]; height = $size[1]; minSize = 0; upscale = 0; url = $path } })
    if ($Kind -eq 'logo') { $q.format = 'png' }
    $resp = $null
    try {
        Assert-MmlmTrafficAllowed
        $req  = New-MmlmPlexRequest -BaseUrl $BaseUrl -Path '/photo/:/transcode' -Token $Token -Accept 'image/*' -Query $q
        $resp = $req.GetResponse()
        $ms   = New-Object IO.MemoryStream
        try {
            $resp.GetResponseStream().CopyTo($ms)
            Add-MmlmTraffic -Bytes $ms.Length
            if ($ms.Length -gt 0) { [IO.File]::WriteAllBytes($dest, $ms.ToArray()); Remove-Item -LiteralPath $none -Force -ErrorAction SilentlyContinue; return 'saved' }
        }
        finally { $ms.Dispose() }
        [IO.File]::WriteAllText($none, ''); return 'none'
    }
    catch {
        $code = 0
        try { $code = [int]$_.Exception.InnerException.Response.StatusCode } catch { }
        if (-not $code) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
        if ($code -eq 404 -or $code -eq 400) { Add-MmlmTraffic; [IO.File]::WriteAllText($none, ''); return 'none' }   # Plex has none for this title
        Add-MmlmTraffic -Failed
        'failed'
    }
    finally { if ($resp) { $resp.Close() } }
}

function Sync-MmlmArtwork {
    # Fetches the chosen artwork kinds for every distinct Plex item behind these records (an episode uses its show), into
    # $Folder. The failed-request rule: three failures in a row stop the run. Returns @{ Saved; Failed; Stopped }.
    param([object[]]$Recs, [string[]]$Kinds, [string]$Folder, [string]$BaseUrl, [string]$Token, [switch]$Retry)
    $res = @{ Saved = 0; Failed = 0; Stopped = $false }
    if (-not $Kinds -or $Kinds.Count -eq 0) { return $res }
    if (-not (Test-Path -LiteralPath $Folder)) { New-Item -Path $Folder -ItemType Directory -Force | Out-Null }
    # the first version saved cropped logos and banners (logo-*, banner-*): drop them so they are fetched again uncropped
    Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(logo|banner)-\d+\.(png|jpg|none)$' } | Remove-Item -Force -ErrorAction SilentlyContinue
    $seen = @{}; $jobs = New-Object System.Collections.Generic.List[object]
    foreach ($r in $Recs) {
        $th = [string]$r.PlexThumb
        if (-not $th -or $seen.ContainsKey($th)) { continue }
        $seen[$th] = $true
        $tv = [bool][string]$r.Show
        foreach ($k in $Kinds) { if ($k -eq 'banner' -and -not $tv) { continue }; $jobs.Add(@($th, $k)) }
    }
    $n = 0; $row = 0
    foreach ($j in $jobs) {
        if (Test-MmlmScanCancelled) { break }
        $n++
        if (($n % 5) -eq 0 -or $n -eq $jobs.Count) { Set-MmlmProgress -Text ('Artwork: {0} of {1}' -f $n, $jobs.Count) -Value $n -Max $jobs.Count }
        $r = Save-MmlmPlexArtwork -BaseUrl $BaseUrl -Token $Token -Thumb $j[0] -Kind $j[1] -Folder $Folder -Retry:$Retry
        if ($r -eq 'saved') { $res.Saved++ }
        if ($r -eq 'failed') { $res.Failed++; $row++; if ($row -ge 3) { $res.Stopped = $true; break } } else { $row = 0 }
    }
    if ($res.Saved -gt 0) { [IO.File]::WriteAllText((Join-Path $Folder 'stamp.txt'), (Get-Date).ToString('o')) }
    $res
}

function Save-MmlmPlexImage {
    # Any Plex image (poster, episode still, cast photo) resized by Plex's own image resizer and saved as <Folder>\<hash>.jpg.
    # Returns the file name ('' when there is no image or Plex could not send it). Already saved = no request.
    param([string]$BaseUrl, [string]$Token, [string]$ThumbPath, [int]$Width, [int]$Height, [string]$Folder)
    if ([string]::IsNullOrWhiteSpace($ThumbPath)) { return '' }
    $name = (Get-MmlmStringHash ($BaseUrl.ToLowerInvariant() + '|' + $ThumbPath + '|' + $Width + 'x' + $Height)).Substring(0, 24) + '.jpg'
    $dest = Join-Path $Folder $name
    if ((Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Length -gt 0)) { return $name }
    $resp = $null
    try {
        Assert-MmlmTrafficAllowed
        $req  = New-MmlmPlexRequest -BaseUrl $BaseUrl -Path '/photo/:/transcode' -Token $Token -Accept 'image/jpeg,image/*' `
                    -Query @{ width = $Width; height = $Height; minSize = 1; upscale = 1; url = $ThumbPath }
        $resp = $req.GetResponse()
        $ms   = New-Object IO.MemoryStream
        try {
            $resp.GetResponseStream().CopyTo($ms)
            Add-MmlmTraffic -Bytes $ms.Length
            if ($ms.Length -gt 0) { [IO.File]::WriteAllBytes($dest, $ms.ToArray()); return $name }
        }
        finally { $ms.Dispose() }
    }
    catch { Add-MmlmTraffic -Failed }
    finally { if ($resp) { $resp.Close() } }
    ''
}

function Convert-MmlmPlexEpoch {
    param([string]$Seconds)
    $n = [long]0
    if ([long]::TryParse($Seconds, [ref]$n) -and $n -gt 0) {
        try { return [DateTimeOffset]::FromUnixTimeSeconds($n).LocalDateTime.ToString('yyyy-MM-dd') } catch { }
    }
    ''
}

function Get-MmlmPlexTags {
    param($Node, [string]$Child, [int]$Max = 0)
    if ($null -eq $Node) { return '' }
    $v = @($Node.SelectNodes($Child) | ForEach-Object { $_.GetAttribute('tag') } | Where-Object { $_ })
    if ($Max -gt 0) { $v = @($v | Select-Object -First $Max) }
    $v -join '; '
}

function Get-MmlmPlexRatings {
    # All the scores Plex carries for one item: Imdb / Tmdb (0-10), RTCritic / RTAudience (percent, 0 = none).
    # Plex lists them as <Rating image= value= type=> children, and as rating / audienceRating attributes with ratingImage / audienceRatingImage.
    param($Node)
    $o = @{ Imdb = 0.0; Tmdb = 0.0; RTCritic = 0; RTAudience = 0 }
    if ($null -eq $Node) { return $o }
    $pairs = New-Object System.Collections.Generic.List[object]
    foreach ($n in @($Node.SelectNodes('Rating'))) { $pairs.Add(@($n.GetAttribute('image'), $n.GetAttribute('value'), $n.GetAttribute('type'))) }
    $pairs.Add(@($Node.GetAttribute('ratingImage'),         $Node.GetAttribute('rating'),         'critic'))
    $pairs.Add(@($Node.GetAttribute('audienceRatingImage'), $Node.GetAttribute('audienceRating'), 'audience'))
    foreach ($p in $pairs) {
        $img = [string]$p[0]; $val = ConvertTo-MmlmSafeDouble $p[1]
        if (-not $img -or $val -le 0) { continue }
        if     ($img -like 'imdb://*')          { if ($o.Imdb -le 0) { $o.Imdb = $val } }
        elseif ($img -like 'themoviedb://*')    { if ($o.Tmdb -le 0) { $o.Tmdb = $val } }
        elseif ($img -like 'rottentomatoes://*') {
            $pct = [int][math]::Round($val * 10)
            if ($pct -lt 1 -or $pct -gt 100) { continue }
            if ($img -match 'upright|spilled') { if ($o.RTAudience -le 0) { $o.RTAudience = $pct } }
            else                               { if ($o.RTCritic   -le 0) { $o.RTCritic   = $pct } }
        }
    }
    $o
}

function Get-MmlmPlexRating {
    # The single generic rating: IMDb, else TMDB, else a Plex score that is not from Rotten Tomatoes.
    param($Node)
    if ($null -eq $Node) { return 0.0 }
    $r = Get-MmlmPlexRatings $Node
    if ($r.Imdb -gt 0) { return $r.Imdb }
    if ($r.Tmdb -gt 0) { return $r.Tmdb }
    if ([string]$Node.GetAttribute('audienceRatingImage') -notlike 'rottentomatoes://*') {
        $a = ConvertTo-MmlmSafeDouble $Node.GetAttribute('audienceRating'); if ($a -gt 0) { return $a }
    }
    if ([string]$Node.GetAttribute('ratingImage') -notlike 'rottentomatoes://*') {
        return (ConvertTo-MmlmSafeDouble $Node.GetAttribute('rating'))
    }
    0.0
}

function Get-MmlmPlexRatingSource {
    # Which service Get-MmlmPlexRating took the number from ('IMDb', 'TMDB', or '' when it is only a generic Plex score).
    param($Node)
    if ($null -eq $Node) { return '' }
    $r = Get-MmlmPlexRatings $Node
    if ($r.Imdb -gt 0) { return 'IMDb' }
    if ($r.Tmdb -gt 0) { return 'TMDB' }
    ''
}

function Get-MmlmPlexAudioFormat {
    # -> @{ Label; Object } using the same names the MediaInfo path produces
    param([string]$Codec, [string]$Profile, [string]$Display)
    $c = $Codec.ToLowerInvariant(); $p = $Profile.ToLowerInvariant()
    $label = switch -Regex ($c) {
        '^truehd'     { 'Dolby TrueHD' }
        '^eac3'       { 'Dolby Digital Plus' }
        '^ac3'        { 'Dolby Digital' }
        '^(dca|dts)'  {
            if     ($p -match 'ma|dts-x|dtsx')  { 'DTS-HD Master Audio' }
            elseif ($p -match 'hra')            { 'DTS-HD High Resolution Audio' }
            elseif ($p -match 'es')             { 'DTS-ES' }
            else                                { 'DTS' }
        }
        '^aac'        { 'AAC' }
        '^flac'       { 'FLAC' }
        '^mp3'        { 'MP3' }
        '^opus'       { 'Opus' }
        '^vorbis'     { 'Vorbis' }
        '^pcm'        { 'PCM' }
        default       { if ($c) { $c.ToUpperInvariant() } else { 'Unknown' } }
    }
    $obj = ''
    if     ($Display -match 'Atmos')                    { $obj = 'Dolby Atmos' }
    elseif ($p -match 'dts-x|dtsx' -or $Display -match 'DTS[-: ]X') { $obj = 'DTS:X' }
    @{ Label = $label; Object = $obj }
}

function ConvertFrom-MmlmPlexVideo {
    # Turns one Plex <Video> (movie or episode) into a record with the same fields the MediaInfo path fills.
    param([Parameter(Mandatory)]$Video, [string]$LibraryName, $Show = $null)

    $rec  = New-MmlmEmptyRecord
    $isEp = ($Video.GetAttribute('type') -eq 'episode')
    $meta = if ($isEp -and $null -ne $Show) { $Show } else { $Video }          # tags (genre, cast, ...) live on the show for episodes

    # ---- best media version -> first part -> streams -------------------------
    $media = @($Video.SelectNodes('Media')) |
        Sort-Object @{ Expression = { ConvertTo-MmlmSafeInt $_.GetAttribute('width') }; Descending = $true },
                    @{ Expression = { ConvertTo-MmlmSafeInt $_.GetAttribute('bitrate') }; Descending = $true } |
        Select-Object -First 1
    $parts = @(); $part = $null; $streams = @()
    if ($null -ne $media) {
        $parts = @($media.SelectNodes('Part'))
        $part  = $parts | Select-Object -First 1
        if ($null -ne $part) { $streams = @($part.SelectNodes('Stream')) }
    }
    $vs       = $streams | Where-Object { $_.GetAttribute('streamType') -eq '1' } | Select-Object -First 1
    $audio    = @($streams | Where-Object { $_.GetAttribute('streamType') -eq '2' })
    $subs     = @($streams | Where-Object { $_.GetAttribute('streamType') -eq '3' })
    $as       = $audio | Where-Object { $_.GetAttribute('selected') -eq '1' } | Select-Object -First 1
    if ($null -eq $as) { $as = $audio | Select-Object -First 1 }

    # ---- titles / descriptive metadata ---------------------------------------
    $title = $Video.GetAttribute('title')
    $rec.Library = $LibraryName
    if ($isEp) {
        $season = ConvertTo-MmlmSafeInt $Video.GetAttribute('parentIndex')
        $epNum  = ConvertTo-MmlmSafeInt $Video.GetAttribute('index')
        $showTitle = $Video.GetAttribute('grandparentTitle')
        $rec.Show    = $showTitle
        $rec.Season  = $season
        $rec.Episode = $epNum
        $rec.Title   = ('{0} - S{1:00}E{2:00} - {3}' -f $showTitle, $season, $epNum, $title)
    }
    else { $rec.Title = $title }

    $rec.ReleaseDate = $Video.GetAttribute('originallyAvailableAt')
    $year = ConvertTo-MmlmSafeInt $Video.GetAttribute('year')
    if ($year -le 0 -and $rec.ReleaseDate.Length -ge 4) { $year = ConvertTo-MmlmSafeInt $rec.ReleaseDate.Substring(0, 4) }
    if ($year -le 0 -and $null -ne $Show) { $year = ConvertTo-MmlmSafeInt $Show.GetAttribute('year') }
    $rec.Year       = $year
    $rec.Genre      = Get-MmlmPlexTags $meta 'Genre'
    $mpaa = $Video.GetAttribute('contentRating')
    if (-not $mpaa -and $null -ne $Show) { $mpaa = $Show.GetAttribute('contentRating') }
    $rec.MPAARating = $mpaa
    $rating = Get-MmlmPlexRating $Video
    if ($rating -le 0 -and $null -ne $Show) { $rating = Get-MmlmPlexRating $Show }
    $rec.Rating     = $rating
    $rsrc = Get-MmlmPlexRatingSource $Video
    if ($rsrc -eq '' -and (Get-MmlmPlexRating $Video) -le 0 -and $null -ne $Show) { $rsrc = Get-MmlmPlexRatingSource $Show }
    $rec.RatingSource = $rsrc
    $rt = Get-MmlmPlexRatings $Video
    if ($rt.RTCritic -le 0 -and $rt.RTAudience -le 0 -and $null -ne $Show) { $rt = Get-MmlmPlexRatings $Show }
    if ($rt.RTCritic   -gt 0) { $rec.RTCritic   = $rt.RTCritic }
    if ($rt.RTAudience -gt 0) { $rec.RTAudience = $rt.RTAudience }
    $rec.Studio     = $meta.GetAttribute('studio')
    $rec.Director   = Get-MmlmPlexTags $Video 'Director' 3
    $rec.Cast       = Get-MmlmPlexTags $meta 'Role' 6
    $rec.Collection = Get-MmlmPlexTags $Video 'Collection' 1
    $rec.Country    = Get-MmlmPlexTags $meta 'Country'
    $rec.Tagline    = $Video.GetAttribute('tagline')
    $rec.Plot       = ($Video.GetAttribute('summary')) -replace '\s+', ' '
    foreach ($g in @($meta.SelectNodes('Guid'))) {
        $id = $g.GetAttribute('id')
        if     ($id -match '^imdb://(tt\d+)') { $rec.IMDBID = $Matches[1] }
        elseif ($id -match '^tmdb://(\d+)')   { $rec.TMDBID = $Matches[1] }
    }
    if (-not $rec.IMDBID -and $meta.GetAttribute('guid') -match 'imdb://(tt\d+)') { $rec.IMDBID = $Matches[1] }
    if (-not $rec.TMDBID -and $meta.GetAttribute('guid') -match 'themoviedb://(\d+)') { $rec.TMDBID = $Matches[1] }

    # ---- file / container ------------------------------------------------------
    $file = if ($null -ne $part) { $part.GetAttribute('file') } else { '' }
    $durMs = if ($null -ne $media) { ConvertTo-MmlmSafeDouble $media.GetAttribute('duration') } else { 0.0 }
    if ($durMs -le 0) { $durMs = ConvertTo-MmlmSafeDouble $Video.GetAttribute('duration') }
    $sizeBytes = 0.0
    foreach ($p in $parts) { $sizeBytes += (ConvertTo-MmlmSafeDouble $p.GetAttribute('size')) }
    $overallKbps = if ($null -ne $media) { ConvertTo-MmlmSafeDouble $media.GetAttribute('bitrate') } else { 0.0 }
    $cont = if ($null -ne $media) { $media.GetAttribute('container') } else { '' }

    $rec.RuntimeMin         = [math]::Round($durMs / 60000, 2)
    $rec.FileName           = if ($file) { [IO.Path]::GetFileName($file) } else { '' }
    $rec.Ext                = if ($file) { [IO.Path]::GetExtension($file).TrimStart('.').ToLowerInvariant() } else { $cont }
    $rec.Type               = 'Video'
    $rec.Container          = switch -Regex ($cont.ToLowerInvariant()) {
        '^mkv'           { 'Matroska' }
        '^(mp4|m4v|mov)' { 'MPEG-4' }
        '^avi'           { 'AVI' }
        '^(ts|mpegts)'   { 'MPEG-TS' }
        '^m2ts'          { 'BDAV' }
        default          { if ($cont) { $cont.ToUpperInvariant() } else { '' } }
    }
    $rec.FileSizeGB         = [math]::Round($sizeBytes / 1GB, 2)
    $rec.OverallBitRateMbps = [math]::Round($overallKbps / 1000, 2)
    $rec.Source             = if ($file) { Get-MmlmSourceFromName ([IO.Path]::GetFileNameWithoutExtension($file)) } else { 'Unknown' }
    $rec.Added              = Convert-MmlmPlexEpoch $Video.GetAttribute('addedAt')
    $rec.Modified           = Convert-MmlmPlexEpoch $Video.GetAttribute('updatedAt')
    if ($file) {
        $cut = $file.LastIndexOfAny([char[]]@('\', '/'))
        $rec.Directory = if ($cut -gt 0) { $file.Substring(0, $cut) } else { '' }
    }
    $rec.FullPath           = $file
    $rec.HasNfo             = $true          # Plex already holds the metadata (keeps the "Missing NFO" health tile honest)
    $rec.ViewCount          = ConvertTo-MmlmSafeInt $Video.GetAttribute('viewCount')
    $rec.LastViewed         = Convert-MmlmPlexEpoch $Video.GetAttribute('lastViewedAt')
    $rec.PlexKey            = $Video.GetAttribute('ratingKey')
    $thumb = if ($isEp -and $Video.GetAttribute('grandparentThumb')) { $Video.GetAttribute('grandparentThumb') } else { $Video.GetAttribute('thumb') }
    $rec.PlexThumb          = $thumb

    # ---- video -------------------------------------------------------------------
    $w = if ($null -ne $media) { ConvertTo-MmlmSafeInt $media.GetAttribute('width') }  else { 0 }
    $h = if ($null -ne $media) { ConvertTo-MmlmSafeInt $media.GetAttribute('height') } else { 0 }
    if ($null -ne $vs) {
        if ($w -le 0) { $w = ConvertTo-MmlmSafeInt $vs.GetAttribute('width') }
        if ($h -le 0) { $h = ConvertTo-MmlmSafeInt $vs.GetAttribute('height') }
    }
    $codecRaw = if ($null -ne $vs) { $vs.GetAttribute('codec') } elseif ($null -ne $media) { $media.GetAttribute('videoCodec') } else { '' }
    $codec = switch -Regex ($codecRaw.ToLowerInvariant()) {
        '^(hevc|h265)'  { 'HEVC' }
        '^(h264|avc)'   { 'AVC' }
        '^vc1'          { 'VC-1' }
        '^mpeg2'        { 'MPEG' }
        '^mpeg4'        { 'MPEG-4 Visual' }
        '^av1'          { 'AV1' }
        '^vp9'          { 'VP9' }
        default         { if ($codecRaw) { $codecRaw.ToUpperInvariant() } else { '' } }
    }
    $fps = if ($null -ne $vs) { ConvertTo-MmlmSafeDouble $vs.GetAttribute('frameRate') } else { 0.0 }
    if ($fps -le 0 -and $media -and $media.GetAttribute('videoFrameRate') -match '^(\d+(\.\d+)?)') { $fps = ConvertTo-MmlmSafeDouble $Matches[1] }
    $vbr = if ($null -ne $vs) { (ConvertTo-MmlmSafeDouble $vs.GetAttribute('bitrate')) * 1000 } else { 0.0 }
    if ($vbr -le 0) { $vbr = $overallKbps * 1000 }

    $rec.Width            = $w
    $rec.Height           = $h
    $rec.Resolution       = if ($w -gt 0) { "${w}x${h}" } else { '' }
    $rec.ResolutionClass  = Get-MmlmResolutionClass -Width $w -Height $h
    $rec.DAR              = if ($null -ne $media) { ConvertTo-MmlmSafeDouble $media.GetAttribute('aspectRatio') } else { 0.0 }
    $rec.VideoCodec       = $codec
    if ($null -ne $vs) { $rec.FormatProfile = (Get-Culture).TextInfo.ToTitleCase($vs.GetAttribute('profile')) }
    $rec.VideoBitRateMbps = [math]::Round($vbr / 1000000, 2)
    $rec.FrameRate        = $fps
    $rec.BitsPerPixel     = if (($w * $h * $fps) -gt 0 -and $vbr -gt 0) { [math]::Round($vbr / ($w * $h * $fps), 3) } else { 0.0 }
    if ($null -ne $vs) {
        $scan = $vs.GetAttribute('scanType')
        $rec.ScanType          = if ($scan) { (Get-Culture).TextInfo.ToTitleCase($scan) } else { '' }
        $rec.BitDepth          = ConvertTo-MmlmSafeInt $vs.GetAttribute('bitDepth')
        $rec.ChromaSubsampling = $vs.GetAttribute('chromaSubsampling')
        $range = $vs.GetAttribute('colorRange')
        $rec.ColorRange        = switch ($range) { 'tv' { 'Limited' } 'pc' { 'Full' } default { $range } }
    }

    # ---- HDR / Dolby Vision (Plex exposes the DOVI* flags on the video stream) -----
    $trc     = if ($null -ne $vs) { $vs.GetAttribute('colorTrc') } else { '' }
    $display = if ($null -ne $vs) { ($vs.GetAttribute('displayTitle') + ' ' + $vs.GetAttribute('extendedDisplayTitle')) } else { '' }
    $doviOn  = $false
    if ($null -ne $vs) {
        $doviOn = ($vs.GetAttribute('DOVIPresent') -in '1', 'true') -or ($display -match 'Dolby Vision|DoVi')
    }
    $hdrType = if ($doviOn) { 'Dolby Vision' }
               elseif ($trc -eq 'smpte2084')    { 'HDR10' }
               elseif ($trc -eq 'arib-std-b67') { 'HLG' }
               else { 'SDR' }

    $dv = [pscustomobject]@{ Profile = ''; Layer = ''; Base = '' }
    if ($doviOn) {
        $num  = ConvertTo-MmlmSafeInt $vs.GetAttribute('DOVIProfile')
        $base = switch ($vs.GetAttribute('DOVIBLCompatID')) { '1' { 'HDR10' } '6' { 'HDR10' } '2' { 'SDR' } '4' { 'HLG' } default { 'None' } }
        if ($num -eq 5) { $base = 'None' }
        $prof = ''
        if ($num -gt 0) {
            $prof = "$num"
            if ($num -in 8, 10) {
                switch ($base) { 'HDR10' { $prof = "$num.1" } 'SDR' { $prof = "$num.2" } 'HLG' { $prof = "$num.4" } }
            }
        }
        $dual = ($vs.GetAttribute('DOVIELPresent') -in '1', 'true') -or ($num -in 4, 7)
        $dv.Profile = $prof
        $dv.Base    = $base
        $dv.Layer   = if ($num -le 0) { '' } elseif ($dual) { 'Dual layer' } else { 'Single layer' }
    }
    $rec.HDRType           = $hdrType
    $rec.DVProfile         = $dv.Profile
    $rec.DVLayer           = $dv.Layer
    $rec.DVBase            = $dv.Base
    $rec.HasHDR10Plus      = $false         # Plex does not report HDR10+ (dynamic metadata)
    $rec.HDRStack          = Get-MmlmHdrStack -HdrType $hdrType -Dv $dv -HasHdr10Plus $false
    $rec.Source            = Resolve-MmlmSourceLabel -Source $rec.Source -FileName $rec.FileName -HdrType $hdrType -DvProfile $dv.Profile
    $rec.HDRFormat         = switch ($hdrType) { 'Dolby Vision' { 'Dolby Vision' } 'HDR10' { 'SMPTE ST 2084' } 'HLG' { 'HLG' } default { '' } }
    if ($doviOn) {
        $rec.HDRFormatLevel    = $vs.GetAttribute('DOVILevel')
        $rec.HDRFormatSettings = if ($dv.Layer -eq 'Dual layer') { 'BL+EL+RPU' } else { 'BL+RPU' }
        $rec.HDRFormatCompat   = $dv.Base
    }
    if ($null -ne $vs) {
        $rec.Primaries = $vs.GetAttribute('colorPrimaries')
        $rec.Transfer  = $trc
        $rec.Matrix    = $vs.GetAttribute('colorSpace')
    }

    # ---- audio (the selected / first track) ----------------------------------------
    if ($null -ne $as) {
        $ch   = ConvertTo-MmlmSafeInt $as.GetAttribute('channels')
        $adis = $as.GetAttribute('displayTitle') + ' ' + $as.GetAttribute('extendedDisplayTitle')
        $af   = Get-MmlmPlexAudioFormat -Codec $as.GetAttribute('codec') -Profile $as.GetAttribute('profile') -Display $adis
        $rec.AudioFormat       = $af.Label
        $rec.ObjectAudio       = $af.Object
        $rec.AudioTitle        = $as.GetAttribute('title')
        $rec.AudioBitRateKbps  = [int](ConvertTo-MmlmSafeDouble $as.GetAttribute('bitrate'))
        $rec.AudioChannels     = $ch
        $rec.AudioLayout       = Get-MmlmAudioLayout -Channels $ch
        $rec.AudioSamplingRate = $as.GetAttribute('samplingRate')
        $rec.AudioBitDepth     = $as.GetAttribute('bitDepth')
    }
    elseif ($null -ne $media) {
        $ch = ConvertTo-MmlmSafeInt $media.GetAttribute('audioChannels')
        $rec.AudioFormat   = (Get-MmlmPlexAudioFormat -Codec $media.GetAttribute('audioCodec') -Profile $media.GetAttribute('audioProfile') -Display '').Label
        $rec.AudioChannels = $ch
        $rec.AudioLayout   = Get-MmlmAudioLayout -Channels $ch
    }
    $rec.AudioTracks    = $audio.Count
    $rec.AudioLanguages = (@($audio | ForEach-Object { $_.GetAttribute('language') } | Where-Object { $_ } | Select-Object -Unique)) -join '; '

    # ---- subtitles --------------------------------------------------------------------
    $rec.SubtitleTracks    = $subs.Count
    $rec.SubtitleLanguages = (@($subs | ForEach-Object { $_.GetAttribute('language') } | Where-Object { $_ } | Select-Object -Unique)) -join '; '
    $rec.SubtitleFormats   = (@($subs | ForEach-Object { $_.GetAttribute('codec') } | Where-Object { $_ } | ForEach-Object { $_.ToUpperInvariant() } | Select-Object -Unique)) -join '; '

    [pscustomobject]$rec
}

function Invoke-MmlmPlexScan {
    param([string]$BaseUrl, [string]$Token, [bool]$Movies, [bool]$Shows, [bool]$Rebuild, [bool]$DetectFel, [hashtable]$Prior = @{})

    Set-MmlmProgress -Text 'Connecting to Plex...'
    $sections = @(Get-MmlmPlexSections -BaseUrl $BaseUrl -Token $Token | Where-Object {
        ($_.Type -eq 'movie' -and $Movies) -or ($_.Type -eq 'show' -and $Shows) })
    if ($sections.Count -eq 0) { throw 'This Plex server has no movie / TV libraries matching your selection.' }

    # 1) list every item (cheap) ---------------------------------------------------------
    $stubs = New-Object System.Collections.Generic.List[object]
    Set-MmlmScanPhase -Lo 0.0 -Hi 0.05
    foreach ($sec in $sections) {
        foreach ($s in @(Get-MmlmPlexStubs -BaseUrl $BaseUrl -Token $Token -Section $sec)) { $stubs.Add($s) }
    }
    $script:Sync.Total = $stubs.Count
    if ($stubs.Count -eq 0) { return @() }

    # 2) reuse cached records whose Plex 'updatedAt' has not changed ------------------------
    $byKey = @{}
    $todo  = New-Object System.Collections.Generic.List[object]
    Set-MmlmScanPhase -Lo 0.05 -Hi 0.10
    $chk = 0
    foreach ($s in $stubs) {
        $chk++
        if (($chk % 250) -eq 0) {
            if (Test-MmlmScanCancelled) { break }
            Set-MmlmProgress -Text ("Checking for changes: {0} of {1}" -f $chk, $stubs.Count) -Value $chk -Max $stubs.Count
        }
        # unchanged since the last scan (same Plex 'updatedAt'): reuse the record we already have
        $p0 = $Prior[[string]$s.Key]
        if ($null -ne $p0 -and [string]$p0.PlexUpdated -eq [string]$s.Updated) { $byKey[$s.Key] = $p0; continue }
        $ck = Join-Path $script:CacheFolder ((Get-MmlmStringHash ('plex|{0}|{1}|{2}|{3}|rt2' -f $BaseUrl.ToLowerInvariant(), $s.Key, $s.Updated, $script:CacheVersion)) + '.json')
        $s | Add-Member -NotePropertyName CacheFile -NotePropertyValue $ck -Force
        if ($Rebuild) { Remove-Item -LiteralPath $ck -Force -ErrorAction SilentlyContinue }
        $hit = $null
        if (Test-Path -LiteralPath $ck) {
            try { $hit = Repair-MmlmCachedRecord ([IO.File]::ReadAllText($ck, [Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { $hit = $null }
        }
        if ($hit) { $byKey[$s.Key] = $hit } else { $todo.Add($s) }
    }

    # 3) fetch full details for the rest, in batches ----------------------------------------
    $showCache = @{}
    $done = $stubs.Count - $todo.Count
    $postLo = if ($todo.Count -gt 0) { 0.8 } else { 0.10 }       # the overall bar: details 0-80 %, posters 80-100 % (all of it when everything was cached)
    Set-MmlmScanPhase -Lo 0.10 -Hi $postLo
    for ($i = 0; $i -lt $todo.Count; $i += 25) {
        if (Test-MmlmScanCancelled) { break }
        $batch = @($todo.GetRange($i, [Math]::Min(25, $todo.Count - $i)))      # (Select-Object -Skip re-walks the whole list every time, which crawls on tens of thousands of episodes)
        Set-MmlmProgress -Text ("Reading Plex metadata: {0} of {1}" -f ($done + 1), $stubs.Count) -Value $done -Max $stubs.Count
        $map = Get-MmlmPlexMetadataMap -BaseUrl $BaseUrl -Token $Token -Keys @($batch | ForEach-Object { $_.Key })
        foreach ($s in $batch) {
            $v = $map[$s.Key]
            if ($null -eq $v) { $done++; continue }
            $showNode = $null
            if ($v.GetAttribute('type') -eq 'episode') {
                $showNode = Get-MmlmPlexShowNode -BaseUrl $BaseUrl -Token $Token -ShowKey $v.GetAttribute('grandparentRatingKey') -Cache $showCache
            }
            try {
                $rec = ConvertFrom-MmlmPlexVideo -Video $v -LibraryName $s.Section -Show $showNode
                $byKey[$s.Key] = $rec
                [IO.File]::WriteAllText($s.CacheFile, ($rec | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding($false)))
            }
            catch { Write-Warning "Skipped Plex item $($s.Key): $_" }
            $done++
        }
    }

    # 4) posters + optional FEL/MEL probe, then put everything back in library order ----------
    $out = New-Object System.Collections.Generic.List[object]
    $posterSeen = @{}
    $n = 0
    Set-MmlmScanPhase -Lo $postLo -Hi 1.0
    foreach ($s in $stubs) {
        if (Test-MmlmScanCancelled) { break }
        $n++
        $rec = $byKey[$s.Key]
        if ($null -eq $rec) { continue }
        if ([string]$rec.PlexUpdated -ne [string]$s.Updated) {          # remembered so the next scan can tell what changed
            if ($null -ne $rec.PSObject.Properties['PlexUpdated']) { $rec.PlexUpdated = $s.Updated }
            else { $rec.PSObject.Properties.Add((New-Object Management.Automation.PSNoteProperty('PlexUpdated', [string]$s.Updated))) }
        }
        if (($n % 5) -eq 0 -or $n -eq $stubs.Count) { Set-MmlmProgress -Text ("Posters: {0} of {1} titles ({2} distinct images)" -f $n, $stubs.Count, $posterSeen.Count) -Value $n -Max $stubs.Count }

        # one poster per distinct image: every episode of a show shares its show's poster, so it is checked / fetched once
        $th = [string]$rec.PlexThumb
        if ($th -and $posterSeen.ContainsKey($th)) { $rec.PosterPath = $posterSeen[$th]; $rec.HasPoster = [bool]$posterSeen[$th] }
        else {
            if (-not $rec.PosterPath -or -not (Test-Path -LiteralPath $rec.PosterPath)) {
                $poster = [string](@(Save-MmlmPlexPoster -BaseUrl $BaseUrl -Token $Token -ThumbPath $th) | Select-Object -Last 1)
                $rec.PosterPath = $poster
                $rec.HasPoster  = [bool]$poster
            }
            if ($th) { $posterSeen[$th] = [string]$rec.PosterPath }
        }
        if ($DetectFel -and $rec.DVLayer -eq 'Dual layer' -and $rec.FullPath -and (Test-Path -LiteralPath $rec.FullPath -ErrorAction SilentlyContinue)) {
            $layer = Get-MmlmDolbyVisionLayerType -Path $rec.FullPath -DurationSec ([int]([double]$rec.RuntimeMin * 60))
            if ($layer) {
                $rec.DVLayer  = $layer
                $rec.HDRStack = ([string]$rec.HDRStack) -replace '\(dual layer\)', $layer
                try { [IO.File]::WriteAllText($s.CacheFile, ($rec | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding($false))) } catch { }
            }
        }
        $out.Add($rec)
    }
    $out.ToArray()
}

Export-ModuleMember -Function @(
    'Set-MmlmPlexContext',
    'Protect-MmlmPlexToken',
    'Unprotect-MmlmPlexToken',
    'New-MmlmPlexRequest',
    'Get-MmlmPlexXml',
    'Get-MmlmPlexSections',
    'Get-MmlmPlexStubs',
    'Get-MmlmPlexMetadataMap',
    'Get-MmlmPlexShowNode',
    'Save-MmlmPlexPoster',
    'Save-MmlmPlexArtwork',
    'Sync-MmlmArtwork',
    'Save-MmlmPlexImage',
    'Convert-MmlmPlexEpoch',
    'Get-MmlmPlexTags',
    'Get-MmlmPlexRatings',
    'Get-MmlmPlexRating',
    'Get-MmlmPlexRatingSource',
    'Get-MmlmPlexAudioFormat',
    'ConvertFrom-MmlmPlexVideo',
    'Invoke-MmlmPlexScan'
)
