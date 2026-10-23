"""完整生产L2 TU、真实OpenAL/loader的生命周期和私有卸载诊断合同。

原五项独立冷进程保留；新增gate/owner/sink/errno反控不得冒充目标设备资格。
先保存完整raw，超时/解析错误/非零退出/缺失终结报告均不能PASS。
"""
from pathlib import Path
from datetime import datetime, timezone
import argparse, errno, hashlib, json, os, re, subprocess

ORIGINAL_CASES = ('normal', 'failure-hold', 'failure-unheld', 'lease-no-owner', 'lease-wrong-owner')
# 独立期望不复制生产canonical数字解析算法。每个case均为一次新subprocess。
DIAGNOSTIC_CASES = {
    **{'diag-mask-' + str(mask): (mask in (3, 7), 0, False, False) for mask in range(8)},
    'diag-mask-max': (True, 0, False, False),
    'diag-no-provider': (False, 1, False, False),
    'diag-no-anchor': (False, 2, False, False),
    'diag-missing-getter': (False, 3, False, False),
    'diag-owner-mismatch': (False, 4, False, False),
    'diag-global-alias-trap': (False, 5, False, False),
    'diag-nondefault': (False, 0, False, False),
    'diag-null-identity': (False, 0, False, False),
    **{name: (False, 0, False, False) for name in (
        'diag-leading-zero', 'diag-plus', 'diag-minus', 'diag-space', 'diag-trailing-space',
        'diag-empty-number', 'diag-tail', 'diag-missing-separator', 'diag-bad-prefix',
        'diag-overflow', 'diag-too-long')},
    'diag-sink-failure': (True, 0, True, False),
    'diag-empty-handle': (True, 0, False, True),
    'diag-test-control-errno': (True, 0, False, False),
    'diag-test-control-result': (True, 0, False, False),
    **{name: (True, 0, False, False) for name in (
        'diag-identity-lookup-failure', 'diag-openal-lookup-failure', 'diag-identity-owner-failure',
        'diag-openal-owner-failure', 'diag-clock-failure')},
}
# 两组明确source故障注入；真实系统close仍0，-37只属于wrapper返回合同。
RETURN_CONTROLS = {'diag-test-control-errno': ('errno', 0),
                   'diag-test-control-result': ('result', -37)}
LOOKUP_CONTROLS = {
    'diag-identity-lookup-failure': 'identity-lookup',
    'diag-openal-lookup-failure': 'openal-lookup',
    'diag-identity-owner-failure': 'identity-owner',
    'diag-openal-owner-failure': 'openal-owner',
    'diag-clock-failure': 'clock',
}
MARKER_PREFIX = 'AMCL_L2_OPENAL_UNLOAD_PHASE'
MARKER_RE = re.compile(
    r'^\[LWJGL2BK\] AMCL_L2_OPENAL_UNLOAD_PHASE pid=(\d+) tid=(\d+) unload_epoch_ns=(\d+) '
    r'handle=(0x[0-9a-f]+) open_device_addr=(0x[0-9a-f]+) open_device_base=(0x[0-9a-f]+) '
    r'operation=dlclose phase=(enter|return) result=(NOT_RETURNED|-?\d+)$', re.MULTILINE)
CONTROL_RE = re.compile(
    r'^UNLOAD_CONTROL round=(\d+) calls=(\d+) entryErrno=(\d+) realCloseErrno=(\d+) '
    r'observedErrno=(\d+) result=(-?\d+) handleCleared=1 sinkFailure=(\d+) sinkRejected=(\d+) empty=(\d+)$',
    re.MULTILINE)
BINDING_RE = re.compile(
    r'^UNLOAD_BINDING round=(\d+) handle=(0x[0-9a-f]+) open_device_addr=(0x[0-9a-f]+) '
    r'open_device_base=(0x[0-9a-f]+)$', re.MULTILINE)
TEST_CONTROL_RE = re.compile(
    r'^TEST_CONTROL round=(\d+) injection=(errno|result) realCloseCalls=(\d+) realCloseResult=(-?\d+) '
    r'realCloseErrno=(\d+) returnedResult=(-?\d+) returnedErrno=(\d+) observedErrno=(\d+) '
    r'source=WRAPPER_AFTER_REAL_CLOSE$', re.MULTILINE)
