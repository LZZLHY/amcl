#!/bin/bash
set -e

# ============================================================
#  OpenJDK 8u for HarmonyOS NEXT — 经典布局完整构建入口
#
#  目标：用 clang-15 + OHOS NDK sysroot 把 jdk8u 编到 aarch64 musl/OHOS。
#  固定源码和外部字体输入、校验 series，再生成完整 image 与候选包。
#
#  与 build_jdk21_ohos.sh 的差异（JDK 8 特有）：
#   - boot JDK = JDK 8（不是 21）
#   - 源码树 jdk8u（老森林：hotspot/ jdk/ langtools/ ...）
#   - config.guess 在 common/autoconf/build-aux/（不是 make/autoconf/）
#   - freetype 必须显式给（8 不 bundle）：--with-freetype-include/lib
#   - target 用 ...-linux-gnu（jdk8u 老 config.sub 不认 musl 三元组）
#   - 经典布局产物（jre/lib/aarch64/...），无 lib/modules
#
#  用法（容器内）：
#    bash build_jdk8_ohos.sh configure   # 显式只跑 configure，不产生发行包
#    bash build_jdk8_ohos.sh build       # 默认：完整构建、打包和内容审计
# ============================================================

STAGE=${1:-build}
case "$STAGE" in configure|build) ;; *) echo 'ERROR: stage must be configure or build'; exit 2;; esac
# 原始 SDK 必须来自受控只读挂载；setup 负责生成带输入身份的可写层。
OHOS_SYSROOT=${OHOS_SYSROOT:-/ohos-sysroot}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-/ohos-toolchain}
WORK_DIR=/build
JOBS=${JOBS:-$(nproc)}
SRC=$WORK_DIR/jdk8u

# boot JDK8 由 Dockerfile.jdk8-toolchain 的官方归档和 SHA-256 固定。
export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
if [ ! -x "$JAVA_HOME/bin/javac" ]; then
  echo "ERROR: boot JDK 8 not found at $JAVA_HOME"; exit 1
fi

echo "============================================"
echo " OpenJDK 8u for HarmonyOS NEXT (aarch64) — $STAGE"
echo " Sysroot:  $OHOS_SYSROOT"
echo " Boot JDK: $JAVA_HOME ($($JAVA_HOME/bin/java -version 2>&1|head -1))"
echo " Jobs:     $JOBS"
echo "============================================"

# --- 工具链 ---
# 不在 source 前使用临时变量赋值：Bash 会在 source 返回时恢复旧值，导致后续
# configure 桩库错误地写向原始只读 SDK。setup 导出的可写路径必须持续有效。
source /build/setup_toolchain.sh
export PATH=$TOOLCHAIN_DIR:$PATH

# 新卷也必须能独立完成取源、补丁、头文件准备；拒绝依赖旧容器预先做过的手工步骤。
python3 /build/scripts/prepare_jdk_source.py 8
python3 /build/scripts/apply_jdk_patches.py --patch-dir /prebuilt/jdk/8/patches --target "$SRC"
mkdir -p /build/stub-cups /build/stub-headers
cp -a /build/stubs/cups/. /build/stub-cups/
cp -a /build/stubs/fontconfig/. /build/stub-headers/
cp -a /build/stubs/x11/. /build/stub-headers/
[ -d /usr/include/alsa ] || { echo 'ERROR: missing configure-only ALSA headers'; exit 1; }
cp -a /usr/include/alsa /build/stub-headers/
# FreeType 先用通用交叉 wrapper 构建，不需要 JDK8 的 configure 兼容 banner。
bash /build/scripts/prepare_freetype8.sh

