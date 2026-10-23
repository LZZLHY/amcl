"""执行生产schema的校验、发布、取消和hotbar解释；平台边界只记录结果。

原审查探针暴露“内容相同也换代清W”。本回归同时验证保持、真正变更、拒绝与越界，
并要求删除等价短路/热区约束的负向变异编译成功后被行为断言拒绝。
"""
from pathlib import Path
import importlib.util
import subprocess
from lib.host_cpp import compile_cpp
from lib.source_host import compile_source_fixture, source_recording_prefix
from lib.workspace_paths import temporary_directory

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('schema_recipe', ROOT / 'scripts/generate-desktop-review-tests.py')
recipe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recipe)
source = (ROOT / 'entry/src/main/cpp/platform/touch_input.cpp').read_text(encoding='utf-8')
types = source[source.index('enum SchemaFingerRole {'):source.index('static SchemaFingerBinding s_schemaFingers')]
snapshot_start = source.index('struct MenuToolHeldSnapshot {')
menu_snapshot_type = source[snapshot_start:source.index('\n};', snapshot_start) + len('\n};')]
signatures = ['static bool touchOverlayContains(', 'static bool setTouchOverlayBounds(',
              'static int schemaGroupControlIndex(',
              'extern "C" bool ohos_set_menu_mouse_bounds(', 'extern "C" bool ohos_set_touch_guide_bounds(',
              'static bool pointInRect(', 'static bool schemaHitTestLocked(', 'static void schemaHotbarTap(',
              'static void schemaFireHaptic(',
              'static void schemaRetireGroupPhaseOwners(', 'static void schemaRetireGroupUiOwnersLocked(',
              'static void schemaRetireTouchPolicyLocked(', 'static void schemaCancelGenerationLocked(',
              'static bool schemaControlSurvivesLocked(', 'static void schemaRetireChangedControlsLocked(',
              'static int schemaNativeFingerCountLocked(',
              'static bool schemaOutputCodeValid(', 'static bool schemaEntriesValid(',
              'static uint64_t setControlSchemaWithGroups(',
              'extern "C" uint64_t ohos_set_control_schema_v3(', 'extern "C" uint64_t ohos_set_control_schema(']
production = '\n'.join(recipe.block(source, source.index(name)) for name in signatures)
includes = ['input_ledger.h', 'schema_wasd_latch.h', 'legacy_output_code.h',
            'control_schema_abi.h', 'control_schema_contract.cpp', 'touch_interaction.cpp', 'touch_group_state.h']
