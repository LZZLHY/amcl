"""在 POSIX 上编译实际观测 C ABI，避免用模型替代 fork 与互斥行为。"""
from pathlib import Path
import os
import subprocess
import tempfile
root = Path(__file__).resolve().parent.parent
source = root / 'entry/src/main/cpp/tests/host/graphics_observation_abi_test.cpp'
includes = root / 'prebuilt/khronos-egl-headers'
if os.name == 'nt':
    translate = lambda path: subprocess.check_output(['wsl', '-d', 'Ubuntu', '--exec', 'wslpath', '-a', path.as_posix()], text=True).strip()
    subprocess.run(['wsl', '-d', 'Ubuntu', '--exec', 'python3', '-c',
        'import subprocess,tempfile,pathlib,sys\n'
        'with tempfile.TemporaryDirectory(prefix="amcl-observation-test-") as d:\n'
        ' p=str(pathlib.Path(d)/"test")\n'
        ' subprocess.run(["g++","-std=c++17","-Wall","-Wextra","-Werror","-pthread","-I"+sys.argv[2],sys.argv[1],"-o",p],check=True,timeout=90)\n'
        ' subprocess.run([p],check=True,timeout=30)\n', translate(source), translate(includes)], check=True, timeout=150)
else:
    with tempfile.TemporaryDirectory(prefix='amcl-observation-test-') as directory:
        binary = str(Path(directory) / 'test')
        subprocess.run([os.getenv('CXX', 'g++'), '-std=c++17', '-Wall', '-Wextra', '-Werror', '-pthread',
                        '-I' + str(includes), str(source), '-o', binary], check=True, timeout=90)
        subprocess.run([binary], check=True, timeout=30)
