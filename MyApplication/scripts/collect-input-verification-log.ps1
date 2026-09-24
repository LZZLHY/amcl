<#
collect-input-verification-log.ps1 — 输入链路真机复测的日志采集与判读

============================ 为什么需要它 ============================

每一轮真机复测都要"清 hilog → 操作 → 拉 hilog → 逐条对齐十几个关键字"。手动做有两个问题：
① 关键字会漏（本项目的判读关键字已经有十几条，散在四个文件里）；
② 缓冲区默认不大，一局游戏的日志会把关键行冲掉，而这件事**不会报错**，只会让判读
   得出"没出现 ⇒ 没问题"的错误结论 —— 那正是最贵的一种失败。

所以这个脚本先把缓冲区调大再清空，操作完再一次性拉全量 + 分类判读。

============================ 用法 ============================

    # 手机
    powershell -ExecutionPolicy Bypass -File .\scripts\collect-input-verification-log.ps1 -Device 3AP0224B08027377

    # 平板（§58.10 判据 1 优先在这台跑：官方确认分屏在 Tablet 上生效）
    powershell -ExecutionPolicy Bypass -File .\scripts\collect-input-verification-log.ps1 -Device 59JYD25815201311

脚本会：调大缓冲 → 清空 → 停下来等你在设备上操作 → 你按 Enter → 拉全量存盘 → 打分类判读。
全量日志会存到 -OutDir（默认工作区的本次 run 目录），判读只是摘要，**结论有疑问时读全量**。

============================ 它能证明什么、不能证明什么 ============================

✅ 能：某条日志出现/未出现、出现了几次、相对顺序。
❌ 不能：任何**视觉**结论。"聊天输入条有没有被关掉"、"那个键在 MC 里是不是还按着"
   只能靠眼睛看 —— 脚本会在对应项明确标 [需目视]。
#>

param(
    [Parameter(Mandatory = $true)][string]$Device,
    [string]$OutDir = '',
    # ⚠️ 平台上限是 **16M**（实测：`hilog -G 64M` 返回
    # "Invalid buffer size, buffer size should be in range [64.0K, 16.0M] [CODE: -30]"）。
    # 这里曾默认 64M，于是调大**一直在静默失败**而脚本照旧打印"buffer=64M" ——
    # 正是本脚本头注释警告的那种失败（日志被冲掉不报错，判读得出"没出现 ⇒ 没问题"）。
    # 详见计划 §70.1。改这个值之前先确认平台上限没变。
    [string]$BufferSize = '16M',
    # 只准备（调大缓冲 + 清空）然后立刻退出，**不等键盘**。
    [switch]$PrepareOnly,
    # 只抓取 + 判读，不动缓冲区。
    [switch]$DumpOnly
)

# ⚠️ 三种模式是刻意的：默认模式带 Read-Host，只适合"同一个人既开脚本又操作设备"。
# 而实际分工是**一个人操作设备、另一个人跑工具**，那时必须用 -PrepareOnly / -DumpOnly
# 两段式，否则跑工具的那一方会卡在 Read-Host 上等一个他自己按不了的回车。
if ($PrepareOnly -and $DumpOnly) { throw '-PrepareOnly 与 -DumpOnly 互斥' }

$ErrorActionPreference = 'Stop'
# 参数覆盖仍经过同一仓外边界检查，避免沿用历史参数时重建源码目录中的日志文件夹。
. (Join-Path $PSScriptRoot 'lib/workspace-paths.ps1')
$OutDir = Get-AmclWorkspacePath -Kind run -Id 'input-verification' -ExplicitPath $OutDir
$hdc = 'D:\Huawei\command-line-tools\sdk\default\openharmony\toolchains\hdc.exe'
if (-not (Test-Path -LiteralPath $hdc)) { throw "hdc not found: $hdc" }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

$targets = (& $hdc list targets) -split "`r?`n" | Where-Object { $_.Trim() }
if ($targets -notcontains $Device) {
    throw "device '$Device' not connected. connected: $($targets -join ', ')"
}

