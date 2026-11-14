#!/usr/bin/env python3
"""用真实 HotSpot/CheckJNI 执行锁定 FreeType 文件读桥，验证原错误及修复边界。"""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shlex
import shutil
import subprocess


def digest(data):
    return hashlib.sha256(data).hexdigest()


def function(source, signature):
    """保留真实函数正文；禁止另写一个与实现相似的测试算法。"""
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 0
    for end in range(opening, len(source)):
        depth += (source[end] == '{') - (source[end] == '}')
        if depth == 0:
            return source[start:end + 1]
    raise ValueError('unclosed function: ' + signature)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--sources', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    args.output.mkdir(parents=True, exist_ok=False)
    spec = json.loads(Path(__file__).with_name('stream-cases.json').read_text())['runtimes']
    manifest = json.loads(args.sources.read_text())
    assert manifest['schemaVersion'] == 2 and manifest['kind'] == 'fontconfig-fallback-sources'
    template = Path(__file__).with_name('stream-jni.c.in').read_text(encoding='utf-8')
    candidates = [Path('/opt/bootjdk-17/bin/javac'), *Path('/opt').glob('**/bin/javac')]
    fallback = shutil.which('javac')
    if fallback:
        candidates.append(Path(fallback))
    javac = next(path.resolve() for path in candidates if path.is_file())
    java = javac.with_name('java')
    include = javac.parent.parent / 'include'
    environment = dict(os.environ, UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1')
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))

    def run(command, log):
        result = subprocess.run([str(item) for item in command], stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, env=environment, timeout=60)
        log.write_bytes(result.stdout)
        if result.returncode:
            raise RuntimeError(str(command) + '\n' + result.stdout.decode('utf-8', errors='replace'))
        return result.stdout.decode('utf-8', errors='replace')

    classes = args.output / 'classes'
    classes.mkdir()
    run([javac, '--release', '8', '-encoding', 'UTF-8', '-d', classes,
         Path(__file__).with_name('FontStreamProbe.java')], args.output / 'javac.log')
    version = run([java, '-version'], args.output / 'java-version.log')
    cflags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', 'freetype2'], text=True))
    results = []
    for major, expected in spec.items():
        item = manifest['runtimes'][major]
        assert item['commit'] == expected['commit'] and item['streamPatchSha256'] == expected['patchSha256']
        patch = root / 'prebuilt/jdk' / major / 'patches/0022-freetype-stream-jni-and-cache-boundary.patch'
        assert digest(patch.read_bytes()) == expected['patchSha256']
        record = item['files']['stream']
        assert record['sourcePath'] == expected['path']
        for variant in ('before', 'after'):
            entry = record[variant]
            source_path = args.sources.parent / entry['file']
            assert source_path.parent == args.sources.parent and not source_path.is_symlink()
            data = source_path.read_bytes()
            assert len(data) == entry['size'] and digest(data) == entry['sha256'] == expected[variant + 'Sha256']
            source = data.decode('utf-8')
            structure = re.search(r'typedef struct \{[\s\S]*?\} FTScalerInfo;', source).group()
            cache = re.search(r'^#define FILEDATACACHESIZE[^\n]+', source, re.M).group()
            macro = ''
            if '#define CHECK_EXCEPTION' in source:
                start = source.index('#define CHECK_EXCEPTION')
                macro = source[start:source.index('\n\n', start)]
            helper = function(source, 'static jboolean checkReadException(') if variant == 'after' else ''
            callback = function(source, 'static unsigned long ReadTTFontFileFunc(')
            generated = template
            for name, value in {'SCALER_STRUCT': structure, 'CACHE_DEFINE': cache,
                                'ORIGINAL_MACRO': macro, 'READ_HELPER': helper,
                                'READ_CALLBACK': callback,
                                'INVALIDATE': function(source, 'static void invalidateJavaScaler(')}.items():
                generated = generated.replace('@' + name + '@', value)
            generated = source[:source.index('*/') + 2] + '\n' + generated
            prefix = major + '-' + variant
            cfile = args.output / (prefix + '.c')
            library = args.output / (prefix + '.so')
            cfile.write_text(generated, encoding='utf-8')
            run(['gcc', '-std=c11', '-O1', '-g', '-fPIC', '-shared', '-fsanitize=undefined',
                 '-I' + str(include), '-I' + str(include / 'linux'), *cflags, cfile, '-o', library],
                args.output / (prefix + '-compile.log'))
            output = run([java, '-Xcheck:jni', '-Xmx64m', '-cp', classes, 'FontStreamProbe',
                          library.resolve(), str(variant == 'after').lower(), major],
                         args.output / (prefix + '-run.log'))
            count = 13 if variant == 'after' else 9
            label = 'repaired' if variant == 'after' else 'original-negative-control'
            assert 'PASS real JNI font stream ' + label + ' major=' + major + ' cases=' + str(count) in output
            warning = 'without checking exceptions' in output or 'JNI call made with exception pending' in output
            if variant == 'after':
                assert not warning, output
            elif major in ('8', '17'):
                assert warning, '原漏检未触发真实 CheckJNI 负控'
            results.append({'major': major, 'variant': variant, 'cases': count,
                            'sourceSha256': digest(data), 'generatedSha256': digest(cfile.read_bytes()),
                            'librarySha256': digest(library.read_bytes()), 'checkJniWarning': warning, 'status': 'PASS'})
            print('PASS stream', major, variant, count, flush=True)
    report = {'schemaVersion': 1, 'createdAt': datetime.now().astimezone().isoformat(),
              'java': str(java), 'version': version, 'sanitizers': ['undefined'],
              'actualJni': True, 'scope': 'actual stream callback and FTScalerInfo, not complete target library',
              'sourceManifestSha256': digest(args.sources.read_bytes()), 'results': results}
    (args.output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
