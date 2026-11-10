# Shared, local-only validation. This file never loads any downloaded DLL.
Set-StrictMode -Version 2.0

function Get-HugoSafePath {
    param([string]$Root, [string]$Relative)
    if (-not $Relative -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':') -or $Relative.Contains('\') -or (($Relative -split '/') -contains '..')) { throw 'Unsafe path in pack manifest.' }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $path = [IO.Path]::GetFullPath((Join-Path $base $Relative))
    if (-not $path.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw 'Pack path escapes its directory.' }
    $cursor = $path
    while ($cursor.Length -ge $base.TrimEnd([IO.Path]::DirectorySeparatorChar).Length) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse points are not accepted inside the pack.' }
        }
        $next = Split-Path -Parent $cursor
        if (-not $next -or $next -eq $cursor) { break }
        $cursor = $next
    }
    return $path
}

function Test-HugoPackFiles {
    param([string]$Root, $Manifest, [switch]$IncludeMutable)
    foreach ($entry in $Manifest.files) {
        $path = Get-HugoSafePath -Root $Root -Relative $entry.path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { "Missing: $($entry.path)"; continue }
        if ($entry.mutable -and -not $IncludeMutable) { continue }
        if ((Get-Item -LiteralPath $path).Length -ne $entry.size) { "Size mismatch: $($entry.path)"; continue }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.sha256) { "SHA256 mismatch: $($entry.path)" }
    }
}

function Test-HugoPck {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    try { $bytes = New-Object byte[] 4; $read = $stream.Read($bytes, 0, 4); return ($read -eq 4 -and [Text.Encoding]::ASCII.GetString($bytes) -eq 'GDPC') }
    finally { $stream.Dispose() }
}

function Test-HugoGodotImage {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    try {
        $header = New-Object byte[] 64
        if ($stream.Read($header, 0, 64) -ne 64 -or $header[0] -ne 77 -or $header[1] -ne 90) { throw 'Not a Windows PE executable.' }
        $pe = [BitConverter]::ToUInt32($header, 60)
        if ($pe -gt 1048576 -or $pe + 26 -gt $stream.Length) { throw 'Invalid PE header.' }
        $stream.Position = $pe
        $image = New-Object byte[] 26
        if ($stream.Read($image, 0, 26) -ne 26 -or [BitConverter]::ToUInt32($image, 0) -ne 17744 -or [BitConverter]::ToUInt16($image, 4) -ne 34404 -or [BitConverter]::ToUInt16($image, 24) -ne 523) { throw 'Only a Godot Windows x64 export is supported.' }
        if ($stream.Length -lt 12) { return $false }
        $stream.Position = $stream.Length - 12
        $footer = New-Object byte[] 12
        [void]$stream.Read($footer, 0, 12)
        if ([Text.Encoding]::ASCII.GetString($footer, 8, 4) -ne 'GDPC') { return $false }
        $size = [BitConverter]::ToUInt64($footer, 0)
        if ($size -lt 4 -or $size -gt $stream.Length - 12) { throw 'Invalid embedded Godot pack.' }
        $stream.Position = $stream.Length - 12 - $size
        $magic = New-Object byte[] 4
        [void]$stream.Read($magic, 0, 4)
        if ([Text.Encoding]::ASCII.GetString($magic) -ne 'GDPC') { throw 'Embedded Godot pack header is missing.' }
        return $true
    } finally { $stream.Dispose() }
}

