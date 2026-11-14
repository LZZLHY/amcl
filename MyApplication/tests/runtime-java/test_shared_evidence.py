"""以固定合成报告验证真实shared验收器的拒绝能力；结果不是真机或JDK资格。

新建外置--output并逐案保留输入/报告，覆盖模式、PID、时间监督、销毁标记与扩展功能缺项。
"""
from pathlib import Path
from datetime import datetime
import argparse
import hashlib
import importlib.util
import json
import shutil


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    if output == root or root in output.parents:
        parser.error('output must be outside the source tree')
    output.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location('shared_verifier_under_test', Path(__file__).with_name('verify-device.py'))
    verifier = importlib.util.module_from_spec(spec); spec.loader.exec_module(verifier)
    sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    write = lambda path, value: path.write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')
    read = lambda path: json.loads(path.read_text(encoding='utf-8'))
    base = output / 'base'; base.mkdir()
    run = base / 'run-21'; run.mkdir()
    archive = base / 'runtime.zip'; archive.write_bytes(b'synthetic archive; never loaded')
    jar = run / 'qualification.jar'; jar.write_bytes(b'synthetic jar; never loaded')
    hap = 'a' * 64; jar_sha = sha(jar); archive_sha = sha(archive)
    native = {'schema': 1, 'executionMode': 'shared-tool', 'major': '21', 'pid': 1234, 'profile': 'basic',
        'archiveSha256': archive_sha, 'fixtureSha256': jar_sha, 'installComplete': True,
        'initResult': 0, 'mainResult': 0, 'destroyResult': 0, 'completionProof': True, 'passed': True,
        'stdioRestored': True, 'runtimeState': 3, 'javaVmPresent': False, 'specialtyResult': -999}
    write(run / 'result.json', native)
    write(run / 'shared-process.json', {'executionMode': 'shared-tool', 'pid': 1234, 'major': '21',
        'profile': 'basic', 'nonce': 'synthetic', 'fixtureSha256': jar_sha, 'restartRequired': True,
        'externalSupervisorRequired': True})
    write(base / 'transfer.json', {'profile': 'shared-basic', 'executionMode': 'shared-tool', 'major': '21',
        'nonce': 'synthetic', 'device': 'synthetic-device', 'parentReportReceived': True, 'hapSha256': hap,
        'archiveSha256': archive_sha, 'candidate': str(archive), 'mainPid': 1234,
        'mainProcess': {'pid': 1234, 'startTicks': '123456'}, 'timedOut': False,
        'resultReceivedBeforeStop': True, 'processReaped': True, 'externalStopRequested': True})
    done = {'stage': 'shared-process-complete', 'pid': 1234, 'executionMode': 'shared-tool',
            'processExitObserved': False, 'restartRequired': True}
    write(base / 'parent-result.json', {'nonce': 'synthetic', 'transportOk': True,
        'text': json.dumps(done) + '\n' + 'nativeReceipt=' + json.dumps(native) + '\n'})
    stages = [{'stage': 'shared-worker', 'pid': 1234, 'executionMode': 'shared-tool', 'runtimeState': 0}] + [
        {'stage': name, 'result': 0} for name in ('jvm-init-return', 'java-main-return', 'destroy-java-vm-return')]
    (run / 'native-stages.jsonl').write_text(''.join(json.dumps(item) + '\n' for item in stages), encoding='utf-8')
    for name in ('fixture-pass.txt', 'main-thread-ended.txt', 'non-daemon.txt', 'shutdown-hook.txt'):
        (run / name).write_text('AMCL-JAVA-QUALIFICATION:1:21\n', encoding='utf-8')
    (run / 'stdout.log').write_text('123 42 4 RuntimeQualification::hotLoop (52 bytes)\n', encoding='utf-8')
    (run / 'fixture-results.txt').write_text('mainThreadJoinRequired=true\nlogicalFontFacesChecked=20\nfontFallbackMissingGlyphs=0\nfontFallbackGlyphComparisons=4\npngRoundtripPixels=17920\n', encoding='utf-8')
    names = ('shared-before-start-pids.txt', 'shared-after-start-pids.txt', 'shared-before-stop-pids.txt', 'shared-after-stop-pids.txt')
    for name, text in zip(names, ('', '1234\n', '1234\n', '')):
        (base / name).write_text(text, encoding='utf-8')
    write(base / 'supervisor.json', {'protocol': 'AMCL_SHARED_QUALIFICATION_SUPERVISOR_V1', 'executionMode': 'shared-tool',
        'nonce': 'synthetic', 'device': 'synthetic-device', 'pid': 1234, 'deadlineMillis': 200000,
        'timedOut': False, 'resultReceivedBeforeStop': True, 'processReclaimed': True,
        'logSha256': {name: sha(base / name) for name in names}})

    def field(directory, relative, key, value):
        data = read(directory / relative); data[key] = value; write(directory / relative, data)

    def extended(directory, omit=False):
        """构造一个独立扩展样本，所有身份仍绑定同一主PID和同一次生命周期。"""
        field(directory, 'transfer.json', 'profile', 'shared-extended')
        field(directory, 'run-21/shared-process.json', 'profile', 'extended')
        data = read(directory / 'run-21/result.json'); data['profile'] = 'extended'; data['specialtyResult'] = 0
        write(directory / 'run-21/result.json', data)
        parent = read(directory / 'parent-result.json'); parent['text'] = json.dumps(done) + '\nnativeReceipt=' + json.dumps(data) + '\n'
        write(directory / 'parent-result.json', parent)
        target = directory / 'run-21/extended-runtime'; target.mkdir()
        required = ['compiler-utf8-load', 'jar-create-load', 'javadoc', 'keytool-and-certificates',
            'process-builder-fixed-command', 'tcp-ipv4', 'tcp-ipv6', 'TLSv1.2-verified', 'TLSv1.3-verified',
            'tls-ipv6-verified', 'tls-wrong-certificate-rejected', 'tls-wrong-hostname-rejected', 'jfr-record-read']
        if omit: required.pop()
        write(target / 'result.json', {'major': '21', 'passed': True,
            'cases': [{'name': name, 'required': True, 'status': 'PASS'} for name in required]})

    def parent_event(directory, item):
        """改变真实验收器读取的父阶段正文，不能让合成NCP成功替代共享进程合同。"""
        data = read(directory / 'parent-result.json')
        data['text'] += json.dumps(item) + '\n'
        write(directory / 'parent-result.json', data)

    def wrong_pid_observation(directory):
        """即使同步重算日志哈希，日志正文里仍存活的PID也必须拒绝回收资格。"""
        path = directory / 'shared-after-stop-pids.txt'; path.write_text('1234\n', encoding='utf-8')
        data = read(directory / 'supervisor.json'); data['logSha256'][path.name] = sha(path)
        write(directory / 'supervisor.json', data)

    def production_stage_shape(directory, variant='normal'):
        """复现真实Report::line(receipt)形态：receipt已有LF，写阶段日志时再次追加LF。
        正常最终收据无stage键；空白可跳过，非JSON/非对象以及阶段缺失/重复仍须拒绝。
        """
        selected = stages[:-1] if variant == 'missing' else stages + ([stages[-1]] if variant == 'duplicate' else [])
        text = ''.join(json.dumps(item) + '\n' for item in selected)
        text += json.dumps(read(directory / 'run-21/result.json')) + '\n\n'
        if variant == 'whitespace': text = ' \t\n' + text.replace('\n', '\n \t\n')
        elif variant == 'garbage': text += 'not-json\n\n'
        elif variant == 'scalar': text += 'null\n\n'
        elif variant == 'empty': text = '\n \t\n'
        (directory / 'run-21/native-stages.jsonl').write_text(text, encoding='utf-8')

    cases = [('basic-positive', lambda d: None, True), ('extended-positive', extended, True),
        ('extended-missing-case', lambda d: extended(d, True), False),
        ('mode-missing', lambda d: field(d, 'transfer.json', 'executionMode', None), False),
        ('pair-profile', lambda d: field(d, 'transfer.json', 'profile', 'shared-native-temp-vms'), False),
        ('mic-profile', lambda d: field(d, 'transfer.json', 'profile', 'shared-sound-capture'), False),
        ('main-pid-mismatch', lambda d: field(d, 'transfer.json', 'mainPid', 4321), False),
        ('retired-state-missing', lambda d: field(d, 'run-21/result.json', 'runtimeState', 0), False),
        ('still-live-vm', lambda d: field(d, 'run-21/result.json', 'javaVmPresent', True), False),
        ('missing-main-join', lambda d: (d / 'run-21/main-thread-ended.txt').unlink(), False),
        ('wrong-hook', lambda d: (d / 'run-21/shutdown-hook.txt').write_text('wrong\n'), False),
        ('destroy-failure', lambda d: field(d, 'run-21/result.json', 'destroyResult', -1), False),
        ('destroy-false-not-code', lambda d: field(d, 'run-21/result.json', 'destroyResult', False), False),
        ('timeout', lambda d: field(d, 'supervisor.json', 'timedOut', True), False),
        ('stop-before-result', lambda d: field(d, 'supervisor.json', 'resultReceivedBeforeStop', False), False),
        ('not-reclaimed', lambda d: field(d, 'supervisor.json', 'processReclaimed', False), False),
        ('pid-log-mutated', lambda d: (d / 'shared-after-stop-pids.txt').write_text('1234\n'), False),
        ('checkjni-warning', lambda d: (d / 'run-21/stdout.log').write_text('WARNING in native method\n'), False),
        ('missing-supervisor', lambda d: (d / 'supervisor.json').unlink(), False)]
    cases += [
        ('fabricated-ncp-start', lambda d: parent_event(d, {'stage': 'native-child-start', 'pid': 1234, 'result': 0}), False),
        ('fabricated-ncp-exit', lambda d: parent_event(d, {'stage': 'native-child-exit', 'observed': True, 'signal': 0}), False),
        ('duplicate-shared-complete', lambda d: parent_event(d, done), False),
        ('rehashed-pid-still-alive', wrong_pid_observation, False),
        ('missing-native-destroy', lambda d: (d / 'run-21/native-stages.jsonl').write_text(
            ''.join(json.dumps(item) + '\n' for item in stages[:-1]), encoding='utf-8'), False)]
    cases += [
        ('production-receipt-double-lf', production_stage_shape, True),
        ('production-whitespace-records', lambda d: production_stage_shape(d, 'whitespace'), True),
        ('production-garbage-after-blanks', lambda d: production_stage_shape(d, 'garbage'), False),
        ('production-non-object-after-blanks', lambda d: production_stage_shape(d, 'scalar'), False),
        ('production-missing-stage-with-blanks', lambda d: production_stage_shape(d, 'missing'), False),
        ('production-duplicate-stage-with-blanks', lambda d: production_stage_shape(d, 'duplicate'), False),
        ('production-only-blank-records', lambda d: production_stage_shape(d, 'empty'), False)]
    rows = []
    for name, mutate, expected in cases:
        directory = output / name; shutil.copytree(base, directory); mutate(directory)
        result = verifier.verify(directory, hap, jar_sha)
        assert result['fixtureQualified'] is expected, (name, result)
        write(directory / 'verification.json', result)
        rows.append({'name': name, 'expectedQualified': expected, 'actualQualified': result['fixtureQualified']})
    write(output / 'receipt.json', {'state': 'PASS', 'recordedAt': datetime.now().astimezone().isoformat(),
        'scope': 'synthetic report verifier regression only; not device or JDK qualification', 'cases': rows})
    print('PASS', len(rows), 'strict shared evidence cases; no device or VM executed')


if __name__ == '__main__':
    main()
