#!/bin/bash
set -e

# ============================================================
#  LWJGL native for HarmonyOS NEXT — Docker 构建脚本
#  基于 LWJGL **官方** release tag（默认 3.4.2；可用 LWJGL_TAG 覆盖）。
#
#  2026-08-01 v8: 现代槽位 3.4.1 → 3.4.2（MC 26.3 / SDL3 绑定要求）。
#    - 整套替换无后缀现代 native；独立的 3.2.3/_v322 与 LWJGL2 槽位不动。
#    - libffi 3.5.1 → 3.7.1，对齐 LWJGL 3.4.2 release notes 与生成绑定。
#  2026-05-30 v7: 升级到 3.4.1（MC 26.1 / Sodium 0.8.12 要求；同时配合方案 B 上游原版 GLFW.class）。
#    - clone tag 3.3.3 → 3.4.1（LWJGL_TAG 参数化）
#    - core/src/main/c 文件名变化：org_lwjgl_system_Callback.c → org_lwjgl_system_Upcalls.c
#      （3.4 把 Callback 实现重命名为 Upcalls）。其余文件 glob，自动跟随。
#    - libffi 3.4.6 → 3.5.1：LWJGL 3.4.1 的 LibFFI 绑定新增 ffi_get_version /
#      ffi_get_version_number / ffi_get_default_abi / ffi_get_closure_size /
#      ffi_get_struct_offsets（libffi 3.5 才有），旧版链接报 undefined symbol。
#  2026-05-19 v6: 切到官方源，弃用 PojavLauncherTeam fork（fork 的 Version.class 是
#    3.3.2-snapshot，导致 sodium 检查失败）。详见 docs/archive/lwjgl-3.4.1-upgrade/LWJGL_3.3.3_UPGRADE.md。
#
#  构建产物:
#    liblwjgl.so          — LWJGL 核心 (JNI + libffi)
#    liblwjgl_opengl.so   — OpenGL 绑定
#    liblwjgl_stb.so      — STB 图像/字体/音频
#    liblwjgl_spng.so     — SPNG PNG 编解码（内嵌 miniz）
#    liblwjgl_tinyfd.so   — TinyFileDialogs (stub)
#    liblwjgl_vma.so      — Vulkan Memory Allocator JNI 绑定（MC 26.2 启动 eager-load；
#                           C++ 用 OHOS libc++ __n1 头，见 Step 7）
#
#  用法:
#    docker run --rm \
#      -e LWJGL_TAG=3.4.2 \
#      -v "/path/to/ohos/sysroot:/ohos-sysroot:ro" \
#      -v "/path/to/output:/output" \
#      -v "/path/to/entry/libs/arm64-v8a:/ohos-libs:ro" \
#      openjdk-ohos-builder /build/build_lwjgl_ohos.sh
#
#  使用 Docker volume 缓存加速后续构建:
#    docker run --rm -v lwjgl_cache:/build \
#      -v ... (同上)
#      openjdk-ohos-builder /build/build_lwjgl_ohos.sh
#
#  JNI 头文件: 从 OpenJDK 17 提取的 jni.h + jni_md.h
#    可以用项目中 entry/src/main/cpp/jvm/jni.h 和 jni_md.h
#    或者用 Docker 中 $JAVA_HOME/include/ 下的
# ============================================================

OHOS_SYSROOT_ORIG=${OHOS_SYSROOT:-/ohos-sysroot}
WORK_DIR=/build
JOBS=${JOBS:-$(nproc)}
OUTPUT_DIR=${OUTPUT_DIR:-/output}
LIBFFI_VERSION=${LIBFFI_VERSION:-3.7.1}
LWJGL_TAG=${LWJGL_TAG:-3.4.2}
# 2026-06-11 多版本并存：可选 native 文件名后缀（如 _v322），让多套 LWJGL 共存于同一签名
# HAP libs 目录不撞名。空 = 现代槽位（当前 342 套，无后缀）。见 docs/adaptation/LWJGL_MULTIVERSION_PLAN.md §10。
NATIVE_SUFFIX=${NATIVE_SUFFIX:-}

# The modern slot preserves the audited resize-v1 API in the same STB DSO.
# Mount prebuilt/lwjgl3/compat/stb-v1 here (or override AMCL_STB_COMPAT_DIR).
AMCL_STB_COMPAT_DIR=${AMCL_STB_COMPAT_DIR:-/prebuilt/lwjgl3/compat/stb-v1}
if [ "$LWJGL_TAG" = "3.4.2" ] && [ ! -f "$AMCL_STB_COMPAT_DIR/sources.json" ]; then
    echo "ERROR: current prebuilt/lwjgl3/compat/stb-v1 input is required for the modern compatibility build"
    exit 1
fi

# 2026-06-11 FFI 后端按 LWJGL 版本选：3.2.x 及更早用 dyncall，3.3.0+ 用 libffi。
# dyncall 静态库由 docker/build_dyncall_ohos.sh 预先编出（默认 /output/dyncall-ohos/）。
case "$LWJGL_TAG" in
    3.0*|3.1*|3.2*) FFI_BACKEND=dyncall ;;
    *)              FFI_BACKEND=libffi ;;
esac
DYNCALL_LIBS_DIR=${DYNCALL_LIBS_DIR:-/output/dyncall-ohos}
echo "  FFI backend for LWJGL $LWJGL_TAG: $FFI_BACKEND"

