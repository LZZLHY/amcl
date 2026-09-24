#!/bin/bash
# =============================================================================
# build-ohos.sh — 交叉编译 imgui-java 的 native（libimgui-java64.so）for OHOS aarch64
# =============================================================================
# 用途：给 CorgiLib 等捆绑桌面专用 ImGui native 的 mod 提供 ARM64(OHOS) 版本，
#       使其 System.loadLibrary("imgui-java64") 命中我们的库、不再解压自带 x86 .so 而崩溃。
#
# 运行环境：在 openjdk-ohos-builder 容器内执行（容器名通常 ohos-debug）。
#   依赖：
#     - /ohos-toolchain/aarch64-linux-ohos-g++ （clang-15 wrapper，target aarch64-linux-ohos）
#     - /usr/bin/ohos-clang （clang-15，直接链接用）
#     - OHOS sysroot：/ohos-sysroot-rw（含 libc++_shared.so、libc.so）
#   产物运行时依赖（设备侧 OHOS 自带）：libc++_shared.so（/system/lib64）、libc.so
#
# 用法：
#   # 1) 把本目录拷进容器（或挂载），例如：
#   docker cp prebuilt/mod-natives/imgui-java ohos-debug:/tmp/imgui-build
#   # 2) 容器内执行：
#   docker exec ohos-debug bash /tmp/imgui-build/build-ohos.sh
#   # 3) 产物 libimgui-java64.so 会在脚本同目录下，拷回仓库：
#   docker cp ohos-debug:/tmp/imgui-build/libimgui-java64.so entry/libs/arm64-v8a/
#
# 详见 docs/guides/mod-native-runtime-plan.md。
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/jni"                       # imgui-java 生成的 JNI cpp + Dear ImGui 源码
OUT="$SCRIPT_DIR/build"
CXX="${OHOS_GXX:-/ohos-toolchain/aarch64-linux-ohos-g++}"
CLANG="${OHOS_CLANG:-/usr/bin/ohos-clang}"
SYSROOT="${OHOS_SYSROOT_RW:-/ohos-sysroot-rw}"
LIBDIR="$SYSROOT/usr/lib/aarch64-linux-ohos"

# 排除的扩展：TextEditor / ImGuiFileDialog / ImGui-node-editor(crude_json)。
# 它们依赖 libc++ <locale>，需要 glibc 专属的 *_l 函数（strtoll_l 等），OHOS musl 无 →
# 编译失败。这些扩展 CorgiLib 及游戏类 mod 都不用，故排除。
# 仍包含：core ImGui + ImPlot + imnodes + imguizmo + knobs + ImCurveEdit + ImZoomSlider + memory_editor。
EXCLUDE_RE="ImGuiFileDialog|TextEditor|crude_json|nodeditor|node_editor"

INC="-I$SRC -I$SRC/jni-headers -I$SRC/jni-headers/linux"
# 注：jni-headers 为 JNI 头（jni.h/jni_md.h）。如需与运行时 JVM 精确对齐，可用
#     openjdk-ohos 容器内 AMCL 实际 JVM 的 include/ 覆盖（JNIEnv 结构跨版本稳定，通常无需）。
CXXFLAGS="-std=c++17 -O2 -fPIC -fvisibility=default -D_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE $INC"

rm -rf "$OUT"; mkdir -p "$OUT/obj"

# ---- 1) 收集源（按排除表过滤） ----
srcs=(); skipped=()
for f in "$SRC"/*.cpp; do
  b=$(basename "$f" .cpp)
  if echo "$b" | grep -qE "$EXCLUDE_RE"; then skipped+=("$b"); else srcs+=("$f"); fi
done
echo "[1] compiling ${#srcs[@]} sources (excluded ${#skipped[@]} locale-dep extensions)"

# ---- 2) 并行编译 ----
for f in "${srcs[@]}"; do
  b=$(basename "$f" .cpp)
  ( "$CXX" $CXXFLAGS -c "$f" -o "$OUT/obj/$b.o" 2> "$OUT/obj/$b.err" ) &
  while [ "$(jobs -r | wc -l)" -ge 8 ]; do sleep 0.1; done
done
wait

fail=0
for f in "${srcs[@]}"; do
  b=$(basename "$f" .cpp)
  if [ ! -f "$OUT/obj/$b.o" ]; then echo "  FAILED: $b"; grep "error:" "$OUT/obj/$b.err" | head -3; fail=1; fi
done
echo "[2] objects: $(ls "$OUT"/obj/*.o 2>/dev/null | wc -l)/${#srcs[@]}"
[ "$fail" = "1" ] && { echo "ABORT: compile errors"; exit 1; }

# ---- 3) 链接：直接用 ohos-clang，依赖 libc++_shared.so（设备侧 OHOS 自带），
#         不走 wrapper 默认的 libcxxabi_shim.so（那是 JDK 构建专用、设备没有）。 ----
echo "[3] linking libimgui-java64.so (NEEDED: libc++_shared.so, libc.so)"
"$CLANG" --target=aarch64-linux-ohos --sysroot="$SYSROOT" \
  -shared -fPIC -o "$SCRIPT_DIR/libimgui-java64.so" "$OUT"/obj/*.o \
  -L"$LIBDIR" -nostdlib++ -lc++_shared \
  -rtlib=compiler-rt -unwindlib=none -fuse-ld=lld

# ---- 4) strip + 自检 ----
/ohos-toolchain/aarch64-linux-ohos-strip "$SCRIPT_DIR/libimgui-java64.so"
echo "[4] DONE -> $SCRIPT_DIR/libimgui-java64.so"
/ohos-toolchain/aarch64-linux-ohos-readelf -h "$SCRIPT_DIR/libimgui-java64.so" | grep -E "Machine"
/ohos-toolchain/aarch64-linux-ohos-readelf -d "$SCRIPT_DIR/libimgui-java64.so" | grep NEEDED
