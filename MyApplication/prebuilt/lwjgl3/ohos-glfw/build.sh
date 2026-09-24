#!/bin/bash
# build.sh — 编译 GLFW 桥接 Java 类并更新 lwjgl-glfw.jar（方案 B）
#
# 用法：cd prebuilt/lwjgl3/ohos-glfw && ./build.sh
#
# 这是 scripts/build-prebuilt-jars.mjs 的 bash 手动 fallback（hvigor 跑不动时用）。
# 方案 B：baseline lwjgl-glfw.jar 用上游原版（含原版 GLFW.class），这里只把我们的
# CallbackBridge / GLFWWindowProperties 桥接类注入进去，【不】碰 GLFW.class。
#
# 前提：
#   - JDK 17 已安装（JAVA_HOME 或 E:\Minecraft\java\jdk-17.0.12）
#   - ../jars/lwjgl-glfw.jar（上游原版 baseline）和 ../jars/lwjgl.jar 存在

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JARS_DIR="$SCRIPT_DIR/../jars"
SRC_DIR="$SCRIPT_DIR/src"
CLASSES_DIR="$SCRIPT_DIR/classes"
JAR_FILE="$JARS_DIR/lwjgl-glfw.jar"

# 查找 JDK
if [ -n "$JAVA_HOME" ] && [ -f "$JAVA_HOME/bin/javac" ]; then
    JDK="$JAVA_HOME"
elif [ -f "E:/Minecraft/java/jdk-17.0.12/bin/javac.exe" ]; then
    JDK="E:/Minecraft/java/jdk-17.0.12"
else
    echo "ERROR: JDK 17 not found. Set JAVA_HOME or install to E:\\Minecraft\\java\\jdk-17.0.12"
    exit 1
fi

echo "=== Building OHOS GLFW Java classes ==="
echo "JDK:     $JDK"
echo "Source:  $SRC_DIR"
echo "Output:  $JAR_FILE"

# 编译
mkdir -p "$CLASSES_DIR"
CP="$JAR_FILE:$JARS_DIR/lwjgl.jar"
# Windows 分号分隔
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]]; then
    CP="$JAR_FILE;$JARS_DIR/lwjgl.jar"
fi

find "$SRC_DIR" -name "*.java" > /tmp/ohos_glfw_sources.txt
"$JDK/bin/javac" -source 17 -target 17 -cp "$CP" -d "$CLASSES_DIR" @/tmp/ohos_glfw_sources.txt
echo "Compiled $(wc -l < /tmp/ohos_glfw_sources.txt) files"

# 更新 jar（方案 B：只注入桥接类，保留上游原版 GLFW.class）
"$JDK/bin/jar" uf "$JAR_FILE" \
    -C "$CLASSES_DIR" "org/lwjgl/glfw/CallbackBridge.class" \
    -C "$CLASSES_DIR" "org/lwjgl/glfw/GLFWWindowProperties.class"

echo "=== Done! jar updated: $(wc -c < "$JAR_FILE") bytes ==="
echo ""
echo "Next steps:"
echo "  1. Run scripts/sync_prebuilt.sh to copy jar to rawfile/"
echo "  2. Delete .installed marker on device: hdc shell rm .../.minecraft/lwjgl-ohos/.installed"
echo "  3. Rebuild and deploy HAP"
