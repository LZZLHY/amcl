#!/bin/bash
set -e

# ============================================================
#  shaderc + SPIRV-Cross native for HarmonyOS NEXT — Docker 构建脚本
#  （VULKAN_ADAPTATION_PLAN.md Phase 3）
#
#  背景：MC 26.2 起官方 Vulkan 渲染后端（Vibrant Visuals）运行时把 GLSL 用 shaderc
#  编成 SPIR-V（lwjgl-shaderc），并用 SPIRV-Cross（lwjgl-spvc）做反射/转换。
#  这两个 LWJGL 绑定与 freetype 同构：libffi 直调 C 符号、无 LWJGL JNI 胶水
#  （已读 lwjgl3_src/.../{Shaderc,Spvc}.java 核实）：
#    - shaderc: Library.loadNative(..., mapLibraryNameBundled("shaderc"), true)
#               → 默认库名 libshaderc.so，导出 shaderc_* C 符号，org.lwjgl.shaderc.libname 可覆盖
#    - spvc:    Library.loadNative(..., mapLibraryNameBundled("spirv-cross"), true)
#               → 默认库名 libspirv-cross.so，导出 spvc_* C 符号，org.lwjgl.spvc.libname 可覆盖
#  所以只需把上游交叉编成导出 C API 的 .so 即可。
#
#  版本对齐 LWJGL 3.4.1（见 lwjgl3_src/doc/notes/3.4.1.md + 3.3.5.md）：
#    - Shaderc 2026.1（内含 glslang 16.2.0 + SPIRV-Tools 2026.1 + SPIRV-Headers）
#    - SPIRV-Cross 0.64.0（3.3.5 起，3.4.x 未再 bump）
#  ⚠️ 版本错配会导致 spvc_*/shaderc_* 符号增删，LWJGL apiGetFunctionAddress 在类初始化抛。
#
#  产物：
#    libshaderc.so       — 导出 shaderc_* （部署到 entry/libs/arm64-v8a/，org.lwjgl.shaderc.libname 指向）
#    libspirv-cross.so   — 导出 spvc_*     （同上，org.lwjgl.spvc.libname 指向）
#
#  用法（容器 ohos-debug 已在跑；工具链同 build_lwjgl/freetype）：
#    docker exec ohos-debug bash /build/setup_toolchain.sh
#    docker exec ohos-debug env \
#      SHADERC_TAG=v2026.1 SPIRV_CROSS_TAG=vulkan-sdk-1.4.x OUTPUT_DIR=/output \
#      bash /build/build_shaderc_ohos.sh
#
#  ⚠️ libc++ ABI 命名空间（2026-05-31 真机 cppcrash 定位，必读）：
#  旧版本用镜像里的 Ubuntu libc++-15 头 → 产物用 std::__1:: ABI，但 HarmonyOS 的
#  libc++_shared.so 用定制 std::__n1:: ABI → 运行时 iostream typeinfo symbol not found →
#  MC 26.2 启动崩（libshaderc.so 尤甚，含 1982 个 __1 引用）。
#  现已改用 OHOS NDK 的 libcxx-ohos 头（__n1 ABI）+ 链接 NDK libc++_shared.so。
#  详见 Step 0 的大注释块。OHOS libc++ 头通过 OHOS_LIBCXX_DIR（默认 /output/ohos-libcxx）传入，
#  需 release 流程预先 stage（见文件尾“准备 OHOS libc++ 头”）。
#  Step 3 verify 会扫描产物若仍含 __1 iostream 符号则 fail，杜绝回归。
# ============================================================

OHOS_SYSROOT_ORIG=${OHOS_SYSROOT:-/ohos-sysroot}
WORK_DIR=${WORK_DIR:-/build/vk-shaders}
OUTPUT_DIR=${OUTPUT_DIR:-/output}
JOBS=${JOBS:-$(nproc)}

# 版本 pin（对齐 LWJGL 3.4.1；可用 env 覆盖）。
# shaderc 用 release tag（v2026.1）；SPIRV-Cross 0.64.0 对应 vulkan-sdk 系列 tag，
# 这里用 commit/tag 都可，release 负责人按 deps.lock 填实际值。
SHADERC_TAG=${SHADERC_TAG:-v2026.1}
SPIRV_CROSS_TAG=${SPIRV_CROSS_TAG:-vulkan-sdk-1.3.290.0}  # 含 SPIRV-Cross 0.64.x 的 SDK tag

