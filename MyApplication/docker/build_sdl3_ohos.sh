#!/bin/bash
set -e
# ============================================================
#  SDL3 cross-compile for HarmonyOS NEXT / OpenHarmony (aarch64, musl)
#
#  MC 26.3 Snapshot 4 起把 GLFW 换成了 SDL3（版本清单声明 org.lwjgl:lwjgl-sdl:3.4.2，
#  完全没有 lwjgl-glfw），LWJGL 的 SDL 绑定用 libffi 直调 libSDL3.so 的 SDL_* 符号。
#  本脚本产出那个 libSDL3.so。
#
#  上游 pin: deps.lock [sdl3-native]（**以 deps.lock 为准，本文件的默认值只是兜底**）
#     upstream = libsdl-org/SDL
#     repo     = icculus/SDL   branch = sdl3-harmonyos
#  2026-08-01 起基线从 LZZLHY/SDL(ohos) 切到 icculus/SDL(sdl3-harmonyos)：后者是 SDL
#  核心作者本人在做的 OHOS 后端，实现质量与后续可维护性都更好；我们对"它是否进上游"
#  不敏感 —— 进了就把 patch 平移，烂尾了我们有已验证实现且完整掌握代码。
#  旧基线仍作 fallback 保留在 deps.lock 注释里（含 15 个切片提交与原作者署名，
#  重建过程见 scripts/rebuild-sdl3-ohos-history.mjs）。
#  AMCL 专有改动落在 prebuilt/sdl3/patches/（我们不拥有 icculus 那个分支）。
#  方案与缺口矩阵见 docs/adaptation/SDL3_MIGRATION_PLAN.md、prebuilt/sdl3/README.md，
#  施工过程见 docs/adaptation/SDL3_PORT_WORKLOG.md。
#
#  历史 Docker 配方入口：launch-builder.ps1 -Component sdl3（主机权威构建仍是 build-sdl3-ohos.ps1）
#  产物：/output/sdl3/libSDL3.so（→ entry/libs/arm64-v8a/）
# ============================================================
#
#  与其它 build_*_ohos.sh 的三点不同，都是实测得出的，别照抄错：
#
#  1. **纯 C，不需要 libc++**。SDL3 是 `project(SDL3 LANGUAGES C)`；仓库里 38 个
#     .cpp/.cc 全在 haiku / ngage / gdk / windows / direct3d12 / hidapi-android 路径上，
#     三处 `enable_language(CXX)` 分别在 `WINDOWS OR CYGWIN` / `HAIKU` / `NGAGE` 分支内。
#     ⇒ **不必套 build_shaderc_ohos.sh 那套 OHOS libc++ `__n1` ABI 机制**，
#     也就没有 `__1` iostream 符号污染的风险（产物仍会扫一遍确认）。
#
#  2. **`OHOS` 变量必须我们自己设**。`cmake/sdlplatform.cmake` 的
#     `SDL_DetectCMakePlatform()` 有 Android/Emscripten/QNX… 却**没有 OHOS 分支**，
#     `OHOS` 一向由华为 NDK 的 `ohos.toolchain.cmake` 提供。我们用自己的极简
#     toolchain file，所以在里面 `set(OHOS TRUE)`。
#     `CMAKE_SYSTEM_NAME` 保持 `Linux`（CMake 需要认识的平台名），这会让
#     `LINUX` 也为真，但 CMakeLists.txt 的平台链是
#     `if(ANDROID) / elseif(OHOS) / elseif(EMSCRIPTEN) / elseif(UNIX AND NOT …)`,
#     `elseif(OHOS)` 在 UNIX 分支**之前**，所以 OHOS 分支稳定命中。
#     （上游改进项：给 sdlplatform.cmake 补 OHOS 检测，见 WORKLOG 的 D12。）
#
#  3. **`CMAKE_PLATFORM_NO_VERSIONED_SONAME=1` 必须开**。默认 CMake 会产出
#     `libSDL3.so.0.x.y` + 符号链接，而 AMCL 是把 .so 平铺进 entry/libs/arm64-v8a/、
#     由 HarmonyOS 的 linker namespace 按**确切文件名**加载，且我们给 MC 传的是
#     `-Dorg.lwjgl.sdl.libname=libSDL3.so`。⇒ 需要 SONAME 就是 `libSDL3.so`。
# ============================================================

