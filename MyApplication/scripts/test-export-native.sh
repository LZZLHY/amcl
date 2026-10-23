#!/usr/bin/env bash
set -euo pipefail
# 正式宿主入口：同一批生产源链接系统zlib，输出必须在仓外；POSIX链接/锁测试应在ext4执行。
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
build=${AMCL_EXPORT_TEST_BUILD:-$(mktemp -d /tmp/amcl-export-test.XXXXXX)}
mkdir -p "$build"
build=$(realpath "$build")
case "$build" in "$repo"|"$repo"/*|/) echo 'Export Native test output must be outside repository' >&2; exit 2;; esac
src="$repo/entry/src/main/cpp"
common=("$src/export/export_pipeline.cpp" "$src/export/export_trusted_io.cpp" "$src/export/export_zip_writer.cpp" "$src/export/export_zip_verifier.cpp" "$src/download/sha1.cpp" "$src/download/hmac_sha256.cpp")
sdk=${AMCL_NAPI_HOST_SDK:-}
headers=()
if [[ -n "$sdk" ]]; then headers=(-idirafter "$sdk"); fi
# 某些登记宿主只有zlib运行时。接口使用锁定SDK头，系统头优先，链接现有宿主同ABI运行库。
zlib=${AMCL_HOST_ZLIB_LIBRARY:-$(ldconfig -p | awk '!found && /libz.so.1 .*x86-64/ {value=$NF; found=1} END {print value}')}
test -f "$zlib"
g++ -std=c++17 -O1 -g -pthread -Wall -Wextra -Werror=return-type -fmax-errors=4 \
  "${headers[@]}" "$repo/tests/export-pipeline/native.cpp" "${common[@]}" "$zlib" \
  -Wl,--wrap=pread -Wl,--wrap=pwrite -Wl,--wrap=fsync -o "$build/export-core"
"$build/export-core" "$build"
python3 - "$build/independent.zip" <<'PY'
import hashlib, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    assert archive.testzip() is None
    assert archive.namelist() == ['.minecraft/assets/', '.minecraft/assets/empty', '.minecraft/版本.json', '.minecraft/assets/a', '.minecraft/assets/b']
    assert len(archive.read('.minecraft/assets/a')) == 1100003
    assert archive.getinfo('.minecraft/assets/a').compress_type == zipfile.ZIP_STORED
print('PASS independent Python zipfile CRC/UTF8/STORE reader')
PY
# NAPI SDK替身仅在宿主入口使用；生产使用真实SDK头与libace_napi，不带替身实现。
if [[ -f "$repo/tests/export-pipeline/napi_async.cpp" ]]; then
  napi_headers=(-I"$repo/tests/export-pipeline/stubs")
  # 维护者本机默认用真实SDK声明；CI无闭源SDK，使用测试专用最小声明，二者编译同一生产桥。
  if [[ -n "$sdk" && ${AMCL_EXPORT_NAPI_HEADERS:-sdk} != stub ]]; then napi_headers=(-idirafter "$sdk"); fi
  g++ -std=c++17 -O1 -g -pthread -Wall -Wextra -Werror=return-type -fmax-errors=4 \
    "${napi_headers[@]}" "${headers[@]}" "$repo/tests/export-pipeline/napi_async.cpp" "${common[@]}" "$zlib" -o "$build/export-napi"
  "$build/export-napi" "$build"
fi
