#!/bin/bash
# 构建兼容 SONAME 的薄 C 入口，显式依赖同 SDK 的真实 libc++/libc++abi/libunwind。
# 旧库名只用于配方和依赖名兼容；本库不再定义任何 C++ ABI 符号。
set -euo pipefail
major=${1:?JDK major required}
out=${2:?output library directory required}
native=${AMCL_JDK_NATIVE_ROOT:?JDK builds require a frozen native SDK}
case "$major" in 8|17|21|25) ;; *) echo 'Unsupported JDK major' >&2; exit 2;; esac
provider="$native/llvm/lib/aarch64-linux-ohos/libc++_shared.so"
target="${OHOS_SYSROOT:?}/usr/lib/aarch64-linux-ohos"
mkdir -p "$out"
cp "$provider" "$out/libc++_shared.so"
cp "$provider" "$target/libc++_shared.so"
extra=()
if [ "$major" = 8 ]; then
    # JDK8 的 libc 名称兼容仍是 C 边界，不能重新定义异常/guard/RTTI。
    /usr/bin/ohos-clang --target=aarch64-linux-ohos --sysroot="$OHOS_SYSROOT" \
        -I"$OHOS_SYSROOT/usr/include/aarch64-linux-ohos" -fPIC -c \
        /recipes/jdk8_musl_compat.c -o "$out/jdk8_musl_compat.o"
    extra+=("$out/jdk8_musl_compat.o")
fi
/usr/bin/ohos-clang++ --target=aarch64-linux-ohos --sysroot="$OHOS_SYSROOT" \
    -I"$OHOS_SYSROOT/usr/include/aarch64-linux-ohos" -shared -fPIC -fvisibility=hidden \
    -nostdlib -fuse-ld=lld /prebuilt/stubs/src/cxxabi_shim.cpp "${extra[@]}" \
    -L"$target" -Wl,--no-as-needed -lc++_shared -Wl,--as-needed -lc \
    -Wl,--no-undefined -Wl,-soname,libcxxabi_shim.so -Wl,-rpath,'$ORIGIN' \
    -o "$out/libcxxabi_shim.so"
python3 /recipes/scripts/verify_jdk_abi.py --provider "$provider" \
    --facade "$out/libcxxabi_shim.so" --headers "$native/llvm/include/libcxx-ohos/include/c++/v1" \
    --receipt "$out/abi-provider.json"
