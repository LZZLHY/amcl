"""从锁定源码构建标准与DH两个独立OHOS zstd-JNI，输出必须仓外且不覆盖旧候选。

两种Java包各有独立JNI静态字段缓存，不能在同一个DSO中通过导出别名混用。第三方C实现
只做已声明包名重定位；不改压缩语义、删除glibc版本字串或以空实现补必需符号。
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
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
SPEC = ROOT / 'prebuilt/mod-natives/zstd-jni'


def digest(path):
    """流式冻结输入/产物；版本号不代替真实字节身份。"""
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    """检查输入、构建、审核真实ELF后才产出锁候选；安装由调用方单独执行。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--sdk', type=Path, required=True, help='OpenHarmony native SDK目录')
    parser.add_argument('--output', required=True)
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    if not 1 <= args.jobs <= 16:
        raise ValueError('jobs应为1..16')
    out = external_output_path(args.output)
    out.mkdir(parents=True, exist_ok=False)
    input_bytes = (SPEC / 'build-inputs.json').read_bytes()
    input_sha256 = hashlib.sha256(input_bytes).hexdigest()
    spec = json.loads(input_bytes)
    if digest(args.archive) != spec['source']['sha256']:
        raise ValueError('上游源码归档摘要不匹配')
    for item in spec['jniHeaders']:
        if digest(ROOT / item['path']) != item['sha256']:
            raise ValueError('目标JNI头身份不匹配')
    prefix = 'zstd-jni-' + spec['source']['commit'] + '/src/main/native/'
    with tarfile.open(args.archive) as archive:
        members = [m for m in archive.getmembers() if m.name.startswith(prefix)]
        if not members or any(m.issym() or m.islnk() for m in members):
            raise ValueError('Native源码缺失或含未核链接')
        archive.extractall(out / 'source', members=members, filter='data')
    native = out / 'source' / prefix
    suffix = '.exe' if os.name == 'nt' else ''
    tools = {name: args.sdk / 'llvm/bin' / (name + suffix) for name in ['clang', 'llvm-strip', 'llvm-readelf']}
    jni = ROOT / Path(spec['jniHeaders'][0]['path']).parent
    common = ['--target=aarch64-linux-ohos', '--sysroot=' + str(args.sdk / 'sysroot'),
              '-std=c99', '-O2', '-fPIC', '-fvisibility=hidden', '-DZSTD_LEGACY_SUPPORT=4',
              '-DZSTD_MULTITHREAD=1', '-DZSTD_DISABLE_ASM=1', '-D_GNU_SOURCE', '-DNDEBUG',
              '-I' + str(native), '-I' + str(native / 'common'), '-I' + str(jni), '-I' + str(jni / 'linux')]
    # 只影响本轮编译子进程的临时目录，不能修改用户全局TEMP/TMP。
    temp = out / 'temp'; temp.mkdir()
    symbols_directory = out / 'symbols'; symbols_directory.mkdir()
    environment = dict(os.environ, TEMP=str(temp), TMP=str(temp))
    commands = []

    def run(command, label):
        """真实编译前台等待；每一步日志独占，失败保留原始输出和输入。"""
        p = subprocess.run(list(map(str, command)), env=environment, capture_output=True)
        (out / (label + '.log')).write_bytes(p.stdout + p.stderr)
        commands.append({'label': label, 'command': list(map(str, command)), 'exitCode': p.returncode})
        if p.returncode:
            raise RuntimeError(label + ': ' + (p.stdout + p.stderr).decode('utf-8', 'replace')[-5000:])
        print('[zstd-jni] ' + label, flush=True)

    def compile_file(item):
        """每个对象拥有唯一输出，基础Zstd对象只编一次，JNI按包分别编译。"""
        source, target, label = item
        # SDK没有qsort_r。仅cover.c消费本地有上下文适配，其余第三方文件不改系统符号。
        extra = ['-Dqsort_r=AmclZstdQsortR', '-include', SPEC / 'qsort_context.h'] if source.name == 'cover.c' else []
        if source.name == 'qsort_context.c':
            extra = ['-std=c11']
        run([tools['clang'], *common, *extra, '-c', source, '-o', target], label)
        return target

    record = {'schemaVersion': 1, 'startedAt': datetime.now().astimezone().isoformat(),
              'inputContractSha256': input_sha256,
              'source': spec['source'], 'recipeSha256': digest(Path(__file__)),
              'compilerSha256': digest(tools['clang']), 'jniHeaders': spec['jniHeaders'],
              'adapterSources': {name: digest(SPEC / name) for name in ['qsort_context.c', 'qsort_context.h']},
              'preparedJniSources': [],
              'commands': commands, 'artifacts': [], 'state': 'building', 'deviceQualified': False}
    try:
        core = sorted(p for p in native.rglob('*.c') if not p.name.startswith('jni_'))
        core.append(SPEC / 'qsort_context.c')
        object_root = out / 'objects'; object_root.mkdir()
        tasks = [(p, object_root / ('core-' + str(i) + '.o'), 'core-' + str(i)) for i, p in enumerate(core)]
        with ThreadPoolExecutor(max_workers=args.jobs) as pool:
            base_objects = list(pool.map(compile_file, tasks))
        for variant in spec['variants']:
            directory = out / variant['id']; directory.mkdir()
            tasks = []
            for i, original in enumerate(sorted(native.glob('jni_*.c'))):
                text = original.read_text(encoding='utf-8')
                if variant['jniPrefix'] != 'Java_com_github_luben_zstd':
                    # 重定位同时覆盖JNI符号与潜在类路径字串；所有其它C代码逐字保留。
                    text = text.replace('com_github_luben_zstd', 'dhcomgithubluben_zstd')
                    text = text.replace('com/github/luben/zstd', 'dhcomgithubluben/zstd')
                prepared = directory / original.name; prepared.write_text(text, encoding='utf-8', newline='\n')
                record['preparedJniSources'].append({'variant': variant['id'], 'file': original.name,
                                                    'originalSha256': digest(original), 'compiledSha256': digest(prepared)})
                tasks.append((prepared, directory / (original.stem + '.o'), variant['id'] + '-jni-' + str(i)))
            with ThreadPoolExecutor(max_workers=args.jobs) as pool:
                jni_objects = list(pool.map(compile_file, tasks))
            exports = directory / 'exports.map'
            exports.write_text('LOCAL_ZSTD { global: ' + variant['jniPrefix'] + '*; local: *; };\n', encoding='ascii')
            library = out / variant['filename']
            run([tools['clang'], *common, '-shared', '-Wl,--no-undefined', '-Wl,-z,noexecstack',
                 '-Wl,-soname,' + variant['filename'], '-Wl,--version-script=' + str(exports),
                 *base_objects, *jni_objects, '-o', library], variant['id'] + '-link')
            # quick/full的应用ABI门需要未剥离来源以排除隐藏的第二展开器，不能只看动态导出。
            unstripped = symbols_directory / library.name
            shutil.copyfile(library, unstripped)
            run([tools['llvm-strip'], '--strip-all', library], variant['id'] + '-strip')
            symbols = subprocess.check_output([str(tools['llvm-readelf']), '--dyn-symbols', '--wide', str(library)], text=True)
            actual = sorted({p[7].split('@')[0] for line in symbols.splitlines()
                             if len(p := line.split()) >= 8 and p[6] != 'UND' and p[7].startswith('Java_')})
            dynamic = subprocess.check_output([str(tools['llvm-readelf']), '-d', str(library)], text=True)
            needed = re.findall(r'Shared library: \[([^\]]+)\]', dynamic)
            data = library.read_bytes()
            if actual != variant['jniExports'] or needed != ['libc.so'] or data[:6] != b'\x7fELF\x02\x01' or int.from_bytes(data[18:20], 'little') != 183:
                raise ValueError('目标JNI/NEEDED/架构合同不匹配：' + variant['id'])
            if 'GLIBC_' in symbols:
                raise ValueError('OHOS产物意外保留glibc符号版本')
            (directory / 'symbols.txt').write_text(symbols, encoding='utf-8')
            (directory / 'dynamic.txt').write_text(dynamic, encoding='utf-8')
            record['artifacts'].append({'id': variant['id'], 'filename': library.name, 'sha256': digest(library),
                                        'size': len(data), 'needed': needed, 'jniExports': actual,
                                        'unstripped': {'path': 'symbols/' + library.name, 'sha256': digest(unstripped),
                                                       'size': unstripped.stat().st_size}})
        if (SPEC / 'build-inputs.json').read_bytes() != input_bytes:
            raise RuntimeError('构建期间输入合同发生变化，保留候选但不授予字节资格')
        record['state'] = 'passed-artifact-only'
    finally:
        record['finishedAt'] = datetime.now().astimezone().isoformat()
        (out / 'receipt.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print('[zstd-jni] target artifacts verified; device and Java compatibility require independent qualification', flush=True)


if __name__ == '__main__':
    main()
