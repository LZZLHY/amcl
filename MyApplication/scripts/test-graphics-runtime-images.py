"""实际装载两份中立运行时ELF，验证同PID唯一owner/绑定；GPU边界使用明确的最小假库。

测试不以RTLD全局符号插入伪造成功：两份库均Bsymbolic且函数地址必须不同。Windows经WSL
执行真实dlopen/fork，临时目录由TemporaryDirectory管理，绝不写入产品的依赖或游戏目录。
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import importlib.util

root = Path(__file__).resolve().parent.parent
if os.name == 'nt':
    script = subprocess.check_output(['wsl', '-d', 'Ubuntu', '--exec', 'wslpath', '-a', Path(__file__).resolve().as_posix()], text=True).strip()
    subprocess.run(['wsl', '-d', 'Ubuntu', '--exec', 'python3', script], check=True, timeout=180)
    sys.exit(0)

with tempfile.TemporaryDirectory(prefix='amcl-runtime-images-') as temp:
    directory = Path(temp)
    # 编译补丁按顺序重建的真实SDL消费者头；不手抄PID/版本/缓存判定。
    spec = importlib.util.spec_from_file_location('recipe', root/'scripts/generate-desktop-review-tests.py')
    recipe = importlib.util.module_from_spec(spec); spec.loader.exec_module(recipe)
    reconstructed = recipe.patch_sources()
    canonical = (root/'entry/src/main/cpp/platform/graphics_runtime_abi.h').read_text(encoding='utf-8')
    assert reconstructed['graphics_runtime_abi.h'].strip() == canonical.strip(), 'SDL public runtime ABI mirror differs'
    for header in ['graphics_runtime_abi.h', 'graphics_context_abi.h', 'SDL_amclgraphicsruntime.h']:
        (directory/header).write_text(reconstructed[header], encoding='utf-8')
    provider = root / 'entry/src/main/cpp/tests/host/runtime_binding_stubs/provider_library.cpp'
    subprocess.run(['g++', '-std=c++17', '-shared', '-fPIC', '-pthread', '-Wl,-Bsymbolic-functions',
        '-I'+str(root/'prebuilt/khronos-egl-headers'), str(provider), '-o', str(directory/'libmobilegl.so')], check=True)
    window_stub = directory/'window_boundary.cpp'
    window_stub.write_text('#include <cstdint>\nextern "C" uint64_t amclWindowHostPeekGeneration() { return 1; }\n', encoding='utf-8')
    # 测试专用导出只返回数值/执行请求，用于证明本地C++视图不借用远端private对象。
    view = directory/'view_boundary.cpp'
    view.write_text('#include "' + (root/'entry/src/main/cpp/platform/graphics_runtime_binding.h').as_posix() + '"\n' + r'''
extern "C" __attribute__((visibility("default"))) uintptr_t testView() { return reinterpret_cast<uintptr_t>(amcl::graphics::BoundGraphicsRuntime()); }
extern "C" __attribute__((visibility("default"))) int testPrivateState() { const auto* r=amcl::graphics::BoundGraphicsRuntime(); return r && r->features ? 1:0; }
extern "C" __attribute__((visibility("default"))) int testContext(AmclGraphicsContextStateV1* state,int destroy) {
    const auto* r=amcl::graphics::BoundGraphicsRuntime(); std::string error;
    const amcl::desktop::ContextRequest request{3,2,0x00032001,true};
    return r && r->contextOperations && (destroy ? r->contextOperations->destroy(*r,*state,7,error) : r->contextOperations->create(*r,*state,request,7,error));
}
''', encoding='utf-8')
    sources = [root / 'entry/src/main/cpp/platform/graphics_runtime_binding.cpp', root / 'entry/src/main/cpp/platform/graphics_egl_context.cpp',
        root / 'entry/src/main/cpp/platform/graphics_features.cpp', root / 'entry/src/main/cpp/platform/graphics_gl_lookup.cpp',
        root / 'entry/src/main/cpp/platform/graphics_observation.cpp', window_stub, view]
    first = directory / 'runtime-a.so'
    subprocess.run(['g++', '-std=c++17', '-shared', '-fPIC', '-fvisibility=hidden', '-pthread', '-Wl,-Bsymbolic-functions',
                    '-Wl,--no-undefined', '-I' + str(root / 'prebuilt/khronos-egl-headers'),
                    *map(str, sources), '-ldl', '-o', str(first)], check=True, timeout=90)
    shutil.copyfile(first, directory / 'runtime-b.so')
    harness = directory / 'main.cpp'
    harness.write_text(r'''
#include <cassert>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <iostream>
#include <thread>
#include <vector>
#include <sys/wait.h>
#include <unistd.h>
// SDL系统函数边界；下面直接包含补丁生成的生产解析器。
#define SDL_getenv_unsafe std::getenv
#define SDL_sscanf std::sscanf
#define SDL_strcmp std::strcmp
void* SDL_GetAtomicPointer(void* const* pointer) { return __atomic_load_n(pointer, __ATOMIC_ACQUIRE); }
void SDL_SetAtomicPointer(void** pointer, void* value) { __atomic_store_n(pointer, value, __ATOMIC_RELEASE); }
#include "SDL_amclgraphicsruntime.h"
int main(int argc, char** argv) {
    assert(argc == 3); unsetenv("AMCL_GRAPHICS_RUNTIME_SERVICE_V2");
    void* a = dlopen(argv[1],RTLD_NOW|RTLD_LOCAL); void* b = dlopen(argv[2],RTLD_NOW|RTLD_LOCAL);
    if (!a || !b) { std::cerr << dlerror() << '\n'; return 2; }
    // 本库是进程启动依赖，不能用同名EGL入口截获系统/UI的扩展查询。GLX查询仍由下方
    // LWJGL路径执行并核对地址；这里检查实际导出，不能以源码删除或visibility默认值代替。
    assert(!dlsym(a,"eglGetProcAddress") && !dlsym(b,"eglGetProcAddress"));
    using Bind=int(*)(const char*,const char*,char*,int); using Owner=uintptr_t(*)(); using Text=const char*(*)();
    auto ba=reinterpret_cast<Bind>(dlsym(a,"amclGraphicsBindRuntimeV1"));
    auto bb=reinterpret_cast<Bind>(dlsym(b,"amclGraphicsBindRuntimeV1"));
    auto oa=reinterpret_cast<Owner>(dlsym(a,"amclGraphicsRuntimeOwnerV1"));
    auto ob=reinterpret_cast<Owner>(dlsym(b,"amclGraphicsRuntimeOwnerV1"));
    auto pa=reinterpret_cast<Text>(dlsym(a,"amclGraphicsBoundProfileV1"));
    auto pb=reinterpret_cast<Text>(dlsym(b,"amclGraphicsBoundProfileV1"));
    assert(ba && bb && ba != bb && oa && ob && oa != ob && !oa() && !ob());
    std::vector<std::thread> threads;
    for (int i=0;i<16;++i) threads.emplace_back([=]{ char e[512]{}; assert((i%2?ba:bb)("mobilegl","OPENGL",e,sizeof(e))==1); });
    for(auto& thread:threads) thread.join();
    assert(oa()!=0 && oa()==ob() && std::strcmp(pa(),"mobilegl")==0 && std::strcmp(pb(),"mobilegl")==0);
    const auto* consumer = AMCL_GraphicsRuntime();
    assert(AMCL_GraphicsRuntimeRequired() && consumer && consumer->processId == static_cast<uint64_t>(getpid()));
    // SDL的冻结C表与Java namespace的GL查询入口必须返回完全相同的provider地址。
    using Proc=void*(*)(const char*);
    auto sdl=reinterpret_cast<Proc>(dlsym(a,"amclGraphicsGlProcV1"));
    auto lwjgl=reinterpret_cast<Proc>(dlsym(b,"glXGetProcAddress"));
    assert(sdl && lwjgl && sdl("glGetString") && sdl("glGetString")==lwjgl("glGetString"));
    assert(consumer->glProc("glGetString") == lwjgl("glGetString"));
    auto viewA=reinterpret_cast<Owner>(dlsym(a,"testView")), viewB=reinterpret_cast<Owner>(dlsym(b,"testView"));
    using Private=int(*)();
    auto privateA=reinterpret_cast<Private>(dlsym(a,"testPrivateState")), privateB=reinterpret_cast<Private>(dlsym(b,"testPrivateState"));
    assert(viewA && viewB && viewA()!=viewB() && privateA()+privateB()==1);
    using Context=int(*)(AmclGraphicsContextStateV1*,int);
    auto contextProxy=reinterpret_cast<Context>(dlsym(privateA()?b:a,"testContext"));
    AmclGraphicsContextStateV1 context{};context.width=640;context.height=480;context.nativeWindow=reinterpret_cast<void*>(9);
    assert(contextProxy && contextProxy(&context,0));
    assert(context.context && context.contextPermit && !consumer->reserveContext(nullptr));
    assert(consumer->inspectContext(context.display,context.config,context.context,context.surface,4,3,0x00032001));
    assert(contextProxy(&context,1) && !context.context && !context.contextPermit);

    // 两个真实映像并发发布观测也必须只有一个owner，不能各自得到“正确但分裂”的计数。
    using Publish=int(*)(); using Present=void(*)(const char*);
    auto publishA=reinterpret_cast<Publish>(dlsym(a,"amclGraphicsPublishObserverV1"));
    auto publishB=reinterpret_cast<Publish>(dlsym(b,"amclGraphicsPublishObserverV1"));
    auto presentA=reinterpret_cast<Present>(dlsym(a,"amclGraphicsPresentedV1"));
    auto presentB=reinterpret_cast<Present>(dlsym(b,"amclGraphicsPresentedV1"));
    auto jsonA=reinterpret_cast<Text>(dlsym(a,"amclGraphicsRuntimeJsonV1"));
    auto jsonB=reinterpret_cast<Text>(dlsym(b,"amclGraphicsRuntimeJsonV1"));
    threads.clear();
    for (int i=0;i<16;++i) threads.emplace_back([=]{ assert((i%2?publishA:publishB)()); for(int j=0;j<1000;++j) (i%2?presentA:presentB)("GLFW"); });
    for (auto& thread:threads) thread.join();
    // snapshot是同一owner的线程局部借用字符串；先复制，不能跨下一次调用比较悬空指针。
    const std::string firstJson=jsonA(), secondJson=jsonB();
    if (firstJson.find("\"presentCount\":16000") == std::string::npos || firstJson != secondJson)
        std::cerr << "observer A=" << firstJson << "\nobserver B=" << secondJson << '\n';
    assert(firstJson.find("\"presentCount\":16000") != std::string::npos && firstJson == secondJson);
    char error[512]{};
    assert(!bb("mobileglues","OPENGL",error,sizeof(error)) && std::strstr(error,"requires_restart"));
    const pid_t child=fork(); assert(child>=0);
    if(!child) {
        assert(!AMCL_GraphicsRuntime());
        assert(!oa() && !ob()); assert(!ba("mobilegl","OPENGL",error,sizeof(error)));
        assert(std::strstr(error,"inherited")); _exit(0);
    }
    int status=0; assert(waitpid(child,&status,0)==child && WIFEXITED(status) && WEXITSTATUS(status)==0);
    // 服务owner按进程寿命固定，测试也不提前dlclose其承载映像。
    std::cout << "Neutral runtime real ELF images PASS: distinct copies, one C owner, distinct local C++ views, forwarded context lifecycle, concurrent binding, fork refusal\n";
}
''', encoding='utf-8')
    binary = directory / 'test'
    subprocess.run(['g++', '-std=c++17', '-pthread', str(harness), '-ldl', '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(first), str(directory / 'runtime-b.so')], check=True, timeout=30)
