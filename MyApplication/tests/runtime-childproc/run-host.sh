#!/bin/bash
# 同一标准Compose QA窗口内跑故障与真实内核两轨，不新建环境或缩短原NCP六动作。
set -euo pipefail
root=/workspace/tests/runtime-childproc
out=/output/runtime-childproc
mkdir -p "$out"
gcc -std=c11 -O1 -g -D_GNU_SOURCE -Wall -Wextra -Werror \
    -fsanitize=address,undefined -fno-omit-frame-pointer "$root/fd_fault_test.c" -o "$out/fd_fault_test"
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 "$out/fd_fault_test"
g++ -std=c++17 -O2 -g -D_GNU_SOURCE -Wall -Wextra -Werror \
    "$root/fd_probe_host.cpp" -o "$out/fd_probe_host"
"$out/fd_probe_host" | tee "$out/real-kernel-fd.json"
