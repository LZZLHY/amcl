#!/bin/bash
set -e

# ============================================================
#  pack_jdk_full.sh — 打包完整 JDK（含 .so + 数据文件）
#
#  新方案（ELF loader 绕过签名验证）：
#    - 完整 JDK 打包为单个 zip，上传到 GitHub Releases
#    - App 运行时下载到 filesDir/jdk/<version>/
#    - .so 文件通过自定义 ELF loader 加载（不需要版本后缀）
#    - 保留原始目录结构：lib/, lib/server/, conf/, release
#
#  用法 (在 ohos-debug 容器内):
#    JDK_VERSION=17 bash /build/scripts/pack_jdk_full.sh
#    JDK_VERSION=21 bash /build/scripts/pack_jdk_full.sh
#
#  输出:
#    /output/jdk<VER>-ohos-full.zip  — 完整 JDK 运行时包
# ============================================================

JDK_VERSION=${JDK_VERSION:-17}

# 查找 JDK 编译输出目录
JDK_CANDIDATE="/build/jdk${JDK_VERSION}u/build/linux-aarch64-server-release/images/jdk"
if [ ! -d "$JDK_CANDIDATE" ]; then
    JDK_CANDIDATE=$(find /build/jdk${JDK_VERSION}u/build -path "*/images/jdk" -type d 2>/dev/null | head -1)
fi
JDK=${JDK_CANDIDATE}
OUTPUT=/output

echo "=== Pack JDK ${JDK_VERSION} Full (ELF loader mode) ==="
echo "Source: $JDK"

if [ ! -d "$JDK" ]; then
    echo "ERROR: JDK directory not found: $JDK"
    exit 1
fi

# ============================================================
# Step 1: 创建 staging 目录（保留原始目录结构）
# ============================================================
echo ""
echo "[1/4] Creating staging directory..."

STAGING=/tmp/jdk-full-staging
rm -rf $STAGING
mkdir -p $STAGING/lib/server