# JNI 头文件路径 (优先用挂载的，否则用系统 JDK)
if [ -d "/jni-headers" ] && [ -f "/jni-headers/jni.h" ]; then
    JNI_HEADERS=/jni-headers
else
    JNI_HEADERS=${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}/include
fi
JNI_HEADERS_PLATFORM=$JNI_HEADERS/linux

echo "============================================"
echo " LWJGL $LWJGL_TAG native for HarmonyOS NEXT"
echo " Sysroot:     $OHOS_SYSROOT_ORIG"
echo " JNI headers: $JNI_HEADERS"
echo " Jobs:        $JOBS"
echo " Output:      $OUTPUT_DIR"
echo "============================================"

# --- Step 0: 设置工具链 ---
# 不依赖 setup_toolchain.sh 的包装器脚本，直接使用 ohos-clang
# 并显式传递 --target 和 --sysroot 参数
echo ""
echo "[0/6] Setting up toolchain..."

# 复制 sysroot 到可写位置（libffi configure 需要写入测试文件）
OHOS_SYSROOT=/ohos-sysroot-rw
if [ ! -d "$OHOS_SYSROOT/usr/include" ]; then
    echo "  Copying sysroot to writable location..."
    cp -a $OHOS_SYSROOT_ORIG $OHOS_SYSROOT
fi

OHOS_LIBDIR=$OHOS_SYSROOT/usr/lib/aarch64-linux-ohos

# 创建 CRT stub（链接需要）
for f in crtbeginS.o crtendS.o; do
    if [ ! -f "$OHOS_SYSROOT/usr/lib/$f" ]; then
        /usr/bin/ohos-ar rcs $OHOS_SYSROOT/usr/lib/$f 2>/dev/null || true
    fi
done
# 创建 stub 库（musl 内含 pthread/dl/rt）
for lib in libpthread.a libdl.a librt.a; do
    if [ ! -f "$OHOS_LIBDIR/$lib" ]; then
        /usr/bin/ohos-ar rcs $OHOS_LIBDIR/$lib
    fi
done
# CRT 文件符号链接
for f in Scrt1.o crt1.o crti.o crtn.o; do
    if [ -f "$OHOS_LIBDIR/$f" ] && [ ! -f "$OHOS_SYSROOT/usr/lib/$f" ]; then
        ln -sf aarch64-linux-ohos/$f $OHOS_SYSROOT/usr/lib/$f
    fi
done
if [ ! -f "$OHOS_LIBDIR/Scrt1.o" ] && [ -f "$OHOS_LIBDIR/crt1.o" ]; then
    cp $OHOS_LIBDIR/crt1.o $OHOS_LIBDIR/Scrt1.o
    ln -sf aarch64-linux-ohos/Scrt1.o $OHOS_SYSROOT/usr/lib/Scrt1.o
fi
# libgcc/libgcc_s stub（OHOS 用 compiler-rt，但链接器会找 libgcc）
if [ ! -f "$OHOS_LIBDIR/libgcc.a" ]; then
    /usr/bin/ohos-ar rcs $OHOS_LIBDIR/libgcc.a
fi
if [ ! -f "$OHOS_LIBDIR/libgcc_s.so" ]; then
    ln -sf libc.so $OHOS_LIBDIR/libgcc_s.so
fi
# 库符号链接
for lib in libc.so libm.so libz.so libgcc.a libgcc_s.so; do
    if [ -f "$OHOS_LIBDIR/$lib" ] && [ ! -e "$OHOS_SYSROOT/usr/lib/$lib" ]; then
        ln -sf aarch64-linux-ohos/$lib $OHOS_SYSROOT/usr/lib/$lib
    fi
done
# include 符号链接
for d in bits asm; do
    if [ ! -e "$OHOS_SYSROOT/usr/include/$d" ]; then
        ln -sf aarch64-linux-ohos/$d $OHOS_SYSROOT/usr/include/$d
    fi
done

# 创建编译器包装脚本（configure 等工具无法处理含空格的 CC 变量）
cat > /tmp/ohos-cc <<CCEOF
#!/bin/bash
exec /usr/bin/ohos-clang --target=aarch64-linux-ohos --sysroot=$OHOS_SYSROOT -L$OHOS_LIBDIR -fuse-ld=lld "\$@"
CCEOF
cat > /tmp/ohos-cxx <<CCEOF
#!/bin/bash
exec /usr/bin/ohos-clang++ --target=aarch64-linux-ohos --sysroot=$OHOS_SYSROOT -stdlib=libc++ -nostdlib++ -L$OHOS_LIBDIR -fuse-ld=lld "\$@"
CCEOF
chmod +x /tmp/ohos-cc /tmp/ohos-cxx

CC=/tmp/ohos-cc
CXX=/tmp/ohos-cxx
AR=/usr/bin/ohos-ar
RANLIB=/usr/bin/ohos-ranlib
STRIP=/usr/bin/ohos-strip

# 验证工具链
echo "  Compiler: $(/usr/bin/ohos-clang --version 2>&1 | head -1)"
echo "  Sysroot:  $OHOS_SYSROOT"
echo "  JNI:      $JNI_HEADERS/jni.h $([ -f $JNI_HEADERS/jni.h ] && echo OK || echo MISSING)"