# ============================================================
# JDK 8 专属：骗过 GCC-only 的 toolchain 探测
# jdk8u 的 common/autoconf 在 Linux 上只认 gcc（没有 --with-toolchain-type=clang，
# 那是 JDK 9+ 才有）。它跑 `$CC --version` 找 "gcc"/"Free Software Foundation"，
# clang 的 banner 不匹配 → "does not seem to be the required gcc compiler"。
# 这里把 gcc/g++ 包装器改成：遇到 --version / -dumpversion 时伪造 gcc 4.9.2 banner，
# 其余照常 exec ohos-clang。让 configure 通过后，再看真正编译时 gcc↔clang 旗标分歧。
# 这是显式保留的 JDK8 configure 兼容层，实际编译器始终是 clang-15；
# 身份清单记录真实 clang 输出，不能把此探测 banner 当作 GCC 供应链身份。
# ============================================================
install_fake_gcc_wrapper() {
  local path="$1" clangbin="$2" lang="$3"
  local syslib="${OHOS_SYSROOT}/usr/lib/aarch64-linux-ohos"
  local cxxflags=""
  [ "$lang" = "cxx" ] && cxxflags="-stdlib=libc++ -nostdlib++ -isystem /usr/lib/llvm-15/include/c++/v1"
  cat > "$path" <<WRAP
#!/bin/bash
for a in "\$@"; do
  case "\$a" in
    --version) echo "gcc (GCC) 4.9.2"; echo "Copyright (C) 2014 Free Software Foundation, Inc."; exit 0;;
    -dumpversion) echo "4.9.2"; exit 0;;
  esac
done
# 编译期 vs 链接期；以及输入是否 C 源（.c）。
LINKING=1; IS_C=0; LINK_EXECUTABLE=1; HAS_OUTPUT=0
for arg in "\$@"; do
  case "\$arg" in
    -c|-E|-S) LINKING=0;;
    *.c) IS_C=1;;
  esac
  case "\$arg" in -c|-E|-S|-shared|-r) LINK_EXECUTABLE=0;; -o) HAS_OUTPUT=1;; esac
done
ARGS=()
for arg in "\$@"; do
  case "\$arg" in
    -lpthread|-ldl|-lrt|-lresolv) ;;
    -static-libstdc++|-static-libgcc) ;;
    # HotSpot 关闭 C++ 异常/RTTI，所需 ABI 符号由已验证的专用 shim 提供。
    # 原脚本转成 -lc++ 依赖旧 sysroot 的手工库，新 SDK 并没有该文件。
    -lstdc++) ARGS+=("-lcxxabi_shim");;
    -std=gnu++*|-std=c++*) [ "\$IS_C" = "1" ] || ARGS+=("\$arg");;
    *) ARGS+=("\$arg");;
  esac
done
# 经典 JDK 的辅助程序若存在也必须使用 OHOS musl 解释器；共享库不能加此参数。
if [ "\$LINK_EXECUTABLE" = 1 ] && [ "\$HAS_OUTPUT" = 1 ]; then
  ARGS+=("-Wl,--dynamic-linker=/lib/ld-musl-aarch64.so.1")
fi
COMMON="--target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} -Qunused-arguments -Wno-error=int-conversion -Wno-error=implicit-function-declaration -Wno-error=implicit-int -Wno-error=incompatible-pointer-types -I${OHOS_SYSROOT}/usr/include/aarch64-linux-ohos -I/build/stub-headers ${cxxflags} -B${syslib} -L${syslib} -rtlib=compiler-rt -unwindlib=none -fuse-ld=lld"
if [ "\$LINKING" = "1" ]; then
  exec $clangbin \$COMMON -L/build/jdk8-libs -lcxxabi_shim "\${ARGS[@]}" -Wno-error
else
  exec $clangbin \$COMMON "\${ARGS[@]}" -Wno-error
fi
WRAP
  chmod +x "$path"
}
install_fake_gcc_wrapper "$TOOLCHAIN_DIR/aarch64-linux-ohos-gcc" /usr/bin/ohos-clang c
install_fake_gcc_wrapper "$TOOLCHAIN_DIR/aarch64-linux-ohos-g++" /usr/bin/ohos-clang++ cxx
echo "  installed fake-gcc-banner wrappers w/ baked cross flags (JDK8 workaround)"

cd "$SRC"

# 锁定的 8u452 源码不存在旧脚本假定的 WSL 检测行；不再执行静默无效的 sed。
export SOURCE_DATE_EPOCH="$(git log -1 --format=%ct)"

ARCH_INCLUDE="-I${OHOS_SYSROOT}/usr/include/aarch64-linux-ohos"
LIBCXX_INC=/usr/lib/llvm-15/include/c++/v1
TARGET_LIB="${OHOS_SYSROOT}/usr/lib/aarch64-linux-ohos"

