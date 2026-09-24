"""编译并执行生产 JVM 同步信号分发契约；宿主不向自身发送真实硬件异常。"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import os,subprocess,tempfile
from lib.host_cpp import compile_cpp

root=Path(__file__).resolve().parents[1]
source=root/'entry/src/main/cpp/tests/host/jvm_signal_dispatch_test.cpp'
with workspace_temporary_directory(prefix='amcl-jvm-signal-') as directory:
    exe=Path(directory)/('signal.exe' if os.name=='nt' else 'signal')
    compile_cpp(source,exe,[],[])
    subprocess.run([str(exe)],check=True,timeout=10)
