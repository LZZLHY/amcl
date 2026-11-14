#!/usr/bin/env python3
"""将已验证0025后的单源时钟/ABI2修复生成为0028增量；所有历史patch原字节保留。"""
import argparse
import datetime
import difflib
import hashlib
import json
import os
from pathlib import Path
import subprocess


def once(text, old, new):
    if text.count(old) != 1: raise ValueError('Expected unique JNI anchor: ' + old[:120])
    return text.replace(old, new, 1)


def timeline_jni(text):
    """查询遇到尚未报告的真实平台错误必须传播；已报告首错不污染close的清理链。"""
    text = once(text, '''static void amcl_daudio_check(JNIEnv *env, void *handle, const char *operation) {
    amcl_daudio_error(env, AMCL_DAudio_GetError(handle), operation);
}''', '''static void amcl_daudio_check(JNIEnv *env, void *handle, const char *operation) {
    int error = AMCL_DAudio_GetError(handle);
    if (error) {
        amcl_daudio_error(env, error, operation);
        /* AMCL：只有已产生待传播异常才确认报告；数据读写仍按原合同拒绝永久失败。 */
        if ((*env)->ExceptionCheck(env)) AMCL_DAudio_MarkErrorReported(handle);
    }
}''')
    for call, operation in [
        ('ret = DAUDIO_GetAvailable(info->handle, (int) isSource);', 'available'),
        ('ret = DAUDIO_GetBytePosition(info->handle, (int) isSource, (INT64) javaBytePos);', 'position')]:
        text = once(text, '        ' + call, '        ' + call + '''
#ifdef AMCL_OHOS_DAUDIO
        /* 后台服务也可能观察到平台失败，首次公开查询不得将它静默变成0/旧位置。 */
        if (AMCL_DAudio_GetPendingError(info->handle)) amcl_daudio_check(env, info->handle, "''' + operation + '''");
#endif''')
    return text


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source-manifest', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]; out = args.out.resolve()
    if not args.out.is_absolute() or out.is_relative_to(repo): raise ValueError('absolute external output required')
    out.mkdir(parents=True, exist_ok=False)
    records = json.loads(args.source_manifest.read_text(encoding='utf-8'))['sources']
    locked = json.loads((repo / 'prebuilt/jdk/build-inputs.json').read_text())['runtimes']
    receipt = {'recordedAt': datetime.datetime.now().astimezone().isoformat(), 'majors': []}
    for major, definition in locked.items():
        tree = out / major; tree.mkdir(); sources = []
        for entry in [e for e in records if e['major'] == major]:
            if entry['commit'] != definition['commit']: raise ValueError('source commit mismatch')
            data = Path(entry['savedPath']).read_bytes()
            if hashlib.sha256(data).hexdigest() != entry['sha256']: raise ValueError('source SHA mismatch')
            target = tree / entry['path']; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(data)
            sources.append({'path': entry['path'], 'sha256': entry['sha256']})
        patch_root = repo / 'prebuilt/jdk' / major / 'patches'
        baseline = [patch_root / ('0011-ohos-java-sound-capability.patch' if major == '8' else
                                  '0011-ohos-javasound-capabilities.patch'),
                    patch_root / '0023-ohos-javasound-daudio-playback.patch',
                    patch_root / '0025-ohos-javasound-duplex-host-callbacks.patch']
        env = {**os.environ, 'GIT_CEILING_DIRECTORIES': str(out)}
        command = ['git', '-c', 'core.autocrlf=false', '-c', 'core.eol=lf', 'apply']
        for patch in baseline:
            subprocess.run([*command, '--check', str(patch)], cwd=tree, env=env, check=True)
            subprocess.run([*command, str(patch)], cwd=tree, env=env, check=True)
        native = 'jdk/src/share/native/com/sun/media/sound/' if major == '8' else 'src/java.desktop/share/native/libjsound/'
        platform = 'jdk/src/solaris/native/com/sun/media/sound/' if major == '8' else 'src/java.desktop/linux/native/libjsound/'
        before = {p.relative_to(tree).as_posix(): p.read_text(encoding='utf-8') for p in tree.rglob('*') if p.is_file()}
        after = {native + 'DirectAudioDevice.c': timeline_jni(before[native + 'DirectAudioDevice.c'])}
        shared = {}
        for name in ('ohos_daudio.c', 'ohos_daudio.h', 'ohos_daudio_callbacks.h', 'ohos_capture_ring.h', 'ohos_playback_timeline.h'):
            source = repo / 'entry/src/main/cpp/javasound' / name
            after[(platform if name.endswith('.c') else native) + name] = source.read_text(encoding='utf-8')
            shared[name] = hashlib.sha256(source.read_bytes()).hexdigest()
        delta = []
        for name, content in sorted(after.items()):
            if before.get(name) == content: continue
            target = tree / name; target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding='utf-8', newline='\n')
            delta.extend(difflib.unified_diff(before.get(name, '').splitlines(True), content.splitlines(True),
                fromfile='a/' + name if name in before else '/dev/null', tofile='b/' + name))
        candidate = out / ('jdk' + major + '-ohos-daudio-timeline.patch')
        candidate.write_text(''.join(delta), encoding='utf-8', newline='\n')
        subprocess.run([*command, '--reverse', '--check', str(candidate)], cwd=tree, env=env, check=True)
        receipt['majors'].append({'major': major, 'sourceCommit': definition['commit'], 'patch': str(candidate),
            'sha256': hashlib.sha256(candidate.read_bytes()).hexdigest(), 'upstream': sources,
            'baseline': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in baseline}, 'shared': shared})
        print('PASS generated and reverse-checked JDK ' + major + ' timeline increment', flush=True)
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')


if __name__ == '__main__': main()
