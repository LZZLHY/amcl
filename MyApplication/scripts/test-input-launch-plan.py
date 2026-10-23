"""编译并执行实际Native输入计划裁决，测试产物由既有工作区工具外置。"""
from pathlib import Path
import os
import subprocess
from lib.host_cpp import compile_cpp
from lib.workspace_paths import temporary_directory

root = Path(__file__).resolve().parent.parent
with temporary_directory(prefix='amcl-input-launch-') as directory:
    binary = Path(directory) / ('input_launch_plan.exe' if os.name == 'nt' else 'input_launch_plan')
    compile_cpp(root / 'entry/src/main/cpp/tests/host/input_launch_plan_test.cpp', binary,
                includes=(root / 'entry/src/main/cpp/jvm',))
    subprocess.run([str(binary)], check=True, timeout=20)
