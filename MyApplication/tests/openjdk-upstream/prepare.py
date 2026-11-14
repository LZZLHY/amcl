#!/usr/bin/env python3
"""从已登记的固定上游 jtreg 源树执行官方构建入口，下载校验沿用上游校验值。

不替用户切换已有源树，不关闭 checksum 校验。BUILD_DIR 仅作用于本轮子进程，
所有依赖、构建产物和日志都落在显式外部目录，完整 harness image 供后续重复使用。
"""
import argparse
from datetime import datetime
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
sys.dont_write_bytecode = True
from run import LOCK, digest, execute, git, java_bin, save, external_output_path, verify_upstream_tree


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--host-jdk', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--reuse-receipt', type=Path, help='只复用已结束失败/成功轮的相同源码工具构建，不覆盖原收据')
    parser.add_argument('--zip', type=Path, help='任务私有 zip 工具；作为官方 Make ZIP 参数，不修改上游源码')
    args = parser.parse_args()
    source = args.source.resolve()
    head = git(source, 'rev-parse', 'HEAD')
    if head != LOCK['jtreg']['commit']:
        raise ValueError('jtreg 必须是锁定 commit 的无修改源码树')
    original = verify_upstream_tree(source)
    parent = external_output_path(args.output)
    parent.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix='jtreg-build-', dir=parent))
    build = output / 'build'
    previous = None
    if args.reuse_receipt:
        previous = json.loads(args.reuse_receipt.read_text(encoding='utf-8'))
        if (previous['state'] not in ('FAILED', 'BUILT') or previous['sourceCommit'] != head or
            previous['sourceTree'] != original or
            previous['buildScriptSha256'] != digest(source / LOCK['jtreg']['buildEntry']) or
            previous['hostJavaSha256'] != digest(java_bin(args.host_jdk.resolve()))):
            raise ValueError('复用 jtreg 构建输入/结束状态不匹配，原目录保留')
        build = external_output_path(Path(previous.get('buildDirectory', args.reuse_receipt.parent / 'build')))
        if not build.is_dir(): raise ValueError('复用构建目录不存在')
    env = dict(os.environ, BUILD_DIR=str(build), JAVA_HOME=str(args.host_jdk.resolve()))
    receipt = {'schemaVersion': 1, 'startedAt': datetime.now().astimezone().isoformat(),
               'sourceCommit': head, 'sourceTree': original, 'repository': LOCK['jtreg']['repository'],
               'buildScriptSha256': digest(source / LOCK['jtreg']['buildEntry']),
               'hostJavaSha256': digest(java_bin(args.host_jdk.resolve())),
               'buildDirectory': str(build), 'state': 'BUILDING'}
    if previous:
        receipt['reusedReceipt'] = {'path': str(args.reuse_receipt), 'sha256': digest(args.reuse_receipt)}
    command = ['bash', str(source / LOCK['jtreg']['buildEntry']), '--jdk', str(args.host_jdk.resolve())]
    if previous: command.append('--skip-download')
    if args.zip:
        tool = args.zip.resolve()
        if not tool.is_file(): raise ValueError('ZIP 工具不存在')
        receipt['zipTool'] = {'path': str(tool), 'sha256': digest(tool)}
        command.extend(['--', 'ZIP=' + str(tool)])
    save(output / 'receipt.json', receipt)
    build.mkdir(parents=True, exist_ok=True)
    with (build / '.amcl-jtreg.lock').open('a+b') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            result, _ = execute(command, source, output / 'build.log', 1800, env)
            receipt['execution'] = result
            image = build / 'images/jtreg'
            receipt['state'] = 'FAILED'
            if not result['exitCode'] and not result['timedOut'] and (image / 'lib/jtreg.jar').is_file():
                if git(source, 'rev-parse', 'HEAD') != head or verify_upstream_tree(source) != original:
                    raise ValueError('jtreg 构建期间源码身份改变')
                receipt['state'] = 'BUILT'
                receipt['image'] = str(image)
                receipt['jars'] = {p.relative_to(image).as_posix(): digest(p) for p in sorted((image / 'lib').glob('*.jar'))}
        except BaseException as error:
            receipt['state'] = 'FAILED'; receipt['error'] = str(error)
            raise
        finally:
            # 逐 JAR 身份与收据落盘仍在同一真实锁内，不能在读回前让另一个构建改写映像。
            receipt['finishedAt'] = datetime.now().astimezone().isoformat()
            save(output / 'receipt.json', receipt)
    print('JTREG_BUILD_RECEIPT=' + str(output / 'receipt.json'), flush=True)
    return 0 if receipt['state'] == 'BUILT' else 1


if __name__ == '__main__':
    raise SystemExit(main())
