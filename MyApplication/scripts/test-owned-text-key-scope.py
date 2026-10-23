"""实际owned编辑键/Core发布围栏与Source私有能力的宿主正反门。

复用原完整NAPI组合；只在外置生产Core/bridge副本注入退休/失败边缘或撤一项判据。
未复制来源/队列/租约算法，编译失败、工具超时不能作为负控捕获。
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime
sys.dont_write_bytecode=True
from lib.workspace_paths import external_output_path,workspace_path

ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output',help='明确仓外证据目录；缺省使用workspace helper独占目录，CI同样在仓外')
parser.add_argument('--build-out',help='明确仓外宿主构建目录；缺省使用workspace helper独占目录')
args=parser.parse_args()
run_id='owned-text-key-scope-'+datetime.now().strftime('%Y%m%d-%H%M%S-%f')
out=external_output_path(args.output) if args.output else workspace_path('run',run_id)
build_root=external_output_path(args.build_out) if args.build_out else workspace_path('build',run_id)
out.mkdir(parents=True,exist_ok=False);build_root.mkdir(parents=True,exist_ok=False)
(build_root/'temp').mkdir();os.environ['TMP']=str(build_root/'temp');os.environ['TEMP']=str(build_root/'temp')
recipe=ROOT/'scripts/test-owned-text-modal-napi.py'
text=recipe.read_text(encoding='utf-8')
cut='\nconfigure_host_cmake(cmake_tool,configure_source,build)';assert text.count(cut)==1
setup=text.split(cut)[0]
old="build_root=workspace_path('build','owned-text-modal');build=build_root/'build'"
assert setup.count(old)==1;setup=setup.replace(old,'build_root=Path('+repr(str(build_root))+');build=build_root/"build"')
sys.argv=[str(recipe),'--output',str(out)]
scope={'__name__':'owned_scope_recipe','__file__':str(recipe)}
exec(compile(setup,str(recipe),'exec'),scope)
cpp=scope['cpp'];template=scope['template'];prefix=scope['prefix'];production=scope['production']
# 原同会话真实装配到START300为止；后续每个mode仍使用原adapter/Core/Source/bridge。
anchor='    CHECK(PlatformInputTextSessionBegin(300));\n    CHECK(PlatformInputOwnedTextSessionMatches(300));';assert template.count(anchor)==1
start=template[:template.index(anchor)+len(anchor)]+'\n    inputBridge_setKeyCallback(legacyKeyCallback);\n'
hooks=r'''
#include <atomic>
#include <thread>
#include <chrono>
std::atomic<bool> testFinished{false};std::thread retireThread,watchdog;
uint64_t hookScope=0;bool enableRetireHook=false,rollbackHook=false,endBudgetFail=false;
extern "C" bool ownedRollbackHook(){return rollbackHook;}
extern "C" bool ownedTextEndBudgetFail(){return endBudgetFail;}
extern "C" void ownedTextAfterReserve(){
 if(!enableRetireHook)return;enableRetireHook=false;
 // Source已经持order；另线程真实end持Core并等待order，先发布原scope退休。
 // 最终复核必须原子读，不得再拿Core mutex。这是明确的调度边缘，不是假retired字段。
 retireThread=std::thread([]{CHECK(PlatformInputTextSessionEnd(300));});
 const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(2);
 while(amclInputOwnerValidateTextScopeV1(hookScope)!=0&&std::chrono::steady_clock::now()<deadline)std::this_thread::yield();
 CHECK(amclInputOwnerValidateTextScopeV1(hookScope)==0);
}
'''
normal=r'''
    AmclInputTextCoreResourceV1 original{};CHECK(amclInputOwnerReadTextResourceV1(&original)==1);
    CHECK(original.textSession==300&&original.scope!=0);
    CHECK(SourceOwnedTextKeyTap(original,259));pumpLegacy();CHECK((legacyKeys==std::vector<int>{1,0}));legacyKeys.clear();
    CHECK(PlatformInputTextSessionEnd(300));CHECK(!SourceOwnedTextKeyTap(original,259));
    CHECK(PlatformInputTextSessionBegin(300));AmclInputTextCoreResourceV1 current{};
    CHECK(amclInputOwnerReadTextResourceV1(&current)==1&&current.scope!=original.scope);
    CHECK(!SourceOwnedTextKeyTap(original,259));CHECK(SourceOwnedTextKeyTap(current,259));pumpLegacy();
    CHECK((legacyKeys==std::vector<int>{1,0})&&SourceSnapshot().owners==0);legacyKeys.clear();
    CHECK(PlatformInputTextSessionAbort(300));CHECK(amclInputOwnerValidateTextScopeV1(current.scope)==0);
    CHECK(PlatformInputTextSessionBegin(301));CHECK(amclInputOwnerReadTextResourceV1(&current)==1);
    CHECK(api->requestReset(AMCL_INPUT_RESET_EXPLICIT)==AMCL_INPUT_OK);
    CHECK(amclInputOwnerValidateTextScopeV1(current.scope)==0&&!SourceOwnedTextKeyTap(current,259));
    pumpLegacy();CHECK(legacyKeys.empty()&&SourceSnapshot().owners==0);
    std::cout<<"OWNED SCOPE PASS normal/end/reopen/abort/reset original facts\n";
'''
concurrent=r'''
    AmclInputTextCoreResourceV1 original{};CHECK(amclInputOwnerReadTextResourceV1(&original)==1);
    hookScope=original.scope;enableRetireHook=true;
    watchdog=std::thread([]{const auto end=std::chrono::steady_clock::now()+std::chrono::seconds(3);
      while(!testFinished&&std::chrono::steady_clock::now()<end)std::this_thread::yield();
      if(!testFinished){std::fprintf(stderr,"OWNED TEXT LOCK ORDER FAIL\n");std::_Exit(42);}});
    CHECK(!SourceOwnedTextKeyTap(original,259));retireThread.join();testFinished=true;watchdog.join();
    pumpLegacy();CHECK(legacyKeys.empty()&&SourceSnapshot().owners==0);
    std::cout<<"OWNED SCOPE PASS actual end waits order; atomic final check progresses\n";
'''
rollback=r'''
    AmclInputTextCoreResourceV1 original{};CHECK(amclInputOwnerReadTextResourceV1(&original)==1);
    AmclInputEvent event{};event.header.abiVersion=1;event.header.structSize=sizeof(event);
    event.header.eventType=AMCL_INPUT_EVENT_PHYSICAL_KEY;event.header.source=AMCL_INPUT_SOURCE_IME;
    event.header.deviceId=kPlatformInputTextKeyDeviceId;event.payload.physicalKey.physicalKey=2055;
    event.payload.physicalKey.action=AMCL_INPUT_ACTION_DOWN;
    rollbackHook=true;CHECK(api->submitBatch(&event,1)==AMCL_INPUT_ERROR_INVALID_ARGUMENT);rollbackHook=false;
    AmclInputTextCoreResourceV1 restored{};CHECK(amclInputOwnerReadTextResourceV1(&restored)==1);
    CHECK(restored.scope==original.scope&&amclInputOwnerValidateTextScopeV1(original.scope)==1);
    CHECK(SourceOwnedTextKeyTap(original,259));pumpLegacy();CHECK((legacyKeys==std::vector<int>{1,0}));
    std::cout<<"OWNED SCOPE PASS actual Core speculative text retirement then production restore\n";
'''
maximum=r'''
    AmclInputTextCoreResourceV1 original{};CHECK(amclInputOwnerReadTextResourceV1(&original)==1);
    CHECK(original.scope==UINT64_MAX-1u);CHECK(PlatformInputTextSessionEnd(300));
    CHECK(!PlatformInputTextSessionBegin(301));AmclInputTextCoreResourceV1 absent{};
    CHECK(amclInputOwnerReadTextResourceV1(&absent)==0&&absent.active==0);
    CHECK(!SourceOwnedTextKeyTap(original,259)&&SourceSnapshot().owners==0);
    std::cout<<"OWNED SCOPE PASS MAX no wrap/no reused authority\n";
'''
failed_end=r'''
    AmclInputTextCoreResourceV1 original{};CHECK(amclInputOwnerReadTextResourceV1(&original)==1);
    endBudgetFail=true;CHECK(!PlatformInputTextSessionEnd(300));endBudgetFail=false;
    // 未提交end保持原会话/资格，不把false伪装成已退休；显式同IDBEGIN仍幂等。
    CHECK(amclInputOwnerValidateTextScopeV1(original.scope)==1&&PlatformInputTextSessionBegin(300));
    CHECK(SourceOwnedTextKeyTap(original,259));pumpLegacy();CHECK((legacyKeys==std::vector<int>{1,0}));legacyKeys.clear();
    CHECK(PlatformInputTextSessionEnd(300));CHECK(!SourceOwnedTextKeyTap(original,259));
    CHECK(PlatformInputTextSessionBegin(301));AmclInputTextCoreResourceV1 fresh{};
    CHECK(amclInputOwnerReadTextResourceV1(&fresh)==1&&fresh.scope!=original.scope);
    CHECK(SourceOwnedTextKeyTap(fresh,259));pumpLegacy();CHECK((legacyKeys==std::vector<int>{1,0}));
    std::cout<<"OWNED SCOPE PASS false end no fake retirement; retry/new scope resume\n";
'''
cold=r'''
int main(){amclSourceControlPublishV1();const AmclSourceControlPortV1* value=nullptr;
 CHECK(amclSourceControlResolveV1(&value)<0&&value==nullptr);CHECK(amclSourceControlPrepareV1()==0);
 std::cout<<"OWNED SCOPE PASS actual old64 table cold rejected before tail/prepare\n";}
'''
source_original=(cpp/'input/source/source_control.cpp').read_text(encoding='utf-8')
core_original=(cpp/'input/input_state_core.cpp').read_text(encoding='utf-8')
bridge_original=(cpp/'glfw/input_bridge_ohos.c').read_text(encoding='utf-8')
cmake_original=(scope['configure_source']/'CMakeLists.txt').read_text(encoding='utf-8')
def absolutize(text,parent):
    """只改外置副本相对include的目标，不改任何生产算法正文。"""
    return re.sub(r'#include "([^"\n]+)"',lambda hit:'#include "'+(parent/hit[1]).resolve().as_posix()+'"',text)
tracked=[*scope['identity_paths'],cpp/'input/input_state_core.h',cpp/'input/input_text_core_hook.h',Path(__file__),recipe]
before={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
scope['configure_host_cmake'](scope['cmake_tool'],scope['configure_source'],scope['build'])
checks=[]
def run_mode(name,body,negative=False,variant=''):
    """每轮独占run文件；实际编译后的行为失效才是反控，watchdog只用于明确旧锁反例。"""
    source,core,bridge=source_original,core_original,bridge_original
    full=prefix+hooks+production
    if variant=='stale':
        needle='||textResource.scope!=request->textScope';assert source.count(needle)==1;source=source.replace(needle,'')
    if variant in ('concurrent','lock'):
        begin=bridge.index('JNIEXPORT int inputBridge_beginSourceActionV1(')
        end=bridge.index('JNIEXPORT void inputBridge_endLookActionV1',begin)
        block=bridge[begin:end];needle='g_lookActionDepth=1;return 1;';assert block.count(needle)==1
        bridge=bridge[:begin]+block.replace(needle,'g_lookActionDepth=1;ownedTextAfterReserve();return 1;')+bridge[end:]
        bridge='extern "C" void ownedTextAfterReserve();\n'+bridge
    if variant=='lock':
        needle='!amclInputOwnerValidateTextScopeV1(textResource.scope)';assert source.count(needle)==1
        source=source.replace(needle,'!([&](){AmclInputTextCoreResourceV1 current{};return amclInputOwnerReadTextResourceV1(&current)&&current.scope==textResource.scope;}())')
    if variant in ('rollback','rollback-negative'):
        needle='    const uint64_t now = NowNs();\n    for (uint32_t i = 0; i < count; ++i) {';assert core.count(needle)==1
        core='extern "C" bool ownedRollbackHook();\n'+core.replace(needle,
          '    if(ownedRollbackHook()){impl_->DropTextPackets();restore();return AMCL_INPUT_ERROR_INVALID_ARGUMENT;}\n'+needle)
        if variant=='rollback-negative':
            needle='impl_->textKeyScope.store(textKeyScope,std::memory_order_release);';assert core.count(needle)==2
            core=core.replace(needle,'/* external negative: original published scope restore removed */')
    if variant in ('max','max-negative'):
        needle='uint64_t nextTextKeyScope = 1;';assert core.count(needle)==1;core=core.replace(needle,'uint64_t nextTextKeyScope = UINT64_MAX-1u;')
        if variant=='max-negative':
            needle='text.change == AMCL_INPUT_TEXT_SESSION_STARTED && nextTextKeyScope == UINT64_MAX';assert core.count(needle)==1
            core=core.replace(needle,'false')
    if variant in ('failed-end','failed-end-negative'):
        begin=core.index('    int32_t SubmitTextSession(');end=core.index('    int32_t MissingConsumerStatus(',begin)
        core_block=core[begin:end];needle='if (!HasSequenceBudget(1u)) {';assert core_block.count(needle)==1
        core_block=core_block.replace(needle,'if ((text.change != AMCL_INPUT_TEXT_SESSION_STARTED && ownedTextEndBudgetFail()) || !HasSequenceBudget(1u)) {')
        if variant=='failed-end-negative':
            core_block=core_block.replace('if ((text.change != AMCL_INPUT_TEXT_SESSION_STARTED && ownedTextEndBudgetFail())',
                'textKeyScope.store(0,std::memory_order_release); if ((text.change != AMCL_INPUT_TEXT_SESSION_STARTED && ownedTextEndBudgetFail())')
        core='extern "C" bool ownedTextEndBudgetFail();\n'+core[:begin]+core_block+core[end:]
    if variant in ('old64','old72'):
        needle='''    static const AmclSourceControlPortV1 port={AMCL_SOURCE_CONTROL_MAGIC,1,sizeof(AmclSourceControlPortV1),sourceProcess,
        reinterpret_cast<uintptr_t>(amclInputGetHostApiV1()),verify,open,prepared,transact,query,ownedTextKeyTap,ownedTextKeyTapForKeyboard};
    return &port;''';assert source.count(needle)==1
        replacement='''    struct Old64 {uint32_t magic,version,size,pid;uint64_t owner;
        decltype(verify)*v;decltype(open)*o;decltype(prepared)*p;decltype(transact)*t;decltype(query)*q;};
    static_assert(sizeof(Old64)==64,"old Source v1 prefix layout");
    static const Old64 port={AMCL_SOURCE_CONTROL_MAGIC,1,sizeof(Old64),sourceProcess,
        reinterpret_cast<uintptr_t>(amclInputGetHostApiV1()),verify,open,prepared,transact,query};
    return reinterpret_cast<const AmclSourceControlPortV1*>(&port);'''
        source=source.replace(needle,replacement)
        if variant=='old72':
            # 真正的旧72前缀仍含owned文字尾，缺原Keyboard能力的新尾；不是错误getter/PID反例。
            source=source.replace('decltype(transact)*t;decltype(query)*q;};','decltype(transact)*t;decltype(query)*q;decltype(ownedTextKeyTap)*tap;};')
            source=source.replace('sizeof(Old64)==64','sizeof(Old64)==72')
            source=source.replace('"old Source v1 prefix layout"','"old Source owned text72 prefix layout"')
            source=source.replace('verify,open,prepared,transact,query};','verify,open,prepared,transact,query,ownedTextKeyTap};')
    copies={cpp/'input/source/source_control.cpp':(build_root/'source-copy.cpp',source),
      cpp/'input/input_state_core.cpp':(build_root/'core-copy.cpp',core),cpp/'glfw/input_bridge_ohos.c':(build_root/'bridge-copy.cpp',bridge)}
    cmake=cmake_original
    for original,(copy,text) in copies.items():
        copy.write_text(absolutize(text,original.parent),encoding='utf-8');cmake=cmake.replace(original.as_posix(),copy.as_posix())
    (scope['configure_source']/'CMakeLists.txt').write_text(cmake,encoding='utf-8')
    code=full+cold.replace('actual old64 table','actual '+('old72' if variant=='old72' else 'old64')+' table') if variant in ('old64','old72') else start.replace('@FIXTURE@',full)+body+'\n}\n'
    scope['candidate'].write_text(code,encoding='utf-8')
    made=subprocess.run([scope['cmake_tool'],'--build',str(scope['build']),'--config','Release','--target','owned'],capture_output=True)
    (out/(name+'-compile.log')).write_bytes(made.stdout+made.stderr);print((made.stdout+made.stderr).decode(errors='replace'),flush=True)
    if made.returncode:raise RuntimeError(name+' compile failed; not a behavior counterexample')
    binary=scope['build']/('Release/owned.exe' if os.name=='nt' else 'owned')
    result=subprocess.run([str(binary)],capture_output=True,timeout=12)
    (out/(name+'.log')).write_bytes(result.stdout+result.stderr);print((result.stdout+result.stderr).decode(errors='replace'),flush=True)
    if negative:
        assert result.returncode!=0 and (b'TEXT KEY ORDER FAIL' in result.stderr or b'OWNED TEXT LOCK ORDER FAIL' in result.stderr)
    else:assert result.returncode==0,result.stdout+result.stderr
    checks.append({'name':name,'negative':negative,'compileExitCode':made.returncode,'exitCode':result.returncode})
run_mode('normal',normal)
run_mode('original-scope-negative',normal,True,'stale')
run_mode('concurrent-end',concurrent,False,'concurrent')
run_mode('core-mutex-final-negative',concurrent,True,'lock')
run_mode('rollback',rollback,False,'rollback')
run_mode('rollback-scope-negative',rollback,True,'rollback-negative')
run_mode('max',maximum,False,'max')
run_mode('max-negative',maximum,True,'max-negative')
run_mode('failed-end',failed_end,False,'failed-end')
run_mode('failed-end-negative',failed_end,True,'failed-end-negative')
run_mode('old-table',cold,False,'old64')
run_mode('old-owned72-table',cold,False,'old72')
run_mode('restored-production',normal)
after={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
(out/'receipt.json').write_text(json.dumps({'startedAt':scope['started'],'finishedAt':datetime.now().astimezone().isoformat(),
  'checks':checks,'sourcesBefore':before,'sourcesAfter':after,'sourceDrift':[x for x in before if before[x]!=after[x]],
  'boundary':'actual NAPI/Core/Source/bridge bodies; explicit OS values/window and scheduler/failure injection; no device/SDK/JVM claim'},indent=2),encoding='utf-8')
assert before==after
