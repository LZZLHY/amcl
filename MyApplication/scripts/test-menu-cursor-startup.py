"""执行真实JVM平台runtime发布阶段，证明菜单ACK consumer按本局独立输入计划冻结。

四条运行库路线、真实uint64 session和configure失败均经同一生产phase；只替换SDK/进程身份/桥边界。
计划解码与组合校验直接include生产input_launch_plan.h，不能在夹具里复制消费者选择算法。
"""
from pathlib import Path
import importlib.util
import os
import re
import subprocess
from lib.host_cpp import compile_cpp
from lib.workspace_paths import temporary_directory

ROOT=Path(__file__).resolve().parents[1]
CPP=ROOT/'entry/src/main/cpp'
spec=importlib.util.spec_from_file_location('cursor_startup_extract',ROOT/'scripts/generate-desktop-review-tests.py')
recipe=importlib.util.module_from_spec(spec)
spec.loader.exec_module(recipe)
source=(CPP/'jvm/mc_launcher.cpp').read_text(encoding='utf-8')
production=recipe.function(source,'phase_publishPlatformRuntime')
prefix=r'''
#include "@PLAN@"
#include "@CURSOR@"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>
#define AMCL_LOG_I(...) ((void)0)
#define LOG_TAG "host startup"
#define JNI_OK 0
#define SYS_gettid 1
#define syscall(...) 456L
#define getpid() 123
#define CHECK(v) do{if(!(v)){std::cerr<<"CHECK failed "<<__LINE__<<": "<<#v<<'\n';return 1;}}while(0)
std::string g_mcStatus;
amcl::input::LaunchPlan g_inputLaunchPlan;
// 此测试消费prepare阶段已经取得的cold事实；真实LoadLibrary/dlopen/同映像校验由
// test-sdl-bootstrap-contract和cold-protocol实编闭包另证，这里不复制其身份算法。
bool sdlClaimVerified=true,g_inputLaunchLegacy=false;
bool claimedTyped=false,claimedAuxiliary=false;
struct SdlClaimBoundary { bool VerifiedForCurrentProcess(bool typed,bool auxiliary) const {
    claimedTyped=typed;claimedAuxiliary=auxiliary;return sdlClaimVerified;
} } g_sdlInputLibraryClaim;
bool configureOK=true,storeOK=true,callbackOK=true,auxiliaryOK=true;
uint32_t configuredBackend=0;uint64_t configuredSession=0,callbackSession=0;
int configureCalls=0,stores=0,auxiliaryCalls=0;uint64_t auxiliarySession=0;bool auxiliaryRetire=true;
// 辅助owner边界记录真实phase传入的64位身份与操作，并可注入拒绝；不复制生产角色选择。
bool configureAuxiliarySdlRuntime(uint64_t session,bool retire){
    ++auxiliaryCalls;auxiliarySession=session;auxiliaryRetire=retire;return auxiliaryOK;
}
std::string storedDescriptor;
// registry边界仅保存本child的描述符；不建立新marker、不修改父进程或用户环境。
namespace amcl::envslot {
const char* kSdlHostRuntimeEnv="AMCL_SDL_HOST_RUNTIME";
struct Registry {int Store(const char*,const char* value){++stores;storedDescriptor=value;return storeOK?1:-1;}} registry;
Registry& ProcessRegistry(){return registry;}
}
int publishCallbackBridgeHostV1(uint64_t session){callbackSession=session;return callbackOK?JNI_OK:-1;}
extern "C" int inputBridge_configureMenuCursorConsumerV1(uint32_t backend,uint64_t session){
    ++configureCalls;configuredBackend=backend;configuredSession=session;return configureOK?1:0;
}
'''
main=r'''
void reset(const char* slot,const char* window){
    // 真实生产计划解析器负责封闭组合；未知组合保留空计划，供发布阶段拒绝。
    // 不再提供GraphicsPlan/ActiveGraphicsPlan，让测试证明该phase没有图形寄生依赖。
    g_inputLaunchPlan=amcl::input::LaunchPlan();std::string error;
    amcl::input::LegacyLaunchPlan(slot,window,g_inputLaunchPlan,error);
    configureOK=storeOK=callbackOK=auxiliaryOK=true;configureCalls=stores=auxiliaryCalls=0;
    auxiliarySession=0;auxiliaryRetire=true;claimedTyped=claimedAuxiliary=false;
    sdlClaimVerified=true;g_inputLaunchLegacy=false;
    configuredBackend=0;configuredSession=callbackSession=0;storedDescriptor.clear();g_mcStatus.clear();
}
int main(){
    constexpr uint64_t session=9007199254740993ULL;
    struct Route{const char* slot;const char* window;uint32_t expected;};
    for(const auto route:{Route{"LWJGL2","GLFW",AMCL_MENU_CURSOR_BACKEND_LWJGL2},
         Route{"LWJGL322","GLFW",AMCL_MENU_CURSOR_BACKEND_GLFW},
         Route{"LWJGL3","GLFW",AMCL_MENU_CURSOR_BACKEND_GLFW},
         Route{"LWJGL3","SDL3",AMCL_MENU_CURSOR_BACKEND_SDL3}}){
        reset(route.slot,route.window);CHECK(phase_publishPlatformRuntime(session));
        CHECK(configureCalls==1&&configuredBackend==route.expected&&configuredSession==session&&callbackSession==session);
        CHECK(claimedTyped&&stores==1);
        if(route.expected==AMCL_MENU_CURSOR_BACKEND_SDL3){
            CHECK(!claimedAuxiliary&&auxiliaryCalls==1&&auxiliarySession==session&&!auxiliaryRetire&&storedDescriptor=="1:123:456:9007199254740993");
        }else{
            CHECK(claimedAuxiliary&&auxiliaryCalls==1&&auxiliarySession==session&&!auxiliaryRetire);
            CHECK(storedDescriptor=="2:123:456:9007199254740993:1");
        }
    }
    reset("LWJGL3","GLFW");g_inputLaunchPlan=amcl::input::LaunchPlan();
    CHECK(!phase_publishPlatformRuntime(session)&&configureCalls==0);
    reset("unknown","GLFW");CHECK(!phase_publishPlatformRuntime(session)&&configureCalls==0);
    reset("LWJGL3","unknown");CHECK(!phase_publishPlatformRuntime(session)&&configureCalls==0);
    reset("LWJGL2","SDL3");CHECK(!phase_publishPlatformRuntime(session)&&configureCalls==0);
    reset("LWJGL3","GLFW");g_inputLaunchPlan.abi="unknown";
    CHECK(!phase_publishPlatformRuntime(session)&&configureCalls==0);
    reset("LWJGL3","GLFW");g_inputLaunchPlan.binding="libSDL3.so";
    CHECK(!phase_publishPlatformRuntime(session)&&configureCalls==0);
    reset("LWJGL3","GLFW");g_inputLaunchPlan.policy="sdl-present-1";
    CHECK(!phase_publishPlatformRuntime(session)&&configureCalls==0);
    reset("LWJGL3","GLFW");configureOK=false;
    CHECK(!phase_publishPlatformRuntime(session)&&configureCalls==1&&configuredSession==session);
    reset("LWJGL3","SDL3");configureOK=false;CHECK(!phase_publishPlatformRuntime(session)&&stores==0);
    reset("LWJGL3","SDL3");storeOK=false;CHECK(!phase_publishPlatformRuntime(session));
    reset("LWJGL3","SDL3");sdlClaimVerified=false;
    CHECK(!phase_publishPlatformRuntime(session)&&configureCalls==0&&stores==0&&callbackSession==0);
    reset("LWJGL3","GLFW");callbackOK=false;CHECK(!phase_publishPlatformRuntime(session)&&configureCalls==0);
    reset("LWJGL3","GLFW");auxiliaryOK=false;
    CHECK(!phase_publishPlatformRuntime(session)&&auxiliaryCalls==1&&configureCalls==0&&stores==0&&callbackSession==0);
    reset("LWJGL3","GLFW");sdlClaimVerified=false;
    CHECK(!phase_publishPlatformRuntime(session)&&auxiliaryCalls==0&&configureCalls==0&&stores==0);
    reset("LWJGL3","SDL3");g_inputLaunchLegacy=true;CHECK(phase_publishPlatformRuntime(session));
    CHECK(!claimedTyped&&!claimedAuxiliary&&auxiliaryCalls==1&&auxiliarySession==session&&!auxiliaryRetire&&storedDescriptor=="1:123:456:9007199254740993");
    reset("LWJGL3","GLFW");g_inputLaunchLegacy=true;CHECK(phase_publishPlatformRuntime(session));
    CHECK(claimedTyped&&claimedAuxiliary&&auxiliaryCalls==1);
    std::cout<<"PASS real startup phase: LWJGL2/322/3/SDL3, exact session, missing/unknown plan and configure failure\n";
    return 0;
}
'''
with temporary_directory(prefix='menu-cursor-startup-') as directory:
    path,binary=Path(directory)/'startup.cpp',Path(directory)/'startup.exe'
    env=dict(os.environ);env['AMCL_SDL_HOST_RUNTIME']='' # 仅此host子进程的预登记空槽。
    def check(body,negative=False):
        path.write_text(prefix.replace('@PLAN@',(CPP/'jvm/input_launch_plan.h').as_posix())
                        .replace('@CURSOR@',(CPP/'input/input_menu_cursor_snapshot.h').as_posix())+body+main,encoding='utf-8')
        compile_cpp(path,binary)
        result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=30,env=env)
        if negative:
            assert result.returncode!=0 and 'CHECK failed' in result.stderr,result.stdout+result.stderr
        else:
            assert result.returncode==0,result.stdout+result.stderr
            print(result.stdout.strip())
    check(production)
    configure=re.search(r'inputBridge_configureMenuCursorConsumerV1\([^,;]+,\s*session\)',production)
    assert configure,'real configure call required in startup phase'
    call=configure[0]
    check(production.replace(call,'inputBridge_configureMenuCursorConsumerV1(AMCL_MENU_CURSOR_BACKEND_GLFW, session)',1),True)
    print('PASS negative control: forcing GLFW for every generation')
    check(production.replace(call,'('+call+', 1)',1),True)
    print('PASS negative control: ignoring configure failure')
    auxiliary='if(!configureAuxiliarySdlRuntime(session,false))return false;'
    assert production.count(auxiliary)==1
    check(production.replace(auxiliary,'(void)configureAuxiliarySdlRuntime(session,false);',1),True)
    print('PASS negative control: ignoring auxiliary owner rejection')
