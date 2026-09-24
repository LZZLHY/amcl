# build-mobilegl.ps1 — 交叉编译 MobileGL → OHOS arm64 独立 DSO（libmobilegl.so）
#
# 治理：docs/adaptation/MOBILEGL_ADAPTATION_PLAN.md §3/§4.4（独立 DSO，不并入 libglfw）
# 施工：docs/refactor/渲染后端治理施工记录.md §S12 起
#
# 用法：
#   pwsh -File prebuilt/mobilegl/build-mobilegl.ps1              # configure + build + verify + dist
#   pwsh -File prebuilt/mobilegl/build-mobilegl.ps1 -Reconfigure # 先清 build 目录
#
# 关键取值（每一条都有出处，不要顺手改）：
#   OHOS_STL=c++_static   — 产物自包含，NEEDED 无 libc++_shared。依据：P1.5 判据「无 libc++」
#                           （方案 §5.2）+ CHANGELOG 1000271 的命名空间学费（NEEDED 在 ndk
#                           namespace 解析不到 HAP 私有库；libc++ 静态化整类消除）。
#                           MobileGL 对外表面是纯 C（gl*/egl*），无 C++ 类型跨界 ⇒ 静态安全。
#   MOBILEGL_ENABLE_LTO=OFF — 对齐上游默认；产物级 build-contract 门禁记录该模式。
#   CMAKE_BUILD_TYPE=Release — 上游按它切符号可见性（Release=hidden）。
#
# 前置（不满足会 fail-fast）：
#   * prebuilt/mobilegl/src 是 amcl/ohos 分支的 checkout（含 8 个已初始化 submodule）
#   * src/3rdparty/glslang/External/spirv-tools(@known_good) + external/spirv-headers(@known_good)
#   * PATH 上有 python 3.x（SPIRV-Tools 构建期生成表）

param(
    [switch]$Reconfigure,
    # 把 strip 后产物拷进 entry/libs/arm64-v8a/（已 gitignore），供本地装机跑
    # RenderPage 的 MobileGL 出帧探针（Phase 2a）。
    # ⛔ 发布 HAP 是否携带 libmobilegl.so 是未决产品决策 D3（deps.lock [mobilegl] 注释）：
    #    本开关只服务本地验证；发布构建前删掉该文件（gitignore 保证它进不了 git，
    #    但 hvigor 打包不看 git —— 文件在就会被打进去）。
    [switch]$DeployToLibs,
    [string]$BuildDir = ''
)

$ErrorActionPreference = 'Stop'

# ---------- [1/6] 路径解析 ----------
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # MyApplication/
$SrcDir   = Join-Path $PSScriptRoot 'src'
if ($BuildDir -eq '') {
    # 刻意放在 workspace 根的 .tmp-*（与 .tmp-sdl3 同模式）：构建产物不进仓，
    # 配方（本脚本）+ pin（deps.lock）才是可复现的真相。
    $BuildDir = Join-Path (Split-Path -Parent $RepoRoot) '.tmp-mobilegl-build\ohos-arm64'
}
$DistDir  = Join-Path $PSScriptRoot 'dist'

# ⚠️ 不盲信继承的 DEVECO_SDK_HOME（本机它指向不含 native 工具链的 shim 目录 ——
# 与 build-hap.ps1:50-59 拒绝继承过期值是同一个理由）。候选按「真的有 cmake」筛选。
$SdkCandidates = @(@(
    $env:DEVECO_SDK_HOME,
    'D:\Huawei\command-line-tools\sdk'
) | Where-Object { $_ -and (Test-Path (Join-Path $_ 'default\openharmony\native\build-tools\cmake\bin\cmake.exe')) })
if ($SdkCandidates.Count -eq 0) { throw '没有一个 SDK 候选路径含 native cmake（查 DEVECO_SDK_HOME）' }
$Sdk    = $SdkCandidates[0]
$Native = Join-Path $Sdk 'default\openharmony\native'
$Cmake  = Join-Path $Native 'build-tools\cmake\bin\cmake.exe'
$Ninja  = Join-Path $Native 'build-tools\cmake\bin\ninja.exe'
$Toolchain = Join-Path $Native 'build\cmake\ohos.toolchain.cmake'
$LlvmBin = Join-Path $Native 'llvm\bin'
foreach ($p in @($Cmake, $Ninja, $Toolchain, $SrcDir)) {
    if (-not (Test-Path $p)) { throw "前置缺失: $p" }
}

# ---------- [2/6] 前置自检（fail-fast 优于 configure 半途死） ----------
$SpirvTools   = Join-Path $SrcDir '3rdparty\glslang\External\spirv-tools'
$SpirvHeaders = Join-Path $SpirvTools 'external\spirv-headers'
foreach ($p in @($SpirvTools, $SpirvHeaders)) {
    if (-not (Test-Path (Join-Path $p 'CMakeLists.txt'))) {
        throw "glslang External 依赖缺失: $p （按 src/3rdparty/glslang/known_good.json 的 pin 克隆）"
    }
}
$python = (Get-Command python -ErrorAction SilentlyContinue)
if (-not $python) { throw 'PATH 上无 python（SPIRV-Tools 构建期生成表需要）' }

