<#
capture-backend-input-evidence.ps1 — LWJGL2 / SDL3 两条新通道的端到端取证

用法（一次验收 = clear → 你在游戏里按键滚轮 → dump）：
    .\scripts\capture-backend-input-evidence.ps1 -Action clear -Device 3AP0224B08027377
    # …进游戏，用实体键盘按 WASD、点左右键、滚一下滚轮…
    .\scripts\capture-backend-input-evidence.ps1 -Action dump -Device 3AP0224B08027377 -Label phone-lwjgl2

⚠️ **这个脚本判的不是"通道建起来了"，是"事件真的到了消费者手里"。**
在 `AMCL_BACKEND_DELIVERED` 这行存在之前，本通道能打出来的最强一句是 "consumer ready"，
而那只证明 Open 成功 —— "通道建起来了但一个事件都没流过"与"工作正常"在日志里长得一模一样，
而前者正是本仓踩过七次的那一族（挂在一个不会被调用的地方）。⇒ 判据必须是**单调增长的计数**。

⚠️ **必须是装了 typed 的包。** 普通产品包 `AMCL_GLFW_TYPED_PHYSICAL_DEFAULT=OFF`，那时
`amclBackendInputNext` 一律返回 UNAVAILABLE、两条新通道整条不可用（这是刻意的回退语义，
不是故障）。本脚本会先看 `typedRouteLatched`，为 0 就直接告诉你包不对，不要去读后面的数字。
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('clear', 'dump')][string]$Action,
    [Parameter(Mandatory = $true)][string]$Device,
    [string]$Label = 'backend-input'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Hdc = 'D:\Huawei\command-line-tools\sdk\default\openharmony\toolchains\hdc.exe'
if (-not (Test-Path -LiteralPath $Hdc)) { throw "hdc not found: $Hdc" }

function Invoke-Hdc([string[]]$HdcArgs) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return (& $Hdc -t $Device @HdcArgs 2>&1 | Out-String) }
    finally { $ErrorActionPreference = $prev }
}

if ($Action -eq 'clear') {
    # 16M 是 hilog 自己声明的上限（API 24 平板实测 64M 被拒）。放大失败必须说出来。
    $grow = Invoke-Hdc @('shell', 'hilog', '-G', '16M')
    Write-Host $grow
    if ($grow -match 'failed') {
        Write-Host '  ⚠️ 放大 buffer 失败 ⇒ 操作要短，不要跑几分钟再来取。' -ForegroundColor Red
    }
    Write-Host (Invoke-Hdc @('shell', 'hilog', '-r'))
    Write-Host "log buffer cleared on $Device" -ForegroundColor Green
    Write-Host '现在进游戏：实体键盘按几下 WASD、点一次左键与右键、滚一下滚轮，然后 -Action dump。' -ForegroundColor Cyan
    exit 0
}

$OutDir = Join-Path $RepoRoot 'validation-packages\logs'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Raw = Join-Path $OutDir "$Label-$Stamp-raw.log"

Write-Host "dumping hilog from $Device ..." -ForegroundColor Cyan
$text = Invoke-Hdc @('shell', 'hilog', '-x')
[System.IO.File]::WriteAllText($Raw, $text, (New-Object System.Text.UTF8Encoding($false)))
$lines = $text -split "`r?`n"
Write-Host ("  raw lines: {0}  -> {1}" -f $lines.Count, $Raw)

