#!/bin/bash
# 固定 amcl qa 内的真实 glibc 对照；所有编译/执行记录留在当前独占 /output。
# warm 要证明基础夹具有效，late 只收集系统实际行为，不预设系统必须支持此边界。
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd)
out=${TLS_CRT_REFERENCE_OUTPUT:-/output/tls-crt-reference}
if [ -e "$out" ]; then
    echo "Reference output already exists: $out" >&2
    exit 2
fi
mkdir -p "$out"
exec > >(tee "$out/run.log") 2>&1
set -x
date --iso-8601=ns
uname -a
g++ --version
ldd --version
sha256sum "$root/fixture_api.h" "$root/owner_a.cpp" "$root/dependency_b.cpp" \
    "$root/glibc_reference.cpp" "$root/run-glibc-reference.sh" > "$out/source-sha256.txt"
g++ -std=c++17 -O2 -g -fPIC -fvisibility=hidden -shared -Wl,-z,now \
    -Wl,-soname,libamcl_sdk_tls_b.so -Wl,-rpath,'$ORIGIN' \
    "$root/dependency_b.cpp" -o "$out/libamcl_sdk_tls_b.so"
g++ -std=c++17 -O2 -g -fPIC -fvisibility=hidden -shared -Wl,-z,now \
    -Wl,-soname,libamcl_sdk_tls_a.so -Wl,-rpath,'$ORIGIN' \
    "$root/owner_a.cpp" -L"$out" -lamcl_sdk_tls_b -o "$out/libamcl_sdk_tls_a.so"
g++ -std=c++17 -O2 -g -Wall -Wextra -Werror "$root/glibc_reference.cpp" \
    -pthread -ldl -o "$out/reference"
readelf -h -d -s -r "$out/libamcl_sdk_tls_a.so" > "$out/elf-a.txt"
readelf -h -d -s -r "$out/libamcl_sdk_tls_b.so" > "$out/elf-b.txt"
sha256sum "$out/libamcl_sdk_tls_a.so" "$out/libamcl_sdk_tls_b.so" "$out/reference" > "$out/artifact-sha256.txt"
# 不产生宿主 core 大文件；原始 stderr、进程退出状态与事件序列已经足够分类本对照。
ulimit -c 0
set +e
timeout 15s "$out/reference" warm "$out" > "$out/warm.jsonl" 2> "$out/warm.stderr"
warm_status=$?
timeout 15s "$out/reference" late "$out" > "$out/late.jsonl" 2> "$out/late.stderr"
late_status=$?
set -e
printf '{"warmExit":%d,"lateExit":%d,"targetDeviceQualified":false}\n' \
    "$warm_status" "$late_status" > "$out/process-status.json"
cat "$out/warm.jsonl" "$out/warm.stderr" "$out/late.jsonl" "$out/late.stderr" "$out/process-status.json"
sha256sum -c "$out/source-sha256.txt"
date --iso-8601=ns
# warm 不成立时只能说实验装置失败，不能用失败的参考程序推断 dlclose 语义。
# late 的成功/静态资源过早终结/原生信号分别保存，不把脚本收取证据成功当行为正确。
python3 - "$out" "$warm_status" "$late_status" <<'PY'
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
warm_status, late_status = map(int, sys.argv[2:])
warm = [json.loads(line) for line in (out / 'warm.jsonl').read_text().splitlines()]
late = [json.loads(line) for line in (out / 'late.jsonl').read_text().splitlines()]
events = [(entry['event'], entry['detail']) for entry in warm if entry['kind'] == 'event']
warm_valid = warm_status == 0 and events[:3] == [(40, 0), (41, 9041), (42, 0)]
warm_valid = warm_valid and all(events.count(value) == 1 for value in
    [(20, 1), (20, 2), (21, 1), (21, 2), (30, 0), (10, 0), (11, 0)])
warm_valid = warm_valid and not any(event == 31 for event, _ in events)
if warm_valid:
    warm_valid = events.index((21, 2)) < events.index((21, 1)) < events.index((30, 0))
    warm_valid = warm_valid and events.index((10, 0)) < events.index((11, 0))
warm_valid = warm_valid and any(entry.get('name') == 'finished' for entry in warm)
late_events = [(entry['event'], entry['detail']) for entry in late if entry['kind'] == 'event']
if late_status == 0 and (21, 1) in late_events and (30, 0) in late_events:
    late_order_valid = (late_events.index((21, 1)) < late_events.index((30, 0)) and
        not any(event == 31 for event, _ in late_events))
    classification = 'tls-dtor-precedes-static-dtor' if late_order_valid else 'static-resource-ended-before-tls-dtor'
elif 128 < late_status < 192:
    classification = 'native-signal-after-fini-first-touch'
else:
    classification = 'incomplete-observation'
summary = {'warmFixtureValid': warm_valid, 'warmExit': warm_status,
    'lateExit': late_status, 'lateClassification': classification,
    'lateEvents': late_events, 'targetDeviceQualified': False}
(out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary))
if not warm_valid or classification == 'incomplete-observation':
    raise SystemExit(1)
PY
echo 'glibc reference collected; late outcome is an observation, not a correctness PASS.'
