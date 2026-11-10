# Explicit optional diagnostic, never part of normal startup. No real game or
# save is opened. Only the bounded asset-free probe may be stopped by this file.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'Hugo-DLSS5.ps1')
$session = [Guid]::NewGuid().ToString('N')
$directory = Join-Path $PSScriptRoot ('dlss5-logs/visual-' + $session)
[IO.Directory]::CreateDirectory($directory) | Out-Null
$reportPath = Join-Path $directory 'nr-image-report.json'
$controlPath = Join-Path $directory 'visual-control.json'
$finalPath = Join-Path $directory 'native-final.json'
$iniPath = Join-Path $PSScriptRoot 'ReShade.ini'
$logPath = Join-Path $PSScriptRoot 'ReShade.log'
$backupIni = Join-Path $directory 'original-ReShade.ini'
$backupLog = Join-Path $directory 'original-ReShade.log'
$script:probeProcess = $null
$script:probeWindow = [IntPtr]::Zero
$script:sampleNumber = 0
$iniChanged = $false
$logArchived = $false
$report = [ordered]@{ schema = 1; session = $session; status = 'inconclusive'; reason_code = 'not_started'; display_output_verified = $false; visual_quality_validated = $false; benchmark_validated = $false; capture_stage = 'desktop_client_after_external_present'; native_inputs = @(); screenshots = @(); limitations = @('Proves a displayed difference in a frozen diagnostic fixture only, not artistic quality or performance.', 'Windows desktop capture and the user GPU must execute this test; offline script checks are not GPU evidence.') }

function Read-VisualBackendLog {
    if (-not (Test-Path -LiteralPath $logPath)) { return '' }
    $stream = New-Object IO.FileStream($logPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader = New-Object IO.StreamReader($stream)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}
function Assert-VisualWindow {
    $script:probeProcess.Refresh()
    if ($script:probeProcess.HasExited) { throw 'diagnostic_process_exited' }
    $check = [HugoNR.ImageCapture]::Check($script:probeWindow, $script:probeProcess.Id)
    if (-not $check.Valid) { throw $check.Reason }
}
function Wait-VisualFrames {
    param([int]$Milliseconds)
    $until = [DateTime]::UtcNow.AddMilliseconds($Milliseconds)
    while ([DateTime]::UtcNow -lt $until) { Assert-VisualWindow; Start-Sleep -Milliseconds 100 }
}
function Get-VisualNativeFrame {
    $script:sampleNumber += 1
    $response = Join-Path $directory ('native-frame-{0:d3}.json' -f $script:sampleNumber)
    Write-HugoNeuralLiveStatus -Path $controlPath -Status @{ schema = 1; session = $session; command = 'sample'; request = $script:sampleNumber }
    $until = [DateTime]::UtcNow.AddSeconds(8)
    while (-not (Test-Path -LiteralPath $response)) {
        Assert-VisualWindow
        if ([DateTime]::UtcNow -ge $until) { throw 'native_frame_handshake_timeout' }
        Start-Sleep -Milliseconds 100
    }
    $native = Get-Content -LiteralPath $response -Raw | ConvertFrom-Json
    if ($native.session -ne $session -or $native.process_id -ne $script:probeProcess.Id -or $native.request -ne $script:sampleNumber -or -not $native.native_framebuffer_valid -or -not $native.window_focused -or $native.native_framebuffer_sha256 -notmatch '^[a-f0-9]{64}$') { throw 'native_frame_handshake_invalid' }
    return $native
}
function Save-VisualSample {
    param([string]$Name)
    Assert-VisualWindow
    $native = Get-VisualNativeFrame
    $image = Join-Path $directory ($Name + '.png')
    $window = [HugoNR.ImageCapture]::Capture($script:probeWindow, $script:probeProcess.Id, $image)
    if ($window.Width -ne $native.native_size[0] -or $window.Height -ne $native.native_size[1]) { throw 'desktop_native_dimensions_differ' }
    $report.native_inputs += $native
    $report.screenshots += [ordered]@{ name = $Name; path = ($Name + '.png'); native_request = $native.request; window = $window; captured_utc = [DateTime]::UtcNow.ToString('o') }
}
function Wait-VisualNrState {
    param([bool]$Enabled)
    $until = [DateTime]::UtcNow.AddSeconds(35)
    while ([DateTime]::UtcNow -lt $until) {
        Assert-VisualWindow
        $evidence = Get-HugoNeuralEvidence -Log (Read-VisualBackendLog)
        if ($evidence.failures.Count) { throw 'backend_failed_during_visual_test' }
        if (($Enabled -and $evidence.neural_frame_reported) -or (-not $Enabled -and $evidence.disabled_reported)) { return $evidence }
        Start-Sleep -Milliseconds 150
    }
    throw $(if ($Enabled) { 'backend_enable_not_acknowledged' } else { 'backend_disable_not_acknowledged' })
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'windows_desktop_capture_required' }
    $status = Get-HugoDlss5Status -Root $PSScriptRoot -StaticOnly
    if (-not $status.static_files_ok) { throw 'neural_files_invalid' }
    $exe = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'HugoRemaster.exe'))
    foreach ($running in @(Get-Process -Name 'HugoRemaster' -ErrorAction SilentlyContinue)) {
        # Do not overwrite ReShade configuration underneath an actual game.
        # If its image cannot be identified, conservatively refuse this test.
        try { $runningPath = $running.MainModule.FileName } catch { throw 'another_game_process_cannot_be_identified' }
        if (-not $runningPath -or [IO.Path]::GetFullPath($runningPath) -eq $exe) { throw 'close_this_game_before_visual_test' }
    }
    Add-Type -AssemblyName System.Drawing
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $references = @((Get-ChildItem -LiteralPath (Join-Path $PSHOME 'ref') -Filter '*.dll').FullName)
        foreach ($library in @('System.Drawing.Common.dll', 'System.Private.Windows.Core.dll')) {
            if (Test-Path -LiteralPath (Join-Path $PSHOME $library)) { $references += Join-Path $PSHOME $library }
        }
        Add-Type -Path (Join-Path $PSScriptRoot 'Hugo-NR-ImageCapture.cs') -ReferencedAssemblies $references
    } else {
        Add-Type -Path (Join-Path $PSScriptRoot 'Hugo-NR-ImageCapture.cs') -ReferencedAssemblies System.Drawing
    }
    [HugoNR.ImageCapture]::ConfigureDpi()
    Copy-Item -LiteralPath $iniPath -Destination $backupIni
    if (Test-Path -LiteralPath $logPath) { Move-Item -LiteralPath $logPath -Destination $backupLog; $logArchived = $true }
    # A dedicated preset excludes extra post-effects and external masks. F8
    # toggles only Uplift's NR flag; Lumenite remains enabled on both sides.
    $preset = @"
