#!/usr/bin/env python3
"""实际 FC 默认缓存函数的宿主文件系统/竞争回归；目标 provider 仍须独立完整构建与验收。"""
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


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--sources', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[2]
    spec = json.loads((root / 'prebuilt/fontconfig/ohos-defaults.json').read_text())
    manifest = json.loads(args.sources.read_text())
    assert manifest['kind'] == 'fontconfig-default-sources' and manifest['schemaVersion'] == 1
    assert manifest['commit'] == spec['commit'] and manifest['patchSha256'] == spec['patchSha256']
    patch = root / 'prebuilt/fontconfig/patches/0001-ohos-default-fonts-and-context-cache.patch'
    assert digest(patch.read_bytes()) == spec['patchSha256']
    prefix = '''#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/stat.h>
typedef unsigned char FcChar8;
typedef int FcBool;
#define FcTrue 1
#define FcFalse 0
#define FC_DIR_SEPARATOR_S "/"
static int _FcConfigHomeEnabled = 1;
static FcChar8 *FcConfigHome(void) { return (FcChar8 *)getenv("HOME"); }
static FcChar8 *FcStrCopy(const FcChar8 *value) { return (FcChar8 *)strdup((const char *)value); }
'''
    suffix = '''
int AmclDefaultCacheProbe(char *output, size_t capacity) {
    FcChar8 *home = FcConfigXdgCacheHome();
    if (!home) return 0;
    int n = snprintf(output, capacity, "%s", home);
    free(home);
    return n > 0 && (size_t)n < capacity;
}
'''
    sources = {}
    for variant in ('before', 'after'):
        record = manifest['files'][variant]
        path = args.sources.parent / record['file']
        assert path.parent == args.sources.parent and not path.is_symlink()
        data = path.read_bytes()
        assert len(data) == record['size'] and digest(data) == record['sha256'] == spec[variant]['src/fccfg.c']
        text = data.decode('utf-8')
        start = text.index('FcChar8 *\nFcConfigXdgCacheHome (void)')
        end = text.index('\nFcChar8 *\nFcConfigXdgConfigHome (void)', start)
        body = text[start:end]
        if variant == 'after':
            helper_start = text.rindex('#ifdef __OHOS__', 0, start)
            # 最近一个 #ifdef 就是完整 helper 区块；区块内部不嵌套平台分支。
            body = text[helper_start:start] + body
        generated = text[:text.index('*/') + 2] + '\n' + prefix + body + suffix
        source = args.output / (variant + '.c')
        source.write_text(generated, encoding='utf-8')
        sources[variant] = source
    driver = args.output / 'driver.c'
    driver.write_text('''#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <limits.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!handle) { fprintf(stderr, "%s\\n", dlerror()); return 3; }
    int (*probe)(char*,size_t) = (int(*)(char*,size_t))dlsym(handle,"AmclDefaultCacheProbe");
    if (!probe) return 4;
    char path[PATH_MAX] = {0};
    int result = probe(path,sizeof(path));
    if (result) puts(path); else puts("NONE");
    dlclose(handle);
    return 0;
}
''')
    commands = []
    def compile(command, log):
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        log.write_bytes(result.stdout)
        commands.append(command)
        assert result.returncode == 0, result.stdout.decode(errors='replace')
    binary = args.output / 'cache-driver'
    compile(['gcc', '-D_GNU_SOURCE', '-O1', '-g', '-fsanitize=address,undefined', '-no-pie', str(driver), '-ldl', '-o', str(binary)],
            args.output / 'driver-compile.log')
    libraries = {}
    for variant, source in sources.items():
        library = args.output / (variant + '.so')
        compile(['gcc', '-D__OHOS__', '-std=c11', '-O1', '-g', '-shared', '-fPIC', '-fsanitize=address,undefined',
                 '-I' + str(Path(__file__).with_name('stubs')), str(source), '-ldl', '-o', str(library)],
                args.output / (variant + '-compile.log'))
        libraries[variant] = library
    provider_dir = args.output / 'context-facade'; provider_dir.mkdir()
    provider_source = provider_dir / 'provider.c'
    provider_source.write_text('''#include <stdlib.h>
#include <string.h>
#include <AbilityKit/ability_runtime/application_context.h>
AbilityRuntime_ErrorCode OH_AbilityRuntime_ApplicationContextGetCacheDir(char *buffer,int32_t size,int32_t *written) {
    const char *path=getenv("AMCL_FC_FIXTURE_CONTEXT");
    const char *mode=getenv("AMCL_FC_FIXTURE_MODE");
    if (!path || (mode && strcmp(mode,"no-context")==0)) return ABILITY_RUNTIME_ERROR_CODE_CONTEXT_NOT_EXIST;
    size_t length=strlen(path);
    if (length+1>(size_t)size) return ABILITY_RUNTIME_ERROR_CODE_PARAM_INVALID;
    memcpy(buffer,path,length+1);*written=(int32_t)length;
    if(mode && strcmp(mode,"bad-length")==0) *written=-1;
    return ABILITY_RUNTIME_ERROR_CODE_NO_ERROR;
}
''')
    compile(['gcc', '-shared', '-fPIC', '-fsanitize=address,undefined', '-I' + str(Path(__file__).with_name('stubs')),
             str(provider_source), '-Wl,-soname,libability_runtime.so', '-o', str(provider_dir / 'libability_runtime.so')],
            args.output / 'context-facade-compile.log')
    sanitized = {key: value for key, value in os.environ.items()
                 if key not in ('HOME', 'XDG_CACHE_HOME', 'FONTCONFIG_FILE', 'FONTCONFIG_PATH', 'LD_LIBRARY_PATH')}
    sanitized.update(ASAN_OPTIONS='detect_leaks=1:abort_on_error=1', UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1')
    cases = []
    def fixture(label, classic=False, variant='after', unknown=False):
        parent = args.output / label
        runtime = parent / 'runtime'
        relative = 'jre/lib/aarch64/libfontconfig.so' if classic else 'lib/libfontconfig.so'
        if unknown:
            relative = 'plugin/font.so'
        path = runtime / relative
        path.parent.mkdir(parents=True)
        shutil.copyfile(libraries[variant], path)
        return parent, runtime, path
    def invoke(label, library, expected, environment=None):
        result = subprocess.run([str(binary), str(library)], cwd='/', env=dict(sanitized, **(environment or {})),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
        (args.output / (label + '.stdout')).write_bytes(result.stdout)
        (args.output / (label + '.stderr')).write_bytes(result.stderr)
        assert result.returncode == 0, result.stderr.decode(errors='replace')
        value = result.stdout.decode().strip()
        assert value == str(expected), (label, value, expected)
        return value
    def snapshot(runtime):
        return {p.relative_to(runtime).as_posix(): (digest(p.read_bytes()), p.stat().st_mode)
                for p in runtime.rglob('*') if p.is_file()}
    for classic in (False, True):
        label = 'classic' if classic else 'modern'
        parent, runtime, library = fixture(label, classic)
        original = snapshot(runtime)
        expected = parent / '.amcl-fontconfig-cache'
        invoke(label, library, expected)
        assert expected.stat().st_mode & 0o777 == 0o700
        file = expected / 'write-read-probe'
        with file.open('xb') as stream:
            stream.write(b'actual-cache-filesystem-write'); stream.flush(); os.fsync(stream.fileno())
        assert file.read_bytes() == b'actual-cache-filesystem-write'
        invoke(label + '-repeat', library, expected)
        assert snapshot(runtime) == original
        cases += [label + '-outside-runtime', label + '-write-read-reuse']
    parent, runtime, library = fixture('before-empty', variant='before')
    invoke('before-empty', library, '/.cache'); cases.append('upstream-empty-home-negative-control')
    parent, runtime, library = fixture('standard')
    xdg, home = parent / 'explicit-xdg', parent / 'explicit-home'
    xdg.mkdir(); home.mkdir()
    invoke('xdg-priority', library, xdg, {'XDG_CACHE_HOME': str(xdg), 'HOME': str(home)})
    invoke('home-priority', library, home / '.cache', {'HOME': str(home)})
    assert not (parent / '.amcl-fontconfig-cache').exists()
    cases += ['explicit-xdg-priority', 'standard-home-priority']
    parent, runtime, library = fixture('unusable-standard')
    bad = parent / 'read-only-home'; bad.mkdir(); bad.chmod(0o555)
    invoke('unusable-standard', library, parent / '.amcl-fontconfig-cache', {'HOME': str(bad), 'XDG_CACHE_HOME': 'relative-is-not-xdg'})
    assert bad.stat().st_mode & 0o777 == 0o555
    cases.append('unusable-standard-falls-back-without-home-mutation')
    for mode in ('available', 'no-context', 'bad-length', 'relative-path'):
        parent, runtime, library = fixture('context-' + mode)
        context = parent / 'actual-context-cache'; context.mkdir()
        expected = context if mode == 'available' else parent / '.amcl-fontconfig-cache'
        invoke('context-' + mode, library, expected, {'LD_LIBRARY_PATH': str(provider_dir),
               'AMCL_FC_FIXTURE_CONTEXT': 'relative' if mode == 'relative-path' else str(context),
               'AMCL_FC_FIXTURE_MODE': mode})
        if mode == 'available': assert not (parent / '.amcl-fontconfig-cache').exists()
        cases.append('optional-context-' + mode)
    for label in ('readonly', 'wrong-owner', 'group-writable', 'symlink', 'file', 'wrong-cache-owner', 'wrong-cache-mode', 'unknown-layout'):
        parent, runtime, library = fixture(label, unknown=label == 'unknown-layout')
        cache = parent / '.amcl-fontconfig-cache'
        if label == 'readonly': parent.chmod(0o555)
        if label == 'wrong-owner': os.chown(parent, 65534, 65534)
        if label == 'group-writable': parent.chmod(0o775)
        if label == 'symlink':
            outside = parent / 'outside'; outside.mkdir(); cache.symlink_to(outside)
        if label == 'file': cache.write_bytes(b'unknown-file-preserved')
        if label in ('wrong-cache-owner', 'wrong-cache-mode'):
            cache.mkdir(mode=0o700)
            if label == 'wrong-cache-owner': os.chown(cache, 65534, 65534)
            else: cache.chmod(0o755)
        original = snapshot(runtime)
        invoke(label, library, 'NONE')
        assert snapshot(runtime) == original
        if label == 'symlink': assert not list(outside.iterdir()) and cache.is_symlink()
        if label == 'file': assert cache.read_bytes() == b'unknown-file-preserved'
        cases.append(label + '-refused-preserved')
    parent, runtime, library = fixture('race')
    original = snapshot(runtime)
    with ThreadPoolExecutor(max_workers=8) as executor:
        list(executor.map(lambda index: invoke('race-' + str(index), library, parent / '.amcl-fontconfig-cache'), range(8)))
    assert snapshot(runtime) == original
    cases.append('eight-process-create-converges')
    report = {'schemaVersion': 1, 'finishedAt': datetime.now().astimezone().isoformat(),
              'patchSha256': spec['patchSha256'], 'sourceManifestSha256': digest(args.sources.read_bytes()),
              'cases': cases, 'compilation': commands, 'sanitizers': ['address', 'undefined', 'leak'],
              'scope': 'actual default cache functions with real host filesystem and dladdr; not target Fontconfig cache-format execution'}
    (args.output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print('PASS Fontconfig default cache:', len(cases), 'cases', flush=True)
    subprocess.run(['bash', str(Path(__file__).with_name('run-installed-defaults.sh'))], check=True)


if __name__ == '__main__':
    main()
