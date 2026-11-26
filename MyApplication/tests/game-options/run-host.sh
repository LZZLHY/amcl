#!/usr/bin/env bash
# 真实 POSIX 文件与系统调用故障注入。参数为显式仓外输出目录，失败保留现场。
set -eu
test "$#" -eq 1
src="$(cd "$(dirname "$0")" && pwd)"
out="$(cd "$1" && pwd)"
case "$out/" in "$(cd "$src/../.." && pwd)/"*) exit 2 ;; esac
run="$(mktemp -d "$out/game-options.XXXXXXXX")"
mkdir "$run/files"
g++ -std=c++17 -Wall -Wextra -Werror "$src/host_test.cpp" \
    "$src/../../entry/src/main/cpp/jvm/game_options.cpp" -o "$run/test" \
    -Wl,--wrap=open,--wrap=read,--wrap=write,--wrap=fsync,--wrap=close
"$run/test" "$run/files"
rm "$run/test" "$run/files/options.txt"
rmdir "$run/files" "$run"
echo "PASS game options: read, write, sync and close failures; short writes; concurrent replacement; ordinary launch and first creation"
