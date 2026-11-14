#!/usr/bin/env python3
"""从四代锁定 Git 对象导出字体回退补前/补后输入；只读源克隆，新目录保留完整字节。"""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess


def main():
    """每代先核原文件和补丁，再真实 git apply；未知输入或既有输出均拒绝覆盖。"""
    parser = argparse.ArgumentParser()
    parser.add_argument('--source-root', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    if args.output.resolve().is_relative_to(root):
        raise ValueError('输出必须在源码仓外')
    args.output.mkdir(parents=True, exist_ok=False)
    spec = json.loads(Path(__file__).with_name('fallback-cases.json').read_text(encoding='utf-8'))
    locked = json.loads((root / 'prebuilt/jdk/build-inputs.json').read_text())['runtimes']
    stream_spec = json.loads(Path(__file__).with_name('stream-cases.json').read_text())['runtimes']
    manifest = {'schemaVersion': 2, 'kind': 'fontconfig-fallback-sources',
                'createdAt': datetime.now().astimezone().isoformat(), 'runtimes': {}}
    for major, item in spec['runtimes'].items():
        assert item['commit'] == locked[major]['commit']
        repo = args.source_root / ('jdk-protocol-' + major)
        patch = root / 'prebuilt/jdk' / major / 'patches/0018-fontconfig-preserve-fallback-coverage.patch'
        assert hashlib.sha256(patch.read_bytes()).hexdigest() == item['patchSha256']
        stage = args.output / ('jdk' + major)
        stage.mkdir()
        files = {}
        stream = stream_spec[major]
        assert stream['commit'] == item['commit']
        originals = dict(item['files'], **{stream['path']: stream['beforeSha256']})
        for name, expected in originals.items():
            data = subprocess.check_output(['git', '-C', str(repo), 'show', item['commit'] + ':' + name])
            assert hashlib.sha256(data).hexdigest() == expected
            target = stage / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            label = 'stream' if name == stream['path'] else 'native' if name.endswith('.c') else 'java'
            files[label] = {'sourcePath': name, 'before': data.decode('utf-8')}
        environment = dict(os.environ, GIT_CEILING_DIRECTORIES=str(stage.parent))
        for check in (['--check'], []):
            subprocess.run(['git', '-c', 'core.autocrlf=false', 'apply', *check, str(patch)],
                           cwd=stage, env=environment, check=True)
        stream_patch = root / 'prebuilt/jdk' / major / 'patches/0022-freetype-stream-jni-and-cache-boundary.patch'
        assert hashlib.sha256(stream_patch.read_bytes()).hexdigest() == stream['patchSha256']
        for check in (['--check'], []):
            subprocess.run(['git', '-c', 'core.autocrlf=false', 'apply', *check, str(stream_patch)],
                           cwd=stage, env=environment, check=True)
        assert hashlib.sha256((stage / stream['path']).read_bytes()).hexdigest() == stream['afterSha256']
        entry = {'commit': item['commit'], 'patchSha256': item['patchSha256'],
                 'streamPatchSha256': stream['patchSha256'], 'files': {}}
        for label, source in files.items():
            entry['files'][label] = {'sourcePath': source['sourcePath']}
            for variant, text in [('before', source['before']), ('after', (stage / source['sourcePath']).read_text(encoding='utf-8'))]:
                name = major + '-' + label + '-' + variant + ('.java' if label == 'java' else '.c')
                data = text.encode('utf-8')
                (args.output / name).write_bytes(data)
                entry['files'][label][variant] = {'file': name, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
        manifest['runtimes'][major] = entry
    (args.output / 'sources.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(args.output / 'sources.json')


if __name__ == '__main__':
    main()
