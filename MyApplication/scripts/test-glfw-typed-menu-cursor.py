"""组合执行实际typedAbsoluteSink、两种Scoped guard、RuntimeCommit/Route与生产neutral bridge。

验证current先提交、callback后才ACK，实际legacy receipt与typed出口一致，公共order和relative
混排，以及回调重建拒绝旧cookie。receipt直接抽生产wrapper，不能用测试回调存在冒充游戏交付。
"""
from pathlib import Path
import importlib.util
import os
import subprocess
from lib.host_cpp import find_host_cmake, configure_host_cmake
from lib.workspace_paths import temporary_directory

ROOT=Path(__file__).resolve().parents[1]
CPP=ROOT/'entry/src/main/cpp'
spec=importlib.util.spec_from_file_location('typed_cursor_extract',ROOT/'scripts/generate-desktop-review-tests.py')
recipe=importlib.util.module_from_spec(spec)
spec.loader.exec_module(recipe)
source=(CPP/'glfw/glfw_compat.cpp').read_text(encoding='utf-8')

def declared_type(signature):
    return recipe.block(source,source.index(signature))+';'

parts=[declared_type('struct TypedWindowInputBinding {'),
       recipe.block(source,source.index('static amcl::input::GlfwTypedRuntimeTarget makeTypedRuntimeTarget(')),
       'static std::shared_mutex g_typedWindowInputBindingMutex;\nstatic TypedWindowInputBinding g_typedWindowInputBinding;',
       recipe.function(source,'publishTypedWindowInputBinding'),
       declared_type('class ScopedTypedWindowInputBinding {'),
       declared_type('class ScopedTypedNativeWindowPublication {'),
       recipe.function(source,'bridgeCursorReceiptCallback'),
       recipe.function(source,'bridgeCursorPosCallback'),
       recipe.function(source,'typedAbsoluteSink')]
