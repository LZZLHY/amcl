#!/usr/bin/env python3
"""独立重算固定 ProcessBuilder 报告/完整流，不从 passed 或完成 marker 单独推定资格。"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import stat

NAMES = ['default-selection', 'utf8-backpressure', 'environment-cwd', 'exit-7', 'exit-255',
         'missing-program', 'denied-exec', 'cwd-is-file', 'cwd-missing', 'destroy', 'destroy-forcibly', 'parent-unchanged']
PROCESS = NAMES[1:-1]
NEGATIVE = {'missing-program': 2, 'denied-exec': 13, 'cwd-is-file': 20, 'cwd-missing': 2}
ROW_TEXT = '|AMCL 数据 Ελληνικά العربية עברית हिन्दी ไทย 日本語 한국어 🙂|$x;"\'\\%|0123456789abcdef'
ENV_VALUE = 'AMCL 固定子环境 🙂'
READY = b'AMCL_PROCESS_READY_V1\n'


def digest(data):
    """摘要只接受实物字节，所有期望 payload 在本验证器独立生成。"""
    return hashlib.sha256(data).hexdigest()


def pairs(items):
    """拒绝 JSON 重复键，避免人和机器看到不同的资格字段。"""
    result = {}
    for key, value in items:
        if key in result:
            raise ValueError('duplicate JSON key: ' + key)
        result[key] = value
    return result


def parse(data):
    return json.loads(data, object_pairs_hook=pairs)


def require(value, message):
    if not value:
        raise ValueError(message)


def read_regular(path, limit):
    """仅核当前证据目录中的普通文件；拒绝链接、超限和截断读取。"""
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_size <= limit, 'invalid evidence file: ' + str(path))
    data = path.read_bytes()
    require(len(data) == info.st_size, 'evidence size changed')
    return data


def posix_errno(errors):
    """独立识别两种上游原生格式，核全部cause中的数值一致，拒绝20冒充2。"""
    values = {int(first or second) for item in errors for first, second in
              re.findall(r'(?:^|[ ,])error(?:=(\d+),|: (\d+) \()', item['message'])}
    require(len(values) == 1, 'original errno missing/ambiguous')
    return values.pop()


def verify_documents(directory, result_raw, marker_raw, progress_raw, major, platform, expected_run):
    """纯报告门与实际流门共用；负控可改报告字节而不改真实原始证据文件。"""
    report, marker = parse(result_raw), parse(marker_raw)
    require(marker == {'protocol': 'AMCL_JAVA_PROCESS_COMPLETE_V1', 'resultSha256': digest(result_raw), 'passed': True},
            'completion marker is not exact successful report identity; observedMarker=' + json.dumps(marker, sort_keys=True)
            + '; observedResultSha256=' + digest(result_raw) + '; observedResultBytes=' + str(len(result_raw)))
    require(report['schemaVersion'] == 1 and report['protocol'] == 'AMCL_JAVA_PROCESS_V1' and report['major'] == major
            and report['platform'] == platform and report['runDirectory'] == expected_run
            and report['passed'] is True and report['cleanupSafe'] is True, 'report identity/scope/cleanup mismatch')
    if platform == 'ohos':
        require(report['osName'] in ('HarmonyOS', 'OHOS'), 'target report does not preserve actual OHOS name')
    require([row['name'] for row in report['cases']] == NAMES, 'missing/duplicate/reordered process cases')
    rows = {row['name']: row for row in report['cases']}
    require(all(row['status'] == 'PASS' for row in rows.values()), 'process case not PASS')
    events = [parse(line) for line in progress_raw.splitlines()]
    require(len(events) == 2 * len(NAMES), 'incomplete progress sequence')
    for index, name in enumerate(NAMES):
        begin, end = events[index * 2:index * 2 + 2]
        require(begin['phase'] == 'BEGIN' and end['phase'] == 'END' and begin['case'] == end['case'] == name
                and end['nanoTime'] >= begin['nanoTime'] and end['details'] == rows[name], 'progress/result differs')
    selection = rows['default-selection']
    require(selection['launchMechanismProperty'] is None and selection['platform'] == platform, 'forced launch mechanism')
    if platform != 'windows-host':
        require(selection['executable'] == ('/system/bin/sh' if platform == 'ohos' else '/bin/sh'), 'wrong fixed shell')
    for name in PROCESS:
        row = rows[name]
        require(row['reaped'] is True and row['allThreadsJoined'] is True and row['cleanupErrors'] == [], 'unreaped child/worker: ' + name)
        if name in NEGATIVE:
            require(row['waitObserved'] is False and row['expectedPosixErrno'] == NEGATIVE[name]
                    and row['originalIOException'][0]['class'] == 'java.io.IOException' and 'pid' not in row,
                    'invalid start not preserved as original IOException')
            if platform != 'windows-host':
                require(posix_errno(row['originalIOException']) == row.get('observedPosixErrno') == NEGATIVE[name], 'original errno changed')
        else:
            require(row['waitObserved'] is True and row['finalAlive'] is False
                    and row['exitCode'] == row['finalExitCode'], 'missing actual final wait/exit: ' + name)
            require(row['commandKind'] == ('fixed-java-child' if platform == 'windows-host' else 'fixed-shell-builtins'), 'unexpected command mode')
    inputs = ''.join(f'{i:05d}{ROW_TEXT}\n' for i in range(8192)).encode('utf-8')
    errors = ''.join(f'ERR:{i:05d}{ROW_TEXT}\n' for i in range(8192)).encode('utf-8')
    data = rows['utf8-backpressure']
    require(len(inputs) > 1024 * 1024 and data['rows'] == 8192 and data['inputBytes'] == len(inputs)
            and data['stdinWritten'] == len(inputs) and data['inputSha256'] == digest(inputs)
            and data['expectedStderrSha256'] == digest(errors), 'full backpressure input proof differs')
    require(read_regular(directory / 'utf8-backpressure.stdin.bin', 4 * 1024 * 1024) == inputs, 'stdin artifact differs')
    require(data['exitCode'] == 0 and rows['environment-cwd']['exitCode'] == 0, 'data/env process failed')
    environment = rows['environment-cwd']
    # 目标的物理 cwd 从明确的 run 身份推导；Windows 分隔符跟随目标报告平台。
    separator = '\\' if platform == 'windows-host' else '/'
    expected_cwd = expected_run.rstrip('/\\') + separator + 'java-process' + separator + 'cwd-验证'
    require(environment['childEnvironment'] == ENV_VALUE and environment['expectedCwd'] == expected_cwd, 'environment/cwd proof differs')
    expected = {'utf8-backpressure': (inputs, errors),
                'environment-cwd': ((ENV_VALUE + '\n' + expected_cwd + '\n').encode(), (ENV_VALUE + '\n').encode()),
                'exit-7': (b'', b''), 'exit-255': (b'', b''), 'destroy': (READY, b''), 'destroy-forcibly': (READY, b'')}
    streams = []
    for name, contents in expected.items():
        for stream, expected_bytes in zip(('stdout', 'stderr'), contents):
            proof = rows[name][stream]
            filename = name + '.' + stream + '.bin'
            require(proof['file'] == filename and proof['eof'] is True and proof['error'] is None, 'stream incomplete: ' + filename)
            actual = read_regular(directory / filename, 4 * 1024 * 1024)
            actual.decode('utf-8', errors='strict')
            require(actual == expected_bytes and proof['bytes'] == len(actual) and proof['sha256'] == digest(actual), 'stream content/checksum differs: ' + filename)
            streams.append({'file': filename, 'bytes': len(actual), 'sha256': digest(actual)})
    for name, code in [('exit-7', 7), ('exit-255', 255)]:
        require(rows[name]['exitCode'] == code and rows[name]['waitCompleted'] is True, 'exit code was truncated or forged')
    for name, method in [('destroy', 'destroy'), ('destroy-forcibly', 'destroyForcibly')]:
        require(rows[name]['boundedWaitCompletedEarly'] is False and rows[name]['cancelMethod'] == method
                and rows[name]['cancelWaitCompleted'] is True and rows[name]['exitCode'] != 0, 'cancel was not followed by actual wait/reap')
    unchanged = rows['parent-unchanged']
    require(unchanged['environmentUnchanged'] is True and unchanged['userDirUnchanged'] is True
            and unchanged['environmentBeforeSha256'] == unchanged['environmentAfterSha256'], 'parent state changed')
    return {'schemaVersion': 1, 'qualified': True, 'major': major, 'platform': platform,
            'resultSha256': digest(result_raw), 'progressSha256': digest(progress_raw), 'markerSha256': digest(marker_raw),
            'cases': len(rows), 'streams': streams, 'stdinBytes': len(inputs),
            'scope': 'fixed direct-child Java ProcessBuilder behavior on the named platform only; not JDK CLI exec, other devices or performance'}


def verify(directory, major, platform, expected_run):
    return verify_documents(directory, read_regular(directory / 'result.json', 1024 * 1024),
                            read_regular(directory / 'complete.json', 4096), read_regular(directory / 'progress.jsonl', 2 * 1024 * 1024),
                            major, platform, expected_run)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--major', choices=('8', '17', '21', '25'), required=True)
    parser.add_argument('--platform', choices=('ohos', 'windows-host', 'unix-host'), required=True)
    parser.add_argument('--expected-run-directory', required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    report = verify(args.directory, args.major, args.platform, args.expected_run_directory)
    text = json.dumps(report, ensure_ascii=False, indent=2) + '\n'
    if args.output:
        with args.output.open('x', encoding='utf-8', newline='\n') as output:
            output.write(text)
    print(text, end='')


if __name__ == '__main__':
    main()
