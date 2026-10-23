"""执行正式selected-handle cold guard、进程claim和绝对SDL属性冻结。

分离DLL只替代加载器边界，marker正文从完整已应用SDL series取真实函数；不伪造输入
reducer/SDL_Init。可传真实完整shared SDK路径作同一frontend正例。外置反控须编译成功。
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
from lib.host_cpp import find_host_cmake, configure_host_cmake
from lib.workspace_paths import external_output_path

ROOT=Path(__file__).resolve().parents[1]
FRONTEND=r'''
#include "input_library_claim.h"
#include <cstdio>
#include <cstdlib>
#define CHECK(v) do{if(!(v)){fprintf(stderr,"SDL INPUT CONTRACT %d: %s\n",__LINE__,#v);return 1;}}while(0)
using namespace amcl::input;
void* load(const char* path){
#ifdef _WIN32
 return reinterpret_cast<void*>(LoadLibraryA(path));
#else
 return dlopen(path,RTLD_NOW|RTLD_LOCAL);
#endif
}
int main(int argc,char** argv){
 CHECK(argc==10);void* current=load(argv[1]),*old=load(argv[2]),*wrong=load(argv[3]),*version=load(argv[4]),*thin=load(argv[5]);
 CHECK(current&&old&&wrong&&version&&thin);uint32_t observed=99;
 CHECK(amclCheckSelectedSdlInputContractV1(current,argv[1],false,&observed)==0&&observed==1);
 CHECK(amclCheckSelectedSdlInputContractV1(old,argv[2],false,&observed)==AMCL_SDL_INPUT_CONTRACT_MISSING&&observed==0);
 CHECK(amclCheckSelectedSdlInputContractV1(old,argv[2],true,&observed)==AMCL_SDL_INPUT_CONTRACT_LEGACY&&observed==0);
 CHECK(amclCheckSelectedSdlInputContractV1(wrong,argv[3],false,&observed)==AMCL_SDL_INPUT_CONTRACT_FOREIGN);
 CHECK(amclCheckSelectedSdlInputContractV1(wrong,argv[3],true,&observed)==AMCL_SDL_INPUT_CONTRACT_FOREIGN);
 CHECK(amclCheckSelectedSdlInputContractV1(thin,argv[5],false,&observed)==AMCL_SDL_INPUT_CONTRACT_FOREIGN);
 CHECK(amclCheckSelectedSdlInputContractV1(version,argv[4],true,&observed)==AMCL_SDL_INPUT_CONTRACT_VERSION&&observed==2);
 CHECK(amclCheckSelectedSdlInputContractV1(nullptr,nullptr,false,&observed)==AMCL_SDL_INPUT_CONTRACT_ARGUMENT&&observed==0);
 void* lookMissing=load(argv[6]),*lookBad=load(argv[7]),*lookForeign=load(argv[8]);CHECK(lookMissing&&lookBad&&lookForeign);
 CHECK(amclCheckSelectedSdlLookContractV1(current,argv[1],false,&observed)==0&&observed==1);
 CHECK(amclCheckSelectedSdlLookContractV1(lookMissing,argv[6],false,&observed)==AMCL_SDL_INPUT_CONTRACT_MISSING&&observed==0);
 CHECK(amclCheckSelectedSdlLookContractV1(lookMissing,argv[6],true,&observed)==AMCL_SDL_INPUT_CONTRACT_LEGACY);
 CHECK(amclCheckSelectedSdlLookContractV1(lookBad,argv[7],true,&observed)==AMCL_SDL_INPUT_CONTRACT_VERSION&&observed==2);
 CHECK(amclCheckSelectedSdlLookContractV1(lookForeign,argv[8],true,&observed)==AMCL_SDL_INPUT_CONTRACT_FOREIGN);
 std::string error;ProcessSdlInputLibraryClaim claim;
 CHECK(ValidateSelectedSdlEnvironment(nullptr,error)&&ValidateSelectedSdlEnvironment("",error));
 CHECK(!ValidateSelectedSdlEnvironment("anotherSDK.dll",error)&&error=="InputContractMismatch:sdl_dynamic_api_override");
 CHECK(!claim.VerifiedForCurrentProcess(true));CHECK(!claim.Claim("libSDL3.so",false,error));
 CHECK(claim.Claim(argv[1],false,error)&&claim.VerifiedForCurrentProcess(true)&&claim.Protocol()==1);
 CHECK(claim.Claim(argv[1],false,error));CHECK(!claim.Claim(argv[2],true,error));
 CHECK(error=="InputContractMismatch:sdl_selected_artifact_changed"&&claim.VerifiedForCurrentProcess(true));
 ProcessSdlInputLibraryClaim compatibility;CHECK(!compatibility.Claim(argv[2],false,error));
 CHECK(compatibility.Claim(argv[2],true,error)&&compatibility.VerifiedForCurrentProcess(false)&&!compatibility.VerifiedForCurrentProcess(true));
 ProcessSdlInputLibraryClaim controlOnly;CHECK(!controlOnly.Claim(argv[6],false,error)&&error=="InputContractMismatch:sdl_look_marker_missing");
 CHECK(controlOnly.Claim(argv[6],true,error)&&controlOnly.VerifiedForCurrentProcess(false)&&!controlOnly.VerifiedForCurrentProcess(true));
 std::vector<std::string> args={"-Xmx1024m","-Dorg.lwjgl.sdl.libname=libSDL3.so"};
 std::vector<amcl::jvm::BootstrapProperty> properties={{"org.lwjgl.sdl.libname","libSDL3.so"},{"amcl.input.plan","v=v1"}};
 CHECK(FreezeSelectedSdlProperty(args,properties,argv[1],error));
 CHECK(properties[0].second==argv[1]&&args[1]==std::string("-Dorg.lwjgl.sdl.libname=")+argv[1]);
 CHECK(amcl::jvm::FreezeBootstrapProperties(args,properties,error));
 CHECK(args.size()==3);auto badArgs=args;badArgs.push_back("-Dorg.lwjgl.sdl.libname=otherSDL.so");
 const auto before=badArgs;const auto beforeProps=properties;
 CHECK(!FreezeSelectedSdlProperty(badArgs,properties,argv[1],error)&&badArgs==before&&properties==beforeProps);
 CHECK(error=="InputContractMismatch:sdl_library_override");
 if(*argv[9]){void* sdk=load(argv[9]);int status=sdk?amclCheckSelectedSdlInputContractV1(sdk,argv[9],false,&observed):AMCL_SDL_INPUT_CONTRACT_ARGUMENT;
  fprintf(stderr,"actual shared SDK loaded=%d status=%d protocol=%u\n",sdk!=nullptr,status,observed);
  CHECK(sdk&&status==0&&observed==1&&amclCheckSelectedSdlLookContractV1(sdk,argv[9],false,&observed)==0&&observed==1);}
 printf("PASS selected SDL actual-handle image/exec/protocol, explicit legacy, immutable claim and absolute property freeze\n");
 return 0; // 保留所有DSO借用至进程退出，不使用FreeLibrary/dlclose伪造无人借用。
}
'''


def main(options):
    output=external_output_path(options.out);build=external_output_path(options.build_out)
    if output.exists() or build.exists():raise ValueError('Use new independent run/build directories')
    output.mkdir(parents=True);build.mkdir(parents=True);temp=build/'temp';temp.mkdir()
    os.environ['TEMP']=str(temp);os.environ['TMP']=str(temp)
    source=(options.sdk_source/'src/SDL.c').read_text(encoding='utf-8')
    hit=re.search(r'^(?:SDL_DECLSPEC|SDL_AMCL_INPUT_PUBLIC) Uint32 SDLCALL SDL_AMCL_InputControlProtocolV1\(void\)\s*\{[^}]*\}',source,re.M)
    if not hit:raise ValueError('actual complete SDK marker missing')
    marker=hit.group(0)
    lookHit=re.search(r'^(?:SDL_DECLSPEC|SDL_AMCL_INPUT_PUBLIC) Uint32 SDLCALL SDL_AMCL_InputLookProtocolV1\(void\)\s*\{[^}]*\}',source,re.M)
    if not lookHit:raise ValueError('actual complete SDK independent look marker missing')
    lookMarker=lookHit.group(0)
    prefix='#include <stdint.h>\ntypedef uint32_t Uint32;\n#define SDLCALL\n#define SDL_AMCL_INPUT_CONTROL_PROTOCOL_V1 1u\n#define SDL_AMCL_INPUT_LOOK_PROTOCOL_V1 1u\n'
    prefix+='#ifdef _WIN32\n#define SDL_DECLSPEC __declspec(dllexport)\n#else\n#define SDL_DECLSPEC __attribute__((visibility("default")))\n#endif\n'
    prefix+='#define SDL_AMCL_INPUT_PUBLIC SDL_DECLSPEC\n'
    standard='extern "C" SDL_DECLSPEC int SDL_GetVersion(void){return 3006000;}\n'
    (build/'new.cpp').write_text(prefix+'extern "C" '+marker+'\nextern "C" '+lookMarker+'\n'+standard,encoding='utf-8')
    # 使用任务专属模块名；version.dll是Windows系统依赖，不能让坏协议fixture遮住它。
    (build/'amcl_bad_protocol.cpp').write_text(prefix.replace('PROTOCOL_V1 1u','PROTOCOL_V1 2u')+'extern "C" '+marker+'\n'+standard,encoding='utf-8')
    (build/'old.cpp').write_text(prefix+standard,encoding='utf-8')
    (build/'fake.cpp').write_text(prefix+'extern "C" '+marker+'\nextern "C" '+lookMarker+'\n'+standard,encoding='utf-8')
    (build/'look_missing.cpp').write_text(prefix+'extern "C" '+marker+'\n'+standard,encoding='utf-8')
    (build/'look_bad.cpp').write_text(prefix.replace('LOOK_PROTOCOL_V1 1u','LOOK_PROTOCOL_V1 2u')+'extern "C" '+marker+'\nextern "C" '+lookMarker+'\n'+standard,encoding='utf-8')
    foreignLook=prefix+'extern "C" '+marker+'\n'+standard
    if os.name=='nt':(build/'look_foreign.def').write_text('LIBRARY look_foreign\nEXPORTS\n SDL_AMCL_InputLookProtocolV1=fake.SDL_AMCL_InputLookProtocolV1\n',encoding='utf-8')
    else:foreignLook+='extern "C" uint32_t SDL_AMCL_InputLookProtocolV1(void);\nextern "C" SDL_DECLSPEC uint32_t retainLookDependency(void){return SDL_AMCL_InputLookProtocolV1();}\n'
    (build/'look_foreign.cpp').write_text(foreignLook,encoding='utf-8')
    wrong=prefix+standard
    if os.name=='nt':(build/'wrong.def').write_text('LIBRARY wrong\nEXPORTS\n SDL_AMCL_InputControlProtocolV1=fake.SDL_AMCL_InputControlProtocolV1\n',encoding='utf-8')
    else:wrong+='extern "C" uint32_t SDL_AMCL_InputControlProtocolV1(void);\nextern "C" SDL_DECLSPEC uint32_t retainFakeDependency(void){return SDL_AMCL_InputControlProtocolV1();}\n'
    (build/'wrong.cpp').write_text(wrong,encoding='utf-8');(build/'frontend.cpp').write_text(FRONTEND,encoding='utf-8')
    thin=prefix+'extern "C" SDL_DECLSPEC int ownThinImage(void){return 1;}\n'
    if os.name=='nt':
        (build/'thin.def').write_text('LIBRARY thin\nEXPORTS\n SDL_GetVersion=fake.SDL_GetVersion\n SDL_AMCL_InputControlProtocolV1=fake.SDL_AMCL_InputControlProtocolV1\n',encoding='utf-8')
    else:
        thin+='extern "C" uint32_t SDL_AMCL_InputControlProtocolV1(void);\nextern "C" int SDL_GetVersion(void);\nextern "C" SDL_DECLSPEC uint32_t retainBoth(void){return SDL_AMCL_InputControlProtocolV1()+SDL_GetVersion();}\n'
    (build/'thin.cpp').write_text(thin,encoding='utf-8')
    jvm=ROOT/'entry/src/main/cpp/jvm';header=(jvm/'sdl_input_contract.h').read_text(encoding='utf-8')
    # 两个单点反控使用正式guard全正文；外置副本只去掉实际协议/映像判断。
    (build/'candidate').mkdir();(build/'candidate/input_library_claim.h').write_bytes((jvm/'input_library_claim.h').read_bytes())
    project='''cmake_minimum_required(VERSION 3.20)
project(sdl_cold_contract LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
foreach(name IN ITEMS new old fake wrong amcl_bad_protocol thin look_missing look_bad look_foreign)
 add_library(${name} SHARED ${name}.cpp)
endforeach()
target_link_libraries(wrong PRIVATE fake)
target_link_libraries(thin PRIVATE fake)
target_link_libraries(look_foreign PRIVATE fake)
if(WIN32)
 target_sources(wrong PRIVATE wrong.def)
 target_sources(thin PRIVATE thin.def)
 target_sources(look_foreign PRIVATE look_foreign.def)
else()
 set_target_properties(wrong PROPERTIES BUILD_RPATH "$ORIGIN")
 set_target_properties(thin PROPERTIES BUILD_RPATH "$ORIGIN")
endif()
add_executable(frontend frontend.cpp)
target_include_directories(frontend PRIVATE "@JVM@")
add_executable(negative frontend.cpp)
target_include_directories(negative PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/candidate" "@JVM@")
if(MSVC)
 foreach(name IN ITEMS new old fake wrong amcl_bad_protocol thin look_missing look_bad look_foreign frontend negative)
  target_compile_options(${name} PRIVATE /utf-8)
 endforeach()
else()
 add_compile_definitions(_GNU_SOURCE)
 target_link_libraries(frontend PRIVATE ${CMAKE_DL_LIBS})
 target_link_libraries(negative PRIVATE ${CMAKE_DL_LIBS})
endif()
'''.replace('@JVM@',jvm.as_posix())
    (build/'candidate/sdl_input_contract.h').write_text(header,encoding='utf-8')
    (build/'CMakeLists.txt').write_text(project,encoding='utf-8')
    cmake=None
    if os.name=='nt':
        cmake=find_host_cmake(options.cmake);configure_host_cmake(cmake,build,build/'build')
    else:
        (build/'build').mkdir()
    def compile_target(target,log):
        if os.name=='nt':
            commands=[[cmake,'--build',str(build/'build'),'--config','Release','--target',*target]]
        else:
            compiler=shutil.which('g++')
            if not compiler:raise FileNotFoundError('Actual POSIX C++ compiler missing')
            commands=[]
            for name in target:
                flags=[compiler,'-std=c++17','-pthread','-D_GNU_SOURCE']
                if name in ('frontend','negative'):
                    if name=='negative':flags+=['-I'+str(build/'candidate')]
                    flags+=['-I'+str(jvm),str(build/'frontend.cpp'),'-ldl','-o',str(build/'build'/name)]
                else:
                    flags+=['-fPIC','-shared',str(build/(name+'.cpp'))]
                    if name in ('wrong','thin','look_foreign'):flags+=['-L'+str(build/'build'),'-lfake','-Wl,-rpath,$ORIGIN']
                    flags+=['-o',str(build/'build'/('lib'+name+'.so'))]
                commands.append(flags)
        with log.open('wb') as stream:
            for command in commands:
                result=subprocess.run(command,capture_output=True)
                stream.write(result.stdout+result.stderr);assert result.returncode==0,str(log)
    compile_target(['new','old','fake','wrong','amcl_bad_protocol','thin','look_missing','look_bad','look_foreign','frontend'],output/'compile.log')
    suffix='.dll' if os.name=='nt' else '.so'
    directory=build/('build/Release' if os.name=='nt' else 'build')
    libraries=[str(directory/((name if os.name=='nt' else 'lib'+name)+suffix)) for name in ['new','old','wrong','amcl_bad_protocol','thin','look_missing','look_bad','look_foreign']]
    def check(binary,log,negative=False):
        result=subprocess.run([str(binary),*libraries,str(options.sdk_library) if options.sdk_library else ''],capture_output=True,timeout=30)
        log.write_bytes(result.stdout+result.stderr)
        text=(result.stdout+result.stderr).decode('utf-8',errors='replace');print(text.strip(),flush=True)
        assert (result.returncode!=0 and 'SDL INPUT CONTRACT' in text) if negative else result.returncode==0,str(log)
        return result.returncode
    facts=[{'mode':'production','exit':check(directory/('frontend.exe' if os.name=='nt' else 'frontend'),output/'production.log')}]
    for mode,before,after in [
        ('missing-marker-fails-open','allowLegacy?AMCL_SDL_INPUT_CONTRACT_LEGACY:AMCL_SDL_INPUT_CONTRACT_MISSING','AMCL_SDL_INPUT_CONTRACT_LEGACY'),
        ('foreign-marker-accepted','standardOwner!=module||markerOwner!=module||','false||') if os.name=='nt' else
        ('foreign-marker-accepted','standardOwner.dli_fbase!=markerOwner.dli_fbase','false'),
        *([] if os.name=='nt' else [('selected-thin-dependency-accepted',
            'expectedFile.st_dev!=standardFile.st_dev||expectedFile.st_ino!=standardFile.st_ino','false')]),
    ]:
        assert before in header,mode
        (build/'candidate/sdl_input_contract.h').write_text(header.replace(before,after),encoding='utf-8')
        compile_target(['negative'],output/(mode+'-compile.log'))
        facts.append({'mode':mode,'exit':check(directory/('negative.exe' if os.name=='nt' else 'negative'),output/(mode+'.log'),True)})
    (output/'receipt.json').write_text(json.dumps({'schema':1,'modes':facts,'sdkMarkerSource':str(options.sdk_source/'src/SDL.c'),
        'sdkMarkerSourceSha256':hashlib.sha256((options.sdk_source/'src/SDL.c').read_bytes()).hexdigest(),
        'actualSharedSdk':str(options.sdk_library) if options.sdk_library else None,
        'layer':'actual OS DSO linkage fixtures and production cold/bootstrap headers; marker is full-series SDK production body; optional actual shared SDK',
        'sources':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [jvm/'sdl_input_contract.h',jvm/'input_library_claim.h']}},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk-source',type=Path,required=True)
    parser.add_argument('--sdk-library',type=Path)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--build-out',type=Path,required=True)
    parser.add_argument('--cmake')
    main(parser.parse_args())
