"""对生产原始会话 IO 执行真实文件测试；所有重定向只发生在测试子进程。"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import os
import subprocess
import tempfile
from lib.host_cpp import compile_cpp

root = Path(__file__).resolve().parents[1]
with workspace_temporary_directory(prefix='amcl-session-io-') as directory:
    target = Path(directory) / ('session-io.exe' if os.name == 'nt' else 'session-io')
    compile_cpp(root / 'entry/src/main/cpp/tests/host/session_log_io_test.cpp', target)
    for mode in ['normal', 'unclean', 'failed-open']:
        subprocess.run([str(target), str(Path(directory) / mode), mode], check=True, timeout=20)
