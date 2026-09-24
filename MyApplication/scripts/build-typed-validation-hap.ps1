<#
build-typed-validation-hap.ps1 — 构建 typed 验证包（**不可分发**）

============================ 它是什么 ============================

一个把物理输入切到 typed 平面的 HAP，用来在真机上拿到计划 §88.6 那组可对比的数字。
与出货包的唯一差别是三个构建期宏（scripts/typed-validation-overrides.h）：
    AMCL_GLFW_TYPED_PHYSICAL_DEFAULT = 1   bit10，非证据位，不受 Gate 0 管
    AMCL_GLFW_RAW_RELATIVE_VERIFIED  = 1   bit13，让 POINTER_RELATIVE 过 ingress
    AMCL_GATE0_EVIDENCE_IDS          = "TYPED-VALIDATION-...-DO-NOT-SHIP"
bit14（native 绝对坐标）刻意保持 0。gate0-evidence.lock 全程 approved=false。

============================ 注入通道与它的三次否证 ============================

  ✗ 环境变量 CXXFLAGS —— ohos.toolchain.cmake:281 用**不带 FORCE** 的
    `set(CMAKE_CXX_FLAGS "" CACHE STRING ...)` 在 toolchain 阶段抢先把 cache 建成空，
    而那早于 CMake 从 CXXFLAGS 初始化 ⇒ env 被吃掉。**实测过一次完整构建**：
    七阶段全过、产物却与出货包等价，是本脚本的正向证据门把它拦下的。
  ✗ -DCMAKE_CXX_FLAGS=-include <path> —— 值里有空格，而 hvigor 把 arguments 按空白切成
    多个 cmake 参数 ⇒ 路径会变成独立参数（被当成源码目录）。
  ✓ -DCMAKE_PROJECT_INCLUDE=<inject.cmake> —— 单 token 无空格；CMake 在顶层 project()
    之后处理它，即 toolchain 之后、任何 target_compile_definitions 之前。
    宏级证据（clang -dM -E 展开）已验：三个宏正是上面那三个值。

⚠️ 这条 -D 必须写进 entry/build-profile.json5，而那是**出货配置**。留在里面就等于下一次
release 静默带上一个没有真机证据的能力位。因此：
  · 本脚本在 finally 里逐字节还原该文件，并在结束前重跑 check-gate0-evidence.mjs 证明它真的回去了；
  · check-gate0-evidence.mjs 已被加强为**主动猎捕**这条残留（任何 CMAKE_PROJECT_INCLUDE
    或 typed-validation 字样），默认一律硬失败，只有同时设了 AMCL_TYPED_VALIDATION=1
    的那一次构建放行。两个条件必须同时成立，缺省状态是出货安全的。

============================ ⚠️ 正向证据门 ============================

覆盖没生效时构建会**照常成功**，产出与出货包逐位等价的 HAP。那时拿两个包对比 AMCL_LOOK
会得到"完全一致"，然后被读成"体验一模一样" —— 结论方向正确、证据完全无效，
规范 §八 第五条推论 b 那个家族里最贵的一种。所以构建后必须证明覆盖真的生效，
两条独立判据，任一不满足即 exit 1：
  ① compile db 里 glfw_compat.cpp 的命令带着 -include，且排在基线 -D=0 之后；
  ② 构建出的 libglfw.so 字符串表真的有那个 evidence id（产物级 —— 编译命令对了
     不等于产物对了，这是 §86.1 刚付过学费的区别）。

============================ 用法 ============================

    powershell -ExecutionPolicy Bypass -File .\scripts\build-typed-validation-hap.ps1
#>

