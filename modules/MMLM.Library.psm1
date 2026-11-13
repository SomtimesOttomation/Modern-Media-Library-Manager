# MMLM.Library.psm1 - part of Modern Media Library Manager. No windows, no UI: safe to load in any runspace.
#   Records and shared helpers: empty records, hashing, number parsing, resolution / HDR / audio labels, MediaInfo reading,
#   the local folder scan, .nfo sidecars, the metadata store, scan progress and cancel.
# Rules (DashLauncher contract): imported by full path; every exported name carries 'Mmlm'; no global state;
# settings, cache and logs live under %LOCALAPPDATA%. Scripts stay ASCII-only for Windows PowerShell 5.1.
# Shared values (progress hashtable, folders, field list ...) arrive through Set-MmlmContext.

function Set-MmlmContext {
    # Copies the shared values (Sync, CacheFolder, Fields ...) into this module's scope.
    param([hashtable]$Values)
    foreach ($k in @($Values.Keys)) { Set-Variable -Scope Script -Name $k -Value $Values[$k] }
}

function Initialize-MmlmNative {
    # The small C# helper (src\Mmlm.Native.cs: TV page data + library snapshot). Compiling takes a second or two, so it
    # is done on first use and the DLL is kept in %LOCALAPPDATA%; later starts just load it. Types are process-wide and
    # cannot be unloaded, so the DLL name carries the app version and a hash of the source: an update loads a new file.
    if ('Mmlm.Native.TvData' -as [type]) { return }
    $srcFile = Join-Path $script:AppRoot 'src\Mmlm.Native.cs'
    $code = [IO.File]::ReadAllText($srcFile)
    $dir = Join-Path $script:AppData 'Helper'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $name = 'Mmlm.Native-{0}-{1}.dll' -f $script:AppVersion, (Get-MmlmStringHash ($code + '|' + $PSVersionTable.PSVersion.Major)).Substring(0, 8)
    $dll = Join-Path $dir $name
    # older cached copies: not loaded in this process yet, so they can go now
    foreach ($old in @(Get-ChildItem -LiteralPath $dir -Filter '*.dll' -File -ErrorAction SilentlyContinue)) {
        if ($old.Name -ne $name -and ($old.Name -like 'Mmlm.Native-*' -or $old.Name -like 'MmlmHelper-*')) { Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue }
    }
    try {
        if (-not (Test-Path -LiteralPath $dll)) { Add-Type -TypeDefinition $code -Language CSharp -OutputAssembly $dll -OutputType Library -ErrorAction Stop }
        if (-not ('Mmlm.Native.TvData' -as [type])) { Add-Type -Path $dll -ErrorAction Stop }
    }
    catch {
        Remove-Item -LiteralPath $dll -Force -ErrorAction SilentlyContinue        # a half-written file must not be reused
        if (-not ('Mmlm.Native.TvData' -as [type])) { Add-Type -TypeDefinition $code -Language CSharp }
    }
}

function Add-MmlmTraffic {
    # Counts one request to a data source (Plex, TMDB, OMDb, IMDb) for the window's / launcher's traffic counter.
    param([long]$Bytes = 0, [switch]$Failed)
    $t = $script:Traffic
    if ($null -eq $t) { return }
    [Threading.Monitor]::Enter($t.SyncRoot)
    try { $t.Requests = [int]$t.Requests + 1; $t.Bytes = [long]$t.Bytes + $Bytes; if ($Failed) { $t.Errors = [int]$t.Errors + 1 } }
    finally { [Threading.Monitor]::Exit($t.SyncRoot) }
}

function Assert-MmlmTrafficAllowed {
    # After the kill switch / pause, no data source is contacted until the person resumes inside the app.
    if ($null -ne $script:Traffic -and $script:Traffic.Halted) { throw 'Traffic to data sources is paused.' }
}

function Set-MmlmProgress {
    # Scan progress for the window: the status text and the step bar (read by the UI thread's timer).
    param([string]$Text, [int]$Value = -1, [int]$Max = 0)
    if ($null -eq $script:Sync) { return }
    if ($Text) { $script:Sync.Text = $Text }
    if ($Max -gt 0 -and $Value -ge 0) { $script:Sync.Value = $Value; $script:Sync.Max = $Max }
}

function Add-MmlmScanTime {
    # Adds seconds to a named stage of the running scan (shown in Settings > Servers > Last scan timings).
    param([string]$Stage, [double]$Seconds, [int]$Count = 0)
    if ($null -eq $script:Sync) { return }
    if (-not $script:Sync.ContainsKey('Times') -or $null -eq $script:Sync.Times) { $script:Sync.Times = [ordered]@{} }
    $t = $script:Sync.Times
    if (-not $t.Contains($Stage)) { $t[$Stage] = @{ Seconds = 0.0; Count = 0 } }
    $t[$Stage].Seconds += $Seconds; $t[$Stage].Count += $Count
}

function ConvertTo-MmlmSafeInt {
    param($Value)
    $r = 0
    if ([int]::TryParse([string]$Value, [Globalization.NumberStyles]::Any, $script:Culture, [ref]$r)) { $r } else { 0 }
}
function ConvertTo-MmlmSafeDouble {
    param($Value)
    $r = 0.0
    if ([double]::TryParse([string]$Value, [Globalization.NumberStyles]::Any, $script:Culture, [ref]$r)) { $r } else { 0.0 }
}

