"""真实 OpenAL/生产 OHAudio 后端的宿主契约验证；每例独立进程，无物理音频输出。"""
import argparse
import ctypes as C
import json
import math
import os
import re
from pathlib import Path
import subprocess
import sys
import time

P, I, U, F = C.c_void_p, C.c_int, C.c_uint, C.c_float


def run_case(library, output, case):
    """只替换系统服务；通过标准 ALC/AL API 检查错误、音频输出和生命周期。"""
    output.mkdir(parents=True, exist_ok=True)
    config = output / (case + '.conf')
    config.write_text('[general]\nchannels=stereo\nsample-type=float32\nfrequency=48000\nhrtf=false\n')
    os.environ.update(ALSOFT_DRIVERS='ohaudio', ALSOFT_CONF=str(config),
                      ALSOFT_LOGLEVEL='3', ALSOFT_LOGFILE=str(output / (case + '.log')),
                      AMCL_AUDIO_DIAGNOSTICS='1' if case == 'diagnostics-on' else '0')
    if case == 'diagnostics-default':
        # 缺省必须单独验证，不能只用显式0代替用户未配置时的行为。
        os.environ.pop('AMCL_AUDIO_DIAGNOSTICS', None)
    lib = C.CDLL(str(library))
    def bind(name, result, *args):
        fn = getattr(lib, name)
        fn.restype, fn.argtypes = result, list(args)
        return fn
    open_device = bind('alcOpenDevice', P, C.c_char_p)
    create = bind('alcCreateContext', P, P, P)
    current = bind('alcMakeContextCurrent', I, P)
    destroy = bind('alcDestroyContext', None, P)
    close = bind('alcCloseDevice', I, P)
    get = bind('alcGetIntegerv', None, P, I, I, P)
    fault = bind('auditFault', None, I, I, I)
    info = bind('auditInfo', I, I)
    pump = bind('auditPump', I, P, I, I)
    interrupt = bind('auditInterrupt', None, I, I)
    error = bind('auditError', None, I)
    def value(device, token):
        result = I()
        get(device, token, 1, C.byref(result))
        return result.value
    def wait_for(predicate):
        limit = time.monotonic() + 2
        while not predicate():
            if time.monotonic() > limit:
                raise AssertionError('控制事件未在有界时间内完成')
            time.sleep(.01)
    operation = int(case.split('-')[1]) if case.startswith('reject-') else 0
    fault(operation, int(case == 'fast-fallback'), 1 if case == 'actual-format' else -1)
    device = open_device(None)
    assert device
    attrs = (I * 5)(0x1007, 48000, 0x199A, 0, 0) if case == 'limiter-off' else (I * 3)(0x1007, 48000, 0)
    context = create(device, attrs)
    result = {'case': case, 'contextCreated': bool(context)}
    if operation:
        assert not context, '必需接口拒绝时不能创建成功'
    else:
        assert context
        current(context)
        wait_for(lambda: info(4) == 2)
        assert info(5) == 1 and info(6) == 1
        if case in ('diagnostics-on', 'diagnostics-off', 'diagnostics-default'):
            # 经真实OpenAL混音回调，最终日志核对显式计时许可；不能以没发生回调伪装关闭。
            data = C.create_string_buffer(1920)
            for _ in range(10): assert pump(data, 1920, 0) == 0
        if case == 'control-burst':
            # 连续中断可合并，但最终状态与STOP锁存必须保留，且结束时控制线程必须可join。
            for _ in range(200): interrupt(0, 2); interrupt(0, 1)
            interrupt(0, 2); wait_for(lambda: info(4) == 5)
            interrupt(0, 1); wait_for(lambda: info(4) == 2)
            interrupt(0, 3); interrupt(0, 1); wait_for(lambda: info(4) == 3)
        result.update(actualRate=info(0), actualChannels=info(1), actualFormat=info(2),
                      limiter=value(device, 0x199A), generateCalls=info(8))
        if case == 'fast-fallback':
            assert info(3) == 0 and info(8) == 2
        if case == 'actual-format':
            assert info(2) == 1
        if case == 'boundaries':
            for size in (-1, 0, 1, 7, 9, 1919, 1920):
                n = max(size, 0)
                data = C.create_string_buffer(n + 16)
                C.memset(data, 0x5A, n + 16)
                returned = pump(data, size, 0)
                assert returned == (-1 if size <= 0 else 0)
                assert data.raw[n:] == b'Z' * 16, '不能写越界'
                if size > 0:
                    assert data.raw[:n] == b'\0' * n, '有效缓冲必须全部填充'
            assert pump(None, 8, 0) == -1
        if case == 'interruptions':
            interrupt(1, 2); wait_for(lambda: info(4) == 5)
            assert value(device, 0x313) == 1, '临时暂停不是断连'
            interrupt(0, 1); wait_for(lambda: info(4) == 2)
            interrupt(1, 4); wait_for(lambda: info(7) == 200)
            interrupt(1, 5); wait_for(lambda: info(7) == 1000)
            interrupt(0, 3); wait_for(lambda: info(4) == 3)
            starts = info(11)
            interrupt(0, 1)
            time.sleep(.15)
            assert info(4) == 3 and info(11) == starts, 'STOP 后 RESUME 不能自行重启'
        if case == 'user-pause':
            pause = bind('alcDevicePauseSOFT', None, P)
            resume = bind('alcDeviceResumeSOFT', None, P)
            pause(device)
            interrupt(0, 1)
            time.sleep(.15)
            assert info(4) == 3
            resume(device); wait_for(lambda: info(4) == 2)
        if case == 'runtime-error':
            error(3); wait_for(lambda: value(device, 0x313) == 0)
            data = C.create_string_buffer(64)
            C.memset(data, 0x5A, 64)
            assert pump(data, 64, 0) == 0 and data.raw == b'\0' * 64
        if case in ('default-limiter', 'limiter-off'):
            gen_buffer = bind('alGenBuffers', None, I, P)
            buffer_data = bind('alBufferData', None, U, I, P, I, I)
            gen_sources = bind('alGenSources', None, I, P)
            source_i = bind('alSourcei', None, U, I, I)
            play = bind('alSourcePlayv', None, I, P)
            delete_sources = bind('alDeleteSources', None, I, P)
            delete_buffers = bind('alDeleteBuffers', None, I, P)
            samples = (F * 48000)(*(.75 * math.sin(2 * math.pi * 440 * i / 48000) for i in range(48000)))
            buffer = U(); gen_buffer(1, C.byref(buffer))
            buffer_data(buffer.value, 0x10010, samples, C.sizeof(samples), 48000)
            sources = (U * 4)(); gen_sources(4, sources)
            for source in sources: source_i(source, 0x1009, buffer.value)
            play(4, sources)
            peak = 0.
            for _ in range(120):
                mixed = (F * 480)()
                assert pump(mixed, C.sizeof(mixed), 0) == 0
                peak = max(peak, max(abs(float(x)) for x in mixed))
            result['peak'] = peak
            if case == 'default-limiter': assert result['limiter'] == 1 and peak <= 1.001 and peak > .1
            else: assert result['limiter'] == 0 and peak > 1.1
            delete_sources(4, sources); delete_buffers(1, C.byref(buffer))
        if case == 'release-failure': fault(23, 0, -1)
        current(None); destroy(context)
    assert close(device)
    assert info(9) == 0
    if case == 'release-failure':
        data = C.create_string_buffer(64)
        C.memset(data, 0x5A, 64)
        assert pump(data, 64, 1) == 0 and data.raw == b'\0' * 64
        result['nativeReleaseUnacknowledged'] = info(10)
        assert info(10) == 1, '如实保留模拟平台释放失败，不能伪造已释放'
    else:
        assert info(10) == 0, '正常/配置失败路径应完整回收 renderer'
    # 开关检查覆盖真实OpenAL创建/回读/回调/Release，而不是另写一份诊断算法。
    log = (output / (case + '.log')).read_text()
    markers = ('AMCL_OHAUDIO_PHASE', 'AMCL_OHAUDIO_RELEASE_PHASE', 'AMCL_OHAUDIO_MAPS_BEGIN')
    if case == 'diagnostics-on':
        counters = re.findall(r'sampledCallbacks=(\d+)', log)
        assert counters and max(map(int, counters)) > 0, '显式诊断须取得真实回调样本'
        assert all(marker in log for marker in markers), '必须实际执行创建/释放和maps诊断正例'
    else:
        assert not any(marker in log for marker in markers), '关闭或缺省不能执行阶段日志/maps转储'
        if case in ('diagnostics-off', 'diagnostics-default'):
            assert 'sampledCallbacks=' not in log, '静默运行不能输出纯诊断停止统计'
    return result


