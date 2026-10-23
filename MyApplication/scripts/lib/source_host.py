"""旧平台轨迹夹具的真实 neutral Source/Core/bridge 构建闭包。

这里只装配生产 TU 和录制运输出口；不复制 registry/ledger/router、Source 准入或预算算法。
"""
from pathlib import Path
import os
import subprocess
from .host_cpp import find_host_cmake, configure_host_cmake

def source_dependencies(cpp):
    """Source 唯一实现及真实 Core/look/control/bridge；typed 设备链由专项完整后端门另外覆盖。"""
    return [cpp/name for name in [
        'input/source/source_control.cpp','platform/input_ledger.cpp','platform/external_held_registry.cpp',
        'platform/external_held_edge_router.cpp','platform/legacy_output_runtime.cpp','platform/legacy_physical_edge_router.cpp',
        # Core 的真实 L2 held reader 使用生产键码 mapper；不能以假 mapper 或 weak 缺席绕过新强依赖。
        'input/input_state_core.cpp','input/adapters/backend_keymaps.cpp','input/amcl_input_host_descriptor.cpp','input/input_interaction_order.cpp',
        'input/delivery/control_delivery.cpp','input/delivery/look_execution.cpp','platform/look_delta_math.cpp',
        'platform/look_pipeline_stats.cpp','glfw/input_bridge_ohos.c','input/adapters/lwjgl2_event_translate.cpp',
        'platform/physical_wheel_quantizer.cpp','tests/host/backend_input_bridge_host_stub.cpp']]

def compile_source_fixture(source, binary, cpp, extra_sources=()):
    """真实桥在同一宿主目标编为 C++；保既有 host 链接名，目标日志交调用方保留。"""
    source=Path(source);binary=Path(binary);work=source.parent; build=work/'source-build'
    cmake=find_host_cmake()
    paths=' '.join('"'+p.as_posix()+'"' for p in [source,*source_dependencies(cpp),*extra_sources])
    text='cmake_minimum_required(VERSION 3.20)\nproject(source_platform_fixture LANGUAGES CXX)\n'
    text+='set_source_files_properties("'+(cpp/'glfw/input_bridge_ohos.c').as_posix()+'" PROPERTIES LANGUAGE CXX)\n'
    text+='add_executable(source_fixture '+paths+')\n'
    text+='target_compile_features(source_fixture PRIVATE cxx_std_17)\n'
    # 真实descriptor在POSIX也核动态getter身份；宿主EXE须导出原符号，不能靠本地假表绕过。
    text+='set_target_properties(source_fixture PROPERTIES ENABLE_EXPORTS ON)\n'
    text+='target_compile_definitions(source_fixture PRIVATE NOMINMAX AMCL_INPUT_HOST_EXPORTS AMCL_CONTROL_DELIVERY_HOST_TESTING AMCL_INPUT_BRIDGE_HOST_TESTING AMCL_DESKTOP_EVENT_BRIDGE=1 _CRT_SECURE_NO_WARNINGS)\n'
    text+='target_include_directories(source_fixture PRIVATE "'+cpp.as_posix()+'" "'+(cpp/'tests/host/stubs').as_posix()+'")\n'
    text+='if(MSVC)\n target_compile_options(source_fixture PRIVATE /utf-8)\nelse()\n target_link_libraries(source_fixture PRIVATE dl pthread)\nendif()\n'
    (work/'CMakeLists.txt').write_text(text,encoding='utf-8')
    if not (build/'CMakeCache.txt').exists():configure_host_cmake(cmake,work,build)
    subprocess.run([cmake,'--build',str(build),'--config','Release'],check=True)
    produced=build/('Release/source_fixture.exe' if os.name=='nt' else 'source_fixture')
    # 调用者原二进制路径只是自己的测试入口；同时保留链接器赋予的执行位，不能只复制字节。
    # POSIX的copyfile会产生不可执行普通文件，Windows扩展名行为不能代证真实Linux执行。
    import shutil
    shutil.copy2(produced,binary)
    if os.name!='nt' and not os.access(binary,os.X_OK):
        raise RuntimeError('Copied host fixture is not executable: '+str(binary))

