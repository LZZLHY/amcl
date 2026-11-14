#!/usr/bin/env python3
"""从固定 jcstress 源码执行上游 Maven install，导出真实 tests-all 测试 JAR。

Maven 本地仓库、临时目录、日志和最终 JAR 显式落到调用者的任务空间。源码 checkout
本身必须是已登记的独占外部输入；target 属于 Maven 约定，不擅自清理已有构建目录。
"""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
sys.dont_write_bytecode = True
from run import ROOT, LOCK, digest, execute, git, java_bin, save, external_output_path, verify_upstream_tree


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--host-jdk', type=Path, required=True)
    parser.add_argument('--maven', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--maven-repository', type=Path,
                        help='可选独占外置Maven缓存；不使用用户全局仓库')
    args = parser.parse_args()
    source, jdk = args.source.resolve(), args.host_jdk.resolve()
    if source.is_relative_to(ROOT): raise ValueError('上游源码必须位于独占外部 checkout')
    head = git(source, 'rev-parse', 'HEAD')
    if head != LOCK['jcstress']['commit']: raise ValueError('jcstress 源码 commit 不匹配')
    before = verify_upstream_tree(source)
    parent = external_output_path(args.output); parent.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix='jcstress-build-', dir=parent))
    temporary = output / 'tmp'; temporary.mkdir()
    env = dict(os.environ, JAVA_HOME=str(jdk), TMPDIR=str(temporary), TEMP=str(temporary), TMP=str(temporary))
    env['PATH'] = str(jdk / 'bin') + os.pathsep + env.get('PATH', '')
    maven = args.maven.resolve()
    repository = external_output_path(args.maven_repository) if args.maven_repository else output / 'maven-repository'
    repository.mkdir(parents=True, exist_ok=True)
    # install 包含原 verify 的全部测试；archetype 会另启 Maven 子构建，需要前置 core
    # 已进入本轮私有仓库。仅 verify 的 reactor 内存解析不能传给这个真实子进程。
    command = [str(maven), '-B', '-f', str(source / 'pom.xml'),
               '-Dmaven.repo.local=' + str(repository), 'install']
    # Windows.cmd 只由 cmd 直接执行，参数没有用户正文或生成式shell表达式。
    if os.name == 'nt' and maven.suffix.lower() in ('.cmd', '.bat'):
        if any(any(c in value for c in '\r\n&|<>^%!"') for value in command):
            raise ValueError('Windows Maven 参数含 shell 元字符；请改用原生 WSL 路径')
        command = [os.environ.get('COMSPEC', 'cmd.exe'), '/d', '/c', *command]
    receipt = {'schemaVersion': 1, 'startedAt': datetime.now().astimezone().isoformat(),
               'sourceCommit': head, 'sourceTree': before, 'mavenSha256': digest(maven),
               'hostJavaSha256': digest(java_bin(jdk)), 'state': 'BUILDING', 'command': command,
               'mavenRepository': str(repository)}
    save(output / 'receipt.json', receipt)
    result, _ = execute(command, source, output / 'build.log', 3600, env)
    receipt['execution'] = result
    artifact = source / 'tests-all/target/jcstress.jar'
    receipt['state'] = 'FAILED'
    if not result['exitCode'] and not result['timedOut'] and artifact.is_file():
        if git(source, 'rev-parse', 'HEAD') != head or verify_upstream_tree(source) != before:
            raise ValueError('jcstress 构建期间原始源码改变')
        destination = output / 'jcstress.jar'
        shutil.copyfile(artifact, destination)
        receipt.update(state='BUILT', artifact=str(destination), artifactSha256=digest(destination))
        receipt['dependencies'] = {p.relative_to(repository).as_posix(): digest(p)
                                   for p in sorted(repository.rglob('*.jar'))}
    receipt['finishedAt'] = datetime.now().astimezone().isoformat()
    save(output / 'receipt.json', receipt)
    print('JCSTRESS_BUILD_RECEIPT=' + str(output / 'receipt.json'), flush=True)
    return 0 if receipt['state'] == 'BUILT' else 1


if __name__ == '__main__': raise SystemExit(main())
