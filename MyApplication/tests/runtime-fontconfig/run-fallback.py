#!/usr/bin/env python3
"""固定 QA：真实 Fontconfig 字符集配合四代原/补后筛选代码，验证覆盖及 owned union 生命周期。"""
import argparse
import ctypes
import ctypes.util
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


def run(command, log, **kwargs):
    """保存原始输出，非零退出一律失败；原缺陷由驱动明确断言，不把任意崩溃算负控。"""
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, **kwargs)
    log.write_bytes(result.stdout)
    if result.returncode:
        raise RuntimeError(str(log) + '\n' + result.stdout.decode('utf-8', errors='replace'))
    return result.stdout.decode('utf-8')


def fragments(source):
    """截取实际源码的阈值、字符并集合并与正常释放段；不得重写比较表达式代替测试。"""
    begin = source.index('        fontCount = 0;') + len('        fontCount = 0;')
    end = source.index('        for (j=0; j<nfonts; j++)', begin)
    initial = source[begin:end]
    initial = initial.replace('        FcCharSet *unionCharset = NULL;', '').replace('        FcCharSet *prevUnionCharset = NULL;', '')
    begin = source.index('            /* We don\'t want 20 or 30 fonts', end)
    end = source.index('            fontCount++;', begin)
    selection = source[begin:end]
    end_loop = source.index("        /* Once we get here 'fontCount'", end)
    cleanup = source[source.rfind('\n        }', end, end_loop) + len('\n        }'):end_loop]
    # 最后一段 cleanup 需独立取其完整 if；上面的循环右括号不能误吞掉 owned union 释放。
    match = re.search(r'        (?:/\* 最后一个 owned union.*?\*/|// Release last instance of CharSet union)\s*'
                      r'if \(prevUnionCharset != NULL\) \{\s*\(\*FcCharSetDestroy\)\(prevUnionCharset\);\s*\}',
                      source[end:end_loop], re.S)
    cleanup = match.group(0) if match else ''
    return initial, selection, cleanup


def alias_test(root, output):
    """由真实 Fontconfig 解析模板展开正文；核 JDK 的 sans 与其它 generic 及样式保持。"""
    library = ctypes.CDLL(ctypes.util.find_library('fontconfig') or 'libfontconfig.so.1')
    signatures = {'FcGetVersion': (ctypes.c_int, []), 'FcConfigCreate': (ctypes.c_void_p, []),
        'FcConfigParseAndLoadFromMemory': (ctypes.c_int, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]),
        'FcNameParse': (ctypes.c_void_p, [ctypes.c_char_p]),
        'FcConfigSubstitute': (ctypes.c_int, [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int]),
        'FcPatternGetString': (ctypes.c_int, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.POINTER(ctypes.c_char_p)]),
        'FcPatternGetInteger': (ctypes.c_int, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.POINTER(ctypes.c_int)]),
        'FcPatternDestroy': (None, [ctypes.c_void_p]), 'FcConfigDestroy': (None, [ctypes.c_void_p])}
    for name, (returns, args) in signatures.items():
        getattr(library, name).restype, getattr(library, name).argtypes = returns, args
    # 使用已登记工具链镜像自带的宿主 provider。记录实际映射/SHA/版本，不能将此
    # 语义回归说成目标 2.17.1 ELF 已执行，目标仍由真实 JDK 资格通道单独验收。
    mapped = sorted({line.split()[-1] for line in Path('/proc/self/maps').read_text().splitlines()
                     if '/libfontconfig.so' in line})
    provider = [{'path': name, 'sha256': hashlib.sha256(Path(name).read_bytes()).hexdigest()} for name in mapped]
    assert provider
    data = (root / 'entry/src/main/resources/rawfile/fonts.conf').read_bytes()
    assert data.count(b'@AMCL_FONT_CACHE_DIR@') == 1
    expanded = data.replace(b'@AMCL_FONT_CACHE_DIR@', str(output / 'cache').encode())
    (output / 'expanded-fonts.conf').write_bytes(expanded)
    config = library.FcConfigCreate()
    try:
        assert config and library.FcConfigParseAndLoadFromMemory(config, expanded, 1)
        reports = {}
        for family, first in [('sans', 'HarmonyOS Sans'), ('sans-serif', 'HarmonyOS Sans'),
                              ('serif', 'Noto Serif'), ('monospace', 'Noto Sans Mono')]:
            pattern = library.FcNameParse((family + ':weight=200:slant=100').encode())
            assert pattern
            try:
                assert library.FcConfigSubstitute(config, pattern, 0)
                values = []
                for index in range(32):
                    value = ctypes.c_char_p()
                    if library.FcPatternGetString(pattern, b'family', index, ctypes.byref(value)) != 0:
                        break
                    values.append(value.value.decode('utf-8'))
                assert values[0] == first, (family, values)
                assert family in values and not any('FTToken' in value for value in values), values
                for name, expected in [(b'weight', 200), (b'slant', 100)]:
                    number = ctypes.c_int()
                    assert library.FcPatternGetInteger(pattern, name, 0, ctypes.byref(number)) == 0
                    assert number.value == expected, (name, number.value)
                reports[family] = values
            finally:
                library.FcPatternDestroy(pattern)
        return {'hostFontconfigVersion': library.FcGetVersion(), 'hostProvider': provider,
                'templateSha256': hashlib.sha256(data).hexdigest(), 'families': reports, 'stylesPreserved': True}
    finally:
        library.FcConfigDestroy(config)


