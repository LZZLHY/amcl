#!/usr/bin/env python3
"""在打包前记录实际 JDK 输入；不把固定 base commit 冒充含补丁的最终源码。"""
import argparse
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path
from jdk_source_inputs import extra_source_inputs


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
    added_paths = set()
    for line in (patchdir / 'series').read_text().splitlines():
        line = line.strip()
        if line and not line.startswith('#'):
            patches[line] = digest(patchdir / line)
            added_paths.update(re.findall(r'^\+\+\+ b/([^\n\t]+)',
                                         (patchdir / line).read_text(), re.M))
    spec = args.image.parent.parent / 'spec.gmk'
    diff = subprocess.check_output(['git', '-C', str(source), 'diff', '--binary', 'HEAD'])
    base.update({'patches': patches, 'sourceDiffSha256': hashlib.sha256(diff).hexdigest(),
                 'patchAddedSourceFiles': extra_source_inputs(source, added_paths),
                 'specSha256': digest(spec),
                 'compiler': command('/usr/bin/ohos-clang', '--version'),
                 'bootJdk': command(os.environ['JAVA_HOME'] + '/bin/java', '-version'),
                 'sysrootSentinels': Path('/ohos-sysroot-rw/.amcl-input-identity').read_text().strip(),
                 'sysrootIdentityScope': 'setup recipe and three SDK sentinels; complete target libraries are verified separately',
                 'release': (args.image / 'release').read_text(),
                 'recipes': {p.name: digest(p) for p in [Path('/recipes/build_jdk' + args.major + '_ohos.sh'),
                             Path('/recipes/setup_toolchain.sh'), Path('/recipes/scripts/rebuild_libjli.sh'),
                             Path('/recipes/scripts/package_runtime.py'), Path('/recipes/scripts/pack_jdk_full.sh'),
                             Path('/recipes/scripts/verify_jdk_abi.py'), Path('/recipes/scripts/midi_runtime_gate.py'),
                             Path('/recipes/scripts/verify_jdk_ports.py')]}})
    base['recipes']['jdk_source_inputs.py'] = digest(Path(__file__).with_name('jdk_source_inputs.py'))
    if args.major != '8':
        from sync_jdk_jmods import verify as verify_jmods, module_payloads
        verify_jmods(args.image)
        base['recipes']['sync_jdk_jmods.py'] = digest(Path(__file__).with_name('sync_jdk_jmods.py'))
        base['jmodClosure'] = {name: digest(args.image / 'jmods' / name) for name in module_payloads(args.image)}
    # 执行器在运行前复制并核对完整配方和目标 SDK。这里只绑定同一次真实执行
    # 的清单，不把当前宿主活目录重新扫描后冒充已经编译过的输入。
    inputs = json.loads(Path('/output/build-inputs.json').read_text())
    if inputs['digest'] != os.environ.get('AMCL_TARGET_INPUTS_DIGEST'):
        raise ValueError('Frozen input identity differs from executing builder')
    base['inputClosure'] = inputs
    if os.environ.get('AMCL_JDK_TEST_IMAGE') == '1':
        base['gtestSource'] = json.loads(Path('/build/upstream-googletest.json').read_text())
    abi_dir = Path('/build/jdk8-libs' if args.major == '8' else '/output/jdk-libs')
    base['cxxAbi'] = json.loads((abi_dir / 'abi-provider.json').read_text())
    if digest(abi_dir / 'libc++_shared.so') != base['cxxAbi']['providerSha256']:
        raise ValueError('C++ ABI provider changed after validation')
    base['sysrootIdentityScope'] = 'complete frozen target SDK inputs; host tools bound to image ID'
    if args.major in ('17', '21', '25'):
        # 来源落盘前再次读取真实源码，不能把编译前曾通过或目录名当作最终身份。
        # 三个现代主版本各验自身锁定上游；JDK8保留独立的经典安全点实现。
        from verify_jdk25_safepoint import verify_source_contract
        guard = Path(__file__).with_name('verify_jdk25_safepoint.py')
        base['safepointContract'] = verify_source_contract(
            source, patchdir, Path('/prebuilt/jdk/build-inputs.json'), args.major)
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
