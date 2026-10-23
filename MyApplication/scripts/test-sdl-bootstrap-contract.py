"""抽取实际mc_launcher输入prepare/publish正文并执行源码路径正反例。

DDL/JNI输出版仅作边界计数；实际plan、SDL owner/cold检查、env槽和freeze规则都用正式头。
缺契约不得publish/prepare consumer，非SDL不装库；不将此宿主证明扩大为游戏Ready。
"""
from pathlib import Path
import argparse
import importlib.util
import json
import hashlib
import os
import shutil
import subprocess
from lib.host_cpp import find_host_cmake, configure_host_cmake
from lib.workspace_paths import external_output_path

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('bootstrap_extract',ROOT/'scripts/generate-desktop-review-tests.py')
recipe=importlib.util.module_from_spec(spec);spec.loader.exec_module(recipe)
source=(ROOT/'entry/src/main/cpp/jvm/mc_launcher.cpp').read_text(encoding='utf-8')
production='\n'.join(recipe.function(source,name) for name in ['phase_prepareInputArtifact','phase_publishPlatformRuntime'])
PREFIX=r'''
#include "input_library_claim.h"
#include "input_launch_plan.h"
#include "../platform/env_slot.h"
#include "../input/input_menu_cursor_snapshot.h"
#include <iostream>
#include <cstdlib>
#ifdef _WIN32
#define getpid _getpid
#define SYS_gettid 1
long syscall(int){return GetCurrentThreadId();}
#else
#include <sys/syscall.h>
#endif
#define AMCL_LOG_I(...) ((void)0)
#define JNI_OK 0
#define CHECK(v) do{if(!(v)){std::cerr<<"SDL BOOTSTRAP "<<__LINE__<<": "<<#v<<'\n';std::exit(1);}}while(0)
using namespace amcl::input;
std::string g_mcStatus;
LaunchPlan g_inputLaunchPlan;
ProcessSdlInputLibraryClaim g_sdlInputLibraryClaim;
bool g_inputLaunchLegacy=false;
int published=0,configured=0;
int publishCallbackBridgeHostV1(uint64_t){++published;return 0;}
extern "C" int inputBridge_configureMenuCursorConsumerV1(uint32_t,uint64_t){++configured;return 1;}
'''
MAIN=r'''
int main(int argc,char** argv){
 CHECK(argc==3);std::string mode=argv[1],directory=argv[2],error;
 LaunchPlan sdl{"v1","SDL3","LWJGL3","SDL3","libSDL3.so","sdl-present-1"};
 std::vector<std::string> args{"-Xmx1024m"};std::vector<amcl::jvm::BootstrapProperty> props{{"org.lwjgl.sdl.libname","libSDL3.so"}};
 if(mode=="unverified-publish"){
  g_inputLaunchPlan=sdl;
  CHECK(!phase_publishPlatformRuntime(42)&&published==0&&configured==0);
 }else if(mode=="non-sdl"){
  LaunchPlan glfw{"v1","GLFW","LWJGL3","GLFW","libglfw.so","glfw-present-2"};
  CHECK(phase_prepareInputArtifact(glfw,false,"/does-not-exist",args,props,error));
  CHECK(g_inputLaunchPlan.abi=="GLFW"&&!g_sdlInputLibraryClaim.VerifiedForCurrentProcess(false));
  CHECK(phase_publishPlatformRuntime(42)&&published==1&&configured==1);
 }else if(mode=="missing"||mode=="override"||mode=="dynapi"){
  if(mode=="override")args.push_back("-Dorg.lwjgl.sdl.libname=other.so");
  if(mode=="dynapi"){
#ifdef _WIN32
   _putenv_s("SDL3_DYNAMIC_API","other.so");
#else
   setenv("SDL3_DYNAMIC_API","other.so",1);
#endif
  }
  const auto before=args;const auto propertiesBefore=props;
  CHECK(!phase_prepareInputArtifact(sdl,false,directory,args,props,error));
  CHECK(args==before&&props==propertiesBefore&&g_inputLaunchPlan.abi.empty());
  CHECK(!phase_publishPlatformRuntime(42)&&published==0&&configured==0);
  if(mode=="dynapi")CHECK(std::string(getenv("SDL3_DYNAMIC_API"))=="other.so");
 }else{
  const bool legacy=mode=="legacy";
  CHECK(phase_prepareInputArtifact(sdl,legacy,directory,args,props,error));
  CHECK(props[0].second==directory+"/libSDL3.so"&&g_inputLaunchPlan.abi=="SDL3");
  CHECK(g_sdlInputLibraryClaim.VerifiedForCurrentProcess(!legacy));
  CHECK(amcl::envslot::ProcessRegistry().Register(amcl::envslot::kSdlHostRuntimeEnv,amcl::envslot::Kind::kText,127,"")>=0);
  CHECK(phase_publishPlatformRuntime(42)&&published==1&&configured==1);
 }
 std::cout<<"PASS actual input artifact prepare/publish: "<<mode<<'\n';
}
'''

