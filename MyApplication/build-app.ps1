# Store APP 入口：完整 HAP 门禁、APP 封装、来源重验、内嵌载荷逐文件绑定和外层签名验证。
# 先正常构建 store HAP，再由 Hvigor 增量封装 APP，保留所有 signed/unsigned 默认输出。
[CmdletBinding()]
param([switch]$Release)
$ErrorActionPreference = 'Stop'
$AppProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $AppProjectRoot
# HAP 与 APP 使用同一 SDK 解析规则，避免继承已经失效的本机环境变量。
. (Join-Path $AppProjectRoot 'scripts/lib/build-tools.ps1')
$env:DEVECO_SDK_HOME = Resolve-AmclBuildSdk -Product store
$AppHvigor = if ($env:AMCL_HVIGORW_MOBILE) { $env:AMCL_HVIGORW_MOBILE } elseif ($env:AMCL_HVIGORW) { $env:AMCL_HVIGORW } else { 'D:\Huawei\command-line-tools\bin\hvigorw.bat' }
if (-not (Test-Path -LiteralPath $AppHvigor)) { throw 'Set AMCL_HVIGORW_MOBILE to the controlled Hvigor launcher' }
& node scripts/check-product-contract.mjs --product store --publish
if ($LASTEXITCODE -ne 0) { throw 'Store product contract failed' }
& node scripts/test-app-product-contract.mjs
if ($LASTEXITCODE -ne 0) { throw 'APP payload binding self-test failed' }
$AppHapArgs = @{ Product = 'store'; HapKind = 'unsigned'; BuildMode = 'release' }
if ($Release) { $AppHapArgs.Release = $true }
& "$AppProjectRoot\build-hap.ps1" @AppHapArgs
if ($LASTEXITCODE -ne 0) { throw 'Store HAP build failed' }
& $AppHvigor --mode project -p product=store -p buildMode=release assembleApp --no-daemon
if ($LASTEXITCODE -ne 0) { throw 'Store assembleApp failed' }
$AppHap = Join-Path $AppProjectRoot 'entry\build\store\outputs\store\entry-store-unsigned.hap'
$AppHapProvenance = Join-Path $AppProjectRoot 'entry\build\store\outputs\store\mg-build-provenance-unsigned.json'
# assembleApp 可能更新封装或签名，完成后就地复验两份正常 HAP；不复制到其他交付目录。
foreach ($AppHapKind in @('unsigned', 'signed')) {
    $AppAuditedHap = Join-Path $AppProjectRoot "entry/build/store/outputs/store/entry-store-$AppHapKind.hap"
    $AppAuditProof = Join-Path $AppProjectRoot "entry/build/store/outputs/store/mg-build-provenance-$AppHapKind.json"
    $AppAuditArgs = @('scripts/check-mg-build-contract.mjs', '--product', 'store', '--target', 'store', '--mode', 'release', '--abi', 'arm64-v8a', '--hap-kind', $AppHapKind, '--hap', $AppAuditedHap, '--hvigor', $AppHvigor, '--verify-signature', '--write-provenance', $AppAuditProof)
    if ($Release) { $AppAuditArgs += '--require-clean' }
    & node @AppAuditArgs
    if ($LASTEXITCODE -ne 0) { throw "Post-assembly $AppHapKind HAP audit failed" }
}
& node scripts/check-diagnostics-contract.mjs --product store --mode release --hap $AppHap --hap-kind unsigned --verify-signature
if ($LASTEXITCODE -ne 0) { throw 'Post-assembly product diagnostics audit failed' }
$AppOutputs = Join-Path $AppProjectRoot 'build\outputs\store'
$AppPackages = @(Get-ChildItem -LiteralPath $AppOutputs -File | Where-Object { $_.Name -match '-signed\.app$' })
if ($AppPackages.Count -ne 1) { throw 'Expected one signed store APP; refusing ambiguous outputs' }
$AppContractArgs = @('scripts/check-app-product.mjs', '--product', 'store', '--app', $AppPackages[0].FullName, '--hap', $AppHap, '--provenance', $AppHapProvenance, '--out', (Join-Path $AppOutputs 'app-product-provenance.json'))
if ($Release) { $AppContractArgs += '--require-clean' }
& node @AppContractArgs
if ($LASTEXITCODE -ne 0) { throw 'APP product/signature binding failed' }
Write-Host "APP BUILD VERIFIED: $($AppPackages[0].FullName)"