# 快速编译+链接测试
printf 'int test_func(void){return 42;}\n' > /tmp/cc_test.c
$CC -c /tmp/cc_test.c -o /tmp/cc_test.o || { echo "ERROR: compile test failed!"; exit 1; }
echo "  Compile test: OK"
printf 'int main(){return 0;}\n' > /tmp/link_test.c
$CC /tmp/link_test.c -o /tmp/link_test || { echo "ERROR: link test failed!"; exit 1; }
echo "  Link test: OK"

# ============================================================
# Step 1: 构建 libffi
# ============================================================
echo ""
echo "[1/6] FFI backend = $FFI_BACKEND"
if [ "$FFI_BACKEND" = "libffi" ]; then
echo "  Building libffi $LIBFFI_VERSION..."
cd $WORK_DIR

# 版本专属目录，避免升级 LIBFFI_VERSION 后复用旧版本缓存（2026-05-30 踩坑：
# 3.4.1 需要 libffi 3.5.1 的 ffi_get_version 等符号，但 /build/libffi 缓存的是 3.4.6 →
# 链接 undefined symbol。改成 libffi-<ver> 目录后，换版本自动用新目录）。
LIBFFI_DIR="libffi-$LIBFFI_VERSION"
if [ ! -d "$LIBFFI_DIR" ]; then
    wget -q https://github.com/libffi/libffi/releases/download/v$LIBFFI_VERSION/libffi-$LIBFFI_VERSION.tar.gz
    tar xf libffi-$LIBFFI_VERSION.tar.gz
    rm -f libffi-$LIBFFI_VERSION.tar.gz
fi

cd "$LIBFFI_DIR"

if [ ! -f ".libs/libffi.a" ]; then
    # CC 包含 --target 和 --sysroot 参数，configure 能正确传递给编译器
    # 用 aarch64-linux-gnu 作为 host triplet（autotools 能识别）
    bash configure \
        --host=aarch64-linux-gnu \
        --prefix=$PWD/install \
        CC="$CC" \
        CXX="$CXX" \
        AR="$AR" \
        RANLIB="$RANLIB" \
        STRIP="$STRIP" \
        LD="/usr/bin/ld.lld" \
        --disable-shared \
        --enable-static \
        --disable-docs \
        --disable-multi-os-directory

    make -j$JOBS
    echo "  libffi.a built: $(ls -la .libs/libffi.a)"
else
    echo "  libffi.a already built, skipping"
fi

# libffi configure 在子目录中构建，找到实际的 .a 文件
LIBFFI_A=$(find $WORK_DIR/$LIBFFI_DIR -name 'libffi.a' -path '*/.libs/*' | head -1)
if [ -z "$LIBFFI_A" ]; then
    echo "ERROR: libffi.a not found!"; exit 1
fi
echo "  Using: $LIBFFI_A"
FFI_LINK="$LIBFFI_A"
else
    # dyncall（LWJGL 3.2.x）：使用 docker/build_dyncall_ohos.sh 预编的静态库
    echo "  Using prebuilt dyncall from $DYNCALL_LIBS_DIR"
    DC_A="$DYNCALL_LIBS_DIR/libdyncall_s.a"
    DCB_A="$DYNCALL_LIBS_DIR/libdyncallback_s.a"
    DL_A="$DYNCALL_LIBS_DIR/libdynload_s.a"
    for a in "$DC_A" "$DCB_A" "$DL_A"; do
        [ -f "$a" ] || { echo "ERROR: dyncall lib missing: $a — 先运行 docker/build_dyncall_ohos.sh"; exit 1; }
    done
    FFI_LINK="$DC_A $DCB_A $DL_A"
fi
cd $WORK_DIR

# ============================================================
# Step 2: 克隆 LWJGL 源码
# ============================================================
echo ""
echo "[2/6] Cloning LWJGL $LWJGL_TAG (official release tag)..."

# 版本专属 clone 目录，避免不同版本污染同一缓存（lwjgl3-<tag>）
LWJGL_SRC_DIR="lwjgl3-$LWJGL_TAG"
if [ ! -d "$LWJGL_SRC_DIR" ]; then
    git clone --depth 1 --branch "$LWJGL_TAG" \
        https://github.com/LWJGL/lwjgl3.git "$LWJGL_SRC_DIR"
else
    echo "  $LWJGL_SRC_DIR already cloned, skipping"
fi

LWJGL_ROOT=$WORK_DIR/$LWJGL_SRC_DIR/modules/lwjgl
CORE_MAIN=$LWJGL_ROOT/core/src/main/c
CORE_GEN=$LWJGL_ROOT/core/src/generated/c

# FFI include 路径（按后端）：libffi（3.3+）或 dyncall（3.2.x）
if [ "$FFI_BACKEND" = "libffi" ]; then
    FFI_INC="-I$CORE_MAIN/libffi -I$CORE_MAIN/libffi/aarch64"
else
    FFI_INC="-I$CORE_MAIN/dyncall"
fi

# ============================================================
# 通用编译参数
# ============================================================
CFLAGS_COMMON="-O3 -fPIC -DNDEBUG -DLWJGL_LINUX -DLWJGL_arm64"
CFLAGS_COMMON="$CFLAGS_COMMON -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -D_GNU_SOURCE"
CFLAGS_COMMON="$CFLAGS_COMMON -D_FILE_OFFSET_BITS=64"
# __ANDROID_API__=24: 跳过 LinuxConfig.h 中的 preadv/pwritev stub（OHOS musl 已提供）
CFLAGS_COMMON="$CFLAGS_COMMON -D__ANDROID_API__=24"
CFLAGS_COMMON="$CFLAGS_COMMON -I$JNI_HEADERS -I$JNI_HEADERS_PLATFORM"
CFLAGS_COMMON="$CFLAGS_COMMON -I$CORE_MAIN -I$CORE_MAIN/linux"