# ---------- [3/6] configure ----------
& node (Join-Path $RepoRoot 'scripts/check-mobilegl-pin.mjs') --offline
if ($LASTEXITCODE -ne 0) { throw 'MobileGL source pin check failed' }
$BuildDir = [IO.Path]::GetFullPath($BuildDir)
$MobileglWorkspace = [IO.Path]::GetFullPath((Split-Path -Parent $RepoRoot)).TrimEnd('\') + '\'
if ($Reconfigure -and (Test-Path -LiteralPath $BuildDir)) {
    if (-not $BuildDir.StartsWith($MobileglWorkspace, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a build directory outside workspace: $BuildDir"
    }
    Remove-Item -LiteralPath $BuildDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null

Write-Host "== [3/6] cmake configure -> $BuildDir" -ForegroundColor Cyan
& $Cmake -G Ninja -S $SrcDir -B $BuildDir `
    "-DCMAKE_TOOLCHAIN_FILE=$Toolchain" `
    '-DOHOS_ARCH=arm64-v8a' `
    '-DOHOS_STL=c++_static' `
    '-DCMAKE_BUILD_TYPE=Release' `
    "-DCMAKE_MAKE_PROGRAM=$Ninja" `
    '-DMOBILEGL_ENABLE_LTO=OFF'
if ($LASTEXITCODE -ne 0) { throw "cmake configure 失败 (EXIT=$LASTEXITCODE)" }

# ---------- [4/6] build ----------
Write-Host '== [4/6] ninja MobileGL' -ForegroundColor Cyan
& $Ninja -C $BuildDir MobileGL
if ($LASTEXITCODE -ne 0) { throw "ninja 失败 (EXIT=$LASTEXITCODE)" }

$Built = Join-Path $BuildDir 'libMobileGL.so'
if (-not (Test-Path $Built)) { throw "产物不存在: $Built" }

# ---------- [5/6] 产物验收（P1.5 判据，方案 §5.2） ----------
Write-Host '== [5/6] readelf 验收' -ForegroundColor Cyan
$readelf = Join-Path $LlvmBin 'llvm-readelf.exe'
$dynamic = & $readelf -d $Built
if ($LASTEXITCODE -ne 0) { throw 'llvm-readelf failed' }
$needed = $dynamic -match 'NEEDED'
if (-not $needed) { throw 'MobileGL dynamic dependencies missing' }
$needed | ForEach-Object { Write-Host "  $_" }
# 判据 1：无 libc++（c++_static 的直接后果）
if ($needed -match 'libc\+\+') { throw 'FAIL: NEEDED 含 libc++ —— OHOS_STL 没有生效' }
# 判据 2：无意外 NEEDED。白名单 = musl + 系统图形栈 + hilog（Phase 2a 的日志 sink，
# 所有 OHOS 设备系统自带）。新增依赖必须在这里显式放行 —— 2026-08-27 hilog 接入时
# 本判据先红后放行，证明它真的在拦。
$unexpected = @()
foreach ($line in $needed) {
    if ($line -match '\[(.+)\]') {
        $so = $Matches[1]
        if ($so -notin @('libc.so', 'libvulkan.so', 'libhilog_ndk.z.so',
                         'libdl.so', 'libm.so', 'libpthread.so', 'libunwind.so',
                         'libnative_image.so', 'libnative_window.so')) {
            $unexpected += $so
        }
    }
}
if ($unexpected.Count -gt 0) { throw "FAIL: 意外 NEEDED: $($unexpected -join ', ')" }
$relocations = & $readelf -r $Built
if ($LASTEXITCODE -ne 0) { throw 'llvm-readelf relocation audit failed' }
$preemptibleGl = $relocations -match 'R_AARCH64_(GLOB_DAT|JUMP_SLOT|ABS64)\s+[0-9a-f]+\s+(egl|gl)[A-Z]'
if ($preemptibleGl) { throw "MobileGL has preemptible GL/EGL function references: $($preemptibleGl -join ', ')" }

# ---------- [6/6] dist（unstripped + stripped 双份，供 build-contract 门禁对账） ----------
Write-Host '== [6/6] dist' -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
$strip = Join-Path $LlvmBin 'llvm-strip.exe'
Copy-Item $Built (Join-Path $DistDir 'libmobilegl.unstripped.so') -Force
& $strip --strip-debug --strip-unneeded -o (Join-Path $DistDir 'libmobilegl.so') $Built
if ($LASTEXITCODE -ne 0) { throw "llvm-strip 失败 (EXIT=$LASTEXITCODE)" }

$rows = foreach ($f in @('libmobilegl.unstripped.so', 'libmobilegl.so')) {
    $fp = Join-Path $DistDir $f
    [pscustomobject]@{
        file   = $f
        bytes  = (Get-Item $fp).Length
        sha256 = (Get-FileHash $fp -Algorithm SHA256).Hash.ToLower()
    }
}
$rows | Format-Table -AutoSize | Out-String | Write-Host

& node (Join-Path $RepoRoot 'scripts/check-mobilegl-build-contract.mjs') --record-build --build-dir $BuildDir
if ($LASTEXITCODE -ne 0) { throw 'MobileGL build provenance failed' }
if ($DeployToLibs) {
    & node (Join-Path $RepoRoot 'scripts/check-mobilegl-build-contract.mjs') --prepare --enabled
    if ($LASTEXITCODE -ne 0) { throw 'MobileGL deployment contract failed (review lock fingerprints after rebuild)' }
}

Write-Host 'BUILD_MOBILEGL_OK' -ForegroundColor Green
