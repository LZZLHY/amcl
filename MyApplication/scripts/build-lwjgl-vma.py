"""用本机 OHOS SDK 重建锁定的 LWJGL VMA JNI，保留 AMCL allocator 兼容策略。

源码必须来自现代槽声明的干净提交，唯一增量是版本化 local-worktree.patch。
构建、归档和证据全部外置；只有显式 --install 才替换规范 native，随后仍须执行
finalize-lwjgl-native-hashes.py --update-lock 和 build-lwjgl-jdk-views.py --update-lock。
诊断版本只用于独立取证，禁止安装进生产槽。编译与导出校验不代替真机 Vulkan 验证。
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
    """记录实际输入/产物字节；不以文件名或上游版本号代替内容身份。"""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, cwd=ROOT):
    """前台执行编译/校验，失败立即停止，不发布部分产物。"""
    print('[lwjgl-vma] ' + ' '.join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), cwd=cwd, check=True)


def exports(tool, library):
    """从真实动态符号表取 JNI 定义集，用既有消费库校准，拒绝漏接口。"""
    text = subprocess.check_output([str(tool), '--dyn-symbols', '--wide', str(library)], text=True)
    return sorted({line.split()[-1].split('@')[0] for line in text.splitlines()
                   if ' UND ' not in line and re.search(r'\b(?:Java_|JNI_OnLoad)', line)})


def main():
    """准备不可覆盖的候选目录，完成来源、ABI及静默检查后才允许安装。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True)
    parser.add_argument('--sdk', default=os.environ.get('OHOS_SDK_ROOT', ''))
    parser.add_argument('--install', action='store_true')
    parser.add_argument('--diagnostics', action='store_true')
    args = parser.parse_args()
    if args.install and args.diagnostics:
        parser.error('诊断库不能安装到生产现代槽')
    if not args.sdk:
        parser.error('必须显式指定 OpenHarmony SDK 根目录或 OHOS_SDK_ROOT')
    out = external_output_path(args.out)
    out.mkdir(parents=True, exist_ok=False)
    sdk = Path(args.sdk).resolve()
    suffix = '.exe' if os.name == 'nt' else ''
    clang = sdk / 'native/llvm/bin' / ('clang++' + suffix)
    strip = sdk / 'native/llvm/bin' / ('llvm-strip' + suffix)
    readelf = sdk / 'native/llvm/bin' / ('llvm-readelf' + suffix)
    source = ROOT / 'prebuilt/lwjgl3/lwjgl3_src'
    manifest = json.loads((ROOT / 'prebuilt/lwjgl3/modern-slot.manifest.json').read_text(encoding='utf-8'))
    commit = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if commit != manifest['sourceCommit']:
        raise RuntimeError('LWJGL checkout 不等于现代槽源码提交')
    if subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain', '--untracked-files=no'], text=True).strip():
        raise RuntimeError('LWJGL 源码工作树有修改；必须通过唯一版本化补丁表达')

    archive, prepared = out / 'source.tar', out / 'source'
    run(['git', '-C', source, 'archive', '--format=tar', '--output=' + str(archive), commit,
         'modules/lwjgl/core/src/main/c', 'modules/lwjgl/vma/src', 'modules/lwjgl/vulkan/src/main/c'])
    prepared.mkdir()
    with tarfile.open(archive) as stream:
        stream.extractall(prepared, filter='data')
    patch = ROOT / 'prebuilt/lwjgl3/local-worktree.patch'
    run(['git', 'apply', '--check', patch], cwd=prepared)
    run(['git', 'apply', patch], cwd=prepared)
    modules = prepared / 'modules/lwjgl'
    jni = ROOT / 'prebuilt/mod-natives/imgui-java/jni/jni-headers'
    common = ['--target=aarch64-linux-ohos', '--sysroot=' + str(sdk / 'native/sysroot'),
              '-O3', '-fPIC', '-DNDEBUG', '-std=c++17', '-DLWJGL_LINUX', '-DLWJGL_arm64',
              '-D__ANDROID_API__=24', '-D_GNU_SOURCE', '-D_FILE_OFFSET_BITS=64',
              '-D_LIBCPP_HAS_MUSL_LIBC', '-D_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE',
              '-DAMCL_VMA_DIAGNOSTICS=' + ('1' if args.diagnostics else '0')]
    for directory in [jni, jni / 'linux', modules / 'core/src/main/c', modules / 'core/src/main/c/linux',
                      modules / 'vma/src/main/c', modules / 'vulkan/src/main/c']:
        common += ['-I', str(directory)]
    objects = []
    for file in sorted((modules / 'vma/src/generated/c').glob('*.cpp')):
        obj = out / (file.stem + '.o')
        run([clang, *common, '-c', file, '-o', obj])
        objects.append(obj)
    if len(objects) != 2:
        raise RuntimeError('锁定 VMA JNI translation unit 数量改变，需重新审核')
    version = out / 'exports.ver'
    version.write_text('{ global: Java_*; JNI_OnLoad; local: *; };\n', encoding='utf-8')
    candidate = out / 'liblwjgl_vma.so'
    run([clang, *common, '-shared', '-Wl,--no-undefined', '-Wl,-z,noexecstack',
         '-Wl,--version-script=' + str(version), '-o', candidate, *objects])
    run([strip, '--strip-all', candidate])
    original = ROOT / 'entry/libs/arm64-v8a/liblwjgl_vma.so'
    before, after = exports(readelf, original), exports(readelf, candidate)
    if not before or before != after:
        raise RuntimeError('JNI动态导出集合与原消费库不一致')
    dyn = subprocess.check_output([str(readelf), '--dyn-symbols', '--wide', str(candidate)], text=True)
    if 'NSt3__1' in dyn:
        raise RuntimeError('产物混入非 OHOS libc++ ABI')
    marker = b'[AMCL_VULKAN_VMA]'
    if (marker in candidate.read_bytes()) != args.diagnostics:
        raise RuntimeError('VMA真实制品的诊断裁剪不符合请求')
    receipt = {'schemaVersion': 1, 'finishedAt': datetime.datetime.now().astimezone().isoformat(),
               'sourceCommit': commit, 'sourceArchiveSha256': sha(archive), 'patchSha256': sha(patch),
               'compilerSha256': sha(clang), 'compiler': subprocess.check_output([str(clang), '--version'], text=True).splitlines()[0],
               'diagnostics': args.diagnostics, 'flags': common, 'jniExports': after,
               'originalSha256': sha(original), 'sha256': sha(candidate), 'size': candidate.stat().st_size,
               'installed': args.install, 'scope': 'OHOS build/ABI/diagnostic inclusion only; device allocation requires separate validation'}
    (out / 'build-provenance.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    if args.install:
        shutil.copyfile(candidate, original)
        # 规范来源收据与native一起进入版本控制；后续清单工具只绑定最终已strip字节。
        (ROOT / 'prebuilt/lwjgl3/vma-build-provenance.json').write_text(
            json.dumps(receipt, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print('[lwjgl-vma] PASS: JNI exports preserved; diagnostic inclusion verified; candidate=' + str(candidate), flush=True)


if __name__ == '__main__':
    main()