function Get-HugoNeuralEvidence {
    param([string]$Log)
    $markers = [ordered]@{
        opengl_bridge = 'OpenGL: NR runs on a private Direct3D 12 device'
        nr_feature_created = 'NR feature created '
        enabled_evaluation = 'NR diagnostic: enabled D3D12 evaluation recorded'
        frame_returned = "NR ran on the game's frame (OpenGL, 64-bit)"
    }
    $found = [ordered]@{}
    foreach ($key in $markers.Keys) { $found[$key] = $Log.Contains($markers[$key]) }
    $failureLines = @($Log -split "`r?`n" | Where-Object { $_ -match "OpenGL bridge stopped:|CreateFeature .*failed:|Init_Ext failed|GPU device was removed|NR could not start|Uplift could not start|NR feature creation failed:|NR evaluate failed:|NR disabled after|Suspended: game needs VRAM|NR's recording .*threw|The back buffer could not be shared" })
    $toggles = [regex]::Matches($Log, 'Hotkey: NR (enabled|disabled)|Enabled set to ([01]) in ReShade.ini')
    $disabled = $false
    $frameAfterEnable = $true
    if ($toggles.Count) {
        $lastToggle = $toggles[$toggles.Count - 1]
        $disabled = $lastToggle.Value -match 'disabled|set to 0'
        # The bridge emits its frame marker once per enable, not every frame.
        # Re-enabling must produce a new returned frame before its old evidence
        # is reused. This is still no readback proof or processed-frame count.
        $frameAfterEnable = $Log.LastIndexOf($markers.frame_returned) -gt $lastToggle.Index
    }
    $diagnostics = @($Log -split "`r?`n" | Where-Object { $_.Contains('NR diagnostic: enabled D3D12 evaluation recorded') })
    $lastDiagnostic = if ($diagnostics.Count) { $diagnostics[$diagnostics.Count - 1] } else { $null }
    $ready = $found.opengl_bridge -and $found.nr_feature_created -and $found.enabled_evaluation -and $found.frame_returned -and $failureLines.Count -eq 0 -and -not $disabled -and $frameAfterEnable
    $boundedFailures = @($failureLines | Select-Object -Last 12 | ForEach-Object { if ($_.Length -gt 1024) { $_.Substring(0, 1024) } else { $_ } })
    if ($null -ne $lastDiagnostic -and $lastDiagnostic.Length -gt 2048) { $lastDiagnostic = $lastDiagnostic.Substring(0, 2048) }
    return [ordered]@{ markers = $found; neural_frame_reported = [bool]$ready; motion_resource_reported = [bool]($Log -match 'enabled D3D12 evaluation recorded[^\r\n]*motion true'); failures = $boundedFailures; disabled_reported = $disabled; last_evaluation_diagnostic = $lastDiagnostic; frames_processed = $null; display_output_verified = $false; evidence_kind = 'once_per_enable_backend_markers' }
}

function Get-HugoIniSection {
    param([string]$Path, [string]$Section)
    $values = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $values }
    $current = ''
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match '^\s*\[([^\]]+)\]\s*$') { $current = $Matches[1]; continue }
        if ($current -eq $Section -and $line -match '^\s*([^=;#]+?)\s*=\s*(.*)$') { $values[$Matches[1].Trim()] = $Matches[2].Trim() }
    }
    return $values
}

