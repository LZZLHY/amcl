#!/usr/bin/env python3
"""对锁定 pin 与完整 series 做字节比对，只接受干净基线或同一完整补丁集。

验证目录外置，未知修改不会被 reset/删除；源码身份与消费 SO 摘要独立记录。
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile


def git(source, *arguments):
    """Git 目标始终明确；失败立即终止，不从父仓库发现一个错误根目录。"""
    return subprocess.check_output(['git', '-C', str(source), *arguments])


def snapshot(source, names):
    """精确比较源码字节与文件集合，缺失文件保留为 None，不能只用 reverse-check 判断身份。"""
    return {name: hashlib.sha256((source/name).read_bytes()).hexdigest()
            if (source/name).is_file() else None for name in sorted(names)}


def verify(source, patch_dir, output, pin):
    """构造原始和期望 preimage/postimage；只有完整匹配才应用或复用。"""
    if git(source, 'rev-parse', 'HEAD').decode().strip() != pin:
        raise ValueError('Source HEAD must equal the exact locked commit')
    output.mkdir(parents=True, exist_ok=True)
    names = git(source, 'ls-tree', '-r', '--name-only', pin).decode().splitlines()
    patches = [patch_dir/row.strip() for row in (patch_dir/'series').read_text().splitlines()
               if row.strip() and not row.lstrip().startswith('#')]
    with tempfile.TemporaryDirectory(prefix='source-verify-', dir=output) as directory:
        directory=Path(directory)
        archive=directory/'source.tar'
        archive.write_bytes(git(source, 'archive', pin))
        original=directory/'original'; original.mkdir()
        with tarfile.open(archive) as stream:
            # Python 3.12 支持 data filter；旧工具链 Python 的成员来自锁定 git archive。
            if hasattr(tarfile, 'data_filter'): stream.extractall(original, filter='data')
            else: stream.extractall(original)
        baseline=snapshot(original,names)
        for patch in patches:
            subprocess.run(['git','apply','--unsafe-paths',str(patch.resolve())],cwd=original,
                           env={'PATH': __import__('os').environ['PATH'], 'GIT_CEILING_DIRECTORIES':str(directory)},check=True)
        patched_names=[p.relative_to(original).as_posix() for p in original.rglob('*') if p.is_file()]
        expected=snapshot(original,patched_names)
        actual_names=set(names)|set(git(source,'ls-files','--others','--exclude-standard').decode().splitlines())
        actual=snapshot(source,actual_names)
        if actual == baseline:
            for patch in patches: subprocess.run(['git','-C',str(source),'apply',str(patch.resolve())],check=True)
            mode='clean-baseline-applied'
        elif actual == expected:
            mode='exact-patched-reuse'
        else:
            differences=[name for name in set(actual)|set(expected) if actual.get(name)!=expected.get(name)]
            raise ValueError('Unknown source state; preserved without reset: '+', '.join(sorted(differences)[:12]))
        if snapshot(source,expected) != expected: raise ValueError('Postimage verification failed')
    result={'commit':pin,'sourceState':mode,'files':expected,
            'patches':[{'name':p.name,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in patches],
            'seriesSha256':hashlib.sha256((patch_dir/'series').read_bytes()).hexdigest()}
    (output/'source-identity.json').write_text(json.dumps(result,indent=2)+'\n')
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',required=True,type=Path)
    parser.add_argument('--patch-dir',required=True,type=Path)
    parser.add_argument('--output',required=True,type=Path)
    parser.add_argument('--pin',required=True)
    args=parser.parse_args()
    print(verify(args.source,args.patch_dir,args.output,args.pin)['sourceState'])
