#!/bin/bash
set -e

# ============================================================
#  OpenJDK 17 for HarmonyOS NEXT — Docker 一键编译脚本
#  使用系统 clang-15 + OHOS NDK sysroot 交叉编译
#
#  用法:
#    docker run --rm \
#      -v "/path/to/ohos/sysroot:/ohos-sysroot:ro" \
#      -v "/path/to/output:/output" \
#      openjdk-ohos-builder /build/build_jdk17_ohos.sh
# ============================================================

OHOS_SYSROOT=${OHOS_SYSROOT:-/ohos-sysroot}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-/ohos-toolchain}
WORK_DIR=/build
JOBS=${JOBS:-$(nproc)}
JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}

echo "============================================"
echo " OpenJDK 17u for HarmonyOS NEXT (aarch64)"
echo " Sysroot:  $OHOS_SYSROOT"
echo " Boot JDK: $JAVA_HOME"
echo " Jobs:     $JOBS"
echo "============================================"

# --- Step 1: 设置工具链 ---
echo ""
echo "[1/7] Setting up toolchain..."
source /build/setup_toolchain.sh
export PATH=$TOOLCHAIN_DIR:$PATH

# --- Step 2: 克隆 JDK 17u ---
echo ""
echo "[2/7] Cloning OpenJDK 17u..."
cd $WORK_DIR

if [ ! -d "jdk17u" ]; then
    git clone --depth 1 https://github.com/openjdk/jdk17u.git jdk17u
    echo "Clone complete."
else
    echo "Source already exists, skipping clone."
fi

cd jdk17u

# --- Step 3: 安装 stub 头文件 ---
echo ""
echo "[3/7] Installing stub headers from stubs/ directory..."

# CUPS stubs → /build/stub-cups/（configure --with-cups-include 指向这里）
cp -r /build/stubs/cups /build/stub-cups
echo "  CUPS stubs installed"

# Fontconfig + X11 stubs → /build/stub-headers/（-I/build/stub-headers）
mkdir -p /build/stub-headers
cp -r /build/stubs/fontconfig/* /build/stub-headers/
cp -r /build/stubs/x11/* /build/stub-headers/
echo "  Fontconfig + X11 stubs installed"

# ALSA headers (copy from host system — not in stubs/ because they are host-dependent)
if [ -d /usr/include/alsa ]; then
    mkdir -p /build/stub-headers/alsa
    cp -r /usr/include/alsa/* /build/stub-headers/alsa/
    echo "  ALSA headers copied from host"
fi

# ALSA stub library (for linking)
if [ ! -f "${OHOS_SYSROOT}/usr/lib/aarch64-linux-ohos/libasound.so" ]; then
    echo 'void snd_stub(void) {}' > /tmp/asound_stub.c
    /usr/bin/ohos-clang --target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} \
        -fuse-ld=lld -shared -o ${OHOS_SYSROOT}/usr/lib/aarch64-linux-ohos/libasound.so /tmp/asound_stub.c
    echo "  libasound.so stub created"
fi

echo "  All stubs ready"

# --- Step 4: 应用源码补丁 ---
echo ""
echo "[4/7] Applying source patches..."

# 修复 WSL 检测 (Docker Desktop 运行在 WSL2 内核上会被误判)
sed -i 's/uname -r | grep -i microsoft/false/' make/autoconf/build-aux/config.guess 2>/dev/null || true

# Patch / shim 来源（2026-05-15 P6.5: 改读 mount 进来的 prebuilt/jdk/17/）
#   /jdk-spec/patches/  ← prebuilt/jdk/17/patches/  (4 个 series patch)
#   /jdk-spec/shims/    ← prebuilt/jdk/17/shims/    (icache_patch.hpp)
#   /stubs-src/         ← prebuilt/stubs/src/       (cxxabi_shim.cpp + eh_stubs.c)
# Legacy fallback: /build/patches/jdk17u + /build/shims（兼容旧 docker run 调用）
JDK_SPEC_DIR="/jdk-spec"
STUBS_SRC_DIR="/stubs-src"
if [ -d "$JDK_SPEC_DIR/patches" ]; then
    PATCH_DIR="$JDK_SPEC_DIR/patches"
    SHIMS_DIR="$JDK_SPEC_DIR/shims"
elif [ -d "/build/patches/jdk17u" ]; then
    echo "  (legacy mount layout: using /build/patches/jdk17u)"
    PATCH_DIR="/build/patches/jdk17u"
    SHIMS_DIR="/build/shims"
else
    echo "ERROR: no patches found at /jdk-spec/patches or /build/patches/jdk17u" >&2
    echo "       mount prebuilt/jdk/17 to /jdk-spec, e.g.:" >&2
    echo "       -v \$(pwd)/prebuilt/jdk/17:/jdk-spec:ro" >&2
    exit 1
fi
if [ ! -d "$STUBS_SRC_DIR" ] && [ -d "/build/shims" ]; then
    STUBS_SRC_DIR="/build/shims"   # legacy fallback
fi
echo "  patches: $PATCH_DIR"
echo "  shims:   $SHIMS_DIR"
echo "  stubs:   $STUBS_SRC_DIR"

# 使用统一补丁系统应用所有源码补丁
bash /build/apply_patches.sh --patch-dir "$PATCH_DIR" --target /build/jdk17u

# --- Step 5: Configure ---
echo ""
echo "[5/7] Running configure..."

# 预先创建 libcxxabi_shim.so (configure 链接测试需要)
echo "  Pre-creating libcxxabi_shim.so for link tests..."
mkdir -p /output/jdk-libs
/usr/bin/ohos-clang --target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} \
    -c -fPIC -o /tmp/eh_stubs.o "$STUBS_SRC_DIR/eh_stubs.c"
/usr/bin/ohos-clang++ --target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} \
    -shared -fPIC -fvisibility=hidden -fno-exceptions -fno-rtti \
    -o /output/jdk-libs/libcxxabi_shim.so "$STUBS_SRC_DIR/cxxabi_shim.cpp" /tmp/eh_stubs.o \
    -fuse-ld=lld -Wl,-soname,libcxxabi_shim.so -nostdlib++ -nodefaultlibs -lc
echo "  libcxxabi_shim.so ready"

export BUILD_CC=/usr/bin/clang-15
export BUILD_CXX=/usr/bin/clang++-15

LIBCXX_INC=/usr/lib/llvm-15/include/c++/v1

COMMON_CFLAGS="--target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} -fPIC -D__MUSL__ -DMUSL_LIBC -D_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE -D_LIBCPP_HAS_MUSL_LIBC -I/build/stub-headers -isystem $LIBCXX_INC"
COMMON_CXXFLAGS="--target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} -fPIC -D__MUSL__ -DMUSL_LIBC -D_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE -D_LIBCPP_HAS_MUSL_LIBC -I/build/stub-headers -stdlib=libc++ -nostdlib++"

bash configure \
    --openjdk-target=aarch64-unknown-linux-musl \
    --with-jvm-variants=server \
    --with-debug-level=release \
    --with-native-debug-symbols=none \
    --with-boot-jdk=$JAVA_HOME \
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
    OBJCOPY=aarch64-linux-ohos-objcopy \
    2>&1 | tee /build/configure.log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "CONFIGURE FAILED! See /build/configure.log"
    exit 1
fi
echo "  Configure complete"

# --- Step 6: Build ---
echo ""
echo "[6/7] Building (JOBS=$JOBS)..."
gmake images JOBS=$JOBS 2>&1 | tee /build/build.log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "BUILD FAILED! Last 50 lines:"
    tail -50 /build/build.log
    exit 1
fi

# --- 输出产物 ---
IMAGE_DIR=$(find build -path "*/images/jdk" -type d 2>/dev/null | head -1)

