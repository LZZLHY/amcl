# ============================================================
# compute_jdk_sha256.ps1
#
# 流式下载 jdk17-ohos-full-v4.zip 并计算 SHA-256，不落盘。
# 用于一次性获取 JDK 镜像哈希，填入
#   entry/src/main/ets/services/JdkManager.ets
#     JDK_VERSIONS['17'].sha256
#
# 用法：
#   ./tools/compute_jdk_sha256.ps1                # 默认走 ghfast 镜像
#   ./tools/compute_jdk_sha256.ps1 -Mirror direct # 直连 GitHub
#   ./tools/compute_jdk_sha256.ps1 -Tag v17.0.13-ohos-4 -Asset jdk17-ohos-full-v4.zip
#
# 输出：
#   - SHA-256 hex 字符串（小写 64 字符）
#   - 文件字节数
#   - 平均下载速度
#
# 兼容：PowerShell 5.1+ 与 7.x
# ============================================================
[CmdletBinding()]
param(
  [ValidateSet('ghfast', 'ghproxy', 'mirror.ghproxy', 'direct')]
  [string]$Mirror = 'ghfast',

  [string]$Tag = 'v17.0.13-ohos-4',
  [string]$Asset = 'jdk17-ohos-full-v4.zip',
  [string]$Repo = 'LZZLHY/mc-ohos-resources',

  [int]$TimeoutMinutes = 30
)

$ErrorActionPreference = 'Stop'

# 镜像模板（与 JdkManager.ets MIRROR_TEMPLATES 保持一致）
$mirrorMap = @{
  'ghfast'         = 'https://ghfast.top/{url}'
  'ghproxy'        = 'https://gh-proxy.com/{url}'
  'mirror.ghproxy' = 'https://mirror.ghproxy.com/{url}'
  'direct'         = '{url}'
}

$ghUrl = "https://github.com/$Repo/releases/download/$Tag/$Asset"
$url   = $mirrorMap[$Mirror].Replace('{url}', $ghUrl)

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " JDK SHA-256 Streaming Computer" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "Mirror : $Mirror"
Write-Host "URL    : $url"
Write-Host ""

# 加载 .NET HttpClient（PS5.1 也支持）
Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $true
$client = [System.Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromMinutes($TimeoutMinutes)
$client.DefaultRequestHeaders.UserAgent.ParseAdd('compute_jdk_sha256.ps1/1.0')

$sha256 = [System.Security.Cryptography.SHA256]::Create()
$total  = 0L
$start  = [DateTime]::UtcNow
$lastReport = $start

try {
  Write-Host "Connecting..." -NoNewline
  $resp = $client.GetAsync($url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
  $resp.EnsureSuccessStatusCode() | Out-Null
  Write-Host " OK ($([int]$resp.StatusCode))"

  $contentLength = $resp.Content.Headers.ContentLength
  if ($contentLength) {
    $totalMB = [math]::Round($contentLength / 1MB, 1)
    Write-Host "Content-Length: $contentLength bytes (~$totalMB MB)"
  } else {
    Write-Host "Content-Length: <unknown> (server did not advertise)"
  }
  Write-Host ""
  Write-Host "Downloading + hashing (no disk write)..." -ForegroundColor Yellow

  $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
  $buffer = [byte[]]::new(1MB)

  while ($true) {
    $n = $stream.Read($buffer, 0, $buffer.Length)
    if ($n -le 0) { break }
    [void]$sha256.TransformBlock($buffer, 0, $n, $null, 0)
    $total += $n

    # 每 5 秒打印一次进度
    $now = [DateTime]::UtcNow
    if (($now - $lastReport).TotalSeconds -ge 5) {
      $elapsed = ($now - $start).TotalSeconds
      $speedMB = if ($elapsed -gt 0) { ($total / 1MB) / $elapsed } else { 0 }
      $progress = if ($contentLength) {
        $pct = [math]::Round(100.0 * $total / $contentLength, 1)
        "$pct% ($([math]::Round($total/1MB,1)) / $([math]::Round($contentLength/1MB,1)) MB)"
      } else {
        "$([math]::Round($total/1MB,1)) MB"
      }
      Write-Host ("  [{0,5:F1} s] {1}  @ {2:F2} MB/s" -f $elapsed, $progress, $speedMB)
      $lastReport = $now
    }
  }

  [void]$sha256.TransformFinalBlock([byte[]]::new(0), 0, 0)

  if ($contentLength -and $total -ne $contentLength) {
    Write-Warning "Bytes received ($total) != Content-Length ($contentLength). 可能下载不完整！"
  }

  $hex = -join ($sha256.Hash | ForEach-Object { $_.ToString('x2') })
  $elapsed = ([DateTime]::UtcNow - $start).TotalSeconds
  $avgMB   = if ($elapsed -gt 0) { ($total / 1MB) / $elapsed } else { 0 }

  Write-Host ""
  Write-Host "==============================================" -ForegroundColor Green
  Write-Host " RESULT" -ForegroundColor Green
  Write-Host "==============================================" -ForegroundColor Green
  Write-Host ("  Tag        : $Tag")
  Write-Host ("  Asset      : $Asset")
  Write-Host ("  Mirror     : $Mirror")
  Write-Host ("  Size       : $total bytes ({0:F2} MB)" -f ($total / 1MB))
  Write-Host ("  Avg speed  : {0:F2} MB/s ({1:F1} s)" -f $avgMB, $elapsed)
  Write-Host ("  SHA-256    : $hex") -ForegroundColor Yellow
  Write-Host ""
  Write-Host "复制到 JdkManager.ets：" -ForegroundColor Cyan
  Write-Host "  sha256: '$hex'," -ForegroundColor White
  Write-Host ""
}
finally {
  if ($sha256) { $sha256.Dispose() }
  if ($client) { $client.Dispose() }
  if ($handler) { $handler.Dispose() }
}
