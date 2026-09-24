#!/bin/bash
# pack_jdk_release.sh — 打包 JDK 编译产物用于 GitHub Releases
#
# 用法 (在 ohos-debug 容器内):
#   bash /build/scripts/pack_jdk_release.sh [VERSION] [TAG]
#   例如: bash /build/scripts/pack_jdk_release.sh 17 v17.0.13-ohos-1
#
# 输出:
#   /output/release/
#     ├── jdk<VERSION>-ohos-data.zip      ← JDK 数据文件（lib/modules, conf 等）
#     ├── jdk<VERSION>-ohos-libs.zip      ← .so 文件（libjvm.so 等）
#     └── manifest.json                   ← 文件清单（sha256, size）
#
# 上传到 GitHub:
#   gh release create <TAG> /output/release/* --repo LZZLHY/mc-ohos-resources
set -e

VERSION=${1:-17}
TAG=${2:-v${VERSION}.0.13-ohos-1}
LIBS_DIR=/output/jdk-libs
DATA_ZIP=/output/jdk-data.zip
RELEASE_DIR=/output/release

echo "=== Packing JDK ${VERSION} for GitHub Release ==="
echo "  Tag:     ${TAG}"
echo "  Libs:    ${LIBS_DIR}"
echo "  Data:    ${DATA_ZIP}"
echo "  Output:  ${RELEASE_DIR}"
echo ""

# 检查源文件
if [ ! -d "$LIBS_DIR" ]; then
    echo "ERROR: $LIBS_DIR not found. Run build first."
    exit 1
fi

mkdir -p "$RELEASE_DIR"

# 1. 打包 .so 文件
echo "[1/3] Packing libs..."
LIBS_ZIP="${RELEASE_DIR}/jdk${VERSION}-ohos-libs.zip"
cd "$LIBS_DIR"
zip -9 "$LIBS_ZIP" *.so
echo "  $(ls *.so | wc -l) .so files → $(du -h $LIBS_ZIP | cut -f1)"

# 2. 复制/创建 data.zip
echo "[2/3] Packing data..."
DATA_RELEASE="${RELEASE_DIR}/jdk${VERSION}-ohos-data.zip"
if [ -f "$DATA_ZIP" ]; then
    cp "$DATA_ZIP" "$DATA_RELEASE"
    echo "  data.zip: $(du -h $DATA_RELEASE | cut -f1)"
else
    echo "  WARNING: $DATA_ZIP not found, skipping data pack"
fi

# 3. 生成 manifest.json
echo "[3/3] Generating manifest.json..."
MANIFEST="${RELEASE_DIR}/manifest.json"

cat > "$MANIFEST" << HEADER
{
  "version": "${VERSION}",
  "tag": "${TAG}",
  "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "files": {
HEADER

# libs.zip
if [ -f "$LIBS_ZIP" ]; then
    LIBS_SHA=$(sha256sum "$LIBS_ZIP" | cut -d' ' -f1)
    LIBS_SIZE=$(stat -c%s "$LIBS_ZIP")
    echo "    \"jdk${VERSION}-ohos-libs.zip\": {" >> "$MANIFEST"
    echo "      \"sha256\": \"${LIBS_SHA}\"," >> "$MANIFEST"
    echo "      \"size\": ${LIBS_SIZE}" >> "$MANIFEST"
    echo "    }," >> "$MANIFEST"
fi

# data.zip
if [ -f "$DATA_RELEASE" ]; then
    DATA_SHA=$(sha256sum "$DATA_RELEASE" | cut -d' ' -f1)
    DATA_SIZE=$(stat -c%s "$DATA_RELEASE")
    echo "    \"jdk${VERSION}-ohos-data.zip\": {" >> "$MANIFEST"
    echo "      \"sha256\": \"${DATA_SHA}\"," >> "$MANIFEST"
    echo "      \"size\": ${DATA_SIZE}" >> "$MANIFEST"
    echo "    }," >> "$MANIFEST"
fi

# 每个 .so 文件的 sha256（用于增量更新）
echo "    \"libs\": {" >> "$MANIFEST"
FIRST=1
cd "$LIBS_DIR"
for so in *.so; do
    SHA=$(sha256sum "$so" | cut -d' ' -f1)
    SIZE=$(stat -c%s "$so")
    if [ $FIRST -eq 0 ]; then echo "," >> "$MANIFEST"; fi
    printf "      \"%s\": { \"sha256\": \"%s\", \"size\": %d }" "$so" "$SHA" "$SIZE" >> "$MANIFEST"
    FIRST=0
done
echo "" >> "$MANIFEST"
echo "    }" >> "$MANIFEST"

echo "  }" >> "$MANIFEST"
echo "}" >> "$MANIFEST"

echo ""
echo "=== Release files ready ==="
ls -lh "$RELEASE_DIR/"
echo ""
echo "Upload with:"
echo "  gh release create ${TAG} ${RELEASE_DIR}/* --repo LZZLHY/mc-ohos-resources --title 'JDK ${VERSION} for OHOS'"