# version script: 只导出 Java_* 和 JNI_OnLoad，隐藏内部符号
# 减小 .so 体积 + 加快 dlopen
cat > $WORK_DIR/lwjgl_exports.ver << 'VSCRIPT'
{
  global:
    Java_*;
    JNI_OnLoad;
  local:
    *;
};
VSCRIPT

LDFLAGS_COMMON="-shared -fPIC -O3 -z noexecstack -Wl,--no-undefined"
LDFLAGS_COMMON="$LDFLAGS_COMMON -Wl,--version-script=$WORK_DIR/lwjgl_exports.ver"

BUILD_DIR=$WORK_DIR/lwjgl_build-$LWJGL_TAG
# 2026-06-11：build 目录按版本隔离 + 每次清空。否则上一次（如 3.4.1）的 *.o（含 libffi LibFFI.o）
# 会被 $CORE_BUILD/*.o glob 进链接，导致 3.2.x（dyncall）链接报 ffi_* undefined。
rm -rf $BUILD_DIR
mkdir -p $BUILD_DIR

# ============================================================
# Step 3: 编译 liblwjgl.so (core)
# ============================================================
echo ""
echo "[3/6] Building liblwjgl.so (core)..."

CORE_BUILD=$BUILD_DIR/core
mkdir -p $CORE_BUILD

# 跳过 liburing（OHOS 不支持 io_uring，MC 不需要）
LIBURING_DIR=$CORE_MAIN/linux/liburing

# __clear_cache: 不再内嵌 shim，运行时链接 libclear_cache.so
# （entry/libs/arm64-v8a/ 中已有 JVM 构建的 libclear_cache.so）
# 链接时通过 /ohos-libs 挂载点找到该库
OHOS_LIBS=${OHOS_LIBS:-/ohos-libs}
if [ ! -f "$OHOS_LIBS/libclear_cache.so" ]; then
    echo "  WARNING: libclear_cache.so not found at $OHOS_LIBS/"
    echo "  Falling back to embedded __clear_cache shim"
    cat > $CORE_BUILD/clear_cache_shim.c << 'SHIM'
#include <stdint.h>
void __clear_cache(void* begin, void* end) {
    uint64_t addr = (uint64_t)begin;
    uint64_t end_addr = (uint64_t)end;
    uint64_t cache_line = 64;
    for (; addr < end_addr; addr += cache_line) {
        __asm__ volatile("dc cvau, %0" :: "r"(addr));
    }
    __asm__ volatile("dsb ish");
    for (addr = (uint64_t)begin; addr < end_addr; addr += cache_line) {
        __asm__ volatile("ic ivau, %0" :: "r"(addr));
    }
    __asm__ volatile("dsb ish\nisb");
}
SHIM
    $CC -c -std=gnu11 -O3 -fPIC $CORE_BUILD/clear_cache_shim.c -o $CORE_BUILD/clear_cache_shim.o
    USE_LIBCLEAR_CACHE=0
else
    echo "  Using libclear_cache.so from $OHOS_LIBS/"
    USE_LIBCLEAR_CACHE=1
fi

# 3a: 编译 core main C 文件
# 注：3.4 把 org_lwjgl_system_Callback.c 重命名为 org_lwjgl_system_Upcalls.c。
# 这里对两种命名都兼容（只编译实际存在的那个），避免跨版本断裂。
echo "  Compiling core main..."
# 2026-06-11 多版本：core main 文件集合随版本变（3.2.x 无 SharedLibraryUtil.c；
# Callback.c≤3.3 / Upcalls.c≥3.4）。改为"候选列表按存在过滤"，不硬编码。
CORE_MAIN_CANDIDATES="common_tools.c \
           org_lwjgl_system_MemoryUtil.c \
           org_lwjgl_system_SharedLibraryUtil.c \
           org_lwjgl_system_ThreadLocalUtil.c \
           org_lwjgl_system_Upcalls.c \
           org_lwjgl_system_Callback.c"
CORE_MAIN_SRCS=""
for f in $CORE_MAIN_CANDIDATES; do
    [ -f "$CORE_MAIN/$f" ] && CORE_MAIN_SRCS="$CORE_MAIN_SRCS $CORE_MAIN/$f"
done
echo "  core main srcs: $(for s in $CORE_MAIN_SRCS; do basename $s; done | paste -sd' ')"
for src in $CORE_MAIN_SRCS; do
    name=$(basename $src .c)
    $CC -c -std=gnu11 $CFLAGS_COMMON \
        $FFI_INC \
        -I$LIBURING_DIR -I$LIBURING_DIR/include \
        $src -o $CORE_BUILD/${name}.o
done

