"""固定双NCP/VM设备驱动；显式设备/产物身份/新nonce，无安装、无录音、无普通单VM验收。

Windows本地HDC路径由参数或项目统一工具默认提供；USB与TCP serial走相同-t参数。
每次启动前只用正常power-shell wakeup与EntryAbility前台启动，不更改系统电源/超时设置。
"""
import argparse
from datetime import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import time

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('pair_verifier', HERE / 'verify-vm-pair.py')
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)
BUNDLE = 'com.amcl.launcher'
LOGICAL = './data/storage/el2/base/haps/entry/files'


def now():
    return datetime.now().astimezone().isoformat()


def save(path, value):
    """所有控制/结果只新建，任何失败都不能覆盖此前尝试。"""
    with path.open('x', encoding='utf-8') as output:
        json.dump(value, output, ensure_ascii=False, indent=2)
        output.write('\n')


class Hdc:
    """逐命令保存输出；检查exit code及HDC的[Fail]，不能仅靠0判断传输成功。"""
    def __init__(self, executable, device, output, run=subprocess.run):
        self.executable, self.device, self.output, self.run = str(executable), device, output, run
        self.counter = 0

    def invoke(self, arguments, *, allow_failure=False, timeout=60):
        self.counter += 1
        command = [self.executable, '-t', self.device, *map(str, arguments)]
        started = now()
        try:
            cp = self.run(command, capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired as error:
            save(self.output / ('hdc-%03d.json' % self.counter), {'startedAt':started,'finishedAt':now(),
                'command':command,'exitCode':None,'timedOut':True,'output':((error.stdout or b'')+(error.stderr or b'')).decode('utf-8',errors='replace')})
            raise
        text = (cp.stdout + cp.stderr).decode('utf-8', errors='replace')
        save(self.output / ('hdc-%03d.json' % self.counter), {'startedAt': started, 'finishedAt': now(),
            'command': command, 'exitCode': cp.returncode, 'output': text})
        ok = cp.returncode == 0 and '[Fail]' not in text
        if not allow_failure and not ok:
            raise RuntimeError('HDC command failed; see hdc-%03d.json' % self.counter)
        return ok, text


def inventory_members():
    """精确固定需要验收的回读文件；无任意glob或原始设备目录收集。"""
    result = ['parent-result.json', 'run-native-temp-vms/parent-report.txt',
              'run-native-temp-vms/owner-reclaimed.json', 'run-native-temp-vms/installed-sha256.txt',
              'run-native-temp-vms/target-ready.properties']
    for role in ('target', 'client'):
        for name in ('qualification.jar', 'result.json', 'parent-pipe.txt', 'native-stages.jsonl',
                     'java-result.properties', 'main-completed.txt', 'main-ended.txt', 'worker.txt', 'shutdown.txt', 'stdout.log'):
            result.append('run-native-temp-vms/' + role + '/' + name)
    return result


def validate_inputs(args):
    """任何HDC动作之前核对全部显式身份，避免错误输入也创建/覆盖设备文件。"""
    verify.require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9:._-]{0,127}', args.device), 'explicit USB/TCP serial required')
    verify.require(args.major in ('8', '17', '21', '25') and re.fullmatch(r'[a-z0-9-]{1,32}', args.nonce), 'fixed major/new nonce required')
    verify.require(re.fullmatch(r'/data/app/el2/[0-9]+/base/com\.amcl\.launcher/haps/entry/files', args.device_files_root), 'explicit verified physical app files root required')
    verify.require(re.fullmatch(r'/[A-Za-z0-9_./-]+', args.expected_native_root) and
                   '..' not in args.expected_native_root.split('/') and args.expected_native_root != '/tmp', 'explicit private native root required')
    verify.require(re.fullmatch(r'/[A-Za-z0-9_./-]+', args.expected_java_root) and
                   '..' not in args.expected_java_root.split('/') and args.expected_java_root.endswith('/jdk-runtime-qualification/'+args.nonce),
                   'explicit Java temporary root must match this nonce installation root')
    verify.check_artifacts(args.hap,args.archive,args.jar,args.expected_hap_sha256,args.expected_archive_sha256,args.expected_jar_sha256)
    deployed = verify.parse_json(args.deployment.read_text(encoding='utf-8-sig'))
    verify.require(deployed.get('installed') is True and deployed.get('preserveData') is True and deployed.get('exitCode') == 0 and
                   deployed.get('device') == args.device and deployed.get('hapSha256') == args.expected_hap_sha256,
                   'reviewed deployment does not match this device/HAP')
    verify.instant(deployed['finishedAt'])
    verify.require(not args.output.exists(), 'output already exists; choose a new nonce/output')


