"""编译并执行实际绑定源码的系统边界故障测试；不装载真实 GPU 驱动。"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import os
import subprocess
import tempfile
from lib.host_cpp import compile_cpp

root = Path(__file__).resolve().parent.parent
with workspace_temporary_directory(prefix='amcl-runtime-binding-') as directory:
    binary = Path(directory) / ('binding.exe' if os.name == 'nt' else 'binding')
    compile_cpp(root / 'entry/src/main/cpp/tests/host/graphics_runtime_binding_test.cpp', binary,
        includes=[root / 'entry/src/main/cpp/tests/host/runtime_binding_stubs', root / 'prebuilt/khronos-egl-headers'])
    subprocess.run([str(binary)], check=True, timeout=30)
    # 相同运行时观测核心用于 GLFW/SDL，测分位数与暂停边界，不将计数当 GPU 性能。
    observation = Path(directory) / ('observation.exe' if os.name == 'nt' else 'observation')
    compile_cpp(root / 'entry/src/main/cpp/tests/host/graphics_observation_test.cpp', observation)
    subprocess.run([str(observation)], check=True, timeout=30)
