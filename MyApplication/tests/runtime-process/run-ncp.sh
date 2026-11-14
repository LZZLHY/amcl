#!/bin/bash
# 官方 NCP 只作边界替身；真实 Linux fork/wait 仅验证六个固定测试动作本身。
set -euo pipefail
root=/workspace/entry/src/main/cpp
mkdir -p /output/runtime-process
g++ -std=c++17 -O1 -g -fPIC -shared -fsanitize=address,undefined \
    -I/workspace/tests/jdk-probe/stubs /workspace/tests/runtime-java/child_process_fixture.cpp \
    -o /output/runtime-process/libchild_process.so
g++ -std=c++17 -O1 -g -pthread -D_GNU_SOURCE -DMC_OHOS_BUILD_TESTS \
    -fsanitize=address,undefined -fno-omit-frame-pointer -Wl,--export-dynamic \
    -I/workspace/tests/jdk-probe/stubs -I"$root" \
    /workspace/tests/runtime-process/owner_test.cpp "$root/download/hmac_sha256.cpp" \
    -L/output/runtime-process -Wl,-rpath,'$ORIGIN' -lchild_process -ldl \
    -o /output/runtime-process/owner_test
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 /output/runtime-process/owner_test
# 独立childproc候选使用同一QA窗口；原processor-setup的run-host.sh不受影响。
bash /workspace/tests/runtime-childproc/run-host.sh
