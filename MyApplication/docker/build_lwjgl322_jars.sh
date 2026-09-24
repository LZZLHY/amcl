#!/bin/bash
set -e
# 在容器内处理 LWJGL 3.2.3 的 jar（方案 C / 322 套）：
#   1. 模块 native 名改 _v322（opengl/stb/tinyfd），让其加载 liblwjgl_<m>_v322.so
#   2. 往 lwjgl-glfw.jar 注入 CallbackBridge / GLFWWindowProperties 桥接类
# 输入: /build/lwjgl322work/jars + /build/lwjgl322work/bridge-src + /build/patch-lwjgl-libname.py
WORK=/build/lwjgl322work
JARS=$WORK/jars
PY=/usr/bin/python3
JAVAC=/usr/lib/jvm/java-17-openjdk-amd64/bin/javac
JAR=/usr/lib/jvm/java-17-openjdk-amd64/bin/jar

cd $JARS

echo "=== before: module libname present? ==="
for m in opengl stb tinyfd; do
    c=$(grep -aoc "lwjgl_$m" lwjgl-$m.jar || true)
    echo "  lwjgl-$m.jar contains 'lwjgl_$m' x$c"
done

echo "=== patch module libnames -> _v322 ==="
$PY /build/patch-lwjgl-libname.py lwjgl-opengl.jar lwjgl_opengl=lwjgl_opengl_v322
$PY /build/patch-lwjgl-libname.py lwjgl-stb.jar    lwjgl_stb=lwjgl_stb_v322
$PY /build/patch-lwjgl-libname.py lwjgl-tinyfd.jar lwjgl_tinyfd=lwjgl_tinyfd_v322

echo "=== after: _v322 present? (extract class & grep) ==="
for m in opengl stb tinyfd; do
    rm -rf /tmp/vchk && mkdir -p /tmp/vchk && (cd /tmp/vchk && unzip -oq $JARS/lwjgl-$m.jar 'org/lwjgl/*' 2>/dev/null || true)
    n=$(grep -rao "lwjgl_${m}_v322" /tmp/vchk 2>/dev/null | wc -l)
    o=$(grep -rao "lwjgl_${m}[^_]" /tmp/vchk 2>/dev/null | grep -v "_v322" | wc -l)
    echo "  lwjgl-$m: new(_v322)=$n  bare-old-left=$o"
done

echo "=== inject bridge classes into lwjgl-glfw.jar ==="
rm -rf /tmp/bcls && mkdir -p /tmp/bcls
$JAVAC -encoding UTF-8 -source 17 -target 17 -d /tmp/bcls $(find $WORK/bridge-src -name '*.java')
$JAR uf lwjgl-glfw.jar -C /tmp/bcls org/lwjgl/glfw/CallbackBridge.class -C /tmp/bcls org/lwjgl/glfw/GLFWWindowProperties.class

echo "=== glfw jar contents (bridge + upstream GLFW.class) ==="
$JAR tf lwjgl-glfw.jar | grep -E 'CallbackBridge|GLFWWindowProperties|glfw/GLFW.class' || true
echo "DONE"
