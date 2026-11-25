"""把真实期限执行/公告迁移与实际bridge mode fence装配，验证确定交错及撤回负对照。"""
from pathlib import Path
import argparse
import runpy
import subprocess
import os
from lib.host_test_lifecycle import HostTestScope
from lib.workspace_paths import external_output_path, workspace_path
from lib.host_cpp import find_host_cmake, configure_host_cmake
from lib.source_host import source_dependencies

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', help='仓库外的运行证据目录；缺省自动外置')
parser.add_argument('--cmake', help='宿主CMake路径；缺省寻找本机原生工具')
args = parser.parse_args()
output = external_output_path(args.output) if args.output else workspace_path('run','touch-deadline')
output.mkdir(parents=True, exist_ok=True)
# 与正常构建/独立预检隔离变异源和二进制；共享固定CMake树会使并发负控互相覆盖。
scope = HostTestScope('run-', parent=workspace_path('build','touch-deadline'))
build_root = scope.directory
build = build_root / 'build'
configure_source = build_root / 'fixture'
configure_source.mkdir(parents=True,exist_ok=True)
cmake_tool = find_host_cmake(args.cmake)
# 复用已运行的生产夹具；对照仍需先通过既有schema和触控行为契约。
fixture = runpy.run_path(str(root / 'scripts/test-touch-production.py'))
prefix, production, source = fixture['prefix'], fixture['production'], fixture['source']
# 使用生产GLFW入口发出程序设位，窗口只保留该入口读取的字段，事件和消费状态仍由真实bridge维护。
callback_source=(root/'entry/src/main/cpp/glfw/glfw_callbacks.cpp').read_text(encoding='utf-8')
front=(root/'entry/src/main/cpp/glfw/glfw_compat.cpp').read_text(encoding='utf-8')
block=fixture['base']['recipe'].block
setter=block(callback_source,callback_source.index('void glfwSetCursorPos('))
warp_pump=block(front,front.index('static void pumpGlfwInputThrough('))
warp_request=block(front,front.index('void glfwOHOS_WarpCarriedMenuCursor('))
prefix=prefix.replace('static int sourceFixtureWindow=0;', '''
enum { GLFW_CURSOR_NORMAL=0x34001, GLFW_CURSOR_DISABLED=0x34003 };
struct GLFWwindow {
    bool auxiliary=false;
    double cursorX=0,cursorY=0;
    int cursorMode=GLFW_CURSOR_NORMAL;
    void (*cursorPosCb)(void*,double,double)=nullptr;
};
static GLFWwindow sourceFixtureWindow;
static GLFWwindow* g_currentWindow=&sourceFixtureWindow;
void inputBridge_setLookCursor(double,double);
void inputBridge_pumpOrdered(void*,int(*)(void*,uint64_t),void*,uint64_t);
// typed来源不生成事件；仍核对两端传递的实际目标及上限。混合typed顺序由其生产组合套件验证。
int pumpTypedThrough(void* window,uint64_t) {return window==g_currentWindow;}
''',1)
prefix += '\n'+'\n'.join([warp_pump,warp_request,setter])+'\n'

# 此目标链接真实neutral bridge；基础纯触控夹具的计数出口只能保留声明，避免重复定义。
# 面板集合仍用基础夹具唯一的平台替身，集合本身由独立生产producer测试覆盖。
scope_stub = 'extern "C" void inputBridge_retireTouchMenuScopeV1(){++menuScopeRetirements;}'
assert prefix.count(scope_stub) == 1
# 该宿主目标按LANGUAGE CXX编译bridge.c，旧菜单入口沿其宿主C++声明链接；OHOS生产TU仍为C ABI。
prefix = prefix.replace(scope_stub, 'void inputBridge_retireTouchMenuScopeV1();', 1)
# Source组合期限使用真实Core/descriptor/resource，不再装一个总是缺席的私有current替身。
prefix = prefix.replace('struct Announcements{int AnnouncedState(){return -1;}}s_grabAnnouncements;',
    '#include "' + (root / 'entry/src/main/cpp/platform/grab_announcement_queue.h').as_posix() + '"\n'
    'std::mutex announcementMutex;GrabAnnouncementQueue s_grabAnnouncements(announcementMutex);')
prefix = prefix.replace('bool consumeGrabEpochLocked(bool value){return value;}',
    'static bool consumeGrabEpochLocked(bool value);')
prefix = prefix.replace('void recordSourceEdge(const Output& output,int action){',
    'std::atomic<bool> blockPress{false},pressEntered{false},releasePress{false};\nvoid recordSourceEdge(const Output& output,int action){')
