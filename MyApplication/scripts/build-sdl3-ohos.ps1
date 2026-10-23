param(
    [string]$SourceRepo = "",
    [string]$BuildRoot = "",
    [switch]$Deploy,
    [switch]$Candidate
)

# 候选不具备工程消费/锁定交付资格。必须在路径解析、helper、目录或工具调用前拒绝，
# 不能先运行部分构建或部署，再用最终标签解释成“只是候选”。
if ($Candidate -and $Deploy) { throw 'Candidate cannot be combined with Deploy; candidate artifacts must remain outside project libs' }
$InvocationStartedAt = (Get-Date).ToString('o')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir '..'))
$LockPath = Join-Path $ProjectRoot 'deps.lock'
# SDL 的锁定输入仍在工程中；打补丁的工作树和编译结果必须留在工作区统一构建目录。
# helper 根据当前 checkout 生成隔离路径，避免不同工作树共享同一 CMake 缓存。
. (Join-Path $ScriptDir 'lib\workspace-paths.ps1')
$AllowedOutputRoot = Get-AmclWorkspacePath -Kind build -Id 'sdl3' -ProjectRoot $ProjectRoot
$CandidateReceipt = $null
$CandidateReceiptPath = ''
$OutputReserved = $false
$Phase = 'initialization'

