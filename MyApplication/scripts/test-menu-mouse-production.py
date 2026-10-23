"""执行真实菜单工具owner/统计入口，只替换SDK身份、grab及中立bridge最终出口。

普通来源仍使用真实LegacyOutputRuntime，工具来源使用生产冻结租约集合；验证源隔离、
首按末松、完整快照、输出union、作用域/PID退休与有界拒绝。bridge真实三端消费另有组合回归。
"""
from pathlib import Path
import importlib.util
import os
import lib.source_host as source_host
import re
import subprocess
from lib.host_cpp import compile_cpp
from lib.source_host import compile_source_fixture, source_recording_prefix
from lib.workspace_paths import temporary_directory

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('menu_recipe',ROOT/'scripts/generate-desktop-review-tests.py')
recipe=importlib.util.module_from_spec(spec)
spec.loader.exec_module(recipe)
source=(ROOT/'entry/src/main/cpp/platform/touch_input.cpp').read_text(encoding='utf-8')
def definition(signature, body_source=source):
    """跳过前置声明，仅抽取产品实际函数体。"""
    match=re.search(re.escape(signature)+r'[^;{]*\{',body_source)
    assert match,signature
    return recipe.block(body_source,match.start())

# 本地compiled反控可显式提供已封存的原生产文件；只替换两个完整采样正文，不依赖私有gitref。
baseline_path=os.environ.get('AMCL_STATISTICS_NEGATIVE_SOURCE','')
baseline_source=Path(baseline_path).read_text(encoding='utf-8') if baseline_path else source
sampling_names={'static void sampleInputInvariants(', 'extern "C" void ohos_log_external_held_state('}

dependencies=['input_ledger.h' ,'source_control_client.h','legacy_output_code.h','touch_interaction.cpp',
              'touch_publication_state.h','input_invariants.cpp','render_scale.cpp','surface_input_gate_state.h','touch_group_state.h']
