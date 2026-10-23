"""重放真实native触控解释器。复用schema夹具，仅替换SDK、时钟和最终投递，不复制手势算法。"""
from pathlib import Path
import runpy
import re
import subprocess
from lib.host_cpp import compile_cpp
from lib.source_host import compile_source_fixture
from lib.workspace_paths import temporary_directory

ROOT = Path(__file__).resolve().parents[1]
# 先执行既有正例/反例，再复用其平台夹具；任何原契约失败都会阻止本轮新增场景。
base = runpy.run_path(str(ROOT / 'scripts/test-control-schema-lifecycle.py'),
    init_globals={'AMCL_TOUCH_RECIPE_ONLY': globals().get('AMCL_TOUCH_RECIPE_ONLY', False)})
source = base['source']
prefix = base['prefix']
prefix = prefix.replace('int64_t schemaNowNs(){return 1000000000;}',
                        'int64_t clockNs=1000000000;int64_t schemaNowNs(){return clockNs;}')
prefix = prefix.replace('int releases=0,lastPressedKey=-1;',
    'struct Edge{Output output;int action;};std::vector<Edge> edges;int releases=0,lastPressedKey=-1;')
prefix = prefix.replace('if(action==0)++releases;if(action==1)lastPressedKey=output.code;',
    'edges.push_back({output,action});if(action==0)++releases;if(action==1)lastPressedKey=output.code;')
prefix = prefix.replace('const Output out{OutputKind::Key,key};',
    'Output out{};if(!DecodeLegacySchemaOutputCode(key,&out))return false;')
assert 'clockNs=1000000000' in prefix and 'edges.push_back' in prefix
prefix += '\n#include "' + (ROOT / 'entry/src/main/cpp/platform/joystick_sector.cpp').as_posix() + '"\n'
prefix += r'''
#include <algorithm>
constexpr int OH_NATIVEXCOMPONENT_DOWN=0,OH_NATIVEXCOMPONENT_UP=1,OH_NATIVEXCOMPONENT_MOVE=2,OH_NATIVEXCOMPONENT_CANCEL=3;
struct OH_NativeXComponent_TouchEvent{int type;int64_t timeStamp;};
struct Finger{float lastX=0,lastY=0;}s_fingers[MAX_FINGERS];
float s_schemaScrollLastY[MAX_FINGERS]{};
// 来源枚举来自真实 Source port 的 input_source.h，不在宿主另造同名整数。
constexpr int s_schemaTakeover=31;
constexpr int64_t SCHEMA_DOUBLETAP_NS=300000000,SCHEMA_LONGPRESS_NS=200000000;
int scrolls=0,looks=0;double lookX=0,lookY=0;bool axisPan=false;
namespace amcl::input::census { enum class Channel{LookFromSchemaTouch,SchemaTouchScroll};void Bump(Channel){} }
int64_t nowMonotonicNs(){return clockNs;}bool axisPanLookSuppressed(int64_t){return axisPan;}
float schemaScrollStepPx(){return 24;}
bool routerScroll(int,int,int dy,bool){scrolls+=dy;return true;}
bool applyLookDelta(int,double x,double y,int64_t){++looks;lookX+=x;lookY+=y;return true;}
void flushLookPending(bool,int){}
'''
names = [
    'static bool menuToolMouseHeldLocked(',
    'static bool schemaDispatchButton(',
    'static bool schemaUsesGroupPhases(',
    'static void schemaAdvanceGroupsLocked(',
    'static bool schemaGroupPhase(', 'static void schemaGroupLastUp(',
    'static void schemaTriggerFirstDown(', 'static void schemaTriggerLastUp(',
    'static void schemaPollLongPressLocked(', 'static void schemaEmitWasd(', 'static void schemaPollWasdLatchLocked(',
    'static void schemaApplyWasd(', 'static void schemaJoystick(', 'static void schemaScrollMove(',
    'static bool schemaOwnsMenuButtonLocked(',
    'static void schemaPollTouchHoldsLocked(', 'static void schemaBeginTouchCandidate(',
    'static void schemaMoveTouchCandidate(', 'static void schemaFinishTouchCandidate(',
    'static void schemaSwipeButtonLocked(', 'static SchemaFingerRole handleSchemaGrabbedTouch('
]
def definition(signature):
    """跳过同名的前置声明，必须取到真正带函数体的生产定义。"""
    found = re.search(re.escape(signature) + r'[^;{]*\{', source)
    assert found, signature
    return base['recipe'].block(source, found.start())

