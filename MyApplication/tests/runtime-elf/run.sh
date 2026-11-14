#!/bin/bash
# 输入源码只读挂载 /workspace；所有编译输出显式留在本任务 /output。
set -euo pipefail
src=/workspace/tests/runtime-elf
out=/output
mkdir -p "$out"
# 先保存独立 glibc 语义对照；其结果不由生产 loader 自己定义。
bash "$src/run-scope-reference.sh"
# 结构解析器在宿主开启内存/未定义行为检查，实际装载回归仍在下面使用 AArch64。
g++ -std=c++17 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$src/unwind_validation_test.cpp" -o "$out/unwind-validation"
ASAN_OPTIONS=detect_leaks=1 "$out/unwind-validation"
g++ -std=c++17 -O1 -g -pthread -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$src/thread_terminal_test.cpp" -o "$out/thread-terminal"
ASAN_OPTIONS=detect_leaks=1 "$out/thread-terminal"
cc=aarch64-linux-gnu-gcc
flags=(-shared -fPIC -nostdlib -Wl,--hash-style=both)
for name in good missing weak concurrent; do
    "$cc" "${flags[@]}" "$src/$name.c" -Wl,-soname,lib${name}.so -o "$out/lib${name}.so"
done
"$cc" "${flags[@]}" -mtls-dialect=desc "$src/tls_failure.c" -o "$out/libtls_failure.so"
# 此夹具只验真实C++析构登记/拥有关系；跨帧EH仍由SDK真实provider套件独立验证。
aarch64-linux-gnu-g++ -std=c++17 "${flags[@]}" -mtls-dialect=desc -fvisibility=hidden \
    -fno-exceptions -fno-unwind-tables -fno-asynchronous-unwind-tables \
    "$src/thread_destructor.cpp" -o "$out/libthread_destructor.so"
# 真实 ELF 符号绑定与可见性，不在驱动中伪造 production 的查询结果。
"$cc" -shared -fPIC -nostdlib -Wl,--hash-style=both "$src/visibility.c" -o "$out/libvisibility.so"
"$cc" -shared -fPIC -nostdlib -Wl,--hash-style=both "$src/binding.c" -o "$out/libbinding.so"
"$cc" -shared -fPIC -nostdlib -Wl,--hash-style=both -DPROTECTED_BINDING "$src/binding.c" -o "$out/libprotected.so"
"$cc" -shared -fPIC -nostdlib -Wl,--hash-style=both -Wl,-Bsymbolic "$src/binding.c" -o "$out/libsymbolic.so"
"$cc" -shared -fPIC -nostdlib -Wl,--hash-style=both "$src/fini.c" \
    -Wl,-fini,finish_library -Wl,-soname,libfini.so -o "$out/libfini.so"
python3 "$src/unsupported.py"
python3 "$src/corrupt_dynamic.py"
"$cc" -shared -fPIC -nostdlib -Wl,--hash-style=both "$src/reentrant_fini.c" -o "$out/libreentrant_fini.so"
mkdir -p "$out/system-only"
"$cc" "${flags[@]}" "$src/system_dependency.c" -Wl,-soname,libamcl_system_ctor.so -o "$out/system-only/libamcl_system_ctor.so"
# 真实系统已加载实例与自定义目录同名文件并存；NOLOAD 不得改选磁盘候选。
"$cc" "${flags[@]}" -DSCOPE_KIND=4 "$src/scope_fixture.c" -Wl,-soname,libscope_shadow.so -o "$out/system-only/libscope_shadow.so"
cp "$out/system-only/libscope_shadow.so" "$out/libscope_shadow.so"
"$cc" "${flags[@]}" -DSCOPE_KIND=8 "$src/scope_fixture.c" -Wl,-soname,libscope_wait.so -o "$out/libscope_wait.so"
for item in '3 leaf' '2 right' '4 local' '5 consumer' '6 next' '7 later'; do
    read -r kind name <<<"$item"
    "$cc" "${flags[@]}" -fno-optimize-sibling-calls -DSCOPE_KIND="$kind" "$src/scope_fixture.c" \
        -Wl,-soname,"libscope_$name.so" -o "$out/libscope_$name.so"
done
"$cc" "${flags[@]}" -DSCOPE_KIND=1 "$src/scope_fixture.c" -L"$out" -l:libscope_leaf.so \
    -Wl,-soname,libscope_left.so -o "$out/libscope_left.so"
"$cc" "${flags[@]}" -DSCOPE_KIND=0 "$src/scope_fixture.c" -L"$out" -l:libscope_left.so -l:libscope_right.so \
    -Wl,-soname,libscope_root.so -o "$out/libscope_root.so"
"$cc" "${flags[@]}" -DSCOPE_KIND=6 "$src/scope_fixture.c" -Wl,--no-as-needed -L"$out" -l:libscope_later.so \
    -o "$out/libscope_next_dependency.so"
"$cc" "${flags[@]}" -DSCOPE_KIND=9 "$src/scope_fixture.c" -Wl,-z,global -o "$out/libscope_dynamic_global.so"
"$cc" "${flags[@]}" -DSCOPE_KIND=10 "$src/scope_fixture.c" -Wl,-z,nodelete -o "$out/libscope_dynamic_nodelete.so"
bash "$src/build-mixed.sh" "$cc" "$out"
"$cc" "${flags[@]}" "$src/needs_system.c" -L"$out/system-only" -lamcl_system_ctor -Wl,-soname,libneeds_system.so -o "$out/libneeds_system.so"
"$cc" "${flags[@]}" "$src/parent.c" -L"$out" -lgood -Wl,-soname,libparent.so -o "$out/libparent.so"
"$cc" "${flags[@]}" "$src/dependent.c" -L"$out" -lgood -Wl,-soname,libdependent.so -o "$out/libdependent.so"
"$cc" "${flags[@]}" "$src/dependent.c" -L"$out" -lgood -Wl,-soname,libdependent_second.so -o "$out/libdependent_second.so"
"$cc" "${flags[@]}" "$src/cycle_a.c" -Wl,-soname,libcycle_a.so -o "$out/libcycle_a.so"
"$cc" "${flags[@]}" "$src/cycle_b.c" -L"$out" -lcycle_a -Wl,-soname,libcycle_b.so -o "$out/libcycle_b.so"
"$cc" "${flags[@]}" "$src/cycle_a.c" -L"$out" -lcycle_b -Wl,-soname,libcycle_a.so -o "$out/libcycle_a.so"
aarch64-linux-gnu-g++ -std=c++17 -O2 -pthread -rdynamic -I"$src/stubs" \
    "$src/driver.cpp" /workspace/entry/src/main/cpp/download/hmac_sha256.cpp -ldl -o "$out/driver"
timeout 45 qemu-aarch64 -L /usr/aarch64-linux-gnu -E LD_LIBRARY_PATH="$out/system-only" "$out/driver" "$out" "${LEGACY_JLI:-}"
aarch64-linux-gnu-g++ -std=c++17 "$src/lease_driver.cpp" -o "$out/lease-driver"
timeout 20 qemu-aarch64 -L /usr/aarch64-linux-gnu "$out/lease-driver" "$out/lease-root"
