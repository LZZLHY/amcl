#!/bin/bash
set -e
# ============================================================
#  Holy GL4ES (gl4es fork) cross-compile for HarmonyOS NEXT (aarch64/musl)
#
#  老 MC（1.7–1.16.5）固定管线 GL → GLES 翻译器。补 MobileGlues（只覆盖 1.17+）的空缺。
#  上游 pin: deps.lock [gl4es] = PojavLauncherTeam/gl4es-114-extra @ 144d0dc...
#  详见 prebuilt/gl4es/README.md、docs/adaptation/OLD_MC_RENDERER_PLAN.md。
#
#  用法（容器内）：docker exec ohos-debug bash /build/build_gl4es_ohos.sh
#  产物：/output/gl4es/libgl4es.so（→ docker cp 到 entry/libs/arm64-v8a/）
# ============================================================

WORK_DIR=/build
SRC_DIR=${SRC_DIR:-$WORK_DIR/gl4es-ohos-src}
GL4ES_REPO=${GL4ES_REPO:-https://github.com/PojavLauncherTeam/gl4es-114-extra.git}
GL4ES_COMMIT=${GL4ES_COMMIT:-144d0dc79855b392e5256dd15fb2dbdedb17141a}
OHOS_SYSROOT=${OHOS_SYSROOT:-/ohos-sysroot-rw}
OUTPUT_DIR=${OUTPUT_DIR:-/output/gl4es}
JOBS=${JOBS:-$(nproc)}
PATCH_DIR=${PATCH_DIR:-/build/gl4es-patches}

OHOS_LIBDIR=$OHOS_SYSROOT/usr/lib/aarch64-linux-ohos

[ -d "$OHOS_SYSROOT/usr/include" ] || { echo "ERROR: sysroot $OHOS_SYSROOT not ready"; exit 1; }

echo "============================================"
echo " Holy GL4ES for HarmonyOS NEXT (aarch64)"
echo " Sysroot: $OHOS_SYSROOT  commit: $GL4ES_COMMIT"
echo "============================================"

# 源码（pin commit）
if [ ! -d "$SRC_DIR/.git" ]; then
    git clone "$GL4ES_REPO" "$SRC_DIR"
fi
cd "$SRC_DIR"
git checkout -q "$GL4ES_COMMIT" 2>/dev/null || true

# 应用 OHOS 补丁（若有）
if [ -d "$PATCH_DIR" ] && [ -f "$PATCH_DIR/series" ]; then
    echo "[patch] applying OHOS patches from $PATCH_DIR/series"
    git checkout -q . 2>/dev/null || true
    while IFS= read -r p || [ -n "$p" ]; do
        p="${p%$'\r'}"
        [ -z "$p" ] && continue
        case "$p" in \#*) continue ;; esac
        echo "  apply $p"
        git apply "$PATCH_DIR/$p"
    done < "$PATCH_DIR/series"
fi

# ohos-clang 包装器（嵌 --target/--sysroot；GLES/EGL 在 sysroot 内）
cat > /tmp/ohos-cc-gl4es <<CCEOF
#!/bin/bash
exec /usr/bin/ohos-clang --target=aarch64-linux-ohos --sysroot=$OHOS_SYSROOT -D__OHOS__ -DNOX11 -DNOEGL -DNO_GBM -L$OHOS_LIBDIR -fuse-ld=lld "\$@"
CCEOF
chmod +x /tmp/ohos-cc-gl4es

cat > /tmp/ohos-gl4es-toolchain.cmake <<TCEOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER /tmp/ohos-cc-gl4es)
set(CMAKE_C_COMPILER_WORKS 1)
set(CMAKE_FIND_ROOT_PATH $OHOS_SYSROOT)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
TCEOF

BUILD=$SRC_DIR/ohos-build
rm -rf "$BUILD"; mkdir -p "$BUILD"; cd "$BUILD"

echo ""
echo "[1/2] CMake configure (NOEGL/NOX11 = host-owned context, aarch64)..."
cmake .. \
    -DCMAKE_TOOLCHAIN_FILE=/tmp/ohos-gl4es-toolchain.cmake \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DNOX11=ON -DNOEGL=ON -DNO_GBM=ON -DNO_INIT_CONSTRUCTOR=ON \
    -DCMAKE_C_FLAGS="-O3 -fPIC -fvisibility=hidden -DNOX11 -DNOEGL -DNO_GBM -D__OHOS__" \
    >/dev/null

echo ""
echo "[2/2] Building target GL (libGL.so.1)..."
cmake --build . --target GL -j"$JOBS"

echo ""
echo "=== locate built lib ==="
BUILT=$(find "$SRC_DIR/lib" "$BUILD" -name 'libGL.so*' -type f 2>/dev/null | head -1)
[ -n "$BUILT" ] || { echo "ERROR: libGL.so not produced"; exit 1; }
mkdir -p "$OUTPUT_DIR"
cp "$BUILT" "$OUTPUT_DIR/libgl4es.so"
/usr/bin/ohos-strip --strip-unneeded "$OUTPUT_DIR/libgl4es.so" 2>/dev/null || true
echo "  -> $OUTPUT_DIR/libgl4es.so ($(stat -c%s "$OUTPUT_DIR/libgl4es.so") bytes)"
echo "--- arch + key fixed-function symbols ---"
ohos-readelf -h "$OUTPUT_DIR/libgl4es.so" 2>/dev/null | grep -E 'Machine|Class' || true
ohos-readelf -sW "$OUTPUT_DIR/libgl4es.so" 2>/dev/null | grep -E ' glAlphaFunc| glBegin| glMatrixMode| glEnableClientState' | head || echo "  (no fixed-function symbols found — check visibility/export)"
echo "--- NEEDED ---"
ohos-readelf -d "$OUTPUT_DIR/libgl4es.so" 2>/dev/null | grep NEEDED | tr -s ' ' | paste -sd' '
echo "Done."