function Join-MmlmUniqueList {
    # "English / English / French" (one entry per track) -> "English; French"
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $parts = @($Text -split '\s*/\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    $parts -join '; '
}

function Get-MmlmStringHash {
    param([Parameter(Mandatory)][string]$Text)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try   { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function New-MmlmEmptyRecord {
    $rec = [ordered]@{}
    foreach ($f in $script:Fields) {
        $rec[$f.Name] = switch ($f.Type) {
            'string' { '' }
            'int'    { 0 }
            'long'   { [long]0 }
            'double' { 0.0 }
            'bool'   { $false }
        }
    }
    $rec
}

function Get-MmlmResolutionClass {
    param([int]$Width, [int]$Height)
    if ($Width -le 0 -and $Height -le 0) { return 'Unknown' }
    if     ($Width -ge 3400 -or $Height -ge 2000) { '4K' }
    elseif ($Width -ge 2400 -or $Height -ge 1300) { '1440p' }
    elseif ($Width -ge 1800 -or $Height -ge 1000) { '1080p' }
    elseif ($Width -ge 1200 -or $Height -ge 700)  { '720p' }
    else                                          { 'SD' }
}

function Get-MmlmHdrType {
    param([string]$HdrFormat, [string]$Compat, [string]$Transfer)
    if ($HdrFormat -match 'Dolby Vision')                                   { return 'Dolby Vision' }
    if ($HdrFormat -match 'SMPTE ST 2094|HDR10\+' -or $Compat -match 'HDR10\+') { return 'HDR10+' }
    if ($HdrFormat -match 'SMPTE ST 2086|HDR10'   -or $Compat -match 'HDR10')   { return 'HDR10' }
    if ($Transfer  -match 'HLG|ARIB STD-B67')                               { return 'HLG' }
    if ($Transfer  -match 'PQ|SMPTE ST 2084')                               { return 'HDR10' }
    'SDR'
}

function Get-MmlmDolbyVisionInfo {
    # Works out the Dolby Vision profile (5, 7, 8.1, 8.2, 8.4 ...), single vs dual layer and the base-layer
    # compatibility from the several MediaInfo fields that describe it. MediaInfo cannot tell FEL from MEL -
    # a dual-layer file is reported as 'Dual layer' until the optional dovi_tool probe has looked at it.
    param([string]$Format, [string]$ProfileRaw, [string]$Settings, [string]$Compat, [string]$InfoString)

    $r = [pscustomobject]@{ Profile = ''; Layer = ''; Base = '' }
    if ($Format -notmatch 'Dolby Vision') { return $r }

    $num = 0; $sub = 0
    if ($ProfileRaw -match 'dv(?:he|h1|av1|a1)\.0*(\d+)') { $num = [int]$Matches[1] }
    if ($InfoString -match 'Profile\s+(\d+)(?:\.(\d))?') {
        if ($num -eq 0) { $num = [int]$Matches[1] }
        if ($Matches[2]) { $sub = [int]$Matches[2] }
    }

    # what a player without Dolby Vision would show (the "base layer")
    $base = 'None'
    if     ($Compat -match 'HLG')           { $base = 'HLG' }
    elseif ($Compat -match 'SDR')           { $base = 'SDR' }
    elseif ($Compat -match 'HDR10|Blu-ray') { $base = 'HDR10' }
    elseif ($sub -eq 1)                     { $base = 'HDR10' }
    elseif ($sub -eq 2)                     { $base = 'SDR' }
    elseif ($sub -eq 4)                     { $base = 'HLG' }
    if ($num -eq 5) { $base = 'None' }               # profile 5 has no backwards-compatible fallback

    $profile = ''
    if ($num -gt 0) {
        $profile = "$num"
        if ($num -in 8, 10) {
            switch ($base) {
                'HDR10' { $profile = "$num.1" }
                'SDR'   { $profile = "$num.2" }
                'HLG'   { $profile = "$num.4" }
            }
        }
    }

    $dual = ($Settings -match '\bEL\b') -or ($num -in 4, 7)
    $r.Profile = $profile
    $r.Layer   = if ($dual) { 'Dual layer' } else { 'Single layer' }
    $r.Base    = $base
    $r
}

function Get-MmlmHdrStack {
    # One readable label for the whole HDR picture, e.g. "Dolby Vision P8.1 + HDR10" or "Dolby Vision P7 FEL + HDR10".
    param([string]$HdrType, $Dv, [bool]$HasHdr10Plus)
    if ($HdrType -ne 'Dolby Vision') { return $HdrType }

    $label = 'Dolby Vision'
    if ($Dv.Profile) { $label += " P$($Dv.Profile)" }
    if     ($Dv.Layer -eq 'FEL')        { $label += ' FEL' }
    elseif ($Dv.Layer -eq 'MEL')        { $label += ' MEL' }
    elseif ($Dv.Layer -eq 'Dual layer') { $label += ' (dual layer)' }

    $fallback = @()
    if ($Dv.Base -in 'HDR10', 'HLG', 'SDR') { $fallback += $Dv.Base }
    if ($HasHdr10Plus)                      { $fallback += 'HDR10+' }
    if ($fallback.Count -gt 0) { $label += ' + ' + ($fallback -join ' + ') }
    $label
}

function Find-MmlmTool {
    # Looks for an executable in the lib folder next to the script first, then on PATH.
    param([Parameter(Mandatory)][string]$Name)
    $local = Join-Path $script:LibFolder $Name
    if (Test-Path -LiteralPath $local) { return $local }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $null
}

function Get-MmlmDolbyVisionLayerType {
    # Optional: tells FEL from MEL by pulling ~20 seconds of video through ffmpeg and reading the Dolby Vision
    # RPU with dovi_tool. Needs ffmpeg.exe and dovi_tool.exe (lib folder or PATH). Returns 'FEL', 'MEL' or ''.
    param([Parameter(Mandatory)][string]$Path, [int]$DurationSec = 0)

    $ffmpeg = Find-MmlmTool 'ffmpeg.exe'
    $dovi   = Find-MmlmTool 'dovi_tool.exe'
    if (-not $ffmpeg -or -not $dovi) { return '' }

    Set-MmlmWorkerStage 'FEL probe: waiting for a free slot' 0 4
    $work = Join-Path ([IO.Path]::GetTempPath()) ('dvprobe-' + [guid]::NewGuid().ToString('N'))
    New-Item -Path $work -ItemType Directory -Force | Out-Null
    # During a parallel scan only a couple of probes may run at once (ffmpeg reads a lot of video).
    $gate = $script:FelGate
    if ($gate) { [void]$gate.Wait() }
    try {
        $hevc = Join-Path $work 'sample.hevc'
        $rpu  = Join-Path $work 'rpu.bin'
        $seek = if ($DurationSec -gt 900) { 300 } else { 0 }      # skip studio logos on feature-length files

        Set-MmlmWorkerStage 'FEL probe: sampling video (ffmpeg)' 1 4
        & $ffmpeg -v error -nostdin -y -ss $seek -i $Path -map 0:v:0 -c:v copy -bsf:v hevc_mp4toannexb -t 20 -f hevc $hevc 2>$null
        if (-not (Test-Path -LiteralPath $hevc) -or (Get-Item -LiteralPath $hevc).Length -eq 0) { return '' }

        Set-MmlmWorkerStage 'FEL probe: extracting RPU' 2 4
        & $dovi extract-rpu -i $hevc -o $rpu 2>$null | Out-Null
        if (-not (Test-Path -LiteralPath $rpu)) { return '' }

        Set-MmlmWorkerStage 'FEL probe: analyzing RPU' 3 4
        $summary = (& $dovi info -i $rpu --summary 2>&1 | Out-String)
        if ($summary -match '\bFEL\b') { return 'FEL' }
        if ($summary -match '\bMEL\b') { return 'MEL' }
        $frame = (& $dovi info -i $rpu -f 0 2>&1 | Out-String)
        if ($frame -match '\bFEL\b') { return 'FEL' }
        if ($frame -match '\bMEL\b') { return 'MEL' }
        return ''
    }
    catch { return '' }
    finally {
        if ($gate) { [void]$gate.Release() }
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-MmlmAudioLabel {
    param([string]$Format, [string]$Commercial)
    $c = ($Commercial -replace '(?i)\s+with\s+Dolby\s+Atmos', '').Trim()
    if ($c) { return $c }
    switch ($Format) {
        'AC-3'    { 'Dolby Digital' }
        'E-AC-3'  { 'Dolby Digital Plus' }
        'MLP FBA' { 'Dolby TrueHD' }
        default   { if ($Format) { $Format } else { 'Unknown' } }
    }
}

function Get-MmlmAudioLayout {
    param([int]$Channels)
    switch ($Channels) {
        0       { 'Unknown' }
        1       { 'Mono' }
        2       { 'Stereo' }
        6       { '5.1' }
        7       { '6.1' }
        8       { '7.1' }
        default { "$Channels ch" }
    }
}

function Get-MmlmSourceFromName {
    param([string]$Name)
    if     ($Name -match '(?i)\bhybrid\b')                  { 'DV/HDR Hybrid' }      # e.g. a UHD remux with a Dolby Vision layer from a WEB-DL
    elseif ($Name -match '(?i)remux')                      { 'Remux' }
    elseif ($Name -match '(?i)blu-?ray|bdrip|brrip|\bbd\b'){ 'Blu-ray' }
    elseif ($Name -match '(?i)web[-. ]?dl|\bamzn\b|\bnf\b|\bdsnp\b') { 'WEB-DL' }
    elseif ($Name -match '(?i)web[-. ]?rip')               { 'WEBRip' }
    elseif ($Name -match '(?i)\bweb\b')                    { 'WEB-DL' }
    elseif ($Name -match '(?i)hdtv|pdtv')                  { 'HDTV' }
    elseif ($Name -match '(?i)dvdrip|\bdvd\b')             { 'DVD' }
    else                                                   { 'Unknown' }
}

function Resolve-MmlmSourceLabel {
    # Fine-tunes an 'Unknown' source from the Dolby Vision profile (the file name always wins):
    #   P7   -> UHD Blu-ray   (dual-layer is a disc format)
    #   P5   -> WEB-DL        (streaming, no HDR10 fallback)
    #   P8.1 -> DV/HDR Hybrid        (typically a UHD remux with the Dolby Vision layer taken from a WEB-DL)
    # Guessed values carry "(inferred)" so they are never mistaken for facts.
    param([string]$Source, [string]$FileName, [string]$HdrType, [string]$DvProfile)
    if ($FileName -match '(?i)\bhybrid\b') { return 'DV/HDR Hybrid' }
    if ($Source -like 'Hybrid*') { $Source = $Source -replace '^Hybrid', 'DV/HDR Hybrid' }      # label used by earlier builds
    if ($Source -and $Source -ne 'Unknown') { return $Source }
    if ($HdrType -ne 'Dolby Vision') { return 'Unknown' }
    switch ($DvProfile) {
        '7'   { 'UHD Blu-ray (inferred)' }
        '5'   { 'WEB-DL (inferred)' }
        '8.1' { 'DV/HDR Hybrid (inferred)' }
        default { 'Unknown' }
    }
}

function Initialize-MmlmMediaInfoModule {
    if ($script:MediaInfoInitialized) { return }

    if (-not (Get-Module -ListAvailable -Name Get-MediaInfo)) {
        Install-Module Get-MediaInfo -Scope CurrentUser -Force -ErrorAction Stop
    }
    $moduleInfo = Get-Module -ListAvailable -Name Get-MediaInfo | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $moduleInfo) { throw 'Get-MediaInfo module could not be found or installed.' }

    $dllPath = Join-Path $moduleInfo.ModuleBase 'MediaInfoSharp.dll'
    if (-not (Test-Path -LiteralPath $dllPath)) { throw "MediaInfoSharp.dll not found at '$dllPath'." }

    Add-Type -Path $dllPath
    $script:MediaInfoInitialized = $true
}

function Get-MmlmMiFirst {
    # First non-empty value among several candidate parameter names, flattened to one line (for CSV-friendly clue columns).
    param([string]$Kind, [string[]]$Names, [int]$Index = 0)
    foreach ($n in $Names) {
        $v = Get-MmlmMi $Kind $n $Index
        if ($v) { return (($v -replace '\s+', ' ').Trim()) }
    }
    ''
}

function Save-MmlmMediaInfoText {
    # Keeps MediaInfo's complete text for one file, so tags we do not know about yet can be found by reading it.
    # Best effort: if this MediaInfo wrapper exposes no Inform method, nothing is written.
    param($Mi, [string]$Leaf)
    try {
        if (-not $script:InformFolder) { return '' }
        if (-not (Test-Path -LiteralPath $script:InformFolder)) { New-Item -Path $script:InformFolder -ItemType Directory -Force | Out-Null }
        try { [void]$Mi.Option('Complete', '1') } catch { }
        $text = ''
        foreach ($m in @('Inform', 'Get_Inform')) {
            try { $text = [string]$Mi.$m(); if ($text) { break } } catch { }
        }
        if (-not $text) { return '' }
        $bad  = [IO.Path]::GetInvalidFileNameChars()
        $safe = -join ($Leaf.ToCharArray() | ForEach-Object { if ($bad -contains $_) { '_' } else { $_ } })
        $path = Join-Path $script:InformFolder ($safe + '.txt')
        [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
        $path
    }
    catch { '' }
}

function Get-MmlmMi {
    # Reads one value from the MediaInfo object currently being processed.
    param([string]$Kind, [string]$Param, [int]$Index = 0)
    try   { $val = $script:CurrentMi.GetInfo($Kind, $Index, $Param) }
    catch { return '' }
    if ($null -eq $val) { return '' }
    ([string]$val).Trim()
}
function Get-MmlmExternalAudioFiles {
    # Audio files that sit beside a video and share its name ("Movie.flac", "Movie.en.dts", "Movie - 5.1.flac").
    # They belong to that video; they are not separate titles.
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)
    $found = @()
    try {
        $base = $File.BaseName.ToLowerInvariant()
        foreach ($p in [IO.Directory]::GetFiles($File.DirectoryName)) {
            $e = [IO.Path]::GetExtension($p).TrimStart('.').ToLowerInvariant()
            if ($script:AudioExtensions -notcontains $e) { continue }
            if ($script:VideoExtensions -contains $e) { continue }
            if ([IO.Path]::GetFileNameWithoutExtension($p).ToLowerInvariant().StartsWith($base)) { $found += (New-Object IO.FileInfo($p)) }
        }
    }
    catch { }
    , $found
}

function Get-MmlmSidecarFiles {
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)

    $result = [pscustomobject]@{ Nfo = ''; Poster = '' }
    try {
        $names = @{}
        foreach ($p in [IO.Directory]::GetFiles($File.DirectoryName)) {
            $names[[IO.Path]::GetFileName($p).ToLowerInvariant()] = $p
        }
        $base = $File.BaseName.ToLowerInvariant()

        # NFO: "<file>.nfo" first, then movie.nfo, then any .nfo in the folder
        foreach ($cand in @("$base.nfo", 'movie.nfo')) {
            if ($names.ContainsKey($cand)) { $result.Nfo = $names[$cand]; break }
        }
        if (-not $result.Nfo) {
            $anyNfo = $names.Keys | Where-Object { $_ -like '*.nfo' } | Sort-Object | Select-Object -First 1
            if ($anyNfo) { $result.Nfo = $names[$anyNfo] }
        }

        # Poster: "<file>-poster.ext", "<file>.ext", then poster/folder/cover/movie/thumb.ext
        $stems = @("$base-poster", $base) + $script:PosterNames
        :search foreach ($stem in $stems) {
            foreach ($ext in $script:ImageExtensions) {
                $key = "$stem.$ext"
                if ($names.ContainsKey($key)) { $result.Poster = $names[$key]; break search }
            }
        }
    }
    catch { }
    $result
}

function Read-MmlmNfoRoot {
    param([string]$NfoPath)
    if (-not $NfoPath) { return $null }
    try {
        $raw = [IO.File]::ReadAllText($NfoPath, [Text.Encoding]::UTF8)
        # The leading comma stops PowerShell from unrolling the XmlElement into its child nodes.
        try { $xml = New-Object System.Xml.XmlDocument; $xml.LoadXml($raw); return ,$xml.DocumentElement }
        catch {
            # Some NFOs have junk (e.g. a URL) before/after the XML - grab the first element block.
            $m = [regex]::Match($raw, '<(movie|episodedetails|tvshow)\b.*</\1>', 'Singleline')
            if ($m.Success) { $xml = New-Object System.Xml.XmlDocument; $xml.LoadXml($m.Value); return ,$xml.DocumentElement }
        }
    }
    catch { }
    $null
}

function Get-MmlmNfoText {
    param($Root, [string]$XPath, [int]$Max = 100)
    if ($null -eq $Root) { return '' }
    try {
        $nodes = $Root.SelectNodes($XPath)
        if ($null -eq $nodes -or $nodes.Count -eq 0) { return '' }
        $vals = foreach ($n in $nodes) { $t = $n.InnerText.Trim(); if ($t) { $t } }
        (@($vals) | Select-Object -First $Max) -join '; '
    }
    catch { '' }
}
function Get-MmlmMediaInfoCachePath {
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)
    $key = '{0}|{1}|{2}' -f $File.FullName, $File.Length, $script:CacheVersion
    Join-Path $script:CacheFolder ((Get-MmlmStringHash $key) + '.json')
}

function Repair-MmlmCachedRecord {
    # PowerShell 7's ConvertFrom-Json turns ISO date strings into DateTime; keep them as plain text.
    param($Rec)
    foreach ($f in $script:Fields) {
        if ($f.Type -eq 'string') {
            $v = $Rec.($f.Name)
            if ($v -is [datetime]) { $Rec.($f.Name) = $v.ToString('yyyy-MM-dd') }
        }
    }
    $Rec.Source = Resolve-MmlmSourceLabel -Source ([string]$Rec.Source) -FileName ([string]$Rec.FileName) -HdrType ([string]$Rec.HDRType) -DvProfile ([string]$Rec.DVProfile)
    $Rec
}

function Get-MmlmMediaInfoRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][System.IO.FileInfo]$File,
        [switch]$RebuildCache,
        [switch]$DetectFel          # probe dual-layer Dolby Vision files with ffmpeg + dovi_tool to tell FEL from MEL
    )

    begin { Initialize-MmlmMediaInfoModule }

    process {
        $ext     = $File.Extension.TrimStart('.').ToLowerInvariant()
        $isVideo = $script:VideoExtensions -contains $ext
        $isAudio = (-not $isVideo) -and ($script:AudioExtensions -contains $ext)
        if (-not $isVideo -and -not $isAudio) { return }

        $cacheFile = Get-MmlmMediaInfoCachePath -File $File
        Set-MmlmWorkerStage 'Checking cache' 1 4
        if ($RebuildCache) { Remove-Item -LiteralPath $cacheFile -Force -ErrorAction SilentlyContinue }

        if (Test-Path -LiteralPath $cacheFile) {
            try {
                Set-MmlmWorkerStage 'Reading cache' 2 4
                $cached = [IO.File]::ReadAllText($cacheFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
                # Records saved before the clue columns existed are read again once (the file is re-opened below).
                if ($cached -and ($null -ne $cached.PSObject.Properties['WritingApp'])) {
                    $cached = Repair-MmlmCachedRecord $cached
                    # A cached dual-layer file can be upgraded to FEL/MEL later, when the probe is switched on.
                    if ($DetectFel -and $cached.DVLayer -eq 'Dual layer') {
                        $layer = Get-MmlmDolbyVisionLayerType -Path $File.FullName -DurationSec ([int]([double]$cached.RuntimeMin * 60))
                        if ($layer) {
                            $cached.DVLayer  = $layer
                            $cached.HDRStack = ([string]$cached.HDRStack) -replace '\(dual layer\)', $layer
                            try { [IO.File]::WriteAllText($cacheFile, ($cached | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding($false))) } catch { }
                        }
                    }
                    return $cached
                }
            }
            catch { }   # corrupt cache entry - rebuild below
        }

        $mi = $null
        try {
            Set-MmlmWorkerStage 'Opening file (MediaInfo)' 2 4
            $mi = New-Object MediaInfoSharp -ArgumentList $File.FullName
            $script:CurrentMi = $mi
            Set-MmlmWorkerStage 'Reading streams and tags' 3 4

            $rec   = New-MmlmEmptyRecord
            $kind  = if ($isVideo) { 'Video' } else { 'Audio' }
            $side  = Get-MmlmSidecarFiles -File $File
            $root  = if ($isVideo) { Read-MmlmNfoRoot -NfoPath $side.Nfo } else { $null }

            # ---- file / container ------------------------------------------------
            $rec.FileName           = $File.Name
            $rec.Ext                = $ext
            $rec.Type               = $kind
            $rec.Container          = Get-MmlmMi 'General' 'Format'
            $rec.FileSizeGB         = [math]::Round($File.Length / 1GB, 2)
            $rec.RuntimeMin         = [math]::Round((ConvertTo-MmlmSafeDouble (Get-MmlmMi 'General' 'Duration')) / 60000, 2)
            $overall                = ConvertTo-MmlmSafeDouble (Get-MmlmMi 'General' 'OverallBitRate')
            $rec.OverallBitRateMbps = [math]::Round($overall / 1000000, 2)
            $rec.Source             = Get-MmlmSourceFromName $File.BaseName
            $rec.Added              = $File.CreationTime.ToString('yyyy-MM-dd')
            $rec.Modified           = $File.LastWriteTime.ToString('yyyy-MM-dd')
            $rec.Directory          = $File.DirectoryName
            $rec.FullPath           = $File.FullName
            $rec.HasNfo             = [bool]$side.Nfo
            $rec.HasPoster          = [bool]$side.Poster
            $rec.PosterPath         = $side.Poster

            # ---- source clues -------------------------------------------------------
            $rec.WritingApp      = Get-MmlmMiFirst 'General' @('Encoded_Application/String', 'Encoded_Application')
            $rec.WritingLib      = Get-MmlmMiFirst 'General' @('Encoded_Library/String', 'Encoded_Library')
            $rec.EmbeddedTitle   = Get-MmlmMiFirst 'General' @('Movie', 'Title')
            $rec.EmbeddedComment = Get-MmlmMiFirst 'General' @('Comment', 'Description')
            $rec.OriginalMedia   = Get-MmlmMiFirst 'General' @('OriginalSourceMedium', 'Original_Source_Medium', 'ORIGINAL_MEDIA_TYPE', 'OriginalMediaType', 'Source')
            $rec.EncodedDate     = Get-MmlmMiFirst 'General' @('Encoded_Date', 'Tagged_Date')
            $chBegin = ConvertTo-MmlmSafeInt (Get-MmlmMi 'Menu' 'Chapters_Pos_Begin'); $chEnd = ConvertTo-MmlmSafeInt (Get-MmlmMi 'Menu' 'Chapters_Pos_End')
            $rec.Chapters        = if ($chEnd -gt $chBegin) { $chEnd - $chBegin } else { 0 }
            $rec.AudioFormatList = Join-MmlmUniqueList (Get-MmlmMi 'General' 'Audio_Format_List')
            $trackLabels = @()
            $trackCount  = [math]::Min((ConvertTo-MmlmSafeInt (Get-MmlmMi 'General' 'AudioCount')), 8)
            for ($ti = 0; $ti -lt $trackCount; $ti++) {
                $tc  = Get-MmlmMi 'Audio' 'Format_Commercial_IfAny' $ti
                $tl  = Get-MmlmAudioLabel -Format (Get-MmlmMi 'Audio' 'Format' $ti) -Commercial $tc
                $tch = ConvertTo-MmlmSafeInt (Get-MmlmMi 'Audio' 'Channels' $ti)
                if ($tc -match 'Atmos') { $tl += ' Atmos' }
                $trackLabels += ('{0} {1}' -f $tl, (Get-MmlmAudioLayout -Channels $tch))
            }
            if ($isVideo) {
                # external audio beside the video (e.g. Movie.flac next to Movie.mkv) is listed, marked "(external)"
                foreach ($extAudio in @(Get-MmlmExternalAudioFiles -File $File)) {
                    $mi2 = $null; $savedMi = $script:CurrentMi
                    try {
                        $mi2 = New-Object MediaInfoSharp -ArgumentList $extAudio.FullName
                        $script:CurrentMi = $mi2
                        $xf  = Get-MmlmMi 'Audio' 'Format'
                        $xl  = Get-MmlmAudioLabel -Format $xf -Commercial (Get-MmlmMi 'Audio' 'Format_Commercial_IfAny')
                        $xch = ConvertTo-MmlmSafeInt (Get-MmlmMi 'Audio' 'Channels')
                        $trackLabels += ('{0} {1} (external)' -f $xl, (Get-MmlmAudioLayout -Channels $xch))
                        $rec.AudioFormatList = (@($rec.AudioFormatList, ($xf + ' (external)')) | Where-Object { $_ }) -join '; '
                    }
                    catch { }
                    finally { $script:CurrentMi = $savedMi; if ($mi2) { $mi2.Dispose() } }
                }
            }
            $rec.AudioTrackList  = $trackLabels -join '; '
            $rec.InformFile      = Save-MmlmMediaInfoText -Mi $mi -Leaf ([IO.Path]::GetFileNameWithoutExtension($File.Name) + '-' + (Get-MmlmStringHash $File.FullName).Substring(0, 6))

            # ---- video -----------------------------------------------------------
            if ($isVideo) {
                $w   = ConvertTo-MmlmSafeInt (Get-MmlmMi 'Video' 'Width')
                $h   = ConvertTo-MmlmSafeInt (Get-MmlmMi 'Video' 'Height')
                $fps = ConvertTo-MmlmSafeDouble (Get-MmlmMi 'Video' 'FrameRate')
                $vbr = ConvertTo-MmlmSafeDouble (Get-MmlmMi 'Video' 'BitRate')
                if ($vbr -le 0) { $vbr = ConvertTo-MmlmSafeDouble (Get-MmlmMi 'Video' 'BitRate_Nominal') }
                if ($vbr -le 0) { $vbr = $overall }

                $codec = Get-MmlmMi 'Video' 'Format'
                if ($codec -eq 'MPEG Video') { $codec = 'MPEG' }

                $rec.Width             = $w
                $rec.Height            = $h
                $rec.Resolution        = if ($w -gt 0) { "${w}x${h}" } else { '' }
                $rec.ResolutionClass   = Get-MmlmResolutionClass -Width $w -Height $h
                $rec.DAR               = ConvertTo-MmlmSafeDouble (Get-MmlmMi 'Video' 'DisplayAspectRatio')
                $rec.VideoCodec        = $codec
                $rec.FormatProfile     = Get-MmlmMi 'Video' 'Format_Profile'
                $rec.VideoCodecID      = Get-MmlmMi 'Video' 'CodecID'
                $rec.VideoBitRateMbps  = [math]::Round($vbr / 1000000, 2)
                $rec.FrameRate         = $fps
                $rec.FrameRateMode     = Get-MmlmMi 'Video' 'FrameRate_Mode'
                $rec.BitsPerPixel      = if (($w * $h * $fps) -gt 0 -and $vbr -gt 0) { [math]::Round($vbr / ($w * $h * $fps), 3) } else { 0.0 }
                $rec.ScanType          = Get-MmlmMi 'Video' 'ScanType'
                $rec.BitDepth          = ConvertTo-MmlmSafeInt (Get-MmlmMi 'Video' 'BitDepth')
                $rec.ChromaSubsampling = Get-MmlmMi 'Video' 'ChromaSubsampling'
                $rec.ColorRange        = Get-MmlmMi 'Video' 'colour_range'
                $enc = Get-MmlmMi 'Video' 'Encoded_Library_Name'
                if (-not $enc) { $enc = Get-MmlmMi 'General' 'Encoded_Library_Name' }
                $rec.Encoder           = $enc
                $rec.VideoTitle        = Get-MmlmMi 'Video' 'Title'
                $rec.VideoEncLib       = Get-MmlmMiFirst 'Video' @('Encoded_Library/String', 'Encoded_Library')
                $encSettings           = Get-MmlmMiFirst 'Video' @('Encoded_Library_Settings')
                $rec.VideoEncSettings  = if ($encSettings.Length -gt 300) { $encSettings.Substring(0, 300) } else { $encSettings }

                $hdrFormat   = Get-MmlmMi 'Video' 'HDR_Format'
                $hdrCompat   = Get-MmlmMi 'Video' 'HDR_Format_Compatibility'
                $hdrProfRaw  = Get-MmlmMi 'Video' 'HDR_Format_Profile'
                $hdrSettings = Get-MmlmMi 'Video' 'HDR_Format_Settings'
                $hdrString   = Get-MmlmMi 'Video' 'HDR_Format/String'
                $transfer    = Get-MmlmMi 'Video' 'transfer_characteristics'

                $rec.HDRType           = Get-MmlmHdrType -HdrFormat $hdrFormat -Compat $hdrCompat -Transfer $transfer
                $dvInfo                = Get-MmlmDolbyVisionInfo -Format $hdrFormat -ProfileRaw $hdrProfRaw -Settings $hdrSettings -Compat $hdrCompat -InfoString $hdrString
                $hasHdr10Plus          = [bool](($hdrFormat -match 'SMPTE ST 2094|HDR10\+') -or ($hdrCompat -match 'HDR10\+'))
                if ($DetectFel -and $dvInfo.Layer -eq 'Dual layer') {
                    $probe = Get-MmlmDolbyVisionLayerType -Path $File.FullName -DurationSec ([int]($rec.RuntimeMin * 60))
                    if ($probe) { $dvInfo.Layer = $probe }
                }
                $rec.DVProfile         = $dvInfo.Profile
                $rec.DVLayer           = $dvInfo.Layer
                $rec.DVBase            = $dvInfo.Base
                $rec.HasHDR10Plus      = $hasHdr10Plus
                $rec.HDRStack          = Get-MmlmHdrStack -HdrType $rec.HDRType -Dv $dvInfo -HasHdr10Plus $hasHdr10Plus
                $rec.Source            = Resolve-MmlmSourceLabel -Source $rec.Source -FileName $File.Name -HdrType $rec.HDRType -DvProfile $rec.DVProfile
                $rec.HDRFormat         = $hdrFormat
                $hdrProfile            = $hdrProfRaw -replace '/', ''
                $rec.HDRFormatProfile  = $hdrProfile
                $rec.HDRFormatLevel    = (Get-MmlmMi 'Video' 'HDR_Format_Level') -replace '/', ''
                $rec.HDRFormatSettings = (Get-MmlmMi 'Video' 'HDR_Format_Settings') -replace '/', ''
                $rec.HDRFormatCompat   = $hdrCompat
                $rec.MaxCLL            = Get-MmlmMi 'Video' 'MaxCLL'
                $rec.MaxFALL           = Get-MmlmMi 'Video' 'MaxFALL'
                $rec.MasteringDisplay  = Get-MmlmMi 'Video' 'MasteringDisplay_Luminance'
                $rec.Primaries         = Get-MmlmMi 'Video' 'colour_primaries'
                $rec.Transfer          = $transfer
                $rec.Matrix            = Get-MmlmMi 'Video' 'matrix_coefficients'
            }

            # ---- audio (first track) ---------------------------------------------
            $aFormat = Get-MmlmMi 'Audio' 'Format'
            $aComm   = Get-MmlmMi 'Audio' 'Format_Commercial_IfAny'
            $aAddl   = Get-MmlmMi 'Audio' 'Format_AdditionalFeatures'
            $ch      = ConvertTo-MmlmSafeInt (Get-MmlmMi 'Audio' 'Channels')
            if ($ch -le 0) { $ch = ConvertTo-MmlmSafeInt (Get-MmlmMi 'Audio' 'Channel(s)') }

            $rec.AudioFormat       = Get-MmlmAudioLabel -Format $aFormat -Commercial $aComm
            $rec.ObjectAudio       = if ($aComm -match 'Atmos' -or $aAddl -match 'JOC') { 'Dolby Atmos' }
                                     elseif ($aAddl -match 'XLL X' -or $aComm -match 'DTS:X') { 'DTS:X' }
                                     else { '' }
            $rec.AudioTitle        = Get-MmlmMi 'Audio' 'Title'
            $rec.AudioCompression  = Get-MmlmMi 'Audio' 'Compression_Mode'
            $rec.AudioBitRateMode  = Get-MmlmMi 'Audio' 'BitRate_Mode'
            $rec.AudioBitRateKbps  = [int][math]::Round((ConvertTo-MmlmSafeDouble (Get-MmlmMi 'Audio' 'BitRate')) / 1000)
            $rec.AudioChannels     = $ch
            $rec.AudioLayout       = Get-MmlmAudioLayout -Channels $ch
            $rec.AudioSamplingRate = Get-MmlmMi 'Audio' 'SamplingRate'
            $rec.AudioBitDepth     = Get-MmlmMi 'Audio' 'BitDepth'
            $rec.AudioLanguages    = Join-MmlmUniqueList (Get-MmlmMi 'General' 'Audio_Language_List')
            $rec.AudioTracks       = ConvertTo-MmlmSafeInt (Get-MmlmMi 'General' 'AudioCount')

            # ---- subtitles --------------------------------------------------------
            $rec.SubtitleTracks    = ConvertTo-MmlmSafeInt (Get-MmlmMi 'General' 'TextCount')
            $rec.SubtitleLanguages = Join-MmlmUniqueList (Get-MmlmMi 'General' 'Text_Language_List')
            $rec.SubtitleFormats   = Join-MmlmUniqueList (Get-MmlmMi 'General' 'Text_Format_List')

            # ---- descriptive metadata (NFO, falling back to file tags / file name) -
            $title = Get-MmlmNfoText $root 'title'
            if (-not $title) { $title = Get-MmlmMi 'General' 'Title' }
            if (-not $title) { $title = $File.BaseName }
            $rec.Title       = $title
            $rec.ReleaseDate = Get-MmlmNfoText $root 'premiered'
            if (-not $rec.ReleaseDate) { $rec.ReleaseDate = Get-MmlmNfoText $root 'releasedate' }
            $year = ConvertTo-MmlmSafeInt (Get-MmlmNfoText $root 'year')
            if ($year -le 0 -and $rec.ReleaseDate.Length -ge 4) { $year = ConvertTo-MmlmSafeInt $rec.ReleaseDate.Substring(0, 4) }
            $rec.Year        = $year
            $rec.Genre       = Get-MmlmNfoText $root 'genre'
            $mpaa            = (Get-MmlmNfoText $root 'mpaa') -replace '(?i)^\s*(rated|usa?)[:\s]+', ''
            $rec.MPAARating  = $mpaa.Trim()
            $rating = Get-MmlmNfoText $root "ratings/rating[@name='imdb']/value"
            $rec.RatingSource = if ($rating) { 'IMDb' } else { '' }
            if (-not $rating) { $rating = (Get-MmlmNfoText $root 'ratings/rating/value') -split ';' | Select-Object -First 1 }
            if (-not $rating) { $rating = Get-MmlmNfoText $root 'rating' }
            $rec.Rating      = ConvertTo-MmlmSafeDouble $rating
            $votes = Get-MmlmNfoText $root "ratings/rating[@name='imdb']/votes"
            if (-not $votes) { $votes = Get-MmlmNfoText $root 'votes' }
            $rec.Votes       = ConvertTo-MmlmSafeInt $votes
            $rec.Studio      = Get-MmlmNfoText $root 'studio' 1
            $rec.Director    = Get-MmlmNfoText $root 'director'
            $rec.Cast        = Get-MmlmNfoText $root 'actor/name' 6
            $coll = Get-MmlmNfoText $root 'set/name'
            if (-not $coll) { $coll = Get-MmlmNfoText $root 'set[not(*)]' }
            $rec.Collection  = $coll
            $rec.Country     = Get-MmlmNfoText $root 'country'
            $rec.Tagline     = Get-MmlmNfoText $root 'tagline'
            $rec.Plot        = (Get-MmlmNfoText $root 'plot') -replace '\s+', ' '
            $imdb = Get-MmlmNfoText $root "uniqueid[@type='imdb']"
            if (-not $imdb) { $imdb = Get-MmlmNfoText $root 'imdbid' }
            if (-not $imdb) { $idTxt = Get-MmlmNfoText $root 'id'; if ($idTxt -match '^tt\d+$') { $imdb = $idTxt } }
            $rec.IMDBID      = $imdb
            $tmdb = Get-MmlmNfoText $root "uniqueid[@type='tmdb']"
            if (-not $tmdb) { $tmdb = Get-MmlmNfoText $root 'tmdbid' }
            $rec.TMDBID      = $tmdb

            $result = [pscustomobject]$rec
            Set-MmlmWorkerStage 'Writing cache' 4 4
            [IO.File]::WriteAllText($cacheFile, ($result | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding($false)))
            $result
        }
        catch {
            Write-Warning "Failed to read media info for '$($File.FullName)': $_"
        }
        finally {
            $script:CurrentMi = $null
            if ($mi) { $mi.Dispose() }
        }
    }
}
function Test-MmlmScanCancelled { [bool]$script:Sync.Cancel }
function Get-MmlmNowMs { [Diagnostics.Stopwatch]::GetTimestamp() * 1000.0 / [Diagnostics.Stopwatch]::Frequency }
function Set-MmlmWorkerStage {
    # Tells the Workers pane what this reader is doing right now (no-op outside a parallel scan).
    param([string]$Text, [int]$Step = 0, [int]$Of = 0)
    $w = $script:WStat
    if ($w) { $w.Stage = $Text; $w.Step = $Step; $w.Of = $Of }
}
function Set-MmlmScanPhase {
    # Starts a new step (reading details, posters, fetching info...): the STEP bar goes back to 0 % and its ETA starts over.
    # Lo..Hi is the slice (0..1) of the OVERALL bar that this step covers.
    param([double]$Lo = 0.0, [double]$Hi = 1.0)
    $sy = $script:Sync
    $sy.Max = 0; $sy.Value = 0
    $sy.PhaseLo = $Lo; $sy.PhaseHi = $Hi
    $sy.PhaseId = 1 + [int]$sy.PhaseId
}

