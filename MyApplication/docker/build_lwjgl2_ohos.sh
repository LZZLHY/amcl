#!/bin/bash
# ============================================================================
# build_lwjgl2_ohos.sh — LWJGL 2.9.x native 交叉编译到 HarmonyOS NEXT aarch64/musl
#
# 用途：为 MC ≤1.12（真·LWJGL2，非兼容层）提供 liblwjgl_v2.so。
# 方案见 docs/adaptation/LWJGL_MULTIVERSION_PLAN.md §11（真 LWJGL2 单独适配）。
#
# 阶段（2026-06-13）：
#   ✅ P1：工具链 + 生成器 + 平台无关单元（GL/AL 绑定 + common）交叉编译跑通（169/169 .o）。
#   🚧 P2：把 desktop 路径的 X11/GLX 后端（linux/ + linux/opengl/）换成 EGL/XComponent
#          —— 见本脚本末尾 TODO 与 plan §11.11.2 改造点清单。
#
# 关键点：
#   - 生成器（org.lwjgl.util.generator.GeneratorProcessor，JSR269）必须用 **JDK 8** 跑
#     （source/target 1.6；JDK17 已不支持 1.6）。产出 src/generated/** + src/native/generated/**。
#   - native 编译用 ohos-clang（clang-15）+ OHOS sysroot，与 build_lwjgl_ohos.sh / build_jdk8 同套路。
#   - GL 调用运行期解析到 libgl4es.so（gl4es 导出 desktop GL 符号），非系统 libGL。
#   - native 改名：核心库 liblwjgl.so → liblwjgl_v2.so（避开与 lwjgl3 的 341/322 套撞名），
#     jar 内 loadLibrary("lwjgl")→"lwjgl_v2" 由 scripts 的字节码 patch 处理（见 §4.3）。
#
# 用法（容器内）：
#   bash /build/build_lwjgl2_ohos.sh generate   # 仅跑生成器（JDK8）
#   bash /build/build_lwjgl2_ohos.sh neutral     # 编平台无关单元（产 .o）
#   bash /build/build_lwjgl2_ohos.sh all         # generate + neutral（P2 完成后含 backend + link）
# ============================================================================
set -u

LWJGL2_SRC=${LWJGL2_SRC:-/tmp/lwjgl2src}
LWJGL2_REVISION=${LWJGL2_REVISION:-2df01dd}
JDK8=${JDK8:-/usr/lib/jvm/java-8-openjdk-amd64}
SYSROOT=/ohos-sysroot-rw
[ -d "$SYSROOT/usr/include" ] || SYSROOT=/ohos-sysroot
OUT=${OUT:-/tmp/lwjgl2build}
SRC="$LWJGL2_SRC/src/native"

CC="/usr/bin/ohos-clang --target=aarch64-linux-ohos --sysroot=$SYSROOT"
INCS="-I$JDK8/include -I$JDK8/include/linux \
 -I$SRC/common -I$SRC/common/opengl -I$SRC/linux -I$SRC/linux/opengl"
CFLAGS="-O2 -Wall -c -fPIC -std=c99 -fno-strict-aliasing -DLWJGL_LINUX"

ensure_src() {
  if [ ! -d "$LWJGL2_SRC/src/native" ]; then
    echo "Cloning LWJGL 2 source..."
    git clone https://github.com/LWJGL/lwjgl.git "$LWJGL2_SRC" || return 1
  fi
  cd "$LWJGL2_SRC" || return 1
  git fetch --depth 1 origin "$LWJGL2_REVISION" || return 1
  git checkout --detach "$LWJGL2_REVISION" || return 1
}

do_generate() {
  ensure_src
  export JAVA_HOME="$JDK8"; export PATH="$JAVA_HOME/bin:$PATH"
  cd "$LWJGL2_SRC"
  echo "=== generator (JDK8: $(java -version 2>&1 | head -1)) ==="
  # generate-all 产出 src/generated/** + src/native/generated/{opengl,openal,opengles,opencl}/*.c
  ant -Dplatform=linux generate-all
  # headers 产出 javah JNI 头到 src/native/{common,common/opengl,linux,linux/opengl}
  ant -Dplatform=linux headers
}

