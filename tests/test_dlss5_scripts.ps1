# Offline integration tests: synthetic PE/PCK data are copied, never launched.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repo 'integrations/dlss5'
. (Join-Path $source 'templates/Hugo-DLSS5.ps1')
$script:Passed = 0
function Assert-Check { param([bool]$Condition, [string]$Name); if (-not $Condition) { throw "FAIL: $Name" }; $script:Passed += 1 }
function Assert-Rejected { param([scriptblock]$Action, [string]$Name); $rejected = $false; try { & $Action | Out-Null } catch { $rejected = $true }; Assert-Check $rejected $Name }
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('hugo dlss5 test ' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temporary) | Out-Null
try {
    $fixture = Join-Path $temporary 'pack'
    $payload = Join-Path $fixture 'payload'
    [IO.Directory]::CreateDirectory($payload) | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $source 'templates') -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $payload }
    [IO.File]::WriteAllText((Join-Path $payload 'owned.bin'), 'immutable fixture bytes')
    $files = @(Get-ChildItem -LiteralPath $payload -File | ForEach-Object { [ordered]@{ path = $_.Name; size = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(); mutable = ($_.Name -in @('ReShade.ini', 'ReShadePreset_DLSS5.ini')) } })
    [ordered]@{ schema = 1; pack_id = 'hugo-dlss5-gitc-opengl-v1'; backend = 'offline test fixture'; files = $files } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $fixture 'pack-manifest.json') -Encoding UTF8
    $game = Join-Path $temporary 'test game.exe'
    $bytes = New-Object byte[] 528
    $bytes[0] = 77; $bytes[1] = 90
    [BitConverter]::GetBytes([uint32]64).CopyTo($bytes, 60)
    [BitConverter]::GetBytes([uint32]17744).CopyTo($bytes, 64)
    [BitConverter]::GetBytes([uint16]34404).CopyTo($bytes, 68)
    [BitConverter]::GetBytes([uint16]523).CopyTo($bytes, 88)
    [Text.Encoding]::ASCII.GetBytes('GDPC').CopyTo($bytes, 512)
    [BitConverter]::GetBytes([uint64]4).CopyTo($bytes, 516)
    [Text.Encoding]::ASCII.GetBytes('GDPC').CopyTo($bytes, 524)
    [IO.File]::WriteAllBytes($game, $bytes)
    $sourceHash = (Get-FileHash -LiteralPath $game -Algorithm SHA256).Hash
    Assert-Check (Test-HugoGodotImage -Path $game) 'embedded Godot pack read statically'
    $destination = Join-Path $temporary 'isolated game'
    & (Join-Path $source 'Install-Hugo-DLSS5.ps1') -GameExe $game -Destination $destination -PackDirectory $fixture | Out-Null
    $status = Get-HugoDlss5Status -Root $destination -StaticOnly
    Assert-Check ($status.static_files_ok -and -not $status.neural_frame_reported) 'installation is not model execution'
    Assert-Check ((Get-FileHash -LiteralPath (Join-Path $destination 'clean/HugoRemaster.exe')).Hash -eq $sourceHash) 'independent clean game copy'
    Assert-Check (-not (Test-Path -LiteralPath (Join-Path $destination 'clean/opengl32.dll'))) 'no proxy in clean application directory'
    $languagePack = Join-Path $temporary 'Hugo_Languages.pck'
    [IO.File]::WriteAllBytes($languagePack, [Text.Encoding]::ASCII.GetBytes('GDPCfixture'))
    $localizedDestination = Join-Path $temporary 'localized isolated game'
    & (Join-Path $source 'Install-Hugo-DLSS5.ps1') -GameExe $game -Destination $localizedDestination -PackDirectory $fixture | Out-Null
    Assert-Check ((Get-FileHash -LiteralPath (Join-Path $localizedDestination 'Hugo_Languages.pck')).Hash -eq (Get-FileHash -LiteralPath $languagePack).Hash) 'adjacent language pack copied intact'
    Assert-Check (-not (Test-Path -LiteralPath (Join-Path $localizedDestination 'clean/Hugo_Languages.pck'))) 'language payload stored only once'
    $localizedState = Get-Content -LiteralPath (Join-Path $localizedDestination 'dlss5-install-state.json') -Raw | ConvertFrom-Json
    Assert-Check (@($localizedState.files | Where-Object { $_.path -eq 'Hugo_Languages.pck' }).Count -eq 1) 'optional language pack included in owned-file integrity inventory'
    Remove-Item -LiteralPath (Join-Path $localizedDestination 'Hugo_Languages.pck')
    $withoutLanguagePack = Get-HugoDlss5Status -Root $localizedDestination -StaticOnly
    Assert-Check ($withoutLanguagePack.static_files_ok -and -not $withoutLanguagePack.optional_language_pack.present) 'missing optional languages do not disable verified graphics files'
    [IO.File]::WriteAllText((Join-Path $localizedDestination 'Hugo_Languages.pck'), 'modified optional language data')
    Assert-Check (Get-HugoDlss5Status -Root $localizedDestination -StaticOnly).static_files_ok 'optional data integrity is handled per cue without blocking graphics'
    [IO.File]::WriteAllText($languagePack, 'invalid optional pack')
    Assert-Rejected { & (Join-Path $source 'Install-Hugo-DLSS5.ps1') -GameExe $game -Destination (Join-Path $temporary 'bad language destination') -PackDirectory $fixture } 'invalid optional language pack rejected before copying'
    Remove-Item -LiteralPath $languagePack
    Assert-Rejected { & (Join-Path $source 'Install-Hugo-DLSS5.ps1') -GameExe $game -Destination $destination -PackDirectory $fixture } 'existing directory never overwritten'
    Assert-Rejected { Get-HugoSafePath -Root $destination -Relative '../escape' } 'manifest path traversal rejected'
    $oldGame = Join-Path $temporary 'old x86.exe'
    [BitConverter]::GetBytes([uint16]332).CopyTo($bytes, 68)
    [IO.File]::WriteAllBytes($oldGame, $bytes)
    Assert-Rejected { Test-HugoGodotImage -Path $oldGame } 'x86 original-distribution executable rejected'

    $probe = [pscustomobject]@{ success = $true; hardware_verified = $true; software_renderer = $false; angle_detected = $false; rendering_driver = 'opengl3'; rendering_method = 'gl_compatibility'; adapter = [pscustomobject]@{ vendor = 'NVIDIA'; name = 'NVIDIA GeForce RTX 4090'; api_version = 'OpenGL 4.6' } }
    Assert-Check ((Select-HugoGraphicsRoute $probe $true) -eq 'neural_probe_required') 'RTX name still requires actual neural probe'
    Assert-Check ((Select-HugoGraphicsRoute $probe $false) -eq 'clean_native') 'broken NR files do not block clean game'
    $probe.adapter.vendor = 'AMD'; $probe.adapter.name = 'Radeon RX 7900 XTX'
    Assert-Check ((Select-HugoGraphicsRoute $probe $true) -eq 'clean_native') 'AMD clean route'
    $probe.adapter.vendor = 'Intel'; $probe.adapter.name = 'Intel Arc B580'
    Assert-Check ((Select-HugoGraphicsRoute $probe $true) -eq 'clean_native') 'Intel clean route'
    $probe.adapter.vendor = 'NVIDIA'; $probe.adapter.name = 'NVIDIA GeForce GTX 1080'
    Assert-Check ((Select-HugoGraphicsRoute $probe $true) -eq 'clean_native') 'non-RTX NVIDIA clean route'
    $probe.adapter.name = 'NVIDIA GeForce RTX 4090'; $probe.angle_detected = $true
    Assert-Check ((Select-HugoGraphicsRoute $probe $true) -eq 'clean_angle') 'ANGLE never treated as native OpenGL NR'
    $probe.angle_detected = $false; $probe.software_renderer = $true; $probe.hardware_verified = $false
    Assert-Check ((Select-HugoGraphicsRoute $probe $true) -eq 'clean_native') 'working software renderer retained without NR'
    Assert-Check ((Select-HugoGraphicsRoute $null $true) -eq 'clean_engine_auto') 'failed probe still permits clean engine fallback'
    $realArguments = @(New-HugoGameArguments -Root $destination -Driver 'opengl3' -Profile '--dlss5-profile')
    Assert-Check (-not ($realArguments -contains '--resolution') -and -not ($realArguments -contains '--fullscreen') -and -not ($realArguments -contains '--quit-after')) 'real launch preserves display settings and has no probe deadline'

    $loadOnly = Get-HugoNeuralEvidence -Log 'Loaded nvngx_dlssnr.dll. Add-on menu enabled.'
    Assert-Check (-not $loadOnly.neural_frame_reported) 'DLL load is not a neural frame'
    $log = @"
