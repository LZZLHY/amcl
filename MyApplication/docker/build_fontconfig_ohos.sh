#!/bin/bash
set -e

# ============================================================
#  build_fontconfig_ohos.sh — 交叉编译 libfontconfig.so for OHOS aarch64
# ============================================================

WORK=/tmp/fontconfig-build
OUTPUT=/output
SYSROOT=/ohos-sysroot-rw
TARGET=aarch64-linux-ohos

echo "=== Build fontconfig for OHOS aarch64 ==="
rm -rf $WORK
mkdir -p $WORK $OUTPUT

# ============================================================
# Step 1: 编译 libexpat
# ============================================================
echo ""
echo "[1/3] Building libexpat..."

EXPAT_VER="2.6.2"
EXPAT_INSTALL=$WORK/expat-install
cd $WORK
wget -q "https://github.com/libexpat/libexpat/releases/download/R_${EXPAT_VER//./_}/expat-${EXPAT_VER}.tar.gz"
tar xzf expat-${EXPAT_VER}.tar.gz
cd expat-${EXPAT_VER}

mkdir -p $EXPAT_INSTALL

CC="ohos-clang --target=$TARGET --sysroot=$SYSROOT" \
CFLAGS="-fPIC -O2" \
LDFLAGS="-fuse-ld=lld" \
./configure \
    --host=aarch64-linux \
    --prefix=$EXPAT_INSTALL \
    --enable-shared \
    --disable-static \
    --without-docbook \
    --without-tests \
    --without-examples \
    2>&1 | tail -5

make -j$(nproc) 2>&1 | tail -3
make install 2>&1 | tail -3

echo "  ✅ libexpat:"
ls -lh $EXPAT_INSTALL/lib/libexpat.so*
file $EXPAT_INSTALL/lib/libexpat.so

# ============================================================
# Step 2: 编译 libfontconfig
# ============================================================
echo ""
echo "[2/3] Building libfontconfig..."

FC_VER="2.14.2"
FC_INSTALL=$WORK/fc-install
cd $WORK
wget -q "https://www.freedesktop.org/software/fontconfig/release/fontconfig-${FC_VER}.tar.gz"
tar xzf fontconfig-${FC_VER}.tar.gz
cd fontconfig-${FC_VER}

mkdir -p $FC_INSTALL

# fontconfig 需要 freetype 和 expat
# freetype 头文件用 host 的，链接时不需要（运行时 JDK 自带）
# expat 用刚编译的

CC="ohos-clang --target=$TARGET --sysroot=$SYSROOT" \
CFLAGS="-fPIC -O2 -I$EXPAT_INSTALL/include" \
LDFLAGS="-fuse-ld=lld -L$EXPAT_INSTALL/lib -L/output/jdk-libs" \
FREETYPE_CFLAGS="-I/usr/include/freetype2 -I/usr/include/libpng16" \
FREETYPE_LIBS="-L/output/jdk-libs -lfreetype" \
EXPAT_CFLAGS="-I$EXPAT_INSTALL/include" \
EXPAT_LIBS="-L$EXPAT_INSTALL/lib -lexpat" \
PKG_CONFIG_PATH="$EXPAT_INSTALL/lib/pkgconfig" \
./configure \
    --host=aarch64-linux \
    --prefix=$FC_INSTALL \
    --enable-shared \
    --disable-static \
    --disable-docs \
    --disable-cache-build \
    --with-default-fonts=/system/fonts \
    --with-cache-dir=/data/local/tmp/fontconfig-cache \
    ac_cv_func_fstatfs=no \
    ac_cv_func_fstatvfs=no \
    2>&1 | tail -10

# 只编译库，不编译工具
make -C src -j$(nproc) 2>&1 | tail -5
make -C src install 2>&1 | tail -3

echo "  ✅ libfontconfig:"
ls -lh $FC_INSTALL/lib/libfontconfig.so*
file $FC_INSTALL/lib/libfontconfig.so

# ============================================================
# Step 3: 复制产物并验证
# ============================================================
echo ""
echo "[3/3] Copying to output..."

# 复制实际文件（解引用符号链接）
cp -L $(ls $FC_INSTALL/lib/libfontconfig.so.1.* 2>/dev/null | head -1 || echo $FC_INSTALL/lib/libfontconfig.so.1) $OUTPUT/libfontconfig.so.1
cp -L $(ls $EXPAT_INSTALL/lib/libexpat.so.1.* 2>/dev/null | head -1 || echo $EXPAT_INSTALL/lib/libexpat.so.1) $OUTPUT/libexpat.so.1

echo ""
echo "=== Verification ==="
echo "libfontconfig.so.1:"
file $OUTPUT/libfontconfig.so.1
ls -lh $OUTPUT/libfontconfig.so.1
readelf -d $OUTPUT/libfontconfig.so.1 | grep NEEDED
echo ""
echo "libexpat.so.1:"
file $OUTPUT/libexpat.so.1
ls -lh $OUTPUT/libexpat.so.1
readelf -d $OUTPUT/libexpat.so.1 | grep NEEDED
echo ""
echo "=== Done ==="
