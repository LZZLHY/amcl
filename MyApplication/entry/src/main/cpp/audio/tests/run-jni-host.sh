#!/bin/sh
# 已存在Linux宿主JDK与生产Java源码路径均显式传入，不下载，不改JavaApp工作树。
set -eu
test "$#" = 3 || { echo 'usage: run-jni-host.sh <output-dir> <java-home> <provider-java-source-dir>' >&2; exit 2; }
output_dir=$1
java_home=$2
java_source=$3
tests_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$output_dir/jni-classes"
"$java_home/bin/javac" --release 8 -d "$output_dir/jni-classes" \
  "$java_source/AudioBackend.java" "$java_source/OhosAudioNative.java" "$tests_dir/AudioNativeSmoke.java"
timeout 30 "$java_home/bin/java" -Xcheck:jni -cp "$output_dir/jni-classes" AudioNativeSmoke \
  "$output_dir/libaudio-host-fixture.so" "$output_dir/libamcl-audio-jni-host.so"
