#Requires -Version 5.1
<#
    MMLM.MediaInfo - brightness (MaxCLL / MaxFALL) for movies, read from the files themselves with the MediaInfo
    command-line program. Plex does not report these.

    Nothing is downloaded or installed: MMLM uses a MediaInfo CLI that is already on this PC (a path set in
    Settings > Compare, lib\MediaInfo.exe beside the app, or "mediainfo" on the PATH, which is where winget puts it).
    Files are read where this PC can reach them; a server path can be mapped to a local one (Settings > Compare).

    Saved results: <AppData>\Library\mediainfo-movies.json, one entry per title key:
        { "cll": 1000, "fall": 400, "len": <bytes>, "mt": "<last write, ticks>", "err": "" }
    A title is read again only when its file's size or date changed (or after "Read again").
#>
Set-StrictMode -Version 2.0

function Test-MmlmWindowedExe {
    # $true when this .exe is a windowed (GUI) program, read from its header without running it. The windowed
    # MediaInfo opens an empty window for every file it is given, so it must never be used as the command-line one.
    param([string]$Path)
    try {
        $fs = [IO.File]::OpenRead($Path)
        try {
            $br = New-Object IO.BinaryReader($fs)
            if ($fs.Length -lt 64 -or $br.ReadUInt16() -ne 0x5A4D) { return $false }   # not "MZ": not a Windows program
            $fs.Position = 0x3C; $pe = $br.ReadInt32()
            if ($pe -le 0 -or $pe + 0x5E -gt $fs.Length) { return $false }
            $fs.Position = $pe; if ($br.ReadUInt32() -ne 0x00004550) { return $false }   # "PE\0\0"
            $fs.Position = $pe + 0x5C
            return ($br.ReadUInt16() -eq 2)   # subsystem 2 = Windows GUI, 3 = console
        }
        finally { $fs.Dispose() }
    }
    catch { $false }
}

function Find-MmlmMediaInfoCli {
    # The MediaInfo command-line program to use, or '' when there is none. Never downloads anything. The windowed
    # MediaInfo app is skipped (see Test-MmlmWindowedExe); $script:MediaInfoGuiSkipped names the last one skipped.
    param([string]$Custom, [string]$AppRoot)
    $script:MediaInfoGuiSkipped = ''
    $cands = New-Object System.Collections.Generic.List[string]
    if ($Custom) { $cands.Add($Custom) }
    if ($AppRoot) {
        foreach ($rel in 'lib\MediaInfo.exe', 'lib\MediaInfo\MediaInfo.exe', 'lib\mediainfo', 'lib/mediainfo') { $cands.Add((Join-Path $AppRoot $rel)) }
    }
    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) {
            $full = (Resolve-Path -LiteralPath $c).ProviderPath
            if (Test-MmlmWindowedExe $full) { $script:MediaInfoGuiSkipped = $full; continue }
            return $full
        }
    }
    foreach ($cmd in @(Get-Command -Name 'mediainfo' -CommandType Application -ErrorAction SilentlyContinue)) {
        if (Test-MmlmWindowedExe ([string]$cmd.Source)) { $script:MediaInfoGuiSkipped = [string]$cmd.Source; continue }
        return [string]$cmd.Source
    }
    ''
}
function Get-MmlmMediaInfoGuiSkipped { [string]$script:MediaInfoGuiSkipped }

function Invoke-MmlmMediaInfoCli {
    # Runs the CLI with these arguments; returns @{ Code; Out; Err }. Stops it after $TimeoutMs.
    param([string]$Cli, [string]$Arguments, [int]$TimeoutMs = 60000)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Cli
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $p = New-Object Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutMs)) {
        try { $p.Kill() } catch { }
        throw ('MediaInfo took longer than {0} seconds.' -f [int]($TimeoutMs / 1000))
    }
    $p.WaitForExit()
    @{ Code = $p.ExitCode; Out = [string]$outTask.Result; Err = [string]$errTask.Result }
}

function Get-MmlmMediaInfoVersion {
    param([string]$Cli)
    try {
        $r = Invoke-MmlmMediaInfoCli -Cli $Cli -Arguments '--Version' -TimeoutMs 15000
        $m = [regex]::Match($r.Out, 'v(\d+(\.\d+)+)')
        if ($m.Success) { return $m.Groups[1].Value }
        return ($r.Out.Trim() -split "`n")[-1].Trim()
    }
    catch { '' }
}

function ConvertTo-MmlmNits {
    # "1000 cd/m2" -> 1000; anything without a number -> 0
    param([string]$Text)
    $m = [regex]::Match([string]$Text, '(\d+(\.\d+)?)')
    if (-not $m.Success) { return 0 }
    [int][Math]::Round([double]::Parse($m.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture))
}

