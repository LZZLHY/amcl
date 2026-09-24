param(
    [string]$BuildDir = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceDir = Join-Path $repoRoot "entry/src/main/cpp/tests/host"
# 自建宿主测试输出与 SDK 原生 build 分开；显式目录同样校验，避免旧参数让缓存回流源码仓。
. (Join-Path $PSScriptRoot 'lib/workspace-paths.ps1')
$BuildDir = Get-AmclWorkspacePath -Kind build -Id 'input-host-tests' -ProjectRoot $repoRoot -ExplicitPath $BuildDir

$cmakeCommand = Get-Command cmake -ErrorAction SilentlyContinue
$cmake = if ($cmakeCommand) { $cmakeCommand.Source } else { "" }
$generator = ""
if ([string]::IsNullOrWhiteSpace($cmake)) {
    $vswhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vsRoot = (& $vswhere -latest -products * -requires `
            Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath).Trim()
        $bundledRoot = Join-Path $vsRoot `
            "Common7/IDE/CommonExtensions/Microsoft/CMake"
        $candidate = Join-Path $bundledRoot "CMake/bin/cmake.exe"
        if (Test-Path $candidate) {
            $cmake = $candidate
            $generator = "Visual Studio 18 2026"
        }
    }
}
if ([string]::IsNullOrWhiteSpace($cmake)) {
    throw "No host CMake found (PATH or Visual Studio bundled CMake)"
}

$configure = @('-S', $sourceDir, '-B', $BuildDir)
if (-not [string]::IsNullOrWhiteSpace($generator)) {
    $configure += @('-G', $generator, '-A', 'x64')
}
Write-Host "Configuring SDK-independent AMCL input host tests..."
& $cmake @configure
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Building all AMCL input host tests..."
& $cmake --build $BuildDir --config Release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$ctest = Join-Path (Split-Path -Parent $cmake) "ctest.exe"
Write-Host "Running AMCL input-labeled host tests (render/network/JNI tests are separate)..."
& $ctest --test-dir $BuildDir -C Release -L input --output-on-failure
exit $LASTEXITCODE