[CmdletBinding()]
param(
    # 刻意只允许 default / 两条 desktop：store 与 sideload 是签名分发轨，验证包绝不能走那两条。
    # desktop 使用 API26 编译工具链；API20/21 设备使用通用产品。
    [ValidateSet('default', 'desktop')]
    [string]$Product = 'default',

    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

$OverrideHeader = Join-Path $PSScriptRoot 'typed-validation-overrides.h'
$InjectCmake = Join-Path $PSScriptRoot 'typed-validation-inject.cmake'
foreach ($f in @($OverrideHeader, $InjectCmake)) {
    if (-not (Test-Path -LiteralPath $f)) { throw "missing validation asset: $f" }
}
# CMake 命令行里的反斜杠在 Ninja 那一层是转义符 ⇒ 一律正斜杠。
$InjectPath = ((Resolve-Path -LiteralPath $InjectCmake).Path) -replace '\\', '/'
if ($InjectPath -match '\s') {
    throw "inject path contains whitespace; hvigor would split it: $InjectPath"
}
$ExpectedEvidenceId = 'TYPED-VALIDATION-BUILD-NO-DEVICE-EVIDENCE-DO-NOT-SHIP'
$Profile = Join-Path $RepoRoot 'entry\build-profile.json5'
# arguments 是整串覆盖，所以按产品锚定当前**完整**值，追加而不是替换。desktop/legacy
# 的 target.config 与通用 release 可能有相同字符串，不能再用全文件 `.Replace()`。
$ReleaseArgs = '-DMC_OHOS_BUILD_TESTS=OFF -DAMCL_GLFW_TYPED_PHYSICAL_DEFAULT=ON ' +
    '-DAMCL_GLFW_RAW_RELATIVE_VERIFIED=ON'
$DesktopReleaseArgs = $ReleaseArgs + ' -DAMCL_GLFW_API26_RAW_MOUSE_MOTION=ON'
$SelectedReleaseArgs = if ($Product -eq 'desktop') { $DesktopReleaseArgs } else { $ReleaseArgs }
$AnchorLine = '"arguments": "' + $SelectedReleaseArgs + '"'
$PatchedLine = '"arguments": "' + $SelectedReleaseArgs +
    ' -DCMAKE_PROJECT_INCLUDE=' + $InjectPath + '"'

Write-Host ''
Write-Host '=== typed validation HAP ===' -ForegroundColor Yellow
Write-Host "  product:     $Product"
Write-Host "  inject:      $InjectPath"
Write-Host '  gate0 lock:  untouched'
Write-Host '  ⚠️ DO NOT DISTRIBUTE the resulting HAP.' -ForegroundColor Yellow

# ⚠️ 读写一律走 System.IO 的**字节**接口，不用 Get-Content/Set-Content。
# 实测代价：`Set-Content -Encoding utf8` 在 Windows PowerShell 5.1 上会写出 UTF-8 **BOM**，
# 而 build-profile.json5 原文没有 BOM ⇒ 还原之后 preflight 的 json5-parse 直接失败
# （`Unexpected token`）。更糟的是当时脚本里那句 `$After -ne $Original` 的字符串比对
# **没有抓到它** —— 这正是规范 §八 第五条推论 c 那条纪律：改了证据的采集方式必须重跑
# 负向验证，字符串相等不等于字节相等。
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function Read-TextExact([string]$path) {
    return [System.IO.File]::ReadAllText($path, $Utf8NoBom)
}
function Write-TextExact([string]$path, [string]$text) {
    [System.IO.File]::WriteAllText($path, $text, $Utf8NoBom)
}

if (-not $VerifyOnly) {
    $OriginalBytes = [System.IO.File]::ReadAllBytes($Profile)
    $Original = Read-TextExact $Profile
    $TargetsIndex = $Original.IndexOf('"targets": [', [StringComparison]::Ordinal)
    if ($TargetsIndex -lt 0) { throw 'entry build profile has no targets array' }
    $SearchStart = 0
    if ($Product -ne 'default') {
        $TargetMarker = '"name": "' + $Product + '",'
        $SearchStart = $Original.IndexOf(
            $TargetMarker, $TargetsIndex, [StringComparison]::Ordinal)
        if ($SearchStart -lt 0) { throw "target block not found for product=$Product" }
    }
    $AnchorIndex = $Original.IndexOf(
        $AnchorLine, $SearchStart, [StringComparison]::Ordinal)
    if ($AnchorIndex -lt 0) {
        throw "native arguments anchor not found in selected product block: $SelectedReleaseArgs"
    }
    $PatchedProfile = $Original.Substring(0, $AnchorIndex) + $PatchedLine +
        $Original.Substring($AnchorIndex + $AnchorLine.Length)
    $PreviousOptIn = $env:AMCL_TYPED_VALIDATION
    try {
        Write-TextExact $Profile $PatchedProfile
        $env:AMCL_TYPED_VALIDATION = '1'
        Write-Host ''
        Write-Host '  build-profile.json5 patched (restored in finally)'
        Write-Host '  AMCL_TYPED_VALIDATION=1 (opt-in for check-gate0-evidence.mjs)'
        Write-Host ''
        & (Join-Path $RepoRoot 'build-hap.ps1') -Product $Product -HapKind signed
        if ($LASTEXITCODE -ne 0) { throw "build-hap.ps1 failed (exit $LASTEXITCODE)" }
    }
    finally {
        Write-TextExact $Profile $Original
        $env:AMCL_TYPED_VALIDATION = $PreviousOptIn
        Write-Host ''
        # 按**字节**核对还原，不是按字符串（BOM / 行尾都只在字节层可见）。
        $AfterBytes = [System.IO.File]::ReadAllBytes($Profile)
        $Identical = $AfterBytes.Length -eq $OriginalBytes.Length
        if ($Identical) {
            for ($i = 0; $i -lt $AfterBytes.Length; $i++) {
                if ($AfterBytes[$i] -ne $OriginalBytes[$i]) { $Identical = $false; break }
            }
        }
        if ($Identical) {
            Write-Host '  build-profile.json5 restored byte-for-byte' -ForegroundColor Cyan
        } else {
            Write-Host '  ⚠️ RESTORE MISMATCH (byte level) — run: git checkout -- entry/build-profile.json5' -ForegroundColor Red
        }
        # 关门断言两条。第一条：撤销之后出货门禁必须在**没有** opt-in 的情况下自己判干净。
        & node (Join-Path $RepoRoot 'scripts\check-gate0-evidence.mjs') | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host '  ⚠️ check-gate0-evidence still fails after restore!' -ForegroundColor Red
        } else {
            Write-Host '  check-gate0-evidence: shipping config is clean again' -ForegroundColor Cyan
        }
        # 第二条：文件仍是合法 json5。它钉的是上面那次 BOM 事故 —— 字节比对已经覆盖，
        # 但这一条是从**消费者**角度独立确认，而消费者才是真正会坏的那一端。
        & node (Join-Path $RepoRoot 'scripts\preflight.mjs') '--only=json5-parse' | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host '  ⚠️ build-profile.json5 no longer parses as json5!' -ForegroundColor Red
        } else {
            Write-Host '  json5-parse: build-profile.json5 still parses' -ForegroundColor Cyan
        }
    }
}

