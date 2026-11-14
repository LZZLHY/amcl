#!/bin/bash
# 用真实上游模板验证可恢复 OOM；旧源码单独作为 ASan 负控制，不能由任意非零退出洗绿。
set -euo pipefail
bash /workspace/tests/runtime-abi/prepare-unwind.sh
mkdir /output/original
tar -xf /unwind-input/source.tar -C /output/original
# 原件没有索引桥，但头文件保持相同编译搜索范围；负控制仍只用未经修改的原缓存。
cp /unwind-input/amcl_unwind_image.h /output/original/libunwind/src/
for flavor in patched original; do
    src=/output/unwind-source/libunwind
    options=()
    if [ "$flavor" = original ]; then src=/output/original/libunwind; options=(-DAMCL_OLD_UNWIND); fi
    g++ -std=c++17 -O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined -pthread \
        -D_LIBUNWIND_IS_NATIVE_ONLY -DNDEBUG -UNDEBUG -I"$src/src" -I"$src/include" \
        "${options[@]}" /workspace/tests/runtime-abi/fde_cache_test.cpp -o /output/cache-$flavor
done
ASAN_OPTIONS=detect_leaks=1 timeout 30 /output/cache-patched | tee /output/cache-positive.log
set +e
ASAN_OPTIONS=detect_leaks=0 timeout 10 /output/cache-original > /output/cache-negative.log 2>&1
status=$?
set -e
[ "$status" -ne 0 ] && [ "$status" -ne 124 ] && \
    grep -Eq 'AddressSanitizer: (SEGV|DEADLYSIGNAL)|null pointer passed' /output/cache-negative.log && \
    grep -q 'DwarfFDECache.*add' /output/cache-negative.log || {
    cat /output/cache-negative.log; echo "FAIL old cache negative control status=$status"; exit 1;
}
echo 'PASS old exact-source malloc(NULL) regression control'
src=/output/unwind-source/libunwind
g++ -std=c++17 -O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined -pthread \
    -D_LIBUNWIND_IS_NATIVE_ONLY -I"$src/src" -I"$src/include" \
    /workspace/tests/runtime-abi/unwind_image_test.cpp -o /output/image-registry
ASAN_OPTIONS=detect_leaks=1 timeout 30 /output/image-registry | tee /output/image-registry.log
