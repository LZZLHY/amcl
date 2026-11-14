#!/bin/bash
# 用正式 JDK 镜像的 Clang 和同一冻结 SDK 构建跨 DSO 行为测试。这里只编译，
# 实际执行必须另外记录设备/仿真器身份；不能将产物成功当作运行通过。
set -euo pipefail
native=/ohos-native
sdk="$native/sysroot"
libs="$sdk/usr/lib/aarch64-linux-ohos"
runtime="$native/llvm/lib/clang/${AMCL_TARGET_RESOURCE_VERSION:?}/lib/aarch64-linux-ohos"
source=/workspace/tests/runtime-abi
out=/output/abi
mkdir -p "$out"
common=(--target=aarch64-linux-ohos "--sysroot=$sdk" -std=c++17 -O2 -fPIC
    -D__OHOS__=1 -D__OHOS_FAMILY__=1 -D__OHOS_Major__=0
    -I"$sdk/usr/include/aarch64-linux-ohos" -nostdinc++
    -isystem "$native/llvm/include/libcxx-ohos/include/c++/v1"
    -nostdlib -fuse-ld=lld -L"$libs" -L"$native/llvm/lib/aarch64-linux-ohos"
    -Wl,--no-undefined -Wl,-z,now -Wl,-z,relro -Wl,--eh-frame-hdr -Wl,-rpath,'$ORIGIN')
# SO 使用真实 crtbegin/crtend，保留系统 DSO 识别与析构关系。
/usr/bin/ohos-clang++ "${common[@]}" -shared "$libs/crti.o" "$runtime/clang_rt.crtbegin.o" \
    "$source/abi_subject.cpp" -Wl,-soname,libabi_subject.so \
    -lc++_shared "$runtime/libclang_rt.builtins.a" -lc -lm \
    "$runtime/clang_rt.crtend.o" "$libs/crtn.o" -o "$out/libabi_subject.so"
/usr/bin/ohos-clang++ "${common[@]}" -pie -Wl,--dynamic-linker=/lib/ld-musl-aarch64.so.1 \
    "$libs/Scrt1.o" "$libs/crti.o" "$runtime/clang_rt.crtbegin.o" "$source/abi_runner.cpp" \
    -L"$out" -labi_subject -lc++_shared "$runtime/libclang_rt.builtins.a" -lc -lm \
    "$runtime/clang_rt.crtend.o" "$libs/crtn.o" -o "$out/abi_runner"
cp "$native/llvm/lib/aarch64-linux-ohos/libc++_shared.so" "$out/"
/usr/bin/ohos-clang++ "${common[@]}" -pie -Wl,--dynamic-linker=/lib/ld-musl-aarch64.so.1 \
    "$libs/Scrt1.o" "$libs/crti.o" "$runtime/clang_rt.crtbegin.o" "$source/cpu_timer_probe.cpp" \
    -lc++_shared "$runtime/libclang_rt.builtins.a" -lc -lm \
    "$runtime/clang_rt.crtend.o" "$libs/crtn.o" -o "$out/cpu_timer_probe"
# 故障 fixture 只进入测试目录；真实运行通过之后必须证明旧发布错误仍被捕获。
/usr/bin/ohos-clang --target=aarch64-linux-ohos -shared -fPIC -nostdlib -fuse-ld=lld \
    "$source/old_guard_negative.c" -Wl,-soname,liboldguard_negative.so -o "$out/liboldguard_negative.so"
/usr/bin/ohos-readelf -d "$out/libabi_subject.so" > "$out/subject-dynamic.txt"
/usr/bin/ohos-readelf -l "$out/abi_runner" > "$out/runner-segments.txt"
sha256sum "$out/"*.so "$out/abi_runner" > "$out/artifacts.sha256"
echo 'PASS target ABI harness build; behavior has not run'