# lib/ 下所有文件（.so + 非 .so，不加版本后缀！）
for f in $JDK/lib/*; do
    bname=$(basename "$f")
    [ "$bname" = "server" ] && continue  # server 子目录单独处理
    if [ -d "$f" ]; then
        cp -a "$f" "$STAGING/lib/$bname"
    else
        cp "$f" "$STAGING/lib/$bname"
    fi
done

# lib/server/libjvm.so（保留原始路径！）
if [ -f "$JDK/lib/server/libjvm.so" ]; then
    cp "$JDK/lib/server/libjvm.so" "$STAGING/lib/server/libjvm.so"
fi

# conf/
if [ -d "$JDK/conf" ]; then
    cp -a $JDK/conf $STAGING/conf
fi

# release 文件
cp $JDK/release $STAGING/release

# jvm.cfg（保留原始的 server 路径）
cat > $STAGING/lib/jvm.cfg << 'JVMCFG'
-server KNOWN
-client IGNORE
JVMCFG

# ============================================================
# Step 2: 添加 libcxxabi_shim.so
# ============================================================
echo ""
echo "[2/4] Adding libcxxabi_shim.so..."

if [ -f "/output/jdk-libs/libcxxabi_shim.so" ]; then
    cp /output/jdk-libs/libcxxabi_shim.so $STAGING/lib/libcxxabi_shim.so
elif [ -f "/tmp/libcxxabi_shim.so" ]; then
    cp /tmp/libcxxabi_shim.so $STAGING/lib/libcxxabi_shim.so
else
    echo "WARNING: libcxxabi_shim.so not found, building..."
    # 跨依赖共享 shim 源码（2026-05-15 P6.5: prebuilt/stubs/src/ 是 SoT）
    STUBS_SRC_DIR="/stubs-src"
    [ -d "$STUBS_SRC_DIR" ] || STUBS_SRC_DIR="/build/shims"
    /usr/bin/ohos-clang --target=aarch64-linux-ohos --sysroot=/ohos-sysroot-rw \
        -c -fPIC -o /tmp/eh_stubs.o "$STUBS_SRC_DIR/eh_stubs.c"
    /usr/bin/ohos-clang++ --target=aarch64-linux-ohos --sysroot=/ohos-sysroot-rw \
        -shared -fPIC -fvisibility=hidden -fno-exceptions -fno-rtti \
        -o $STAGING/lib/libcxxabi_shim.so "$STUBS_SRC_DIR/cxxabi_shim.cpp" /tmp/eh_stubs.o \
        -fuse-ld=lld -Wl,-soname,libcxxabi_shim.so -nostdlib++ -nodefaultlibs -lc
fi
echo "  ✅ libcxxabi_shim.so added"

# ============================================================
# Step 2.5: libawt_xawt.so stub — REMOVED in v6 (2026-05-19)
# ============================================================
# 历史：v2 加了空 stub 让 OpenJDK 的 java.awt.Toolkit.<clinit> 在
# 非 headless 模式下 System.loadLibrary("awt_xawt") 调用能成功返回。
# v3-v5 又叠加 patch 0009 试图绕开 X11GE。但 jvm_launcher.cpp 同时设了
# -Djava.awt.headless=false（Cacio 模式），prop 优先级高于 platform default，
# patch 完全被绕过；最终崩在 Insets.<clinit>.initIDs（native 在
# --enable-headless-only 编译已不构建的 libawt_xawt.so 内）。
#
# v6 决策：放弃 Cacio，改设 -Djava.awt.headless=true。
# OpenJDK 自带 sun.awt.HeadlessToolkit 接管，所有 AWT 类的 <clinit> 通过
# if (!isHeadless()) 保护跳过 native initIDs() 调用 —— 不需要 stub。
# 而且空 stub 反而让 getDefaultHeadlessProperty 的 auto-detect
# (headlessLib && !xawtLib) 失效。
#
# 详见 docs/archive/jdk21-awt-headless-journey-202605.md §5（第一阶段方案）。
# ============================================================
echo ""
echo "[2.5/4] libawt_xawt.so stub: REMOVED in v6 (real headless mode, no stub needed)"

# ============================================================
# Step 3: 打包为 zip
# ============================================================
echo ""
echo "[3/4] Creating jdk${JDK_VERSION}-ohos-full.zip..."

ZIP_FILE="$OUTPUT/jdk${JDK_VERSION}-ohos-full.zip"
rm -f "$ZIP_FILE"
cd $STAGING
zip -r -q "$ZIP_FILE" .

echo "  Created: $ZIP_FILE"
ls -lh "$ZIP_FILE"

# ============================================================
# Step 4: 验证
# ============================================================
echo ""
echo "[4/4] Verification..."

echo ""
echo "=== Directory structure ==="
find $STAGING -type f | sort | head -40
echo "..."

echo ""
echo "=== .so files ==="
find $STAGING -name "*.so" | sort
echo "Total .so count: $(find $STAGING -name "*.so" | wc -l)"

echo ""
echo "=== Key files ==="
for f in lib/server/libjvm.so lib/libjava.so lib/libjsig.so lib/libzip.so lib/libcxxabi_shim.so release lib/jvm.cfg lib/modules; do
    if [ -f "$STAGING/$f" ]; then
        sz=$(stat -c%s "$STAGING/$f" 2>/dev/null || echo "?")
        echo "  ✅ $f ($sz bytes)"
    else
        echo "  ❌ $f MISSING"
    fi
done

echo ""
echo "=== libjvm.so NEEDED ==="
readelf -d "$STAGING/lib/server/libjvm.so" 2>/dev/null | grep NEEDED | head -10

echo ""
echo "=== Package size ==="
ls -lh "$ZIP_FILE"

echo ""
echo "=== Done ==="
echo "Upload $ZIP_FILE to GitHub Releases"
echo "App will download and extract to filesDir/jdk/${JDK_VERSION}/"
echo "ELF loader will load .so files bypassing code signature"