def main():
    """父进程限定每例时限并保存结果；无设备也能验证失败路径与真实混音。"""
    parser = argparse.ArgumentParser()
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--case')
    args = parser.parse_args()
    if args.case:
        print(json.dumps(run_case(args.library.resolve(), args.output.resolve(), args.case)))
        return
    cases = [f'reject-{n}' for n in list(range(1, 14)) + [20, 100, 101]]
    cases += ['normal', 'fast-fallback', 'actual-format', 'boundaries', 'interruptions',
              'user-pause', 'runtime-error', 'release-failure', 'default-limiter', 'limiter-off',
              'control-burst', 'diagnostics-on', 'diagnostics-off', 'diagnostics-default']
    results = []
    args.output.mkdir(parents=True, exist_ok=True)
    for case in cases:
        child = subprocess.run([sys.executable, '-B', __file__, '--library', str(args.library.resolve()),
            '--output', str(args.output.resolve()), '--case', case], capture_output=True, text=True, timeout=20)
        if child.returncode:
            raise RuntimeError(case + '\n' + child.stdout + child.stderr)
        result = json.loads(child.stdout.strip().splitlines()[-1])
        results.append(result)
        print('PASS ' + case, flush=True)
    (args.output / 'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2))
    print(f'OHAudio production backend: {len(results)}/{len(cases)} passed', flush=True)


if __name__ == '__main__':
    main()
