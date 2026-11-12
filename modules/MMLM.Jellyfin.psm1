#Requires -Version 5.1
<#
    MMLM.Jellyfin - reads a Jellyfin server's movie and TV libraries into MMLM's records (the same fields a Plex scan
    fills), plus posters and artwork. Uses the person's own server with an API key made in Jellyfin's dashboard
    (Administration > API Keys); nothing else is contacted.

    Ids: a Jellyfin item is stored with PlexKey = 'jf-<item id>' (so a title's id, "p:jf-...", can never clash with a
    Plex one), PlexThumb = '/Items/<item or series id>/Images/Primary' and PlexUpdated = its Etag (changes when Jellyfin
    changes the item, so unchanged titles are reused on the next scan, as with Plex). The field names stay as they are
    so saved scans, collections and the page need no change.
#>
Set-StrictMode -Version 2.0
foreach ($m0 in @('MMLM.Library.psm1', 'MMLM.Plex.psm1')) { Import-Module (Join-Path $PSScriptRoot $m0) -DisableNameChecking }

$script:JellyfinTimeoutMs = 30000
$script:DetailFields = 'Etag,MediaSources,MediaStreams,Path,ProviderIds,Genres,Studios,People,Overview,Taglines,ProductionLocations,DateCreated'

function Set-MmlmJellyfinContext {
    param([hashtable]$Values)
    foreach ($k in @($Values.Keys)) { Set-Variable -Scope Script -Name $k -Value $Values[$k] }
}

function New-MmlmJellyfinRequest {
    param([string]$BaseUrl, [string]$Path, [hashtable]$Query = @{}, [string]$Token, [string]$Accept = 'application/json')
    $parts = @()
    foreach ($k in $Query.Keys) { $parts += ('{0}={1}' -f [Uri]::EscapeDataString([string]$k), [Uri]::EscapeDataString([string]$Query[$k])) }
    $url = $BaseUrl.TrimEnd('/') + $Path
    if ($parts.Count -gt 0) { $url += '?' + ($parts -join '&') }
    $req = [Net.HttpWebRequest]::Create($url)
    $req.Method = 'GET'; $req.Timeout = $script:JellyfinTimeoutMs; $req.ReadWriteTimeout = $script:JellyfinTimeoutMs; $req.Accept = $Accept
    # the key goes in headers, never in the address (so it never lands in a log)
    $req.Headers.Add('Authorization', ('MediaBrowser Client="Modern Media Library Manager", Device="Windows", DeviceId="mmlm", Version="1", Token="{0}"' -f $Token))
    $req.Headers.Add('X-Emby-Token', $Token)
    $req
}

