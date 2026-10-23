"""复用已编完整SDL静态SDK，用当前真实Source/Core/bridge执行来源贡献纵向回归。"""
from pathlib import Path
from datetime import datetime
import argparse
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
sys.dont_write_bytecode=True
from lib.host_cpp import configure_host_cmake,find_host_cmake
from lib.workspace_paths import external_output_path
ROOT=Path(__file__).resolve().parents[1]

def function_span(text,name):
    """定位明确的静态函数定义并按花括号取完整正文；声明或找不到定义均拒绝测试装配。"""
    hit=re.search(r'static (?:int|bool|Uint64|SDL_Scancode|Uint8) '+name+r'\([^;{}]*\)\s*\{',text)
    assert hit,name
    depth=1;end=hit.end()
    while depth:
        if text[end]=='{':depth+=1
        elif text[end]=='}':depth-=1
        end+=1
    return hit.start(),end

def replace_function(text,name,body):
    """只改夹具链接边缘，或以同一SDK真实正文替换原映射替身；不复制消费或来源算法。"""
    start,end=function_span(text,name)
    return text[:start]+body+text[end:]

def borrowed_paths(cpp,sdk,base,library,fixture,support):
    """在提取/生成消费者前封住实际借用源；这里只登记字节，不把现存源码推断成建库证明。"""
    paths=[fixture,support,Path(__file__).resolve(),ROOT/'scripts/test-sdl-look-prefix.py',
        ROOT/'scripts/test-sdl-control-delivery.py',ROOT/'scripts/fixtures/input-consumer/sdl_control_production.c.in',
        ROOT/'scripts/fixtures/input-consumer/sdl_look_production.c.in',ROOT/'scripts/lib/host_cpp.py',
        ROOT/'scripts/lib/workspace_paths.py',base/'CMakeLists.txt',base/'build/CMakeCache.txt',library]
    for directory in [cpp/'input',cpp/'platform',cpp/'glfw',cpp/'tests/host/stubs',sdk/'include',sdk/'src',base/'build/sdk']:
        # portable消费用SDK真实导出target，实际CMake正文也与库/源一起封住，避免借库期间链接材料漂移。
        paths += [p for p in directory.rglob('*') if p.is_file() and p.suffix in ('.h','.c','.cpp','.in','.cmake')]
    return list(dict.fromkeys(paths))