prefix = '\n'.join('#include "' + (ROOT / 'entry/src/main/cpp/platform' / name).as_posix() + '"' for name in includes)
prefix += r'''
#include <cmath>
#include <algorithm>
#include <atomic>
#include <cstring>
#include <iostream>
#include <limits>
#define AMCL_LOG_W(...) ((void)0)
#define AMCL_LOG_I(...) ((void)0)
#define OH_LOG_INFO(...) ((void)0)
#define CHECK(v) do { if (!(v)) { std::cerr << "CHECK failed line " << __LINE__ << " " << #v << '\n'; return 1; } } while (0)
using namespace amcl::input;
constexpr int MAX_FINGERS=10;
constexpr OwnerToken OWNER_SCHEMA_WASD=0x300000001ULL;
'''+types+'\n'+menu_snapshot_type+r'''
// 面板持有查询只作为平台资格输入；其集合算法另由test-menu-mouse-production执行真实函数。
unsigned testMenuToolLive=0;
static MenuToolHeldSnapshot menuToolHeldSnapshot(){MenuToolHeldSnapshot snapshot;snapshot.live=testMenuToolLive;return snapshot;}
void releaseMenuToolControls(){testMenuToolLive=0;}
SchemaFingerBinding s_schemaFingers[MAX_FINGERS];
std::map<std::string,SchemaButtonRuntime> s_schemaButtons;
std::map<OwnerToken,SchemaCarriedOwner> s_schemaCarriedOwners;
std::map<int,OwnerToken> s_schemaCarriedByFinger;
std::vector<AmclCtrlEntry> s_schema;
TouchGroupState s_touchGroups;
uint64_t s_touchGroupSequence=0;
struct GroupUiOwner{uint64_t token=0;int control=-1;};
std::array<GroupUiOwner,512> s_groupUiOwners{};
std::string s_groupMouseMember;
int s_groupMouseControl=-1;
void amcl_notify_touch_groups(){}
double s_touchContextDensity=2.0;
SchemaWasdLatch s_schemaWasdLatch;
int s_schemaJoyFinger=-1,s_schemaLookFinger=-1;
float s_schemaScrollAccum[MAX_FINGERS]{},s_schemaDragLastX[MAX_FINGERS]{},s_schemaDragLastY[MAX_FINGERS]{};
int s_schemaHotbarLastSlot[MAX_FINGERS]{};
std::mutex s_touchStateMutex,s_schemaMutex;
std::recursive_mutex s_surfaceInputGateMutex;
double s_menuMouseBounds[4]{},s_touchGuideBounds[4]{};
void pthread_mutex_lock(std::mutex* m){m->lock();}void pthread_mutex_unlock(std::mutex* m){m->unlock();}
int releases=0,lastPressedKey=-1;
// 宿主记录跨层退休接线次数；具体epoch/cutoff行为另由真实bridge组合回归验证。
int menuScopeRetirements=0;
extern "C" void inputBridge_retireTouchMenuScopeV1(){++menuScopeRetirements;}
// 此宿主闭包按 CXX 编译生产 bridge.c，沿实际宿主符号声明；OHOS 生产 TU 保持原 C ABI。
void inputBridge_retireTouchMenuToolScopeV1();
'''+source_recording_prefix(ROOT/'entry/src/main/cpp')+r'''
// 记录的是实际桥泵输出；本夹具不再拥有另一份 Source ledger/token allocator。
void recordSourceEdge(const Output& output,int action){if(action==0)++releases;if(action==1)lastPressedKey=output.code;}
SourceLedgerProxy ledger;
SourceLedgerProxy& inputLedger(){return ledger;}
void amcl_fire_button_pressed(const char*,int){}void schemaWakeDeadlineWorker(){}void amcl_fire_haptic(int){}
// 硬件反馈是唯一替身：真实schema helper冻结身份，此夹具只接受请求并转到既有计数出口。
namespace amcl::input { struct TestResetSnapshot{uint64_t touch=1;};TestResetSnapshot PlatformInputResetDomains(){return {};} }
void amcl_fire_haptic_tagged(int strength,const char*,uint64_t,uint64_t,int64_t,uint64_t){amcl_fire_haptic(strength);}
constexpr int SCHEMA_HOTBAR_SLOTS=9,SCHEMA_GLFW_KEY_1=49,GLFW_PRESS=1,GLFW_RELEASE=0;
OwnerToken nextOwnerToken(){return SourceNextNativeOwner();}
bool routerOutput(OwnerToken owner,int key,int action){const Output out{OutputKind::Key,key};return action==1?ledger.acquire(owner,out):ledger.release(owner,out);}
void resolveBridge(){}void reconcileLegacyRingDiscontinuity(){}
struct Announcements{int AnnouncedState(){return -1;}}s_grabAnnouncements;
bool(*s_isGrabbingFn)()=nullptr;bool s_grabFlipInit=true,s_grabFlipLastState=true;
bool consumeGrabEpochLocked(bool value){return value;}
uint64_t s_schemaGeneration=0;float s_schemaDeadZone=.18f,s_schemaWidthPx=0,s_schemaHeightPx=0;
uint64_t s_touchContextPolicy=1,s_schemaContextPolicy=0;
uint64_t s_touchPublicationGrabEpoch=0;
// 新策略使用真实生产实现；这里仍只替换平台坐标/事件投递边界。
TouchInteractionConfig s_touchConfig;MenuTouchInteraction s_menuTouch;TouchJoystickInteraction s_touchJoystick;
TouchGuideSignals s_touchGuide;
std::string s_touchJoystickId;int64_t s_touchPolicyStartNs=0;
std::atomic<bool> s_touchMenuCursorVisible{false};int64_t schemaNowNs(){return 1000000000;}
int s_touchLastTapSlot=-1;int64_t s_touchLastTapNs=0;std::string s_touchLastTapControl;
uint32_t s_activeMenuTransactionToken=0;int s_normalFinger=-1;
constexpr int EVENT_TYPE_MENU_POINTER=1008,MENU_POINTER_CANCEL=3;
void sendEvent(int,int,int,int,uint32_t){}double ohos_display_density(){return 2.0;}
void emitMenuInteraction(MenuTouchAction,double,double){}
// 与后面抽取的生产static正文保持相同内部链接，不能依赖MSVC接受外部声明再静态定义。
static void schemaFireHaptic(int,const char*);
'''
main = r'''
int main(){
 CHECK(initializeSourceFixture());
 AmclCtrlEntry entry{};std::strcpy(entry.id,"joystick");entry.kind=1;entry.w=100;entry.h=100;
 const auto first=ohos_set_control_schema(&entry,1,1000,1000,1,.18f,2);CHECK(first>0);
 const int firstRetirement=menuScopeRetirements;
 const Output w{OutputKind::Key,87};ledger.acquire(OWNER_SCHEMA_WASD,w);
 s_schemaJoyFinger=0;s_schemaFingers[0].role=SCHEMA_FINGER_JOYSTICK;
 entry.keys[5]=99; // 未使用的槽位不构成行为变化。
 const auto same=ohos_set_control_schema(&entry,1,1000,1000,1,.18f,2);
 CHECK(same==first&&ledger.owns(OWNER_SCHEMA_WASD,w)&&releases==0&&s_schemaJoyFinger==0);
 CHECK(menuScopeRetirements==firstRetirement); // 等价发布不退休消费端，不制造不必要的鼠标断续。
 // 真实教学区域显隐、移动与非法更新不更换游戏配置，也不释放正在按住的W。
 CHECK(ohos_set_touch_guide_bounds(200,10,300,60));
 CHECK(touchOverlayContains(s_touchGuideBounds,200,10));CHECK(!touchOverlayContains(s_touchGuideBounds,500,10));
 CHECK(!ohos_set_touch_guide_bounds(-1,10,300,60));CHECK(touchOverlayContains(s_touchGuideBounds,200,10));
 CHECK(ohos_set_touch_guide_bounds(0,0,0,0));CHECK(!touchOverlayContains(s_touchGuideBounds,200,10));
 CHECK(s_schemaGeneration==first&&ledger.owns(OWNER_SCHEMA_WASD,w)&&releases==0&&s_schemaJoyFinger==0);
 AmclCtrlEntry invalid=entry;invalid.w=std::numeric_limits<float>::quiet_NaN();
 CHECK(ohos_set_control_schema(&invalid,1,1000,1000,1,.18f,2)==0);
 CHECK(ledger.owns(OWNER_SCHEMA_WASD,w)&&s_schemaGeneration==first);
 entry.w=101;
 CHECK(ohos_set_control_schema(&entry,1,1000,1000,1,.18f,2)==first+1);
 CHECK(!ledger.owns(OWNER_SCHEMA_WASD,w)&&releases==1&&s_schemaJoyFinger==-1);
 CHECK(s_schemaFingers[0].role==SCHEMA_FINGER_NONE);
 std::strcpy(entry.id,"hotbar");entry.kind=4;entry.x=100;entry.y=100;entry.w=180;entry.h=22;entry.hitSlop=8;
 CHECK(ohos_set_control_schema(&entry,1,1000,1000,1,.18f,2)>0);
 AmclCtrlEntry hit{};
 CHECK(!schemaHitTestLocked(95,110,hit));CHECK(!schemaHitTestLocked(280,110,hit));
 CHECK(!schemaHitTestLocked(105,122,hit));CHECK(schemaHitTestLocked(100,100,hit));
 const int before=lastPressedKey;schemaHotbarTap(500,110,entry,0);CHECK(lastPressedKey==before);
 for(int i=0;i<9;++i){schemaHotbarTap(105.0f+i*20,110,entry,0);CHECK(lastPressedKey==49+i);}
 // v3动作表与几何原子发布：非法策略不退休，合法改键切换后使用新绑定。
 TouchInteractionConfig touch;touch.actions[TouchHotbar1]=82;
 const auto v3=ohos_set_control_schema_v3(&entry,1,1000,1000,1,.18f,3,&touch);CHECK(v3>0);
 schemaHotbarTap(105,110,entry,0);CHECK(lastPressedKey==82);
 auto invalidTouch=touch;invalidTouch.actions[TouchHotbar1]=999;
 CHECK(ohos_set_control_schema_v3(&entry,1,1000,1000,1,.18f,3,&invalidTouch)==0);
 CHECK(s_schemaGeneration==v3&&s_touchConfig.actions[TouchHotbar1]==82);
 CHECK(ohos_set_control_schema_v3(&entry,1,1000,1000,1,.18f,3,&touch)==v3);
 // 菜单primary不属于schema world角色；纯表变化必须保持贴屏拖动，不能误用schema计数0退休。
 const int retiredBeforeMenuContact=menuScopeRetirements;
 s_menuTouch.Event(TouchPhase::Down,0,300,400,1100000000,emitMenuInteraction);
 CHECK(s_menuTouch.Active()&&schemaNativeFingerCountLocked()==0);
 entry.x+=1;
 CHECK(ohos_set_control_schema_v3(&entry,1,1000,1000,1,.18f,3,&touch)==v3+1);
 CHECK(menuScopeRetirements==retiredBeforeMenuContact&&s_menuTouch.Active());
 s_menuTouch.Event(TouchPhase::Up,0,350,450,1200000000,emitMenuInteraction);
 CHECK(!s_menuTouch.Active());
 // 独立面板owner同样不是schema finger；纯表发布保留仍持有的面板按钮。
 testMenuToolLive=1;entry.x+=1;
 CHECK(ohos_set_control_schema_v3(&entry,1,1000,1000,1,.18f,3,&touch)==v3+2);
 CHECK(menuScopeRetirements==retiredBeforeMenuContact);
 testMenuToolLive=0;
 const int retiredBeforeZeroContactChange=menuScopeRetirements;
 entry.x+=1;
 CHECK(ohos_set_control_schema_v3(&entry,1,1000,1000,1,.18f,3,&touch)==v3+3);
 CHECK(menuScopeRetirements==retiredBeforeZeroContactChange+1);
 std::cout<<"PASS production schema: equivalent keeps held/generation, changes retire, reject atomic, hotbar edges and nine slots\n";
}
'''

