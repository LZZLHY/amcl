#!/usr/bin/env python3
"""真实HAP诊断表及收据的host正负回归；固定合成样本，不运行Java录音/系统音频API。

使用实际SDK声明，宿主仅移除availability注解；正常无TestHooks对象另编译并证明没有
诊断符号依赖。所有编译/进程/输出在显式新目录，失败收据保留原错误和命令。
"""
import argparse
from datetime import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk-headers', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]; native = repo / 'entry/src/main/cpp/javasound'; napi = repo / 'entry/src/main/cpp/napi'
    out = args.out.resolve()
    if not args.out.is_absolute() or out.is_relative_to(repo): raise ValueError('absolute external output required')
    out.mkdir(parents=True, exist_ok=False)
    sources = [native / name for name in ('ohos_daudio_callbacks.c', 'ohos_daudio_callbacks.h', 'ohos_capture_diagnostics.c',
               'ohos_capture_diagnostics.h', 'ohos_capture_ring.h', 'ohos_playback_timeline.h')]
    sources += [napi / 'jdk_capture_diagnostics.cpp', napi / 'jdk_capture_diagnostics.h', Path(__file__), Path(__file__).with_name('capture_diagnostics_test.cpp')]
    receipt = {'startedAt': datetime.now().astimezone().isoformat(), 'scope': 'host synthetic boundary statistics; no recording/device qualification',
               'inputs': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}, 'commands': [], 'cases': []}

    def run(command, label):
        result = subprocess.run(command, capture_output=True, timeout=45, env={**os.environ,
            'ASAN_OPTIONS': 'detect_leaks=1:abort_on_error=1', 'UBSAN_OPTIONS': 'halt_on_error=1'})
        (out / (label + '.stdout')).write_bytes(result.stdout); (out / (label + '.stderr')).write_bytes(result.stderr)
        receipt['commands'].append({'argv': list(map(str, command)), 'returncode': result.returncode})
        if result.returncode: raise RuntimeError(label + ': ' + result.stderr.decode('utf-8', errors='replace'))
        return result.stdout.decode('utf-8')

    try:
        flags = ['-O1', '-g', '-Wall', '-Wextra', '-Werror', '-fno-omit-frame-pointer', '-fsanitize=address,undefined',
                 '-D__availability__(...)=', '-I' + str(args.sdk_headers), '-I' + str(native), '-I' + str(napi), '-pthread']
        run(['gcc', '--version'], 'compiler')
        run(['gcc', '-std=c11', *flags, '-c', str(native / 'ohos_daudio_callbacks.c'), '-o', str(out / 'normal.o')], 'normal-compile')
        normal = run(['nm', '-u', str(out / 'normal.o')], 'normal-symbols')
        if 'diagnostic' in normal: raise AssertionError('production callback acquired diagnostic dependency')
        flags += ['-DMC_OHOS_BUILD_TESTS=1', '-DAMCL_CAPTURE_DIAGNOSTIC_TEST_HOOK=amcl_capture_diagnostic_test_hook']
        objects = []
        for name in ('ohos_daudio_callbacks', 'ohos_capture_diagnostics'):
            obj = out / (name + '.o'); objects.append(str(obj))
            run(['gcc', '-std=c11', *flags, '-c', str(native / (name + '.c')), '-o', str(obj)], name)
        run(['g++', '-std=c++17', *flags, str(Path(__file__).with_name('capture_diagnostics_test.cpp')),
             str(napi / 'jdk_capture_diagnostics.cpp'), *objects, '-o', str(out / 'run')], 'compile-main')
        for case in ('normal', 'prefix-overwrite', 'wrong-frame', 'bad-order', 'extra-open', 'inflight', 'concurrent'):
            directory = out / case; directory.mkdir()
            run([str(out / 'run'), case, str(directory)], case)
            if case != 'inflight':
                report = json.loads((directory / 'capture-diagnostic-report.json').read_text(encoding='utf-8'))
                if report['signalQualified'] or report['rawPcmSaved'] or not report['quiescent']: raise AssertionError('scope/snapshot differs')
                low, high = report['passes']
                if case == 'normal':
                    for item, count in zip((low, high), (3200, 9600)):
                        expected = math.sqrt(sum(((i * 157) % 511 - 255) ** 2 for i in range(count)) / count)
                        if not item['comparable'] or item['measuredFrames'] != count or item['peak'] != 255 or abs(item['rms'] - expected) > 1e-9:
                            raise AssertionError('prefix budget/sample moments differ')
                elif low['comparable']: raise AssertionError('false comparable prefix: ' + case)
            receipt['cases'].append({'case': case, 'result': 'PASS'})
        receipt['passed'] = True
        print('PASS signed-host source callbacks, exact 3200/9600 prefix statistics, six invalid boundaries, no production diagnostic import')
    finally:
        receipt['finishedAt'] = datetime.now().astimezone().isoformat()
        (out / 'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__': main()
