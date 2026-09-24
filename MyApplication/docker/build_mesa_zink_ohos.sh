#!/bin/bash
set -e
# ============================================================
#  Mesa OSMesa + Zink cross-compile for HarmonyOS NEXT (aarch64/musl)
#
#  目标：产出 libOSMesa.so（含 Zink Gallium 驱动），在只支持 Vulkan 的设备上获得
#        真·桌面 OpenGL 4.6 —— 让 Voxy / Nvidium 等"只吃桌面 GL 4.x"的 mod 能跑。
#  渲染链：MC GL → LWJGL → libOSMesa(Mesa GL) → Zink(Gallium→Vulkan) → 设备 libvulkan → Maleoon 920
#
#  上游 pin: deps.lock [mesa-zink]
#  参考实现: PojavLauncherTeam/osmesa-zink-builder（Android/bionic → 本脚本改 OHOS/musl）
#  规划: docs/adaptation/ZINK_RENDERER_PLAN.md（Phase 1）
#
#  用法（容器内）：
#    docker exec ohos-debug bash /build/build_mesa_zink_ohos.sh deps       # 装构建依赖（meson/flex/bison/mako）
#    docker exec ohos-debug bash /build/build_mesa_zink_ohos.sh configure   # 仅 meson setup（先打通 configure）
#    docker exec ohos-debug bash /build/build_mesa_zink_ohos.sh build       # configure + ninja
#  产物：/output/mesa-zink/libOSMesa.so（→ docker cp 到 entry/libs/arm64-v8a/）
#
#  ⚠️ 状态：Phase 1 探路。Mesa 构建系统假设 glibc/Linux，musl/OHOS 适配会逐个报错收敛
#     （照搬 JDK/freetype 移植经验）。本脚本是骨架 + 已知旗标，错误在 configure/build 期逐步啃。
# ============================================================