production='\n'.join(parts)
prefix=r'''
#include "@CPP@/input/input_menu_cursor_snapshot.h"
#include "@CPP@/input/input_surface_context_snapshot.h"
#include "@CPP@/input/input_interaction_order.h"
#include "@CPP@/input/adapters/glfw_typed_runtime_dispatch.h"
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <deque>
#include <iostream>
#include <mutex>
#include <shared_mutex>
#include <vector>
using namespace amcl::input;
// 旧隔离目标没有owner Core时fresh reader明确返回无current；完整owner目标使用真实
// Core reader。没有发布实际surface依然返回无current，测试不能伪造元数据。
#ifndef AMCL_CONTROL_DELIVERY_HOST_TESTING
extern "C" int amcl_input_owner_read_surface_context(AmclInputSurfaceContextPayload* out){if(out)*out={};return 0;}
#endif
#define AMCL_EXTERNAL_LOG_E(...) ((void)0)
#define CHECK(v) do{if(!(v)){std::cerr<<"TYPED CURSOR CHECK "<<__LINE__<<": "<<#v<<'\n';std::exit(1);}}while(0)
struct GLFWwindow;
using GLFWcursorposfun=void(*)(GLFWwindow*,double,double);
struct GLFWwindow {
    double cursorX=0,cursorY=0;int mouseButtons[8]{};
    void* nativeWindow=reinterpret_cast<void*>(1);uint64_t nativeWindowGeneration=700,windowId=42;
    int width=1000,height=800;GLFWcursorposfun cursorPosCb=nullptr;
};
GLFWwindow* g_currentWindow=nullptr;
static std::atomic<uint64_t> g_invalidCursorPositionCallbackCount{0u};
GlfwTypedAbsoluteRoute g_typedAbsoluteRoute;
struct AdapterBoundary {uint64_t order=0;uint64_t CurrentInteractionOrder()const{return order;}}g_typedInputAdapter;
std::shared_mutex nativePublicationMutex;
uint64_t nativeGeneration=700;bool nativeAvailable=true;
int glfwOHOS_BeginNativeWindowInputPublication(int* w,int* h,uint64_t* generation,void** broker){
    nativePublicationMutex.lock_shared();*w=1000;*h=800;*generation=nativeGeneration;*broker=&nativePublicationMutex;
    if(nativeAvailable)return 1;nativePublicationMutex.unlock_shared();return 0;
}
void glfwOHOS_EndNativeWindowInputPublication(void*){nativePublicationMutex.unlock_shared();}
void logTypedAbsoluteRouteDrop(const char*){}
void inputBridge_pushEvent(int,int,int,int,int);
void inputBridge_setCursorPosCallback(void(*)(void*,double,double));
void inputBridgeStartPumping();void inputBridgeStopPumping();
void inputBridge_pumpOrdered(void*,int(*)(void*,uint64_t),void*,uint64_t);
void inputBridge_cancelAllState(void*,int);void inputBridge_setGrabState(int);
void inputBridge_glfwSetActive(void*,int);void inputBridge_glfwSetTargetV1(uint64_t,uint64_t,uint64_t);
void inputBridge_publishMenuCursor(double,double);
void inputBridge_publishTouchMenuToolRelativeV1(double,double,double,double);
void inputBridge_retireTouchMenuScopeV1();void inputBridge_retireTouchMenuToolScopeV1();
void inputBridge_getCursorSnapshot(double*,double*);
void inputBridge_testResetMenuCursorSelectionV1();
struct Point {double x,y;};std::vector<Point> moves;
GLFWwindow window;
struct PendingAbsolute {GlfwAbsoluteSinkEvent event;uint64_t order;};
std::deque<PendingAbsolute> typed;
bool observeCallback=false;int callbackReentry=0;unsigned observedCallbacks=0;
uint64_t callbackExpectedAck=0;
'''
main=r'''
AmclCommittedMenuCursorV1 ack(){AmclCommittedMenuCursorV1 value{};value.structSize=sizeof(value);CHECK(inputBridge_getCommittedMenuCursorV1(&value)==1);return value;}
void TypedCallback(GLFWwindow* target,double x,double y){
    CHECK(target==&window&&target->cursorX==x&&target->cursorY==y);
    // 回调开始时current已经B；前一已完成A仍是ACK，不能提前把本次callback当处理完。
    if(observeCallback){double currentX=0,currentY=0;inputBridge_getCursorSnapshot(&currentX,&currentY);
        CHECK(currentX==x&&currentY==y);const auto prior=ack();CHECK(prior.interactionOrder==callbackExpectedAck);
        ++observedCallbacks;}
    moves.push_back({x,y});
    if(callbackReentry){
        const int mode=callbackReentry;callbackReentry=0;
        if(mode==3){inputBridge_retireTouchMenuScopeV1();return;}
        if(mode==4){inputBridge_retireTouchMenuToolScopeV1();return;}
        if(mode==1)inputBridge_glfwSetActive(&window,0);
        window.nativeWindowGeneration=701;window.windowId=43;nativeGeneration=701;
        publishTypedWindowInputBinding(&window,true);
        inputBridge_glfwSetTargetV1(reinterpret_cast<uint64_t>(&window),701,43);
        if(mode==1)inputBridge_glfwSetActive(&window,1);
        g_typedInputAdapter.order+=1000;
    }
}
int DrainTyped(void*,uint64_t ceiling){
    while(!typed.empty()&&typed.front().order<=ceiling){
        const auto item=typed.front();typed.pop_front();g_typedInputAdapter.order=item.order;
        typedAbsoluteSink(nullptr,item.event);
    }return 1;
}
void pump(){inputBridgeStartPumping();inputBridge_pumpOrdered(&window,DrainTyped,nullptr,amclInputInteractionFence());inputBridgeStopPumping();}
void surface(uint64_t epoch,uint64_t generation){GlfwSurfaceSinkEvent value{};value.surface.active=1;
    value.surface.widthPx=1000;value.surface.heightPx=800;
    value.surface.validFields=AMCL_INPUT_SURFACE_FIELD_DIMENSIONS|AMCL_INPUT_SURFACE_FIELD_PUBLICATION_GENERATION;
    value.surface.publicationGeneration=generation;value.surfaceEpoch=epoch;value.sequence=1;g_typedAbsoluteRoute.ConsumeSurface(value);}
void reset(){inputBridge_testResetMenuCursorSelectionV1();inputBridge_cancelAllState(&window,5);inputBridge_glfwSetActive(&window,0);
    inputBridge_glfwSetTargetV1(0,0,0); // host模拟新局还需退休旧target映射，不能让同tuple幂等短路新authority。
    inputBridge_setGrabState(0);window=GLFWwindow();window.cursorPosCb=TypedCallback;nativeGeneration=700;nativeAvailable=true;
    g_currentWindow=&window;
    publishTypedWindowInputBinding(&window,true);g_typedAbsoluteRoute.Reset();surface(3,700);
    CHECK(inputBridge_configureMenuCursorConsumerV1(AMCL_MENU_CURSOR_BACKEND_GLFW,9007199254740993ULL)==1);
    inputBridge_glfwSetTargetV1(reinterpret_cast<uint64_t>(&window),700,42);inputBridge_glfwSetActive(&window,1);
    typed.clear();moves.clear();observeCallback=false;callbackReentry=0;observedCallbacks=0;
    // 每次host新局都交付不同中间点后再A，保证真实callback，不把合法同位置去重当ACK。
    inputBridge_publishMenuCursor(9,19);pump();inputBridge_publishMenuCursor(10,20);pump();CHECK(ack().x==10&&ack().y==20);
}
void absolute(double x,double y,uint64_t sequence=50){const uint64_t order=amclInputNextInteractionOrder();
    typed.push_back({GlfwAbsoluteSinkEvent{x,y,7,sequence,3,700},order});}
int main(){
    inputBridge_setCursorPosCallback(bridgeCursorPosCallback);
    inputBridge_setCursorReceiptCallbackV1(bridgeCursorReceiptCallback);reset();
    callbackExpectedAck=ack().interactionOrder;observeCallback=true;absolute(300,400,9999);const auto expected=typed.front().order;pump();
    CHECK(observedCallbacks==1);const auto committed=ack();CHECK(committed.x==300&&committed.y==400&&committed.interactionOrder==expected);
    CHECK(committed.interactionOrder!=9999); // core sequence不可冒充共同interactionOrder。
    reset();inputBridge_publishTouchMenuToolRelativeV1(1,0,999,799);absolute(300,400);
    inputBridge_publishTouchMenuToolRelativeV1(1,0,999,799);pump();
    CHECK(ack().x==301&&ack().y==400&&window.cursorX==301&&window.cursorY==400);
    bool before=false,absoluteSeen=false,after=false;
    for(const auto point:moves){if(point.x==11)before=true;if(point.x==300){CHECK(before);absoluteSeen=true;}
        if(point.x==301){CHECK(absoluteSeen);after=true;}}CHECK(before&&absoluteSeen&&after);
    reset();callbackExpectedAck=ack().interactionOrder;observeCallback=true;callbackReentry=1;absolute(300,400);pump();
    AmclCommittedMenuCursorV1 invalid{};invalid.structSize=sizeof(invalid);CHECK(inputBridge_getCommittedMenuCursorV1(&invalid)==0&&invalid.flags==0);
    // 同址新publication/activation不认旧cookie；新实际legacy坐标才建立新ACK。
    observeCallback=false;inputBridge_publishMenuCursor(500,600);pump();CHECK(ack().x==500&&ack().inputPublication==701);
    reset();nativeGeneration=699;absolute(300,400);pump();CHECK(ack().x==10); // 错publication经真实RuntimeCommit拒绝。
    // 轮询current可以合法更新，但没有实际callback就不能获得新的交付ACK。
    reset();const auto beforeNull=ack();window.cursorPosCb=nullptr;absolute(300,400);pump();
    CHECK(ack().x==10&&ack().y==20&&ack().interactionOrder==beforeNull.interactionOrder);
    double nullCurrentX=0,nullCurrentY=0;inputBridge_getCursorSnapshot(&nullCurrentX,&nullCurrentY);
    CHECK(nullCurrentX==300&&nullCurrentY==400);
    // typed callback只换publication，不变activation：已复制的旧relative也必须重新验cutoff。
    reset();callbackReentry=2;absolute(300,400);inputBridge_publishTouchMenuToolRelativeV1(1,0,999,799);pump();
    AmclCommittedMenuCursorV1 afterCutoff{};afterCutoff.structSize=sizeof(afterCutoff);
    CHECK(inputBridge_getCommittedMenuCursorV1(&afterCutoff)==0&&afterCutoff.flags==0);
    CHECK(window.cursorX==300&&window.cursorY==400);
    inputBridge_publishTouchMenuToolRelativeV1(1,0,999,799);pump();CHECK(ack().x==301&&ack().inputPublication==701);
    // fullscope回调内退休使旧B complete无ACK；工具取消保持同target当前B及其实际callback ACK。
    reset();callbackReentry=3;absolute(300,400);pump();
    AmclCommittedMenuCursorV1 fullScope{};fullScope.structSize=sizeof(fullScope);
    CHECK(inputBridge_getCommittedMenuCursorV1(&fullScope)==0&&fullScope.flags==0);
    inputBridge_publishTouchMenuToolRelativeV1(1,0,999,799);pump();CHECK(ack().x==301);
    reset();callbackReentry=4;absolute(300,400);pump();CHECK(ack().x==300&&ack().y==400);
    // legacy与typed使用同一真实游戏callback：进入callback时仅current=B，返回才领取ACK_B。
    reset();callbackExpectedAck=ack().interactionOrder;observeCallback=true;
    inputBridge_publishMenuCursor(310,410);pump();CHECK(observedCallbacks==1);
    CHECK(ack().x==310&&ack().y==410);
    // wrapper已注册也不能充当游戏callback。null只写轮询current，保留前一实际已交付ACK_A。
    reset();const auto legacyBeforeNull=ack();window.cursorPosCb=nullptr;
    inputBridge_publishMenuCursor(320,420);pump();
    CHECK(ack().interactionOrder==legacyBeforeNull.interactionOrder&&ack().x==10&&ack().y==20);
    double legacyCurrentX=0,legacyCurrentY=0;inputBridge_getCursorSnapshot(&legacyCurrentX,&legacyCurrentY);
    CHECK(legacyCurrentX==320&&legacyCurrentY==420&&window.cursorX==320&&window.cursorY==420);
    // 同一legacy出口callback内退休fullscope/更换目标后，wrapper虽返回1，旧tuple/cookie仍无ACK。
    reset();callbackReentry=3;inputBridge_publishMenuCursor(330,430);pump();
    AmclCommittedMenuCursorV1 legacyRetired{};legacyRetired.structSize=sizeof(legacyRetired);
    CHECK(inputBridge_getCommittedMenuCursorV1(&legacyRetired)==0&&legacyRetired.flags==0);
    inputBridge_publishTouchMenuToolRelativeV1(1,0,999,799);pump();CHECK(ack().x==331&&ack().y==430);
    reset();callbackReentry=2;inputBridge_publishMenuCursor(340,440);pump();
    AmclCommittedMenuCursorV1 legacyReentry{};legacyReentry.structSize=sizeof(legacyReentry);
    CHECK(inputBridge_getCommittedMenuCursorV1(&legacyReentry)==0&&legacyReentry.flags==0);
    inputBridge_publishMenuCursor(341,441);pump();CHECK(ack().x==341&&ack().inputPublication==701);
    std::cout<<"PASS actual typed sink: exact runtime authorization, current-before/ACK-after, real order, relative mix and reentry rejection\n";
}
'''
with temporary_directory(prefix='typed-menu-cursor-') as directory:
    work=Path(directory);candidate=work/'fixture.cpp';build=work/'build';cmake=find_host_cmake()
    sources=['glfw/input_bridge_ohos.c','platform/physical_wheel_quantizer.cpp','input/input_interaction_order.cpp',
             # 真bridge的JNI/terminal维护借同一Source owner，不能用缺符号/noop替身绕过。
             'input/source/source_control.cpp','platform/input_ledger.cpp','platform/external_held_registry.cpp',
             'platform/external_held_edge_router.cpp','platform/legacy_output_runtime.cpp','platform/legacy_physical_edge_router.cpp',
             'input/adapters/glfw_source_plane_aggregate.cpp','input/adapters/lwjgl2_event_translate.cpp',
             'input/adapters/glfw_typed_absolute_route.cpp','input/adapters/glfw_typed_runtime_dispatch.cpp',
             'input/delivery/control_delivery.cpp','input/input_state_core.cpp',
             # 完整 Core 的真实 L2 held reader 使用同一生产 mapper；typed 光标/ACK 原断言不变。
             'input/adapters/backend_keymaps.cpp',
             'input/delivery/look_execution.cpp','platform/look_delta_math.cpp','platform/look_pipeline_stats.cpp',
             'input/amcl_input_host_descriptor.cpp',
             'tests/host/backend_input_bridge_host_stub.cpp']
    paths='\n'.join(' "'+(CPP/name).as_posix()+'"' for name in sources)
    (work/'CMakeLists.txt').write_text(f'''cmake_minimum_required(VERSION 3.16)
project(typed_menu_cursor LANGUAGES CXX)
find_package(Threads REQUIRED)
set_source_files_properties("{(CPP/'glfw/input_bridge_ohos.c').as_posix()}" PROPERTIES LANGUAGE CXX)
add_executable(typed "{candidate.as_posix()}" {paths})
target_compile_features(typed PRIVATE cxx_std_17)
target_link_libraries(typed PRIVATE Threads::Threads)
target_compile_definitions(typed PRIVATE AMCL_INPUT_BRIDGE_HOST_TESTING AMCL_CONTROL_DELIVERY_HOST_TESTING AMCL_INPUT_HOST_EXPORTS EVENT_WINDOW_SIZE=64 _CRT_SECURE_NO_WARNINGS)
target_include_directories(typed PRIVATE "{(CPP/'input').as_posix()}" "{(CPP/'tests/host/stubs').as_posix()}")
if(MSVC)
 target_compile_options(typed PRIVATE /utf-8)
endif()
''',encoding='utf-8')
    candidate.write_text(prefix.replace('@CPP@',CPP.as_posix())+production+main,encoding='utf-8')
    configure_host_cmake(cmake,work,build)
    def check(body,negative=False):
        candidate.write_text(prefix.replace('@CPP@',CPP.as_posix())+body+main,encoding='utf-8')
        subprocess.run([cmake,'--build',str(build),'--config','Release','--target','typed'],check=True)
        binary=build/'Release/typed.exe' if os.name=='nt' else build/'typed'
        result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=30)
        if negative:
            assert result.returncode!=0 and 'TYPED CURSOR CHECK' in result.stderr,result.stdout+result.stderr
        else:
            assert result.returncode==0,result.stdout+result.stderr
            print(result.stdout.strip())
    check(production)
    for name,before,after in [
        ('core sequence replaces public order','g_typedInputAdapter.CurrentInteractionOrder()','event.sequence'),
        ('typed skips neutral current synchronization','cursorCookie = inputBridge_beginGlfwMenuCursorV1(logicalTarget, inputPublication, wsiIdentity,\n            interactionOrder, committed.x, committed.y);','cursorCookie = 0;'),
        ('typed skips callback-complete ACK','(void)inputBridge_completeGlfwMenuCursorV1(logicalTarget, inputPublication, wsiIdentity,\n                cursorCookie, interactionOrder, committed.x, committed.y);','(void)cursorCookie;'),
        ('legacy wrapper fabricates receipt without actual callback','    }\n    return 0;\n}', '    }\n    return 1;\n}'),
    ]:
        assert production.count(before)==1,name
        check(production.replace(before,after,1),True)
        print('PASS negative control: '+name)
