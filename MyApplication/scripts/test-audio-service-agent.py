"""验证独立音频 SPI Agent 的字节码隔离与注入反例；真实加载器资格另由 loader 脚本验证。"""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import zipfile
from lib.game_compat_inputs import jdk_tool
from lib.workspace_paths import external_output_path

ROOT = Path(__file__).resolve().parent.parent


def main():
    """每个 JDK 与父枚举故障场景均用独立 JVM，不依赖跨场景可变静态标记。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    parser.add_argument('--launcher-jar', required=True)
    parser.add_argument('--java', action='append', default=[])
    args = parser.parse_args()
    directory = external_output_path(args.output); directory.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location('audio_builder', ROOT / 'scripts/build-audio-service-agent.py')
    builder = importlib.util.module_from_spec(spec); spec.loader.exec_module(builder)
    artifact = builder.build(directory / 'build')
    with zipfile.ZipFile(artifact) as archive:
        names = archive.namelist()
        if any(name.startswith(('org/objectweb/asm/', 'com/amcl/launcher/', 'com/amcl/audio/')) for name in names):
            raise AssertionError('Audio service agent package ownership isolation failed')
        for name in names:
            if name.endswith('.class'):
                data = archive.read(name)
                if int.from_bytes(data[6:8], 'big') > 52 or b'org/objectweb/asm/' in data:
                    raise AssertionError('Audio service agent Java8/shading contract failed: ' + name)
    classes = directory / 'classes'; classes.mkdir()
    subprocess.run([jdk_tool('javac', minimum=17), '--release', '8', '-encoding', 'UTF-8', '-proc:none',
                    '-cp', str(artifact), '-d', str(classes),
                    *map(str, sorted((ROOT / 'JavaAudioServiceAgent/test').rglob('*.java')))], check=True)
    results = []
    for index, java in enumerate(args.java or [jdk_tool('java', minimum=17)]):
        for fault in ('', 'io', 'security'):
            command = [str(java), '-Xverify:all']
            if fault:
                command += ['-Djava.system.class.loader=com.amcl.audioagent.ThrowingSystemLoader',
                            '-Damcl.audio.test.parentFault=' + fault]
            command += ['-cp', os.pathsep.join(map(str, (classes, artifact, Path(args.launcher_jar)))),
                        'com.amcl.audioagent.AudioServicePolicyTest']
            result = subprocess.run(command, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=30)
            name = f'jdk-{index + 1}-{fault or "normal"}'
            (directory / (name + '.log')).write_text(result.stdout + result.stderr, encoding='utf-8')
            results.append({'java': str(java), 'parentFault': fault, 'exitCode': result.returncode,
                            'command': command, 'output': result.stdout + result.stderr})
            print(result.stdout + result.stderr, end='', flush=True)
            if result.returncode or 'PASS audio service injection policy' not in result.stdout:
                raise RuntimeError('Audio service injection policy failed: ' + name)
    receipt = {'schemaVersion': 1, 'artifact': str(artifact), 'sha256': hashlib.sha256(artifact.read_bytes()).hexdigest(),
               'bytecodeMajor': 52, 'privateAsm': True, 'testCases': results, 'storageStatus': 'success-fixtures-retired'}
    # 所有独立 JVM 已返回并关闭后，核验并回收本次亲建的 classes，失败路径则保留现场。
    if classes.resolve().parent != directory.resolve():
        raise RuntimeError('Refusing audio service policy fixture cleanup outside owned directory')
    shutil.rmtree(classes)
    (directory / 'result.json').write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
