# build-hap.ps1 — AMCL HAP 的唯一正式构建入口
#
# 它在耗时构建前验证 MG source pin/snapshot/docs 引用，清掉可再生 native
# cache，按产品选择 Debug/Release 变体，并对刚生成的 signed/unsigned HAP 写入
# 可复验 provenance。日常构建允许 superproject dirty（provenance 会列出状态）；
# CI/发布必须加 -Release，此时 dirty superproject 会 fail closed。
#
# 用法：
#   .\build-hap.ps1                         # default/default signed, 日常证据
#   .\build-hap.ps1 -HapKind unsigned       # 明确审计 unsigned 出货包
#   .\build-hap.ps1 -AllowDirtyMobileGlues    # 仅本地诊断；内容哈希写入 SO/provenance
#   .\build-hap.ps1 -Product store -Release # 正式、clean 的 store Release

[CmdletBinding()]
param(
    [ValidateSet('default', 'desktop', 'store', 'sideload')]
    [string]$Product = 'default',

    [ValidateSet('signed', 'unsigned')]
    [string]$HapKind = 'signed',

    [ValidateSet('arm64-v8a')]
    [string]$Abi = 'arm64-v8a',

    [ValidateSet('auto', 'debug', 'release')]
    [string]$BuildMode = 'auto',

    [ValidateSet('none', 'tests', 'input-trace', 'mg-frames', 'mg-gl', 'mg-exhaustive', 'mg-upload', 'stack', 'gate0', 'vulkan-trace')]
    [string[]]$Diagnostics = @('none'),

    [switch]$Release,

    [switch]$AllowDirtyMobileGlues,
    [switch]$NativeGlValidation,

    [switch]$IncludeMobileGL
)

if ($NativeGlValidation -and ($Product -ne 'desktop' -or $Release)) {
    throw 'NativeGlValidation requires desktop and cannot be used for publication'
}
$env:AMCL_DESKTOP_NATIVE_GL_VALIDATE = if ($NativeGlValidation) { '1' } else { '0' }

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ProjectRoot
$Target = $Product

if ($IncludeMobileGL -and ($Release -or $Product -ne 'default')) {
    throw '-IncludeMobileGL is default-only and cannot be combined with -Release.'
}
if ($Release) {
    if ($BuildMode -eq 'debug' -or @($Diagnostics | Where-Object { $_ -ne 'none' }).Count -gt 0) {
        throw '-Release requires release mode with all optional diagnostics disabled.'
    }
    $BuildMode = 'release'
}
if ($IncludeMobileGL) { $Diagnostics += 'tests' }
$env:AMCL_DIAGNOSTICS = $Diagnostics -join ','
$DiagnosticJson = & node "$ProjectRoot\scripts\diagnostic-profile.mjs" --product $Product --mode $BuildMode
if ($LASTEXITCODE -ne 0) { throw 'Invalid product diagnostic configuration' }
$DiagnosticBuild = $DiagnosticJson | ConvertFrom-Json
$BuildMode = $DiagnosticBuild.mode
$UseDevelopmentAudit = $BuildMode -ne 'release' -or $DiagnosticBuild.diagnostics.Count -gt 0

$env:AMCL_MOBILEGL_VALIDATION = if ($IncludeMobileGL) { '1' } else { '0' }
& node "$ProjectRoot\scripts\check-mobilegl-build-contract.mjs" --prepare --product $Product
if ($LASTEXITCODE -ne 0) { throw 'MobileGL packaging preparation failed' }

if ($Release -and $AllowDirtyMobileGlues) {
    throw '-AllowDirtyMobileGlues is diagnostic-only and cannot be combined with -Release.'
}
if ($Release) {
    $ReleaseStatus = @(& git -C $ProjectRoot status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw "git status failed (exit $LASTEXITCODE)" }
    if ($ReleaseStatus.Count -gt 0) {
        Write-Host 'Release checkout is not reproducible; dirty/untracked paths:' -ForegroundColor Red
        $ReleaseStatus | Select-Object -First 25 | ForEach-Object { Write-Host "  $_" }
        if ($ReleaseStatus.Count -gt 25) {
            Write-Host "  ... $($ReleaseStatus.Count - 25) more paths"
        }
        throw "-Release requires one clean immutable checkout; found $($ReleaseStatus.Count) status entries"
    }
}

$FormalDesktop = $Product -eq 'desktop'
$ProductHvigorOverride = if ($FormalDesktop) {
    $env:AMCL_HVIGORW_DESKTOP
} else {
    $env:AMCL_HVIGORW_MOBILE
}
$ProductHvigorCandidates = if ($Product -eq 'desktop') {
    # formal API26 needs the matching 6.26.x plugin. A still-installed DevEco
    # 6.24.x rejects the valid "26.0.0" SDK string before compilation.
    @(
        'D:\Huawei\command-line-tools\bin\hvigorw.bat',
        'D:\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat'
    )
} else {
    @(
        'D:\Huawei\command-line-tools\bin\hvigorw.bat',
        'D:\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat'
    )
}
$HvigorCandidates = @($ProductHvigorOverride, $env:AMCL_HVIGORW) + $ProductHvigorCandidates |
    Where-Object { $_ -and (Test-Path -LiteralPath $_) }
if (-not $HvigorCandidates) {
    throw 'No hvigorw found. Set AMCL_HVIGORW to the DevEco hvigorw.bat path.'
}
$Hvigorw = [System.IO.Path]::GetFullPath($HvigorCandidates[0])

