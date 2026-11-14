#!/usr/bin/env python3
"""导出上游 make test-image 的实际 native/WhiteBox/gtest 输入，不用自写替身。

测试映像和正式 JDK 分开交付，来源绑定同次冻结输入及最终 libjvm。是否具有 gtest
由实际内容记录；编译了 test-image 不代表运行过测试，也不自动证明目标执行许可。
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tarfile


def digest(path):
    """兼容固定 builder 的 Python 3.10；不依赖3.11才加入的file_digest。"""
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''): value.update(chunk)
    return value.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--major', choices=('17', '21', '25'), required=True)
    parser.add_argument('--jdk-image', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    test = args.jdk_image.parent / 'test'
    if not test.is_dir(): raise ValueError('上游 test-image 目录不存在')
    files = {}
    for path in sorted(test.rglob('*')):
        if path.is_symlink(): raise ValueError('测试映像必须按真实文件导出：' + str(path))
        if path.is_file():
            files[path.relative_to(test).as_posix()] = {'bytes': path.stat().st_size, 'sha256': digest(path)}
    if not files: raise ValueError('上游测试映像为空')
    executables = [name for name in files if Path(name).name in ('gtestLauncher', 'gtestLauncher.exe')]
    if not executables: raise ValueError('上游测试映像缺少gtestLauncher，请核对--with-gtest配置')
    test_vms = {name: files[name] for name in files if Path(name).name in ('libjvm.so', 'jvm.dll') and 'gtest' in Path(name).parts}
    if not test_vms: raise ValueError('gtest缺少包含原测试的专用libjvm')
    args.output.mkdir(parents=True, exist_ok=True)
    archive = args.output / ('jdk' + args.major + '-upstream-test-image.tar.gz')
    with archive.open('xb') as raw, tarfile.open(fileobj=raw, mode='w:gz') as packed:
        for name in files: packed.add(test / name, arcname=name, recursive=False)
    # 完整 EOF 与逐条内容回读；不依赖 tar 命令的退出码替代身份检查。
    with tarfile.open(archive) as packed:
        if sorted(packed.getnames()) != sorted(files): raise ValueError('测试映像条目集合改变')
        for member in packed:
            data = packed.extractfile(member).read()
            if len(data) != files[member.name]['bytes'] or hashlib.sha256(data).hexdigest() != files[member.name]['sha256']:
                raise ValueError('测试映像内容回读失败：' + member.name)
    result = {'schemaVersion': 1, 'major': args.major, 'builtNotExecuted': True,
              'source': json.loads(Path('/build/jdk' + args.major + '-source-base.json').read_text()),
              'inputDigest': os.environ['AMCL_TARGET_INPUTS_DIGEST'],
              'libjvmSha256': digest(args.jdk_image / 'lib/server/libjvm.so'),
              'archive': archive.name, 'sha256': digest(archive), 'files': files,
              'gtestExecutables': executables, 'gtestVms': test_vms,
              'gtestSource': json.loads(Path('/build/upstream-googletest.json').read_text())}
    archive.with_suffix('.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print('UPSTREAM_TEST_IMAGE=' + str(archive), flush=True)


if __name__ == '__main__': main()
