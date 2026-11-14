"""从现役SDL patch series提取生产上下文生命周期，与公共资格实现共同执行。"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import importlib.util
import os
import subprocess
import sys
import tempfile

root=Path(__file__).resolve().parent.parent
if os.name=='nt':
    script=subprocess.check_output(['wsl','-d','Ubuntu','--exec','wslpath','-a',Path(__file__).resolve().as_posix()],text=True).strip()
    subprocess.run(['wsl','-d','Ubuntu','--exec','python3',script],check=True,timeout=120);sys.exit(0)
spec=importlib.util.spec_from_file_location('extract',root/'scripts/generate-desktop-review-tests.py')
extract=importlib.util.module_from_spec(spec);spec.loader.exec_module(extract)
sources=extract.patch_sources()
code=(root/'entry/src/main/cpp/tests/host/sdl_graphics_context.cpp.in').read_text(encoding='utf-8').replace('@ROOT@',root.as_posix())
for token,file,function in [('@EGL_DESTROY@','SDL_egl.c','SDL_EGL_DestroyContext'),
    ('@SDL_CREATE@','SDL_openharmonyopengl.c','OPENHARMONY_GLES_CreateContext'),
    ('@SDL_DESTROY@','SDL_openharmonyopengl.c','OPENHARMONY_GLES_DestroyContext')]:
    code=code.replace(token,extract.function(sources[file],function))
with workspace_temporary_directory(prefix='amcl-sdl-context-') as temporary:
    source=Path(temporary)/'test.cpp';source.write_text(code,encoding='utf-8');binary=Path(temporary)/'test'
    subprocess.run(['g++','-std=c++17','-pthread','-I'+str(root/'prebuilt/khronos-egl-headers'),str(source),'-o',str(binary)],check=True,timeout=60)
    subprocess.run([str(binary)],check=True,timeout=30)
    # 同一现役驱动包装区分EGL返回和实际呈现，辅助面不通知，后续acquire失败仍保留已呈现事实。
    observed=extract.function(sources['SDL_openharmonyopengl.c'],'OPENHARMONY_AMCL_ObservedSwap')
    prefix=r'''
#include "@ROOT@/entry/src/main/cpp/platform/graphics_runtime_abi.h"
#include <cstddef>
#include <stdexcept>
#include <iostream>
using Uint64=uint64_t;using EGLint=int;
#define OPENHARMONY_WINDOW_PRESENTED 0
#define EGL_WIDTH 0x3057
#define EGL_HEIGHT 0x3056
#define SDL_LOG_CATEGORY_VIDEO 1
struct Presentation {uint32_t flags=0;};
struct SDL_WindowData {int role=0;void* egl_surface=nullptr;bool amcl_last_swap_presented=false;Presentation presentation;};
struct SDL_VideoData {int presented_notify=0,presented_swap_success=0;};
struct EglData {void* egl_display=nullptr;bool(*eglQuerySurface)(void*,void*,int,int*);int(*eglGetError)();};
struct SDL_VideoDevice {SDL_VideoData* internal;EglData* egl_data=nullptr;};
bool queryOk=true;int observedWidth=-1,observedHeight=-1;uint32_t observedKind=99;int warnings=0;
uint32_t AMCL_PresentationGeometryFlags(Presentation* p){return p->flags;}
void AMCL_PresentationObserveDrawable(Presentation*,int width,int height,uint32_t kind){observedWidth=width;observedHeight=height;observedKind=kind;}
bool querySurface(void*,void*,int field,int* result){*result=field==EGL_WIDTH?480:270;return queryOk;}
int queryError(){return 0x300d;}
void SDL_LogWarn(int,const char*,int){++warnings;}
struct AMCL_GraphicsObserverV1 {void(*swapped)(const char*,uint64_t,int,uint32_t);};
uint64_t sequence=0;bool result=true,advance=true;int input=0,swaps=0;
AmclGraphicsRuntimeV1 runtime{};
void swapped(const char*,uint64_t,int,uint32_t){++swaps;}
AMCL_GraphicsObserverV1 observer{swapped};
const AmclGraphicsRuntimeV1* AMCL_GraphicsRuntime(){return &runtime;}
const AMCL_GraphicsObserverV1* AMCL_GraphicsObserver(){return &observer;}
bool AMCL_GraphicsSamplingEnabled(const AMCL_GraphicsObserverV1*){return false;}
Uint64 SDL_GetTicksNS(){return 0;}
bool SDL_EGL_SwapBuffersWithError(SDL_VideoDevice*,void*,int* error){if(advance)++sequence;*error=result?0:0x300e;return result;}
void OPENHARMONY_AMCL_NotifyFramePresented(){++input;}
#define CHECK(value) do{if(!(value))throw std::runtime_error(#value);}while(0)
'''.replace('@ROOT@',root.as_posix())
    main=r'''
int main()try{
    runtime.structSize=sizeof(runtime);runtime.presentSequence=[]()->uint64_t{return sequence;};
    SDL_VideoData video;SDL_VideoDevice device{&video};SDL_WindowData window;int error=0;
    CHECK(OPENHARMONY_AMCL_ObservedSwap(&device,&window,&error) && input==1);
    advance=false;CHECK(OPENHARMONY_AMCL_ObservedSwap(&device,&window,&error) && input==1);
    result=false;CHECK(!OPENHARMONY_AMCL_ObservedSwap(&device,&window,&error) && input==1);
    advance=true;CHECK(!OPENHARMONY_AMCL_ObservedSwap(&device,&window,&error) && input==2);
    result=true;window.role=1;CHECK(OPENHARMONY_AMCL_ObservedSwap(&device,&window,&error) && input==2);
    window.role=0;advance=false;runtime.presentSequence=nullptr;
    CHECK(OPENHARMONY_AMCL_ObservedSwap(&device,&window,&error) && input==3);
    CHECK(video.presented_notify==3 && video.presented_swap_success==3 && swaps==5);
    // 系统查询口显式报告真实drawable；失败必须传递未知值，不能沿用上次尺寸。
    EglData egl{nullptr,&querySurface,&queryError};device.egl_data=&egl;window.presentation.flags=2;
    CHECK(OPENHARMONY_AMCL_ObservedSwap(&device,&window,&error));
    CHECK(observedWidth==480 && observedHeight==270 && observedKind==1);
    queryOk=false;CHECK(OPENHARMONY_AMCL_ObservedSwap(&device,&window,&error));
    CHECK(observedWidth==0 && observedHeight==0 && observedKind==0 && warnings==1);
    std::cout<<"SDL present evidence PASS: actual production swap wrapper, deferred/auxiliary/failure exclusion and post-present failure\n";
    return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
'''
    source.write_text(prefix+observed+main,encoding='utf-8')
    subprocess.run(['g++','-std=c++17',str(source),'-o',str(binary)],check=True,timeout=60)
    subprocess.run([str(binary)],check=True,timeout=30)
    wrong=observed.replace('verify ? runtime->presentSequence() > before_present : result','result')
    assert wrong!=observed
    source.write_text(prefix+wrong+main,encoding='utf-8')
    subprocess.run(['g++','-std=c++17',str(source),'-o',str(binary)],check=True,timeout=60)
    rejected=subprocess.run([str(binary)],capture_output=True,text=True,timeout=30)
    assert rejected.returncode!=0 and 'input==1' in rejected.stderr,rejected
    print('PASS: SDL EGL-success-only false-present negative control rejected')
