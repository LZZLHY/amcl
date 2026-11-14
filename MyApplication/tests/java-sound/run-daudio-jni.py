#!/usr/bin/env python3
"""固定 Linux17 JVM/原 JNI/共享 DAUDIO 的集成资格；平台替身不是目标硬件证明。"""
from pathlib import Path
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    source = Path('/source/jdk17u'); inputs = Path('/daudio-inputs')
    host = Path('/usr/lib/jvm/java-17-openjdk-amd64'); output = Path('/output'); work = Path('/work')
    manifest = inputs / 'manifest.json'
    if sha(manifest) != os.environ['AMCL_DAUDIO_INPUT_SHA']: raise ValueError('input manifest SHA changed')
    facts = json.loads(manifest.read_text())
    if facts['schema'] not in ('amcl-daudio-jni-inputs/v1', 'amcl-daudio-jni-inputs/v2', 'amcl-daudio-jni-inputs/v3') or facts['major'] != 17: raise ValueError('wrong input type')
    timeline = facts['schema'] == 'amcl-daudio-jni-inputs/v3'
    duplex = facts['schema'] != 'amcl-daudio-jni-inputs/v1'
    actual = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != facts['sourceCommit']: raise ValueError('source volume HEAD differs from frozen input')
    for entry in facts['files']:
        relative = Path(entry['path']); p = inputs / relative
        if relative.is_absolute() or '..' in relative.parts or p.is_symlink() or sha(p) != entry['sha256'] or p.stat().st_size != entry['bytes']:
            raise ValueError('input identity mismatch: ' + str(relative))
    receipt = {'startedAt': datetime.datetime.now().astimezone().isoformat(), 'sourceCommit': actual,
               'inputManifestSha256': sha(manifest), 'scope': 'actual host Java/JNI; OHAudio mock, not device', 'commands': []}
    work.mkdir(parents=True, exist_ok=True)
    tree = work / 'source'; tree.mkdir()

    def run(argv, label, expected=0, cwd=None):
        result = subprocess.run([str(x) for x in argv], capture_output=True, timeout=100, cwd=cwd,
            env={**os.environ, 'GIT_CEILING_DIRECTORIES': str(work), 'LD_LIBRARY_PATH': str(host / 'lib') + ':' + str(host / 'lib/server')})
        (output / (label + '.stdout')).write_bytes(result.stdout); (output / (label + '.stderr')).write_bytes(result.stderr)
        receipt['commands'].append({'argv': [str(x) for x in argv], 'returncode': result.returncode, 'expected': expected, 'label': label})
        print(result.stdout.decode(errors='replace'), end='', flush=True)
        if result.returncode != expected:
            print(result.stderr.decode(errors='replace'), flush=True)
            raise RuntimeError(label + ': unexpected exit ' + str(result.returncode))
        return result

    try:
        # 从源卷 Git 对象读取真实原文，完整补丁在独立树重放；不消费未知工作树修改。
        patches = [inputs / 'baseline-0011.patch']
        if duplex: patches.append(inputs / 'baseline-0023.patch')
        if timeline: patches.append(inputs / 'baseline-0025.patch')
        patches.append(inputs / 'candidate.patch')
        names = set()
        for patch in patches: names.update(re.findall(r'^\+\+\+ b/(.+)$', patch.read_text(), re.M))
        native_root = source / 'src/java.desktop/share/native/libjsound'
        names.update(p.relative_to(source).as_posix() for p in native_root.iterdir() if p.suffix in ('.c', '.h'))
        for name in sorted(names):
            if name.endswith(('/ohos_daudio.c', '/ohos_daudio.h', '/ohos_capture_ring.h', '/ohos_daudio_callbacks.h', '/ohos_playback_timeline.h')): continue
            data = subprocess.check_output(['git', '-C', str(source), 'show', 'HEAD:' + name])
            dest = tree / name; dest.parent.mkdir(parents=True, exist_ok=True); dest.write_bytes(data)
        original_jni = (tree / 'src/java.desktop/share/native/libjsound/DirectAudioDevice.c').read_bytes()
        for index, patch in enumerate(patches):
            run(['git', '-c', 'core.autocrlf=false', 'apply', '--check', patch], 'patch-check-' + str(index), cwd=tree)
            run(['git', '-c', 'core.autocrlf=false', 'apply', patch], 'patch-' + str(index), cwd=tree)
            if duplex and patch.name == 'baseline-0023.patch':
                old_read_jni = (tree / 'src/java.desktop/share/native/libjsound/DirectAudioDevice.c').read_bytes()
            if timeline and patch.name == 'baseline-0025.patch':
                # 旧0025完整后端及JNI原件保留，用同一个真实Java drain/平台延迟模型精确反控。
                old_timeline = {p: p.read_bytes() for p in (
                    tree / 'src/java.desktop/linux/native/libjsound/ohos_daudio.c',
                    *(tree / 'src/java.desktop/share/native/libjsound' / name for name in
                      ('ohos_daudio.h', 'ohos_daudio_callbacks.h', 'DirectAudioDevice.c')))}
        native = tree / 'src/java.desktop/share/native/libjsound'
        platform = tree / 'src/java.desktop/linux/native/libjsound/ohos_daudio.c'
        shared = [(platform, inputs / 'backend/ohos_daudio.c'), (native / 'ohos_daudio.h', inputs / 'backend/ohos_daudio.h')]
        if duplex: shared += [(native / n, inputs / 'backend' / n) for n in ('ohos_capture_ring.h', 'ohos_daudio_callbacks.h')]
        if timeline: shared.append((native / 'ohos_playback_timeline.h', inputs / 'backend/ohos_playback_timeline.h'))
        for path, supplied in shared:
            if sha(path) != sha(supplied): raise ValueError('patch does not embed current shared source: ' + str(path))
        private = work / 'jdk'; (private / 'bin').mkdir(parents=True); (private / 'lib/server').mkdir(parents=True)
        shutil.copyfile(host / 'bin/java', private / 'bin/java'); (private / 'bin/java').chmod(0o755)
        shutil.copyfile(host / 'lib/server/libjvm.so', private / 'lib/server/libjvm.so')
        for item in (host / 'lib').iterdir():
            if item.name not in ('libjsound.so', 'server'): (private / 'lib' / item.name).symlink_to(item)
        (private / 'conf').symlink_to(host / 'conf'); shutil.copyfile(host / 'release', private / 'release')
        classes = output / 'classes'; headers = output / 'headers'; classes.mkdir(); headers.mkdir()
        java = tree / 'src/java.desktop/share/classes'
        java_tests = [inputs / 'tests/DaudioJniRegression.java', inputs / 'tests/SoundLifecycleRegression.java']
        if duplex: java_tests.append(inputs / 'tests/DaudioCaptureJniRegression.java')
        if timeline: java_tests.append(inputs / 'tests/DaudioTimelineJniRegression.java')
        run([host / 'bin/javac', '-encoding', 'UTF-8', '--patch-module', 'java.desktop=' + str(java),
             '-d', classes, '-h', headers, *sorted(java.rglob('*.java')), inputs / 'tests/DaudioJniRegression.java',
             *java_tests[1:]], 'javac')
        target_platform = source / 'build/linux-aarch64-server-release/jdk/modules/java.desktop/com/sun/media/sound/Platform.class'
        shutil.copyfile(target_platform, classes / 'com/sun/media/sound/Platform.class')
        target_headers = source / 'build/linux-aarch64-server-release/support/headers/java.desktop'
        common = ['cc', '-shared', '-fPIC', '-O2', '-g', '-DX_PLATFORM=X_LINUX', '-DUSE_PORTS=FALSE', '-DUSE_DAUDIO=TRUE',
            '-DUSE_PLATFORM_MIDI_IN=FALSE', '-DUSE_PLATFORM_MIDI_OUT=FALSE', '-DAMCL_OHOS_DAUDIO=1',
            '-DAMCL_DAUDIO_REAL_JNI=1', '-D_GNU_SOURCE', '-D__availability__(...)=',
            '-I' + str(inputs / 'sdk'), '-I' + str(native), '-I' + str(host / 'include'), '-I' + str(host / 'include/linux'),
            '-I' + str(headers), '-I' + str(target_headers), '-I' + str(source / 'src/java.base/share/native/libjava'),
            '-I' + str(source / 'src/java.base/unix/native/libjava')]
        units = [*sorted(native.glob('*.c')), platform, inputs / 'tests/daudio_backend_test.c', inputs / 'tests/daudio_jni_control.c']
        if duplex: units.append(inputs / 'tests/daudio_capture_jni_control.c')
        link = ['-L' + str(host / 'lib'), '-L' + str(host / 'lib/server'), '-ljava', '-ljvm', '-lm', '-ldl', '-pthread',
                '-Wl,--no-undefined', '-o', str(private / 'lib/libjsound.so')]
        vm = [private / 'bin/java', '--patch-module', 'java.desktop=' + str(classes), '-Xcheck:jni',
              '-Xlog:library=debug', '-Djava.home=' + str(private), '-Dsun.boot.library.path=' + str(private / 'lib')]
        run([*common, *units, *link], 'compile-patched')
        shutil.copyfile(private / 'lib/libjsound.so', output / 'libjsound.patched.host.so')
        result = run([*vm, '-m', 'java.desktop/com.sun.media.sound.DaudioJniRegression'], 'jni-positive')
        if b'WARNING in native method' in result.stdout + result.stderr or b'FATAL ERROR in native method' in result.stdout + result.stderr:
            raise ValueError('CheckJNI diagnostic in positive fixture')
        if b'Loaded library /work/jdk/lib/libjsound.so' not in result.stdout + result.stderr:
            raise ValueError('actual libjsound load not proved')
        run([*vm, '-m', 'java.desktop/com.sun.media.sound.SoundLifecycleRegression'], 'java-positive')
        if timeline:
            result = run([*vm, '-m', 'java.desktop/com.sun.media.sound.DaudioTimelineJniRegression'], 'timeline-positive')
            if b'WARNING in native method' in result.stdout + result.stderr: raise ValueError('CheckJNI in timeline positive')
            current_timeline = {p: p.read_bytes() for p in old_timeline}
            for p, data in old_timeline.items(): p.write_bytes(data)
            run([*common, *units, *link], 'compile-old-timeline')
            shutil.copyfile(private / 'lib/libjsound.so', output / 'libjsound.old-timeline.host.so')
            result = run([*vm, '-m', 'java.desktop/com.sun.media.sound.DaudioTimelineJniRegression', '--old-timeline-control'], 'timeline-old-control', 77)
            if b'EXPECTED-OLD-TIMELINE-DEFECT' not in result.stdout: raise ValueError('wrong old timeline failure')
            for p, data in current_timeline.items(): p.write_bytes(data)
            run([*common, *units, *link], 'restore-current-timeline')
        if duplex:
            result = run([*vm, '-m', 'java.desktop/com.sun.media.sound.DaudioCaptureJniRegression'], 'capture-positive')
            if b'WARNING in native method' in result.stdout + result.stderr or b'FATAL ERROR in native method' in result.stdout + result.stderr:
                raise ValueError('CheckJNI diagnostic in Capture positive fixture')
            # 仅撤销0025的nRead修复，保留已验证0023生命周期与当前Capture后端。
            (native / 'DirectAudioDevice.c').write_bytes(old_read_jni)
            run([*common, *units, *link], 'compile-old-read')
            shutil.copyfile(private / 'lib/libjsound.so', output / 'libjsound.old-read.host.so')
            result = run([*vm, '-m', 'java.desktop/com.sun.media.sound.DaudioCaptureJniRegression', '--old-read-control'], 'capture-old-control', 77)
            if b'EXPECTED-OLD-READ-DEFECT' not in result.stdout: raise ValueError('wrong old-read failure')
        # 原 JNI 负控保留相同 Java/平台后端，只撤去状态检查；错误必须在真正 Java 调用上复现。
        (native / 'DirectAudioDevice.c').write_bytes(original_jni)
        run([*common, *units, *link], 'compile-old-jni')
        shutil.copyfile(private / 'lib/libjsound.so', output / 'libjsound.old-jni.host.so')
        result = run([*vm, '-m', 'java.desktop/com.sun.media.sound.DaudioJniRegression', '--old-jni-control'], 'jni-old-control', 77)
        if b'EXPECTED-OLD-JNI-DEFECT' not in result.stdout: raise ValueError('wrong negative control failure')
        receipt['result'] = 'PASS'
        receipt['payloads'] = {p.name: sha(p) for p in output.glob('*.so')}
    finally:
        receipt['finishedAt'] = datetime.datetime.now().astimezone().isoformat()
        (output / 'daudio-jni-receipt.json').write_text(json.dumps(receipt, indent=2))


if __name__ == '__main__': main()
