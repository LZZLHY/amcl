#!/usr/bin/env python3
"""执行原 OpenJDK gtest 或 jcstress 产物，保留原报告及平台缺失，不生成替代断言。"""
import argparse
from collections import Counter
from datetime import datetime
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import sys
import tempfile
import xml.etree.ElementTree as ET
sys.dont_write_bytecode = True
from run import ROOT, LOCK, HostTestScope, external_output_path, digest, execute, java_bin, probe_runtime, save
sys.path.insert(0, str(ROOT / 'docker/scripts'))
from prepare_gtest import COMMIT as GTEST_COMMIT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--framework', choices=('gtest', 'jcstress'), required=True)
    parser.add_argument('--major', choices=LOCK['suites'], required=True)
    parser.add_argument('--jdk', type=Path, required=True)
    parser.add_argument('--host-jdk', type=Path, required=True)
    parser.add_argument('--artifact', type=Path, required=True)
    parser.add_argument('--build-receipt', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--role', choices=('ohos-target', 'host-reference'), default='ohos-target')
    parser.add_argument('--filter', default=None)
    parser.add_argument('--timeout', type=int, default=3600)
    parser.add_argument('--stress-budget', default='10m')
    parser.add_argument('--cpus', type=int, default=2)
    args = parser.parse_args()
    parent = external_output_path(args.output); parent.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix=args.framework + '-', dir=parent))
    work = HostTestScope('work-', parent=output)
    record = {'schemaVersion': 1, 'framework': args.framework, 'major': args.major, 'role': args.role,
              'startedAt': datetime.now().astimezone().isoformat(), 'state': 'PREPARING', 'wholeJdkQualified': False}
    success = False
    try:
        artifact = args.artifact.resolve()
        proof = json.loads(args.build_receipt.read_text(encoding='utf-8'))
        record['buildReceiptSha256'] = digest(args.build_receipt)
        record['runtime'], record['probe'], env, usable = probe_runtime(args.jdk.resolve(), args.major,
                                                                      args.role, work.directory, output)
        if not usable: record['state'] = 'ENV_BLOCKED'; return 2
        if args.framework == 'gtest':
            expected = json.loads((ROOT / 'prebuilt/jdk/build-inputs.json').read_text())['runtimes'][args.major]['commit']
            if proof['source']['head'] != expected or proof['major'] != args.major:
                raise ValueError('gtest 源码身份不匹配')
            if proof.get('gtestSource', {}).get('commit') != GTEST_COMMIT:
                raise ValueError('GoogleTest框架不是构建器固定源码')
            if record['runtime'].get('vm', {}).get('sha256') != proof['libjvmSha256']:
                raise ValueError('gtest 与实际 libjvm 不是同一构建')
            matches = [name for name in proof['gtestExecutables'] if proof['files'][name]['sha256'] == digest(artifact)]
            if len(matches) != 1: raise ValueError('gtest 可执行文件没有唯一构建身份')
            # 上游gtest把同次HotSpot对象与原测试链接进专用libjvm，launcher必须加载它。
            # 正式runtime的libjvm只用于证明同次产品来源，不能替换含runUnitTests的测试库。
            relative = PurePosixPath(matches[0])
            if relative.is_absolute() or '..' in relative.parts: raise ValueError('invalid gtest receipt path')
            test_root = artifact.parents[len(relative.parts) - 1]
            test_vms = proof.get('gtestVms', {})
            if not test_vms: raise ValueError('缺少同次gtest专用VM来源')
            for name, identity in proof['files'].items():
                member = PurePosixPath(name)
                if member.is_absolute() or '..' in member.parts: raise ValueError('invalid test-image path')
                path = test_root / name
                if not path.resolve().is_relative_to(test_root) or not path.is_file() or digest(path) != identity['sha256']:
                    raise ValueError('测试映像内容与构建收据不同：' + name)
            vm_name = 'jvm.dll' if os.name == 'nt' else 'libjvm.so'
            adjacent = artifact.with_name(vm_name)
            vm_relative = adjacent.relative_to(test_root).as_posix()
            if vm_relative not in test_vms: raise ValueError('launcher旁没有同次gtest VM')
            record['gtestVm'] = {'path': str(adjacent), 'sha256': digest(adjacent)}
            xml = output / 'gtest.xml'
            env['LD_LIBRARY_PATH'] = os.pathsep.join([str(artifact.parent),
                *(str(args.jdk.resolve() / part) for part in ('lib/server', 'lib'))])
            command = [str(artifact), '-jdk', str(args.jdk.resolve()),
                       '--gtest_output=xml:' + str(xml), '--gtest_filter=' + (args.filter or '*')]
            record['execution'], _ = execute(command, work.directory, output / 'gtest.log', args.timeout, env)
            cases = []
            if xml.is_file():
                for item in ET.parse(xml).getroot().iter('testcase'):
                    state = 'FAIL' if item.find('failure') is not None else 'NOT_RUN' if item.find('skipped') is not None or item.get('status') == 'notrun' else 'PASS'
                    cases.append({'test': item.get('classname', '') + '.' + item.get('name', ''), 'state': state})
        else:
            if proof['sourceCommit'] != LOCK['jcstress']['commit'] or proof['artifactSha256'] != digest(artifact):
                raise ValueError('jcstress 产物不是锁定源码构建收据中的文件')
            report = output / 'original-report'
            command = [str(java_bin(args.jdk.resolve())), '-jar', str(artifact), '-r', str(report),
                       '-t', args.filter or '.*', '-tb', args.stress_budget, '-c', str(args.cpus)]
            record['execution'], _ = execute(command, work.directory, output / 'jcstress.log', args.timeout, env)
            blobs = list(work.directory.glob('jcstress-results-*.bin.gz'))
            if len(blobs) != 1: raise ValueError('jcstress 未产生唯一原始结果')
            stored = output / blobs[0].name; shutil.copyfile(blobs[0], stored)
            record['rawResult'] = {'path': str(stored), 'sha256': digest(stored)}
            classes = work.directory / 'grader'; classes.mkdir()
            javac = args.host_jdk.resolve() / 'bin' / ('javac.exe' if os.name == 'nt' else 'javac')
            compile_result, _ = execute([str(javac), '--release', '8', '-cp', str(artifact), '-d', str(classes),
                                        str(Path(__file__).with_name('JcstressResultExport.java'))],
                                       work.directory, output / 'grader-compile.log', 120, env)
            if compile_result['exitCode']: raise ValueError('原 jcstress grader 接口编译失败')
            exported = output / 'results.jsonl'
            grade_result, _ = execute([str(java_bin(args.host_jdk.resolve())), '-cp', str(classes) + os.pathsep + str(artifact),
                                      'JcstressResultExport', str(stored), str(exported)],
                                     work.directory, output / 'grader.log', 120, env)
            if grade_result['exitCode']: raise ValueError('原 jcstress 结果解析失败')
            cases = [json.loads(line) for line in exported.read_text(encoding='utf-8').splitlines() if line]
        record['command'] = command
        record['results'] = cases
        record['counts'] = dict(Counter(case['state'] for case in cases))
        success = bool(cases) and all(case['state'] == 'PASS' for case in cases) and record['execution']['exitCode'] == 0 and not record['execution']['timedOut']
        record['state'] = 'PASS_SELECTED_TESTS' if success else 'FAILED_OR_INCOMPLETE'
        return 0 if success else 1
    except Exception as error:
        record['state'] = 'HARNESS_OR_ENVIRONMENT_ERROR'; record['error'] = str(error); return 2
    finally:
        record['finishedAt'] = datetime.now().astimezone().isoformat()
        save(output / 'receipt.json', record)
        record['fixturesRemoved'] = work.close(success=success)
        save(output / 'receipt.json', record)
        print('OPENJDK_NATIVE_RECEIPT=' + str(output / 'receipt.json'), flush=True)


if __name__ == '__main__': raise SystemExit(main())