def syntax_check(source, output):
    """用工具链镜像的真实 JNI/Fontconfig 头编译完整修改函数，防止片段遗漏上下文错误。"""
    found = re.search(r'Java_sun_font_FontConfigManager_getFontConfig\s*\(', source)
    assert found
    start = source.rfind('JNIEXPORT void JNICALL', 0, found.start())
    opening = source.index('{', found.end())
    depth = 0
    for end in range(opening, len(source)):
        depth += (source[end] == '{') - (source[end] == '}')
        if depth == 0:
            break
    typedefs = '\n'.join(value for value in re.findall(r'typedef\s+[^;]+;', source)
                         if 'FuncType' in value and 'Fc' in value)
    headers = list(Path('/opt').glob('**/include/jni.h')) + list(Path('/usr/lib/jvm').glob('*/include/jni.h'))
    assert headers, 'toolchain image has no host JNI headers'
    header = headers[0].parent
    code = '''#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <dlfcn.h>
#include <jni.h>
#include <fontconfig/fontconfig.h>
#define CHECK_NULL(x) do { if ((x)==NULL) return; } while(0)
#define IS_NULL(x) ((x)==NULL)
#define JNU_CHECK_EXCEPTION(env) do { if ((*(env))->ExceptionCheck(env)) return; } while(0)
extern void *openFontConfig(void);
extern void closeFontConfig(void *, jboolean);
extern void JNU_ThrowOutOfMemoryError(JNIEnv *, const char *);
''' + typedefs + '\n' + source[start:end + 1] + '\n'
    path = output / 'full-function.c'
    path.write_text(code, encoding='utf-8')
    run(['gcc', '-std=c11', '-D__OHOS__', '-fsyntax-only', '-I' + str(header), '-I' + str(header / 'linux'), str(path)],
        output / 'full-function-syntax.log')


def main():
    """只读源码输入，所有 C/ELF/日志均外置；sanitizer 失败不得标记为成功。"""
    parser = argparse.ArgumentParser()
    parser.add_argument('--sources', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    args.output.mkdir(parents=True, exist_ok=False)
    manifest = json.loads(args.sources.read_text())
    assert manifest['kind'] == 'fontconfig-fallback-sources' and set(manifest['runtimes']) == {'8', '17', '21', '25'}
    spec = json.loads(Path(__file__).with_name('fallback-cases.json').read_text())['runtimes']
    report = {'startedAt': datetime.now().astimezone().isoformat(), 'targetJdkQualified': False,
              'sourcesSha256': hashlib.sha256(args.sources.read_bytes()).hexdigest(), 'runtimes': {}}
    template = Path(__file__).with_name('fallback-driver.c.in').read_text()
    for major, entry in manifest['runtimes'].items():
        assert entry['commit'] == spec[major]['commit'] and entry['patchSha256'] == spec[major]['patchSha256']
        assert hashlib.sha256((root / 'prebuilt/jdk' / major / 'patches/0018-fontconfig-preserve-fallback-coverage.patch').read_bytes()).hexdigest() == entry['patchSha256']
        report['runtimes'][major] = {}
        for variant, ohos in [('before', True), ('after', True), ('after', False)]:
            item = entry['files']['native'][variant]
            assert Path(item['file']).name == item['file']
            data = (args.sources.parent / item['file']).read_bytes()
            assert hashlib.sha256(data).hexdigest() == item['sha256'] and len(data) == item['size']
            source_path = entry['files']['native']['sourcePath']
            assert item['sha256'] == spec[major]['files' if variant == 'before' else 'patchedFiles'][source_path]
            initial, selection, cleanup = fragments(data.decode('utf-8'))
            # 原函数返回 void；测试用 0 记录其错误返回，清理分支其它语句保持实际源正文。
            selection = selection.replace('return;', 'return 0;')
            code = template.replace('@INITIAL@', initial).replace('@SELECTION@', selection).replace('@CLEANUP@', cleanup)
            destination = args.output / (major + '-' + variant + ('-ohos' if ohos else '-linux'))
            destination.mkdir()
            if variant == 'after' and ohos:
                syntax_check(data.decode('utf-8'), destination)
            source = destination / 'fallback.c'
            source.write_text(code, encoding='utf-8')
            binary = destination / 'fallback'
            run(['gcc', '-std=c11', '-O1', '-g', '-fno-omit-frame-pointer', '-fsanitize=address,undefined',
                 *(['-D__OHOS__'] if ohos else []), str(source), '-ldl', '-o', str(binary)], destination / 'build.log')
            result = run([str(binary), str(int(variant == 'after' and ohos)), str(int(major == '8' and variant == 'before')),
                          str(int(variant == 'after')), str(int(major == '8' and variant == 'after'))],
                         destination / 'behavior.log', env=dict(os.environ, ASAN_OPTIONS='detect_leaks=1:abort_on_error=1',
                             UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1'))
            print(major, variant, 'OHOS' if ohos else 'Linux', result.strip(), flush=True)
            report['runtimes'][major][destination.name] = {'sourceSha256': item['sha256'], 'passed': True}
    report['config'] = alias_test(root, args.output)
    report['completedAt'] = datetime.now().astimezone().isoformat()
    (args.output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print('PASS real Fontconfig alias parsing: sans/sans-serif/serif/monospace, requested weight/slant preserved')


if __name__ == '__main__':
    main()
