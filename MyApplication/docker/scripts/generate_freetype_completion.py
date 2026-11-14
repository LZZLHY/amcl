#!/usr/bin/env python3
"""从各 JDK 对应的真实 FreeType 提交生成字体服务恢复补丁与逐文件来源。

补丁导入上游原始正文，不拼接不同 FreeType 版本；原 JDK 压缩/渲染选项不变。
BDF/PCF 驱动、SFNT 的 BDF 服务和公共查询函数必须一起恢复，不能只导出空桩。
"""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import re
import subprocess

VERSIONS = {
    '17': ('2.13.3', '42608f77f20749dd6ddc9e0536788eaad70ea4b5'),
    '21': ('2.13.2', '920c5502cc3ddda88f6c7d85ee834ac611bb11cc'),
    '25': ('2.14.2', 'f4205da14867c5387cd6a329b90ee10a6df6eeff'),
}
PREFIX = 'src/java.desktop/share/native/libfreetype/'
PATCH = '0016-fontconfig-freetype-bdf-pcf-completion.patch'


def git(repo, *arguments):
    """只读 Git 对象；所有引用均由锁定提交组成，不修改源克隆的工作树。"""
    return subprocess.check_output(['git', '-C', str(repo), *arguments])


def sha(data):
    return hashlib.sha256(data).hexdigest()


def delta(name, old, new):
    """生成标准普通文本 git diff；新增文件明确使用 /dev/null 作为基线。"""
    header = f'diff --git a/{name} b/{name}\n'
    if old is None:
        header += 'new file mode 100644\n'
    return header + ''.join(difflib.unified_diff(
        [] if old is None else old.decode().splitlines(keepends=True), new.decode().splitlines(keepends=True),
        fromfile='/dev/null' if old is None else 'a/' + name, tofile='b/' + name))


def main():
    """输出只落主仓的 patch、来源清单和许可证；证据/构建树仍由调用者外置。"""
    parser = argparse.ArgumentParser()
    parser.add_argument('--freetype-repo', type=Path, required=True)
    for major in VERSIONS:
        parser.add_argument('--jdk' + major + '-repo', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    inputs = json.loads((root / 'prebuilt/jdk/build-inputs.json').read_text())['runtimes']
    manifest = {'schemaVersion': 1, 'purpose': 'Restore real Fontconfig BDF/PCF service closure',
                'repository': 'https://github.com/freetype/freetype.git', 'runtimes': {}}
    for major, (version, commit) in VERSIONS.items():
        jdk = getattr(args, 'jdk' + major + '_repo')
        base = inputs[major]['commit']
        version_header = git(jdk, 'show', base + ':' + PREFIX + 'include/freetype/freetype.h')
        numbers = [re.search(rb'^#define FREETYPE_' + key + rb'\s+(\d+)', version_header, re.M)[1].decode()
                   for key in (b'MAJOR', b'MINOR', b'PATCH')]
        if '.'.join(numbers) != version:
            raise ValueError('JDK FreeType version differs from locked import: ' + major)
        files = git(args.freetype_repo, 'ls-tree', '-r', '--name-only', commit, '--',
                    'src/bdf', 'src/pcf').decode().splitlines()
        files = [name for name in files if Path(name).suffix in ('.c', '.h')
                 and name not in ('src/bdf/bdf.c', 'src/pcf/pcf.c')]
        files += ['src/base/ftbdf.c', 'src/sfnt/ttbdf.c', 'src/sfnt/ttbdf.h',
                  'include/freetype/ftlzw.h', 'include/freetype/ftbzip2.h']
        changes, source_files = [], {}
        for name in sorted(files):
            destination = PREFIX + name
            if git(jdk, 'ls-tree', base, '--', destination):
                raise ValueError('Expected deliberately omitted JDK source: ' + destination)
            original = git(args.freetype_repo, 'show', commit + ':' + name)
            changes.append(delta(destination, None, original))
            source_files[name] = {'sha256': sha(original), 'target': destination}
        # 只打开恢复模块需要的服务，不改已有 TT/CFF/Type1/抗锯齿、压缩或 PNG 选项。
        controls = {}
        for name in ('include/freetype/config/ftmodule.h', 'include/freetype/config/ftoption.h'):
            original = git(jdk, 'show', base + ':' + PREFIX + name)
            changed = original.decode()
            if name.endswith('ftmodule.h'):
                for driver in ('pcf_driver_class', 'bdf_driver_class'):
                    before = '// FT_USE_MODULE( FT_Driver_ClassRec, ' + driver + ' )'
                    if changed.count(before) != 1:
                        raise ValueError('Unknown JDK module declaration: ' + major + '/' + driver)
                    changed = changed.replace(before, '/* AMCL：恢复真实字体驱动，为 Fontconfig 的 BDF 属性查询提供完整服务。 */\n'
                                              + before.removeprefix('// '))
            else:
                before = '/* #define TT_CONFIG_OPTION_BDF */'
                if changed.count(before) != 1:
                    raise ValueError('Unknown JDK SFNT BDF configuration: ' + major)
                changed = changed.replace(before,
                    '/* AMCL：读取 SFNT 内嵌 BDF 属性，与恢复的 ttbdf.c 服务共同启用。 */\n'
                    '#define TT_CONFIG_OPTION_BDF')
            changed = changed.encode()
            changes.append(delta(PREFIX + name, original, changed))
            controls[name] = {'beforeSha256': sha(original), 'afterSha256': sha(changed)}
        patch = ''.join(changes).encode()
        destination = root / 'prebuilt/jdk' / major / 'patches' / PATCH
        destination.write_bytes(patch)
        series = destination.parent / 'series'
        existing = series.read_bytes()
        if PATCH.encode() not in existing.splitlines():
            series.write_bytes(existing.rstrip() + b'\n\n' +
                '# Fontconfig：恢复本代 FreeType 的真实 BDF/PCF 驱动及查询服务，不裁减 FC 能力。\n'.encode() +
                PATCH.encode() + b'\n')
        licenses = {}
        for name in ('LICENSE.TXT', 'docs/FTL.TXT', 'docs/GPLv2.TXT'):
            content = git(args.freetype_repo, 'show', commit + ':' + name)
            target = root / 'prebuilt/fontconfig/licenses' / ('freetype-' + version) / Path(name).name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
            licenses[name] = {'path': target.relative_to(root).as_posix(), 'sha256': sha(content)}
        manifest['runtimes'][major] = {
            'jdkCommit': base, 'version': version, 'commit': commit,
            'jdkHeaderSha256': sha(version_header), 'patch': destination.relative_to(root).as_posix(),
            'patchSha256': sha(patch), 'importedFiles': source_files, 'controls': controls, 'licenses': licenses,
        }
    target = root / 'prebuilt/fontconfig/freetype-completion.json'
    target.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print('Generated version-matched FreeType completion patches for JDK 17, 21, 25')


if __name__ == '__main__':
    main()