prefix = prefix.replace('edges.push_back({output,action});',
    'edges.push_back({output,action});if(action==1&&blockPress.load()){'
    'pressEntered.store(true,std::memory_order_release);while(!releasePress.load(std::memory_order_acquire))std::this_thread::yield();}')
# 将真实bridge已消费的指针和按键回调记录在同一轨迹；录制器不参与排序和持有。
prefix = prefix.replace('void recordSourceEdge(const Output& output,int action){',
                        'void recordDeliveredCarriedRelease(const Output&,int);\n'
                        'void recordSourceEdge(const Output& output,int action){recordDeliveredCarriedRelease(output,action);')
prefix = '#include <thread>\n#include <cstdio>\n#include "platform/render_scale.h"\n#include "input/input_menu_cursor_snapshot.h"\n' + prefix
# 提取生产RAII事务类，底层begin/end委派到此目标链接的真实bridge。
header = (root / 'entry/src/main/cpp/platform/touch_input.h').read_text(encoding='utf-8')
raii = header[header.index('class AuthoritativeGrabInputTransaction final'):header.index('class SurfaceInputGateTransaction final')]
prefix += r'''
void inputBridge_setGrabState(int);
void inputBridge_setCursorPosCallback(void(*)(void*,double,double));
void inputBridge_publishMenuCursor(double,double);
void inputBridge_getCursorSnapshot(double*,double*);
void inputBridge_publishTouchMenuRelativeV1(int,uint32_t,double,double,double,double);
void inputBridge_notifyFramePresentedForTargetV1(uint64_t,uint64_t);
constexpr int MENU_POINTER_MOVE=0,MENU_POINTER_END=5;
int inputBridge_beginPhysicalMotionTransaction(int*);
void inputBridge_endPhysicalMotionTransaction();
unsigned int inputBridge_testGrabWriterWaiters();
bool modeAvailable=true,surfaceAvailable=true;
bool ohos_begin_authoritative_grab_input_transaction(bool* grabbed){
 if(!modeAvailable)return false;int value=0;if(!inputBridge_beginPhysicalMotionTransaction(&value))return false;
 *grabbed=value!=0;return true;}
void ohos_end_authoritative_grab_input_transaction(){inputBridge_endPhysicalMotionTransaction();}
bool currentBridgeGrabbed(){int value=0;inputBridge_beginPhysicalMotionTransaction(&value);inputBridge_endPhysicalMotionTransaction();return value!=0;}
bool s_fingerDown[MAX_FINGERS]{},s_fingerDead[MAX_FINGERS]{};
std::atomic<bool> s_touchPaused{false};
void resetMirrorGestureStateLocked(){}void flushLookPending(bool){}
void announceGrab(int state){s_grabAnnouncements.Announce(state!=0);}
void setTestEnv(const char* name,const char* value){
#ifdef _WIN32
 _putenv_s(name,value);
#else
 setenv(name,value,1);
#endif
}
namespace amcl::input {
'''+raii+r'''
// surfaceSDK是准入替身，输出/角色/公告/真实mode fence均使用生产代码。
class SurfaceInputGateTransaction{public:explicit operator bool()const{return surfaceAvailable;}};
}
'''
names = ['static bool mapMenuRelativePayload(', 'static void schemaCaptureCarriedMenuDragLocked(',
         'static std::set<OwnerToken> schemaCaptureHeldOwnersLocked(',
         'static bool schemaCollectCarriedUpLocked(', 'static bool handleSchemaCarriedTouch(',
         'static void schemaResetTransientStateLocked(', 'static void onGrabFlipCancel(',
         'static bool consumeGrabEpochLocked(', 'extern "C" void ohos_note_physical_pointer_visual(',
         'static uint64_t amcl_touch_claim_menu_warp(', 'static bool schemaExecuteDueDeadlines(']
