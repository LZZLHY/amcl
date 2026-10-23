"""编译并执行实际绑定源码的系统边界故障测试；不装载真实 GPU 驱动。"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import os
import subprocess
import tempfile
import argparse
from lib.host_cpp import compile_cpp

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--negative-controls', action='store_true')
arguments = parser.parse_args()
with workspace_temporary_directory(prefix='amcl-runtime-binding-') as directory:
    binary = Path(directory) / ('binding.exe' if os.name == 'nt' else 'binding')
    compile_cpp(root / 'entry/src/main/cpp/tests/host/graphics_runtime_binding_test.cpp', binary,
        includes=[root / 'entry/src/main/cpp/tests/host/runtime_binding_stubs', root / 'prebuilt/khronos-egl-headers'])
    subprocess.run([str(binary)], check=True, timeout=30)
    # 相同运行时观测核心用于 GLFW/SDL，测分位数与暂停边界，不将计数当 GPU 性能。
    observation = Path(directory) / ('observation.exe' if os.name == 'nt' else 'observation')
    compile_cpp(root / 'entry/src/main/cpp/tests/host/graphics_observation_test.cpp', observation)
    subprocess.run([str(observation)], check=True, timeout=30)
    if arguments.negative_controls:
        # 仅改外部临时生产副本；同一真实TU套件必须检出MobileGL已terminate后残留display，
        # 不能用仅断言窗口表的正向夹具掩盖owner生命周期错误。异常由套件返回1，无交互弹窗。
        platform = root / 'entry/src/main/cpp/platform'
        production = (platform / 'graphics_egl_context.cpp').read_text(encoding='utf-8')
        anchor = 'f.initializedEglDisplay = nullptr;'
        if production.count(anchor) != 1:
            raise ValueError('provider display retirement negative-control anchor changed')
        altered = Path(directory) / 'graphics_egl_context_without_display_retirement.cpp'
        altered.write_text(production.replace(anchor, '(void)f.initializedEglDisplay;'), encoding='utf-8')
        fixture = (root / 'entry/src/main/cpp/tests/host/graphics_runtime_binding_test.cpp').read_text(encoding='utf-8')
        for name in ('graphics_runtime_binding.cpp', 'graphics_features.cpp'):
            fixture = fixture.replace('"../../platform/' + name + '"', '"' + (platform / name).as_posix() + '"')
        fixture = fixture.replace('"../../platform/graphics_egl_context.cpp"', '"' + altered.as_posix() + '"')
        generated = Path(directory) / 'display_retirement_control.cpp'
        generated.write_text(fixture, encoding='utf-8')
        controlled = Path(directory) / ('display_retirement_control.exe' if os.name == 'nt' else 'display_retirement_control')
        compile_cpp(generated, controlled, includes=[platform,
            root / 'entry/src/main/cpp/tests/host/runtime_binding_stubs', root / 'prebuilt/khronos-egl-headers'])
        rejected = subprocess.run([str(controlled)], check=False, timeout=30, capture_output=True, text=True)
        expected = 'successful final provider terminate retained stale display'
        if rejected.returncode != 1 or expected not in rejected.stderr:
            raise RuntimeError('provider display retirement control was not rejected by the expected assertion: ' + rejected.stderr)
        print('PASS negative control rejected: actual provider terminate must retire initialized display')
