#!/usr/bin/env python3
"""独立宿主MIDI原语/真实DSO回调资格，显式仓外输出；不冒充OHOS/硬件收发。
沿用固定SDK头，GCC只去除其不认识的availability注解，ASan/UBSan/LSan正常开启。
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--sdk-headers', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    tests = Path(__file__).resolve().parent
    root = tests.parents[1]
    native = root / 'entry/src/main/cpp/javasound'
    out = args.out.resolve()
    if out == root or root in out.parents:
        raise ValueError('output must be outside source checkout')
    out.mkdir(parents=True, exist_ok=False)
    inputs = sorted(native.glob('midi*.[ch]')) + sorted(tests.glob('*'))
    receipt = {'startedAt': datetime.datetime.now().astimezone().isoformat(),
               'inputs': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs if p.is_file()},
               'commands': [], 'ohosQualified': False, 'hardwareTransferQualified': False}
    flags = ['-std=c11', '-D_GNU_SOURCE', '-O1', '-g', '-Wall', '-Wextra', '-Werror',
             '-fno-omit-frame-pointer', '-fsanitize=address,undefined',
             '-D__availability__(...)=', '-I' + str(args.sdk_headers), '-pthread']

    def run(command, label, negative=False):
        result = subprocess.run(command, capture_output=True, timeout=40, env={
            **os.environ, 'ASAN_OPTIONS': 'detect_leaks=1:abort_on_error=1',
            'UBSAN_OPTIONS': 'halt_on_error=1:print_stacktrace=1'})
        (out / (label + '.stdout')).write_bytes(result.stdout)
        (out / (label + '.stderr')).write_bytes(result.stderr)
        receipt['commands'].append({'argv': [str(x) for x in command], 'exitCode': result.returncode, 'expectedNegative': negative})
        print(result.stdout.decode('utf-8', 'replace'), end='', flush=True)
        print(result.stderr.decode('utf-8', 'replace'), end='', flush=True)
        if negative:
            if result.returncode == 0 or b'incompatible-pointer-types' not in result.stderr:
                raise RuntimeError('wrong callback signature was not specifically rejected')
        elif result.returncode:
            raise RuntimeError(label + ' failed')
    try:
        run(['gcc', '--version'], 'compiler')
        run(['gcc', *flags, tests / 'ump_test.c', native / 'midi_ump.c', '-o', out / 'ump-test'], 'build-ump')
        run([out / 'ump-test'], 'ump')
        run(['gcc', *flags, tests / 'stream_test.c', native / 'midi_stream.c', native / 'midi_ump.c', '-o', out / 'stream-test'], 'build-stream')
        run([out / 'stream-test'], 'stream')
        run(['gcc', *flags, tests / 'core_test.c', native / 'midi_core.c', native / 'midi_stream.c', native / 'midi_ump.c', '-o', out / 'core-test'], 'build-core')
        run([out / 'core-test'], 'core')
        run(['gcc', *flags, '-fPIC', '-shared', native / 'midi_callbacks.c', '-o', out / 'callbacks.so'], 'build-callbacks')
        run(['gcc', *flags, tests / 'callback_test.c', '-ldl', '-o', out / 'callback-test'], 'build-callback-test')
        run([out / 'callback-test', out / 'callbacks.so'], 'callbacks')
        run(['gcc', *flags, '-fsyntax-only', tests / 'wrong_signature.c'], 'wrong-signature', True)
        run(['gcc', *flags, '-c', native / 'midi_api.c', '-o', out / 'api.o'], 'build-api')
        run(['nm', '-u', out / 'api.o'], 'api-undefined')
        if b'OH_MIDI' in (out / 'api-undefined.stdout').read_bytes():
            raise RuntimeError('optional API became a link dependency')
        receipt['result'] = 'PASS'
    finally:
        receipt['finishedAt'] = datetime.datetime.now().astimezone().isoformat()
        (out / 'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