function Get-HugoNeuralConfiguration {
    param([string]$Root)
    $iniPath = Join-Path $Root 'ReShade.ini'
    $uplift = Get-HugoIniSection -Path $iniPath -Section 'Uplift'
    # Defaults are pinned to the packaged Uplift 1.8 source, not guesses based on
    # an adapter name. Include output strengths: successful Evaluate can still
    # be blended back to the original image by a user-modified configuration.
    $defaults = [ordered]@{ Enabled = 0; Intensity = 1; TransferStrength = 1; ColorStrength = 1; LocalTone = 1; LocalStructure = 1; SkinStructure = 1; AutoMask = 1; MaskBlendMode = 1; Mask = 0; Source = 0; MotionVectors = 0; PassCount = 1; Preset = 1; KeepFaces = 0 }
    $settings = [ordered]@{}
    $invalid = @()
    foreach ($key in $defaults.Keys) {
        $value = [double]$defaults[$key]
        if ($uplift.ContainsKey($key)) {
            if (-not [double]::TryParse($uplift[$key], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value) -or [double]::IsNaN($value) -or [double]::IsInfinity($value)) { $invalid += $key; $value = [double]$defaults[$key] }
        }
        $settings[$key] = $value
    }
    $general = Get-HugoIniSection -Path $iniPath -Section 'GENERAL'
    $presetRelative = if ($general.ContainsKey('PresetPath')) { ([string]$general.PresetPath).Replace('\', '/') } else { 'ReShadePreset_DLSS5.ini' }
    if ($presetRelative.StartsWith('./')) { $presetRelative = $presetRelative.Substring(2) }
    $preset = @{}
    $presetInspected = $false
    try {
        $presetPath = Get-HugoSafePath -Root $Root -Relative $presetRelative
        $preset = Get-HugoIniSection -Path $presetPath -Section ''
        $presetInspected = Test-Path -LiteralPath $presetPath -PathType Leaf
    } catch { }
    $techniques = if ($preset.ContainsKey('Techniques')) { [string]$preset.Techniques } else { '' }
    $warnings = @()
    if ($settings.MaskBlendMode -eq 0) { $warnings += 'native_mask_mode_zero_can_reduce_visible_change' }
    if ($techniques -notmatch '(^|,)Uplift@Uplift\.fx(,|$)') { $warnings += 'uplift_marker_not_enabled_in_pack_preset' }
    if ($settings.MotionVectors -eq 4 -and $techniques -notmatch 'Lumenite_Kernel@lumenite_Kernel\.fx') { $warnings += 'selected_lumenite_not_enabled_in_pack_preset' }
    if (-not $presetInspected) { $warnings += 'configured_preset_not_inspected' }
    return [ordered]@{ present = (Test-Path -LiteralPath $iniPath -PathType Leaf); settings = $settings; configured_preset = $presetRelative; preset_inspected = $presetInspected; configured_techniques = $techniques; invalid_numeric_settings = $invalid; warnings = $warnings; runtime_values_read_back = $false }
}

function Get-HugoImageTestClassification {
    param([bool]$NativeInputsIdentical, [bool]$BackendReported, $Differences)
    $result = [ordered]@{ status = 'inconclusive'; reason_code = 'native_input_changed'; display_output_verified = $false }
    if (-not $NativeInputsIdentical) { return $result }
    if (-not $BackendReported) { $result.reason_code = 'enabled_phase_backend_not_confirmed'; return $result }
    foreach ($key in @('off_repeat', 'on_repeat', 'off_return', 'off_on')) {
        if (-not $Differences[$key].FirstNonuniform -or -not $Differences[$key].SecondNonuniform) { $result.reason_code = 'blank_or_uniform_desktop_capture'; return $result }
    }
    # The off/off control and off return must remain stable. Otherwise an OS
    # overlay, a moving window or an un-frozen input could imitate an NR change.
    foreach ($key in @('off_repeat', 'off_return')) {
        $delta = $Differences[$key]
        if ($delta.MeanAbsoluteRgb -gt 0.05 -or $delta.ChangedPixels -gt [Math]::Max(16, $delta.Pixels * 0.0001)) { $result.reason_code = 'desktop_off_control_not_stable'; return $result }
    }
    $change = $Differences.off_on
    $noise = [Math]::Max($Differences.off_repeat.CentralMeanAbsoluteRgb, $Differences.off_return.CentralMeanAbsoluteRgb)
    if ($change.CentralMeanAbsoluteRgb -le [Math]::Max(0.25, $noise * 10) -or $change.CentralChangedPixels -le [Math]::Max(256, $change.CentralPixels * 0.001)) {
        $result.status = 'no_visible_change'; $result.reason_code = 'backend_reported_but_frozen_display_change_below_threshold'; return $result
    }
    if ($Differences.on_repeat.CentralMeanAbsoluteRgb -gt [Math]::Max(0.1, $change.CentralMeanAbsoluteRgb * 0.5)) { $result.reason_code = 'neural_output_not_settled'; return $result }
    $result.status = 'display_change_verified'
    $result.reason_code = 'frozen_native_input_and_reversible_desktop_difference'
    $result.display_output_verified = $true
    return $result
}

function New-HugoNeuralLiveStatus {
    param([string]$Session, [int]$GameProcessId, [DateTime]$StartedUtc, [switch]$ObserveNeural, [string]$InactiveReason = 'neural_not_requested', [string]$Log = '', [bool]$FreshLog = $false, $Configuration = $null)
    $status = [ordered]@{ schema = 1; session = $Session; provider = 'none'; state = 'inactive'; reason_code = $InactiveReason; frames_processed = $null; updated_utc = [DateTime]::UtcNow.ToString('o'); process_id = $GameProcessId; started_utc = $StartedUtc.ToUniversalTime().ToString('o'); display_output_verified = $false }
    if (-not $ObserveNeural) { return $status }
    $status.provider = 'gitc_uplift_opengl'
    $status.state = 'probing'
    $status.reason_code = 'awaiting_current_process_backend_frame'
    if (([DateTime]::UtcNow - $StartedUtc.ToUniversalTime()).TotalSeconds -ge 30) { $status.state = 'inactive'; $status.reason_code = 'no_current_process_backend_frame_yet' }
    if ($null -ne $Configuration) {
        $status.configuration = $Configuration
        if (-not $Configuration.present) { $status.state = 'inactive'; $status.reason_code = 'configuration_missing'; return $status }
        if ($Configuration.settings.Enabled -eq 0) { $status.state = 'inactive'; $status.reason_code = 'disabled_in_configuration'; return $status }
        if ($Configuration.settings.Intensity -le 0) { $status.state = 'inactive'; $status.reason_code = 'zero_intensity'; return $status }
        if ($Configuration.settings.TransferStrength -eq 0 -and $Configuration.settings.ColorStrength -eq 0) { $status.state = 'inactive'; $status.reason_code = 'zero_result_strength'; return $status }
    }
    if (-not $FreshLog) { return $status }
    $evidence = Get-HugoNeuralEvidence -Log $Log
    $status.evidence = $evidence
    if ($evidence.failures.Count) { $status.state = 'failed'; $status.reason_code = 'backend_failure'; return $status }
    if ($evidence.disabled_reported) { $status.state = 'inactive'; $status.reason_code = 'disabled_by_backend'; return $status }
    if ($evidence.neural_frame_reported) { $status.state = 'backend_reported'; $status.reason_code = 'backend_frame_reported_display_unverified' }
    return $status
}

function Write-HugoNeuralLiveStatus {
    param([string]$Path, $Status)
    if (-not $Path) { return }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $temporary = $fullPath + '.new'
    [IO.File]::WriteAllText($temporary, ($Status | ConvertTo-Json -Depth 14), (New-Object Text.UTF8Encoding $false))
    # Readers either get the previous complete JSON or the new complete JSON.
    # The file is per session and has a single launcher writer.
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            if (Test-Path -LiteralPath $fullPath) { [IO.File]::Replace($temporary, $fullPath, [NullString]::Value) }
            else { [IO.File]::Move($temporary, $fullPath) }
            return
        } catch [IO.IOException] {
            # A Windows reader may briefly hold the old file without delete
            # sharing. Retry the atomic rename; never publish partial JSON.
            if ($attempt -eq 4) { throw }
            Start-Sleep -Milliseconds 25
        }
    }
}

