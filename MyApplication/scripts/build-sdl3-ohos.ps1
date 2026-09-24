param(
    [string]$SourceRepo = "",
    [string]$BuildRoot = "",
    [switch]$Deploy
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir '..'))
$LockPath = Join-Path $ProjectRoot 'deps.lock'
# SDL 的锁定输入仍在工程中；打补丁的工作树和编译结果必须留在工作区统一构建目录。
# helper 根据当前 checkout 生成隔离路径，避免不同工作树共享同一 CMake 缓存。
. (Join-Path $ScriptDir 'lib\workspace-paths.ps1')
$AllowedOutputRoot = Get-AmclWorkspacePath -Kind build -Id 'sdl3' -ProjectRoot $ProjectRoot

function Read-LockField([string]$Section, [string]$Key) {
    $inside = $false
    foreach ($raw in Get-Content -LiteralPath $LockPath) {
        $line = $raw.TrimEnd("`r")
        if ($line -match '^\s*\[(.+)\]\s*$') {
            $inside = $Matches[1] -eq $Section
            continue
        }
        if (-not $inside) { continue }
        $match = [regex]::Match($line, '^\s*' + [regex]::Escape($Key) + '\s*=\s*([^#]*?)\s*(?:#.*)?$')
        if ($match.Success) { return $match.Groups[1].Value.Trim() }
    }
    throw "deps.lock [$Section].$Key is missing"
}

function Invoke-Checked([string]$File, [string[]]$Arguments, [string]$WorkingDirectory = $ProjectRoot) {
    Push-Location $WorkingDirectory
    try {
        & $File @Arguments
        if ($LASTEXITCODE -ne 0) { throw "command failed ($LASTEXITCODE): $File $($Arguments -join ' ')" }
    } finally {
        Pop-Location
    }
}

$Commit = Read-LockField 'sdl3-native' 'commit'
$AbiBase = Read-LockField 'sdl3-native' 'abi_base'
$Revision = Read-LockField 'sdl3-native' 'version_string'
$ExpectedPatchsetSha = (Read-LockField 'sdl3-native' 'patchset_sha256').ToLowerInvariant()
$ExpectedSize = [long](Read-LockField 'sdl3-native' 'size')
$ExpectedSha = (Read-LockField 'sdl3-native' 'sha256').ToLowerInvariant()

if ($Commit -notmatch '^[0-9a-f]{40}$' -or $AbiBase -notmatch '^[0-9a-f]{40}$') {
    throw 'SDL3 commit/abi_base must be exact 40-character hashes'
}
if ($Revision -notlike "*g$($Commit.Substring(0, 9))*") {
    throw "version_string does not contain pinned commit prefix: $Revision"
}
if ($ExpectedPatchsetSha -notmatch '^[0-9a-f]{64}$') {
    throw 'SDL3 patchset_sha256 must be exact lowercase 64-character hex'
}
$PatchsetOutput = @(& node (Join-Path $ProjectRoot 'scripts\sdl3-patchset-digest.mjs'))
if ($LASTEXITCODE -ne 0) { throw "SDL3 patchset digest failed (exit $LASTEXITCODE)" }
$ActualPatchsetSha = ($PatchsetOutput -join "`n").Trim().ToLowerInvariant()
if ($ActualPatchsetSha -ne $ExpectedPatchsetSha) {
    throw "SDL3 patchset mismatch: actual=$ActualPatchsetSha expected=$ExpectedPatchsetSha"
}
$ArtifactRevision = "$Revision-amclps$ExpectedPatchsetSha"

if ([string]::IsNullOrWhiteSpace($SourceRepo)) {
    $Candidates = @(
        (Join-Path $ProjectRoot 'prebuilt\sdl3\sdl3_src'),
        (Join-Path $ProjectRoot '..\sdl3-ohos')
    )
    $SourceRepo = $Candidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ '.git') } | Select-Object -First 1
}
if ([string]::IsNullOrWhiteSpace($SourceRepo)) {
    throw 'SDL source repository not found; run bash setup_deps.sh or pass -SourceRepo'
}
$SourceRepo = [System.IO.Path]::GetFullPath($SourceRepo)

