#!/bin/bash
set -e

# ============================================================
#  pack_jdk_split.sh — 分离打包 JDK runtime（支持多版本）
#
#  策略：
#    1. .so 文件 → /output/jdk<VER>-libs/ (复制到 entry/libs/arm64-v8a/)
#       文件名添加版本后缀：libjvm.so → libjvm<VER>.so
#       这样 .so 会安装到系统允许 dlopen 的路径
#    2. 非 .so 文件 → /output/jdk<VER>-data.zip (放入 rawfile/)
#       app 首次启动自动解压到 filesDir/jdk/<VER>/
#
#  用法 (在 ohos-debug 容器内):
#    JDK_VERSION=17 bash /build/scripts/pack_jdk_split.sh
#    JDK_VERSION=21 bash /build/scripts/pack_jdk_split.sh
#
#  环境变量：
#    JDK_VERSION — JDK 版本号（默认 17）
#    ADD_VERSION_SUFFIX — 是否添加版本后缀到 .so 文件名（默认 true）
#
#  输出:
#    /output/jdk<VER>-libs/     — 所有 .so 文件（带版本后缀）
#    /output/jdk<VER>-data.zip  — 非 .so 数据文件
# ============================================================

# 从环境变量获取版本号，默认 17
JDK_VERSION=${JDK_VERSION:-17}
ADD_VERSION_SUFFIX=${ADD_VERSION_SUFFIX:-true}

# 根据版本号查找 JDK 编译输出目录
JDK_CANDIDATE="/build/jdk${JDK_VERSION}u/build/linux-aarch64-server-release/images/jdk"
if [ ! -d "$JDK_CANDIDATE" ]; then
    # 自动检测 (openjdk-target 不同时目录名可能变化)
    JDK_CANDIDATE=$(find /build/jdk${JDK_VERSION}u/build -path "*/images/jdk" -type d 2>/dev/null | head -1)
fi
JDK=${JDK_CANDIDATE}
OUTPUT=/output

echo "=== Pack JDK ${JDK_VERSION} Split (libs + data) ==="
echo "Source: $JDK"
echo "Version suffix: $ADD_VERSION_SUFFIX"

if [ ! -d "$JDK" ]; then
    echo "ERROR: JDK directory not found: $JDK"
    exit 1
fi

# ============================================================
# Step 1: 创建 libcxxabi_shim.so (C++ 版本，提供 std::nothrow)
# ============================================================
echo ""
echo "[1/6] Creating libcxxabi_shim.so (C++ with std::nothrow)..."

# 使用项目中的 C++ shim 源码（2026-05-15 P6.5: prebuilt/stubs/src/ 是 SoT）
STUBS_SRC_DIR="/stubs-src"
[ -d "$STUBS_SRC_DIR" ] || STUBS_SRC_DIR="/build/shims"   # legacy fallback
cp "$STUBS_SRC_DIR/cxxabi_shim.cpp" /tmp/cxxabi_shim.cpp
cp "$STUBS_SRC_DIR/eh_stubs.c" /tmp/eh_stubs.c

# 编译 eh_stubs.c (C 文件，提供 __gxx_personality_v0, operator new/delete 等)
/usr/bin/ohos-clang --target=aarch64-linux-ohos --sysroot=/ohos-sysroot-rw \
    -c -fPIC -o /tmp/eh_stubs.o /tmp/eh_stubs.c

# 编译为 C++，-fvisibility=hidden 全局隐藏，源码中用 SHIM_EXPORT 选择性导出
# -fno-exceptions -fno-rtti 避免引入 __gxx_personality_v0 / _ZSt9terminatev 依赖
/usr/bin/ohos-clang++ --target=aarch64-linux-ohos --sysroot=/ohos-sysroot-rw \
    -shared -fPIC -fvisibility=hidden -fno-exceptions -fno-rtti \
    -o /tmp/libcxxabi_shim.so /tmp/cxxabi_shim.cpp /tmp/eh_stubs.o \
    -fuse-ld=lld -Wl,-soname,libcxxabi_shim.so -nostdlib++ -nodefaultlibs -lc

