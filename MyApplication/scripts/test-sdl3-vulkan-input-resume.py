"""逐字编译现役SDL同窗采纳与资格函数，覆盖真实几何重发布序列和撤回修正的负对照。"""
from pathlib import Path
import importlib.util
import os
import subprocess
from lib.host_cpp import compile_cpp
from lib.workspace_paths import temporary_directory

root=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('sdl_resume_extract',root/'scripts/generate-desktop-review-tests.py')
extract=importlib.util.module_from_spec(spec)
spec.loader.exec_module(extract)
source=extract.patch_sources()['SDL_openharmonyamcl.c']
names=['OPENHARMONY_AMCL_PublishTouchInputTarget','OPENHARMONY_AMCL_SyncVulkanWindow','OPENHARMONY_AMCL_SyncLiveWindow',
       'OPENHARMONY_AMCL_HostIsForeground','OPENHARMONY_AMCL_UpdatePresentedForeground']
production='\n\n'.join(extract.function(source,name) for name in names)
template=(root/'entry/src/main/cpp/tests/host/sdl_vulkan_input_resume.cpp.in').read_text(encoding='utf8')
with temporary_directory(prefix='sdl-vulkan-resume-') as output:
    path=Path(output)/'resume.cpp';binary=Path(output)/('resume.exe' if os.name=='nt' else 'resume')
    path.write_text(template.replace('@PRODUCTION@',production),encoding='utf8')
    compile_cpp(path,binary,includes=[root/'entry/src/main/cpp/glfw'])
    subprocess.run([str(binary)],check=True,timeout=30)
    # 移除Vulkan分支后重现旧P1；不能靠一个永远通过的边界替身掩盖生产函数未参与。
    old='(void)OPENHARMONY_AMCL_SyncVulkanWindow(window, data);'
    assert production.count(old)==1
    wrong=production.replace(old,'(void)window; /* 撤回采纳，保留原资格检查。 */',1)
    path.write_text(template.replace('@PRODUCTION@',wrong),encoding='utf8')
    compile_cpp(path,binary,includes=[root/'entry/src/main/cpp/glfw'])
    result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=30)
    assert result.returncode!=0 and 'CHECK line' in result.stderr
    print('PASS negative control: removing Vulkan metadata adoption reproduces input loss')