# 仅显式装配复用时返回同一份生产函数/平台夹具，不执行旧main或宣布测试通过。
# 普通脚本及既有runpy调用仍完整执行原正例、编译负控和恢复，不以此模式跳过门禁。
if not globals().get('AMCL_TOUCH_RECIPE_ONLY', False):
    with temporary_directory(prefix='control-schema-lifecycle-') as directory:
        path = Path(directory) / 'schema.cpp'
        binary = Path(directory) / 'schema-test.exe'
        def check(body, negative=False):
            path.write_text(prefix+body+main, encoding='utf-8', newline='\n')
            compile_source_fixture(path,binary,ROOT/'entry/src/main/cpp')
            result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=20)
            if negative:
                assert result.returncode != 0 and 'CHECK failed' in result.stderr, result.stdout+result.stderr
            else:
                assert result.returncode == 0, result.stdout+result.stderr
                print(result.stdout.strip())
        check(production)
        mutations = [('schema equivalent short-circuit', 's_schemaGeneration != 0 &&', 'false &&'),
                     ('hotbar outer hit area', 'if (e.kind == 4 && amcl::input::ControlHotbarSlot(e, px, py) < 0) continue;', '')]
        for name, before, after in mutations:
            changed = production.replace(before, after, 1)
            assert changed != production, name
            check(changed, True)
            print('PASS negative control: '+name)
