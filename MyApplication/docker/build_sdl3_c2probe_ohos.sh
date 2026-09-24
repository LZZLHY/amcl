#!/bin/bash
set -e
# ============================================================
#  【已被取代，不再维护】
#  C2 探针的正式形态是应用内测试：entry/src/main/cpp/tests/sdl3_c2_test.cpp
#  （DevTools →「图形渲染」→「SDL3 C2 关卡」）。
#
#  本脚本产出的独立可执行文件在 HarmonyOS NEXT 真机上跑不起来：/data 无 noexec、
#  chmod +x 也生效，但执行返回 126 Permission denied —— SELinux 域策略拒绝
#  （sh 域对 data_local_tmp 无 execute），无 root 绕不过。而且 shell 域的
#  linker namespace 与应用进程不同，测出来的结论不能迁移到 MC 的运行环境。
#
#  真机结论（2026-07-31 12:26，应用内探针）：C2 PASS，driver=ohos，
#  A == C == 0x5a4c0539b8，抽查 6/6 同址。
#  详见 docs/adaptation/SDL3_PORT_WORKLOG.md 的 12:27:14 条目。
#
#  保留原因：有 root 的设备/模拟器上仍可用；下面的 PT_INTERP 判据可复用。
# ============================================================
#  编 C2 真机探针（aarch64 OHOS）
#
#  为什么必须上真机：C2 的所有**代码层**事实都已离线证明（见 sdl3_c2probe.c 头注释
#  与 docs/adaptation/SDL3_PORT_WORKLOG.md 的 Task#10 条目）——
#  libglfw.so 自己 DEFINED 全部 gl*/egl*、libSDL3.so 零静态 GL 依赖、
#  SDL_EGL_GetProcAddressInternal 只有两个来源且都用具体 handle、
#  SDL_LoadObject 用 RTLD_NOW|RTLD_LOCAL。
#  唯一剩下的变量是 **HarmonyOS 的 linker namespace 行为**（应用私有 .so 与系统 .so
#  分属不同 namespace，dlopen/dlsym 可见性由系统策略决定），这个只能在设备上量。
#
#  产物是**不带 NEEDED 依赖**的独立可执行文件：探针内部用 dlopen/dlsym 取
#  libSDL3.so 与 libglfw.so，路径由命令行给定，所以不需要预设部署布局。
#
#  用法（容器内）：docker exec ohos-debug bash /host-docker/build_sdl3_c2probe_ohos.sh
#  产物：/output/sdl3/sdl3_c2probe
# ============================================================

OHOS_SYSROOT=${OHOS_SYSROOT_RW:-/ohos-sysroot-rw}
OUTPUT_DIR=${OUTPUT_DIR:-/output/sdl3}
SRC=${SRC:-/host-docker/sdl3_c2probe.c}
OHOS_LIBDIR=$OHOS_SYSROOT/usr/lib/aarch64-linux-ohos

[ -f "$SRC" ] || { echo "ERROR: 找不到源码 $SRC"; exit 1; }
[ -d "$OHOS_SYSROOT/usr/include" ] || { echo "ERROR: sysroot 未就绪"; exit 1; }

mkdir -p "$OUTPUT_DIR"
OUT="$OUTPUT_DIR/sdl3_c2probe"
OUT_SO="$OUTPUT_DIR/libsdl3_c2probe.so"

# -std=gnu11 而不是 c11：setenv/dup/dup2 是 POSIX 而非 ISO C，严格 c11 下
# stdlib.h/unistd.h 不暴露它们，会退化成隐式声明（第一版就吃了这个警告）。
# -Werror：探针必须零警告，否则这类"能跑但不对"的问题会一直溜过去。
CFLAGS_COMMON="--target=aarch64-linux-ohos --sysroot=$OHOS_SYSROOT
    -O2 -std=gnu11 -D__OHOS__ -DOHOS
    -Wall -Wextra -Werror -Wno-unused-parameter"

echo "=== 编 C2 探针可执行文件（aarch64-linux-ohos） ==="
/usr/bin/ohos-clang $CFLAGS_COMMON \
    -o "$OUT" "$SRC" \
    -L"$OHOS_LIBDIR" -ldl -fuse-ld=lld
echo "  -> $OUT ($(stat -c%s "$OUT") bytes)"

# 备用形态：/data/local/tmp 若挂 noexec，就由 AMCL native 层 dlopen 这个 .so
# 调 c2probe_main_to_file()。同一份源码，不会两边行为漂移。
echo ""
echo "=== 编 C2 探针 .so（noexec 备用路径） ==="
/usr/bin/ohos-clang $CFLAGS_COMMON -fPIC -shared \
    -o "$OUT_SO" "$SRC" \
    -L"$OHOS_LIBDIR" -ldl -fuse-ld=lld
echo "  -> $OUT_SO ($(stat -c%s "$OUT_SO") bytes)"

