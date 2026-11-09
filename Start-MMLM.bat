@echo off
rem Modern Media Library Manager, the new page (WebView2). The window app is Run-ModernMediaLibraryManager.cmd.
rem If Windows blocks the scripts because they were downloaded, run this once in PowerShell:
rem     Get-ChildItem "%~dp0" -Recurse ^| Unblock-File
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Start-MMLM.ps1" %*
