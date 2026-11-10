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

    $probe = [pscustomobject]@{ success = $true; headless = $false; hardware_verified = $true; software_renderer = $false; angle_detected = $false; rendering_driver = 'opengl3'; rendering_method = 'gl_compatibility'; adapter = [pscustomobject]@{ vendor = 'NVIDIA'; name = 'NVIDIA GeForce RTX 4090'; api_version = 'OpenGL 4.6' } }
    Assert-Check ((Select-HugoGraphicsRoute $probe $true) -eq 'neural_probe_required') 'RTX name still requires actual neural probe'
    Assert-Check ((Select-HugoGraphicsRoute $probe $false) -eq 'clean_native') 'broken NR files do not block clean game'
    Assert-Check ((Select-HugoCleanProfile $probe) -eq '') 'working RTX retains user quality when NR is unavailable'
    $probe.headless = $true
    Assert-Check ((Select-HugoCleanProfile $probe) -eq '--graphics-safe-profile') 'headless result does not establish an unrestricted graphics profile'
    $probe.headless = $false
    Assert-Check ((Select-HugoCleanProfile ([pscustomobject]@{ success = $true; hardware_verified = $true })) -eq '--graphics-safe-profile') 'incomplete capability data remains conservative without a strict-mode exception'
    $probe.adapter.vendor = 'AMD'; $probe.adapter.name = 'Radeon RX 7900 XTX'
    Assert-Check ((Select-HugoGraphicsRoute $probe $true) -eq 'clean_native') 'AMD clean route'
    Assert-Check ((Select-HugoCleanProfile $probe) -eq '') 'working AMD does not receive an artificial 512px texture cap'
    $probe.adapter.vendor = 'Intel'; $probe.adapter.name = 'Intel Arc B580'
    Assert-Check ((Select-HugoGraphicsRoute $probe $true) -eq 'clean_native') 'Intel clean route'
    Assert-Check ((Select-HugoCleanProfile $probe) -eq '') 'working Intel retains editable graphics settings'
    $probe.adapter.vendor = 'NVIDIA'; $probe.adapter.name = 'NVIDIA GeForce GTX 1080'
    Assert-Check ((Select-HugoGraphicsRoute $probe $true) -eq 'clean_native') 'non-RTX NVIDIA clean route'
    $probe.adapter.name = 'NVIDIA GeForce RTX 4090'; $probe.angle_detected = $true
    Assert-Check ((Select-HugoGraphicsRoute $probe $true) -eq 'clean_angle') 'ANGLE never treated as native OpenGL NR'
    Assert-Check ((Select-HugoCleanProfile $probe) -eq '') 'verified hardware ANGLE preserves normal quality before an actual failure'
    $probe.angle_detected = $false; $probe.software_renderer = $true; $probe.hardware_verified = $false
    Assert-Check ((Select-HugoGraphicsRoute $probe $true) -eq 'clean_native') 'working software renderer retained without NR'
    Assert-Check ((Select-HugoCleanProfile $probe) -eq '--graphics-safe-profile') 'software renderer starts with bounded texture memory'
    Assert-Check ((Select-HugoGraphicsRoute $null $true) -eq 'clean_engine_auto') 'failed probe still permits clean engine fallback'
    Assert-Check ((Select-HugoCleanProfile $null) -eq '--graphics-safe-profile') 'unknown renderer retains the conservative startup profile'
    $realArguments = @(New-HugoGameArguments -Root $destination -Driver 'opengl3' -Profile '--dlss5-profile')
    Assert-Check (-not ($realArguments -contains '--resolution') -and -not ($realArguments -contains '--fullscreen') -and -not ($realArguments -contains '--quit-after')) 'real launch preserves display settings and has no probe deadline'
    $livePath = Join-Path $temporary 'current session.json'
    $liveArguments = @(New-HugoGameArguments -Root $destination -Driver 'opengl3' -Profile '--dlss5-profile' -NeuralStatusPath $livePath -Session 'session-a')
    Assert-Check ($liveArguments -contains ('--nr-status-file=' + $livePath) -and $liveArguments -contains '--nr-session=session-a') 'live status arguments retain spaced paths and exact session'
    Assert-Check (@($liveArguments | Where-Object { $_ -eq '--' }).Count -eq 1) 'one Godot user-argument separator'
    $cleanArguments = @(New-HugoGameArguments -Root $destination -Driver 'opengl3' -Profile '' -NeuralStatusPath $livePath -Session 'clean-quality')
    Assert-Check (-not ($cleanArguments -contains '') -and -not ($cleanArguments -contains '--graphics-safe-profile') -and $cleanArguments -contains '--nr-session=clean-quality') 'standard clean launch has no hidden profile cap or empty argument and keeps live status'

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
    Assert-Check (-not (Get-HugoNeuralEvidence -Log ($log + "`nHotkey: NR disabled")).neural_frame_reported) 'F8 disable invalidates earlier frame evidence'
    Assert-Check (-not (Get-HugoNeuralEvidence -Log ($log + "`nHotkey: NR disabled`nHotkey: NR enabled")).neural_frame_reported) 're-enable awaits a new returned frame'
    Assert-Check (Get-HugoNeuralEvidence -Log ($log + "`nHotkey: NR disabled`nHotkey: NR enabled`nNR ran on the game's frame (OpenGL, 64-bit)")).neural_frame_reported 'new returned frame after re-enable is distinguished'
    $configuration = Get-HugoNeuralConfiguration -Root $destination
    Assert-Check ($configuration.settings.Intensity -eq 1 -and $configuration.settings.MaskBlendMode -eq 1 -and $configuration.warnings.Count -eq 0) 'pinned configuration exposes nonzero result and marker chain'
    $live = New-HugoNeuralLiveStatus -Session 'session-a' -GameProcessId 1234 -StartedUtc ([DateTime]::UtcNow) -ObserveNeural -Log $log -FreshLog $false -Configuration $configuration
    Assert-Check ($live.state -eq 'probing') 'preflight or stale markers cannot qualify current play'
    $live = New-HugoNeuralLiveStatus -Session 'session-a' -GameProcessId 1234 -StartedUtc ([DateTime]::UtcNow) -ObserveNeural -Log $log -FreshLog $true -Configuration $configuration
    Assert-Check ($live.state -eq 'backend_reported' -and $null -eq $live.frames_processed -and -not $live.display_output_verified) 'backend marker neither invents a frame counter nor proves display output'
    Write-HugoNeuralLiveStatus -Path $livePath -Status $live
    $live.process_id = 5678; $live.session = 'session-b'
    Write-HugoNeuralLiveStatus -Path $livePath -Status $live
    $savedLive = Get-Content -LiteralPath $livePath -Raw | ConvertFrom-Json
    Assert-Check ($savedLive.process_id -eq 5678 -and $savedLive.session -eq 'session-b' -and -not (Test-Path -LiteralPath ($livePath + '.new'))) 'atomic replacement publishes complete current PID and session'
    $configuration.settings.Intensity = 0
    $live = New-HugoNeuralLiveStatus -Session 'session-a' -GameProcessId 1234 -StartedUtc ([DateTime]::UtcNow) -ObserveNeural -Log $log -FreshLog $true -Configuration $configuration
    Assert-Check ($live.reason_code -eq 'zero_intensity' -and $live.state -eq 'inactive') 'zero intensity overrides earlier successful backend markers'
    $configuration.settings.Intensity = 1; $configuration.settings.TransferStrength = 0; $configuration.settings.ColorStrength = 0
    $live = New-HugoNeuralLiveStatus -Session 'session-a' -GameProcessId 1234 -StartedUtc ([DateTime]::UtcNow) -ObserveNeural -Log $log -FreshLog $true -Configuration $configuration
    Assert-Check ($live.reason_code -eq 'zero_result_strength') 'zero output mixture is reported explicitly'
    $cleanLive = New-HugoNeuralLiveStatus -Session 'session-a' -GameProcessId 1234 -StartedUtc ([DateTime]::UtcNow) -InactiveReason 'neural_preflight_not_confirmed'
    Assert-Check ($cleanLive.provider -eq 'none' -and $cleanLive.state -eq 'inactive' -and $cleanLive.reason_code -eq 'neural_preflight_not_confirmed') 'clean fallback carries its reason into the game'
    $differences = @{}
    foreach ($name in @('off_repeat', 'off_return', 'on_repeat', 'off_on')) {
        $differences[$name] = @{ FirstNonuniform = $true; SecondNonuniform = $true; MeanAbsoluteRgb = 0.0; CentralMeanAbsoluteRgb = 0.0; ChangedPixels = 0; Pixels = 921600; CentralPixels = 450000; CentralChangedPixels = 0 }
    }
    $classification = Get-HugoImageTestClassification -NativeInputsIdentical $true -BackendReported $true -Differences $differences
    Assert-Check ($classification.status -eq 'no_visible_change' -and -not $classification.display_output_verified) 'backend success without desktop change is not image verification'
    $differences.off_on.CentralMeanAbsoluteRgb = 4.0; $differences.off_on.CentralChangedPixels = 120000
    $classification = Get-HugoImageTestClassification -NativeInputsIdentical $true -BackendReported $true -Differences $differences
    Assert-Check ($classification.status -eq 'display_change_verified') 'stable reversible synthetic desktop difference passes classifier only'
    Assert-Check ((Get-HugoImageTestClassification -NativeInputsIdentical $false -BackendReported $true -Differences $differences).status -eq 'inconclusive') 'native framebuffer mismatch rejects a misleading A/B'
    Assert-Check ((Get-HugoImageTestClassification -NativeInputsIdentical $true -BackendReported $false -Differences $differences).status -eq 'inconclusive') 'desktop difference without enabled backend evidence remains inconclusive'
    $differences.off_return.ChangedPixels = 1000
    Assert-Check ((Get-HugoImageTestClassification -NativeInputsIdentical $true -BackendReported $true -Differences $differences).reason_code -eq 'desktop_off_control_not_stable') 'failed return to off detects an overlay or drift'
    $differences.off_return.ChangedPixels = 0; $differences.on_repeat.SecondNonuniform = $false
    Assert-Check ((Get-HugoImageTestClassification -NativeInputsIdentical $true -BackendReported $true -Differences $differences).reason_code -eq 'blank_or_uniform_desktop_capture') 'blank desktop capture cannot verify neural output'
    $parseTokens = $null; $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'templates/Check-Hugo-NR-Image.ps1'), [ref]$parseTokens, [ref]$parseErrors)
    Assert-Check ($parseErrors.Count -eq 0) 'optional Windows visual helper parses without running it'
    # Exercise the real observer loop with a fake process object. No game or
    # Windows DLL is executed; its first wait writes a fresh synthetic log.
    $script:mockLogPath = Join-Path $destination 'ReShade.log'
    $script:mockLivePath = $livePath
    $script:mockBackendText = $log
    $script:mockObservedLive = $null
    $script:mockLaunchArguments = ''
    $script:mockProcess = [pscustomobject]@{ Id = 43210; ExitCode = 0; Waits = 0 }
    $script:mockProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
        param($Milliseconds)
        $this.Waits += 1
        if ($this.Waits -eq 1) {
            [IO.File]::WriteAllText($script:mockLogPath, $script:mockBackendText)
            return $false
        }
        $script:mockObservedLive = Get-Content -LiteralPath $script:mockLivePath -Raw | ConvertFrom-Json
        return $true
    }
    function Start-Process {
        param($FilePath, $ArgumentList, $WorkingDirectory, [switch]$PassThru)
        $script:mockLaunchArguments = $ArgumentList
        return $script:mockProcess
    }
    try {
        if (Test-Path -LiteralPath $script:mockLogPath) { Remove-Item -LiteralPath $script:mockLogPath }
        $observed = Start-HugoObservedGame -Root $destination -Driver 'opengl3' -Profile '--dlss5-profile' -ObserveNeural -NeuralStatusPath $livePath -Session '0123456789abcdef0123456789abcdef'
        Assert-Check ($observed.exit_code -eq 0 -and $observed.process_id -eq 43210 -and $script:mockObservedLive.state -eq 'backend_reported' -and $script:mockObservedLive.process_id -eq 43210) 'real observer publishes fresh-process evidence before normal exit'
        Assert-Check ($script:mockLaunchArguments.Contains('--nr-session=0123456789abcdef0123456789abcdef')) 'actual process receives observer session'
        $script:mockProcess.Waits = 0
        $staleObserved = Start-HugoObservedGame -Root $destination -Driver 'opengl3' -Profile '--dlss5-profile' -ObserveNeural -NeuralStatusPath $livePath -Session 'fedcba9876543210fedcba9876543210'
        Assert-Check ($script:mockObservedLive.state -eq 'probing') 'touching an existing earlier-process log never qualifies a live session'
    } finally { Remove-Item Function:\Start-Process }
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
    $ended = Invoke-HugoBoundedProcess -FilePath $shellPath -WorkingDirectory $temporary -Arguments @('-NoProfile', '-Command', 'exit 7') -TimeoutSeconds 15
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
