#!/bin/bash
# ============================================================
#  SVE2 target 属性探针 —— 为上游 PR 取实证
#
#  验证目标：上游 SDL 的 SVE2 能力检测（CMakeLists.txt 的 check_c_source_compiles +
#  CMAKE_REQUIRED_FLAGS " -march=armv8-a+sve2"）只验证了命令行 flag，没验证
#  src/video/arm/SDL_sve2_*.c 实际使用的函数级 SDL_TARGETING("arch=armv8-a+sve2")。
#  若后者不被支持，属性被静默忽略 + 产生 -Wignored-attributes，SDL_WERROR=ON 必然失败。
#
#  用法: docker exec ohos-debug bash /host-docker/build_sve2_attr_probe.sh
# ============================================================
set -u

# 必须用增补过的可写 sysroot：容器环境变量 OHOS_SYSROOT 指向华为原版只读挂载
# /ohos-sysroot，那里**缺 bits/alltypes.h**（clang 自带的 stdint.h 会 include 它），
# 直接用会 fatal error。与 build_sdl3_ohos.sh:52 保持同一取值方式。
OHOS_SYSROOT=${OHOS_SYSROOT_RW:-/ohos-sysroot-rw}
SRC=/host-docker/sve2_attr_probe.c
OUT=/tmp/sve2-attr-probe
mkdir -p "$OUT"

CC=/usr/bin/ohos-clang
COMMON="--target=aarch64-linux-ohos --sysroot=$OHOS_SYSROOT -O2 -c -Wall -Wextra"
MARCH="-march=armv8-a+sve2"

echo "=== 编译器版本 ==="
$CC --version | head -2
echo ""

# 逐个 part 编译，分别统计 -Wignored-attributes
run_part() {
    local part="$1" desc="$2"
    local log="$OUT/$part.log"
    echo "--- $part: $desc ---"
    $CC $COMMON $MARCH -D"$part" -o "$OUT/$part.o" "$SRC" >"$log" 2>&1
    local rc=$?
    # 注意用 || true 而不是 || echo 0：grep -c 无匹配时**已经输出 0** 且返回 1，
    # 再 echo 0 会得到 "0\n0"，后续数值比较全乱。
    local ignored
    ignored=$(grep -c 'ignored-attributes' "$log" 2>/dev/null || true)
    : "${ignored:=0}"
    echo "    exit=$rc  ignored-attributes 警告数=$ignored"
    if [ "$ignored" != "0" ]; then
        echo "    首条警告:"
        grep -m1 -A2 'ignored-attributes' "$log" | sed 's/^/      /'
    fi
    if [ $rc -ne 0 ]; then
        echo "    编译失败，完整输出:"
        sed 's/^/      /' "$log"
    fi
    echo ""
}

echo "=== 三种写法对比（都带命令行 $MARCH）==="
run_part PART_A '上游 check_c_source_compiles 的等价物（函数上无 target 属性）'
run_part PART_B 'SDL_sve2_*.c 的等价物（带 SDL_TARGETING("arch=armv8-a+sve2")）'
run_part PART_C '对照：__attribute__((target("+sve2")))（特性名写法）'

echo "=== 结论判据 ==="
a=$(grep -c 'ignored-attributes' "$OUT/PART_A.log" 2>/dev/null || true)
b=$(grep -c 'ignored-attributes' "$OUT/PART_B.log" 2>/dev/null || true)
c=$(grep -c 'ignored-attributes' "$OUT/PART_C.log" 2>/dev/null || true)
: "${a:=0}" "${b:=0}" "${c:=0}"
echo "  PART_A（无属性）= $a   PART_B（arch= 写法）= $b   PART_C（+sve2 写法）= $c"
if [ "$a" = "0" ] && [ "$b" != "0" ]; then
    echo "  ✅ 复现成立：上游的检测能通过，但实际源文件用的 arch= 写法被忽略并警告。"
    echo "     ⇒ check_c_source_compiles 的测试代码没覆盖真实用法，这就是 210 个警告的来源。"
    if [ "$c" = "0" ]; then
        echo "  ➕ 且 PART_C 无警告 ⇒ 不是 target 属性本身不支持，而是 \"arch=\" 这种写法不支持。"
        echo "     ⇒ 修法有两条可选：把检测改严（连函数级属性一起测），或把源码换成 \"+sve2\" 写法。"
    else
        echo "  ➖ PART_C 也有警告 ⇒ 该编译器对 AArch64 函数级 target 属性整体不支持。"
        echo "     ⇒ 修法应是把检测改严，让不支持的编译器整体关掉 SVE2。"
    fi
else
    echo "  ❌ 未复现（A=$a B=$b）。结论需重新评估，不要据此提 PR。"
fi
