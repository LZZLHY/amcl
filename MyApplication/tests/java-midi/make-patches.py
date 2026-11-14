#!/usr/bin/env python3
"""从四代固定原文重放0001..0025，再生成0026草稿；不修改series和包能力门。
正式同源C/头按LF正文进入补丁，所用前序patch及原文SHA全部保存在仓外收据。
"""
import argparse
import difflib
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
from datetime import datetime


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('expected one build anchor: ' + old[:120])
    return text.replace(old, new, 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--write-patches', action='store_true')
    args = parser.parse_args()
    tests = Path(__file__).resolve().parent
    root = tests.parents[1]
    out = args.out.resolve()
    if root == out or root in out.parents:
        raise ValueError('output must be outside source checkout')
    out.mkdir(parents=True, exist_ok=False)
    reference = tests / 'reference'
    records = json.loads((reference / 'source.json').read_text())['files']
    for row in records:
        assert digest(reference / row['file']) == row['sha256'], row['file']
    spec = importlib.util.spec_from_file_location('midi_java_patch', tests / 'patch-java.py')
    patcher = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(patcher)
    native = root / 'entry/src/main/cpp/javasound'
    names = ['midi_api.c', 'midi_api.h', 'midi_callbacks.h', 'midi_core.c', 'midi_core.h',
             'midi_stream.c', 'midi_stream.h', 'midi_ump.c', 'midi_ump.h', 'midi_jdk.c']
    source_names = [name for name in names if name.endswith('.c')]
    original_jni = 'MidiInDevice.c MidiOutDevice.c MidiInDeviceProvider.c MidiOutDeviceProvider.c PlatformMidi.c'
    receipt = {'startedAt': datetime.now().astimezone().isoformat(), 'majors': [],
               'scope': 'draft patch replay/source identity, not full JDK build or target MIDI transport'}
    for major in ('8', '17', '21', '25'):
        work = out / major
        before, after = work / 'before', work / 'after'
        before.mkdir(parents=True)
        selected = [row for row in records if row['major'] == major and
                    (row['path'].endswith(('.java', '.c', '.gmk')) or '/make/mapfiles/' in row['path'])]
        paths = {row['path'] for row in selected}
        for row in selected:
            target = before / row['path']
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(reference / row['file'], target)
        patch_dir = root / 'prebuilt/jdk' / major / 'patches'
        predecessors = []
        for line in (patch_dir / 'series').read_text().splitlines():
            line = line.strip()
            if not line or line.startswith('#') or int(line[:4]) > 25:
                continue
            patch = patch_dir / line
            predecessors.append({'name': line, 'sha256': digest(patch)})
            touched = set(re.findall(r'^\+\+\+ b/(.+)$', patch.read_text(), re.M))
            included = sorted(paths & touched)
            if not included:
                continue
            command = ['git', '-c', 'core.autocrlf=false', 'apply', '--whitespace=nowarn', *['--include=' + p for p in included], str(patch)]
            result = subprocess.run(command, cwd=before, capture_output=True)
            (work / (line + '.apply.stdout')).write_bytes(result.stdout)
            (work / (line + '.apply.stderr')).write_bytes(result.stderr)
            if result.returncode:
                raise RuntimeError('prior patch failed: ' + major + '/' + line)
        shutil.copytree(before, after)
        java_dir = 'jdk/src/share/classes/com/sun/media/sound' if major == '8' else 'src/java.desktop/share/classes/com/sun/media/sound'
        sources = {p.name: p.read_text(encoding='utf-8') for p in (after / java_dir).glob('*.java')}
        for name, text in patcher.transform(sources).items():
            (after / java_dir / name).write_text(text, encoding='utf-8', newline='\n')
        native_dir = 'jdk/src/solaris/native/com/sun/media/sound' if major == '8' else 'src/java.desktop/linux/native/libjsound'
        (after / native_dir).mkdir(parents=True, exist_ok=True)
        for name in names:
            # LF是同源输入合同；意外CRLF不能悄悄改变补丁正文/来源身份。
            data = (native / name).read_bytes()
            if b'\r' in data:
                raise ValueError('native source must have LF checkout: ' + name)
            (after / native_dir / name).write_bytes(data)
        share = 'jdk/src/share/native/com/sun/media/sound' if major == '8' else 'src/java.desktop/share/native/libjsound'
        for direction in ('In', 'Out'):
            provider = after / share / ('Midi' + direction + 'DeviceProvider.c')
            provider.write_text(provider.read_text() + '''
/* AMCL：非OHOS保留原平台枚举合同；新Java看到null继续使用原native索引和缓存。
 * OHOS构建排除此上游JNI单元，改用同名标准接口的midi_jdk.c统一快照实现。 */
JNIEXPORT jobjectArray JNICALL
Java_com_sun_media_sound_MidiDIRECTIONDeviceProvider_nGetDeviceInfos(JNIEnv* env, jclass cls) {
    (void)env; (void)cls; return NULL;
}
'''.replace('DIRECTION', direction), encoding='utf-8', newline='\n')
        build_path = 'jdk/make/lib/SoundLibraries.gmk' if major == '8' else 'make/modules/java.desktop/Lib.gmk'
        build = (after / build_path).read_text()
        if major == '8':
            build = once(build, '-DUSE_PLATFORM_MIDI_IN=FALSE -DUSE_PLATFORM_MIDI_OUT=FALSE -DAMCL_OHOS_DAUDIO=1',
                         '-DUSE_PLATFORM_MIDI_IN=TRUE -DUSE_PLATFORM_MIDI_OUT=TRUE -DAMCL_OHOS_DAUDIO=1 -DAMCL_OHOS_MIDI=1')
            build = once(build, '    LIBJSOUND_SRC_FILES += $(LIBJSOUND_DAUDIOFILES) ohos_daudio.c',
                         '    LIBJSOUND_SRC_FILES += $(LIBJSOUND_DAUDIOFILES) ohos_daudio.c ' + ' '.join(source_names))
            platform = after / share / 'Platform.c'
            text = platform.read_text()
            text = once(text, '    return feature == com_sun_media_sound_Platform_FEATURE_DIRECT_AUDIO ?',
                        '''    /* AMCL：MIDI JNI已在主库实现；平台provider仍在API20运行时可选。 */
    if (feature == com_sun_media_sound_Platform_FEATURE_MIDIIO) return com_sun_media_sound_Platform_LIB_MAIN;
    return feature == com_sun_media_sound_Platform_FEATURE_DIRECT_AUDIO ?''')
            platform.write_text(text, encoding='utf-8', newline='\n')
            # JDK8显式version-script会隐藏新JNI/自有身份；真实链接产物必须能查到，
            # 不能以源上JNIEXPORT属性推断已经导出。通配生命周期标记允许非OHOS无定义。
            for library in ('libjsound', 'libjsoundalsa'):
                mapfile = after / ('jdk/make/mapfiles/' + library + '/mapfile-vers')
                extra = ('            JNI_OnUnload*;\n            AMCL_Midi_BackendIdentity*;\n' if library == 'libjsound' else '')
                extra += '            Java_com_sun_media_sound_MidiInDeviceProvider_nGetDeviceInfos;\n'
                extra += '            Java_com_sun_media_sound_MidiOutDeviceProvider_nGetDeviceInfos;\n'
                mapfile.write_text(once(mapfile.read_text(), '\tglobal:\n', '\tglobal:\n' + extra), encoding='utf-8', newline='\n')
        else:
            build = once(build, '  LIBJSOUND_EXCLUDE_FILES := ohos_daudio.c',
                         '  LIBJSOUND_EXCLUDE_FILES := ohos_daudio.c ' + ' '.join(source_names))
            build = once(build, '-DUSE_PORTS=FALSE -DUSE_PLATFORM_MIDI_OUT=FALSE -DUSE_PLATFORM_MIDI_IN=FALSE -DAMCL_OHOS_DAUDIO=1',
                         '-DUSE_PORTS=FALSE -DUSE_PLATFORM_MIDI_OUT=TRUE -DUSE_PLATFORM_MIDI_IN=TRUE -DAMCL_OHOS_DAUDIO=1 -DAMCL_OHOS_MIDI=1')
            anchor = '    LIBJSOUND_EXCLUDE_FILES := $(notdir $(wildcard $(TOPDIR)/src/java.desktop/linux/native/libjsound/PLATFORM_API_LinuxOS_ALSA*.c))'
            build = once(build, anchor, anchor + ' ' + original_jni)
        (after / build_path).write_text(build, encoding='utf-8', newline='\n')
        diffs = []
        for path in sorted(p.relative_to(after).as_posix() for p in after.rglob('*') if p.is_file()):
            old = (before / path).read_text(encoding='utf-8') if (before / path).exists() else ''
            new = (after / path).read_text(encoding='utf-8')
            if old != new:
                diffs += difflib.unified_diff(old.splitlines(True), new.splitlines(True),
                    'a/' + path if (before / path).exists() else '/dev/null', 'b/' + path)
        patch_name = '0026-ohos-javasound-native-midi.patch'
        patch = work / patch_name
        patch.write_text(''.join(diffs), encoding='utf-8', newline='\n')
        verify = work / 'replay'
        shutil.copytree(before, verify)
        result = subprocess.run(['git', '-c', 'core.autocrlf=false', 'apply', '--check', str(patch)], cwd=verify, capture_output=True)
        (work / 'candidate-check.log').write_bytes(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError('draft failed git apply --check: ' + major)
        subprocess.run(['git', '-c', 'core.autocrlf=false', 'apply', '--whitespace=nowarn', str(patch)], cwd=verify, check=True)
        for path in after.rglob('*'):
            if path.is_file():
                assert digest(path) == digest(verify / path.relative_to(after)), str(path)
        if args.write_patches:
            shutil.copyfile(patch, patch_dir / patch_name)
        receipt['majors'].append({'major': major, 'patch': str(patch), 'patchSha256': digest(patch),
            'predecessors': predecessors, 'postimage': {p.relative_to(after).as_posix(): digest(p) for p in after.rglob('*') if p.is_file()}})
        print('PASS draft replay ' + major, flush=True)
    receipt['finishedAt'] = datetime.now().astimezone().isoformat()
    (out / 'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