$ProductSdkOverride = if ($FormalDesktop) {
    $env:AMCL_SDK_HOME_DESKTOP
} else {
    $env:AMCL_SDK_HOME_MOBILE
}
$ProductSdkCandidates = if ($FormalDesktop) {
    @('D:\Huawei\command-line-tools\sdk', 'D:\Huawei\DevEco Studio\sdk')
} else {
    @('D:\Huawei\command-line-tools\sdk', 'D:\Huawei\DevEco Studio\sdk')
}
$SdkCandidates = @($ProductSdkOverride, $env:DEVECO_SDK_HOME) + $ProductSdkCandidates |
    Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'default\openharmony')) }
if (-not $SdkCandidates) {
    throw 'No valid DevEco SDK root found (expected default\openharmony below it)'
}
# Do not inherit a stale machine/user value: Hvigor validates this variable
# before it reads local.properties.
$env:DEVECO_SDK_HOME = [System.IO.Path]::GetFullPath($SdkCandidates[0])
& node "$ProjectRoot\scripts\test-desktop-arkts-seams.mjs"
if ($LASTEXITCODE -ne 0) { throw 'Desktop Ability/API compatibility regression failed' }
& node "$ProjectRoot\scripts\test-desktop-render-diagnostics.mjs"
if ($LASTEXITCODE -ne 0) { throw 'Desktop render diagnostic attachment regression failed' }
$HvigorVersionOutput = & $Hvigorw --version --no-daemon 2>&1
if ($LASTEXITCODE -ne 0) { throw "hvigor --version failed (exit $LASTEXITCODE)" }
$HvigorVersion = ($HvigorVersionOutput -join "`n").Trim()

Write-Host "Using DEVECO_SDK_HOME=$env:DEVECO_SDK_HOME"
Write-Host "Using hvigor=$Hvigorw ($HvigorVersion)"
Write-Host "Selected variant: product=$Product target=$Target buildMode=$BuildMode abi=$Abi artifact=$HapKind"
if ($AllowDirtyMobileGlues) {
    Write-Warning 'DIAGNOSTIC BUILD: dirty MobileGlues is allowed, content-addressed, and recorded in libglfw/provenance; this artifact is not releasable.'
}
if (-not $Release) {
    $DevelopmentStatus = @(& git status --short --untracked-files=all)
    if ($DevelopmentStatus.Count -gt 0) {
        Write-Warning "development build has a dirty superproject ($($DevelopmentStatus.Count) paths); provenance records dirty/count/status hash"
        $DevelopmentStatus | Select-Object -First 25 | ForEach-Object { Write-Host "  $_" }
        if ($DevelopmentStatus.Count -gt 25) {
            Write-Host "  ... $($DevelopmentStatus.Count - 25) more paths omitted from console; provenance retains the complete status hash"
        }
    }
}

