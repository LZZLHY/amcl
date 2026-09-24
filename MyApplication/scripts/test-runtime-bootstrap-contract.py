"""编译并执行生产启动契约纯核心；临时目录仅存本次测试产物，失败直接向调用方传播。"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import os
import subprocess
import sys
import tempfile
from lib.host_cpp import compile_cpp

root = Path(__file__).resolve().parent.parent
# 默认 Invocation 入口与显式 java-home 都必须可用；该回归不依赖真实 JDK 安装或本机代码页。
subprocess.run([sys.executable, str(root / 'scripts/test-jvm-java-home-discovery.py')], check=True, timeout=20)
with workspace_temporary_directory(prefix='amcl-bootstrap-contract-') as directory:
    # 三个生产核心共同保护 JVM 前后的契约：路径冻结、最终堆关系和标准 UTF-8 回读。
    # 每个源文件独立编译，任何一个失败都让原有 runtime-ownership 预检失败。
    for name in ('runtime_bootstrap_contract', 'jvm_heap_options', 'jni_mutf8'):
        source = root / ('entry/src/main/cpp/tests/host/' + name + '_test.cpp')
        binary = Path(directory) / (name + ('.exe' if os.name == 'nt' else ''))
        compile_cpp(source, binary, includes=(root / 'entry/src/main/cpp/jvm',))
        subprocess.run([str(binary)], check=True, timeout=20)
