@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Launch-Hugo.ps1"
if errorlevel 1 pause
