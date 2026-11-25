"""机械抽取生产装配和 JNI 属性函数，在独立宿主 JVM 中执行正反例。

--java-home 可指定任一宿主 JRE/JDK 8/17/21/25；不下载运行时，不加载游戏或 OHOS 库。
没有参数时使用 AMCL_JVM_TEST_JAVA_HOME/JAVA_HOME，再查询 PATH 中 java 的 java.home。
输出目录通过统一外置检查，源码指纹/原始日志保留；明确参数可用于不同机器和公开 CI。
"""
from pathlib import Path
import argparse
import hashlib
import json
import locale
import os
import re
import shutil
import subprocess
import sys
from lib.host_cpp import compile_cpp
from lib.workspace_paths import external_output_path, workspace_path

ROOT = Path(__file__).resolve().parents[1]
CPP = ROOT / 'entry/src/main/cpp'


def java_home_from_properties(stdout, stderr, encodings=None):
    """只解码 ASCII 键 java.home 的值，其他本地化系统属性保持原始字节。

    Windows Java8 的输出可能采用 ANSI/GBK，Python UTF-8 模式不能改变子进程编码。
    各候选均严格解码并核验 bin/java；不能用 replacement 字符制造一个错误目录。
    encodings 仅供跨平台回归指定字节编码，正常调用使用 UTF-8、Windows mbcs 和 locale。
    """
    if encodings is None:
        local_encoding = locale.getencoding() if hasattr(locale, 'getencoding') else locale.getpreferredencoding(False)
        encodings = ('utf-8', *(['mbcs'] if os.name == 'nt' else []), local_encoding)
    executable = 'java.exe' if os.name == 'nt' else 'java'
    # 按换行分割字节后精确匹配键，避免其它属性的 GBK/不可解码字符破坏定位。
    for line in ((stdout or b'') + b'\n' + (stderr or b'')).split(b'\n'):
        match = re.fullmatch(rb'[ \t]*java\.home[ \t]*=[ \t]*(.+?)[ \t\r]*', line)
        if not match:
            continue
        for encoding in dict.fromkeys(encodings):
            try:
                candidate = Path(match.group(1).decode(encoding)).resolve()
                if (candidate / 'bin' / executable).is_file():
                    return candidate
            except (UnicodeError, LookupError, ValueError, OSError):
                # 无效编码或路径只淘汰该候选，不读取/打印其它系统属性或环境内容。
                continue
    raise RuntimeError('Cannot discover an existing host java.home; pass --java-home')


def function(text, signature):
    """提取已知生产函数的平衡花括号正文；这里的函数内无不平衡花括号字符串。"""
    begin = text.index(signature)
    end = text.index('{', begin) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[begin:end]


