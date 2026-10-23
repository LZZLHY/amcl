"""执行真实触控维护与视觉函数，证明读取无副作用、无观察者维护仍成立，并拒绝旧getter负例。"""
from pathlib import Path
import importlib.util
import json
import subprocess
import uuid
from lib.host_cpp import compile_cpp
from lib.workspace_paths import workspace_path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('source_recipe', ROOT / 'scripts/generate-desktop-review-tests.py')
recipe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recipe)
source = (ROOT / 'entry/src/main/cpp/platform/touch_input.cpp').read_text(encoding='utf-8')
maintain = recipe.block(source, source.index('extern "C" bool ohos_touch_input_maintain('))
visual = recipe.block(source, source.index('extern "C" void ohos_touch_interaction_visual('))
output = workspace_path('run', 'touch-maintenance')
build = workspace_path('build', 'touch-maintenance') / ('run-' + uuid.uuid4().hex[:8])
output.mkdir(parents=True, exist_ok=True)
build.mkdir(parents=True, exist_ok=True)

# 平台、grab公告与投影载体是边界替身；被测函数的锁序、调用方向和副作用全部使用生产原文。
prefix = r'''
#include <algorithm>
#include <atomic>
#include <cstdint>
#include <iostream>
#include <map>
#include <mutex>
#include <string>
#include <vector>
// Windows宿主用std::mutex承接pthread锁边界，保留实际互斥，不改被测函数的锁序。
#ifdef _WIN32
using pthread_mutex_t=std::mutex;
int pthread_mutex_lock(pthread_mutex_t* mutex){mutex->lock();return 0;}
int pthread_mutex_unlock(pthread_mutex_t* mutex){mutex->unlock();return 0;}
#define PTHREAD_MUTEX_INITIALIZER {}
#else
// POSIX标准库已声明pthread类型，使用真实锁和静态初始化器，不能再用Windows别名覆盖。
#include <pthread.h>
#endif
#define CHECK(v) do { if(!(v)){std::cerr << "CHECK failed " << __LINE__ << " " << #v << '\n';return 1;} }while(0)
std::recursive_mutex s_surfaceInputGateMutex;
std::mutex s_touchStateMutex;
pthread_mutex_t s_schemaMutex=PTHREAD_MUTEX_INITIALIZER;
bool modeAvailable=true,modeGrabbed=false,s_grabFlipInit=false,s_grabFlipLastState=false,held=true;
int modeReads=0,consumes=0,adoptions=0,releases=0;
namespace amcl::input {
enum { TouchUse=0 };
class AuthoritativeGrabInputTransaction {
 public: AuthoritativeGrabInputTransaction(){++modeReads;}
 explicit operator bool()const{return modeAvailable;}
 bool grabbed()const{return modeGrabbed;}
};
}
bool isGrabbedMode(){++modeReads;return modeGrabbed;}
bool consumeGrabEpochLocked(bool grabbed){
 ++consumes;if(!s_grabFlipInit||s_grabFlipLastState!=grabbed){if(held){held=false;++releases;}}
 s_grabFlipInit=true;s_grabFlipLastState=grabbed;return grabbed;
}
struct Menu { double x=3,y=4;bool direct=false;
 double X()const{return x;}double Y()const{return y;}
 bool DirectActive()const{return direct;}bool Active()const{return direct;} }s_menuTouch;
bool ackAvailable=true;double ackX=80,ackY=90;
bool adoptCommittedMenuCursorLocked(){++adoptions;if(!ackAvailable)return false;s_menuTouch.x=ackX;s_menuTouch.y=ackY;return true;}
std::atomic<bool> s_touchMenuCursorVisible{true};
struct Joystick {double CenterX()const{return 10;}double CenterY()const{return 20;}
 double X()const{return 0;}double Y()const{return 0;}bool Locked()const{return false;}bool Armed()const{return false;}}s_touchJoystick;
int s_schemaJoyFinger=-1;uint64_t s_schemaGeneration=7;
struct Guide {uint64_t movement=0,hotbar=0,scroll=0,mouseMove=0,mouseButton=0;
 int slot=0,mouseCode=0;double scrollAmount=0;}s_touchGuide;
constexpr int MAX_FINGERS=10,SCHEMA_FINGER_LOOK=1,SCHEMA_FINGER_HOTBAR=2;
bool s_fingerDown[MAX_FINGERS]{},s_fingerDead[MAX_FINGERS]{};
struct Control {std::string id;int keyCount=0,keyOrMouse=0,keys[16]{};};
std::vector<Control> s_schema;std::string s_touchJoystickId;
struct FingerBinding {int role=0;bool moved=false,holdFired=false;int64_t deadlineNs=0,startNs=0;};
FingerBinding s_schemaFingers[MAX_FINGERS];
struct Button {bool outputDown=false;Control control;};std::map<int,Button>s_schemaButtons;
struct Config {double holdMs=200;int gestureMode=0,actions[16]{};}s_touchConfig;
int64_t schemaNowNs(){return 1000000000;}
'''
main = r'''
int main(){
 double values[25]{};modeGrabbed=true;s_fingerDown[0]=true;
 for(int i=0;i<4;++i)ohos_touch_interaction_visual(values,25);
 CHECK(consumes==0&&modeReads==0&&adoptions==0&&releases==0&&held);
 CHECK(!s_grabFlipInit&&values[24]==0&&values[0]==3&&values[23]==1);
 // 没有观察者调用也能完成grab退休；getter不能承担这项生产工作。
 CHECK(ohos_touch_input_maintain());CHECK(consumes==1&&releases==1&&!held&&s_grabFlipLastState);
 int beforeReads=modeReads,beforeConsumes=consumes;ohos_touch_interaction_visual(values,25);
 CHECK(values[24]==1&&consumes==beforeConsumes&&modeReads==beforeReads);
 modeGrabbed=false;ohos_touch_interaction_visual(values,25);CHECK(values[0]==3&&adoptions==0);
 CHECK(ohos_touch_input_maintain());CHECK(adoptions==1&&s_menuTouch.x==80&&s_menuTouch.y==90);
 beforeConsumes=consumes;ohos_touch_interaction_visual(values,25);
 CHECK(values[0]==80&&values[1]==90&&values[24]==0&&consumes==beforeConsumes&&adoptions==1);
 modeAvailable=false;ackAvailable=false;CHECK(!ohos_touch_input_maintain());
 CHECK(!s_touchMenuCursorVisible.load());ohos_touch_interaction_visual(values,25);CHECK(values[2]==0);
 std::cout<<"PASS production explicit maintenance and read-only visual contract\n";return 0;
}
'''

