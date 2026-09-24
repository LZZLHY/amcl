#!/bin/bash
set -e

# ============================================================
#  rebuild_libjli.sh — 重新编译 libjli.so 并强制导出 JLI_* 符号
#
#  设计理念：
#    - 标准 OpenJDK 用 -fvisibility=hidden 编译 libjli.c，导致 libjava.so
#      链接时无法解析 JLI_Exit / JLI_ExitHook 这些被 hotspot/share/runtime
#      间接 dlsym 的符号。
#    - 我们通过链接器版本脚本（version-script）显式 exports JLI_*。
#
#  用法：
#    JDK_VERSION=17 bash /build/scripts/rebuild_libjli.sh [BUILD_DIR]
#    JDK_VERSION=21 bash /build/scripts/rebuild_libjli.sh
#
#  输入：
#    JDK_VERSION = 17 | 21（默认 17，决定 /build/jdkXXu 路径）
#    可选位置参数：BUILD_DIR（默认自动 find）
#
#  输出：
#    - 覆盖 ${BUILD_DIR}/support/modules_libs/java.base/libjli.so
#    - 同步 cp 到 /output/jdk-libs/libjli.so
#    - 同步 cp 到 ${BUILD_DIR}/images/jdk/lib/libjli.so
# ============================================================

JDK_VERSION=${JDK_VERSION:-17}
JDK_SRC="/build/jdk${JDK_VERSION}u"

if [ ! -d "$JDK_SRC" ]; then
    echo "ERROR: JDK source not found: $JDK_SRC"
    exit 1
fi

echo "=== Rebuilding libjli.so for JDK ${JDK_VERSION} with all OHOS patches ==="

# 自动检测 build 输出目录 (openjdk-target 不同时目录名可能变化)
if [ -n "$1" ] && [ -d "$1" ]; then
    BUILD_DIR=$(find "$1/.." -maxdepth 2 -name "linux-*-server-release" -type d 2>/dev/null | head -1)
    if [ -z "$BUILD_DIR" ]; then
        # User explicitly passed a path; resolve to the linux-*-server-release parent
        BUILD_DIR=$(find "$JDK_SRC/build" -maxdepth 1 -name "linux-*-server-release" -type d | head -1)
    fi
else
    BUILD_DIR=$(find "$JDK_SRC/build" -maxdepth 1 -name "linux-*-server-release" -type d | head -1)
fi
if [ -z "$BUILD_DIR" ]; then
    echo "ERROR: Cannot find build output directory under $JDK_SRC/build/"
    ls "$JDK_SRC/build/" 2>/dev/null
    exit 1
fi
echo "  Build dir: $BUILD_DIR"

# 创建版本脚本，强制导出 JLI_* 符号
# 即使 -fvisibility=hidden，链接器版本脚本优先级更高。
# 注意：JDK 17 有 JLI_Exit / JLI_ExitHook（被我们的 cxxabi_shim 用于 System.exit hook），
# JDK 21 把这两个移除了，jdk21u 的 jli_util.h 已不导出它们。
# 列在 globals 里 + 不存在 = 链接器不会报错（version-script 是 selective export，缺失符号忽略）。
cat > /tmp/libjli_exports.map << 'VERSCRIPT'
{
    global:
        JLI_Launch;
        JLI_Exit;
        JLI_ExitHook;
        JLI_TraceLauncher;
        JLI_ReportErrorMessage;
        JLI_ReportErrorMessageSys;
        JLI_ReportMessage;
        JLI_SetTraceLauncher;
        JLI_MemAlloc;
        JLI_StringDup;
        JLI_List_*;
    local:
        *;
};
VERSCRIPT
echo "  Created linker version script for symbol export"

COMMON_FLAGS="-MMD \
    -I${BUILD_DIR}/support/modules_include/java.base \
    -I${BUILD_DIR}/support/modules_include/java.base/linux \
    -I${JDK_SRC}/src/java.base/share/native/libjava \
    -I${JDK_SRC}/src/java.base/unix/native/libjava \
    -I${JDK_SRC}/src/hotspot/share/include \
    -I${JDK_SRC}/src/hotspot/os/posix/include \
    -pipe -DLIBC=musl -D_GNU_SOURCE -D_REENTRANT -D_LARGEFILE64_SOURCE -DLINUX -DNDEBUG \
    -Wall -Wextra -Wformat=2 -Wpointer-arith -Wsign-compare -Wreorder \
    -Wunused-function -Wundef -Wunused-value -Woverloaded-virtual \
    -std=c99 -fno-strict-aliasing \
    --target=aarch64-linux-ohos --sysroot=/ohos-sysroot-rw -fPIC \
    -D__MUSL__ -DMUSL_LIBC -D_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE -D_LIBCPP_HAS_MUSL_LIBC \
    -I/ohos-sysroot-rw/usr/include/aarch64-linux-ohos \
    -I/build/stub-headers -isystem /usr/lib/llvm-15/include/c++/v1 \
    -B/ohos-sysroot-rw/usr/lib/aarch64-linux-ohos \
    -L/ohos-sysroot-rw/usr/lib/aarch64-linux-ohos \
    -rtlib=compiler-rt -unwindlib=none \
    -D_LITTLE_ENDIAN -DARCH='\"aarch64\"' -Daarch64 -D_LP64=1 \
    -fno-omit-frame-pointer -fPIC -fvisibility=hidden \
    -I${JDK_SRC}/src/java.base/unix/native/libjli \
    -I${JDK_SRC}/src/java.base/share/native/libjli \
    -I${BUILD_DIR}/support/headers/java.base \
    -Wno-unknown-warning-option -Wno-unused-parameter -Wno-unused \
    -Wno-sometimes-uninitialized -Wno-format-nonliteral -Wno-deprecated-non-prototype \
    -O3"

