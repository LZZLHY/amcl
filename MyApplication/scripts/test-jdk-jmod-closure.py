#!/usr/bin/env python3
"""使用精确真实运行包和原 JDK jmod/jlink 验证派生映像的 native 闭包。

只构造 image，不在宿主执行外来架构；原模块描述符保持逐字节一致。成功后保留小收据
及原工具输出，回收亲建的解包/派生映像，原发布包不改动。
"""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import zipfile
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'docker/scripts'))
from sync_jdk_jmods import sync, verify, module_payloads, NATIVE
from lib.host_test_lifecycle import HostTestScope
from lib.workspace_paths import external_output_path


def sha(path):
    with path.open('rb') as stream: return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--host-jdk', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if sha(args.runtime) != args.sha256: raise ValueError('原运行包摘要不匹配')
    output = external_output_path(args.output); output.mkdir(parents=True, exist_ok=False)
    work = HostTestScope('fixture-', parent=output)
    image = work.directory / 'image'; image.mkdir()
    report = {'time': datetime.now().astimezone().isoformat(), 'runtimeSha256': args.sha256,
              'scope': 'real jmod/jlink format and derived native bytes; target execution not performed', 'passed': False}
    success = False
    try:
        required = set(NATIVE) | {'release', 'legal/amcl-native/NOTICE.txt',
            'lib/libfontconfig.so', 'lib/libfreetype.so', 'lib/libfontmanager.so',
            'legal/amcl-fontconfig/COPYING', 'legal/amcl-expat/COPYING', 'legal/amcl-freetype-completion/NOTICE.txt'}
        with zipfile.ZipFile(args.runtime) as original:
            for name in original.namelist():
                if name not in required and not re.fullmatch(r'jmods/[a-zA-Z0-9_.]+\.jmod', name): continue
                target = image / name; target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(original.read(name))
        before = {}
        for name in module_payloads(image):
            with zipfile.ZipFile(image / 'jmods' / name) as archive:
                before[name] = hashlib.sha256(archive.read('classes/module-info.class')).hexdigest()
        try:
            verify(image)
        except (KeyError, ValueError) as error:
            report['originalMismatch'] = str(error)
        else:
            raise ValueError('所选原包没有重现已知 JMOD 缺口；不能借无差异样本证明修复')
        report['sync'] = sync(image)
        for name, expected in before.items():
            with zipfile.ZipFile(image / 'jmods' / name) as archive:
                if hashlib.sha256(archive.read('classes/module-info.class')).hexdigest() != expected:
                    raise ValueError('原模块描述符改变：' + name)
        suffix = '.exe' if os.name == 'nt' else ''
        jmod = args.host_jdk / 'bin' / ('jmod' + suffix)
        jlink = args.host_jdk / 'bin' / ('jlink' + suffix)
        linked = work.directory / 'linked'
        commands = [[str(jmod), 'describe', str(image / 'jmods/java.base.jmod')],
                    [str(jmod), 'describe', str(image / 'jmods/java.desktop.jmod')],
                    [str(jlink), '--module-path', str(image / 'jmods'), '--add-modules', 'java.base,java.desktop',
                     '--no-header-files', '--no-man-pages', '--output', str(linked)]]
        report['tools'] = {'jmodSha256': sha(jmod), 'jlinkSha256': sha(jlink)}
        report['commands'] = []
        env = dict(os.environ, TMPDIR=str(work.directory), TEMP=str(work.directory), TMP=str(work.directory))
        for index, command in enumerate(commands):
            result = subprocess.run(command, cwd=work.directory, env=env, capture_output=True, timeout=180)
            (output / (str(index) + '.log')).write_bytes(result.stdout + result.stderr)
            report['commands'].append({'command': command, 'exitCode': result.returncode})
            if result.returncode: raise ValueError('原 jmod/jlink 拒绝派生映像：' + str(index))
        report['linkedFiles'] = {}
        for module, payloads in module_payloads(image).items():
            for name, content in payloads.items():
                relative = ('legal/' + module.removesuffix('.jmod') + '/' + name.removeprefix('legal/')) if name.startswith('legal/') else name
                actual = linked / relative
                if not actual.is_file() or actual.read_bytes() != content:
                    raise ValueError('实际 jlink image 缺少或改变 native/许可：' + relative)
                report['linkedFiles'][relative] = sha(actual)
        success = report['passed'] = True
        print('PASS original jmod/jlink, unchanged descriptors and actual ABI/font native closure', flush=True)
    finally:
        (output / 'receipt.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        work.close(success=success)


if __name__ == '__main__': main()
