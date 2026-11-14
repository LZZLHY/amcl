#!/bin/bash
# 重建单一应用 ABI provider：SDK 已合并的 libc++/libc++abi + 固定 vendor LLVM unwinder。
# 不生成第二套 EH 库，不覆盖 SDK 或应用输入；输出在本次独占 QA 目录等待资格与集成。
set -euo pipefail
bash /workspace/tests/runtime-abi/prepare-unwind.sh
native=/ohos-native
source=/output/unwind-source/libunwind
out=/output/provider
sdk="$native/sysroot"
target="$native/llvm/lib/aarch64-linux-ohos"
syslibs="$sdk/usr/lib/aarch64-linux-ohos"
runtime="$native/llvm/lib/clang/${AMCL_TARGET_RESOURCE_VERSION:?}/lib/aarch64-linux-ohos"
mkdir -p "$out/objects"
common=(--target=aarch64-linux-ohos "--sysroot=$sdk" -O2 -fPIC -funwind-tables
    -D__OHOS__=1 -D__OHOS_FAMILY__=1 -D__OHOS_Major__=0
    -fvisibility=hidden -D_LIBUNWIND_IS_NATIVE_ONLY -DNDEBUG
    -I"$sdk/usr/include/aarch64-linux-ohos" -I"$source/include" -I"$source/src")
objects=()
for name in libunwind.cpp Unwind-EHABI.cpp Unwind-seh.cpp UnwindLevel1.c \
    UnwindLevel1-gcc-ext.c Unwind-sjlj.c UnwindRegistersRestore.S UnwindRegistersSave.S; do
    options=()
    compiler=/usr/bin/ohos-clang
    if [[ "$name" = *.cpp ]]; then
        compiler=/usr/bin/ohos-clang++
        options=(-std=c++17 -fno-exceptions -fno-rtti -nostdinc++
            -isystem "$native/llvm/include/libcxx-ohos/include/c++/v1")
    fi
    "$compiler" "${common[@]}" "${options[@]}" -c "$source/src/$name" -o "$out/objects/$name.o"
    objects+=("$out/objects/$name.o")
done
# 该 SDK 的 libc++_static.a 已含 libc++abi 对象。再次 whole-archive libc++abi 会重定义，
# 不能用 --allow-multiple-definition 掩盖两份运行时；只链接真实单份归档。
/usr/bin/ohos-clang++ --target=aarch64-linux-ohos "--sysroot=$sdk" -nostdlib -shared -fuse-ld=lld \
    -Wl,--no-undefined -Wl,-z,now -Wl,-z,relro -Wl,--hash-style=both -Wl,--eh-frame-hdr \
    -Wl,-soname,libc++_shared.so "$syslibs/crti.o" "$runtime/clang_rt.crtbegin.o" \
    -Wl,--whole-archive "$target/libc++_static.a" -Wl,--no-whole-archive "${objects[@]}" \
    "$runtime/libclang_rt.builtins.a" -L"$syslibs" -lc -lm \
    "$runtime/clang_rt.crtend.o" "$syslibs/crtn.o" -o "$out/libc++_shared.so"
# 发布输入保留运行所需动态符号与 EH，完整调试原件留在同一构建目录用于溯源/反解。
mv "$out/libc++_shared.so" "$out/libc++_shared.unstripped.so"
/usr/bin/ohos-strip --strip-unneeded -o "$out/libc++_shared.so" "$out/libc++_shared.unstripped.so"
python3 /workspace/tests/runtime-abi/verify-application-provider.py \
    --original "$target/libc++_shared.so" --candidate "$out/libc++_shared.so" \
    --unstripped "$out/libc++_shared.unstripped.so" --receipt "$out/receipt.json"
bash /workspace/tests/runtime-abi/build-elf-unwind.sh
