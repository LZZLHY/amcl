<#
为一次 Native/JDK 实验创建独立的 Docker 构建现场。
输入：工具链镜像、明确的 SDK sysroot、当前受控配方；输出：外部任务目录和具名 Linux 卷。
始终前台运行并保留本次容器/卷，不删除、启动或复用任何历史容器。
-PlanOnly 只校验并返回计划，不创建目录、卷或容器。
目录入口验证不等于证明各个历史配方已能完整复建线上包，来源缺口见 source-provenance.json。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ImageName,
    [Parameter(Mandatory)][string]$Sysroot,
    [ValidateSet('smoke', 'curl', 'gl4es', 'jdk8', 'jdk17', 'jdk21', 'jdk25', 'lwjgl', 'sdl3', 'shaderc')]
    [string]$Component = 'curl',
    [string[]]$RecipeArguments = @(),
    [switch]$PlanOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $ProjectRoot 'scripts\lib\workspace-paths.ps1')

function Resolve-BuilderInput([string]$Path, [string[]]$RequiredFiles) {
    # --mount 使用 CSV 语法；逗号/换行会改变参数边界，因此提前拒绝。
    if ($Path -match '[,\r\n]') { throw "Unsupported comma/newline in mount path: $Path" }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Input directory does not exist: $Path" }
    $Resolved = (Resolve-Path -LiteralPath $Path).ProviderPath
    foreach ($Relative in $RequiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $Resolved $Relative) -PathType Leaf)) { throw "Input is incomplete: $Resolved/$Relative" }
    }
    return $Resolved
}
function Invoke-BuilderDocker([string[]]$Arguments) {
    # 独立传递参数，禁止 shell 拼接；只读探测失败时不执行后续写操作。
    $Result = @(& docker @Arguments)
    if ($LASTEXITCODE -ne 0) { throw "Docker command failed ($LASTEXITCODE): $($Arguments -join ' ')" }
    return $Result
}
$RecipeNames = @{
    smoke = 'build_sysroot_probe.sh'
    curl = 'build_curl_ohos.sh'; gl4es = 'build_gl4es_ohos.sh'; jdk8 = 'build_jdk8_ohos.sh'
    jdk17 = 'build_jdk17_ohos.sh'; jdk21 = 'build_jdk21_ohos.sh'; jdk25 = 'build_jdk25_ohos.sh'
    lwjgl = 'build_lwjgl_ohos.sh'; sdl3 = 'build_sdl3_ohos.sh'; shaderc = 'build_shaderc_ohos.sh'
}
$Recipe = $RecipeNames[$Component]
$Recipes = Resolve-BuilderInput $PSScriptRoot @($Recipe, 'builder-entry.sh', 'setup_toolchain.sh')
$Prebuilt = Resolve-BuilderInput (Join-Path $ProjectRoot 'prebuilt') @('stubs/src/cxxabi_shim.cpp')
$SysrootChecks = @('usr/include/stdio.h', 'usr/include/aarch64-linux-ohos/bits/alltypes.h', 'usr/lib/aarch64-linux-ohos/libc.so')
$Sysroot = Resolve-BuilderInput $Sysroot $SysrootChecks
$Identity = foreach ($Relative in $SysrootChecks) {
    [ordered]@{ path = $Relative; sha256 = (Get-FileHash -LiteralPath (Join-Path $Sysroot $Relative) -Algorithm SHA256).Hash.ToLowerInvariant() }
}
# 将可变标签解引用为完整镜像 ID，后面的 run 只用此 ID。
$ImageId = ((Invoke-BuilderDocker @('image', 'inspect', '--format', '{{.Id}}', $ImageName)) -join '').Trim()
if ($ImageId -notmatch '^sha256:[0-9a-f]{64}$') { throw "Image is not an immutable Docker ID: $ImageId" }
$RunId = "docker-$Component-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$BuildRoot = Get-AmclWorkspacePath -Kind build -Id $RunId -ProjectRoot $ProjectRoot
if ($BuildRoot -match '[,\r\n]') { throw "Build path cannot be used as a Docker mount: $BuildRoot" }
$Out = Join-Path $BuildRoot 'out'
$Container = "amcl-$RunId"
$Volume = "$Container-work"
$Mounts = @(
    "type=bind,src=$Recipes,dst=/recipes,readonly",
    "type=bind,src=$Prebuilt,dst=/prebuilt,readonly",
    "type=bind,src=$Sysroot,dst=/ohos-sysroot,readonly",
    "type=bind,src=$Out,dst=/output",
    "type=volume,src=$Volume,dst=/build,volume-nocopy"
)
$RunArguments = @('run', '--name', $Container, '--label', 'amcl.role=managed-builder', '--label', "amcl.run=$RunId", '--workdir', '/build')
foreach ($Mount in $Mounts) { $RunArguments += @('--mount', $Mount) }
$RunArguments += @('--env', 'AMCL_SYSROOT_BASE=/ohos-sysroot', '--env', 'AMCL_BUILDER_MANAGED=1', '--env', "AMCL_BUILD_ID=$RunId")
$RunArguments += @('--entrypoint', '/bin/bash', $ImageId, '/recipes/builder-entry.sh', $Recipe)
$RunArguments += $RecipeArguments
$Plan = [ordered]@{
    schemaVersion = 1; runId = $RunId; state = 'planned'; createdAt = (Get-Date).ToString('o')
    projectRoot = $ProjectRoot; recipes = $Recipes; recipe = $Recipe
    recipeSha256 = (Get-FileHash -LiteralPath (Join-Path $Recipes $Recipe) -Algorithm SHA256).Hash.ToLowerInvariant()
    depsLockSha256 = (Get-FileHash -LiteralPath (Join-Path $ProjectRoot 'deps.lock') -Algorithm SHA256).Hash.ToLowerInvariant()
    imageRequested = $ImageName; imageId = $ImageId; sysroot = $Sysroot
    sysrootIdentityScope = 'three sentinel files, not a complete SDK digest'; sysrootSentinels = @($Identity)
    output = $Out; container = $Container; workVolume = $Volume
    lifecycle = 'Container and volume retained on success or failure; no automatic removal'
    dockerArguments = $RunArguments
}
if ($PlanOnly) { [pscustomobject]$Plan; return }
# 只有全部只读预检通过才创建输出，随机任务 ID 与已存在检查保证不覆盖旧现场。
if (Test-Path -LiteralPath $BuildRoot) { throw "Build directory already exists: $BuildRoot" }
New-Item -ItemType Directory -Path $Out -Force | Out-Null
$Manifest = Join-Path $BuildRoot 'build-manifest.json'
function Save-BuilderManifest { $Plan | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Manifest -Encoding utf8 }
Save-BuilderManifest
try {
    $Existing = Invoke-BuilderDocker @('volume', 'ls', '--filter', "name=^$Volume`$", '--format', '{{.Name}}')
    if ($Existing -contains $Volume) { throw "Work volume already exists: $Volume" }
    Invoke-BuilderDocker @('volume', 'create', '--label', 'amcl.role=managed-builder', '--label', "amcl.run=$RunId", $Volume) | Out-Null
    $Plan.state = 'running'; Save-BuilderManifest
    Write-Host "[builder] $Component -> $Out; manifest: $Manifest"
    # 不使用 -d/--rm；实时输出完整日志，成功与失败都保留本次现场供检查。
    & docker @RunArguments
    $Code = $LASTEXITCODE
    $Plan['exitCode'] = $Code
    if ($Code -ne 0) { throw "Builder exited with code $Code; retained container $Container and volume $Volume" }
    $Plan.state = 'completed'
} catch {
    $Plan.state = 'failed'; $Plan['error'] = $_.Exception.Message
    throw
} finally {
    $Plan['finishedAt'] = (Get-Date).ToString('o'); Save-BuilderManifest
}
