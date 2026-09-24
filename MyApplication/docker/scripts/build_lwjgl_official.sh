#!/bin/bash
set -e

# ============================================================
#  LWJGL Official Build for HarmonyOS NEXT
#  从 LWJGL 官方源码编译 native .so + Java jar
#  支持任意 LWJGL 3.3.x 版本
#
#  用法: ./build_lwjgl_official.sh [VERSION]
#  例如: ./build_lwjgl_official.sh 3.3.2
#        ./build_lwjgl_official.sh 3.3.3
#
#  输出:
#    /output/lwjgl-<VERSION>/
#      ├── native/
#      │   ├── liblwjgl.so
#      │   ├── liblwjgl_opengl.so
#      │   ├── liblwjgl_stb.so
#      │   └── liblwjgl_tinyfd.so
#      └── jar/
#          ├── lwjgl.jar
#          ├── lwjgl-glfw.jar
#          ├── lwjgl-opengl.jar
#          ├── lwjgl-stb.jar
#          ├── lwjgl-tinyfd.jar
#          ├── lwjgl-jemalloc.jar
#          └── lwjgl-openal.jar
# ============================================================

LWJGL_VERSION=${1:-3.3.2}
WORK_DIR=/build
OUTPUT_DIR=/output/lwjgl-${LWJGL_VERSION}
JOBS=${JOBS:-$(nproc)}
LIBFFI_VERSION=3.4.6

NATIVE_MODULES="core opengl stb tinyfd"
JAVA_ONLY_MODULES="glfw jemalloc openal vulkan egl opengles"
ALL_MODULES="$NATIVE_MODULES $JAVA_ONLY_MODULES"

OHOS_SYSROOT_ORIG=${OHOS_SYSROOT:-/ohos-sysroot}

echo "============================================"
echo " LWJGL ${LWJGL_VERSION} for HarmonyOS NEXT"
echo " Modules: $ALL_MODULES"
echo " Output:  $OUTPUT_DIR"
echo " Jobs:    $JOBS"
echo "============================================"

# JNI 头文件
if [ -d "/jni-headers" ] && [ -f "/jni-headers/jni.h" ]; then
    JNI_HEADERS=/jni-headers
else
    JNI_HEADERS=$(dirname $(find /usr -name jni.h 2>/dev/null | head -1))
fi
JNI_HEADERS_PLATFORM=$JNI_HEADERS/linux
echo "JNI headers: $JNI_HEADERS"

mkdir -p $OUTPUT_DIR/native $OUTPUT_DIR/jar

# ============================================================
# Step 0: 设置 OHOS 工具链（复用已验证的配置）
# ============================================================
echo ""
echo "[0/5] Setting up OHOS toolchain..."

OHOS_SYSROOT=/ohos-sysroot-rw
if [ ! -d "$OHOS_SYSROOT/usr/include" ]; then
    echo "  Copying sysroot to writable location..."
    cp -a $OHOS_SYSROOT_ORIG $OHOS_SYSROOT
fi

OHOS_LIBDIR=$OHOS_SYSROOT/usr/lib/aarch64-linux-ohos

# CRT stubs
for f in crtbeginS.o crtendS.o; do
    [ ! -f "$OHOS_SYSROOT/usr/lib/$f" ] && /usr/bin/ohos-ar rcs $OHOS_SYSROOT/usr/lib/$f 2>/dev/null || true
done
for lib in libpthread.a libdl.a librt.a; do
    [ ! -f "$OHOS_LIBDIR/$lib" ] && /usr/bin/ohos-ar rcs $OHOS_LIBDIR/$lib
done
for f in Scrt1.o crt1.o crti.o crtn.o; do
    [ -f "$OHOS_LIBDIR/$f" ] && [ ! -f "$OHOS_SYSROOT/usr/lib/$f" ] && ln -sf aarch64-linux-ohos/$f $OHOS_SYSROOT/usr/lib/$f
