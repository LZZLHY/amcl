#!/usr/bin/env python3
"""实际DAUDIO控制层与宿主回调DSO的ASan/UBSan选择/租约回归，不模拟系统CFI通过。"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from scripts.lib.host_test_lifecycle import HostTestScope


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--sdk-headers', type=Path, required=True)
    parser.add_argument('--jdk-headers', type=Path, required=True)
    parser.add_argument('--jni-headers', type=Path, help='使用真实JDK源码头时显式给出JNI include目录')
    parser.add_argument('--git-dir', type=Path, help='跨WSL访问Windows工作树时显式提供可读Git对象库')
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]; native = repo / 'entry/src/main/cpp/javasound'
    tests = Path(__file__).resolve().parent; out = args.out.resolve()
    if not args.out.is_absolute() or out.is_relative_to(repo): raise ValueError('external output required')
    out.mkdir(parents=True, exist_ok=False)
    work = HostTestScope('fixtures-', parent=out)
    fixtures = work.directory
    success = False
    sources = [native / n for n in ('ohos_daudio.c', 'ohos_daudio.h', 'ohos_daudio_callbacks.h',
                                  'ohos_daudio_callbacks.c', 'ohos_capture_ring.h', 'ohos_playback_timeline.h',
                                  'ohos_daudio_host.h')]
    sources.append(repo / 'entry/src/main/cpp/audio/audio_runtime.h')
    sources += [tests / n for n in ('daudio_backend_test.c', 'daudio_callback_selection_test.c',
                                   'daudio_callback_selection_host.c', 'daudio_callback_selection_main.c')]
    receipt = {'startedAt': datetime.datetime.now().astimezone().isoformat(),
               'sources': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}, 'commands': []}
    def run(argv, label):
        r = subprocess.run([str(x) for x in argv], capture_output=True, timeout=60, env={**os.environ,
            'ASAN_OPTIONS': 'detect_leaks=1:abort_on_error=1', 'UBSAN_OPTIONS': 'halt_on_error=1:print_stacktrace=1'})
        (out / (label + '.stdout')).write_bytes(r.stdout); (out / (label + '.stderr')).write_bytes(r.stderr)
        receipt['commands'].append({'argv': [str(x) for x in argv], 'returncode': r.returncode})
        print(r.stdout.decode(errors='replace'), end='', flush=True)
        if r.returncode: raise RuntimeError(label + ': ' + r.stderr.decode(errors='replace'))
    try:
        flags = ['gcc', '-std=c99', '-D_GNU_SOURCE', '-DX_PLATFORM=2', '-DX_ARCH=X_AMD64', '-DUSE_DAUDIO=1', '-Wall', '-Wextra',
                 '-Werror', '-g', '-O1', '-fno-omit-frame-pointer', '-fsanitize=address,undefined',
                 '-D__availability__(...)=', '-I' + str(args.sdk_headers), '-I' + str(args.jdk_headers),
                 '-I' + str(native), '-pthread']
        if args.jni_headers:
            flags += ['-I' + str(args.jni_headers), '-I' + str(args.jni_headers / 'linux')]
        run([*flags, '-shared', '-fPIC', native / 'ohos_daudio.c', tests / 'daudio_callback_selection_test.c',
             '-ldl', '-o', fixtures / 'backend.so'], 'backend')
        run([*flags, '-rdynamic', tests / 'daudio_callback_selection_main.c', '-ldl', '-o', fixtures / 'run'], 'main')
        for mode in ('good', 'missing', 'wrong-abi', 'foreign-callback'):
            units = [tests / 'daudio_callback_selection_host.c']; defines = []
            if mode == 'good': units.append(native / 'ohos_daudio_callbacks.c')
            elif mode == 'wrong-abi': defines.append('-DAMCL_TEST_WRONG_ABI=1')
            elif mode == 'foreign-callback': defines.append('-DAMCL_TEST_FOREIGN_CALLBACK=1')
            host = fixtures / ('host-' + mode + '.so')
            run([*flags, *defines, '-shared', '-fPIC', *units, '-ldl', '-o', host], 'compile-' + mode)
            run([fixtures / 'run', host, fixtures / 'backend.so', '1' if mode == 'good' else '0'], mode)
        # 只导出被已发布R12提交保护的真实控制层，不修改旧patch或凭当前实现拼造旧行为。
        baseline = 'ca45edbe36296442dbbedb57f4ef81d5e4bb99c6'
        git_prefix = ['git', '--git-dir=' + str(args.git_dir)] if args.git_dir else ['git', '-C', str(repo)]
        legacy = subprocess.check_output([*git_prefix, 'show',
            baseline + ':entry/src/main/cpp/javasound/ohos_daudio.c'])
        legacy_source = fixtures / 'legacy.c'; legacy_source.write_bytes(legacy)
        receipt['legacyBackend'] = {'commit': baseline, 'sha256': hashlib.sha256(legacy).hexdigest()}
        run([*flags, '-shared', '-fPIC', legacy_source, tests / 'daudio_callback_selection_test.c',
             '-ldl', '-o', fixtures / 'legacy.so'], 'legacy-backend')
        run([fixtures / 'run', fixtures / 'host-good.so', fixtures / 'legacy.so', '0', 'shared-owner'],
            'legacy-shared-owner-rejection')
        receipt['result'] = 'PASS'
        success = True
    finally:
        receipt['fixturesRemoved'] = work.close(success=success)
        receipt['finishedAt'] = datetime.datetime.now().astimezone().isoformat()
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')


if __name__ == '__main__': main()
