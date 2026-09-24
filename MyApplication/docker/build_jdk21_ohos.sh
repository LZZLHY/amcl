#!/bin/bash
set -e

# ============================================================
#  OpenJDK 21u for HarmonyOS NEXT — Docker 一键编译脚本
#  使用系统 clang-15 + OHOS NDK sysroot 交叉编译
#
#  状态 (2026-05-18): JDK 21 上线编译路径
#  - 8 个 OHOS 真 patch（与 17 同构，由 docker/port_jdk21_patches.sh 生成）
#  - 默认上游：jdk21u jdk-21.0.5+11 (commit dfcd8d2ee)
#  - 输出：/output/jdk21-ohos-full.zip（与 17 的 jdk17-ohos-full-v4.zip 同构）
#  - 严格对齐 build_jdk17_ohos.sh，仅替换版本号 + boot JDK 21
#
#  用法:
#    docker run --rm \
#      -v "/path/to/ohos/sysroot:/ohos-sysroot:ro" \
#      -v "/path/to/output:/output" \
#      -v "$(pwd)/prebuilt/jdk/21:/jdk21-spec:ro" \
#      -v "$(pwd)/prebuilt/stubs:/stubs-src:ro" \
#      openjdk-ohos-builder /build/build_jdk21_ohos.sh
#
#  ⚠️ /ohos-sysroot 必须 RW 挂载（脚本会写 libasound.so 进去），
#     否则跑前先 cp -a 到一份 RW 副本作为 OHOS_SYSROOT。
#
#  ⚠️ 容器内必须存在 Huawei NDK 的 aarch64-linux-ohos compiler-rt。
#     从 Huawei DevEco SDK 拷贝：
#       <DevEco>/sdk/default/openharmony/native/llvm/lib/clang/15.0.4/lib/aarch64-linux-ohos/
#         libclang_rt.builtins.a → /usr/lib/llvm-15/lib/clang/15.0.7/lib/linux/libclang_rt.builtins-aarch64.a
#         clang_rt.crtbegin.o   → /usr/lib/llvm-15/lib/clang/15.0.7/lib/linux/clang_rt.crtbegin-aarch64.o
#         clang_rt.crtend.o     → /usr/lib/llvm-15/lib/clang/15.0.7/lib/linux/clang_rt.crtend-aarch64.o
#     缺少这些 ld.lld 会找不到 libgcc / crtbeginS.o，整个 configure 失败。
# ============================================================

OHOS_SYSROOT=${OHOS_SYSROOT:-/ohos-sysroot}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-/ohos-toolchain}
WORK_DIR=/build
JOBS=${JOBS:-$(nproc)}

# Boot JDK：JDK 21 build 通常需要 JDK 20+，必须强制用 Temurin 21（如果存在）
# 注意：Dockerfile 把 JAVA_HOME export 成了 JDK 17，所以这里不能依赖 ${JAVA_HOME:-...}
unset JAVA_HOME
if [ -d "/usr/lib/jvm/temurin-21-jdk-amd64" ]; then
    JAVA_HOME=/usr/lib/jvm/temurin-21-jdk-amd64
elif [ -d "/usr/lib/jvm/java-21-openjdk-amd64" ]; then
    JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
else
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
    echo "WARNING: Falling back to JDK 17 as boot JDK; configure may reject it for jdk21u."
fi
export JAVA_HOME

echo "============================================"
echo " OpenJDK 21u for HarmonyOS NEXT (aarch64)"
echo " Sysroot:  $OHOS_SYSROOT"
echo " Boot JDK: $JAVA_HOME"
echo " Jobs:     $JOBS"
echo "============================================"

# ============================================================
# /ohos-sysroot 必须可写（要往 usr/lib/aarch64-linux-ohos/libasound.so 写）
# 实际部署中 /ohos-sysroot 是 RO 挂载；如果是 RO 就 cp 一份 RW 副本到
# /ohos-sysroot-rw 后切过去用。
# ============================================================
if [ ! -w "$OHOS_SYSROOT/usr/lib/aarch64-linux-ohos" ] 2>/dev/null \
   || ! touch "$OHOS_SYSROOT/.amcl_rw_test" 2>/dev/null; then
    OHOS_SYSROOT_RW=/ohos-sysroot-rw
    if [ ! -d "$OHOS_SYSROOT_RW" ]; then
        echo "  /ohos-sysroot is RO, creating RW copy at $OHOS_SYSROOT_RW..."
        cp -a "$OHOS_SYSROOT" "$OHOS_SYSROOT_RW"
    fi
    OHOS_SYSROOT="$OHOS_SYSROOT_RW"
    echo "  Switched to writable sysroot: $OHOS_SYSROOT"