echo "============================================"
echo " shaderc + SPIRV-Cross native for HarmonyOS NEXT (Phase 3)"
echo " shaderc:      $SHADERC_TAG"
echo " spirv-cross:  $SPIRV_CROSS_TAG"
echo " Jobs:         $JOBS"
echo " Output:       $OUTPUT_DIR"
echo "============================================"

# ============================================================
# Step 0: 工具链（与 build_lwjgl/freetype 同套路）
# ============================================================
echo ""
echo "[0/4] Setting up toolchain..."

OHOS_SYSROOT=/ohos-sysroot-rw
if [ ! -d "$OHOS_SYSROOT/usr/include" ]; then
    echo "  Copying sysroot to writable location..."
    cp -a "$OHOS_SYSROOT_ORIG" "$OHOS_SYSROOT"
fi
OHOS_LIBDIR=$OHOS_SYSROOT/usr/lib/aarch64-linux-ohos

# ============================================================
#  ⚠️⚠️ libc++ ABI 命名空间修复（2026-05-31 真机 cppcrash 定位）⚠️⚠️
#
#  症状：MC 26.2 启动崩 → UnsatisfiedLinkError: libshaderc.so ...
#        _ZTINSt3__114basic_iostreamIcNS_11char_traitsIcEEEE: symbol not found
#
#  根因：本构建镜像的 Ubuntu libc++-15 头用上游标准 inline namespace `std::__1::`
#        （符号 _ZTINSt3__1...）。但 HarmonyOS 的 libc++_shared.so（设备 + NDK 一致）
#        用 OHOS 定制 inline namespace `std::__n1::`（符号 _ZTINSt4__n1...）。
#        shaderc 重度用 <sstream>/<iostream>，把 __1 的 iostream typeinfo 外部引用泄露出来，
#        运行时去只有 __n1 的系统 libc++ 找 → symbol not found → 启动崩。
#        （实测：旧产物 libshaderc.so 含 1982 个 __1 引用、0 个 __n1。spvc 只 24 个 __1
#         侥幸没被加载路径触发，所以 spvc 早一步过关、shaderc 卡住。）
#
#  修复：改用 OHOS NDK 自带的 libc++ 头（libcxx-ohos/include/c++/v1，其 __config_site
#        定义 _LIBCPP_ABI_NAMESPACE __n1），并链接 NDK 的 libc++_shared.so（同 __n1）。
#        产物符号变 __n1，与设备运行时一致。实测：abitest.cpp 用本配置编出 __1=0 / __n1=22。
#
#  OHOS libc++ 头从哪来：NDK 在宿主机（Windows），容器没挂载。release 流程把
#  NDK 的 libcxx-ohos 头 + aarch64 libc++ 库 stage 到容器可见目录，路径用 env 传入：
#    OHOS_LIBCXX_DIR  （默认 /output/ohos-libcxx）
#      ├─ include/c++/v1/   （__config_site = __n1 的那套头，792 文件）
#      └─ lib/libc++_shared.so （__n1 ABI 的运行时库，仅用于链接期 -l 解析）
#  stage 办法见 scripts/stage_ohos_libcxx.* 或文件尾“准备 OHOS libc++ 头”说明。
#
#  注意：OHOS libc++ 的 musl 走 ctype "default rune table" + musl xlocale 兜底，
#        所以仍需这两个 define（不是 Ubuntu 头的遗留，是 OHOS musl libc++ 本身需要）：
#          -D_LIBCPP_HAS_MUSL_LIBC            → musl xlocale（strtoll_l/strtoull_l inline 兜底）
#          -D_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE → ctype mask 位表（musl 无 __GLIBC__/__BIONIC__ 分支）
#        关键差别只在“配 OHOS 头”——同样的 define 配 Ubuntu 头出 __1、配 OHOS 头出 __n1。
# ============================================================
OHOS_LIBCXX_DIR=${OHOS_LIBCXX_DIR:-/output/ohos-libcxx}
OHOS_CXX_INC=$OHOS_LIBCXX_DIR/include/c++/v1
OHOS_CXX_LIB=$OHOS_LIBCXX_DIR/lib

