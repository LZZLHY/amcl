"""共享工具证据的独立准入：固定模式、同主PID、正常VM关闭和外部进程回收分别核验。

不创建目标进程、不改原件，也不把HDC force-stop记成JVM正常退出或NCP退出码。
通用HAP/JAR/archive、CheckJNI、基础功能门仍由verify-device.py执行。
"""
import hashlib
import json
import re
from pathlib import Path


def verify_shared(directory, transfer, parent, native, problems):
    """失败统一追加到原验证器的问题列表；文件缺失/非法JSON一律拒绝资格。"""
    directory = Path(directory)
    read = lambda path: json.loads(path.read_text(encoding='utf-8-sig'))
    mode = 'shared-tool'
    profile = transfer.get('profile')
    major = transfer.get('major')
    nonce = transfer.get('nonce')
    run = directory / ('run-' + str(major))
    process_qualified = False
    extended_qualified = None
    try:
        if profile not in ('shared-basic', 'shared-extended') or major not in ('8', '17', '21', '25'):
            raise ValueError('only fixed shared-basic/shared-extended majors are allowed')
        if not isinstance(nonce, str) or re.fullmatch(r'[a-z0-9-]{1,40}', nonce) is None:
            raise ValueError('invalid shared nonce')
        if transfer.get('executionMode') != mode or native.get('executionMode') != mode:
            raise ValueError('shared execution mode is not explicit in both identities')
        if transfer.get('parentReportReceived') is not True or parent.get('transportOk') is not True:
            raise ValueError('shared report transport is incomplete')
        if native.get('profile') != profile[7:] or parent.get('nonce') != nonce:
            raise ValueError('shared profile/nonce identity mismatch')
        pid = native.get('pid')
        if type(pid) is not int or pid <= 0 or transfer.get('mainPid') != pid:
            raise ValueError('shared VM is not the observed application main PID')
        identity = transfer.get('mainProcess', {})
        if identity.get('pid') != pid or not isinstance(identity.get('startTicks'), str) or not identity['startTicks'].isdigit():
            raise ValueError('external main process start identity is missing')
        entered = read(run / 'shared-process.json')
        expected = {'executionMode': mode, 'pid': pid, 'major': major, 'profile': profile[7:], 'nonce': nonce,
                    'fixtureSha256': native.get('fixtureSha256'), 'restartRequired': True, 'externalSupervisorRequired': True}
        if any(type(entered.get(key)) is not type(value) or entered.get(key) != value for key, value in expected.items()):
            raise ValueError('native shared entry identity differs from the external observed process')
        if any(native.get(key) is not True for key in ('installComplete', 'passed', 'completionProof', 'stdioRestored')):
            raise ValueError('shared installation/lifecycle/stdio completion is not positive')
        if any(type(native.get(key)) is not int or native[key] != 0 for key in ('initResult', 'mainResult', 'destroyResult')):
            raise ValueError('shared lifecycle return codes must be explicit numeric zero')
        if native.get('runtimeState') != 3 or native.get('javaVmPresent') is not False:
            raise ValueError('shared RuntimeOnce was not retired with the VM released')
        lines = parent.get('text', '').splitlines()
        returned = [json.loads(line[len('nativeReceipt='):]) for line in lines if line.startswith('nativeReceipt=')]
        if returned != [native]:
            raise ValueError('returned shared native receipt differs from persisted bytes')
        events = [json.loads(line) for line in lines if line.startswith('{')]
        done = [item for item in events if item.get('stage') == 'shared-process-complete']
        if len(done) != 1 or done[0].get('pid') != pid or done[0].get('executionMode') != mode or \
                done[0].get('processExitObserved') is not False or done[0].get('restartRequired') is not True:
            raise ValueError('shared completion incorrectly claims a process exit or lacks identity')
        if any(str(item.get('stage', '')).startswith('native-child') for item in events):
            raise ValueError('shared parent report contains a fabricated native-child event')
        # Report::line统一追加LF，最终receipt自身也带LF，所以真实报告末尾含空记录。
        # 只跳过纯空白；所有非空记录仍须为JSON对象，缺失/重复的必需阶段继续由下方拒绝。
        stages = []
        for line in (run / 'native-stages.jsonl').read_text(encoding='utf-8').splitlines():
            if not line.strip():
                continue
            item = json.loads(line)
            if not isinstance(item, dict):
                raise ValueError('shared native stage record must be a JSON object')
            stages.append(item)
        order = []
        for name in ('shared-worker', 'jvm-init-return', 'java-main-return', 'destroy-java-vm-return'):
            found = [(index, item) for index, item in enumerate(stages) if item.get('stage') == name]
            if len(found) != 1:
                raise ValueError('missing/duplicate shared native stage: ' + name)
            index, item = found[0]
            order.append(index)
            if name == 'shared-worker':
                if item.get('pid') != pid or item.get('executionMode') != mode or item.get('runtimeState') != 0:
                    raise ValueError('shared worker was not Fresh in the observed main PID')
            elif type(item.get('result')) is not int or item['result'] != 0:
                raise ValueError('shared native lifecycle stage failed: ' + name)
        if order != sorted(order) or any(item.get('stage') == 'child' for item in stages):
            raise ValueError('shared lifecycle order or process mode is invalid')
        token = 'AMCL-JAVA-QUALIFICATION:1:' + major + '\n'
        for name in ('fixture-pass.txt', 'main-thread-ended.txt', 'non-daemon.txt', 'shutdown-hook.txt'):
            if (run / name).read_text(encoding='utf-8') != token:
                raise ValueError('shared completion marker mismatch: ' + name)
        if profile == 'shared-extended':
            extended = read(run / 'extended-runtime/result.json')
            required = {'compiler-utf8-load', 'jar-create-load', 'javadoc', 'keytool-and-certificates',
                'process-builder-fixed-command', 'tcp-ipv4', 'tcp-ipv6', 'TLSv1.2-verified', 'TLSv1.3-verified',
                'tls-ipv6-verified', 'tls-wrong-certificate-rejected', 'tls-wrong-hostname-rejected', 'jfr-record-read'}
            cases = extended.get('cases', [])
            names = [row.get('name') for row in cases]
            if extended.get('major') != major or extended.get('passed') is not True or \
                    type(native.get('specialtyResult')) is not int or native.get('specialtyResult') != 0 or \
                    len(names) != len(set(names)) or not required.issubset(names):
                raise ValueError('shared extended report/required cases incomplete')
            if any(row.get('status') != 'PASS' for row in cases if row.get('required') is True or row.get('name') in required):
                raise ValueError('shared extended required case did not pass')
            extended_qualified = True
        supervisor = read(directory / 'supervisor.json')
        expected = {'protocol': 'AMCL_SHARED_QUALIFICATION_SUPERVISOR_V1', 'executionMode': mode,
                    'nonce': nonce, 'device': transfer.get('device'), 'pid': pid, 'deadlineMillis': 200000,
                    'timedOut': False, 'resultReceivedBeforeStop': True, 'processReclaimed': True}
        if not isinstance(expected['device'], str) or not expected['device'] or any(
                type(supervisor.get(key)) is not type(value) or supervisor.get(key) != value for key, value in expected.items()):
            raise ValueError('shared external supervisor identity/deadline/reclaim failed')
        if transfer.get('timedOut') is not False or transfer.get('resultReceivedBeforeStop') is not True or \
                transfer.get('processReaped') is not True or transfer.get('externalStopRequested') is not True:
            raise ValueError('shared transfer does not independently confirm controlled external cleanup')
        # 仅解析固定文件名的真实pidof正文。哈希来自宿主监督记录，空快照须完全不含错误文本。
        observations = {'shared-before-start-pids.txt': [], 'shared-after-start-pids.txt': [pid],
                        'shared-before-stop-pids.txt': [pid], 'shared-after-stop-pids.txt': []}
        for name, wanted in observations.items():
            path = directory / name
            text = path.read_text(encoding='utf-8-sig')
            if hashlib.sha256(path.read_bytes()).hexdigest() != supervisor.get('logSha256', {}).get(name):
                raise ValueError('shared raw PID observation hash mismatch: ' + name)
            if re.fullmatch(r'\s*(?:[0-9]+\s*)*', text) is None or [int(value) for value in text.split()] != wanted:
                raise ValueError('shared raw PID observation mismatch: ' + name)
        process_qualified = True
    except (ValueError, KeyError, TypeError, OSError) as error:
        problems.append('shared qualification failed: ' + str(error))
    return {'executionMode': mode, 'externalProcessReclaimQualified': process_qualified,
            'extendedFixtureQualified': extended_qualified, 'nativeChildExitQualified': False,
            'scope': 'one shared tool VM and separately observed external app cleanup; no native-child, pair or game qualification'}