done
[ ! -f "$OHOS_LIBDIR/Scrt1.o" ] && [ -f "$OHOS_LIBDIR/crt1.o" ] && cp $OHOS_LIBDIR/crt1.o $OHOS_LIBDIR/Scrt1.o && ln -sf aarch64-linux-ohos/Scrt1.o $OHOS_SYSROOT/usr/lib/Scrt1.o
[ ! -f "$OHOS_LIBDIR/libgcc.a" ] && /usr/bin/ohos-ar rcs $OHOS_LIBDIR/libgcc.a
[ ! -f "$OHOS_LIBDIR/libgcc_s.so" ] && ln -sf libc.so $OHOS_LIBDIR/libgcc_s.so
for lib in libc.so libm.so libz.so libgcc.a libgcc_s.so; do
    [ -f "$OHOS_LIBDIR/$lib" ] && [ ! -e "$OHOS_SYSROOT/usr/lib/$lib" ] && ln -sf aarch64-linux-ohos/$lib $OHOS_SYSROOT/usr/lib/$lib
done
for d in bits asm; do
    [ ! -e "$OHOS_SYSROOT/usr/include/$d" ] && ln -sf aarch64-linux-ohos/$d $OHOS_SYSROOT/usr/include/$d
done

# 编译器包装脚本（configure 无法处理含空格的 CC 变量）
cat > /tmp/ohos-cc << 'CCEOF'
#!/bin/bash
exec /usr/bin/ohos-clang --target=aarch64-linux-ohos --sysroot=/ohos-sysroot-rw -L/ohos-sysroot-rw/usr/lib/aarch64-linux-ohos -fuse-ld=lld "$@"
CCEOF
chmod +x /tmp/ohos-cc

CC=/tmp/ohos-cc
AR=/usr/bin/ohos-ar
RANLIB=/usr/bin/ohos-ranlib
STRIP=/usr/bin/ohos-strip

# 验证工具链
printf 'int test_func(void){return 42;}\n' > /tmp/cc_test.c
$CC -c /tmp/cc_test.c -o /tmp/cc_test.o || { echo "ERROR: compile test failed!"; exit 1; }
echo "  Toolchain OK"

# ============================================================
# Step 1: Clone LWJGL 源码
# ============================================================
echo ""
echo "[1/5] Cloning LWJGL ${LWJGL_VERSION} from official repo..."

LWJGL_SRC=$WORK_DIR/lwjgl3-${LWJGL_VERSION}
if [ ! -d "$LWJGL_SRC" ]; then
    git clone --depth 1 --branch ${LWJGL_VERSION} \
        https://github.com/LWJGL/lwjgl3.git $LWJGL_SRC
else
    echo "  Already cloned, skipping"
fi

LWJGL_ROOT=$LWJGL_SRC/modules/lwjgl

# ============================================================
# Step 2: Build libffi (core 模块依赖)
# ============================================================
echo ""
echo "[2/5] Building libffi ${LIBFFI_VERSION}..."

cd $WORK_DIR
LIBFFI_A=$(find $WORK_DIR/libffi -name 'libffi.a' -path '*/.libs/*' 2>/dev/null | head -1)
if [ -z "$LIBFFI_A" ]; then
    if [ ! -d "libffi" ]; then
        wget -q https://github.com/libffi/libffi/releases/download/v${LIBFFI_VERSION}/libffi-${LIBFFI_VERSION}.tar.gz
        tar xf libffi-${LIBFFI_VERSION}.tar.gz
        mv libffi-${LIBFFI_VERSION} libffi
        rm -f libffi-${LIBFFI_VERSION}.tar.gz
    fi
    cd libffi
    # 清理之前失败的构建
    rm -rf build
    bash configure \
        --host=aarch64-linux-gnu \
        --prefix=$PWD/install \
        CC="$CC" \
        AR="$AR" \
        RANLIB="$RANLIB" \
        STRIP="$STRIP" \
        LD="/usr/bin/ld.lld" \
        --disable-shared --enable-static \
        --disable-docs --disable-multi-os-directory 2>&1 | tail -3
    make -j$JOBS 2>&1 | tail -3
    LIBFFI_A=$(find $WORK_DIR/libffi -name 'libffi.a' -path '*/.libs/*' | head -1)
    echo "  libffi.a built: $LIBFFI_A"
