#!/usr/bin/env bash
# 在显式仓外目录编译真实生产broker与OHOS薄后端；Linux验证不替代平板UI/JNI。
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
out=${1:?需要独占的仓外输出目录}
headers=${2:?需要锁定TinyFD头目录}
case "$out/" in "$root/"*) echo '拒绝工程内输出' >&2; exit 2;; esac
mkdir "$out"
cc -std=c11 -Wall -Wextra -Werror -g -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I"$headers" -I"$root/entry/src/main/cpp/platform" -c \
  "$root/prebuilt/lwjgl3/ohos-tinyfd/tinyfd_ohos.c" -o "$out/tinyfd.o"
c++ -std=c++17 -Wall -Wextra -Werror -g -fsanitize=address,undefined -fno-omit-frame-pointer -pthread \
  -I"$headers" -I"$root/entry/src/main/cpp/platform" \
  "$root/entry/src/main/cpp/platform/game_dialog.cpp" "$root/tests/game-dialog/broker_test.cpp" \
  "$out/tinyfd.o" -o "$out/broker-test"
ASAN_OPTIONS=detect_leaks=1 timeout 20 "$out/broker-test"
# SDK替身只控制分配/异常边界；被测NAPI、队列、线程等待都仍使用生产源。
c++ -std=c++17 -Wall -Wextra -Werror -g -fsanitize=address,undefined -fno-omit-frame-pointer -pthread \
  -I"$root/tests/runtime-process/stubs" -I"$root/entry/src/main/cpp/platform" -I"$root/entry/src/main/cpp/napi" \
  "$root/entry/src/main/cpp/platform/game_dialog.cpp" "$root/entry/src/main/cpp/napi/napi_game_dialog.cpp" \
  "$root/tests/game-dialog/napi_failure_test.cpp" -o "$out/napi-failure-test"
ASAN_OPTIONS=detect_leaks=1 timeout 20 "$out/napi-failure-test"
