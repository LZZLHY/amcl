#!/bin/bash
# 宿主真实 stdio + 生产 IPv6 垫片；ASan/UBSan/LSan 检查关闭/失败和并发后的资源。
# 仅替换网络观测输入和日志持久化，不用近似实现替代被测文件生命周期。
set -euo pipefail
root=/workspace/entry/src/main/cpp
mkdir -p /output/io
g++ -std=c++17 -O1 -g -pthread -fsanitize=address,undefined -fno-omit-frame-pointer \
    -D_GNU_SOURCE -I"$root" -I"$root/tests/host/stubs" \
    /workspace/tests/runtime-io/inet6_stream_test.cpp "$root/jvm/if_inet6_shim.cpp" \
    "$root/tests/host/stubs/amcl_log_stub.cpp" \
    -Wl,--wrap=fopen -Wl,--wrap=fopencookie -Wl,--wrap=getifaddrs \
    -Wl,--wrap=freeifaddrs -Wl,--wrap=if_nametoindex -Wl,--wrap=access \
    -o /output/io/inet6_stream_test
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 timeout 40s /output/io/inet6_stream_test \
    > /output/io/result.log 2>&1
tail -1 /output/io/result.log
