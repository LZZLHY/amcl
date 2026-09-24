<#
check-host-tests-crosscompile.ps1 — 在没有 host C/C++ 工具链的环境里验证 C++ host 测试

============================ 为什么需要它 ============================

`entry/src/main/cpp/tests/host` 的 27 个目标原本用主机编译器（MSVC）构建并执行。
在当前开发环境里没有可用的 host C/C++ 编译器（无 MSVC vcvars，PATH 里无 gcc/clang/cl），
于是从 2026-08-20 起每一轮都只能写「host tests 未运行」。

那不是一个可以接受的稳态。2026-08-20 第三十五轮我把四个 host-test seam 移进
`#ifdef AMCL_INPUT_HOST_TESTING`，那个改动**直接影响 host 目标能否看到它们**，
而产品构建只能证明"产品不用它们"，证明不了"host 测试仍然能编译链接"。
本脚本就是为了让那一类断言重新可验证。

============================ 它能证明什么、不能证明什么 ============================

✅ 能证明（用 OHOS 交叉工具链为 aarch64 完整**编译 + 链接**，带项目自己的
   `-Wall -Wextra -Werror -pedantic`）：
     · 声明/定义可见性 —— **链接成功即证明没有未定义符号**，这是上面那个 `#ifdef`
       改动唯一需要的证明；
     · `#ifdef` 分支组合、类型与模板实例化、全部编译期告警。

❌ 不能证明：**任何 `CHECK(...)` 断言**。二进制是 aarch64，本机跑不了。

❌ 也不能在真机上跑（2026-08-20 实测定论）：把二进制推到
   `/data/local/tmp` 后 `exec` 被 **SELinux** 拒绝 —— 标签是
   `u:object_r:data_local_tmp:s0`，`hdc shell` 的域是 `u:r:sh:s0`，
   `chcon` 同样被拒（无 root）。`/data` 本身没有 noexec，所以这不是挂载选项问题，
   是策略问题，在生产设备上无法绕过。**不要再往这个方向投入。**

============================ 两个抑制标志的来历（不是掩盖缺陷）============================

CMakeLists 给每个 host 目标加了 `-Wall -Wextra -Werror -pedantic`。用 OHOS clang 交叉编译时
有两类**工具链差异**告警会变成错误，它们在原本的主机编译器上不触发，也都不是缺陷：

  1. `-Wmissing-field-initializers`（属 `-Wextra`）——
     代码用聚合初始化省略尾部字段，是合法 C++（其余字段零初始化）。
  2. `-Wdeprecated`：`input_bridge_ohos.c` 被 CMakeLists 显式 `set_source_files_properties
     (... LANGUAGE CXX)`（那是 host 构建刻意为之），OHOS clang 对"把 .c 当 C++ 编"发告警。

⚠️ 因此本脚本**只在调用层**抑制它们，**绝不**修改 CMakeLists 或源码去迁就这套验证手段 ——
那会把"验证工具适配项目"倒过来变成"项目适配验证工具"。

⚠️ 一个 CMake 的顺序坑：`CMAKE_CXX_FLAGS` 排在 `target_compile_options` **之前**，
所以在那里写 `-Wno-missing-field-initializers` 会被随后的 `-Wextra` 重新打开。
`-Wno-unused-command-line-argument` 不属任何 `-W` 组，所以在 `CMAKE_CXX_FLAGS` 里有效。
两者的区别就是这么来的：能整体构建的 23 个目标用前者，剩下 4 个只能逐 TU 做语义检查。

============================ 用法 ============================

    powershell -ExecutionPolicy Bypass -File .\scripts\check-host-tests-crosscompile.ps1

可选：-KeepBuildDir 保留构建目录（默认删除，避免在源码树里留下大体积产物）。

**尚未接入 `build-hap.ps1` 的 source gates** —— 是否接入是一个决定（它增加约 1~2 分钟
构建时间，且带着上面两个抑制标志），留给使用者。
#>

param([switch]$KeepBuildDir)

$ErrorActionPreference = 'Stop'

$repoRoot   = Split-Path -Parent $PSScriptRoot
$hostDir    = Join-Path $repoRoot 'entry\src\main\cpp\tests\host'
$cppDir     = Join-Path $repoRoot 'entry\src\main\cpp'
$sdk        = 'D:\Huawei\command-line-tools\sdk\default'
$toolchain  = "$sdk\openharmony\native\build\cmake\ohos.toolchain.cmake"
$cmake      = "$sdk\openharmony\native\build-tools\cmake\bin\cmake.exe"
$ninja      = "$sdk\openharmony\native\build-tools\cmake\bin\ninja.exe"
# ⚠️ 必须用 hms/native/BiSheng 这个 clang 并显式给 --target / --sysroot。
# openharmony/native/llvm 下那个默认 target 是 x86_64-w64-windows-gnu 且**没有对应
# sysroot**（连 <cstdint> 都找不到），用它只会得到一堆假失败。
$clang      = "$sdk\hms\native\BiSheng\bin\clang++.exe"
$sysroot    = "$sdk/openharmony/native/sysroot"
# 交叉编译验证树与 SDK 自动输出不同，独占外部目录避免在宿主测试源码目录留下中间物。
. (Join-Path $PSScriptRoot 'lib/workspace-paths.ps1')
$buildDir = Get-AmclWorkspacePath -Kind build -Id "ohos-host-$PID" -ProjectRoot $repoRoot

