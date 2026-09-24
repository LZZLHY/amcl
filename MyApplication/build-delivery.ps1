# 正常的四产品构建入口：三个 autoDebug 测试产品，以及使用本机正式证书的 store。
# 沿用现有 HAP/APP 入口的完整审核；SDK 生成的 signed/unsigned 包原位保留，不搬运或改名。
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$DeliveryRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $DeliveryRoot
$DeliveryShell = (Get-Process -Id $PID).Path
$DeliverySigning = Join-Path $DeliveryRoot 'scripts/build-menu-signing.mjs'
$DeliveryProfile = Join-Path $DeliveryRoot 'build-profile.json5'
$DeliveryBackup = Join-Path $DeliveryRoot '.secrets/amcl-build-menu-profile.backup'
$DeliveryBackedUp = $false

try {
    # 与签名菜单共用独占备份，防止同时改本机签名配置；已有备份不能覆盖。
    $DeliveryOriginal = [System.IO.File]::ReadAllBytes($DeliveryProfile)
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $DeliveryBackup)) | Out-Null
    $DeliveryStream = [System.IO.File]::Open($DeliveryBackup, [System.IO.FileMode]::CreateNew)
    try { $DeliveryStream.Write($DeliveryOriginal, 0, $DeliveryOriginal.Length) } finally { $DeliveryStream.Dispose() }
    $DeliveryBackedUp = $true

    # 当前 DevEco 配置保存 autoDebug 材料。调用现有签名选择器，不另建证书或签名方案。
    foreach ($DeliveryProduct in @('default', 'sideload', 'desktop')) {
        '' | node $DeliverySigning prepare --root $DeliveryRoot --kind debug --product $DeliveryProduct
        if ($LASTEXITCODE -ne 0) { throw "autoDebug 配置失败：$DeliveryProduct" }
        Write-Host "=== $DeliveryProduct / autoDebug / debug ===" -ForegroundColor Cyan
        & $DeliveryShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $DeliveryRoot 'build-hap.ps1') `
            -Product $DeliveryProduct -HapKind signed -BuildMode debug
        if ($LASTEXITCODE -ne 0) { throw "HAP 构建失败：$DeliveryProduct" }
    }

    # store 直接使用已保存的正式证书。build-app 先构建 HAP，再由 Hvigor 增量封装 APP。
    '' | node $DeliverySigning prepare --root $DeliveryRoot --kind release --product store
    if ($LASTEXITCODE -ne 0) { throw 'store 正式签名配置失败' }
    Write-Host '=== store / Release key / release ===' -ForegroundColor Cyan
    & $DeliveryShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $DeliveryRoot 'build-app.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'store HAP/APP 构建失败' }

    # 直接列出 SDK 原生输出；signed 和 unsigned 都是正常构建结果，不能只挑签名包交付。
    Write-Host '=== 构建结果（SDK 默认位置）===' -ForegroundColor Green
    foreach ($DeliveryProduct in @('default', 'sideload', 'desktop', 'store')) {
        foreach ($DeliveryKind in @('signed', 'unsigned')) {
            $DeliveryFile = Join-Path $DeliveryRoot "entry/build/$DeliveryProduct/outputs/$DeliveryProduct/entry-$DeliveryProduct-$DeliveryKind.hap"
            Write-Host (Get-Item -LiteralPath $DeliveryFile -ErrorAction Stop).FullName
        }
    }
    foreach ($DeliveryKind in @('signed', 'unsigned')) {
        $DeliveryFiles = @(Get-ChildItem -LiteralPath (Join-Path $DeliveryRoot 'build/outputs/store') -File -Filter "*-$DeliveryKind.app")
        if ($DeliveryFiles.Count -ne 1) { throw "store $DeliveryKind APP 输出缺失或不唯一" }
        Write-Host $DeliveryFiles[0].FullName
    }
} finally {
    if ($DeliveryBackedUp) {
        # 成功或失败均按原字节恢复；恢复校验失败则保留备份，避免丢失本机配置。
        [System.IO.File]::WriteAllBytes($DeliveryProfile, [System.IO.File]::ReadAllBytes($DeliveryBackup))
        if ((Get-FileHash -LiteralPath $DeliveryProfile).Hash -ne (Get-FileHash -LiteralPath $DeliveryBackup).Hash) { throw '签名配置恢复校验失败，已保留备份' }
        Remove-Item -LiteralPath $DeliveryBackup -ErrorAction Stop
    }
}
Write-Host '四产品构建完成，signed/unsigned 均在原目录，原签名配置已恢复。' -ForegroundColor Green