Write-Host ''
Write-Host '=== positive-evidence gate: did the overrides actually land? ===' -ForegroundColor Cyan

# ---- 判据 ① 编译命令 ----
$Db = Join-Path $RepoRoot "entry\.cxx\$Product\$Product\release\arm64-v8a\compile_commands.json"
if (-not (Test-Path -LiteralPath $Db)) { throw "compile db not found: $Db" }
$Glfw = (Get-Content -LiteralPath $Db -Raw | ConvertFrom-Json) |
    Where-Object { $_.file -match 'glfw_compat\.cpp$' } | Select-Object -First 1
if (-not $Glfw) { throw 'glfw_compat.cpp is not in the compile db' }

$IncludeIndex = $Glfw.command.IndexOf('-include')
if ($IncludeIndex -lt 0) {
    Write-Host '  FAIL: the -include override is absent from the compile command' -ForegroundColor Red
    Write-Host '        ⇒ the injection channel did not work; this build equals shipping.'
    throw 'override not applied (compile command)'
}
$ZeroIndex = $Glfw.command.IndexOf('-DAMCL_GLFW_RAW_RELATIVE_VERIFIED=0')
if ($ZeroIndex -ge 0 -and $IncludeIndex -lt $ZeroIndex) {
    throw '-include precedes the baseline -D=0; the override would be undone'
}
Write-Host "  OK  compile command carries -include (char $IncludeIndex, baseline -D at $ZeroIndex)"

# ---- 判据 ② 产物 ----
$So = @(
    "entry\build\$Product\intermediates\cmake\$Product\obj\arm64-v8a\libglfw.so",
    "entry\build\$Product\intermediates\libs\$Product\arm64-v8a\libglfw.so"
) | ForEach-Object { Join-Path $RepoRoot $_ } | Where-Object { Test-Path -LiteralPath $_ } |
    Select-Object -First 1
if (-not $So) { throw 'no built libglfw.so found for artifact verification' }

$StringsTool = @(
    'D:/Huawei/command-line-tools/sdk/default/openharmony/native/llvm/bin/llvm-strings.exe',
    'D:/Huawei/command-line-tools/sdk/default/openharmony/native/llvm/bin/llvm-strings'
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
# fail-closed：找不到工具不等于没有问题（与 check-dso-undefined-symbols.mjs 同一条纪律）。
if (-not $StringsTool) { throw 'llvm-strings not found; refusing to report verified' }

if (-not (& $StringsTool $So | Select-String -SimpleMatch $ExpectedEvidenceId)) {
    Write-Host '  FAIL: libglfw.so does not carry the validation evidence id' -ForegroundColor Red
    throw 'override not applied (artifact)'
}
Write-Host "  OK  libglfw.so carries the evidence id"

# ---- 改名 + 搬出 entry/build ----
# ⚠️ 必须搬出去：`entry/build/**` 会被下一次 build-hap.ps1 的 [4/7] `hvigorw clean` 整片
# 清掉。实测丢过一次 —— 建完验证包再去建 legacy 基线包，回头验证包已经不在了。
# 双包对比恰恰要求两个包同时在手，所以落点必须是 clean 打不到的地方。
$OutDir = Join-Path $RepoRoot "entry\build\$Product\outputs\$Product"
$Source = Join-Path $OutDir "entry-$Product-signed.hap"
if (-not (Test-Path -LiteralPath $Source)) { throw "expected HAP not found: $Source" }
$KeepDir = Join-Path $RepoRoot 'validation-packages'
New-Item -ItemType Directory -Force -Path $KeepDir | Out-Null
$Target = Join-Path $KeepDir "entry-$Product-signed-TYPED-VALIDATION.hap"
Copy-Item -LiteralPath $Source -Destination $Target -Force
$Info = Get-Item -LiteralPath $Target

Write-Host ''
Write-Host 'TYPED VALIDATION HAP READY' -ForegroundColor Green
Write-Host "  HAP:      $Target"
Write-Host "  Size:     $([math]::Round($Info.Length / 1MB, 2)) MB"
Write-Host "  SHA-256:  $((Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash.ToLowerInvariant())"
Write-Host '  ⚠️ 只装自己的设备：它宣称了一个没有任何真机证据的能力位。' -ForegroundColor Yellow
