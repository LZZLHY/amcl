#!/usr/bin/env python3
"""在固定 QA 内编译三代真实补前/补后 FreeType 并执行字体行为测试。

输入是 prepare-freetype-inputs.py 产生的只读闭包，不访问网络，不复制系统字体。
原 JDK 的配置头原样编译，所有 *.c 与 JDK 的 bundled FreeType 文件发现方式一致。
宿主 sanitizer 检查只能授予这套行为资格，不代表 OHOS JDK 整包已经通过。
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shlex
import subprocess
import sys
import tarfile


def sha(data):
    """文件和 manifest 使用字节摘要，防止只凭路径认领输入。"""
    return hashlib.sha256(data).hexdigest()


def run_logged(command, log, *, expected=0, env=None):
    """专用退出码也必须由调用者明确声明，任何其他失败都不能算负控成功。"""
    result = subprocess.run([str(item) for item in command], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, env=env)
    log.write_bytes((shlex.join([str(item) for item in command]) + '\n').encode() + result.stdout)
    if result.returncode != expected:
        sys.stdout.buffer.write(result.stdout)
        raise RuntimeError(f'Expected exit {expected}, got {result.returncode}: {log}')
    return result.stdout


def extract_checked(root, item, destination):
    """摘要和每个条目先核对再写；只收普通文件，拒绝额外、重复和越界成员。"""
    archive_path = root / item['file']
    if Path(item['file']).name != item['file'] or sha(archive_path.read_bytes()) != item['sha256']:
        raise ValueError('Unexpected source archive identity')
    destination.mkdir(parents=True, exist_ok=False)
    seen = set()
    with tarfile.open(archive_path) as archive:
        for entry in archive:
            name = PurePosixPath(entry.name)
            if not entry.isfile() or name.is_absolute() or '..' in name.parts or entry.name in seen:
                raise ValueError('Source archive is not a plain, unique relative tree')
            if entry.name not in item['files']:
                raise ValueError('Unexpected extra source entry')
            content = archive.extractfile(entry).read()
            expected = item['files'][entry.name]
            if len(content) != expected['size'] or sha(content) != expected['sha256']:
                raise ValueError('Source entry identity mismatch: ' + entry.name)
            target = destination / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
            seen.add(entry.name)
    if seen != set(item['files']):
        raise ValueError('Source archive missing declared entries')


def build_variant(source, output, jobs):
    """逐编译单元并行，所有对象和日志外置；未改任何 JDK 字体能力宏。"""
    objects = output / 'objects'
    objects.mkdir()
    flags = ['-O1', '-g', '-fPIC', '-DFT2_BUILD_LIBRARY', '-fno-omit-frame-pointer',
             '-fsanitize=address,undefined', '-I' + str(source / 'include')]
    files = sorted((source / 'src').rglob('*.c'))
    if len(files) < 100:
        raise ValueError('Incomplete bundled FreeType source tree')
    def compile_file(path):
        relative = path.relative_to(source).as_posix().replace('/', '_')
        target = objects / (relative + '.o')
        run_logged(['gcc', *flags, '-c', path, '-o', target], objects / (relative + '.log'))
        return target
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        built = list(pool.map(compile_file, files))
    library = output / 'libfreetype-test.so'
    run_logged(['gcc', '-shared', '-fsanitize=address,undefined', '-Wl,-z,defs',
                '-Wl,-soname,libfreetype-test.so', '-o', library, *built, '-lm'], output / 'link.log')
    return library, len(files)


def main():
    """每代独立进程加载补前/补后库；ASan/UBSan/LSan 任一发现立即失败。"""
    parser = argparse.ArgumentParser()
    parser.add_argument('--sources', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    if not 1 <= args.jobs <= 16:
        raise ValueError('jobs must be between 1 and 16')
    root = Path(__file__).resolve().parents[2]
    sources = json.loads(args.sources.read_text())
    if sources['schemaVersion'] != 1 or set(sources['runtimes']) != {'17', '21', '25'}:
        raise ValueError('Expected all three version-matched JDK source pairs')
    args.output.mkdir(parents=True, exist_ok=True)
    fixture_dir = args.output / 'fixtures'
    run_logged([sys.executable, '-B', root / 'tests/runtime-fontconfig/make-fixtures.py', fixture_dir],
               args.output / 'fixtures.log')
    spec = json.loads((root / 'prebuilt/fontconfig/freetype-completion.json').read_text())
    report = {'schemaVersion': 1, 'startedAt': datetime.now().astimezone().isoformat(),
              'inputManifestSha256': sha(args.sources.read_bytes()), 'targetExecutionQualified': False,
              'sanitizers': ['address', 'undefined', 'leak'], 'runtimes': {}}
    sanitizer_env = dict(os.environ, ASAN_OPTIONS='detect_leaks=1:abort_on_error=1',
                         UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1')
    for major, item in sorted(sources['runtimes'].items()):
        if (item['jdkCommit'], item['freeTypeVersion'], item['freeTypeImportCommit']) != (
                spec['runtimes'][major]['jdkCommit'], spec['runtimes'][major]['version'],
                spec['runtimes'][major]['commit']):
            raise ValueError('Version-matched source closure changed')
        patch_dir = root / 'prebuilt/jdk' / major / 'patches'
        if sha((patch_dir / 'series').read_bytes()) != item['seriesSha256']:
            raise ValueError('Series changed after source export')
        for name, digest in item['patches'].items():
            if Path(name).name != name or sha((patch_dir / name).read_bytes()) != digest:
                raise ValueError('Patch changed after source export')
        for license_item in item['licenses'].values():
            if sha((root / license_item['path']).read_bytes()) != license_item['sha256']:
                raise ValueError('License changed after source export')
        records = {}
        for variant in ('before', 'after'):
            output = args.output / ('jdk' + major + '-' + variant)
            output.mkdir()
            source = output / 'source'
            extract_checked(args.sources.parent, item[variant], source)
            print(f'Building actual JDK {major} bundled FreeType {item["freeTypeVersion"]} ({variant})', flush=True)
            library, count = build_variant(source, output, args.jobs)
            driver = output / 'behavior'
            run_logged(['gcc', '-O1', '-g', '-Wall', '-Wextra', '-Werror', '-fno-omit-frame-pointer',
                        '-fsanitize=address,undefined', '-I' + str(source / 'include'),
                        root / 'tests/runtime-fontconfig/freetype_behavior.c', '-ldl', '-o', driver], output / 'driver-build.log')
            # 77 只有在原库有效、TrueType 正常、BDF 导出和两个位图驱动确实缺席
            # 的全部断言通过后才出现；超时、崩溃或 sanitizer 错误一律不是负控成功。
            text = run_logged(['timeout', '30', driver, library, fixture_dir, item['freeTypeVersion'], variant],
                              output / 'behavior.log', expected=77 if variant == 'before' else 0, env=sanitizer_env)
            if variant == 'before' and b'REPRO: valid original FreeType' not in text:
                raise ValueError('Negative control did not reproduce the known missing service')
            print(text.decode(), end='', flush=True)
            records[variant] = {'librarySha256': sha(library.read_bytes()), 'compiledSources': count,
                                'behaviorLogSha256': sha((output / 'behavior.log').read_bytes()),
                                'expectedExit': 77 if variant == 'before' else 0, 'passed': True}
        report['runtimes'][major] = records
    report['finishedAt'], report['passed'] = datetime.now().astimezone().isoformat(), True
    (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print('PASS all three complete-series FreeType behavior and original-library negative controls', flush=True)


if __name__ == '__main__':
    main()