# 3b: 编译 core generated C 文件
echo "  Compiling core generated..."
for src in $CORE_GEN/*.c; do
    name=$(basename $src .c)
    $CC -c -std=gnu11 $CFLAGS_COMMON \
        $FFI_INC \
        $src -o $CORE_BUILD/${name}.o
done

# 3c: 编译 core generated/c/linux 文件（跳过 liburing 相关）
echo "  Compiling core generated (linux)..."
# 3.2.x 的 LinuxLWJGL.h 无条件 #include <X11/X.h>/<Xlib.h>（3.4.1 不再如此）。
# OHOS 无 X11 → 用 /build/stub-headers 的 X11 桩头让其编过（这些 .c 实际不用 X11 类型）。
X11_STUB_INC=""
[ -d /build/stub-headers/X11 ] && X11_STUB_INC="-I/build/stub-headers"
for src in $CORE_GEN/linux/*.c; do
    name=$(basename $src .c)
    # 跳过 liburing 相关的 JNI 绑定（OHOS 不支持 io_uring）
    case "$name" in *liburing*) continue ;; esac
    $CC -c -std=gnu11 $CFLAGS_COMMON \
        $FFI_INC $X11_STUB_INC \
        $src -o $CORE_BUILD/${name}.o
done

# 3c.5: dyncall 后端补 dlinfo 桩（OHOS musl 无 dlinfo；dyncall 的 dlGetLibraryPath 用它）。
# 桩返回 -1（失败）→ dlGetLibraryPath 走失败分支返回空路径（仅诊断用，无功能影响）。
if [ "$FFI_BACKEND" = "dyncall" ]; then
    cat > $CORE_BUILD/dlinfo_stub.c << 'DLSTUB'
/* OHOS musl 不提供 dlinfo；提供最小桩满足 dyncall dynload 链接需求。 */
int dlinfo(void *handle, int request, void *info) {
    (void)handle; (void)request; (void)info;
    return -1; /* 失败：调用方据此回退到空路径 */
}
DLSTUB
    $CC -c -std=gnu11 -O3 -fPIC $CORE_BUILD/dlinfo_stub.c -o $CORE_BUILD/dlinfo_stub.o
    echo "  Added dlinfo stub (dyncall/musl)"
fi

