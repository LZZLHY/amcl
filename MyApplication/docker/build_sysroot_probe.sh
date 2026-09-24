#!/bin/bash
# 最小真实环境验证：使用当前包装器编译一个 OHOS AArch64 ELF，不执行目标架构程序。
# 此探针只证明 C 编译器、链接器、sysroot、当前配方和输出挂载贯通，不代表任意 JDK 可重建。
set -euo pipefail
mkdir -p /build/sysroot-probe
cat > /build/sysroot-probe/probe.c <<'C'
#include <stdio.h>
/* 以标准库调用强制验证链接目标 libc；产物不会在 x86 容器里执行。 */
int amcl_sysroot_probe(void) { return puts("AMCL OHOS sysroot probe"); }
C
aarch64-linux-ohos-gcc -fPIC -shared -nostdlib -fuse-ld=lld \
    -Wl,--no-undefined -Wl,-soname,libamcl_sysroot_probe.so \
    /build/sysroot-probe/probe.c -lc -o /output/libamcl_sysroot_probe.so
aarch64-linux-ohos-readelf -h /output/libamcl_sysroot_probe.so | tee /output/probe-elf-header.txt
grep -q 'AArch64' /output/probe-elf-header.txt
aarch64-linux-ohos-readelf -d /output/libamcl_sysroot_probe.so | tee /output/probe-elf-dynamic.txt
grep -q 'libc.so' /output/probe-elf-dynamic.txt
sha256sum /output/libamcl_sysroot_probe.so > /output/probe-artifact.sha256
printf 'PASS: current recipe -> identified sysroot -> AArch64 shared library -> external output\n'