echo "  Created libcxxabi_shim.so"
echo "  Exported symbols:"
nm -D /tmp/libcxxabi_shim.so | grep " T " | head -20
echo "  Checking _ZSt7nothrow:"
nm -D /tmp/libcxxabi_shim.so | grep nothrow || echo "  WARNING: nothrow not found!"

# ============================================================
# Step 2: 收集所有 .so 文件到 jdk<VER>-libs/
# ============================================================
echo ""
echo "[2/6] Collecting .so files..."

LIBS_DIR=$OUTPUT/jdk${JDK_VERSION}-libs
rm -rf $LIBS_DIR
mkdir -p $LIBS_DIR

# 辅助函数：根据配置决定是否添加版本后缀
add_suffix() {
    local name=$1
    if [ "$ADD_VERSION_SUFFIX" = "true" ]; then
        # libfoo.so → libfoo<VER>.so
        echo "${name%.so}${JDK_VERSION}.so"
    else
        echo "$name"
    fi
}

# 复制 shim（共用，不加版本后缀）
cp /tmp/libcxxabi_shim.so $LIBS_DIR/libcxxabi_shim.so

# 复制 lib/ 下的 .so（添加版本后缀）
for f in $JDK/lib/*.so; do
    bname=$(basename "$f")
    newname=$(add_suffix "$bname")
    cp "$f" "$LIBS_DIR/$newname"
done

# 复制 lib/server/libjvm.so (扁平化，不保留 server/ 子目录)
if [ -f "$JDK/lib/server/libjvm.so" ]; then
    newname=$(add_suffix "libjvm.so")
    cp "$JDK/lib/server/libjvm.so" "$LIBS_DIR/$newname"
fi

echo "  Collected .so files (with version suffix: $ADD_VERSION_SUFFIX):"
ls $LIBS_DIR/ | head -20
echo "  ..."

# ============================================================
# Step 3: 验证 .so 文件 (编译时已链接 libcxxabi_shim.so，无需 patchelf)
# ============================================================
echo ""
echo "[3/6] Verifying .so files (no patchelf needed — linked at compile time)..."

# 验证 libjvm.so 已有 shim 依赖
LIBJVM_NAME=$(add_suffix "libjvm.so")
if [ -f "$LIBS_DIR/$LIBJVM_NAME" ]; then
    if readelf -d "$LIBS_DIR/$LIBJVM_NAME" 2>/dev/null | grep -q cxxabi_shim; then
        echo "  ✅ $LIBJVM_NAME: libcxxabi_shim.so in NEEDED (compile-time)"
    else
        echo "  ⚠️ $LIBJVM_NAME: missing libcxxabi_shim.so — adding via patchelf"
        patchelf --add-needed libcxxabi_shim.so "$LIBS_DIR/$LIBJVM_NAME"
    fi
fi

# ============================================================
# Step 4: 验证 RPATH (扁平化后所有 .so 在同一目录)
# ============================================================
echo ""
echo "[4/6] Checking RPATH..."

# libjvm.so 原来在 lib/server/，现在扁平化到同一目录
# 如果没有 RPATH 或 RPATH 不是 $ORIGIN，不需要修改
# HarmonyOS 的 ndk namespace 会自动搜索 app 的 native lib 目录
if [ -f "$LIBS_DIR/$LIBJVM_NAME" ]; then
    rpath=$(patchelf --print-rpath "$LIBS_DIR/$LIBJVM_NAME" 2>/dev/null || true)
    echo "  $LIBJVM_NAME RPATH: ${rpath:-'(none)'}"
fi

# ============================================================
# Step 5: 打包非 .so 数据文件为 jdk<VER>-data.zip
# ============================================================
echo ""
echo "[5/6] Creating jdk${JDK_VERSION}-data.zip (non-.so files)..."

DATA_STAGING=/tmp/jdk-data-staging
rm -rf $DATA_STAGING
mkdir -p $DATA_STAGING

# lib/ 下的非 .so 文件 (modules, jvm.cfg, tzdb.dat, etc.)
mkdir -p $DATA_STAGING/lib
for f in $JDK/lib/*; do
    bname=$(basename "$f")
    # 跳过 .so 文件
    echo "$bname" | grep -q '\.so$' && continue
    # 跳过 server/ 目录 (libjvm.so 已经扁平化了)
    [ "$bname" = "server" ] && continue
    if [ -d "$f" ]; then
        cp -a "$f" "$DATA_STAGING/lib/$bname"
    else
        cp "$f" "$DATA_STAGING/lib/$bname"
    fi
done

# 创建一个 jvm.cfg 指向扁平化的 libjvm.so
# 原始 jvm.cfg 指向 -server KNOWN (lib/server/libjvm.so)
# 我们需要让 JVM 知道 libjvm.so 在同一目录
cat > $DATA_STAGING/lib/jvm.cfg << 'JVMCFG'
-server KNOWN
-client IGNORE
JVMCFG

# conf/ 目录
cp -a $JDK/conf $DATA_STAGING/conf

# release 文件
cp $JDK/release $DATA_STAGING/release

echo "  Data staging contents:"
find $DATA_STAGING -type f | head -30
echo "  ..."

# 打包
DATA_ZIP="$OUTPUT/jdk${JDK_VERSION}-data.zip"
rm -f "$DATA_ZIP"
cd $DATA_STAGING
zip -r -q "$DATA_ZIP" .

echo "  Created jdk${JDK_VERSION}-data.zip"
ls -lh "$DATA_ZIP"

# ============================================================
# Step 6: 验证
# ============================================================
echo ""
echo "[6/6] Verification..."

echo ""
echo "=== .so files (for entry/libs/arm64-v8a/) ==="
ls -lh $LIBS_DIR/ | head -40
echo ""
echo "Total .so count: $(ls $LIBS_DIR/*.so | wc -l)"
echo "Total .so size: $(du -sh $LIBS_DIR | cut -f1)"

echo ""
echo "=== Data files (for GitHub Releases) ==="
ls -lh "$DATA_ZIP"

echo ""
echo "=== Key file checks ==="
# 检查关键 .so 文件（使用版本后缀）
for base in libjvm libjava libjsig libzip; do
    f=$(add_suffix "${base}.so")
    if [ -f "$LIBS_DIR/$f" ]; then
        sz=$(stat -c%s "$LIBS_DIR/$f" 2>/dev/null || echo "?")
        echo "  ✅ $f ($sz bytes)"
        # 检查 NEEDED
        readelf -d "$LIBS_DIR/$f" 2>/dev/null | grep NEEDED | head -5 | sed 's/^/     /'
    else
        echo "  ❌ $f MISSING"
    fi
done
# libcxxabi_shim.so 不加版本后缀
if [ -f "$LIBS_DIR/libcxxabi_shim.so" ]; then
    sz=$(stat -c%s "$LIBS_DIR/libcxxabi_shim.so" 2>/dev/null || echo "?")
    echo "  ✅ libcxxabi_shim.so ($sz bytes)"
else
    echo "  ❌ libcxxabi_shim.so MISSING"
fi

echo ""
echo "=== $LIBJVM_NAME details ==="
readelf -d "$LIBS_DIR/$LIBJVM_NAME" 2>/dev/null | grep -E "NEEDED|RPATH|RUNPATH"

echo ""
echo "=== Done ==="
echo "JDK Version: $JDK_VERSION"
echo "Version suffix enabled: $ADD_VERSION_SUFFIX"
echo ""
echo "Next steps:"
echo "  1. Copy $LIBS_DIR/*.so to entry/libs/arm64-v8a/"
echo "  2. Upload $DATA_ZIP to GitHub Releases"
echo ""
echo "For multi-version support, .so files are named:"
echo "  libjvm${JDK_VERSION}.so, libjava${JDK_VERSION}.so, etc."