def run_variant(name, production, expected):
    """变异必须编译成功再由行为断言拒绝；编译失败不能冒充负向验证。"""
    cpp = build / (name + '.cpp')
    binary = build / (name + ('.exe' if __import__('os').name == 'nt' else ''))
    cpp.write_text(prefix + production + main, encoding='utf-8')
    compile_cpp(cpp, binary)
    result = subprocess.run([str(binary)], text=True, capture_output=True)
    (output / (name + '.log')).write_text(result.stdout + result.stderr, encoding='utf-8')
    assert (result.returncode == 0) == expected, name + ': ' + result.stdout + result.stderr
    print(('PASS ' if expected else 'PASS rejected negative control ') + name)

run_variant('production', maintain + visual, True)
old_visual = visual.replace('const bool grabbed=s_grabFlipInit && s_grabFlipLastState;',
    'amcl::input::AuthoritativeGrabInputTransaction mode; const bool grabbed=consumeGrabEpochLocked(mode ? mode.grabbed() : isGrabbedMode());')
assert old_visual != visual
run_variant('old-getter-consumes-grab', maintain + old_visual, False)
no_maintenance = maintain.replace('const bool grabbed=consumeGrabEpochLocked(mode ? mode.grabbed() : isGrabbedMode());',
    'const bool grabbed=s_grabFlipInit && s_grabFlipLastState;')
assert no_maintenance != maintain
run_variant('missing-explicit-grab-maintenance', no_maintenance + visual, False)
(output / 'result.json').write_text(json.dumps({'production': 'PASS', 'negativeControls': 2,
    'source': str(ROOT / 'entry/src/main/cpp/platform/touch_input.cpp'), 'build': str(build)}, indent=2), encoding='utf-8')
print('touch-maintenance evidence=' + str(output))