def source_recording_prefix(cpp):
    """使用真实 bridge Pump 的 key/button 回调录值；初始化真实 Core、Source 与消费者身份。
    recordSourceEdge 由原轨迹夹具提供，记录器不维护任何来源 held 集合。
    """
    return '\n#include "'+(cpp/'platform/source_control_client.h').as_posix()+'"\n'+r'''
#include "input/amcl_input_api.h"
#include "input/amcl_input_host_descriptor.h"
void inputBridge_setGrabState(int);int inputBridge_setInputReady(int);
void inputBridge_glfwSetActive(void*,int);void inputBridge_glfwSetTargetV1(uint64_t,uint64_t,uint64_t);
extern "C" int inputBridge_configureMenuCursorConsumerV1(uint32_t,uint64_t);
void inputBridge_setKeyCallback(void(*)(void*,int,int,int,int));
void inputBridge_setMouseButtonCallback(void(*)(void*,int,int,int));
void inputBridgeStartPumping();void inputBridgePumpEvents(void*);void inputBridgeStopPumping();
void recordSourceEdge(const amcl::input::Output&,int);
static bool sourceFixtureReady=false;static int sourceFixtureWindow=0;
static void sourceFixtureKey(void*,int code,int,int action,int){recordSourceEdge({amcl::input::OutputKind::Key,code},action);}
static void sourceFixtureMouse(void*,int code,int action,int){recordSourceEdge({amcl::input::OutputKind::Mouse,code},action);}
extern "C" void amclDesktopNotifyInput(){
    if(!sourceFixtureReady)return;
    static thread_local bool pumping=false;if(pumping)return;pumping=true;
    inputBridgeStartPumping();inputBridgePumpEvents(&sourceFixtureWindow);inputBridgeStopPumping();pumping=false;
}
static bool initializeSourceFixture(){
    const auto* core=amclInputGetHostApiV1();if(amclInputHostDescriptorPublishV1(core)!=0)return false;
    amclSourceControlPublishV1();if(!amclSourceControlPrepareV1())return false;
    uint64_t epoch=0;if(core->beginSession(&epoch)!=0||core->publishFocus(1)!=0)return false;
    AmclInputSurfacePayload surface{};surface.active=1;surface.widthPx=1000;surface.heightPx=1000;surface.density=1;
    surface.validFields=AMCL_INPUT_SURFACE_FIELD_ALL;surface.publicationGeneration=1;if(core->publishSurface(&surface)!=0)return false;
    AmclInputEvent context{};context.header.abiVersion=1;context.header.structSize=sizeof(context);
    context.header.eventType=AMCL_INPUT_EVENT_SURFACE_CONTEXT_CHANGED;context.header.source=AMCL_INPUT_SOURCE_SYNTHETIC;
    context.payload.surfaceContext.generation=1;context.payload.surfaceContext.windowId=42;context.payload.surfaceContext.displayId=1;
    context.payload.surfaceContext.widthPx=1000;context.payload.surfaceContext.heightPx=1000;context.payload.surfaceContext.density=1;
    context.payload.surfaceContext.validFields=AMCL_INPUT_SURFACE_CONTEXT_FIELD_WINDOW|AMCL_INPUT_SURFACE_CONTEXT_FIELD_DISPLAY|
        AMCL_INPUT_SURFACE_CONTEXT_FIELD_RECT|AMCL_INPUT_SURFACE_CONTEXT_FIELD_DENSITY|AMCL_INPUT_SURFACE_CONTEXT_FIELD_TRANSFORM;
    if(core->submitEvent(&context)!=0||inputBridge_configureMenuCursorConsumerV1(1,1)!=1)return false;
    inputBridge_setInputReady(1);inputBridge_glfwSetTargetV1(reinterpret_cast<uint64_t>(&sourceFixtureWindow),1,42);
    inputBridge_glfwSetActive(&sourceFixtureWindow,1);inputBridge_setKeyCallback(sourceFixtureKey);inputBridge_setMouseButtonCallback(sourceFixtureMouse);
    inputBridge_setGrabState(1);sourceFixtureReady=true;return true;
}
'''
