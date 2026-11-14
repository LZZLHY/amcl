#!/bin/bash
# 固定QA和独立Linux CI执行同一生产POSIX/fork/fsync/ZIP套件。默认沿用/output，
# CI必须显式给仓外新输出目录；不依赖维护者工作区、SDK或已生成的忽略文件。
set -euo pipefail
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
src="$project/entry/src/main/cpp"
tests="$project/tests/runtime-install"
out=${AMCL_RUNTIME_INSTALL_OUTPUT:-/output}
[[ "$out" = /* ]] || { echo 'AMCL_RUNTIME_INSTALL_OUTPUT must be absolute' >&2; exit 1; }
out=$(python3 -B "$project/scripts/lib/workspace_paths.py" build runtime-install --explicit "$out")
# 只取得新空执行目录。失败不清旧现场，也不把其他调用者的输出当作本轮可删除夹具。
python3 -B - "$out" <<'PY'
from pathlib import Path
import os,sys
directory=Path(sys.argv[1]); directory.mkdir(parents=True,exist_ok=True)
existing=list(directory.iterdir())
# 固定qa的唯一入口先写本轮claim。只认精确runId，不能用该例外接管旧输出。
claim=directory/'.amcl-request-claimed'
owned_claim=(len(existing)==1 and existing[0]==claim and not claim.is_symlink()
 and bool(os.environ.get('AMCL_RUN_ID')) and claim.read_text().strip()==os.environ['AMCL_RUN_ID'])
if existing and not owned_claim: raise SystemExit('Runtime install output is not empty; preserve it and select a new output')
PY
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# 工具链可显式选择单一真实编译器；默认与CI安装的GNU AArch64工具链一致。
# 该输入只生成对抗ELF，不执行目标程序，目标机器/依赖/解释器仍由生产解析器验证。
aarch64_cc=${AARCH64_CC:-aarch64-linux-gnu-gcc}
# UBSan默认可以只打印错误后退出0；持续门禁要求检测到未定义行为时确实失败。
export UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1
mkdir -p "$out/fixtures"
# 用真实 AArch64 链接器生成 PT_INTERP/PT_DYNAMIC 工具负例基准，不以宿主 /bin/sh 冒充 OHOS。
printf 'int fixture(void){return 7;}\n' > "$out/library.c"
printf 'extern int fixture(void); void _start(void){(void)fixture();for(;;){}}\n' > "$out/tool.c"
"$aarch64_cc" -shared -fPIC -nostdlib "$out/library.c" -Wl,-soname,libfixture.so -o "$out/libfixture.so"
"$aarch64_cc" -nostdlib -fPIE -pie "$out/tool.c" -L"$out" -lfixture -Wl,--dynamic-linker=/lib/ld-musl-aarch64.so.1 -o "$out/tool"
python3 "$tests/fixtures.py" "$out/fixtures" "$out/tool" "$out/libfixture.so"
# 固定Git历史原字节作为真实负控，不在测试里另写一份估算内存的算法。
python3 - "$tests/fixtures" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]); proof=json.loads((root/'archive-before-path-compaction.json').read_text())
assert hashlib.sha256((root/'archive-before-path-compaction.cpp.txt').read_bytes()).hexdigest()==proof['sha256']
print('PATH-MEMORY BASELINE', proof, flush=True)
PY
for variant in current baseline; do
    parser="$src/platform/jdk_install_archive.cpp"
    if [[ "$variant" == baseline ]]; then parser="$tests/fixtures/archive-before-path-compaction.cpp.txt"; fi
    g++ -std=c++17 -O2 -g -I"$src/platform" "-DAMCL_ARCHIVE_PARSER=\"$parser\"" \
        "$tests/path_memory_test.cpp" "$src/download/hmac_sha256.cpp" -lz -o "$out/path-memory-$variant"
done
"$out/path-memory-current" "$out/fixtures/deep-path-metadata.zip"
set +e
"$out/path-memory-baseline" "$out/fixtures/deep-path-metadata.zip"
baseline_status=$?
set -e
[[ "$baseline_status" == 77 ]] || { echo "Historical negative control did not reach the expected allocation limit: $baseline_status"; exit 1; }
g++ -std=c++17 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$tests/zip64_test.cpp" "$src/download/hmac_sha256.cpp" -lz -o "$out/zip64-test"
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 "$out/zip64-test"
g++ -std=c++17 -O1 -g -Wall -Wextra -Werror=return-type -pthread \
    -fsanitize=address,undefined -fno-omit-frame-pointer -DAMCL_JDK_INSTALL_TEST \
    "$tests/install_test.cpp" "$src/platform/jdk_install_store.cpp" \
    "$src/platform/jdk_install_archive.cpp" "$src/platform/jdk_font_resources.cpp" \
    "$src/download/hmac_sha256.cpp" -Wl,--wrap=renameat -Wl,--wrap=fsync -Wl,--wrap=fchmod \
    -lz -o "$out/install-test"
# Windows bind 的目录 fstat/stat/rename 身份不能假定与设备 POSIX 文件系统相同。
# 先记录实际关系；状态机在小型内存 POSIX 树执行，原始树打包留到外置输出。这里只证明
# 真实进程死亡和调用顺序；断电后的持久化资格必须另在目标文件系统验收。
python3 - "$out" <<'PY'
import json, os, pathlib, sys
root=pathlib.Path(sys.argv[1]); a=root/'inode-probe-before'; b=root/'inode-probe-after'
def capture(action):
    try: return action()
    except OSError as error: return {'errno':error.errno,'message':str(error)}
a.mkdir(); fd=os.open(a, os.O_RDONLY|os.O_DIRECTORY)
result={'beforeStat':capture(lambda:os.stat(a).st_ino),'beforeFstat':capture(lambda:os.fstat(fd).st_ino)}
result['rename']=capture(lambda:os.rename(a,b)); result.update(afterStat=capture(lambda:os.stat(b).st_ino),afterFstat=capture(lambda:os.fstat(fd).st_ino))
os.close(fd)
(root/'inode-probe.json').write_text(json.dumps(result,indent=2)); print('OUTPUT_FILESYSTEM',result,flush=True)
PY
cases=$(mktemp -d /dev/shm/amcl-jdk-install-XXXXXXXX)
# 所有真实子进程均由下方前台测试等待。失败保留执行输出并归档本轮tmpfs现场；成功只
# 留小型收据和必要量具记录，回收亲建、可再生的二进制和ZIP夹具，不清共享父目录。
finish() {
    status=$?
    trap - EXIT
    if [[ "$status" == 0 ]]; then
        # 收据采集也可能因工具查询或磁盘故障失败；在确认这一步成功前保留原案例。
        # 使用显式条件接住错误，不能由set -e直接退出而跳过失败归档。
        if python3 -B - "$project" "$out" "$started_at" <<'PY'
from pathlib import Path
from datetime import datetime,timezone
import hashlib,json,os,shutil,subprocess,sys
project,out=map(Path,sys.argv[1:3])
names=['entry/src/main/cpp/platform/jdk_install_store.cpp','entry/src/main/cpp/platform/jdk_install_archive.cpp',
 'entry/src/main/cpp/platform/jdk_font_resources.cpp','entry/src/main/cpp/download/hmac_sha256.cpp',
 'tests/runtime-install/install_test.cpp','tests/runtime-install/zip64_test.cpp',
 'entry/src/main/cpp/platform/jdk_install_store.h','entry/src/main/cpp/platform/jdk_install_io.h',
 'entry/src/main/cpp/platform/jdk_font_resources.h','entry/src/main/cpp/platform/jdk_font_resources.inc',
 'entry/src/main/cpp/download/hmac_sha256.h','tests/runtime-install/path_memory_test.cpp',
 'tests/runtime-install/fixtures.py','tests/runtime-install/run-host.sh',
 'tests/runtime-install/fixtures/archive-before-path-compaction.cpp.txt',
 'tests/runtime-install/fixtures/archive-before-path-compaction.json',
 'tests/runtime-install/fixtures/legacy-jdk17-v5-helper.json']
receipt={'schemaVersion':1,'ok':True,'startedAt':sys.argv[3],
 'finishedAt':datetime.now(timezone.utc).isoformat(),'scope':'production POSIX/fork/ZIP and ASan/UBSan; no OHOS or power-loss qualification',
 'hostCompiler':subprocess.check_output(['g++','--version'],text=True).splitlines()[0],
 'fixtureCompiler':os.environ.get('AARCH64_CC','aarch64-linux-gnu-gcc'),
 'sources':{name:hashlib.sha256((project/name).read_bytes()).hexdigest() for name in names}}
for name in ['fixtures','path-memory-current','path-memory-baseline','zip64-test','install-test',
 'full-install-test','library.c','tool.c','libfixture.so','tool','inode-probe-after']:
 target=out/name
 if target.is_symlink(): raise RuntimeError('Owned output unexpectedly became a symlink: '+str(target))
 if target.is_dir(): shutil.rmtree(target)
 elif target.exists(): target.unlink()
(out/'result.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
PY
        then status=0
        else status=$?
        fi
    fi
    if [[ "$status" != 0 ]]; then
        # 归档成功才回收唯一tmpfs副本。归档本身失败则留下原路径并输出恢复入口。
        if tar -C "$cases" -cf "$out/install-cases.tar" .; then
            rm -rf -- "$cases" || true
        else
            echo "Native test evidence retained at $cases because archival failed" >&2
        fi
    elif ! rm -rf -- "$cases"; then
        # 检查已经通过但回收失败时，保留仍存的本轮字节和独立失败结局，不伪报成功退出。
        tar -C "$cases" -cf "$out/install-cases.tar" . || true
        status=1
    fi
    exit "$status"
}
trap finish EXIT
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 timeout 120 "$out/install-test" "$out/fixtures" "$cases"
if [[ -n "${AMCL_INSTALL_ARCHIVES:-}" ]]; then
    # 大体积完整包单独使用正常优化构建；上面的同生产解析/状态机先通过ASan/UBSan。
    g++ -std=c++17 -O2 -g -pthread "$tests/full_install_test.cpp" \
        "$src/platform/jdk_install_store.cpp" "$src/platform/jdk_install_archive.cpp" \
        "$src/download/hmac_sha256.cpp" -lz -o "$out/full-install-test"
    timeout 600 "$out/full-install-test" "$AMCL_INSTALL_ARCHIVES" "$cases/full" "$out"
    python3 "$tests/verify_full_install.py" "$out"
fi
