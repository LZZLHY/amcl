#!/bin/bash
# 固定amcl/qa宿主核心轨：实际生产C源码+受控SDK供应者，不执行目标平台代码。
set -euo pipefail
root=/workspace/tests/java-sound-ports
out=/output/java-ports
mkdir "$out"
cc -std=c11 -O1 -g -Wall -Wextra -Werror -fno-omit-frame-pointer -no-pie \
  -fsanitize=address,undefined -pthread -I"$root/stubs" \
  "$root/ports_core_test.c" "$root/ports_fake_device.c" -o "$out/ports-core-test"
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  "$out/ports-core-test" | tee "$out/core.log"
sha256sum /workspace/entry/src/main/cpp/javasound/ports_ohos.c \
  /workspace/entry/src/main/cpp/javasound/ports_ohos.h "$root/ports_core_test.c" \
  "$root/ports_fake_device.c" "$out/ports-core-test" > "$out/core-inputs.sha256"
python3 -B "$root/run-jni-host.py" --output "$out/jni"
