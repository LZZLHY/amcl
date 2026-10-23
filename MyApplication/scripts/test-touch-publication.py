"""执行真实触控发布/模态平台函数与生产输出运行时；只替换SDK身份、时钟和最终出口。

同一夹具覆盖关门后零触点、丢回执查询、旧确认、嵌套租约、密度换代及跨端同键持有。
负对照必须编译并在行为CHECK失败；不能把状态机单测替代实际平台接线。
"""
from pathlib import Path
import re
import runpy
import subprocess
from lib.host_cpp import compile_cpp
from lib.source_host import compile_source_fixture
from lib.workspace_paths import temporary_directory

ROOT = Path(__file__).resolve().parents[1]
runpy.run_path(str(ROOT / 'scripts/test-control-schema-lifecycle.py'))
# 新组入口调用原阶段解释器；复用完整生产函数配方，不为组路径另造假状态机。
base = runpy.run_path(str(ROOT / 'scripts/test-touch-production.py'), init_globals={'AMCL_TOUCH_RECIPE_ONLY': True})
source = base['source']
prefix = base['prefix']
platform = ROOT / 'entry/src/main/cpp/platform'
extra = ['surface_input_gate_state.h', 'touch_publication.h']
prefix = '\n'.join('#include "' + (platform / name).as_posix() + '"' for name in extra) + '\n' + prefix
# base 已借实际Source/Core/bridge；这里不再内嵌第二套runtime或伪造pushEvent。
prefix = prefix.replace('struct TestResetSnapshot{uint64_t touch=1;};TestResetSnapshot PlatformInputResetDomains(){return {};}',
                       'uint64_t resetTouch=1;struct TestResetSnapshot{uint64_t touch=1;};TestResetSnapshot PlatformInputResetDomains(){return {resetTouch};} constexpr uint32_t kInputResetTouch=1; void PlatformInputCompleteResetBoundary(uint32_t domains){if(domains&kInputResetTouch)++resetTouch;}')
prefix = prefix.replace('double ohos_display_density(){return 2.0;}', 'std::atomic<double> s_displayDensity{2}; double ohos_display_density(){return s_displayDensity.load();}')
prefix += r'''
bool s_fingerDown[MAX_FINGERS]{},s_fingerDead[MAX_FINGERS]{},s_wheelGestureIntegral[MAX_FINGERS]{};
surface_gate::State s_surfaceInputGate;
TouchPublicationState s_touchAdmission;
std::atomic<bool> s_touchPaused{false};
uint32_t s_touchContextTransform=0;
bool modeAvailable=true,realGrab=true;
namespace amcl::input {
class AuthoritativeGrabInputTransaction{public: explicit operator bool()const{return modeAvailable;}bool grabbed()const{return realGrab;}};
}
void flushLookPending(bool,int){}
'''
prefix=prefix.replace('void flushLookPending(bool,int){}','',1)
prefix+='\nbool bridgeReady(){return true;}\n'
def extra_definition(signature):
    match=re.search(re.escape(signature)+r'[^;{]*\{',source)
    assert match,signature
    return base['base']['recipe'].block(source,match.start())
production = base['production'] + '\n' + extra_definition('static AmclInputSource normalizeInputSource(') + '\n' + \
    extra_definition('extern "C" uint64_t ohos_acquire_source_control(') + '\n' + source[source.index('// ==================== 触控发布/模态扩展v1'):]
