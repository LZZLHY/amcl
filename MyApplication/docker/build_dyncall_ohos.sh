#!/bin/bash
set -e
# ============================================================
#  dyncall 1.0 cross-compile for HarmonyOS NEXT (aarch64/musl)
#
#  背景：LWJGL 3.2.x（老 MC 套，覆盖 1.13–1.18）的 core 用 **dyncall** 做 FFI，
#  3.3.0 才换 libffi。故 322 套 native 需要先把 dyncall 编出来（3 个静态库）：
#    libdyncall_s.a / libdyncallback_s.a / libdynload_s.a
#  再由 build_lwjgl_ohos.sh 的 3.2.x 分支链接进 liblwjgl_v322.so。
#
#  用法（容器内）：
#    docker exec ohos-debug bash /build/build_dyncall_ohos.sh
#  产物：/build/dyncall-1.0/ohos-build/{dyncall,dyncallback,dynload}/*.a
#        并汇总到 /output/dyncall-ohos/
# ============================================================

WORK_DIR=/build
DYNCALL_VER=${DYNCALL_VER:-1.0}
DYNCALL_DIR=$WORK_DIR/dyncall-$DYNCALL_VER
OHOS_SYSROOT=${OHOS_SYSROOT:-/ohos-sysroot-rw}
OUTPUT_DIR=${OUTPUT_DIR:-/output/dyncall-ohos}
JOBS=${JOBS:-$(nproc)}

OHOS_LIBDIR=$OHOS_SYSROOT/usr/lib/aarch64-linux-ohos

if [ ! -d "$OHOS_SYSROOT/usr/include" ]; then
    echo "ERROR: sysroot $OHOS_SYSROOT not ready"; exit 1
fi

echo "============================================"
echo " dyncall $DYNCALL_VER for HarmonyOS NEXT (aarch64)"
echo " Sysroot: $OHOS_SYSROOT"
echo "============================================"

# 下载 + 解压
cd $WORK_DIR
if [ ! -d "$DYNCALL_DIR" ]; then
    [ -f dyncall-$DYNCALL_VER.tar.gz ] || wget -q https://dyncall.org/r$DYNCALL_VER/dyncall-$DYNCALL_VER.tar.gz
    tar xf dyncall-$DYNCALL_VER.tar.gz
fi

# ohos-clang 包装器（嵌 --target/--sysroot）
cat > /tmp/ohos-cc-dc <<CCEOF
#!/bin/bash
exec /usr/bin/ohos-clang --target=aarch64-linux-ohos --sysroot=$OHOS_SYSROOT -L$OHOS_LIBDIR -fuse-ld=lld "\$@"
CCEOF
chmod +x /tmp/ohos-cc-dc

# CMake toolchain 文件：声明交叉到 aarch64 Linux，让 dyncall 选对 arm64 汇编
cat > /tmp/ohos-dyncall-toolchain.cmake <<TCEOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER /tmp/ohos-cc-dc)
set(CMAKE_ASM_COMPILER /tmp/ohos-cc-dc)
set(CMAKE_C_COMPILER_WORKS 1)
set(CMAKE_ASM_COMPILER_WORKS 1)
set(CMAKE_FIND_ROOT_PATH $OHOS_SYSROOT)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
TCEOF

BUILD=$DYNCALL_DIR/ohos-build
rm -rf $BUILD
mkdir -p $BUILD
cd $BUILD

echo ""
echo "[1/2] CMake configure (cross aarch64)..."
cmake .. \
    -DCMAKE_TOOLCHAIN_FILE=/tmp/ohos-dyncall-toolchain.cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_ASM_FLAGS="-fPIC" \
    -DCMAKE_C_FLAGS="-O3 -fPIC -DNDEBUG" \
    >/dev/null

echo ""
echo "[2/2] Building dyncall_s + dyncallback_s + dynload_s..."
cmake --build . --target dyncall_s dyncallback_s dynload_s -j$JOBS

echo ""
echo "============================================"
echo " dyncall build complete; collecting .a"
echo "============================================"
mkdir -p $OUTPUT_DIR
found=0
for a in $(find $BUILD -name 'libdyncall_s.a' -o -name 'libdyncallback_s.a' -o -name 'libdynload_s.a'); do
    cp "$a" $OUTPUT_DIR/
    echo "  $(basename $a)  $(stat -c%s "$a") bytes"
    found=$((found+1))
done
if [ "$found" -lt 3 ]; then
    echo "ERROR: expected 3 .a, found $found"; exit 1
fi
# 校验是 aarch64 目标
echo "--- arch check (libdyncall_s.a first obj) ---"
cd /tmp && rm -f __dc_probe && mkdir -p __dc_probe && cd __dc_probe && ohos-ar x $OUTPUT_DIR/libdyncall_s.a 2>/dev/null && ohos-readelf -h "$(ls *.o | head -1)" 2>/dev/null | grep -E 'Machine|Class' || true
echo "Done. .a in $OUTPUT_DIR"