def option_fragments(text):
    """按 jvmInit 的职责边界提取，不依赖 option 的存储类型或旧固定数组长度。

    区块必须在同一生产函数内唯一且有序；结构变化时明确失败，不能从别处拼出测试替身。
    字符串所有者和最终 JavaVMInitArgs 一起进入夹具作用域，直到真实 CreateJavaVM 返回。
    """
    # 四参重载只转发给拥有实际堆预检、选项装配及一次性认领的五参实现。
    body = function(text, 'int jvmInit(const char* appFilesDir, const char* jdkVersion, const char* gameWorkingDirectory,\n            const char* trustedAppFilesDir, bool returnToLauncherOnExit)')

    def offset(marker):
        if body.count(marker) != 1:
            raise RuntimeError('Production jvmInit boundary is missing or ambiguous: ' + marker.strip())
        return body.index(marker)

    preflight = offset('    amcl::jvm::HeapOptions heapOptions;')
    claim = offset('    const int creationClaim = g_runtimeOnce.beginResult();')
    start = offset('    // JVM 参数（')
    stop = offset('    // 使用 OpenJDK')
    if not preflight < claim < start < stop:
        raise RuntimeError('Production heap preflight and Invocation option blocks are out of order')
    return {'jvm_bootstrap_heap_preflight.inc': body[preflight:claim],
            'jvm_bootstrap_options.inc': body[start:stop]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--java-home', default='')
    parser.add_argument('--build-dir', default='')
    parser.add_argument('--out-dir', default='')
    args = parser.parse_args()
    build = external_output_path(args.build_dir) if args.build_dir else workspace_path('build', 'jvm-bootstrap-invocation')
    output = external_output_path(args.out_dir) if args.out_dir else workspace_path('run', 'jvm-bootstrap-invocation')
    build.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    for name in list(env):
        if name.upper() in ('JAVA_TOOL_OPTIONS', '_JAVA_OPTIONS', 'JDK_JAVA_OPTIONS', 'AMCL_GAME_DIR'):
            del env[name]
    home = args.java_home or os.environ.get('AMCL_JVM_TEST_JAVA_HOME') or os.environ.get('JAVA_HOME')
    if not home:
        java = shutil.which('java')
        if not java:
            raise RuntimeError('Host Java missing; pass --java-home')
        found = subprocess.run([java, '-XshowSettings:properties', '-version'], env=env, capture_output=True, check=True)
        home = java_home_from_properties(found.stdout, found.stderr)
    home = Path(home).resolve()
    version = subprocess.run([str(home / 'bin' / ('java.exe' if os.name == 'nt' else 'java')), '-version'],
                             env=env, capture_output=True, check=True)
    (output / 'java-version.txt').write_bytes(version.stdout + version.stderr)
    version_text = (version.stdout + version.stderr).decode('utf-8', errors='replace')
    match = re.search(r'version "(?:1\.)?(\d+)', version_text)
    if not match:
        raise RuntimeError('Cannot identify selected host JVM version')
    major = match.group(1)
    candidates = ('bin/server/jvm.dll', 'jre/bin/server/jvm.dll') if os.name == 'nt' else (
        'lib/server/libjvm.so', 'jre/lib/amd64/server/libjvm.so', 'lib/server/libjvm.dylib')
    jvm = next((home / relative for relative in candidates if (home / relative).is_file()), None)
    if jvm is None:
        raise RuntimeError('Selected Java home lacks a supported server JVM')

    # 注入实际正文而非复制算法；测试工装仅替换平台服务，保持 getter/validator/option 顺序。
    launch_path = CPP / 'jvm/mc_launcher.cpp'
    options_path = CPP / 'jvm/jvm_launcher.cpp'
    launch = launch_path.read_text(encoding='utf-8')
    options = options_path.read_text(encoding='utf-8')
    functions = [function(launch, signature) for signature in ('static void setSystemProperty(',
                 'static bool getSystemProperty(', 'static bool phase_verifyRuntimeProperties(')]
    pieces = {'jvm_bootstrap_properties.inc': '\n'.join(functions), **option_fragments(options)}
    for name, body in pieces.items():
        (build / name).write_text(body, encoding='utf-8')
    hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in (
        Path(__file__), launch_path, options_path, CPP / 'tests/host/jvm_bootstrap_invocation.cpp',
        CPP / 'jvm/jvm_heap_options.h', CPP / 'jvm/jvm_heap_backing.h', CPP / 'jvm/jni_mutf8.h', CPP / 'jvm/jvm_common_args.cpp', CPP / 'jvm/jvm_cf_policy.h',
        CPP / 'jvm/runtime_bootstrap_contract.h', CPP / 'jvm/hap_native_provider_contract.h', CPP / 'jvm/jna_runtime_contract.h', CPP / 'jvm/jdk_native_temp_contract.h', CPP / 'jvm/elf_input_validation.h',
        CPP / 'platform/graphics_plan.h', CPP / 'platform/egl_provider_dispatch.h')}
    (output / 'source-manifest.json').write_text(json.dumps({'source_sha256': hashes,
        'extracted_sha256': {name: hashlib.sha256(body.encode()).hexdigest() for name, body in pieces.items()},
        'host_adjustment': 'Remove only AMCL java.system.class.loader option before Invocation; do not run production exit hook.'}, indent=2), encoding='utf-8')
    binary = build / ('jvm-bootstrap-test.exe' if os.name == 'nt' else 'jvm-bootstrap-test')
    if os.name == 'nt':
        compile_cpp(CPP / 'tests/host/jvm_bootstrap_invocation.cpp', binary, includes=(CPP, build))
    else:
        # 旧 Linux libc 的动态装载接口仍需 libdl；macOS 将它们包含在系统库内。
        subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++17', '-pthread', '-I' + str(CPP),
            '-I' + str(build), str(CPP / 'tests/host/jvm_bootstrap_invocation.cpp'), '-o', str(binary),
            *([] if sys.platform == 'darwin' else ['-ldl'])], check=True)
    cases = [('unicode-properties', 'properties', [], None),
             ('default', 'options', ['128'], None),
             ('owned-paths-longer-than-512', 'owned-options', ['128'], None),
             ('custom-xmx-audit-regression', 'options', ['4096', '-Xmx512m'], None),
             ('explicit-xms', 'options', ['4096', '-Xmx512m', '-Xms128m'], None),
             ('last-maximum', 'options', ['4096', '-Xmx1g', '-XX:MaxHeapSize=128m'], None),
             ('last-initial', 'options', ['4096', '-Xmx512m', '-Xms1g', '-Xms128m'], None),
             ('initial-alias', 'options', ['4096', '-Xmx512m', '-XX:InitialHeapSize=128m'], None),
             ('zero-initial', 'options', ['4096', '-Xmx128m', '-Xms0'], None),
             ('gc-alignment-boundary', 'options', ['4096', '-Xmx512m', '-Xms134217730',
                 '-XX:InitialHeapSize=134217729'], 'gc-alignment-dependent'),
             ('explicit-too-large', 'options', ['4096', '-Xmx128m', '-Xms256m'], 'heap_minimum_exceeds_maximum'),
             ('invalid-then-valid', 'options', ['4096', '-Xmxwrong', '-Xmx128m'], 'heap_size_invalid:Xmx'),
             ('overflow', 'options', ['4096', '-Xmx18446744073709551616'], 'heap_size_invalid:Xmx'),
             # 文件堆不在本套宿主JNI资格内；仍需证明真实生产拒绝不会静默变成RAM启动。
             ('file-heap-rejected-before-load', 'options', ['128','-Damcl.heapfile=1'],
              'host_fixture_heapfile_unavailable' if int(major) in (17,21,25) else 'heapfile_runtime_family_unverified')]
    rows = []
    for name, mode, extra, rejection in cases:
        # 这里验证 JVM 选项字符串，不声称该虚拟路径可创建文件。原始日志始终落真实 output；
        # 多段路径使 user/home/tmp/ErrorFile 超过旧 512 字节边界，不碰宿主 JDK 或文件系统限制。
        directory = output.joinpath(*(['owned-' + 'p' * 72] * 8)) if mode == 'owned-options' else output
        result = subprocess.run([str(binary), mode, str(jvm), str(home), str(directory), major, *extra],
                                cwd=output, env=env, capture_output=True, timeout=45)
        (output / (name + '.log')).write_bytes(result.stdout + b'\nSTDERR:\n' + result.stderr)
        actual = (result.stdout + result.stderr).decode('utf-8', errors='replace')
        if rejection == 'gc-alignment-dependent':
            # 此显式组合由 JVM/GC 自己判断；旧代接受、新代拒绝，均不应被宿主提前否决。
            assert 'JVM_LIBRARY_LOADED=1' in actual and 'HOST_RESULT=-11' not in actual, (name, actual)
            if int(major) <= 17:
                assert result.returncode == 0 and 'CREATE_JVM_RC=0' in actual, (name, actual)
            else:
                assert result.returncode != 0 and 'heap size' in actual.lower(), (name, actual)
        elif rejection:
            assert result.returncode == 0, (name, result.returncode, actual)
            assert 'HOST_RESULT=-11' in actual and rejection in actual, (name, actual)
            assert 'JVM_LIBRARY_LOADED' not in actual, (name, 'invalid heap reached VM loader')
        elif mode == 'properties':
            assert result.returncode == 0, (name, result.returncode, actual)
            assert actual.count('CORRECT=accepted TAMPERED=rejected') == 4 and 'PROPERTY_PROTECTION=PASS' in actual
        else:
            assert result.returncode == 0, (name, result.returncode, actual)
            assert 'CREATE_JVM_RC=0' in actual and 'HOST_RESULT=0' in actual, (name, actual)
            if mode == 'owned-options':
                assert 'OWNED_OPTIONS=PASS' in actual and 'OWNED_PROPERTIES=PASS' in actual, (name, actual)
        rows.append({'case': name, 'jdk': major, 'process_rc': result.returncode, 'expected_rejection': rejection, 'pass': True})
        print('PASS jdk' + major + ' ' + name, flush=True)
    (output / 'results.json').write_text(json.dumps(rows, indent=2), encoding='utf-8')
    print('Host JNI semantics only; no OHOS loader, GPU, Minecraft or release artifact verification.')


if __name__ == '__main__':
    main()
