#!/usr/bin/env python3
"""准备 Fontconfig 的锁定源码和宿主 Meson，并导出可独立保存的源码归档。

所有下载均固定为提交或 SHA-256；已有目录只允许同身份、干净的源码复用。
失败保留原现场，不清理、不 reset，不把 HTTP 成功但内容错误的页面当成源码。
"""
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
import sys
import tarfile
import urllib.request
import zipfile


def run(*arguments):
    """参数按数组执行并立即传播失败，stdout 留在标准构建日志中。"""
    subprocess.run(arguments, check=True)


def git_text(root, *arguments):
    """读取 Git 实际身份，不用版本名称或目录名称代替提交证据。"""
    return subprocess.check_output(['git', '-C', str(root), *arguments], text=True).strip()


def verify_tool_tree(directory, expected):
    """逐文件核对工具展开树，阻止复用卷中的漂移脚本绕开原件 SHA 校验。

    上游源码和宿主工具的构建输出都在其他目录。这里不删除、补写或修复漂移
    文件；缺失、额外、链接或正文不同都保留现场并拒绝执行。归档中的空目录
    不参与内容身份，但现存目录的链接仍明确拒绝。
    """
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError('Tool extraction root is not a plain directory: ' + str(directory))
    seen = set()
    for path in directory.rglob('*'):
        if path.is_symlink():
            raise ValueError('Unexpected link in extracted tool: ' + str(path))
        if path.is_dir():
            continue
        name = path.relative_to(directory).as_posix()
        if not path.is_file() or name not in expected or path.read_bytes() != expected[name]:
            raise ValueError('Extracted tool differs from verified archive: ' + name)
        seen.add(name)
    if seen != set(expected):
        raise ValueError('Extracted tool is missing verified archive members')


def extract_meson(wheel, destination):
    """只收普通 wheel 文件，在首次展开和后续复用时执行同样的逐文件校验。"""
    expected, seen = {}, set()
    with zipfile.ZipFile(wheel) as archive:
        for item in archive.infolist():
            # ZipInfo 在 Windows 读取时也会正规化 filename；orig_filename 才
            # 保存中央目录原始路径。先检查原字节语义，不能让宿主替我们放宽路径。
            name = PurePosixPath(item.orig_filename)
            mode = item.external_attr >> 16
            if (name.is_absolute() or '..' in name.parts or '\\' in item.orig_filename
                    or item.filename in seen or mode & 0o170000 not in (0, 0o040000, 0o100000)):
                raise ValueError('Unexpected Meson wheel path/type')
            seen.add(item.filename)
            if not item.is_dir():
                expected[item.filename] = archive.read(item)
        if not destination.exists():
            destination.mkdir()
            archive.extractall(destination)
    verify_tool_tree(destination, expected)


def extract_gperf(source, root, directory_name):
    """只展开固定顶层下的普通源文件，复用目录必须仍与已验证 tar 一致。"""
    expected, seen = {}, set()
    with tarfile.open(source) as archive:
        for entry in archive.getmembers():
            name = PurePosixPath(entry.name)
            if (name.is_absolute() or '..' in name.parts or '\\' in entry.name
                    or not name.parts or name.parts[0] != directory_name
                    or entry.name in seen or not (entry.isdir() or entry.isfile())):
                raise ValueError('Unexpected gperf source path/type')
            seen.add(entry.name)
            if entry.isfile():
                relative = PurePosixPath(*name.parts[1:]).as_posix()
                expected[relative] = archive.extractfile(entry).read()
        if not (root / directory_name).exists():
            archive.extractall(root)
    verify_tool_tree(root / directory_name, expected)


