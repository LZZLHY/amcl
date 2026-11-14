#!/bin/bash
# 宿主只验证资格通道的资源失败边界；真正 JavaVM 仍由 API26 设备独立创建。
set -euo pipefail
root=/workspace/entry/src/main/cpp
mkdir -p /output/runtime-java
g++ -std=c++17 -O1 -g -fPIC -shared -fsanitize=address,undefined \
    -I/workspace/tests/jdk-probe/stubs /workspace/tests/runtime-java/child_process_fixture.cpp \
    -o /output/runtime-java/libchild_process.so
g++ -std=c++17 -O1 -g -pthread -D_GNU_SOURCE -DMC_OHOS_BUILD_TESTS \
    -fsanitize=address,undefined -fno-omit-frame-pointer -Wl,--export-dynamic \
    -I/workspace/tests/jdk-probe/stubs -I/workspace/tests/runtime-fontconfig/stubs -I"$root" \
    /workspace/tests/runtime-java/owner_test.cpp "$root/download/hmac_sha256.cpp" \
    "$root/platform/jdk_install_store.cpp" "$root/platform/jdk_install_archive.cpp" \
    -L/output/runtime-java -Wl,-rpath,'$ORIGIN' -lchild_process -ldl -lz -o /output/runtime-java/owner_test
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 /output/runtime-java/owner_test
# 双NCP候选共享原入口，但两个退出/TSFN环境结束具有独立回收边界；直接消费真实正文。
python3 -B /workspace/tests/runtime-native-temp/run-pair-host.py \
    --source-root /workspace --output /output/runtime-java/native-temp-pair
