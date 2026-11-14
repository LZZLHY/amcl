#!/bin/bash
set -e

# ============================================================
#  OpenJDK 25u for HarmonyOS NEXT — Docker 一键编译脚本
#  使用系统 clang-15 + OHOS NDK sysroot 交叉编译
#
#  状态 (2026-05-30): JDK 25 上线编译路径（MC 26.1+ YY.D.H 纪元首个要求 Java 25）
#  - 8 个 OHOS 真 patch（与 21 同构，由 docker/port_jdk25_patches.sh 生成）
#  - 默认上游：jdk25u jdk-25.0.4+3 (commit e8f9ebe5e)
#  - 输出：$JDK_OUTPUT（与 21 的 jdk21-ohos-full.zip 同构）
#  - 严格对齐 build_jdk21_ohos.sh，仅替换版本号 + boot JDK 25
#
#  用法:
#    docker run --rm \
#      -v "/path/to/ohos/sysroot:/ohos-sysroot:ro" \
#      -v "/path/to/output:/output" \
#      -v "$(pwd)/prebuilt/jdk/25:/jdk25-spec:ro" \
#      -v "$(pwd)/prebuilt/stubs:/stubs-src:ro" \
#      openjdk-ohos-builder /build/build_jdk25_ohos.sh
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
#
#  ⚠️ Boot JDK：jdk25u configure 要求 JDK 24 或 25。容器需先
#     apt-get install temurin-25-jdk（Adoptium 源已配置）。
# ============================================================

OHOS_SYSROOT=${OHOS_SYSROOT:-/ohos-sysroot}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-/ohos-toolchain}
WORK_DIR=/build
JOBS=${JOBS:-$(nproc)}
# 统一产物身份：配方、打包和收尾检查共用本次请求的新文件名。
export JDK_OUTPUT="${JDK_OUTPUT:-/output/jdk25-ohos-${AMCL_RUN_ID:-candidate}.zip}"

# Boot JDK：jdk25u build 需要 JDK 24 或 25，必须强制用 Temurin 25（如果存在）
# 注意：Dockerfile 把 JAVA_HOME export 成了 JDK 17，所以这里不能依赖 ${JAVA_HOME:-...}
unset JAVA_HOME
if [ -d "/usr/lib/jvm/temurin-25-jdk-amd64" ]; then
    JAVA_HOME=/usr/lib/jvm/temurin-25-jdk-amd64
elif [ -d "/usr/lib/jvm/java-25-openjdk-amd64" ]; then
    JAVA_HOME=/usr/lib/jvm/java-25-openjdk-amd64
elif [ -d "/usr/lib/jvm/temurin-24-jdk-amd64" ]; then
    JAVA_HOME=/usr/lib/jvm/temurin-24-jdk-amd64
elif [ -d "/usr/lib/jvm/java-24-openjdk-amd64" ]; then
    JAVA_HOME=/usr/lib/jvm/java-24-openjdk-amd64
else
    echo "ERROR: no JDK 24/25 boot JDK found. jdk25u configure will reject older."
    echo "       Run: apt-get install -y temurin-25-jdk"
    exit 1
fi
export JAVA_HOME

echo "============================================"
echo " OpenJDK 25u for HarmonyOS NEXT (aarch64)"
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

# --- Step 2: 克隆 / 重置 JDK 25u ---
echo ""
echo "[2/7] Cloning OpenJDK 25u..."
cd $WORK_DIR

python3 /build/scripts/prepare_jdk_source.py 25
cd jdk25u

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

# Patch / shim 来源（mount: prebuilt/jdk/25/ → /jdk25-spec, prebuilt/stubs → /stubs-src）
# stubs sources 实际放在 /stubs-src/src/{cxxabi_shim.cpp, eh_stubs.c}
JDK_SPEC_DIR="/jdk25-spec"
STUBS_SRC_DIR="/stubs-src/src"
if [ -d "$JDK_SPEC_DIR/patches" ]; then
    PATCH_DIR="$JDK_SPEC_DIR/patches"
elif [ -d "/build/patches/jdk25u" ]; then
    echo "  (legacy mount layout: using /build/patches/jdk25u)"
    PATCH_DIR="/build/patches/jdk25u"
