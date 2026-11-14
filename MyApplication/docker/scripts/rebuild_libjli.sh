#!/bin/bash
# 现代JDK的libjli重链：编译器visibility决定可见性，version-script只限制导出范围。
# 正式17/21/25配方均使用固定标准编译树，不搜索其他配置作为静默回落。
# 可选BUILD_DIR必须指向同一标准树；--verify-only用于只读核验真实目标库。
set -euo pipefail

# 解析唯一标准目录；函数可被回归直接source，source本文件不会触发编译。
resolve_libjli_build_dir() {
    local source=${1:?source required} requested=${2-} expected resolved
    source=$(realpath -e -- "$source") || return 1
    expected="$source/build/linux-aarch64-server-release"
    [ -d "$expected" ] || { echo "ERROR: expected build directory missing: $expected" >&2; return 1; }
    expected=$(realpath -e -- "$expected") || return 1
    [ "$expected" = "$source/build/linux-aarch64-server-release" ] || {
        echo 'ERROR: build directory resolves outside its fixed source tree' >&2; return 1;
    }
    if [ -n "$requested" ]; then
        [[ "$requested" = /* ]] || { echo 'ERROR: explicit BUILD_DIR must be absolute' >&2; return 1; }
        resolved=$(realpath -e -- "$requested") || return 1
        [ "$resolved" = "$expected" ] || { echo "ERROR: explicit BUILD_DIR is not $expected" >&2; return 1; }
    fi
    for required in spec.gmk support/native/java.base/libjli support/modules_libs/java.base images/jdk/lib; do
        [ -e "$expected/$required" ] || { echo "ERROR: incomplete build directory: $expected/$required" >&2; return 1; }
    done
    printf '%s\n' "$expected"
}

# 只认可dynsym内已定义且可见的函数，不接受UND、普通symtab或同名前缀。
# 失败必须传递给正式构建；READELF仅选择读取工具，不能关闭门禁。
verify_libjli_exports() {
    local library=${1:?library required} reader=${READELF:-aarch64-linux-ohos-readelf} header symbols symbol
    [ -f "$library" ] || { echo "ERROR: libjli missing: $library" >&2; return 1; }
    header=$("$reader" -h "$library") || return 1
    grep -Eq 'Class:[[:space:]]+ELF64' <<< "$header" &&
        grep -Eq 'Data:.*little endian' <<< "$header" &&
        grep -Eq 'Type:[[:space:]]+DYN' <<< "$header" &&
        grep -Eq 'Machine:[[:space:]]+AArch64' <<< "$header" || {
            echo "ERROR: libjli must be an ELF64 little-endian AArch64 shared object: $library" >&2; return 1;
        }
    symbols=$("$reader" --dyn-syms --wide "$library") || return 1
    for symbol in JLI_Launch JLI_ManifestIterate; do
        awk -v wanted="$symbol" '
            $4 == "FUNC" && ($5 == "GLOBAL" || $5 == "WEAK") &&
            ($6 == "DEFAULT" || $6 == "PROTECTED") && $7 ~ /^[0-9]+$/ && $7 + 0 > 0 {
                name = $8; sub(/@.*/, "", name); if (name == wanted) found = 1;
            }
            END { exit !found }
        ' <<< "$symbols" || { echo "ERROR: missing defined dynamic JLI function: $symbol" >&2; return 1; }
    done
    echo "PASS: AArch64 libjli exports JLI_Launch and JLI_ManifestIterate: $library"
}

main() {
    if [ "${1-}" = '--verify-only' ]; then
        [ "$#" -eq 2 ] || { echo 'Usage: rebuild_libjli.sh --verify-only LIBRARY' >&2; return 2; }
        verify_libjli_exports "$2"
        return
    fi
    [ "$#" -le 1 ] || { echo 'Usage: rebuild_libjli.sh [BUILD_DIR]' >&2; return 2; }
    if [ "$#" -eq 1 ] && [ -z "$1" ]; then echo 'ERROR: explicit BUILD_DIR is empty' >&2; return 2; fi
    JDK_VERSION=${JDK_VERSION:-17}
    case "$JDK_VERSION" in 17|21|25) ;; *) echo "ERROR: unsupported JDK_VERSION: $JDK_VERSION" >&2; return 2 ;; esac
    JDK_SRC="/build/jdk${JDK_VERSION}u"
    BUILD_DIR=$(resolve_libjli_build_dir "$JDK_SRC" "${1-}")
    echo "=== Rebuilding libjli.so for JDK $JDK_VERSION in $BUILD_DIR ==="
    # 版本脚本不能提升hidden符号；下方重编以default visibility公开真实JLI实现。
    # JLI_Exit/JLI_ExitHook旧伪桥已退役；required export只由实际消费者契约决定。
    EXPORT_MAP="$BUILD_DIR/libjli_exports.map"
    cat > "$EXPORT_MAP" << 'VERSCRIPT'
{
    global: JLI_*;
    local: *;
};
VERSCRIPT