if [ ! -f "$OHOS_CXX_INC/__config_site" ] || [ ! -f "$OHOS_CXX_LIB/libc++_shared.so" ]; then
    echo "ERROR: OHOS libc++ headers/libs not found under $OHOS_LIBCXX_DIR"
    echo "       需要先把 NDK 的 libcxx-ohos 头 + aarch64 libc++ 库 stage 到该目录："
    echo "         \$OHOS_LIBCXX_DIR/include/c++/v1/__config_site   (应含 _LIBCPP_ABI_NAMESPACE __n1)"
    echo "         \$OHOS_LIBCXX_DIR/lib/libc++_shared.so"
    echo "       见本脚本尾部“准备 OHOS libc++ 头”说明 / scripts/stage_ohos_libcxx.*。"
    exit 1
fi
# 防呆：确认头确实是 __n1 ABI（用错成 Ubuntu 的 __1 头会再次复现崩溃）。
if ! grep -q '_LIBCPP_ABI_NAMESPACE __n1' "$OHOS_CXX_INC/__config_site"; then
    echo "ERROR: $OHOS_CXX_INC/__config_site 不是 OHOS 的 __n1 ABI！"
    echo "       grep 结果: $(grep _LIBCPP_ABI_NAMESPACE "$OHOS_CXX_INC/__config_site")"
    echo "       必须用 NDK 的 libcxx-ohos 头（__n1），不能用 Ubuntu libc++-15 头（__1）。"
    exit 1
fi
# `-stdlib=libc++` searches for libc++.so, while the OHOS SDK ships the runtime
# as libc++_shared.so. Keep the runtime SONAME and add a build-only link-name copy.
if [ ! -f "$OHOS_CXX_LIB/libc++.so" ]; then
    cp "$OHOS_CXX_LIB/libc++_shared.so" "$OHOS_CXX_LIB/libc++.so"
fi
echo "  OHOS libc++ headers: $OHOS_CXX_INC ($(grep _LIBCPP_ABI_NAMESPACE "$OHOS_CXX_INC/__config_site" | tr -s ' '))"

# 编译器包装脚本（CMake/无空格友好）。C++ 用 OHOS NDK 的 libc++ 头（__n1 ABI），
# -nostdinc++ 屏蔽镜像里的 Ubuntu libc++-15 头（__1 ABI），-isystem 指向 OHOS 头。
# 链接：-stdlib=libc++ 让 clang driver 正常补 -lc++，从 -L$OHOS_CXX_LIB 解析到 OHOS 的
# libc++.so（= __n1 的 libc++_shared.so 副本，SONAME 仍 libc++_shared.so → NEEDED 干净）。
# ⚠️ 不能往 wrapper 尾部追加 libc++_shared.so 当输入文件：glslang 的 PCH 步骤用 -emit-pch，
#    多输入会触发 "cannot specify -o when generating multiple output files"（2026-05-31 实测）。
#    靠 -stdlib=libc++ + -L 的 driver 链接最稳，编译/PCH/链接三种调用形态都安全。
# 两个 musl/rune define 见上方注释块（OHOS musl libc++ 本身需要）。
# -Qunused-arguments：抑制 -L/-fuse-ld 在 -c 步骤的 "argument unused"（shaderc -Werror 会把它变 fatal）。
cat > /tmp/ohos-cc-vk <<CCEOF
#!/bin/bash
exec /usr/bin/ohos-clang --target=aarch64-linux-ohos --sysroot=$OHOS_SYSROOT -Qunused-arguments -L$OHOS_LIBDIR -fuse-ld=lld "\$@"
CCEOF
cat > /tmp/ohos-cxx-vk <<CCEOF
#!/bin/bash
exec /usr/bin/ohos-clang++ --target=aarch64-linux-ohos --sysroot=$OHOS_SYSROOT \\
    -stdlib=libc++ -nostdinc++ -isystem $OHOS_CXX_INC \\
    -D_LIBCPP_HAS_MUSL_LIBC -D_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE \\
    -Qunused-arguments -L$OHOS_LIBDIR -L$OHOS_CXX_LIB -fuse-ld=lld \\
    "\$@"
CCEOF
chmod +x /tmp/ohos-cc-vk /tmp/ohos-cxx-vk
CC=/tmp/ohos-cc-vk
CXX=/tmp/ohos-cxx-vk

