"""编译并执行生产 JVM 同步信号分发契约；宿主不向自身发送真实硬件异常。"""
from pathlib import Path
import os,subprocess,tempfile
from lib.host_cpp import compile_cpp

root=Path(__file__).resolve().parents[1]
source=root/'entry/src/main/cpp/tests/host/jvm_signal_dispatch_test.cpp'
with tempfile.TemporaryDirectory(prefix='amcl-jvm-signal-') as directory:
    exe=Path(directory)/('signal.exe' if os.name=='nt' else 'signal')
    compile_cpp(source,exe,[],[])
    subprocess.run([str(exe)],check=True,timeout=10)
