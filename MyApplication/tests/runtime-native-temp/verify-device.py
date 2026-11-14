"""固定native-only前置报告校验；不运行探针，不授跨VM Attach/跨进程mmap/CLI资格。"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path


def require(value, message):
    if not value:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def root_ready(root, observation):
    """真实失败仍是可用观测，但绝不成为平台前提通过。允许父filesDir的真实0770。"""
    if root is None:
        return False
    for name in ('created', 'ordinaryFileObserved', 'renameIdentityObserved', 'sameProcessUnixObserved',
                 'sameProcessSharedMapObserved', 'cleanupComplete', 'cleanupAbsenceObserved'):
        if root.get(name) is not True:
            return False
    pid, uid, gid = observation['pid'], observation['euid'], observation['egid']
    scratch, sock = root['scratchMetadata'], root['socketMetadata']
    if scratch['type'] != 0o040000 or scratch['uid'] != uid or scratch['mode'] & 0o022:
        return False
    if sock['type'] != 0o140000 or sock['mode'] != 0o600 or sock['uid'] != uid or sock['gid'] != gid:
        return False
    peer = root['peer']
    if (peer['pid'], peer['uid'], peer['gid']) != (pid, uid, gid):
        return False
    before, after = root['fileBefore'], root['fileAfter']
    if (before['dev'], before['ino'], before['size']) != (after['dev'], after['ino'], after['size']) or after['type'] != 0o100000:
        return False
    operations = [row['operation'] for row in root['calls']]
    required = ('mkdirat-exclusive', 'renameat', 'file-reopen-after-rename', 'socket-chmod', 'socket-chown-self',
                'socket-lstat', 'bind', 'listen', 'accept4', 'getsockopt-SO_PEERCRED', 'send-fixed-byte', 'recv-fixed-byte',
                'mmap-write', 'mmap-read', 'msync', 'mmap-pread', 'munmap-read', 'munmap-write',
                'close-accepted', 'close-client', 'close-server', 'close-mmap-file', 'rmdir-owned-scratch', 'cleanup-fstatat')
    if any(operations.count(name) != 1 for name in required):
        return False
    for row in root['calls']:
        if row['result'] >= 0:
            if row['errno'] != 0:
                return False
            continue
        if row['operation'] == 'connect' and row['errno'] in (11, 115):
            continue
        if row['operation'] == 'cleanup-fstatat' and row['errno'] == 2:
            continue
        return False
    return True


def verify_observation(report, pid, nonce):
    require(report.get('protocol') == 'AMCL_NATIVE_TEMP_QUALIFICATION_V1' and report.get('nativeOnly') is True, 'wrong report protocol')
    observation = report['observation']
    require(observation.get('protocol') == 'AMCL_NATIVE_TEMP_PREFLIGHT_V1' and observation.get('status') == 'OBSERVED', 'incomplete OS observation')
    require(observation['pid'] == pid and observation['nonce'] == nonce, 'PID/nonce mismatch')
    for key in ('jvmStarted', 'crossVmAttachQualified', 'crossProcessMmapQualified', 'defaultCliQualified'):
        require(observation.get(key) is False, 'overstated scope: ' + key)
    require(observation['operationBudgetMillis'] == 5000 and observation['requiredParentDeadlineMillis'] == 10000, 'budget changed')
    require(not observation['deadlineExceeded'] and observation['elapsedMillis'] < 10000, 'probe timed out')
    sandbox = observation['sandbox']
    require(sandbox['rootMetadata']['uid'] == observation['euid'], 'sandbox is not owned by effective UID')
    for root in (sandbox, observation['tmpControl']):
        if root is None:
            continue
        require(root['scratch'] == root['path'] + '/.nt-' + nonce + '-' + str(pid), 'scratch ownership mismatch')
        require(root['pathBytes'] == len(root['path'].encode('utf-8')) and
                root['socketPathBytes'] == len((root['scratch'] + '/s').encode('utf-8')), 'path bytes mismatch')
    require(observation['tmpControl'] is None or observation['tmpControl']['path'] == '/tmp', 'unexpected control root')
    user = observation['passwdEffective']
    mapped = user['returnCode'] == 0 and user['found'] and user['nameComplete'] and bool(user['nameHex']) and user['mappedUid'] == observation['euid']
    return {'validObservation': True, 'effectiveUidMappingObserved': mapped,
            'privateRootOsPreconditionsObserved': mapped and root_ready(sandbox, observation),
            'tmpControlOsPreconditionsObserved': observation['tmpOpenErrno'] == 0 and root_ready(observation['tmpControl'], observation),
            'crossVmAttachQualified': False, 'crossProcessMmapQualified': False, 'defaultCliQualified': False}


def verify(run, parent_path, deployment_path, hap, nonce):
    report_path = run / 'native-temp-report.json'
    report, completion, parent, deployment = read(report_path), read(run / 'result.json'), read(parent_path), read(deployment_path)
    require(deployment.get('installed') is True and deployment.get('hapSha256') == hap, 'deployment/HAP identity mismatch')
    require(parent.get('transportOk') is True, 'parent transport failed')
    require(completion.get('protocol') == 'AMCL_NATIVE_TEMP_RESULT_V1' and completion.get('profile') == 'native-temp', 'wrong completion protocol')
    require(completion.get('observationComplete') is True and completion.get('error') == '', 'native-only observation incomplete')
    require(completion.get('nonce') == nonce and completion.get('reportSha256') == digest(report_path), 'completion identity/SHA mismatch')
    require(completion.get('archiveInstalled') is False and completion.get('jvmStarted') is False, 'unexpected archive or VM work')
    require(not any(name in completion for name in ('initResult', 'mainResult', 'destroyResult')), 'Java lifecycle fields are invalid for native-only run')
    pid = completion['pid']
    parent_stages = []
    for line in parent['text'].splitlines():
        try:
            value = json.loads(line)
            if isinstance(value, dict): parent_stages.append(value)
        except ValueError:
            pass
    starts = [row for row in parent_stages if row.get('stage') == 'native-child-start']
    ends = [row for row in parent_stages if row.get('stage') == 'native-child-exit']
    require(len(starts) == len(ends) == 1 and starts[0]['pid'] == pid and starts[0]['result'] == 0, 'owned child identity mismatch')
    require(ends[0]['observed'] is True and ends[0]['signal'] == 0 and ends[0]['timedOut'] is False, 'child exit/deadline failed')
    stages = [json.loads(line) for line in (run / 'native-stages.jsonl').read_text().splitlines() if line]
    names = [row.get('stage', '') for row in stages]
    require(names.count('native-temp-main') == names.count('native-temp-main-return') == names.count('native-temp-observed') == 1, 'stage completion incomplete')
    require(names.index('native-temp-main') < names.index('native-temp-main-return') < names.index('native-temp-observed'), 'stage order mismatch')
    require(not any(name.startswith(('archive-', 'install-', 'jvm-', 'java-', 'destroy-')) for name in names), 'native-only scope was exceeded')
    observed = next(row for row in stages if row.get('stage') == 'native-temp-observed')
    require(observed['reportSha256'] == digest(report_path), 'stage SHA mismatch')
    result = verify_observation(report, pid, nonce)
    result.update(at=datetime.now().astimezone().isoformat(), hapSha256=hap, pid=pid, nonce=nonce,
                  files={str(path): digest(path) for path in (report_path, run / 'result.json', run / 'native-stages.jsonl', parent_path, deployment_path)})
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', type=Path, required=True)
    parser.add_argument('--parent-result', type=Path, required=True)
    parser.add_argument('--deployment', type=Path, required=True)
    parser.add_argument('--expected-hap-sha256', required=True)
    parser.add_argument('--nonce', required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    result = verify(args.run, args.parent_result, args.deployment, args.expected_hap_sha256, args.nonce)
    with args.report.open('x', encoding='utf-8') as output:
        json.dump(result, output, ensure_ascii=False, indent=2)
        output.write('\n')
    print(json.dumps({key: value for key, value in result.items() if key != 'files'}))
