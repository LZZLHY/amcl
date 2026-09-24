#!/bin/bash
set -e

# ============================================================
#  copy_jdk_to_project.sh — 从 Docker output 复制 JDK 文件到项目
#
#  在 Windows 上用 Git Bash 或 WSL 运行:
#    bash docker/copy_jdk_to_project.sh
#
#  或者手动复制:
#    1. docker/output/jdk-libs/*.so → entry/libs/arm64-v8a/
#    2. docker/output/jdk-data.zip → entry/src/main/resources/rawfile/
#    3. 删除 entry/src/main/resources/rawfile/jdk-full.zip
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

LIBS_SRC="$SCRIPT_DIR/output/jdk-libs"
DATA_SRC="$SCRIPT_DIR/output/jdk-data.zip"
LIBS_DST="$PROJECT_DIR/entry/libs/arm64-v8a"
RAWFILE_DST="$PROJECT_DIR/entry/src/main/resources/rawfile"

echo "=== Copy JDK files to project ==="

# 检查源文件
if [ ! -d "$LIBS_SRC" ]; then
    echo "ERROR: $LIBS_SRC not found. Run pack_jdk_split.sh in Docker first."
    exit 1
fi
if [ ! -f "$DATA_SRC" ]; then
    echo "ERROR: $DATA_SRC not found. Run pack_jdk_split.sh in Docker first."
    exit 1
fi

# 1. 复制 .so 文件
echo ""
echo "[1/3] Copying .so files to $LIBS_DST/"
mkdir -p "$LIBS_DST"
cp "$LIBS_SRC"/*.so "$LIBS_DST/"
echo "  Copied $(ls "$LIBS_DST"/*.so | wc -l) .so files"
ls -lh "$LIBS_DST/"

# 2. 复制 jdk-data.zip
echo ""
echo "[2/3] Copying jdk-data.zip to $RAWFILE_DST/"
mkdir -p "$RAWFILE_DST"
cp "$DATA_SRC" "$RAWFILE_DST/jdk-data.zip"
ls -lh "$RAWFILE_DST/jdk-data.zip"

# 3. 删除旧的 jdk-full.zip
echo ""
echo "[3/3] Removing old jdk-full.zip..."
if [ -f "$RAWFILE_DST/jdk-full.zip" ]; then
    rm "$RAWFILE_DST/jdk-full.zip"
    echo "  Removed jdk-full.zip"
else
    echo "  jdk-full.zip not found (already removed)"
fi

echo ""
echo "=== Done ==="
echo "Now build the project with hvigorw"