$groups = [ordered]@{
    'AMCL_GATE0 (包身份 / typed 是否闭锁)' = 'AMCL_GATE0 build'
    '⭐ 投递计数 (端到端判据)'             = 'AMCL_BACKEND_DELIVERED'
    'scanCode 来源分布 (测量, 不判成败)'   = 'AMCL_BACKEND_SCANSRC'
    '消费者就绪 / 延迟'                    = 'backend (typed consumer ready|adapter open deferred)'
    '通道拒绝 / 溢出'                      = 'backend (wheel rejected|queue overflow)'
    'SDL 侧闭锁 (只该在 legacy 包出现)'    = 'openharmony: typed input channel unavailable'
    '键映射未命中'                         = 'AMCL_INV|unsupportedMapping'
}
$summary = Join-Path $OutDir "$Label-$Stamp-summary.txt"
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("label=$Label  device=$Device  at=$Stamp")
[void]$sb.AppendLine("raw=$Raw  rawLines=$($lines.Count)")
foreach ($g in $groups.GetEnumerator()) {
    $hits = @($lines | Where-Object { $_ -match $g.Value })
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("=== $($g.Key)  [$($hits.Count) 行] ===")
    foreach ($h in ($hits | Select-Object -Last 25)) { [void]$sb.AppendLine('  ' + $h.Trim()) }
    Write-Host ("  {0,-38} {1} 行" -f $g.Key, $hits.Count)
}
[System.IO.File]::WriteAllText($summary, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("  summary -> {0}" -f $summary) -ForegroundColor Green

Write-Host ''
Write-Host '=== 判读 ===' -ForegroundColor Cyan

# ① 包身份先行。数字在错的包上没有意义。
$gate0 = @($lines | Where-Object { $_ -match 'AMCL_GATE0 build' })
if ($gate0.Count -eq 0) {
    Write-Host '  ⚠️ 没有 AMCL_GATE0 build 行 ⇒ 无法确认这份日志属于哪个包。' -ForegroundColor Red
    Write-Host '     该行在 glfwInit ⇒ 游戏还没启动过，或 buffer 已滚过。先启动一次游戏。' -ForegroundColor Red
    exit 2
}
$latched = if ($gate0[-1] -match 'typedRouteLatched=(\d)') { $Matches[1] } else { '?' }
Write-Host ("  包身份: typedRouteLatched={0}" -f $latched)
if ($latched -ne '1') {
    Write-Host '  ⚠️ 这是 legacy 包 ⇒ 两条新通道**按设计**整条不可用，后面的 0 不是缺陷。' -ForegroundColor Red
    Write-Host '     要验收新链请装 typed 包：scripts\build-typed-validation-hap.ps1 + deploy-validation-hap.ps1' -ForegroundColor Red
    exit 2
}

# ② 端到端判据：投递计数存在且键 > 0。
$delivered = @($lines | Where-Object { $_ -match 'AMCL_BACKEND_DELIVERED' })
if ($delivered.Count -eq 0) {
    Write-Host '  ❌ 没有 AMCL_BACKEND_DELIVERED 行 ⇒ 一个事件都没到消费者手里。' -ForegroundColor Red
    Write-Host '     区分两种成因：' -ForegroundColor Red
    Write-Host '       · 有 "consumer ready" 但没有本行 ⇒ 通道建起来了却没有事件流过（真缺陷）。' -ForegroundColor Red
    Write-Host '       · 只有 "adapter open deferred" ⇒ 还没就绪，进游戏后再试一次。' -ForegroundColor Red
    exit 1
}
$ok = $true
foreach ($backend in 2, 3) {
    $rows = @($delivered | Where-Object { $_ -match ("backend={0} " -f $backend) })
    $name = if ($backend -eq 2) { 'LWJGL2 (MC <=1.12)' } else { 'SDL3 (MC 26.3+)' }
    if ($rows.Count -eq 0) {
        Write-Host ("  --  {0}: 无投递记录（本次没跑这个世代的 MC 就是正常的）" -f $name)
        continue
    }
    $last = $rows[-1]
    if ($last -match 'keys=(\d+) buttons=(\d+) wheels=(\d+) resets=(\d+) dropped=(\d+) overflow=(\d+)') {
        $keys, $buttons, $wheels, $resets, $dropped, $overflow =
            [int64]$Matches[1], [int64]$Matches[2], [int64]$Matches[3],
            [int64]$Matches[4], [int64]$Matches[5], [int64]$Matches[6]
        $verdict = if ($keys -gt 0) { 'PASS' } else { 'FAIL(键=0)' }
        if ($keys -le 0) { $ok = $false }
        Write-Host ("  {0}  {1}: keys={2} buttons={3} wheels={4} resets={5} dropped={6} overflow={7}" -f `
            $verdict, $name, $keys, $buttons, $wheels, $resets, $dropped, $overflow)
        # ⚠️ dropped/overflow 非零不判失败，但必须说出来：它意味着消费者取得比产生慢，
        # 而那会表现为"偶尔丢一串输入"，是一条独立的问题而不是本通道不通。
        if ($overflow -gt 0) {
            Write-Host ("     ⚠️ overflow={0} ⇒ 消费者取得比产生慢，会偶尔丢一串输入。" -f $overflow) -ForegroundColor Yellow
        }
        # ⚠️ scanCode 来源分布是**测量**，不参与判成败：三支都合法，只是只有 hardware 那支
        # 是 evdev 语义（SDL 把这个值当 rawcode 用）。非 hardware 出现意味着"给 ABI 加判别位"
        # 这件事有真实收益，为 0 则那条缺口实际影响是 0，可以带证据关掉。
        $src = @($lines | Where-Object { $_ -match ("AMCL_BACKEND_SCANSRC backend={0} " -f $backend) })
        if ($src.Count -gt 0 -and $src[-1] -match 'hardware=(\d+) hidUsage=(\d+) rawIdentity=(\d+)') {
            Write-Host ("     scanCode 来源: hardware={0} hidUsage={1} rawIdentity={2}" -f `
                $Matches[1], $Matches[2], $Matches[3])
            if ([int64]$Matches[2] -gt 0 -or [int64]$Matches[3] -gt 0) {
                Write-Host '     ⚠️ 出现了非 hardware 来源 ⇒ SDL 拿到的 rawcode 不是 evdev 码（计划 §106.2）。' -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host ("  ??  {0}: 有行但字段解析不出来 -> {1}" -f $name, $last.Trim()) -ForegroundColor Yellow
        $ok = $false
    }
}

# ③ typed 包里出现 SDL 闭锁行就是矛盾：路由位开着却报不适用。
if ($lines | Where-Object { $_ -match 'typed input channel unavailable' }) {
    Write-Host '  ❌ typed 包里出现了 SDL 的 "channel unavailable" 闭锁行 —— 与 typedRouteLatched=1 矛盾。' -ForegroundColor Red
    Write-Host '     它只该在 legacy 包出现。请把这份 raw 日志留下（计划 §103.3 那条判据要用）。' -ForegroundColor Red
    $ok = $false
}

if ($ok) {
    Write-Host '  端到端判据通过（至少一条新通道有键投递，且无矛盾行）。' -ForegroundColor Green
    exit 0
}
exit 1
