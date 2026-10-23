#!/usr/bin/env python3
"""编译可复用NOLOAD/I/O真实宿主控制；独立输出，绝不替代设备图形资格。"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import subprocess

def sha(path):
    """从真实字节核身份，copy必须与同次实际fixture一致。"""
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    """每次使用新仓外构建/运行目录，固定命令与所有源码摘要均写收据。"""
    parser = argparse.ArgumentParser()
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    source = Path(__file__).resolve().parent
    project = source.parents[1]
    for directory in [args.build, args.output]:
        if directory.resolve().is_relative_to(project):
            raise ValueError('output must be outside application repository')
        directory.mkdir(parents=True, exist_ok=False)
    owner, facade = args.build / 'libimage-owner.so', args.build / 'libimage-facade.so'
    executable = args.build / 'image-evidence-test'
    commands = [
        ['c++', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror', str(source / 'image_owner_fixture.cpp'), '-o', str(owner)],
        ['c++', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror', str(source / 'image_facade_fixture.cpp'), str(owner), '-o', str(facade)],
        ['c++', '-std=c++17', '-Wall', '-Wextra', '-Werror', str(source / 'loaded_image_evidence_test.cpp'), '-ldl', '-o', str(executable)],
        [str(executable), str(owner), str(facade), str(args.output)]]
    receipt = {'startedAt': datetime.now().astimezone().isoformat(), 'scope': 'Host image identity and checked I/O only; no GPU/OHOS qualification',
               'sources': {name: sha(source / name) for name in ['image_owner_fixture.cpp', 'image_facade_fixture.cpp', 'loaded_image_evidence_test.cpp', 'run-image-evidence-host.py']},
               'sharedHelperSha256': sha(project / 'entry/src/main/cpp/tests/test_loaded_image_evidence.h'), 'commands': []}
    for index, command in enumerate(commands):
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
        log = args.output / f'command-{index}.log'
        log.write_text(result.stdout, encoding='utf-8')
        receipt['commands'].append({'command': command, 'exitCode': result.returncode, 'logSha256': sha(log)})
        print(result.stdout, end='', flush=True)
        if result.returncode:
            receipt['finishedAt'] = datetime.now().astimezone().isoformat()
            (args.output / 'receipt.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')
            return result.returncode
    receipt['ownerSha256'] = sha(owner)
    receipt['actualCopySha256'] = sha(args.output / 'loaded-owner.so')
    receipt['passed'] = receipt['ownerSha256'] == receipt['actualCopySha256']
    receipt['finishedAt'] = datetime.now().astimezone().isoformat()
    (args.output / 'receipt.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')
    return 0 if receipt['passed'] else 1

if __name__ == '__main__':
    raise SystemExit(main())
