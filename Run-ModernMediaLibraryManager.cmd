@echo off
rem Double-click launcher for the Modern Media Library Manager (Windows PowerShell 5.1, STA is required for WinForms/WebView2).
rem If Windows blocks the script because it was downloaded, run this once in PowerShell:
rem     Get-ChildItem "%~dp0" -Recurse | Unblock-File
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Modern-Media-Library-Manager.ps1"
