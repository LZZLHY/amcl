#!/bin/bash
# 隔离非root宿主用例只核探针边界，不把字体替身当成目标 Fontconfig/缓存格式资格。
set -euo pipefail
src=/workspace/tests/runtime-fontconfig
out=/output/font-installed-boundaries
mkdir -p "$out/cases"
chmod 0755 "$out"
chown 65534:65534 "$out/cases"
printf '%s\n' 'void FT_Get_BDF_Property(void) {}' > "$out/ft.c"
gcc -shared -fPIC -fsanitize=address,undefined "$out/ft.c" -Wl,-soname,libfreetype.so -o "$out/libfreetype.so"
gcc -shared -fPIC -fsanitize=address,undefined -g -O1 -I"$src/reference" "$src/installed-defaults-provider.c" -L"$out" \
    -Wl,--no-as-needed -l:libfreetype.so -Wl,-rpath,'$ORIGIN' -Wl,-soname,libfontconfig.so -o "$out/libfontconfig.so"
g++ -std=c++17 -g -O1 -fsanitize=address,undefined -fno-omit-frame-pointer -no-pie \
    -I"$src/reference" -I"$src/stubs" -I/workspace/entry/src/main/cpp "$src/installed-defaults-host.cpp" \
    /workspace/entry/src/main/cpp/download/hmac_sha256.cpp -ldl -o "$out/host"
for mode in good wrong-hash wrong-origin bad-cache no-fonts read-fails no-disk warm-rewrite missing-glyph mutate-slot close-fails search-throw collision; do
    ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        runuser -u nobody -- "$out/host" "$mode" "$out/cases/$mode" "$out" 2>&1 | tee "$out/$mode.log"
done
