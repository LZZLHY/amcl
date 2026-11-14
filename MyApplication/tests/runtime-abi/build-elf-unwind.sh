#!/bin/bash
# 复用刚刚构建的真实 provider 和冻结 SDK，编译包含生产 mapper 的独立目标进程。
set -euo pipefail
native=/ohos-native
sdk="$native/sysroot"
syslibs="$sdk/usr/lib/aarch64-linux-ohos"
runtime="$native/llvm/lib/clang/${AMCL_TARGET_RESOURCE_VERSION:?}/lib/aarch64-linux-ohos"
source=/workspace/tests/runtime-abi
out=/output/elf-unwind
mkdir "$out"
common=(--target=aarch64-linux-ohos "--sysroot=$sdk" -std=c++17 -O2 -fPIC
    -D__OHOS__=1 -D__OHOS_FAMILY__=1 -D__OHOS_Major__=0 -D_LIBUNWIND_IS_NATIVE_ONLY
    -I/workspace/tests/runtime-elf/stubs -I"$sdk/usr/include/aarch64-linux-ohos"
    -I/output/unwind-source/libunwind/include -I"$out" -nostdinc++
    -isystem "$native/llvm/include/libcxx-ohos/include/c++/v1"
    -nostdlib -fuse-ld=lld -L"$syslibs" -L/output/provider
    -Wl,--no-undefined -Wl,--eh-frame-hdr -Wl,-z,now -Wl,-z,relro -Wl,-rpath,'$ORIGIN')
/usr/bin/ohos-clang++ "${common[@]}" -shared -fvisibility=hidden -fno-optimize-sibling-calls \
    "$syslibs/crti.o" "$runtime/clang_rt.crtbegin.o" "$source/elf_unwind_subject.cpp" \
    -Wl,-soname,libelf_unwind_subject.so -Wl,--allow-shlib-undefined \
    -lc++_shared "$runtime/libclang_rt.builtins.a" -lc -lm \
    "$runtime/clang_rt.crtend.o" "$syslibs/crtn.o" -Wl,--unresolved-symbols=ignore-in-object-files \
    -o "$out/libelf_unwind_subject.so"
cp "$out/libelf_unwind_subject.so" "$out/libelf_unwind_second.so"
python3 "$source/fixture-sections.py" "$out/libelf_unwind_subject.so" "$out/fixture_sections.h"
/usr/bin/ohos-clang++ "${common[@]}" -shared "$syslibs/crti.o" "$runtime/clang_rt.crtbegin.o" \
    "$source/elf_unwind_parent.cpp" -L"$out" -lelf_unwind_subject -Wl,--allow-shlib-undefined \
    -Wl,-soname,libelf_unwind_parent.so -lc++_shared "$runtime/libclang_rt.builtins.a" -lc -lm \
    "$runtime/clang_rt.crtend.o" "$syslibs/crtn.o" -o "$out/libelf_unwind_parent.so"
/usr/bin/ohos-clang++ "${common[@]}" -pie -rdynamic -Wl,-u,__clear_cache -Wl,--dynamic-linker=/lib/ld-musl-aarch64.so.1 \
    "$syslibs/Scrt1.o" "$syslibs/crti.o" "$runtime/clang_rt.crtbegin.o" \
    "$source/elf_unwind_runner.cpp" /workspace/entry/src/main/cpp/download/hmac_sha256.cpp \
    -lc++_shared "$runtime/libclang_rt.builtins.a" -lc -lm \
    "$runtime/clang_rt.crtend.o" "$syslibs/crtn.o" -o "$out/elf_unwind_runner"
cp /output/provider/libc++_shared.so "$out/"
sha256sum "$out/"*.so "$out/elf_unwind_runner" > "$out/artifacts.sha256"
