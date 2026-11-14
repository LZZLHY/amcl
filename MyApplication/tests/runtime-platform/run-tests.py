#!/usr/bin/env python3
"""从四代锁定 Git 对象重放完整 series，并编译执行真实平台分派表达式。

只测 Java 平台分类，不把宿主谓词测试当成目标进程、终端、ptrace 或网络功能资格。
所有上游字节、补丁快照、javac 输出和负控都保存在调用者指定的新外置目录。
"""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


def sha(data):
    """来源以实际正文摘要绑定，路径名和版本显示不能代替输入身份。"""
    return hashlib.sha256(data).hexdigest()


def method(source, name):
    """提取实际无参数方法；花括号平衡保证不把其它分支截断后冒充原代码。"""
    start = source.index('private static OperatingSystem ' + name + '()')
    opening = source.index('{', start)
    depth = 0
    for end in range(opening, len(source)):
        depth += (source[end] == '{') - (source[end] == '}')
        if depth == 0:
            return source[start:end + 1]
    raise ValueError('Unclosed platform factory')


def main():
    """外部克隆只读；四代源码/patch 全部核实后在独立目录重放，不修改原源码工作树。"""
    parser = argparse.ArgumentParser()
    parser.add_argument('--source-root', type=Path, required=True, help='包含 jdk-protocol-{8,17,21,25} 的外置目录')
    parser.add_argument('--javac', type=Path, required=True)
    parser.add_argument('--java', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    if output.is_relative_to(root):
        raise ValueError('测试输出必须位于仓外')
    output.mkdir(parents=True, exist_ok=False)
    spec = json.loads(Path(__file__).with_name('dispatch-cases.json').read_text(encoding='utf-8'))
    locked = json.loads((root / 'prebuilt/jdk/build-inputs.json').read_text())['runtimes']
    report = {'startedAt': datetime.now().astimezone().isoformat(), 'targetRuntimeQualified': False,
              'javacSha256': sha(args.javac.read_bytes()), 'javaSha256': sha(args.java.read_bytes()), 'runtimes': {}}
    environment = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                       GIT_CEILING_DIRECTORIES=str(output), PYTHONUTF8='1')
    for major, item in spec['runtimes'].items():
        repo = args.source_root / ('jdk-protocol-' + major)
        if item['commit'] != locked[major]['commit']:
            raise ValueError('测试清单与构建锁定源不同')
        target = output / major
        stage = target / 'source'
        stage.mkdir(parents=True)
        inputs = target / 'patches'
        inputs.mkdir()
        patch_dir = root / 'prebuilt/jdk' / major / 'patches'
        series = (patch_dir / 'series').read_bytes()
        (inputs / 'series').write_bytes(series)
        patches = [x.strip() for x in series.decode('utf-8').splitlines() if x.strip() and not x.lstrip().startswith('#')]
        originals = {}
        patch_hashes = {}
        for name in patches:
            data = (patch_dir / name).read_bytes()
            (inputs / name).write_bytes(data)
            patch_hashes[name] = sha(data)
            for relative in re.findall(r'^\+\+\+ b/([^\n\t\r]+)', data.decode('utf-8'), re.M):
                if relative in originals:
                    continue
                tree = subprocess.check_output(['git', '-C', str(repo), 'ls-tree', item['commit'], '--', relative])
                if not tree:
                    originals[relative] = None
                    continue
                content = subprocess.check_output(['git', '-C', str(repo), 'show', item['commit'] + ':' + relative])
                originals[relative] = content
                path = stage / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
        if patch_hashes['0017-ohos-runtime-platform-dispatch.patch'] != item['patchSha256']:
            raise ValueError('平台补丁身份改变，必须重新审查测试清单')
        for relative, digest in item['files'].items():
            if sha(originals[relative]) != digest:
                raise ValueError('锁定原文件变化：' + relative)
        with (target / 'series.log').open('wb') as log:
            for patch in patches:
                for check in (['--check'], []):
                    process = subprocess.run(['git', '-c', 'core.autocrlf=false', '-c', 'core.eol=lf',
                        'apply', *check, str(inputs / patch)], cwd=stage, env=environment,
                        stdout=log, stderr=subprocess.STDOUT)
                    if process.returncode:
                        raise RuntimeError('完整 series 重放失败：' + str(target / 'series.log'))
        # 字体夹具消费的 after 也必须来自本次完整 series 的真实输出，不能只信生产者
        # 给候选正文自行写的 SHA；此处独立从锁定 Git 对象和全部 patch 重新得到它。
        fallback_spec = root / 'tests/runtime-fontconfig/fallback-cases.json'
        if fallback_spec.is_file():
            fallback = json.loads(fallback_spec.read_text())['runtimes'][major]
            for name, digest in fallback['patchedFiles'].items():
                if sha((stage / name).read_bytes()) != digest:
                    raise ValueError('字体候选与完整 series 重放不一致：' + name)
        stream_spec = root / 'tests/runtime-fontconfig/stream-cases.json'
        if stream_spec.is_file():
            stream = json.loads(stream_spec.read_text())['runtimes'][major]
            if (patch_hashes['0022-freetype-stream-jni-and-cache-boundary.patch'] != stream['patchSha256'] or
                    sha((stage / stream['path']).read_bytes()) != stream['afterSha256']):
                raise ValueError('FreeType 读桥候选与完整 series 重放不一致：' + stream['path'])
        probes = []
        lines = ['import java.security.AccessController;\n',
            'class GetPropertyAction implements java.security.PrivilegedAction<String> {\n'
            ' private final String key; GetPropertyAction(String k) { key=k; }\n'
            ' public String run() { return System.getProperty(key); }\n}\n',
            'public class DispatchProbe {\n',
            ' enum OperatingSystem { WINDOWS, LINUX, MACOS, AIX, UNKNOWN }\n']
        for index, case in enumerate(item['tests']):
            after = (stage / case['path']).read_text(encoding='utf-8')
            before = originals[case['path']].decode('utf-8')
            if case.get('fullMethod'):
                lines += [method(before, case['method']).replace(case['method'] + '()', 'before' + str(index) + '()') + '\n',
                          method(after, case['method']).replace(case['method'] + '()', 'after' + str(index) + '()') + '\n']
                probes.append((index, True))
            else:
                expression = case['expression']
                if after.count(expression) != case['count'] or before.count(case['originalExpression']) != case['count']:
                    raise ValueError('被编译的谓词不是实际源码正文：' + case['path'])
                for variant, value in [('before', case['originalExpression']), ('after', expression)]:
                    # 只有原先 jpackage 本身 lower-case 的局部变量会小写化，不扩大其它入口契约。
                    convert = '.toLowerCase()' if case.get('lowercase') else ''
                    lines.append('static boolean ' + variant + str(index) + '() {\n'
                        ' String osName=System.getProperty("os.name")' + convert + ', osname=osName, os=osName;\n'
                        ' return ' + value + ';\n}\n')
                probes.append((index, False))
        lines += ['static void check(boolean b, String label) { if (!b) throw new AssertionError(label); }\n',
            'public static void main(String[] args) {\n int cases=0;\n'
            ' for(String os : new String[]{"HarmonyOS","OpenHarmony","OHOS","Linux","Windows 11","Mac OS X",'
            '"SunOS","AIX","FreeBSD","HarmonyOS-test","OpenHarmony-test","unknown"}) {\n'
            ' System.setProperty("os.name", os);\n'
            ' boolean known = os.equals("HarmonyOS") || os.equals("OpenHarmony") || os.equals("OHOS");\n']
        for index, full in probes:
            if full:
                lines.append(f'check(after{index}()==(known?OperatingSystem.LINUX:before{index}()), "factory {index}: "+os);\n'
                             f'if(known) check(before{index}()==OperatingSystem.UNKNOWN, "negative factory did not reproduce");\n')
            else:
                lines.append(f'check(after{index}()==(known||before{index}()), "predicate {index}: "+os);\n'
                             f'if(known) check(!before{index}(), "negative predicate did not reproduce");\n')
            lines.append('++cases;\n')
        lines += [' check(System.getProperty("os.name").equals(os), "platform identity rewritten");\n }\n'
                  ' System.out.println("PASS actual source predicates/factory and original negative controls: "+cases);\n}\n}\n']
        probe = target / 'DispatchProbe.java'
        probe.write_text(''.join(lines), encoding='utf-8', newline='\n')
        classes = target / 'classes'
        classes.mkdir()
        with (target / 'javac.log').open('wb') as log:
            subprocess.run([str(args.javac), '-encoding', 'UTF-8', '-d', str(classes), str(probe)],
                           stdout=log, stderr=subprocess.STDOUT, check=True)
        process = subprocess.run([str(args.java), '-cp', str(classes), 'DispatchProbe'],
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (target / 'behavior.log').write_bytes(process.stdout)
        if process.returncode:
            raise RuntimeError(process.stdout.decode('utf-8', errors='replace'))
        print('JDK ' + major + ': ' + process.stdout.decode().strip(), flush=True)
        report['runtimes'][major] = {'commit': item['commit'], 'seriesSha256': sha(series), 'patches': patch_hashes,
            'patchedSourceSha256': {name: sha((stage / name).read_bytes()) for name in item['files']},
            'predicateAndFactoryCases': len(probes) * 12, 'originalNegativeControls': len(probes) * 3,
            'passed': True}
    report['completedAt'] = datetime.now().astimezone().isoformat()
    (output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