PreprocessorDefinitions=UPLIFT_USE_LAUNCHPAD=0,UPLIFT_USE_LUMENITE=1
Techniques=Lumenite_Kernel@lumenite_Kernel.fx,Uplift@Uplift.fx
TechniqueSorting=Lumenite_Kernel@lumenite_Kernel.fx,Uplift@Uplift.fx

[Uplift.fx]
UpliftAllowLaunchpad=0
UpliftAllowLumenite=1
"@
    [IO.File]::WriteAllText((Join-Path $directory 'visual-preset.ini'), $preset, (New-Object Text.UTF8Encoding $false))
    $probeIni = @"
[GENERAL]
EffectSearchPaths=.\reshade-shaders\Shaders
TextureSearchPaths=.\reshade-shaders\Textures
PresetPath=.\dlss5-logs\visual-$session\visual-preset.ini
PerformanceMode=0

[INPUT]
KeyOverlay=36,0,0,0

[OVERLAY]
TutorialProgress=4

[Uplift]
ConfigVersion=3
Enabled=0
EnableKey=119
Source=2
NgxHooks=1
MotionVectors=4
PassCount=1
VramCheck=0
ResolutionMode=0
ResolutionPresent=0
Intensity=1.0
TransferStrength=1.0
ColorStrength=1.0
LocalTone=1.0
LocalStructure=1.0
SkinStructure=1.0
AutoMask=1
Mask=1
MaskBlendMode=1
Preset=1
KeepFaces=0
KeepFacesPresent=0
ShowNvIndicator=0
SnippetPath=.\GITC-Uplift\nvngx_dlssnr.dll
"@
    $iniChanged = $true
    [IO.File]::WriteAllText($iniPath, $probeIni, (New-Object Text.UTF8Encoding $false))
    $report.fixed_configuration = Get-HugoNeuralConfiguration -Root $PSScriptRoot
    Write-HugoNeuralLiveStatus -Path $controlPath -Status @{ schema = 1; session = $session; command = 'wait'; request = 0 }
    $arguments = @('--rendering-method', 'gl_compatibility', '--rendering-driver', 'opengl3', '--windowed', '--resolution', '1280x720')
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'HugoRemaster.pck')) { $arguments += @('--main-pack', 'HugoRemaster.pck') }
    $arguments += @('--', '--dlss5-profile', ('--graphics-probe=' + $finalPath), ('--graphics-visual-control=' + $controlPath), ('--graphics-visual-session=' + $session))
    $report.started_utc = [DateTime]::UtcNow.ToString('o')
    $script:probeProcess = Start-Process -FilePath $exe -WorkingDirectory $PSScriptRoot -ArgumentList (ConvertTo-HugoArgumentString $arguments) -PassThru
    $report.process_id = $script:probeProcess.Id
    $until = [DateTime]::UtcNow.AddSeconds(25)
    do {
        $script:probeProcess.Refresh()
        if ($script:probeProcess.HasExited) { throw 'diagnostic_process_exited_before_window' }
        if ($script:probeProcess.MainWindowHandle -ne [IntPtr]::Zero -and $script:probeProcess.MainWindowTitle.Contains($session.Substring(0, 8))) { $script:probeWindow = $script:probeProcess.MainWindowHandle; break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $until)
    if ($script:probeWindow -eq [IntPtr]::Zero) { throw 'diagnostic_window_not_found' }
    [void][HugoNR.ImageCapture]::Activate($script:probeWindow)
    Start-Sleep -Milliseconds 300
    Wait-VisualFrames -Milliseconds 5000
    Save-VisualSample -Name 'nr-off-a'
    Wait-VisualFrames -Milliseconds 700
    Save-VisualSample -Name 'nr-off-b'
    [HugoNR.ImageCapture]::ToggleNr($script:probeWindow, $script:probeProcess.Id)
    $report.enabled_phase_evidence = Wait-VisualNrState -Enabled $true
    Wait-VisualFrames -Milliseconds 3500
    Save-VisualSample -Name 'nr-on-a'
    Wait-VisualFrames -Milliseconds 700
    Save-VisualSample -Name 'nr-on-b'
    [HugoNR.ImageCapture]::ToggleNr($script:probeWindow, $script:probeProcess.Id)
    $report.disabled_phase_evidence = Wait-VisualNrState -Enabled $false
    Wait-VisualFrames -Milliseconds 1500
    Save-VisualSample -Name 'nr-off-return'
    $report.native_inputs_identical = @($report.native_inputs | Select-Object -ExpandProperty native_framebuffer_sha256 -Unique).Count -eq 1 -and @($report.native_inputs | Select-Object -ExpandProperty pose -Unique).Count -eq 1
    $off = Join-Path $directory 'nr-off-a.png'
    $on = Join-Path $directory 'nr-on-a.png'
    $report.differences = [ordered]@{
        off_repeat = [HugoNR.ImageCapture]::Compare($off, (Join-Path $directory 'nr-off-b.png'), '')
        on_repeat = [HugoNR.ImageCapture]::Compare($on, (Join-Path $directory 'nr-on-b.png'), '')
        off_return = [HugoNR.ImageCapture]::Compare($off, (Join-Path $directory 'nr-off-return.png'), '')
        off_on = [HugoNR.ImageCapture]::Compare($off, $on, (Join-Path $directory 'nr-difference-x4.png'))
    }
    $classification = Get-HugoImageTestClassification -NativeInputsIdentical $report.native_inputs_identical -BackendReported $report.enabled_phase_evidence.neural_frame_reported -Differences $report.differences
    $report.status = $classification.status
    $report.reason_code = $classification.reason_code
    $report.display_output_verified = $classification.display_output_verified
} catch {
    $report.status = 'inconclusive'
    $report.reason_code = $_.Exception.Message
    $report.display_output_verified = $false
} finally {
    if ($null -ne $script:probeProcess) {
        try {
            if (-not $script:probeProcess.HasExited) {
                Write-HugoNeuralLiveStatus -Path $controlPath -Status @{ schema = 1; session = $session; command = 'finish'; request = 0 }
                if (-not $script:probeProcess.WaitForExit(5000)) { $script:probeProcess.Kill(); [void]$script:probeProcess.WaitForExit(5000) }
            }
            if (Test-Path -LiteralPath $finalPath) {
                $report.native_final = Get-Content -LiteralPath $finalPath -Raw | ConvertFrom-Json
            }
            if ($report.display_output_verified -and ($script:probeProcess.ExitCode -ne 0 -or -not $report.Contains('native_final') -or -not $report.native_final.success -or -not $report.native_final.native_inputs_identical -or $report.native_final.native_input_samples -ne 5 -or $report.native_final.visual_session -ne $session)) {
                $report.status = 'inconclusive'; $report.reason_code = 'native_probe_did_not_complete'; $report.display_output_verified = $false
            }
        } catch { $report.shutdown_warning = $_.Exception.Message; $report.status = 'inconclusive'; $report.reason_code = 'probe_shutdown_failed'; $report.display_output_verified = $false }
    }
    # Preserve both the user's exact config and their real-play log/timestamps.
    # The test log can never masquerade as the previous game's verification.
    try {
        if ($iniChanged -and (Test-Path -LiteralPath $backupIni)) { Copy-Item -LiteralPath $backupIni -Destination $iniPath -Force }
        if ($iniChanged -and (Test-Path -LiteralPath $logPath)) { Move-Item -LiteralPath $logPath -Destination (Join-Path $directory 'visual-ReShade.log') }
        if ($logArchived) { Move-Item -LiteralPath $backupLog -Destination $logPath }
    } catch { $report.restore_warning = $_.Exception.Message; $report.status = 'inconclusive'; $report.display_output_verified = $false }
    $report.completed_utc = [DateTime]::UtcNow.ToString('o')
    Write-HugoNeuralLiveStatus -Path $reportPath -Status $report
}
Write-Host ($report.status + ': ' + $report.reason_code)
Write-Host $reportPath
if ($report.display_output_verified) { exit 0 }
exit 2