else
    echo "  libffi.a already built, skipping"
fi

if [ -z "$LIBFFI_A" ]; then
    echo "ERROR: libffi.a not found!"; exit 1
fi
LIBFFI_INC=$(dirname $(find $WORK_DIR/libffi -name 'ffi.h' -path '*/include/*' | head -1))
echo "  libffi.a: $LIBFFI_A"
echo "  ffi.h:    $LIBFFI_INC"

# ============================================================
# Step 3: Compile native .so for each module
# ============================================================
echo ""
echo "[3/5] Compiling native .so modules..."

CFLAGS_BASE="-fPIC -O2 -DLWJGL_LINUX -D_GNU_SOURCE"
CFLAGS_BASE="$CFLAGS_BASE -I$JNI_HEADERS -I$JNI_HEADERS_PLATFORM"

# Version script: 只导出 Java_* 和 JNI_OnLoad
cat > $WORK_DIR/lwjgl_exports.ver << 'VSCRIPT'
{
  global:
    Java_*;
    JNI_OnLoad;
  local:
    *;
};
VSCRIPT

LDFLAGS_BASE="-shared -fPIC -O2 -z noexecstack"
LDFLAGS_BASE="$LDFLAGS_BASE -Wl,--version-script=$WORK_DIR/lwjgl_exports.ver"

BUILD_DIR=$WORK_DIR/lwjgl_build_${LWJGL_VERSION}
mkdir -p $BUILD_DIR

build_native_module() {
    local mod=$1
    local so_name=$2
    local extra_cflags=$3
    local extra_ldflags=$4

    echo "  Building $so_name..."

    local MOD_DIR=$LWJGL_ROOT/$mod
    local MAIN_C=$MOD_DIR/src/main/c
    local GEN_C=$MOD_DIR/src/generated/c

    # 收集 C 文件（排除 windows/macos）
    local c_files=""
    if [ -d "$MAIN_C" ]; then
        c_files="$c_files $(find $MAIN_C -name '*.c' | grep -v '/windows/' | grep -v '/macos/' | grep -v '/freebsd/' | sort)"
    fi
    if [ -d "$GEN_C" ]; then
        c_files="$c_files $(find $GEN_C -name '*.c' | grep -v '/windows/' | grep -v '/macos/' | grep -v '/freebsd/' | sort)"
    fi

    if [ -z "$(echo $c_files | tr -d ' ')" ]; then
        echo "    No C files, skipping native build"
        return
    fi

    local CFLAGS="$CFLAGS_BASE $extra_cflags"
    # 添加模块自己的 include 路径
    CFLAGS="$CFLAGS -I$MAIN_C -I$MAIN_C/linux"
    # core 模块的头文件被其他模块引用
    CFLAGS="$CFLAGS -I$LWJGL_ROOT/core/src/main/c -I$LWJGL_ROOT/core/src/main/c/linux"

    local OBJ_DIR=$BUILD_DIR/$mod
    mkdir -p $OBJ_DIR

    # 编译每个 .c 文件
    local obj_files=""
    local count=0
    local skip=0
    for f in $c_files; do
        local base=$(basename $f .c)
        local obj=$OBJ_DIR/${base}.o
        # 跳过不兼容的文件
        case "$f" in
            *liburing*) skip=$((skip + 1)); continue ;;  # OHOS 不支持 io_uring
            *stb_vorbis.c) skip=$((skip + 1)); continue ;;  # generated JNI 已 #include 它
        esac
        if $CC $CFLAGS -c $f -o $obj 2>/tmp/lwjgl_cc_err.txt; then
            obj_files="$obj_files $obj"
            count=$((count + 1))
        else
            # 编译失败，跳过（可能是平台特有代码）
            echo "    WARN: skipped $(basename $f): $(head -1 /tmp/lwjgl_cc_err.txt)"
            skip=$((skip + 1))
        fi
    done
    echo "    Compiled $count C files (skipped $skip)"

    # 链接
    local LDFLAGS="$LDFLAGS_BASE $extra_ldflags"
    $CC $LDFLAGS $obj_files -o $BUILD_DIR/$so_name -lm -ldl 2>&1 | head -3
    $STRIP --strip-unneeded $BUILD_DIR/$so_name

    local size=$(stat -c%s $BUILD_DIR/$so_name 2>/dev/null || echo 0)
    echo "    $so_name: $(($size / 1024)) KB"
    cp $BUILD_DIR/$so_name $OUTPUT_DIR/native/
}

