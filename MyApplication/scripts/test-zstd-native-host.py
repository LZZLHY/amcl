"""对同一C输入构建Linux宿主JNI并运行原发布者Java绑定；不把宿主结果当OHOS设备资格。

Windows使用现有WSL Ubuntu工具链，输出仍显式落仓外；仅测试源导入前缀变化，原JAR不重写。
成功后保留日志/收据及小型可部署探针JAR，构建夹具生命周期由调用任务核同后关闭。
"""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
from lib.workspace_paths import external_output_path

ROOT = Path(__file__).resolve().parents[1]


def main():
    """核输入身份后前台构建，Java正例与真实loader负例必须全部完成。"""
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--target-build', type=Path, required=True)
    p.add_argument('--standard-jar', type=Path, required=True)
    p.add_argument('--dh-jar', type=Path, required=True)
    p.add_argument('--javac', type=Path, required=True)
    p.add_argument('--output', required=True)
    a = p.parse_args(); out = external_output_path(a.output); out.mkdir(parents=True, exist_ok=False)
    spec = ROOT / 'prebuilt/mod-natives/zstd-jni'
    build = json.loads((a.target_build / 'receipt.json').read_text(encoding='utf-8'))
    contract = json.loads((spec / 'verified-bindings.json').read_text(encoding='utf-8'))
    assert build['state'] == 'passed-artifact-only'
    for jar, profile in zip([a.standard_jar, a.dh_jar], contract['profiles']):
        assert hashlib.sha256(jar.read_bytes()).hexdigest() == profile['source']['sha256']
    for name, sha in build['adapterSources'].items():
        assert hashlib.sha256((spec / name).read_bytes()).hexdigest() == sha
    for header in build['jniHeaders']:
        assert hashlib.sha256((ROOT / header['path']).read_bytes()).hexdigest() == header['sha256']

    def linux(path):
        """Windows盘符转WSL实际挂载，不把序列化JSON当shell转义。"""
        value = Path(path).resolve()
        return '/mnt/' + value.drive[0].lower() + value.as_posix()[2:] if os.name == 'nt' else str(value)

    commands, steps = [], []
    def run(command, name):
        result = subprocess.run(list(map(str, command)), capture_output=True, timeout=240)
        (out / (name + '.log')).write_bytes(result.stdout + result.stderr)
        steps.append({'name': name, 'command': list(map(str, command)), 'exitCode': result.returncode})
        print('[zstd-host]', name, 'exit=' + str(result.returncode), flush=True)
        if result.returncode: raise RuntimeError((result.stdout + result.stderr).decode('utf-8', 'replace')[-5000:])

    record = {'at': datetime.now().astimezone().isoformat(), 'steps': steps, 'scope': 'real Linux JNI / original standard and DH classes', 'passed': False}
    try:
        native = a.target_build / 'source' / ('zstd-jni-' + build['source']['commit']) / 'src/main/native'
        headers = ROOT / Path(build['jniHeaders'][0]['path']).parent
        common = ['gcc', '-std=c11', '-O2', '-fPIC', '-fvisibility=hidden', '-D_GNU_SOURCE', '-DZSTD_LEGACY_SUPPORT=4',
                  '-DZSTD_MULTITHREAD=1', '-DZSTD_DISABLE_ASM=1', '-I' + linux(native), '-I' + linux(native / 'common'),
                  '-I' + linux(headers), '-I' + linux(headers / 'linux')]
        objects = []
        for i, source in enumerate(sorted(x for x in native.rglob('*.c') if not x.name.startswith('jni_')) + [spec / 'qsort_context.c']):
            obj = out / ('core-' + str(i) + '.o'); objects.append(linux(obj))
            extra = ['-Dqsort_r=AmclZstdQsortR', '-include', linux(spec / 'qsort_context.h')] if source.name == 'cover.c' else []
            commands.append([*common, *extra, '-c', linux(source), '-o', linux(obj)])
        classes = []
        for jar, profile in zip([a.standard_jar, a.dh_jar], contract['profiles']):
            group = out / profile['id']; group.mkdir(); source = group / 'ZstdInteropProbe.java'; destination = group / 'classes'; destination.mkdir()
            text = (ROOT / 'tests/zstd-jni/ZstdInteropProbe.java').read_text(encoding='utf-8')
            text = text.replace('com.github.luben.zstd', profile['classPrefix'].rstrip('/').replace('/', '.'))
            source.write_text(text, encoding='utf-8'); classes.append(destination)
            run([a.javac, '-encoding', 'UTF-8', '--release', '8', '-cp', jar, '-d', destination, source], profile['id'] + '-javac')
            jni_sources = sorted((a.target_build / profile['id']).glob('jni_*.c'))
            commands.append([*common, '-shared', '-Wl,--no-undefined', '-Wl,-soname,' + profile['filename'],
                             '-Wl,--version-script=' + linux(a.target_build / profile['id'] / 'exports.map'),
                             *objects, *map(linux, jni_sources), '-pthread', '-o', linux(out / profile['filename'])])
        commands.append(['gcc', '-std=c11', '-g', '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-pthread',
                         linux(spec / 'qsort_context.c'), linux(ROOT / 'tests/zstd-jni/qsort_context_test.c'), '-o', linux(out / 'qsort-test')])
        commands.append([linux(out / 'qsort-test')])
        script = out / 'build-host.sh'
        script.write_text('set -euo pipefail\n' + '\n'.join(shlex.join(c) for c in commands) + '\n', encoding='utf-8', newline='\n')
        wsl = ['wsl', '-d', 'Ubuntu', '--'] if os.name == 'nt' else []
        run([*wsl, 'bash', linux(script)], 'build-and-qsort')
        harness = out / 'harness'; harness.mkdir()
        run([a.javac, '-encoding', 'UTF-8', '--release', '8', '-d', harness, ROOT / 'tests/zstd-jni/ClassLoaderOwnershipProbe.java'], 'ownership-javac')
        run([*wsl, 'java', '-Xcheck:jni', '-cp', linux(harness), 'com.amcl.qa.ClassLoaderOwnershipProbe',
             linux(classes[0]), linux(a.standard_jar), linux(classes[1]), linux(a.dh_jar),
             linux(out / contract['profiles'][0]['filename']), linux(out / contract['profiles'][1]['filename'])], 'jni-interop-and-ownership')
        record['passed'] = True
    finally:
        record['finishedAt'] = datetime.now().astimezone().isoformat()
        (out / 'receipt.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