if (-not $DumpOnly) {
    Write-Host "=== [1/3] enlarge + clear hilog buffer on $Device ===" -ForegroundColor Cyan
    # ⚠️ **必须校验调大是否真的生效，不能只发命令。** hilog 对非法尺寸只在 stdout 打一行
    # "failed" 然后正常退出（退出码 0），所以只看退出码等于永远成功。
    $setOut = (& $hdc -t $Device shell "hilog -G $BufferSize" 2>&1 | Out-String)
    Write-Host $setOut.Trim()
    if ($setOut -match 'failed') {
        throw ("hilog -G $BufferSize 被拒绝（平台上限见上面的报错）。" +
               '缓冲没调大就采集，关键行可能被冲掉而判读表现为"没出现 ⇒ 没问题" —— ' +
               'fail-closed，不继续。')
    }
    # 回读确认。`hilog -g` 打印当前各类型的缓冲大小。
    $getOut = (& $hdc -t $Device shell 'hilog -g' 2>&1 | Out-String)
    Write-Host $getOut.Trim()
    & $hdc -t $Device shell 'hilog -r' | Write-Host
    Write-Host "  requested=$BufferSize, cleared at $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Green
    Write-Host '  ⚠️ 上面 `hilog -g` 的回读值就是实际生效值，判读时以它为准。' -ForegroundColor Green
    Write-Host ''
    if ($PrepareOnly) {
        Write-Host '缓冲已就绪。现在去设备上操作；操作完用 -DumpOnly 抓取：' -ForegroundColor Yellow
        Write-Host "  powershell -ExecutionPolicy Bypass -File .\scripts\collect-input-verification-log.ps1 -Device $Device -DumpOnly" -ForegroundColor Yellow
        exit 0
    }
    Write-Host '现在去设备上做操作（见对话里给出的步骤）。' -ForegroundColor Yellow
    Write-Host '做完之后回到这里按 Enter 拉日志。' -ForegroundColor Yellow
    Read-Host '按 Enter 继续' | Out-Null
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$full = Join-Path $OutDir "$Device-$stamp.log"
Write-Host "=== [2/3] dump hilog -> $full ===" -ForegroundColor Cyan
& $hdc -t $Device shell 'hilog -x' | Out-File -LiteralPath $full -Encoding utf8
$lines = Get-Content -LiteralPath $full
Write-Host ("  {0} lines" -f $lines.Count)

Write-Host ''
Write-Host "=== [3/3] verdict ===" -ForegroundColor Cyan

function Hits([string]$pattern) {
    return @($lines | Select-String -SimpleMatch $pattern)
}

# 每一项：关键字 / 期望 / 它对应哪条判据。
# 期望值刻意写成三种，因为它们的失败方向不同：
#   MUST_ABSENT  出现即为缺陷
#   MUST_APPEAR  没出现说明这一步根本没触发到，判读无效（不是"通过"）
#   INFO         只是给判读用的上下文，无对错
$checks = @(
    @{ Key = 'neutral input typed-core epoch recovery completed'; Want = 'MUST_ABSENT';
       Why = 'typed core epoch recovery 发生过（异常路径，正常会话不该有）' },
    @{ Key = 'neutral input session failed closed'; Want = 'MUST_ABSENT';
       Why = 'typed core 会话 fail-closed（异常路径，正常会话不该有）' },
    @{ Key = 'AMCL_INVARIANT'; Want = 'MUST_ABSENT';
       Why = '输入账目不变量被破坏（五条守恒式任一条）' },
    @{ Key = 'AMCL_KBD stale held self-healed'; Want = 'MUST_ABSENT';
       Why = '物理键的按下缓存陈旧后自愈（说明中间丢了一个 UP）' },
    @{ Key = 'ControlSchema NAPI rejected'; Want = 'MUST_ABSENT';
       Why = '虚拟按键 schema 被整条拒收（所有虚拟控件会一起失效）' },
    @{ Key = 'Surface changed:'; Want = 'INFO';
       Why = 'surface 几何变化次数 —— 判据 1 的前提，为 0 说明分屏/悬浮窗没触发到' },
    @{ Key = 'AMCL_INSRC released source='; Want = 'INFO';
       Why = '★判据 1 核心：按端释放，held=N 且 N>=1 就是当场抓到幽灵持有记录' },
    @{ Key = 'dropAllEndState reason=native-reset-epoch'; Want = 'INFO';
       Why = '★判据 2：native 复位对账次数。应为个位数，若≈按键次数则是回归' },
    @{ Key = 'releaseAllEnds reason='; Want = 'INFO';
       Why = 'ArkTS 先归零方向的复位边界（page-hide / background / grab 翻转等）' },
    @{ Key = 'Input cancelAll reason='; Want = 'INFO';
       Why = '完整 native cancel 次数。判据 1 要求"released 不伴随它"' },
    @{ Key = 'AMCL_PADID'; Want = 'INFO';
       Why = '手柄按键 deviceId 探针。十轮来 0 条 —— 有手柄的话接上，这一条能解锁第 3 批端内分桶' },
    @{ Key = 'AMCL_PADAXIS'; Want = 'INFO';
       Why = '手柄摇杆 deviceId 探针（§63 新增）。kind=1 是"事件域与 inputDevice 域相通"的证据' },
    @{ Key = 'AMCL_INSRC held'; Want = 'INFO';
       Why = '按端持有账目。live 三栏在每个复位边界之后都应回到 0（P3 新判据）' },

    # ---- 2026-08-21（§69 / D1 第 2 步）：游戏态左键载体。规范 §6.1 末尾的四项取证 ----
    # 这四条合起来回答"游戏态下左键 PRESS/RELEASE 经哪条路径抵达 MC"。代码里存在一个
    # 逻辑闭环（过滤器掐断合成触摸，而 onMouse 是否投递又取决于"掐断后会恢复"这个官方
    # 从未承诺的推断），所以只能真机定论。左键三通道的所有者**因设备而异**。
    @{ Key = 'AMCL_INPOLICY left owner='; Want = 'MUST_APPEAR';
       Why = '★左键载体：arkuiMouse / nativeMouse / touchMirror 三者之一。没出现说明整局没按过左键，判读无效' },
    @{ Key = 'AMCL_WINFILTER degraded:'; Want = 'MUST_ABSENT';
       Why = '★窗口过滤器看门狗降级。出现 = 该状态下按住键拖动的视角**没有生产者**（规范 §6.1 第 3 条）' },
    @{ Key = 'AMCL_WINFILTER resolved'; Want = 'INFO';
       Why = '★过滤器解析结果。报 NO_TOOLTYPE = 该机只观测从不过滤（API<24 无 GetTouchEventToolType）' },
    @{ Key = 'AMCL_CENSUS'; Want = 'INFO';
       Why = '★逐秒普查。看同一秒的 btnArkui / btnNativeMouse / btnMirror / btnRejected 四栏归属' },

    # ---- 2026-08-21（§67.4）：AXIS_PAN 的量纲标定，只在平板上有数据 ----
    @{ Key = 'AMCL_WHEEL pan update'; Want = 'INFO';
       Why = '★平板专项：读 offsetY 与 delta。一格 delta 是多少 vp 决定 WHEEL_PAN_STEP_VP=40 对不对（C1 输入）' },
    @{ Key = 'AMCL_INPOLICY wheel owner='; Want = 'MUST_APPEAR';
       Why = '★滚轮所有者：nativeAxis / arktsAxis / axisPan / touchWheel。手机应为 nativeAxis，平板应为 axisPan' }
)

$problems = 0
foreach ($c in $checks) {
    $hits = Hits $c.Key
    $n = $hits.Count
    switch ($c.Want) {
        'MUST_ABSENT' {
            if ($n -eq 0) {
                Write-Host ("  OK    {0,-4} {1}" -f $n, $c.Key) -ForegroundColor Green
            } else {
                $problems++
                Write-Host ("  PROBLEM {0,-2} {1}" -f $n, $c.Key) -ForegroundColor Red
                Write-Host ("          -> {0}" -f $c.Why) -ForegroundColor Red
                foreach ($h in $hits | Select-Object -First 5) {
                    Write-Host ("          | " + $h.Line.Trim())
                }
            }
        }
        'MUST_APPEAR' {
            if ($n -gt 0) {
                Write-Host ("  OK    {0,-4} {1}" -f $n, $c.Key) -ForegroundColor Green
            } else {
                $problems++
                Write-Host ("  MISSING    {0}" -f $c.Key) -ForegroundColor Red
                Write-Host ("          -> {0}" -f $c.Why) -ForegroundColor Red
            }
        }
        default {
            $color = if ($n -gt 0) { 'White' } else { 'DarkGray' }
            Write-Host ("  info  {0,-4} {1}" -f $n, $c.Key) -ForegroundColor $color
            Write-Host ("          -> {0}" -f $c.Why) -ForegroundColor DarkGray
            foreach ($h in $hits | Select-Object -First 6) {
                Write-Host ("          | " + $h.Line.Trim()) -ForegroundColor DarkGray
            }
        }
    }
}

Write-Host ''
# 判据 1 的组合判定：Surface changed 之后是否跟着一次按端释放，且不伴随完整 cancel。
#
# ⚠️ **必须排除会话开头那一次** `Surface changed:` —— 它是 surface **建立**（启动时
# generation 从 1 变 2），不是几何变化，此时 ArkTS 侧还没有任何按下缓存，当然不会有按端
# 释放。不排除它就会每轮都误报一次"几何变化后未见按端释放"（2026-08-22 实测踩到，§70.4）。
# 判据：只有**第二次及以后**才算真的几何变化。
$surfaceAll = @($lines | Select-String -SimpleMatch 'Surface changed:' | ForEach-Object { $_.LineNumber })
$surfaceIdx = @(if ($surfaceAll.Count -gt 1) { $surfaceAll[1..($surfaceAll.Count - 1)] } else { @() })
$releasedIdx = @($lines | Select-String -SimpleMatch 'AMCL_INSRC released source=' | ForEach-Object { $_.LineNumber })
$cancelIdx = @($lines | Select-String -SimpleMatch 'Input cancelAll reason=' | ForEach-Object { $_.LineNumber })
Write-Host '--- 判据 1 组合判定（几何变化 -> 按端释放，且不伴随完整 cancel）---' -ForegroundColor Cyan
if ($surfaceIdx.Count -eq 0) {
    Write-Host ("  N/A  本次没有 surface **几何变化** —— 判据 1 没被触发到，不能算通过。" +
                "（共 {0} 次 Surface changed，其中首次是 surface 建立，已排除）" -f $surfaceAll.Count) -ForegroundColor Yellow
    Write-Host '       平板上用手势拉分屏/悬浮窗；手机上试小窗/悬浮窗或折叠形态切换。' -ForegroundColor Yellow
} else {
    foreach ($s in $surfaceIdx) {
        $rel = $releasedIdx | Where-Object { $_ -gt $s -and $_ -lt ($s + 400) } | Select-Object -First 1
        $can = $cancelIdx  | Where-Object { $_ -gt $s -and $_ -lt ($s + 400) } | Select-Object -First 1
        if ($rel) {
            $tag = if ($can -and $can -lt $rel) { '（但前面有 cancelAll，本次不能归因给修复）' } else { '（无 cancelAll 伴随 ⇒ 正是修复起作用）' }
            Write-Host ("  L{0}: 几何变化后在 L{1} 看到按端释放 {2}" -f $s, $rel, $tag) -ForegroundColor Green
        } else {
            Write-Host ("  L{0}: 几何变化后未见按端释放 —— 若当时确实按住了键，这是缺陷" -f $s) -ForegroundColor Yellow
        }
    }
}

Write-Host ''
Write-Host '--- 只能目视的两项（脚本判不了）---' -ForegroundColor Cyan
Write-Host '  [需目视] 判据 1：松手后那个键在游戏里是否真的抬起了（不是看日志，是看角色停不停）'
Write-Host '  [需目视] 判据 3：菜单里开着聊天输入条 -> 进游戏 -> 按物理键盘 -> 输入条与抽屉不得被关掉'
Write-Host ''
Write-Host ("full log: {0}" -f $full)
if ($problems -gt 0) {
    Write-Host ("{0} problem categor(ies) found — 读全量日志确认" -f $problems) -ForegroundColor Red
    exit 1
}
Write-Host 'no MUST_ABSENT violations.' -ForegroundColor Green
