"""固定单流一秒启动观察的精确校验；只验证观测完整性，绝不授信号质量PASS。"""
import hashlib
import json
import math
from pathlib import Path


def need(value, message):
    if not value:
        raise ValueError(message)


def check_report(report):
    """纯结构/统计合同供少量宿主损坏反例复用；目标provider/PID由validate_run另核。"""
    need(report.get('protocol') == 'AMCL_CAPTURE_STARTUP_V1' and report.get('status') == 'OBSERVED', 'wrong startup protocol/status')
    need(report.get('rawPcmSaved') is False and report.get('signalQualified') is False, 'startup scope changed')
    need(not report.get('error') and report.get('actualFastObserved') is True, 'startup SDK/actual FAST observation failed')
    need(report.get('deadlineMillis') == 10000 and 0 <= report['elapsedMillis'] < 10000, 'startup deadline exceeded')
    need(report['requested'] == {'rate': 48000, 'channels': 1, 'format': 1, 'encoding': 0, 'source': 0, 'prefixFrames': 48000}, 'startup request changed')
    need(len(report['cases']) == 1, 'startup must have exactly one stream')
    case = report['cases'][0]
    need(case['requestedLatencyMode'] == 1 and case['status'] == 'OBSERVED' and not case['error'], 'startup case failed')
    need(case['quiescent'] is True and case['retainedForSafety'] is False, 'startup callback/resources not closed')
    need(case['callbackErrorSeen'] is False and case['invalidFlags'] == case['interruptEvents'] == 0, 'startup callback error/interruption')
    need(case['layoutSetterCalled'] is False and case['requestedChannelLayout'] is None, 'startup default layout changed')
    calls = case['calls']; names = [row['api'] for row in calls]
    need(all(row['result'] == 0 for row in calls), 'startup API error')
    for name in ('Create', 'GenerateCapturer', 'DestroyBuilder', 'Start', 'Stop', 'Release'):
        need(names.count(name) == 1, 'startup missing/duplicate ' + name)
    need(names.index('Start') < names.index('Stop') < names.index('Release') and 'SetChannelLayout' not in names, 'startup lifecycle/request changed')
    snapshots = case['snapshots']
    need([row['stage'] for row in snapshots] == ['prepared', 'started', 'stopped', 'stopped-frames'], 'startup actual getter snapshots incomplete')
    for snapshot, state in zip(snapshots[:3], (1, 2, 3)):
        need((snapshot['rate'], snapshot['channels'], snapshot['format'], snapshot['encoding'], snapshot['source']) == (48000, 1, 1, 0, 0), 'startup actual format/source mismatch')
        need(snapshot['state'] == state and snapshot['latencyMode'] == snapshot['fastStatus'] == 1, 'startup actual state/mode mismatch')
        need(snapshot['overflowCount'] == 0 and snapshot['frameSizeInCallback'] > 0, 'startup overflow/callback span invalid')
    need(snapshots[3]['framesRead'] >= 48000 and case['offeredFrames'] >= 48000 and case['callbackCount'] > 0, 'startup prefix not delivered')
    need(0 < case['minimumCallbackBytes'] <= case['maximumCallbackBytes'] and
         case['minimumCallbackBytes'] % 2 == case['maximumCallbackBytes'] % 2 == 0, 'startup partial/invalid S16 frame')
    for name in ('s16le', 's16beInterpretation'):
        value = case[name]
        need(value['frames'] == 48000 and 0 <= value['peak'] <= 32768 and
             math.isfinite(value['rms']) and 0 <= value['rms'] <= value['peak'], 'startup prefix statistics invalid')
    need(case['f32TotalSamples'] == 24000 and 0 <= case['f32leInterpretation']['finiteSamples'] <= 24000, 'startup interpretation prefix incomplete')
    windows = case['windows']
    need(len(windows) == 25, 'startup needs all 25 windows')
    for index, window in enumerate(windows):
        need((window['index'], window['firstFrame'], window['frames']) == (index, index * 1920, 1920), 'startup window skipped/reordered')
        need(0 <= window['peak'] <= 32768 and math.isfinite(window['rms']) and 0 <= window['rms'] <= window['peak'], 'startup window statistics invalid')
    rms = math.sqrt(sum(row['rms'] ** 2 * row['frames'] for row in windows) / 48000)
    need(math.isclose(rms, case['s16le']['rms'], rel_tol=1e-12, abs_tol=1e-8) and
         max(row['peak'] for row in windows) == case['s16le']['peak'], 'startup whole/window statistics disagree')
    return {'observationVerified': True, 'signalQualified': False, 'windows': windows,
            'wholePrefix': case['s16le'], 'scope': 'single actual FAST first48000 frames; no subjective threshold or DC/root-cause claim'}


def validate_run(run, native):
    """由Java基础verifier显式分派，不能把其它音频profile的OBSERVED报告当成本次完成。"""
    run = Path(run)
    need(native.get('profile') == 'sound-capture-startup' and native.get('specialtyResult') == 0, 'not the fixed startup profile')
    path = run / 'capture-startup-report.json'
    raw = path.read_bytes(); report = json.loads(raw)
    need(report['pid'] == native['pid'] and report['provider'] == '/system/lib64/ndk/libohaudio.so', 'startup process/provider identity mismatch')
    result = check_report(report)
    stages = [json.loads(line) for line in (run / 'native-stages.jsonl').read_text(encoding='utf-8').splitlines() if line]
    names = [row.get('stage') for row in stages]
    for stage in ('capture-main', 'capture-main-return', 'capture-startup-observed', 'jvm-init'):
        need(names.count(stage) == 1, 'startup missing/duplicate stage ' + stage)
    need(names.index('capture-main') < names.index('capture-main-return') < names.index('capture-startup-observed') < names.index('jvm-init'), 'startup was not completed before VM loading')
    observed = next(row for row in stages if row.get('stage') == 'capture-startup-observed')
    need(observed['reportSha256'] == hashlib.sha256(raw).hexdigest(), 'startup body SHA mismatch')
    result['reportSha256'] = hashlib.sha256(raw).hexdigest()
    return result
