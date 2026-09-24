"""编译并执行生产启动契约纯核心；临时目录仅存本次测试产物，失败直接向调用方传播。"""
from pathlib import Path
import os
import subprocess
import tempfile
from lib.host_cpp import compile_cpp

root = Path(__file__).resolve().parent.parent
source = root / 'entry/src/main/cpp/tests/host/runtime_bootstrap_contract_test.cpp'
with tempfile.TemporaryDirectory(prefix='amcl-bootstrap-contract-') as directory:
    binary = Path(directory) / ('test.exe' if os.name == 'nt' else 'test')
    compile_cpp(source, binary)
    subprocess.run([str(binary)], check=True, timeout=20)
