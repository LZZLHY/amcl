"""复用原平台夹具与真实 Source 实现，执行真实触控/阶段/组提交/定向退休函数。"""
from pathlib import Path
import runpy
import subprocess
from lib.source_host import compile_source_fixture
from lib.workspace_paths import temporary_directory

ROOT = Path(__file__).resolve().parents[1]
recipe = runpy.run_path(str(ROOT / 'scripts/test-touch-production.py'), init_globals={'AMCL_TOUCH_RECIPE_ONLY': True})
# 反馈仍由生产代码发出；只把最终NAPI出口从空SDK替身换成按控件记录，不能镜像松开算法。
prefix = recipe['prefix'].replace('void amcl_fire_button_pressed(const char*,int){}',
    'std::map<std::string,int> buttonFeedback;void amcl_fire_button_pressed(const char* id,int pressed){buttonFeedback[id]=pressed;}')
assert 'buttonFeedback[id]=pressed' in prefix
extra='\n'.join(recipe['definition'](name) for name in ['static void schemaCaptureCarriedMenuDragLocked(',
    'static std::set<OwnerToken> schemaCaptureHeldOwnersLocked(',
    'static bool schemaCollectCarriedUpLocked(', 'static void schemaResetTransientStateLocked('])
main = r'''
void touch(int phase,int id,float x,float y,int64_t advance=10000000){
 clockNs+=advance;OH_NativeXComponent_TouchEvent event{phase,clockNs};handleSchemaGrabbedTouch(event,x,y,id);
}
int count(int code,int action){int n=0;for(const auto&e:edges)if(e.output.kind==OutputKind::Key&&e.output.code==code&&e.action==action)++n;return n;}
AmclCtrlEntry button(const char*id,int key,float x){AmclCtrlEntry e{};std::strcpy(e.id,id);e.kind=0;e.keyOrMouse=key;e.x=x;e.y=100;e.w=80;e.h=80;return e;}
void confirmed(){if(s_touchGroups.PendingPresentation()){s_touchGroups.Confirm(s_touchGroups.Revision());schemaAdvanceGroupsLocked();}}
int main(){
 CHECK(initializeSourceFixture());
 TouchInteractionConfig config;
 AmclCtrlEntry entries[4]={button("joy",0,0),button("open",0,150),button("shift",0,300),button("close",0,450)};
 entries[0].kind=1;
 TouchGroupSchema schema;schema.profile="groups-production";schema.groups={{"base",true},{"tools",false}};schema.controls.resize(4);
 for(int i=0;i<4;++i){schema.controls[i].group=i==2?1:0;schema.controls[i].rank=i;schema.controls[i].phases=i!=0;}
 schema.controls[1].bindings[0].actions={{1,TouchGroupOperation::Toggle}};
 schema.controls[2].bindings[0].keys={340};
 schema.controls[3].bindings[0].actions={{1,TouchGroupOperation::Hide}};
 CHECK(setControlSchemaWithGroups(entries,4,1000,1000,1,.18f,4,&config,&schema)>0);
 touch(0,0,40,102);CHECK(ledger.isHeld({OutputKind::Key,87}));
 const auto joyOwner=s_schemaFingers[0].owner;const auto joyRole=s_schemaFingers[0].role;
 touch(0,1,180,130);CHECK(s_touchGroups.Visible(2));
 CHECK(s_schemaFingers[0].owner==joyOwner&&s_schemaFingers[0].role==joyRole&&ledger.isHeld({OutputKind::Key,87}));
 confirmed();touch(1,1,180,130);
 touch(0,2,330,130);CHECK(ledger.isHeld({OutputKind::Key,340}));CHECK(buttonFeedback["shift"]==1);
 const auto other=SourceAcquireControl({AMCL_INPUT_SOURCE_GAMEPAD,0,"pad-shift"},{{OutputKind::Key,340}});CHECK(other!=0);
 touch(0,3,480,130);CHECK(!s_touchGroups.Visible(2));CHECK(ledger.isHeld({OutputKind::Key,340}));
 CHECK(buttonFeedback["shift"]==0); // 本组高亮结束，不受其它来源仍持同键影响。
 CHECK(count(340,0)==0&&ledger.isHeld({OutputKind::Key,87}));
 touch(2,2,330,130);touch(1,2,330,130);CHECK(ledger.isHeld({OutputKind::Key,340}));
 CHECK(SourceReleaseControl(other));CHECK(!ledger.isHeld({OutputKind::Key,340}));
 confirmed();touch(1,3,480,130);touch(1,0,40,102);CHECK(!ledger.isHeld({OutputKind::Key,87}));

 // 同阶段键 + 隐藏自身：新键先接受再精确退休，重显不复活 owner。
 schema.controls[2].bindings[0].actions={{1,TouchGroupOperation::Hide}};
 schema.groups[1].initialVisible=true;schema.profile="self-hide";
 CHECK(setControlSchemaWithGroups(entries,4,1000,1000,1,.18f,4,&config,&schema)>0);
 const auto beforeDown=count(340,1),beforeUp=count(340,0);
 touch(0,2,330,130);CHECK(!s_touchGroups.Visible(2));
 CHECK(count(340,1)==beforeDown+1&&count(340,0)==beforeUp+1&&!ledger.isHeld({OutputKind::Key,340}));
 touch(1,2,330,130);confirmed();

 // click 必须等合格 UP；CANCEL 不补 click 或组动作。
 schema.profile="click-cancel";schema.controls[1].bindings[0]={};
 schema.controls[1].bindings[2].keys={69};schema.controls[1].bindings[2].actions={{1,TouchGroupOperation::Toggle}};
 schema.groups[1].initialVisible=false;
 CHECK(setControlSchemaWithGroups(entries,4,1000,1000,1,.18f,4,&config,&schema)>0);
 const int eBefore=count(69,1);
 touch(0,1,180,130);CHECK(count(69,1)==eBefore&&!s_touchGroups.Visible(2));
 touch(3,1,180,130);CHECK(count(69,1)==eBefore&&!s_touchGroups.Visible(2));
 touch(0,1,180,130);touch(1,1,180,130);CHECK(count(69,1)==eBefore+1&&s_touchGroups.Visible(2));confirmed();

 // A组长按跨B组切换，原资格与期限保持；四阶段组合允许第二次click再doubleClick。
 schema.profile="phases";schema.controls[1].bindings={};schema.controls[1].bindings[1].keys={70};
 schema.controls[3].bindings[0].actions={{1,TouchGroupOperation::Toggle}};
 CHECK(setControlSchemaWithGroups(entries,4,1000,1000,1,.18f,4,&config,&schema)>0);
 touch(0,1,180,130);const auto deadline=s_schemaButtons["open"].longDeadlineNs;
 touch(0,3,480,130);CHECK(s_schemaButtons["open"].longDeadlineNs==deadline);confirmed();touch(1,3,480,130);
 clockNs=deadline+1;schemaPollLongPressLocked();schemaAdvanceGroupsLocked();CHECK(ledger.isHeld({OutputKind::Key,70}));
 touch(1,1,180,130);CHECK(!ledger.isHeld({OutputKind::Key,70}));CHECK(buttonFeedback["open"]==0);
 schema.profile="double";schema.controls[1].bindings={};schema.controls[1].fcl=true;
 schema.controls[1].bindings[2].keys={69};schema.controls[1].bindings[3].keys={294};
 CHECK(setControlSchemaWithGroups(entries,4,1000,1000,1,.18f,4,&config,&schema)>0);
 const int clicks=count(69,1),doubles=count(294,1);
 touch(0,1,180,130);touch(1,1,180,130);touch(0,1,180,130);touch(1,1,180,130);
 CHECK(count(69,1)==clicks+2&&count(294,1)==doubles+1);
 // 固定FCL源码的双击间隔是400ms而非AMCL的300ms；单击检查最终落点。
 clockNs+=500000000;touch(0,1,180,130);touch(1,1,180,130);
 clockNs+=330000000;touch(0,1,180,130);touch(1,1,180,130);
 CHECK(count(294,1)==doubles+2);
 const int returnedClicks=count(69,1);
 clockNs+=500000000;touch(0,1,180,130);touch(2,1,205,130);touch(1,1,180,130);
 CHECK(count(69,1)==returnedClicks+1);

 // autoKeep 解锁边沿仍执行附带组toggle，释放手指不反向toggle。
 schema.profile="keep";schema.controls[1].bindings={};schema.controls[1].bindings[0].keys={340};
 schema.controls[1].bindings[2].keys={69}; // click脉冲结束不能清掉仍锁存的press高亮。
 schema.controls[1].bindings[0].autoKeep=true;schema.controls[1].bindings[0].actions={{1,TouchGroupOperation::Toggle}};
 CHECK(setControlSchemaWithGroups(entries,4,1000,1000,1,.18f,4,&config,&schema)>0);
 touch(0,1,180,130);confirmed();touch(1,1,180,130);CHECK(ledger.isHeld({OutputKind::Key,340})&&s_touchGroups.Visible(2));
 CHECK(buttonFeedback["open"]==1);
 touch(0,1,180,130);CHECK(!ledger.isHeld({OutputKind::Key,340})&&!s_touchGroups.Visible(2));confirmed();touch(1,1,180,130);
 CHECK(buttonFeedback["open"]==0);
 schemaCancelGenerationLocked();CHECK(ledger.ownerCount()==0);
 // 同指 press+longPress 跨模式承接都保留到真实 UP，不能只保留一个阶段。
 schema.profile="carried-phases";schema.controls[1].bindings={};schema.controls[1].fcl=false;
 schema.controls[1].bindings[0].keys={293};schema.controls[1].bindings[1].keys={294};
 CHECK(setControlSchemaWithGroups(entries,4,1000,1000,1,.18f,4,&config,&schema)>0);
 touch(0,1,180,130);clockNs+=210000000;schemaPollLongPressLocked();schemaAdvanceGroupsLocked();s_fingerDown[1]=true;
 const auto keep=schemaCaptureHeldOwnersLocked();CHECK(keep.size()==2);schemaResetTransientStateLocked(keep);
 CHECK(buttonFeedback["open"]==1); // 被原承接表保留的阶段不能在清旧state时误清高亮。
 CHECK(ledger.isHeld({OutputKind::Key,293})&&ledger.isHeld({OutputKind::Key,294}));
 std::array<SchemaCarriedOwner,MAX_FINGERS*4> completed{};size_t completedCount=0;
 CHECK(schemaCollectCarriedUpLocked(1,true,completed,completedCount)&&completedCount==2);
 for(size_t i=0;i<completedCount;++i)ledger.releaseOwner(completed[i].owner);
 s_fingerDown[1]=false;CHECK(ledger.ownerCount()==0);
 // 编辑内旧方案只带空组元数据；真实Native安装及普通按住/抬起仍沿旧按钮解释器。
 AmclCtrlEntry legacyEntry=button("legacy",69,150);

 // 修复前反例：同一阶段按钮3次微动，真实末指UP之前只能有一个DOWN，不能重建owner或期限。
 schemaCancelGenerationLocked();
 schema.profile="phase-swipe-stationary";schema.controls[1].bindings={};schema.controls[1].fcl=false;
 schema.controls[1].bindings[0].keys={65};schema.controls[1].bindings[1].keys={66};
 entries[1].swipeGroup=1;entries[1].trigger=0;entries[1].dragLook=0;
 CHECK(setControlSchemaWithGroups(entries,4,1000,1000,1,.18f,4,&config,&schema)>0);
 const int a0=count(65,1),u0=count(65,0);
 touch(0,1,180,130);const auto owner0=s_schemaButtons["open"].phaseOwners[0];
 const auto deadline0=s_schemaButtons["open"].longDeadlineNs;
 touch(2,1,181,130);touch(2,1,182,130);touch(2,1,183,130);
 CHECK(count(65,1)==a0+1&&count(65,0)==u0&&s_schemaButtons["open"].phaseOwners[0]==owner0);
 // 微动超过AMCL候选阈值以前，期限必须是原真实DOWN建立的一份。
 CHECK(s_schemaButtons["open"].longDeadlineNs==deadline0);
 touch(1,1,183,130);CHECK(count(65,0)==u0+1&&!ledger.isHeld({OutputKind::Key,65}));

 // 真正接力不等于tap：源无click，滑入目标只press，不开启long/click/double候选。
 schema.profile="phase-swipe-transfer";schema.controls[1].bindings={};schema.controls[3].bindings={};
 schema.controls[1].bindings[0].keys={65};schema.controls[1].bindings[2].keys={67};
 schema.controls[3].bindings[0].keys={68};schema.controls[3].bindings[1].keys={69};schema.controls[3].bindings[2].keys={70};
 entries[3].swipeGroup=1;
 CHECK(setControlSchemaWithGroups(entries,4,1000,1000,1,.18f,4,&config,&schema)>0);
 const int clickA=count(67,1),clickB=count(70,1),longB=count(69,1),downB=count(68,1);
 touch(0,0,180,130);touch(2,0,260,130);CHECK(!ledger.isHeld({OutputKind::Key,65}));
 touch(2,0,480,130);CHECK(count(68,1)==downB+1&&s_schemaButtons["close"].longDeadlineNs==0);
 clockNs+=500000000;schemaPollLongPressLocked();CHECK(count(69,1)==longB);
 touch(1,0,480,130);CHECK(count(67,1)==clickA&&count(70,1)==clickB&&!ledger.isHeld({OutputKind::Key,68}));

 // 源非末指退出、目标已有直接手指：保持双方owner；真实目标UP产生自己的click，链末UP不重复。
 schema.profile="phase-swipe-multiple";schema.controls[3].bindings[3].keys={71};
 CHECK(setControlSchemaWithGroups(entries,4,1000,1000,1,.18f,4,&config,&schema)>0);
 const int clicksBefore=count(70,1),bBefore=count(68,1),doublesBefore=count(71,1);
 touch(0,0,180,130);touch(0,1,181,130);touch(0,2,480,130);
 touch(2,1,480,130);CHECK(ledger.isHeld({OutputKind::Key,65})&&count(68,1)==bBefore+1);
 touch(1,0,180,130);touch(1,2,480,130);
 CHECK(ledger.isHeld({OutputKind::Key,68})&&count(70,1)==clicksBefore+1);
 touch(1,1,480,130);CHECK(!ledger.isHeld({OutputKind::Key,68})&&count(70,1)==clicksBefore+1);
 touch(0,2,480,130);touch(1,2,480,130);CHECK(count(71,1)==doublesBefore+1);

 // AMCL显式锁存与FCL SwipeExit分开：相同滑出动作不能粗暴CANCEL全部阶段。
 for(bool fcl:{false,true}) {
  schema.profile=fcl?"fcl-swipe-keep":"amcl-swipe-keep";schema.controls[1].fcl=fcl;
  schema.controls[1].bindings={};schema.controls[1].bindings[0].keys={65};schema.controls[1].bindings[0].autoKeep=true;
  CHECK(setControlSchemaWithGroups(entries,4,1000,1000,1,.18f,4,&config,&schema)>0);
  touch(0,0,180,130);touch(2,0,260,130);CHECK(ledger.isHeld({OutputKind::Key,65})==!fcl);
  touch(1,0,260,130);schemaCancelGenerationLocked();CHECK(!ledger.isHeld({OutputKind::Key,65}));
 }
 schema.controls[1].fcl=false;
 // 辅助陀螺仪读取本触控真实Use，阶段持有/锁存有效；其他来源同键不授予触控资格。
 schema.profile="phase-use";schema.controls[1].bindings={};schema.controls[1].bindings[0].keys={-2};
 entries[1].swipeGroup=0;
 CHECK(setControlSchemaWithGroups(entries,4,1000,1000,1,.18f,4,&config,&schema)>0);
 const auto padUse=SourceAcquireControl({AMCL_INPUT_SOURCE_GAMEPAD,0,"pad-use"},{{OutputKind::Mouse,1}});CHECK(padUse!=0);
 CHECK(!schemaTouchUseHeldLocked());touch(0,0,180,130);CHECK(schemaTouchUseHeldLocked());
 touch(1,0,180,130);CHECK(!schemaTouchUseHeldLocked()&&ledger.isHeld({OutputKind::Mouse,1}));
 CHECK(SourceReleaseControl(padUse));
 schema.profile="phase-use-lock";schema.controls[1].bindings[0].autoKeep=true;
 CHECK(setControlSchemaWithGroups(entries,4,1000,1000,1,.18f,4,&config,&schema)>0);
 touch(0,0,180,130);touch(1,0,180,130);CHECK(schemaTouchUseHeldLocked());
 touch(0,0,180,130);CHECK(!schemaTouchUseHeldLocked());touch(1,0,180,130);
 schemaCancelGenerationLocked();CHECK(ledger.ownerCount()==0);
 schema.profile="carried-use";schema.controls[1].bindings[0].autoKeep=false;
 CHECK(setControlSchemaWithGroups(entries,4,1000,1000,1,.18f,4,&config,&schema)>0);
 touch(0,0,180,130);s_fingerDown[0]=true;
 const auto keepUse=schemaCaptureHeldOwnersLocked();schemaResetTransientStateLocked(keepUse);CHECK(schemaTouchUseHeldLocked());
 std::array<SchemaCarriedOwner,MAX_FINGERS*4> endedUse{};size_t endedUseCount=0;
 CHECK(schemaCollectCarriedUpLocked(0,true,endedUse,endedUseCount));
 for(size_t i=0;i<endedUseCount;++i)ledger.releaseOwner(endedUse[i].owner);
 s_fingerDown[0]=false;CHECK(!schemaTouchUseHeldLocked()&&ledger.ownerCount()==0);
 // 二级层级必须通过同一生产解释器退休触控持有；外部手柄同键和原键位的解绑备份不受污染。
 schemaCancelGenerationLocked();TouchGroupSchema secondary;secondary.profile="secondary-production";
 secondary.groups={{"base",true},{"layer",false,true,true}};secondary.controls.resize(4);
 AmclCtrlEntry secondaryEntries[4]={button("primary-shift",340,0),button("layer-open",69,150),button("layer-f3",292,300),button("protected-edit",0,450)};
 secondaryEntries[3].handledBy=1;
 for(int i=0;i<4;++i){secondary.controls[i].group=i==2?1:i==3?-1:0;secondary.controls[i].rank=i;}
 secondary.controls[1].phases=true;secondary.controls[1].secondaryTarget=1;
 secondary.controls[1].bindings[0].actions={{1,TouchGroupOperation::ToggleSecondary}};
 CHECK(setControlSchemaWithGroups(secondaryEntries,4,1000,1000,1,.18f,4,&config,&secondary)>0);
 const auto sharedShift=SourceAcquireControl({AMCL_INPUT_SOURCE_GAMEPAD,0,"pad-secondary-shift"},{{OutputKind::Key,340}});CHECK(sharedShift!=0);
 touch(0,0,30,130);CHECK(ledger.isHeld({OutputKind::Key,340}));const int priorE=count(69,1);
 touch(0,1,180,130);CHECK(s_touchGroups.Visible(1)&&s_touchGroups.Visible(2)&&!s_touchGroups.Visible(0)&&!s_touchGroups.Visible(3));
 CHECK(ledger.isHeld({OutputKind::Key,340})&&count(69,1)==priorE);confirmed();touch(1,1,180,130);touch(1,0,30,130);
 touch(0,2,330,130);CHECK(ledger.isHeld({OutputKind::Key,292}));
 touch(0,1,180,130);CHECK(!s_touchGroups.Visible(2)&&s_touchGroups.Visible(0)&&s_touchGroups.Visible(3));
 CHECK(!ledger.isHeld({OutputKind::Key,292})&&ledger.isHeld({OutputKind::Key,340}));confirmed();touch(1,1,180,130);touch(1,2,330,130);
 CHECK(SourceReleaseControl(sharedShift));CHECK(!ledger.isHeld({OutputKind::Key,340}));
 // 成员可任意摆放；覆盖入口时仍由同一rank命中入口，第二次点击收起且不发送被覆盖F3。
 secondaryEntries[2].x=secondaryEntries[1].x;
 CHECK(setControlSchemaWithGroups(secondaryEntries,4,1000,1000,1,.18f,4,&config,&secondary)>0);
 const int priorF3=count(292,1);touch(0,1,180,130);confirmed();touch(1,1,180,130);
 touch(0,1,180,130);CHECK(!s_touchGroups.Visible(2)&&count(292,1)==priorF3);confirmed();touch(1,1,180,130);
 CHECK(ledger.ownerCount()==0);
 std::cout<<"PASS actual Native groups: continuous joystick, shared key ownership, phases, secondary visibility/retirement and overlapping opener collapse\n";
}
'''
with temporary_directory(prefix='touch-groups-production-') as directory:
    source = Path(directory) / 'groups.cpp'
    binary = Path(directory) / 'groups.exe'
    source.write_text(prefix + '\nbool s_fingerDown[MAX_FINGERS]{};\n' + recipe['production'] + extra + main, encoding='utf-8', newline='\n')
    compile_source_fixture(source,binary,ROOT / 'entry/src/main/cpp')
    subprocess.run([str(binary)],check=True,timeout=30)