prefix='\n'.join('#include "'+(ROOT/'entry/src/main/cpp/platform'/p).as_posix()+'"' for p in dependencies)
prefix += '\n#include "'+(ROOT/'entry/src/main/cpp/input/input_menu_cursor_snapshot.h').as_posix()+'"\n'
prefix+=r'''
#include <atomic>
#include <algorithm>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <iostream>
#include <thread>
#include <cstdarg>
constexpr int LOG_APP=0;
unsigned heldLog[15]{};unsigned heldLogCount=0;
// 日志仅录制最终参数；不维护来源状态、不参与owner/Native准入。
void recordHostLog(int,const char* format,...){
 if(!format||std::strncmp(format,"AMCL_INSRC held ",16)!=0)return;
 va_list args;va_start(args,format);for(unsigned& value:heldLog)value=va_arg(args,unsigned);va_end(args);++heldLogCount;
}
#define OH_LOG_INFO(...) recordHostLog(__VA_ARGS__)
std::atomic<unsigned> fullSourceQueries{0},filteredSourceQueries{0};
// 此钩子只在外置的真实Source query入口计数；下面的生产resolver、getter、owner及query正文不替换。
extern "C" void recordSourceQuery(bool filtered){if(filtered)++filteredSourceQueries;else ++fullSourceQueries;}
void resetQueryCounts(){fullSourceQueries=0;filteredSourceQueries=0;}
std::string savedSourceEnvironment;
void removeSourceEnvironment(){
 // 发布本身为一次性准入；失败场景结束后恢复确切原材料，不能调用publish假装重建新owner。
 const char* value=std::getenv(AMCL_SOURCE_CONTROL_ENV);savedSourceEnvironment=value?value:"";
#ifdef _WIN32
 _putenv_s(AMCL_SOURCE_CONTROL_ENV,"");
#else
 unsetenv(AMCL_SOURCE_CONTROL_ENV);
#endif
}
void restoreSourceEnvironment(){
#ifdef _WIN32
 _putenv_s(AMCL_SOURCE_CONTROL_ENV,savedSourceEnvironment.c_str());
#else
 setenv(AMCL_SOURCE_CONTROL_ENV,savedSourceEnvironment.c_str(),1);
#endif
}
#define CHECK(x) do{if(!(x)){std::cerr<<"FAIL "<<__LINE__<<" "<<#x<<'\n';return 1;}}while(0)
using namespace amcl::input;
struct Event{int type,key,action;};std::vector<Event> events;
struct RelativeEvent{int type,phase;uint32_t token;double dx,dy,maxX,maxY;};std::vector<RelativeEvent> relatives;
struct GestureEvent{int phase;uint32_t token;};std::vector<GestureEvent> gestures;
unsigned menuEpoch=1;
extern "C" void inputBridge_retireTouchMenuScopeV1(){++menuEpoch;}
unsigned toolEpoch=1;
extern "C" void inputBridge_retireTouchMenuToolScopeV1(){++toolEpoch;}
extern "C" void inputBridge_pushTouchMenuToolV1(int code,int action){events.push_back({1011,code,action});}
extern "C" void inputBridge_publishTouchMenuScrollV1(int dx,int dy){events.push_back({1014,dx,dy});}
extern "C" void inputBridge_pushTouchMenuToolScrollV1(int dx,int dy){events.push_back({1015,dx,dy});}
extern "C" void inputBridge_publishTouchMenuToolCursorV1(double x,double y){events.push_back({1013,int(x),int(y)});}
extern "C" void inputBridge_publishTouchMenuCursorV1(double x,double y){events.push_back({1012,int(x),int(y)});}
extern "C" void inputBridge_publishTouchMenuToolRelativeV1(double dx,double dy,double mx,double my){relatives.push_back({1016,0,0,dx,dy,mx,my});events.push_back({1016,int(dx),int(dy)});}
extern "C" void inputBridge_publishTouchMenuRelativeV1(int phase,uint32_t token,double dx,double dy,double mx,double my){relatives.push_back({1017,phase,token,dx,dy,mx,my});gestures.push_back({phase,token});}
void sendEvent(int type,int a,int b,int c,int token){events.push_back({type,a,b});if(type==1008)gestures.push_back({a,uint32_t(token)});}
using pid_t=int;int currentPid=10;int getpid(){return currentPid;}
bool committedAvailable=true;double committedX=100,committedY=200;uint64_t committedPublication=7;unsigned committedQueries=0;
extern "C" int inputBridge_getCommittedMenuCursorV1(AmclCommittedMenuCursorV1* out){
 ++committedQueries;if(!committedAvailable)return 0;
 out->abiVersion=1;out->backend=1;out->flags=1;out->processId=currentPid;out->gameSession=3;
 out->logicalTarget=4;out->inputPublication=committedPublication;out->x=committedX;out->y=committedY;return 1;
}
std::mutex s_touchStateMutex,s_schemaMutex;
TouchGroupState s_touchGroups;int s_groupMouseControl=-1;std::vector<AmclCtrlEntry> s_schema;
struct GroupUiOwner{uint64_t token=0;int control=-1;};std::array<GroupUiOwner,512> s_groupUiOwners{};
std::recursive_mutex s_surfaceInputGateMutex;
surface_gate::State s_surfaceInputGate;
std::recursive_mutex s_inputTransactionMutex;
std::mutex s_externalInputMutex;
SourceRegistryProxy s_externalHeld;SourceLedgerProxy sourceLedger;SourcePhysicalProxy sourcePhysical;
SourceLedgerProxy& inputLedger(){return sourceLedger;}
SourcePhysicalProxy& physicalEdgeRouter(){return sourcePhysical;}
double s_menuMouseBounds[4]{},s_touchGuideBounds[4]{};
TouchGuideSignals s_touchGuide;
MenuTouchInteraction s_menuTouch;uint32_t s_touchMenuToken=0,s_touchMenuNextToken=0x40000000;
float s_schemaWidthPx=1000,s_schemaHeightPx=1000;
std::atomic<bool> s_touchMenuCursorVisible{false};
std::atomic<bool> s_touchPaused{false};bool grabbed=false,ready=true;int scrolls=0;
// 使用真实准入状态而不是恒真替身；grab公告代次来自平台边界，供抽取的生产退休函数写入。
TouchPublicationState s_touchAdmission;uint64_t s_touchPublicationGrabEpoch=0;
uint64_t testTouchDomain=3,s_touchContextPolicy=1,s_schemaGeneration=1;
double s_touchContextDensity=1;uint32_t s_touchContextTransform=0;bool s_grabFlipLastState=false;
namespace amcl::input {struct MenuTestDomains{uint64_t touch;};MenuTestDomains PlatformInputResetDomains(){return {testTouchDomain};}}
amcl::input::TouchPublicationContext touchPublicationContextLocked();
bool touchAdmissionAcceptsUiContinuationLocked(uint64_t token);
void resolveBridge(){}void reconcileLegacyRingDiscontinuity(){}
bool bridgeReady(){return ready;}bool isGrabbedMode(){return grabbed;}
bool finitePair(double x,double y){return std::isfinite(x)&&std::isfinite(y);}
bool consumeGrabEpochLocked(bool value){return value;}
bool routerScroll(AmclInputSource,int,int steps,bool){scrolls+=steps;return true;}
void resetMirrorGestureStateLocked(){}void flushLookPending(bool){}
std::set<OwnerToken> schemaCaptureHeldOwnersLocked(){return {};}
void schemaResetTransientStateLocked(const std::set<OwnerToken>&){}
void pthread_mutex_lock(std::mutex* m){m->lock();}void pthread_mutex_unlock(std::mutex* m){m->unlock();}
constexpr int MAX_FINGERS=10;bool s_fingerDown[MAX_FINGERS]{},s_fingerDead[MAX_FINGERS]{},s_wheelGestureIntegral[MAX_FINGERS]{};
constexpr int GLFW_PRESS=1,GLFW_RELEASE=0;
constexpr int EVENT_TYPE_MENU_POINTER=1008,MENU_POINTER_MOVE=0,MENU_POINTER_DOWN=1,MENU_POINTER_UP=2,MENU_POINTER_CANCEL=3,MENU_POINTER_BEGIN=4,MENU_POINTER_END=5;
extern "C" unsigned amcl_input_source_look_count(AmclInputSource){return 0;}
unsigned sourceScrolls=0;
extern "C" unsigned amcl_input_source_scroll_count(AmclInputSource source){return source==AMCL_INPUT_SOURCE_TOUCH_CONTROLS?sourceScrolls:0;}
extern "C" void amcl_input_source_note_scroll(AmclInputSource){++sourceScrolls;}
namespace amcl::input::census{enum class Channel{LookApplied,ScrollDelivered};std::atomic<unsigned> g_counters[2]{};void Bump(Channel c){++g_counters[int(c)];}}
AmclInputSource normalizeInputSource(int source){return static_cast<AmclInputSource>(source);}
static void releaseMenuToolControls(bool retireRegistration=true);
'''
prefix += source[source.index('struct MenuToolOwner {'):source.index('static void releaseMenuToolControls(')]
production=definition('struct MenuToolHeldSnapshot')+';\n'+'\n'.join(definition(name,baseline_source if name in sampling_names else source) for name in [
    'amcl::input::TouchPublicationContext touchPublicationContextLocked(', 'bool touchAdmissionAcceptsUiContinuationLocked(',
    'static void reconcileMenuToolProcessLocked(', 'static MenuToolHeldSnapshot menuToolHeldSnapshot(',
    'static bool menuToolMouseHeldLocked(', 'static void sampleInputInvariants(',
    'extern "C" void ohos_log_external_held_state(',
    'static bool parseMenuToolPanelPrefix(', 'static bool menuToolPanelMatchesLocked(',
    'static bool emitScopedMenuScroll(', 'static bool mapMenuRelativePayload(', 'static bool adoptCommittedMenuCursorLocked(',
    'static void emitMenuToolPosition(', 'static void emitMenuInteraction(',
    'extern "C" bool ohos_release_source_control(', 'static void releaseMenuToolControls(',
    'static void retireTouchMenuSurfaceScope(',
    'extern "C" bool ohos_cancel_touch_menu_mouse(',
    'extern "C" bool ohos_touch_menu_button(', 'extern "C" bool ohos_touch_menu_scroll(',
    'extern "C" bool ohos_move_touch_menu_pointer(',
    'static bool setTouchOverlayBounds(', 'extern "C" bool ohos_set_menu_mouse_bounds(',
    'extern "C" bool ohos_set_menu_mouse_bounds_for_panel(',
    'extern "C" bool ohos_set_touch_guide_bounds(',
    'static void onGrabFlipCancel(', 'extern "C" void ohos_release_input_source_held(', 'static void legacyRingResetSchema('])
