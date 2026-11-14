#!/bin/bash
# 同一固定 QA 的 Context 探针边界测试，目标执行由父任务的官方 NCP 验收。
set -euo pipefail
src=/workspace/tests/runtime-fontconfig
root=/workspace/entry/src/main/cpp
out=/output/font-context-boundaries
mkdir -p "$out/missing" "$out/wrong"
g++ -std=c++17 -O1 -g -fPIC -shared -fsanitize=address,undefined \
    -I"$src/stubs" "$src/font-context-provider.cpp" -Wl,-soname,libability_runtime.so \
    -o "$out/libability_runtime.so"
printf '%s\n' 'extern "C" void NoCacheSymbol() {}' > "$out/missing.cpp"
g++ -shared -fPIC "$out/missing.cpp" -Wl,-soname,libability_runtime.so -o "$out/missing/libability_runtime.so"
g++ -std=c++17 -O1 -g -fPIC -shared -fsanitize=address,undefined \
    -I"$src/stubs" "$src/font-context-provider.cpp" -Wl,-soname,libwrong_context.so -o "$out/wrong/libwrong_context.so"
printf '%s\n' 'extern "C" void AmclFontContextFixtureConfigure(const char*,int);' \
    'extern "C" void KeepDependency(){AmclFontContextFixtureConfigure("/",0);}' > "$out/wrong.cpp"
g++ -shared -fPIC "$out/wrong.cpp" -L"$out/wrong" -lwrong_context -Wl,-rpath,'$ORIGIN' \
    -Wl,-soname,libability_runtime.so -o "$out/wrong/libability_runtime.so"
g++ -std=c++17 -O1 -g -D_GNU_SOURCE -DMC_OHOS_BUILD_TESTS -fsanitize=address,undefined \
    -fno-omit-frame-pointer -I"$src/stubs" -I"$root" "$src/font-context-host.cpp" \
    "$root/download/hmac_sha256.cpp" -ldl -o "$out/context-host"
for mode in good missing-provider missing-symbol wrong-provider no-context bad-path bad-length write-failure collision exception-restore load-facade; do
    mkdir "$out/$mode"
    fixture="$out/libability_runtime.so"
    if [[ "$mode" == missing-symbol ]]; then fixture="$out/missing/libability_runtime.so"; fi
    if [[ "$mode" == wrong-provider ]]; then fixture="$out/wrong/libability_runtime.so"; fi
    fixture_search=""
    if [[ "$mode" == load-facade ]]; then fixture_search="$out"; fi
    LD_LIBRARY_PATH="$fixture_search" ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        "$out/context-host" "$mode" "$out/$mode" "$fixture" 2>&1 | tee "$out/$mode.log"
done