LOOKUP_CONTROL_RE = re.compile(
    r'^TEST_LOOKUP_CONTROL round=(\d+) injection=(identity-lookup|openal-lookup|identity-owner|openal-owner|clock) '
    r'hits=(\d+) realSucceeded=(\d+) realErrno=(\d+) returnedFailure=1 returnedErrno=(\d+) '
    r'source=WRAPPER_AFTER_REAL_QUERY$', re.MULTILINE)


def require(value, message):
    """显式判据保留Python-O行为；缺原件或契约不满足时失败关闭。"""
    if not value:
        raise RuntimeError(message)


def validate_unload(name, stdout, stderr, pid, owners):
    """核真实close与marker pair。先核数量再索引，残缺报告作为失败收据保全。"""
    enabled, mode, sink_failure, empty = DIAGNOSTIC_CASES.get(name, (False, 0, False, False))
    normal = name == 'normal' or name in DIAGNOSTIC_CASES and not empty
    rounds = 2 if normal else 1
    controls = CONTROL_RE.findall(stdout)
    bindings = BINDING_RE.findall(stdout)
    markers = MARKER_RE.findall(stderr)
    test_controls = TEST_CONTROL_RE.findall(stdout)
    injected = RETURN_CONTROLS.get(name)
    lookup_injected = LOOKUP_CONTROLS.get(name)
    lookup_controls = LOOKUP_CONTROL_RE.findall(stdout)
    expected_markers = rounds * 2 if enabled and not sink_failure and not empty and not lookup_injected else 0
    valid = len(controls) == rounds and stdout.count('UNLOAD_CONTROL') == rounds
    valid = valid and len(bindings) == (0 if empty else rounds) and stdout.count('UNLOAD_BINDING') == len(bindings)
    valid = valid and len(markers) == expected_markers and stderr.count(MARKER_PREFIX) == expected_markers
    valid = valid and MARKER_PREFIX not in stdout
    valid = valid and len(test_controls) == (rounds if injected else 0)
    valid = valid and stdout.count('TEST_CONTROL') == len(test_controls)
    valid = valid and len(lookup_controls) == (rounds if lookup_injected else 0)
    valid = valid and stdout.count('TEST_LOOKUP_CONTROL') == len(lookup_controls)
    if not valid:
        return False, controls, bindings, markers
    for index, control in enumerate(controls):
        round_id, calls, incoming, actual, observed, result, sink, rejected, is_empty = map(int, control)
        valid = valid and round_id == index and incoming == errno.EBUSY and result == (injected[1] if injected else 0)
        valid = valid and calls == (0 if empty else 1) and is_empty == int(empty)
        valid = valid and sink == int(sink_failure) and rejected == int(sink_failure)
        valid = valid and observed == (errno.EBUSY if empty else errno.EIO if injected else actual)
        if injected:
            test = test_controls[index]
            valid = valid and int(test[0]) == index and test[1] == injected[0]
            valid = valid and int(test[2]) == 1 and int(test[3]) == 0 and int(test[4]) == actual
            valid = valid and int(test[5]) == injected[1] and int(test[6]) == errno.EIO
            valid = valid and int(test[7]) == observed and observed != incoming
        if lookup_injected:
            lookup = lookup_controls[index]
            valid = valid and int(lookup[0]) == index and lookup[1] == lookup_injected
            valid = valid and int(lookup[2]) == 1 and int(lookup[3]) == 1 and int(lookup[5]) == errno.EIO
    if name in DIAGNOSTIC_CASES:
        expected = 'DIAGNOSTIC_GATE enabled=' + str(int(enabled)) + ' expected=' + str(int(enabled)) + ' mode=' + str(mode)
        valid = valid and stdout.count('DIAGNOSTIC_GATE') == 1 and expected in stdout.splitlines()
        if mode in (3, 4, 5):
            expected_provider = 'PROVIDER_CONTROL mode=' + str(mode) + ' sameImage=0 globalGetterPresent=1'
            valid = valid and stdout.count('PROVIDER_CONTROL') == 1 and expected_provider in stdout.splitlines()
    else:
        valid = valid and 'DIAGNOSTIC_GATE' not in stdout and 'PROVIDER_CONTROL' not in stdout
    if expected_markers and len(owners) != rounds:
        return False, controls, bindings, markers
    previous_epoch = 0
    for index in range(expected_markers // 2):
        before, after = markers[2 * index:2 * index + 2]
        valid = valid and before[:6] == after[:6] and before[6:] == ('enter', 'NOT_RETURNED')
        valid = valid and after[6:] == ('return', controls[index][5])
        valid = valid and int(before[0]) == pid and int(before[1]) == pid and int(before[2]) > previous_epoch
        previous_epoch = int(before[2])
        valid = valid and int(bindings[index][0]) == index and before[3:6] == bindings[index][1:]
        valid = valid and owners[index][2] == before[4]
    return valid, controls, bindings, markers


def main():
    """现成build输入/全新output；raw保存早于严格UTF8和exit/语义判据。"""
    parser = argparse.ArgumentParser()
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--asan-runtime', type=Path)
    args = parser.parse_args()
    build, out = args.build.resolve(), args.output.resolve()
    require(not out.exists(), 'output already exists')
    out.mkdir(parents=True)
    started = datetime.now(timezone.utc).isoformat()
    env = os.environ.copy()
    env.pop('LD_PRELOAD', None)
    env.pop('AMCL_LEASE_FAULT', None)
    env.update(LD_LIBRARY_PATH=str(build) + ':' + str(build / 'openal'),
               ALSOFT_DRIVERS='ohaudio', ALSOFT_LOGLEVEL='3')
    config = out / 'openal.conf'
    config.write_text('[general]\nfrequency=48000\nchannels=stereo\nsample-type=float32\nhrtf=false\n')
    env['ALSOFT_CONF'] = str(config)
    if args.asan_runtime:
        require(args.asan_runtime.is_file(), 'actual ASan runtime missing')
    rows = []
    for name in (*ORIGINAL_CASES, *DIAGNOSTIC_CASES):
        case_env = env.copy()
        case_env['ALSOFT_LOGFILE'] = str(out / (name + '-openal.log'))
        if name.startswith('lease-'):
            case_env['LD_PRELOAD'] = str(build / 'liblease-fault.so')
            case_env['AMCL_LEASE_FAULT'] = 'no-owner' if name == 'lease-no-owner' else 'wrong-owner'
        if args.asan_runtime:
            # ASan运行库先于原lease故障模块；不关闭检测器或吞掉加载失败。
            case_env['LD_PRELOAD'] = str(args.asan_runtime.resolve()) + (
                ':' + case_env['LD_PRELOAD'] if 'LD_PRELOAD' in case_env else '')
        begin = datetime.now(timezone.utc).isoformat()
        command = [str(build / 'lifetime'), name]
        timed_out = False
        try:
            result = subprocess.run(command, env=case_env, capture_output=True, timeout=20)
            stdout_raw, stderr_raw, returncode = result.stdout, result.stderr, result.returncode
        except subprocess.TimeoutExpired as error:
            timed_out = True
            stdout_raw, stderr_raw, returncode = error.stdout or b'', error.stderr or b'', None
        path = out / (name + '.log')
        (out / (name + '-stdout.bin')).write_bytes(stdout_raw)
        (out / (name + '-stderr.bin')).write_bytes(stderr_raw)
        path.write_bytes(stdout_raw + stderr_raw)
        decode_error = None
        try:
            stdout, stderr = stdout_raw.decode('utf-8'), stderr_raw.decode('utf-8')
        except UnicodeDecodeError as error:
            decode_error, stdout, stderr = str(error), '', ''
        terminal = 'LIFETIME_END completed=1 case=' + name
        valid = not timed_out and decode_error is None and returncode == 0
        valid = valid and stdout.count('LIFETIME_END') == 1 and stdout.rstrip().endswith(terminal)
        starts = re.findall(r'^LIFETIME_START pid=(\d+) case=(\S+)$', stdout, re.MULTILINE)
        owners = re.findall(r'^ACTUAL_OPENAL round=(\d+) owner=(\S+) address=(0x[0-9a-f]+)$', stdout, re.MULTILINE)
        pid = int(starts[0][0]) if len(starts) == 1 else None
        valid = valid and len(starts) == 1 and starts[0][1] == name and pid > 0
        empty = DIAGNOSTIC_CASES.get(name, (False, 0, False, False))[3]
        normal = name == 'normal' or name in DIAGNOSTIC_CASES and not empty
        valid = valid and len(owners) == (0 if empty else 2 if normal else 1) and all(
            int(round_id) == index and Path(owner).resolve() == (build / 'openal/libopenal.so').resolve()
            for index, (round_id, owner, _) in enumerate(owners))
        # 原normal两轮、失败后真实迟到回调、租约拒绝/回滚三组判据未削弱。
        if normal:
            valid = valid and all(stdout.count(
                'POST_UNLOAD round=' + str(n) + ' callbackMapped=0 retainedRenderers=0 hold=0') == 1 for n in (0, 1))
        elif name.startswith('failure-'):
            valid = valid and 'POST_UNLOAD round=0 callbackMapped=1 retainedRenderers=1 hold=' + str(int(name == 'failure-hold')) in stdout
            valid = valid and stdout.count('LATE_CALLBACK_RETURNED result=0') == 1
        elif name.startswith('lease-'):
            valid = valid and stdout.count('LEASE_REJECTED contextCreated=0 callbacksPublished=0 generateCalls=0') == 1
            valid = valid and 'REJECT_UNLOAD apiMapped=0 foreignMapped=0' in stdout
        unload_valid, controls, bindings, markers = validate_unload(name, stdout, stderr, pid, owners)
        valid = valid and unload_valid
        rows.append({
            'case': name, 'startedAt': begin, 'finishedAt': datetime.now(timezone.utc).isoformat(),
            'command': command, 'pid': pid, 'actualOwners': owners, 'exitCode': returncode,
            'timedOut': timed_out, 'decodeStatus': 'PASS' if decode_error is None else 'FAILED',
            'decodeError': decode_error, 'unloadControls': controls, 'unloadBindings': bindings,
            'unloadMarkers': markers, 'complete': valid,
            'testControls': TEST_CONTROL_RE.findall(stdout),
            'lookupTestControls': LOOKUP_CONTROL_RE.findall(stdout),
            'logSha256': hashlib.sha256(path.read_bytes()).hexdigest(),
            'stdoutSha256': hashlib.sha256(stdout_raw).hexdigest(),
            'stderrSha256': hashlib.sha256(stderr_raw).hexdigest()})
        print(name + ' actualExit=' + str(returncode) + ' complete=' + str(valid), flush=True)
    source_root = Path(__file__).resolve().parents[2]
    sources = ('prebuilt/lwjgl2/ohos-backend/amcl_lwjgl2_backend.c',
               'tests/ohaudio-lifetime-host/CMakeLists.txt', 'tests/ohaudio-lifetime-host/lifetime.c',
               'tests/ohaudio-lifetime-host/probe.py', 'tests/ohaudio-lifetime-host/diagnostic-identity.c')
    record = {
        'startedAt': started, 'finishedAt': datetime.now(timezone.utc).isoformat(), 'cases': rows,
        'completed': all(row['complete'] for row in rows),
        'sourceReadHashes': {path: hashlib.sha256((source_root / path).read_bytes()).hexdigest() for path in sources},
        'scope': 'Linux full production TU/real-loader controls with platform mock only; source-read hashes need actual build receipt to qualify compilation identity'}
    (out / 'lifetime-receipt.json').write_text(json.dumps(record, indent=2) + '\n')
    require(record['completed'], 'lifetime contract incomplete')
    print('OHAUDIO_LIFETIME_RESULT completed=1 cases=' + str(len(rows)) + ' failures=0')


if __name__ == '__main__':
    main()