echo "  Compiler: $(/usr/bin/ohos-clang --version 2>&1 | head -1)"
echo "  CMake:    $(cmake --version 2>&1 | head -1)"

# CMake toolchain file（交叉编译三件套：SYSTEM_NAME + 编译器 + sysroot）
TOOLCHAIN_CMAKE=$WORK_DIR/ohos-toolchain.cmake
mkdir -p "$WORK_DIR"
cat > "$TOOLCHAIN_CMAKE" <<TCEOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER   $CC)
set(CMAKE_CXX_COMPILER $CXX)
set(CMAKE_AR      /usr/bin/ohos-ar)
set(CMAKE_RANLIB  /usr/bin/ohos-ranlib)
set(CMAKE_FIND_ROOT_PATH $OHOS_SYSROOT)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
# OHOS 用 compiler-rt + libc++；不要 GNU libstdc++。
# rune table 修复（_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE）已烤进 /tmp/ohos-cxx-vk wrapper，
# 这里不再靠 CMAKE_CXX_FLAGS_INIT（toolchain file 的 _INIT 对子项目不可靠）。
set(CMAKE_CXX_FLAGS_INIT "-fPIC")
set(CMAKE_C_FLAGS_INIT   "-fPIC")
TCEOF
echo "  Toolchain file: $TOOLCHAIN_CMAKE"

command -v patchelf >/dev/null 2>&1 || { echo "ERROR: patchelf 未安装（Dockerfile 应已装）"; exit 1; }

mkdir -p "$OUTPUT_DIR"

# ============================================================
# Step 1: SPIRV-Cross（先做，轻）→ libspirv-cross.so 导出 spvc_*
# ============================================================
echo ""
echo "[1/4] Building SPIRV-Cross ($SPIRV_CROSS_TAG, shared C API)..."
cd "$WORK_DIR"
SPVC_SRC="SPIRV-Cross"
if [ ! -d "$SPVC_SRC" ]; then
    git clone --depth 1 --branch "$SPIRV_CROSS_TAG" \
        https://github.com/KhronosGroup/SPIRV-Cross.git "$SPVC_SRC"
fi

SPVC_BUILD="$WORK_DIR/spvc-build"
# SPIRV_CROSS_SHARED=ON 产出 libspirv-cross-c-shared.so（导出 spvc_* C API）。
# 全开 GLSL/HLSL/MSL/REFLECT/CPP：LWJGL spvc 绑定带 msl/hlsl 符号（spvc_compiler_msl_* /
# spvc_compiler_hlsl_*），关掉会缺符号 → apiGetFunctionAddress 抛。CLI/TESTS 关掉减体积。
cmake -S "$SPVC_SRC" -B "$SPVC_BUILD" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_CMAKE" \
    -DCMAKE_BUILD_TYPE=Release \
    -DSPIRV_CROSS_SHARED=ON \
    -DSPIRV_CROSS_STATIC=OFF \
    -DSPIRV_CROSS_CLI=OFF \
    -DSPIRV_CROSS_ENABLE_TESTS=OFF \
    -DSPIRV_CROSS_ENABLE_GLSL=ON \
    -DSPIRV_CROSS_ENABLE_HLSL=ON \
    -DSPIRV_CROSS_ENABLE_MSL=ON \
    -DSPIRV_CROSS_ENABLE_CPP=ON \
    -DSPIRV_CROSS_ENABLE_REFLECT=ON \
    -DSPIRV_CROSS_ENABLE_C_API=ON \
    -DSPIRV_CROSS_ENABLE_UTIL=ON
ninja -C "$SPVC_BUILD" -j"$JOBS" spirv-cross-c-shared

SPVC_SO=$(find "$SPVC_BUILD" -name 'libspirv-cross-c-shared.so*' -type f | head -1)
if [ -z "$SPVC_SO" ]; then echo "ERROR: libspirv-cross-c-shared.so not built!"; exit 1; fi
/usr/bin/ohos-strip --strip-unneeded "$SPVC_SO" 2>/dev/null || true
cp -L "$SPVC_SO" "$OUTPUT_DIR/libspirv-cross.so"
patchelf --set-soname libspirv-cross.so "$OUTPUT_DIR/libspirv-cross.so"
echo "  -> $OUTPUT_DIR/libspirv-cross.so"

