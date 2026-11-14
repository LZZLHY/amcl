#!/usr/bin/env python3
"""读取锁定上游及正式编码补丁，用实际javac验证中文源码与原ASCII负控。

这里只验证编译输入编码，不把单类成功替代完整images。所有临时源码、class和
编译器输出都放显式仓外目录；JDK25已有UTF-8，不为一致的编号制造无用补丁。
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sources-parent', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--javac', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    args.output.mkdir(parents=True, exist_ok=False)
    cases = []
    for major in ('8', '17', '21', '25'):
        clone = args.sources_parent / ('jdk-protocol-' + major)
        names = ['jdk/make/Setup.gmk', 'hotspot/make/linux/makefiles/rules.make',
                 'common/autoconf/spec.gmk.in'] if major == '8' else ['make/common/JavaCompilation.gmk']
        work = args.output / major
        work.mkdir()
        for name in names:
            data = subprocess.check_output(['git', '-C', str(clone), 'show', 'HEAD:' + name])
            target = work / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        if major != '25':
            patch = root / 'prebuilt/jdk' / major / 'patches/0021-java-source-utf8.patch'
            subprocess.run(['git', 'apply', '--check', str(patch)], cwd=work, check=True)
            subprocess.run(['git', 'apply', str(patch)], cwd=work, check=True)
        fixture = work / 'EncodingFixture.java'
        fixture.write_text('/** 中文注释不能被删除或转义来规避正式构建。 */\npublic final class EncodingFixture { public static final String TEXT = "中文"; }\n', encoding='utf-8')
        for name in names:
            makefile = (work / name).read_text(encoding='utf-8')
            if name == 'common/autoconf/spec.gmk.in':
                # BeanInfo/doclet不是带-encoding的外层javac命令，必须验证实际JavaCompiler
                # API在构建JVM默认charset下的行为，不能再以主类单一flags覆盖全部入口。
                found = re.findall(r'^JAVA_FLAGS:=.*?(-Dfile.encoding=\S+)', makefile, re.M)
                if found != ['-Dfile.encoding=UTF-8']:
                    raise AssertionError((major, name, found))
                helper = work / 'DefaultCompilerProbe.java'
                helper.write_text('/** 复现构建工具进程内调用JavaCompiler且未传encoding的入口。 */\n'
                    'public class DefaultCompilerProbe { public static void main(String[] a) { '
                    'System.exit(javax.tools.ToolProvider.getSystemJavaCompiler().run(null,null,null,"-d",a[1],a[0])); } }\n',
                    encoding='utf-8')
                helper_classes = work / 'default-compiler'
                helper_classes.mkdir()
                subprocess.run([str(args.javac), '--release', '8', '-encoding', 'UTF-8', '-d', str(helper_classes), str(helper)], check=True)
                java = args.javac.with_name('java' + args.javac.suffix)
                exits = []
                for label, option in (('patched', found[0]), ('original-c-locale', '-Dfile.encoding=ASCII')):
                    output = work / label
                    output.mkdir()
                    command = [str(java), option, '-cp', str(helper_classes), 'DefaultCompilerProbe', str(fixture), str(output)]
                    result = subprocess.run(command, capture_output=True)
                    (output / 'compiler.log').write_bytes(result.stdout + result.stderr)
                    exits.append(result.returncode)
                if exits[0] != 0 or exits[1] == 0:
                    raise AssertionError(('build JVM default charset', exits))
                data = (work / 'patched/EncodingFixture.class').read_bytes()
                if b'\xe4\xb8\xad\xe6\x96\x87' not in data:
                    raise AssertionError('in-process compiler lost Unicode literal')
                cases.append({'major': major, 'makefile': name, 'jvmOption': found[0],
                              'classSha256': hashlib.sha256(data).hexdigest(), 'originalAsciiExit': exits[1]})
                continue
            found = re.findall(r'-encoding\s+([A-Za-z0-9_-]+)', makefile)
            expected_count = 3 if name == 'jdk/make/Setup.gmk' else 1
            if len(found) != expected_count or any(value.lower() != 'utf-8' for value in found):
                raise AssertionError((major, name, found))
            output = work / ('classes-' + str(len(cases)))
            output.mkdir()
            command = [str(args.javac), '--release', '8', '-encoding', found[0], '-d', str(output), str(fixture)]
            result = subprocess.run(command, capture_output=True)
            (output / 'javac.log').write_bytes(result.stdout + result.stderr)
            if result.returncode:
                raise AssertionError((major, name, result.stderr.decode(errors='replace')))
            data = (output / 'EncodingFixture.class').read_bytes()
            if b'\xe4\xb8\xad\xe6\x96\x87' not in data:
                raise AssertionError('compiled class lost Unicode literal')
            old = subprocess.run([str(args.javac), '--release', '8', '-encoding', 'ascii', '-d', str(output), str(fixture)], capture_output=True)
            (output / 'original-ascii-negative.log').write_bytes(old.stdout + old.stderr)
            if old.returncode == 0 or b'unmappable' not in old.stderr:
                # 本机javac可能使用中文诊断，仍要求编码错误明确包含ASCII与非零退出。
                if old.returncode == 0 or b'ascii' not in old.stderr.lower():
                    raise AssertionError('original ASCII negative did not fail on source encoding')
            cases.append({'major': major, 'makefile': name, 'encoding': found[0],
                          'compilerProfilesChecked': len(found), 'classSha256': hashlib.sha256(data).hexdigest(), 'originalAsciiExit': old.returncode})
    report = {'cases': cases, 'javac': str(args.javac), 'scope': 'real makefile encoding + actual javac; full images still separate'}
    (args.output / 'receipt.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False))


if __name__ == '__main__':
    main()