def apply_fontconfig_defaults(directory, spec_path, output):
    """只接纳锁定基线/已知补后状态，复用同一受控 applier；原 Git 归档不混入适配。

    generic 宏头来自 HAP 现役规则的生成产物，作为独立编译输入冻结。源码导出包含
    原归档、完整补丁/宏头/配方及变换摘要，不把后加规则追认为较早 JDK 的编译输入。
    """
    spec = json.loads(spec_path.read_text())
    adaptation = json.loads((spec_path.parent / 'ohos-defaults.json').read_text())
    if adaptation['commit'] != spec['sources']['fontconfig']['commit']:
        raise ValueError('Fontconfig adaptation source commit differs from locked source')
    patch_dir = spec_path.parent / 'patches'
    patch = patch_dir / '0001-ohos-default-fonts-and-context-cache.patch'
    if hashlib.sha256(patch.read_bytes()).hexdigest() != adaptation['patchSha256']:
        raise ValueError('Fontconfig default patch identity changed')
    for name, expected in adaptation['before'].items():
        original = subprocess.check_output(['git', '-C', str(directory), 'show', 'HEAD:' + name])
        if hashlib.sha256(original).hexdigest() != expected:
            raise ValueError('Fontconfig adaptation base file differs from locked source: ' + name)
    header = (spec_path.parent / 'ohos-generic-fonts.h').read_bytes()
    destination = directory / 'src/amcl-generic-fonts.h'
    if (destination.is_symlink() or not destination.resolve().is_relative_to(directory.resolve()) or
            (destination.exists() and (not destination.is_file() or destination.read_bytes() != header))):
        raise ValueError('Unknown generated generic header in Fontconfig source; preserved')
    extra = set(git_text(directory, 'ls-files', '--others', '--exclude-standard').splitlines())
    if extra - {'src/amcl-generic-fonts.h'}:
        raise ValueError('Unknown untracked Fontconfig source inputs: ' + repr(sorted(extra)))
    # applier 从 HEAD 取原文，完整重放并验证全部现状，未知 tracked 修改不会被覆盖。
    run(sys.executable, '-B', str(Path(__file__).with_name('apply_jdk_patches.py')),
        '--target', str(directory), '--patch-dir', str(patch_dir))
    for name, digest in adaptation['after'].items():
        if hashlib.sha256((directory / name).read_bytes()).hexdigest() != digest:
            raise ValueError('Fontconfig transformed source mismatch: ' + name)
    if not destination.exists():
        destination.write_bytes(header)
    record = dict(adaptation, genericHeader='prebuilt/fontconfig/ohos-generic-fonts.h',
                  genericHeaderSha256=hashlib.sha256(header).hexdigest(),
                  compiledHeader='src/amcl-generic-fonts.h')
    (output / 'fontconfig-adaptation.json').write_text(json.dumps(record, indent=2) + '\n')
    return record


def main():
    """锁定来源后再解包工具；输出归档全在本次独占 output，不覆盖旧候选。"""
    spec_path, root, output = map(Path, sys.argv[1:])
    spec = json.loads(spec_path.read_text())
    identities = {}
    for name, item in spec['sources'].items():
        directory = root / name
        if not directory.exists():
            directory.mkdir()
            run('git', '-C', str(directory), 'init')
            run('git', '-C', str(directory), 'remote', 'add', 'origin', item['repository'])
            run('git', '-C', str(directory), 'fetch', '--depth=1', 'origin', item['commit'])
            run('git', '-C', str(directory), 'checkout', '--detach', 'FETCH_HEAD')
        if git_text(directory, 'remote', 'get-url', 'origin') != item['repository']:
            raise ValueError('Source repository mismatch: ' + name)
        if git_text(directory, 'rev-parse', 'HEAD') != item['commit']:
            raise ValueError('Source commit mismatch: ' + name)
        adaptation = None
        if name == 'fontconfig':
            adaptation = apply_fontconfig_defaults(directory, spec_path, output)
        elif git_text(directory, 'status', '--porcelain', '--untracked-files=all'):
            raise ValueError('Source has changes or unknown generated files: ' + name)
        archive = output / (name + '-' + item['commit'] + '.tar')
        run('git', '-C', str(directory), 'archive', '--format=tar', '--output=' + str(archive), 'HEAD')
        identities[name] = dict(item, archive=archive.name,
                                archiveSha256=hashlib.sha256(archive.read_bytes()).hexdigest())
        if adaptation is not None:
            identities[name]['adaptation'] = adaptation
    wheel = root / 'meson.whl'
    tool = spec['meson']
    if not wheel.exists():
        with urllib.request.urlopen(tool['url'], timeout=90) as incoming, wheel.open('xb') as outgoing:
            while block := incoming.read(1024 * 1024):
                outgoing.write(block)
    if hashlib.sha256(wheel.read_bytes()).hexdigest() != tool['sha256']:
        raise ValueError('Meson wheel SHA-256 mismatch; preserve the failed input')
    meson = root / 'meson'
    extract_meson(wheel, meson)
    (output / 'source-identities.json').write_text(json.dumps(identities, indent=2) + '\n')
    (output / 'meson.whl').write_bytes(wheel.read_bytes())
    # gperf 是宿主源码生成工具，不属于目标运行库。使用 GNU 发布公告的固定
    # SHA 校验，再检查归档包含范围；不修改镜像或 apt 安装状态。
    tool = spec['gperf']
    source = root / ('gperf-' + tool['version'] + '.tar.gz')
    if not source.exists():
        with urllib.request.urlopen(tool['url'], timeout=90) as incoming, source.open('xb') as outgoing:
            while block := incoming.read(1024 * 1024):
                outgoing.write(block)
    if hashlib.sha256(source.read_bytes()).hexdigest() != tool['sha256']:
        raise ValueError('gperf source SHA-256 mismatch')
    expected = 'gperf-' + tool['version']
    extract_gperf(source, root, expected)
    (output / source.name).write_bytes(source.read_bytes())


if __name__ == '__main__':
    main()
