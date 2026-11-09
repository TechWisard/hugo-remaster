# Filename alias; every normal launch uses the clean fallback policy.
[CmdletBinding()]
param([switch]$ForceClean)
& (Join-Path $PSScriptRoot 'Launch-Hugo.ps1') -ForceClean:$ForceClean
exit $LASTEXITCODE