# Fetched and hand-typed values live in one small JSON store, NOT in the media files and not in the scan cache:
#   manual values always win, fetched values fill empty fields (or replace them when "Replace existing values" was ticked).
function Set-MmlmRecField {
    # Cached records are plain objects that may predate a field - add the property when it is missing.
    param($Rec, [string]$Name, $Value)
    if ($null -ne $Rec.PSObject.Properties[$Name]) { $Rec.$Name = $Value }
    else { $Rec | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}

function Test-MmlmValueEmpty {
    param($Value)
    if ($null -eq $Value) { return $true }
    if ($Value -is [string]) { return [string]::IsNullOrWhiteSpace($Value) }
    if ($Value -is [ValueType]) { return ([double]$Value -eq 0) }
    $false
}

function Get-MmlmMetaKeys {
    # Every key a title can be filed under, best first (an IMDb id survives renames; title+year is the fallback).
    param($Rec)
    $keys = @()
    if ($Rec.IMDBID)  { $keys += ('imdb:' + [string]$Rec.IMDBID) }
    if ($Rec.TMDBID)  { $keys += ('tmdb:' + [string]$Rec.TMDBID) }
    $keys += ('t:' + ([string]$Rec.Title).ToLowerInvariant() + '|' + [string]$Rec.Year)
    $keys
}

function Read-MmlmMetaStore {
    param([string]$Path)
    $store = @{}
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $store }
    try {
        $j = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) {
            $e = @{ Manual = @{}; Scraped = @{}; Force = @(); Sources = @{}; At = [string]$p.Value.At }
            if ($p.Value.Manual)  { foreach ($q in $p.Value.Manual.PSObject.Properties)  { $e.Manual[$q.Name]  = $q.Value } }
            if ($p.Value.Scraped) { foreach ($q in $p.Value.Scraped.PSObject.Properties) { $e.Scraped[$q.Name] = $q.Value } }
            if ($p.Value.Sources) { foreach ($q in $p.Value.Sources.PSObject.Properties) { $e.Sources[$q.Name] = [string]$q.Value } }
            if ($p.Value.Force)   { $e.Force = @($p.Value.Force) }
            $store[$p.Name] = $e
        }
    }
    catch { }
    $store
}

