"""编译生产功能探针与边界故障测试；不使用真实GPU，也不将fixture阳性当成设备能力。"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import os
import subprocess
import sys
import tempfile
root = Path(__file__).resolve().parent.parent
if os.name == 'nt':
    script = subprocess.check_output(['wsl', '-d', 'Ubuntu', '--exec', 'wslpath', '-a', Path(__file__).resolve().as_posix()], text=True).strip()
    subprocess.run(['wsl', '-d', 'Ubuntu', '--exec', 'python3', script], check=True, timeout=150)
    sys.exit(0)
with workspace_temporary_directory(prefix='amcl-feature-test-') as temp:
    for name in ['graphics_features_test', 'graphics_context_resources_test']:
        binary = str(Path(temp) / name)
        subprocess.run(['g++', '-std=c++17', '-Wall', '-Wextra', '-Werror', '-pthread',
            '-I'+str(root/'prebuilt/khronos-egl-headers'), str(root/('entry/src/main/cpp/tests/host/'+name+'.cpp')), '-o', binary], check=True, timeout=90)
        subprocess.run([binary], check=True, timeout=30)