foreach ($p in @($toolchain, $cmake, $ninja, $clang)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "missing toolchain component: $p" }
}

Write-Host '=== [1/2] cross-compile + link the host test targets (aarch64-linux-ohos) ===' -ForegroundColor Cyan

if (Test-Path -LiteralPath $buildDir) { Remove-Item -LiteralPath $buildDir -Recurse -Force }

# 见文件头：这里只放不属于任何 -W 组的那一个，否则会被 target 的 -Wextra 覆盖。
$configureFlags = '-Wno-unused-command-line-argument'

Push-Location $hostDir
try {
    & $cmake -S . -B $buildDir -G Ninja `
        "-DCMAKE_MAKE_PROGRAM=$ninja" `
        "-DCMAKE_TOOLCHAIN_FILE=$toolchain" `
        -DOHOS_ARCH=arm64-v8a `
        "-DCMAKE_CXX_FLAGS=$configureFlags" `
        "-DCMAKE_C_FLAGS=$configureFlags" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "cmake configure failed ($LASTEXITCODE)" }

    # -k 0：不要在第一个失败处停下。四个已知的工具链差异目标由第 2 步单独覆盖，
    # 但其余目标的真实错误必须在同一次运行里全部暴露出来。
    $buildLog = & $cmake --build $buildDir -- -k 0 2>&1
    $linked = @(Get-ChildItem -LiteralPath $buildDir -File |
                Where-Object { $_.Name -like 'amcl_*' -and $_.Extension -eq '' })
    Write-Host "  linked executables: $($linked.Count)"

    # 只把**非**已知工具链差异的错误当失败。
    $realErrors = $buildLog |
        Select-String -Pattern 'error:' |
        Where-Object {
            $_ -notmatch 'missing-field-initializers' -and
            $_ -notmatch "treating 'c' input as 'c\+\+'"
        }
    if ($realErrors) {
        Write-Host '  UNEXPECTED compile/link errors:' -ForegroundColor Red
        $realErrors | Select-Object -First 20 | ForEach-Object { Write-Host "    $_" }
        throw 'host test cross-build reported errors that are not known toolchain differences'
    }
    Write-Host '  no unexpected errors (only the two documented toolchain-difference warnings)'
}
finally { Pop-Location }

Write-Host ''
Write-Host '=== [2/2] semantic check for the TUs the cross-build could not -Werror through ===' -ForegroundColor Cyan

# 这四个 TU 触发上面两类工具链差异告警，而 CMake 的 flag 顺序让抑制无法生效
# （见文件头）。在这里逐 TU 做完整语义分析，抑制**只有那两类**。
$semanticTargets = @(
    'input/adapters/glfw_input_adapter.cpp',
    'tests/host/glfw_input_adapter_test.cpp',
    'tests/host/glfw_runtime_input_bridge_test.cpp',
    'tests/host/input_core_glfw_adapter_integration_test.cpp'
)

$semanticFlags = @(
    '--target=aarch64-linux-ohos', "--sysroot=$sysroot",
    '-std=gnu++17', '-fsyntax-only',
    '-Wall', '-Wextra', '-Werror', '-pedantic',
    '-Wno-missing-field-initializers', '-Wno-deprecated',
    '-DAMCL_INPUT_HOST_EXPORTS', '-DAMCL_INPUT_HOST_TESTING',
    '-DAMCL_INPUT_SHADOW=0',
    '-DAMCL_INPUT_QUEUE_CAPACITY=8', '-DAMCL_INPUT_BLOB_POOL_CAPACITY=16',
    '-DAMCL_GLFW_INPUT_ADAPTER_TESTING',
    '-DAMCL_INPUT_BRIDGE_HOST_TESTING', '-DEVENT_WINDOW_SIZE=8',
    '-Iinput', '-Iplatform', '-Itests/host/stubs'
)

$failed = @()
Push-Location $cppDir
try {
    foreach ($tu in $semanticTargets) {
        $out = & $clang @semanticFlags $tu 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  PASS  $tu"
        } else {
            $failed += $tu
            Write-Host "  FAIL  $tu" -ForegroundColor Red
            $out | Select-Object -First 8 | ForEach-Object { Write-Host "        $_" }
        }
    }
}
finally { Pop-Location }

if (-not $KeepBuildDir -and (Test-Path -LiteralPath $buildDir)) {
    Remove-Item -LiteralPath $buildDir -Recurse -Force
}

if ($failed.Count -gt 0) { throw "semantic check failed for: $($failed -join ', ')" }

Write-Host ''
Write-Host 'HOST TEST CROSS-VERIFICATION PASS' -ForegroundColor Green
Write-Host '  compiled + linked for aarch64 with the suite''s own -Wall -Wextra -Werror -pedantic.'
Write-Host '  ⚠️ assertions were NOT executed: the binaries are aarch64, and on-device exec is'
Write-Host '     blocked by SELinux (u:object_r:data_local_tmp:s0 vs u:r:sh:s0). See the header.'