# 本门明确把菜单SDK getter/作用域投递当录制边缘；重命名避免覆盖真实neutral bridge导出。
# 普通来源则完整借Source/Core/bridge，记录器不持有registry/ledger或分配token。
for boundary in re.findall(r'extern "C" (?:void|int) (inputBridge_\w+)\(',prefix):
    replacement='fixture_'+boundary
    prefix=re.sub(r'\b'+re.escape(boundary)+r'\b',replacement,prefix)
    production=re.sub(r'\b'+re.escape(boundary)+r'\b',replacement,production)
prefix=source_recording_prefix(ROOT/'entry/src/main/cpp')+prefix
prefix+='\nvoid recordSourceEdge(const Output& output,int action){events.push_back({output.kind==OutputKind::Key?1005:1006,output.code,action});}\n'
prefix+='\n#include "platform/mapped_look_producer.h"\n'
# 启用真实日志参数后，来源名字叶函数也逐字抽取生产正文，避免用命名替身填链接。
name_source=(ROOT/'entry/src/main/cpp/platform/input_source.cpp').read_text(encoding='utf-8')
prefix+='\n'+definition('extern "C" const char* amcl_input_source_name(',name_source)+'\n'
main=r'''
std::string panel(unsigned id){return "mouse-panel-"+std::to_string(id)+":";}
std::string owner(unsigned id,const char* key){return panel(id)+key;}
uint64_t currentPublication=0;unsigned uiOperation=0;
void confirmPanelUi(){auto context=touchPublicationContextLocked();context.nativeTouches=0;
 const auto operation="panel-ui-"+std::to_string(++uiOperation);
 const auto receipt=s_touchAdmission.Begin(operation,"panel",context,context);s_touchAdmission.Complete(context,false);
 if(!s_touchAdmission.Confirm(operation,receipt.token,context))std::abort();currentPublication=receipt.token;}
bool registerPanel(unsigned id,uint64_t publication=0,double x=10){if(publication==0)publication=currentPublication;return ohos_set_menu_mouse_bounds_for_panel(x,20,152,208,panel(id).c_str(),publication);}
bool button(unsigned id,const char* key,int code,bool down){return ohos_touch_menu_button(owner(id,key).c_str(),code,down,down?currentPublication:0);}
int main(){
 // 未建立连接时真实环境缺席必须返回零快照，且不调用任何owner query。
 // 该边界放在初始化前；已借出的进程pin表不因移除发现公告而失效。
 AmclInputInvariantSnapshot emptyStats{};removeSourceEnvironment();
 std::memset(&emptyStats,0xff,sizeof(emptyStats));resetQueryCounts();sampleInputInvariants(&emptyStats);
 CHECK(emptyStats.physicalIdentityLive==0&&emptyStats.ledgerOwnerLive==0&&emptyStats.ledgerOutputLive==0&&emptyStats.maxSameSourceHeld==0);
 for(int i=0;i<AMCL_INPUT_SOURCE_COUNT;++i)CHECK(emptyStats.heldLive[i]==0&&emptyStats.heldAcquired[i]==0&&emptyStats.heldReleased[i]==0);
 CHECK(fullSourceQueries==0&&filteredSourceQueries==0);ohos_log_external_held_state();for(unsigned value:heldLog)CHECK(value==0);
 CHECK(fullSourceQueries==0&&filteredSourceQueries==0);restoreSourceEnvironment();
 CHECK(initializeSourceFixture());
 // 在真实owner/consumer已装配、没有菜单工具时，两完整函数分别只做一次统计query。
 // 旧完整函数反控实际读数19/15；先打印两读数再断言，编译失败或超时不能代替行为失败。
 resetQueryCounts();sampleInputInvariants(&emptyStats);
 const unsigned invariantReads=fullSourceQueries.load(),invariantFiltered=filteredSourceQueries.load();
 resetQueryCounts();ohos_log_external_held_state();const unsigned logReads=fullSourceQueries.load();
 std::cout<<"statistics actual query invariant="<<invariantReads<<" log="<<logReads<<" filtered="<<invariantFiltered<<std::endl;
 CHECK(invariantReads==1&&invariantFiltered==0&&logReads==1&&filteredSourceQueries==0);
 resetQueryCounts();sampleInputInvariants(nullptr);CHECK(fullSourceQueries==0&&filteredSourceQueries==0);
 CHECK(SourceSnapshot().size==sizeof(AmclSourceSnapshotV1));
 s_surfaceInputGate.active=true;s_surfaceInputGate.publicationGeneration=7;
 s_menuTouch.Configure(1000,1000,1,TouchInteractionConfig{},[](MenuTouchAction,double,double){});
 confirmPanelUi();CHECK(currentPublication!=0);
 const Output left{OutputKind::Mouse,0},shift{OutputKind::Key,340};
 uint64_t parsed=0;CHECK(parseMenuToolPanelPrefix("mouse-panel-1:",&parsed)&&parsed==1);
 CHECK(!parseMenuToolPanelPrefix("mouse-panel-0:",&parsed)&&!parseMenuToolPanelPrefix("mouse-panel-01:",&parsed));
 CHECK(!parseMenuToolPanelPrefix("mouse-panel-9007199254740992:",&parsed));
 CHECK(!button(1,"unregistered",-1,true)&&!ohos_touch_menu_scroll(1,panel(1).c_str(),currentPublication)&&!ohos_move_touch_menu_pointer(1,1,panel(1).c_str(),currentPublication));
 CHECK(registerPanel(1));
 const auto pad=SourceAcquireControl({AMCL_INPUT_SOURCE_GAMEPAD,7,"pad"},{left});CHECK(pad!=0);
 CHECK(button(1,"press",-1,true)&&button(1,"lock",-1,true));CHECK(inputLedger().ownerCount()==1&&events.size()==2);
 CHECK(!ohos_touch_menu_button(owner(1,"press").c_str(),-1,true,currentPublication+2));
 CHECK(!ohos_move_touch_menu_pointer(1,1,panel(1).c_str(),currentPublication+2)&&!ohos_touch_menu_scroll(1,panel(1).c_str(),currentPublication+2));
 CHECK(button(1,"press",-1,true)&&!button(1,"press",-2,true));
 auto tool=menuToolHeldSnapshot();CHECK(tool.live==2&&tool.acquired==2&&tool.released==0&&tool.outputMask==1&&tool.maxSameCode==2);
 AmclInputInvariantSnapshot snapshot{};sampleInputInvariants(&snapshot);CHECK(snapshot.ledgerOwnerLive==3&&snapshot.ledgerOutputLive==1);
 CHECK(amcl_input_invariants_evaluate(&snapshot)==0);
 const auto unchangedEpoch=toolEpoch;CHECK(registerPanel(1,currentPublication,35));CHECK(toolEpoch==unchangedEpoch&&menuToolHeldSnapshot().live==2);
 CHECK(!registerPanel(2)&&!button(2,"steal",-1,true));
 CHECK(ohos_set_touch_guide_bounds(200,10,300,60)&&ohos_set_touch_guide_bounds(0,0,0,0));CHECK(menuToolHeldSnapshot().live==2);
 CHECK(button(1,"press",-2,false)&&button(1,"right",-2,true)&&button(1,"shift",340,true));
 int mapped=-1;const auto physical=physicalEdgeRouter().Route(true,{OutputKind::Key,9,340},&shift,LegacyPhysicalAction::Down,0,&mapped);
 CHECK(physical==AMCL_LEGACY_PHYSICAL_EMITTED&&SourceSnapshot().physical==1);
 // 一份普通来源统计与三个必要定向交集query分别计数，common/tool共持LEFT/Shift仍只计一次。
 const auto sourceStats=SourceSnapshot();tool=menuToolHeldSnapshot();resetQueryCounts();sampleInputInvariants(&snapshot);
 CHECK(fullSourceQueries==1&&filteredSourceQueries==3&&snapshot.physicalIdentityLive==sourceStats.physical);
 CHECK(snapshot.ledgerOwnerLive==sourceStats.owners+tool.live&&snapshot.ledgerOutputLive==3);
 CHECK(snapshot.maxSameSourceHeld==std::max(sourceStats.maxSameSource,tool.maxSameCode));
 for(int i=0;i<AMCL_INPUT_SOURCE_COUNT;++i){const unsigned add=i==AMCL_INPUT_SOURCE_TOUCH_CONTROLS?tool.live:0;
  CHECK(snapshot.heldLive[i]==sourceStats.held[i]+add);
  CHECK(snapshot.heldAcquired[i]==sourceStats.acquired[i]+(i==AMCL_INPUT_SOURCE_TOUCH_CONTROLS?tool.acquired:0));
  CHECK(snapshot.heldReleased[i]==sourceStats.released[i]+(i==AMCL_INPUT_SOURCE_TOUCH_CONTROLS?tool.released:0));}
 resetQueryCounts();ohos_log_external_held_state();CHECK(fullSourceQueries==1&&filteredSourceQueries==0);
 const unsigned order[5]={AMCL_INPUT_SOURCE_TOUCH_CONTROLS,AMCL_INPUT_SOURCE_GAMEPAD,AMCL_INPUT_SOURCE_PHYSICAL_KBM,AMCL_INPUT_SOURCE_PLATFORM_GESTURE,AMCL_INPUT_SOURCE_NONE};
 for(unsigned i=0;i<5;++i){const unsigned s=order[i];CHECK(heldLog[i]==snapshot.heldLive[s]);CHECK(heldLog[i+5]==snapshot.heldAcquired[s]);CHECK(heldLog[i+10]==snapshot.heldReleased[s]);}
 // 公告撤下阻止新握手，不能把已有真实source/tool共持投影成只剩tool或伪造零持有。
 removeSourceEnvironment();const AmclSourceControlPortV1* cold=nullptr;
 CHECK(amclSourceControlResolveV1(&cold)<0&&cold==nullptr);resetQueryCounts();sampleInputInvariants(&snapshot);
 CHECK(fullSourceQueries==1&&filteredSourceQueries==3&&snapshot.ledgerOwnerLive==sourceStats.owners+tool.live&&
       snapshot.ledgerOutputLive==3&&snapshot.physicalIdentityLive==sourceStats.physical);
 ohos_log_external_held_state();CHECK(fullSourceQueries==2&&filteredSourceQueries==3);
 for(unsigned i=0;i<5;++i){const unsigned s=order[i];
  CHECK(heldLog[i]==snapshot.heldLive[s]&&heldLog[i+5]==snapshot.heldAcquired[s]&&heldLog[i+10]==snapshot.heldReleased[s]);}
 restoreSourceEnvironment();CHECK(SourceSnapshot().owners==sourceStats.owners);
 sampleInputInvariants(&snapshot);CHECK(snapshot.ledgerOwnerLive==5&&snapshot.ledgerOutputLive==3&&amcl_input_invariants_evaluate(&snapshot)==0);
 CHECK(ohos_move_touch_menu_pointer(5,7,panel(1).c_str(),currentPublication)&&events.back().type==1016&&relatives.back().dx==5&&relatives.back().dy==7);
 CHECK(ohos_touch_menu_scroll(3,panel(1).c_str(),currentPublication)&&events.back().type==1015);
 emitMenuInteraction(MenuTouchAction::Scroll,0,2);CHECK(events.back().type==1014);
 sampleInputInvariants(&snapshot);CHECK(amcl_input_invariants_evaluate(&snapshot)==0);
 const auto directEpoch=menuEpoch;CHECK(ohos_cancel_touch_menu_mouse(panel(1).c_str()));
 CHECK(menuEpoch==directEpoch&&menuToolHeldSnapshot().live==0&&s_menuToolPanelPrefix==panel(1));
 CHECK(s_menuTouch.X()==100&&s_menuTouch.Y()==200);
 // 未消费desired B取消只承接实际A；actual C已消费后取消B须保C，不恢复手势初始A。
 CHECK(ohos_move_touch_menu_pointer(200,0,panel(1).c_str(),currentPublication)&&relatives.back().dx==200);
 CHECK(ohos_cancel_touch_menu_mouse(panel(1).c_str())&&s_menuTouch.X()==100);
 CHECK(ohos_move_touch_menu_pointer(1,0,panel(1).c_str(),currentPublication)&&s_menuTouch.X()==101&&relatives.back().dx==1);
 committedX=300;CHECK(ohos_move_touch_menu_pointer(50,0,panel(1).c_str(),currentPublication));
 CHECK(ohos_cancel_touch_menu_mouse(panel(1).c_str())&&s_menuTouch.X()==300);
 amcl::renderscale::PublishSnapshot(1000,1000,500,500);committedX=25;committedY=50;
 CHECK(ohos_cancel_touch_menu_mouse(panel(1).c_str())&&s_menuTouch.X()==50&&s_menuTouch.Y()==100);
 CHECK(ohos_move_touch_menu_pointer(1,0,panel(1).c_str(),currentPublication)&&relatives.back().dx==.5&&relatives.back().maxX==499.5);
 amcl::renderscale::ResetSnapshot();committedX=100;committedY=200;
 // 实际策略→真实Native emitter：UP只松LEFT，同一token保持到END；direct活跃时tool取消不读ACK。
 gestures.clear();s_menuTouch.Event(TouchPhase::Down,0,700,800,1000000000,emitMenuInteraction);
 const auto activeToken=s_touchMenuToken,queryBefore=committedQueries;CHECK(activeToken!=0&&s_menuTouch.DirectActive());
 CHECK(ohos_cancel_touch_menu_mouse(panel(1).c_str())&&committedQueries==queryBefore&&s_menuTouch.X()==700);
 s_menuTouch.Event(TouchPhase::Up,0,710,810,1100000000,emitMenuInteraction);
 CHECK(gestures.size()==5&&gestures[0].phase==4&&gestures[1].phase==1&&gestures[3].phase==2&&gestures[4].phase==5);
 for(const auto& event:gestures)CHECK(event.token==activeToken);CHECK(s_touchMenuToken==0);
 TouchInteractionConfig relative;relative.touchpad=true;relative.menuScroll=false;
 s_menuTouch.Configure(1000,1000,1,relative,emitMenuInteraction);relatives.clear();gestures.clear();
 s_menuTouch.Event(TouchPhase::Down,1,10,10,2000000000,emitMenuInteraction);const auto relativeToken=s_touchMenuToken;
 s_menuTouch.Event(TouchPhase::Up,1,12,13,2100000000,emitMenuInteraction);
 CHECK(relatives.size()==4&&relatives[0].phase==4&&relatives[1].phase==1&&relatives[1].dx==2&&relatives[1].dy==3&&
       relatives[2].phase==2&&relatives[3].phase==5&&relatives[3].dx==0&&s_touchMenuToken==0);
 for(const auto& event:relatives)CHECK(event.token==relativeToken);
 s_menuTouch.Configure(1000,1000,1,TouchInteractionConfig{},emitMenuInteraction);
 CHECK(inputLedger().isHeld(left)&&inputLedger().isHeld(shift));
 CHECK(button(1,"after-cancel",-1,true)&&button(1,"after-cancel",-1,false));
 const auto afterUp=toolEpoch;CHECK(ohos_cancel_touch_menu_mouse(panel(1).c_str())&&toolEpoch==afterUp+1);
 CHECK(registerPanel(2));const auto newEpoch=toolEpoch;
 CHECK(!registerPanel(1)&&!button(1,"late",-1,true)&&!ohos_touch_menu_scroll(1,panel(1).c_str(),currentPublication));
 CHECK(!ohos_move_touch_menu_pointer(1,1,panel(1).c_str(),currentPublication));
 CHECK(!ohos_set_menu_mouse_bounds_for_panel(0,0,0,0,panel(1).c_str(),currentPublication));CHECK(s_menuToolPanelPrefix==panel(2));
 CHECK(button(2,"left",-1,true));CHECK(ohos_cancel_touch_menu_mouse(panel(1).c_str())&&toolEpoch==newEpoch&&menuToolHeldSnapshot().live==1);
 CHECK(button(2,"left",-1,false));
 CHECK(ohos_set_menu_mouse_bounds_for_panel(0,0,0,0,panel(2).c_str(),currentPublication));CHECK(s_menuToolPanelPrefix.empty());
 CHECK(!registerPanel(1)&&registerPanel(2)); // 同实例重开可视bounds，旧较小序号仍不能反抢。
 s_fingerDown[2]=true;grabbed=true;onGrabFlipCancel(true);CHECK(s_fingerDead[2]&&s_menuToolPanelPrefix.empty());
 CHECK(!button(2,"grabbed",-1,true)&&!ohos_touch_menu_scroll(1,panel(2).c_str(),currentPublication));
 CHECK(SourceReleaseControl(pad));CHECK(physicalEdgeRouter().Route(true,{OutputKind::Key,9,340},&shift,LegacyPhysicalAction::Up,0,&mapped)==AMCL_LEGACY_PHYSICAL_EMITTED);
 grabbed=false;onGrabFlipCancel(false);
 s_fingerDown[2]=false; // 该独立grab样本的真实终止后不把旧SDK接触带入后面的pending样本。
 confirmPanelUi();
 CHECK(registerPanel(3)&&button(3,"held",-1,true));ohos_release_input_source_held(AMCL_INPUT_SOURCE_TOUCH_CONTROLS);
 CHECK(s_menuToolPanelPrefix.empty()&&menuToolHeldSnapshot().live==0&&registerPanel(4));
 CHECK(button(4,"new",-1,true)&&button(3,"held",-1,false)&&menuToolHeldSnapshot().live==1);CHECK(button(4,"new",-1,false));
 CHECK(button(4,"ring",-1,true));legacyRingResetSchema(nullptr);CHECK(s_menuToolOwners.empty()&&s_menuToolPanelPrefix.empty());
 CHECK(registerPanel(5));s_touchPaused=true;CHECK(!button(5,"paused",-2,true)&&!ohos_touch_menu_scroll(1,panel(5).c_str(),currentPublication));s_touchPaused=false;
 ready=false;CHECK(!button(5,"unready",-2,true));ready=true;
 CHECK(!button(5,"bad",87,true)&&!ohos_touch_menu_scroll(33,panel(5).c_str(),currentPublication)&&!ohos_touch_menu_scroll(0,panel(5).c_str(),currentPublication));
 const auto modal=s_touchAdmission.AcquireModal("chat");CHECK(modal&&!button(5,"modal",-1,true)&&!ohos_touch_menu_scroll(1,panel(5).c_str(),currentPublication));
 CHECK(s_touchAdmission.ReleaseModal(modal)&&ohos_touch_menu_scroll(-1,panel(5).c_str(),currentPublication));
 // 实际confirmed token与Native getter：waiting只挡新owner，动态touches=1不改变原UI身份。
 CHECK(button(5,"continuing",-1,true));const auto oldUi=currentPublication;s_fingerDown[0]=true;
 const auto current=touchPublicationContextLocked();const auto pending=s_touchAdmission.Begin("pending-panel","new-layout",current,current);
 CHECK(pending.status==TouchPublicationStatus::Waiting&&!s_touchAdmission.AcceptsUiToken(oldUi));
 CHECK(ohos_move_touch_menu_pointer(1,1,panel(5).c_str(),oldUi)&&ohos_touch_menu_scroll(1,panel(5).c_str(),oldUi));
 CHECK(!button(5,"new-while-waiting",-1,true));
 CHECK(!ohos_move_touch_menu_pointer(1,1,panel(4).c_str(),oldUi)&&!ohos_touch_menu_scroll(1,panel(4).c_str(),oldUi));
 CHECK(!ohos_move_touch_menu_pointer(1,1,panel(5).c_str(),pending.token));
 const auto pendingState=s_touchAdmission;
 // 每项是独立输入场景，复制真实State复位夹具，不用布尔替身替代身份比较。
 ++testTouchDomain;CHECK(!ohos_move_touch_menu_pointer(1,1,panel(5).c_str(),oldUi));--testTouchDomain;s_touchAdmission=pendingState;
 ++s_touchContextPolicy;CHECK(!ohos_touch_menu_scroll(1,panel(5).c_str(),oldUi));--s_touchContextPolicy;s_touchAdmission=pendingState;
 ++s_schemaGeneration;CHECK(!ohos_move_touch_menu_pointer(1,1,panel(5).c_str(),oldUi));--s_schemaGeneration;s_touchAdmission=pendingState;
 ++s_touchContextDensity;CHECK(!ohos_touch_menu_scroll(1,panel(5).c_str(),oldUi));--s_touchContextDensity;s_touchAdmission=pendingState;
 ++s_touchContextTransform;CHECK(!ohos_move_touch_menu_pointer(1,1,panel(5).c_str(),oldUi));--s_touchContextTransform;s_touchAdmission=pendingState;
 ++s_touchPublicationGrabEpoch;CHECK(!ohos_touch_menu_scroll(1,panel(5).c_str(),oldUi));--s_touchPublicationGrabEpoch;s_touchAdmission=pendingState;
 ++s_surfaceInputGate.publicationGeneration;CHECK(!ohos_move_touch_menu_pointer(1,1,panel(5).c_str(),oldUi));--s_surfaceInputGate.publicationGeneration;s_touchAdmission=pendingState;
 s_surfaceInputGate.active=false;CHECK(!ohos_touch_menu_scroll(1,panel(5).c_str(),oldUi));s_surfaceInputGate.active=true;s_touchAdmission=pendingState;
 s_touchPaused=true;CHECK(!ohos_move_touch_menu_pointer(1,1,panel(5).c_str(),oldUi));s_touchPaused=false;
 grabbed=true;CHECK(!ohos_touch_menu_scroll(1,panel(5).c_str(),oldUi));grabbed=false;
 const auto waitingModal=s_touchAdmission.AcquireModal("waiting-modal");CHECK(waitingModal&&!ohos_move_touch_menu_pointer(1,1,panel(5).c_str(),oldUi));
 CHECK(s_touchAdmission.ReleaseModal(waitingModal));
 CHECK(button(5,"continuing",-1,false));s_fingerDown[0]=false;
 CHECK(s_touchAdmission.Prepare("pending-panel",touchPublicationContextLocked()).status==TouchPublicationStatus::Fenced);
 CHECK(ohos_move_touch_menu_pointer(1,1,panel(5).c_str(),oldUi));
 s_touchAdmission.Complete(touchPublicationContextLocked(),true);
 CHECK(!ohos_move_touch_menu_pointer(1,1,panel(5).c_str(),oldUi)&&!ohos_touch_menu_scroll(1,panel(5).c_str(),pending.token));
 CHECK(s_touchAdmission.Confirm("pending-panel",pending.token,touchPublicationContextLocked()));currentPublication=pending.token;CHECK(registerPanel(5));
 CHECK(ohos_move_touch_menu_pointer(1,1,panel(5).c_str(),currentPublication)&&!ohos_move_touch_menu_pointer(1,1,panel(5).c_str(),oldUi));
 for(int i=0;i<32;++i)CHECK(ohos_touch_menu_button((panel(5)+std::to_string(i)).c_str(),-1,true,currentPublication));
 const auto atLimit=menuToolHeldSnapshot();CHECK(!button(5,"overflow",-1,true));CHECK(menuToolHeldSnapshot().acquired==atLimit.acquired);
 retireTouchMenuSurfaceScope();CHECK(s_menuToolPanelPrefix.empty()&&menuToolHeldSnapshot().live==0);
 CHECK(registerPanel(6));std::atomic<bool> done{false};
 std::thread worker([&](){for(int i=0;i<200;++i){button(6,"worker",-1,true);button(6,"worker",-1,false);}done=true;});
 bool consistent=true;while(!done.load()){auto state=menuToolHeldSnapshot();if(state.acquired-state.released!=state.live)consistent=false;}worker.join();CHECK(consistent);
 CHECK(ohos_set_menu_mouse_bounds_for_panel(0,0,0,0,panel(6).c_str(),currentPublication));CHECK(!registerPanel(1));confirmPanelUi();CHECK(registerPanel(1));
 CHECK(button(1,"parent",340,true));const auto parentEpoch=menuEpoch;++currentPid;
 tool=menuToolHeldSnapshot();CHECK(tool.live==0&&tool.acquired==0&&tool.released==0&&menuEpoch==parentEpoch+1&&s_menuToolRegistrationPublication==0);
 CHECK(button(1,"parent",340,false));sampleInputInvariants(&snapshot);CHECK(amcl_input_invariants_evaluate(&snapshot)==0);
 std::cout<<"PASS real menu tools: actual visible registration, same-instance held retention, safe prefix/watermark, source-scoped cursor/wheel, direct scroll, precise cancel/late-instance rejection, owner statistics/output union, capacity, PID and reset\n";
}
'''
with temporary_directory(prefix='menu-mouse-production-') as directory:
    path=Path(directory)/'menu_mouse.cpp';binary=Path(directory)/'menu_mouse.exe'
    path.write_text(prefix+production+main,encoding='utf-8',newline='\n')
    cpp=ROOT/'entry/src/main/cpp'
    # 外置生成一份生产Source TU，仅在query入口加纯计数；包含路径转绝对，余算法原正文保留。
    # 精确替换唯一原Source TU，不同时链接两份owner，也不伪造descriptor/Port/provider。
    provider=cpp/'input/source/source_control.cpp'
    provider_text=provider.read_text(encoding='utf-8')
    signature='int32_t query(uint64_t producer,uint64_t owner,const AmclSourceOutputV1* value,AmclSourceSnapshotV1* snapshot){'
    assert provider_text.count(signature)==1
    provider_text=provider_text.replace(signature,signature+'\n    recordSourceQuery(value!=nullptr);')
    provider_text='extern "C" void recordSourceQuery(bool);\n'+provider_text
    provider_text=re.sub(r'#include "([^"\n]+)"',lambda match:'#include "'+(provider.parent/match[1]).resolve().as_posix()+'"',provider_text)
    instrumented=Path(directory)/'source_control_counted.cpp';instrumented.write_text(provider_text,encoding='utf-8',newline='\n')
    actual_dependencies=source_host.source_dependencies
    def counted_dependencies(cpp_root):
        """本次构建只换上述计数版实际TU；原helper及其它生产依赖字节不改。"""
        return [instrumented if item==provider else item for item in actual_dependencies(cpp_root)]
    source_host.source_dependencies=counted_dependencies
    try:
        compile_source_fixture(path,binary,cpp,[cpp/'platform/mapped_look_producer.cpp',cpp/'platform/source_look_producer.cpp',cpp/'platform/source_look_processor.cpp'])
    finally:
        source_host.source_dependencies=actual_dependencies
    result=subprocess.run([str(binary)],text=True,capture_output=True,timeout=20)
    assert result.returncode==0,result.stdout+result.stderr
    print(result.stdout.strip())
