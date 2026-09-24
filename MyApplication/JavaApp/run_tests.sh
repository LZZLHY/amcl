#!/bin/bash
# AMCL Java Launcher Layer - 测试运行脚本
# 用法: cd JavaApp && bash run_tests.sh
#
# 前提: javac 和 java 在 PATH 中（JDK 17+）

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
TEST_DIR="$SCRIPT_DIR/test"
BUILD_DIR="$SCRIPT_DIR/build"

echo "=== AMCL Java Launcher Tests ==="
echo "Source: $SRC_DIR"
echo "Tests:  $TEST_DIR"
echo ""

# 清理
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/classes" "$BUILD_DIR/test-classes"

# 编译源码
echo "[1/3] Compiling source..."
find "$SRC_DIR" -name "*.java" > "$BUILD_DIR/src_files.txt" 2>/dev/null || true
if [ -s "$BUILD_DIR/src_files.txt" ]; then
    javac -d "$BUILD_DIR/classes" -source 17 -target 17 @"$BUILD_DIR/src_files.txt"
    echo "  Compiled $(wc -l < "$BUILD_DIR/src_files.txt") source files"
else
    echo "  No source files found (create src/com/amcl/launcher/*.java first)"
    echo "  Tests will fail until implementation is provided."
fi

# 编译测试
echo "[2/3] Compiling tests..."
find "$TEST_DIR" -name "*.java" > "$BUILD_DIR/test_files.txt"
javac -d "$BUILD_DIR/test-classes" -source 17 -target 17 \
    -cp "$BUILD_DIR/classes" \
    @"$BUILD_DIR/test_files.txt"
echo "  Compiled $(wc -l < "$BUILD_DIR/test_files.txt") test files"

# 运行测试
echo "[3/3] Running tests..."
echo ""

CLASSPATH="$BUILD_DIR/test-classes:$BUILD_DIR/classes"
TOTAL_PASS=0
TOTAL_FAIL=0

for TEST_CLASS in \
    com.amcl.launcher.LaunchConfigTest \
    com.amcl.launcher.AmclClassLoaderTest \
    com.amcl.launcher.ForgeHelperTest \
    com.amcl.launcher.DebugProfileCompatTest \
    com.amcl.launcher.AmclLauncherTest
do
    echo "--- Running $TEST_CLASS ---"
    if java -cp "$CLASSPATH" "$TEST_CLASS"; then
        echo ""
    else
        echo "  *** TEST SUITE FAILED ***"
        echo ""
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
done

echo "=== All test suites complete ==="
if [ $TOTAL_FAIL -gt 0 ]; then
    echo "FAILED: $TOTAL_FAIL suite(s) had failures"
    exit 1
else
    echo "ALL PASSED"
    exit 0
fi
