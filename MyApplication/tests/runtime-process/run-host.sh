#!/bin/bash
# 仓外独占输出中的真实子进程测试；不改测试服务的工作目录和标准流。
set -euo pipefail
mkdir -p /output/processor-setup
g++ -std=c++17 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
    /workspace/tests/runtime-process/setup_test.cpp -o /output/processor-setup/check
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 /output/processor-setup/check /output/processor-setup/cases
root=/workspace/entry/src/main/cpp
g++ -std=c++17 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
    -I/workspace/tests/runtime-process/stubs -I/workspace/tests/runtime-elf/stubs -I"$root" \
    /workspace/tests/runtime-process/napi_owner_test.cpp "$root/napi/napi_forge.cpp" \
    "$root/napi/napi_helpers.cpp" -o /output/processor-setup/napi-owner
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 /output/processor-setup/napi-owner
g++ -std=c++17 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
    /workspace/tests/runtime-process/signal_owner_test.cpp -o /output/processor-setup/signal-owner
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 /output/processor-setup/signal-owner
g++ -std=c++17 -O1 -g -pthread -fsanitize=address,undefined -fno-omit-frame-pointer \
    /workspace/tests/runtime-process/status_test.cpp -o /output/processor-setup/status-snapshot
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 /output/processor-setup/status-snapshot
g++ -std=c++17 -O1 -g -pthread -fsanitize=address,undefined -fno-omit-frame-pointer \
    /workspace/tests/runtime-process/control_test.cpp -o /output/processor-setup/control
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 /output/processor-setup/control
g++ -std=c++17 -O1 -g -pthread -fsanitize=address,undefined -fno-omit-frame-pointer \
    -I/workspace/tests/runtime-elf/stubs -I"$root" \
    /workspace/tests/runtime-process/fork_entry_test.cpp "$root/jvm/fork_run_java.cpp" \
    -o /output/processor-setup/fork-entry
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 /output/processor-setup/fork-entry /output/processor-setup/fork-cases
g++ -std=c++17 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
    /workspace/tests/runtime-process/child_owner_test.cpp -o /output/processor-setup/child-owner
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 /output/processor-setup/child-owner