else
    rm -f "$OHOS_SYSROOT/.amcl_rw_test" 2>/dev/null || true
fi

# --- Step 1: 设置工具链 ---
echo ""
echo "[1/7] Setting up toolchain..."
OHOS_SYSROOT="$OHOS_SYSROOT" source /build/setup_toolchain.sh
export PATH=$TOOLCHAIN_DIR:$PATH

# --- Step 2: 克隆 / 重置 JDK 21u ---
echo ""
echo "[2/7] Cloning OpenJDK 21u..."
cd $WORK_DIR

if [ ! -d "jdk21u" ]; then
    # 用稳定 tag jdk-21.0.5+11
    git clone --depth 1 --branch jdk-21.0.5+11 https://github.com/openjdk/jdk21u.git jdk21u || \
    git clone --depth 1 https://github.com/openjdk/jdk21u.git jdk21u
    echo "Clone complete."
else
    echo "Source already exists, resetting..."
    cd jdk21u
    git reset --hard HEAD
    git clean -fdx -- src/
    cd ..
fi

cd jdk21u

# --- Step 3: 安装 stub 头文件 ---
echo ""
echo "[3/7] Installing stub headers from stubs/ directory..."

# CUPS stubs → /build/stub-cups/（configure --with-cups-include 指向这里）
rm -rf /build/stub-cups
cp -r /build/stubs/cups /build/stub-cups
echo "  CUPS stubs installed"

# Fontconfig + X11 stubs → /build/stub-headers/（-I/build/stub-headers）
rm -rf /build/stub-headers
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

# ALSA stub library (for linking) — must be writable to OHOS_SYSROOT
# 注意：用 -nostdlib 是因为 OHOS sysroot 没有 gcc 风格的 crt*.o / libgcc，
# clang 默认会去找 host 的 /usr/lib/gcc/* 失败。stub 完全不需要 libc，所以
# nostdlib 安全；JDK 真正的代码用 cxxabi_shim.cpp 的方式自己提供 unwinding。
if [ ! -f "${OHOS_SYSROOT}/usr/lib/aarch64-linux-ohos/libasound.so" ]; then
    echo 'void snd_stub(void) {}' > /tmp/asound_stub.c
    /usr/bin/ohos-clang --target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} \
        -fuse-ld=lld -shared -nostdlib \
        -o ${OHOS_SYSROOT}/usr/lib/aarch64-linux-ohos/libasound.so /tmp/asound_stub.c
    echo "  libasound.so stub created"
fi

echo "  All stubs ready"

# --- Step 4: 应用源码补丁 ---
echo ""
echo "[4/7] Applying source patches..."

# 修复 WSL 检测 (Docker Desktop 运行在 WSL2 内核上会被误判)
sed -i 's/uname -r | grep -i microsoft/false/' make/autoconf/build-aux/config.guess 2>/dev/null || true

# Patch / shim 来源（mount: prebuilt/jdk/21/ → /jdk21-spec, prebuilt/stubs → /stubs-src）
# stubs sources 实际放在 /stubs-src/src/{cxxabi_shim.cpp, eh_stubs.c}
JDK_SPEC_DIR="/jdk21-spec"
STUBS_SRC_DIR="/stubs-src/src"
if [ -d "$JDK_SPEC_DIR/patches" ]; then
    PATCH_DIR="$JDK_SPEC_DIR/patches"
elif [ -d "/build/patches/jdk21u" ]; then
    echo "  (legacy mount layout: using /build/patches/jdk21u)"
    PATCH_DIR="/build/patches/jdk21u"
else
    echo "ERROR: no patches found at /jdk21-spec/patches or /build/patches/jdk21u" >&2
    echo "       mount prebuilt/jdk/21 to /jdk21-spec, e.g.:" >&2
    echo "       -v \$(pwd)/prebuilt/jdk/21:/jdk21-spec:ro" >&2
    exit 1