production = base['production'] + '\n' + '\n'.join(definition(name) for name in names)
main = r'''
void touch(int phase,int id,float x,float y,int64_t advance=10000000){
 clockNs+=advance;OH_NativeXComponent_TouchEvent event{phase,clockNs};handleSchemaGrabbedTouch(event,x,y,id);
}
int count(OutputKind kind,int code,int action){int n=0;for(const auto&e:edges)if(e.output.kind==kind&&e.output.code==code&&e.action==action)++n;return n;}
void reset(){schemaCancelGenerationLocked();ledger.releaseAll();edges.clear();axisPan=false;looks=scrolls=0;lookX=lookY=0;clockNs+=1000000000;}
AmclCtrlEntry button(const char*id,int key,float x){AmclCtrlEntry e{};std::strcpy(e.id,id);e.kind=0;e.keyOrMouse=key;e.x=x;e.y=100;e.w=100;e.h=100;return e;}
int main(){
 CHECK(initializeSourceFixture());
 reset();TouchInteractionConfig config;
 // UI解释域覆盖Native exact时只让出一次DOWN；MOVE离开UI也不得退回world/look或补一个Native按下。
 // 倒置定义数组证明该所有权不依赖schema末项；输出经真实Source/Core/bridge而非本地ledger。
 for(int reverse=0;reverse<2;++reverse){
  reset();AmclCtrlEntry ui=button("ui-region",0,0);ui.handledBy=1;ui.x=ui.y=0;ui.w=ui.h=300;
  AmclCtrlEntry native=button("native-overlap",65,100);native.w=native.h=20;
  AmclCtrlEntry overlap[2]={reverse?native:ui,reverse?ui:native};
  CHECK(ohos_set_control_schema_v3(overlap,2,1000,1000,1,.18f,3,&config)>0);
  touch(0,0,110,110);CHECK(s_schemaFingers[0].role==SCHEMA_FINGER_ARKTS);
  touch(2,0,500,500);touch(1,0,500,500);
  CHECK(edges.empty()&&ledger.ownerCount()==0&&looks==0);
 }
 // 普通press保留原DOWN认领。仅显式连滑可在UI exact区结束原输出，不能在Native仍有slop时漏末松。
 for(int swipe=0;swipe<2;++swipe){
  reset();AmclCtrlEntry native=button("native-held",65,100);native.swipeGroup=swipe;native.hitSlop=12;
  AmclCtrlEntry ui=button("ui-edge",0,180);ui.handledBy=1;ui.y=80;ui.w=160;ui.h=160;
  AmclCtrlEntry overlap[2]={native,ui};
  CHECK(ohos_set_control_schema_v3(overlap,2,1000,1000,1,.18f,3,&config)>0);
  touch(0,0,150,150);CHECK(ledger.isHeld({OutputKind::Key,65}));
  touch(2,0,185,150);CHECK(ledger.isHeld({OutputKind::Key,65})==(swipe==0));
  CHECK(count(OutputKind::Key,65,1)==1&&count(OutputKind::Key,65,0)==swipe&&looks==0);
  touch(1,0,185,150);CHECK(count(OutputKind::Key,65,0)==1&&ledger.ownerCount()==0);
 }
 // UI exact遮住Native slop是既有保护；没有UI时Native exact/最近中心/首个等距仍是原规则。
 reset();AmclCtrlEntry ui=button("ui-slop",0,100);ui.handledBy=1;
 AmclCtrlEntry slopNeighbor=button("native-slop",66,200);slopNeighbor.hitSlop=12;AmclCtrlEntry pair[2]={slopNeighbor,ui},hit{};
 CHECK(ohos_set_control_schema_v3(pair,2,1000,1000,1,.18f,3,&config)>0);
 CHECK(schemaHitTestLocked(195,150,hit)&&hit.handledBy==1);
 pair[1]=button("native-exact",65,100);
 CHECK(ohos_set_control_schema_v3(pair,2,1000,1000,1,.18f,3,&config)>0);
 CHECK(schemaHitTestLocked(195,150,hit)&&std::strcmp(hit.id,"native-exact")==0);
 pair[0]=button("small",66,100);pair[0].w=pair[0].h=20;pair[1]=button("large",65,0);pair[1].y=0;pair[1].w=pair[1].h=300;
 CHECK(ohos_set_control_schema_v3(pair,2,1000,1000,1,.18f,3,&config)>0);
 CHECK(schemaHitTestLocked(110,110,hit)&&std::strcmp(hit.id,"small")==0);
 pair[1]=pair[0];std::strcpy(pair[1].id,"same-center-second");
 CHECK(ohos_set_control_schema_v3(pair,2,1000,1000,1,.18f,3,&config)>0);
 CHECK(schemaHitTestLocked(110,110,hit)&&std::strcmp(hit.id,"small")==0);
 reset();
 AmclCtrlEntry keys[2]={button("a",65,100),button("b",65,220)};keys[0].swipeGroup=keys[1].swipeGroup=1;
 CHECK(ohos_set_control_schema_v3(keys,2,1000,1000,1,.18f,3,&config)>0);
 touch(0,0,150,150);touch(0,1,250,150);CHECK(count(OutputKind::Key,65,1)==1);
 touch(2,0,250,150);CHECK(count(OutputKind::Key,65,0)==0);
 touch(1,1,250,150);CHECK(count(OutputKind::Key,65,0)==0);
 touch(1,0,250,150);CHECK(count(OutputKind::Key,65,0)==1&&ledger.ownerCount()==0);

 // 教学热区优先于下面的真实按钮；移除热区不释放既有toggle，旧教学触点也不穿透补点。
 reset();keys[0].trigger=1;keys[0].swipeGroup=0;
 CHECK(ohos_set_control_schema_v3(keys,1,1000,1000,1,.18f,3,&config)>0);
 touch(0,0,150,150);touch(1,0,150,150);CHECK(ledger.isHeld({OutputKind::Key,65}));
 const auto beforeGuide=s_schemaGeneration;const auto edgesBeforeGuide=edges.size();
 CHECK(ohos_set_touch_guide_bounds(100,100,100,100));
 touch(0,1,150,150);CHECK(s_schemaFingers[1].role==SCHEMA_FINGER_ARKTS);
 CHECK(ohos_set_touch_guide_bounds(0,0,0,0));
 touch(2,1,170,170);touch(1,1,170,170);
 CHECK(s_schemaGeneration==beforeGuide&&edges.size()==edgesBeforeGuide&&ledger.isHeld({OutputKind::Key,65}));
 touch(0,1,150,150);touch(1,1,150,150);CHECK(!ledger.isHeld({OutputKind::Key,65}));

 reset();AmclCtrlEntry joy=button("joystick",0,100);joy.kind=1;joy.w=joy.h=200;
 config.floatingJoystick=true;config.sprint=true;config.autoWalk=true;
 config.actions[TouchForward]=73;config.actions[TouchLeft]=73;
 CHECK(ohos_set_control_schema_v3(&joy,1,1000,1000,1,.18f,3,&config)>0);
 touch(0,0,130,150);CHECK(ledger.ownerCount()==0);
 touch(2,0,130,40);CHECK(ledger.isHeld({OutputKind::Key,73})&&ledger.isHeld({OutputKind::Key,341}));
 touch(1,0,130,40);CHECK(!s_touchJoystick.Locked()&&!ledger.isHeld({OutputKind::Key,73}));
 touch(0,0,150,150,100000000);CHECK(!s_touchJoystick.Locked()&&!ledger.isHeld({OutputKind::Key,73}));
 touch(2,0,150,40,100000000);touch(3,0,150,40);CHECK(ledger.ownerCount()==0&&!s_touchJoystick.Locked());
 // 改键退休不能碰其它端的同键持有。
 const auto gamepadOwner=SourceAcquireControl({AMCL_INPUT_SOURCE_GAMEPAD,1,"fixture:gamepad"},{{OutputKind::Key,73}});
 CHECK(gamepadOwner!=0);touch(0,0,150,150);touch(2,0,150,40,100000000);
 auto remap=config;remap.actions[TouchForward]=74;
 CHECK(ohos_set_control_schema_v3(&joy,1,1000,1000,1,.18f,3,&remap)>0);
 CHECK(ledger.owns(gamepadOwner,{OutputKind::Key,73})&&!ledger.owns(OWNER_SCHEMA_WASD,{OutputKind::Key,73}));

 reset();config=TouchInteractionConfig{};config.hotbarSwap=true;config.hotbarDrop=true;config.holdMs=300;
 config.actions[TouchSwap]=82;config.actions[TouchDrop]=71;
 AmclCtrlEntry hotbar=button("hotbar",0,100);hotbar.kind=4;hotbar.w=180;hotbar.h=22;
 CHECK(ohos_set_control_schema_v3(&hotbar,1,1000,1000,1,.18f,3,&config)>0);
 touch(0,0,110,110);touch(1,0,110,110);touch(0,0,110,110);touch(1,0,110,110);
 CHECK(count(OutputKind::Key,82,1)==1&&ledger.ownerCount()==0);
 touch(0,0,130,110);clockNs+=310000000;schemaPollTouchHoldsLocked();
 CHECK(ledger.isHeld({OutputKind::Key,71}));touch(2,0,150,110);CHECK(!ledger.isHeld({OutputKind::Key,71}));
 touch(1,0,150,110);CHECK(ledger.ownerCount()==0);
 const int dropped=count(OutputKind::Key,71,1);
 touch(0,0,130,110);touch(3,0,130,110);clockNs+=400000000;schemaPollTouchHoldsLocked();
 CHECK(count(OutputKind::Key,71,1)==dropped);
 const int lastKey=lastPressedKey;touch(0,0,99,110);touch(1,0,99,110);CHECK(lastPressedKey==lastKey);

 reset();config=TouchInteractionConfig{};config.gestureMode=1;config.holdMs=300;
 CHECK(ohos_set_control_schema_v3(nullptr,0,1000,1000,1,.18f,3,&config)>0);
 touch(0,0,500,500);touch(1,0,500,500);CHECK(count(OutputKind::Mouse,1,1)==0&&ledger.ownerCount()==0);
 touch(0,0,500,500);touch(2,0,600,510);touch(1,0,600,510);
 CHECK(count(OutputKind::Mouse,1,1)==0&&looks==1&&lookX==100);
 touch(0,0,500,500);clockNs+=310000000;schemaPollTouchHoldsLocked();CHECK(!ledger.isHeld({OutputKind::Mouse,0}));
 touch(2,0,650,550);CHECK(!ledger.isHeld({OutputKind::Mouse,0}));touch(3,0,650,550);CHECK(ledger.ownerCount()==0);
 // 已知的滚轮镜像只允许原有look抑制，不得被新手势误认成攻击或使用。
 const int before=static_cast<int>(edges.size());axisPan=true;
 touch(0,0,500,500);touch(1,0,500,500);CHECK(static_cast<int>(edges.size())==before);
 axisPan=false;touch(0,0,500,500);axisPan=true;touch(1,0,500,500);CHECK(static_cast<int>(edges.size())==before);
 // 无组旧方案也沿菜单同一Native入口；不依赖组开关决定普通按钮解释权。
 reset();config=TouchInteractionConfig{};
 for(int trigger=0;trigger<4;++trigger){
   auto child=button("drawer-child",65,100);child.trigger=trigger;
   CHECK(ohos_set_control_schema_v3(&child,1,1000,1000,1,.18f,3,&config)>0);
   CHECK(!s_touchGroups.Enabled()&&schemaOwnsMenuButtonLocked(0,true,150,150));
   touch(0,0,150,150);CHECK(schemaOwnsMenuButtonLocked(0,false,900,900));
   touch(3,0,150,150);CHECK(!schemaOwnsMenuButtonLocked(0,false,150,150));
   reset();
 }
 auto system=button("system",0,100);system.handledBy=1;
 CHECK(ohos_set_control_schema_v3(&system,1,1000,1000,1,.18f,3,&config)>0);
 CHECK(!schemaOwnsMenuButtonLocked(0,true,150,150));
 std::cout<<"PASS production touch: multi-owner swipe, floating/sprint/cancel, remap isolation, hotbar gestures, look/axis suppression\n";
}
'''
# 仅显式装配复用时返回同一份生产函数/平台夹具，不执行旧main或宣布测试通过。
# 普通脚本及既有runpy调用仍完整执行原正例、编译负控和恢复，不以此模式跳过门禁。
if not globals().get('AMCL_TOUCH_RECIPE_ONLY', False):
    with temporary_directory(prefix='touch-production-') as directory:
        path = Path(directory) / 'touch.cpp'
        binary = Path(directory) / 'touch.exe'
        def check(body, negative=False):
            """负控必须完成同一真实Source闭包编译并命中UI所有权断言；配方/链接失败不算识别回归。"""
            path.write_text(prefix+body+main,encoding='utf-8',newline='\n')
            compile_source_fixture(path,binary,ROOT/'entry/src/main/cpp')
            result = subprocess.run([str(binary)],text=True,capture_output=True,timeout=20)
            if negative:
                assert result.returncode != 0 and 's_schemaFingers[0].role==SCHEMA_FINGER_ARKTS' in result.stderr, result.stdout+result.stderr
            else:
                assert result.returncode == 0, result.stdout+result.stderr
                print(result.stdout.strip())
        check(production)
        needle='if (pass == 0 && e.handledBy == 0) continue;'
        assert production.count(needle)==1
        check(production.replace(needle,'/* negative: Native exact participates in the UI-priority pass */',1),True)
        print('PASS compiled negative: removing UI exact priority restores the overlapping Native DOWN')
        # 最终再编译/运行真实生产，不能把末尾仍为撤回算法的二进制当成恢复成功。
        check(production)
        print('PASS restored production: UI domain blocks world fallback; original contact/swipe/nearest and Source contributions retained')