# core: 需要 libffi
# 定义平台特有的 FFI 调用约定为 0（aarch64 只用 FFI_SYSV）
FFI_COMPAT="-DFFI_GNUW64=0 -DFFI_UNIX64=0 -DFFI_EFI64=0 -DFFI_STDCALL=0"
FFI_COMPAT="$FFI_COMPAT -DFFI_THISCALL=0 -DFFI_FASTCALL=0 -DFFI_MS_CDECL=0"
FFI_COMPAT="$FFI_COMPAT -DFFI_PASCAL=0 -DFFI_REGISTER=0 -DFFI_VFP=0"
build_native_module "core" "liblwjgl.so" \
    "-I$LIBFFI_INC -I$LWJGL_ROOT/core/src/main/c/libffi $FFI_COMPAT" \
    "$LIBFFI_A"

# opengl: 纯 JNI binding 到 GL 函数
build_native_module "opengl" "liblwjgl_opengl.so" "" ""

# stb: 包含 stb_image 等
build_native_module "stb" "liblwjgl_stb.so" \
    "-I$LWJGL_ROOT/stb/src/main/c" ""

# tinyfd: 文件对话框
build_native_module "tinyfd" "liblwjgl_tinyfd.so" \
    "-I$LWJGL_ROOT/tinyfd/src/main/c" ""

echo ""
echo "  Native .so files:"
ls -la $OUTPUT_DIR/native/

# ============================================================
# Step 4: Compile Java jar for each module
# ============================================================
echo ""
echo "[4/5] Compiling Java jars..."

JAVA_BUILD=$BUILD_DIR/java
mkdir -p $JAVA_BUILD

# 检查 javac 是否可用
if ! command -v javac &>/dev/null; then
    echo "  WARNING: javac not found, trying to install..."
    apt-get update -qq && apt-get install -y -qq default-jdk 2>&1 | tail -3
fi

JAVAC_VERSION=$(javac -version 2>&1)
echo "  javac: $JAVAC_VERSION"

