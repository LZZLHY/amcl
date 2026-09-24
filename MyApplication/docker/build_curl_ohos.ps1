# ============================================================
#  build_curl_ohos.ps1 — POC wrapper: Windows → Docker 交叉编译 libcurl for OHOS
#
#  需要先 build 过 mc-ohos-jdk-builder 镜像（即能成功跑 build_jdk17_ohos.sh 的那个）。
#  没有的话请先：
#    docker build -t mc-ohos-jdk-builder -f docker/Dockerfile.openjdk-ohos docker/
#
#  用法：
#    ./docker/build_curl_ohos.ps1
#
#  产物：
#    docker/output/libcurl.so          (OHOS aarch64, OpenSSL 静态内联)
#    docker/output/curl-headers/       (头文件供 C++ include)
# ============================================================

param(
    [string]$ImageName = 'openjdk-ohos-builder:latest',
    [switch]$KeepContainer
)

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
$Repo = Split-Path $Here -Parent
$ContainerName = 'mc-curl-poc'
$OutputDir = Join-Path $Here 'output'

# 确保输出目录存在
if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory | Out-Null
}

Write-Host "=== libcurl for OHOS — POC Build ===" -ForegroundColor Cyan
Write-Host "Image:     $ImageName"
Write-Host "Repo root: $Repo"
Write-Host "Output:    $OutputDir"
Write-Host ""

# 检查镜像是否存在（docker images -q 输出镜像 ID，没有则空）
$imgId = (docker images -q $ImageName 2>$null | Out-String).Trim()
if (-not $imgId) {
    Write-Host "[X] Image '$ImageName' not found." -ForegroundColor Red
    Write-Host "   Please build it first:" -ForegroundColor Yellow
    Write-Host "   docker build -t $ImageName -f docker/Dockerfile.openjdk-ohos docker/" -ForegroundColor Yellow
    exit 1
}
Write-Host "  Image found: $imgId" -ForegroundColor Green

# 清理同名容器
docker rm -f $ContainerName 2>$null | Out-Null

# 启动容器，挂载：
#   - docker/ 到 /build-scripts (包含我们的 build_curl_ohos.sh)
#   - docker/output 到 /output (产物拷回宿主机)
#   - 宿主机的 sysroot 需要通过 Docker 镜像里已有的 /ohos-sysroot
# 注意：Dockerfile 里已经 COPY setup_toolchain.sh 到 /build/ 所以可以直接用
Write-Host "[1/3] Starting container..." -ForegroundColor Cyan
$containerId = docker run -d `
    --name $ContainerName `
    -v "${Here}:/build-scripts:ro" `
    -v "${OutputDir}:/output" `
    $ImageName `
    sleep infinity

if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Failed to start container" -ForegroundColor Red
    exit 1
}
Write-Host "  Container started: $($containerId.Substring(0, 12))" -ForegroundColor Green

try {
    # Setup toolchain (symlinks, stubs, wrappers)
    Write-Host ""
    Write-Host "[2/3] Setting up toolchain..." -ForegroundColor Cyan
    docker exec $ContainerName bash /build/setup_toolchain.sh
    if ($LASTEXITCODE -ne 0) {
        throw "Toolchain setup failed"
    }

    # Build curl + openssl
    Write-Host ""
    Write-Host "[3/3] Building curl + OpenSSL (this may take 3-5 minutes)..." -ForegroundColor Cyan
    docker exec $ContainerName bash /build-scripts/build_curl_ohos.sh
    if ($LASTEXITCODE -ne 0) {
        throw "curl build failed"
    }

    Write-Host ""
    Write-Host "=== POC BUILD SUCCESS ===" -ForegroundColor Green
    Write-Host ""

    # 显示产物
    $lib = Join-Path $OutputDir 'libcurl.so'
    if (Test-Path $lib) {
        $size = (Get-Item $lib).Length / 1KB
        Write-Host ("  libcurl.so: {0:N1} KB" -f $size) -ForegroundColor Green
    }
    $headers = Join-Path $OutputDir 'curl-headers\curl'
    if (Test-Path $headers) {
        $count = (Get-ChildItem $headers -Filter '*.h' | Measure-Object).Count
        Write-Host ("  curl-headers: $count header files") -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "Next step: examine libcurl.so NEEDED dependencies above." -ForegroundColor Yellow
    Write-Host "If only libc/libm/libdl, the POC is a clean pass." -ForegroundColor Yellow

} catch {
    Write-Host ""
    Write-Host "=== POC BUILD FAILED ===" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    throw
} finally {
    if (-not $KeepContainer) {
        Write-Host ""
        Write-Host "Cleaning up container..." -ForegroundColor Gray
        docker rm -f $ContainerName 2>$null | Out-Null
    } else {
        Write-Host ""
        Write-Host "Container kept alive: $ContainerName (use 'docker exec -it $ContainerName bash' to inspect)" -ForegroundColor Yellow
    }
}
