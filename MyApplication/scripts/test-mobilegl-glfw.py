"""直接编译生产 MobileGL OpenGL 生命周期与 provider 分派测试，不调用真实设备或重建依赖。"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import os
import subprocess
import tempfile
from lib.host_cpp import compile_cpp

root = Path(__file__).resolve().parent.parent
with workspace_temporary_directory(prefix='amcl-mobilegl-glfw-') as directory:
    for source in ['mobilegl_egl_core_test.cpp', 'egl_provider_dispatch_test.cpp']:
        binary = Path(directory) / (Path(source).stem + ('.exe' if os.name == 'nt' else ''))
        compile_cpp(root / 'entry/src/main/cpp/tests/host' / source, binary,
                    includes=[root / 'prebuilt/khronos-egl-headers'])
        subprocess.run([str(binary)], check=True, timeout=30)
    # 原样编译准入执行器和注入驱动，两个 provider 均执行成功及所有清理失败场景。
    probe = Path(directory) / 'capability.cpp'
    probe.write_text('#include "' + (root / 'entry/src/main/cpp/platform/mobilegl_capability.cpp').as_posix()
        + '"\n#include "' + (root / 'entry/src/main/cpp/tests/host/mobilegl_capability_host_test.cpp').as_posix()
        + '"\n', encoding='utf-8')
    binary = Path(directory) / ('capability.exe' if os.name == 'nt' else 'capability')
    compile_cpp(probe, binary)
    subprocess.run([str(binary)], check=True, timeout=30)
print('PASS MobileGL GLFW production lifecycle and selected-provider isolation; GPU/device not inferred')