function Merge-MmlmMetaStore {
    # Applies the store to freshly scanned records (the window app after every scan; the dash backend in its scan and when it prepares the page).
    # A title can be filed under several keys (IMDb id, TMDB id, title+year): all of them apply, fetched values first, typed-in values last.
    param([object[]]$Records, [string]$Path)
    $store = Read-MmlmMetaStore -Path $Path
    if ($store.Count -eq 0) { return }
    foreach ($rec in $Records) {
        $entries = @()
        foreach ($k in (Get-MmlmMetaKeys $rec)) { if ($store.ContainsKey($k)) { $entries += , $store[$k] } }
        if ($entries.Count -eq 0) { continue }
        [array]::Reverse($entries)                      # weakest key first, so the best key has the last word
        $manualNames = @{}
        foreach ($entry in $entries) { foreach ($n in $entry.Manual.Keys) { $manualNames[$n] = $true } }
        $notes = @()
        foreach ($entry in $entries) {
            foreach ($name in @($entry.Scraped.Keys)) {
                if ($manualNames.ContainsKey($name)) { continue }
                $cur = $rec.$name
                if ((Test-MmlmValueEmpty $cur) -or ($entry.Force -contains $name)) {
                    $f = $script:Fields | Where-Object { $_.Name -eq $name } | Select-Object -First 1
                    if ($null -eq $f) { continue }
                    try { Set-MmlmRecField $rec $name ([Convert]::ChangeType($entry.Scraped[$name], $script:TypeMap[$f.Type])) } catch { continue }
                    $notes += ('{0}: {1}' -f $name, $entry.Sources[$name])
                    if ($name -eq 'Rating') { Set-MmlmRecField $rec 'RatingSource' ([string]$entry.Sources[$name]) }
                }
            }
        }
        foreach ($entry in $entries) {
            foreach ($name in @($entry.Manual.Keys)) {
                $f = $script:Fields | Where-Object { $_.Name -eq $name } | Select-Object -First 1
                if ($null -eq $f) { continue }
                try { Set-MmlmRecField $rec $name ([Convert]::ChangeType($entry.Manual[$name], $script:TypeMap[$f.Type])) } catch { continue }
                $notes += ('{0}: manual' -f $name)
                if ($name -eq 'Rating') { Set-MmlmRecField $rec 'RatingSource' '' }
            }
        }
        if ($notes.Count -gt 0) { Set-MmlmRecField $rec 'MetaSources' ($notes -join '; ') }
    }
}

