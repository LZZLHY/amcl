"""用本机 OHOS SDK 构建完整 LWJGL shaderc C API，源码和构建输出均在显式仓外目录。

只构建 shaderc/glslang/SPIRV-Tools 的真实库目标；不拉测试、fuzz 引擎或 CLI 依赖。
每次重用都核对锁定归档及展开后的完整源码文件，随后核对五组 required C API、
ELF 架构、SONAME、依赖和 libc++ ABI。只有显式 --install 且所有校验通过才替换正式库。
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
import urllib.request

from lib.workspace_paths import external_output_path

ROOT = Path(__file__).resolve().parents[1]
SPEC = ROOT / 'prebuilt/shaderc'


def sha(data):
    """统一用 SHA256 绑定实际文件内容；版本名不能替代字节身份。"""
    return hashlib.sha256(data).hexdigest()


def verify_binding(binding):
    """从现代槽锁定的 Git 对象提取必需函数，拒绝过期或自选缩减的导出清单。"""
    manifest = json.loads((ROOT / 'prebuilt/lwjgl3/modern-slot.manifest.json').read_text(encoding='utf-8'))
    if binding['lwjglCommit'] != manifest['sourceCommit']:
        raise RuntimeError('shaderc 绑定清单不属于现代槽锁定源码')
    if set(binding['classes']) != {'Shaderc', 'GLSLang', 'GLSLangResourceLimits', 'SPV', 'SPVOptimizer'}:
        raise RuntimeError('shaderc 绑定清单必须包含全部五组 C API')
    source = ROOT / 'prebuilt/lwjgl3/lwjgl3_src'
    symbols = set()
    for name, group in binding['classes'].items():
        relative = 'modules/lwjgl/shaderc/src/generated/java/org/lwjgl/util/shaderc/' + name + '.java'
        data = subprocess.check_output(['git', '-C', str(source), 'show', binding['lwjglCommit'] + ':' + relative])
        required = set(re.findall(r'apiGetFunctionAddress\(SHADERC, "([A-Za-z0-9_]+)"\)', data.decode('utf-8')))
        if sha(data) != group['sourceSha256'] or not required or required != set(group['required']):
            raise RuntimeError('绑定源码或必需符号集合不符：' + name)
        symbols.update(required)
    # CMake 保留表与动态导出表必须是同一个集合。否则即使最终失败，也可能浪费完整重编时间。
    listed = set((SPEC / 'required-symbols.txt').read_text(encoding='utf-8').splitlines())
    mapped = set(re.findall(r'^\s+([A-Za-z_][A-Za-z0-9_]*);\s*$',
                            (SPEC / 'exports.map').read_text(encoding='utf-8'), re.MULTILINE))
    if listed != symbols or mapped != symbols:
        raise RuntimeError('链接保留表或动态导出表与完整绑定集合不一致')


def prepare_source(name, spec, out):
    """只下载精确提交归档；缓存摘要或展开树不符时停止，绝不覆盖独有源码。"""
    archive = out / 'downloads' / (name + '.tar.gz')
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        url = f'https://codeload.github.com/{spec["repository"]}/tar.gz/{spec["commit"]}'
        print('[shaderc] 下载锁定源码 ' + url, flush=True)
        # 下载中断只留下 .part，不会把不完整归档误认成可重用输入。
        temporary = archive.with_suffix('.part')
        with urllib.request.urlopen(url, timeout=120) as response, temporary.open('wb') as target:
            shutil.copyfileobj(response, target)
        if sha(temporary.read_bytes()) != spec['archiveSha256']:
            raise RuntimeError('下载归档摘要不符：' + name)
        temporary.rename(archive)
    if sha(archive.read_bytes()) != spec['archiveSha256']:
        raise RuntimeError('缓存归档摘要不符：' + str(archive))
    destination = out / 'sources' / name
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as stream:
        members = stream.getmembers()
        prefix = members[0].name.split('/')[0]
        if not destination.exists():
            # tarfile 的 data filter 拒绝逃逸目标的成员。源归档根目录保留到解包完成后再改名。
            stream.extractall(destination.parent, filter='data')
            (destination.parent / prefix).rename(destination)
        expected = {}
        for member in members:
            if member.isfile():
                relative = Path(member.name).relative_to(prefix).as_posix()
                expected[relative] = sha(stream.extractfile(member).read())
        actual = {p.relative_to(destination).as_posix(): sha(p.read_bytes())
                  for p in destination.rglob('*') if p.is_file()}
        if actual != expected:
            raise RuntimeError('展开源码不同于锁定归档，拒绝复用或覆盖：' + str(destination))
    return destination


def run(command, log, cwd):
    """前台输出并保存同一份日志；非零退出立即阻止安装，保留失败构建供复查。"""
    print('[shaderc] ' + ' '.join(map(str, command)), flush=True)
    # SPIRV-Tools 的生成器会导入源码内 Python 模块。禁止解释器生成 __pycache__，
    # 让复用源码仍能逐文件匹配锁定归档；这不会跳过已有源码或放宽输入身份核验。
    environment = os.environ.copy()
    environment['PYTHONDONTWRITEBYTECODE'] = '1'
    # 重用构建树时日志按真实时间追加，不能因修复后重试覆盖上一次失败证据。
    with log.open('a', encoding='utf-8') as sink:
        sink.write('\n[' + datetime.datetime.now().astimezone().isoformat() + '] ' +
                   ' '.join(map(str, command)) + '\n')
        process = subprocess.Popen(list(map(str, command)), cwd=cwd, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, encoding='utf-8', errors='replace',
                                   env=environment)
        for line in process.stdout:
            print(line, end='', flush=True)
            sink.write(line)
        if process.wait():
            raise RuntimeError('命令失败，完整日志：' + str(log))


def verify(candidate, readelf, binding):
    """读取真实动态符号表；既要求完整 required 面，也拒绝意外公开内部 C++ ABI。"""
    dyn = subprocess.check_output([str(readelf), '--dyn-symbols', '--wide', str(candidate)], text=True)
    defined = {line.split()[-1].split('@')[0] for line in dyn.splitlines()
               if re.search(r'\bGLOBAL\b', line) and ' UND ' not in line and len(line.split()) >= 8}
    wanted = {symbol for cls in binding['classes'].values() for symbol in cls['required']}
    groups = {name: {'required': len(cls['required']), 'missing': sorted(set(cls['required']) - defined)}
              for name, cls in binding['classes'].items()}
    if defined != wanted:
        raise RuntimeError('动态 C API 集合不符：' + json.dumps(
            {'missing': sorted(wanted - defined), 'extra': sorted(defined - wanted)}))
    header = subprocess.check_output([str(readelf), '--file-header', str(candidate)], text=True)
    dynamic = subprocess.check_output([str(readelf), '--dynamic', str(candidate)], text=True)
    needed = re.findall(r'\(NEEDED\).*?\[([^]]+)\]', dynamic)
    if 'AArch64' not in header or 'ELF64' not in header:
        raise RuntimeError('候选不是 AArch64 ELF64')
    if 'NSt3__1' in dyn:
        raise RuntimeError('候选泄漏非 OHOS libc++ __1 ABI')
    if not re.search(r'\(SONAME\).*?\[libshaderc.so\]', dynamic):
        raise RuntimeError('SONAME 必须为 libshaderc.so')
    if not needed or set(needed) - {'libc.so', 'libc++_shared.so', 'libm.so', 'libdl.so'}:
        raise RuntimeError('发现未批准的动态依赖：' + repr(needed))
    return {'groups': groups, 'exports': sorted(defined), 'needed': needed,
            'ohosLibcxxSymbols': dyn.count('NSt4__n1')}


def main():
    """组织来源准备、完整 CMake 构建、产物校验及可选安装，不自动修改消费者锁文件。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True)
    parser.add_argument('--sdk', required=True, help='包含 native/ 的 OpenHarmony SDK 根目录')
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--install', action='store_true')
    args = parser.parse_args()
    out = external_output_path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    sdk = Path(args.sdk).resolve()
    native = sdk / 'native'
    exe = '.exe' if os.name == 'nt' else ''
    cmake = native / 'build-tools/cmake/bin' / ('cmake' + exe)
    ninja = cmake.with_name('ninja' + exe)
    clang = native / 'llvm/bin' / ('clang++' + exe)
    readelf = clang.with_name('llvm-readelf' + exe)
    strip = clang.with_name('llvm-strip' + exe)
    inputs = json.loads((SPEC / 'build-inputs.json').read_text(encoding='utf-8'))
    binding = json.loads((SPEC / 'required-symbols.json').read_text(encoding='utf-8'))
    verify_binding(binding)
    sources = {name: prepare_source(name, value, out) for name, value in inputs['sources'].items()}
    # shaderc 的 DEPS 是三个真实依赖提交的上游事实源，独立锁不能悄悄改成不配套版本。
    deps = (sources['shaderc'] / 'DEPS').read_text(encoding='utf-8')
    for name in ('glslang', 'spirv-tools', 'spirv-headers'):
        if inputs['sources'][name]['commit'] not in deps:
            raise RuntimeError('依赖提交与 shaderc DEPS 不匹配：' + name)
    flags = '-D_LIBCPP_HAS_MUSL_LIBC -D_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE'
    command = [cmake, '-S', SPEC, '-B', out / 'build', '-G', 'Ninja',
               '-DCMAKE_MAKE_PROGRAM=' + ninja.as_posix(),
               '-DCMAKE_TOOLCHAIN_FILE=' + (native / 'build/cmake/ohos.toolchain.cmake').as_posix(),
               '-DOHOS_ARCH=arm64-v8a', '-DOHOS_STL=c++_shared', '-DCMAKE_BUILD_TYPE=Release',
               '-DAMCL_SHADERC_SOURCE=' + sources['shaderc'].as_posix(),
               '-DSHADERC_GLSLANG_DIR=' + sources['glslang'].as_posix(),
               '-DSHADERC_SPIRV_TOOLS_DIR=' + sources['spirv-tools'].as_posix(),
               '-DSHADERC_SPIRV_HEADERS_DIR=' + sources['spirv-headers'].as_posix(),
               '-DCMAKE_CXX_FLAGS=' + flags, '-DCMAKE_C_FLAGS=' + flags]
    run(command, out / 'configure.log', ROOT)
    run([cmake, '--build', out / 'build', '--target', 'shaderc_shared', '--parallel', str(args.jobs)],
        out / 'build.log', ROOT)
    built = out / 'build/shaderc/libshaderc/libshaderc.so'
    candidate = out / 'libshaderc.so'
    shutil.copyfile(built, candidate)
    run([strip, '--strip-unneeded', candidate], out / 'strip.log', ROOT)
    checked = verify(candidate, readelf, binding)
    receipt = {'schemaVersion': 1, 'finishedAt': datetime.datetime.now().astimezone().isoformat(),
               'sourceInputs': inputs, 'lwjglCommit': binding['lwjglCommit'],
               'compiler': subprocess.check_output([str(clang), '--version'], text=True).splitlines()[0],
               'compilerSha256': sha(clang.read_bytes()),
               'recipeHashes': {str(p.relative_to(ROOT)).replace('\\', '/'): sha(p.read_bytes())
                                for p in [Path(__file__), *sorted(SPEC.glob('*'))] if p.is_file()
                                and p.name != 'build-provenance.json'},
               'size': candidate.stat().st_size, 'sha256': sha(candidate.read_bytes()),
               'validation': checked, 'installed': args.install,
               'scope': 'OHOS native build and complete C ABI; device shader execution is separately validated'}
    text = json.dumps(receipt, ensure_ascii=False, indent=2) + '\n'
    (out / 'build-provenance.json').write_text(text, encoding='utf-8')
    if args.install:
        shutil.copyfile(candidate, ROOT / 'entry/libs/arm64-v8a/libshaderc.so')
        (SPEC / 'build-provenance.json').write_text(text, encoding='utf-8')
    print('[shaderc] PASS ' + json.dumps({'size': receipt['size'], 'sha256': receipt['sha256'],
                                        'groups': checked['groups']}, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