# 3d: 链接 liblwjgl.so
echo "  Linking liblwjgl.so..."
if [ "$USE_LIBCLEAR_CACHE" = "1" ]; then
    # 链接外部 libclear_cache.so（与 JVM 共享同一个实现）
    $CC $LDFLAGS_COMMON \
        -o $BUILD_DIR/liblwjgl.so \
        $CORE_BUILD/*.o \
        $FFI_LINK \
        -L$OHOS_LIBS -ldl -lm -lclear_cache
else
    # 使用内嵌 shim（fallback）
    $CC $LDFLAGS_COMMON \
        -o $BUILD_DIR/liblwjgl.so \
        $CORE_BUILD/*.o \
        $FFI_LINK \
        -ldl -lm
fi
$STRIP --strip-unneeded $BUILD_DIR/liblwjgl.so
echo "  $(ls -la $BUILD_DIR/liblwjgl.so)"

# 3e: 校验 libffi 关键符号已链接（仅 libffi 后端；dyncall 后端跳过）。
# 2026-05-30 踩坑：LWJGL 3.4.1 的 LibFFI 绑定调用 ffi_get_version / ffi_get_default_abi 等
# （libffi ≥ 3.5），若用旧 libffi 编，这里会是 UND（未定义引用）→ 上链接期已 fail，但若链接
# 阶段侥幸过了也要在此兜底确认。导出符号是 Java_*，ffi_* 是内部静态链接，应已 resolve（非 UND）。
if [ "$FFI_BACKEND" = "libffi" ] && command -v readelf >/dev/null 2>&1; then
    UND_FFI=$(readelf -sW $BUILD_DIR/liblwjgl.so 2>/dev/null | grep -E ' UND .*ffi_get_(version|default_abi|closure_size)' || true)
    if [ -n "$UND_FFI" ]; then
        echo "ERROR: liblwjgl.so has UNDEFINED ffi_get_* symbols — libffi too old for LWJGL $LWJGL_TAG."
        echo "       Bump LIBFFI_VERSION (LWJGL 3.4.x needs libffi >= 3.5.x). Got: $LIBFFI_VERSION"
        echo "$UND_FFI"
        exit 1
    fi
    echo "  libffi symbol check OK (ffi_get_* resolved, libffi $LIBFFI_VERSION matches LWJGL $LWJGL_TAG)"
fi
echo ""
echo "[4/6] Building liblwjgl_opengl.so..."

OGL_BUILD=$BUILD_DIR/opengl
OGL_MAIN=$LWJGL_ROOT/opengl/src/main/c
OGL_GEN=$LWJGL_ROOT/opengl/src/generated/c
mkdir -p $OGL_BUILD

# 编译所有 generated C 文件（排除 WGL，那是 Windows 的）
for src in $OGL_GEN/*.c; do
    name=$(basename $src .c)
    # 跳过 Windows WGL
    if [ "$name" = "org_lwjgl_opengl_WGL" ]; then
        continue
    fi
    $CC -c -std=gnu11 $CFLAGS_COMMON \
        -I$OGL_MAIN \
        $src -o $OGL_BUILD/${name}.o
done

echo "  Linking liblwjgl_opengl.so..."
$CC $LDFLAGS_COMMON \
    -o $BUILD_DIR/liblwjgl_opengl.so \
    $OGL_BUILD/*.o
$STRIP --strip-unneeded $BUILD_DIR/liblwjgl_opengl.so
echo "  $(ls -la $BUILD_DIR/liblwjgl_opengl.so)"

# ============================================================
# Step 5: 编译 liblwjgl_stb.so
# ============================================================
echo ""
echo "[5/6] Building liblwjgl_stb.so..."

STB_BUILD=$BUILD_DIR/stb
STB_MAIN=$LWJGL_ROOT/stb/src/main/c
STB_GEN=$LWJGL_ROOT/stb/src/generated/c
mkdir -p $STB_BUILD

# 注意：不单独编译 stb_vorbis.c，generated 的 JNI 文件会 #include 它
# 编译 generated C 文件
for src in $STB_GEN/*.c; do
    name=$(basename $src .c)
    $CC -c -std=gnu11 $CFLAGS_COMMON \
        -isystem$STB_MAIN \
        $src -o $STB_BUILD/${name}.o
done

echo "  Linking liblwjgl_stb.so..."
if [ "$LWJGL_TAG" = "3.4.2" ]; then
    python3 - "$AMCL_STB_COMPAT_DIR" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
for item in json.loads((root / 'sources.json').read_text())['files']:
    data = (root / item['file']).read_bytes()
    assert len(data) == item['size'] and hashlib.sha256(data).hexdigest() == item['sha256'], item['file']
PY
    sed 's/Java_org_lwjgl_stb_STBImageResize_/Java_org_lwjgl_stb_STBImageResizeV1_/g' \
        "$AMCL_STB_COMPAT_DIR/org_lwjgl_stb_STBImageResize.c" > "$STB_BUILD/stb_resize_v1.c"
    $CC -c -std=gnu11 $CFLAGS_COMMON -I"$AMCL_STB_COMPAT_DIR" \
        "$STB_BUILD/stb_resize_v1.c" -o "$STB_BUILD/stb_resize_v1.o"
fi
$CC $LDFLAGS_COMMON \
    -o $BUILD_DIR/liblwjgl_stb.so \
    $STB_BUILD/*.o \
    -lm
$STRIP --strip-unneeded $BUILD_DIR/liblwjgl_stb.so
echo "  $(ls -la $BUILD_DIR/liblwjgl_stb.so)"

# ============================================================
# Step 5.5: 编译 liblwjgl_spng.so（SPNG + miniz）
# ============================================================
# generated SPNG.c 会以 SPNG_STATIC + SPNG_USE_MINIZ include spng.c；上游
# Linux 构建另外编译 core/dependencies/miniz/*.c。本步保持相同源码形状，
# 生成自包含 JNI 库，不依赖设备上的 libpng/zlib。
echo ""
echo "[5.5/7] Building liblwjgl_spng.so..."

SPNG_BUILD=$BUILD_DIR/spng
SPNG_MAIN=$LWJGL_ROOT/spng/src/main/c
SPNG_GEN=$LWJGL_ROOT/spng/src/generated/c
MINIZ_DIR=$LWJGL_ROOT/core/src/main/c/dependencies/miniz

if [ ! -d "$SPNG_GEN" ]; then
    echo "  spng skipped (module absent from LWJGL $LWJGL_TAG)."
elif [ ! -f "$SPNG_GEN/org_lwjgl_util_spng_SPNG.c" ] || \
     [ ! -f "$SPNG_GEN/org_lwjgl_util_spng_LibSPNG.c" ]; then
    echo "ERROR: incomplete SPNG generated source set in $SPNG_GEN"
    echo "       both org_lwjgl_util_spng_SPNG.c and org_lwjgl_util_spng_LibSPNG.c are required"
    exit 1
else
mkdir -p $SPNG_BUILD

echo "  Compiling SPNG generated JNI..."
for src in $SPNG_GEN/*.c; do
    name=$(basename $src .c)
    $CC -c -std=gnu11 $CFLAGS_COMMON \
        -I$SPNG_MAIN -I$MINIZ_DIR \
        $src -o $SPNG_BUILD/${name}.o
done

echo "  Compiling miniz..."
for src in $MINIZ_DIR/*.c; do
    name=$(basename $src .c)
    $CC -c -std=gnu11 $CFLAGS_COMMON \
        -I$MINIZ_DIR \
        $src -o $SPNG_BUILD/${name}.o
done

echo "  Linking liblwjgl_spng.so..."
$CC $LDFLAGS_COMMON \
    -o $BUILD_DIR/liblwjgl_spng.so \
    $SPNG_BUILD/*.o \
    -lm
$STRIP --strip-unneeded $BUILD_DIR/liblwjgl_spng.so
echo "  $(ls -la $BUILD_DIR/liblwjgl_spng.so)"
fi

# ============================================================
# Step 6: 编译 liblwjgl_tinyfd.so
# ============================================================
echo ""
echo "[6/6] Building liblwjgl_tinyfd.so..."

TFD_BUILD=$BUILD_DIR/tinyfd
TFD_MAIN=$LWJGL_ROOT/tinyfd/src/main/c
TFD_GEN=$LWJGL_ROOT/tinyfd/src/generated/c
mkdir -p $TFD_BUILD

# 编译 tinyfiledialogs.c
$CC -c -std=gnu11 $CFLAGS_COMMON \
    -I$TFD_MAIN \
    $TFD_MAIN/tinyfiledialogs.c -o $TFD_BUILD/tinyfiledialogs.o

# 编译 generated
$CC -c -std=gnu11 $CFLAGS_COMMON \
    -I$TFD_MAIN \
    $TFD_GEN/org_lwjgl_util_tinyfd_TinyFileDialogs.c -o $TFD_BUILD/org_lwjgl_util_tinyfd_TinyFileDialogs.o

echo "  Linking liblwjgl_tinyfd.so..."
$CC $LDFLAGS_COMMON \
    -o $BUILD_DIR/liblwjgl_tinyfd.so \
    $TFD_BUILD/*.o
$STRIP --strip-unneeded $BUILD_DIR/liblwjgl_tinyfd.so
echo "  $(ls -la $BUILD_DIR/liblwjgl_tinyfd.so)"

# ============================================================
# Step 7: 编译 liblwjgl_vma.so（Vulkan Memory Allocator JNI 绑定）
# ============================================================
#  背景（2026-05-31 真机定位）：MC 26.2 启动期 eager-load vma（与 shaderc/spvc 同列），
#  缺 liblwjgl_vma.so → UnsatisfiedLinkError: Failed to locate library: liblwjgl_vma.so → 崩。
#  vma 与 shaderc/spvc 不同：它是 LWJGL **JNI 风格**模块（LibVma.loadSystem 找固定名
#  liblwjgl_vma.so，无 libname 可重定向），native = VMA header-only 实现 + LWJGL JNI 胶水。
#
#  ⚠️ vma 是 C++（org_lwjgl_util_vma_Vma.cpp 含 VMA_IMPLEMENTATION），必须用 OHOS NDK 的
#     libc++ 头（__n1 ABI）编译，否则与设备 libc++_shared.so（__n1）ABI 不符 → 运行时
#     symbol not found（同 shaderc 的 iostream typeinfo 坑，见 build_shaderc_ohos.sh Step 0）。
#     故这里用专门的 CXX_VMA wrapper（OHOS libc++ 头），不能用上面的 $CXX（Ubuntu 头 = __1）。
#
#  VMA 配置（见 Vma.cpp 顶部）：VMA_STATIC/DYNAMIC_VULKAN_FUNCTIONS=0 → 不引用任何 vk* 符号
#  （运行时由调用方传函数指针），所以**不链接 libvulkan**，只需 Vulkan 类型头来编译。
#  Vulkan 头用 LWJGL vulkan 模块自带的（VK_HEADER_VERSION 342，配套 VMA 1.4），
#  而非 OHOS sysroot 的（309，偏旧，可能缺 VMA 1.4 用到的类型）。
echo ""
echo "[7/7] Building liblwjgl_vma.so..."

# 2026-06-11 多版本：vma 仅 3.3+/3.4（libffi 后端、Vulkan MC）需要。3.2.x（老 MC 套，dyncall）
# 即便源码带 vma 模块也不需要（1.13–1.16.5 无 Vulkan）→ 跳过整步。
VMA_GEN_DIR=$LWJGL_ROOT/vma/src/generated/c
if [ "$FFI_BACKEND" != "libffi" ] || [ ! -d "$VMA_GEN_DIR" ] || [ ! -f "$VMA_GEN_DIR/org_lwjgl_util_vma_Vma.cpp" ]; then
    echo "  vma skipped (FFI=$FFI_BACKEND / module 适用性) — 老 MC 套不需要 Vulkan vma。"
else
# stage 办法见 docker/build_shaderc_ohos.sh 文件尾“准备 OHOS libc++ 头”。
OHOS_LIBCXX_DIR=${OHOS_LIBCXX_DIR:-/output/ohos-libcxx}
OHOS_CXX_INC=$OHOS_LIBCXX_DIR/include/c++/v1
OHOS_CXX_LIB=$OHOS_LIBCXX_DIR/lib
if [ ! -f "$OHOS_CXX_INC/__config_site" ] || ! grep -q '_LIBCPP_ABI_NAMESPACE __n1' "$OHOS_CXX_INC/__config_site"; then
    echo "ERROR: OHOS libc++ (__n1) headers not found / wrong ABI under $OHOS_LIBCXX_DIR"
    echo "       liblwjgl_vma.so 必须用 __n1 头编译，否则真机 MC 26.2 启动崩 symbol not found。"
    echo "       stage 办法见 docker/build_shaderc_ohos.sh 文件尾说明。"
    exit 1
fi

# clang 的 -stdlib=libc++ 会按链接名查 libc++.so；SDK 交付名是
# libc++_shared.so（其 SONAME 也必须保持该名称）。构建目录内补一个副本用于 -lc++ 解析。
if [ ! -f "$OHOS_CXX_LIB/libc++_shared.so" ]; then
    echo "ERROR: missing $OHOS_CXX_LIB/libc++_shared.so"
    exit 1
fi
if [ ! -f "$OHOS_CXX_LIB/libc++.so" ]; then
    cp "$OHOS_CXX_LIB/libc++_shared.so" "$OHOS_CXX_LIB/libc++.so"
fi

# vma 专用 C++ wrapper：OHOS libc++ 头（__n1）+ musl/rune define（同 shaderc）。
cat > /tmp/ohos-cxx-vma <<CXXEOF
#!/bin/bash
exec /usr/bin/ohos-clang++ --target=aarch64-linux-ohos --sysroot=$OHOS_SYSROOT \\
    -stdlib=libc++ -nostdinc++ -isystem $OHOS_CXX_INC \\
    -D_LIBCPP_HAS_MUSL_LIBC -D_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE \\
    -L$OHOS_LIBDIR -L$OHOS_CXX_LIB -fuse-ld=lld "\$@"
CXXEOF
chmod +x /tmp/ohos-cxx-vma
CXX_VMA=/tmp/ohos-cxx-vma

VMA_BUILD=$BUILD_DIR/vma
VMA_MAIN=$LWJGL_ROOT/vma/src/main/c           # vk_mem_alloc.h
VMA_GEN=$LWJGL_ROOT/vma/src/generated/c       # org_lwjgl_util_vma_{Vma,LibVma}.cpp
VKINC=$LWJGL_ROOT/vulkan/src/main/c           # vulkan/vulkan.h（342，配套 VMA 1.4）
mkdir -p $VMA_BUILD

# CFLAGS：复用 CFLAGS_COMMON 的 JNI/core include（含 -D__ANDROID_API__=24 跳 preadv stub），
# 追加 VMA 头 + Vulkan 头路径。注意 CFLAGS_COMMON 是 C 用的，C++ 这里直接展开其 -I/-D。
VMA_CXXFLAGS="-O3 -fPIC -DNDEBUG -DLWJGL_LINUX -DLWJGL_arm64 -D__ANDROID_API__=24 -std=c++17"
VMA_INCLUDES="-I$JNI_HEADERS -I$JNI_HEADERS_PLATFORM -I$CORE_MAIN -I$CORE_MAIN/linux -I$VMA_MAIN -I$VKINC"

echo "  Compiling org_lwjgl_util_vma_Vma.cpp (VMA_IMPLEMENTATION, OHOS libc++ __n1)..."
$CXX_VMA -c $VMA_CXXFLAGS $VMA_INCLUDES \
    $VMA_GEN/org_lwjgl_util_vma_Vma.cpp -o $VMA_BUILD/Vma.o
echo "  Compiling org_lwjgl_util_vma_LibVma.cpp..."
$CXX_VMA -c $VMA_CXXFLAGS $VMA_INCLUDES \
    $VMA_GEN/org_lwjgl_util_vma_LibVma.cpp -o $VMA_BUILD/LibVma.o

echo "  Linking liblwjgl_vma.so..."
# 用 $CXX_VMA 链接（-stdlib=libc++ → driver 从 -L$OHOS_CXX_LIB 解析 -lc++ = OHOS __n1 运行时）。
# version script 只导出 Java_*/JNI_OnLoad（复用上面 lwjgl_exports.ver）。
$CXX_VMA -shared -fPIC -O3 -z noexecstack -Wl,--no-undefined \
    -Wl,--version-script=$WORK_DIR/lwjgl_exports.ver \
    -o $BUILD_DIR/liblwjgl_vma.so \
    $VMA_BUILD/Vma.o $VMA_BUILD/LibVma.o
