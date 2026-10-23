#!/usr/bin/env python3
"""在打包前记录实际 JDK 输入；不把固定 base commit 冒充含补丁的最终源码。"""
import argparse
import hashlib
import json
import os
import subprocess
from pathlib import Path


def digest(path):
    """返回文件原字节摘要，记录 patch/configure/工具链输入而非易漂移的描述文本。"""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(*args):
    """只执行只读身份查询，任一失败使打包停止。"""
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()


def main():
    """在独立 /build 现场生成完整输入身份，供包内清单与外部收据共用。"""
    parser = argparse.ArgumentParser()
    parser.add_argument('major', choices=['8', '17', '21', '25'])
    parser.add_argument('--image', type=Path, required=True)
    args = parser.parse_args()
    source = Path('/build/jdk' + args.major + 'u')
    base = json.loads(Path('/build/jdk' + args.major + '-source-base.json').read_text())
    if command('git', '-C', str(source), 'rev-parse', 'HEAD') != base['head']:
        raise ValueError('构建期间源码 HEAD 发生变化')
    patchdir = Path('/prebuilt/jdk') / args.major / 'patches'
    patches = {'series': digest(patchdir / 'series')}
    for line in (patchdir / 'series').read_text().splitlines():
        line = line.strip()
        if line and not line.startswith('#'):
            patches[line] = digest(patchdir / line)
    spec = args.image.parent.parent / 'spec.gmk'
    diff = subprocess.check_output(['git', '-C', str(source), 'diff', '--binary', 'HEAD'])
    base.update({'patches': patches, 'sourceDiffSha256': hashlib.sha256(diff).hexdigest(),
                 'specSha256': digest(spec),
                 'compiler': command('/usr/bin/ohos-clang', '--version'),
                 'bootJdk': command(os.environ['JAVA_HOME'] + '/bin/java', '-version'),
                 'sysrootSentinels': Path('/ohos-sysroot-rw/.amcl-input-identity').read_text().strip(),
                 'sysrootIdentityScope': 'setup recipe and three SDK sentinels; complete target libraries are verified separately',
                 'release': (args.image / 'release').read_text(),
                 'recipes': {p.name: digest(p) for p in [Path('/recipes/build_jdk' + args.major + '_ohos.sh'),
                             Path('/recipes/setup_toolchain.sh'), Path('/recipes/scripts/rebuild_libjli.sh'),
                             Path('/recipes/scripts/package_runtime.py'), Path('/recipes/scripts/pack_jdk_full.sh')]}})
    if args.major == '25':
        # 来源落盘前再次读取真实源码，不能把编译前曾通过或目录名当作最终身份。
        # 仅25启用此专项契约，其他主版本的输入、验证和行为保持原有流程。
        from verify_jdk25_safepoint import verify_source_contract
        guard = Path(__file__).with_name('verify_jdk25_safepoint.py')
        base['safepointContract'] = verify_source_contract(
            source, patchdir, Path('/prebuilt/jdk/build-inputs.json'))
        base['recipes'][guard.name] = digest(guard)
    if args.major == '8':
        # 经典版本的外部字体库也是发行内容，必须把它的源码、差异与配方一起绑定。
        base['freetypeBuild'] = json.loads(Path('/build/freetype-build-identity.json').read_text())
        for name in ('prepare_freetype8.sh', '../jdk8_musl_compat.c'):
            path = Path('/recipes/scripts') / name
            base['recipes'][name] = digest(path)
    Path('/build/jdk' + args.major + '-build-identity.json').write_text(
        json.dumps(base, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()