def main(args):
    """不复制/重建大SDK树；SDK库、维护源码/配方与新输入源独立记录真实身份。"""
    started=datetime.now().astimezone().isoformat();out=external_output_path(args.out);build=external_output_path(args.build_out)
    # Windows与实际Ubuntu QA共用生产场景，只条件化工具/制品布局；未知宿主明确失败不skip。
    if os.name!='nt' and sys.platform!='linux':raise ValueError('SDL source host recipe supports Windows and Linux only')
    out.mkdir(parents=True,exist_ok=False);build.mkdir(parents=True,exist_ok=args.reuse_build)
    temp=build/'temp';temp.mkdir(exist_ok=args.reuse_build);os.environ['TEMP']=str(temp);os.environ['TMP']=str(temp)
    base=Path(args.sdk_host_tree).resolve();sdk=base/'source'
    library=base/('build/sdk/Release/SDL3-static.lib' if os.name=='nt' else 'build/sdk/libSDL3.a')
    if not library.is_file():raise ValueError('existing complete SDL host static SDK required')
    cpp=ROOT/'entry/src/main/cpp'
    # 永久 owned 文本门只选择这一份已知 fixture；正常来源门仍执行原完整场景，
    # 不接受任意 provider/脚本文档作为可执行输入，也不修改 SDK/Source 生产实现。
    owned_text=bool(getattr(args,'owned_text',False))
    fixture=ROOT/'scripts/fixtures/input-consumer'/('sdl_owned_text_production.c.in' if owned_text else 'sdl_source_production.c.in')
    support=ROOT/'scripts/fixtures/input-consumer/sdl_source_support.cpp.in'
    tracked=borrowed_paths(cpp,sdk,base,library,fixture,support)
    before={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    spec=importlib.util.spec_from_file_location('sdl_look_helper',ROOT/'scripts/test-sdl-look-prefix.py')
    helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper)
    production=(sdk/'src/video/openharmony/SDL_openharmonyamcl.c').read_text(encoding='utf-8')
    # 既有完整SDK consumer保持其所有生产函数；仅将材料reader改为真正bridge/backend。
    prelude=helper.fixture(production).split('static Uint64 tickNs=')[0]
    declarations='''
#include "input/source/source_control_client.h"
void sourceSdkActivate(void);void sourceSdkDeactivate(void);int sourceSdkBind(void);void sourceSdkMode(int);
int sourceSdkNext(int*,int*,int*,int*,int*);Uint64 sourceSdkPeek(void);
int sourceSdkNextThrough(int*,int*,int*,int*,int*,Uint64);
void sourceSdkKey(int,int);void sourceSdkButton(int,int);void sourceSdkFill(int);int sourceSdkLook(double,double);
int amclBackendInputReadText(Uint32,Uint64,Uint8*,Uint32,Uint32*);
int amclBackendInputReleaseText(Uint32,Uint64);
'''
    prelude=prelude.replace('#include "input_interaction_order.h"','#include "input_interaction_order.h"'+declarations)
    prelude=replace_function(prelude,'nextLegacy','static int nextLegacy(int*t,int*a,int*b,int*c,int*d){return sourceSdkNext(t,a,b,c,d);}')
    prelude=replace_function(prelude,'peekLegacyOrder','static Uint64 peekLegacyOrder(void){return sourceSdkPeek();}')
    prelude=replace_function(prelude,'frameFence','static Uint64 frameFence(void){return amclInputInteractionFence();}')
    prelude=replace_function(prelude,'nextLegacyThrough','static int nextLegacyThrough(int*t,int*a,int*b,int*c,int*d,Uint64 limit){return sourceSdkNextThrough(t,a,b,c,d,limit);}')
    prelude=replace_function(prelude,'nextTyped','static int nextTyped(Uint32 backend,AMCL_BackendInputEvent*out){AmclBackendInputEvent e;int result=amclBackendInputNext(backend,&e);if(result==1){CHECK(sizeof(e)==sizeof(*out));SDL_memcpy(out,&e,sizeof(e));}return result;}')
    prelude=replace_function(prelude,'nextTypedThrough','static int nextTypedThrough(Uint32 backend,AMCL_BackendInputEvent*out,Uint64 limit){AmclBackendInputEvent e;int result=amclBackendInputNextThrough(backend,&e,limit);if(result==1){CHECK(sizeof(e)==sizeof(*out));SDL_memcpy(out,&e,sizeof(e));}return result;}')
    # 新文本顺序场不能沿用look夹具固定失败的packet reader。真实SDK消费正文保持逐字，
    # 只把已解析的reader/release地址边缘接到本次链接的唯一production backend。
    # 这证明copy/release与SDK ADD/Poll，不把边缘代称商业OS dlopen/namespace资格。
    start,end=function_span(production,'OPENHARMONY_ReadAndReleaseText')
    packet_edge='''typedef int (*OPENHARMONY_TextReadFn)(Uint32,Uint64,Uint8*,Uint32,Uint32*);
typedef int (*OPENHARMONY_TextReleaseFn)(Uint32,Uint64);
static OPENHARMONY_TextReadFn OPENHARMONY_GetTextRead(const OPENHARMONY_HostBridge*b){(void)b;return amclBackendInputReadText;}
static OPENHARMONY_TextReleaseFn OPENHARMONY_GetTextRelease(const OPENHARMONY_HostBridge*b){(void)b;return amclBackendInputReleaseText;}
'''
    prelude=replace_function(prelude,'OPENHARMONY_ReadAndReleaseText',packet_edge+production[start:end])
    if owned_text:
        # 文本专门门使用完整真实私有 bridge 字段与 descriptor parser。ready 从0开始，
        # fixture只在真实解析成功并发布字段后采用它，不用固定 true reader/假 blob。
        def actual_static(name):
            """保留 SDK 的完整定义，支持返回函数指针 typedef 的两个真实 getter。"""
            hit=re.search(r'static [A-Za-z_]\w*\s+'+re.escape(name)+r'\([^;{}]*\)\s*\{',production)
            if not hit:raise ValueError('Actual text definition missing: '+name)
            depth=1;end=hit.end()
            while depth:
                depth+=(production[end]=='{')-(production[end]=='}');end+=1
            return production[hit.start():end]
        full_bridge=re.search(r'typedef struct\s*\{[^}]*\}\s*OPENHARMONY_HostBridge;',production).group(0)
        prelude=re.sub(r'typedef struct OPENHARMONY_HostBridge\s*\{[^}]*\}\s*OPENHARMONY_HostBridge;',lambda _:full_bridge,prelude,count=1)
        prelude=replace_function(prelude,'OPENHARMONY_ValidUtf8Bytes',actual_static('OPENHARMONY_ValidUtf8Bytes'))
        a=prelude.index('typedef int (*OPENHARMONY_TextReadFn)');b=prelude.index('static bool OPENHARMONY_ReadAndReleaseText',a)
        packet_bindings='''typedef int (*OPENHARMONY_TextReadFn)(Uint32,Uint64,Uint8*,Uint32,Uint32*);
typedef int (*OPENHARMONY_TextReleaseFn)(Uint32,Uint64);
static SDL_AtomicInt host_text_state;
'''+actual_static('OPENHARMONY_GetTextRead')+'\n'+actual_static('OPENHARMONY_GetTextRelease')+'\n'+actual_static('OPENHARMONY_ResolveTextBridgeFromEnvironment')+'\n'
        # 不由fixture直接赋READY；逐字取GetHostBridge中真正的CAS/解析/字段发布分支。
        # 只保窗口发现这条外部边缘，文本资格、失败恢复与内存发布沿真实SDK正文。
        adoption='if (SDL_GetAtomicInt(&host_text_state) == AMCL_TEXT_UNRESOLVED &&'
        a0=production.index(adoption);brace=production.index('{',a0)+1;depth=1;b0=brace
        while depth:
            depth+=(production[b0]=='{')-(production[b0]=='}');b0+=1
        packet_bindings+='static void adoptProductionTextBindings(OPENHARMONY_HostBridge *bridge){\n'+production[a0:b0]+'\n}\n'
        prelude=prelude[:a]+packet_bindings+prelude[b:]
        old='static OPENHARMONY_HostBridge bridge={nextLegacy,getCursor,isGrabbing,frameFence,nextTypedThrough,peekLegacyOrder,nextLegacyThrough,UINT64_MAX,0,false};'
        if prelude.count(old)!=1:raise ValueError('Actual fixture bridge initializer must be unique')
        prelude=prelude.replace(old,'static OPENHARMONY_HostBridge bridge;',1)
        # 仅观察真实backend刚交出的packet/scalars；记录器不保存或制造文本blob。
        prelude=prelude.replace('int amclBackendInputReadText(Uint32,Uint64,Uint8*,Uint32,Uint32*);',
            'int amclBackendInputReadText(Uint32,Uint64,Uint8*,Uint32,Uint32*);\nvoid recordOwnedPacket(const AmclBackendInputEvent*);',1)
        anchor='SDL_memcpy(out,&e,sizeof(e));'
        if prelude.count(anchor)!=2:raise ValueError('Two actual backend readers required')
        prelude=prelude.replace(anchor,anchor+'recordOwnedPacket(&e);')
        if args.negative=='text-read-withdrawn':
            prelude=replace_function(prelude,'OPENHARMONY_ReadAndReleaseText',
                'static bool OPENHARMONY_ReadAndReleaseText(OPENHARMONY_HostBridge*b,Uint64 p,Uint32 n,Uint8**out){(void)b;(void)p;(void)n;*out=NULL;return false;}')
        elif args.negative=='text-release-withdrawn':
            release_anchor='const int release_status = release(AMCL_BACKEND_ID_SDL3, packet);'
            if prelude.count(release_anchor)!=1:raise ValueError('Actual release boundary must be unique')
            prelude=prelude.replace(release_anchor,'const int release_status = AMCL_BACKEND_RESULT_EVENT; /* 编译撤回：不执行实际 release。 */',1)
        elif args.negative=='text-scalar-withdrawn':
            scalar_anchor='(const char *)text, (int)event.action,\n                    (int)event.modifiers'
            if prelude.count(scalar_anchor)!=1:raise ValueError('Actual scalar projection must be unique')
            prelude=prelude.replace(scalar_anchor,'(const char *)text, (int)event.action + 3,\n                    (int)event.modifiers',1)
    # GLFW码与SDL scancode/button值不能强转：A-F及右/中键在两套枚举中不同，采用维护SDK真实映射定义。
    for name in ['OPENHARMONY_ScancodeFromGlfwKey','OPENHARMONY_ButtonFromGlfwButton']:
        start,end=function_span(production,name)
        prelude=replace_function(prelude,name,production[start:end])
    if args.negative=='simplified-mapping':
        # 仅在外置consumer中恢复旧简化映射，证明新最终ABI断言能发现枚举错误；维护SDK和产品源不改。
        prelude=replace_function(prelude,'OPENHARMONY_ScancodeFromGlfwKey',
            'static SDL_Scancode OPENHARMONY_ScancodeFromGlfwKey(int key){return key==65?SDL_SCANCODE_A:(SDL_Scancode)key;}')
        prelude=replace_function(prelude,'OPENHARMONY_ButtonFromGlfwButton',
            'static Uint8 OPENHARMONY_ButtonFromGlfwButton(int button){return (Uint8)(button+1);}')
    (build/'consumer.c').write_text(fixture.read_text(encoding='utf-8').replace('@PRELUDE@',prelude),encoding='utf-8')
    shutil.copyfile(support,build/'support.cpp')
    names=['input/source/source_control.cpp','platform/input_ledger.cpp','platform/external_held_registry.cpp',
      'platform/external_held_edge_router.cpp','platform/legacy_output_runtime.cpp','platform/legacy_physical_edge_router.cpp',
      'input/delivery/control_delivery.cpp','input/delivery/look_execution.cpp','input/input_state_core.cpp','input/amcl_input_host_descriptor.cpp',
      'input/input_interaction_order.cpp','platform/look_delta_math.cpp','platform/look_pipeline_stats.cpp','platform/physical_wheel_quantizer.cpp',
      'platform/input_source.cpp','glfw/input_bridge_ohos.c','input/adapters/backend_input_bridge.cpp','input/adapters/glfw_input_adapter.cpp',
      'input/adapters/backend_keymaps.cpp','input/adapters/glfw_source_plane_aggregate.cpp','input/adapters/lwjgl2_event_translate.cpp']
    native_sources=[cpp/name for name in names];bridge=cpp/'glfw/input_bridge_ohos.c'
    if args.negative in ('compat-bypass','budget2'):
        body=bridge.read_text(encoding='utf-8')
        old,new= ('(void)amclSourceControlCompatEdgeV1(0u,key,scancode,action,mods);',
          'inputBridge_pushEvent(EVENT_TYPE_KEY,key,scancode,action,mods);') if args.negative=='compat-bypass' else (
          'lookRingReserveLocked(count+(grabbed?1u:0u))','lookRingReserveLocked(2)')
        assert body.count(old)==1;body=body.replace(old,new,1)
        body=re.sub(r'#include "([^\"]+)"',lambda match:'#include "'+(bridge.parent/match[1]).resolve().as_posix()+'"',body)
        modified=build/'negative_bridge.cpp';modified.write_text(body,encoding='utf-8')
        native_sources=[modified if path==bridge else path for path in native_sources];bridge=modified
    text='cmake_minimum_required(VERSION 3.20)\nproject(sdl_source C CXX)\nset(CMAKE_CXX_STANDARD 17)\n'
    # 单配置Linux使用真实Release布局；SDK自身导出的static target给出真实系统链接依赖。
    if os.name!='nt':text+='set(CMAKE_BUILD_TYPE Release CACHE STRING "host configuration" FORCE)\n'
    text+='find_package(SDL3 CONFIG REQUIRED PATHS "'+(base/'build/sdk').as_posix()+'" NO_DEFAULT_PATH)\n'
    text+='add_executable(consumer consumer.c support.cpp '+' '.join('"'+path.as_posix()+'"' for path in native_sources)+')\n'
    text+='set_property(TARGET consumer PROPERTY C_STANDARD 11)\n'
    text+='set_source_files_properties("'+bridge.as_posix()+'" PROPERTIES LANGUAGE CXX)\n'
    text+='target_compile_definitions(consumer PRIVATE SDL_VIDEO_DRIVER_OPENHARMONY AMCL_CONTROL_DELIVERY_HOST_TESTING AMCL_INPUT_HOST_TESTING AMCL_INPUT_HOST_EXPORTS AMCL_INPUT_BRIDGE_HOST_TESTING _CRT_SECURE_NO_WARNINGS NOMINMAX EVENT_WINDOW_SIZE=8)\n'
    if owned_text:
        # 文本门必须真实建立backend consumer，不能使用Core测试宏放松Ready准入。
        text=text.replace(' AMCL_INPUT_HOST_TESTING ',' ')
    text+='target_compile_definitions(consumer PRIVATE AMCL_GLFW_TYPED_PHYSICAL_DEFAULT=1 AMCL_GLFW_RAW_RELATIVE_VERIFIED=1 AMCL_GLFW_API26_RAW_MOUSE_MOTION=1 AMCL_GATE0_EVIDENCE_IDS="host-sdl-source")\n'
    include=[sdk/'src',sdk/'include',base/'build/sdk/include-config-release/build_config',base/'build/sdk/include-revision',sdk/'src/video/openharmony',cpp,cpp/'input',cpp/'tests/host/stubs']
    text+='target_include_directories(consumer PRIVATE '+' '.join('"'+p.as_posix()+'"' for p in include)+')\n'
    if os.name=='nt':text+='target_compile_options(consumer PRIVATE /utf-8)\nset_source_files_properties(consumer.c PROPERTIES COMPILE_OPTIONS "/experimental:c11atomics")\n'
    else:
        text+='target_compile_definitions(consumer PRIVATE _GNU_SOURCE)\ntarget_link_options(consumer PRIVATE -rdynamic)\n'
        # 真实bridge的host宏POSIX分支仅声明pthread，Linux菜单PID仍调用真正getpid。
        # 只给这个编成C++的宿主TU补系统声明；不换函数、产品头、PID身份或任何业务断言。
        text+='set_property(SOURCE "'+bridge.as_posix()+'" APPEND PROPERTY COMPILE_OPTIONS -include unistd.h)\n'
    text+='target_link_libraries(consumer PRIVATE SDL3::SDL3-static ${CMAKE_DL_LIBS})\n'
    (build/'CMakeLists.txt').write_text(text,encoding='utf-8');cmake=find_host_cmake(args.cmake);configure_host_cmake(cmake,build,build/'build')
    compile_run=subprocess.run([cmake,'--build',str(build/'build'),'--config','Release','--parallel','8'],capture_output=True)
    (out/'compile.log').write_bytes(compile_run.stdout+compile_run.stderr);print((compile_run.stdout+compile_run.stderr).decode(errors='replace'),flush=True);compile_run.check_returncode()
    binary=build/('build/Release/consumer.exe' if os.name=='nt' else 'build/consumer')
    result=subprocess.run([str(binary)],capture_output=True,timeout=30)
    (out/'behavior.log').write_bytes(result.stdout+result.stderr);print((result.stdout+result.stderr).decode(errors='replace'),flush=True)
    after={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked};drift=[p for p in before if before[p]!=after[p]]
    # 生成源、真实链接配方与执行二进制单独绑定，以免把旧行为日志借给后来改写的缓存文件。
    generated=[build/'consumer.c',build/'support.cpp',build/'CMakeLists.txt',binary]
    if args.negative in ('compat-bypass','budget2'):generated.append(build/'negative_bridge.cpp')
    generated_identity={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in generated}
    (out/'receipt.json').write_text(json.dumps({'startedAt':started,'finishedAt':datetime.now().astimezone().isoformat(),
      'exitCode':result.returncode,'negative':args.negative,'harnessPlatform':'Windows/MSVC' if os.name=='nt' else 'Linux/native CMake compiler',
      'sdkStaticLibrary':{'path':str(library),'sha256':after[str(library)],'sha256Before':before[str(library)]},
      'sourcesBefore':before,'sourcesAfter':after,'sourceDrift':drift,
      'generatedSha256':generated_identity,
      'boundary':'existing complete SDL static SDK + production Source/Core/backend/bridge/JNI bodies and actual SDK key/button mapping; window discovery, text, capture and menu cursor retain explicit fixture edges; source/library stability is separate from build provenance; no OHOS/game/device claim'},indent=2)+'\n',encoding='utf-8')
    if args.negative:assert result.returncode!=0 and b'CHECK failed' in result.stderr,'negative must hit actual consumer behavior'
    else:result.check_returncode()
    if drift:raise RuntimeError('source drift while compiling consumer')
if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--sdk-host-tree',required=True)
    parser.add_argument('--out',required=True);parser.add_argument('--build-out',required=True);parser.add_argument('--cmake')
    parser.add_argument('--reuse-build',action='store_true',help='复用该任务已登记host缓存，证据另写新目录')
    parser.add_argument('--negative',choices=['compat-bypass','budget2','simplified-mapping']);main(parser.parse_args())
