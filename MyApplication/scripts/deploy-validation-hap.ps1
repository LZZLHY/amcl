<#
deploy-validation-hap.ps1 — 把 legacy 基线包 / typed 验证包 / typed 出货包装到指定设备

用法：
    .\scripts\deploy-validation-hap.ps1 -Which typed    -Device 3AP0224B08027377
    .\scripts\deploy-validation-hap.ps1 -Which legacy   -Device 3AP0224B08027377
    .\scripts\deploy-validation-hap.ps1 -Which shipping -Device 59JYD25815201311

⚠️ `typed` 与 `shipping` 都开着 bit10+bit13，但 evidence id 不同：`typed` 那份写着
DO-NOT-SHIP（无任何真机证据的伪造批准），`shipping` 那份是 lock 里 approved=true 的
真批准串。两者产物不可互换 —— 装错了会让"这个包是谁"这件事在日志里指向错误的授权来源。

⚠️ 两个包**同一个 bundle name**，所以设备上一次只能装一个 —— 装另一个是覆盖安装。
这正是 §83.5 说的"做不到同包 A/B，只能两个包 + 跨进程差分"：每次换包都要重跑一遍手势。

⚠️ 装之前会先读设备上现有包的 versionCode 与 bundle 状态并打印，装完再读一次 ——
否则"装上了"这件事只有 install 的退出码作证，而覆盖安装失败时它不一定非零。
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('typed', 'legacy', 'shipping')][string]$Which,
    [Parameter(Mandatory = $true)][string]$Device
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Hdc = 'D:\Huawei\command-line-tools\sdk\default\openharmony\toolchains\hdc.exe'
if (-not (Test-Path -LiteralPath $Hdc)) { throw "hdc not found: $Hdc" }

$Bundle = 'com.amcl.launcher'
$Name = switch ($Which) {
    'typed' { 'entry-default-signed-TYPED-VALIDATION.hap' }
    'shipping' { 'entry-default-signed-TYPED-SHIPPING.hap' }
    default { 'entry-default-signed-LEGACY-BASELINE.hap' }
}
$Hap = Join-Path $RepoRoot "validation-packages\$Name"
if (-not (Test-Path -LiteralPath $Hap)) { throw "package not found: $Hap" }

# 外部命令的 stderr 在重定向下会被 EAP 当成终止错误（build-hap.ps1 [3/7] 同一个坑）。
function Invoke-Hdc([string[]]$HdcArgs) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return (& $Hdc -t $Device @HdcArgs 2>&1 | Out-String) }
    finally { $ErrorActionPreference = $prev }
}

Write-Host ''
Write-Host "=== deploy $Which -> $Device ===" -ForegroundColor Cyan
Write-Host "  package: $Name"
Write-Host "  sha256:  $((Get-FileHash -LiteralPath $Hap -Algorithm SHA256).Hash.ToLowerInvariant())"
if ($Which -eq 'typed') {
    Write-Host '  ⚠️ 验证包：宣称了一个没有真机证据的能力位，不得分发。' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '--- before ---'
Write-Host (Invoke-Hdc @('shell', 'bm', 'dump', '-n', $Bundle, '|', 'grep', '-m', '2', 'versionCode'))

Write-Host '--- install (覆盖安装) ---'
$installOut = Invoke-Hdc @('app', 'install', '-r', $Hap)
Write-Host $installOut

Write-Host '--- after ---'
Write-Host (Invoke-Hdc @('shell', 'bm', 'dump', '-n', $Bundle, '|', 'grep', '-m', '2', 'versionCode'))

# 正向证据门：install 的输出必须自己说成功，退出码不足以采信（覆盖安装失败时它不一定非零）。
if ($installOut -notmatch 'successfully') {
    Write-Host ''
    Write-Host '  ⚠️ install 输出里没有 successfully —— 不要当成装好了。' -ForegroundColor Red
    exit 1
}
Write-Host ''
Write-Host "DEPLOYED: $Which on $Device" -ForegroundColor Green
