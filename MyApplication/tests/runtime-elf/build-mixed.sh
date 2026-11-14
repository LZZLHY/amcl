#!/bin/bash
# 两种体系结构共享完全相同的依赖图；只把 native 子图放入系统 loader 的搜索目录。
set -euo pipefail
cc=$1
out=$2
src=/workspace/tests/runtime-elf
mkdir -p "$out/system-only"
flags=(-shared -fPIC -nostdlib -Wl,--hash-style=both -Wl,-rpath,'$ORIGIN:$ORIGIN/system-only')
build() {
    local kind=$1 path=$2
    shift 2
    "$cc" "${flags[@]}" -DMIXED_KIND="$kind" "$src/mixed_fixture.c" \
        -Wl,-soname,"${path##*/}" -o "$out/$path" "$@"
}
build 3 system-only/libmixed_leaf.so
mkdir -p "$out/duplicate-private"
cp "$out/system-only/libmixed_leaf.so" "$out/duplicate-private/libmixed_leaf.so"
build 1 system-only/libmixed_left.so -L"$out/system-only" -lmixed_leaf
build 7 system-only/libmixed_own.so -L"$out/system-only" -lmixed_leaf
build 2 libmixed_right.so
build 6 libmixed_deep.so
build 5 libmixed_middle.so -L"$out" -lmixed_deep
build 4 libmixed_branch.so -L"$out" -lmixed_middle
build 0 libmixed_root.so -L"$out/system-only" -lmixed_left -L"$out" -lmixed_right
build 0 libmixed_root_deep.so -L"$out/system-only" -lmixed_left -L"$out" -lmixed_branch
build 0 libmixed_root_own.so -L"$out/system-only" -lmixed_own -L"$out" -lmixed_right
build 8 system-only/libmixed_ifunc.so
build 9 libmixed_ifunc_user.so -L"$out/system-only" -lmixed_ifunc
# 同一个 B 的子依赖在此 owner 中是下标 2，在普通 root_deep 中是下标 1；复用表不能复用旧索引。
build 0 libmixed_root_shared.so -Wl,--no-as-needed -L"$out/system-only" -lmixed_left -lmixed_ifunc -L"$out" -lmixed_branch
build 10 libmixed_permission.so
build 11 libmixed_global_consumer.so
build 12 libmixed_resolver_consumer.so
