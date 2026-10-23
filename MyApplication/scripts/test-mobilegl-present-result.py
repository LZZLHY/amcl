"""抽取完整生产呈现函数，验证零尺寸/重建/失败与成功事实贯穿到EGL证据序列。"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import importlib.util
import os
import re
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
    ('@CHOOSE_MODE@','MG_Backend/DirectVulkan/Renderer/SwapchainObject.cpp','    VkPresentModeKHR SwapchainObject::ChooseSwapchainPresentMode('),
    ('@RENDERER_INTERVAL@','MG_Backend/DirectVulkan/Renderer/VulkanRenderer.cpp','    void VulkanRenderer::SetSwapInterval('),
    ('@RETARGET@','MG_Backend/DirectVulkan/Renderer/VulkanRenderer.cpp','    Bool VulkanRenderer::RetargetOhosSurface('),
    ('@DIRECT_INTERVAL@','MG_Backend/DirectVulkan/DirectVulkan.cpp','    void SetSwapInterval('),
    ('@BACKEND_INTERVAL@','MG_Backend/BackendObject.cpp','    void BackendObject::SetEGLSwapInterval('),
    ('@BACKEND_SWAP@','MG_Backend/BackendObject.cpp','    PresentationResult BackendObject::SwapEGLBuffers('),
    ('@EGL_SWAP@','MG_Impl/EGLImpl/EGLImpl.cpp','    EGLBoolean SwapBuffers('),
    ('@SEQUENCE@','MG_Impl/EGLImpl/EGLImpl.cpp','    std::uint64_t PresentedSequence()')]:
    source=(module/path).read_text(encoding='utf-8')
    template=template.replace(token,extract.block(source,source.index(signature)))

# 默认排序同样从真实头文件取，不能用夹具自行重写的排名掩盖上游行为变化。
header=(module/'MG_Backend/DirectVulkan/Renderer/SwapchainObject.h').read_text(encoding='utf-8')
ranking=re.search(r'static constexpr VkPresentModeKHR s_desiredPresentModes\[\]\s*\{[^}]+\};',header).group()
template=template.replace('@RANKING@',ranking)
template=template.replace('@ROOT@',root.as_posix())
with workspace_temporary_directory(prefix='amcl-mobilegl-present-') as temporary:
    source=Path(temporary)/'test.cpp';source.write_text(template,encoding='utf-8')
    binary=Path(temporary)/('test.exe' if os.name=='nt' else 'test')
    compile_cpp(source,binary,standard='c++20');subprocess.run([str(binary)],check=True,timeout=30)
    # 恢复“调用完即成功”的旧语义必须被相同跨层用例击穿，不用另一份模型当反控。
    needle='return backendFunctions.Present();'
    assert template.count(needle)==1
    source.write_text(template.replace(needle,'(void)backendFunctions.Present(); return {PresentationStatus::Presented,true,0};'),encoding='utf-8')
    compile_cpp(source,binary,standard='c++20')
    rejected=subprocess.run([str(binary)],capture_output=True,text=True,timeout=30)
    assert rejected.returncode!=0 and 'PresentedSequence()' in rejected.stderr,rejected
    print('PASS: unconditional-success backend negative control rejected')
    # 撤回OHOS切换资格更新后，pbuffer会错误沿用窗口VSync；必须由相同真实retarget用例拒绝。
    needle='m_presentsToAppWindow = window != NativeWindowType{};'
    assert template.count(needle)==1
    source.write_text(template.replace(needle,'/* negative: retain old window classification */'),encoding='utf-8')
    compile_cpp(source,binary,standard='c++20')
    rejected=subprocess.run([str(binary)],capture_output=True,text=True,timeout=30)
    assert rejected.returncode!=0 and 'm_presentsToAppWindow' in rejected.stderr,rejected
    print('PASS: stale OHOS window/pbuffer classification negative control rejected')
