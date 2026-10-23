#!/usr/bin/env bash
set -euo pipefail
# 宿主编译真实下载核心，仅替换 OHOS 日志出口。输出必须在仓外；独立 CI 默认使用系统临时目录。
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
build=${AMCL_DOWNLOAD_TEST_BUILD:-$(mktemp -d /tmp/amcl-download-test.XXXXXX)}
mkdir -p "$build"
build=$(realpath "$build")
case "$build" in "$repo"|"$repo"/*|/) echo 'Native test output must be outside repository' >&2; exit 2;; esac
src="$repo/entry/src/main/cpp/download"
# 已装 libcurl 的 Linux 宿主可直接复用运行库；头文件使用仓库锁定的 curl 接口。
# awk读取到EOF，避免pipefail下提前退出令较大的ldconfig输出触发SIGPIPE。
curl_lib=${AMCL_HOST_CURL_LIBRARY:-$(ldconfig -p | awk '!found && /libcurl.so.4 .*x86-64/ {value=$NF; found=1} END {print value}')}
test -f "$curl_lib"
g++ -std=c++17 -O0 -g -pthread -fmax-errors=2 -I"$repo/tests/download-system/stubs" -I"$src" \
  -I"$repo/entry/src/main/cpp/third_party/curl/include" \
  "$repo/tests/download-system/native.cpp" "$src/engine.cpp" "$src/loader_download.cpp" \
  "$src/net_file.cpp" "$src/net_thread.cpp" "$src/net_source.cpp" "$src/net_state.cpp" \
  "$src/multi_downloader.cpp" "$src/download_meta.cpp" "$src/file_checker.cpp" \
  "$src/sha1.cpp" "$src/config.cpp" "$src/exception.cpp" "$src/probe.cpp" \
  "$src/relay.cpp" "$src/hmac_sha256.cpp" "$curl_lib" -o "$build/native-regression"
"$build/native-regression" "$build"
