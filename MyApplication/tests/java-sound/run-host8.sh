#!/bin/bash
# 使用真实 8u452 Platform.class 与同一已打补丁的 native 源码验证经典 SPI 门控。
# /work 是 qa 临时可写层；复制宿主 JRE 后仅覆盖自有副本，不修改工具链系统安装。
set -euo pipefail
src=/source/jdk8u
build="$src/build/linux-aarch64-normal-server-release"
host=/usr/lib/jvm/java-8-openjdk-amd64
mkdir -p /work/jdk /output/classes /output/platform/com/sun/media/sound
cp -a "$host/jre" /work/jdk/jre
cp "$build/jdk/classes/com/sun/media/sound/Platform.class" /output/platform/com/sun/media/sound/
native="$src/jdk/src/share/native/com/sun/media/sound"
cc -shared -fPIC -O2 -D__MUSL__ -D_LITTLE_ENDIAN -DX_PLATFORM=X_LINUX -DX_ARCH=X_AMD64 \
  -I"$host/include" -I"$host/include/linux" -I"$build/jdk/gensrc_headers" -I"$native" \
  "$native/Platform.c" "$native/Utilities.c" -Wl,--no-undefined -o /work/jdk/jre/lib/amd64/libjsound.so
"$host/bin/javac" -encoding UTF-8 -d /output/classes /workspace/tests/java-sound/RuntimeSoundSmoke.java
sha256sum /work/jdk/jre/lib/amd64/libjsound.so > /output/host-jsound.sha256
python3 -B /workspace/tests/java-sound/provenance.py --major 8 --source "$src" --host "$host" --native /work/jdk/jre/lib/amd64/libjsound.so
# 用动态链接器的实际路径记录证明加载的是改造副本；8 不支持现代 -Xlog:library。
LD_DEBUG=files /work/jdk/jre/bin/java -Xbootclasspath/p:/output/platform \
  -cp /output/classes RuntimeSoundSmoke 2>/output/native-loader.log | tee /output/smoke.log
grep -F 'calling init: /work/jdk/jre/lib/amd64/libjsound.so' /output/native-loader.log > /dev/null
if grep -E 'calling init: .*libjsoundalsa.so' /output/native-loader.log; then
  echo 'ERROR: classic test loaded an ALSA provider'; exit 1
fi