# ============================================================
# Step 2: shaderc（重，拉 glslang/SPIRV-Tools/SPIRV-Headers）→ libshaderc.so 导出 shaderc_*
# ============================================================
echo ""
echo "[2/4] Building shaderc ($SHADERC_TAG, shared)..."
cd "$WORK_DIR"
SHADERC_SRC="shaderc"
if [ ! -d "$SHADERC_SRC" ]; then
    git clone --depth 1 --branch "$SHADERC_TAG" \
        https://github.com/google/shaderc.git "$SHADERC_SRC"
    # shaderc 用 utils/git-sync-deps 拉 glslang / SPIRV-Tools / SPIRV-Headers 到 third_party/
    ( cd "$SHADERC_SRC" && python3 ./utils/git-sync-deps )
fi

SHADERC_BUILD="$WORK_DIR/shaderc-build"
# SHADERC_SKIP_*：关测试/示例/版权检查/安装组件加速。
# 产出 shaderc_shared target（libshaderc_shared.so，导出 shaderc_* C API）。
# BUILD_SHARED_LIBS 留默认（OFF）——只让 shaderc_shared 本身是动态，其依赖静态内联进去，
# 这样产物自包含、NEEDED 只剩 libc/libc++（与 freetype/curl 自包含风格一致）。
cmake -S "$SHADERC_SRC" -B "$SHADERC_BUILD" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_CMAKE" \
    -DCMAKE_BUILD_TYPE=Release \
    -DSHADERC_SKIP_TESTS=ON \
    -DSHADERC_SKIP_EXAMPLES=ON \
    -DSHADERC_SKIP_COPYRIGHT_CHECK=ON \
    -DSHADERC_ENABLE_SHARED_CRT=OFF \
    -DSPIRV_HEADERS_SKIP_EXAMPLES=ON \
    -DSPIRV_SKIP_TESTS=ON \
    -DSKIP_SPIRV_TOOLS_INSTALL=ON \
    -DENABLE_GLSLANG_BINARIES=OFF \
    -DGLSLANG_TESTS=OFF
ninja -C "$SHADERC_BUILD" -j"$JOBS" shaderc_shared

SHADERC_SO=$(find "$SHADERC_BUILD" -name 'libshaderc_shared.so*' -type f | head -1)
if [ -z "$SHADERC_SO" ]; then echo "ERROR: libshaderc_shared.so not built!"; exit 1; fi
/usr/bin/ohos-strip --strip-unneeded "$SHADERC_SO" 2>/dev/null || true
cp -L "$SHADERC_SO" "$OUTPUT_DIR/libshaderc.so"
patchelf --set-soname libshaderc.so "$OUTPUT_DIR/libshaderc.so"
echo "  -> $OUTPUT_DIR/libshaderc.so"

# ============================================================
# Step 3: 校验导出符号 + NEEDED（仿 freetype verify）
# ============================================================
echo ""
echo "[3/4] Verifying spvc..."
NSPVC=$(ohos-readelf -sW "$OUTPUT_DIR/libspirv-cross.so" 2>/dev/null | grep -c ' spvc_' || echo 0)
echo "  exported spvc_* symbols: $NSPVC"
echo "  NEEDED: $(ohos-readelf -d "$OUTPUT_DIR/libspirv-cross.so" 2>/dev/null | grep NEEDED | tr -s ' ' | paste -sd' ')"
# spvc_context_create / spvc_compiler_compile 是 LWJGL spvc 绑定的核心入口，必须在
for sym in spvc_context_create spvc_context_parse_spirv spvc_compiler_compile spvc_get_version; do
    if ! ohos-readelf -sW "$OUTPUT_DIR/libspirv-cross.so" 2>/dev/null | grep -q " $sym\$"; then
        echo "  ERROR: missing $sym in libspirv-cross.so"; exit 1
    fi
done
echo "  spvc core symbols OK"

echo ""
echo "[4/4] Verifying shaderc..."
NSHADERC=$(ohos-readelf -sW "$OUTPUT_DIR/libshaderc.so" 2>/dev/null | grep -c ' shaderc_' || echo 0)
echo "  exported shaderc_* symbols: $NSHADERC"
echo "  NEEDED: $(ohos-readelf -d "$OUTPUT_DIR/libshaderc.so" 2>/dev/null | grep NEEDED | tr -s ' ' | paste -sd' ')"
for sym in shaderc_compiler_initialize shaderc_compile_into_spv shaderc_result_get_bytes; do
    if ! ohos-readelf -sW "$OUTPUT_DIR/libshaderc.so" 2>/dev/null | grep -q " $sym\$"; then
        echo "  ERROR: missing $sym in libshaderc.so"; exit 1
    fi
