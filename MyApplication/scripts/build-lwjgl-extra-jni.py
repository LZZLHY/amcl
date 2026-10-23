"""用本机 OHOS SDK 从现代槽锁定源码构建 NanoVG 与 OpenGL ES JNI。

两个模块均消费上游真实生成代码。NanoVG 的 GL/GLES 取址由上游绑定关联到
调用线程的 LWJGL 能力表，不直接链接系统 GLES，避免绕过所选图形后端。
候选源码、对象和来源收据必须外置；显式 --install 才发布到工程交付目录。
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

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    """以真实字节记录源码工具和产物身份，不把版本字符串当来源证明。"""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, cwd=ROOT):
    """前台执行单个命令并保留编译输出；失败不发布部分候选。"""
    print('[lwjgl-extra-jni] ' + ' '.join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), cwd=cwd, check=True)


def main():
    """准备独占目录，构建并核对完整 JNI 导出后才安装候选。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True)
    parser.add_argument('--sdk', required=True)
    parser.add_argument('--install', action='store_true')
    args = parser.parse_args()
    out = Path(args.out).resolve()
    # 避免 cwd 或错误参数把源码导出和对象写回工程；产物安装是唯一例外。
    if out == ROOT or ROOT in out.parents:
        parser.error('--out 必须是工程之外的独占目录')
    out.mkdir(parents=True, exist_ok=False)
    sdk = Path(args.sdk).resolve()
    suffix = '.exe' if os.name == 'nt' else ''
    clang = sdk / 'native/llvm/bin' / ('clang' + suffix)
    strip = sdk / 'native/llvm/bin' / ('llvm-strip' + suffix)
    readelf = sdk / 'native/llvm/bin' / ('llvm-readelf' + suffix)
    source = ROOT / 'prebuilt/lwjgl3/lwjgl3_src'
    manifest = json.loads((ROOT / 'prebuilt/lwjgl3/modern-slot.manifest.json').read_text())
    commit = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if commit != manifest['sourceCommit']:
        raise RuntimeError('LWJGL 源码身份不等于现代槽锁定提交')
    if subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain', '--untracked-files=no'], text=True).strip():
        raise RuntimeError('LWJGL 源码有未登记改动')
    archive, prepared = out / 'source.tar', out / 'source'
    paths = ['modules/lwjgl/' + part for part in
             ('core/src/main/c', 'nanovg/src', 'opengles/src', 'stb/src/main/c')]
    run(['git', '-C', source, 'archive', '--format=tar', '--output=' + str(archive), commit, *paths])
    prepared.mkdir()
    with tarfile.open(archive) as stream:
        stream.extractall(prepared, filter='data')
    modules = prepared / 'modules/lwjgl'
    jni = ROOT / 'prebuilt/mod-natives/imgui-java/jni/jni-headers'
    flags = ['--target=aarch64-linux-ohos', '--sysroot=' + str(sdk / 'native/sysroot'),
             '-O2', '-fPIC', '-fvisibility=hidden', '-DNDEBUG', '-std=c11',
             '-DLWJGL_LINUX', '-DLWJGL_arm64', '-D__ANDROID_API__=24',
             '-D_GNU_SOURCE', '-D_FILE_OFFSET_BITS=64']
    for directory in (jni, jni / 'linux', modules / 'core/src/main/c',
                      modules / 'core/src/main/c/linux', modules / 'stb/src/main/c'):
        flags += ['-I', str(directory)]
    version = out / 'exports.ver'
    version.write_text('{ global: Java_*; JNI_OnLoad; local: *; };\n')
    records = []
    for module in ('nanovg', 'opengles'):
        module_dir = out / module
        module_dir.mkdir()
        sources = sorted((modules / module / 'src/generated/c').glob('*.c'))
        if not sources:
            raise RuntimeError('模块缺少上游生成的真实 JNI 源码：' + module)
        objects = []
        for file in sources:
            obj = module_dir / (file.stem + '.o')
            run([clang, *flags, '-I', modules / module / 'src/main/c', '-c', file, '-o', obj])
            objects.append(obj)
        candidate = out / ('liblwjgl_' + module + '.so')
        run([clang, *flags, '-shared', '-Wl,--no-undefined', '-Wl,-z,noexecstack',
             '-Wl,--version-script=' + str(version), '-Wl,-soname,' + candidate.name,
             '-o', candidate, *objects, '-lm'])
        run([strip, '--strip-all', candidate])
        symbols = subprocess.check_output([str(readelf), '--dyn-syms', '--wide', str(candidate)], text=True)
        actual = {line.split()[-1].split('@')[0] for line in symbols.splitlines()
                  if ' UND ' not in line and 'Java_' in line}
        expected = {symbol for file in sources for symbol in
                    re.findall(r'\bJava_[A-Za-z0-9_]+(?=\s*\()', file.read_text())}
        if module == 'nanovg':
            # allocator 入口由 lwjgl_malloc.h 的 LWJGL_MALLOC_LIB 宏展开，
            # 不能只按生成 .c 的字面函数声明漏掉这一项真实必需导出。
            expected.add('Java_org_lwjgl_nanovg_LibNanoVG_setupMalloc')
        if actual != expected:
            raise RuntimeError(f'{module} JNI 不完整：missing={sorted(expected-actual)}, extra={sorted(actual-expected)}')
        dynamic = subprocess.check_output([str(readelf), '-d', str(candidate)], text=True)
        needed = re.findall(r'Shared library: \[([^\]]+)\]', dynamic)
        if any(name != 'libc.so' for name in needed):
            raise RuntimeError('JNI 模块出现未批准的动态依赖：' + ','.join(needed))
        records.append({'module': module, 'name': candidate.name, 'size': candidate.stat().st_size,
                        'sha256': sha(candidate), 'jniExports': len(actual), 'needed': needed,
                        'sources': [{'path': str(file.relative_to(prepared)), 'sha256': sha(file)} for file in sources]})
    receipt = {'schemaVersion': 1, 'finishedAt': datetime.datetime.now().astimezone().isoformat(),
               'sourceCommit': commit, 'compilerSha256': sha(clang), 'recipeSha256': sha(Path(__file__)),
               'artifacts': records, 'validation': '完整JNI动态导出与NEEDED核验；不等于真机渲染验证'}
    (out / 'provenance.json').write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    if args.install:
        for item in records:
            shutil.copyfile(out / item['name'], ROOT / 'entry/libs/arm64-v8a' / item['name'])
        shutil.copyfile(out / 'provenance.json', ROOT / 'prebuilt/lwjgl3/extra-jni-build-provenance.json')
    print('[lwjgl-extra-jni] 两个模块的真实 JNI 构建和配套导出核验通过', flush=True)


if __name__ == '__main__':
    main()
