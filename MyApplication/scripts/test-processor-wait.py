"""编译并执行真实 processor 等待策略的故障注入测试；不需要真实信号或子进程时序。"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import os
import subprocess
import tempfile
from lib.host_cpp import compile_cpp

root = Path(__file__).resolve().parent.parent
source = root / 'entry/src/main/cpp/tests/host/processor_wait_test.cpp'
with workspace_temporary_directory(prefix='amcl-processor-wait-') as directory:
    binary = Path(directory) / ('test.exe' if os.name == 'nt' else 'test')
    compile_cpp(source, binary)
    subprocess.run([str(binary)], check=True, timeout=20)