else
    echo "ERROR: no patches found at /jdk25-spec/patches or /build/patches/jdk25u" >&2
    echo "       mount prebuilt/jdk/25 to /jdk25-spec, e.g.:" >&2
    echo "       -v \$(pwd)/prebuilt/jdk/25:/jdk25-spec:ro" >&2
    exit 1
fi
if [ ! -f "$STUBS_SRC_DIR/eh_stubs.c" ]; then
    if [ -f "/stubs-src/eh_stubs.c" ]; then STUBS_SRC_DIR="/stubs-src"
    elif [ -f "/build/shims/eh_stubs.c" ]; then STUBS_SRC_DIR="/build/shims"   # legacy fallback
    fi
fi
echo "  patches: $PATCH_DIR"
echo "  stubs:   $STUBS_SRC_DIR"

# 仅重放series声明的活动补丁；历史0005/0006/0007原件留作追溯，不通配应用。
python3 /build/scripts/apply_jdk_patches.py --patch-dir "$PATCH_DIR" --target /build/jdk25u
# 编译前核对完整上游安全点和普通信号入口，防止旧绕过换名回生；宿主桥独立保留。
python3 /build/scripts/verify_jdk25_safepoint.py --major 25 --source /build/jdk25u \
    --patch-dir "$PATCH_DIR" --inputs /prebuilt/jdk/build-inputs.json

# --- Step 5: Configure ---
echo ""
echo "[5/7] Running configure..."

# 链接真实应用 ABI；兼容外壳只保留 SONAME，不定义 guard/EH/RTTI。
ARCH_INCLUDE="-I${OHOS_SYSROOT}/usr/include/aarch64-linux-ohos"
bash /build/scripts/prepare_jdk_abi.sh 25 /output/jdk-libs

export BUILD_CC=/usr/bin/clang-15
export BUILD_CXX=/usr/bin/clang++-15

LIBCXX_INC=${AMCL_JDK_CXX_INCLUDE:?}

# 关键：让 Ubuntu clang 使用 Huawei NDK 的 compiler-rt + crt 启动文件。
# - -rtlib=compiler-rt 让 clang 使用 compiler-rt 而不是 libgcc
# - -unwindlib=none 禁止编译器隐式添加另一套 unwind；真实 unwind 在 libc++_shared 中
# - -B 加 sysroot 的 aarch64-linux-ohos 子目录到 crt 搜索路径
# 提前条件：/usr/lib/llvm-15/lib/clang/15.0.7/lib/linux/libclang_rt.builtins-aarch64.a
# 由 docker entrypoint 或 setup_toolchain.sh 从 Huawei NDK 复制好。
TARGET_LIB="${OHOS_SYSROOT}/usr/lib/aarch64-linux-ohos"

COMMON_CFLAGS="-I/prebuilt/jdk/25/shims ${AMCL_JDK_RESOURCE_FLAG} --target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} -fPIC -D__OHOS__=1 -D__OHOS_FAMILY__=1 -D__OHOS_Major__=0 -D__MUSL__ -DMUSL_LIBC $ARCH_INCLUDE -I/build/stub-headers -isystem $LIBCXX_INC -B${TARGET_LIB} -L${TARGET_LIB} -rtlib=compiler-rt -unwindlib=none"
COMMON_CXXFLAGS="-I/prebuilt/jdk/25/shims ${AMCL_JDK_RESOURCE_FLAG} --target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} -fPIC -D__OHOS__=1 -D__OHOS_FAMILY__=1 -D__OHOS_Major__=0 -D__MUSL__ -DMUSL_LIBC $ARCH_INCLUDE -I/build/stub-headers -isystem $LIBCXX_INC -stdlib=libc++ -nostdlib++ -nostdinc++ -B${TARGET_LIB} -L${TARGET_LIB} -rtlib=compiler-rt -unwindlib=none"

# 固定上游源码时间，避免构建时间成为未登记输入。
export SOURCE_DATE_EPOCH="$(git log -1 --format=%ct)"
# test-image默认不会带gtest；显式配置真实框架，不能导出空清单后声称已接入。
test_configure=()
if [ "${AMCL_JDK_TEST_IMAGE:-0}" = 1 ]; then
    python3 /build/scripts/prepare_gtest.py --source /build/upstream-googletest --receipt /build/upstream-googletest.json
    test_configure+=(--with-gtest=/build/upstream-googletest)
