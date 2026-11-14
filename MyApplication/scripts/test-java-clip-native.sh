#!/bin/sh
# 复用显式 Native 系统夹具，测试生产 Clip/JNI/core。所有编译输出写调用者指定的仓外目录。
# 参数不下载依赖、不构建应用；Native tests 目录可来自已锁定的并行工作树。
set -eu
test "$#" = 6 || { echo 'usage: test-java-clip-native.sh <output> <java-home> <launcher.jar> <native-tests-dir> <host-fixture.so> <audio-jni.so>' >&2; exit 2; }
output_dir=$1
java_home=$2
launcher=$3
native_tests=$4
host_fixture=$5
audio_jni=$6
case "$output_dir" in /*) ;; *) echo 'output must be an external absolute path' >&2; exit 2;; esac
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
case "$output_dir/" in "$repo/"*) echo 'output must be outside repository' >&2; exit 2;; esac
mkdir -p "$output_dir/clip-native-classes"
"$java_home/bin/javac" --release 8 -encoding UTF-8 -cp "$launcher" -d "$output_dir/clip-native-classes" \
  "$repo/JavaApp/test/ClipNativeContractTest.java" "$native_tests/AudioNativeSmoke.java"
timeout 30 "$java_home/bin/java" -Xcheck:jni \
  -Damcl.audio.jni.path="$audio_jni" \
  -Djavax.sound.sampled.Clip='com.amcl.audio.OhosMixerProvider#AMCL OHAudio' \
  -cp "$launcher:$output_dir/clip-native-classes" ClipNativeContractTest "$host_fixture"
