#!/bin/bash
# ============================================================
#  SVE2 target 属性修复的对照编译验证（为 libsdl-org/SDL 上游 PR 取证）
#
#  验证内容：把 src/video/arm 里的
#      SDL_TARGETING("arch=armv8-a+sve2")   ->   SDL_TARGETING("+sve2")
#  之后，clang 下的 -Wignored-attributes 是否从 N 降到 0，且编译仍然成功。
#
#  为什么要对照编译真实文件而不是靠最小复现：
#    sve2_attr_probe.c 已证明机制（arch= 写法被忽略、+sve2 写法被接受），但
#    「上游真实源码在真实构建配置下有多少条警告」只能编真的。SVE2 源文件
#    include ../../SDL_internal.h + ../SDL_blit.h，需要 CMake 生成的
#    SDL_build_config.h，所以必须走完整 configure。
#
#  用法（宿主先导出两份源码 tar 并 docker cp 进来）：
#    git -C <sdl3 repo> archive upstream/main -o orig.tar
#    git -C <sdl3 repo> archive HEAD          -o fixed.tar
#    docker cp orig.tar  ohos-debug:/tmp/sve2-cmp/orig.tar
#    docker cp fixed.tar ohos-debug:/tmp/sve2-cmp/fixed.tar
#    docker exec ohos-debug bash /host-docker/verify_sve2_target_attr.sh
# ============================================================
set -u

# 必须用增补过的可写 sysroot（华为原版只读挂载 /ohos-sysroot 缺 bits/alltypes.h）。
# 与 build_sdl3_ohos.sh 同一取值方式。
OHOS_SYSROOT=${OHOS_SYSROOT_RW:-/ohos-sysroot-rw}
OHOS_LIBDIR=$OHOS_SYSROOT/usr/lib/aarch64-linux-ohos
BASE=/tmp/sve2-cmp

[ -d "$OHOS_SYSROOT/usr/include" ] || { echo "ERROR: sysroot $OHOS_SYSROOT not ready"; exit 1; }

# ---------- 编译器包装器（与 build_sdl3_ohos.sh 逐字一致）----------
cat > /tmp/ohos-cc-sve2 <<CCEOF
#!/bin/bash
exec /usr/bin/ohos-clang --target=aarch64-linux-ohos --sysroot=$OHOS_SYSROOT \\
    -D__OHOS__ -DOHOS -Wno-unused-command-line-argument \\
    -L$OHOS_LIBDIR -fuse-ld=lld "\$@"
CCEOF
chmod +x /tmp/ohos-cc-sve2

cat > /tmp/ohos-sve2-toolchain.cmake <<TCEOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER /tmp/ohos-cc-sve2)
set(CMAKE_C_COMPILER_WORKS 1)
set(CMAKE_SYSROOT $OHOS_SYSROOT)
set(CMAKE_FIND_ROOT_PATH $OHOS_SYSROOT)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
TCEOF
# 注意这里**不**设 OHOS TRUE：本验证走的是纯 upstream 源码（没有 OHOS 后端），
# 当成普通 aarch64 Linux 目标编即可。SVE2 只要求 SDL_CPU_ARM64。

# 两个待编 object 的 ninja 目标（SDL3-shared 目标下的路径）
OBJ_A='CMakeFiles/SDL3-shared.dir/src/video/arm/SDL_sve2_blit_A.c.o'
OBJ_N='CMakeFiles/SDL3-shared.dir/src/video/arm/SDL_sve2_blit_N.c.o'