fi
if [ ! -f "$STUBS_SRC_DIR/eh_stubs.c" ]; then
    if [ -f "/stubs-src/eh_stubs.c" ]; then STUBS_SRC_DIR="/stubs-src"
    elif [ -f "/build/shims/eh_stubs.c" ]; then STUBS_SRC_DIR="/build/shims"   # legacy fallback
    fi
fi
echo "  patches: $PATCH_DIR"
echo "  stubs:   $STUBS_SRC_DIR"

# 使用统一补丁系统应用 8 个 OHOS patch
bash /build/apply_patches.sh --patch-dir "$PATCH_DIR" --target /build/jdk21u

# --- Step 5: Configure ---
echo ""
echo "[5/7] Running configure..."

# 预先创建 libcxxabi_shim.so (configure 链接测试需要)
echo "  Pre-creating libcxxabi_shim.so for link tests..."
mkdir -p /output/jdk-libs
# 清理上一次 post-build 留下的 libjli.so（rebuild_libjli.sh 会把版本脚本受限的
# libjli.so 拷到 /output/jdk-libs/）。如果这个文件残留，下次 jdk21 build 的
# javac/jrunscript/jstatd 等可执行文件 link 时会优先命中它（因为 /output/jdk-libs
# 在 -L 列表前面），结果出现 "JLI_PreprocessArg undefined" 这种诡异链接错误。
rm -f /output/jdk-libs/libjli.so 2>/dev/null || true

# 关键 include path：clang 默认只看 /usr/include；OHOS musl 的 bits/* 在 per-arch 子目录
# /usr/include/aarch64-linux-ohos/。stdlib.h 会 #include <bits/alltypes.h>，
# 不加这个 -I 整个 sysroot 都用不了。
ARCH_INCLUDE="-I${OHOS_SYSROOT}/usr/include/aarch64-linux-ohos"

/usr/bin/ohos-clang --target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} $ARCH_INCLUDE \
    -c -fPIC -o /tmp/eh_stubs.o "$STUBS_SRC_DIR/eh_stubs.c"
# 注意 -nostdlib：OHOS sysroot 没有 gcc 风格的 crt*.o；clang 默认会去找 host 的
# /usr/lib/gcc/* 链接 crti.o / crtbeginS.o，链接器会失败。
# -nostdlib 同时禁用 startfiles 和 default libs；shim 不需要 startfile（它就是个共享库），
# libc 自己用 -lc 显式带。
/usr/bin/ohos-clang++ --target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} $ARCH_INCLUDE \
    -shared -fPIC -fvisibility=hidden -fno-exceptions -fno-rtti \
    -nostdlib -L${OHOS_SYSROOT}/usr/lib/aarch64-linux-ohos \
    -o /output/jdk-libs/libcxxabi_shim.so "$STUBS_SRC_DIR/cxxabi_shim.cpp" /tmp/eh_stubs.o \
    -fuse-ld=lld -Wl,-soname,libcxxabi_shim.so -lc
echo "  libcxxabi_shim.so ready"

export BUILD_CC=/usr/bin/clang-15
export BUILD_CXX=/usr/bin/clang++-15

LIBCXX_INC=/usr/lib/llvm-15/include/c++/v1

# 关键：让 Ubuntu clang 使用 Huawei NDK 的 compiler-rt + crt 启动文件。
# - -rtlib=compiler-rt 让 clang 使用 compiler-rt 而不是 libgcc
# - -unwindlib=none 不需要 unwinder（cxxabi_shim.cpp 自带 stub）
# - -B 加 sysroot 的 aarch64-linux-ohos 子目录到 crt 搜索路径
# 提前条件：/usr/lib/llvm-15/lib/clang/15.0.7/lib/linux/libclang_rt.builtins-aarch64.a
# 由 docker entrypoint 或 setup_toolchain.sh 从 Huawei NDK 复制好。
TARGET_LIB="${OHOS_SYSROOT}/usr/lib/aarch64-linux-ohos"

COMMON_CFLAGS="--target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} -fPIC -D__MUSL__ -DMUSL_LIBC -D_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE -D_LIBCPP_HAS_MUSL_LIBC $ARCH_INCLUDE -I/build/stub-headers -isystem $LIBCXX_INC -B${TARGET_LIB} -L${TARGET_LIB} -rtlib=compiler-rt -unwindlib=none"
COMMON_CXXFLAGS="--target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} -fPIC -D__MUSL__ -DMUSL_LIBC -D_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE -D_LIBCPP_HAS_MUSL_LIBC $ARCH_INCLUDE -I/build/stub-headers -stdlib=libc++ -nostdlib++ -B${TARGET_LIB} -L${TARGET_LIB} -rtlib=compiler-rt -unwindlib=none"

