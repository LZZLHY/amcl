#!/bin/bash
# 仅系统 glibc 对照，所有库与执行产物外置；与 AArch64 自定义 loader 回归分开计证。
set -euo pipefail
src=/workspace/tests/runtime-elf
out=/output/scope-reference
mkdir -p "$out"
flags=(-shared -fPIC -nostdlib -Wl,--hash-style=both -Wl,-rpath,'$ORIGIN')
for item in '3 leaf' '2 right' '4 local' '5 consumer' '6 next' '7 later' '8 wait'; do
    read -r kind name <<<"$item"
    gcc "${flags[@]}" -fno-optimize-sibling-calls -DSCOPE_KIND="$kind" "$src/scope_fixture.c" \
        -Wl,-soname,"libscope_$name.so" -o "$out/libscope_$name.so"
done
gcc "${flags[@]}" -DSCOPE_KIND=1 "$src/scope_fixture.c" -L"$out" -l:libscope_leaf.so \
    -Wl,-soname,libscope_left.so -o "$out/libscope_left.so"
gcc "${flags[@]}" -DSCOPE_KIND=0 "$src/scope_fixture.c" -L"$out" -l:libscope_left.so -l:libscope_right.so \
    -Wl,-soname,libscope_root.so -o "$out/libscope_root.so"
gcc "${flags[@]}" -DSCOPE_KIND=6 "$src/scope_fixture.c" -Wl,--no-as-needed -L"$out" -l:libscope_later.so \
    -o "$out/libscope_next_dependency.so"
gcc "${flags[@]}" -DSCOPE_KIND=9 "$src/scope_fixture.c" -Wl,-z,global -o "$out/libscope_dynamic_global.so"
gcc "${flags[@]}" -DSCOPE_KIND=10 "$src/scope_fixture.c" -Wl,-z,nodelete -o "$out/libscope_dynamic_nodelete.so"
g++ -std=c++17 -O2 -pthread -rdynamic "$src/scope_reference.cpp" -ldl -o "$out/reference"
bash "$src/build-mixed.sh" gcc "$out"
timeout 8 "$out/reference" "$out"
