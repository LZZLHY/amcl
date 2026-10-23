"""执行生产WSI创建/呈现/销毁、公共观测owner及真实输入呈现订阅者。

仅驱动、设备句柄、窗口只读查询和输入owner发现使用替身；跨层路由正文从当前源码
逐字提取。用同一程序验证GLFW/SDL、失活输入、失败/未知swapchain和退休后的行为。
"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import importlib.util
import os
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
if os.name == 'nt':
    script = subprocess.check_output(['wsl', '-d', 'Ubuntu', '--exec', 'wslpath', '-a', Path(__file__).resolve().as_posix()], text=True).strip()
    subprocess.run(['wsl', '-d', 'Ubuntu', '--exec', 'python3', script], check=True, timeout=90)
    sys.exit(0)
spec = importlib.util.spec_from_file_location('extract', root / 'scripts/generate-desktop-review-tests.py')
extract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(extract)
bridge = (root / 'entry/src/main/cpp/glfw/input_bridge_ohos.c').read_text(encoding='utf-8')
wsi = (root / 'entry/src/main/cpp/platform/vulkan_wsi.cpp').read_text(encoding='utf-8')
# 呈现函数现在调用生产诊断宏。连同完整续行定义和下方真实策略头一起消费，
# 避免宿主夹具漏声明，也不能用空宏绕过生产的参数求值与错误日志分支。
trace_starts = list(re.finditer(r'^#define AMCL_WSI_TRACE\(', wsi, re.M))
if len(trace_starts) != 1:
    raise ValueError('Production WSI trace macro must have exactly one definition')
trace_lines = []
for line in wsi[trace_starts[0].start():].splitlines(keepends=True):
    trace_lines.append(line)
    if not line.rstrip('\r\n').endswith('\\'):
        break
else:
    raise ValueError('Production WSI trace macro has an unterminated continuation')
trace_macro = ''.join(trace_lines)
# 采用真实生产state类型；只给可观测边界提供空初态，不能伪造几个字段代替target合同。
def state_type(name):
    match = re.search(r'typedef struct\s*\{[^{}]*\}\s*' + re.escape(name) + r';', bridge)
    if not match:
        raise ValueError('Production input presentation state missing: ' + name)
    return match[0]
bridge_functions = [extract.block(bridge, bridge.index(signature)) for signature in [
    'static void refreshGlfwPresentationState(void) {',
    'static void advanceGlfwPresentation(uint64_t window, uint64_t generation) {',
    'static void advanceSdlPresentation(uint64_t window, uint64_t generation) {',
    'static void registerGraphicsPresentationSinks(void) {',
    'static void publishGraphicsPresentation(const char* provider) {',
    'JNIEXPORT void inputBridge_notifyFramePresented(void) {',
    'void inputBridge_sdlNotifyFramePresented(void) {']]
wsi_functions = [extract.block(wsi, wsi.index(signature)) for signature in [
    'void notifyFramePresented(const char* provider, uint64_t window, uint64_t generation) {',
    'VKAPI_ATTR VkResult VKAPI_CALL createSwapchain(VkDevice device, const VkSwapchainCreateInfoKHR* requested,',
    'VKAPI_ATTR void VKAPI_CALL destroySwapchain(VkDevice device, VkSwapchainKHR swapchain,',
    'VKAPI_ATTR VkResult VKAPI_CALL queuePresent(VkQueue queue, const VkPresentInfoKHR* info) {']]
prefix = r'''
#include "@ROOT@/entry/src/main/cpp/platform/graphics_observation.cpp"
#include "@ROOT@/entry/src/main/cpp/input/delivery/pointer_transaction.h"
#include "@ROOT@/entry/src/main/cpp/platform/vulkan_wsi_diagnostics.h"
#include "@ROOT@/entry/src/main/cpp/utils/product_diagnostics.h"
#include <map>
#include <cassert>
#include <iostream>
#include <pthread.h>
namespace amcl::graphics {
const GraphicsRuntimeBinding* BoundGraphicsRuntime() { return nullptr; }
std::string GraphicsFeaturesJson(const GraphicsRuntimeBinding&) { return "null"; }
}
extern "C" uint64_t amclWindowHostPeekGeneration() { return 7; }
#define JNIEXPORT
using atomic_uint_fast64_t=std::atomic<uint_fast64_t>;
using std::atomic_load_explicit; using std::atomic_store_explicit;
using std::memory_order_acquire; using std::memory_order_release;
struct InputBridgeInstanceV1 { void(*notifyFramePresented)(); void(*sdlNotifyFramePresented)(); };
const InputBridgeInstanceV1* bridgeDelegate() { return nullptr; }
std::atomic<bool> g_sdlActive{false};
pthread_mutex_t g_sdlMenuMutex=PTHREAD_MUTEX_INITIALIZER;
@LEFT_CONTRIBUTION@
@SDL_MENU_STATE@
SDLMenuPointerState g_sdlMenuState{};
@GLFW_PRESENTATION_CLOCK@
pthread_mutex_t g_glfwPresentationMutex=PTHREAD_MUTEX_INITIALIZER;
GlfwPresentationClock g_glfwPresentationClock{};
uint64_t g_presentSerial=0;
// 实际目标准入在完整bridge组合回归验证；此例专门串起WSI→公共owner→真实订阅者。
bool g_l3TargetIdentityRequired=false,g_sdlTargetIdentityRequired=false;
uint64_t g_l3InputTargetWindow=0,g_l3WsiPresentationIdentity=0;
uint64_t g_sdlInputTargetWindow=0,g_sdlWsiPresentationIdentity=0;
uint64_t g_glfwPresentedWindow=0,g_glfwPresentedGeneration=0,g_glfwPresentedIdentity=0;
AmclPointerTransaction g_glfwPointer{};
uint64_t g_menuPresentedWindow=0,g_menuPresentedGeneration=0,g_menuPresentedIdentity=0;
'''
driver = r'''
namespace wsi_fixture {
#define VKAPI_ATTR
#define VKAPI_CALL
using VkQueue=uintptr_t; using VkDevice=uintptr_t; using VkSwapchainKHR=uintptr_t; using VkResult=int;
struct VkAllocationCallbacks {};
struct VkSwapchainCreateInfoKHR { uintptr_t surface; };
struct VkPresentInfoKHR { uint32_t swapchainCount; const VkSwapchainKHR* pSwapchains; VkResult* pResults; };
constexpr VkResult VK_SUCCESS=0, VK_SUBOPTIMAL_KHR=1000001003, VK_ERROR_DEVICE_LOST=-4;
constexpr uintptr_t VK_NULL_HANDLE=0;
using PFN_vkQueuePresentKHR=VkResult(*)(VkQueue,const VkPresentInfoKHR*);
using PFN_vkCreateSwapchainKHR=VkResult(*)(VkDevice,const VkSwapchainCreateInfoKHR*,const VkAllocationCallbacks*,VkSwapchainKHR*);
using PFN_vkDestroySwapchainKHR=void(*)(VkDevice,VkSwapchainKHR,const VkAllocationCallbacks*);
constexpr VkResult VK_ERROR_EXTENSION_NOT_PRESENT=-7;
struct SurfaceRecord { uint64_t windowId, generation; const char* provider; };
struct SwapchainRecord { VkDevice device; uint64_t windowId, generation; const char* provider; };
struct Runtime { std::mutex mutex; std::map<uint64_t,VkDevice> queues{{1,2}};
    std::map<uint64_t,SurfaceRecord> surfaces;
    std::map<uint64_t,SwapchainRecord> swapchains;
    uint64_t presents=0,swapchainsCreated=0,swapchainsDestroyed=0; } state;
Runtime& runtime() { return state; }
uint64_t bits(uintptr_t value) { return value; }
uint64_t pid() { return getpid(); }
VkResult result=VK_SUCCESS;
VkResult rawPresent(VkQueue, const VkPresentInfoKHR*) { return result; }
VkResult rawCreate(VkDevice, const VkSwapchainCreateInfoKHR* request, const VkAllocationCallbacks*, VkSwapchainKHR* out) {
    *out=request->surface+100; return VK_SUCCESS;
}
void rawDestroy(VkDevice, VkSwapchainKHR,const VkAllocationCallbacks*) {}
void* resolveDevice(VkDevice, const char* name) {
    if(!std::strcmp(name,"vkQueuePresentKHR")) return reinterpret_cast<void*>(&rawPresent);
    if(!std::strcmp(name,"vkCreateSwapchainKHR")) return reinterpret_cast<void*>(&rawCreate);
    if(!std::strcmp(name,"vkDestroySwapchainKHR")) return reinterpret_cast<void*>(&rawDestroy);
    return nullptr;
}
auto deviceProcFor(VkDevice) { return &resolveDevice; }
void emitWsiLog(bool, const char*, ...) {}
VkResult queryAndAdaptSwapchain(VkDevice,const VkSwapchainCreateInfoKHR* from,VkSwapchainCreateInfoKHR& to,uint32_t&,uint32_t&) {
    to=*from;return VK_SUCCESS;
}
'''
main = r'''
}
int main() {
    using namespace wsi_fixture;
    assert(amclGraphicsPublishObserverV1()); registerGraphicsPresentationSinks();
    state.surfaces[10]={77,7,"GLFW"};
    VkSwapchainCreateInfoKHR request{10};VkSwapchainKHR chain=0;
    assert(createSwapchain(2,&request,nullptr,&chain)==VK_SUCCESS);
    VkPresentInfoKHR info{1,&chain,nullptr};
    for(int i=0;i<3;++i) assert(queuePresent(1,&info)==VK_SUCCESS);
    refreshGlfwPresentationState();
    assert(g_presentSerial==3 && g_sdlMenuState.presentSerial==0 && local().totalFrames==3);
    assert(g_glfwPresentedWindow==77 && g_glfwPresentedGeneration==7 && g_glfwPresentedIdentity==77);
    result=VK_ERROR_DEVICE_LOST;queuePresent(1,&info);
    refreshGlfwPresentationState();
    assert(g_presentSerial==3 && local().totalFrames==3);
    result=VK_SUCCESS;destroySwapchain(2,chain,nullptr);queuePresent(1,&info);
    refreshGlfwPresentationState();
    assert(g_presentSerial==3 && local().totalFrames==3);
    state.surfaces[20]={88,8,"SDL3"};request.surface=20;
    assert(createSwapchain(2,&request,nullptr,&chain)==VK_SUCCESS);
    queuePresent(1,&info);
    assert(g_sdlMenuState.presentSerial==0 && local().totalFrames==4); // 输入失活不抹去图形事实。
    g_sdlActive=true;result=VK_SUBOPTIMAL_KHR;queuePresent(1,&info);
    assert(g_presentSerial==3 && g_sdlMenuState.presentSerial==1 && local().totalFrames==5);
    assert(g_sdlMenuState.presentedWindow==88 && g_sdlMenuState.presentedGeneration==8 && g_sdlMenuState.presentedIdentity==88);
    result=VK_ERROR_DEVICE_LOST;VkResult item=VK_SUCCESS;info.pResults=&item;queuePresent(1,&info);
    assert(g_sdlMenuState.presentSerial==2 && local().totalFrames==6); // 多项提交保留逐swapchain结果。
    item=VK_ERROR_DEVICE_LOST;result=VK_SUCCESS;queuePresent(1,&info);
    assert(g_sdlMenuState.presentSerial==2 && local().totalFrames==6);
    inputBridge_notifyFramePresented();inputBridge_sdlNotifyFramePresented();
    refreshGlfwPresentationState();
    // 已知GLFW真实身份后匿名帧不能替该target贡献准入；图形事实仍由公共owner记录。
    assert(g_presentSerial==3 && g_sdlMenuState.presentSerial==3 && local().totalFrames==8);
    std::cout<<"Vulkan presentation bridge PASS: production swapchain identity, observer, GLFW/SDL input, inactive input, failure/retirement, per-item results and legacy GL callbacks\n";
}
'''
code = prefix.replace('@ROOT@', root.as_posix()).replace('@LEFT_CONTRIBUTION@', state_type('LegacyLeftContribution'))
code = code.replace('@SDL_MENU_STATE@', state_type('SDLMenuPointerState'))
code = code.replace('@GLFW_PRESENTATION_CLOCK@', state_type('GlfwPresentationClock'))
code += '\n'.join(bridge_functions) + driver + trace_macro + '\n'.join(wsi_functions) + main
with workspace_temporary_directory(prefix='amcl-present-bridge-') as temporary:
    source=Path(temporary)/'test.cpp';source.write_text(code,encoding='utf-8')
    # 缺省关闭和显式开发 trace 共用同一生产呈现正文；两种模式都须保持帧数、
    # swapchain 身份、失败/退休以及 GLFW/SDL 订阅行为，不能只验证一种宏配置能编译。
    for mask in [None, 513]:
        binary=Path(temporary)/('test-'+str(mask))
        defines=[] if mask is None else ['-DAMCL_DIAGNOSTICS_MASK='+str(mask)]
        subprocess.run(['g++','-std=c++17','-pthread',*defines,'-I'+str(root/'prebuilt/khronos-egl-headers'),str(source),'-o',str(binary)],check=True,timeout=60)
        subprocess.run([str(binary)],check=True,timeout=20)