build_java_module() {
    local mod=$1
    local jar_name=$2

    echo "  Building $jar_name..."

    local MOD_DIR=$LWJGL_ROOT/$mod
    local CLASS_DIR=$JAVA_BUILD/$mod/classes
    mkdir -p $CLASS_DIR

    # 收集 Java 源文件（排除 module-info.java）
    local java_files=""
    for src_dir in "$MOD_DIR/src/main/java" "$MOD_DIR/src/generated/java" "$MOD_DIR/src/main/resources"; do
        if [ -d "$src_dir" ]; then
            java_files="$java_files $(find $src_dir -name '*.java' \
                ! -name 'module-info.java' \
                2>/dev/null)"
        fi
    done

    if [ -z "$(echo $java_files | tr -d ' ')" ]; then
        echo "    No Java files, skipping"
        return
    fi

    local count=$(echo $java_files | wc -w)
    echo "    $count Java files"

    # 下载 JSR305 注解（@Nullable 等）— 只需一次
    local JSR305=$JAVA_BUILD/jsr305-3.0.2.jar
    if [ ! -f "$JSR305" ]; then
        wget -q -O $JSR305 https://repo1.maven.org/maven2/com/google/code/findbugs/jsr305/3.0.2/jsr305-3.0.2.jar 2>/dev/null || true
    fi

    # 构建完整 classpath（包含所有已编译的 jar + JSR305）
    local full_cp=""
    for existing_jar in $OUTPUT_DIR/jar/*.jar; do
        [ -f "$existing_jar" ] && [ $(stat -c%s "$existing_jar") -gt 500 ] && \
            full_cp="${full_cp:+$full_cp:}$existing_jar"
    done
    if [ -f "$JSR305" ]; then
        full_cp="${full_cp:+$full_cp:}$JSR305"
    fi
    local cp_opt=""
    if [ -n "$full_cp" ]; then
        cp_opt="-cp $full_cp"
    fi

    # 编译（UTF-8 编码 + 忽略警告）
    echo $java_files > $JAVA_BUILD/$mod/sources.txt
    javac -source 11 -target 11 \
        -encoding UTF-8 \
        $cp_opt \
        -d $CLASS_DIR \
        -Xlint:none \
        -Xmaxerrs 9999 \
        @$JAVA_BUILD/$mod/sources.txt 2>&1 | tail -5 || true

    local class_count=$(find $CLASS_DIR -name '*.class' | wc -l)
    echo "    Compiled $class_count classes"

    # 打包 jar
    cd $CLASS_DIR
    jar cf $OUTPUT_DIR/jar/$jar_name .
    local size=$(stat -c%s $OUTPUT_DIR/jar/$jar_name 2>/dev/null || echo 0)
    echo "    $jar_name: $(($size / 1024)) KB"
}

# 编译顺序：core 先编译，然后 vulkan/egl（被 glfw 依赖），最后其他模块
build_java_module "core" "lwjgl.jar"
build_java_module "vulkan" "lwjgl-vulkan.jar"
build_java_module "egl" "lwjgl-egl.jar"
build_java_module "opengles" "lwjgl-opengles.jar"
for mod in glfw opengl stb tinyfd jemalloc openal; do
    build_java_module "$mod" "lwjgl-${mod}.jar"
done

# ------------------------------------------------------------
# 强制剥离所有 lwjgl-*.jar 里的 module-info.class —— 让它们统一退化为
# Automatic Module。否则 Forge/ModLauncher 在 SECURE-BOOTSTRAP layer
# 下会按 named module 加载 lwjgl-glfw，访问 sun.misc.Unsafe 抛
# IllegalAccessError（module org.lwjgl.glfw does not read module jdk.unsupported）。
# 历史教训见 docs/archive/forge-analysis/forge-runtime-lwjgl-mismatch-20260328.md
# ------------------------------------------------------------
echo ""
echo "  Stripping module-info.class (force Automatic Module mode)..."
for jar in $OUTPUT_DIR/jar/lwjgl-*.jar $OUTPUT_DIR/jar/lwjgl.jar; do
    [ -f "$jar" ] || continue
    removed=$(zip -d "$jar" 'module-info.class' 'META-INF/versions/*/module-info.class' 2>/dev/null | grep -c 'deleting:' || true)
    if [ "$removed" -gt 0 ]; then
        echo "    $(basename $jar): removed $removed module-info entries"
    fi
done

echo ""
echo "  Java jars:"
ls -la $OUTPUT_DIR/jar/

# ============================================================
# Step 5: 验证输出
# ============================================================
echo ""
echo "[5/5] Verification..."
echo ""
echo "LWJGL ${LWJGL_VERSION} for OHOS build complete!"
echo ""
echo "Output directory: $OUTPUT_DIR"
echo ""
echo "Native libraries (.so):"
for f in $OUTPUT_DIR/native/*.so; do
    echo "  $(basename $f): $(stat -c%s $f) bytes"
done
echo ""
echo "Java archives (.jar):"
for f in $OUTPUT_DIR/jar/*.jar; do
    echo "  $(basename $f): $(stat -c%s $f) bytes, $(jar tf $f | grep '\.class$' | wc -l) classes"
done
echo ""
echo "To deploy:"
echo "  1. Copy native/*.so to entry/libs/arm64-v8a/"
echo "  2. Copy jar/*.jar to entry/src/main/resources/rawfile/lwjgl/"
echo "  3. MC launcher will auto-replace LWJGL jars in classpath"
