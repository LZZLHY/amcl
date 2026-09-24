<#
capture-look-evidence.ps1 — 采集双包对比要用的那几行日志

用法（一次对比 = clear → 你操作 → dump）：
    .\scripts\capture-look-evidence.ps1 -Action clear -Device 3AP0224B08027377
    # …在设备上跑完一套手势，并制造一次失焦/切后台…
    .\scripts\capture-look-evidence.ps1 -Action dump -Device 3AP0224B08027377 -Label phone-legacy

⚠️ 为什么是 clear + dump 而不是流式跟：hilog 环形缓冲会滚，流式跟又要一个常驻进程。
先清后 dump 能保证"这份日志里的每一行都属于这一次手势"，也就是让样本的**分母可归属**
（规范 §八 第六条推论 f：一个计数器只对它实际采样到的那个状态成立）。

⚠️ `AMCL_LOOK` **只在 `ohos_cancel_all_input` 的复位边界打**（计划 §88.4）。
不切后台 / 不失焦就 dump，这一行会是 0 条 —— 那不是"没有数据"，是"还没到观测点"。
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('clear', 'dump')][string]$Action,
    [Parameter(Mandatory = $true)][string]$Device,
    [string]$Label = 'capture'
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
    # 放大缓冲再清空：视角手势会刷很多行，默认 buffer 容易把开头的 AMCL_GATE0 滚掉，
    # 而那一行正是"这份日志属于哪个包"的唯一依据。
    # ⚠️ 16M 是 hilog 自己声明的上限（API 24 平板实测 64M 被拒：range [64.0K, 16.0M]），
    #    而放大失败必须说出来 —— 此前这里印的 "cleared (64M)" 在平板上是一句假话。
    $grow = Invoke-Hdc @('shell', 'hilog', '-G', '16M')
    Write-Host $grow
    if ($grow -match 'failed') {
        Write-Host '  ⚠️ 放大 buffer 失败 ⇒ 仍是默认大小，长会话可能把 AMCL_GATE0 滚掉。' -ForegroundColor Red
        Write-Host '     ⇒ 操作要短（一套手势 + 一次失焦就 dump），不要跑几分钟再来取。' -ForegroundColor Red
    }
    Write-Host (Invoke-Hdc @('shell', 'hilog', '-r'))
    Write-Host "log buffer cleared on $Device" -ForegroundColor Green
    Write-Host '现在去设备上操作，完事后跑 -Action dump。' -ForegroundColor Cyan
    exit 0
}

# 原始证据由工作区会话保留，不再写回项目中的历史验证包目录。
. (Join-Path $PSScriptRoot 'lib/workspace-paths.ps1')
$OutDir = Get-AmclWorkspacePath -Kind run -Id 'look-evidence' -ProjectRoot $RepoRoot
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Raw = Join-Path $OutDir "$Label-$Stamp-raw.log"

Write-Host "dumping hilog from $Device ..." -ForegroundColor Cyan
$text = Invoke-Hdc @('shell', 'hilog', '-x')
[System.IO.File]::WriteAllText($Raw, $text, (New-Object System.Text.UTF8Encoding($false)))
$lines = $text -split "`r?`n"
Write-Host ("  raw lines: {0}  -> {1}" -f $lines.Count, $Raw)

# 只抽与本次判据相关的行。刻意把 AMCL_GATE0 放第一组：**先确认包身份再看数字**，
# 否则拿到的数字无法归属（这一步就是 §89.4 那行日志存在的理由）。
$groups = [ordered]@{
    'AMCL_GATE0 (包身份 / 能力位)' = 'AMCL_GATE0 build'
    'AMCL_LOOK (视角管线守恒)'     = 'AMCL_LOOK '
    'GLFW init / typed 路由'       = 'GLFW: (Initialized|typed)'
    '通道所有权'                   = 'AMCL_INPOLICY'
    '输入不变量'                   = 'AMCL_INV'
    '相对样本 / 量纲'              = 'AMCL_MOUSEIN'
    'typed 拒绝 / 诊断'            = 'typed (relative look rejected|wheel rejected|edge dropped)'
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
    Write-Host ("  {0,-32} {1} 行" -f $g.Key, $hits.Count)
}
[System.IO.File]::WriteAllText($summary, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("  summary -> {0}" -f $summary) -ForegroundColor Green

# 判据缺失时明确说出来，不要让"0 行"被读成"通过"。
if (-not ($lines | Where-Object { $_ -match 'AMCL_GATE0 build' })) {
    Write-Host '  ⚠️ 没有 AMCL_GATE0 build 行 ⇒ 无法确认这份日志属于哪个包。' -ForegroundColor Red
    Write-Host '     成因通常是：游戏还没启动过（该行在 glfwInit），或 buffer 已滚过。' -ForegroundColor Red
}
if (-not ($lines | Where-Object { $_ -match 'AMCL_LOOK ' })) {
    Write-Host '  ⚠️ 没有 AMCL_LOOK 行 ⇒ 还没到观测点，不是没有数据。' -ForegroundColor Red
    Write-Host '     它只在复位边界打：切后台一次 / 让游戏失焦一次，再 dump。' -ForegroundColor Red
}
