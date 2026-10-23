"""直接编译 MG 生产深度范围 TU；可选接入 desktop 版本身份的生产 TU 回归。

这是宿主驱动接缝回归，不创建 EGL/GPU。Windows 使用显式 WSL Linux 工具链，
Linux 使用原生 GNU/Clang；不需要编译 glslang/SPIRV-Cross，不把 SDK ARM clang
误作宿主编译器。真实 provider 的像素验证由 graphics semantic runner 承担。
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess
from lib.workspace_paths import external_output_path, workspace_path


def main():
    """编译完整生产 TU、核对唯一符号，再在两个干净进程中执行正例和负控制。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', help='仓库外宿主构建目录；默认由工作区策略解析')
    parser.add_argument('--cxx', default='g++', help='Linux GNU/Clang C++ 编译器')
    parser.add_argument('--wsl-distro', default='Ubuntu', help='Windows 上明确使用的 WSL 分发')
    parser.add_argument('--sanitizers', action='store_true', help='开启 ASan/UBSan 检查真实 TU')
    parser.add_argument('--include-version-identity', action='store_true',
                        help='另编译真实 context/getter/enable，并执行低/高版本首次读取顺序')
    arguments = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    mg = project / 'prebuilt/mobileglues/mg_src/MobileGlues-cpp'
    output = (external_output_path(arguments.build_dir) if arguments.build_dir
              else workspace_path('build', 'mg-depth-range'))
    output.mkdir(parents=True, exist_ok=True)

    # 只传参数数组，不拼 shell 文本；路径转换不执行命令替换，也不继承交叉编译配置。
    prefix = ['wsl', '-d', arguments.wsl_distro, '--'] if os.name == 'nt' else []

    def host_path(path):
        """把同一真实文件转换为 WSL 挂载路径；原生 Linux 保留绝对路径。"""
        absolute = str(Path(path).resolve())
        if not prefix:
            return absolute
        return subprocess.run(prefix + ['wslpath', '-a', '-u', Path(path).resolve().as_posix()],
                              check=True, capture_output=True, text=True).stdout.strip()

    identity = subprocess.run(prefix + [arguments.cxx, '--version'], check=True,
                              capture_output=True, text=True).stdout.splitlines()[0]
    print('Host compiler: ' + identity, flush=True)
    print('MG source: ' + str(mg), flush=True)
    # include/ 必须先于 MG 根：Windows 挂载目录不区分 EGL/ 与内部 egl/，反序会误选头。
    compiler_command = prefix + [arguments.cxx, '-std=gnu++20', '-O1', '-g', '-UNDEBUG',
        '-ffunction-sections', '-fdata-sections', '-pthread',
        '-DAMCL_MG_FRAME_STATS=0', '-DAMCL_MG_UPLOAD_SCHEDULER_LAB=0', '-DPROFILING=0',
        '-I' + host_path(mg / 'include'), '-I' + host_path(mg),
        '-I' + host_path(mg / '3rdparty/xxhash')]
    if arguments.sanitizers:
        compiler_command += ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']

    def build_binary(source_paths, binary, required_symbols):
        """同一显式宿主工具链编译完整 TU，前台输出并核对真实生产入口的唯一符号。

        linker 只丢弃未使用的无关 wrapper，不抽取或改写目标函数；新增版本测试与深度
        测试使用相同 WSL/path/sanitizer 机制，结果保持不同 binary 和 evidence 身份。
        """
        command = compiler_command + [host_path(path) for path in source_paths]
        command += ['-Wl,--gc-sections', '-o', host_path(binary)]
        subprocess.run(command, check=True)
        symbols = subprocess.run(prefix + ['nm', '--defined-only', host_path(binary)],
                                 check=True, capture_output=True, text=True).stdout
        for symbol in required_symbols:
            if sum(line.split()[-1:] == [symbol] for line in symbols.splitlines()) != 1:
                raise RuntimeError('Expected exactly one production symbol: ' + symbol)

    source_paths = [mg / 'tests/depth_range_test.cpp', mg / 'gl/gl_native.cpp',
                    mg / 'gl/gl_stub.cpp', mg / 'gl/enable.cpp']
    binary = output / 'depth_range_test'
    build_binary(source_paths, binary, ['glDepthRange', 'glDepthRangef', 'glGetFloatv', 'glGetDoublev'])

    results = []
    for arguments_for_run, expected in [([], 'PASS production depth range:'),
        (['--verify-legacy-noop'], 'PASS negative control: original double noop rejected')]:
        result = subprocess.run(prefix + [host_path(binary), *arguments_for_run],
                                capture_output=True, text=True, timeout=30)
        print(result.stdout, end='', flush=True)
        if result.stderr:
            print(result.stderr, end='', flush=True)
        if result.returncode != 0 or expected not in result.stdout:
            raise RuntimeError('Depth-range regression failed: ' + str(result.returncode))
        # 负控制须由精确范围断言拒绝，崩溃/别的错误不能充当语义失败。
        if arguments_for_run and 'FAIL glDepthRange changes actual driver range' not in result.stderr:
            raise RuntimeError('Legacy negative did not fail at the intended state assertion')
        results.append({'arguments': arguments_for_run, 'exit_code': result.returncode,
                        'stdout': result.stdout, 'stderr': result.stderr})
    evidence = {'compiler': identity, 'platform': 'WSL Linux host' if prefix else 'Linux host',
        'sanitizers': arguments.sanitizers, 'sources': [
            {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
            for path in source_paths],
        'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
        'unique_production_symbols': ['glDepthRange', 'glDepthRangef', 'glGetFloatv', 'glGetDoublev'],
        'results': results,
        'boundary': 'Production TUs with driver seam; no real EGL context or GPU pixel claim'}
    (output / 'depth-range-evidence.json').write_text(
        json.dumps(evidence, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print('Evidence: ' + str(output / 'depth-range-evidence.json'), flush=True)

    if arguments.include_version_identity:
        # B2只验证已经修复的desktop current/cache接缝，不扩大ES frontend或GLSL承诺。
        # 两种顺序在独立进程中运行，生产测试内部保留pointer/deferred-destroy/thread迁移；
        # 旧getter/context真实TU负证据另有收据，不为永久负控制复制整份第三方实现。
        version_sources = [mg / 'tests/version_identity_test.cpp', mg / 'gl/getter.cpp',
                           mg / 'egl/context.cpp', mg / 'gl/enable.cpp']
        version_binary = output / 'version_identity_test'
        version_symbols = ['glGetString', 'glGetStringi', 'glGetIntegerv']
        build_binary(version_sources, version_binary, version_symbols)
        version_results = []
        for version_arguments in [[], ['--high-first']]:
            result = subprocess.run(prefix + [host_path(version_binary), *version_arguments],
                                    capture_output=True, text=True, timeout=30)
            print(result.stdout, end='', flush=True)
            if result.stderr:
                print(result.stderr, end='', flush=True)
            if result.returncode != 0 or 'PASS production desktop version identity:' not in result.stdout:
                raise RuntimeError('Version-identity regression failed: ' + str(result.returncode))
            version_results.append({'arguments': version_arguments, 'exit_code': result.returncode,
                                    'stdout': result.stdout, 'stderr': result.stderr})
        # 记录实际MG提交及关键布局/API头，不能只用main仓HEAD冒充fork实现身份。
        # 这些是host接缝证据；context/GPU的真实资格继续由共享场景和设备验收分层提供。
        headers = [mg / name for name in ['egl/context.h', 'gl/getter.h', 'gl/mg.h',
            'gl/enable.h', 'gl/shader.h', 'config/settings.h', 'includes.h',
            'include/GL/gl.h', 'gl/glcorearb.h', 'include/EGL/egl.h']]
        version_evidence = {'compiler': identity,
            'platform': 'WSL Linux host' if prefix else 'Linux host',
            'sanitizers': arguments.sanitizers,
            'mg_commit': subprocess.run(['git', '-C', str(mg), 'rev-parse', 'HEAD'],
                                       check=True, capture_output=True, text=True).stdout.strip(),
            'sources': [{'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
                        for path in version_sources],
            'headers': [{'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
                        for path in headers],
            'binary_sha256': hashlib.sha256(version_binary.read_bytes()).hexdigest(),
            'unique_production_symbols': version_symbols, 'results': version_results,
            'boundary': 'Production context/getter TUs with driver seam; desktop cache scope only; no real EGL/GPU qualification'}
        version_path = output / 'version-identity-evidence.json'
        version_path.write_text(json.dumps(version_evidence, ensure_ascii=False, indent=2) + '\n',
                                encoding='utf-8')
        print('Evidence: ' + str(version_path), flush=True)


if __name__ == '__main__':
    main()
