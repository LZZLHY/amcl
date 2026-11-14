# 真实Windows OHOS SDK编译独立A/B夹具；不修改工程/SDK/已发布JDK，不调用HAP探针。
# 显式链接SDK crti/crtbegin/crtend/crtn，保留正常C++ EH，使用本任务已修复的应用provider。
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [Parameter(Mandatory=$true)][string]$Provider,
    [string]$NativeSdk = 'D:/Huawei/command-line-tools/sdk/default/openharmony/native'
)
$ErrorActionPreference = 'Stop'
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw '夹具输出必须是尚不存在的独立目录，不能覆盖历史证据。' }
$started = (Get-Date).ToString('o')
New-Item -ItemType Directory -Path $output | Out-Null
# 首次工具调用前保存执行意图；即使 SDK、输入或链接失败，仍留下对应命令及失败收据。
$receipt = [ordered]@{ schemaVersion=2; startedAt=$started; finishedAt=$null; state='running';
    purpose='SDK CRT + real C++ TLS destructor and EH fixtures; compile evidence only';
    output=$output; compilerVersion=$null; inputs=@(); commands=@(); artifacts=@();
    checks=@(); deviceQualified=$false }
function Save-Receipt {
    $receipt | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $output 'receipt.json') -Encoding utf8
}
function Invoke-RecordedNative([string]$Executable, [string[]]$Arguments, [string]$LogName) {
    # 参数保存为 JSON 数组，避免把 PowerShell 显示字符串误当可准确重放的 shell 引号。
    $command = [ordered]@{ executable=$Executable; arguments=$Arguments;
        startedAt=(Get-Date).ToString('o'); finishedAt=$null; exitCode=$null; log=$LogName }
    $receipt.commands += $command
    Save-Receipt
    $nativeOutput = @(& $Executable @Arguments 2>&1)
    $nativeExit = $LASTEXITCODE
    $nativeOutput | Tee-Object -FilePath (Join-Path $output $LogName) | Write-Host
    $command.finishedAt = (Get-Date).ToString('o')
    $command.exitCode = $nativeExit
    Save-Receipt
    if ($nativeExit -ne 0) { throw "工具失败：$Executable，exit=$nativeExit，见 $LogName。" }
    return ($nativeOutput | Out-String).Trim()
}
Save-Receipt
try {
$source = Join-Path $PSScriptRoot 'tls-crt'
$clang = Join-Path $NativeSdk 'llvm/bin/clang++.exe'
$readelf = Join-Path $NativeSdk 'llvm/bin/llvm-readelf.exe'
$resource = Invoke-RecordedNative $clang @('-print-resource-dir') 'compiler-resource.log'
if (!$resource) { throw '无法核实当前SDK compiler resource目录。' }
$receipt.compilerVersion = Invoke-RecordedNative $clang @('--version') 'compiler-version.log'
$sysroot = Join-Path $NativeSdk 'sysroot'
$systemLib = Join-Path $sysroot 'usr/lib/aarch64-linux-ohos'
$runtime = Join-Path $resource 'lib/aarch64-linux-ohos'
$providerPath = (Resolve-Path -LiteralPath $Provider).Path
$inputs = @($PSCommandPath, $clang, $readelf, $providerPath,
    (Join-Path $systemLib 'crti.o'), (Join-Path $runtime 'clang_rt.crtbegin.o'),
    (Join-Path $runtime 'clang_rt.crtend.o'), (Join-Path $systemLib 'crtn.o'),
    (Join-Path $runtime 'libclang_rt.builtins.a'), (Join-Path $systemLib 'libc.so'),
    (Join-Path $systemLib 'libm.a'), (Join-Path $source 'fixture_api.h'),
    (Join-Path $source 'owner_a.cpp'), (Join-Path $source 'dependency_b.cpp'))
foreach ($inputFile in $inputs) { if (!(Test-Path -LiteralPath $inputFile -PathType Leaf)) { throw "缺少真实输入：$inputFile" } }
$receipt.inputs = @($inputs | ForEach-Object { [ordered]@{path=$_;
    bytes=(Get-Item -LiteralPath $_).Length;
    sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant()} })
Save-Receipt
$providerDir = Join-Path $output 'provider'
New-Item -ItemType Directory -Path $providerDir | Out-Null
Copy-Item -LiteralPath $providerPath -Destination (Join-Path $providerDir 'libc++_shared.so')
$common = @('--target=aarch64-linux-ohos', "--sysroot=$sysroot")
# 当前 OHOS driver 默认 emutls；明确关闭模拟 TLS 才会生成本轮需要验收的 TLSDESC。
# EH、C++ 析构和 RTTI 保持开启；此选项不更换 SDK CRT 或伪造 __dso_handle。
$compileOptions = @('-std=c++17', '-O2', '-g', '-fPIC', '-fno-emulated-tls',
    '-fvisibility=hidden', '-fno-optimize-sibling-calls', '-D__OHOS__=1', '-D__OHOS_FAMILY__=1',
    '-D__OHOS_Major__=0', "-I$source")
$linkOptions = @('-nostdlib', '-fuse-ld=lld', '-shared',
    '-Wl,--no-undefined', '-Wl,--eh-frame-hdr', '-Wl,-z,now', '-Wl,-z,relro',
    '-Wl,--hash-style=both', '-Wl,-rpath,$ORIGIN', "-L$systemLib", "-L$providerDir")
$startObjects = @((Join-Path $systemLib 'crti.o'), (Join-Path $runtime 'clang_rt.crtbegin.o'))
$endObjects = @('-lc++_shared', (Join-Path $runtime 'libclang_rt.builtins.a'), '-lc', '-lm',
    (Join-Path $runtime 'clang_rt.crtend.o'), (Join-Path $systemLib 'crtn.o'))
foreach ($name in @('b','a')) {
    $file = if ($name -eq 'b') { 'dependency_b.cpp' } else { 'owner_a.cpp' }
    $object = Join-Path $output "tls-$name.o"
    $destination = Join-Path $output "libamcl_sdk_tls_$name.so"
    # 分开编译与链接并显式指定对象路径，不让 driver 在系统 TEMP 产生临时 .o。
    $compileArguments = $common + $compileOptions + @('-c', (Join-Path $source $file), '-o', $object)
    $null = Invoke-RecordedNative $clang ($compileArguments + @('-###')) "driver-compile-$name.log"
    $null = Invoke-RecordedNative $clang $compileArguments "compile-$name.log"
    $arguments = $common + $linkOptions + $startObjects + @($object, "-Wl,-soname,libamcl_sdk_tls_$name.so")
    if ($name -eq 'a') { $arguments += @("-L$output", '-lamcl_sdk_tls_b') }
    $arguments += $endObjects + @('-o', $destination)
    # -### 不执行编译，记录当前 driver 真正选择的 cc1/lld 参数；紧接着执行同一组参数。
    $null = Invoke-RecordedNative $clang ($arguments + @('-###')) "driver-$name.log"
    $null = Invoke-RecordedNative $clang $arguments "build-$name.log"
    $inspection = Invoke-RecordedNative $readelf @('-h', '-S', '-d', '-r', '--symbols', $destination) "elf-$name.txt"
    $required = @('Machine:\s+AArch64', '\.eh_frame_hdr', '\.eh_frame', 'LOCAL\s+HIDDEN\s+\d+\s+__dso_handle',
        'UND\s+__cxa_atexit', 'UND\s+__cxa_finalize', 'UND\s+__gxx_personality_v0')
    if ($name -eq 'a') { $required += @('Shared library: \[libamcl_sdk_tls_b.so\]', 'UND\s+__cxa_begin_catch') }
    else { $required += @('\.tdata', 'R_AARCH64_TLSDESC', 'UND\s+__cxa_thread_atexit', 'UND\s+__cxa_throw') }
    foreach ($pattern in $required) {
        $matched = $inspection -match $pattern
        $receipt.checks += [ordered]@{artifact=$name; pattern=$pattern; passed=$matched}
        Save-Receipt
        if (!$matched) { throw "夹具${name}缺少必要的真实 CRT/TLS/EH 证据：$pattern" }
    }
    if ($name -eq 'b') {
        # 不能仅看出现.tdata就声称覆盖初值重定位：确认实际RELATIVE目的地址落在
        # 唯一的已初始化TLS指针上，且addend就是夹具全局初值对象的真实ELF虚拟地址。
        $dataSection = [regex]::Match($inspection, '(?m)^\s*\[\s*\d+\]\s+\.tdata\s+PROGBITS\s+([0-9a-fA-F]+)')
        $initialObject = [regex]::Match($inspection, '(?m)^\s*\d+:\s+([0-9a-fA-F]+)\s+4\s+OBJECT\s+LOCAL\s+DEFAULT\s+\d+\s+\S*relocatedInitialValueE')
        if (!$dataSection.Success -or !$initialObject.Success) { throw '缺少.tdata或实际初值对象符号。' }
        $dataAddress = [Convert]::ToUInt64($dataSection.Groups[1].Value, 16)
        $initialAddress = [Convert]::ToUInt64($initialObject.Groups[1].Value, 16)
        $relocations = [regex]::Matches($inspection, '(?m)^([0-9a-fA-F]{16})\s+\S+\s+R_AARCH64_RELATIVE\s+([0-9a-fA-F]+)\s*$')
        $pointerRelocated = @($relocations | Where-Object {
            [Convert]::ToUInt64($_.Groups[1].Value, 16) -eq $dataAddress -and
            [Convert]::ToUInt64($_.Groups[2].Value, 16) -eq $initialAddress
        }).Count -eq 1
        $receipt.checks += [ordered]@{artifact=$name; name='tdata-pointer-relative-initial';
            tlsAddress=$dataAddress; initialObjectAddress=$initialAddress; passed=$pointerRelocated}
        Save-Receipt
        if (!$pointerRelocated) { throw '初值指针未由实际R_AARCH64_RELATIVE指向夹具全局值。' }
    }
}
# 输入在整个前台构建期间必须稳定，不能以最后一刻重新算出的散列掩盖并发修改。
foreach ($inputRecord in $receipt.inputs) {
    if ((Get-FileHash -LiteralPath $inputRecord.path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $inputRecord.sha256) {
        throw "构建期间输入发生变化：$($inputRecord.path)"
    }
}
$receipt.artifacts = @('libamcl_sdk_tls_a.so','libamcl_sdk_tls_b.so' | ForEach-Object {
        $path=Join-Path $output $_; [ordered]@{name=$_;bytes=(Get-Item -LiteralPath $path).Length;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()} });
$receipt.state = 'compiled-and-inspected'
$receipt.finishedAt = (Get-Date).ToString('o')
Save-Receipt
Write-Output "SDK CRT fixture build complete: $output"
} catch {
    $receipt.state = 'failed'
    $receipt.finishedAt = (Get-Date).ToString('o')
    $receipt['failure'] = $_.Exception.Message
    Save-Receipt
    throw
}