function Write-MmlmMetaStore {
    param([string]$Path, [hashtable]$Store)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $tmp = $Path + '.tmp'
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $Store -Depth 6), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Invoke-MmlmFolderScan {
    # Walks a folder (local or UNC), reads every media file and adds each finished record to $script:Sync.Partial.
    # Cancellable between files and between directories; a progress line is published as it goes.
    param([string]$Folder, [bool]$Video, [bool]$Audio, [bool]$Rebuild, [bool]$DetectFel, [int]$Parallel = 1)

    if (-not [IO.Directory]::Exists($Folder)) { throw "The folder was not found or cannot be reached:`n$Folder" }
    Initialize-MmlmMediaInfoModule

    $exts = @()
    if ($Video) { $exts += $script:VideoExtensions }
    if ($Audio) { $exts += $script:AudioExtensions }

    $paths = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Folder)
    while ($stack.Count -gt 0) {
        if (Test-MmlmScanCancelled) { return }
        $dir = $stack.Pop()
        try {
            foreach ($f in [IO.Directory]::EnumerateFiles($dir)) {
                $e = [IO.Path]::GetExtension($f).TrimStart('.').ToLowerInvariant()
                if ($exts -contains $e) { $paths.Add($f) }
            }
            foreach ($d in [IO.Directory]::EnumerateDirectories($dir)) { $stack.Push($d) }
        }
        catch { }          # unreadable folder: skip it
        Set-MmlmProgress -Text ('Enumerating files... {0} found' -f $paths.Count)
    }
    # External audio that belongs to a video in the same folder (Movie.mkv + Movie.flac) is not a title of its own.
    $videoBases = @{}
    foreach ($p in $paths) {
        if ($script:VideoExtensions -contains [IO.Path]::GetExtension($p).TrimStart('.').ToLowerInvariant()) {
            $d = [IO.Path]::GetDirectoryName($p)
            if (-not $videoBases.ContainsKey($d)) { $videoBases[$d] = New-Object System.Collections.Generic.List[string] }
            $videoBases[$d].Add([IO.Path]::GetFileNameWithoutExtension($p).ToLowerInvariant())
        }
    }
    if ($videoBases.Count -gt 0) {
        $kept = New-Object System.Collections.Generic.List[string]
        foreach ($p in $paths) {
            $isCompanion = $false
            if ($script:AudioExtensions -contains [IO.Path]::GetExtension($p).TrimStart('.').ToLowerInvariant()) {
                $d = [IO.Path]::GetDirectoryName($p)
                if ($videoBases.ContainsKey($d)) {
                    $ab = [IO.Path]::GetFileNameWithoutExtension($p).ToLowerInvariant()
                    foreach ($vb in $videoBases[$d]) { if ($ab.StartsWith($vb)) { $isCompanion = $true; break } }
                }
            }
            if (-not $isCompanion) { $kept.Add($p) }
        }
        $paths = $kept
    }
    $script:Sync.Total = $paths.Count
    if ($paths.Count -eq 0) { return }

    $sorted = @($paths | Sort-Object)
    $workers = [Math]::Max(1, [Math]::Min([Math]::Min(12, [int]$Parallel), $sorted.Count))

    if ($sorted.Count -lt 2 -or -not $script:FunctionCode) {
        $i = 0
        foreach ($p in $sorted) {
            if (Test-MmlmScanCancelled) { break }
            $i++
            Set-MmlmProgress -Text ('Reading {0} of {1}: {2}' -f $i, $sorted.Count, [IO.Path]::GetFileName($p)) -Value $i -Max $sorted.Count
            try {
                $fi  = New-Object IO.FileInfo($p)
                $rec = Get-MmlmMediaInfoRecord -File $fi -RebuildCache:$Rebuild -DetectFel:$DetectFel
                if ($rec) { [void]$script:Sync.Partial.Add($rec) }
            }
            catch { }
        }
        return
    }

    # ---- parallel: N reader runspaces pull file numbers from one shared queue ---------------------------
    $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[int]'
    for ($k = 0; $k -lt $sorted.Count; $k++) { $queue.Enqueue($k) }
    $slots  = New-Object 'object[]' $sorted.Count
    $shared = [hashtable]::Synchronized(@{ Done = 0; Error = $null })
    $gate   = New-Object System.Threading.SemaphoreSlim -ArgumentList 4
    $stats  = New-Object 'object[]' 13           # one live status record per reader, shown by the Workers pane
    for ($k = 1; $k -le 12; $k++) {
        $stats[$k] = [hashtable]::Synchronized(@{ No = $k; State = 'Not started'; File = ''; Stage = ''; Step = 0; Of = 4; Since = 0.0; Started = 0.0; Done = 0; BusyMs = 0.0 })
    }
    $script:Sync.WorkerStats = $stats

    $childScript = $script:FunctionCode + @'
