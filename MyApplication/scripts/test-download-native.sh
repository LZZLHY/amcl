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
  "$src/relay.cpp" "$src/hmac_sha256.cpp" "$curl_lib" \
  -Wl,--wrap=curl_easy_setopt -Wl,--wrap=curl_easy_perform -Wl,--wrap=curl_multi_info_read -o "$build/native-regression"
# 默认仍运行完整suite；定向开关选择同一生产执行器中的正文、网关或重定向URL场景。
if [[ "${AMCL_DOWNLOAD_TEST_SUITE:-}" == relay ]]; then
  "$build/native-regression" "$build" --relay-only
elif [[ "${AMCL_DOWNLOAD_TEST_SUITE:-}" == redirect-url ]]; then
  "$build/native-regression" "$build" --redirect-url-only
elif [[ "${AMCL_DOWNLOAD_TEST_SUITE:-}" == transport ]]; then
  "$build/native-regression" "$build" --transport-only
elif [[ "${AMCL_DOWNLOAD_TEST_SUITE:-}" == metadata ]]; then
  "$build/native-regression" "$build" --metadata-only
elif [[ "${AMCL_DOWNLOAD_TEST_SUITE:-}" == callback-rebalance ]]; then
  "$build/native-regression" "$build" --callback-rebalance-only
elif [[ "${AMCL_DOWNLOAD_TEST_SUITE:-}" == transfer-probe ]]; then
  "$build/native-regression" "$build" --transfer-probe-only
elif [[ "${AMCL_DOWNLOAD_TEST_SUITE:-}" == cold-source-race ]]; then
  "$build/native-regression" "$build" --cold-source-race-only
elif [[ "${AMCL_DOWNLOAD_TEST_SUITE:-}" == cold-source-yield ]]; then
  "$build/native-regression" "$build" --cold-source-yield-only
elif [[ "${AMCL_DOWNLOAD_TEST_SUITE:-}" == cold-source-reverse ]]; then
  "$build/native-regression" "$build" --cold-source-reverse-only
else
  "$build/native-regression" "$build"
fi