Write-Host ""
Write-Host "=== [1/7] Source gates (before expensive build) ===" -ForegroundColor Cyan
& node "$ProjectRoot\scripts\test-diagnostic-profile.mjs"
if ($LASTEXITCODE -ne 0) { throw 'Diagnostic policy self-test failed' }
& node "$ProjectRoot\scripts\test-diagnostic-source-policy.mjs"
if ($LASTEXITCODE -ne 0) { throw 'Diagnostic log producer guard failed' }
& node "$ProjectRoot\scripts\test-diagnostics-cmake.mjs"
if ($LASTEXITCODE -ne 0) { throw 'Diagnostic CMake bypass rejection failed' }
& node "$ProjectRoot\scripts\test-product-benchmark-contract.mjs"
if ($LASTEXITCODE -ne 0) { throw 'Product benchmark isolation failed' }
& node "$ProjectRoot\scripts\test-product-contract.mjs"
if ($LASTEXITCODE -ne 0) { throw "product contract failed" }
& node "$ProjectRoot\scripts\test-check-lwjgl-target-manifest.mjs"
if ($LASTEXITCODE -ne 0) { throw 'LWJGL target-manifest tests failed' }
# 首次加载归属回归必须在打包前执行；JAR 去重检查不能替代真实 JVM/JNI 双加载器行为。
& node "$ProjectRoot\scripts\test-runtime-slot-classpath.mjs"
if ($LASTEXITCODE -ne 0) { throw 'Runtime slot classpath regression failed' }
& python "$ProjectRoot\scripts\test-runtime-bootstrap-contract.py"
if ($LASTEXITCODE -ne 0) { throw 'Runtime bootstrap contract regression failed' }
& python "$ProjectRoot\scripts\test-processor-wait.py"
if ($LASTEXITCODE -ne 0) { throw 'Processor exact-PID wait regression failed' }
& node "$ProjectRoot\scripts\test-jni-classloader-ownership.mjs"
if ($LASTEXITCODE -ne 0) { throw 'JNI classloader ownership regression failed' }
& node "$ProjectRoot\scripts\test-sdl3-host-runtime.mjs"
if ($LASTEXITCODE -ne 0) { throw 'SDL actual-consumer initialization regression failed' }
& node "$ProjectRoot\scripts\test-check-sdl3-launch-contract.mjs"
if ($LASTEXITCODE -ne 0) { throw "SDL consumer launch contract self-test failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\check-lwjgl-target-manifest.mjs"
if ($LASTEXITCODE -ne 0) { throw "LWJGL target-manifest coverage check failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\test-check-lwjgl-native-surface.mjs"
if ($LASTEXITCODE -ne 0) { throw "LWJGL native-surface self-test failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\test-check-input-build-profile.mjs"
if ($LASTEXITCODE -ne 0) { throw "input build profile self-test failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\check-input-build-profile.mjs"
if ($LASTEXITCODE -ne 0) { throw "input build profile check failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\test-sdl3-patchset-digest.mjs"
if ($LASTEXITCODE -ne 0) { throw "SDL3 patchset digest self-test failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\test-zip-entry-buffer.mjs"
if ($LASTEXITCODE -ne 0) { throw "HAP ZIP unique-entry parser self-test failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\check-sdl3-artifact.mjs"
if ($LASTEXITCODE -ne 0) { throw "SDL3 source/artifact provenance check failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\test-check-gate-f-readiness.mjs"
if ($LASTEXITCODE -ne 0) { throw "Gate F readiness self-test failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\check-gate-f-readiness.mjs"
if ($LASTEXITCODE -ne 0) { throw "Gate F readiness check failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\test-check-mg-build-contract.mjs"
if ($LASTEXITCODE -ne 0) { throw "MG release contract self-test failed (exit $LASTEXITCODE)" }
if ($Product -eq 'desktop') {
    & node "$ProjectRoot\scripts\test-check-desktop-api26-baseline.mjs"
    if ($LASTEXITCODE -ne 0) { throw "desktop baseline self-test failed (exit $LASTEXITCODE)" }
    & node "$ProjectRoot\scripts\check-desktop-api26-baseline.mjs" --product $Product
    if ($LASTEXITCODE -ne 0) { throw "desktop baseline check failed (exit $LASTEXITCODE)" }
}
$PinArguments = @("$ProjectRoot\scripts\check-mg-pin.mjs")
if ($Release) { $PinArguments += '--release' }
if ($AllowDirtyMobileGlues) { $PinArguments += '--allow-dirty' }
$PinExitCode = 1
try {
    & node @PinArguments
    $PinExitCode = $LASTEXITCODE
}
finally {
    # A private source repository may provide a read-only token solely for the
    # live origin/main advertisement. Never let it reach Hvigor/CMake/compiler.
    Remove-Item Env:AMCL_SOURCE_READ_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:AMCL_EXPECTED_SOURCE_REPOSITORY -ErrorAction SilentlyContinue
}
if ($PinExitCode -ne 0) { throw "check-mg-pin.mjs failed (exit $PinExitCode)" }
& node "$ProjectRoot\scripts\check-mg-snapshot.mjs"
if ($LASTEXITCODE -ne 0) { throw "check-mg-snapshot.mjs failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\check-ohos-runtime-optimizations.mjs"
if ($LASTEXITCODE -ne 0) { throw "check-ohos-runtime-optimizations.mjs failed (exit $LASTEXITCODE)" }

# Gate 0 证据门禁。放在耗时构建之前：AMCL_GLFW_*_VERIFIED 断言的是真机事实，未经
# gate0-evidence.lock 书面批准就打开时必须在这里停下，而不是产出一个宣称未验证能力的
# HAP。第二个脚本用 host CMake 实测 configure 期是否真的 fail closed —— 只做文本检查
# 无法证明门禁会拦住人。
& node "$ProjectRoot\scripts\check-gate0-evidence.mjs"
if ($LASTEXITCODE -ne 0) { throw "check-gate0-evidence.mjs failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\test-check-gate0-evidence.mjs"
if ($LASTEXITCODE -ne 0) { throw "test-check-gate0-evidence.mjs failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\test-gate0-evidence-cmake.mjs"
if ($LASTEXITCODE -ne 0) { throw "test-gate0-evidence-cmake.mjs failed (exit $LASTEXITCODE)" }
# ArkTS 本地单测套件的结构契约。这套测试曾经因为三层架构重构后的旧相对路径而整体
# 不执行（633 个 unresolved import），且 CI 没有 OHOS SDK 跑不了 hvigor，所以完全无
# 信号。这里用纯静态检查守住"套件不会整体不跑"这条底线；真正执行仍靠 hvigorw test。
& node "$ProjectRoot\scripts\check-arkts-test-suite.mjs"
if ($LASTEXITCODE -ne 0) { throw "check-arkts-test-suite.mjs failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\test-check-arkts-test-suite.mjs"
if ($LASTEXITCODE -ne 0) { throw "test-check-arkts-test-suite.mjs failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\test-mod-install.mjs"
if ($LASTEXITCODE -ne 0) { throw "mod installation regression failed (exit $LASTEXITCODE)" }
# 日志噪声白名单（事实源 config/log-noise-rules.json ↔ LogNoiseFilter.ets 镜像）+ 错误信号判据。
# ⭐ 为什么进 [1/7] 而不是只进 preflight：它挡的是**用户会不会看到假崩溃**。
# 1000591 关掉帧遥测之后，同样的 32 KB 诊断尾窗会装进真实 MC 输出，其中那几行
# 「剥完噪声仍被判成真实错误、但一行都不是错误」的行会把健康会话判成 CRASHED
# （1000451 那族误报）。判定链的失效形态两个方向都**不报错**：
#   往松了坏 ⇒ 健康会话弹错误 Sheet 并给破坏性建议；
#   往严了坏 ⇒ 真崩溃被判 not_diagnosable，用户看到「上次游戏已结束」。
# hypium 测试只能在设备上跑，所以"提交前必然红"这条只能落在这道门禁上。
# 先跑自测再跑门禁：判据里有一半是"源码里有没有某个形状"，正是最容易写成恒真的那一类。
& node "$ProjectRoot\scripts\test-check-log-noise-rules.mjs"
if ($LASTEXITCODE -ne 0) { throw "test-check-log-noise-rules.mjs failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\check-log-noise-rules.mjs"
if ($LASTEXITCODE -ne 0) { throw "check-log-noise-rules.mjs failed (exit $LASTEXITCODE)" }
# 落盘渗透率棘轮。裸 hilog / 裸 OH_LOG 只进易失缓冲，远端用户报的问题原理上拿不到那些行。
# ⚠️ 这道门禁 2026-06 就存在，但一直没接 —— 它当时把 .tmp-build/ 与 docker/output/ 也数了
# 进去（同一个文件数 5 遍、451 处 testTag 全在脚手架里），计数差一个数量级、--strict 恒红。
# 现在改成 allowlist（只走第一方模块根）并重新采基线，实测能复现独立 rg 统计的数字。
# 自测里最承重的是**缩水守卫**：漏登记一个模块根会让计数变小，而「漏扫」与「真改好了」
# 在计数上一模一样 ⇒ 没有那条守卫，本门禁的失效形态是静默变绿。
& node "$ProjectRoot\scripts\test-audit-logging.mjs"
if ($LASTEXITCODE -ne 0) { throw "test-audit-logging.mjs failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\audit-logging.mjs" --strict
if ($LASTEXITCODE -ne 0) { throw "audit-logging.mjs --strict failed (exit $LASTEXITCODE)" }
# 日志通道注册表：通道必须是被登记的，不能是 fopen 出来的。
# 2026-09-06 真机数出 10 条通道，而专门做全链路普查的调研报告只列了 6 条 —— 连专门数的人
# 都漏 4 条 ⇒ 靠人普查不是解法。本门禁上线第一次运行又抓出 2 条（forge-installer.log 与
# vendored openal-soft），其中 forge-installer.log 是调研与真机目录普查都没发现的第 11 条。
# 漏登记的代价是实的：MG/latest.log 存在很久，但任何读取/导出/清理路径都不碰它。
# 自测里最承重的是**阳性对照**：判据是"扫源码找疑似 sink"，正则一失效就一个都扫不到 ⇒
# 0 个违规 ⇒ 静默变绿，比有违规更危险。
& node "$ProjectRoot\scripts\test-check-log-channels.mjs"
if ($LASTEXITCODE -ne 0) { throw "test-check-log-channels.mjs failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\check-log-channels.mjs"
if ($LASTEXITCODE -ne 0) { throw "check-log-channels.mjs failed (exit $LASTEXITCODE)" }
# 导出配额（N-7）。旧做法把各段拼成一整段再**保尾**截断，而拼装顺序里环境头、活动摘要、
# 启动器日志都在前面 ⇒ 游戏日志一大它们就全被丢掉，上传出去的正文可能一行启动器日志都没有。
# 修复本体在 ArkTS，而 hypium 只能在设备上跑 ⇒ 「提交前必然红」只能落在这道静态门禁上。
# 最可能的回归形状是有人把 ledgerRead 的配额参数去掉（静默恢复成 16 MB 全读），
# 自测 §2.2 专门钉这一条。
& node "$ProjectRoot\scripts\test-check-log-export-budget.mjs"
if ($LASTEXITCODE -ne 0) { throw "test-check-log-export-budget.mjs failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\check-log-export-budget.mjs"
if ($LASTEXITCODE -ne 0) { throw "check-log-export-budget.mjs failed (exit $LASTEXITCODE)" }
# 日志域注册表：tag 必须被登记，不能是随手取的字符串。全仓 191 个 tag、14 个域。
# ⚠️ 抽取器第一版只认 `const TAG = '字面量'` 一种约定，于是「全部有归属」那个绿是**假的** ——
# 真机日志里的 McGamePage / EntryAbility / LWJGL 它一个都没看见。本仓实际有三种约定并存：
# const TAG 字面量、LogTags.ets 集中常量（2026-05-10 建的部分注册表，没铺开）、内联字面量。
# 抓住这个假绿的是**真机产物**，不是另一条静态规则 ⇒ 静态门禁至少要与一份真实产物对过账。
& node "$ProjectRoot\scripts\test-check-log-domains.mjs"
if ($LASTEXITCODE -ne 0) { throw "test-check-log-domains.mjs failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\check-log-domains.mjs"
if ($LASTEXITCODE -ne 0) { throw "check-log-domains.mjs failed (exit $LASTEXITCODE)" }
# 重复行合并的**接线**。宿主用例测的是纯策略（amcl_log_coalesce.h），它证明不了
# amcl_log.cpp 把策略接对了 —— 而这次接线真的出过一个让收益归零的缺陷：
# writer 每轮无条件收尾（本意「轮转前收尾」，但 rotateLogFiles 绝大多数周期是 no-op），
# 游程恒为 1 ⇒ 合并完全失效，而文件照常写、宿主用例照常绿、编译照常过。
& node "$ProjectRoot\scripts\test-check-log-coalesce-wiring.mjs"
if ($LASTEXITCODE -ne 0) { throw "test-check-log-coalesce-wiring.mjs failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\check-log-coalesce-wiring.mjs"
if ($LASTEXITCODE -ne 0) { throw "check-log-coalesce-wiring.mjs failed (exit $LASTEXITCODE)" }
# 加载器世代启动契约。`java.class.path` 被 7 个世代以不同方式消费，而此前代码里只有
# isForge/isFabric 两个布尔 —— 分辨率低于契约空间，于是 642edf87 一次改动同时改了 7 条契约
# （Fabric 崩于 1000576、Forge 新 bootstrap 崩于 2026-09-04，同形状事故至少 6 次）。
# ⭐ hypium 测试只能在设备上跑，所以"提交前必然红"这条不变量只能落在这道静态门禁上。
# 自测里有 642edf87 与 1000576 两次故障的最小复现，先跑自测再跑门禁。
& node "$ProjectRoot\scripts\test-check-launch-generation-contract.mjs"
if ($LASTEXITCODE -ne 0) { throw "test-check-launch-generation-contract.mjs failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\check-launch-generation-contract.mjs"
if ($LASTEXITCODE -ne 0) { throw "check-launch-generation-contract.mjs failed (exit $LASTEXITCODE)" }
# 批次 C 的 C0 探针纪律：默认关 / C0 不变换 / 显式 catch + 计数 / 快路径 / 无 ASM /
# 无 retransform / Premain-Class 声明与实际配对。这七条**一条都不会在运行期报错** ——
# 探针默认开就等于把未验证的机制放进产品路径，而 transform 抛异常被 JPLIS 静默吞掉之后
# "探针挂了"与"探针没命中"完全不可区分。同样先跑自测再跑门禁（判据全是"源码里有没有
# 某个形状"，正是最容易写成恒真的那一类；自测第一次运行就抓到一条）。
& node "$ProjectRoot\scripts\test-check-launch-agent-probe.mjs"
if ($LASTEXITCODE -ne 0) { throw "test-check-launch-agent-probe.mjs failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\check-launch-agent-probe.mjs"
if ($LASTEXITCODE -ne 0) { throw "check-launch-agent-probe.mjs failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\test-check-gamecontrol-runtime-scope.mjs"
if ($LASTEXITCODE -ne 0) { throw "gamecontrol runtime scope self-test failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\check-gamecontrol-runtime-scope.mjs"
if ($LASTEXITCODE -ne 0) { throw "gamecontrol runtime scope check failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\check-napi-obfuscation.mjs"
if ($LASTEXITCODE -ne 0) { throw "check-napi-obfuscation.mjs failed (exit $LASTEXITCODE)" }
# 混淆规则文件的单点控制面：① 未知 / 已被明确拒绝的 -enable-* 不得进来；② -keep-global-name
# 必须覆盖 module.json5 里被系统按字符串反射的入口名（漏掉 = release 启动即崩、debug 全绿）。
# 进 [1/7] 而不是只进 preflight：它挡的是**出货产物能不能起来**，与上面两道同一性质。
& node "$ProjectRoot\scripts\test-check-obfuscation-rules.mjs"
if ($LASTEXITCODE -ne 0) { throw "test-check-obfuscation-rules.mjs failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\check-obfuscation-rules.mjs"
if ($LASTEXITCODE -ne 0) { throw "check-obfuscation-rules.mjs failed (exit $LASTEXITCODE)" }
# 属性名混淆与"用接口读外部 JSON"不能同时成立（2026-08-22 事故：latest→n84 让下载页
# 两个列表与正版登录在所有开混淆的 release 包里静默失效，debug 恒绿）。
# 这一步只查规则文件；产物那半在 [5/7] 之后带 --require-artifact 再跑一次 —— 此刻的
# nameCache 还是上一次构建留下的，用它下结论等于拿旧产物给新代码背书。
& node "$ProjectRoot\scripts\test-check-wire-json-obfuscation.mjs"
if ($LASTEXITCODE -ne 0) { throw "test-check-wire-json-obfuscation.mjs failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\check-wire-json-obfuscation.mjs"
if ($LASTEXITCODE -ne 0) { throw "check-wire-json-obfuscation.mjs failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\test-ohos-runtime-cache-policy.mjs"
if ($LASTEXITCODE -ne 0) { throw "test-ohos-runtime-cache-policy.mjs failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\check-mg-docs.mjs"
if ($LASTEXITCODE -ne 0) { throw "check-mg-docs.mjs failed (exit $LASTEXITCODE)" }
if (Test-Path -LiteralPath "$ProjectRoot\scripts\check-line-refs.mjs") {
    & node "$ProjectRoot\scripts\check-line-refs.mjs"
    if ($LASTEXITCODE -ne 0) { throw "check-line-refs.mjs failed (exit $LASTEXITCODE)" }
}

Write-Host ""
Write-Host "=== [2/7] Pre-build amcl-launcher.jar ===" -ForegroundColor Cyan
& node "$ProjectRoot\scripts\build-amcl-launcher.mjs" --product $Product
if ($LASTEXITCODE -ne 0) { throw "build-amcl-launcher.mjs failed (exit $LASTEXITCODE)" }

Write-Host ""
Write-Host "=== [3/7] ArkTS local unit tests ===" -ForegroundColor Cyan
# entry/src/test 是 local unit test：hvigorw test 在主机上编译**并执行**它，不需要设备。
# 因此这一步同时给出两类证据：符号导出/类型/语法由真编译器判定，断言由 Hypium 真的跑。
# （断言确实执行：故意改错一条断言会得到 `Error in <用例名>, expect …` 并带
#  entry/src/test/<文件>.ets:<行> 栈帧，已实测。需要设备的用例在 entry/src/ohosTest，
#  不在本步范围内 —— 两者区别见 docs/guides/download-test-coverage.md §一 的更正说明。）
#
# ⚠️ **必须扫输出，不能只看退出码**（2026-08-21 实测，计划 §63.5）：断言失败时 hvigor
# 打出 `hvigor ERROR: Error in <用例名>, expect …`，但随后仍然报 **BUILD SUCCESSFUL
# 且退出码 0**。也就是说这一步在此之前是 fail-open 的 —— 它证明了"套件跑起来了"，
# 却证明不了"断言全过"。只留退出码检查等于一个永远为绿的门禁（规范 §八 第五条）。
#
# 匹配 `hvigor ERROR:` 而不是更窄的 `Error in`：本步骤里出现的任何 hvigor 级错误都应当
# 让构建停下（含 Hypium 抛出的异常栈帧、加载失败等），刻意取宽以 fail-closed。
# 已知代价：若将来 hvigor 在本步骤打出一条无害的 ERROR 行，这里会误报 —— 那时的正确
# 处置是**具名放行那一条**，不是把检查删掉。
#
# ⚠️ **必须先剥 ANSI 转义**：即使输出被重定向进管道，hvigor 仍然上色，实际字节是
# `> hvigor <ESC>[91mERROR: ...`。直接匹配字面量 `hvigor ERROR:` 会一条都匹配不到 ——
# 那就又是一个永远为绿的检查（我第一版就是这么写的，被两份实测日志的回放否证）。
#
# 为什么必须放在这里：CI 的 runner 没有 OHOS SDK，跑不了 hvigor，那边只有
# check-arkts-test-suite.mjs 的结构检查。这套测试曾因旧相对路径整体停摆很久没人发现，
# 出货路径上必须有一次真实执行。
#
# 放在 clean 之前：ArkTS 单测是纯逻辑、零 I/O，不需要 fresh native cache，而把它放在
# 昂贵的 native 构建之前可以更早失败。
#
# SDK 本地 Previewer 对 desktop target 错传 default 资源路径（见电脑施工记录 S16）。
# 共享 ArkTS 用例仍用 default 执行；独立桌面 EGL 用生产核心宿主测试和实际桌面编译验证。
$TestProduct = 'default'
# 判定逻辑刻意放在 scripts\check-hvigor-test-log.mjs 里（带 test-check- 自测），不在这里
# 内联正则：那条 "先剥 ANSI" 的前提一旦写错就是静默永绿，必须有自测钉住它。
$ArkTsTestLogPath = Join-Path $ProjectRoot '.logs\arkts-unit-test-output.log'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ArkTsTestLogPath) | Out-Null
# ⚠️ 这一段的形状是被实测逼出来的（2026-08-21，计划 §64.5），改它之前请先读完：
#
# 本脚本 `$ErrorActionPreference = 'Stop'`。而 Windows PowerShell 在**重定向外部命令的
# stderr** 时（`2>&1 |` 与 `*>` 都算）会把每一行 stderr 包成 ErrorRecord 并遵守 EAP ——
# 于是 hvigor 的**第一条 ArkTS WARN** 就会终止整个构建。原来那句没有任何重定向，
# stderr 直接进控制台，所以不触发；一旦为了扫日志而加重定向，就必须同时局部降级 EAP。
# 两种写法都实测失败过，这是第三版。
$PrevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $Hvigorw test --mode module -p "module=entry@$TestProduct" -p "product=$TestProduct" `
        -p buildMode=debug -p coverage=false --no-daemon *> $ArkTsTestLogPath
    $ArkTsTestExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $PrevEap
}
Get-Content -LiteralPath $ArkTsTestLogPath | ForEach-Object { Write-Host $_ }
if ($ArkTsTestExit -ne 0) { throw "ArkTS local unit tests failed (exit $ArkTsTestExit)" }
& node "$ProjectRoot\scripts\test-check-hvigor-test-log.mjs"
if ($LASTEXITCODE -ne 0) { throw "test-check-hvigor-test-log.mjs failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\check-hvigor-test-log.mjs" $ArkTsTestLogPath
if ($LASTEXITCODE -ne 0) { throw "ArkTS local unit tests reported failures (exit $LASTEXITCODE)" }

Write-Host ""
Write-Host "=== [4/7] Hvigor clean ===" -ForegroundColor Cyan
& $Hvigorw clean --mode module -p "product=$Product" -p buildMode=$BuildMode --no-daemon
if ($LASTEXITCODE -ne 0) { throw "hvigor clean failed (exit $LASTEXITCODE)" }

# entry/.cxx is a fully reproducible CMake/Hvigor cache. Verify the resolved
# location before recursive removal so this can never target outside the repo.
$NativeCache = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot "entry\.cxx\$Product"))
$ProjectPrefix = [System.IO.Path]::GetFullPath($ProjectRoot + [System.IO.Path]::DirectorySeparatorChar)
if (-not $NativeCache.StartsWith($ProjectPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "refusing to clean native cache outside project: $NativeCache"
}
if (Test-Path -LiteralPath $NativeCache) {
    Remove-Item -LiteralPath $NativeCache -Recurse -Force
    Write-Host "  removed stale native cache: $NativeCache"
}

Write-Host ""
Write-Host "=== [5/7] Hvigor assembleHap (fresh $BuildMode native build) ===" -ForegroundColor Cyan
& $Hvigorw assembleHap --mode module -p "product=$Product" -p buildMode=$BuildMode --no-daemon
if ($LASTEXITCODE -ne 0) { throw "hvigor assembleHap failed (exit $LASTEXITCODE)" }

# 产物级复核：读**刚刚**这次编译留下的混淆映射表，确认探针字段一个都没被改名。
# 为什么必须在这里而不是只在 [1/7]：规则文件是输入、nameCache 是结果，两者会脱钩
# （旧 CompileArkTS 缓存、某个模块的 consumerFiles 又把 flag 带回来）。[4/7] 已 clean，
# 所以此刻的映射表一定属于本次构建。--require-artifact 让"查不到产物"也算失败，
# 否则这半判据会在出货路径上空真通过。
if ($BuildMode -eq 'release') {
& node "$ProjectRoot\scripts\check-wire-json-obfuscation.mjs" --require-artifact
if ($LASTEXITCODE -ne 0) { throw "check-wire-json-obfuscation.mjs (artifact) failed (exit $LASTEXITCODE)" }
}

# libglfw.so 不得引用它没有链接的本仓符号（2026-08-23，计划 §86.1）。
# 依赖方向是单向的 libentry → libglfw，所以 libglfw 里任何对 libentry 符号的按名引用都是
# 错的 —— 而它**不会在构建期报错**：glfw 目标的 link options 没有 --no-undefined，符号会
# 留成 UND、链接静默通过、加载期才炸。这个形状已经真实发生过一次（GlfwScrollFromWheelPx
# 的定义只进了 PLATFORM_SOURCES），而当时 host 断言 30/30、aarch64 交叉 PASS、preflight
# 全绿、check-product-tu-syntax 76/76 —— 四条门禁全都只做**编译**，抓不到**链接**问题。
# ⚠️ 必须在 assembleHap **之后**跑：它查的是刚构建出来的 .so。
& node "$ProjectRoot\scripts\check-dso-undefined-symbols.mjs" --product $Product --target $Target
if ($LASTEXITCODE -ne 0) { throw "check-dso-undefined-symbols.mjs failed (exit $LASTEXITCODE)" }

# 产品 TU 的 aarch64 前端解析 + compile db 完整性交叉核对（计划 §86.2）。
# 它复用本次构建刚刷新的 compile_commands.json，把每条命令的 -c -o 换成 -fsyntax-only，
# 因此不是从零构建。完整性那一半挡的是"新增 TU 从未被任何 add_library 收录"——
# 上一次它的第一个受害者就是同批新增的唯一产品 TU。
# ⚠️ 同样刻意不进 preflight：CI runner 没有 compile db，放进去会变成永远为绿的检查项。
& node "$ProjectRoot\scripts\test-check-product-tu-syntax.mjs"
if ($LASTEXITCODE -ne 0) { throw "test-check-product-tu-syntax.mjs failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\check-product-tu-syntax.mjs" `
    --product $Product --target $Target --mode $BuildMode --abi $Abi
if ($LASTEXITCODE -ne 0) { throw "check-product-tu-syntax.mjs failed (exit $LASTEXITCODE)" }

# 测试代码不得进出货产物（2026-08-23 的产品决定）。判据直接查 HAP：libfakejvm.so 不在场、
# libentry.so 的字符串表里没有那 14 个测试 NAPI 属性名。
# 为什么查产物而不是只查 build-profile.json5：cmake 配置命令带 --no-warn-unused-cli，
# **拼错的 -D 不会有任何告警**，静默退化成"没传"；CMakeCache 也可能是脏 .cxx 的残留。
& node "$ProjectRoot\scripts\test-check-release-no-test-symbols.mjs"
if ($LASTEXITCODE -ne 0) { throw "test-check-release-no-test-symbols.mjs failed (exit $LASTEXITCODE)" }
if ($DiagnosticBuild.flags.MC_OHOS_BUILD_TESTS -eq 'OFF') {
& node "$ProjectRoot\scripts\check-release-no-test-symbols.mjs" --require-artifact `
    --product $Product --target $Target --hap-kind $HapKind
if ($LASTEXITCODE -ne 0) { throw "check-release-no-test-symbols.mjs failed (exit $LASTEXITCODE)" }
}

$OutputDirectory = Join-Path $ProjectRoot "entry\build\$Product\outputs\$Target"
$Hap = Join-Path $OutputDirectory "entry-$Target-$HapKind.hap"
$AuditScript = if ($FormalDesktop) { 'check-desktop-build-contract.mjs' } elseif ($UseDevelopmentAudit) { 'check-diagnostics-contract.mjs' } else { 'check-mg-build-contract.mjs' }
$ProvenanceName = if ($FormalDesktop) { "desktop-build-provenance-$HapKind.json" } elseif ($UseDevelopmentAudit) { "development-build-provenance-$HapKind.json" } else { "mg-build-provenance-$HapKind.json" }
$Provenance = Join-Path $OutputDirectory $ProvenanceName
if (-not (Test-Path -LiteralPath $Hap)) {
    throw "selected HAP was not produced: $Hap"
}
& node "$ProjectRoot\scripts\test-graphics-runtime-artifact.mjs"
if ($LASTEXITCODE -ne 0) { throw 'Graphics runtime artifact checker negative fixtures failed' }
& node "$ProjectRoot\scripts\check-graphics-runtime-artifact.mjs" --hap $Hap `
    --out (Join-Path $OutputDirectory 'graphics-runtime-evidence')
if ($LASTEXITCODE -ne 0) { throw 'Graphics runtime DSO/HAP linkage contract failed' }
& node "$ProjectRoot\scripts\check-lwjgl-target-manifest.mjs" --hap $Hap
if ($LASTEXITCODE -ne 0) { throw "LWJGL target manifest HAP check failed" }
& python "$ProjectRoot\scripts\check-game-runtime-compat.py" --hap $Hap
if ($LASTEXITCODE -ne 0) { throw "Game runtime compatibility final HAP check failed" }
if ($LASTEXITCODE -ne 0) { throw "HAP-embedded LWJGL target coverage check failed (exit $LASTEXITCODE)" }
& node "$ProjectRoot\scripts\check-sdl3-artifact.mjs" --provenance-only --hap $Hap
if ($LASTEXITCODE -ne 0) { throw "HAP-embedded SDL3 provenance check failed (exit $LASTEXITCODE)" }

Write-Host ""
Write-Host "=== [6/7] Audit the selected HAP and write provenance ===" -ForegroundColor Cyan
& node "$ProjectRoot\scripts\check-product-contract.mjs" --product $Product --hap $Hap
if ($LASTEXITCODE -ne 0) { throw "HAP product contract failed" }
& node "$ProjectRoot\scripts\check-desktop-render-diagnostics.mjs" --product $Product --hap $Hap `
    --source-map (Join-Path $OutputDirectory 'mapping\sourceMaps.map')
if ($LASTEXITCODE -ne 0) { throw 'Desktop render diagnostic product isolation failed' }
& node "$ProjectRoot\scripts\test-check-desktop-runtime.mjs"
if ($LASTEXITCODE -ne 0) { throw 'Desktop runtime guard self-test failed' }
$DesktopRuntimeArguments = @("$ProjectRoot\scripts\check-desktop-runtime.mjs", '--hap', $Hap,
    '--native-build', "$ProjectRoot\entry\.cxx\$Product\$Product\$BuildMode\arm64-v8a")
if ($NativeGlValidation) { $DesktopRuntimeArguments += '--native-gl-validation' }
& node @DesktopRuntimeArguments
if ($LASTEXITCODE -ne 0) { throw 'Desktop runtime HAP contract failed' }
& node "$ProjectRoot\scripts\check-mobilegl-build-contract.mjs" --product $Product --hap $Hap
if ($LASTEXITCODE -ne 0) { throw 'MobileGL HAP contract failed' }
& node "$ProjectRoot\scripts\check-diagnostics-contract.mjs" --product $Product --mode $BuildMode `
    --hap $Hap --hap-kind $HapKind --verify-signature
if ($LASTEXITCODE -ne 0) { throw 'Product diagnostic artifact contract failed' }
$ContractArguments = @(
    "$ProjectRoot\scripts\$AuditScript",
    '--product', $Product,
    '--target', $Target,
    '--mode', $BuildMode,
    '--abi', $Abi,
    '--hap-kind', $HapKind,
    '--hap', $Hap,
    '--hvigor', $Hvigorw,
    '--verify-signature',
    '--write-provenance', $Provenance
)
if ($Release) { $ContractArguments += '--require-clean' }
if ($AllowDirtyMobileGlues) { $ContractArguments += '--allow-dirty-mg' }
& node @ContractArguments
if ($LASTEXITCODE -ne 0) { throw "check-mg-build-contract.mjs failed (exit $LASTEXITCODE)" }

Write-Host ""
Write-Host "=== [7/7] Re-verify persisted provenance ===" -ForegroundColor Cyan
$VerifyArguments = @(
    "$ProjectRoot\scripts\$AuditScript",
    '--product', $Product,
    '--target', $Target,
    '--mode', $BuildMode,
    '--abi', $Abi,
    '--hap-kind', $HapKind,
    '--hap', $Hap,
    '--hvigor', $Hvigorw,
    '--verify-signature',
    '--verify-provenance', $Provenance
)
if ($Release) { $VerifyArguments += '--require-clean' }
if ($AllowDirtyMobileGlues) { $VerifyArguments += '--allow-dirty-mg' }
& node @VerifyArguments
if ($LASTEXITCODE -ne 0) { throw "persisted provenance verification failed (exit $LASTEXITCODE)" }

$HapInfo = Get-Item -LiteralPath $Hap
Write-Host ""
Write-Host "BUILD SUCCESS" -ForegroundColor Green
Write-Host "  HAP:        $Hap"
Write-Host "  Kind:       $HapKind"
Write-Host "  Size:       $([math]::Round($HapInfo.Length / 1MB, 2)) MB"
Write-Host "  SHA-256:    $((Get-FileHash -LiteralPath $Hap -Algorithm SHA256).Hash.ToLowerInvariant())"
Write-Host "  Provenance: $Provenance"
