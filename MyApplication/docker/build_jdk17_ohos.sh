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
# 统一产物身份：配方、打包和收尾检查共用本次请求的新文件名。
export JDK_OUTPUT="${JDK_OUTPUT:-/output/jdk17-ohos-${AMCL_RUN_ID:-candidate}.zip}"
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

python3 /build/scripts/prepare_jdk_source.py 17
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
python3 /build/scripts/apply_jdk_patches.py --patch-dir "$PATCH_DIR" --target /build/jdk17u
# 对本版本的完整上游协议文件复核；撤销补丁编号本身不能阻止改名绕过回生。
python3 /build/scripts/verify_jdk25_safepoint.py --major 17 --source /build/jdk17u \
    --patch-dir "$PATCH_DIR" --inputs /prebuilt/jdk/build-inputs.json

# --- Step 5: Configure ---
echo ""
echo "[5/7] Running configure..."

# 链接真实应用 ABI；兼容外壳只保留 SONAME，不定义 guard/EH/RTTI。
ARCH_INCLUDE="-I${OHOS_SYSROOT}/usr/include/aarch64-linux-ohos"
bash /build/scripts/prepare_jdk_abi.sh 17 /output/jdk-libs

export BUILD_CC=/usr/bin/clang-15
export BUILD_CXX=/usr/bin/clang++-15

LIBCXX_INC=${AMCL_JDK_CXX_INCLUDE:?}

COMMON_CFLAGS="${AMCL_JDK_RESOURCE_FLAG} --target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} -fPIC -D__OHOS__=1 -D__OHOS_FAMILY__=1 -D__OHOS_Major__=0 -D__MUSL__ -DMUSL_LIBC -I/build/stub-headers -isystem $LIBCXX_INC"
COMMON_CXXFLAGS="${AMCL_JDK_RESOURCE_FLAG} --target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} -fPIC -D__OHOS__=1 -D__OHOS_FAMILY__=1 -D__OHOS_Major__=0 -D__MUSL__ -DMUSL_LIBC -I/build/stub-headers -isystem $LIBCXX_INC -stdlib=libc++ -nostdlib++ -nostdinc++"

# 固定上游源码时间，避免构建时间成为未登记输入。
export SOURCE_DATE_EPOCH="$(git log -1 --format=%ct)"
# test-image默认不会带gtest；显式配置真实框架，不能导出空清单后声称已接入。
test_configure=()
if [ "${AMCL_JDK_TEST_IMAGE:-0}" = 1 ]; then
    python3 /build/scripts/prepare_gtest.py --source /build/upstream-googletest --receipt /build/upstream-googletest.json
    test_configure+=(--with-gtest=/build/upstream-googletest)
fi
bash configure "${test_configure[@]}" \
    --openjdk-target=aarch64-unknown-linux-musl \
    --with-jvm-variants=server \
    --with-debug-level=release \
    --with-native-debug-symbols=none \
    --with-boot-jdk=$JAVA_HOME \
    --with-extra-cflags="$COMMON_CFLAGS" \
    --with-extra-cxxflags="$COMMON_CXXFLAGS" \
    --with-extra-ldflags="--target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} -fuse-ld=lld -L${OHOS_SYSROOT}/usr/lib/aarch64-linux-ohos -nostdlib++ -L/output/jdk-libs -lcxxabi_shim -lc++_shared" \
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
# 上游 native/gtest 只在显式资格请求中编译，保持正常 JDK 增量构建范围。
build_targets=(images)
if [ "${AMCL_JDK_TEST_IMAGE:-0}" = 1 ]; then build_targets+=(test-image); fi
gmake "${build_targets[@]}" JOBS=$JOBS 2>&1 | tee /build/build.log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "BUILD FAILED! Last 50 lines:"
    tail -50 /build/build.log
    exit 1
fi

# --- 输出产物 ---
IMAGE_DIR=/build/jdk17u/build/linux-aarch64-server-release/images/jdk

if [ ! -f "$IMAGE_DIR/release" ] || [ ! -f "$IMAGE_DIR/lib/modules" ]; then
    echo "ERROR: Build output not found"
    exit 1
fi

echo ""
echo "============================================"
echo " BUILD SUCCESSFUL!"
echo " JDK:     $IMAGE_DIR"
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

# 最终运行包由统一入口生成；不再额外复制整棵开发 image 到输出目录。

# ABI 库在 configure 前已经从冻结 SDK 构建并验证，无需重新生成。

# --- Post-build Step 2: 重编 libjli.so (含 exit 拦截 + 符号导出) ---
echo ""
echo "[Post-2] Rebuilding libjli.so with exit interception patches..."
bash /build/scripts/rebuild_libjli.sh

# --- Post-build Step 3: 验证并打包完整运行时 ---
echo ""
echo "[Post-3] Packing validated JDK runtime..."
JDK_VERSION=17 bash /build/scripts/pack_jdk_full.sh

echo ""
echo "============================================"
echo " FULL BUILD PIPELINE COMPLETE!"
echo " .so files: /output/jdk-libs/"
echo " Runtime zip: $JDK_OUTPUT"
echo "============================================"
