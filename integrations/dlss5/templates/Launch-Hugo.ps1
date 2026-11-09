[CmdletBinding()]
param([switch]$ForceClean, [int]$ProbeTimeoutSeconds = 120)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Hugo-DLSS5.ps1')
$ProbeTimeoutSeconds = [Math]::Max(5, [Math]::Min(300, $ProbeTimeoutSeconds))
$state = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'dlss5-install-state.json') -Raw | ConvertFrom-Json
if ($state.pack_id -ne 'hugo-dlss5-gitc-opengl-v1') { throw 'Unknown installation.' }
$cleanRoot = Join-Path $PSScriptRoot 'clean'
$cleanEntries = @($state.files | Where-Object { $_.path.StartsWith('clean/') })
if (-not $cleanEntries.Count) { throw 'The independent clean fallback is missing.' }
$cleanErrors = @(Test-HugoPackFiles -Root $PSScriptRoot -Manifest @{ files = $cleanEntries })
if ($cleanErrors.Count) { throw ('Clean game verification failed: ' + ($cleanErrors -join '; ')) }
# The application directory AND working directory of clean launches contain no
# ReShade proxy. Windows does not search their parent directory for opengl32.dll.
if (Test-Path -LiteralPath (Join-Path $cleanRoot 'opengl32.dll')) { throw 'A graphics proxy was added to the clean fallback.' }
[void](Test-HugoGodotImage -Path (Join-Path $cleanRoot 'HugoRemaster.exe'))
$session = [Guid]::NewGuid().ToString('N')
$logs = Join-Path $PSScriptRoot ('dlss5-logs/' + $session)
[IO.Directory]::CreateDirectory($logs) | Out-Null
$decisions = [ordered]@{ schema = 1; session = $session; started_utc = [DateTime]::UtcNow.ToString('o'); route = 'pending'; neural_rendering_verified = $false; probes = @() }
$decisionPath = Join-Path $PSScriptRoot 'graphics-launch-status.json'
$cachePath = Join-Path $PSScriptRoot 'dlss5-capability-cache.json'

function Save-Decision { $decisions | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $decisionPath -Encoding UTF8 }
function Invoke-GraphicsProbe {
    param([string]$Root, [string]$Driver, [string]$Name, [string]$Profile, [int]$Frames)
    $jsonPath = Join-Path $logs ($Name + '.json')
    $arguments = @('--rendering-method', 'gl_compatibility', '--rendering-driver', $Driver, '--windowed', '--resolution', '1280x720', '--quit-after', [string]($Frames + 120))
    if (Test-Path -LiteralPath (Join-Path $Root 'HugoRemaster.pck')) { $arguments += @('--main-pack', 'HugoRemaster.pck') }
    $arguments += @('--', $Profile, ('--graphics-probe=' + $jsonPath), ('--graphics-probe-frames=' + $Frames))
    $execution = Invoke-HugoBoundedProcess -FilePath (Join-Path $Root 'HugoRemaster.exe') -WorkingDirectory $Root -Arguments $arguments -TimeoutSeconds $ProbeTimeoutSeconds
    $capability = $null
    if ($execution.exit_code -eq 0 -and -not $execution.timed_out -and (Test-Path -LiteralPath $jsonPath)) {
        try {
            $candidate = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
            if ($candidate.schema -eq 1 -and $candidate.success -and -not $candidate.headless -and $candidate.rendered_frames -ge 3) { $capability = $candidate }
        } catch { }
    }
    return [ordered]@{ name = $Name; driver_requested = $Driver; execution = $execution; capability = $capability }
}
function Archive-NeuralLog {
    param([string]$Name)
    $source = Join-Path $PSScriptRoot 'ReShade.log'
    if (Test-Path -LiteralPath $source) { Move-Item -LiteralPath $source -Destination (Join-Path $logs $Name) }
}

