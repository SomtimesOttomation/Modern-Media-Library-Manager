<#
.SYNOPSIS
    Modern Media Library Manager, the new page: a WebView2 window around modules\MMLM.Host.psm1.
.DESCRIPTION
    Windows PowerShell 5.1. The whole "thin host" a dash needs to run on its own under DashLauncher's dash contract:
    make the window and WebView2, build the context, call the backend. DashLauncher does the same for its tab.
    The window app (Run-ModernMediaLibraryManager.cmd) still works beside it and shares the same library and settings.
#>
param([switch]$Debug)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Title = 'Modern Media Library Manager'

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $relaunch = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($Debug) { $relaunch += '-Debug' }
    & powershell.exe @relaunch
    exit $LASTEXITCODE
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------- WebView2 assemblies
# The same three files the window app uses: in lib\, or in %LOCALAPPDATA%\Modern-Media-Library-Manager\WebView2.
$need = 'Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.WinForms.dll', 'WebView2Loader.dll'
$lib = @((Join-Path $Root 'lib'), (Join-Path $env:LOCALAPPDATA 'Modern-Media-Library-Manager\WebView2')) |
    Where-Object { $d = $_; @($need | Where-Object { -not (Test-Path -LiteralPath (Join-Path $d $_)) }).Count -eq 0 } | Select-Object -First 1
if (-not $lib) {
    [Windows.Forms.MessageBox]::Show("The WebView2 files are not here yet.`n`nOpen the window app once (Run-ModernMediaLibraryManager.cmd) and view its dashboard: it downloads them. Or copy $($need -join ', ') into:`n$(Join-Path $Root 'lib')", $Title, 'OK', 'Warning') | Out-Null
    exit 1
}
Add-Type -Namespace Mmlm.Start -Name Native -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Unicode)] public static extern bool SetDllDirectory(string path);'
[Mmlm.Start.Native]::SetDllDirectory($lib) | Out-Null
Add-Type -Path (Join-Path $lib 'Microsoft.Web.WebView2.Core.dll')
Add-Type -Path (Join-Path $lib 'Microsoft.Web.WebView2.WinForms.dll')

# ---------------------------------------------------------------- window
$form = New-Object Windows.Forms.Form
$form.Text = $Title
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object Drawing.Size(1380, 900)
$form.MinimumSize = New-Object Drawing.Size(760, 520)
$form.BackColor = [Drawing.Color]::FromArgb(13, 16, 23)
$webView = New-Object Microsoft.Web.WebView2.WinForms.WebView2
$webView.Dock = 'Fill'
$form.Controls.Add($webView)

# ---------------------------------------------------------------- backend (dash contract)
$wv = $webView; $fm = $form
$context = [pscustomobject]@{
    Mode            = 'standalone'
    Root            = $Root
    Post            = { param([string]$Json) try { $wv.CoreWebView2.PostWebMessageAsJson($Json) } catch { } }.GetNewClosure()
    Close           = { $fm.Close() }.GetNewClosure()
    Relaunch        = '"' + (Join-Path $Root 'Start-MMLM.bat') + '"'
    HostPid         = $PID
    Theme           = ''
    LauncherVersion = ''
    Debug           = [bool]$Debug
}
Import-Module (Join-Path $Root 'modules\MMLM.Host.psm1') -Force -DisableNameChecking
$init = Initialize-Dash -Context $context
if (-not $init.Ok) {
    $why = if ($init.Reason -eq 'locked') { 'Modern Media Library Manager is already open, in its own window or in DashLauncher.' } else { "It could not start: $($init.Reason)" }
    [Windows.Forms.MessageBox]::Show($why, $Title, 'OK', 'Information') | Out-Null
    exit 1
}
$props = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
$props.UserDataFolder = $init.WebViewDataDir
$webView.CreationProperties = $props

$webView.add_CoreWebView2InitializationCompleted({
    param($sender, $e)
    if (-not $e.IsSuccess) {
        [Windows.Forms.MessageBox]::Show("WebView2 failed to start:`n$($e.InitializationException.Message)`n`nInstall the Microsoft Edge WebView2 Runtime: https://go.microsoft.com/fwlink/p/?LinkId=2124703", $Title, 'OK', 'Error') | Out-Null
        $form.Close(); return
    }
    $core = $webView.CoreWebView2
    $core.SetVirtualHostNameToFolderMapping('mmlm.ui', (Join-Path $Root 'ui'), [Microsoft.Web.WebView2.Core.CoreWebView2HostResourceAccessKind]::Allow)
    $core.SetVirtualHostNameToFolderMapping('mmlm.cache', $init.CacheDir, [Microsoft.Web.WebView2.Core.CoreWebView2HostResourceAccessKind]::Allow)
    $core.Settings.AreDefaultContextMenusEnabled = [bool]$Debug
    $core.Settings.AreDevToolsEnabled = [bool]$Debug
    $core.Settings.IsStatusBarEnabled = $false
    $core.add_NewWindowRequested({ param($s, $a) $a.Handled = $true })
    $core.Navigate('https://mmlm.ui/index.html')
})
$webView.add_WebMessageReceived({
    param($s, $a)
    $msg = $null
    try { $msg = $a.WebMessageAsJson | ConvertFrom-Json } catch { return }
    Invoke-DashCommand -Message $msg
})
$webView.add_NavigationStarting({ param($s, $a) if ($a.Uri -notmatch '^https://mmlm\.(ui|cache)/') { $a.Cancel = $true } })

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 250
$timer.add_Tick({ try { foreach ($json in @(Receive-DashEvents)) { if ($json) { $webView.CoreWebView2.PostWebMessageAsJson($json) } } } catch { } })

$form.add_Shown({ Start-DashWorker; $timer.Start(); [void]$webView.EnsureCoreWebView2Async($null) })
$form.add_FormClosing({ $timer.Stop(); Stop-Dash })
[Windows.Forms.Application]::Run($form)