STAGE=${1:-configure}
WORK_DIR=/build
SRC_DIR=${SRC_DIR:-$WORK_DIR/mesa-ohos-src}
MESA_REPO=${MESA_REPO:-https://gitlab.freedesktop.org/mesa/mesa.git}
# deps.lock [mesa-zink] commit/tag —— 选近一年稳定 tag（Zink 已 GL4.6 conformant）。
MESA_TAG=${MESA_TAG:-mesa-24.3.4}
OHOS_SYSROOT=${OHOS_SYSROOT:-/ohos-sysroot-rw}
OUTPUT_DIR=${OUTPUT_DIR:-/output/mesa-zink}
JOBS=${JOBS:-$(nproc)}
PATCH_DIR=${PATCH_DIR:-/build/mesa-zink-patches}
BUILD_DIR=$SRC_DIR/build-ohos

OHOS_LIBDIR=$OHOS_SYSROOT/usr/lib/aarch64-linux-ohos

# OHOS NDK 的 libc++（__n1 ABI）头 + 库。Zink/部分 Mesa 是 C++，最终链接 libOSMesa.so 需要它。
# ⚠️ 关键：镜像自带的 Ubuntu libc++-15 头是 __1 ABI，设备/sysroot 的 libc++_shared.so 是 __n1 ABI
#    → 用错头会编出 std::__1:: 符号、链接/运行期 "undefined/symbol not found"（同 shaderc 2026-05-31 坑）。
#    必须用 NDK 的 libcxx-ohos 头（__config_site 含 _LIBCPP_ABI_NAMESPACE __n1）。
#    通过 OHOS_LIBCXX_DIR 传入（默认 /output/ohos-libcxx，需先 stage：见 build_shaderc_ohos.sh 尾注）。
OHOS_LIBCXX_DIR=${OHOS_LIBCXX_DIR:-/output/ohos-libcxx}
OHOS_CXX_INC=$OHOS_LIBCXX_DIR/include/c++/v1
OHOS_CXX_LIB=$OHOS_LIBCXX_DIR/lib

# ============================================================
#  deps —— 装 Mesa 构建期依赖（host 工具，不进产物）
#    meson + ninja（构建）/ flex + bison（GLSL 词法语法）/ python3-mako（代码生成）
# ============================================================
if [ "$STAGE" = "deps" ]; then
  echo "[deps] installing meson/flex/bison/mako ..."
  (apt-get update && apt-get install -y meson flex bison python3-mako python3-pip pkg-config) \
    || pip3 install --break-system-packages meson mako 2>/dev/null || pip3 install meson mako
  echo "[deps] meson=$(meson --version 2>/dev/null) ninja=$(ninja --version 2>/dev/null) flex=$(flex --version 2>/dev/null|head -1) bison=$(bison --version 2>/dev/null|head -1)"
  exit 0
fi

[ -d "$OHOS_SYSROOT/usr/include" ] || { echo "ERROR: sysroot $OHOS_SYSROOT not ready (先跑 setup_toolchain.sh)"; exit 1; }

echo "============================================"
echo " Mesa OSMesa+Zink for HarmonyOS NEXT (aarch64)"
echo " Sysroot: $OHOS_SYSROOT   Mesa: $MESA_TAG"
echo "============================================"

# --- 源码（pin tag）---
if [ ! -d "$SRC_DIR/.git" ]; then
    echo "[src] clone Mesa $MESA_TAG (shallow) ..."
    git clone --depth 1 --branch "$MESA_TAG" "$MESA_REPO" "$SRC_DIR"
fi
cd "$SRC_DIR"

# --- 应用 OHOS/musl 补丁（若有，随适配增补）---
if [ -d "$PATCH_DIR" ] && [ -f "$PATCH_DIR/series" ]; then
    echo "[patch] applying OHOS patches from $PATCH_DIR/series"
    git checkout -q . 2>/dev/null || true
    while IFS= read -r p || [ -n "$p" ]; do
        p="${p%$'\r'}"; [ -z "$p" ] && continue
        case "$p" in \#*) continue ;; esac
        echo "  apply $p"; git apply "$PATCH_DIR/$p"
    done < "$PATCH_DIR/series"
fi

# --- meson cross file（aarch64-linux-ohos / musl / clang）---
# ⚠️ 不能用 setup_toolchain.sh / build_jdk8 的 `aarch64-linux-ohos-gcc` 包装器：JDK8 那个会
#    伪造 "gcc (GCC) 4.9.2" banner，导致 meson 把编译器误判成 GCC 4.2.1 → "GCC>=4.4.6 required"。
#    故仿 build_gl4es 造干净的 clang 包装器，让 meson 正确识别为 clang。
MESA_CC=/tmp/ohos-mesa-cc
MESA_CXX=/tmp/ohos-mesa-cxx
cat > "$MESA_CC" <<CCEOF
#!/bin/bash
exec /usr/bin/ohos-clang --target=aarch64-linux-ohos --sysroot=$OHOS_SYSROOT -D__MUSL__ -Qunused-arguments -L$OHOS_LIBDIR -fuse-ld=lld "\$@"
CCEOF
# C++ 编译/链接：必须用 OHOS __n1 头（见上 OHOS_LIBCXX_DIR 说明）。
# -nostdinc++ 屏蔽 Ubuntu __1 头；-isystem 指 OHOS __n1 头；-stdlib=libc++ + -L$OHOS_CXX_LIB
# 让 driver 自动补 -lc++（解析到 OHOS 的 libc++.so = __n1 的 libc++_shared 副本，NEEDED 干净）。
# 两个 musl/rune define 同 shaderc（OHOS musl libc++ 本身需要）。
if [ -f "$OHOS_CXX_INC/__config_site" ] && grep -q '_LIBCPP_ABI_NAMESPACE __n1' "$OHOS_CXX_INC/__config_site" 2>/dev/null; then
  echo "  [cxx] using OHOS __n1 libc++ headers: $OHOS_CXX_INC"
  cat > "$MESA_CXX" <<CXEOF
#!/bin/bash
exec /usr/bin/ohos-clang++ --target=aarch64-linux-ohos --sysroot=$OHOS_SYSROOT -D__MUSL__ \\
  -stdlib=libc++ -nostdinc++ -isystem $OHOS_CXX_INC \\
  -D_LIBCPP_HAS_MUSL_LIBC -D_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE \\
  -Qunused-arguments -L$OHOS_LIBDIR -L$OHOS_CXX_LIB -fuse-ld=lld "\$@"
CXEOF
else
  echo "  ⚠️ [cxx] OHOS __n1 libc++ 头未找到（OHOS_LIBCXX_DIR=$OHOS_LIBCXX_DIR）。"
  echo "     最终链接 libOSMesa.so 会因 std::__1 vs __n1 ABI 不匹配而 undefined symbol 失败。"
  echo "     先 stage NDK libcxx-ohos 头到该目录（见 build_shaderc_ohos.sh 尾注 / scripts/stage_ohos_libcxx）。"
  echo "     —— 仍写一个 fallback wrapper（用镜像 __1 头）以便 configure/编译期推进。"
  cat > "$MESA_CXX" <<CXEOF
#!/bin/bash
exec /usr/bin/ohos-clang++ --target=aarch64-linux-ohos --sysroot=$OHOS_SYSROOT -D__MUSL__ -Qunused-arguments -stdlib=libc++ -nostdlib++ -L$OHOS_LIBDIR -fuse-ld=lld "\$@" -lc++_shared
CXEOF
fi
chmod +x "$MESA_CC" "$MESA_CXX"

CROSS=/tmp/ohos-mesa-cross.ini
cat > "$CROSS" <<CROSSEOF
[binaries]
c = '$MESA_CC'
cpp = '$MESA_CXX'
ar = '/usr/bin/ohos-ar'
strip = '/usr/bin/ohos-strip'
pkg-config = 'pkg-config'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[properties]
needs_exe_wrapper = true
CROSSEOF

if [ "$STAGE" = "configure" ] || [ "$STAGE" = "build" ]; then
  echo "[configure] meson setup ..."
  rm -rf "$BUILD_DIR"
  # 交叉 pkg-config：OHOS sysroot 有 libz.so/zlib.h 但无 zlib.pc → 自造 .pc，并用
  # PKG_CONFIG_LIBDIR 把搜索域锁到这里（排除 host x86_64 的 libz/libexpat，避免
  # "incompatible with aarch64linux" 链接错）；PKG_CONFIG_SYSROOT_DIR 让 -L/-I 自动加 sysroot 前缀。
  # expat 不在 sysroot → 不提供其 .pc，Mesa 走"无 expat"路径（drirc/XML 配置禁用，OSMesa 不需要）。
  mkdir -p /tmp/ohos-pkgconfig
  cat > /tmp/ohos-pkgconfig/zlib.pc <<PCEOF
prefix=/usr
libdir=\${prefix}/lib/aarch64-linux-ohos
includedir=\${prefix}/include
Name: zlib
Description: zlib compression library
Version: 1.2.11
Libs: -L\${libdir} -lz
Cflags: -I\${includedir}
PCEOF
  export PKG_CONFIG_LIBDIR=/tmp/ohos-pkgconfig
  export PKG_CONFIG_SYSROOT_DIR=$OHOS_SYSROOT
  # 关键旗标：
  #   gallium-drivers=zink,softpipe → 编 Zink（GL→Vulkan）+ softpipe（CPU 兜底/基线）
  #   vulkan-drivers=[]     → 不编任何 Vulkan ICD（用设备自带 libvulkan，运行时 dlopen）
  #   osmesa=true           → 产 libOSMesa.so（离屏 GL 上下文，供 LWJGL 加载）
  #   gbm/egl/glx/platforms 关掉 → 无 X11/GBM/DRM 依赖（OSMesa→zink 走 sw_screen_create
  #     直连 null sw winsys 的离屏路径，不用 pipe_loader 的 kopper 路径，故不需要 HAVE_DRI/libdrm）
  #   xmlconfig=disabled    → driconf 走 stub，免 expat 依赖（zink 用 driParseConfigFiles，
  #     WITH_XMLCONFIG=0 时为 no-op stub，driconf 选项取默认值即可）
  #   shared-glapi=disabled + gles1/2=disabled → glapi 静态链入 libOSMesa，**不产单独 libglapi.so**。
  #     这是为绕开 OHOS 坑：libglfw 所在 ndk 命名空间 dlopen libOSMesa 时，其 NEEDED libglapi.so
  #     在该命名空间搜不到（errno=2）→ 整个 dlopen 失败。静态 glapi 后 libOSMesa 的 NEEDED 仅
  #     libz/libc++_shared/libc（系统/已全局），绝对路径 dlopen 即可成。gles2 依赖 shared-glapi 故一并关。
  #   llvm=disabled         → Zink 不需要 LLVM（不像 softpipe/llvmpipe）
  # ⚠️ zink 真正链进 OSMesa target 靠 patches/0002（meson 加 driver_zink+idep_xmlconfig）
  #    + 0003（inline_sw_helper 补 zink_public.h include）+ 0001（VK_LIBNAME→libvulkan.so）。
  #    setup_deps/手动 apply patches/series 后再 configure。
  meson setup "$BUILD_DIR" \
    --cross-file "$CROSS" \
    --prefix=/usr \
    -Dgallium-drivers=zink,softpipe \
    -Dvulkan-drivers= \
    -Dplatforms= \
    -Dglx=disabled \
    -Degl=disabled \
    -Dgbm=disabled \
    -Dosmesa=true \
    -Dxmlconfig=disabled \
    -Dshared-glapi=disabled \
    -Dllvm=disabled \
    -Dgallium-vdpau=disabled \
    -Dgallium-va=disabled \
    -Dgallium-xa=disabled \
    -Dgles1=disabled \
    -Dgles2=disabled \
    -Dopengl=true \
    -Dc_args="-D__MUSL__ -D__OHOS__ -D_GNU_SOURCE -DHAVE_DLFCN_H -DHAVE_STRUCT_TIMESPEC -DUTIL_ARCH_LITTLE_ENDIAN=1 -DUTIL_ARCH_BIG_ENDIAN=0 -Wno-error" \
    -Dcpp_args="-D__MUSL__ -D__OHOS__ -D_GNU_SOURCE -DHAVE_DLFCN_H -DHAVE_STRUCT_TIMESPEC -DUTIL_ARCH_LITTLE_ENDIAN=1 -DUTIL_ARCH_BIG_ENDIAN=0 -Wno-error" \
    2>&1 | tee /build/mesa-configure.log
  echo "MESON_SETUP_EXIT=${PIPESTATUS[0]}"
fi

if [ "$STAGE" = "build" ]; then
  echo "[build] ninja (libOSMesa) ..."
  ninja -C "$BUILD_DIR" -j"$JOBS" 2>&1 | tee /build/mesa-build.log
  echo "NINJA_EXIT=${PIPESTATUS[0]}"

  BUILT=$(find "$BUILD_DIR" -name 'libOSMesa.so*' -type f 2>/dev/null | head -1)
  [ -n "$BUILT" ] || { echo "ERROR: libOSMesa.so not produced"; exit 1; }
  mkdir -p "$OUTPUT_DIR"
  cp "$BUILT" "$OUTPUT_DIR/libOSMesa.so"
  /usr/bin/ohos-strip --strip-unneeded "$OUTPUT_DIR/libOSMesa.so" 2>/dev/null || true
  # libOSMesa.so NEEDED libglapi.so.0（Mesa 的共享 GL API）—— 一并产出，部署时同 entry/libs。
  GLAPI=$(find "$BUILD_DIR" -name 'libglapi.so.0.0.0' -type f 2>/dev/null | head -1)
  if [ -n "$GLAPI" ]; then
    cp "$GLAPI" "$OUTPUT_DIR/libglapi.so.0"
    /usr/bin/ohos-strip --strip-unneeded "$OUTPUT_DIR/libglapi.so.0" 2>/dev/null || true
    echo "  -> $OUTPUT_DIR/libglapi.so.0 ($(stat -c%s "$OUTPUT_DIR/libglapi.so.0") bytes)"
  fi
  echo "  -> $OUTPUT_DIR/libOSMesa.so ($(stat -c%s "$OUTPUT_DIR/libOSMesa.so") bytes)"
  echo "--- arch + key symbols (OSMesaCreateContextAttribs / glGetString) ---"
  ohos-readelf -h "$OUTPUT_DIR/libOSMesa.so" 2>/dev/null | grep -E 'Machine|Class' || true
  ohos-readelf -sW "$OUTPUT_DIR/libOSMesa.so" 2>/dev/null | grep -E 'OSMesaCreateContext|OSMesaMakeCurrent|glGetString' | head || true
  echo "--- NEEDED ---"
  ohos-readelf -d "$OUTPUT_DIR/libOSMesa.so" 2>/dev/null | grep NEEDED | tr -s ' ' | paste -sd' '
  echo "Done."
fi
