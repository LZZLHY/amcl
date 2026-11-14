#!/usr/bin/env python3
"""为现有 java-sound-17 QA 生成一个小型、完整 SHA 闭包，输出必须仓外全新目录。

只复制候选 patch、单一后端源、实际 SDK 声明和本套件源码；JDK 原文仍由 QA 的已登记
源卷按锁定 Git HEAD 取出，运行中不联网，不修改源卷或任一正在构建的树。
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import shutil


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--sdk-include', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--duplex', action='store_true', help='freeze incremental0025 after immutable0011/0023')
    parser.add_argument('--timeline', action='store_true', help='freeze incremental0028 after immutable0011/0023/0025')
    args = parser.parse_args()
    if args.timeline: args.duplex = True
    repo = Path(__file__).resolve().parents[2]
    out = args.out.resolve()
    if not args.out.is_absolute() or out.is_relative_to(repo): raise ValueError('external absolute output required')
    out.mkdir(parents=True, exist_ok=False)
    candidate = args.candidate.resolve()
    record = next(x for x in json.loads((candidate / 'receipt.json').read_text())['majors'] if x['major'] == '17')
    patch = candidate / ('jdk17-ohos-daudio-timeline.patch' if args.timeline else
                          'jdk17-ohos-daudio-duplex.patch' if args.duplex else 'jdk17-ohos-daudio.patch')
    if hashlib.sha256(patch.read_bytes()).hexdigest() != record['sha256']: raise ValueError('candidate SHA changed')
    locked = json.loads((repo / 'prebuilt/jdk/build-inputs.json').read_text())['runtimes']['17']['commit']
    if record['sourceCommit'] != locked: raise ValueError('candidate source commit changed')
    copies = {patch: 'candidate.patch',
              repo / 'prebuilt/jdk/17/patches/0011-ohos-javasound-capabilities.patch': 'baseline-0011.patch'}
    if args.duplex:
        copies[repo / 'prebuilt/jdk/17/patches/0023-ohos-javasound-daudio-playback.patch'] = 'baseline-0023.patch'
    if args.timeline:
        copies[repo / 'prebuilt/jdk/17/patches/0025-ohos-javasound-duplex-host-callbacks.patch'] = 'baseline-0025.patch'
    tests = ['daudio_backend_test.c', 'daudio_jni_control.c', 'DaudioJniRegression.java', 'SoundLifecycleRegression.java']
    if args.duplex: tests += ['DaudioCaptureJniRegression.java', 'daudio_capture_jni_control.c']
    if args.timeline: tests += ['DaudioTimelineJniRegression.java']
    for name in tests:
        copies[repo / 'tests/java-sound' / name] = 'tests/' + name
    backend = ['ohos_daudio.c', 'ohos_daudio.h']
    if args.duplex: backend += ['ohos_capture_ring.h', 'ohos_daudio_callbacks.h']
    if args.timeline: backend += ['ohos_playback_timeline.h']
    for name in backend:
        copies[repo / 'entry/src/main/cpp/javasound' / name] = 'backend/' + name
    for directory in ['ohaudio', 'info']:
        for path in (args.sdk_include / directory).glob('*.h'):
            copies[path] = 'sdk/' + directory + '/' + path.name
    copies[args.sdk_include / 'multimedia/native_audio_channel_layout.h'] = 'sdk/multimedia/native_audio_channel_layout.h'
    files = []
    for source, relative in sorted(copies.items(), key=lambda x: x[1]):
        data = source.read_bytes(); target = out / relative; target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        files.append({'path': relative, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(), 'source': str(source.resolve())})
    manifest = {'schema': 'amcl-daudio-jni-inputs/v3' if args.timeline else
                         'amcl-daudio-jni-inputs/v2' if args.duplex else 'amcl-daudio-jni-inputs/v1',
                'major': 17, 'sourceCommit': locked,
                'createdAt': datetime.datetime.now().astimezone().isoformat(), 'files': files}
    path = out / 'manifest.json'; path.write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    print(json.dumps({'manifest': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}))


if __name__ == '__main__': main()
