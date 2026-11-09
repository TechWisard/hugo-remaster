[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$GameExe,
    [Parameter(Mandatory = $true)][string]$Destination,
    [string]$PckFile = '',
    [string]$LanguagePackFile = '',
    [string]$PackDirectory = $PSScriptRoot
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PackDirectory 'payload/Hugo-DLSS5.ps1')

$pack = Get-Content -LiteralPath (Join-Path $PackDirectory 'pack-manifest.json') -Raw | ConvertFrom-Json
if ($pack.pack_id -ne 'hugo-dlss5-gitc-opengl-v1') { throw 'Unknown pack format.' }
$payload = Join-Path $PackDirectory 'payload'
$failures = @(Test-HugoPackFiles -Root $payload -Manifest $pack -IncludeMutable)
if ($failures.Count) { throw ('Pack verification failed: ' + ($failures -join '; ')) }
$gamePath = (Resolve-Path -LiteralPath $GameExe).Path
$embedded = Test-HugoGodotImage -Path $gamePath
if (-not $embedded) {
    if (-not $PckFile) { $PckFile = [IO.Path]::ChangeExtension($gamePath, '.pck') }
    $PckFile = (Resolve-Path -LiteralPath $PckFile).Path
    if (-not (Test-HugoPck -Path $PckFile)) { throw 'A Godot GDPC resource pack is required.' }
}
if (-not $LanguagePackFile) {
    $adjacentLanguages = Join-Path (Split-Path -Parent $gamePath) 'Hugo_Languages.pck'
    if (Test-Path -LiteralPath $adjacentLanguages -PathType Leaf) { $LanguagePackFile = $adjacentLanguages }
}
if ($LanguagePackFile) {
    $LanguagePackFile = (Resolve-Path -LiteralPath $LanguagePackFile).Path
    if (-not (Test-HugoPck -Path $LanguagePackFile)) { throw 'The optional language pack must be a Godot GDPC pack.' }
}
$destinationPath = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $destinationPath) { throw 'Destination must not exist. Choose a new isolated directory.' }
$parent = Split-Path -Parent $destinationPath
[IO.Directory]::CreateDirectory($parent) | Out-Null
$stage = Join-Path $parent ('.hugo-dlss5-stage-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($stage) | Out-Null
try {
    foreach ($entry in $pack.files) {
        $target = Get-HugoSafePath -Root $stage -Relative $entry.path
        [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
        Copy-Item -LiteralPath (Get-HugoSafePath -Root $payload -Relative $entry.path) -Destination $target
    }
    Copy-Item -LiteralPath $gamePath -Destination (Join-Path $stage 'HugoRemaster.exe')
    $gameFiles = @('HugoRemaster.exe')
    if (-not $embedded) {
        Copy-Item -LiteralPath $PckFile -Destination (Join-Path $stage 'HugoRemaster.pck')
        $gameFiles += 'HugoRemaster.pck'
    }
    $clean = Join-Path $stage 'clean'
    [IO.Directory]::CreateDirectory($clean) | Out-Null
    foreach ($relative in @($gameFiles)) {
        Copy-Item -LiteralPath (Join-Path $stage $relative) -Destination (Join-Path $clean $relative)
        $gameFiles += 'clean/' + $relative
    }
    # One shared language pack is enough. The clean executable resolves this
    # fixed name in its parent directory; no DLL or other proxy is copied there.
    if ($LanguagePackFile) {
        Copy-Item -LiteralPath $LanguagePackFile -Destination (Join-Path $stage 'Hugo_Languages.pck')
        $gameFiles += 'Hugo_Languages.pck'
    }
    Copy-Item -LiteralPath (Join-Path $PackDirectory 'pack-manifest.json') -Destination (Join-Path $stage 'dlss5-pack-manifest.json')
    $owned = @($pack.files)
    foreach ($relative in ($gameFiles + 'dlss5-pack-manifest.json')) {
        $file = Get-Item -LiteralPath (Join-Path $stage $relative)
        $owned += [ordered]@{ path = $relative; size = $file.Length; sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant(); mutable = $false }
    }
    $state = [ordered]@{ schema = 1; pack_id = $pack.pack_id; created_utc = [DateTime]::UtcNow.ToString('o'); embedded_pck = $embedded; files = $owned }
    $state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $stage 'dlss5-install-state.json') -Encoding UTF8
    [IO.Directory]::Move($stage, $destinationPath)
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
[ordered]@{ status = 'installed_not_executed'; directory = $destinationPath; launch = 'Launch-Hugo.cmd'; model_execution = 'not_run'; clean_fallback = 'clean' } | ConvertTo-Json