echo ""
echo "=== 产物自检 ==="
for f in "$OUT" "$OUT_SO"; do
    echo "  --- $(basename "$f") ---"
    /usr/bin/ohos-readelf -h "$f" | grep -E 'Class|Machine|Type:' | tr -s ' ' | sed 's/^/    /'
    echo "    NEEDED: $(/usr/bin/ohos-readelf -d "$f" | grep NEEDED | sed -E 's/.*\[(.*)\].*/\1/' | tr '\n' ' ')"
    if /usr/bin/ohos-readelf -d "$f" | grep -qE 'libSDL3|libglfw'; then
        echo "    ❌ 出现了 libSDL3/libglfw 依赖 —— 探针应当零依赖，全靠 dlopen"
        exit 1
    fi
done
echo "  ✅ 两个产物都没有 libSDL3/libglfw 依赖"

# OHOS clang 默认 -pie，PIE 可执行文件的 ELF Type 也是 DYN，光看 Type 分不出
# "可执行文件" 和 "共享库"。真正的判据是有没有 PT_INTERP（程序解释器）。
echo ""
echo "  --- 可执行性判据：PT_INTERP ---"
if /usr/bin/ohos-readelf -lW "$OUT" | grep -q 'INTERP'; then
    echo "    ✅ sdl3_c2probe 有 PT_INTERP: $(/usr/bin/ohos-readelf -lW "$OUT" | grep -A1 INTERP | grep -oE '/[^]]*' | head -1) —— 是可执行文件（PIE）"
else
    echo "    ❌ sdl3_c2probe 没有 PT_INTERP，不是可执行文件"
    exit 1
fi
if /usr/bin/ohos-readelf -lW "$OUT_SO" | grep -q 'INTERP'; then
    echo "    ❌ libsdl3_c2probe.so 竟然有 PT_INTERP，不是纯共享库"
    exit 1
fi
echo "    ✅ libsdl3_c2probe.so 无 PT_INTERP —— 是纯共享库"

echo ""
echo "  --- .so 的入口符号（noexec 备用路径要用）---"
for sym in c2probe_main c2probe_main_to_file; do
    if /usr/bin/ohos-readelf -sW "$OUT_SO" | grep -qE "FUNC .*GLOBAL .*DEFAULT .* $sym\$"; then
        echo "    ✅ 导出 $sym"
    else
        echo "    ❌ 未导出 $sym"
        exit 1
    fi
done

cat <<'HOWTO'

=== 怎么在真机上跑 ===

1) 三个文件推到设备（libglfw.so 取 stripped 版）：
     hdc file send <output>/sdl3_c2probe                        /data/local/tmp/
     hdc file send entry/libs/arm64-v8a/libSDL3.so              /data/local/tmp/
     hdc file send entry/build/default/intermediates/stripped_native_libs/default/arm64-v8a/libglfw.so \
                                                                /data/local/tmp/

2) 跑：
     hdc shell "cd /data/local/tmp && chmod +x sdl3_c2probe && \
                LD_LIBRARY_PATH=/data/local/tmp ./sdl3_c2probe \
                /data/local/tmp/libSDL3.so /data/local/tmp/libglfw.so; echo EXIT=\$?"

   退出码：0 = C2 成立（A==C，MC 的 glGetError 硬校验会过）
           1 = 证伪（地址不同，需要 patch）
           2 = 探测未完成（看输出停在第几层）

3) libglfw.so 还依赖 libc++_shared.so / libnative_window.so / libhilog_ndk.z.so /
   libEGL.so / libGLESv3.so。后三个是系统库；libc++_shared.so 需要一起推：
     hdc file send entry/libs/arm64-v8a/libc++_shared.so /data/local/tmp/

4) 若 /data/local/tmp 挂了 noexec（执行报 Permission denied），用已经编好的 .so：
     hdc file send <output>/libsdl3_c2probe.so /data/local/tmp/
   然后由 AMCL native 层（或任何能 dlopen 的入口）调：
     void *h = dlopen("<沙箱路径>/libsdl3_c2probe.so", RTLD_NOW);
     int (*f)(const char*, const char*, const char*) = dlsym(h, "c2probe_main_to_file");
     f("<沙箱>/libSDL3.so", "<沙箱>/libglfw.so", "<沙箱>/c2probe_report.txt");
   报告取回：hdc file recv <沙箱>/c2probe_report.txt .
   （c2probe_main_to_file 只是把 stdout 重定向到文件再调 c2probe_main，
    两条路径共用同一份逻辑，不会行为漂移。）

即使第 2 层（SDL 代码路径）因为命令行环境起不来 video driver 而失败，
**第 1 层的 dlsym 事实仍然有效**——那已经能回答"HarmonyOS namespace 下
libglfw.so 的 glGetError 与系统 GLES 的是否同址"这个核心问题。
HOWTO
