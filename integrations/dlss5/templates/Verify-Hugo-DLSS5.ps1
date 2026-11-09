[CmdletBinding()]
param([switch]$StaticOnly, [switch]$WriteReport)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Hugo-DLSS5.ps1')
$report = Get-HugoDlss5Status -Root $PSScriptRoot -StaticOnly:$StaticOnly
$json = $report | ConvertTo-Json -Depth 12
if ($WriteReport) { $json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'dlss5-verification.json') -Encoding UTF8 }
$json
if (-not $report.static_files_ok) { exit 2 }
if (-not $StaticOnly -and -not $report.neural_frame_reported) { exit 3 }
