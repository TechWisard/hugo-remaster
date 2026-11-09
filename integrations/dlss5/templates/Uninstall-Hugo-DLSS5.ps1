[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Hugo-DLSS5.ps1')
$statePath = Join-Path $PSScriptRoot 'dlss5-install-state.json'
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
if ($state.pack_id -ne 'hugo-dlss5-gitc-opengl-v1') { throw 'This directory is not an installation owned by this pack.' }
$retained = @()
foreach ($entry in $state.files) {
    $path = Get-HugoSafePath -Root $PSScriptRoot -Relative $entry.path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    $same = ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $entry.sha256)
    if ($same -or $entry.mutable) { Remove-Item -LiteralPath $path }
    else { $retained += $entry.path }
}
if (-not $retained.Count) { Remove-Item -LiteralPath $statePath }
[ordered]@{ status = $(if ($retained.Count) { 'changed_files_retained' } else { 'owned_files_removed' }); retained_changed_files = $retained; logs_and_unrecognized_files = 'preserved' } | ConvertTo-Json