def main(options):
    run=external_output_path(options.out);build=external_output_path(options.build_out)
    if run.exists() or build.exists():raise ValueError('Use fresh independent run/build directories')
    run.mkdir(parents=True);build.mkdir(parents=True);temp=build/'temp';temp.mkdir();os.environ['TEMP']=str(temp);os.environ['TMP']=str(temp)
    for name,path in [('new',options.sdk_library),('old',options.old_fixture)]:
        folder=build/name;folder.mkdir();shutil.copyfile(path,folder/'libSDL3.so')
    fixture=build/'fixture.cpp';fixture.write_text(PREFIX+production+MAIN,encoding='utf-8')
    jvm=ROOT/'entry/src/main/cpp/jvm';cmake=find_host_cmake(options.cmake)
    (build/'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.20)
project(sdl_bootstrap_contract LANGUAGES CXX)
add_executable(bootstrap fixture.cpp)
target_compile_features(bootstrap PRIVATE cxx_std_17)
target_include_directories(bootstrap PRIVATE "@JVM@")
target_compile_definitions(bootstrap PRIVATE _CRT_SECURE_NO_WARNINGS)
if(MSVC)
 target_compile_options(bootstrap PRIVATE /utf-8)
else()
 target_compile_definitions(bootstrap PRIVATE _GNU_SOURCE)
 target_link_libraries(bootstrap PRIVATE ${CMAKE_DL_LIBS} pthread)
endif()
'''.replace('@JVM@',jvm.as_posix()),encoding='utf-8')
    configure_host_cmake(cmake,build,build/'build')
    def compile(name):
        result=subprocess.run([cmake,'--build',str(build/'build'),'--config','Release'],capture_output=True)
        (run/(name+'-compile.log')).write_bytes(result.stdout+result.stderr);assert result.returncode==0,name
    compile('production');binary=build/('build/Release/bootstrap.exe' if os.name=='nt' else 'build/bootstrap')
    facts=[]
    def check(mode,negative=False,label=None):
        directory=build/('old' if mode in ('missing','legacy') else 'new')
        result=subprocess.run([str(binary),mode,str(directory)],capture_output=True,timeout=30)
        text=(result.stdout+result.stderr).decode('utf-8',errors='replace');print(text.strip(),flush=True)
        (run/((label or mode)+'.log')).write_text(text,encoding='utf-8')
        assert (result.returncode!=0 and 'SDL BOOTSTRAP' in text) if negative else result.returncode==0,mode
        facts.append({'mode':label or mode,'exit':result.returncode,'negative':negative})
    for mode in ['missing','unverified-publish','non-sdl','override','dynapi','legacy','production']:check(mode)
    for name,before,after,mode in [
        ('publish-suppresses-artifact-check','!g_sdlInputLibraryClaim.VerifiedForCurrentProcess(!g_inputLaunchLegacy)','false','unverified-publish'),
        ('non-sdl-also-loads','if (plan.abi == "SDL3")','if (true)','non-sdl'),
        ('dynapi-not-rejected','!amcl::input::ValidateSelectedSdlEnvironment(std::getenv("SDL3_DYNAMIC_API"), error)','false','dynapi'),
    ]:
        assert production.count(before)==1,name
        fixture.write_text(PREFIX+production.replace(before,after,1)+MAIN,encoding='utf-8');compile(name);check(mode,True,name)
    (run/'receipt.json').write_text(json.dumps({'schema':1,'modes':facts,'scope':'production launcher prepare/publish bodies; transport/JNI boundary counters; no JVM/Ready claim',
        'sources':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [ROOT/'entry/src/main/cpp/jvm/mc_launcher.cpp',jvm/'sdl_input_contract.h',jvm/'input_library_claim.h']},
        'sdkLibrarySha256':hashlib.sha256(options.sdk_library.read_bytes()).hexdigest()},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk-library',type=Path,required=True)
    parser.add_argument('--old-fixture',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--build-out',type=Path,required=True)
    parser.add_argument('--cmake')
    main(parser.parse_args())
