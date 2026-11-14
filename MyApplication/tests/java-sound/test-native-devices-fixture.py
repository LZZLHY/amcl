#!/usr/bin/env python3
"""新只读设备夹具的class52及最小假Port边界回归；不调用设备、SPI或生产资格main。"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--javac', type=Path, required=True)
    parser.add_argument('--java', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    tests = Path(__file__).resolve().parent; repo = tests.parents[1]; out = args.out.resolve()
    if not args.out.is_absolute() or out.is_relative_to(repo): raise ValueError('absolute external output required')
    out.mkdir(parents=True, exist_ok=False); classes = out / 'classes'; classes.mkdir()
    sources = [tests / name for name in ('NativeSoundDevicesQualification.java', 'NativeSoundDevicesBoundaryTest.java')]
    receipt = {'startedAt': datetime.datetime.now().astimezone().isoformat(), 'scope': 'host fixture boundary only; no native/provider/device qualification',
               'sources': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}, 'commands': []}
    commands = [[str(args.javac), '--release', '8', '-encoding', 'UTF-8', '-g', '-d', str(classes), *map(str, sources)],
                [str(args.java), '-cp', str(classes), 'NativeSoundDevicesBoundaryTest', str(out)]]
    try:
        for index, command in enumerate(commands):
            result = subprocess.run(command, capture_output=True, timeout=30)
            (out / (str(index) + '.stdout')).write_bytes(result.stdout); (out / (str(index) + '.stderr')).write_bytes(result.stderr)
            receipt['commands'].append({'argv': command, 'returncode': result.returncode})
            if result.returncode: raise RuntimeError(result.stderr.decode(errors='replace'))
        for file in classes.rglob('*.class'):
            if file.read_bytes()[6:8] != b'\x00\x34': raise ValueError('not class52')
        rows = [json.loads(line) for line in (out / 'boundary-progress.jsonl').read_text(encoding='utf-8').splitlines()]
        normal = next(row for row in rows if row['event'] == 'port-opened')
        if normal['name'] != '输入&<>🚀\n' or normal['controls'] != []: raise ValueError('JSON lost exact Unicode metadata')
        if not any(row['event'] == 'ports-unavailable' and row['qualified'] is False for row in rows): raise ValueError('zero Port observation missing')
        receipt['result'] = 'PASS'; print('PASS class52 and bounded fake-Port resource/error/Unicode controls; no target capability granted')
    finally:
        receipt['finishedAt'] = datetime.datetime.now().astimezone().isoformat()
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')


if __name__ == '__main__': main()