# 预建 libcxxabi_shim.so（configure 链接测试需要；与 jdk21 同款）
# 全程写容器本地 /build（避开当前不可靠的 D:\ bind mount）。
OUT_LIBDIR=/build/jdk8-libs
mkdir -p "$OUT_LIBDIR"
STUBS_SRC_DIR=/build/stubs/src
for c in /build/stubs/src /stubs-src/src /stubs-src /work25/stubs-src/src; do
  [ -f "$c/eh_stubs.c" ] && STUBS_SRC_DIR="$c" && break
done
echo "  stubs src: $STUBS_SRC_DIR ; out libdir: $OUT_LIBDIR"
/usr/bin/ohos-clang --target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} $ARCH_INCLUDE \
    -c -fPIC -o /tmp/eh_stubs.o "$STUBS_SRC_DIR/eh_stubs.c"

# musl 兼容垫片（isnanf/isinff/__xpg_strerror_r/awt_*）必须编进同一个 .so ——
# 理由：JDK 8 的 hotspot/jdk 链接行已经带 -lcxxabi_shim，搭这趟车就不用改 configure。
# ⚠️ 这一步 2026-06 是**手工**做的，脚本里只留了一行 TODO ⇒ 换容器后 JDK 8 直接编不过。
#    2026-08-29 正式化进脚本；找不到源就硬失败，别静默编出一个缺符号的 shim。
MUSL_COMPAT=""
for c in /host-docker/jdk8_musl_compat.c /out/jdk8_musl_compat.c /build/jdk8_musl_compat.c \
         "$(dirname "$0")/jdk8_musl_compat.c"; do
  [ -f "$c" ] && MUSL_COMPAT="$c" && break
done
[ -n "$MUSL_COMPAT" ] || { echo "ERROR: jdk8_musl_compat.c not found (docker/jdk8_musl_compat.c)"; exit 1; }
echo "  musl compat shim: $MUSL_COMPAT"
/usr/bin/ohos-clang --target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} $ARCH_INCLUDE \
    -c -fPIC -o /tmp/jdk8_musl_compat.o "$MUSL_COMPAT"

/usr/bin/ohos-clang++ --target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} $ARCH_INCLUDE \
    -shared -fPIC -fvisibility=hidden -fno-exceptions -fno-rtti \
    -nostdlib -L${TARGET_LIB} \
    -o "$OUT_LIBDIR/libcxxabi_shim.so" "$STUBS_SRC_DIR/cxxabi_shim.cpp" /tmp/eh_stubs.o \
    /tmp/jdk8_musl_compat.o \
    -fuse-ld=lld -Wl,-soname,libcxxabi_shim.so -lc
# 断言垫片符号真的被导出了 —— `-fvisibility=hidden` + 忘了 EXPORT 会静默丢符号，
# 而后果要等到几十分钟后 libjava.so 链接才炸。
for s in isnanf isinff __xpg_strerror_r awt_Lock; do
  /usr/bin/llvm-nm-15 --defined-only "$OUT_LIBDIR/libcxxabi_shim.so" 2>/dev/null | grep -qw "$s" \
    || { echo "ERROR: libcxxabi_shim.so 缺导出符号 $s"; exit 1; }
done
echo "  libcxxabi_shim.so ready (含 musl 垫片，符号已断言)"

# X11 stub 头补两个 Xt 类型：headless 构建仍会编 jawt/头文件预处理，
# 而我们的 stub Intrinsic.h 是手写的最小集，缺这两个 typedef 会在预处理期报错。
XT_H=/build/stub-headers/X11/Intrinsic.h
if [ -f "$XT_H" ] && ! grep -q 'typedef char Boolean;' "$XT_H"; then
  {
    echo ""
    echo "/* OHOS JDK8: minimal Xt types needed by jdk8u headers */"
    echo "typedef char Boolean;"
    echo "typedef struct _XRegion *Region;"
  } >> "$XT_H"
  echo "  patched $XT_H (Boolean/Region)"
fi

