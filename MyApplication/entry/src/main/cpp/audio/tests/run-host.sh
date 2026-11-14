#!/bin/sh
# 生产Native核心/真实DSO测试。必须显式指定仓库外输出；不下载工具、不清理已有目录。
set -eu
test "$#" = 1 || { echo 'usage: run-host.sh <external-output-directory>' >&2; exit 2; }
audio_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir=$1
mkdir -p "$output_dir"
compiler=${CXX:-g++}
"$compiler" -std=c++17 -O1 -g -DNDEBUG -fsanitize=address,undefined -fno-omit-frame-pointer -pthread \
  "$audio_dir/audio_core.cpp" "$audio_dir/tests/audio_core_test.cpp" -o "$output_dir/audio-core-test"
timeout 30 "$output_dir/audio-core-test"
# 此DSO只用FakePlatform替代系统设备，ABI/控制线程/发现协议均为实际生产源。
"$compiler" -std=c++17 -O1 -g -fPIC -shared -fvisibility=hidden -pthread \
  "$audio_dir/audio_core.cpp" "$audio_dir/audio_host.cpp" "$audio_dir/tests/audio_test_platform.cpp" \
  -ldl -o "$output_dir/libaudio-host-fixture.so"
"$compiler" -std=c++17 -O1 -g -fPIC -shared -fvisibility=hidden -pthread \
  "$audio_dir/audio_jni.cpp" "$audio_dir/audio_client.cpp" -ldl -o "$output_dir/libamcl-audio-jni-host.so"
"$compiler" -std=c++17 -O1 -g -fPIC -shared -fvisibility=hidden \
  "$audio_dir/audio_client.cpp" "$audio_dir/tests/audio_client_test_export.cpp" -ldl -o "$output_dir/libaudio-client-fixture.so"
"$compiler" -std=c++17 -O1 -g -DNDEBUG "$audio_dir/tests/audio_binding_test.cpp" -ldl -o "$output_dir/audio-binding-test"
timeout 30 "$output_dir/audio-binding-test" "$output_dir/libaudio-host-fixture.so" "$output_dir/libaudio-client-fixture.so"
