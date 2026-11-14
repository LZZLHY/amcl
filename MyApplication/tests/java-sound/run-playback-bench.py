#!/usr/bin/env python3
"""匹配旧/新真实callback的宿主稳态CPU成本。没有设备API，不能作为目标音频/性能资格。"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--sdk-headers', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    tests = Path(__file__).resolve().parent; repo = tests.parents[1]
    native = repo / 'entry/src/main/cpp/javasound'; out = args.out.resolve()
    if not args.out.is_absolute() or out.is_relative_to(repo): raise ValueError('absolute external output required')
    out.mkdir(parents=True, exist_ok=False)
    sources = [native / name for name in ('ohos_daudio_callbacks.h', 'ohos_playback_timeline.h', 'ohos_capture_ring.h')]
    sources += [tests / name for name in ('daudio_zero_return_reference.h', 'playback_callback_bench.c', 'run-playback-bench.py')]
    receipt = {'startedAt': datetime.datetime.now().astimezone().isoformat(),
               'scope': 'host matched steady callback cost only; not device qualification',
               'sources': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}, 'commands': []}
    commands = [['gcc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-D__availability__(...)=',
                 '-I' + str(args.sdk_headers), '-I' + str(native), '-I' + str(tests),
                 str(tests / 'playback_callback_bench.c'), '-o', str(out / 'bench')], [str(out / 'bench')]]
    try:
        for index, command in enumerate(commands):
            result = subprocess.run(command, capture_output=True, timeout=60)
            (out / (str(index) + '.stdout')).write_bytes(result.stdout)
            (out / (str(index) + '.stderr')).write_bytes(result.stderr)
            receipt['commands'].append({'argv': command, 'returncode': result.returncode})
            print(result.stdout.decode(errors='replace'), end='', flush=True)
            if result.returncode: raise RuntimeError(result.stderr.decode(errors='replace'))
        receipt['result'] = 'PASS'
    finally:
        receipt['finishedAt'] = datetime.datetime.now().astimezone().isoformat()
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')


if __name__ == '__main__': main()