function File-Identity([string]$Path) {
    # 只公布路径、大小和摘要，不把工具/输入正文复制进普通日志。缺失对象由调用方明确拒绝。
    $Item = Get-Item -LiteralPath $Path
    if ($Item.PSIsContainer) { throw "Expected file: $Path" }
    return [ordered]@{ path = $Item.FullName; size = $Item.Length; sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
}

function Text-Sha256([string]$Text) {
    # ordered输入清单的独立摘要固定UTF-8字节；不依赖PowerShell默认编码或绝对仓库位置。
    $Hasher = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($Hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $Hasher.Dispose() }
}

function Write-CandidateReceipt {
    if (-not $Candidate -or $null -eq $CandidateReceipt -or [string]::IsNullOrWhiteSpace($CandidateReceiptPath)) { return }
    [System.IO.File]::WriteAllText($CandidateReceiptPath, ($CandidateReceipt | ConvertTo-Json -Depth 15) + "`n", [Text.UTF8Encoding]::new($false))
}

function Resolve-BuildOutput {
    # 仅接受helper核验过的仓外统一build根下fresh路径，不覆盖旧构建/收据，也不写工程libs。
    if ([string]::IsNullOrWhiteSpace($script:BuildRoot)) {
        $script:BuildRoot = Join-Path $AllowedOutputRoot ("run-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    }
    $script:BuildRoot = Get-AmclWorkspacePath -Kind build -Id 'sdl3' -ProjectRoot $ProjectRoot -ExplicitPath $script:BuildRoot
    $AllowedPrefix = $AllowedOutputRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $script:BuildRoot.StartsWith($AllowedPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "BuildRoot must stay under $AllowedOutputRoot" }
    if (Test-Path -LiteralPath $script:BuildRoot) { throw "BuildRoot already exists; choose a fresh path: $script:BuildRoot" }
}

function Resolve-NativeSdk {
    # SDK仍来自显式环境/现有local.properties，不切换用户SDK或伪造编译器身份。
    $SdkRoots = @()
    if (-not [string]::IsNullOrWhiteSpace($env:DEVECO_SDK_HOME)) { $SdkRoots += $env:DEVECO_SDK_HOME }
    $LocalProperties = Join-Path $ProjectRoot 'local.properties'
    if (Test-Path -LiteralPath $LocalProperties) {
        $SdkLine = Get-Content -LiteralPath $LocalProperties | Where-Object { $_ -match '^hwsdk\.dir=' } | Select-Object -First 1
        if ($SdkLine) { $SdkRoots += (($SdkLine -replace '^hwsdk\.dir=', '') -replace '\\\\', '\') }
    }
    $SdkCandidates = foreach ($SdkRoot in $SdkRoots) {
        $FullSdkRoot = [IO.Path]::GetFullPath($SdkRoot)
        $FullSdkRoot
        Join-Path $FullSdkRoot 'default\openharmony'
    }
    $Resolved = $SdkCandidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'native\llvm\bin\clang.exe') } | Select-Object -First 1
    if (-not $Resolved) { throw 'HarmonyOS native SDK not found; set DEVECO_SDK_HOME or hwsdk.dir in local.properties' }
    return $Resolved
}

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

function Invoke-Checked([string]$File, [string[]]$Arguments, [string]$WorkingDirectory = $ProjectRoot, [switch]$Capture) {
    # 候选每条命令记录实际可执行文件和参数、目录、实取起止与返回码；工具异常也保留失败。
    $Entry = $null
    $Executable = $File
    if ($Candidate) {
        $Executable = (Get-Command $File -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $Entry = [ordered]@{ phase = $script:Phase; tool = (File-Identity $Executable); arguments = @($Arguments); workingDirectory = $WorkingDirectory; startedAt = (Get-Date).ToString('o'); finishedAt = $null; exitCode = $null }
        $script:CandidateReceipt.commands += $Entry
    }
    Push-Location $WorkingDirectory
    try {
        if ($Capture) { $Captured = @(& $Executable @Arguments) }
        else { & $Executable @Arguments }
        $ExitCode = $LASTEXITCODE
        if ($null -ne $Entry) { $Entry.exitCode = $ExitCode }
        if ($ExitCode -ne 0) { throw "command failed ($ExitCode): $Executable $($Arguments -join ' ')" }
        if ($Capture) { return $Captured }
    } finally {
        Pop-Location
        if ($null -ne $Entry) { $Entry.finishedAt = (Get-Date).ToString('o') }
        Write-CandidateReceipt
    }
}

try {
if ($Candidate) {
    # 候选先预约自己的fresh目录，便于即使pin/SDK/源码准备失败也保留明确Failed收据。
    # 不合法或已有BuildRoot在创建前拒绝，因此没有覆盖其它任务收据的兜底写路径。
    Resolve-BuildOutput
    New-Item -ItemType Directory -Path $BuildRoot | Out-Null
    $OutputReserved = $true
    $CandidateReceiptPath = Join-Path $BuildRoot 'candidate-receipt.json'
    $CandidateReceipt = [ordered]@{
        schemaVersion = 1; mode = 'candidate'; state = 'Running'; lockedArtifactApproved = $false
        startedAt = $InvocationStartedAt; finishedAt = $null; timezone = 'Asia/Shanghai'
        script = (File-Identity $MyInvocation.MyCommand.Path)
        invocation = [ordered]@{ sourceRepo = $SourceRepo; buildRoot = $BuildRoot; candidate = $true; deploy = $false }
        source = $null; patchset = $null; sdk = $null; artifact = $null; lockedExpected = $null
        commands = @(); error = $null
    }
    Write-CandidateReceipt
}

$Phase = 'locked-source-inputs'
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
$DigestScript = Join-Path $ProjectRoot 'scripts\sdl3-patchset-digest.mjs'
$Phase = 'ordered-patch-inputs'
$PatchsetReport = ((Invoke-Checked 'node' @($DigestScript, '--json') -Capture) -join "`n") | ConvertFrom-Json
$ActualPatchsetSha = ([string]$PatchsetReport.sha256).ToLowerInvariant()
if ($ActualPatchsetSha -notmatch '^[0-9a-f]{64}$') { throw 'SDL3 actual patchset digest is invalid' }
if (-not $Candidate -and $ActualPatchsetSha -ne $ExpectedPatchsetSha) {
    throw "SDL3 patchset mismatch: actual=$ActualPatchsetSha expected=$ExpectedPatchsetSha"
}
$ArtifactRevision = "$Revision-amclps$ActualPatchsetSha"
$Series = Join-Path $ProjectRoot 'prebuilt\sdl3\patches\series'
if ($Candidate) {
    $PatchInputs = @(); $Ordinal = 0
    foreach ($Name in $PatchsetReport.names) {
        $Identity = File-Identity (Join-Path (Split-Path -Parent $Series) $Name)
        $PatchInputs += [ordered]@{ ordinal = (++$Ordinal); name = [string]$Name; size = $Identity.size; sha256 = $Identity.sha256; path = $Identity.path }
    }
    $StableInputs = @($PatchInputs | ForEach-Object { [ordered]@{ ordinal = $_.ordinal; name = $_.name; size = $_.size; sha256 = $_.sha256 } })
    $CandidateReceipt.patchset = [ordered]@{ actualSha256 = $ActualPatchsetSha; lockedSha256 = $ExpectedPatchsetSha; artifactRevision = $ArtifactRevision; series = (File-Identity $Series); orderedInputs = $PatchInputs; inputListSha256 = (Text-Sha256 ($StableInputs | ConvertTo-Json -Depth 5 -Compress)) }
    $CandidateReceipt.source = [ordered]@{ repository = $SourceRepo; pin = $Commit; abiBase = $AbiBase; worktree = $null; worktreeHead = $null }
    $CandidateReceipt.lockedExpected = [ordered]@{ size = $ExpectedSize; sha256 = $ExpectedSha; patchsetSha256 = $ExpectedPatchsetSha; lockFile = (File-Identity $LockPath) }
    Write-CandidateReceipt
}

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

if (-not $OutputReserved) { Resolve-BuildOutput }

$Phase = 'source-pin'
if ($Candidate) { $CandidateReceipt.source.repository = $SourceRepo }
Invoke-Checked 'git' @('-C', $SourceRepo, 'cat-file', '-e', "$Commit`^{commit}")
if ($Candidate) { Invoke-Checked 'git' @('-C', $SourceRepo, 'cat-file', '-e', "$AbiBase`^{commit}") }
if (-not $OutputReserved) { New-Item -ItemType Directory -Path $BuildRoot | Out-Null }
$Worktree = Join-Path $BuildRoot 'source'
Invoke-Checked 'git' @('-C', $SourceRepo, 'worktree', 'add', '--detach', $Worktree, $Commit)
if ($Candidate) {
    $Head = ((Invoke-Checked 'git' @('-C', $Worktree, 'rev-parse', 'HEAD') -Capture) -join "`n").Trim()
    if ($Head -ne $Commit) { throw "SDL3 candidate worktree HEAD differs from precise source pin: $Head" }
    $CandidateReceipt.source.worktree = $Worktree; $CandidateReceipt.source.worktreeHead = $Head
}

$Phase = 'complete-ordered-patch-apply'
foreach ($name in $PatchsetReport.names) {
    $Patch = Join-Path (Split-Path -Parent $Series) $name
    if (-not (Test-Path -LiteralPath $Patch)) { throw "patch listed by series is missing: $Patch" }
    Invoke-Checked 'git' @('-C', $Worktree, 'apply', '--check', $Patch)
    Invoke-Checked 'git' @('-C', $Worktree, 'apply', $Patch)
}

# 在昂贵的 CMake/Ninja 编译之前验证已打补丁源码的窗口契约。
# preflight 检查补丁文件，这里再验证补丁真正落在精确锁定基线上之后的语义。
$Phase = 'patched-source-gates'
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

$Phase = 'sdk-toolchain'
$Hwsdk = Resolve-NativeSdk

$Native = Join-Path $Hwsdk 'native'
$Cmake = Join-Path $Native 'build-tools\cmake\bin\cmake.exe'
$Ninja = Join-Path $Native 'build-tools\cmake\bin\ninja.exe'
$Toolchain = Join-Path $Native 'build\cmake\ohos.toolchain.cmake'
if ($Candidate) {
    $SdkTools = [ordered]@{}
    foreach ($Tool in @('llvm\bin\clang.exe', 'llvm\bin\clang++.exe', 'llvm\bin\ld.lld.exe', 'llvm\bin\llvm-ar.exe', 'llvm\bin\llvm-strip.exe', 'build-tools\cmake\bin\cmake.exe', 'build-tools\cmake\bin\ninja.exe', 'build\cmake\ohos.toolchain.cmake')) {
        $SdkTools[$Tool] = File-Identity (Join-Path $Native $Tool)
    }
    $CandidateReceipt.sdk = [ordered]@{ root = $Hwsdk; tools = $SdkTools }
    Write-CandidateReceipt
}
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
$Phase = 'sdk-cmake-configure'
Invoke-Checked $Cmake $CmakeArgs
if ($Candidate) {
    # 记录CMake真正选中的编译器，而不把“SDK中存在clang”冒充“本产物用了它”。
    # OHOS toolchain把编译器设为普通变量，CMakeCache可不包含这两个字段；生成的
    # CMakeC/CXXCompiler.cmake是此次configure确认的语言配置。只读取数据，不执行它。
    # 同一语言必须恰有一个配置和一个实际路径，旧版/重复目录或空字段都不能假确认。
    $CachePath = Join-Path $Build 'CMakeCache.txt'
    $EffectiveTools = [ordered]@{}
    $CompilerConfigurations = [ordered]@{}
    foreach ($Language in @('C', 'CXX')) {
        $CompilerFiles = @(Get-ChildItem -Path (Join-Path $Build "CMakeFiles\*\CMake${Language}Compiler.cmake") -File)
        if ($CompilerFiles.Count -ne 1) { throw "Candidate requires one generated $Language compiler configuration" }
        $Key = "CMAKE_${Language}_COMPILER"
        $CompilerMatches = @([regex]::Matches([IO.File]::ReadAllText($CompilerFiles[0].FullName),
            '(?m)^set\(' + [regex]::Escape($Key) + '\s+"([^"\r\n]+)"\)\s*$'))
        if ($CompilerMatches.Count -ne 1) { throw "Candidate generated $Language compiler path is missing or ambiguous" }
        $EffectiveTools[$Key] = File-Identity $CompilerMatches[0].Groups[1].Value
        $CompilerConfigurations[$Language] = File-Identity $CompilerFiles[0].FullName
    }
    foreach ($Key in @('CMAKE_LINKER', 'CMAKE_AR', 'CMAKE_RANLIB')) {
        $CacheLine = Get-Content -LiteralPath $CachePath | Where-Object { $_ -match ('^' + [regex]::Escape($Key) + ':(?:FILEPATH|STRING)=') } | Select-Object -First 1
        if ($CacheLine) { $EffectiveTools[$Key] = File-Identity ($CacheLine -replace '^[^=]+=','') }
    }
    if (-not $EffectiveTools.Contains('CMAKE_C_COMPILER') -or -not $EffectiveTools.Contains('CMAKE_CXX_COMPILER')) { throw 'Candidate CMake cache does not prove selected C/C++ compilers' }
    $CandidateReceipt.sdk.effectiveTools = $EffectiveTools
    $CandidateReceipt.sdk.compilerConfigurations = $CompilerConfigurations
    $CandidateReceipt.sdk.cmakeCache = File-Identity $CachePath
    Write-CandidateReceipt
}
$Phase = 'sdk-ninja-build'
Invoke-Checked $Ninja @('-C', $Build, 'SDL3-shared')

$Artifact = Join-Path $Build 'libSDL3.so'
if (-not (Test-Path -LiteralPath $Artifact)) { throw "SDL3 artifact missing: $Artifact" }
$ActualSize = (Get-Item -LiteralPath $Artifact).Length
$ActualSha = (Get-FileHash -LiteralPath $Artifact -Algorithm SHA256).Hash.ToLowerInvariant()
if (-not $Candidate -and ($ActualSize -ne $ExpectedSize -or $ActualSha -ne $ExpectedSha)) {
    throw "SDL3 artifact mismatch: size=$ActualSize sha256=$ActualSha; expected size=$ExpectedSize sha256=$ExpectedSha"
}
if ($Candidate) {
    $CandidateReceipt.artifact = [ordered]@{ path = $Artifact; size = $ActualSize; sha256 = $ActualSha; revision = $ArtifactRevision; patchsetMarkerVerified = $false }
    # 不只相信CMake参数：用同一个生产marker检查器核实际ELF确含当前完整ordered recipe身份。
    $Phase = 'candidate-embedded-revision'
    $MarkerCheck = "import fs from 'node:fs';import {pathToFileURL} from 'node:url';const m=await import(pathToFileURL(process.argv[1]).href);if(!m.artifactEmbedsSdl3Patchset(fs.readFileSync(process.argv[2]),process.argv[3]))throw Error('candidate actual patchset marker missing');"
    Invoke-Checked 'node' @('--input-type=module', '-e', $MarkerCheck, $DigestScript, $Artifact, $ActualPatchsetSha)
    $CandidateReceipt.artifact.patchsetMarkerVerified = $true
}

$Phase = 'final-abi-layout-surface-launch-gates'
Invoke-Checked 'node' @((Join-Path $ProjectRoot 'scripts\check-sdl3-abi.mjs'), '--repo', $Worktree, '--base', $AbiBase, '--head', $Commit)
Invoke-Checked 'node' @((Join-Path $ProjectRoot 'scripts\check-sdl3-layout.mjs'), '--repo', $Worktree, '--sdk', $Hwsdk)
Invoke-Checked 'node' @(
    (Join-Path $ProjectRoot 'scripts\check-sdl3-surface.mjs'),
    '--so', $Artifact,
    '--jar', (Join-Path $ProjectRoot 'prebuilt\lwjgl3\jars\lwjgl-sdl.jar')
)
Invoke-Checked 'node' @((Join-Path $ProjectRoot 'scripts\check-sdl3-launch-contract.mjs'))

if ($Candidate) {
    # 成功前再核当前实际输入，发现构建中漂移则失败，不给新旧recipe混合产物签发候选完成。
    $Phase = 'candidate-input-consistency'
    $FinalPatchset = ((Invoke-Checked 'node' @($DigestScript, '--json') -Capture) -join "`n") | ConvertFrom-Json
    if ($FinalPatchset.sha256 -ne $ActualPatchsetSha) { throw 'SDL3 patch inputs changed during candidate build' }
    foreach ($Input in $CandidateReceipt.patchset.orderedInputs) {
        $Now = File-Identity $Input.path
        if ($Now.sha256 -ne $Input.sha256 -or $Now.size -ne $Input.size) { throw "SDL3 patch input changed during candidate build: $($Input.name)" }
    }
    $FinalArtifact = File-Identity $Artifact
    if ($FinalArtifact.sha256 -ne $ActualSha -or $FinalArtifact.size -ne $ActualSize) { throw 'SDL3 candidate artifact changed during verification' }
    $CandidateReceipt.state = 'VerifiedCandidate'; $CandidateReceipt.finishedAt = (Get-Date).ToString('o')
    Write-CandidateReceipt
    Write-Host "[sdl3-build] CANDIDATE VERIFIED $ActualSize bytes $ActualSha (not a locked delivery artifact)"
    Write-Host "[sdl3-build] candidate receipt: $CandidateReceiptPath"
}

if ($Deploy) {
    $Destination = Join-Path $ProjectRoot 'entry\libs\arm64-v8a\libSDL3.so'
    $TempDestination = "$Destination.amcl-new"
    Copy-Item -LiteralPath $Artifact -Destination $TempDestination -Force
    Move-Item -LiteralPath $TempDestination -Destination $Destination -Force
    Write-Host "[sdl3-build] deployed exact artifact -> $Destination"
}

if (-not $Candidate) { Write-Host "[sdl3-build] PASS $ActualSize bytes $ActualSha" }
Write-Host "[sdl3-build] artifact: $Artifact"
} catch {
    if ($Candidate -and $null -ne $CandidateReceipt) {
        $CandidateReceipt.state = 'Failed'; $CandidateReceipt.finishedAt = (Get-Date).ToString('o')
        $CandidateReceipt.error = [ordered]@{ phase = $Phase; message = $_.Exception.Message; type = $_.Exception.GetType().FullName }
        Write-CandidateReceipt
    }
    throw
}
