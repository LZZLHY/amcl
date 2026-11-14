"""只授固定stereo→mono观察完整性，不把幅度或平均统计作为质量/修复门。

check_report用于合成宿主与目标共用的纯结构门；validate_run供未来固定NCP接线使用。
模块不执行设备调用，不读取PCM，不扩大录音范围。
"""
import hashlib
import json
import math
from pathlib import Path


def need(value, message):
    if not value:
        raise ValueError(message)


def check_stats(value):
    """每个通道与同帧平均都必须完整覆盖同一首9600帧、5个连续窗口。"""
    need(value['frames'] == 9600 and len(value['windows']) == 5, 'incomplete channel prefix/windows')
    for index, window in enumerate(value['windows']):
        need((window['index'], window['firstFrame'], window['frames']) == (index, index * 1920, 1920), 'window omitted/reordered')
        need(math.isfinite(window['rms']) and 0 <= window['rms'] <= window['peak'] <= 32768, 'invalid window moments')
    rms = math.sqrt(sum(window['frames'] * window['rms'] ** 2 for window in value['windows']) / 9600)
    need(math.isfinite(value['rms']) and math.isclose(rms, value['rms'], rel_tol=1e-12, abs_tol=1e-8), 'whole/window RMS mismatch')
    need(value['peak'] == max(window['peak'] for window in value['windows']), 'whole/window peak mismatch')


def check_report(report):
    need(report['protocol'] == 'AMCL_CAPTURE_CHANNELS_V1' and report['status'] == 'OBSERVED' and not report['error'], 'not a complete fixed channel observation')
    need(report['rawPcmSaved'] is False and report['signalQualified'] is False, 'observation scope changed')
    need(report['bothFastObserved'] is True and report['deadlineMillis'] == 10000 and 0 <= report['elapsedMillis'] < 10000, 'actual FAST/deadline premise failed')
    need(report['requested'] == {'rate': 48000, 'channelCounts': [2, 1], 'format': 1, 'encoding': 0, 'source': 0, 'prefixFrames': 9600}, 'fixed channel contrast request changed')
    need(len(report['cases']) == 2, 'channel contrast must have exactly two arms')
    ids = []
    for expected_channels, case in zip((2, 1), report['cases']):
        need(case['requestedChannelCount'] == expected_channels and case['requestedLatencyMode'] == 1, 'stereo-first/mono-second changed')
        need(case['status'] == 'OBSERVED' and not case['error'] and case['quiescent'] and not case['retainedForSafety'], 'arm failed or not closed')
        need(not case['callbackErrorSeen'] and case['invalidFlags'] == case['interruptEvents'] == 0, 'callback error/interruption')
        need(not case['layoutSetterCalled'] and case['requestedChannelLayout'] is None, 'default layout changed')
        calls = case['calls']; names = [row['api'] for row in calls]
        need(all(row['result'] == 0 for row in calls), 'SDK error')
        for name in ('Create', 'GenerateCapturer', 'DestroyBuilder', 'Start', 'Stop', 'Release'):
            need(names.count(name) == 1, 'missing/repeated lifecycle ' + name)
        need(names.count('GetStreamId') == 3 and 'SetChannelLayout' not in names and names.index('Start') < names.index('Stop') < names.index('Release'), 'identity/lifecycle calls incomplete')
        snapshots = case['snapshots']
        need([row['stage'] for row in snapshots] == ['prepared', 'started', 'stopped', 'stopped-frames'], 'missing getter snapshots')
        for snapshot, state in zip(snapshots[:3], (1, 2, 3)):
            need((snapshot['rate'], snapshot['channels'], snapshot['format'], snapshot['encoding'], snapshot['source']) == (48000, expected_channels, 1, 0, 0), 'actual stream format/source mismatch')
            need(snapshot['latencyMode'] == snapshot['fastStatus'] == 1 and snapshot['state'] == state, 'actual FAST/state mismatch')
            need(snapshot['frameSizeInCallback'] > 0 and snapshot['overflowCount'] == 0, 'overflow/span mismatch')
            need(snapshot['streamId'] == snapshots[0]['streamId'], 'stream identity changed')
        ids.append(snapshots[0]['streamId'])
        need(snapshots[-1]['framesRead'] >= 9600 and case['countedFrames'] == 9600 and case['offeredFrames'] >= 9600 and case['callbackCount'] > 0, 'fixed frame prefix not delivered')
        need(0 < case['minimumCallbackBytes'] <= case['maximumCallbackBytes'] and
             case['minimumCallbackBytes'] % (2 * expected_channels) == case['maximumCallbackBytes'] % (2 * expected_channels) == 0, 'partial interleaved frame')
        need([row['index'] for row in case['channels']] == list(range(expected_channels)), 'channel missing/reordered')
        for row in case['channels']: check_stats(row['statistics'])
        check_stats(case['sameFrameArithmeticMean'])
        # 平均RMS无法由两声道RMS唯一推出；不写虚假的同源一致性式。单声道平均应精确相同。
        if expected_channels == 1:
            need(case['sameFrameArithmeticMean'] == case['channels'][0]['statistics'], 'mono arithmetic mean differs')
    need(ids[0] != ids[1], 'two arms share a stream identity')
    return {'observationVerified': True, 'signalQualified': False, 'productionFixQualified': False,
            'scope': 'two actual FAST streams; each first9600 frames; mean is diagnostic only', 'cases': report['cases']}


def validate_run(run, native):
    """未来root固定profile接线后使用，仍由base verifier先绑定完整HAP/JAR/ZIP/退出。"""
    run = Path(run)
    need(native.get('profile') == 'sound-capture-channels' and native.get('specialtyResult') == 0, 'wrong fixed profile')
    raw = (run / 'capture-channels-report.json').read_bytes(); report = json.loads(raw)
    need(report['pid'] == native['pid'] and report['provider'] == '/system/lib64/ndk/libohaudio.so', 'process/provider mismatch')
    result = check_report(report)
    stages = [json.loads(line) for line in (run / 'native-stages.jsonl').read_text(encoding='utf-8').splitlines() if line]
    names = [row.get('stage') for row in stages]
    expected = ('capture-main', 'capture-main-return', 'capture-channels-observed', 'jvm-init')
    need(all(names.count(name) == 1 for name in expected) and [names.index(name) for name in expected] == sorted(names.index(name) for name in expected), 'missing/reordered capture stages')
    observed = next(row for row in stages if row.get('stage') == 'capture-channels-observed')
    need(observed['reportSha256'] == hashlib.sha256(raw).hexdigest(), 'report body SHA mismatch')
    result['reportSha256'] = hashlib.sha256(raw).hexdigest()
    return result