do_neutral() {
  rm -rf "$OUT"; mkdir -p "$OUT"
  echo "=== ohos-clang neutral compile ==="
  /usr/bin/ohos-clang --version | head -1
  local ok=0 fail=0 faillist=""
  local srcs=""
  for d in "$SRC/common" "$SRC/common/opengl" "$SRC/generated/opengl" "$SRC/generated/openal"; do
    for f in "$d"/*.c; do
      [ -f "$f" ] || continue
      case "$(basename "$f")" in
        *AWT*|*awt*) continue;;                # AWT canvas — MC 用 Display，跳过
        *opencl*|*_CL*|org_lwjgl_opencl_*) continue;;  # OpenCL — MC 不需要
        org_lwjgl_opengl_NVVideoCaptureUtil.c|org_lwjgl_opengl_NVPresentVideoUtil.c) continue;;
      esac
      srcs="$srcs $f"
    done
  done
  for f in $srcs; do
    local base; base=$(basename "$f" .c)
    if $CC $CFLAGS $INCS -o "$OUT/$base.o" "$f" 2>"$OUT/$base.err"; then
      ok=$((ok+1))
    else
      fail=$((fail+1)); faillist="$faillist $base"
    fi
  done
  echo "=== neutral compile: ok=$ok fail=$fail (.o in $OUT) ==="
  [ -n "$faillist" ] && { echo "FAILS:$faillist"; for b in $faillist; do echo "--- $b ---"; head -4 "$OUT/$b.err"; done; }
  [ "$fail" -eq 0 ]   # 退出码反映成败
}

# ---------------------------------------------------------------------------
# TODO P2 — OHOS/EGL/XComponent backend（替代 X11/GLX），见 plan §11.11.2：
#   - 窗口  : LinuxDisplay native (org_lwjgl_opengl_Display.c/display.c) → 读 env AMCL_NATIVE_WINDOW
#             的 OH NativeWindow（与 libglfw 同源），建/管窗口（参 glfw_compat.cpp）。
#   - 上下文: opengl/context.c + LinuxContextImplementation + GLX.c/extgl_glx.c → EGL
#             （可搬 LWJGL2 自带 opengles 路径的 EGL 逻辑 + 复用 InitEGL 序列）。
#   - 像素  : LinuxDisplayPeerInfo / LinuxPeerInfo → EGLConfig。
#   - 输入  : LinuxKeyboard/Mouse/Event/Cursor → XComponent 事件源（复用 touch_input.cpp）。
#   - GL符号: extgl 的 desktop GL 函数指针表 → dlopen libgl4es.so + 其 GetProcAddress。
#   - 链接  : ohos-clang++ -shared -o liblwjgl_v2.so（version-script 视情况），strip。
#   - 声音  : linux_al.c → OpenAL-soft 交叉编译（P4）。
# ---------------------------------------------------------------------------

# AMCL OHOS backend（我们自写、桥接 libglfw+gl4es；见 plan §11.13）。
# 源码在 workspace prebuilt/lwjgl2/ohos-backend/，构建时复制到容器；BACKEND_DIR 可覆盖。
BACKEND_DIR=${BACKEND_DIR:-/tmp/lwjgl2-ohos-backend}
do_backend() {
  [ -d "$BACKEND_DIR" ] || { echo "skip backend: $BACKEND_DIR 不存在（把 prebuilt/lwjgl2/ohos-backend/ 复制到此）"; return 0; }
  mkdir -p "$OUT"
  echo "=== ohos-clang backend compile ($BACKEND_DIR) ==="
  local ok=0 fail=0
  for f in "$BACKEND_DIR"/*.c; do
    [ -f "$f" ] || continue
    local base; base=$(basename "$f" .c)
    if $CC $CFLAGS $INCS -I"$BACKEND_DIR" -o "$OUT/$base.o" "$f" 2>"$OUT/$base.err"; then
      echo "OK   $base"; ok=$((ok+1))
    else
      echo "FAIL $base"; head -6 "$OUT/$base.err"; fail=$((fail+1))
    fi
  done
  echo "=== backend compile: ok=$ok fail=$fail ==="
  [ "$fail" -eq 0 ]
}

do_java() {
  export JAVA_HOME="$JDK8"; export PATH="$JAVA_HOME/bin:$PATH"
  local SRCROOT="$LWJGL2_SRC/src/java"
  local SRCJ="$SRCROOT/org/lwjgl/opengl"
  local BIN="$LWJGL2_SRC/bin"
  local PATCH_JAVA_DIR=${PATCH_JAVA_DIR:-/tmp/lwjgl2-patches/java}
  echo "=== integrate AMCL backend java + factory patch ==="
  # 复制 AMCL 后端类（保留包路径 org/lwjgl/... 与 org/lwjgl/opengl/...）
  [ -d "$PATCH_JAVA_DIR/org" ] && cp -rf "$PATCH_JAVA_DIR/org" "$SRCROOT/"
  # 工厂 + 库名 patch（幂等）
  sed -i 's/return new LinuxDisplay();/return new AMCLDisplay();/' "$SRCJ/Display.java"
  sed -i 's/return new LinuxContextImplementation();/return new AMCLContextImplementation();/' "$SRCJ/ContextGL.java"
  sed -i 's/return new LinuxSysImplementation();/return new AMCLSysImplementation();/' "$SRCROOT/org/lwjgl/Sys.java"
  sed -i 's/private static final String JNI_LIBRARY_NAME = "lwjgl";/private static final String JNI_LIBRARY_NAME = "lwjgl_v2";/' "$SRCROOT/org/lwjgl/Sys.java"
  echo "--- patch check ---"
  grep -h 'new AMCLDisplay()\|new AMCLContextImplementation()\|new AMCLSysImplementation()\|JNI_LIBRARY_NAME = ' \
    "$SRCJ/Display.java" "$SRCJ/ContextGL.java" "$SRCROOT/org/lwjgl/Sys.java"
  javac -encoding UTF-8 -source 1.6 -target 1.6 -cp "$BIN" -d "$BIN" \
    $(find "$SRCROOT/org/lwjgl" -name 'AMCL*.java') \
    "$SRCJ/Display.java" "$SRCJ/ContextGL.java" "$SRCROOT/org/lwjgl/Sys.java" || return 1
  mkdir -p "$BACKEND_DIR"
  javah -force -classpath "$BIN" -d "$BACKEND_DIR" \
    org.lwjgl.opengl.AMCLDisplay org.lwjgl.opengl.AMCLContextImplementation || return 1
  echo "=== java ok (AMCL*.class + javah headers in $BACKEND_DIR) ==="
}

do_jar() {
  export JAVA_HOME="$JDK8"; export PATH="$JAVA_HOME/bin:$PATH"
  local BIN="$LWJGL2_SRC/bin"
  local JAR="$OUT/lwjgl.jar"
  mkdir -p "$OUT"
  # 运行期 jar：打包 org/lwjgl/**（含 AMCL 后端类）。generator/test/examples 留着无害（运行期不引用）。
  ( cd "$BIN" && jar cf "$JAR" org/lwjgl ) || return 1
  echo "=== jar: $(ls -la "$JAR") ==="
}

do_link() {
  local SO="$OUT/liblwjgl_v2.so"
  echo "=== link liblwjgl_v2.so ($(ls "$OUT"/*.o 2>/dev/null | wc -l) objects) ==="
  /usr/bin/ohos-clang --target=aarch64-linux-ohos --sysroot=$SYSROOT \
    -shared -fPIC -fuse-ld=lld -Wl,-soname,liblwjgl_v2.so \
    -o "$SO" "$OUT"/*.o || return 1
  ls -la "$SO"
  echo "=== link ok (NEEDED 仅 libc；glfw/gl4es 走 dlopen) ==="
}

case "${1:-all}" in
  generate) do_generate ;;
  neutral)  do_neutral ;;
  java)     do_java ;;
  backend)  do_backend ;;
  link)     do_link ;;
  jar)      do_jar ;;
  all)      do_generate && do_java && do_neutral && do_backend && do_link && do_jar ;;
  *) echo "usage: $0 {generate|java|neutral|backend|link|jar|all}"; exit 1 ;;
esac
