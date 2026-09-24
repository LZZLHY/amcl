"""编译生产 POSIX 存储器与真实文件系统回归；Windows 经 WSL 执行，不把锁替换成模拟对象。"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
sources = ['entry/src/main/cpp/tests/host/runtime_slot_store_test.cpp',
           'entry/src/main/cpp/platform/runtime_slot_store.cpp']
if os.name == 'nt':
    # WSL 执行同一脚本，由共享 helper 管理二进制位置；POSIX 锁/renameat 断言仍真实运行。
    script = subprocess.check_output(['wsl', '-d', 'Ubuntu', '--exec', 'wslpath', '-a', Path(__file__).resolve().as_posix()], text=True).strip()
    subprocess.run(['wsl', '-d', 'Ubuntu', '--exec', 'python3', script], check=True, timeout=150)
    sys.exit(0)
else:
    with workspace_temporary_directory(prefix='amcl-slot-test-') as directory:
        binary = str(Path(directory) / 'test')
        subprocess.run([os.getenv('CXX', 'g++'), '-std=c++17', '-Wall', '-Wextra', '-Werror', '-pthread', '-Wl,--wrap=renameat',
                        *[str(root / source) for source in sources], '-o', binary], check=True, timeout=90)
        subprocess.run([binary], check=True, timeout=30)
