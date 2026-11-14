#!/bin/bash
# 标准QA从/workspace只读源码构建，输出全部在/output；独立克隆可显式设仓外输出目录。
# ASan/UBSan与真实glibc参考分开：不让sanitizer的分配隔离改变系统loader资源对照。
set -euo pipefail
src=$(cd "$(dirname "$0")" && pwd)
out=${TLS_STORAGE_OUTPUT:-/output}
mkdir -p "$out"
g++ -std=c++17 -O1 -g -pthread -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$src/recovery_race.cpp" -o "$out/tls-recovery-race"
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 timeout 30 "$out/tls-recovery-race"
# 根任务可把本次保存的真实旧header只读挂载后显式指定。只接受约定的77和具体反例文字，
# 崩溃、超时或其它错误不能伪装成负对照成功；此输入不是第二份长期维护的算法。
if [[ -n ${TLS_STORAGE_NEGATIVE_HEADER:-} ]]; then
    g++ -std=c++17 -O1 -g -pthread -DAMCL_TLS_STORAGE_HEADER="\"${TLS_STORAGE_NEGATIVE_HEADER}\"" \
        "$src/recovery_race.cpp" -o "$out/tls-recovery-before"
    set +e
    timeout 30 "$out/tls-recovery-before" >"$out/tls-recovery-before.log" 2>&1
    negative_status=$?
    set -e
    cat "$out/tls-recovery-before.log"
    if [[ $negative_status != 77 ]] || ! grep -q '^REPRO stale recovery erased a newer same-errno failure$' "$out/tls-recovery-before.log"; then
        echo "Expected exact stale-recovery negative control was not reproduced (status $negative_status)" >&2
        exit 1
    fi
fi
g++ -std=c++17 -O1 -g -pthread -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$src/storage_test.cpp" -o "$out/tls-storage-asan"
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 timeout 90 "$out/tls-storage-asan"
g++ -std=c++17 -O1 -g -pthread -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$src/module_churn.cpp" -o "$out/tls-module-churn"
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 timeout 30 "$out/tls-module-churn"
# 模块回收的历史输入单独按SHA挂载，不复用错误恢复负控；两项旧缺陷的预期信号不同。
if [[ -n ${TLS_STORAGE_MODULE_NEGATIVE_HEADER:-} ]]; then
    g++ -std=c++17 -O1 -g -pthread -DAMCL_TLS_STORAGE_HEADER="\"${TLS_STORAGE_MODULE_NEGATIVE_HEADER}\"" \
        "$src/module_churn.cpp" -o "$out/tls-module-before"
    set +e
    timeout 30 "$out/tls-module-before" >"$out/tls-module-before.log" 2>&1
    negative_status=$?
    set -e
    cat "$out/tls-module-before.log"
    if [[ $negative_status != 77 ]] || ! grep -q '^REPRO closed modules retain 64 complete TLS payloads on a live thread$' "$out/tls-module-before.log"; then
        echo "Expected exact module-retention negative control was not reproduced (status $negative_status)" >&2
        exit 1
    fi
fi
gcc -shared -fPIC -O2 -Wl,-soname,libordinary-tls.so "$src/ordinary_tls.c" -o "$out/libordinary-tls.so"
g++ -std=c++17 -O2 -pthread -Wall -Wextra -Werror "$src/glibc_reference.cpp" -ldl -o "$out/tls-glibc-reference"
timeout 30 "$out/tls-glibc-reference" "$out/libordinary-tls.so"
# TSan需要执行环境支持；按单独验证请求开启，失败原样报告，不伪装为已通过或静默吞掉。
if [[ ${TLS_STORAGE_TSAN:-0} == 1 ]]; then
    g++ -std=c++17 -O1 -g -pthread -fsanitize=thread -fno-omit-frame-pointer \
        "$src/storage_test.cpp" -o "$out/tls-storage-tsan"
    TSAN_OPTIONS=halt_on_error=1 timeout 90 "$out/tls-storage-tsan"
fi
