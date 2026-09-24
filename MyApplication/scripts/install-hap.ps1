# install-hap.ps1 — 把 build-hap.ps1 产出的 signed HAP 装到所有在线设备
#
# 为什么单独一个脚本：hdc 的路径、bundle 名、HAP 路径都要写死一次，而每轮装机都要用；
# 内联命令在 cmd 里引号会被打乱（见环境约束）。
#
# 用法：
#   .\scripts\install-hap.ps1              # 装到所有在线设备
#   .\scripts\install-hap.ps1 -List        # 只列设备，不装

param([switch]$List)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot

$HdcCandidates = @(
    $env:AMCL_HDC,
    'D:\Huawei\command-line-tools\sdk\default\openharmony\toolchains\hdc.exe',
    'D:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
if (-not $HdcCandidates) { throw 'hdc.exe not found. Set AMCL_HDC.' }
$Hdc = [System.IO.Path]::GetFullPath($HdcCandidates[0])
Write-Host "hdc = $Hdc"

$Hap = Join-Path $ProjectRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
if (-not (Test-Path -LiteralPath $Hap)) {
    throw "signed HAP not found: $Hap  (run build-hap.ps1 first)"
}
$HapInfo = Get-Item -LiteralPath $Hap
$Sha = (Get-FileHash -LiteralPath $Hap -Algorithm SHA256).Hash.ToLower()
Write-Host "hap = $Hap"
Write-Host "     $([math]::Round($HapInfo.Length/1MB,1)) MB   built $($HapInfo.LastWriteTime)"
Write-Host "     sha256 $Sha"

# hdc 把设备列表写在 stdout；一行一个 connect-key。
$PrevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$raw = & $Hdc list targets 2>&1 | Out-String
$ErrorActionPreference = $PrevEap

$devices = @()
foreach ($line in ($raw -split "`r?`n")) {
    $t = $line.Trim()
    if ($t.Length -eq 0) { continue }
    if ($t -match '^\[Empty\]') { continue }
    if ($t -match '^\s*$') { continue }
    $devices += $t
}

Write-Host ""
Write-Host "=== online targets ($($devices.Count)) ==="
foreach ($d in $devices) { Write-Host "  $d" }
if ($devices.Count -eq 0) {
    Write-Host "  (none — 检查 USB 线、设备上的调试授权弹窗)" -ForegroundColor Yellow
    exit 1
}
if ($List) { exit 0 }

$failed = @()
foreach ($d in $devices) {
    Write-Host ""
    Write-Host "=== install -> $d ===" -ForegroundColor Cyan
    $ErrorActionPreference = 'Continue'
    $out = & $Hdc -t $d install -r $Hap 2>&1 | Out-String
    $code = $LASTEXITCODE
    $ErrorActionPreference = $PrevEap
    Write-Host $out.Trim()
    if ($out -match 'install bundle successfully' -or $out -match 'msg:install_succeed') {
        Write-Host "  OK" -ForegroundColor Green
    } else {
        Write-Host "  FAILED (exit $code)" -ForegroundColor Red
        $failed += $d
    }
}

Write-Host ""
if ($failed.Count -gt 0) {
    Write-Host "failed on: $($failed -join ', ')" -ForegroundColor Red
    exit 1
}
Write-Host "all devices installed. sha256 $Sha" -ForegroundColor Green