# JDK 8 没有 --enable-headless-only：headful 强制，configure 必须找到 X11 (+ ALSA) 库。
# 用 nostdlib 造空 stub .so（与 build_jdk21 的 libasound stub 同款），头文件用 /build/stub-headers。
echo "  creating X11/ALSA stub libs for JDK8 headful configure..."
for lib in asound X11 Xext Xrender Xtst Xt Xi Xau Xdmcp; do
  so="${TARGET_LIB}/lib${lib}.so"
  if [ ! -f "$so" ]; then
    echo "void ${lib}_stub(void){}" > /tmp/${lib}_stub.c
    /usr/bin/ohos-clang --target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} \
        -fuse-ld=lld -shared -nostdlib -o "$so" /tmp/${lib}_stub.c
  fi
done
echo "  stub libs ready"

export BUILD_CC=/usr/bin/clang-15
export BUILD_CXX=/usr/bin/clang++-15

COMMON_CFLAGS="--target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} -fPIC -D__MUSL__ -DMUSL_LIBC $ARCH_INCLUDE -I/build/stub-headers -isystem $LIBCXX_INC -B${TARGET_LIB} -L${TARGET_LIB} -rtlib=compiler-rt -unwindlib=none"
COMMON_CXXFLAGS="--target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} -fPIC -D__MUSL__ -DMUSL_LIBC $ARCH_INCLUDE -I/build/stub-headers -stdlib=libc++ -nostdlib++ -B${TARGET_LIB} -L${TARGET_LIB} -rtlib=compiler-rt -unwindlib=none"
COMMON_LDFLAGS="--target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} -fuse-ld=lld -B${TARGET_LIB} -L${TARGET_LIB} -rtlib=compiler-rt -unwindlib=none -nostdlib++ -L${OUT_LIBDIR} -lcxxabi_shim"

if [ "$STAGE" = "configure" ] || [ "$STAGE" = "build" ]; then
  echo ""
  echo "[configure] running..."
  bash configure \
    --openjdk-target=aarch64-unknown-linux-gnu \
    --with-jvm-variants=server \
    --with-debug-level=release \
    --with-native-debug-symbols=none \
    --with-boot-jdk=$JAVA_HOME \
    --with-stdc++lib=dynamic \
    --with-freetype-include=/build/freetype-2.13.3/include \
    --with-freetype-lib=/build/freetype-2.13.3/objs/.libs \
    --with-extra-cflags="$COMMON_CFLAGS" \
    --with-extra-cxxflags="$COMMON_CXXFLAGS" \
    --with-extra-ldflags="$COMMON_LDFLAGS" \
    --with-cups-include=/build/stub-cups \
    --with-x \
    --x-includes=/build/stub-headers \
    --x-libraries=${TARGET_LIB} \
    CC=aarch64-linux-ohos-gcc \
    CXX=aarch64-linux-ohos-g++ \
    AR=aarch64-linux-ohos-ar \
    STRIP=aarch64-linux-ohos-strip \
    NM=aarch64-linux-ohos-nm \
    OBJCOPY=aarch64-linux-ohos-objcopy \
    2>&1 | tee /build/configure-8.log
  CFG_RC=${PIPESTATUS[0]}
  echo "CONFIGURE_EXIT=$CFG_RC"
  [ "$CFG_RC" -ne 0 ] && { echo "CONFIGURE FAILED"; exit $CFG_RC; }
fi

