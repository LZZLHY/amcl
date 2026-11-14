#!/usr/bin/env python3
"""运行真实Linux libc前置探针与三个有限边界；所有输出外置，不接设备/不启动JVM。"""
from datetime import datetime
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
source = Path(__file__).resolve().parent
out = args.out.resolve()
if not args.out.is_absolute() or out.is_relative_to(source.parents[1]):
    raise ValueError('absolute external output required')
out.mkdir(parents=True, exist_ok=False)
receipt = {'startedAt': datetime.now().astimezone().isoformat(), 'hostOnly': True, 'deviceRun': False,
           'inputs': {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in source.glob('*') if path.is_file()},
           'commands': []}


def run(command, label):
    result = subprocess.run(command, capture_output=True, timeout=25,
        env={**os.environ, 'ASAN_OPTIONS': 'detect_leaks=1:abort_on_error=1', 'UBSAN_OPTIONS': 'halt_on_error=1'})
    (out / (label + '.stdout')).write_bytes(result.stdout)
    (out / (label + '.stderr')).write_bytes(result.stderr)
    receipt['commands'].append({'argv': list(map(str, command)), 'returncode': result.returncode})
    if result.returncode:
        raise RuntimeError(label + ': ' + result.stderr.decode('utf-8', errors='replace'))


try:
    run(['g++', '-std=c++17', '-DMC_OHOS_BUILD_TESTS=1', '-O1', '-g', '-Wall', '-Wextra', '-Werror',
         '-fno-omit-frame-pointer', '-fsanitize=address,undefined', str(source / 'host_test.cpp'),
         str(source.parents[1] / 'entry/src/main/cpp/download/hmac_sha256.cpp'), '-o', str(out / 'run')], 'compile')
    run([str(out / 'run'), str(out)], 'run')
    read = lambda name: json.loads((out / name).read_text(encoding='utf-8'))
    normal = read('normal.json')
    assert normal['protocol'] == 'AMCL_NATIVE_TEMP_PREFLIGHT_V1' and not normal['deadlineExceeded']
    assert not normal['jvmStarted'] and not normal['crossVmAttachQualified'] and not normal['crossProcessMmapQualified']
    assert normal['passwdEffective']['returnCode'] == 0 and normal['passwdEffective']['found']
    for root in (normal['sandbox'], normal['tmpControl']):
        assert root['created'] and root['ordinaryFileObserved'] and root['renameIdentityObserved']
        assert root['sameProcessUnixObserved'] and root['sameProcessSharedMapObserved'] and root['cleanupComplete']
        assert root['peer']['pid'] == normal['pid'] and root['peer']['uid'] == normal['euid'] and root['peer']['gid'] == normal['egid']
        assert root['socketMetadata']['mode'] == 0o600 and root['socketMetadata']['uid'] == normal['euid']
        assert root['cleanupAbsenceObserved'] and root['socketMetadata']['type'] == 0o140000
        assert all(call['result'] >= 0 or (call['operation'] == 'connect' and call['errno'] in (11, 115)) or
                   (call['operation'] == 'cleanup-fstatat' and call['errno'] == 2) for call in root['calls'])
    collision = read('collision.json')
    assert not collision['created'] and not collision['unixAttempted'] and not collision['mappingAttempted']
    assert any(call['operation'] == 'mkdirat-exclusive' and call['errno'] == 17 for call in collision['calls'])
    long = read('long-socket.json')
    assert long['socketPathBytes'] >= long['socketCapacity'] and not long['sameProcessUnixObserved']
    assert long['sameProcessSharedMapObserved'] and long['cleanupComplete']
    assert any(call['operation'] == 'socket-path-limit-no-syscall' and call['kind'] == 'contract' for call in long['calls'])
    assert not any(call['operation'] == 'bind' for call in long['calls'])
    assert read('invalid-input.json')['rejectedBeforeProbe']
    expired = read('expired-deadline.json')
    assert not expired['created'] and not any(call['operation'] == 'mkdirat-exclusive' for call in expired['calls'])
    assert any(call['operation'] == 'group-deadline' and call['kind'] == 'contract' for call in expired['calls'])
    poll = read('bounded-poll.json')
    assert not poll['ready'] and poll['elapsedMillis'] < 1000 and any(call['operation'] == 'poll-timeout' for call in poll['calls'])
    assert read('duplicate-report.json')['duplicateRejected']
    assert read('wrong-root.json')['wrongRootRejectedBeforeProbe']
    bridge = read('bridge.json')
    assert bridge['protocol'] == 'AMCL_NATIVE_TEMP_QUALIFICATION_V1' and bridge['nativeOnly']
    assert bridge['observation']['sandbox']['cleanupComplete'] and not bridge['observation']['jvmStarted']
    assert read('host-complete.json')['ownedScratchRemoved']
    receipt['passed'] = True
    receipt['cases'] = ['real-file-rename-unix-peer-mmap-cleanup', 'existing-nonce-preserved',
                        'long-unix-path-no-bind', 'invalid-nonce-rejected', 'real-wrapper', 'duplicate-report-rejected',
                        'expired-before-mutation', 'bounded-nonblocking-poll', 'wrong-root-before-probe']
    print('PASS real host libc/mapping/socket + finite boundary controls; no device/VM qualification')
finally:
    receipt['finishedAt'] = datetime.now().astimezone().isoformat()
    (out / 'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
