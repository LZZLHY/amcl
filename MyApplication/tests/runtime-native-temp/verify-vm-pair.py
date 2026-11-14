"""独立双NCP/VM证据验收；只读且严格绑定外部预期身份，不执行JDK或设备命令。

成功只授本次固定Attach/共享PerfData协议；CLI、JLI、游戏及其他设备不在范围。
所有JSON拒绝重复键，Java Properties按转义解码并拒绝重复键；不能靠文件存在或passed字段单独放行。
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys
import zipfile

sys.dont_write_bytecode = True
HEX = re.compile(r'[0-9a-f]{64}\Z')


def require(condition, message):
    """遇到不完整、矛盾或类型错误证据即拒绝；调用方保留原件和失败报告。"""
    if not condition:
        raise ValueError(message)


def sha(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as source:
        for data in iter(lambda: source.read(1024 * 1024), b''):
            result.update(data)
    return result.hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'duplicate JSON key: ' + key)
        result[key] = value
    return result


def parse_json(text):
    return json.loads(text, object_pairs_hook=unique_object,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError('non-finite JSON: ' + value)))


class Evidence:
    """只接受证据根内普通文件并记录实际SHA；限制文本大小，拒绝symlink和跨根路径。"""
    def __init__(self, root):
        self.root = Path(root).resolve(strict=True)
        self.files = {}

    def data(self, relative, limit=16 * 1024 * 1024):
        path = self.root / relative
        require(not Path(relative).is_absolute() and '..' not in Path(relative).parts, 'invalid evidence member')
        current = path
        while current != self.root:
            require(not current.is_symlink(), 'symlink evidence member: ' + relative)
            current = current.parent
        require(path.is_file() and path.stat().st_size <= limit, 'missing/oversized evidence: ' + relative)
        require(path.resolve(strict=True).is_relative_to(self.root), 'evidence path escapes root: ' + relative)
        data = path.read_bytes()
        self.files[relative] = hashlib.sha256(data).hexdigest()
        return data

    def text(self, relative, limit=16 * 1024 * 1024):
        return self.data(relative, limit).decode('utf-8-sig')

    def json(self, relative):
        value = parse_json(self.text(relative, 1024 * 1024))
        require(isinstance(value, dict), 'JSON object required: ' + relative)
        return value


def properties(data):
    """实现Properties.store所用的ISO-8859-1/反斜线语法，支持续行和Unicode，不默默覆盖重复身份键。"""
    lines = data.decode('iso-8859-1').splitlines()
    logical = []
    pending = ''
    for line in lines:
        line = line.lstrip(' \t\f') if pending else line
        pending += line
        backslashes = len(pending) - len(pending.rstrip('\\'))
        if backslashes % 2:
            pending = pending[:-1]
            continue
        logical.append(pending)
        pending = ''
    require(not pending, 'unfinished Properties continuation')

    def unescape(value):
        result = ''
        offset = 0
        while offset < len(value):
            char = value[offset]
            offset += 1
            if char != '\\':
                result += char
                continue
            require(offset < len(value), 'unfinished Properties escape')
            char = value[offset]
            offset += 1
            if char == 'u':
                digits = value[offset:offset + 4]
                require(len(digits) == 4 and re.fullmatch(r'[0-9a-fA-F]{4}', digits), 'invalid Properties unicode')
                result += chr(int(digits, 16))
                offset += 4
            else:
                result += {'t': '\t', 'n': '\n', 'r': '\r', 'f': '\f'}.get(char, char)
        return result.encode('utf-16', 'surrogatepass').decode('utf-16')

    result = {}
    for line in logical:
        line = line.lstrip(' \t\f')
        if not line or line[0] in '#!':
            continue
        end = 0
        escaped = False
        while end < len(line):
            char = line[end]
            if not escaped and char in '=:\t\f ':
                break
            escaped = char == '\\' and not escaped
            end += 1
        start = end
        while start < len(line) and line[start] in ' \t\f':
            start += 1
        if start < len(line) and line[start] in '=:':
            start += 1
        while start < len(line) and line[start] in ' \t\f':
            start += 1
        key, value = unescape(line[:end]), unescape(line[start:])
        require(key not in result, 'duplicate Properties key: ' + key)
        result[key] = value
    return result


def rows(text):
    """JSONL不得忽略损坏行或尾部垃圾，防止丢失某个失败记录后仍找到成功字段。"""
    values = [parse_json(line) for line in text.splitlines() if line.strip()]
    require(all(isinstance(value, dict) for value in values), 'non-object stage')
    return values


def one(values, stage, role=None):
    selected = [value for value in values if value.get('stage') == stage and (role is None or value.get('role') == role)]
    require(len(selected) == 1, 'expected one stage ' + stage + ('/' + role if role else ''))
    return selected[0]


def integer(value, label, minimum=0):
    require(type(value) is int and minimum <= value <= 2 ** 63 - 1, 'invalid integer ' + label)
    return value


def decimal(value, label, minimum=0):
    require(type(value) is str and re.fullmatch(r'0|[1-9][0-9]*', value), 'noncanonical decimal ' + label)
    return integer(int(value), label, minimum)


def instant(value):
    require(type(value) is str, 'timestamp must be a string')
    parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    require(parsed.tzinfo is not None, 'timestamp lacks timezone')
    return parsed


def freezer_state(text):
    """区分当前设备已观察到的v1 freezer根组与Thawed/Frozen组，其他形状准确保持未知。

    Linux cgroup-v1规定根组不可冻结且没有freezer.state。不能将合法的freezer:/
    错判成冻结，也不能仅见路径含Thawed字样就放行。多条控制器记录仍拒绝。
    官方依据：https://docs.kernel.org/admin-guide/cgroup-v1/freezer-subsystem.html
    """
    paths = re.findall(r'^\d+:freezer:(/[^\r\n]*)\r?$', text, re.MULTILINE)
    if paths == ['/']:
        return 'RootNonFreezable'
    if paths == ['/Thawed']:
        return 'Thawed'
    if paths == ['/Frozen']:
        return 'Frozen'
    return 'UNKNOWN'


def check_props(props, major, nonce, role, pid, target, jar, native_root, java_root, passed):
    expected = {'schema': 'AMCL_NATIVE_TEMP_PAIR_V1', 'role': role, 'major': major,
                'nonce': nonce, 'pid': str(pid), 'targetPid': str(target), 'fixtureJarSha256': jar,
                'nativeTmpdir': native_root, 'environmentTMPDIR': native_root, 'javaTmpdir': java_root,
                'UsePerfData': 'true', 'PerfDisableSharedMem': 'false', 'DisableAttachMechanism': 'false',
                'passed': passed}
    for key, value in expected.items():
        require(props.get(key) == value, 'Properties identity/flag mismatch: ' + role + '/' + key)
    require(not any(key in props for key in ('error', 'discovery.error', 'discovery.hostError')), 'Java protocol error properties present')
    path = props.get('selfPerf.path', '')
    require(re.fullmatch(re.escape(native_root) + r'/hsperfdata_[^/\\\x00\r\n]+/' + str(pid), path), 'self PerfData exact path mismatch')
    require(props.get('selfPerf.magic') in ('cafec0c0', 'c0c0feca'), 'PerfData magic missing')
    size = decimal(props.get('selfPerf.bytes'), role + '/selfPerf.bytes', 32)
    require(size <= 16 * 1024 * 1024, 'oversized PerfData file')


def check_artifacts(hap, archive, jar, hap_sha, archive_sha, jar_sha):
    """供driver的任何设备动作前及最终验收复用；只核实际字节，不读取报告里的预期身份。"""
    require(all(HEX.fullmatch(value) for value in (hap_sha, archive_sha, jar_sha)), 'invalid expected SHA')
    require(sha(hap) == hap_sha and sha(archive) == archive_sha and sha(jar) == jar_sha, 'actual HAP/archive/JAR digest mismatch')
    payload = Path(jar).read_bytes()
    require(0 < len(payload) <= 16 * 1024 * 1024, 'invalid fixture size')
    with zipfile.ZipFile(hap) as package:
        members = [info for info in package.infolist() if info.filename.endswith('/libentry.so')]
        require(len(members) == 1 and members[0].file_size <= 256 * 1024 * 1024, 'unique bounded libentry payload required')
        require(package.read(members[0]).count(payload) == 1, 'expected JAR is not exact embedded HAP fixture')


def verify_pair(evidence, deployment, hap, archive, jar, *, device, major, nonce, native_root, java_root, hap_sha, archive_sha, jar_sha):
    """预期身份全部来自调用参数/实际产物；回读报告不能决定自己的预期SHA。"""
    require(major in ('8', '17', '21', '25') and re.fullmatch(r'[a-z0-9-]{1,32}', nonce), 'invalid fixed major/nonce')
    check_artifacts(hap, archive, jar, hap_sha, archive_sha, jar_sha)
    deploy = parse_json(Path(deployment).read_text(encoding='utf-8-sig'))
    require(deploy.get('installed') is True and deploy.get('preserveData') is True and
            deploy.get('exitCode') == 0 and deploy.get('hapSha256') == hap_sha and deploy.get('device') == device,
            'deployment identity/success mismatch')
    ev = Evidence(evidence)
    transfer = ev.json('transfer.json')
    for key, value in {'protocol': 'AMCL_NATIVE_TEMP_PAIR_TRANSFER_V1', 'profile': 'native-temp-vms',
                       'device': device, 'major': major, 'nonce': nonce, 'hapSha256': hap_sha,
                       'archiveSha256': archive_sha, 'jarSha256': jar_sha, 'expectedNativeRoot': native_root, 'expectedJavaRoot': java_root,
                       'deploymentSha256': sha(deployment)}.items():
        require(transfer.get(key) == value, 'transfer mismatch: ' + key)
    for key in ('parentReportReceived', 'ownerReportReceived', 'pairDirectoryReceived', 'freshNonceObserved'):
        require(transfer.get(key) is True, 'transfer incomplete: ' + key)
    power=transfer.get('powerPreflight',{})
    power_text=ev.text('power-preflight.txt',65536)
    power_state=re.findall(r'Current State:\s*([A-Z_]+)',power_text)
    overrides=re.findall(r'OverrideTimeout\s*=\s*([0-9]+)ms',power_text)
    require(power.get('state')=='AWAKE' and power.get('overrideTimeoutMillis')!=10000 and
            power_state==['AWAKE'] and len(overrides)<=1 and power.get('overrideTimeoutMillis')==(int(overrides[0]) if overrides else None) and
            power.get('sha256')==hashlib.sha256(ev.data('power-preflight.txt',65536)).hexdigest(), 'power preflight absent/mismatched')
    require(instant(deploy['finishedAt']) <= instant(transfer['launchedAt']) <= instant(transfer['finishedAt']), 'deployment/launch/finish order mismatch')
    parent = ev.json('parent-result.json')
    require(parent.get('nonce') == nonce and parent.get('transportOk') is True and parent.get('error') is None, 'parent transport/nonce mismatch')
    integer(parent.get('startedAt'), 'parent start', 1)
    require(integer(parent.get('finishedAt'), 'parent finish', 1) >= parent['startedAt'], 'parent time order')
    run = 'run-native-temp-vms/'
    parent_text = ev.text(run + 'parent-report.txt', 65536)
    require(parent.get('text') == parent_text, 'ArkTS and native parent reports differ')
    stages = rows(parent_text)
    require(len(stages) == 6, 'unexpected/missing parent stages')
    require([row.get('stage') for row in stages] == ['native-temp-pair-parent', 'pair-child-start', 'pair-child-start',
            'pair-parent-finished', 'pair-pipe', 'pair-pipe'] and stages[1].get('role') == stages[4].get('role') == 'target' and
            stages[2].get('role') == stages[5].get('role') == 'client', 'parent stage order mismatch')
    head = one(stages, 'native-temp-pair-parent')
    require(head.get('major') == major and head.get('fixtureSha256') == jar_sha, 'parent fixture/major identity')
    parent_pid = integer(head.get('pid'), 'parent pid', 1)
    freezer=transfer.get('parentFreezer',{})
    observed_freezer=freezer_state(ev.text('parent-cgroup-after.txt',65536))
    require(freezer.get('pid')==parent_pid and freezer.get('state')==observed_freezer and
            observed_freezer in ('Thawed', 'RootNonFreezable') and
            freezer.get('sha256')==hashlib.sha256(ev.data('parent-cgroup-after.txt',65536)).hexdigest(), 'parent freezer evidence absent/Frozen/unknown')
    started = [one(stages, 'pair-child-start', role) for role in ('target', 'client')]
    pids = [integer(item.get('pid'), 'child pid', 1) for item in started]
    require(len(set(pids + [parent_pid])) == 3, 'parent and two children must have distinct real PIDs')
    for item, pid in zip(started, pids):
        require(type(item.get('result')) is int and item['result'] == 0 and type(item.get('sdkResult')) is int and item['sdkResult'] == 0 and item.get('reportedPid') == pid and
                item.get('poisonedStart') is False, 'SDK child start did not produce owned identity')
    finished = one(stages, 'pair-parent-finished')
    require(finished.get('targetPid') == pids[0] and finished.get('clientPid') == pids[1], 'finished child identity mismatch')
    for key in ('targetExitObserved', 'clientExitObserved', 'postExitFilesAbsent'):
        require(finished.get(key) is True, 'missing real exit/file cleanup: ' + key)
    for key in ('timedOut', 'cleanupIncomplete', 'poisonedStart', 'earlyEventOverflow', 'restartRequiredIfExitMissing', 'environmentClosed'):
        require(finished.get(key) is False, 'failed/unknown parent state: ' + key)
    require(finished.get('targetCallbackSignal') == 0 and finished.get('clientCallbackSignal') == 0 and
            finished.get('error') == '' and 'osExitStatus' in finished and finished['osExitStatus'] is None, 'exit/error contract mismatch')
    owner = ev.json(run + 'owner-reclaimed.json')
    require(owner.get('schema') == 1 and owner.get('stage') == 'pair-owner-reclaimed' and
            owner.get('targetPid') == pids[0] and owner.get('clientPid') == pids[1], 'owner identity mismatch')
    require(all(owner.get(key) is True for key in ('targetExitObserved', 'clientExitObserved')), 'owner missing real exit')
    require(all(owner.get(key) is False for key in ('lateCleanup', 'environmentClosed', 'restartRequired')) and
            owner.get('unregisterResult') == 0 and owner.get('reclaimExecutor') == 'napi-loop', 'owner cleanup not normal and complete')
    require(not (ev.root / run / 'owner-cleanup-failed.json').exists(), 'native cleanup failure record present')
    require(ev.text(run + 'installed-sha256.txt', 66) == archive_sha + '\n', 'shared installed slot seal mismatch')
    ready = properties(ev.data(run + 'target-ready.properties', 65536))
    require(native_root.startswith('/') and native_root != '/tmp' and '\\' not in native_root and
            str(PurePosixPath(native_root)) == native_root and '..' not in PurePosixPath(native_root).parts,
            'not a canonical app-private native root')
    require(java_root.startswith('/') and str(PurePosixPath(java_root)) == java_root and '..' not in PurePosixPath(java_root).parts,
            'invalid independently expected Java temporary root')
    # 宿主显式-Djava.io.tmpdir保留自己的文件语义，不能强迫它等于native跨VM会合根。
    check_props(ready, major, nonce, 'target', pids[0], pids[0], jar_sha, native_root, java_root, 'false')
    role_properties = []
    total_bytes = 0
    for role, pid in zip(('target', 'client'), pids):
        prefix = run + role + '/'
        require(hashlib.sha256(ev.data(prefix + 'qualification.jar')).hexdigest() == jar_sha, 'actual role JAR mismatch: ' + role)
        native = ev.json(prefix + 'result.json')
        require(native.get('schema') == 1 and native.get('profile') == 'native-temp-vms' and native.get('role') == role and
                native.get('major') == major and native.get('pid') == pid and native.get('archiveSha256') == archive_sha and
                native.get('fixtureSha256') == jar_sha and native.get('installedHere') is (role == 'target'), 'native role identity mismatch: ' + role)
        require(native.get('passed') is True and native.get('completionProof') is True and native.get('error') == '' and
                all(type(native.get(key)) is int and native[key] == 0 for key in ('initResult', 'mainResult', 'destroyResult')), 'native VM lifecycle failed: ' + role)
        pipe = ev.data(prefix + 'parent-pipe.txt', 128 * 1024)
        pipe_summary = one(stages, 'pair-pipe', role)
        require(pipe_summary.get('bytes') == len(pipe) and pipe_summary.get('retainedBytes') == len(pipe) and
                pipe_summary.get('sha256') == hashlib.sha256(pipe).hexdigest(), 'pipe truncated/tampered: ' + role)
        total_bytes += len(pipe)
        native_log = ev.data(prefix + 'native-stages.jsonl', 128 * 1024)
        require(native_log == pipe, 'pipe/file stage mismatch: ' + role)
        child_stages = rows(native_log.decode('utf-8'))
        require(one(child_stages, 'pair-child', role).get('pid') == pid and
                one(child_stages, 'pair-java-main-return', role).get('result') == 0, 'child stages incomplete: ' + role)
        require([value for value in child_stages if value.get('profile') == 'native-temp-vms'] == [native], 'child result differs from native stages')
        require(sum(value.get('stage') == 'pair-java-main' for value in child_stages) == 1, 'missing/duplicate actual main stage')
        sequence = [value.get('stage') for value in child_stages]
        require(sequence[0] == 'pair-child' and sequence.index('pair-java-main') < sequence.index('pair-java-main-return') == len(sequence) - 2,
                'child main/return/completion order mismatch')
        installed = [value for value in child_stages if value.get('stage') == 'install-complete']
        require(installed == ([{'stage': 'install-complete', 'archiveSha256': archive_sha}] if role == 'target' else []), 'target/client install ownership mismatch')
        props = properties(ev.data(prefix + 'java-result.properties', 65536))
        check_props(props, major, nonce, role, pid, pids[0], jar_sha, native_root, java_root, 'true')
        role_properties.append(props)
        for name in ('main-completed.txt', 'main-ended.txt', 'worker.txt', 'shutdown.txt'):
            require(ev.data(prefix + name, 128) == (nonce + '\n').encode(), 'completion marker mismatch: ' + role + '/' + name)
        log = ev.text(prefix + 'stdout.log')
        require(not any(word in log for word in ('WARNING in native method', 'FATAL ERROR in native method', '# A fatal error has been detected', 'java.lang.AssertionError')),
                'CheckJNI/VM failure in stdout: ' + role)
        require(not list((ev.root / prefix).glob('hs_err*.log')), 'VM crash report present: ' + role)
    require(finished.get('reportBytes') == total_bytes, 'parent total pipe bytes mismatch')
    target, client = role_properties
    require(all(target.get(key) == value for key, value in ready.items() if key != 'passed'), 'target readiness identity changed')
    require(decimal(target.get('completedProgress'), 'target progress', 2) >= decimal(client.get('perf.last'), 'last shared counter', 1) >
            decimal(client.get('perf.first'), 'first shared counter', 1), 'shared counter did not advance within target lifetime')
    for key in ('attach.propertiesVerified', 'attach.detached', 'perf.bodyVerified', 'perf.detachRequested', 'discovery.targetListed'):
        require(client.get(key) == 'true', 'missing Attach/shared/discovery proof: ' + key)
    require(decimal(client.get('discovery.vmCount'), 'discovered VMs', 1) >= 1 and
            client.get('discovery.defaultNativeRoot') == native_root and client.get('targetPerf.path') == ready['selfPerf.path'] and
            client.get('targetPerf.bytes') == ready['selfPerf.bytes'] and client.get('targetPerf.magic') == ready['selfPerf.magic'],
            'standard discovery or shared target file identity mismatch')
    inventory = ev.json('readback-inventory.json')
    require(inventory.get('protocol') == 'AMCL_NATIVE_TEMP_PAIR_READBACK_V1', 'readback inventory protocol')
    expected_members = {key: value for key, value in ev.files.items() if key not in ('transfer.json', 'readback-inventory.json','power-preflight.txt','parent-cgroup-after.txt')}
    require(inventory.get('files') == expected_members, 'readback file inventory missing/changed/unexpected members')
    return {'protocol': 'AMCL_NATIVE_TEMP_PAIR_VERIFICATION_V1', 'pairQualified': True, 'device': device,
            'major': major, 'nonce': nonce, 'hapSha256': hap_sha, 'archiveSha256': archive_sha, 'jarSha256': jar_sha,
            'targetPid': pids[0], 'clientPid': pids[1], 'nativeTmpdir': native_root, 'javaTmpdir': java_root,
            'attachReadOnlyQualified': True, 'sharedPerfDataQualified': True, 'standardDiscoveryQualified': True,
            'realExitObserved': True, 'osExitStatus': None, 'cliQualified': False, 'jliQualified': False,
            'files': ev.files, 'verifiedAt': datetime.now().astimezone().isoformat()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('evidence', 'deployment', 'hap', 'archive', 'jar', 'report'):
        parser.add_argument('--' + name, type=Path, required=True)
    for name in ('device', 'major', 'nonce', 'expected-native-root', 'expected-java-root', 'expected-hap-sha256', 'expected-archive-sha256', 'expected-jar-sha256'):
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    try:
        result = verify_pair(args.evidence, args.deployment, args.hap, args.archive, args.jar, device=args.device,
            major=args.major, nonce=args.nonce, native_root=args.expected_native_root, java_root=args.expected_java_root, hap_sha=args.expected_hap_sha256, archive_sha=args.expected_archive_sha256, jar_sha=args.expected_jar_sha256)
    except (OSError, ValueError, TypeError, KeyError, zipfile.BadZipFile) as failure:
        result = {'protocol': 'AMCL_NATIVE_TEMP_PAIR_VERIFICATION_V1', 'pairQualified': False,
                  'error': str(failure), 'verifiedAt': datetime.now().astimezone().isoformat()}
    with args.report.open('x', encoding='utf-8') as output:
        json.dump(result, output, ensure_ascii=False, indent=2)
        output.write('\n')
    print(json.dumps({key: value for key, value in result.items() if key != 'files'}, ensure_ascii=False))
    return 0 if result['pairQualified'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
