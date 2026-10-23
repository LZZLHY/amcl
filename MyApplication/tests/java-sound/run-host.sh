#!/bin/bash
# 同一受控源码的共享 JNI 在同主版本宿主 JDK 上验证 Java SPI 语义。
# 使用隔离 Java 目录覆盖 jsound，系统安装不改动；这不替代 OHOS ABI/设备验收。
set -euo pipefail
major=${1:?major}
src="/source/jdk${major}u"
build="$src/build/linux-aarch64-server-release"
case "$major" in
  17) host=/usr/lib/jvm/java-17-openjdk-amd64 ;;
  21|25) host="/usr/lib/jvm/temurin-${major}-jdk-amd64" ;;
  *) exit 2 ;;
esac
mkdir -p /work/jdk/bin /work/jdk/lib/server /output/classes
mkdir -p /output/platform/com/sun/media/sound
# 私有 native 桥接可随维护版变化（25 的 nIsBigEndian 已移到 Java 层）。
# 使用同一目标源码编出的 Platform.class，不能借宿主发行版的旧桥接验证新 native。
cp "$build/jdk/modules/java.desktop/com/sun/media/sound/Platform.class" /output/platform/com/sun/media/sound/
cp "$host/bin/java" /work/jdk/bin/java
# VM 的真实 dladdr 路径参与 boot library path 推导，不能仅给 java.home 换名字。
cp "$host/lib/server/libjvm.so" /work/jdk/lib/server/libjvm.so
# 只在自有目录建立逐文件链接；待替换 native 通过条件排除，不 unlink 系统文件。
for item in "$host"/lib/*; do
    name=$(basename "$item")
    if [ "$name" != libjsound.so ] && [ "$name" != server ]; then ln -s "$item" "/work/jdk/lib/$name"; fi
done
ln -s "$host/conf" /work/jdk/conf
cp "$host/release" /work/jdk/release
cc -shared -fPIC -O2 -DX_PLATFORM=X_LINUX -DUSE_PORTS=FALSE -DUSE_DAUDIO=FALSE \
    -DUSE_PLATFORM_MIDI_IN=FALSE -DUSE_PLATFORM_MIDI_OUT=FALSE \
    -I"$host/include" -I"$host/include/linux" -I"$build/support/headers/java.desktop" \
    -I"$src/src/java.base/share/native/libjava" -I"$src/src/java.base/unix/native/libjava" \
    -I"$src/src/java.desktop/share/native/libjsound" \
    "$src"/src/java.desktop/share/native/libjsound/*.c \
    -L"$host/lib" -L"$host/lib/server" -ljava -ljvm -lm \
    -Wl,--no-undefined -o /work/jdk/lib/libjsound.so
"$host/bin/javac" -encoding UTF-8 --release 8 -d /output/classes /workspace/tests/java-sound/RuntimeSoundSmoke.java
sha256sum /work/jdk/lib/libjsound.so > /output/host-jsound.sha256
python3 -B /workspace/tests/java-sound/provenance.py --major "$major" --source "$src" --host "$host" --native /work/jdk/lib/libjsound.so
export LD_LIBRARY_PATH="$host/lib:$host/lib/server"
/work/jdk/bin/java --add-opens java.desktop/com.sun.media.sound=ALL-UNNAMED \
    --patch-module java.desktop=/output/platform \
    -Djava.home=/work/jdk -Dsun.boot.library.path=/work/jdk/lib -Xlog:library=debug \
    -cp /output/classes RuntimeSoundSmoke | tee /output/smoke.log
grep -F 'Loaded library /work/jdk/lib/libjsound.so' /output/smoke.log > /dev/null || {
    echo 'ERROR: test did not load the rebuilt native library'; exit 1;
}
