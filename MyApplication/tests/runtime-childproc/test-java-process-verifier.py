#!/usr/bin/env python3
"""用一份真实完成的宿主报告驱动资格负控；原目录始终只读，字节破坏只写新控制目录。"""
import argparse
import copy
import importlib.util
import json
from pathlib import Path
import sys


def main():
    sys.dont_write_bytecode = True
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--major', choices=('8', '17', '21', '25'), required=True)
    parser.add_argument('--platform', choices=('windows-host', 'unix-host'), required=True)
    parser.add_argument('--expected-run-directory', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location('verifier', Path(__file__).with_name('verify-java-process.py'))
    verifier = importlib.util.module_from_spec(spec); spec.loader.exec_module(verifier)
    result_raw = (args.evidence / 'result.json').read_bytes()
    marker_raw = (args.evidence / 'complete.json').read_bytes()
    progress_raw = (args.evidence / 'progress.jsonl').read_bytes()
    verifier.verify_documents(args.evidence, result_raw, marker_raw, progress_raw, args.major, args.platform, args.expected_run_directory)
    # 与锁定上游IOE_FORMAT及本次真实21宿主文案对照；错误格式/混合cause不能被吞掉。
    for text, expected in [('error=2, No such file', 2), ('Exec failed, error: 13 (Permission denied) ', 13), ('error=20, Not a directory', 20)]:
        if verifier.posix_errno([{'message': text}]) != expected: raise RuntimeError('errno parser failed')
    for chain in [[{'message': 'error=2, x'}, {'message': 'error=20, x'}], [{'message': 'error without number'}]]:
        try: verifier.posix_errno(chain)
        except ValueError: pass
        else: raise RuntimeError('invalid errno cause accepted')
    report = verifier.parse(result_raw); events = [verifier.parse(line) for line in progress_raw.splitlines()]
    def row(data, name):
        return next(item for item in data['cases'] if item['name'] == name)
    changes = [
        ('forced-default', lambda d: row(d, 'default-selection').update(launchMechanismProperty='FORK'), 'forced launch'),
        ('unreaped-child', lambda d: row(d, 'destroy').update(reaped=False), 'unreaped'),
        ('unjoined-worker', lambda d: row(d, 'utf8-backpressure').update(allThreadsJoined=False), 'unreaped'),
        ('no-final-wait', lambda d: row(d, 'exit-7').update(waitObserved=False), 'final wait'),
        ('fake-ioexception', lambda d: row(d, 'missing-program')['originalIOException'][0].update({'class': 'java.lang.RuntimeException'}), 'original IOException'),
        ('exit255-truncated', lambda d: row(d, 'exit-255').update(exitCode=0, finalExitCode=0), 'exit code'),
        ('stdin-incomplete', lambda d: row(d, 'utf8-backpressure').update(stdinWritten=1), 'backpressure'),
        ('stdout-digest', lambda d: row(d, 'utf8-backpressure')['stdout'].update(sha256='0' * 64), 'checksum'),
        ('no-eof', lambda d: row(d, 'utf8-backpressure')['stderr'].update(eof=False), 'stream incomplete'),
        ('wrong-cwd', lambda d: row(d, 'environment-cwd').update(expectedCwd='/elsewhere'), 'cwd proof'),
        ('cancel-only-request', lambda d: row(d, 'destroy-forcibly').update(cancelWaitCompleted=False), 'actual wait'),
        ('parent-env-changed', lambda d: row(d, 'parent-unchanged').update(environmentAfterSha256='0' * 64), 'parent state'),
        ('case-failed', lambda d: row(d, 'exit-7').update(status='FAIL'), 'case not PASS'),
        ('wrong-scope', lambda d: d.update(platform='ohos'), 'scope'),
    ]
    if args.platform == 'unix-host':
        changes.append(('wrong-native-errno', lambda d: row(d, 'missing-program').update(observedPosixErrno=20), 'errno changed'))
    controls = []
    for name, change, expected in changes:
        changed = copy.deepcopy(report); change(changed)
        # 同时更新进度 END 和 marker，确保负例由语义门拒绝，而不只被外层 SHA 差异挡住。
        changed_events = copy.deepcopy(events)
        for event in changed_events:
            if event['phase'] == 'END': event['details'] = row(changed, event['case'])
        data = json.dumps(changed, ensure_ascii=False).encode('utf-8')
        marker = json.dumps({'protocol': 'AMCL_JAVA_PROCESS_COMPLETE_V1', 'passed': True, 'resultSha256': verifier.digest(data)}).encode()
        progress = '\n'.join(json.dumps(event, ensure_ascii=False) for event in changed_events).encode('utf-8')
        try:
            verifier.verify_documents(args.evidence, data, marker, progress, args.major, args.platform, args.expected_run_directory)
        except ValueError as error:
            if expected not in str(error): raise
            controls.append({'name': name, 'rejected': True, 'reason': str(error)})
        else: raise RuntimeError('negative accepted: ' + name)
    damaged = output / 'damaged-stream'; damaged.mkdir()
    for file in args.evidence.glob('*.bin'):
        (damaged / file.name).write_bytes(file.read_bytes())
    target = damaged / 'utf8-backpressure.stdout.bin'
    data = bytearray(target.read_bytes()); data[100] ^= 1; target.write_bytes(data)
    try:
        verifier.verify_documents(damaged, result_raw, marker_raw, progress_raw, args.major, args.platform, args.expected_run_directory)
    except ValueError as error:
        controls.append({'name': 'actual-stream-corrupted', 'rejected': True, 'reason': str(error)})
    else: raise RuntimeError('modified actual stdout accepted')
    receipt = {'schemaVersion': 1, 'positive': True, 'errnoFormatCases': 5, 'negativeCount': len(controls), 'controls': controls,
               'originalResultSha256': verifier.digest(result_raw), 'originalEvidenceUnchanged': result_raw == (args.evidence / 'result.json').read_bytes()}
    with (output / 'verification-controls.json').open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(receipt, stream, ensure_ascii=False, indent=2); stream.write('\n')
    print(json.dumps(receipt, ensure_ascii=False))


if __name__ == '__main__':
    main()
