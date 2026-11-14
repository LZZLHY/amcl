# install-hap.ps1 — 保留旧入口的只读设备发现能力。
# 用 .\scripts\install-hap.ps1 -List 查询设备，独立克隆可用 AMCL_HDC 指定本机工具。
# 覆盖安装应通过 AMCL 工作区统一交付，核对选定设备、主线候选和已验签产物。

param([switch]$List)

$ErrorActionPreference = 'Stop'

# 默认调用必须在查找 HDC 或制品之前失败，避免旧命令自动挑包并批量覆盖设备。
if (-not $List) {
    throw '旧安装入口仅支持 -List。覆盖安装请使用 AMCL 工作区统一装机门禁，见 .agents/scripts/device-delivery-README.md。'
}

$HdcCandidates = @(
    $env:AMCL_HDC,
    'D:\Huawei\command-line-tools\sdk\default\openharmony\toolchains\hdc.exe',
    'D:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
if (-not $HdcCandidates) { throw 'hdc.exe not found. Set AMCL_HDC.' }
$Hdc = [System.IO.Path]::GetFullPath($HdcCandidates[0])
Write-Host "hdc = $Hdc"

# 列表查询不依赖任何 HAP 或上级工作区。保留原生失败输出，避免误报为在线设备。
$PrevEap = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $raw = & $Hdc list targets 2>&1 | Out-String
    $code = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $PrevEap
}
if ($code -ne 0) {
    throw "hdc 设备列表查询失败（退出码 $code） $($raw.Trim())"
}

# hdc 每行输出一个设备标识，空列表用 [Empty] 表示。
$devices = @($raw -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^\[Empty\]' })
Write-Host ""
Write-Host "=== online targets ($($devices.Count)) ==="
foreach ($d in $devices) { Write-Host "  $d" }
if ($devices.Count -eq 0) {
    Write-Host "  (none — 检查 USB 线、设备上的调试授权弹窗)" -ForegroundColor Yellow
    exit 1
}
exit 0
