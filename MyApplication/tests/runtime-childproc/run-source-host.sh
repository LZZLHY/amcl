#!/bin/bash
# 生成非活动候选并编译四份完整固定childproc.c；只使用当前标准QA服务。
set -euo pipefail
root=/workspace/tests/runtime-childproc
out=/output/runtime-childproc-source
mkdir -p "$out"
python3 "$root/prepare_source_candidate.py" --output "$out/candidates"
for major in 8 17 21 25; do
    candidate="$out/candidates/$major"
    # 原源对照只检查旧execvp分支；候选故障语义在父侧运行ASan/UBSan。
    gcc -std=c11 -O1 -g -D_GNU_SOURCE -DAMCL_EXPECT_ORIGINAL \
        -fsanitize=address,undefined -fno-omit-frame-pointer \
        -I"$root/reference/$major" "$root/exec_source_test.c" -o "$candidate/original_exec_test"
    ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 "$candidate/original_exec_test"
    gcc -std=c11 -O1 -g -D_GNU_SOURCE -D__OHOS__ \
        -fsanitize=address,undefined -fno-omit-frame-pointer \
        -I"$candidate" "$root/exec_source_test.c" -o "$candidate/candidate_exec_test"
    ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 "$candidate/candidate_exec_test"
    # 真实fork/exec轨不插入sanitizer回调，普通工具链优化保持开启。
    gcc -std=c11 -O2 -g -D_GNU_SOURCE -D__OHOS__ -Wall -Wextra \
        -I"$candidate" "$root/child_source_host.c" -o "$candidate/child_source_host"
    "$candidate/child_source_host" "$candidate" | tee "$candidate/actual-child.log"
    gcc -std=c11 -O2 -D_GNU_SOURCE -D__OHOS__ -I"$candidate" \
        -c "$candidate/childproc.c" -o "$candidate/childproc.o"
    nm -u "$candidate/childproc.o" > "$candidate/undefined-symbols.txt"
done
python3 - "$out" <<'PY'
"""四代候选的实际编译闭包审查，不能把源文本不含调用当作对象代码也不引用。"""
import json,pathlib,sys
root=pathlib.Path(sys.argv[1])
forbidden={'malloc','calloc','realloc','free','opendir','readdir','closedir','strtol','sysconf','execvp','getenv'}
for major in ('8','17','21','25'):
    path=root/'candidates'/major/'undefined-symbols.txt'
    symbols={line.split()[-1] for line in path.read_text().splitlines() if line.split()}
    assert not symbols & forbidden,(major,sorted(symbols & forbidden))
    print('PASS actual candidate object',major,'no forbidden child dependencies',sorted(symbols))
PY