if [ "$STAGE" = "build" ]; then
  echo ""
  # ── JDK8 交叉编译关键修复 ──
  # jdk8u 把 HOST_CFLAGS/CXXFLAGS/LDFLAGS 也设成了 target 交叉旗标（--target=aarch64 +
  # sysroot + -L + -unwindlib），导致用 host clang-15 编 adlc 等"构建期工具"时被当成
  # aarch64 交叉编（编出的 adlc 在 x86 host 上跑不了）且链接旗标在 -c 期 -Werror。
  # HOSTCXX 本身已正确指向 /usr/bin/clang++-15（host），只需把 HOST_* 旗标清成干净 host 旗标。
  HSPEC="$SRC/build/linux-aarch64-normal-server-release/hotspot-spec.gmk"
  if [ -n "$HSPEC" ]; then
    echo "[fix] cleaning HOST_* flags in $HSPEC"
    {
      echo ""
      echo "# OHOS JDK8 patch: host build tools (adlc/jvmtiEnvFill/...) use clean host flags"
      echo "HOST_CFLAGS = -m64 -Qunused-arguments"
      echo "HOST_CXXFLAGS = -m64 -Qunused-arguments"
      echo "HOST_LDFLAGS = -m64"
    } >> "$HSPEC"
  else
    echo "ERROR: exact hotspot-spec.gmk missing"; exit 1
  fi

  echo "[build] make images (capturing first errors)..."
  # 已验证的 JDK8/OHOS make 旗标（完整 images 构建通过）：
  #  - WARNINGS_ARE_ERRORS= ：关 -Werror（伪 gcc 下裸 -Werror 被 clang 严诊断打挂）
  #  - USE_CLANG=true ：让 hotspot 走 clang 分支，避免 -fpch-deps 等 gcc-only 旗标
  #  - BUILDLIBSAPROC= / 'ADD_SA_BINARIES/aarch64=' ：跳过 SA native（依赖 glibc thread_db.h）+ 其 export
  #  - BUILD_HEADLESS_ONLY=true ：跳过 X11 xawt（headless；MC 用 LWJGL 不用 AWT 显示）
  #  - EXTRA_SOUND_JNI_LIBS= ：跳过 Java Sound ALSA（MC 用 OpenAL）
  # 上面 1)/2) 两条前置（musl 垫片、Xt typedef）已正式化到本脚本前半段。
  # 3) sa-jdi.jar：我们用 BUILDLIBSAPROC= 跳过了 SA 的 native，但 images 步骤仍要 jdk/lib/sa-jdi.jar。
  #    它由 hotspot 生成，正常流程会被 Import.gmk 拷过去；跳过 SA native 之后那条拷贝也没了。
  #    ⇒ 让 make 先失败一次、补上这个 jar、再续跑（make 是增量的，代价只是重跑失败那一步）。
  MK_ARGS=(JOBS=$JOBS DISABLE_HOTSPOT_OS_VERSION_CHECK=ok COMPILER_WARNINGS_FATAL=false
           WARNINGS_ARE_ERRORS= USE_CLANG=true BUILDLIBSAPROC= 'ADD_SA_BINARIES/aarch64='
           BUILD_HEADLESS_ONLY=true EXTRA_SOUND_JNI_LIBS=)

  copy_sa_jdi() {
    local src dst
    src=$(find "$SRC"/build/*/hotspot -name 'sa-jdi.jar' 2>/dev/null | head -1)
    dst=$(ls -d "$SRC"/build/*/jdk 2>/dev/null | head -1)
    if [ -n "$src" ] && [ -n "$dst" ] && [ ! -f "$dst/lib/sa-jdi.jar" ]; then
      mkdir -p "$dst/lib" && cp "$src" "$dst/lib/sa-jdi.jar"
      echo "[fix] copied $src -> $dst/lib/sa-jdi.jar"
      return 0
    fi
    return 1
  }

  echo "[build] make images (capturing first errors)..."
  make images "${MK_ARGS[@]}" 2>&1 | tee /build/build-8.log
  RC=${PIPESTATUS[0]}
  if [ "$RC" -ne 0 ] && copy_sa_jdi; then
    echo "[build] retrying images after sa-jdi.jar fixup..."
    make images "${MK_ARGS[@]}" 2>&1 | tee /build/build-8-retry.log
    RC=${PIPESTATUS[0]}
  fi
  echo "BUILD_EXIT=$RC"
  [ "$RC" -eq 0 ] || exit "$RC"

  # 经典布局保留完整 jre 与 release。外部字体和 ABI 垫片同最终 image 一起审计，
  # 不能再只抽取单个 libnet/libjvm 替换旧包来冒充一次完整源码重建。
  IMAGE="$SRC/build/linux-aarch64-normal-server-release/images/j2sdk-image"
  cp "$OUT_LIBDIR/libcxxabi_shim.so" "$IMAGE/jre/lib/aarch64/"
  cp -L /build/freetype-2.13.3/objs/.libs/libfreetype.so "$IMAGE/jre/lib/aarch64/libfreetype.so.6"
  # 修复后的完整运行包使用独立名称；不能覆盖曾含缺失 HotSpot 符号的旧候选。
  JDK_VERSION=8 JDK_IMAGE="$IMAGE" JDK_OUTPUT=/output/jdk8-ohos-runtime-link-rc1.zip \
    bash /build/scripts/pack_jdk_full.sh
fi