$neuralFilesValid = $false
try { $neuralFilesValid = (Get-HugoDlss5Status -Root $PSScriptRoot -StaticOnly).static_files_ok } catch { }
$baseProbe = Invoke-GraphicsProbe -Root $cleanRoot -Driver 'opengl3' -Name 'native-probe' -Profile '--graphics-safe-profile' -Frames 8
$decisions.probes += $baseProbe
if ($null -eq $baseProbe.capability) {
    $baseProbe = Invoke-GraphicsProbe -Root $cleanRoot -Driver 'opengl3_angle' -Name 'angle-probe' -Profile '--graphics-safe-profile' -Frames 8
    $decisions.probes += $baseProbe
}
$route = Select-HugoGraphicsRoute -Probe $baseProbe.capability -NeuralFilesValid $neuralFilesValid
if ($ForceClean -and $route -eq 'neural_probe_required') { $route = 'clean_native' }
$fingerprint = ''
if ($route -eq 'neural_probe_required') {
    $driverInfo = @()
    if ($baseProbe.capability.PSObject.Properties['driver_info']) { $driverInfo = @($baseProbe.capability.driver_info) }
    $canCache = $driverInfo.Count -gt 0 -and ($driverInfo -join '').Length -gt 0
    $parts = [ordered]@{ adapter = $baseProbe.capability.adapter; driver = $baseProbe.capability.rendering_driver; driver_info = $driverInfo; files = @() }
    foreach ($relative in @('HugoRemaster.exe', 'GITC-Uplift/nvngx_dlssnr.dll', 'gitc-uplift.addon64', 'opengl32.dll', 'ReShade.ini', 'ReShadePreset_DLSS5.ini')) {
        $parts.files += (Get-FileHash -LiteralPath (Get-HugoSafePath -Root $PSScriptRoot -Relative $relative) -Algorithm SHA256).Hash
    }
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'HugoRemaster.pck')) { $parts.files += (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'HugoRemaster.pck') -Algorithm SHA256).Hash }
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $fingerprint = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes(($parts | ConvertTo-Json -Depth 6 -Compress))))).Replace('-', '').ToLowerInvariant() } finally { $hash.Dispose() }
    $qualified = $false
    if ($canCache -and (Test-Path -LiteralPath $cachePath)) {
        try {
            $cache = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
            $evidencePath = Get-HugoSafePath -Root $PSScriptRoot -Relative $cache.evidence_log
            $qualified = $cache.qualified -and $cache.fingerprint -eq $fingerprint -and (Test-Path -LiteralPath $evidencePath) -and ((Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $cache.evidence_sha256)
        } catch { $qualified = $false }
    }
    if (-not $qualified) {
        Archive-NeuralLog -Name 'previous-ReShade.log'
        $nrProbe = Invoke-GraphicsProbe -Root $PSScriptRoot -Driver 'opengl3' -Name 'neural-probe' -Profile '--dlss5-profile' -Frames 320
        $decisions.probes += $nrProbe
        $nrLog = Join-Path $PSScriptRoot 'ReShade.log'
        $evidence = Get-HugoNeuralEvidence -Log ''
        if (Test-Path -LiteralPath $nrLog) { $evidence = Get-HugoNeuralEvidence -Log (Get-Content -LiteralPath $nrLog -Raw) }
        $qualified = $null -ne $nrProbe.capability -and $nrProbe.capability.hardware_verified -and $nrProbe.execution.exit_code -eq 0 -and -not $nrProbe.execution.timed_out -and -not $nrProbe.capability.angle_detected -and $evidence.neural_frame_reported
        $decisions.neural_probe_evidence = $evidence
        Archive-NeuralLog -Name 'neural-probe-ReShade.log'
        if ($qualified -and $canCache) {
            $relativeEvidence = 'dlss5-logs/' + $session + '/neural-probe-ReShade.log'
            [ordered]@{ schema = 1; fingerprint = $fingerprint; qualified = $true; evidence_log = $relativeEvidence; evidence_sha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $relativeEvidence) -Algorithm SHA256).Hash.ToLowerInvariant() } | ConvertTo-Json | Set-Content -LiteralPath $cachePath -Encoding UTF8
        } elseif (Test-Path -LiteralPath $cachePath) { Remove-Item -LiteralPath $cachePath }
    } else { $decisions.neural_probe_cache = 'matching_hardware_driver_game_components_and_configuration' }
    $route = $(if ($qualified) { 'neural_native' } else { 'clean_native' })
}
$decisions.route = $route
Save-Decision
if ($route -eq 'neural_native') {
    Archive-NeuralLog -Name 'previous-cached-ReShade.log'
    $run = [ordered]@{ schema = 1; run_id = $session; started_utc = [DateTime]::UtcNow.ToString('o'); exit_code = $null; backend = 'gitc_uplift_opengl'; user_argument = '--dlss5-profile' }
    $run | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'dlss5-last-run.json') -Encoding UTF8
    $result = Start-HugoObservedGame -Root $PSScriptRoot -Driver 'opengl3' -Profile '--dlss5-profile' -ObserveNeural
    $run.exit_code = $result.exit_code
    $run.completed_utc = [DateTime]::UtcNow.ToString('o')
    $run | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'dlss5-last-run.json') -Encoding UTF8
    try {
        $actual = Get-HugoDlss5Status -Root $PSScriptRoot
        $actual | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'dlss5-verification.json') -Encoding UTF8
        $decisions.neural_rendering_verified = $actual.neural_frame_reported
    } catch { }
    if ($result.neural_failure_seen -or -not $decisions.neural_rendering_verified) { if (Test-Path -LiteralPath $cachePath) { Remove-Item -LiteralPath $cachePath } }
    if ($result.exit_code -eq 0) { $decisions.completed_utc = [DateTime]::UtcNow.ToString('o'); Save-Decision; exit 0 }
    # A crashed NR process gets one clean relaunch; a healthy process is never
    # stopped or relaunched simply because it has no neural evaluation markers.
    $decisions.neural_process_exit = $result.exit_code
    $route = 'clean_native'
}
$driver = $(if ($route -eq 'clean_angle') { 'opengl3_angle' } elseif ($route -eq 'clean_engine_auto') { '' } else { 'opengl3' })
$decisions.route = $route
Save-Decision
$cleanResult = Start-HugoObservedGame -Root $cleanRoot -Driver $driver -Profile '--graphics-safe-profile'
if ($cleanResult.exit_code -ne 0 -and $driver -ne 'opengl3_angle') {
    $decisions.native_clean_exit = $cleanResult.exit_code
    $decisions.route = 'clean_angle_after_native_failure'
    Save-Decision
    $cleanResult = Start-HugoObservedGame -Root $cleanRoot -Driver 'opengl3_angle' -Profile '--graphics-safe-profile'
}
$decisions.clean_exit = $cleanResult.exit_code
$decisions.completed_utc = [DateTime]::UtcNow.ToString('o')
Save-Decision
if ($cleanResult.exit_code -ne 0) { Write-Host 'The clean OpenGL/ANGLE renderer could not start. See graphics-launch-status.json and the probe reports.' }
exit $cleanResult.exit_code