fi
bash configure "${test_configure[@]}" \
    `# 2026-08-29：显式声明构建主机，别让 config.guess 自己猜。` \
    `# Docker Desktop 的容器跑在 WSL2 VM 里，uname -r 带 "microsoft-standard-WSL2"，` \
    `# 而 jdk25u 的 config.guess 会据此判成 x86_64-pc-wsl ⇒ openjdk-build os-cpu 变成` \
    `# windows-x86_64 ⇒ 启用 fixpath ⇒ "The path of TOPDIR ... can not be properly resolved"` \
    `# 后 exit 127。同一个镜像在 2026-05-19 编 jdk21u 时检出的是 x86_64-pc-linux-gnu，` \
    `# 所以这不是配置漂移而是 WSL 内核串被 config.guess 认出来了。` \
    `# --build 只影响构建主机侧的工具分类，不影响 target 代码生成。` \
    `# ⚠️ 17/21/8 的脚本没跟着改：它们当时能过，未在本机复验，不做未验证的改动。` \
    --build=x86_64-unknown-linux-gnu \
    --openjdk-target=aarch64-unknown-linux-musl \
    --with-jvm-variants=server \
    --with-debug-level=release \
    --with-native-debug-symbols=none \
    --with-boot-jdk=$JAVA_HOME \
    --with-extra-cflags="$COMMON_CFLAGS" \
    --with-extra-cxxflags="$COMMON_CXXFLAGS" \
    --with-extra-ldflags="--target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} -fuse-ld=lld -B${TARGET_LIB} -L${TARGET_LIB} -rtlib=compiler-rt -unwindlib=none -nostdlib++ -L/output/jdk-libs -lcxxabi_shim -lc++_shared" \
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
    2>&1 | tee /build/configure-25.log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "CONFIGURE FAILED! See /build/configure-25.log"
    exit 1
fi
echo "  Configure complete"

# --- Step 6: Build ---
echo ""
echo "[6/7] Building (JOBS=$JOBS)..."
# 上游 test-image 与正式映像共用已冻结输入；是否实际运行另由 jtreg/gtest 收据证明。
build_targets=(images)
if [ "${AMCL_JDK_TEST_IMAGE:-0}" = 1 ]; then build_targets+=(test-image); fi
gmake "${build_targets[@]}" JOBS=$JOBS 2>&1 | tee /build/build-25.log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "BUILD FAILED! Last 50 lines:"
    tail -50 /build/build-25.log
    exit 1
fi

# --- Step 7: 重新编译 libjli + 打包 ---
echo ""
echo "[7/7] Post-build: rebuild libjli + pack zip..."

# 精确消费最终 image，禁止选中 support/images 的中间目录。
IMAGE_DIR=/build/jdk25u/build/linux-aarch64-server-release/images/jdk
[ -f "$IMAGE_DIR/release" ] && [ -f "$IMAGE_DIR/lib/modules" ] || { echo 'ERROR: missing final image'; exit 1; }

echo "  JDK images at: $IMAGE_DIR"

# 复制 libcxxabi_shim.so 到 image lib/（保证打包包含）
cp /output/jdk-libs/libcxxabi_shim.so $IMAGE_DIR/lib/

# 重链 libjli.so（导出 JLI_Launch 等）
JDK_VERSION=25 bash /build/scripts/rebuild_libjli.sh

# 打包发布 zip（与 21 的 jdk21-ohos-full.zip 同构）
JDK_VERSION=25 bash /build/scripts/pack_jdk_full.sh

echo ""
echo "============================================"
echo " BUILD SUCCESSFUL!"
echo " JDK:     $IMAGE_DIR"
echo " Version: $(grep JAVA_VERSION= $IMAGE_DIR/release | head -1)"
echo " Output:  $JDK_OUTPUT"
echo "============================================"
du -sh $IMAGE_DIR
[ -s "$JDK_OUTPUT" ] || { echo "ERROR: missing validated runtime: $JDK_OUTPUT"; exit 1; }
ls -lh "$JDK_OUTPUT"

echo ""
echo "Candidate runtime built; use the recorded remote validation plan before any immutable new release."
