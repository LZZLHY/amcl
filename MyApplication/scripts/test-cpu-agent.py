"""在独立 JVM/加载器内查询真实 OSHI，各版本依赖必须由固定游戏 metadata 核验。"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess
import zipfile
import urllib.request
from lib.game_compat_inputs import jdk_tool
from lib.workspace_paths import external_output_path
import importlib.util

ROOT = Path(__file__).resolve().parent.parent


def verified_dependencies(inputs, version, cache=None):
    """只消费对应游戏元数据声明的 OSHI/JNA/SLF4J，校验大小和 SHA1，不混用另一版 JNA。"""
    lock = json.loads((ROOT / 'JavaCpuAgent/oshi-test-inputs.json').read_text(encoding='utf-8'))
    metadata = next(item for item in lock['versions'] if item['minecraft'] == version)
    result = []
    for item in metadata['libraries']:
        entry = item
        path = inputs / 'libraries' / entry['path']
        if not path.is_file() and cache is not None:
            path = cache / entry['path']; path.parent.mkdir(parents=True, exist_ok=True)
            # 仅显式 --download 时补齐缺失测试输入，下载写本轮外部目录，不改历史缓存。
            with urllib.request.urlopen(entry['url'], timeout=30) as response:
                path.write_bytes(response.read())
        data = path.read_bytes()
        if len(data) != entry['size'] or hashlib.sha1(data).hexdigest() != entry['sha1']:
            raise RuntimeError('Unverified OSHI test dependency: ' + str(path))
        result.append(path)
    if not any('oshi' in path.name for path in result):
        raise RuntimeError('No real OSHI input')
    return result


def main():
    """每个 ABI 启动新 JVM，输出完整收据；不同 ClassLoader 在 Java 测试中独立验收。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--java', action='append', default=[])
    parser.add_argument('--download', action='store_true', help='Download missing pinned dependencies into this run only')
    parser.add_argument('--mode', choices=['all', 'module'], default='all', help='Run only a previously blocked module-layer check when resuming')
    args = parser.parse_args()
    directory = external_output_path(args.output); directory.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location('cpu_builder', ROOT / 'scripts/build-cpu-agent.py')
    builder = importlib.util.module_from_spec(spec); spec.loader.exec_module(builder)
    artifact = builder.build()
    classes = directory / 'classes'; classes.mkdir()
    subprocess.run([jdk_tool('javac', minimum=17), '--release', '8', '-encoding', 'UTF-8', '-proc:none',
                    '-cp', str(artifact), '-d', str(classes),
                    str(ROOT / 'JavaCpuAgent/test/com/amcl/cpu/CpuQueryTest.java'),
                    str(ROOT / 'JavaCpuAgent/test/com/amcl/cpu/CpuAgentPolicyTest.java')], check=True)
    subprocess.run([jdk_tool('javac', minimum=17), '--release', '17', '-encoding', 'UTF-8', '-proc:none',
                    '-cp', str(classes), '-d', str(classes),
                    str(ROOT / 'JavaCpuAgent/test/com/amcl/cpu/CpuModuleQueryTest.java')], check=True)
    with zipfile.ZipFile(artifact) as archive:
        names = archive.namelist()
        if any(name.startswith(('oshi/', 'org/objectweb/asm/', 'com/amcl/launcher/')) for name in names):
            raise AssertionError('CPU agent package isolation failed')
        for name in names:
            if name.endswith('.class'):
                data = archive.read(name)
                if int.from_bytes(data[6:8], 'big') > 52 or b'org/objectweb/asm/' in data:
                    raise AssertionError('CPU agent Java8/shading contract failed: ' + name)
    cases = []
    runtimes = args.java or [jdk_tool('java', minimum=17)]
    versions = ['1.12.2', '1.18.2', '1.20.1', '1.20.4', '1.21.1', '26.2']
    scenarios = [
        ('observed', 'KirinT92', '0,1,2,3,4,5', '0,0,0;1,0,0;2,1,0;3,1,0;4,0,1;5,0,1', '6', '3', '2'),
        ('no-topology', 'KirinT92', '0,2,4', '', '3', '0', '0'),
        ('no-model', '', '0,1', '', '2', '0', '0'),
        ('jvm-fallback', 'KirinT92', '', '', 'runtime', '0', '0'),
    ]
    for runtime in runtimes:
        policy = subprocess.run([str(runtime), '-Xverify:all', '-cp', str(classes) + os.pathsep + str(artifact),
                                 'com.amcl.cpu.CpuAgentPolicyTest'], capture_output=True, text=True, timeout=30)
        if policy.returncode or 'CPU_POLICY_PASS' not in policy.stdout:
            raise RuntimeError('CPU policy controls failed: ' + policy.stdout + policy.stderr)
        for version in (versions if args.mode == 'all' else []):
            dependencies = verified_dependencies(Path(args.inputs), version, directory / 'inputs' if args.download else None)
            for scenario, model, online, topology, logical, physical, packages in scenarios:
                command = [str(runtime), '-Xverify:all', '-Damcl.cpu.schema=1', '-Damcl.cpu.abi=arm64-v8a',
                           '-Damcl.cpu.model=' + model, '-Damcl.cpu.online=' + online, '-Damcl.cpu.topology=' + topology,
                           '-javaagent:' + str(artifact), '-cp', str(classes), 'com.amcl.cpu.CpuQueryTest',
                           model or 'unknown', logical, physical, packages, *map(str, dependencies)]
                result = subprocess.run(command, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=45)
                name = str(len(cases) + 1) + '-' + version + '-' + scenario
                (directory / (name + '.log')).write_text(result.stdout + result.stderr, encoding='utf-8')
                cases.append({'version': version, 'scenario': scenario, 'java': str(runtime), 'exitCode': result.returncode,
                              'dependencies': [{'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()} for path in dependencies]})
                (directory / 'result.partial.json').write_text(json.dumps(cases, indent=2), encoding='utf-8')
                print('[cpu-agent-test] ' + name + ' exit=' + str(result.returncode), flush=True)
                if result.returncode or 'CPU_QUERY_PASS' not in result.stdout:
                    print(result.stdout + result.stderr)
                    (directory / 'result.json').write_text(json.dumps(cases, indent=2), encoding='utf-8')
                    raise RuntimeError('Real OSHI query failed: ' + name)
        # 模块层需要 Java 17+；旧 Java 8/常规类加载器路径由上面的同一生产查询覆盖。
        version_text = subprocess.run([str(runtime), '-version'], capture_output=True, text=True, timeout=10)
        if '"1.8.' not in version_text.stdout + version_text.stderr:
            dependencies = verified_dependencies(Path(args.inputs), '26.2', directory / 'inputs' if args.download else None)
            result = subprocess.run([str(runtime), '-Xverify:all', '-Damcl.cpu.schema=1', '-Damcl.cpu.abi=arm64-v8a',
                                     '-Damcl.cpu.model=KirinT92', '-Damcl.cpu.online=0,2,4', '-javaagent:' + str(artifact),
                                     '-cp', str(classes), 'com.amcl.cpu.CpuModuleQueryTest', *map(str, dependencies)],
                                    capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=45)
            (directory / ('module-' + str(len(cases)) + '.log')).write_text(result.stdout + result.stderr, encoding='utf-8')
            if result.returncode or 'CPU_MODULE_PASS' not in result.stdout:
                raise RuntimeError('CPU module layer failed: ' + result.stdout + result.stderr)
            cases.append({'version': '26.2', 'scenario': 'named-module-layer', 'java': str(runtime), 'exitCode': 0})
    (directory / 'result.json').write_text(json.dumps({'passed': len(cases), 'cases': cases}, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