production += '\n' + '\n'.join(fixture['definition'](name) for name in names)
template = (root / 'entry/src/main/cpp/tests/host/touch_deadline_transaction.cpp.in').read_text(encoding='utf-8')
cpp = root / 'entry/src/main/cpp'
source_paths='\n'.join(' "'+path.as_posix()+'"' for path in source_dependencies(cpp))
cmake = f'''cmake_minimum_required(VERSION 3.16)
project(touch_deadline_transaction LANGUAGES CXX)
find_package(Threads REQUIRED)
set_source_files_properties("{(cpp/'glfw/input_bridge_ohos.c').as_posix()}" PROPERTIES LANGUAGE CXX)
add_executable(deadline "{(output/'deadline.cpp').as_posix()}"
 {source_paths}
 "{(cpp/'platform/render_scale.cpp').as_posix()}")
target_compile_features(deadline PRIVATE cxx_std_17)
# POSIX也通过真实动态getter验证owner，不能靠Windows导出pragma代替。
set_target_properties(deadline PROPERTIES ENABLE_EXPORTS ON)
target_link_libraries(deadline PRIVATE Threads::Threads ${{CMAKE_DL_LIBS}})
target_compile_definitions(deadline PRIVATE NOMINMAX AMCL_INPUT_BRIDGE_HOST_TESTING AMCL_INPUT_HOST_EXPORTS AMCL_CONTROL_DELIVERY_HOST_TESTING AMCL_DESKTOP_EVENT_BRIDGE=1 _CRT_SECURE_NO_WARNINGS)
target_include_directories(deadline PRIVATE "{cpp.as_posix()}" "{(cpp/'tests/host/stubs').as_posix()}")
if(MSVC)
 target_compile_options(deadline PRIVATE /utf-8)
endif()
'''
(configure_source/'CMakeLists.txt').write_text(cmake,encoding='utf-8')
(output/'CMakeLists.txt').write_text(cmake,encoding='utf-8')
(output/'deadline.cpp').write_text(template.replace('@FIXTURE@',prefix+production),encoding='utf-8')
configure_host_cmake(cmake_tool,configure_source,build)
def check(body, negative=False, expected='CHECK failed', label=''):
    """负对照须编译成功后违反行为断言；编译失败或超时不记为成功捕获。"""
    (output/'deadline.cpp').write_text(template.replace('@FIXTURE@',prefix+body),encoding='utf-8')
    subprocess.run([cmake_tool,'--build',str(build),'--config','Release','--target','deadline'],check=True)
    binary = build/'Release'/'deadline.exe' if os.name=='nt' else build/'deadline'
    result = subprocess.run([str(binary)],capture_output=True,text=True,timeout=20)
    (output/(label or ('negative.log' if negative else 'positive.log'))).write_text(result.stdout+result.stderr,encoding='utf-8')
    if negative:
        assert result.returncode != 0 and expected in result.stderr,result.stdout+result.stderr
    else:
        assert result.returncode == 0,result.stdout+result.stderr
        print(result.stdout.strip())
check(production)
# 回到旧worker只持schema直接执行的路径，应由grab-first行为断言直接抓住误PRESS。
before = fixture['definition']('static bool schemaExecuteDueDeadlines(')
after = 'static bool schemaExecuteDueDeadlines(){schemaPollLongPressLocked();schemaPollWasdLatchLocked();schemaPollTouchHoldsLocked();return true;}'
assert production.count(before)==1
check(production.replace(before,after,1),negative=True)
print('PASS negative control: deadline emits without real grab transaction')
# 恢复旧的world/groups条件会使无组菜单静止长按不触发，必须命中新加的特定断言。
before='schemaPollLongPressLocked();\n        if (grabbed) schemaPollWasdLatchLocked();'
assert production.count(before)==1
check(production.replace(before,'if (grabbed || s_touchGroups.Enabled()) schemaPollLongPressLocked();\n        if (grabbed) schemaPollWasdLatchLocked();',1),
      negative=True,expected='!s_touchGroups.Enabled()&&ledger.isHeld',label='negative-menu.log')
print('PASS compiled withdrawal: legacy menu long-press requires deadline advancement without another input event')
# 撤回承接指的位置投递，真实松键仍可达，但实际consumer轨迹必须拒绝旧坐标。
before = 'inputBridge_publishTouchMenuRelativeV1(MENU_POINTER_MOVE, 0, x, y, maxX, maxY);'
assert production.count(before) == 1
check(production.replace(before, '(void)0;', 1),
      negative=True, expected='carriedDelivery==pendingPositions', label='negative-carried-motion.log')
print('PASS compiled withdrawal: same-finger menu position must arrive before right release')
# 只撤回程序设位对松键屏障的贡献；零物理MOVE时旧值仍能显示，但提前松键会把位移带到世界帧。
warp_claim = fixture['definition']('static uint64_t amcl_touch_claim_menu_warp(')
assert warp_claim.count('drag.movedInMenu = true;') == 1 and production.count(warp_claim)==1
check(production.replace(warp_claim,warp_claim.replace('drag.movedInMenu = true;', '(void)0;')),
      negative=True, expected='count(OutputKind::Mouse,1,GLFW_RELEASE)==0',label='negative-warp-release.log')
print('PASS compiled withdrawal: initial warp alone must protect the first world frame')
check(production,label='restored.log')
# 全部断言和撤回负控结束后仅回收本次生成树；失败直接保留现场与日志。
scope.close()