bash configure \
    --openjdk-target=aarch64-unknown-linux-musl \
    --with-jvm-variants=server \
    --with-debug-level=release \
    --with-native-debug-symbols=none \
    --with-boot-jdk=$JAVA_HOME \
    --with-extra-cflags="$COMMON_CFLAGS" \
    --with-extra-cxxflags="$COMMON_CXXFLAGS" \
    --with-extra-ldflags="--target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} -fuse-ld=lld -B${TARGET_LIB} -L${TARGET_LIB} -rtlib=compiler-rt -unwindlib=none -nostdlib++ -L/output/jdk-libs -lcxxabi_shim" \
    --x-includes=/dev/null \
    --x-libraries=/dev/null \
    --with-cups-include=/build/stub-cups \
    --with-freetype=bundled \
    --enable-headless-only \
    --disable-warnings-as-errors \
    --with-toolchain-type=clang \
    CC=aarch64-linux-ohos-gcc \
    CXX=aarch64-linux-ohos-g++ \
    CPP="aarch64-linux-ohos-gcc -E $ARCH_INCLUDE -I/build/stub-headers --target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT}" \
    CXXCPP="aarch64-linux-ohos-g++ -E $ARCH_INCLUDE -I/build/stub-headers --target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT}" \
    BUILD_CC=$BUILD_CC \
    BUILD_CXX=$BUILD_CXX \
    AR=aarch64-linux-ohos-ar \
    STRIP=aarch64-linux-ohos-strip \
    NM=aarch64-linux-ohos-nm \
    OBJCOPY=aarch64-linux-ohos-objcopy \
    2>&1 | tee /build/configure-21.log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "CONFIGURE FAILED! See /build/configure-21.log"
    exit 1
fi
echo "  Configure complete"

# --- Step 6: Build ---
echo ""
echo "[6/7] Building (JOBS=$JOBS)..."
gmake images JOBS=$JOBS 2>&1 | tee /build/build-21.log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "BUILD FAILED! Last 50 lines:"
    tail -50 /build/build-21.log
    exit 1
fi

# --- Step 7: 重新编译 libjli + 打包 ---
echo ""
echo "[7/7] Post-build: rebuild libjli + pack zip..."

IMAGE_DIR=$(find /build/jdk21u/build -path "*/images/jdk" -type d -not -path "*/support/*" 2>/dev/null | head -1)
if [ -z "$IMAGE_DIR" ]; then
    # legacy fallback (some JDK 17 builds)
    IMAGE_DIR=$(find /build/jdk21u/build -path "*/images/jdk" -type d 2>/dev/null | head -1)
fi
if [ -z "$IMAGE_DIR" ]; then
    echo "ERROR: Build output not found"
    exit 1
fi
echo "  JDK images at: $IMAGE_DIR"

# 复制 libcxxabi_shim.so 到 image lib/（保证打包包含）
cp /output/jdk-libs/libcxxabi_shim.so $IMAGE_DIR/lib/

# 重链 libjli.so（导出 JLI_Exit/JLI_ExitHook）
JDK_VERSION=21 bash /build/scripts/rebuild_libjli.sh

# 打包发布 zip（与 17 的 jdk17-ohos-full-v4.zip 同构）
JDK_VERSION=21 bash /build/scripts/pack_jdk_full.sh

echo ""
echo "============================================"
echo " BUILD SUCCESSFUL!"
echo " JDK:     $IMAGE_DIR"
echo " Version: $(grep JAVA_VERSION= $IMAGE_DIR/release | head -1)"
echo " Output:  /output/jdk21-ohos-full.zip"
echo "============================================"
du -sh $IMAGE_DIR
ls -lh /output/jdk21-ohos-full.zip 2>/dev/null || echo "WARNING: pack_jdk_full.sh did not produce zip!"

echo ""
echo "Next steps:"
echo "  1. sha256sum /output/jdk21-ohos-full.zip"
echo "  2. gh release create v21.0.5-ohos-1 /output/jdk21-ohos-full.zip --repo LZZLHY/mc-ohos-resources"
echo "  3. Update entry/src/main/ets/services/JdkManager.ets JDK_VERSIONS['21'].sha256/sizeBytes"
