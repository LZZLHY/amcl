#!/usr/bin/env python3
"""独立原生对照的host SDK替身验证；输出外置，所有数据为固定合成，不接设备。

正常/字节序/F32解释对照均仍是观测，不授信号PASS。失败例必须先落FAILED并抛出；
Release失败例刻意保留userdata/provider，单独关闭LSan并做迟到callback的ASan验证。
"""
import argparse
import copy
from datetime import datetime
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import sys

sys.dont_write_bytecode = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk-headers', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    tests = Path(__file__).resolve().parent; repo = tests.parents[1]; native = repo / 'entry/src/main/cpp/napi'
    out = args.out.resolve()
    if not args.out.is_absolute() or out.is_relative_to(repo): raise ValueError('absolute external output required')
    out.mkdir(parents=True, exist_ok=False)
    sources = [native / 'jdk_capture_native_qualification.cpp', native / 'jdk_capture_native_qualification.h',
               tests / 'capture_native_mock.cpp', tests / 'capture_native_test.cpp', Path(__file__), tests / 'verify-capture-channels.py']
    receipt = {'startedAt': datetime.now().astimezone().isoformat(), 'inputs': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
               'scope': 'host synthetic SDK boundary only; no device/microphone qualification', 'commands': [], 'cases': []}

    def run(command, label, extra=None):
        result = subprocess.run(command, capture_output=True, timeout=35, env={**os.environ,
            'LD_LIBRARY_PATH': str(out), 'ASAN_OPTIONS': 'detect_leaks=1:abort_on_error=1',
            'UBSAN_OPTIONS': 'halt_on_error=1', **(extra or {})})
        (out / (label + '.stdout')).write_bytes(result.stdout); (out / (label + '.stderr')).write_bytes(result.stderr)
        receipt['commands'].append({'argv': list(map(str, command)), 'returncode': result.returncode, 'extraEnvironment': extra or {}})
        if result.returncode: raise RuntimeError(label + ': ' + result.stderr.decode('utf-8', errors='replace'))
        return result.stdout.decode('utf-8')

    try:
        flags = ['-std=c++17', '-O1', '-g', '-Wall', '-Wextra', '-Werror', '-fno-omit-frame-pointer', '-fsanitize=address,undefined',
                 '-DMC_OHOS_BUILD_TESTS=1', '-D__availability__(...)=', '-I' + str(args.sdk_headers), '-I' + str(native), '-pthread']
        run(['g++', *flags, '-shared', '-fPIC', str(tests / 'capture_native_mock.cpp'), '-o', str(out / 'libohaudio.so')], 'mock')
        run(['g++', *flags, str(tests / 'capture_native_test.cpp'), str(native / 'jdk_capture_native_qualification.cpp'), '-ldl', '-o', str(out / 'run')], 'main')
        raw = b''.join(struct.pack('<h', (i * 157) % 511 - 255) for i in range(9600))
        rms = math.sqrt(sum(value[0] ** 2 for value in struct.iter_unpack('<h', raw)) / 9600)
        swapped_rms = math.sqrt(sum(value[0] ** 2 for value in struct.iter_unpack('>h', raw)) / 9600)
        spec = importlib.util.spec_from_file_location('channel_verifier', tests / 'verify-capture-channels.py')
        validator = importlib.util.module_from_spec(spec); spec.loader.exec_module(validator)
        for mode in ('normal', 'swapped', 'float-payload', 'fast-fallback', 'wrong-format', 'odd-length', 'callback-error', 'release-failure', 'no-data', 'layout-response', 'layout-windows', 'layout-setter-failure',
                     'startup-normal', 'startup-windows', 'startup-split', 'startup-error', 'startup-release-failure', 'startup-no-data',
                     'channels-normal', 'channels-first-window', 'channels-extremes', 'channels-split', 'channels-half-frame',
                     'channels-wrong-count', 'channels-fallback', 'channels-overflow', 'channels-id-change', 'channels-short-platform-count',
                     'channels-error', 'channels-stop-failure', 'channels-release-failure', 'channels-generate-failure', 'channels-no-data'):
            directory = out / mode; directory.mkdir()
            extra = {'AMCL_CAPTURE_NATIVE_CASE': mode}
            if mode in ('release-failure', 'startup-release-failure', 'channels-release-failure'): extra['ASAN_OPTIONS'] = 'detect_leaks=0:abort_on_error=1'
            run([str(out / 'run'), str(directory), mode], mode, extra)
            layout = mode.startswith('layout-'); startup = mode.startswith('startup-'); channels = mode.startswith('channels-')
            report = json.loads((directory / ('capture-channels-report.json' if channels else 'capture-startup-report.json' if startup else 'capture-layout-report.json' if layout else 'capture-native-report.json')).read_text(encoding='utf-8'))
            assert report['requested']['prefixFrames'] == (48000 if startup else 9600)
            if channels:
                good = mode in ('channels-normal', 'channels-first-window', 'channels-extremes', 'channels-split')
                assert report['protocol'] == 'AMCL_CAPTURE_CHANNELS_V1' and report['status'] == ('OBSERVED' if good else 'FAILED')
                if good:
                    assert validator.check_report(report)['observationVerified']
                    # 使用独立逐帧预期，证明交错步长、首帧、窗口跨界、末回调截断及mean相关性。
                    for count, case in zip((2, 1), report['cases']):
                        values = []
                        for channel in range(count):
                            values.append([(-32768 if channel == 0 else 32767) if mode == 'channels-extremes' else
                                           (32767 if channel == 0 else -120) if mode == 'channels-first-window' and index < 1920 else
                                           ((index * 157) % 511 - 255 if channel == 0 else (index * 73) % 701 - 350)
                                           for index in range(9600)])
                        mean = [sum(row[index] for row in values) / count for index in range(9600)]
                        observed = [row['statistics'] for row in case['channels']] + [case['sameFrameArithmeticMean']]
                        for expected, stats in zip(values + [mean], observed):
                            assert stats['frames'] == 9600 and stats['peak'] == max(map(abs, expected))
                            assert abs(stats['rms'] - math.sqrt(sum(value * value for value in expected) / 9600)) < 1e-9
                            for index, window in enumerate(stats['windows']):
                                chunk = expected[index * 1920:(index + 1) * 1920]
                                assert window['peak'] == max(map(abs, chunk))
                                assert abs(window['rms'] - math.sqrt(sum(value * value for value in chunk) / 1920)) < 1e-9
                        if mode == 'channels-split':
                            assert case['minimumCallbackBytes'] == case['maximumCallbackBytes'] == 347 * count * 2
                            assert case['offeredFrames'] > case['countedFrames'] == 9600
                    if mode == 'channels-extremes': assert report['cases'][0]['sameFrameArithmeticMean']['peak'] == .5
                    if mode == 'channels-normal':
                        # 少量关键损坏反例：即使顶层伪装OBSERVED，也不能授不完整观察资格。
                        mutations = [
                            ('reordered-arms', lambda value: value['cases'].reverse()),
                            ('actual-fallback', lambda value: value['cases'][1]['snapshots'][1].__setitem__('fastStatus', 0)),
                            ('actual-mono-in-stereo-arm', lambda value: value['cases'][0]['snapshots'][1].__setitem__('channels', 1)),
                            ('missing-first-window', lambda value: value['cases'][0]['channels'][0]['statistics']['windows'].pop(0)),
                            ('short-prefix', lambda value: value['cases'][0].__setitem__('countedFrames', 9599)),
                            ('mean-rms-corrupted', lambda value: value['cases'][0]['sameFrameArithmeticMean'].__setitem__('rms', 0)),
                            ('close-error', lambda value: value['cases'][0]['calls'][-1].__setitem__('result', -1)),
                            ('callback-not-quiescent', lambda value: value['cases'][0].__setitem__('quiescent', False)),
                        ]
                        for name, mutate in mutations:
                            broken = copy.deepcopy(report); mutate(broken)
                            try: validator.check_report(broken)
                            except ValueError: pass
                            else: raise AssertionError('corrupt contrast accepted: ' + name)
                        receipt['channelVerifierNegativeControls'] = [name for name, _ in mutations]
                else:
                    try: validator.check_report(report)
                    except ValueError: pass
                    else: raise AssertionError('failed contrast accepted by validator')
                    case = report['cases'][0]; names = [row['api'] for row in case['calls']]
                    assert len(report['cases']) == 1 and case['error']
                    if mode in ('channels-wrong-count', 'channels-fallback', 'channels-overflow', 'channels-generate-failure'):
                        assert 'Start' not in names
                    else: assert names.count('Start') == names.count('Stop') == names.count('Release') == 1
                    if mode == 'channels-half-frame': assert case['invalidFlags'] & 2 and case['countedFrames'] == 0
                    if mode == 'channels-no-data': assert report['elapsedMillis'] >= 10000 and case['countedFrames'] == 0
                    if mode == 'channels-stop-failure': assert not case['retainedForSafety'] and next(row for row in case['calls'] if row['api'] == 'Stop')['result'] != 0
                    if mode == 'channels-release-failure': assert case['retainedForSafety']
                    if mode == 'channels-id-change': assert case['snapshots'][0]['streamId'] != case['snapshots'][1]['streamId']
                receipt['cases'].append({'case': mode, 'result': 'PASS', 'targetQualification': False,
                                         'intentionalRetentionLsanExcluded': mode == 'channels-release-failure'})
                continue
            if startup:
                assert report['protocol'] == 'AMCL_CAPTURE_STARTUP_V1' and len(report['cases']) == 1
                assert report['deadlineMillis'] == 10000 and not report['rawPcmSaved'] and not report['signalQualified']
                case = report['cases'][0]
                assert case['requestedLatencyMode'] == 1 and case['requestedChannelLayout'] is None and not case['layoutSetterCalled']
                assert not any(call['api'] == 'SetChannelLayout' for call in case['calls'])
                good = mode in ('startup-normal', 'startup-windows', 'startup-split')
                assert report['status'] == ('OBSERVED' if good else 'FAILED')
                calls = [call['api'] for call in case['calls']]
                assert calls.count('Start') == calls.count('Stop') == calls.count('Release') == 1
                if good:
                    assert report['actualFastObserved'] and case['quiescent'] and not case['retainedForSafety']
                    assert all(call['result'] == 0 for call in case['calls'])
                    assert case['s16le']['frames'] == 48000 and case['f32TotalSamples'] == 24000
                    assert len(case['windows']) == 25
                    for index, window in enumerate(case['windows']):
                        assert (window['index'], window['firstFrame'], window['frames']) == (index, index * 1920, 1920)
                        values = [32767 if mode != 'startup-normal' and i < 1920 else (i * 157) % 511 - 255
                                  for i in range(index * 1920, (index + 1) * 1920)]
                        expected_rms = math.sqrt(sum(value * value for value in values) / 1920)
                        assert abs(window['rms'] - expected_rms) < 1e-9 and window['peak'] == max(map(abs, values))
                    weighted = math.sqrt(sum(window['rms'] ** 2 * window['frames'] for window in case['windows']) / 48000)
                    assert abs(weighted - case['s16le']['rms']) < 1e-8
                    if mode == 'startup-split':
                        assert case['minimumCallbackBytes'] == case['maximumCallbackBytes'] == 694
                        assert case['offeredFrames'] > 48000
                if mode == 'startup-error': assert case['callbackErrorSeen']
                if mode == 'startup-release-failure': assert case['retainedForSafety']
                if mode == 'startup-no-data': assert report['elapsedMillis'] >= 10000 and case['s16le']['frames'] == 0
                receipt['cases'].append({'case': mode, 'result': 'PASS', 'targetQualification': False,
                                         'intentionalRetentionLsanExcluded': mode == 'startup-release-failure'})
                continue
            if layout:
                assert report['protocol'] == 'AMCL_CAPTURE_LAYOUT_V1' and not report['rawPcmSaved'] and not report['signalQualified']
                assert all(case['requestedLatencyMode'] == 1 for case in report['cases'])
                first = report['cases'][0]
                assert first['layoutSetterCalled'] and first['requestedChannelLayout'] == 4
                setters = [call for call in first['calls'] if call['api'] == 'SetChannelLayout']; assert len(setters) == 1
                if mode == 'layout-setter-failure':
                    assert len(report['cases']) == 1 and report['status'] == 'FAILED' and not report['bothFastObserved'] and setters[0]['result'] != 0
                    assert not any(call['api'] == 'Start' for call in first['calls'])
                else:
                    assert len(report['cases']) == 2 and report['status'] == 'OBSERVED' and report['bothFastObserved'] and setters[0]['result'] == 0
                    second = report['cases'][1]
                    assert not second['layoutSetterCalled'] and second['requestedChannelLayout'] is None
                    assert not any(call['api'] == 'SetChannelLayout' for call in second['calls'])
                    for case in report['cases']:
                        assert case['s16le']['frames'] == 9600 and len(case['windows']) == 5
                        for index, window in enumerate(case['windows']):
                            assert window['index'] == index and window['firstFrame'] == index * 1920 and window['frames'] == 1920
                            if mode == 'layout-windows' and index == 0: assert window['peak'] == window['rms'] == 32767
                            elif mode == 'layout-windows': assert window['peak'] <= 255
                        weighted = math.sqrt(sum(window['rms'] ** 2 * window['frames'] for window in case['windows']) / 9600)
                        assert abs(weighted - case['s16le']['rms']) < 1e-8
                    if mode == 'layout-response':
                        assert abs(first['s16le']['rms'] - rms) < 1e-9 and first['s16le']['peak'] == 255
                        assert second['s16le']['peak'] == second['s16le']['rms'] == 30000
                receipt['cases'].append({'case': mode, 'result': 'PASS', 'targetQualification': False})
                continue
            good = mode in ('normal', 'swapped', 'float-payload', 'fast-fallback')
            assert report['status'] == ('OBSERVED' if good else 'FAILED') and not report['rawPcmSaved'] and not report['signalQualified']
            if good:
                assert len(report['cases']) == 2 and report['modeContrastObserved'] is (mode != 'fast-fallback')
                for index, case in enumerate(report['cases']):
                    assert case['quiescent'] and not case['retainedForSafety'] and case['s16le']['frames'] == 9600 and case['f32TotalSamples'] == 4800
                    assert case['snapshots'][1]['fastStatus'] == (0 if mode == 'fast-fallback' else index) and case['snapshots'][1]['rate'] == 48000
                    assert all(call['result'] == 0 for call in case['calls'])
                low, high = report['cases']
                assert abs(low['s16le']['rms'] - rms) < 1e-9 and low['s16le']['peak'] == 255
                if mode == 'normal': assert abs(high['s16le']['rms'] - rms) < 1e-9
                if mode == 'swapped':
                    assert abs(high['s16le']['rms'] - swapped_rms) < 1e-9 and abs(high['s16beInterpretation']['rms'] - rms) < 1e-9
                if mode == 'float-payload':
                    assert high['f32leInterpretation']['finiteSamples'] == 4800 and high['f32leInterpretation']['peak'] == .5
            else:
                assert len(report['cases']) == 1 and report['cases'][0]['error']
                if mode == 'release-failure': assert report['cases'][0]['retainedForSafety']
                if mode == 'callback-error': assert report['cases'][0]['callbackErrorSeen']
                if mode == 'wrong-format': assert not any(row['api'] == 'Start' for row in report['cases'][0]['calls'])
                if mode == 'no-data': assert report['elapsedMillis'] >= 10000 and report['cases'][0]['s16le']['frames'] == 0
            receipt['cases'].append({'case': mode, 'result': 'PASS', 'intentionalRetentionLsanExcluded': mode == 'release-failure'})
        receipt['passed'] = True
        print('PASS fixed native capture boundary and format interpretations; errors/deadline/retained late callbacks remain explicit')
    finally:
        receipt['finishedAt'] = datetime.now().astimezone().isoformat()
        (out / 'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__': main()
