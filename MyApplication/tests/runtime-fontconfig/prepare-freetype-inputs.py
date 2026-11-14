#!/usr/bin/env python3
"""从锁定的三份 JDK 基线重放完整 series，导出只读字体测试输入。

验证工作树显式位于调用者提供的仓外目录，借用原克隆对象但不修改原工作树。
输入归档分别保存真实基线和完整补丁结果；每个正文、patch、许可证均有摘要。
该过程不构建 JDK，不把独立字体测试写成整包资格。
"""
import argparse
from datetime import datetime
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import tarfile


PREFIX = 'src/java.desktop/share/native/libfreetype/'


def sha(data):
    """所有身份都基于原始字节；这里不对源码换行进行隐式归一化。"""
    return hashlib.sha256(data).hexdigest()


def run(*args, **kwargs):
    """子命令失败立即停止，完整输出由调用方保存，避免后续步骤伪装成功。"""
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def git(root, *args):
    """只读 Git 对象的字节接口，保留上游正文和真实提交身份。"""
    return subprocess.check_output(['git', '-C', str(root), *args])


def archive_files(output, files):
    """固定顺序和元数据写普通文件归档；输出必须不存在，绝不覆盖旧证据。"""
    index = {}
    with output.open('xb') as raw, tarfile.open(fileobj=raw, mode='w') as archive:
        for name, content in sorted(files.items()):
            entry = tarfile.TarInfo(name)
            entry.size, entry.mode = len(content), 0o644
            archive.addfile(entry, io.BytesIO(content))
            index[name] = {'size': len(content), 'sha256': sha(content)}
    return {'file': output.name, 'sha256': sha(output.read_bytes()), 'files': index}


def main():
    """仅新建验证树，完整 series 的首次与重复应用都必须成功且正文不漂移。"""
    parser = argparse.ArgumentParser()
    for major in ('17', '21', '25'):
        parser.add_argument('--jdk' + major + '-repo', type=Path, required=True)
    parser.add_argument('--verification-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    spec = json.loads((root / 'prebuilt/fontconfig/freetype-completion.json').read_text())
    args.verification_root.mkdir(parents=True, exist_ok=False)
    args.output.mkdir(parents=True, exist_ok=False)
    report = {'schemaVersion': 1, 'createdAt': datetime.now().astimezone().isoformat(),
              'purpose': 'Version-matched complete-series FreeType behavior QA', 'runtimes': {}}
    for major, item in spec['runtimes'].items():
        original = getattr(args, 'jdk' + major + '_repo').resolve()
        if git(original, 'rev-parse', 'HEAD').decode().strip() != item['jdkCommit']:
            raise ValueError('Unexpected JDK source HEAD: ' + major)
        directory = args.verification_root / ('jdk' + major)
        patches = root / 'prebuilt/jdk' / major / 'patches'
        names, patch_index = set(), {}
        for line in (patches / 'series').read_text().splitlines():
            name = line.strip()
            if not name or name.startswith('#'):
                continue
            content = (patches / name).read_bytes()
            patch_index[name] = sha(content)
            names.update(re.findall(r'^\+\+\+ b/([^\r\n\t]+)', content.decode(), re.M))
        # worktree 复用已有 partial clone 的按需取对象能力；clone --shared 在
        # 部分 Git 版本中反而尝试通过本地 upload-pack 取得未物化的所有对象。
        # sparse-checkout set 使用当前 Git 的工作树独立配置，不改原树的路径集。
        # 原对象库必须保留，manifest 保存该恢复依赖，不能把新树当正式源项目。
        run('git', '-C', original, 'worktree', 'add', '--detach', '--no-checkout', directory, item['jdkCommit'])
        run('git', '-C', directory, 'sparse-checkout', 'set', '--no-cone', '--stdin',
            input=('\n'.join('/' + name for name in sorted(names)) + '\n/' + PREFIX + '\n').encode())
        run('git', '-C', directory, 'config', '--worktree', 'core.autocrlf', 'false')
        run('git', '-C', directory, 'checkout', '--detach', item['jdkCommit'])
        baseline = {name[len(PREFIX):]: git(original, 'show', item['jdkCommit'] + ':' + name)
                    for name in git(original, 'ls-tree', '-r', '--name-only', item['jdkCommit'],
                                    '--', PREFIX).decode().splitlines()}
        before = archive_files(args.output / ('jdk' + major + '-before.tar'), baseline)
        command = [sys.executable, '-B', str(root / 'docker/scripts/apply_jdk_patches.py'),
                   '--target', str(directory), '--patch-dir', str(patches)]
        for attempt in ('first', 'repeat'):
            completed = run(*command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            (args.output / ('jdk' + major + '-' + attempt + '-series.log')).write_bytes(completed.stdout)
            print(completed.stdout.decode(), end='', flush=True)
        # 新导入文件和配置必须与版本匹配来源逐字节一致，不能只看 patch 返回 0。
        for name, imported in item['importedFiles'].items():
            if sha((directory / imported['target']).read_bytes()) != imported['sha256']:
                raise ValueError('Imported source mismatch: ' + major + '/' + name)
        for name, control in item['controls'].items():
            if sha((directory / PREFIX / name).read_bytes()) != control['afterSha256']:
                raise ValueError('Configuration mismatch: ' + major + '/' + name)
        for license_item in item['licenses'].values():
            if sha((root / license_item['path']).read_bytes()) != license_item['sha256']:
                raise ValueError('License identity mismatch')
        modified = {path.relative_to(directory / PREFIX).as_posix(): path.read_bytes()
                    for path in (directory / PREFIX).rglob('*') if path.is_file()}
        after = archive_files(args.output / ('jdk' + major + '-after.tar'), modified)
        report['runtimes'][major] = {'jdkCommit': item['jdkCommit'], 'freeTypeVersion': item['version'],
            'freeTypeImportCommit': item['commit'], 'sourceObjectDependency': str(original),
            'verificationTree': str(directory), 'seriesSha256': sha((patches / 'series').read_bytes()),
            'patches': patch_index, 'licenses': item['licenses'], 'before': before, 'after': after}
        print('PASS source closure JDK', major, len(baseline), '->', len(modified), 'files', flush=True)
    report['finishedAt'] = datetime.now().astimezone().isoformat()
    (args.output / 'sources.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