if [ -z "$IMAGE_DIR" ]; then
    echo "ERROR: Build output not found"
    exit 1
fi

echo ""
echo "============================================"
echo " BUILD SUCCESSFUL!"
echo " JDK:     $WORK_DIR/jdk17u/$IMAGE_DIR"
echo " Version: $(cat $IMAGE_DIR/release | grep JAVA_VERSION= | head -1)"
echo "============================================"
du -sh $IMAGE_DIR
echo ""
echo "Key .so files:"
find $IMAGE_DIR -name "*.so" | head -20
echo ""
echo "Verify ELF format:"
file $(find $IMAGE_DIR -name "libjvm.so" | head -1)
echo ""
echo "NEEDED libraries (libjvm.so):"
readelf -d $(find $IMAGE_DIR -name "libjvm.so" | head -1) | grep NEEDED

# 复制到输出目录
if [ -d /output ]; then
    mkdir -p /output
    cp -r $IMAGE_DIR/* /output/
    echo ""
    echo "Output copied to /output/"
    du -sh /output/
fi

# --- Post-build Step 1: 创建 libcxxabi_shim.so (供 rebuild_libjli 链接) ---
echo ""
echo "[Post-1] Creating libcxxabi_shim.so..."
mkdir -p /output/jdk-libs
/usr/bin/ohos-clang --target=aarch64-linux-ohos --sysroot=/ohos-sysroot-rw \
    -c -fPIC -o /tmp/eh_stubs.o "$STUBS_SRC_DIR/eh_stubs.c"
/usr/bin/ohos-clang++ --target=aarch64-linux-ohos --sysroot=/ohos-sysroot-rw \
    -shared -fPIC -fvisibility=hidden -fno-exceptions -fno-rtti \
    -o /output/jdk-libs/libcxxabi_shim.so "$STUBS_SRC_DIR/cxxabi_shim.cpp" /tmp/eh_stubs.o \
    -fuse-ld=lld -Wl,-soname,libcxxabi_shim.so -nostdlib++ -nodefaultlibs -lc
echo "  libcxxabi_shim.so created (with eh_stubs)"

# --- Post-build Step 2: 重编 libjli.so (含 exit 拦截 + 符号导出) ---
echo ""
echo "[Post-2] Rebuilding libjli.so with exit interception patches..."
bash /build/scripts/rebuild_libjli.sh

# --- Post-build Step 3: 分离打包 (libs + data) ---
echo ""
echo "[Post-3] Packing JDK split (libs + data)..."
bash /build/scripts/pack_jdk_split.sh

echo ""
echo "============================================"
echo " FULL BUILD PIPELINE COMPLETE!"
echo " .so files: /output/jdk-libs/"
echo " Data zip:  /output/jdk-data.zip"
echo "============================================"