do_variant() {
    local name="$1"
    local src="$BASE/$name"
    local bld="$src/build"
    local log="$BASE/$name.log"

    echo "=========================================="
    echo " variant: $name"
    echo "=========================================="

    if [ ! -f "$BASE/$name.tar" ]; then
        echo "  ERROR: $BASE/$name.tar 不存在（宿主先 docker cp 进来）"
        return 1
    fi
    rm -rf "$src"; mkdir -p "$src"
    tar -xf "$BASE/$name.tar" -C "$src"

    # 该 variant 里 arch= 写法与 +sve2 写法各有多少处（静态计数，先于编译）
    local n_arch n_feat
    n_arch=$(grep -rho 'SDL_TARGETING("arch=armv8-a+sve2")' "$src/src/video/arm/" | wc -l)
    n_feat=$(grep -rho 'SDL_TARGETING("+sve2")' "$src/src/video/arm/" | wc -l)
    echo "  源码静态计数: arch= 写法 $n_arch 处 / +sve2 写法 $n_feat 处"

    mkdir -p "$bld"; cd "$bld" || return 1
    echo "  [1/2] cmake configure..."
    cmake .. -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE=/tmp/ohos-sve2-toolchain.cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DSDL_SHARED=ON -DSDL_STATIC=OFF \
        -DSDL_TESTS=OFF -DSDL_TEST_LIBRARY=OFF -DSDL_EXAMPLES=OFF \
        -DSDL_INSTALL_TESTS=OFF -DSDL_DISABLE_INSTALL_DOCS=ON \
        -DSDL_VIDEO=ON \
        -DSDL_X11=OFF -DSDL_WAYLAND=OFF \
        -DSDL_UNIX_CONSOLE_BUILD=ON \
        > "$log.configure" 2>&1
    if [ $? -ne 0 ]; then
        echo "  ❌ configure 失败，尾部输出："
        tail -25 "$log.configure" | sed 's/^/      /'
        return 1
    fi

    # 确认 SVE2 真的被开启了 —— 否则整个验证没有意义
    if grep -qE 'HAVE_ARMSVE2:INTERNAL=TRUE|COMPILER_SUPPORTS_ARMSVE2:INTERNAL=1' CMakeCache.txt; then
        echo "  SVE2: 已启用（COMPILER_SUPPORTS_ARMSVE2 / HAVE_ARMSVE2）"
    else
        echo "  ⚠️  SVE2 似乎未启用，检查 CMakeCache："
        grep -iE 'armsve2|sve2' CMakeCache.txt | sed 's/^/      /'
    fi

    echo "  [2/2] ninja 只编那两个 SVE2 object..."
    ninja "$OBJ_A" "$OBJ_N" > "$log.build" 2>&1
    local rc=$?

    local warn
    warn=$(grep -c 'ignored-attributes' "$log.build" 2>/dev/null || true)
    : "${warn:=0}"
    echo "  编译 exit=$rc   ignored-attributes 警告数=$warn"
    if [ "$warn" != "0" ]; then
        echo "  首条警告："
        grep -m1 -B1 -A2 'ignored-attributes' "$log.build" | sed 's/^/      /'
    fi
    if [ $rc -ne 0 ]; then
        echo "  ❌ 编译失败，尾部输出："
        tail -25 "$log.build" | sed 's/^/      /'
    fi
    # 产物存在性
    for o in "$OBJ_A" "$OBJ_N"; do
        if [ -f "$o" ]; then
            echo "  产物 $(basename "$o") = $(stat -c%s "$o") B"
        else
            echo "  ❌ 产物缺失: $o"
        fi
    done
    echo ""
    # 把结果写到文件供最后汇总
    echo "$warn $rc" > "$BASE/$name.result"
    return 0
}

mkdir -p "$BASE"
do_variant orig
do_variant fixed

echo "=========================================="
echo " 汇总"
echo "=========================================="
read -r w_orig rc_orig < "$BASE/orig.result" 2>/dev/null || { w_orig=-1; rc_orig=-1; }
read -r w_fixed rc_fixed < "$BASE/fixed.result" 2>/dev/null || { w_fixed=-1; rc_fixed=-1; }
echo "  orig  (arch=armv8-a+sve2): ignored-attributes=$w_orig  exit=$rc_orig"
echo "  fixed (+sve2)            : ignored-attributes=$w_fixed  exit=$rc_fixed"
echo ""
if [ "$rc_orig" = "0" ] && [ "$rc_fixed" = "0" ] && [ "$w_orig" -gt 0 ] && [ "$w_fixed" = "0" ]; then
    echo "  ✅ 验证通过：修复前 $w_orig 条 -Wignored-attributes，修复后 0 条，两者都编译成功。"
    exit 0
else
    echo "  ❌ 验证未达成预期（期望 orig>0 且 fixed=0，两者 exit 均为 0）。"
    exit 1
fi
