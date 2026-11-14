#!/bin/bash
# 宿主替身只控制 NAPI/SDK 返回值；实际执行生产入口与清理分支，并启用 sanitizer。
set -euo pipefail
root=/workspace/entry/src/main/cpp
mkdir -p /output/jdk-probe-owner
g++ -std=c++17 -O1 -g -pthread -D_GNU_SOURCE -DMC_OHOS_BUILD_TESTS \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    -I/workspace/tests/jdk-probe/stubs -I"$root" \
    /workspace/tests/jdk-probe/owner_test.cpp "$root/napi/napi_jdk_probe.cpp" \
    "$root/platform/jdk_font_resources.cpp" "$root/download/hmac_sha256.cpp" \
    "$root/platform/jdk_install_store.cpp" "$root/platform/jdk_install_archive.cpp" \
    -ldl -lz -o /output/jdk-probe-owner/owner_test
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 /output/jdk-probe-owner/owner_test
