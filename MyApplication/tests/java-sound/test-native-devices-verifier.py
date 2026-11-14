#!/usr/bin/env python3
"""在真实回收件的内存副本上破坏关键字段，证明新专项门不能只看passed/SHA放行。

不修改原件、不运行Java或设备。多数负控主动重算完成SHA，确保失败来自语义/资源
配对检查；另保留一个不重算SHA的正文损坏例。输出目录必须全新且位于仓库外。
"""
import argparse
import copy
from datetime import datetime
import importlib.util
import json
from pathlib import Path
import sys


def main():
    """复用正式verify入口核正例/错误JAR，再以少量纯字节负例核专项严格拒绝。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    for kind in ('hap', 'jar', 'archive'):
        parser.add_argument('--expected-' + kind + '-sha256', required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    source = Path(__file__).with_name('verify-native-devices.py')
    out = args.out.resolve()
    if not args.out.is_absolute() or out.is_relative_to(source.parents[2]):
        raise ValueError('absolute output outside repository required')
    out.mkdir(parents=True, exist_ok=False)
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location('native_devices_verifier', source)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    receipt = {'startedAt': datetime.now().astimezone().isoformat(), 'passed': False,
               'scope': 'real-evidence verifier regression only; no new device operation',
               'sources': {str(path): module.digest(path.read_bytes()) for path in (Path(__file__), source, module.BASE_PATH)},
               'cases': []}
    try:
        positive = module.verify(args.evidence, args.expected_hap_sha256, args.expected_jar_sha256, args.expected_archive_sha256)
        (out / 'positive.json').write_text(json.dumps(positive, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        if not positive['qualified']: raise AssertionError(positive['problems'])
        receipt['cases'].append({'name': 'real-full-evidence', 'result': 'PASS'})
        wrong = module.verify(args.evidence, args.expected_hap_sha256, '0' * 64, args.expected_archive_sha256)
        if wrong['qualified'] or not any('JAR identity mismatch' in text for text in wrong['problems']):
            raise AssertionError('wrong JAR identity escaped shared base gate')
        receipt['cases'].append({'name': 'wrong-jar-identity', 'result': 'REJECTED', 'reason': wrong['problems']})
        run = args.evidence / ('run-' + positive['major'])
        raw = (run / module.PROGRESS).read_bytes(); original_marker = (run / module.COMPLETE).read_bytes()
        stdout = (run / 'stdout.log').read_bytes()
        original_rows = [module.parse(line) for line in raw.splitlines()]
        marker = module.parse(original_marker)

        def corrupt(name, event, key=None, value=None, remove=False, renumber=False):
            """仅改内存中的一个真实事件；重算SHA后仍须被相应语义门拒绝。"""
            rows = copy.deepcopy(original_rows)
            selected = next(row for row in rows if row['event'] == event)
            if remove: rows.remove(selected)
            else: selected[key] = value
            if renumber:
                for index, row in enumerate(rows): row['sequence'] = index
            data = ''.join(json.dumps(row, ensure_ascii=False, separators=(',', ':')) + '\n' for row in rows).encode('utf-8')
            changed_marker = dict(marker, progressSha256=module.digest(data))
            return name, data, json.dumps(changed_marker).encode(), stdout

        cases = [('progress-byte-corruption', raw.replace(b'"midiPortsOpened":false', b'"midiPortsOpened":true', 1), original_marker, stdout)]
        cases += [corrupt('duplicate-sequence', 'platform-gates', 'sequence', 0),
                  corrupt('capture-overclaim', 'start', 'captureOpened', True),
                  corrupt('disabled-platform-gate', 'platform-gates', 'midiProviderEnabled', False),
                  corrupt('wrong-native-provider', 'midi-enumeration-start', 'provider', 'com.sun.media.sound.SoftProvider'),
                  corrupt('missing-port-close', 'port-closed', remove=True, renumber=True),
                  corrupt('wrong-port-type', 'port-opened', 'lineClass', 'javax.sound.sampled.SourceDataLine'),
                  corrupt('fake-control', 'port-opened', 'controls', [{'type': 'VOLUME'}])]
        cases += [('native-ready-missing', raw, original_marker, stdout.replace(module.READY.encode(), b'REMOVED_CREATE_PROOF')),
                  ('ready-text-inside-json', raw, original_marker, stdout.replace(module.READY.encode(), json.dumps({'name': module.READY}).encode())),
                  ('midi-io-overclaim', raw, json.dumps(dict(marker, midiIoQualified=True)).encode(), stdout)]
        for name, progress, complete, log in cases:
            try:
                module.verify_documents(progress, complete, log, int(positive['major']), positive['pid'])
            except ValueError as error:
                receipt['cases'].append({'name': name, 'result': 'REJECTED', 'reason': str(error)})
            else:
                raise AssertionError('false green: ' + name)
        receipt['passed'] = True
        print('PASS real complete identity and 12 negative controls; original evidence unchanged')
    finally:
        receipt['finishedAt'] = datetime.now().astimezone().isoformat()
        (out / 'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