if ([string]::IsNullOrWhiteSpace($BuildRoot)) {
    $BuildRoot = Join-Path $AllowedOutputRoot ("run-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
}
$BuildRoot = Get-AmclWorkspacePath -Kind build -Id 'sdl3' -ProjectRoot $ProjectRoot -ExplicitPath $BuildRoot
$AllowedPrefix = $AllowedOutputRoot.TrimEnd('\') + '\'
if (-not $BuildRoot.StartsWith($AllowedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "BuildRoot must stay under $AllowedOutputRoot"
}
if (Test-Path -LiteralPath $BuildRoot) {
    throw "BuildRoot already exists; choose a fresh path: $BuildRoot"
}

Invoke-Checked 'git' @('-C', $SourceRepo, 'cat-file', '-e', "$Commit`^{commit}")
New-Item -ItemType Directory -Path $BuildRoot | Out-Null
$Worktree = Join-Path $BuildRoot 'source'
Invoke-Checked 'git' @('-C', $SourceRepo, 'worktree', 'add', '--detach', $Worktree, $Commit)

$Series = Join-Path $ProjectRoot 'prebuilt\sdl3\patches\series'
foreach ($raw in Get-Content -LiteralPath $Series) {
    $name = $raw.Trim()
    if ([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith('#')) { continue }
    $Patch = Join-Path (Split-Path -Parent $Series) $name
    if (-not (Test-Path -LiteralPath $Patch)) { throw "patch listed by series is missing: $Patch" }
    Invoke-Checked 'git' @('-C', $Worktree, 'apply', '--check', $Patch)
    Invoke-Checked 'git' @('-C', $Worktree, 'apply', $Patch)
}

# 在昂贵的 CMake/Ninja 编译之前验证已打补丁源码的窗口契约。
# preflight 检查补丁文件，这里再验证补丁真正落在精确锁定基线上之后的语义。
Invoke-Checked 'node' @((Join-Path $ProjectRoot 'scripts\check-desktop-runtime.mjs'), '--sdl-repo', $Worktree)
Invoke-Checked 'node' @(
    (Join-Path $ProjectRoot 'scripts\check-sdl3-multiwindow-contract.mjs'),
    '--repo', $Worktree
)
Invoke-Checked 'node' @(
    (Join-Path $ProjectRoot 'scripts\check-sdl3-video-callbacks.mjs'),
    '--repo', $Worktree
)
Invoke-Checked 'node' @(
    (Join-Path $ProjectRoot 'scripts\check-sdl3-presentation-contract.mjs'),
    '--repo', $Worktree
)
Invoke-Checked 'node' @(
    (Join-Path $ProjectRoot 'scripts\check-sdl3-text-session-contract.mjs')
)

$SdkRoots = @()
if (-not [string]::IsNullOrWhiteSpace($env:DEVECO_SDK_HOME)) { $SdkRoots += $env:DEVECO_SDK_HOME }
$LocalProperties = Join-Path $ProjectRoot 'local.properties'
if (Test-Path -LiteralPath $LocalProperties) {
    $SdkLine = Get-Content -LiteralPath $LocalProperties | Where-Object { $_ -match '^hwsdk\.dir=' } | Select-Object -First 1
    if ($SdkLine) { $SdkRoots += (($SdkLine -replace '^hwsdk\.dir=', '') -replace '\\\\', '\') }
}
$SdkCandidates = foreach ($SdkRoot in $SdkRoots) {
    $FullSdkRoot = [System.IO.Path]::GetFullPath($SdkRoot)
    $FullSdkRoot
    Join-Path $FullSdkRoot 'default\openharmony'
}
$Hwsdk = $SdkCandidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'native\llvm\bin\clang.exe') } | Select-Object -First 1
if (-not $Hwsdk) { throw 'HarmonyOS native SDK not found; set DEVECO_SDK_HOME or hwsdk.dir in local.properties' }

$Native = Join-Path $Hwsdk 'native'
$Cmake = Join-Path $Native 'build-tools\cmake\bin\cmake.exe'
$Ninja = Join-Path $Native 'build-tools\cmake\bin\ninja.exe'
$Toolchain = Join-Path $Native 'build\cmake\ohos.toolchain.cmake'
$Build = Join-Path $Worktree 'build-amcl'
$CmakeArgs = @(
    '-S', $Worktree,
    '-B', $Build,
    '-G', 'Ninja',
    "-DCMAKE_TOOLCHAIN_FILE:FILEPATH=$Toolchain",
    "-DCMAKE_MAKE_PROGRAM:FILEPATH=$Ninja",
    '-DCMAKE_BUILD_TYPE:STRING=Release',
    '-DSDL_AMCL_DESKTOP_HOST:BOOL=ON',
    '-DCMAKE_PLATFORM_NO_VERSIONED_SONAME:BOOL=ON',
    "-DSDL_REVISION:STRING=$ArtifactRevision"
)
Invoke-Checked $Cmake $CmakeArgs
Invoke-Checked $Ninja @('-C', $Build, 'SDL3-shared')

$Artifact = Join-Path $Build 'libSDL3.so'
if (-not (Test-Path -LiteralPath $Artifact)) { throw "SDL3 artifact missing: $Artifact" }
$ActualSize = (Get-Item -LiteralPath $Artifact).Length
$ActualSha = (Get-FileHash -LiteralPath $Artifact -Algorithm SHA256).Hash.ToLowerInvariant()
if ($ActualSize -ne $ExpectedSize -or $ActualSha -ne $ExpectedSha) {
    throw "SDL3 artifact mismatch: size=$ActualSize sha256=$ActualSha; expected size=$ExpectedSize sha256=$ExpectedSha"
}

Invoke-Checked 'node' @((Join-Path $ProjectRoot 'scripts\check-sdl3-abi.mjs'), '--repo', $Worktree, '--base', $AbiBase, '--head', $Commit)
Invoke-Checked 'node' @((Join-Path $ProjectRoot 'scripts\check-sdl3-layout.mjs'), '--repo', $Worktree, '--sdk', $Hwsdk)
Invoke-Checked 'node' @(
    (Join-Path $ProjectRoot 'scripts\check-sdl3-surface.mjs'),
    '--so', $Artifact,
    '--jar', (Join-Path $ProjectRoot 'prebuilt\lwjgl3\jars\lwjgl-sdl.jar')
)
Invoke-Checked 'node' @((Join-Path $ProjectRoot 'scripts\check-sdl3-launch-contract.mjs'))

if ($Deploy) {
    $Destination = Join-Path $ProjectRoot 'entry\libs\arm64-v8a\libSDL3.so'
    $TempDestination = "$Destination.amcl-new"
    Copy-Item -LiteralPath $Artifact -Destination $TempDestination -Force
    Move-Item -LiteralPath $TempDestination -Destination $Destination -Force
    Write-Host "[sdl3-build] deployed exact artifact -> $Destination"
}

Write-Host "[sdl3-build] PASS $ActualSize bytes $ActualSha"
Write-Host "[sdl3-build] artifact: $Artifact"
