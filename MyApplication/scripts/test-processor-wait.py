"""编译并执行真实 processor 等待策略的故障注入测试；不需要真实信号或子进程时序。"""
from pathlib import Path
import os
import subprocess
import tempfile
from lib.host_cpp import compile_cpp

root = Path(__file__).resolve().parent.parent
source = root / 'entry/src/main/cpp/tests/host/processor_wait_test.cpp'
with tempfile.TemporaryDirectory(prefix='amcl-processor-wait-') as directory:
    binary = Path(directory) / ('test.exe' if os.name == 'nt' else 'test')
    compile_cpp(source, binary)
    subprocess.run([str(binary)], check=True, timeout=20)
