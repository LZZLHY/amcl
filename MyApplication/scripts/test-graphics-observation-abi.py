"""在 POSIX 上编译实际观测 C ABI，避免用模型替代 fork 与互斥行为。"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import os
import subprocess
import sys
import tempfile
root = Path(__file__).resolve().parent.parent
source = root / 'entry/src/main/cpp/tests/host/graphics_observation_abi_test.cpp'
includes = root / 'prebuilt/khronos-egl-headers'
if os.name == 'nt':
    # WSL 重新执行同一脚本，共用下面的真实 POSIX 测试和外部输出规则，不维护第二份内嵌脚本。
    script = subprocess.check_output(['wsl', '-d', 'Ubuntu', '--exec', 'wslpath', '-a', Path(__file__).resolve().as_posix()], text=True).strip()
    subprocess.run(['wsl', '-d', 'Ubuntu', '--exec', 'python3', script], check=True, timeout=150)
    sys.exit(0)
else:
    with workspace_temporary_directory(prefix='amcl-observation-test-') as directory:
        binary = str(Path(directory) / 'test')
        subprocess.run([os.getenv('CXX', 'g++'), '-std=c++17', '-Wall', '-Wextra', '-Werror', '-pthread',
                        '-I' + str(includes), str(source), '-o', binary], check=True, timeout=90)
        subprocess.run([binary], check=True, timeout=30)
