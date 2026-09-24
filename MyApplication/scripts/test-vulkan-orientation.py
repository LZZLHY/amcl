"""编译完整生产WSI及实际surface探针，验证窗口方向图像契约和旧错误实现反控。

模板只替换驱动/窗口API；生产正文在每次执行时读取。所有二进制放临时目录，
不加载GPU、不运行应用、不修改现役源文件。失败必须返回非零，不能静默跳过。
"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import importlib.util
import os
import subprocess
import tempfile
from lib.host_cpp import compile_cpp

root=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('extract',root/'scripts/generate-desktop-review-tests.py')
extract=importlib.util.module_from_spec(spec)
spec.loader.exec_module(extract)
wsi=(root/'entry/src/main/cpp/platform/vulkan_wsi.cpp').read_text(encoding='utf-8')
probe=(root/'entry/src/main/cpp/platform/vulkan_probe.cpp').read_text(encoding='utf-8')
body=extract.block(probe,probe.index('void probeQueuePresentation('))
template=(root/'entry/src/main/cpp/tests/host/vulkan_orientation.cpp.in').read_text(encoding='utf-8')
code=template.replace('@ROOT@',root.as_posix()).replace('@WSI@',wsi).replace('@PROBE@',body)
includes=[root/'entry/src/main/cpp/platform',root/'entry/src/main/cpp/tests/host/stubs',
          root/'prebuilt/mobilegl/src/3rdparty/Vulkan-Headers/include']
with workspace_temporary_directory(prefix='amcl-vulkan-orientation-') as temporary:
    source=Path(temporary)/'orientation.cpp'
    binary=Path(temporary)/('orientation.exe' if os.name=='nt' else 'orientation')
    source.write_text(code,encoding='utf-8')
    compile_cpp(source,binary,includes=includes)
    result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=30)
    if result.returncode: raise RuntimeError(result.stdout+'\n'+result.stderr)
    if 'policy=window-oriented-identity' not in result.stderr: raise RuntimeError('missing actual orientation evidence')
    print(result.stdout.strip())
    # 恢复旧行为只删生产赋值，同一公开入口测试必须发现实际驱动仍收到90°，而非只查源码形状。
    change='adjusted.preTransform = static_cast<VkSurfaceTransformFlagBitsKHR>(orientation.preTransform);'
    if code.count(change)!=1: raise RuntimeError('production transform assignment changed; inspect negative control')
    source.write_text(code.replace(change,'/* 历史反控：保留调用者的错误旋转声明。 */'),encoding='utf-8')
    compile_cpp(source,binary,includes=includes)
    failed=subprocess.run([str(binary)],capture_output=True,text=True,timeout=30)
    if failed.returncode==0 or 'submitted.preTransform==' not in failed.stderr:
        raise RuntimeError('old transform passthrough was not rejected: '+failed.stderr)
    print('PASS: old preTransform passthrough negative control rejected by actual driver-call assertion')
