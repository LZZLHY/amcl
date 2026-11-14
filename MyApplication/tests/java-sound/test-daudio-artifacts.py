#!/usr/bin/env python3
"""实际 SDK AArch64 后端与四个真实旧发行库的音频产物门正负控。

所有破坏只写外置副本；原 SDK、候选 ZIP、旧收据均只读。变更 ELF 内容/依赖/映射及
实际 SDK 供应者，证明门禁能拒绝仅有字符串或缺真实链接的伪声明。
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import runpy
import shutil
import struct
import sys
import zipfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--sdk-library-dir', type=Path, required=True)
    parser.add_argument('--old-candidates', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--duplex', action='store_true')
    parser.add_argument('--timeline', action='store_true')
    parser.add_argument('--playback-fixture', type=Path, help='required with duplex: immutable real SDK V1 fixture')
    parser.add_argument('--duplex-fixture', type=Path, help='required with timeline: immutable real SDK V2 fixture')
    args = parser.parse_args()
    if args.timeline: args.duplex = True
    repo = Path(__file__).resolve().parents[2]
    out = args.out.resolve()
    if not args.out.is_absolute() or out.is_relative_to(repo): raise ValueError('external absolute output required')
    out.mkdir(parents=True, exist_ok=False)
    # run_path不会自动加入脚本目录；依赖必须来自与该生产打包器同一工作树的真实模块。
    sys.path.insert(0, str(repo / 'docker/scripts'))
    module = runpy.run_path(str(repo / 'docker/scripts/package_runtime.py'))
    facts, audit = module['elf_facts'], module['validate_sound_backend']
    data = args.fixture.read_bytes(); cases = []
    if args.duplex and not args.playback_fixture: raise ValueError('duplex requires actual old playback fixture')
    if args.timeline and not args.duplex_fixture: raise ValueError('timeline requires actual V2 fixture')
    result = audit(facts(data), args.sdk_library_dir, require_playback=True,
                   require_duplex=args.duplex, require_timeline=args.timeline)
    assert result['qualification'] == 'implemented-requires-device-test' and result['minimumApi'] == 20
    assert result['capture'] == ('implemented-requires-permission-and-device-test' if args.duplex else 'not-implemented')
    cases.append({'name': 'actual SDK-linked backend', 'result': result, 'sha256': hashlib.sha256(data).hexdigest()})
    for major in ['8', '17', '21', '25']:
        archive = args.old_candidates / ('jdk' + major + '-ohos-20261021-repair4.zip')
        member = 'jre/lib/aarch64/libjsound.so' if major == '8' else 'lib/libjsound.so'
        with zipfile.ZipFile(archive) as z: old = z.read(member)
        assert audit(facts(old), args.sdk_library_dir) is None
        try:
            audit(facts(old), args.sdk_library_dir, require_playback=True)
        except ValueError as error:
            assert '缺少后端' in str(error)
        else:
            raise AssertionError('new recipe silently accepted old backend: ' + major)
        cases.append({'name': 'actual repair4 ' + major, 'result': 'unavailable-safe unchanged',
                      'archive': str(archive), 'member': member, 'sha256': hashlib.sha256(old).hexdigest()})
    if args.duplex:
        playback = args.playback_fixture.read_bytes()
        assert audit(facts(playback), args.sdk_library_dir)['capture'] == 'not-implemented'
        try: audit(facts(playback), args.sdk_library_dir, require_duplex=True)
        except ValueError as error:
            assert '0025' in str(error)
        else: raise AssertionError('0025 identity accepted old playback-only artifact')
        cases.append({'name': 'actual old V1 playback', 'result': 'unchanged and cannot satisfy0025',
                      'sha256': hashlib.sha256(playback).hexdigest()})
    if args.timeline:
        duplex = args.duplex_fixture.read_bytes()
        old = audit(facts(duplex), args.sdk_library_dir)
        assert old['backend'] == 'ohos-daudio-duplex-v2' and old['embeddedCallbacks'] == 'signed-host-data-abi-v1-required'
        try: audit(facts(duplex), args.sdk_library_dir, require_timeline=True)
        except ValueError as error: assert '0028' in str(error)
        else: raise AssertionError('0028 identity accepted old V2 artifact')
        assert result['backend'] == 'ohos-daudio-duplex-v3' and result['embeddedCallbacks'] == 'signed-host-data-abi-v2-required'
        cases.append({'name': 'actual old V2 duplex', 'result': 'unchanged and cannot satisfy0028',
                      'sha256': hashlib.sha256(duplex).hexdigest()})

    def negative(name, changed, provider=args.sdk_library_dir):
        """只接纳 ValueError/OSError；不是把任意测试脚本崩溃冒充反例成立。"""
        p = out / (name + '.so'); p.write_bytes(changed)
        try:
            audit(facts(changed), provider)
        except (ValueError, OSError) as error:
            cases.append({'name': name, 'result': 'REJECTED', 'reason': str(error),
                          'sha256': hashlib.sha256(changed).hexdigest()})
            return
        raise AssertionError('invalid artifact accepted: ' + name)

    marker = b'AMCL_DAUDIO_OHOS_API20_DUPLEX_V3\0' if args.timeline else b'AMCL_DAUDIO_OHOS_API20_DUPLEX_V2\0' if args.duplex else b'AMCL_DAUDIO_OHOS_API20_PLAYBACK_V1\0'
    assert data.count(marker) == 1
    negative('wrong-marker', data.replace(marker, b'X' + marker[1:]))
    negative('no-audio-dependency', data.replace(b'libohaudio.so\0', b'libnxaudio.so\0'))
    negative('missing-start-provider', data.replace(b'OH_AudioRenderer_Start\0', b'OH_AudioRenderer_StXrt\0'))
    if args.duplex:
        negative('missing-capture-start', data.replace(b'OH_AudioCapturer_Start\0', b'OH_AudioCapturer_StXrt\0'))
        negative('missing-capture-route', data.replace(b'OH_AudioRoutingManager_GetPreferredInputDevice\0',
                                                     b'OH_AudioRoutingManager_GetPreferredInpXtDevice\0'))
    if args.timeline:
        negative('missing-presentation-provider', data.replace(b'OH_AudioRenderer_GetAudioTimestampInfo\0',
                                                              b'OH_AudioRenderer_GetAudioTimestampInfX\0'))
    negative('no-named-marker', data.replace(b'.amcl.daudio\0', b'.amcl.zzzzzz\0'))
    # 用实际节表定位字节，只改写标记属性/加载映射，源夹具保持原样。
    shoff = struct.unpack_from('<Q', data, 40)[0]
    shnum, names_index = struct.unpack_from('<HH', data, 60)
    sections = [struct.unpack_from('<IIQQQQIIQQ', data, shoff + 64 * i) for i in range(shnum)]
    names = sections[names_index]; strings = data[names[4]:names[4] + names[5]]
    index = next(i for i, s in enumerate(sections) if strings[s[0]:].split(b'\0', 1)[0] == b'.amcl.daudio')
    changed = bytearray(data); struct.pack_into('<Q', changed, shoff + 64 * index + 8, 3)
    negative('writable-section-marker', bytes(changed))
    changed = bytearray(data); struct.pack_into('<Q', changed, shoff + 64 * index + 8, 0)
    negative('unallocated-section-marker', bytes(changed))
    phoff = struct.unpack_from('<Q', data, 32)[0]; phnum = struct.unpack_from('<H', data, 56)[0]
    for n in range(phnum):
        ph = struct.unpack_from('<IIQQQQQQ', data, phoff + n * 56)
        if ph[0] == 1 and ph[2] <= sections[index][4] < ph[2] + ph[5]:
            changed = bytearray(data); struct.pack_into('<I', changed, phoff + n * 56 + 4, ph[1] | 2)
            negative('writable-load-marker', bytes(changed)); break
    else: raise AssertionError('fixture marker is not mapped')
    negative('missing-sdk-provider', data, out / 'missing-sdk')
    wrong = out / 'wrong-provider'; wrong.mkdir(); shutil.copyfile(args.sdk_library_dir / 'libc.so', wrong / 'libohaudio.so')
    negative('unrelated-real-sdk-provider', data, wrong)
    print('PASS actual SDK backend + four unchanged repair4 libraries + required-backend and artifact rejection cases: ' + str(len(cases)))
    (out / 'receipt.json').write_text(json.dumps({'recordedAt': datetime.datetime.now().astimezone().isoformat(),
        'packagerSha256': hashlib.sha256((repo / 'docker/scripts/package_runtime.py').read_bytes()).hexdigest(),
        'cases': cases}, indent=2), encoding='utf-8')


if __name__ == '__main__': main()
