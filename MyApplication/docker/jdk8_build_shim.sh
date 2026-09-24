#!/bin/bash
# 重建 libcxxabi_shim.so，把 jdk8_musl_compat.c 一并编进去（musl 兼容符号）。
set -e
SR=/ohos-sysroot-rw
LIBC=$SR/usr/lib/aarch64-linux-ohos
AI="-I$SR/usr/include/aarch64-linux-ohos"
ST=/work25/stubs-src/src
mkdir -p /build/jdk8-libs
/usr/bin/ohos-clang --target=aarch64-linux-ohos --sysroot=$SR $AI -c -fPIC -o /tmp/eh_stubs.o "$ST/eh_stubs.c"
/usr/bin/ohos-clang --target=aarch64-linux-ohos --sysroot=$SR $AI -c -fPIC -o /tmp/musl_compat.o /build/jdk8_musl_compat.c
/usr/bin/ohos-clang++ --target=aarch64-linux-ohos --sysroot=$SR $AI \
    -shared -fPIC -fvisibility=hidden -fno-exceptions -fno-rtti -nostdlib -L"$LIBC" \
    -o /build/jdk8-libs/libcxxabi_shim.so "$ST/cxxabi_shim.cpp" /tmp/eh_stubs.o /tmp/musl_compat.o \
    -fuse-ld=lld -Wl,-soname,libcxxabi_shim.so -lc
echo "=== exported musl-compat symbols ==="
nm -D /build/jdk8-libs/libcxxabi_shim.so 2>/dev/null | grep -iE 'isnanf|isinff|xpg_strerror' || echo "(nm not found / none)"
