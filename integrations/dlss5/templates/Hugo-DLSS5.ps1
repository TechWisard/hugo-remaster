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
    $failureLines = @($Log -split "`r?`n" | Where-Object { $_ -match "OpenGL bridge stopped:|CreateFeature .*failed:|Init_Ext failed|GPU device was removed|NR could not start|NR feature creation failed:|NR evaluate failed:|NR disabled after|Suspended: game needs VRAM|NR's recording .*threw|The back buffer could not be shared" })
    $ready = $found.opengl_bridge -and $found.nr_feature_created -and $found.enabled_evaluation -and $found.frame_returned -and $failureLines.Count -eq 0
    return [ordered]@{ markers = $found; neural_frame_reported = [bool]$ready; motion_resource_reported = [bool]($Log -match 'enabled D3D12 evaluation recorded[^\r\n]*motion true'); failures = $failureLines }
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
    param([string]$Root, [string]$Driver, [string]$Profile)
    $result = @('--rendering-method', 'gl_compatibility')
    if ($Driver) { $result += @('--rendering-driver', $Driver) }
    if (Test-Path -LiteralPath (Join-Path $Root 'HugoRemaster.pck')) { $result += @('--main-pack', 'HugoRemaster.pck') }
    if ($Profile) { $result += @('--', $Profile) }
    return $result
}

function Start-HugoObservedGame {
    param([string]$Root, [string]$Driver, [string]$Profile, [switch]$ObserveNeural)
    $arguments = @(New-HugoGameArguments -Root $Root -Driver $Driver -Profile $Profile)
    try { $process = Start-Process -FilePath (Join-Path $Root 'HugoRemaster.exe') -ArgumentList (ConvertTo-HugoArgumentString $arguments) -WorkingDirectory $Root -PassThru }
    catch { return [ordered]@{ exit_code = -1; neural_failure_seen = $false; error = $_.Exception.Message } }
    $neuralFailure = $false
    while (-not $process.WaitForExit(1000)) {
        if ($ObserveNeural -and -not $neuralFailure) {
            $log = Join-Path $Root 'ReShade.log'
            if (Test-Path -LiteralPath $log) {
                $tail = (Get-Content -LiteralPath $log -Tail 60 -ErrorAction SilentlyContinue) -join "`n"
                if ((Get-HugoNeuralEvidence -Log $tail).failures.Count) {
                    $neuralFailure = $true
                    Write-Host 'NR reported a failure. The game remains active; the backend may skip neural processing.'
                }
            }
        }
        # Never terminate an actual game just because NR is absent or slow.
    }
    return [ordered]@{ exit_code = $process.ExitCode; neural_failure_seen = $neuralFailure; error = $null }
}
