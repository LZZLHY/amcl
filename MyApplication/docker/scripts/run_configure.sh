#!/bin/bash
set -e

source /build/setup_toolchain.sh
export PATH=/ohos-toolchain:$PATH

cd /build/jdk17u

# 修复 WSL 检测 (Docker Desktop 运行在 WSL2 内核上会被误判)
sed -i 's/uname -r | grep -i microsoft/false/' make/autoconf/build-aux/config.guess 2>/dev/null || true

echo "[4/5] Running configure..."

# 确保 Build 编译器也是 clang (OpenJDK 要求 toolchain 一致)
export BUILD_CC=/usr/bin/clang-15
export BUILD_CXX=/usr/bin/clang++-15

# 使用可写 sysroot (setup_toolchain.sh 已导出 OHOS_SYSROOT=/ohos-sysroot-rw)
# libc++ headers 路径 (从 libc++-15-dev 安装)
LIBCXX_INC=/usr/lib/llvm-15/include/c++/v1

COMMON_CFLAGS="--target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} -fPIC -D__MUSL__ -DMUSL_LIBC -D_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE -D_LIBCPP_HAS_MUSL_LIBC -I/build/stub-headers -isystem $LIBCXX_INC"
COMMON_CXXFLAGS="--target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} -fPIC -D__MUSL__ -DMUSL_LIBC -D_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE -D_LIBCPP_HAS_MUSL_LIBC -I/build/stub-headers -stdlib=libc++ -nostdlib++"

bash configure \
    --openjdk-target=aarch64-unknown-linux-musl \
    --with-jvm-variants=server \
    --with-debug-level=release \
    --with-native-debug-symbols=none \
    --with-boot-jdk=/usr/lib/jvm/java-17-openjdk-amd64 \
    --with-extra-cflags="$COMMON_CFLAGS" \
    --with-extra-cxxflags="$COMMON_CXXFLAGS" \
    --with-extra-ldflags="--target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} -fuse-ld=lld -L${OHOS_SYSROOT}/usr/lib/aarch64-linux-ohos -nostdlib++ -L/output/jdk-libs -lcxxabi_shim" \
    --x-includes=/dev/null \
    --x-libraries=/dev/null \
    --with-cups-include=/build/stub-cups \
    --with-freetype=bundled \
    --enable-headless-only \
    --disable-warnings-as-errors \
    --with-toolchain-type=clang \
    CC=aarch64-linux-ohos-gcc \
    CXX=aarch64-linux-ohos-g++ \
    CPP="aarch64-linux-ohos-gcc -E" \
    CXXCPP="aarch64-linux-ohos-g++ -E" \
    BUILD_CC=$BUILD_CC \
    BUILD_CXX=$BUILD_CXX \
    AR=aarch64-linux-ohos-ar \
    STRIP=aarch64-linux-ohos-strip \
    NM=aarch64-linux-ohos-nm \
    OBJCOPY=aarch64-linux-ohos-objcopy

echo ""
echo "Configure completed successfully!"