function Get-HugoDlss5Status {
    param([string]$Root, [switch]$StaticOnly)
    $manifest = Get-Content -LiteralPath (Join-Path $Root 'dlss5-pack-manifest.json') -Raw | ConvertFrom-Json
    $state = Get-Content -LiteralPath (Join-Path $Root 'dlss5-install-state.json') -Raw | ConvertFrom-Json
    if ($manifest.pack_id -ne 'hugo-dlss5-gitc-opengl-v1' -or $state.pack_id -ne $manifest.pack_id) { throw 'Invalid installation marker.' }
    # Localization is optional data. Its absence/corruption must not disable a
    # working graphics route, and hashing hundreds of MB here delays every launch.
    # The game checks each requested language cue before opening it.
    $graphicsState = @{ files = @($state.files | Where-Object { $_.path -ne 'Hugo_Languages.pck' }) }
    $errors = @(Test-HugoPackFiles -Root $Root -Manifest $graphicsState)
    $report = [ordered]@{ schema = 1; backend = $manifest.backend; static_files_ok = ($errors.Count -eq 0); errors = $errors; status = 'static_ready_not_executed'; neural_frame_reported = $false; visual_quality_validated = $false; benchmark_validated = $false }
    $report.optional_language_pack = [ordered]@{ present = (Test-Path -LiteralPath (Join-Path $Root 'Hugo_Languages.pck') -PathType Leaf); required_for_graphics = $false; integrity = 'checked_per_cue_by_game' }
    $report.configuration = Get-HugoNeuralConfiguration -Root $Root
    $report.frames_processed = $null
    $report.display_output_verified = $false
    if ($errors.Count) { $report.status = 'files_invalid'; return $report }
    if ($StaticOnly) { return $report }
    $runPath = Join-Path $Root 'dlss5-last-run.json'
    $logPath = Join-Path $Root 'ReShade.log'
    if (-not (Test-Path -LiteralPath $runPath) -or -not (Test-Path -LiteralPath $logPath)) { return $report }
    $run = Get-Content -LiteralPath $runPath -Raw | ConvertFrom-Json
    # ConvertFrom-Json can return a DateTime instead of a string. Reparsing that
    # object through a locale-dependent string loses its UTC kind on PowerShell.
    if ($run.started_utc -is [DateTime]) { $started = $run.started_utc.ToUniversalTime() }
    elseif ($run.started_utc -is [DateTimeOffset]) { $started = $run.started_utc.UtcDateTime }
    else { $started = [DateTimeOffset]::Parse([string]$run.started_utc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime }
    $report.run_started_utc = $started.ToString('o')
    $report.log_modified_utc = (Get-Item -LiteralPath $logPath).LastWriteTimeUtc.ToString('o')
    if ((Get-Item -LiteralPath $logPath).LastWriteTimeUtc -lt $started) { $report.status = 'stale_log_rejected'; return $report }
    $evidence = Get-HugoNeuralEvidence -Log (Get-Content -LiteralPath $logPath -Raw)
    $report.evidence = $evidence
    $report.run_id = $run.run_id
    $report.neural_frame_reported = $evidence.neural_frame_reported
    $report.status = 'started_without_neural_frame_evidence'
    if ($evidence.neural_frame_reported) { $report.status = 'neural_frame_reported_by_backend' }
    if ($null -ne $run.exit_code -and $run.exit_code -ne 0) { $report.status = 'game_process_failed'; $report.neural_frame_reported = $false }
    return $report
}

function Select-HugoGraphicsRoute {
    param($Probe, [bool]$NeuralFilesValid)
    if ($null -eq $Probe -or -not $Probe.success) { return 'clean_engine_auto' }
    if ($Probe.angle_detected -or $Probe.rendering_driver -match 'angle') { return 'clean_angle' }
    if ($Probe.software_renderer -or -not $Probe.hardware_verified -or -not $NeuralFilesValid) { return 'clean_native' }
    if ($Probe.rendering_driver -ne 'opengl3' -or $Probe.rendering_method -ne 'gl_compatibility') { return 'clean_native' }
    $vendor = [string]$Probe.adapter.vendor
    $name = [string]$Probe.adapter.name
    if (($vendor -match 'NVIDIA|10de' -or $name -match 'NVIDIA') -and $name -match 'RTX') { return 'neural_probe_required' }
    return 'clean_native'
}

function Select-HugoCleanProfile {
    param($Probe)
    # An unavailable neural backend says nothing about the quality a working
    # GPU can render. Preserve the user's normal settings on verified hardware;
    # reserve the bounded texture/AA profile for unknown or software renderers.
    if ($null -eq $Probe) { return '--graphics-safe-profile' }
    foreach ($name in @('success', 'headless', 'software_renderer', 'hardware_verified')) {
        if (-not $Probe.PSObject.Properties[$name]) { return '--graphics-safe-profile' }
    }
    if (-not $Probe.success -or $Probe.headless -or
        $Probe.software_renderer -or -not $Probe.hardware_verified) {
        return '--graphics-safe-profile'
    }
    return ''
}

function ConvertTo-HugoArgumentString {
    param([string[]]$Arguments)
    $quoted = foreach ($argument in $Arguments) {
        if ($argument -notmatch '[\s"]' -and $argument.Length) { $argument }
        else {
            $escaped = [regex]::Replace($argument, '(\\*)"', '$1$1\"')
            $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
            '"' + $escaped + '"'
        }
    }
    return $quoted -join ' '
}

function Invoke-HugoBoundedProcess {
    param([string]$FilePath, [string]$WorkingDirectory, [string[]]$Arguments, [int]$TimeoutSeconds = 120)
    # Only explicit graphics probes use this timeout/termination path.
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try { $process = Start-Process -FilePath $FilePath -WorkingDirectory $WorkingDirectory -ArgumentList (ConvertTo-HugoArgumentString $Arguments) -PassThru }
    catch { return [ordered]@{ started = $false; timed_out = $false; exit_code = $null; error = $_.Exception.Message } }
    while (-not $process.WaitForExit(250)) {
        if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            try { $process.Kill(); [void]$process.WaitForExit(5000) } catch { }
            return [ordered]@{ started = $true; timed_out = $true; exit_code = $null; error = 'bounded_probe_timeout' }
        }
    }
    return [ordered]@{ started = $true; timed_out = $false; exit_code = $process.ExitCode; error = $null }
}

