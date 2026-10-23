"""定位宿主 C++ 工具链并编译探针；普通 Windows 终端无需先手工运行 vcvars。"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from .workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import os
import shutil
import subprocess
import tempfile


def find_host_cmake(explicit=None):
    """寻找真实宿主CMake；显式路径优先，Windows优先已安装Visual Studio自带工具。

    该工具只负责编排宿主工程，不选择HarmonyOS SDK交叉编译器；Windows配置阶段另以
    已安装Visual Studio的x64生成器固定编译器身份，Linux使用系统原生工具链。
    """
    candidates = [Path(explicit)] if explicit else []
    if os.name == 'nt':
        candidates += [Path('D:/Microsoft Visual Studio/18/Community/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'),
            Path('C:/Program Files/Microsoft Visual Studio/2022/Community/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe')]
    found = shutil.which('cmake')
    if found:
        candidates.append(Path(found))
    executable = next((candidate for candidate in candidates if candidate.is_file()), None)
    if executable is None:
        raise FileNotFoundError('Native host CMake not found; pass --cmake with an installed host tool')
    return str(executable.resolve())


def configure_host_cmake(cmake, source, build):
    """配置原生宿主工程，清除继承的交叉编译器变量，不污染调用者或用户全局环境。

    Windows必须有真实Visual Studio实例，按vswhere签发版本选择x64生成器；找不到实例
    时明确失败，不能把SDK clang/ARM目标称为宿主验证。构建树和生成源码由调用方外置。
    """
    command = [cmake, '-S', str(source), '-B', str(build)]
    child_env = dict(os.environ)
    for name in ('CC', 'CXX', 'CMAKE_TOOLCHAIN_FILE', 'CMAKE_GENERATOR', 'CMAKE_GENERATOR_PLATFORM'):
        child_env.pop(name, None)
    if os.name == 'nt':
        vswhere = Path(os.environ.get('ProgramFiles(x86)', 'C:/Program Files (x86)')) / 'Microsoft Visual Studio/Installer/vswhere.exe'
        major = None
        if vswhere.is_file():
            found = subprocess.run([str(vswhere), '-latest', '-products', '*', '-requires',
                'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationVersion'],
                capture_output=True, text=True, check=True)
            if found.stdout.strip():
                major = int(found.stdout.strip().split('.')[0])
        if major is None:
            for version, vcvars in [(18, 'D:/Microsoft Visual Studio/18/Community/VC/Auxiliary/Build/vcvars64.bat'),
                    (17, 'C:/Program Files/Microsoft Visual Studio/2022/Community/VC/Auxiliary/Build/vcvars64.bat')]:
                if Path(vcvars).is_file():
                    major = version
                    break
        years = {16: 2019, 17: 2022, 18: 2026}
        if major not in years:
            raise FileNotFoundError('Installed native Visual Studio C++ toolchain not found')
        command += ['-G', 'Visual Studio ' + str(major) + ' ' + str(years[major]), '-A', 'x64']
    subprocess.run(command, env=child_env, check=True)


def compile_cpp(source, binary, includes=(), defines=(), *, standard='c++17'):
    """输入源码/输出路径和显式 include/define；编译失败抛错，不静默跳过。

    非 Windows 直接调用 c++。Windows 优先使用当前 cl，再通过 vswhere 或
    AMCL_VCVARS64 查找环境脚本；临时批处理只在其子进程加载环境并且退出后清理。
    所有路径作为带引号的参数，百分号转义，避免批处理将路径解释为环境变量。
    """
    # 默认保留既有C++17；个别上游生产函数使用span时显式请求20，不改变其它宿主套件。
    if standard not in ('c++17', 'c++20'):
        raise ValueError('unsupported explicit host C++ standard')
    source, binary = Path(source), Path(binary)
    if os.name != 'nt':
        subprocess.run(['c++', '-std=' + standard, '-pthread', *['-D' + d for d in defines],
                        *['-I' + str(p) for p in includes], str(source), '-o', str(binary)], check=True)
        return
    command = ['cl', '/nologo', '/utf-8', '/EHsc', '/std:' + standard, '/D_CRT_SECURE_NO_WARNINGS',
               *['/D' + d for d in defines], *['/I' + str(p) for p in includes], str(source),
               '/Fo' + str(binary.with_suffix('.obj')), '/Fe' + str(binary)]
    if shutil.which('cl'):
        subprocess.run(command, check=True)
        return
    candidates = [Path(value) for value in [os.environ.get('AMCL_VCVARS64'),
        'D:/Microsoft Visual Studio/18/Community/VC/Auxiliary/Build/vcvars64.bat',
        'C:/Program Files/Microsoft Visual Studio/2022/Community/VC/Auxiliary/Build/vcvars64.bat'] if value]
    vswhere = Path(os.environ.get('ProgramFiles(x86)', 'C:/Program Files (x86)')) / 'Microsoft Visual Studio/Installer/vswhere.exe'
    if vswhere.exists():
        found = subprocess.run([str(vswhere), '-latest', '-products', '*', '-requires',
            'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath'], capture_output=True, text=True, check=True)
        if found.stdout.strip():
            candidates.insert(0, Path(found.stdout.strip()) / 'VC/Auxiliary/Build/vcvars64.bat')
    vcvars = next((path for path in candidates if path.is_file()), None)
    if vcvars is None:
        raise FileNotFoundError('MSVC not found: initialize vcvars64 or set AMCL_VCVARS64')
    quote = lambda value: '"' + str(value).replace('%', '%%').replace('"', '""') + '"'
    with workspace_temporary_directory(prefix='amcl-host-compiler-') as directory:
        script = Path(directory) / 'compile.cmd'
        script.write_text('@echo off\ncall ' + quote(vcvars) + ' >nul\nif errorlevel 1 exit /b %errorlevel%\n'
                          + ' '.join(quote(arg) for arg in command) + '\nexit /b %errorlevel%\n', encoding='utf-8')
        subprocess.run(['cmd', '/d', '/c', str(script)], check=True)