main = r'''
int main(){
 CHECK(initializeSourceFixture());
 s_surfaceInputGate.active=true;s_surfaceInputGate.publicationGeneration=7;
 TouchInteractionConfig config;AmclCtrlEntry e{};std::strcpy(e.id,"left");e.kind=0;e.keyOrMouse=65;e.w=100;e.h=100;
 CHECK(ohos_set_control_schema_v3(&e,1,1000,1000,1,.18f,3,&config)>0);
 auto original=QueryTouchPublication();CHECK(original.context.surface==7&&!original.fenced);
 // 首次候选失败时没有已确认的applied可回退，abort明确结束该操作但必须继续关新DOWN。
 auto firstBad=BeginTouchPublication("first-bad","first-bad-candidate",original.context);
 auto badFirst=e;badFirst.w=-1;
 CHECK(PublishTouchSchema("first-bad",&badFirst,1,1000,1000,1,.18f,3,&config).status==TouchPublicationStatus::Invalid);
 auto endedFirst=AbortTouchPublication("first-bad");
 CHECK(firstBad.token!=0&&endedFirst.fenced&&endedFirst.operationId.empty()&&endedFirst.token==0);
 s_fingerDown[0]=true;
 auto waiting=BeginTouchPublication("op-1","candidate-1",original.context);
 CHECK(waiting.fenced&&waiting.status==TouchPublicationStatus::Waiting);
 CHECK(!ConfirmTouchPublication("op-1",waiting.token));
 e.x=10;auto notYet=PublishTouchSchema("op-1",&e,1,1000,1000,1,.18f,3,&config);
 CHECK(notYet.status==TouchPublicationStatus::Waiting&&notYet.context.schema==original.context.schema);
 s_fingerDown[0]=false;
 const int retiredBeforeLayout=menuScopeRetirements;
 auto committed=PublishTouchSchema("op-1",&e,1,1000,1000,1,.18f,3,&config);
 CHECK(committed.status==TouchPublicationStatus::Committed&&committed.fenced);
 CHECK(menuScopeRetirements==retiredBeforeLayout+1);
 CHECK(!AcceptTouchUiPublication(committed.token));
 // 假设JS未拿到上一个回执：真实查询仍识别已提交，重复送达不再换代或退休owner。
 auto queried=QueryTouchPublication();CHECK(queried.operationId=="op-1"&&queried.token==committed.token);
 auto repeated=PublishTouchSchema("op-1",&e,1,1000,1000,1,.18f,3,&config);
 CHECK(repeated.context.schema==committed.context.schema&&repeated.token==committed.token);
 CHECK(AbortTouchPublication("op-1").status==TouchPublicationStatus::Stale);
 CHECK(ConfirmTouchPublication("op-1",committed.token)&&AcceptTouchUiPublication(committed.token));
 auto next=BeginTouchPublication("op-2","candidate-2",QueryTouchPublication().context);
 CHECK(next.fenced&&!ConfirmTouchPublication("op-1",committed.token));
 auto invalid=e;invalid.w=-1;
 CHECK(PublishTouchSchema("op-2",&invalid,1,1000,1000,1,.18f,3,&config).status==TouchPublicationStatus::Invalid);
 CHECK(AbortTouchPublication("op-2").status==TouchPublicationStatus::Idle&&AcceptTouchUiPublication(committed.token));
 // modal只释放TouchControls自己的真实外部owner；实体/手柄同键贡献仍持有。
 const Output a{OutputKind::Key,65};
 const auto touch=SourceAcquireControl({AMCL_INPUT_SOURCE_TOUCH_CONTROLS,0,"touch"},{a});
 const auto pad=SourceAcquireControl({AMCL_INPUT_SOURCE_GAMEPAD,8,"pad"},{a});
 SourcePhysicalProxy physicalRouter;int mapped=-1;
 const auto physical=physicalRouter.Route(true,{OutputKind::Key,9,65},&a,LegacyPhysicalAction::Down,0,&mapped);
 CHECK(physical==AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE&&SourceSnapshot().physical==1);
 CHECK(touch&&pad&&physical&&ledger.isHeld(a));const auto resetBefore=resetTouch;
 const int retiredBeforeModal=menuScopeRetirements;
 const auto chat=AcquireTouchModal("chat"),editor=AcquireTouchModal("editor");
 CHECK(chat&&editor&&chat!=editor&&resetTouch==resetBefore+1&&ledger.isHeld(a));
 CHECK(menuScopeRetirements==retiredBeforeModal+1); // 首个具名模态立即退休，嵌套租约不重复清输入。
 CHECK(!ledger.owns(touch,a)&&ledger.owns(pad,a)&&SourceSnapshot().physical==1);
 CHECK(ReleaseTouchModal(chat)&&ReleaseTouchModal(chat)&&QueryTouchPublication().modalCount==1);
 CHECK(!ReleaseTouchModal(0)&&!ReleaseTouchModal(committed.token)&&!ReleaseTouchModal(UINT64_MAX));
 CHECK(!AcceptTouchUiPublication(committed.token));CHECK(ReleaseTouchModal(editor));
 // touch会话已退休，旧UI确认不能恢复；新出版身份必须重新确认。
 auto afterModal=QueryTouchPublication();CHECK(afterModal.status==TouchPublicationStatus::Stale);
 auto renewed=BeginTouchPublication("op-3","candidate-3",afterModal.context);
 auto same=PublishTouchSchema("op-3",&e,1,1000,1000,1,.18f,3,&config);
 CHECK(same.status==TouchPublicationStatus::Unchanged&&ConfirmTouchPublication("op-3",renewed.token));
 const auto policyBefore=QueryTouchPublication();
 TouchContextPolicyChanged(3,1);
 auto density=QueryTouchPublication();CHECK(density.context.policy!=policyBefore.context.policy&&density.context.density==3&&density.context.transform==1);
 CHECK(density.fenced&&!ConfirmTouchPublication("op-3",renewed.token)&&ledger.owns(pad,a)&&SourceSnapshot().physical==1);
 auto changed=BeginTouchPublication("op-4","candidate-4",density.context);
 auto applied=PublishTouchSchema("op-4",&e,1,1000,1000,1,.18f,3,&config);
 CHECK(applied.status==TouchPublicationStatus::Committed&&applied.context.schema!=same.context.schema);
 CHECK(ConfirmTouchPublication("op-4",changed.token));
 // 一串实际grab翻转即使最终bool相同也有独立代次，旧UI动作不能等JS回调以后才失效。
 s_touchPublicationGrabEpoch+=2;
 CHECK(!AcceptTouchUiPublication(changed.token));
 auto scene=BeginTouchPublication("op-5","candidate-5",QueryTouchPublication().context);
 auto sceneApplied=PublishTouchSchema("op-5",&e,1,1000,1000,1,.18f,3,&config);
 CHECK(sceneApplied.status==TouchPublicationStatus::Unchanged&&ConfirmTouchPublication("op-5",scene.token));
 s_surfaceInputGate.publicationGeneration=8;
 // OS已发布新surface但JS尚未查询：实际direct-touch准入helper自身识别失效。
 {std::lock_guard<std::mutex> lock(s_touchStateMutex);CHECK(touchAdmissionBlocksNewTouchLocked());}
 CHECK(QueryTouchPublication().fenced&&!AcceptTouchUiPublication(scene.token));
 // 实际平台continuation入口：切到已确认菜单身份，waiting的动态触点仍能完成旧手势。
 realGrab=false;s_grabFlipLastState=false;++s_touchPublicationGrabEpoch;
 for(auto& finger:s_fingerDown)finger=false;
 s_touchAdmission=TouchPublicationState{};
 const auto menuContext=QueryTouchPublication().context;
 const auto menu=BeginTouchPublication("menu-ui","menu-candidate",menuContext);
 CHECK(PublishTouchSchema("menu-ui",&e,1,1000,1000,0,.18f,3,&config).status==TouchPublicationStatus::Unchanged);
 CHECK(ConfirmTouchPublication("menu-ui",menu.token)&&AcceptTouchUiContinuation(menu.token));
 s_fingerDown[0]=true;
 const auto waitingMenu=BeginTouchPublication("menu-wait","pending-candidate",QueryTouchPublication().context);
 CHECK(waitingMenu.status==TouchPublicationStatus::Waiting&&!AcceptTouchUiPublication(menu.token));
 CHECK(AcceptTouchUiContinuation(menu.token)&&!AcceptTouchUiContinuation(waitingMenu.token));
 s_touchPaused=true;CHECK(!AcceptTouchUiContinuation(menu.token));s_touchPaused=false;
 modeAvailable=false;CHECK(!AcceptTouchUiContinuation(menu.token));modeAvailable=true;
 realGrab=true;CHECK(!AcceptTouchUiContinuation(menu.token));realGrab=false;
 s_fingerDown[0]=false;
 CHECK(PublishTouchSchema("menu-wait",&e,1,1000,1000,0,.18f,3,&config).status==TouchPublicationStatus::Unchanged);
 CHECK(!AcceptTouchUiContinuation(menu.token)&&!AcceptTouchUiContinuation(waitingMenu.token));
 CHECK(ConfirmTouchPublication("menu-wait",waitingMenu.token)&&AcceptTouchUiContinuation(waitingMenu.token));
 const auto finalModal=AcquireTouchModal("continuation-modal");CHECK(finalModal&&!AcceptTouchUiContinuation(waitingMenu.token));
 CHECK(ReleaseTouchModal(finalModal)&&!AcceptTouchUiContinuation(waitingMenu.token));
 std::cout<<"PASS production publication/modal: waiting, receipt recovery, old confirm, reject rollback, nested touch-only leases, density and surface identity\n";
}
'''
with temporary_directory(prefix='touch-publication-') as directory:
    path, binary = Path(directory) / 'publication.cpp', Path(directory) / 'publication.exe'
    def check(body, negative=False):
        path.write_text(prefix + body + main, encoding='utf-8', newline='\n')
        compile_source_fixture(path,binary,ROOT/'entry/src/main/cpp')
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
        if negative:
            assert result.returncode != 0 and 'CHECK failed' in result.stderr, result.stdout + result.stderr
        else:
            assert result.returncode == 0, result.stdout + result.stderr
            print(result.stdout.strip())
    check(production)
    needle = 'if (s_fingerDown[i] && !s_wheelGestureIntegral[i]) ++context.nativeTouches;'
    assert production.count(needle) == 1
    check(production.replace(needle, '/* negative: ignore real contacts */', 1), True)
    print('PASS negative control: publication installs while old native contact remains')
    needle = 'SourceReleaseSource(AMCL_INPUT_SOURCE_TOUCH_CONTROLS);'
    assert production.count(needle) == 1
    check(production.replace(needle, 'SourceLedgerProxy{}.releaseAll();', 1), True)
    print('PASS negative control: modal incorrectly clears other input domains')
    needle = 'inputBridge_retireTouchMenuScopeV1();'
    assert needle in production
    # 生产调用可能是单行if的唯一语句；保留一个合法空语句，负控必须在行为CHECK失败。
    check(production.replace(needle, '(void)0; /* negative: omit consumer menu-scope retirement */'), True)
    print('PASS negative control: layout/modal leaves completed menu transaction eligible')
