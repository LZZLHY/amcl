#!/bin/bash
set -e

# ============================================================
#  FreeType native for HarmonyOS NEXT — Docker 构建脚本
#
#  背景：MC 26.2 起字体后端改用 LWJGL lwjgl-freetype 绑定
#  (org.lwjgl.util.freetype.FreeType)。LWJGL 的 FreeType 绑定不走 per-method JNI，
#  而是 libffi 直接调 FT_* C 符号 —— 实测 LWJGL 官方 arm64 的 libfreetype.so 是
#  **纯 freetype 库**（导出 202 个 FT_* 符号，0 个 Java_ 符号，只 NEED libm/libc）。
#  所以我们这边只需把上游 freetype 交叉编成同样的 libfreetype.so 即可，
#  不需要任何 LWJGL 专属 C 胶水。
#
#  版本：FreeType 2.13.3（与 LWJGL 3.4.1 绑定的版本一致；见 lwjgl3 doc/notes 3.4.0.md）。
#  最小构建：--without-harfbuzz/zlib/png/brotli/bzip2（MC 字体渲染只用 core；
#  freetype 内置 zlib 解 gzip，足够）。
#
#  产物：libfreetype.so（部署到 entry/libs/arm64-v8a/，由 org.lwjgl.freetype.libname 指向）。
#
#  用法：
#    docker exec ohos-debug env FREETYPE_VERSION=2.13.3 \
#      OUTPUT_DIR=/build/planb/natives bash /build/build_freetype_ohos.sh
# ============================================================

OHOS_SYSROOT_ORIG=${OHOS_SYSROOT:-/ohos-sysroot}
WORK_DIR=/build
OUTPUT_DIR=${OUTPUT_DIR:-/output}
JOBS=${JOBS:-$(nproc)}
FREETYPE_VERSION=${FREETYPE_VERSION:-2.13.3}

echo "============================================"
echo " FreeType $FREETYPE_VERSION native for HarmonyOS NEXT"
echo " Output: $OUTPUT_DIR"
echo "============================================"

# --- toolchain (与 build_lwjgl_ohos.sh 同套路) ---
OHOS_SYSROOT=/ohos-sysroot-rw
if [ ! -d "$OHOS_SYSROOT/usr/include" ]; then
    echo "  Copying sysroot to writable location..."
    cp -a "$OHOS_SYSROOT_ORIG" "$OHOS_SYSROOT"
fi
OHOS_LIBDIR=$OHOS_SYSROOT/usr/lib/aarch64-linux-ohos

cat > /tmp/ohos-cc-ft <<CCEOF
#!/bin/bash
exec /usr/bin/ohos-clang --target=aarch64-linux-ohos --sysroot=$OHOS_SYSROOT -L$OHOS_LIBDIR -fuse-ld=lld "\$@"
CCEOF
chmod +x /tmp/ohos-cc-ft
CC=/tmp/ohos-cc-ft

echo "  Compiler: $(/usr/bin/ohos-clang --version 2>&1 | head -1)"

# --- fetch freetype source ---
cd "$WORK_DIR"
FT_DIR="freetype-$FREETYPE_VERSION"
if [ ! -d "$FT_DIR" ]; then
    echo "[1/3] Downloading FreeType $FREETYPE_VERSION..."
    # GNU savannah / sourceforge mirror
    curl -fsSL -m 180 -o "ft.tar.gz" \
        "https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE_VERSION.tar.gz" \
      || curl -fsSL -m 180 -o "ft.tar.gz" \
        "https://downloads.sourceforge.net/project/freetype/freetype2/$FREETYPE_VERSION/freetype-$FREETYPE_VERSION.tar.gz"
    tar xf ft.tar.gz
    rm -f ft.tar.gz
fi
cd "$FT_DIR"

# --- configure: minimal shared build ---
echo "[2/3] Configuring + building (minimal, shared)..."
if [ ! -f ".libs/libfreetype.so" ]; then
    # freetype 用 autotools(builds/unix/configure)。最小依赖：关掉 harfbuzz/png/brotli/bzip2/zlib(用内置)。
    bash ./configure \
        --host=aarch64-linux-ohos \
        --prefix=/usr \
        CC="$CC" \
        --enable-shared \
        --disable-static \
        --without-harfbuzz \
        --without-png \
        --without-brotli \
        --without-bzip2 \
        --without-zlib \
        --with-old-mac-fonts=no
    make -j"$JOBS"
fi

# --- locate + verify + export ---
echo "[3/3] Verifying..."
FT_SO=$(find "$WORK_DIR/$FT_DIR" -name 'libfreetype.so*' -type f | head -1)
if [ -z "$FT_SO" ]; then
    echo "ERROR: libfreetype.so not built!"; exit 1
fi
# strip + 归一化文件名
mkdir -p "$OUTPUT_DIR"
/usr/bin/ohos-strip --strip-unneeded "$FT_SO" 2>/dev/null || true
cp "$FT_SO" "$OUTPUT_DIR/libfreetype.so"

echo "  $(ls -la $OUTPUT_DIR/libfreetype.so)"
echo "  file: $(file $OUTPUT_DIR/libfreetype.so)"
NFT=$(readelf -sW "$OUTPUT_DIR/libfreetype.so" 2>/dev/null | grep -c ' FT_')
echo "  exported FT_* symbols: $NFT (LWJGL 3.4.1 needs 210 required)"
echo "  NEEDED: $(readelf -d "$OUTPUT_DIR/libfreetype.so" 2>/dev/null | grep NEEDED | tr -s ' ' | paste -sd' ')"
echo ""
echo "Done! Copy $OUTPUT_DIR/libfreetype.so to entry/libs/arm64-v8a/"