OBJ_DIR=${BUILD_DIR}/support/native/java.base/libjli

# Step 1: Recompile java.c (contains JLI_Exit, JavaMain, etc.)
echo "[1/4] Recompiling java.c..."
/ohos-toolchain/aarch64-linux-ohos-gcc \
    $COMMON_FLAGS \
    -c -o $OBJ_DIR/java.o \
    ${JDK_SRC}/src/java.base/share/native/libjli/java.c
echo "  java.o compiled OK"

# Step 2: Recompile java_md.c (contains GetJREPath, LoadJavaVM, etc.)
echo "[2/4] Recompiling java_md.c..."
/ohos-toolchain/aarch64-linux-ohos-gcc \
    $COMMON_FLAGS \
    -c -o $OBJ_DIR/java_md.o \
    ${JDK_SRC}/src/java.base/unix/native/libjli/java_md.c
echo "  java_md.o compiled OK"

# Step 3: Relink libjli.so
echo "[3/4] Relinking libjli.so..."
/ohos-toolchain/aarch64-linux-ohos-gcc \
    --target=aarch64-linux-ohos --sysroot=/ohos-sysroot-rw \
    -fuse-ld=lld \
    -B/ohos-sysroot-rw/usr/lib/aarch64-linux-ohos \
    -L/ohos-sysroot-rw/usr/lib/aarch64-linux-ohos \
    -rtlib=compiler-rt -unwindlib=none \
    -nostdlib++ -L/output/jdk-libs -lcxxabi_shim \
    -L${BUILD_DIR}/support/modules_libs/java.base \
    -L${BUILD_DIR}/support/modules_libs/java.base/server \
    -shared -Wl,-z,origin -Wl,-rpath,\$ORIGIN -Wl,--disable-new-dtags \
    -Wl,-soname=libjli.so \
    -Wl,--version-script=/tmp/libjli_exports.map \
    -o ${BUILD_DIR}/support/modules_libs/java.base/libjli.so \
    $OBJ_DIR/args.o \
    $OBJ_DIR/java.o \
    $OBJ_DIR/java_md.o \
    $OBJ_DIR/java_md_common.o \
    $OBJ_DIR/jli_util.o \
    $OBJ_DIR/parse_manifest.o \
    $OBJ_DIR/splashscreen_stubs.o \
    $OBJ_DIR/wildcard.o \
    -lz -ldl -lpthread
echo "  libjli.so linked OK"

# Step 4: Copy to output and JDK image
echo "[4/4] Copying to output..."
mkdir -p /output/jdk-libs
cp ${BUILD_DIR}/support/modules_libs/java.base/libjli.so /output/jdk-libs/libjli.so
cp ${BUILD_DIR}/support/modules_libs/java.base/libjli.so ${BUILD_DIR}/images/jdk/lib/libjli.so 2>/dev/null || true

echo ""
echo "=== Done! ==="
ls -la /output/jdk-libs/libjli.so
file /output/jdk-libs/libjli.so
echo ""
echo "Verify exported symbols (must show JLI_Exit and JLI_ExitHook):"
aarch64-linux-ohos-nm -D /output/jdk-libs/libjli.so | grep -i "JLI_Exit" || echo "❌ JLI_Exit NOT in dynamic symbols!"
aarch64-linux-ohos-nm -D /output/jdk-libs/libjli.so | grep -i "JLI_ExitHook" || echo "❌ JLI_ExitHook NOT in dynamic symbols!"
aarch64-linux-ohos-nm -D /output/jdk-libs/libjli.so | grep -i "JLI_Launch" || echo "❌ JLI_Launch NOT in dynamic symbols!"
echo ""
echo "NEEDED dependencies:"
aarch64-linux-ohos-readelf -d /output/jdk-libs/libjli.so | grep NEEDED