$STRIP --strip-unneeded $BUILD_DIR/liblwjgl_vma.so
echo "  $(ls -la $BUILD_DIR/liblwjgl_vma.so)"

# vma ABI 防回归：必须纯 __n1（含 __1 = 用错 Ubuntu 头，真机必崩）。
VMA_N1=$(ohos-readelf -sW $BUILD_DIR/liblwjgl_vma.so 2>/dev/null | grep -c 'NSt3__1' || true)
if [ "$VMA_N1" -ne 0 ]; then
    echo "  ERROR: liblwjgl_vma.so 含 $VMA_N1 个 std::__1:: 符号（应为 0）！ABI 不符，真机会崩。"
    exit 1
fi
VMA_JNI=$(ohos-readelf -sW $BUILD_DIR/liblwjgl_vma.so 2>/dev/null | grep -c 'Java_org_lwjgl_util_vma' || true)
echo "  ABI OK（纯 __n1）；导出 $VMA_JNI 个 Java_*_vma JNI 符号"
echo "  NEEDED: $(ohos-readelf -d $BUILD_DIR/liblwjgl_vma.so 2>/dev/null | grep NEEDED | tr -s ' ' | paste -sd' ')"
fi   # end vma module guard (3.2.x 无 vma 时跳过)

# ============================================================
# 输出
# ============================================================
echo ""
echo "============================================"
echo " Build complete! Output files:"
echo "============================================"
mkdir -p $OUTPUT_DIR
# 只拷贝实际编出来的库（3.2.x 无 vma）；NATIVE_SUFFIX 非空时给文件名加后缀（多套共存）。
for lib in liblwjgl.so liblwjgl_opengl.so liblwjgl_stb.so liblwjgl_spng.so liblwjgl_tinyfd.so liblwjgl_vma.so; do
    if [ ! -f "$BUILD_DIR/$lib" ]; then
        echo "  (skip $lib — not built for LWJGL $LWJGL_TAG)"
        continue
    fi
    dest="${lib%.so}${NATIVE_SUFFIX}.so"
    cp $BUILD_DIR/$lib $OUTPUT_DIR/$dest
    size=$(stat -c%s $OUTPUT_DIR/$dest 2>/dev/null || stat -f%z $OUTPUT_DIR/$dest)
    echo "  $dest  $(( size / 1024 )) KB"
done

echo ""
echo "Done! Copy these to your project:"
echo "  entry/libs/arm64-v8a/"
echo ""
echo "提示：使用 Docker volume 缓存加速后续构建："
echo "  docker run --rm \\"
echo "    -v lwjgl_cache:/build \\"
echo "    -v /path/to/sysroot:/ohos-sysroot:ro \\"
echo "    -v /path/to/output:/output \\"
echo "    openjdk-ohos-builder /build/build_lwjgl_ohos.sh"
echo ""
