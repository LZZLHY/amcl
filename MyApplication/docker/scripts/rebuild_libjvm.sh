#!/bin/bash
set -e

echo "=== Incremental Rebuild: libjvm.so (with safepoint patch) ==="

export PATH=/ohos-toolchain:$PATH
WORK_DIR=/build
JDK_SRC=$WORK_DIR/jdk17u

if [ ! -d "$JDK_SRC" ]; then
    echo "ERROR: JDK source not found at $JDK_SRC"
    echo "Run full build first: build_jdk17_ohos.sh"
    exit 1
fi

cd $JDK_SRC

# Step 1: 应用 safepoint patch
echo ""
echo "[1/3] Applying safepoint polling page patch..."
python3 /build/patch_safepoint.py $JDK_SRC

# Step 2: 增量编译 hotspot (只重编 libjvm.so)
echo ""
echo "[2/3] Rebuilding hotspot (libjvm.so)..."
gmake hotspot JOBS=${JOBS:-$(nproc)} 2>&1 | tail -20

# 找到编译输出
LIBJVM=$(find build -name "libjvm.so" -path "*/server/*" 2>/dev/null | head -1)
if [ -z "$LIBJVM" ]; then
    LIBJVM=$(find build -name "libjvm.so" 2>/dev/null | head -1)
fi

if [ -z "$LIBJVM" ]; then
    echo "ERROR: libjvm.so not found in build output"
    exit 1
fi

echo "  Built: $LIBJVM"
echo "  Size: $(du -h $LIBJVM | cut -f1)"

# Step 3: 复制到输出
echo ""
echo "[3/3] Copying to output..."
cp $LIBJVM /output/jdk-libs/libjvm.so
echo "  Copied to /output/jdk-libs/libjvm.so"

# 验证
echo ""
echo "=== Verification ==="
file /output/jdk-libs/libjvm.so
echo ""
echo "NEEDED libraries:"
readelf -d /output/jdk-libs/libjvm.so | grep NEEDED | head -10
echo ""
echo "Checking for polling page symbols:"
llvm-nm-15 -D /output/jdk-libs/libjvm.so 2>/dev/null | grep -i "polling_page" || echo "  (no polling_page exports — expected)"
echo ""
echo "=== libjvm.so rebuild complete ==="
