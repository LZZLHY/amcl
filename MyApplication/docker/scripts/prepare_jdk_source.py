#!/usr/bin/env python3
"""取得固定 JDK commit；从不回退主线或清理旧源树，重复执行仅接受身份一致的现场。"""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path


def git(root, *args):
    """Git 参数独立传递；失败即终止构建，不用默认分支掩盖取源失败。"""
    return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()


def main():
    """输入为主版本和独占构建目录；输出源码及机器可读的基础身份。"""
    parser = argparse.ArgumentParser()
    parser.add_argument('major', choices=['8', '17', '21', '25'])
    parser.add_argument('--root', type=Path, default=Path('/build'))
    parser.add_argument('--inputs', type=Path, default=Path('/prebuilt/jdk/build-inputs.json'))
    args = parser.parse_args()
    item = json.loads(args.inputs.read_text())['runtimes'][args.major]
    target = args.root / ('jdk' + args.major + 'u')
    if not target.exists():
        target.mkdir()
        git(target, 'init')
        git(target, 'remote', 'add', 'origin', item['repository'])
    if not (target / '.git').is_dir():
        raise RuntimeError('源码目标不是独立 Git 仓库；请使用新的构建现场')
    if git(target, 'remote', 'get-url', 'origin') != item['repository']:
        raise RuntimeError('源码 remote 与锁定输入不一致')
    try:
        head = git(target, 'rev-parse', '--verify', 'HEAD')
    except subprocess.CalledProcessError:
        git(target, 'fetch', '--depth=1', 'origin', item['commit'])
        git(target, 'checkout', '--detach', 'FETCH_HEAD')
        head = git(target, 'rev-parse', 'HEAD')
    if head != item['commit']:
        raise RuntimeError('源码 HEAD 不一致；保留旧现场并使用新目录')
    # 补丁由后续统一 series 应用；这里只记录精确 base，不把带补丁工作树称为 clean。
    result = dict(item, major=args.major, head=head,
                  inputsSha256=hashlib.sha256(args.inputs.read_bytes()).hexdigest())
    (args.root / ('jdk' + args.major + '-source-base.json')).write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
