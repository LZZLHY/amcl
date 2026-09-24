[CmdletBinding()]
param(
    [ValidateSet('debug','release')][string]$Certificate = 'debug',
    [ValidateSet('default','desktop','store','sideload')][string]$Product = 'default',
    [ValidateSet('debug','release')][string]$BuildMode = 'debug',
    [string]$ProjectRoot = '',
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
if (!$ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$helper = Join-Path $PSScriptRoot 'build-menu-signing.mjs'
$profile = Join-Path $ProjectRoot 'build-profile.json5'
$builder = Join-Path $ProjectRoot 'build-hap.ps1'
$backup = Join-Path $ProjectRoot '.secrets\amcl-build-menu-profile.backup'
$backedUp = $false
$exitCode = 1

try {
    if (!(Test-Path -LiteralPath $builder -PathType Leaf)) { throw "找不到权威构建脚本：$builder" }
    $node = (Get-Command node.exe -ErrorAction Stop).Source
    $selectionText = & $node $helper inspect --root $ProjectRoot --kind $Certificate --product $Product
    if ($LASTEXITCODE -ne 0) { throw '签名材料检查失败，请查看上方具体文件路径。' }
    $selection = $selectionText | ConvertFrom-Json
    Write-Host "签名证书：$($selection.certpath)"
    Write-Host "证书库  ：$($selection.storeFile)"
    Write-Host "授权文件：$($selection.profile)"
    if ($CheckOnly) { exit 0 }

    $secrets = @{}
    $prepareArgs = @($helper, 'prepare', '--root', $ProjectRoot, '--kind', $Certificate, '--product', $Product)
    if ($selection.needsPasswords) {
        throw '已找到 Release 证书，但没有已保存的加密签名配置。请在 DevEco 导入一次签名配置，或设置 AMCL_RELEASE_PROFILE；菜单不再重复询问密码。'
    }

    # Backup bytes exactly and refuse to overwrite recovery data from an
    # interrupted or concurrent menu. Nothing changes before final confirmation.
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $backup)) | Out-Null
    $savedBytes = [System.IO.File]::ReadAllBytes($profile)
    $stream = [System.IO.File]::Open($backup, [System.IO.FileMode]::CreateNew)
    try { $stream.Write($savedBytes, 0, $savedBytes.Length) } finally { $stream.Dispose() }
    $backedUp = $true
    $payload = ConvertTo-Json -InputObject $secrets -Compress
    $payload | & $node @prepareArgs
    if ($LASTEXITCODE -ne 0) { throw '签名配置准备失败；未开始编译。' }
    $secrets.Clear(); $payload = $null

    $shell = (Get-Process -Id $PID).Path
    Push-Location -LiteralPath $ProjectRoot
    try {
        & $shell -NoProfile -ExecutionPolicy Bypass -File $builder -Product $Product -BuildMode $BuildMode -HapKind signed
        $exitCode = $LASTEXITCODE
    } finally { Pop-Location }
} catch {
    Write-Host "[构建菜单] $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
} finally {
    if ($secrets) { $secrets.Clear() }
    $payload = $null
    if ($backedUp) {
        try {
            [System.IO.File]::WriteAllBytes($profile, [System.IO.File]::ReadAllBytes($backup))
            Remove-Item -LiteralPath $backup -ErrorAction Stop
        } catch {
            Write-Host "[构建菜单] 原签名配置恢复失败，备份保留在：$backup" -ForegroundColor Red
            $exitCode = 1
        }
    }
}
exit $exitCode
