@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Check-Hugo-NR-Image.ps1"
if errorlevel 1 echo NR image test did not verify a displayed change. Read its JSON report.
pause