function Invoke-MmlmJellyfinJson {
    # One JSON request, counted as traffic. Plain errors: a refused key, a wrong address, a server that is down.
    param([string]$BaseUrl, [string]$Path, [hashtable]$Query = @{}, [string]$Token)
    Assert-MmlmTrafficAllowed
    $resp = $null
    try {
        $req = New-MmlmJellyfinRequest -BaseUrl $BaseUrl -Path $Path -Query $Query -Token $Token
        $resp = $req.GetResponse()
        $sr = New-Object IO.StreamReader ($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        $text = $sr.ReadToEnd(); $sr.Dispose()
        Add-MmlmTraffic -Bytes ([Text.Encoding]::UTF8.GetByteCount($text))
        if (-not $text) { return $null }
        $text | ConvertFrom-Json
    }
    catch [Net.WebException] {
        Add-MmlmTraffic -Failed
        $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        if ($code -eq 401 -or $code -eq 403) { throw 'Jellyfin refused the API key. Make one in Jellyfin: Dashboard > API Keys.' }
        if ($code -eq 404) { throw ('Jellyfin does not know {0} (is this a Jellyfin server?).' -f $Path) }
        throw ('Could not reach Jellyfin at {0}: {1}' -f $BaseUrl, $_.Exception.Message)
    }
    finally { if ($resp) { $resp.Close() } }
}

function Get-MmlmJellyfinInfo {
    # The server's name and version, and its movie and TV libraries (for Settings > Servers > Test).
    param([string]$BaseUrl, [string]$Token)
    $sys = Invoke-MmlmJellyfinJson -BaseUrl $BaseUrl -Path '/System/Info' -Token $Token
    [ordered]@{ name = [string]$sys.ServerName; version = [string]$sys.Version; libraries = @(Get-MmlmJellyfinLibraries -BaseUrl $BaseUrl -Token $Token | ForEach-Object { [ordered]@{ name = $_.Name; type = $_.Type } }) }
}

function Get-MmlmJellyfinLibraries {
    param([string]$BaseUrl, [string]$Token)
    foreach ($f in @(Invoke-MmlmJellyfinJson -BaseUrl $BaseUrl -Path '/Library/VirtualFolders' -Token $Token)) {
        $t = switch ([string]$f.CollectionType) { 'movies' { 'movie' } 'tvshows' { 'show' } default { '' } }
        if ($t) { [pscustomobject]@{ Id = [string]$f.ItemId; Name = [string]$f.Name; Type = $t } }
    }
}

function Get-MmlmJellyfinStubs {
    # Every movie or episode in one library, cheaply (id + Etag), in pages of 500.
    param([string]$BaseUrl, [string]$Token, $Library)
    $type = $(if ($Library.Type -eq 'show') { 'Episode' } else { 'Movie' })
    $start = 0
    do {
        $page = Invoke-MmlmJellyfinJson -BaseUrl $BaseUrl -Path '/Items' -Token $Token -Query @{
            ParentId = $Library.Id; Recursive = 'true'; IncludeItemTypes = $type; Fields = 'Etag'; EnableImages = 'false'; EnableUserData = 'false'
            SortBy = 'SortName'; StartIndex = $start; Limit = 500 }
        $items = @($page.Items)
        foreach ($it in $items) { [pscustomobject]@{ Key = 'jf-' + [string]$it.Id; Id = [string]$it.Id; Updated = [string]$it.Etag; Section = $Library.Name } }
        $start += $items.Count
    } while ($items.Count -gt 0 -and $start -lt [int]$page.TotalRecordCount)
}

function Get-MmlmJellyfinItems {
    # Full details for a batch of ids (one request).
    param([string]$BaseUrl, [string]$Token, [string[]]$Ids, [string]$Fields = $script:DetailFields)
    $map = @{}
    if (-not $Ids -or $Ids.Count -eq 0) { return $map }
    $r = Invoke-MmlmJellyfinJson -BaseUrl $BaseUrl -Path '/Items' -Token $Token -Query @{ Ids = ($Ids -join ','); Fields = $Fields; EnableUserData = 'false' }
    foreach ($it in @($r.Items)) { $map[[string]$it.Id] = $it }
    $map
}

function Get-MmlmJellyfinProp {
    # $o.Name, or $null when the property is missing (Jellyfin leaves out empty properties)
    param($o, [string]$Name)
    if ($null -eq $o) { return $null }
    $p = $o.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

function ConvertFrom-MmlmJellyfinItem {
    # One Jellyfin movie or episode -> a record with the same fields a Plex scan fills.
    param([Parameter(Mandatory)]$Item, [string]$LibraryName, $Series = $null)
    $P = { param($o, $n) Get-MmlmJellyfinProp $o $n }
    $rec  = New-MmlmEmptyRecord
    $isEp = ([string](& $P $Item 'Type') -eq 'Episode')
    $meta = $(if ($isEp -and $null -ne $Series) { $Series } else { $Item })      # genres, cast and studio live on the series

    # best version: the widest, then the biggest
    $srcs = @(& $P $Item 'MediaSources')
    $src = $srcs | Sort-Object @{ Expression = { $vw = @(@(& $P $_ 'MediaStreams') | Where-Object { (& $P $_ 'Type') -eq 'Video' }) | Select-Object -First 1; [int](& $P $vw 'Width') }; Descending = $true },
                                @{ Expression = { [double](& $P $_ 'Size') }; Descending = $true } | Select-Object -First 1
    $streams = @($(if ($src) { & $P $src 'MediaStreams' } else { & $P $Item 'MediaStreams' }))
    $vs    = $streams | Where-Object { (& $P $_ 'Type') -eq 'Video' } | Select-Object -First 1
    $audio = @($streams | Where-Object { (& $P $_ 'Type') -eq 'Audio' })
    $subs  = @($streams | Where-Object { (& $P $_ 'Type') -eq 'Subtitle' })
    $as    = $audio | Where-Object { (& $P $_ 'IsDefault') -eq $true } | Select-Object -First 1
    if ($null -eq $as) { $as = $audio | Select-Object -First 1 }

    # ---- titles / descriptive metadata
    $title = [string](& $P $Item 'Name')
    $rec.Library = $LibraryName
    if ($isEp) {
        $season = [int](& $P $Item 'ParentIndexNumber'); $epNum = [int](& $P $Item 'IndexNumber')
        $showTitle = [string](& $P $Item 'SeriesName')
        $rec.Show = $showTitle; $rec.Season = $season; $rec.Episode = $epNum
        $rec.Title = ('{0} - S{1:00}E{2:00} - {3}' -f $showTitle, $season, $epNum, $title)
    }
    else { $rec.Title = $title }
    $prem = [string](& $P $Item 'PremiereDate')
    if ($prem.Length -ge 10) { $rec.ReleaseDate = $prem.Substring(0, 10) }
    $year = [int](& $P $Item 'ProductionYear')
    if ($year -le 0 -and $rec.ReleaseDate.Length -ge 4) { $year = ConvertTo-MmlmSafeInt $rec.ReleaseDate.Substring(0, 4) }
    if ($year -le 0 -and $null -ne $Series) { $year = [int](& $P $Series 'ProductionYear') }
    $rec.Year = $year
    $rec.Genre = (@(& $P $meta 'Genres') | Where-Object { $_ }) -join ', '
    $mpaa = [string](& $P $Item 'OfficialRating'); if (-not $mpaa -and $Series) { $mpaa = [string](& $P $Series 'OfficialRating') }
    $rec.MPAARating = $mpaa
    $cr = [double](& $P $Item 'CommunityRating'); if ($cr -le 0 -and $Series) { $cr = [double](& $P $Series 'CommunityRating') }
    if ($cr -gt 0) { $rec.Rating = [math]::Round($cr, 1); $rec.RatingSource = 'Jellyfin' }
    $crit = [double](& $P $Item 'CriticRating'); if ($crit -le 0 -and -not $isEp -and $Series) { $crit = [double](& $P $Series 'CriticRating') }
    if ($crit -gt 0) { $rec.RTCritic = [int][math]::Round($crit) }                 # Jellyfin's critic score is Rotten Tomatoes' (no audience score)
    $rec.Studio = (@(& $P $meta 'Studios') | ForEach-Object { [string](& $P $_ 'Name') } | Where-Object { $_ } | Select-Object -First 1) -join ''
    $people = @(& $P $meta 'People')
    $rec.Director = (@(@(& $P $Item 'People') | Where-Object { (& $P $_ 'Type') -eq 'Director' } | ForEach-Object { [string](& $P $_ 'Name') }) | Select-Object -First 3) -join ', '
    $rec.Cast = (@($people | Where-Object { (& $P $_ 'Type') -eq 'Actor' } | ForEach-Object { [string](& $P $_ 'Name') }) | Select-Object -First 6) -join ', '
    $rec.Country = (@(& $P $meta 'ProductionLocations') | Where-Object { $_ }) -join ', '
    $rec.Tagline = (@(& $P $Item 'Taglines') | Select-Object -First 1) -join ''
    $rec.Plot = ([string](& $P $Item 'Overview')) -replace '\s+', ' '
    $ids = & $P $meta 'ProviderIds'
    $imdb = [string](& $P $ids 'Imdb'); $tmdb = [string](& $P $ids 'Tmdb')
    if ($imdb -match '^tt\d+$') { $rec.IMDBID = $imdb }
    if ($tmdb -match '^\d+$') { $rec.TMDBID = $tmdb }

    # ---- file / container
    $file = [string]$(if ($src) { & $P $src 'Path' } else { & $P $Item 'Path' })
    $ticks = [double]$(if ($src -and (& $P $src 'RunTimeTicks')) { & $P $src 'RunTimeTicks' } else { & $P $Item 'RunTimeTicks' })
    $size = [double]$(if ($src) { & $P $src 'Size' } else { 0 })
    $overall = [double]$(if ($src) { & $P $src 'Bitrate' } else { 0 })                 # bits per second
    $cont = ([string]$(if ($src) { & $P $src 'Container' } else { & $P $Item 'Container' })).Split(',')[0]
    $rec.RuntimeMin = [math]::Round($ticks / 600000000, 2)
    $rec.FileName = $(if ($file) { [IO.Path]::GetFileName($file) } else { '' })
    $rec.Ext = $(if ($file) { [IO.Path]::GetExtension($file).TrimStart('.').ToLowerInvariant() } else { $cont })
    $rec.Type = 'Video'
    $rec.Container = switch -Regex ($cont.ToLowerInvariant()) {
        '^(mkv|matroska)' { 'Matroska' }
        '^(mp4|m4v|mov)'  { 'MPEG-4' }
        '^avi'            { 'AVI' }
        '^(ts|mpegts)'    { 'MPEG-TS' }
        '^m2ts'           { 'BDAV' }
        default           { if ($cont) { $cont.ToUpperInvariant() } else { '' } }
    }
    $rec.FileSizeGB = [math]::Round($size / 1GB, 2)
    $rec.OverallBitRateMbps = [math]::Round($overall / 1000000, 2)
    $rec.Source = $(if ($file) { Get-MmlmSourceFromName ([IO.Path]::GetFileNameWithoutExtension($file)) } else { 'Unknown' })
    $created = [string](& $P $Item 'DateCreated')
    if ($created.Length -ge 19) { $rec.Added = $created.Substring(0, 19).Replace('T', ' ') }
    if ($file) { $cut = $file.LastIndexOfAny([char[]]@('\', '/')); $rec.Directory = $(if ($cut -gt 0) { $file.Substring(0, $cut) } else { '' }) }
    $rec.FullPath = $file
    $rec.HasNfo = $true                 # Jellyfin holds the metadata
    $rec.PlexKey = 'jf-' + [string](& $P $Item 'Id')
    $tags = & $P $Item 'ImageTags'
    if ($isEp -and (& $P $Item 'SeriesPrimaryImageTag') -and (& $P $Item 'SeriesId')) { $rec.PlexThumb = '/Items/' + [string](& $P $Item 'SeriesId') + '/Images/Primary' }
    elseif (& $P $tags 'Primary') { $rec.PlexThumb = '/Items/' + [string](& $P $Item 'Id') + '/Images/Primary' }

    # ---- video
    $w = [int](& $P $vs 'Width'); $h = [int](& $P $vs 'Height')
    $codecRaw = [string](& $P $vs 'Codec')
    $rec.VideoCodec = switch -Regex ($codecRaw.ToLowerInvariant()) {
        '^(hevc|h265)' { 'HEVC' } '^(h264|avc)' { 'AVC' } '^vc1' { 'VC-1' } '^mpeg2' { 'MPEG' } '^mpeg4' { 'MPEG-4 Visual' } '^av1' { 'AV1' } '^vp9' { 'VP9' }
        default { if ($codecRaw) { $codecRaw.ToUpperInvariant() } else { '' } }
    }
    $fps = [double](& $P $vs 'RealFrameRate'); if ($fps -le 0) { $fps = [double](& $P $vs 'AverageFrameRate') }
    $fps = [math]::Round($fps, 3)
    $vbr = [double](& $P $vs 'BitRate'); if ($vbr -le 0) { $vbr = $overall }
    $rec.Width = $w; $rec.Height = $h
    $rec.Resolution = $(if ($w -gt 0) { "${w}x${h}" } else { '' })
    $rec.ResolutionClass = Get-MmlmResolutionClass -Width $w -Height $h
    $ar = [string](& $P $vs 'AspectRatio')
    if ($ar -match '^(\d+(\.\d+)?):(\d+(\.\d+)?)$' -and [double]$Matches[3] -gt 0) { $rec.DAR = [math]::Round([double]$Matches[1] / [double]$Matches[3], 2) }
    elseif ($h -gt 0) { $rec.DAR = [math]::Round($w / $h, 2) }
    if ($vs) { $rec.FormatProfile = (Get-Culture).TextInfo.ToTitleCase([string](& $P $vs 'Profile')) }
    $rec.VideoBitRateMbps = [math]::Round($vbr / 1000000, 2)
    $rec.FrameRate = $fps
    $rec.BitsPerPixel = $(if (($w * $h * $fps) -gt 0 -and $vbr -gt 0) { [math]::Round($vbr / ($w * $h * $fps), 3) } else { 0.0 })
    if ($vs) {
        $rec.ScanType = $(if ((& $P $vs 'IsInterlaced') -eq $true) { 'Interlaced' } else { 'Progressive' })
        $bd = [int](& $P $vs 'BitDepth')
        if ($bd -le 0 -and [string](& $P $vs 'PixelFormat') -match 'p(10|12)') { $bd = [int]$Matches[1] }
        if ($bd -le 0 -and [string](& $P $vs 'PixelFormat')) { $bd = 8 }
        $rec.BitDepth = $bd
        $pf = [string](& $P $vs 'PixelFormat')
        $rec.ChromaSubsampling = switch -Regex ($pf) { 'yuv420' { '4:2:0' } 'yuv422' { '4:2:2' } 'yuv444' { '4:4:4' } default { '' } }
        $rng = [string](& $P $vs 'ColorRange')
        $rec.ColorRange = switch ($rng) { 'tv' { 'Limited' } 'pc' { 'Full' } default { $rng } }
    }

    # ---- HDR / Dolby Vision (Jellyfin 10.9+ reports the Dolby Vision configuration on the video stream)
    $rangeType = [string](& $P $vs 'VideoRangeType'); $trc = [string](& $P $vs 'ColorTransfer')
    $doviOn = ($rangeType -match '^DOVI') -or ([int](& $P $vs 'DvProfile') -gt 0)
    $hdr10p = ($rangeType -match 'HDR10Plus')
    $hdrType = $(if ($doviOn) { 'Dolby Vision' } elseif ($rangeType -match 'HDR10' -or $trc -eq 'smpte2084') { 'HDR10' } elseif ($rangeType -eq 'HLG' -or $trc -eq 'arib-std-b67') { 'HLG' } else { 'SDR' })
    $dv = [pscustomobject]@{ Profile = ''; Layer = ''; Base = '' }
    if ($doviOn) {
        $num = [int](& $P $vs 'DvProfile')
        $base = switch ([string](& $P $vs 'DvBlSignalCompatibilityId')) { '1' { 'HDR10' } '6' { 'HDR10' } '2' { 'SDR' } '4' { 'HLG' } default { 'None' } }
        if ($base -eq 'None') { $base = switch -Regex ($rangeType) { 'WithHDR10' { 'HDR10' } 'WithSDR' { 'SDR' } 'WithHLG' { 'HLG' } default { 'None' } } }
        if ($num -eq 5) { $base = 'None' }
        $prof = ''
        if ($num -gt 0) { $prof = "$num"; if ($num -in 8, 10) { switch ($base) { 'HDR10' { $prof = "$num.1" } 'SDR' { $prof = "$num.2" } 'HLG' { $prof = "$num.4" } } } }
        $dual = ([int](& $P $vs 'ElPresentFlag') -eq 1) -or ($num -in 4, 7)
        $dv.Profile = $prof; $dv.Base = $base
        $dv.Layer = $(if ($num -le 0) { '' } elseif ($dual) { 'Dual layer' } else { 'Single layer' })
    }
    $rec.HDRType = $hdrType; $rec.DVProfile = $dv.Profile; $rec.DVLayer = $dv.Layer; $rec.DVBase = $dv.Base
    $rec.HasHDR10Plus = $hdr10p
    $rec.HDRStack = Get-MmlmHdrStack -HdrType $hdrType -Dv $dv -HasHdr10Plus $hdr10p
    $rec.Source = Resolve-MmlmSourceLabel -Source $rec.Source -FileName $rec.FileName -HdrType $hdrType -DvProfile $dv.Profile
    $rec.HDRFormat = switch ($hdrType) { 'Dolby Vision' { 'Dolby Vision' } 'HDR10' { 'SMPTE ST 2084' } 'HLG' { 'HLG' } default { '' } }
    if ($doviOn) {
        $lvl = [int](& $P $vs 'DvLevel'); if ($lvl -gt 0) { $rec.HDRFormatLevel = '{0:00}' -f $lvl }
        $rec.HDRFormatSettings = $(if ($dv.Layer -eq 'Dual layer') { 'BL+EL+RPU' } else { 'BL+RPU' })
        $rec.HDRFormatCompat = $dv.Base
    }
    if ($vs) { $rec.Primaries = [string](& $P $vs 'ColorPrimaries'); $rec.Transfer = $trc; $rec.Matrix = [string](& $P $vs 'ColorSpace') }

    # ---- audio (the default / first track)
    if ($as) {
        $ch = [int](& $P $as 'Channels')
        $af = Get-MmlmPlexAudioFormat -Codec ([string](& $P $as 'Codec')) -Profile ([string](& $P $as 'Profile')) -Display ([string](& $P $as 'DisplayTitle'))
        $rec.AudioFormat = $af.Label; $rec.ObjectAudio = $af.Object
        $rec.AudioTitle = [string](& $P $as 'Title')
        $rec.AudioBitRateKbps = [int]([double](& $P $as 'BitRate') / 1000)
        $rec.AudioChannels = $ch; $rec.AudioLayout = Get-MmlmAudioLayout -Channels $ch
        $sr = [int](& $P $as 'SampleRate'); if ($sr -gt 0) { $rec.AudioSamplingRate = [string]$sr }
        $abd = [int](& $P $as 'BitDepth'); if ($abd -gt 0) { $rec.AudioBitDepth = [string]$abd }
    }
    $rec.AudioTracks = $audio.Count
    $rec.AudioLanguages = (@($audio | ForEach-Object { [string](& $P $_ 'Language') } | Where-Object { $_ } | Select-Object -Unique)) -join '; '
    $rec.SubtitleTracks = $subs.Count
    $rec.SubtitleLanguages = (@($subs | ForEach-Object { [string](& $P $_ 'Language') } | Where-Object { $_ } | Select-Object -Unique)) -join '; '
    $rec.SubtitleFormats = (@($subs | ForEach-Object { [string](& $P $_ 'Codec') } | Where-Object { $_ } | ForEach-Object { $_.ToUpperInvariant() } | Select-Object -Unique)) -join '; '
    [pscustomobject]$rec
}

function Save-MmlmJellyfinImage {
    # One picture from Jellyfin's image service into $Dest. $Fit 'fill' crops to the box (posters); 'fit' keeps the shape
    # (logos, banners). Returns 'saved', 'none' (Jellyfin has no such picture) or 'failed'.
    param([string]$BaseUrl, [string]$Token, [string]$Path, [int]$Width, [int]$Height, [string]$Dest, [ValidateSet('fill', 'fit')][string]$Fit = 'fill', [string]$Format = 'jpg')
    $q = $(if ($Fit -eq 'fill') { @{ fillWidth = $Width; fillHeight = $Height; quality = 90 } } else { @{ maxWidth = $Width; maxHeight = $Height; quality = 90 } })
    if ($Format -eq 'png') { $q.format = 'png' }
    $resp = $null
    try {
        Assert-MmlmTrafficAllowed
        $req = New-MmlmJellyfinRequest -BaseUrl $BaseUrl -Path $Path -Query $q -Token $Token -Accept 'image/*'
        $resp = $req.GetResponse()
        $ms = New-Object IO.MemoryStream
        try {
            $resp.GetResponseStream().CopyTo($ms)
            Add-MmlmTraffic -Bytes $ms.Length
            if ($ms.Length -gt 0) { [IO.File]::WriteAllBytes($Dest + '.part', $ms.ToArray()); Move-Item -LiteralPath ($Dest + '.part') -Destination $Dest -Force; return 'saved' }
        }
        finally { $ms.Dispose() }
        'none'
    }
    catch {
        $code = 0
        try { $code = [int]$_.Exception.InnerException.Response.StatusCode } catch { }
        if (-not $code) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
        if ($code -eq 404) { Add-MmlmTraffic; return 'none' }
        Add-MmlmTraffic -Failed
        'failed'
    }
    finally { if ($resp) { $resp.Close() } }
}

function Save-MmlmJellyfinPoster {
    # A small (240x360) poster in the thumbnail folder, as a Plex scan saves one.
    param([string]$BaseUrl, [string]$Token, [string]$ThumbPath)
    if ([string]::IsNullOrWhiteSpace($ThumbPath)) { return '' }
    $dest = Join-Path $script:ThumbFolder ('jf-' + (Get-MmlmStringHash ($BaseUrl.ToLowerInvariant() + '|' + $ThumbPath)) + '.jpg')
    if ((Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Length -gt 0)) { return $dest }
    if ((Save-MmlmJellyfinImage -BaseUrl $BaseUrl -Token $Token -Path $ThumbPath -Width 240 -Height 360 -Dest $dest -Fit fill) -eq 'saved') { return $dest }
    ''
}

function Get-MmlmJellyfinArtworkId {
    # 'jf<item id>' from a record's thumb, for the artwork file names (art-jf<id>.jpg), next to Plex's numeric ids
    param([string]$Thumb)
    if ($Thumb -match '^/Items/([0-9a-fA-F-]+)/Images/') { 'jf' + $Matches[1].Replace('-', '').ToLowerInvariant() } else { '' }
}

function Save-MmlmJellyfinArtwork {
    # Background art, clear logo or TV banner (Jellyfin's Backdrop, Logo, Banner images), saved as Plex's are:
    # <kind prefix>-<id>.<ext> with a .none marker when Jellyfin has none. Never cropped except background art.
    param([string]$BaseUrl, [string]$Token, [string]$Thumb, [ValidateSet('art', 'logo', 'banner')][string]$Kind, [string]$Folder, [switch]$Retry, [switch]$Force)
    $id = Get-MmlmJellyfinArtworkId $Thumb
    if (-not $id) { return 'none' }
    $item = ([regex]::Match($Thumb, '^/Items/([^/]+)/')).Groups[1].Value
    $ext = $(if ($Kind -eq 'logo') { 'png' } else { 'jpg' })
    $pre = @{ art = 'art'; logo = 'clogo'; banner = 'tvbanner' }[$Kind]
    $dest = Join-Path $Folder ('{0}-{1}.{2}' -f $pre, $id, $ext)
    $none = Join-Path $Folder ('{0}-{1}.none' -f $pre, $id)
    if (-not $Force -and (Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Length -gt 0)) { return 'have' }
    if ((Test-Path -LiteralPath $none) -and -not $Retry -and -not $Force) { return 'none' }
    $type = @{ art = 'Backdrop'; logo = 'Logo'; banner = 'Banner' }[$Kind]
    $size = @{ art = @(1280, 720); logo = @(800, 310); banner = @(1000, 185) }[$Kind]
    $r = Save-MmlmJellyfinImage -BaseUrl $BaseUrl -Token $Token -Path ('/Items/{0}/Images/{1}' -f $item, $type) -Width $size[0] -Height $size[1] -Dest $dest -Fit $(if ($Kind -eq 'art') { 'fill' } else { 'fit' }) -Format $ext
    if ($r -eq 'saved') { Remove-Item -LiteralPath $none -Force -ErrorAction SilentlyContinue }
    if ($r -eq 'none') { Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue; [IO.File]::WriteAllText($none, '') }
    $r
}

function Invoke-MmlmJellyfinScan {
    # The Jellyfin version of Invoke-MmlmPlexScan: list, reuse unchanged titles, read the rest in batches, posters.
    param([string]$BaseUrl, [string]$Token, [bool]$Movies, [bool]$Shows, [bool]$Rebuild, [bool]$DetectFel, [hashtable]$Prior = @{})
    Set-MmlmProgress -Text 'Connecting to Jellyfin...'
    $libs = @(Get-MmlmJellyfinLibraries -BaseUrl $BaseUrl -Token $Token | Where-Object { ($_.Type -eq 'movie' -and $Movies) -or ($_.Type -eq 'show' -and $Shows) })
    if ($libs.Count -eq 0) { throw 'This Jellyfin server has no movie / TV libraries matching your selection.' }

    # 1) list every item
    $stubs = New-Object System.Collections.Generic.List[object]
    Set-MmlmScanPhase -Lo 0.0 -Hi 0.05
    foreach ($l in $libs) { foreach ($s in @(Get-MmlmJellyfinStubs -BaseUrl $BaseUrl -Token $Token -Library $l)) { $stubs.Add($s) } }
    $script:Sync.Total = $stubs.Count
    if ($stubs.Count -eq 0) { return @() }

    # 2) reuse records whose Etag has not changed
    $byKey = @{}; $todo = New-Object System.Collections.Generic.List[object]
    Set-MmlmScanPhase -Lo 0.05 -Hi 0.10
    $chk = 0
    foreach ($s in $stubs) {
        $chk++
        if (($chk % 250) -eq 0) { if (Test-MmlmScanCancelled) { break }; Set-MmlmProgress -Text ('Checking for changes: {0} of {1}' -f $chk, $stubs.Count) -Value $chk -Max $stubs.Count }
        $p0 = $Prior[[string]$s.Key]
        if ($null -ne $p0 -and $s.Updated -and $p0.PSObject.Properties['PlexUpdated'] -and [string]$p0.PlexUpdated -eq [string]$s.Updated) { $byKey[$s.Key] = $p0; continue }
        $ck = Join-Path $script:CacheFolder ((Get-MmlmStringHash ('jellyfin|{0}|{1}|{2}|{3}' -f $BaseUrl.ToLowerInvariant(), $s.Key, $s.Updated, $script:CacheVersion)) + '.json')
        $s | Add-Member -NotePropertyName CacheFile -NotePropertyValue $ck -Force
        if ($Rebuild) { Remove-Item -LiteralPath $ck -Force -ErrorAction SilentlyContinue }
        $hit = $null
        if (Test-Path -LiteralPath $ck) { try { $hit = Repair-MmlmCachedRecord ([IO.File]::ReadAllText($ck, [Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { $hit = $null } }
        if ($hit) { $byKey[$s.Key] = $hit } else { $todo.Add($s) }
    }

    # 3) full details for the rest, 50 at a time; each show's details once
    $series = @{}
    $done = $stubs.Count - $todo.Count
    $postLo = $(if ($todo.Count -gt 0) { 0.8 } else { 0.10 })
    Set-MmlmScanPhase -Lo 0.10 -Hi $postLo
    for ($i = 0; $i -lt $todo.Count; $i += 50) {
        if (Test-MmlmScanCancelled) { break }
        $batch = @($todo.GetRange($i, [Math]::Min(50, $todo.Count - $i)))
        Set-MmlmProgress -Text ('Reading Jellyfin metadata: {0} of {1}' -f ($done + 1), $stubs.Count) -Value $done -Max $stubs.Count
        $map = Get-MmlmJellyfinItems -BaseUrl $BaseUrl -Token $Token -Ids @($batch | ForEach-Object { $_.Id })
        $need = @($map.Values | ForEach-Object { [string](Get-MmlmJellyfinProp $_ 'SeriesId') } | Where-Object { $_ -and -not $series.ContainsKey($_) } | Select-Object -Unique)
        if ($need.Count) { $sm = Get-MmlmJellyfinItems -BaseUrl $BaseUrl -Token $Token -Ids $need -Fields 'ProviderIds,Genres,Studios,People,Overview,ProductionLocations'; foreach ($k in $need) { $series[$k] = $sm[$k] } }
        foreach ($s in $batch) {
            $it = $map[$s.Id]
            if ($null -eq $it) { $done++; continue }
            try {
                $rec = ConvertFrom-MmlmJellyfinItem -Item $it -LibraryName $s.Section -Series $series[[string](Get-MmlmJellyfinProp $it 'SeriesId')]
                $byKey[$s.Key] = $rec
                [IO.File]::WriteAllText($s.CacheFile, ($rec | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding($false)))
            }
            catch { Write-Warning "Skipped Jellyfin item $($s.Id): $_" }
            $done++
        }
    }

    # 4) posters (one per distinct picture: an episode shares its show's), optional FEL/MEL probe, library order
    $out = New-Object System.Collections.Generic.List[object]
    $posterSeen = @{}; $n = 0
    Set-MmlmScanPhase -Lo $postLo -Hi 1.0
    foreach ($s in $stubs) {
        if (Test-MmlmScanCancelled) { break }
        $n++
        $rec = $byKey[$s.Key]
        if ($null -eq $rec) { continue }
        # remembered so the next scan can tell what changed (not a record field, so added when missing)
        $pu = $rec.PSObject.Properties['PlexUpdated']
        if ($null -ne $pu) { if ([string]$pu.Value -ne [string]$s.Updated) { $pu.Value = [string]$s.Updated } }
        else { $rec.PSObject.Properties.Add((New-Object Management.Automation.PSNoteProperty('PlexUpdated', [string]$s.Updated))) }
        if (($n % 5) -eq 0 -or $n -eq $stubs.Count) { Set-MmlmProgress -Text ('Posters: {0} of {1} titles ({2} distinct images)' -f $n, $stubs.Count, $posterSeen.Count) -Value $n -Max $stubs.Count }
        $th = [string]$rec.PlexThumb
        if ($th -and $posterSeen.ContainsKey($th)) { $rec.PosterPath = $posterSeen[$th]; $rec.HasPoster = [bool]$posterSeen[$th] }
        else {
            if (-not $rec.PosterPath -or -not (Test-Path -LiteralPath $rec.PosterPath)) {
                $poster = [string](@(Save-MmlmJellyfinPoster -BaseUrl $BaseUrl -Token $Token -ThumbPath $th) | Select-Object -Last 1)
                $rec.PosterPath = $poster; $rec.HasPoster = [bool]$poster
            }
            if ($th) { $posterSeen[$th] = [string]$rec.PosterPath }
        }
        if ($DetectFel -and $rec.DVLayer -eq 'Dual layer' -and $rec.FullPath -and (Test-Path -LiteralPath $rec.FullPath -ErrorAction SilentlyContinue)) {
            $layer = Get-MmlmDolbyVisionLayerType -Path $rec.FullPath -DurationSec ([int]([double]$rec.RuntimeMin * 60))
            if ($layer) { $rec.DVLayer = $layer; $rec.HDRStack = ([string]$rec.HDRStack) -replace '\(dual layer\)', $layer }
        }
        $out.Add($rec)
    }
    $out.ToArray()
}

Export-ModuleMember -Function @(
    'Set-MmlmJellyfinContext',
    'Invoke-MmlmJellyfinJson',
    'Get-MmlmJellyfinInfo',
    'Get-MmlmJellyfinLibraries',
    'Get-MmlmJellyfinStubs',
    'Get-MmlmJellyfinItems',
    'ConvertFrom-MmlmJellyfinItem',
    'Save-MmlmJellyfinPoster',
    'Get-MmlmJellyfinArtworkId',
    'Save-MmlmJellyfinArtwork',
    'Invoke-MmlmJellyfinScan'
)
