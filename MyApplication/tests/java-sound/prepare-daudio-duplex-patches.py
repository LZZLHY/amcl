#!/usr/bin/env python3
"""从锁定原文+已提交0011/0023生成0025增量，不重写已验证的播放补丁。

同源回调、捕获覆盖环与平台控制源分别进入原JDK的native目录；JNI只修实际读取长度
及原平台错误传播。输出必须是仓外全新目录，记录所有输入SHA并逐代反向验证补丁。
"""
import argparse
import datetime
import difflib
import hashlib
import json
import os
from pathlib import Path
import subprocess


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('Expected unique native read anchor: ' + old[:120])
    return text.replace(old, new, 1)


def capture_jni(text):
    """数组尾部不是本次收到的数据；部分读取不得交换其字节或掩盖native失败。"""
    text = once(text, '''        ret = DAUDIO_Read(info->handle, dataOffset, (int) len);
        if (conversionSize > 0) {
            handleSignEndianConversion(dataOffset, dataOffset, (int) len, (int) conversionSize);
        }''', '''        ret = DAUDIO_Read(info->handle, dataOffset, (int) len);
#ifdef AMCL_OHOS_DAUDIO
        /* AMCL：只转换本次实际收到的完整字节；0/失败和未写入的数组尾部保持原样。 */
        if (conversionSize > 0 && ret > 0) {
            handleSignEndianConversion(dataOffset, dataOffset, ret, (int) conversionSize);
        }
#else
        if (conversionSize > 0) {
            handleSignEndianConversion(dataOffset, dataOffset, (int) len, (int) conversionSize);
        }
#endif''')
    start = text.index('JNIEXPORT jint JNICALL Java_com_sun_media_sound_DirectAudioDevice_nRead')
    end = text.index('JNIEXPORT jint JNICALL', start + 1)
    body = text[start:end]
    body = once(body, '''        (*env)->ReleaseByteArrayElements(env, jData, (jbyte*) data, 0);''', '''        (*env)->ReleaseByteArrayElements(env, jData, (jbyte*) data, 0);
#ifdef AMCL_OHOS_DAUDIO
        /* 数组提交后才传播首个平台错误；正常无数据/停止仍按上游0返回合同处理。 */
        if (ret < 0) amcl_daudio_check(env, info->handle, "read");
#endif''')
    return text[:start] + body + text[end:]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source-manifest', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    out = args.out.resolve()
    if not args.out.is_absolute() or out.is_relative_to(repo):
        raise ValueError('Candidate output must be an absolute external directory')
    out.mkdir(parents=True, exist_ok=False)
    records = json.loads(args.source_manifest.read_text(encoding='utf-8'))['sources']
    locked = json.loads((repo / 'prebuilt/jdk/build-inputs.json').read_text())['runtimes']
    receipt = {'recordedAt': datetime.datetime.now().astimezone().isoformat(), 'majors': []}
    for major, definition in locked.items():
        tree = out / major; tree.mkdir()
        sources = []
        for entry in [e for e in records if e['major'] == major]:
            if entry['commit'] != definition['commit']: raise ValueError('Source commit mismatch')
            data = Path(entry['savedPath']).read_bytes()
            if hashlib.sha256(data).hexdigest() != entry['sha256']: raise ValueError('Source SHA changed')
            target = tree / entry['path']; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(data)
            sources.append({'path': entry['path'], 'sha256': entry['sha256']})
        patch_root = repo / 'prebuilt/jdk' / major / 'patches'
        baseline = [patch_root / ('0011-ohos-java-sound-capability.patch' if major == '8' else
                                  '0011-ohos-javasound-capabilities.patch'),
                    patch_root / '0023-ohos-javasound-daudio-playback.patch']
        env = {**os.environ, 'GIT_CEILING_DIRECTORIES': str(out)}
        command = ['git', '-c', 'core.autocrlf=false', '-c', 'core.eol=lf', 'apply']
        for patch in baseline:
            subprocess.run([*command, '--check', str(patch)], cwd=tree, env=env, check=True)
            subprocess.run([*command, str(patch)], cwd=tree, env=env, check=True)
        native = 'jdk/src/share/native/com/sun/media/sound/' if major == '8' else 'src/java.desktop/share/native/libjsound/'
        platform = 'jdk/src/solaris/native/com/sun/media/sound/' if major == '8' else 'src/java.desktop/linux/native/libjsound/'
        before = {p.relative_to(tree).as_posix(): p.read_text(encoding='utf-8') for p in tree.rglob('*') if p.is_file()}
        after = {native + 'DirectAudioDevice.c': capture_jni(before[native + 'DirectAudioDevice.c'])}
        source_files = {}
        for name in ('ohos_daudio.c', 'ohos_daudio.h', 'ohos_capture_ring.h', 'ohos_daudio_callbacks.h'):
            source = repo / 'entry/src/main/cpp/javasound' / name
            after[(platform if name.endswith('.c') else native) + name] = source.read_text(encoding='utf-8')
            source_files[name] = hashlib.sha256(source.read_bytes()).hexdigest()
        delta = []
        for name, content in sorted(after.items()):
            if before.get(name) == content: continue
            target = tree / name; target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding='utf-8', newline='\n')
            delta.extend(difflib.unified_diff(before.get(name, '').splitlines(True), content.splitlines(True),
                fromfile='a/' + name if name in before else '/dev/null', tofile='b/' + name))
        candidate = out / ('jdk' + major + '-ohos-daudio-duplex.patch')
        candidate.write_text(''.join(delta), encoding='utf-8', newline='\n')
        subprocess.run([*command, '--reverse', '--check', str(candidate)], cwd=tree, env=env, check=True)
        receipt['majors'].append({'major': major, 'patch': str(candidate),
            'sha256': hashlib.sha256(candidate.read_bytes()).hexdigest(), 'sourceCommit': definition['commit'],
            'baseline': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in baseline},
            'upstream': sources, 'shared': source_files})
        print('PASS generated and reverse-checked JDK ' + major + ' duplex increment', flush=True)
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')


if __name__ == '__main__': main()
