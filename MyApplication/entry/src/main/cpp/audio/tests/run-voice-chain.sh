#!/bin/sh
# 参数均为已存在且锁定的仓外输入；只生成本次测试classes，不下载或改写模型/官方JAR。
set -eu
test "$#" = 6 || { echo 'usage: run-voice-chain.sh <output> <java-home> <launcher.jar> <verity-root> <native-root> <bindings.jar>' >&2; exit 2; }
output_dir=$1
java_home=$2
launcher=$3
models=$4
native_dir=$5
bindings=$6
tests_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$output_dir/voice-chain-classes"
"$java_home/bin/javac" -cp "$launcher:$bindings" -d "$output_dir/voice-chain-classes" "$tests_dir/VoiceChain.java"
timeout 180 "$java_home/bin/java" -Xcheck:jni \
  -Damcl.audio.jni.path="$output_dir/libamcl-audio-jni-host.so" \
  -Dsherpa_onnx.native.path="$native_dir" \
  -Djavax.sound.sampled.SourceDataLine='com.amcl.audio.OhosMixerProvider#AMCL OHAudio' \
  -Djavax.sound.sampled.TargetDataLine='com.amcl.audio.OhosMixerProvider#AMCL OHAudio' \
  -cp "$output_dir/voice-chain-classes:$launcher:$bindings" VoiceChain \
  "$models" "$native_dir" "$output_dir/libaudio-host-fixture.so"