WORK_DIR=/build
SRC_DIR=${SRC_DIR:-$WORK_DIR/sdl3-ohos-src}
SDL3_REPO=${SDL3_REPO:-https://github.com/icculus/SDL.git}
SDL3_BRANCH=${SDL3_BRANCH:-sdl3-harmonyos}
# pin：与 deps.lock [sdl3-native] 的 commit 一致。基底 upstream/main = de51952c2。
SDL3_COMMIT=${SDL3_COMMIT:-e293db30d74cca888eafba4e27f0c894f128e67d}
# 版本串必须显式传给 CMake，不能靠 CMakeLists.txt 的 git_describe()：
# 我们是按 commit 做的浅/detached checkout，git_describe() 在这种树上失效，
# 版本串会退化成 `SDL-3.5.0--128-NOTFOUND`，而 CI 的 [sdl3-native].version_string
# 校验要求它内嵌 commit 短哈希 ⇒ 会直接判失败。取值必须与 deps.lock 一致。
SDL3_REVISION=${SDL3_REVISION:-SDL-3.5.0-release-3.4.0-983-ge293db30d}
OHOS_SYSROOT=${OHOS_SYSROOT_RW:-/ohos-sysroot-rw}
OUTPUT_DIR=${OUTPUT_DIR:-/output/sdl3}
JOBS=${JOBS:-$(nproc)}
PATCH_DIR=${PATCH_DIR:-/prebuilt/sdl3/patches}
BUILD_TYPE=${BUILD_TYPE:-RelWithDebInfo}

OHOS_LIBDIR=$OHOS_SYSROOT/usr/lib/aarch64-linux-ohos

[ -d "$OHOS_SYSROOT/usr/include" ] || { echo "ERROR: sysroot $OHOS_SYSROOT not ready (run setup_toolchain.sh)"; exit 1; }
[ -d "$OHOS_LIBDIR" ] || { echo "ERROR: libdir $OHOS_LIBDIR missing"; exit 1; }

echo "============================================"
echo " SDL3 for HarmonyOS NEXT (aarch64)"
echo " repo   : $SDL3_REPO  branch=$SDL3_BRANCH"
echo " commit : $SDL3_COMMIT"
echo " sysroot: $OHOS_SYSROOT"
echo " jobs   : $JOBS   build type: $BUILD_TYPE"
echo "============================================"

# ---------- 源码（pin commit，可离线复用） ----------
if [ ! -d "$SRC_DIR/.git" ]; then
    echo "[src] cloning $SDL3_REPO ($SDL3_BRANCH)..."
    git clone --branch "$SDL3_BRANCH" "$SDL3_REPO" "$SRC_DIR"
fi
cd "$SRC_DIR"
# 当前任务必须使用干净源码，未知改动留给归档，不用 checkout . 擦除。
[[ "$SDL3_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo 'ERROR: SDL3_COMMIT must be a full SHA'; exit 1; }
[ -z "$(git status --porcelain --untracked-files=all)" ] || { echo 'ERROR: SDL source is dirty; use a fresh task'; exit 1; }
git cat-file -e "$SDL3_COMMIT^{commit}"
git checkout --detach -q "$SDL3_COMMIT"
echo "[src] HEAD = $(git rev-parse --short HEAD)  ($(git log -1 --format=%s))"

# ---------- AMCL 宿主集成补丁（只放"通用能力之外"的那几个） ----------
# 通用能力一律在开发仓里改并回推上游；这里只应用与 AMCL 宿主耦合的部分。
if [ -d "$PATCH_DIR" ] && [ -f "$PATCH_DIR/series" ]; then
    echo "[patch] applying AMCL host patches from $PATCH_DIR/series"
    while IFS= read -r p || [ -n "$p" ]; do
        p="${p%$'\r'}"
        [ -z "$p" ] && continue
        case "$p" in \#*) continue ;; esac
        echo "  apply $p"
        git apply "$PATCH_DIR/$p"
    done < "$PATCH_DIR/series"
else
    echo "ERROR: AMCL patch series is required at $PATCH_DIR"
    exit 1
fi

# ---------- 编译器包装器 ----------
# 把 --target/--sysroot/-L 固化进去，CMake 的编译器探测才不会因缺 sysroot 而误判。
# -Wno-unused-command-line-argument：包装器把 -L / -fuse-ld 也传给了纯编译（-c）阶段，
# clang 会为每个 .o 各报一次（实测 50 条噪声）。CMakeLists 的 OHOS 分支虽然有同名
# sdl_compile_options，但排在包装器注入的参数之后，压不住。
cat > /tmp/ohos-cc-sdl3 <<CCEOF
#!/bin/bash
exec /usr/bin/ohos-clang --target=aarch64-linux-ohos --sysroot=$OHOS_SYSROOT \\
    -D__OHOS__ -DOHOS -Wno-unused-command-line-argument \\
    -L$OHOS_LIBDIR -fuse-ld=lld "\$@"
CCEOF
chmod +x /tmp/ohos-cc-sdl3

# ---------- toolchain file ----------
# CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY：交叉编译时不要求能链出可执行文件，
# 否则 CMake 的 check_c_source_compiles 全军覆没（gl4es/shaderc 脚本同一处理）。
cat > /tmp/ohos-sdl3-toolchain.cmake <<TCEOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

# SDL 的 sdlplatform.cmake 没有 OHOS 检测（OHOS 一向由华为 NDK 的 toolchain 提供），
# 这里显式声明。CMakeLists.txt 的平台链里 elseif(OHOS) 在 UNIX 分支之前，稳定命中。
set(OHOS TRUE)
set(OHOS_ARCH "arm64-v8a")

set(CMAKE_C_COMPILER /tmp/ohos-cc-sdl3)
set(CMAKE_C_COMPILER_WORKS 1)
set(CMAKE_SYSROOT $OHOS_SYSROOT)
set(CMAKE_FIND_ROOT_PATH $OHOS_SYSROOT)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# 产出 libSDL3.so 而不是 libSDL3.so.0.x.y + 符号链接（见文件头第 3 点）
set(CMAKE_PLATFORM_NO_VERSIONED_SONAME 1)
TCEOF

BUILD=$SRC_DIR/ohos-build
rm -rf "$BUILD"; mkdir -p "$BUILD"; cd "$BUILD"

# ---------- CMake 配置 ----------
# 「完整子系统」的含义（Phase 0.9 定）：**凡是有 OHOS 后端的一律打开**；
# 没有 OHOS 后端的（audio/joystick/haptic/camera）不要关掉子系统本身 ——
# CMakeLists.txt 的 `if(NOT HAVE_SDL_AUDIO)` 等会回落到 dummy 后端，
# 这样公开 API 与符号仍然完整存在、调用时优雅失败。
# 这一点对 LWJGL 很关键：org.lwjgl.sdl.SDL* 每个类的 <clinit> 用
# apiGetFunctionAddress 解析符号，**符号缺失会直接抛异常**，
# 所以宁可要 dummy 后端也不能让符号消失。
echo ""
echo "[1/4] CMake configure..."
cmake .. \
    -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE=/tmp/ohos-sdl3-toolchain.cmake \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DCMAKE_PLATFORM_NO_VERSIONED_SONAME=1 \
    -DSDL_REVISION="$SDL3_REVISION" \
    -DSDL_SHARED=ON \
    -DSDL_STATIC=OFF \
    -DSDL_TESTS=OFF \
    -DSDL_TEST_LIBRARY=OFF \
    -DSDL_EXAMPLES=OFF \
    -DSDL_INSTALL_TESTS=OFF \
    -DSDL_DISABLE_INSTALL_DOCS=ON \
    -DSDL_VIDEO=ON \
    -DSDL_OPENGLES=ON \
    -DSDL_VULKAN=ON \
    -DSDL_RENDER=ON \
    -DSDL_AUDIO=ON \
    -DSDL_JOYSTICK=ON \
    -DSDL_HAPTIC=ON \
    -DSDL_SENSOR=ON \
    -DSDL_POWER=ON \
    -DSDL_DIALOG=ON \
    -DSDL_CAMERA=ON \
    -DSDL_HIDAPI=ON \
    -DSDL_OPENGL=OFF \
    -DSDL_WAYLAND=OFF \
    -DSDL_X11=OFF \
    -DSDL_KMSDRM=OFF \
    -DSDL_RPATH=OFF \
    -DSDL_WERROR=OFF \
    -DSDL_CCACHE=OFF

echo ""
echo "[2/4] Configure summary (关键驱动是否选中 OHOS)..."
# 生成路径带 build type 后缀（例：include-config-relwithdebinfo/build_config/SDL_build_config.h），
# 所以用 find 而不是写死路径。
GENCFG=$(find . -name SDL_build_config.h -path '*build_config*' 2>/dev/null | head -1)
if [ -n "$GENCFG" ]; then
    echo "    (from $GENCFG)"
    grep -E '^#define SDL_(VIDEO_DRIVER|AUDIO_DRIVER|CAMERA_DRIVER|SENSOR|POWER|FILESYSTEM|JOYSTICK|HAPTIC|VIDEO_OPENGL|VIDEO_VULKAN|VIDEO_RENDER|LOADSO|THREAD|TIME|TIMER)[A-Z0-9_]* 1' \
        "$GENCFG" | sed 's/^/    /' || true
    # 硬闸门：OHOS 后端必须真的被选中，否则等于编了个 dummy 库
    for must in SDL_VIDEO_DRIVER_OHOS SDL_SENSOR_OHOS SDL_POWER_OHOS SDL_FILESYSTEM_OHOS \
                SDL_VIDEO_OPENGL_EGL SDL_VIDEO_OPENGL_ES2 SDL_VIDEO_VULKAN; do
        grep -q "^#define ${must} 1" "$GENCFG" || { echo "  ERROR: ${must} 未被选中 —— OHOS 分支没命中？"; exit 1; }
    done
    echo "    ✅ 7 个 OHOS 关键开关全部选中"
else
    echo "  ERROR: SDL_build_config.h 未生成，configure 失败"; exit 1
fi

echo ""
echo "[3/4] Building SDL3-shared..."
cmake --build . --target SDL3-shared -j"$JOBS"

# ---------- 收产物 ----------
echo ""
echo "[4/4] Collecting artifact..."
BUILT=$(find "$BUILD" -name 'libSDL3.so*' -type f 2>/dev/null | head -1)
[ -n "$BUILT" ] || { echo "ERROR: libSDL3.so not produced"; exit 1; }

# OHOS 后端符号必须在 strip **之前**查：`--strip-unneeded` 会去掉本地符号表，
# 而 OHOS_CreateDevice 是 static（nm 里是小写 t），strip 后 nm 一个都看不到，
# 第一版脚本因此报出误导性的「含 ohos 的符号数: 0」。
echo "  built from : $BUILT ($(stat -c%s "$BUILT") bytes, unstripped)"
OHOS_SYMS=$(/usr/bin/ohos-nm "$BUILT" 2>/dev/null | grep -ci ohos || true)
echo "  OHOS 后端符号数（strip 前）= $OHOS_SYMS"
if [ "$OHOS_SYMS" -lt 20 ]; then
    echo "  ERROR: OHOS 后端符号过少，后端可能没编进去"; exit 1
fi
/usr/bin/ohos-nm "$BUILT" 2>/dev/null | grep -E ' [tT] OHOS_(CreateDevice|CreateWindow|GLES_CreateContext|OnKeyDown)$' | sed 's/^/    /' || true

mkdir -p "$OUTPUT_DIR"
cp "$BUILT" "$OUTPUT_DIR/libSDL3.so"
UNSTRIPPED_SIZE=$(stat -c%s "$OUTPUT_DIR/libSDL3.so")
/usr/bin/ohos-strip --strip-unneeded "$OUTPUT_DIR/libSDL3.so" 2>/dev/null || true
echo "  -> $OUTPUT_DIR/libSDL3.so  ($UNSTRIPPED_SIZE -> $(stat -c%s "$OUTPUT_DIR/libSDL3.so") bytes after strip)"

# ---------- 产物自检 ----------
# 这里只做"看一眼就能发现问题"的快检；符号面 100% 覆盖的硬闸门由
# scripts/check-sdl3-surface.mjs 负责（Task#9）。
SO="$OUTPUT_DIR/libSDL3.so"
echo ""
echo "=== arch / class ==="
/usr/bin/ohos-readelf -h "$SO" | grep -E 'Class|Machine' | sed 's/^/  /'

echo "=== SONAME（必须是 libSDL3.so，不带版本后缀） ==="
/usr/bin/ohos-readelf -d "$SO" | grep SONAME | tr -s ' ' | sed 's/^/  /' || echo "  (无 SONAME — 需检查 NO_VERSIONED_SONAME)"

echo "=== NEEDED ==="
/usr/bin/ohos-readelf -d "$SO" | grep NEEDED | tr -s ' ' | sed 's/^/  /'

echo "=== SDL 版本串 ==="
strings "$SO" | grep -E '^SDL-[0-9]+\.[0-9]+\.[0-9]+' | head -3 | sed 's/^/  /' || echo "  (未找到版本串)"

echo "=== MC 必用符号抽查（完整清单交给 check-sdl3-surface.mjs） ==="
MISSING=0
for s in SDL_Init SDL_Quit SDL_CreateWindow SDL_DestroyWindow SDL_ShowWindow \
         SDL_GL_CreateContext SDL_GL_LoadLibrary SDL_GL_GetProcAddress SDL_GL_MakeCurrent \
         SDL_GL_SwapWindow SDL_GL_SetAttribute SDL_PollEvent SDL_PumpEvents \
         SDL_GetKeyboardState SDL_GetModState SDL_StartTextInput SDL_SetTextInputArea \
         SDL_SetWindowRelativeMouseMode SDL_WarpMouseInWindow SDL_CreateSystemCursor \
         SDL_GetWindowPixelDensity SDL_GetWindowSizeInPixels SDL_SetWindowFullscreen \
         SDL_GetCurrentDisplayMode SDL_GetFullscreenDisplayModes SDL_SetWindowIcon \
         SDL_CreateSurfaceFrom SDL_GetPixelFormatDetails SDL_GetClipboardText \
         SDL_Vulkan_CreateSurface SDL_Vulkan_LoadLibrary \
         SDL_SetHint SDL_SetLogOutputFunction SDL_SetAppMetadataProperty \
         SDL_GetPlatform SDL_GetTicksNS SDL_GetError SDL_free; do
    if ! /usr/bin/ohos-nm -D --defined-only "$SO" 2>/dev/null | grep -qE " ${s}\$"; then
        echo "  MISS $s"; MISSING=$((MISSING+1))
    fi
done
[ "$MISSING" -eq 0 ] && echo "  抽查的 38 个符号全部导出"

# OHOS 后端的存在性已在 strip 前用 nm 验过（见上）。strip 后只能靠字符串证据：
# VideoBootStrap 里的驱动名和描述会留在 .rodata。
echo "=== OHOS video driver 注册名（strip 后仍可见的证据） ==="
strings "$SO" | grep -x -E 'ohos|OpenHarmony video driver' | sed 's/^/  /' \
  || { echo "  ERROR: 产物里找不到 ohos 驱动注册名"; exit 1; }

# libGLESv2 出现在 NEEDED 是 CMakeLists 的 OHOS 分支无条件
# `sdl_link_dependency(opengles LIBS GLESv2)` 造成的。这里核实它是否真被引用 ——
# 若 gl* 未定义符号为 0，说明所有 GL 入口都走 SDL_EGL_GetProcAddress 动态解析，
# 那个 NEEDED 是多余的。这一点对 C2（MC 硬校验 glGetError 地址同源）很关键：
# 多余的 NEEDED 会让 loader 把系统 libGLESv2 的 gl* 拉进进程符号空间。
echo "=== gl* 未定义符号（应为 0：GL 全走动态解析） ==="
GLU=$(/usr/bin/ohos-nm -D --undefined-only "$SO" 2>/dev/null | grep -cE ' gl[A-Z]' || true)
echo "  gl* 未定义符号数 = $GLU"
if [ "$GLU" -eq 0 ]; then
    echo "  ⇒ 未静态绑定系统 GLESv2 的 gl*；NEEDED 里的 libGLESv2.so 是多余依赖"
    echo "    （上游可改进项；C2 验证时需确认它不会污染 MobileGlues 的 gl* 解析）"
fi

echo "=== libc++ ABI 纯净检查（SDL3 是纯 C，应为 0） ==="
N1=$(/usr/bin/ohos-nm -D "$SO" 2>/dev/null | grep -c '__1' || true)
echo "  含 __1 (libc++ __ndk1/__1 命名空间) 的符号数 = $N1"
if [ "$N1" -ne 0 ]; then
    echo "  ⚠️ 不该出现 —— SDL3 是 project(... LANGUAGES C)，出现说明误链了 libc++"
fi
if /usr/bin/ohos-readelf -d "$SO" | grep -q 'libc++'; then
    echo "  ⚠️ NEEDED 里出现 libc++，与纯 C 预期不符"
else
    echo "  NEEDED 中无 libc++  ✅"
fi

echo ""
if [ "$MISSING" -ne 0 ]; then
    echo "RESULT: FAIL —— $MISSING 个抽查符号缺失"
    exit 1
fi
echo "RESULT: OK —— $OUTPUT_DIR/libSDL3.so"
echo "下一步：scripts/check-sdl3-surface.mjs 做符号面 100% 覆盖硬闸门；"
echo "        然后 docker cp 到 entry/libs/arm64-v8a/ 并填 deps.lock [sdl3-native]。"
