"""抽取完整生产呈现函数，验证零尺寸/重建/失败与成功事实贯穿到EGL证据序列。"""
from pathlib import Path
import importlib.util
import os
import subprocess
import tempfile
from lib.host_cpp import compile_cpp

root=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('extract', root/'scripts/generate-desktop-review-tests.py')
extract=importlib.util.module_from_spec(spec);spec.loader.exec_module(extract)
module=root/'prebuilt/mobilegl/src/MobileGL'
template=(root/'entry/src/main/cpp/tests/host/mobilegl_present_result.cpp.in').read_text(encoding='utf-8')
for token,path,signature in [
    ('@VULKAN_PRESENT@','MG_Backend/DirectVulkan/Renderer/VulkanRenderer.cpp','    PresentationResult VulkanRenderer::Present() {'),
    ('@BACKEND_SWAP@','MG_Backend/BackendObject.cpp','    PresentationResult BackendObject::SwapEGLBuffers('),
    ('@EGL_SWAP@','MG_Impl/EGLImpl/EGLImpl.cpp','    EGLBoolean SwapBuffers('),
    ('@SEQUENCE@','MG_Impl/EGLImpl/EGLImpl.cpp','    std::uint64_t PresentedSequence()')]:
    source=(module/path).read_text(encoding='utf-8')
    template=template.replace(token,extract.block(source,source.index(signature)))
template=template.replace('@ROOT@',root.as_posix())
with tempfile.TemporaryDirectory(prefix='amcl-mobilegl-present-') as temporary:
    source=Path(temporary)/'test.cpp';source.write_text(template,encoding='utf-8')
    binary=Path(temporary)/('test.exe' if os.name=='nt' else 'test')
    compile_cpp(source,binary);subprocess.run([str(binary)],check=True,timeout=30)
    # 恢复“调用完即成功”的旧语义必须被相同跨层用例击穿，不用另一份模型当反控。
    needle='return backendFunctions.Present();'
    assert template.count(needle)==1
    source.write_text(template.replace(needle,'(void)backendFunctions.Present(); return {PresentationStatus::Presented,true,0};'),encoding='utf-8')
    compile_cpp(source,binary)
    rejected=subprocess.run([str(binary)],capture_output=True,text=True,timeout=30)
    assert rejected.returncode!=0 and 'PresentedSequence()' in rejected.stderr,rejected
    print('PASS: unconditional-success backend negative control rejected')
