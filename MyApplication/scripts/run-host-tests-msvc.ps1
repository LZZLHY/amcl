<#
run-host-tests-msvc.ps1 — 用本机 MSVC **真正执行** C++ host 测试的断言

============================ 它相对既有脚本多买到了什么 ============================

`check-host-tests-crosscompile.ps1` 用 OHOS 交叉工具链为 aarch64 编译+链接,它的文件头
明确写着「❌ 不能证明：**任何 `CHECK(...)` 断言**」。本脚本补上的正是那一格。

⚠️ **一条被写进三份文档的归因是错的,2026-08-23 推翻**：
`多输入端架构愿景与改进提案.md` 的 P8b 记「❌ 环境阻塞：本机无 host C/C++ 编译器；
真机执行已判死」,而实测：

  · **MSVC 装着** —— `vswhere -requires VC.Tools.x86.x64` 返回 VS 安装路径,
    `VC\Tools\MSVC\*\bin\Hostx64\x64\cl.exe` 有两套,VS 自带 cmake 与 ninja 也在。
    「PATH 里没有」是真的,「本机没有」是假的 —— 只需先跑 `vcvars64.bat`。
  · **SELinux 那条只关于 aarch64 二进制在设备上执行**,与宿主原生二进制无关。
    把"真机跑不了"推成"断言跑不了"是一次推理错误,不是环境限制。

⇒ 这批测试的 29 个目标**全部是纯逻辑**：运行期只要 libstdc++/pthread/libdl,唯一的 OHOS
面是 `<hilog/log.h>`,而 `tests/host/stubs/hilog/log.h`(17 行)已经把它替成 no-op。
`CMakeLists.txt` 本身就是为宿主编译器写的(`if(MSVC) /W4 /WX`、`_CRT_SECURE_NO_WARNINGS`),
交叉编译才是外部包装。`enable_testing()` + 29 个 `add_test` 也早就接好了。

============================ 它能证明什么、不能证明什么 ============================

✅ 能证明：29 个目标的 `CHECK(...)` 断言在 LLP64 + MSVC 语义下的真实结果(CTest 逐用例)。
✅ 顺带证明：`/W4 /WX` 下的全部编译期告警(比 clang 的 `-Wall -Wextra` 更严,已抓到两处)。

❌ 不能证明：**aarch64 目标平台上的行为**。指针宽度、`long` 宽度、真 pthread 语义、
   真 hilog 的 format 校验都不在射程内 —— 那仍然要靠
   `check-host-tests-crosscompile.ps1`(交叉编译)与真机。
❌ 不能替代真机回归。host 测试不碰 XComponent / NAPI / ArkUI,它们只覆盖纯逻辑层。

⇒ **两个脚本是互补的,不是替代关系**：本脚本给"断言红不红",交叉脚本给"aarch64 编得过吗"。

============================ 用法 ============================

    powershell -ExecutionPolicy Bypass -File .\scripts\run-host-tests-msvc.ps1

可选：
    -KeepBuildDir   保留构建目录(默认删除,避免在源码树里留大体积产物)
    -Filter <正则>  只跑名字匹配的用例(传给 ctest -R)

退出码 0 = 全部通过。非 0 = 有目标编译失败或有断言失败,详情在 stdout。
#>

param(
    [switch]$KeepBuildDir,
    [string]$Filter = ''
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$hostDir  = Join-Path $repoRoot 'entry\src\main\cpp\tests\host'
$buildDir = Join-Path $hostDir 'build-msvc-host'

# ---- 定位 MSVC 与 VS 自带的 cmake / ninja ----
# 刻意用 vswhere 而不是写死路径：VS 的安装盘与版本号在不同机器上都不一样,而 vswhere
# 的位置由微软固定在 ProgramFiles(x86) 下,这是唯一可移植的入口。
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw "找不到 vswhere: $vswhere（未安装 Visual Studio？）"
}
$vs = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
if (-not $vs) { throw 'vswhere 未找到带 x64 C++ 工具集的 Visual Studio 安装' }

$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
$cmake  = Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
$ninja  = Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe'
foreach ($p in @($vcvars, $cmake, $ninja)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "缺少组件: $p" }
}
Write-Host "=== host tests (MSVC) ===" -ForegroundColor Cyan
Write-Host "  VS:    $vs"

if (Test-Path -LiteralPath $buildDir) {
    Remove-Item -LiteralPath $buildDir -Recurse -Force
}

# vcvars64 只影响它自己那个 cmd 进程的环境,所以 configure/build/ctest 必须与它同一次
# `cmd /c` 调用,不能拆成三次。
$q = [char]34
$ctestArgs = 'ctest --output-on-failure'
if ($Filter) { $ctestArgs = "$ctestArgs -R $q$Filter$q" }
$chain = @(
    "$q$vcvars$q >nul 2>&1"
    "$q$cmake$q -S . -B $q$buildDir$q -G Ninja -DCMAKE_MAKE_PROGRAM=$q$ninja$q"
    "$q$cmake$q --build $q$buildDir$q"
    "$q$cmake$q -E chdir $q$buildDir$q $ctestArgs"
) -join ' && '

$exit = 0
Push-Location $hostDir
try {
    cmd /c $chain
    $exit = $LASTEXITCODE
}
finally {
    Pop-Location
    if (-not $KeepBuildDir -and (Test-Path -LiteralPath $buildDir)) {
        Remove-Item -LiteralPath $buildDir -Recurse -Force
    }
}

Write-Host ''
if ($exit -eq 0) {
    Write-Host 'HOST TEST ASSERTIONS PASS (MSVC / x64)' -ForegroundColor Green
    Write-Host '  ⚠️ 只证明 LLP64 + MSVC 语义下断言成立；aarch64 行为仍需交叉脚本 + 真机。'
} else {
    Write-Host "HOST TEST RUN FAILED (exit $exit)" -ForegroundColor Red
    Write-Host '  上面的 ctest 输出里有 FAIL 行；每条都指明 test 文件与行号。'
}
exit $exit
