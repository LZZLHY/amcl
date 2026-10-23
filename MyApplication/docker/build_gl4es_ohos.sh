#!/bin/bash
# 锁定 gl4es 的完整 OHOS 构建。固定 amcl/builder 调用，源码/编译树在登记工作卷，制品与符号外置。
# 输入校验失败保留现场；不 reset、不删除旧源码、不以 strip/readelf 的失败继续交付。
set -euo pipefail
[[ "${AMCL_BUILDER_MANAGED:-}" == 1 ]] || { echo 'ERROR: use docker/launch-builder.ps1'; exit 1; }
WORK_DIR=/build
SRC_DIR=${SRC_DIR:-$WORK_DIR/gl4es-ohos-src}
BUILD_DIR=${BUILD_DIR:-$WORK_DIR/gl4es-build}
OUTPUT_DIR=${OUTPUT_DIR:-/output/gl4es}
PATCH_DIR=${PATCH_DIR:-/prebuilt/gl4es/patches}
OHOS_SYSROOT=${GL4ES_SYSROOT:-/ohos-sysroot-rw}
JOBS=${JOBS:-8}
INPUTS=/prebuilt/gl4es/build-inputs.json
STARTED=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
GL4ES_REPO=$(python3 -c 'import json; print(json.load(open("/prebuilt/gl4es/build-inputs.json"))["repository"])')
GL4ES_COMMIT=$(python3 -c 'import json; print(json.load(open("/prebuilt/gl4es/build-inputs.json"))["commit"])')
[[ "$GL4ES_COMMIT" =~ ^[0-9a-f]{40}$ ]] || exit 1
[[ -f "$OHOS_SYSROOT/usr/include/stdio.h" && -f "$PATCH_DIR/series" ]] || exit 1
mkdir -p "$OUTPUT_DIR" "$BUILD_DIR"
cp "$INPUTS" "$OUTPUT_DIR/build-inputs.json"
sha256sum "$INPUTS" /recipes/build_gl4es_ohos.sh > "$OUTPUT_DIR/recipe-inputs.sha256"

# 干净源码才允许转到精确 pin；带同一补丁集的复用副本随后逐文件比对，未知修改始终拒绝。
if [[ ! -d "$SRC_DIR/.git" ]]; then
    [[ ! -e "$SRC_DIR" ]] || { echo 'ERROR: unmanaged source directory; preserved'; exit 1; }
    git clone "$GL4ES_REPO" "$SRC_DIR"
fi
if [[ "$(git -C "$SRC_DIR" rev-parse HEAD)" != "$GL4ES_COMMIT" ]]; then
    [[ -z "$(git -C "$SRC_DIR" status --porcelain --untracked-files=all)" ]] || { echo 'ERROR: unknown dirty source; preserved'; exit 1; }
    git -C "$SRC_DIR" checkout --detach "$GL4ES_COMMIT"
fi
python3 -B /recipes/verify_gl4es_source.py --source "$SRC_DIR" --patch-dir "$PATCH_DIR" --output "$OUTPUT_DIR" --pin "$GL4ES_COMMIT"

# 包装器与 CMake 描述属于工作卷中的构建资料，显式使用 compiler/sysroot 和动态 BuildID。
OHOS_LIBDIR=$OHOS_SYSROOT/usr/lib/aarch64-linux-ohos
cat > "$BUILD_DIR/ohos-cc" <<CCEOF
#!/bin/bash
exec /usr/bin/ohos-clang --target=aarch64-linux-ohos --sysroot=$OHOS_SYSROOT -D__OHOS__ -DNOX11 -DNOEGL -DNO_GBM -L$OHOS_LIBDIR -fuse-ld=lld "\$@"
CCEOF
chmod +x "$BUILD_DIR/ohos-cc"
cat > "$BUILD_DIR/toolchain.cmake" <<TCEOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER $BUILD_DIR/ohos-cc)
set(CMAKE_C_COMPILER_WORKS 1)
set(CMAKE_FIND_ROOT_PATH $OHOS_SYSROOT)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
TCEOF
cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
    -DCMAKE_TOOLCHAIN_FILE="$BUILD_DIR/toolchain.cmake" \
    -DCMAKE_LIBRARY_OUTPUT_DIRECTORY="$BUILD_DIR/lib" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DNOX11=ON -DNOEGL=ON -DNO_GBM=ON -DNO_INIT_CONSTRUCTOR=ON \
    -DCMAKE_C_FLAGS='-O3 -fPIC -fvisibility=hidden -DNOX11 -DNOEGL -DNO_GBM -D__OHOS__' \
    -DCMAKE_SHARED_LINKER_FLAGS='-Wl,--build-id=sha1'
cmake --build "$BUILD_DIR" --target GL -j"$JOBS"

# 唯一正常 CMake 产物，不能误取旧 lib 目录或任意 find/head 命中的历史 SO。
BUILT="$BUILD_DIR/lib/libGL.so.1"
[[ -s "$BUILT" ]] || { echo 'ERROR: target GL output missing'; exit 1; }
cp "$BUILT" "$OUTPUT_DIR/libgl4es.unstripped.so"
ohos-objcopy --only-keep-debug "$BUILT" "$OUTPUT_DIR/libgl4es.so.debug"
cp "$BUILT" "$OUTPUT_DIR/libgl4es.so"
ohos-strip --strip-unneeded "$OUTPUT_DIR/libgl4es.so"
python3 -B /recipes/verify_gl4es_artifact.py --directory "$OUTPUT_DIR" --started "$STARTED"
printf 'gl4es complete: %s\n' "$OUTPUT_DIR/libgl4es.so"