done
echo "  shaderc core symbols OK"

# ============================================================
# Step 4b: ABI 防回归 —— 产物绝不能含 std::__1:: 符号（必须全是 __n1）
#   这是本次崩溃的根因守门：含任何 __1 iostream/locale 符号 = 用错了 Ubuntu 头，
#   一上真机 MC 26.2 必崩 symbol not found。宁可在这里 fail，不让坏产物流出。
# ============================================================
echo ""
echo "[ABI] Checking libc++ namespace (__n1 expected, __1 forbidden)..."
abi_guard() {
    local so="$1"
    local n1 nn1
    n1=$(ohos-readelf -sW "$so" 2>/dev/null | grep -c 'NSt3__1' || true)
    nn1=$(ohos-readelf -sW "$so" 2>/dev/null | grep -c 'NSt4__n1' || true)
    echo "  $(basename "$so"): __1=$n1  __n1=$nn1"
    if [ "$n1" -ne 0 ]; then
        echo "  ERROR: $(basename "$so") 含 $n1 个 std::__1:: 符号（应为 0）！"
        echo "         说明编译用错了 Ubuntu libc++-15 头（__1），与 HarmonyOS libc++（__n1）ABI 不兼容。"
        echo "         真机 MC 26.2 会崩 'symbol not found'。检查 OHOS_LIBCXX_DIR 是否指向 __n1 头。"
        ohos-readelf -sW "$so" 2>/dev/null | grep 'NSt3__1' | head -5
        exit 1
    fi
}
abi_guard "$OUTPUT_DIR/libspirv-cross.so"
abi_guard "$OUTPUT_DIR/libshaderc.so"
echo "  ABI OK — 两个产物均为纯 __n1，与设备 libc++_shared.so 一致"


echo ""
echo "============================================"
echo " Build complete!"
echo "   $OUTPUT_DIR/libspirv-cross.so   (spvc_* = $NSPVC)"
echo "   $OUTPUT_DIR/libshaderc.so       (shaderc_* = $NSHADERC)"
echo "============================================"
echo ""
echo "Next (on host):"
echo "  1. cp 两个 .so 到 entry/libs/arm64-v8a/"
echo "  2. mc_launcher.cpp::phase_setProperties 已设 org.lwjgl.shaderc.libname / org.lwjgl.spvc.libname"
echo "  3. deps.lock 填 [shaderc-native] / [spvc-native] 的 tag + sha256"
echo "  4. 真机 MC 26.2 选 Vulkan，确认 shaderc/spvc loadNative 不崩"

# ============================================================
#  准备 OHOS libc++ 头（构建前置，一次性）
# ============================================================
#  本脚本要求 OHOS_LIBCXX_DIR（默认 /output/ohos-libcxx）下有 OHOS NDK 的 __n1 ABI
#  libc++ 头 + aarch64 libc++ 库。NDK 在宿主机（Windows/macOS/Linux），容器未挂载，
#  故 release 流程需先把它们 stage 到本次任务可见目录（/output 对应外部任务 out）。
#
#  宿主机一次性 stage（NDK 路径按实际填）：
#    NDK=/path/to/command-line-tools/sdk/default/openharmony/native/llvm
#    DST=/path/to/.workspace/build/<task>/out/ohos-libcxx
#    mkdir -p "$DST/include/c++/v1" "$DST/lib"
#    cp -a "$NDK/include/libcxx-ohos/include/c++/v1/." "$DST/include/c++/v1/"
#    cp "$NDK/lib/aarch64-linux-ohos/libc++_shared.so"  "$DST/lib/"
#    # 校验：grep _LIBCPP_ABI_NAMESPACE "$DST/include/c++/v1/__config_site"  → 应为 __n1
#
#  Windows PowerShell 版见 scripts/stage_ohos_libcxx.ps1（如已添加）。
#  关键校验：__config_site 必须是 `_LIBCPP_ABI_NAMESPACE __n1`，否则本脚本 Step 0 会拒绝运行。
# ============================================================
