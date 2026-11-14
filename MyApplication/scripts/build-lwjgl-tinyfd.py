"""从锁定LWJGL头/JNI与自有OHOS后端重建TinyFD，不编入桌面shell探测路径。

输出是独占候选，只有--install更新当前源码树的现代槽原件。链接用的broker来自同一
生产源码，SDK正常构建时再次编译并随HAP交付；它不是空桩或可单独替代HAP的发行件。
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
from lib.workspace_paths import external_output_path

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    """冻结实际输入和产物字节，不能把上游版本等同本地平台后端身份。"""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, cwd=ROOT):
    """编译前台执行，失败保留现场；不自动接受或安装部分成功产物。"""
    print('[tinyfd-build] ' + ' '.join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), cwd=cwd, check=True)


def symbols(tool, library):
    """读真实动态表，导出与导入分别审计，避免仅有同名未定义引用的假通过。"""
    text = subprocess.check_output([str(tool), '--dyn-symbols', '--wide', str(library)], text=True)
    defined, undefined = set(), set()
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 8 and parts[0].rstrip(':').isdigit():
            (undefined if parts[6] == 'UND' else defined).add(parts[7].split('@')[0])
    return defined, undefined


def main():
    """归档固定源码、构建真实provider、核JNI/依赖/禁用shell后才提交候选。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True)
    parser.add_argument('--sdk', required=True)
    parser.add_argument('--source', type=Path, default=ROOT / 'prebuilt/lwjgl3/lwjgl3_src')
    parser.add_argument('--install', action='store_true')
    args = parser.parse_args()
    out = external_output_path(args.out)
    out.mkdir(parents=True, exist_ok=False)
    sdk, source = Path(args.sdk).resolve(), args.source.resolve()
    suffix = '.exe' if os.name == 'nt' else ''
    tools = {name: sdk / 'native/llvm/bin' / (name + suffix) for name in ('clang', 'clang++', 'llvm-strip', 'llvm-readelf')}
    manifest = json.loads((ROOT / 'prebuilt/lwjgl3/modern-slot.manifest.json').read_text(encoding='utf-8'))
    commit = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if commit != manifest['sourceCommit']:
        raise RuntimeError('LWJGL源码身份与现代槽不一致')
    if subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain', '--untracked-files=no'], text=True).strip():
        raise RuntimeError('只读源码输入有未登记修改，保留并拒绝')
    archive, prepared = out / 'source.tar', out / 'source'
    run(['git', '-C', source, 'archive', '--format=tar', '--output=' + str(archive), commit,
         'modules/lwjgl/core/src/main/c', 'modules/lwjgl/tinyfd/src'])
    prepared.mkdir()
    with tarfile.open(archive) as stream:
        stream.extractall(prepared, filter='data')
    modules = prepared / 'modules/lwjgl'
    jni = ROOT / 'prebuilt/mod-natives/imgui-java/jni/jni-headers'
    backend = ROOT / 'prebuilt/lwjgl3/ohos-tinyfd/tinyfd_ohos.c'
    platform = ROOT / 'entry/src/main/cpp/platform'
    common = ['--target=aarch64-linux-ohos', '--sysroot=' + str(sdk / 'native/sysroot'),
              '-O2', '-fPIC', '-fvisibility=hidden', '-DNDEBUG', '-D_GNU_SOURCE', '-D_FILE_OFFSET_BITS=64']
    broker = out / 'libamcl_game_dialog.so'
    run([tools['clang++'], *common, '-std=c++17', '-fvisibility-inlines-hidden', '-shared',
         '-nostdlib++', '-lc++_shared', '--unwindlib=none', '-Wl,--no-undefined',
         '-Wl,-soname,libamcl_game_dialog.so', '-Wl,-z,noexecstack', platform / 'game_dialog.cpp', '-o', broker])
    flags = [*common, '-std=c11', '-DLWJGL_LINUX', '-DLWJGL_arm64', '-D__ANDROID_API__=24']
    for directory in (jni, jni / 'linux', modules / 'core/src/main/c', modules / 'core/src/main/c/linux',
                      modules / 'tinyfd/src/main/c', platform):
        flags += ['-I', str(directory)]
    sources = [backend, modules / 'tinyfd/src/generated/c/org_lwjgl_util_tinyfd_TinyFileDialogs.c']
    objects = []
    for file in sources:
        obj = out / (file.stem + '.o')
        run([tools['clang'], *flags, '-c', file, '-o', obj])
        objects.append(obj)
    version = out / 'exports.ver'
    version.write_text('{ global: Java_*; JNI_OnLoad; local: *; };\n', encoding='utf-8')
    candidate = out / 'liblwjgl_tinyfd.so'
    run([tools['clang'], *flags, '-shared', '-Wl,--no-undefined', '-Wl,-z,noexecstack',
         '-Wl,--version-script=' + str(version), '-Wl,-soname,liblwjgl_tinyfd.so',
         *objects, '-L', out, '-lamcl_game_dialog', '-o', candidate])
    run([tools['llvm-strip'], '--strip-all', candidate])
    original = ROOT / 'entry/libs/arm64-v8a/liblwjgl_tinyfd.so'
    old, _ = symbols(tools['llvm-readelf'], original)
    new, imports = symbols(tools['llvm-readelf'], candidate)
    jni_old = {name for name in old if name.startswith('Java_')}
    if not jni_old or jni_old != {name for name in new if name.startswith('Java_')}:
        raise RuntimeError('实际JNI导出不完整')
    if imports.intersection({'popen', 'system', 'fork', 'execve', 'fgets', 'getchar'}):
        raise RuntimeError('OHOS后端意外携带桌面shell/控制台路径')
    dynamic = subprocess.check_output([str(tools['llvm-readelf']), '-d', str(candidate)], text=True)
    needed = re.findall(r'Shared library: \[([^\]]+)\]', dynamic)
    if set(needed) != {'libc.so', 'libamcl_game_dialog.so'}:
        raise RuntimeError('TinyFD依赖集合不匹配：' + str(needed))
    broker_exports, _ = symbols(tools['llvm-readelf'], broker)
    required = {name for name in imports if name.startswith('AmclGameDialog')}
    if not required or not required.issubset(broker_exports):
        raise RuntimeError('真实broker未实现TinyFD全部C ABI引用')
    receipt = {'schemaVersion': 1, 'finishedAt': datetime.datetime.now().astimezone().isoformat(),
               'sourceCommit': commit, 'sourceArchiveSha256': sha(archive), 'recipeSha256': sha(Path(__file__)),
               'backendSha256': sha(backend), 'brokerSourceSha256': sha(platform / 'game_dialog.cpp'),
               'brokerHeaderSha256': sha(platform / 'game_dialog.h'), 'compilerSha256': sha(tools['clang']),
               'jniExports': sorted(jni_old), 'needed': needed, 'brokerImports': sorted(required),
               'sha256': sha(candidate), 'size': candidate.stat().st_size, 'originalSha256': sha(original),
               'installed': args.install, 'scope': 'OHOS ABI and sources; real dialogs/game require tablet validation'}
    (out / 'provenance.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    if args.install:
        shutil.copyfile(candidate, original)
        shutil.copyfile(out / 'provenance.json', ROOT / 'prebuilt/lwjgl3/tinyfd-build-provenance.json')
    print('[tinyfd-build] PASS: actual JNI/NEEDED/provider verified; no shell imports', flush=True)


if __name__ == '__main__':
    main()
