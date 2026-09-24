# Store APP entry: HAP gates, app assembly, fresh HAP provenance, exact nested binding and signature verification.
[CmdletBinding()]
param([switch]$Release)
$ErrorActionPreference = 'Stop'
$AppProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $AppProjectRoot
$AppHvigor = if ($env:AMCL_HVIGORW_MOBILE) { $env:AMCL_HVIGORW_MOBILE } elseif ($env:AMCL_HVIGORW) { $env:AMCL_HVIGORW } else { 'D:\Huawei\command-line-tools\bin\hvigorw.bat' }
if (-not (Test-Path -LiteralPath $AppHvigor)) { throw 'Set AMCL_HVIGORW_MOBILE to the controlled Hvigor launcher' }
& node scripts/check-product-contract.mjs --product store --publish
if ($LASTEXITCODE -ne 0) { throw 'Store product contract failed' }
& node scripts/test-app-product-contract.mjs
if ($LASTEXITCODE -ne 0) { throw 'APP payload binding self-test failed' }
$AppHapArgs = @{ Product = 'store'; HapKind = 'unsigned' }
if ($Release) { $AppHapArgs.Release = $true }
& "$AppProjectRoot\build-hap.ps1" @AppHapArgs
& $AppHvigor --mode project -p product=store -p buildMode=release assembleApp --no-daemon
if ($LASTEXITCODE -ne 0) { throw 'Store assembleApp failed' }
$AppHap = Join-Path $AppProjectRoot 'entry\build\store\outputs\store\entry-store-unsigned.hap'
$AppHapProvenance = Join-Path $AppProjectRoot 'entry\build\store\outputs\store\mg-build-provenance-unsigned.json'
# assembleApp may rebuild or re-sign outputs: bind provenance again after it.
$AppAuditArgs = @('scripts/check-mg-build-contract.mjs', '--product', 'store', '--target', 'store', '--mode', 'release', '--abi', 'arm64-v8a', '--hap-kind', 'unsigned', '--hap', $AppHap, '--hvigor', $AppHvigor, '--verify-signature', '--write-provenance', $AppHapProvenance)
if ($Release) { $AppAuditArgs += '--require-clean' }
& node @AppAuditArgs
if ($LASTEXITCODE -ne 0) { throw 'Post-assembly HAP audit failed' }
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