Set-MmlmContext -Values @{ WStat = $WStat; FelGate = $FelGate }        # this reader's own status record and the FEL probe gate
try {
    $idx = 0
    if ([double]$WStat.Started -eq 0) { $WStat.Started = Get-MmlmNowMs }
    $WStat.State = 'Idle'
    # A reader whose number is above the current target (the box can be changed mid-scan) stops after its file.
    while (-not (Test-MmlmScanCancelled) -and ($WorkerNo -le [int]$script:Sync.Workers) -and $Queue.TryDequeue([ref]$idx)) {
        $p = $Paths[$idx]
        $WStat.File = [IO.Path]::GetFileName($p); $WStat.Stage = 'Starting'; $WStat.Step = 0; $WStat.Of = 4
        $WStat.Since = Get-MmlmNowMs; $WStat.State = 'Reading'
        try {
            $fi  = New-Object IO.FileInfo($p)
            $rec = Get-MmlmMediaInfoRecord -File $fi -RebuildCache:$Rebuild -DetectFel:$DetectFel
            if ($rec) { $Slots[$idx] = $rec; [void]$script:Sync.Partial.Add($rec) }
        }
        catch { }
        $WStat.BusyMs = [double]$WStat.BusyMs + ((Get-MmlmNowMs) - [double]$WStat.Since)
        $WStat.Done = [int]$WStat.Done + 1
        $WStat.State = 'Idle'; $WStat.Stage = 'Finished file'; $WStat.Step = 4
        [System.Threading.Monitor]::Enter($Shared.SyncRoot)
        try {
            $Shared.Done = [int]$Shared.Done + 1
            Set-MmlmProgress -Text ('Reading {0} of {1}: {2}' -f $Shared.Done, $Paths.Count, [IO.Path]::GetFileName($p)) -Value $Shared.Done -Max $Paths.Count
        }
        finally { [System.Threading.Monitor]::Exit($Shared.SyncRoot) }
    }
    $WStat.State = if (Test-MmlmScanCancelled) { 'Cancelled' } elseif ($WorkerNo -gt [int]$script:Sync.Workers) { 'Stopped' } else { 'Finished' }
    $WStat.Stage = ''
}
catch { $Shared.Error = $_.Exception.Message; $WStat.State = 'Error' }
'@

    $kids    = New-Object System.Collections.Generic.List[object]      # every reader ever started (cleaned up at the end)
    $readers = New-Object 'object[]' 13                                 # the current reader for each number 1..12
    $script:Sync.Workers = [Math]::Max(1, [Math]::Min(12, [int]$Parallel))

    $addReader = {
        param([int]$no)
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'MTA'
        $rs.Open()
        foreach ($key in @($script:WorkerVars.Keys)) { $rs.SessionStateProxy.SetVariable($key, $script:WorkerVars[$key]) }
        $rs.SessionStateProxy.SetVariable('WorkerVars', $script:WorkerVars)      # the reader's modules get their context from it
        $rs.SessionStateProxy.SetVariable('Queue',     $queue)
        $rs.SessionStateProxy.SetVariable('Paths',     $sorted)
        $rs.SessionStateProxy.SetVariable('Slots',     $slots)
        $rs.SessionStateProxy.SetVariable('Shared',    $shared)
        $rs.SessionStateProxy.SetVariable('Rebuild',   $Rebuild)
        $rs.SessionStateProxy.SetVariable('DetectFel', $DetectFel)
        $rs.SessionStateProxy.SetVariable('FelGate',   $gate)
        $rs.SessionStateProxy.SetVariable('WorkerNo',  $no)
        $rs.SessionStateProxy.SetVariable('WStat',     $stats[$no])
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($childScript)
        $kid = [pscustomobject]@{ Ps = $ps; Rs = $rs; Handle = $ps.BeginInvoke() }
        $kids.Add($kid)
        $kid
    }

    try {
        $started = 0
        while ($true) {
            # (re)start readers up to the current target; the box can be raised or lowered while the scan runs
            if (-not (Test-MmlmScanCancelled) -and -not $queue.IsEmpty -and $started -lt 80) {
                $target = [Math]::Max(1, [Math]::Min(12, [int]$script:Sync.Workers))
                for ($no = 1; $no -le $target; $no++) {
                    $cur = $readers[$no]
                    if ($null -eq $cur -or $cur.Handle.IsCompleted) { $readers[$no] = & $addReader $no; $started++ }
                }
            }
            $alive = 0
            for ($no = 1; $no -le 12; $no++) {
                if ($null -ne $readers[$no] -and -not $readers[$no].Handle.IsCompleted) { $alive++ }
            }
            $script:Sync.Active = $alive
            if ($alive -eq 0) { break }
            Start-Sleep -Milliseconds 120
        }
    }
    finally {
        foreach ($kid in $kids) {
            try { if ($kid.Handle.IsCompleted) { $kid.Ps.EndInvoke($kid.Handle) | Out-Null } } catch { }
            try { $kid.Ps.Dispose() } catch { }
            try { $kid.Rs.Dispose() } catch { }
        }
        try { $gate.Dispose() } catch { }
    }

    # put the records back in library (path) order
    $ordered = @($slots | Where-Object { $null -ne $_ })
    if ($ordered.Count -eq 0 -and $shared.Error -and -not (Test-MmlmScanCancelled)) { throw $shared.Error }
    $script:Sync.Partial.Clear()
    foreach ($r in $ordered) { [void]$script:Sync.Partial.Add($r) }
}