COMMON_FLAGS="-MMD \
    -I${BUILD_DIR}/support/modules_include/java.base \
    -I${BUILD_DIR}/support/modules_include/java.base/linux \
    -I${JDK_SRC}/src/java.base/share/native/libjava \
    -I${JDK_SRC}/src/java.base/unix/native/libjava \
    -I${JDK_SRC}/src/hotspot/share/include \
    -I${JDK_SRC}/src/hotspot/os/posix/include \
    -pipe -DLIBC=musl -D_GNU_SOURCE -D_REENTRANT -D_LARGEFILE64_SOURCE -DLINUX -DNDEBUG \
    -Wall -Wextra -Wformat=2 -Wpointer-arith -Wsign-compare -Wreorder \
    -Wunused-function -Wundef -Wunused-value -Woverloaded-virtual \
    -std=c99 -fno-strict-aliasing \
    --target=aarch64-linux-ohos --sysroot=/ohos-sysroot-rw -fPIC \
    -D__MUSL__ -DMUSL_LIBC  \
    -I/ohos-sysroot-rw/usr/include/aarch64-linux-ohos \
    -I/build/stub-headers -isystem ${AMCL_JDK_CXX_INCLUDE:?} \
    -B/ohos-sysroot-rw/usr/lib/aarch64-linux-ohos \
    -L/ohos-sysroot-rw/usr/lib/aarch64-linux-ohos \
    -rtlib=compiler-rt -unwindlib=none \
    -D_LITTLE_ENDIAN -DARCH='\"aarch64\"' -Daarch64 -D_LP64=1 \
    -fno-omit-frame-pointer -fPIC -fvisibility=default \
    -I${JDK_SRC}/src/java.base/unix/native/libjli \
    -I${JDK_SRC}/src/java.base/share/native/libjli \
    -I${BUILD_DIR}/support/headers/java.base \
    -Wno-unknown-warning-option -Wno-unused-parameter -Wno-unused \
    -Wno-sometimes-uninitialized -Wno-format-nonliteral -Wno-deprecated-non-prototype \
    -O3"

OBJ_DIR=${BUILD_DIR}/support/native/java.base/libjli

# Step 1: 重编java.c中的JLI_Launch/JavaMain等真实入口。
echo "[1/4] Recompiling java.c..."
/ohos-toolchain/aarch64-linux-ohos-gcc \
    $COMMON_FLAGS \
    -c -o $OBJ_DIR/java.o \
    ${JDK_SRC}/src/java.base/share/native/libjli/java.c
echo "  java.o compiled OK"

# Step 2: Recompile java_md.c (contains GetJREPath, LoadJavaVM, etc.)
echo "[2/4] Recompiling java_md.c..."
/ohos-toolchain/aarch64-linux-ohos-gcc \
    $COMMON_FLAGS \
    -c -o $OBJ_DIR/java_md.o \
    ${JDK_SRC}/src/java.base/unix/native/libjli/java_md.c
echo "  java_md.o compiled OK"

# 解析 manifest 的实现也必须公开；仅修改 version-script 不能提升编译器隐藏的符号。
/ohos-toolchain/aarch64-linux-ohos-gcc $COMMON_FLAGS \
    -c -o "$OBJ_DIR/parse_manifest.o" "${JDK_SRC}/src/java.base/share/native/libjli/parse_manifest.c"

# Step 3: Relink libjli.so
echo "[3/4] Relinking libjli.so..."
/ohos-toolchain/aarch64-linux-ohos-gcc \
    --target=aarch64-linux-ohos --sysroot=/ohos-sysroot-rw \
    -fuse-ld=lld \
    -B/ohos-sysroot-rw/usr/lib/aarch64-linux-ohos \
    -L/ohos-sysroot-rw/usr/lib/aarch64-linux-ohos \
    -rtlib=compiler-rt -unwindlib=none \
    -nostdlib++ -L/output/jdk-libs -lcxxabi_shim -lc++_shared \
    -L${BUILD_DIR}/support/modules_libs/java.base \
    -L${BUILD_DIR}/support/modules_libs/java.base/server \
    -shared -Wl,-z,origin -Wl,-rpath,\$ORIGIN -Wl,--disable-new-dtags \
    -Wl,-soname=libjli.so \
    -Wl,--version-script="$EXPORT_MAP" \
    -o ${BUILD_DIR}/support/modules_libs/java.base/libjli.so \
    "$OBJ_DIR"/*.o \
    -Wl,--no-undefined \
    -lz -ldl -lpthread
echo "  libjli.so linked OK"

# 发布前检查required exports；不将错误产物先复制到输出或最终镜像。
verify_libjli_exports "${BUILD_DIR}/support/modules_libs/java.base/libjli.so"
echo "[4/4] Copying verified libjli to output and JDK image..."
mkdir -p /output/jdk-libs
cp "${BUILD_DIR}/support/modules_libs/java.base/libjli.so" /output/jdk-libs/libjli.so
cp "${BUILD_DIR}/support/modules_libs/java.base/libjli.so" "${BUILD_DIR}/images/jdk/lib/libjli.so"
verify_libjli_exports /output/jdk-libs/libjli.so
verify_libjli_exports "${BUILD_DIR}/images/jdk/lib/libjli.so"
echo 'NEEDED dependencies:'
"${READELF:-aarch64-linux-ohos-readelf}" -d /output/jdk-libs/libjli.so | grep NEEDED
echo '=== Verified libjli rebuild complete ==='
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
