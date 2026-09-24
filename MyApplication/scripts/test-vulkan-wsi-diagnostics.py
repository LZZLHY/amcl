"""编译真实 WSI 的假驱动宿主测试，分别核对诊断关闭、开发默认与显式开启的两个日志通道。

全部产物位于本轮临时目录，不启动应用、不访问 GPU/设备，也不更改任何已有 HAP。
宿主 fixture 计数 hilog，外层捕获 stderr；成功输出需有正控，不能只依赖静默结果。
"""
from pathlib import Path
import os
import subprocess
import tempfile
from lib.host_cpp import compile_cpp

root = Path(__file__).resolve().parent.parent
source = root / 'entry/src/main/cpp/tests/host/vulkan_wsi_diagnostics_test.cpp'
includes = [root / 'entry/src/main/cpp/tests/host/stubs',
            root / 'prebuilt/mobilegl/src/3rdparty/Vulkan-Headers/include']

with tempfile.TemporaryDirectory(prefix='amcl-wsi-diagnostics-') as directory:
    # 不传宏时也必须关闭；512 反例证明仅有 trace 位不能越过开发产品身份。
    for mask in [None, 0, 1, 512, 513]:
        effective = 0 if mask is None else mask
        binary = Path(directory) / ('wsi-' + str(mask) + ('.exe' if os.name == 'nt' else ''))
        defines = [] if mask is None else ['AMCL_DIAGNOSTICS_MASK=' + str(mask)]
        compile_cpp(source, binary, includes=includes, defines=defines)
        result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=30)
        expected = f'PASS WSI trace mask={effective} buffers=65 memory=64 bind=64 free=64 presents=300 failedPresent=1'
        assert expected in result.stdout, result.stdout
        trace = effective == 513
        for message in ['graphics_vk_create_buffer begin', 'graphics_vk_create_buffer end result=0',
                        'graphics_vk_allocate_memory begin', 'graphics_vk_bind_buffer_memory begin',
                        'graphics_vk_free_memory begin', 'graphics_vk_resolve_device begin', 'fixture_trace_argument=1']:
            assert (message in result.stderr) == trace, (mask, message, result.stderr)
        for message in ['graphics_loader_admission', 'graphics_vk_create_device end result=0',
                        'graphics_vk_create_buffer end result=-2', 'graphics_vk_get_buffer_memory end device=8960 buffer=0',
                        'graphics_queue_present result=0 presents=300', 'graphics_queue_present result=-4',
                        'fixture_error_argument=1']:
            assert message in result.stderr, (mask, message, result.stderr)
        print(expected)
print('PASS Vulkan WSI: release/default trace-off, explicit trace-on, failure/lifecycle evidence and dispatch preserved')
