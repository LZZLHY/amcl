#!/bin/bash
set -e

echo "=== Incremental Rebuild ==="

export PATH=/ohos-toolchain:$PATH

# Step 1: Build libcxxabi_shim.so
echo ""
echo "[1/4] Building libcxxabi_shim.so..."

# 跨依赖共享 shim 源码（2026-05-15 P6.5: prebuilt/stubs/src/ 是 SoT）
STUBS_SRC_DIR="/stubs-src"
[ -d "$STUBS_SRC_DIR" ] || STUBS_SRC_DIR="/build/shims"   # legacy fallback

/usr/bin/ohos-clang --target=aarch64-linux-ohos --sysroot=/ohos-sysroot-rw \
    -c -fPIC -o /tmp/eh_stubs.o "$STUBS_SRC_DIR/eh_stubs.c"
echo "  eh_stubs.o OK"

/usr/bin/ohos-clang++ --target=aarch64-linux-ohos --sysroot=/ohos-sysroot-rw \
    -shared -fPIC -fvisibility=hidden -fno-exceptions -fno-rtti \
    -o /tmp/libcxxabi_shim.so "$STUBS_SRC_DIR/cxxabi_shim.cpp" /tmp/eh_stubs.o \
    -fuse-ld=lld -Wl,-soname,libcxxabi_shim.so -nostdlib++ -nodefaultlibs -lc
echo "  libcxxabi_shim.so OK"

cp /tmp/libcxxabi_shim.so /output/jdk-libs/libcxxabi_shim.so
echo "  Copied to /output/jdk-libs/"

echo "  Exported symbols:"
llvm-nm-15 -D /tmp/libcxxabi_shim.so | grep " T " | head -20
echo "  nothrow check:"
llvm-nm-15 -D /tmp/libcxxabi_shim.so | grep nothrow || echo "  WARNING: nothrow not found"

# Step 2: Rebuild libjli.so
echo ""
echo "[2/4] Rebuilding libjli.so..."
bash /build/scripts/rebuild_libjli.sh

# Step 3: Verify symbols
echo ""
echo "[3/4] Verifying libjli.so symbols..."
echo "JLI_Exit symbols:"
llvm-nm-15 -D /output/jdk-libs/libjli.so | grep -i "JLI_Exit" || echo "  NONE FOUND"
echo "JLI_Launch:"
llvm-nm-15 -D /output/jdk-libs/libjli.so | grep -i "JLI_Launch" || echo "  NONE FOUND"

# Step 4: Pack JDK split
echo ""
echo "[4/4] Packing JDK split..."
bash /build/scripts/pack_jdk_split.sh

echo ""
echo "=== Incremental Rebuild Complete ==="
