@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Launch-Hugo-DLSS5.ps1"
if errorlevel 1 pause