Export-ModuleMember -Function @(
    'Add-MmlmScanTime',
    'Set-MmlmContext',
    'ConvertTo-MmlmSafeInt',
    'ConvertTo-MmlmSafeDouble',
    'Join-MmlmUniqueList',
    'Get-MmlmStringHash',
    'New-MmlmEmptyRecord',
    'Get-MmlmResolutionClass',
    'Get-MmlmHdrType',
    'Get-MmlmDolbyVisionInfo',
    'Get-MmlmHdrStack',
    'Find-MmlmTool',
    'Get-MmlmDolbyVisionLayerType',
    'Get-MmlmAudioLabel',
    'Get-MmlmAudioLayout',
    'Get-MmlmSourceFromName',
    'Resolve-MmlmSourceLabel',
    'Initialize-MmlmMediaInfoModule',
    'Get-MmlmMiFirst',
    'Save-MmlmMediaInfoText',
    'Get-MmlmMi',
    'Get-MmlmExternalAudioFiles',
    'Get-MmlmSidecarFiles',
    'Read-MmlmNfoRoot',
    'Get-MmlmNfoText',
    'Get-MmlmMediaInfoCachePath',
    'Repair-MmlmCachedRecord',
    'Get-MmlmMediaInfoRecord',
    'Test-MmlmScanCancelled',
    'Get-MmlmNowMs',
    'Set-MmlmWorkerStage',
    'Set-MmlmScanPhase',
    'Set-MmlmRecField',
    'Test-MmlmValueEmpty',
    'Get-MmlmMetaKeys',
    'Read-MmlmMetaStore',
    'Write-MmlmMetaStore',
    'Merge-MmlmMetaStore',
    'Invoke-MmlmFolderScan',
    'Set-MmlmProgress',
    'Initialize-MmlmNative',
    'Add-MmlmTraffic',
    'Assert-MmlmTrafficAllowed'
)