function New-HugoGameArguments {
    param([string]$Root, [string]$Driver, [string]$Profile, [string]$NeuralStatusPath = '', [string]$Session = '')
    $result = @('--rendering-method', 'gl_compatibility')
    if ($Driver) { $result += @('--rendering-driver', $Driver) }
    if (Test-Path -LiteralPath (Join-Path $Root 'HugoRemaster.pck')) { $result += @('--main-pack', 'HugoRemaster.pck') }
    $userArguments = @()
    if ($Profile) { $userArguments += $Profile }
    if ($NeuralStatusPath -and $Session) { $userArguments += @(('--nr-status-file=' + [IO.Path]::GetFullPath($NeuralStatusPath)), ('--nr-session=' + $Session)) }
    if ($userArguments.Count) { $result += @('--') + $userArguments }
    return $result
}

function Start-HugoObservedGame {
    param([string]$Root, [string]$Driver, [string]$Profile, [switch]$ObserveNeural, [string]$NeuralStatusPath = '', [string]$Session = '', [string]$InactiveReason = 'neural_not_requested')
    $started = [DateTime]::UtcNow
    $logPath = Join-Path $Root 'ReShade.log'
    $logExisted = Test-Path -LiteralPath $logPath
    $arguments = @(New-HugoGameArguments -Root $Root -Driver $Driver -Profile $Profile -NeuralStatusPath $NeuralStatusPath -Session $Session)
    $live = New-HugoNeuralLiveStatus -Session $Session -GameProcessId 0 -StartedUtc $started -ObserveNeural:$ObserveNeural -InactiveReason $InactiveReason
    Write-HugoNeuralLiveStatus -Path $NeuralStatusPath -Status $live
    try { $process = Start-Process -FilePath (Join-Path $Root 'HugoRemaster.exe') -ArgumentList (ConvertTo-HugoArgumentString $arguments) -WorkingDirectory $Root -PassThru }
    catch {
        $live.state = 'failed'; $live.reason_code = 'game_start_failed'
        Write-HugoNeuralLiveStatus -Path $NeuralStatusPath -Status $live
        return [ordered]@{ exit_code = -1; neural_failure_seen = $false; process_id = 0; error = $_.Exception.Message }
    }
    $live.process_id = $process.Id
    Write-HugoNeuralLiveStatus -Path $NeuralStatusPath -Status $live
    $neuralFailure = $false
    $currentLog = ''
    $lastLogStamp = ''
    $fresh = $false
    while (-not $process.WaitForExit(1000)) {
        try {
            $configuration = $null
            if ($ObserveNeural) {
                $configuration = Get-HugoNeuralConfiguration -Root $Root
                if (Test-Path -LiteralPath $logPath) {
                    $item = Get-Item -LiteralPath $logPath
                    # Actual-launch logs are archived by Launch-Hugo, separately
                    # from preflight/cached evidence. Never consume an earlier
                    # process's log just because its file was touched recently.
                    $fresh = -not $logExisted -and $item.LastWriteTimeUtc -ge $started
                    $stamp = [string]$item.LastWriteTimeUtc.Ticks + ':' + [string]$item.Length
                    if ($fresh -and $stamp -ne $lastLogStamp) {
                        $stream = New-Object IO.FileStream($logPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                        $reader = New-Object IO.StreamReader($stream)
                        try { $currentLog = $reader.ReadToEnd() } finally { $reader.Dispose() }
                        $lastLogStamp = $stamp
                    }
                }
            }
            $live = New-HugoNeuralLiveStatus -Session $Session -GameProcessId $process.Id -StartedUtc $started -ObserveNeural:$ObserveNeural -InactiveReason $InactiveReason -Log $currentLog -FreshLog $fresh -Configuration $configuration
            if ($live.state -eq 'failed' -and -not $neuralFailure) { $neuralFailure = $true; Write-Host 'NR reported a failure. The game remains active; see its neural-rendering status.' }
            Write-HugoNeuralLiveStatus -Path $NeuralStatusPath -Status $live
        } catch {
            # A transient locked log/status file must not kill or relaunch play.
            # The in-game reader expires a missing launcher heartbeat.
        }
        # Never terminate an actual game just because NR is absent or slow.
    }
    $live.state = if ($process.ExitCode -eq 0) { 'inactive' } else { 'failed' }
    $live.reason_code = if ($process.ExitCode -eq 0) { 'game_exited' } else { 'game_process_failed' }
    $live.updated_utc = [DateTime]::UtcNow.ToString('o')
    Write-HugoNeuralLiveStatus -Path $NeuralStatusPath -Status $live
    return [ordered]@{ exit_code = $process.ExitCode; neural_failure_seen = $neuralFailure; process_id = $process.Id; error = $null }
}
