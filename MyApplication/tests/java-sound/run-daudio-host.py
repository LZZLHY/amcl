#!/usr/bin/env python3
"""编译实际 OHOS DAUDIO 源与官方 SDK 声明，独立 ASan/UBSan 回归；产物必须显式外置。

宿主 GCC 只移除平台 availability 注解，不替换任何 API 声明、参数类型或其它 attribute。
SDK 目标编译单独使用完整原始 sysroot，此脚本不能替代目标/实际设备验证。
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--sdk-headers', required=True, type=Path)
    parser.add_argument('--jdk-headers', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--duplex', action='store_true', help='include actual Capture facade before complete Playback regression')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    native = repo / 'entry/src/main/cpp/javasound'
    tests = Path(__file__).resolve().parent
    test_source = tests / ('daudio_capture_backend_test.c' if args.duplex else 'daudio_backend_test.c')
    inputs = [native / 'ohos_daudio.c', native / 'ohos_daudio.h', native / 'ohos_capture_ring.h',
              native / 'ohos_daudio_callbacks.h', native / 'ohos_playback_timeline.h',
              tests / 'daudio_backend_test.c', tests / 'daudio_test_main.c',
              tests / 'audio_timing_callback_test.cpp', tests / 'daudio_zero_return_reference.h',
              tests / 'playback_timeline_test.c', tests / 'daudio_position_test.c', tests / 'daudio_position_main.c',
              repo / 'entry/src/main/cpp/napi/jdk_audio_timing_qualification.cpp']
    if args.duplex: inputs.append(test_source)
    receipt = {'startedAt': datetime.datetime.now().astimezone().isoformat(),
               'sources': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}, 'commands': []}

    def run(argv, label):
        """每条命令保存原输出及状态，失败立即停止；没有用关键字代替真实 exit code。"""
        result = subprocess.run(argv, capture_output=True, timeout=90, env={**os.environ,
            'ASAN_OPTIONS': 'detect_leaks=1:abort_on_error=1', 'UBSAN_OPTIONS': 'halt_on_error=1:print_stacktrace=1'})
        (out / (label + '.stdout')).write_bytes(result.stdout)
        (out / (label + '.stderr')).write_bytes(result.stderr)
        receipt['commands'].append({'argv': argv, 'returncode': result.returncode})
        print(result.stdout.decode('utf-8', 'replace'), end='', flush=True)
        print(result.stderr.decode('utf-8', 'replace'), end='', flush=True)
        if result.returncode:
            raise RuntimeError(label + ' failed: ' + str(result.returncode))

    try:
        flags = ['-std=c99', '-D_GNU_SOURCE', '-DX_PLATFORM=2', '-DUSE_DAUDIO=1', '-Wall', '-Wextra',
                 '-Werror', '-g', '-O1', '-fno-omit-frame-pointer', '-fsanitize=address,undefined',
                 '-D__availability__(...)=', '-I' + str(args.sdk_headers), '-I' + str(args.jdk_headers),
                 '-I' + str(native), '-pthread']
        run(['gcc', '--version'], 'compiler')
        run(['gcc', *flags, '-fPIC', '-shared', str(native / 'ohos_daudio.c'),
             str(test_source), '-ldl', '-o', str(out / 'libdaudio-test.so')], 'compile-library')
        run(['gcc', *flags, str(tests / 'daudio_test_main.c'), '-ldl', '-o', str(out / 'run')], 'compile-main')
        run([str(out / 'run'), str(out / 'libdaudio-test.so')], 'test')
        # 此独立回归只运行固定timing回调的字节/budget逻辑，从不创建OHAudio或启动设备。
        cpp_flags = [arg for arg in flags if arg != '-std=c99']
        run(['g++', '-std=c++17', *cpp_flags, str(tests / 'audio_timing_callback_test.cpp'),
             '-ldl', '-o', str(out / 'timing-callback')], 'compile-timing-callback')
        run([str(out / 'timing-callback')], 'timing-callback')
        run(['gcc', *flags, str(tests / 'playback_timeline_test.c'), '-o', str(out / 'timeline')], 'compile-timeline')
        run([str(out / 'timeline')], 'timeline')
        run(['gcc', *flags, '-fPIC', '-shared', str(native / 'ohos_daudio.c'),
             str(tests / 'daudio_position_test.c'), '-ldl', '-o', str(out / 'position.so')], 'compile-position')
        run(['gcc', *flags, str(tests / 'daudio_position_main.c'), '-ldl', '-o', str(out / 'position')], 'compile-position-main')
        run([str(out / 'position'), str(out / 'position.so')], 'position')
        receipt['result'] = 'PASS'
    finally:
        receipt['completedAt'] = datetime.datetime.now().astimezone().isoformat()
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()
