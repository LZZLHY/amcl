#!/usr/bin/env python3
"""取得并核验上游HotSpot gtest的固定框架源码；只用于显式test-image构建。

三代锁定源码要求1.13/1.14及以上，这里固定共同支持的1.14.0。源树与JDK源码分离，
不把框架文件补进OpenJDK仓库。整个标准builder已持有工作卷锁；拒绝已有脏源/错HEAD，
不靠reset或clean接管未知输入。实际commit/tree/逐文件SHA写入独立来源收据。
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

REPOSITORY = 'https://github.com/google/googletest.git'
COMMIT = 'f8d7d77c06936315286eb55f8de22cd23c188571'


def git(source, *args):
    """失败即中止，输出原始Git错误供构建日志追踪；不执行任意shell文本。"""
    return subprocess.check_output(['git', '-C', str(source), *args])


def prepare(source, receipt):
    """返回唯一受控源码路径；复用时逐字节对照Git blob及额外文件集合。"""
    if source.is_symlink(): raise ValueError('gtest source cannot be a symlink')
    if not source.exists():
        source.mkdir(parents=True)
        git(source, 'init', '-q')
        git(source, 'remote', 'add', 'origin', REPOSITORY)
        git(source, 'fetch', '--depth=1', 'origin', COMMIT)
        git(source, '-c', 'core.autocrlf=false', 'checkout', '--detach', 'FETCH_HEAD')
    if git(source, 'rev-parse', 'HEAD').decode().strip() != COMMIT:
        raise ValueError('gtest source HEAD mismatch')
    git(source, 'diff', '--no-ext-diff', '--exit-code', 'HEAD', '--')
    if git(source, 'ls-files', '--others', '--exclude-standard').strip() or git(
            source, 'ls-files', '--others', '--ignored', '--exclude-standard').strip():
        raise ValueError('unregistered gtest source inputs')
    files = {}
    for entry in git(source, 'ls-tree', '-r', '-z', 'HEAD').split(b'\0'):
        if not entry: continue
        metadata, raw = entry.split(b'\t', 1)
        mode, kind, oid = metadata.split()
        if kind != b'blob' or mode not in (b'100644', b'100755'):
            raise ValueError('unexpected gtest tree member')
        path = source / raw.decode('utf-8')
        content = path.read_bytes()
        if path.is_symlink() or hashlib.sha1(b'blob ' + str(len(content)).encode() + b'\0' + content).hexdigest() != oid.decode():
            raise ValueError('gtest source bytes differ: ' + str(path))
        files[raw.decode('utf-8')] = hashlib.sha256(content).hexdigest()
    data = {'repository': REPOSITORY, 'commit': COMMIT, 'version': '1.14.0',
            'tree': git(source, 'rev-parse', 'HEAD^{tree}').decode().strip(), 'files': files}
    receipt.write_text(json.dumps(data, sort_keys=True, indent=2) + '\n', encoding='utf-8')
    return source


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--receipt', type=Path, required=True)
    args = parser.parse_args()
    print(prepare(args.source.resolve(), args.receipt.resolve()))
