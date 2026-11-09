@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Verify-Hugo-DLSS5.ps1" -WriteReport
pause
