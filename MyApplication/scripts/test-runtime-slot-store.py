"""编译生产 POSIX 存储器与真实文件系统回归；Windows 经 WSL 执行，不把锁替换成模拟对象。"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
sources = ['entry/src/main/cpp/tests/host/runtime_slot_store_test.cpp',
           'entry/src/main/cpp/platform/runtime_slot_store.cpp']
if os.name == 'nt':
    # 源文件在只读传参的工作区；二进制和测试数据均放 WSL 自己的 mktemp 目录。
    paths = [subprocess.check_output(['wsl', '-d', 'Ubuntu', '--exec', 'wslpath', '-a', (root / source).as_posix()], text=True).strip()
             for source in sources]
    subprocess.run(['wsl', '-d', 'Ubuntu', '--exec', 'python3', '-c',
        'import subprocess,tempfile,pathlib,sys\n'
        'with tempfile.TemporaryDirectory(prefix="amcl-slot-test-") as d:\n'
        ' p=str(pathlib.Path(d)/"test")\n'
        ' subprocess.run(["g++","-std=c++17","-Wall","-Wextra","-Werror","-pthread","-Wl,--wrap=renameat",*sys.argv[1:],"-o",p],check=True,timeout=90)\n'
        ' subprocess.run([p],check=True,timeout=30)\n', *paths], check=True, timeout=150)
else:
    with tempfile.TemporaryDirectory(prefix='amcl-slot-test-') as directory:
        binary = str(Path(directory) / 'test')
        subprocess.run([os.getenv('CXX', 'g++'), '-std=c++17', '-Wall', '-Wextra', '-Werror', '-pthread', '-Wl,--wrap=renameat',
                        *[str(root / source) for source in sources], '-o', binary], check=True, timeout=90)
        subprocess.run([binary], check=True, timeout=30)