OpenGL: NR runs on a private Direct3D 12 device
NR feature created 1280x720 (D3D12)
NR diagnostic: enabled D3D12 evaluation recorded (motion true)
NR ran on the game's frame (OpenGL, 64-bit)
"@
    Assert-Check (Get-HugoNeuralEvidence -Log $log).neural_frame_reported 'complete backend evidence accepted'
    Assert-Check (-not (Get-HugoNeuralEvidence -Log ($log + "`nThe OpenGL bridge stopped: device failed")).neural_frame_reported) 'fault after a good frame not called a successful session'
    Assert-Check (-not (Get-HugoNeuralEvidence -Log ($log + "`nNR evaluate failed: 0xbad")).neural_frame_reported) 'evaluation failure invalidates earlier neural evidence'
    Assert-Check (-not (Get-HugoNeuralEvidence -Log ($log + "`nSuspended: game needs VRAM")).neural_frame_reported) 'VRAM suspension invalidates earlier neural evidence'
    $run = [ordered]@{ run_id = 'synthetic'; started_utc = [DateTime]::UtcNow.AddHours(1).ToString('o'); exit_code = 0 }
    $run | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $destination 'dlss5-last-run.json') -Encoding UTF8
    $log | Set-Content -LiteralPath (Join-Path $destination 'ReShade.log')
    $staleStatus = Get-HugoDlss5Status -Root $destination
    Assert-Check ($staleStatus.status -eq 'stale_log_rejected') ('stale log rejected: ' + ($staleStatus | ConvertTo-Json -Depth 8 -Compress))
    $run.started_utc = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
    $run | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $destination 'dlss5-last-run.json') -Encoding UTF8
    Assert-Check (Get-HugoDlss5Status -Root $destination).neural_frame_reported 'fresh synthetic evidence passes classifier only'
    Remove-Item -LiteralPath (Join-Path $destination 'ReShade.ini')
    Assert-Check (-not (Get-HugoDlss5Status -Root $destination -StaticOnly).static_files_ok) 'missing mutable configuration is detected'
    Copy-Item -LiteralPath (Join-Path $payload 'ReShade.ini') -Destination $destination

    $shellPath = Join-Path $PSHOME 'powershell.exe'
    foreach ($candidateShell in @('pwsh', 'pwsh.exe')) {
        if (Test-Path -LiteralPath (Join-Path $PSHOME $candidateShell)) { $shellPath = Join-Path $PSHOME $candidateShell; break }
    }
    $ended = Invoke-HugoBoundedProcess -FilePath $shellPath -WorkingDirectory $temporary -Arguments @('-NoProfile', '-Command', 'exit 7') -TimeoutSeconds 5
    Assert-Check ($ended.started -and -not $ended.timed_out -and $ended.exit_code -eq 7) ('probe exit code preserved: ' + ($ended | ConvertTo-Json -Compress))
    $timeout = Invoke-HugoBoundedProcess -FilePath $shellPath -WorkingDirectory $temporary -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 20') -TimeoutSeconds 1
    Assert-Check ($timeout.started -and $timeout.timed_out) 'only bounded child process is stopped at deadline'

    [IO.File]::WriteAllText((Join-Path $destination 'owned.bin'), 'user modification')
    [IO.File]::WriteAllText((Join-Path $destination 'unrecognized-save.txt'), 'keep this')
    & (Join-Path $destination 'Uninstall-Hugo-DLSS5.ps1') | Out-Null
    Assert-Check ((Get-FileHash -LiteralPath $game -Algorithm SHA256).Hash -eq $sourceHash) 'source export untouched through install/uninstall'
    Assert-Check (Test-Path -LiteralPath (Join-Path $destination 'unrecognized-save.txt')) 'unrecognized file preserved on uninstall'
    Assert-Check ((Get-Content -LiteralPath (Join-Path $destination 'owned.bin') -Raw) -eq 'user modification') 'changed immutable file retained on uninstall'
    Assert-Check (-not (Test-Path -LiteralPath (Join-Path $destination 'clean/HugoRemaster.exe'))) 'owned clean copy removed on uninstall'
    Write-Output "PASS: $script:Passed offline DLSS5 script checks; no game or neural DLL executed."
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
