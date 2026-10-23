"""执行真实GLFW末级cache/callback/poll函数及真实neutral/Core owner，观测不以ringTaken代替。"""
from pathlib import Path
import importlib.util
import os
import subprocess
from lib.host_cpp import find_host_cmake, configure_host_cmake
from lib.workspace_paths import temporary_directory

ROOT=Path(__file__).resolve().parents[1]
CPP=ROOT/'entry/src/main/cpp'
spec=importlib.util.spec_from_file_location('observer_extract',ROOT/'scripts/generate-desktop-review-tests.py')
recipe=importlib.util.module_from_spec(spec);spec.loader.exec_module(recipe)
compat=(CPP/'glfw/glfw_compat.cpp').read_text(encoding='utf-8')
callbacks=(CPP/'glfw/glfw_callbacks.cpp').read_text(encoding='utf-8')
def extract(source,name):
    """只定位生产函数；正文逐字使用，遇不存在或不完整的依赖即失败。"""
    import re
    hit=re.search(r'^(?:static )?(?:void|int) '+name+r'\([^;{}]*\)\s*\{',source,re.M)
    assert hit,name
    return recipe.block(source,hit.start())
production='\n'.join(extract(compat,n) for n in ['glfwOHOS_RecordControlPoll','currentModifierMask','dispatchAggregateKey','dispatchAggregateButton'])
production+='\n'+'\n'.join(extract(callbacks,n) for n in ['glfwGetKey','glfwGetMouseButton'])
prefix=r'''
#include "@CPP@/input/adapters/glfw_source_plane_aggregate.h"
#include <atomic>
#include <cstdlib>
#include <iostream>
#include <cstring>
using namespace amcl::input;
#define CHECK(v) do{if(!(v)){std::cerr<<"CONTROL GLFW OBSERVER "<<__LINE__<<": "<<#v<<'\n';std::exit(1);}}while(0)
#define OH_LOG_INFO(...) ((void)0)
#define LOG_APP 0
constexpr int GLFW_RELEASE=0,GLFW_PRESS=1;
constexpr int GLFW_MOUSE_BUTTON_LEFT=0;
constexpr int GLFW_MOD_SHIFT=1,GLFW_MOD_CONTROL=2,GLFW_MOD_ALT=4,GLFW_MOD_SUPER=8;
struct GLFWwindow{int keys[512]{},mouseButtons[8]{};uint64_t windowId=42;
 void(*keyCb)(GLFWwindow*,int,int,int,int)=nullptr;void(*mouseButtonCb)(GLFWwindow*,int,int,int)=nullptr;};
GLFWwindow* g_currentWindow=nullptr;
GlfwSourcePlaneAggregate g_sourcePlaneAggregate;
'''
main=r'''
unsigned returned=0;bool reentry=false;
void Key(GLFWwindow* w,int key,int,int action,int){
 CHECK(w==g_currentWindow);CHECK(w->keys[key]==(action?1:0));
 AmclControlSnapshotV1 inside{};CHECK(g_sourcePlaneAggregate.Snapshot(inside));CHECK(inside.callbackReturned==returned);++returned;
 if(reentry&&key==65&&action==0){reentry=false;g_sourcePlaneAggregate.SubmitKey(GlfwSourcePlane::kTyped,66,30,GlfwAggregateAction::kPress,0,{w,dispatchAggregateKey,dispatchAggregateButton});}
}
void Button(GLFWwindow* w,int button,int action,int){CHECK(w->mouseButtons[button]==action);
 AmclControlSnapshotV1 inside{};CHECK(g_sourcePlaneAggregate.Snapshot(inside));CHECK(inside.callbackReturned==returned);++returned;}
int main(){GLFWwindow window;g_currentWindow=&window;window.keyCb=Key;window.mouseButtonCb=Button;
 g_sourcePlaneAggregate.BindTarget(window.windowId);GlfwAggregateSink sink{&window,dispatchAggregateKey,dispatchAggregateButton};
 g_sourcePlaneAggregate.SubmitKey(GlfwSourcePlane::kLegacy,65,0,GlfwAggregateAction::kPress,0,sink);
 g_sourcePlaneAggregate.SubmitKey(GlfwSourcePlane::kTyped,65,30,GlfwAggregateAction::kPress,0,sink);
 CHECK(glfwGetKey(&window,65)==1);
 g_sourcePlaneAggregate.SubmitButton(GlfwSourcePlane::kLegacy,0,GlfwAggregateAction::kPress,0,sink);CHECK(glfwGetMouseButton(&window,0)==1);
 AmclControlSnapshotV1 facts{};CHECK(g_sourcePlaneAggregate.Snapshot(facts));
 CHECK(facts.accepted==3&&facts.edges==2&&facts.noEdge==1&&facts.callbackReturned==2&&returned==2&&facts.legalPollReads==2);
 // reset后首个release的回调重新取得后面的B，旧prepared B-UP不能误松或补一次重复B-DOWN。
 g_sourcePlaneAggregate.SubmitKey(GlfwSourcePlane::kLegacy,66,0,GlfwAggregateAction::kPress,0,sink);
 reentry=true;g_sourcePlaneAggregate.ClearAll(sink);
 CHECK(window.keys[65]==0&&window.keys[66]==1&&glfwGetKey(&window,66)==1);
 CHECK(g_sourcePlaneAggregate.IsKeyPressed(66));
 // 无真实窗口出口时，void sink返回不能冒充缓存已经写入。
 CHECK(g_sourcePlaneAggregate.Snapshot(facts));const uint64_t previousState=facts.stateOnly,previousCallback=facts.callbackReturned;
 g_currentWindow=nullptr;
 g_sourcePlaneAggregate.SubmitKey(GlfwSourcePlane::kLegacy,90,0,GlfwAggregateAction::kPress,0,{nullptr,dispatchAggregateKey,dispatchAggregateButton});
 CHECK(g_sourcePlaneAggregate.Snapshot(facts));CHECK(facts.stateOnly==previousState&&facts.callbackReturned==previousCallback);
 const auto* owner=amclControlDeliveryGetPortV1();CHECK(owner->queryDelivered(facts.consumer,1,90)==0);
 g_currentWindow=&window;g_sourcePlaneAggregate.ClearPlane(GlfwSourcePlane::kLegacy,sink);
 // 同址的实际window identity变化，即使旧ticket在neutral内仍有效，也不能写新目标cache。
 AmclControlEmissionV1 old{};CHECK(owner->apply(facts.consumer,4,100,1,91,0,1,&old)==1&&owner->claim(&old)==1);
 window.windowId=43;dispatchAggregateKey(&window,{91,0,GlfwAggregateAction::kPress,0,old});
 CHECK(window.keys[91]==0&&owner->queryDelivered(facts.consumer,1,91)==0);
 window.windowId=42;
 // neutral已退休旧target但window地址/identity恰巧仍旧值：出口还须逐票validate。
 CHECK(owner->apply(facts.consumer,4,101,1,92,0,1,&old)==1&&owner->claim(&old)==1);
 g_sourcePlaneAggregate.BindTarget(43);dispatchAggregateKey(&window,{92,0,GlfwAggregateAction::kPress,0,old});
 CHECK(window.keys[92]==0);g_sourcePlaneAggregate.BindTarget(42);
 // 两份贡献的真实void出口均失败后，退出legacy仍须把剩余typed holder补成实际PRESS。
 g_currentWindow=nullptr;
 g_sourcePlaneAggregate.SubmitKey(GlfwSourcePlane::kLegacy,95,0,GlfwAggregateAction::kPress,0,{nullptr,dispatchAggregateKey,dispatchAggregateButton});
 g_sourcePlaneAggregate.SubmitKey(GlfwSourcePlane::kTyped,95,30,GlfwAggregateAction::kPress,0,{nullptr,dispatchAggregateKey,dispatchAggregateButton});
 g_currentWindow=&window;
 g_sourcePlaneAggregate.SubmitKey(GlfwSourcePlane::kLegacy,95,0,GlfwAggregateAction::kRelease,0,sink);
 CHECK(window.keys[95]==1&&glfwGetKey(&window,95)==1);
 g_sourcePlaneAggregate.SubmitKey(GlfwSourcePlane::kTyped,95,30,GlfwAggregateAction::kRelease,0,sink);
 CHECK(window.keys[95]==0&&glfwGetKey(&window,95)==0);
 // 反向：真实DOWN已交付，缺窗口时UP丢弃仍保cache held；完整窗口退休必须修复它。
 g_sourcePlaneAggregate.SubmitKey(GlfwSourcePlane::kLegacy,96,0,GlfwAggregateAction::kPress,0,sink);
 g_currentWindow=nullptr;
 g_sourcePlaneAggregate.SubmitKey(GlfwSourcePlane::kLegacy,96,0,GlfwAggregateAction::kRelease,0,{nullptr,dispatchAggregateKey,dispatchAggregateButton});
 g_currentWindow=&window;CHECK(window.keys[96]==1&&!g_sourcePlaneAggregate.IsKeyPressed(96));
 g_sourcePlaneAggregate.ClearPlane(GlfwSourcePlane::kTyped,sink);CHECK(window.keys[96]==1);
 g_sourcePlaneAggregate.ClearAll(sink);CHECK(window.keys[96]==0&&glfwGetKey(&window,96)==0);
 std::cout<<"PASS actual GLFW cache/callback-return/valid-poll counters and reset reentry receipt\n";
}
'''
with temporary_directory(prefix='control-glfw-observer-') as folder:
    folder=Path(folder);source=folder/'observer.cpp';source.write_text(prefix.replace('@CPP@',CPP.as_posix())+production+main,encoding='utf-8')
    cmake='''cmake_minimum_required(VERSION 3.16)
project(control_glfw_observer LANGUAGES CXX)
add_executable(observer "@SOURCE@" "@CPP@/input/adapters/glfw_source_plane_aggregate.cpp"
 "@CPP@/input/delivery/control_delivery.cpp" "@CPP@/input/input_state_core.cpp"
 "@CPP@/input/amcl_input_host_descriptor.cpp" "@CPP@/input/input_interaction_order.cpp"
 # Core 的真实 L2 held reader 依赖生产 mapper；补完整强链接，不以 weak/noop 或假映射替代。
 "@CPP@/input/adapters/backend_keymaps.cpp")
target_include_directories(observer PRIVATE "@CPP@/input" "@CPP@/tests/host/stubs")
target_compile_features(observer PRIVATE cxx_std_17)
target_compile_definitions(observer PRIVATE AMCL_CONTROL_DELIVERY_HOST_TESTING AMCL_INPUT_HOST_EXPORTS)
if(MSVC)
 target_compile_options(observer PRIVATE /utf-8)
endif()
'''.replace('@SOURCE@',source.as_posix()).replace('@CPP@',CPP.as_posix())
    (folder/'CMakeLists.txt').write_text(cmake,encoding='utf-8');build=folder/'build';tool=find_host_cmake()
    configure_host_cmake(tool,folder,build);subprocess.run([tool,'--build',str(build),'--config','Release'],check=True)
    binary=build/'Release/observer.exe' if os.name=='nt' else build/'observer'
    subprocess.run([str(binary)],check=True)
    # 每次只变异外置生产正文；必须编译成功且由真实运行CHECK拒绝，编译失败不算反控。
    for label,before,after in [
        ('callback return report missing','g_sourcePlaneAggregate.Complete(event.receipt, AMCL_CONTROL_CALLBACK_RETURNED);','/* negative: callback returned but not recorded */'),
        ('actual poll report missing','g_sourcePlaneAggregate.ObservePoll(kind,code,held);','/* negative: actual poll not recorded */'),
        ('callback completion reported early','win->keyCb(win, event.key, scanCode,','g_sourcePlaneAggregate.Complete(event.receipt, AMCL_CONTROL_CALLBACK_RETURNED);\n        win->keyCb(win, event.key, scanCode,'),
        ('void sink failure falsely reports cache','g_sourcePlaneAggregate.Complete(event.receipt, AMCL_CONTROL_DISCARDED);','/* negative: no actual cache written, but facade still finalizes */'),
        ('actual target identity guard removed','event.receipt.target != win->windowId ||','/* negative: actual window identity not checked */'),
        ('old ticket validation removed','!g_sourcePlaneAggregate.Validate(event.receipt)','false'),
    ]:
        assert before in production,label
        source.write_text(prefix.replace('@CPP@',CPP.as_posix())+production.replace(before,after,1)+main,encoding='utf-8')
        subprocess.run([tool,'--build',str(build),'--config','Release'],check=True)
        result=subprocess.run([str(binary)],capture_output=True,text=True)
        assert result.returncode!=0 and 'CONTROL GLFW OBSERVER' in result.stderr,label+result.stdout+result.stderr
        print('PASS negative control: '+label)
