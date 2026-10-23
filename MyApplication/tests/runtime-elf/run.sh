#!/bin/bash
# 输入源码只读挂载 /workspace；所有编译输出显式留在本任务 /output。
set -euo pipefail
src=/workspace/tests/runtime-elf
out=/output
mkdir -p "$out"
cc=aarch64-linux-gnu-gcc
flags=(-shared -fPIC -nostdlib -Wl,--hash-style=both)
for name in good missing weak concurrent; do
    "$cc" "${flags[@]}" "$src/$name.c" -Wl,-soname,lib${name}.so -o "$out/lib${name}.so"
done
python3 "$src/unsupported.py"
mkdir -p "$out/system-only"
"$cc" "${flags[@]}" "$src/system_dependency.c" -Wl,-soname,libamcl_system_ctor.so -o "$out/system-only/libamcl_system_ctor.so"
"$cc" "${flags[@]}" "$src/needs_system.c" -L"$out/system-only" -lamcl_system_ctor -Wl,-soname,libneeds_system.so -o "$out/libneeds_system.so"
"$cc" "${flags[@]}" "$src/parent.c" -L"$out" -lgood -Wl,-soname,libparent.so -o "$out/libparent.so"
"$cc" "${flags[@]}" "$src/cycle_a.c" -Wl,-soname,libcycle_a.so -o "$out/libcycle_a.so"
"$cc" "${flags[@]}" "$src/cycle_b.c" -L"$out" -lcycle_a -Wl,-soname,libcycle_b.so -o "$out/libcycle_b.so"
"$cc" "${flags[@]}" "$src/cycle_a.c" -L"$out" -lcycle_b -Wl,-soname,libcycle_a.so -o "$out/libcycle_a.so"
aarch64-linux-gnu-g++ -std=c++17 -O2 -pthread -rdynamic -I"$src/stubs" \
    "$src/driver.cpp" /workspace/entry/src/main/cpp/download/hmac_sha256.cpp -ldl -o "$out/driver"
timeout 45 qemu-aarch64 -L /usr/aarch64-linux-gnu -E LD_LIBRARY_PATH="$out/system-only" "$out/driver" "$out" "${LEGACY_JLI:-}"
aarch64-linux-gnu-g++ -std=c++17 "$src/lease_driver.cpp" -o "$out/lease-driver"
timeout 20 qemu-aarch64 -L /usr/aarch64-linux-gnu "$out/lease-driver" "$out/lease-root"