function Read-MmlmBrightness {
    # MaxCLL and MaxFALL of one video file, from its first video stream. Returns @{ Cll; Fall }; 0 when the file has
    # none (SDR, or HDR mastered without them). Throws when MediaInfo cannot read the file.
    param([string]$Cli, [string]$Path)
    $r = Invoke-MmlmMediaInfoCli -Cli $Cli -Arguments ('--Inform="Video;%MaxCLL%|%MaxFALL%\n" "' + $Path + '"')
    if ($r.Code -ne 0 -and -not $r.Out.Trim()) { throw ('MediaInfo could not read the file. ' + $r.Err.Trim()) }
    $line = (@($r.Out -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($null -eq $line) { return @{ Cll = 0; Fall = 0 } }
    $parts = ([string]$line).Split('|')
    @{ Cll = (ConvertTo-MmlmNits $parts[0]); Fall = $(if ($parts.Count -gt 1) { ConvertTo-MmlmNits $parts[1] } else { 0 }) }
}

function Resolve-MmlmLocalPath {
    # The server's path for a file, as this PC sees it: the mapped prefix swapped in (case-insensitive) and the
    # slashes turned to the local kind. With no map the path is used as it is.
    param([string]$Path, [string]$From, [string]$To)
    if (-not $Path) { return '' }
    $p = $Path
    if ($From -and $p.StartsWith($From, [StringComparison]::OrdinalIgnoreCase)) {
        $p = $To + $p.Substring($From.Length)
        $sep = [IO.Path]::DirectorySeparatorChar
        if ($To -match '^[A-Za-z]:|^\\\\') { $sep = '\' } elseif ($To.StartsWith('/')) { $sep = '/' }
        $p = $p.Replace('/', $sep).Replace('\', $sep)
        if ($sep -eq '\' -and $To.StartsWith('\\')) { $p = '\\' + $p.TrimStart('\') }
    }
    $p
}

function Read-MmlmBrightnessStore {
    param([string]$File)
    $o = @{}
    if (-not (Test-Path -LiteralPath $File)) { return $o }
    try {
        $j = [IO.File]::ReadAllText($File) | ConvertFrom-Json
        foreach ($pr in $j.PSObject.Properties) {
            $v = $pr.Value
            $o[$pr.Name] = @{ cll = [int]$v.cll; fall = [int]$v.fall; len = [long]$v.len; mt = [string]$v.mt; err = [string]$v.err }
        }
    }
    catch { }
    $o
}
function Save-MmlmBrightnessStore {
    param([string]$File, [hashtable]$Store)
    $dir = Split-Path -Parent $File
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $ord = [ordered]@{}
    foreach ($k in ($Store.Keys | Sort-Object)) { $ord[$k] = $Store[$k] }
    [IO.File]::WriteAllText($File + '.tmp', (ConvertTo-Json -InputObject $ord -Depth 3 -Compress), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath ($File + '.tmp') -Destination $File -Force
}

function Update-MmlmBrightness {
    # Reads brightness for these titles (@{ Key; Path } each) into the store file. A title whose file has not changed
    # since it was last read is skipped unless -Force. Saves every 25 titles, so a long run that is stopped keeps
    # what it read. Returns @{ Read; Skipped; Unreachable; Failed; Total }.
    param([string]$Cli, [object[]]$Titles, [string]$StoreFile, [string]$MapFrom, [string]$MapTo, [switch]$Force, $Sync)
    $store = Read-MmlmBrightnessStore $StoreFile
    $res = @{ Read = 0; Skipped = 0; Unreachable = 0; Failed = 0; Total = @($Titles).Count }
    $n = 0; $dirty = 0
    foreach ($t in @($Titles)) {
        if ($Sync -and $Sync.Cancel) { break }
        $n++
        if ($Sync) { $Sync.Text = ('MediaInfo: {0} of {1}' -f $n, $res.Total); $Sync.Value = $n; $Sync.Max = $res.Total }
        $key = [string]$t.Key
        $local = Resolve-MmlmLocalPath -Path ([string]$t.Path) -From $MapFrom -To $MapTo
        $fi = $null
        try { if ($local -and (Test-Path -LiteralPath $local -PathType Leaf)) { $fi = Get-Item -LiteralPath $local } } catch { }
        if ($null -eq $fi) {
            $res.Unreachable++
            $store[$key] = @{ cll = 0; fall = 0; len = 0; mt = ''; err = 'unreachable' }
            $dirty++
            continue
        }
        $old = $store[$key]
        $mt = [string]$fi.LastWriteTimeUtc.Ticks
        if (-not $Force -and $old -and -not $old.err -and $old.len -eq $fi.Length -and $old.mt -eq $mt) { $res.Skipped++; continue }
        try {
            $b = Read-MmlmBrightness -Cli $Cli -Path $fi.FullName
            $store[$key] = @{ cll = [int]$b.Cll; fall = [int]$b.Fall; len = [long]$fi.Length; mt = $mt; err = '' }
            $res.Read++
        }
        catch {
            $store[$key] = @{ cll = 0; fall = 0; len = [long]$fi.Length; mt = $mt; err = [string]$_.Exception.Message }
            $res.Failed++
        }
        $dirty++
        if ($dirty -ge 25) { Save-MmlmBrightnessStore $StoreFile $store; $dirty = 0 }
    }
    if ($dirty -gt 0) { Save-MmlmBrightnessStore $StoreFile $store }
    $res
}

Export-ModuleMember -Function @(
    'Find-MmlmMediaInfoCli',
    'Test-MmlmWindowedExe',
    'Get-MmlmMediaInfoGuiSkipped',
    'Get-MmlmMediaInfoVersion',
    'Read-MmlmBrightness',
    'Resolve-MmlmLocalPath',
    'Read-MmlmBrightnessStore',
    'Save-MmlmBrightnessStore',
    'Update-MmlmBrightness',
    'ConvertTo-MmlmNits'
)
