"""定位宿主 C++ 工具链并编译探针；普通 Windows 终端无需先手工运行 vcvars。"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile


def compile_cpp(source, binary, includes=(), defines=()):
    """输入源码/输出路径和显式 include/define；编译失败抛错，不静默跳过。

    非 Windows 直接调用 c++。Windows 优先使用当前 cl，再通过 vswhere 或
    AMCL_VCVARS64 查找环境脚本；临时批处理只在其子进程加载环境并且退出后清理。
    所有路径作为带引号的参数，百分号转义，避免批处理将路径解释为环境变量。
    """
    source, binary = Path(source), Path(binary)
    if os.name != 'nt':
        subprocess.run(['c++', '-std=c++17', '-pthread', *['-D' + d for d in defines],
                        *['-I' + str(p) for p in includes], str(source), '-o', str(binary)], check=True)
        return
    command = ['cl', '/nologo', '/utf-8', '/EHsc', '/std:c++17', '/D_CRT_SECURE_NO_WARNINGS',
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
    with tempfile.TemporaryDirectory(prefix='amcl-host-compiler-') as directory:
        script = Path(directory) / 'compile.cmd'
        script.write_text('@echo off\ncall ' + quote(vcvars) + ' >nul\nif errorlevel 1 exit /b %errorlevel%\n'
                          + ' '.join(quote(arg) for arg in command) + '\nexit /b %errorlevel%\n', encoding='utf-8')
        subprocess.run(['cmd', '/d', '/c', str(script)], check=True)