def execute(args, *, runner=subprocess.run, sleep=time.sleep, monotonic=time.monotonic):
    """一次launch，不自动重跑；轮询只取自己的两个小回执，最后回读固定pair目录。"""
    validate_inputs(args)
    args.output.mkdir(parents=True, exist_ok=False)
    commands = args.output / 'commands'
    commands.mkdir()
    hdc = Hdc(args.hdc, args.device, commands, runner)
    transfer = {'protocol': 'AMCL_NATIVE_TEMP_PAIR_TRANSFER_V1', 'profile': 'native-temp-vms',
        'startedAt': now(), 'device': args.device, 'major': args.major, 'nonce': args.nonce,
        'hapSha256': args.expected_hap_sha256, 'archiveSha256': args.expected_archive_sha256,
        'jarSha256': args.expected_jar_sha256, 'expectedNativeRoot': args.expected_native_root, 'expectedJavaRoot': args.expected_java_root,
        'deploymentSha256': verify.sha(args.deployment), 'deviceFilesRoot': args.device_files_root,
        'parentReportReceived': False, 'ownerReportReceived': False, 'pairDirectoryReceived': False,
        'freshNonceObserved': False}
    save(args.output / 'request.json', transfer)
    remote = LOGICAL + '/jdk-runtime-qualification/' + args.nonce
    physical = args.device_files_root + '/jdk-runtime-qualification/' + args.nonce
    launched = False
    try:
        # 参数已限定纯路径字符。先证明父根可读/可进入，再严格区分不存在、已存在和无法判断。
        command = ('if [ -e ' + physical + ' ] || [ -L ' + physical + ' ]; then echo AMCL_PAIR_EXISTS; '
            'elif [ -d ' + args.device_files_root + ' ] && [ -r ' + args.device_files_root +
            ' ] && [ -x ' + args.device_files_root + ' ]; then echo AMCL_PAIR_FRESH; else echo AMCL_PAIR_UNKNOWN; fi')
        _, check = hdc.invoke(['shell', command])
        verify.require(check.strip() == 'AMCL_PAIR_FRESH', 'remote nonce exists or cannot establish absence')
        transfer['freshNonceObserved'] = True
        preparation = args.output / 'prepare'
        preparation.mkdir()
        (preparation / 'archive-sha256.txt').write_text(args.expected_archive_sha256 + '\n', encoding='utf-8', newline='\n')
        hdc.invoke(['file', 'send', '-b', BUNDLE, preparation.resolve(), remote])
        hdc.invoke(['file', 'send', '-b', BUNDLE, args.archive.resolve(), remote + '/runtime.zip'], timeout=180)
        hdc.invoke(['shell', 'power-shell wakeup'])
        _, foreground = hdc.invoke(['shell', 'aa', 'start', '-a', 'EntryAbility', '-b', BUNDLE])
        verify.require('start ability successfully' in foreground.lower(), 'foreground start did not confirm success')
        sleep(0.5)
        _, power = hdc.invoke(['shell', 'hidumper -s PowerManagerService -a -s'])
        (args.output / 'power-preflight.txt').write_text(power,encoding='utf-8',newline='\n')
        state = re.search(r'Current State:\s*([A-Z_]+)',power)
        override = re.search(r'OverrideTimeout\s*=\s*([0-9]+)ms',power)
        transfer['powerPreflight'] = {'state': state.group(1) if state else 'UNKNOWN',
            'overrideTimeoutMillis': int(override.group(1)) if override else None, 'sha256': verify.sha(args.output/'power-preflight.txt')}
        verify.require(state is not None and state.group(1)=='AWAKE', 'screen state is not verified AWAKE; no qualification launched')
        verify.require(override is None or int(override.group(1))!=10000,
                       'active 10000ms screen override can freeze this run; recorded without changing power settings')
        transfer['launchedAt'] = now()
        _, launch = hdc.invoke(['shell', 'aa', 'start', '-a', 'EntryAbility', '-b', BUNDLE,
            '--ps', 'amclJdkProbe', 'java', '--ps', 'amclJdkProbeNonce', args.nonce,
            '--ps', 'amclJdkMajor', args.major, '--ps', 'amclJdkProfile', 'native-temp-vms'])
        verify.require('start ability successfully' in launch.lower(), 'qualification launch not confirmed')
        launched = True
        attempts = args.output / 'poll'
        attempts.mkdir()
        deadline = monotonic() + 240
        count = 0
        while monotonic() < deadline and not (transfer['parentReportReceived'] and transfer['ownerReportReceived']):
            count += 1
            if not transfer['parentReportReceived']:
                target = attempts / ('parent-%03d.json' % count)
                ok, _ = hdc.invoke(['file', 'recv', '-b', BUNDLE, LOGICAL + '/jdk-java-' + args.nonce + '.json', target.resolve()], allow_failure=True)
                if ok and target.is_file():
                    item = verify.parse_json(target.read_text(encoding='utf-8-sig'))
                    verify.require(item.get('nonce') == args.nonce, 'received wrong parent nonce')
                    (args.output / 'parent-result.json').write_bytes(target.read_bytes())
                    transfer['parentReportReceived'] = True
            if not transfer['ownerReportReceived']:
                target = attempts / ('owner-%03d.json' % count)
                ok, _ = hdc.invoke(['file', 'recv', '-b', BUNDLE, remote + '/run-native-temp-vms/owner-reclaimed.json', target.resolve()], allow_failure=True)
                if ok and target.is_file():
                    item = verify.parse_json(target.read_text(encoding='utf-8-sig'))
                    verify.require(item.get('stage') == 'pair-owner-reclaimed', 'wrong owner completion protocol')
                    transfer['ownerReportReceived'] = True
            if not (transfer['parentReportReceived'] and transfer['ownerReportReceived']):
                sleep(2)
        ok, _ = hdc.invoke(['file', 'recv', '-b', BUNDLE, remote + '/run-native-temp-vms',
                            (args.output / 'run-native-temp-vms').resolve()], allow_failure=True, timeout=60)
        transfer['pairDirectoryReceived'] = ok and (args.output / 'run-native-temp-vms').is_dir()
        verify.require(transfer['parentReportReceived'] and transfer['ownerReportReceived'] and transfer['pairDirectoryReceived'],
                       'parent/owner/pair evidence incomplete before deadline; no automatic rerun or force-stop')
        parent=verify.parse_json((args.output/'parent-result.json').read_text(encoding='utf-8-sig'))
        parent_pid=verify.integer(verify.one(verify.rows(parent['text']),'native-temp-pair-parent').get('pid'),'parent pid',1)
        ok,cgroup=hdc.invoke(['shell','cat /proc/'+str(parent_pid)+'/cgroup'],allow_failure=True)
        (args.output/'parent-cgroup-after.txt').write_text(cgroup,encoding='utf-8',newline='\n')
        # 根组是Linux v1明确规定的不可冻结组，与设备的/Thawed命名组分开记录。
        group=verify.freezer_state(cgroup) if ok else 'UNKNOWN'
        transfer['parentFreezer']={'pid':parent_pid,'state':group,
            'sha256':verify.sha(args.output/'parent-cgroup-after.txt')}
        verify.require(group in ('Thawed', 'RootNonFreezable'), 'parent freezer state is Frozen or unknown; preserved evidence cannot qualify this round')
        files = {name: verify.sha(args.output / name) for name in inventory_members()}
        save(args.output / 'readback-inventory.json', {'protocol': 'AMCL_NATIVE_TEMP_PAIR_READBACK_V1', 'files': files})
    except Exception as error:
        transfer['error'] = str(error)
        raise
    finally:
        transfer['launchConfirmed'] = launched
        transfer['finishedAt'] = now()
        save(args.output / 'transfer.json', transfer)
    # 仅使用本目录独立pair verifier；绝不调用旧单VM验收器。
    try:
        result = verify.verify_pair(args.output, args.deployment, args.hap, args.archive, args.jar,
            device=args.device, major=args.major, nonce=args.nonce, native_root=args.expected_native_root, java_root=args.expected_java_root,
            hap_sha=args.expected_hap_sha256, archive_sha=args.expected_archive_sha256, jar_sha=args.expected_jar_sha256)
    except (ValueError,OSError,TypeError,KeyError) as error:
        save(args.output/'pair-verification.json',{'protocol':'AMCL_NATIVE_TEMP_PAIR_VERIFICATION_V1','pairQualified':False,'error':str(error)})
        raise
    save(args.output / 'pair-verification.json', result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('output', 'hap', 'archive', 'jar', 'deployment'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--hdc', type=Path, default=Path('D:/Huawei/command-line-tools/sdk/default/openharmony/toolchains/hdc.exe'))
    for name in ('device', 'device-files-root', 'major', 'nonce', 'expected-native-root', 'expected-java-root', 'expected-hap-sha256', 'expected-archive-sha256', 'expected-jar-sha256'):
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    result = execute(args)
    print(json.dumps({key: value for key, value in result.items() if key != 'files'}, ensure_ascii=False))


if __name__ == '__main__':
    main()
