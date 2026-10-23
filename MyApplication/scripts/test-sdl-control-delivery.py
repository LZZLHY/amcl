"""应用锁定SDL完整series，编译完整SDK并执行真实pump/缓存/队列及neutral生产Core。

--source-repo必须含deps.lock固定commit，只读git archive取源；不运行库仓setup、不取设备。
输出树只能为新外置目录。公共SDL_Send* ABI不替身，平台来源运输/窗口资格才由fixture提供。
每个negative必须成功编译后命中CHECK，不能用编译失败或Ready宣称验证。
"""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import threading
from datetime import datetime
from lib.host_cpp import configure_host_cmake, find_host_cmake
from lib.workspace_paths import external_output_path

ROOT=Path(__file__).resolve().parents[1]
COMMAND_RECEIPTS=[]
# 后续 owned 文本门实际借用静态SDK与这些消费/队列/私有合同正文。
# 清单固定于测试契约，不能由旧summary自行删减成更小的“已验证范围”。
SDK_CONSUMPTION_PATHS=(
 'source/src/SDL.c','source/src/dynapi/SDL_dynapi.c','source/src/dynapi/SDL_dynapi.h',
 'source/src/events/SDL_keyboard.c','source/src/events/SDL_mouse.c','source/src/events/SDL_events.c',
 'source/src/events/SDL_eventwatch.c','source/src/events/SDL_inputdelivery_c.h',
 'source/src/SDL_amclinputcontrol_c.h','source/src/core/openharmony/SDL_amclhostruntime.h',
 'source/src/video/openharmony/SDL_openharmonyamcl.c',
 'source/src/video/openharmony/control_delivery.h','source/src/video/openharmony/control_delivery_client.h',
 # 后续owned文本门复用本SDK时也必须绑定此次真实可选client的两共同声明。
 'source/src/video/openharmony/input/input_latency_observation.h','source/src/video/openharmony/input/input_latency_client.h',
)
SDK_CMAKE_EXPORT_PATHS=tuple('build/sdk/'+name for name in
 ('SDL3Config.cmake','SDL3headersTargets.cmake','SDL3staticTargets.cmake','SDL3sharedTargets.cmake'))

def sdk_identity(path,root):
    """实取当前完整SDK生产末态的raw字节；不从文件名/旧摘要推断制品身份。"""
    path=Path(path);data=path.read_bytes()
    return {'path':path.relative_to(root).as_posix(),'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}
spec=importlib.util.spec_from_file_location('sdl_recipe',ROOT/'scripts/generate-desktop-review-tests.py')
recipe=importlib.util.module_from_spec(spec);spec.loader.exec_module(recipe)
TRACE=[(1,1,1,1),(2,1,1,1),(1,1,1,1),(2,2,1,2),(1,0,1,2),(1,2,1,2),(2,0,0,3),(2,0,0,3),(2,2,0,3),
 (1,1,1,4),(2,1,1,4),(2,-1,1,4),(2,0,1,4),(1,0,0,5),(2,1,1,6),(1,1,1,6),(1,-1,1,6),(2,0,0,7),
 (1,1,1,8),(1,-1,0,9),(2,4,0,9)]
MOUSE_TRACE=[(1,1,1,1),(2,1,1,1),(1,1,1,1),(1,0,1,1),(2,0,0,2),(2,1,1,3),(1,1,1,3),(2,-1,1,3),(1,0,0,4),(1,0,0,4)]

def run(args,cwd,log,negative=False):
    """保持前台输出与完整日志；负控要求明确行为断言失败，保存真实退出码。"""
    print('[sdl-production] '+' '.join(map(str,args)),flush=True)
    receipt={'command':list(map(str,args)),'cwd':str(cwd),'log':str(log),'negativeExpected':negative,
      'startedAt':datetime.now().astimezone().isoformat()}
    COMMAND_RECEIPTS.append(receipt)
    with log.open('wb') as stream:
        process=subprocess.Popen(list(map(str,args)),cwd=cwd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        timer=threading.Timer(180,process.kill);timer.start()
        try:
            for line in iter(process.stdout.readline,b''):
                stream.write(line);stream.flush();print(line.decode('utf-8',errors='replace').rstrip(),flush=True)
            code=process.wait()
        finally:timer.cancel()
    receipt.update(exitCode=code,finishedAt=datetime.now().astimezone().isoformat())
    if negative:
        if code==0 or b'CHECK failed' not in log.read_bytes():raise RuntimeError('negative not rejected by behavior: '+str(log))
    elif code!=0:raise RuntimeError('failed: '+str(log))
    return code

def production(source,name):
    """从完整已应用源提取函数单正文；同样与series重建逐字核对，不拼凑未知上游上下文。"""
    match=re.search(r'^(?:JNIEXPORT )?(?:static )?(?:bool|void|int|SDL_MouseID)\s+'+re.escape(name)+r'\([^;{}]*\)\s*\{',source,re.M)
    if not match:raise ValueError('Missing production function: '+name)
    return recipe.block(source,match.start())

def render_fixture(sdl):
    """一次装配全部真实函数与固定来源材料；施工增量/完整验收使用同一生成入口。"""
    names=['OPENHARMONY_MouseIDFromHost','OPENHARMONY_ValidPointerIdentity','OPENHARMONY_ValidateTypedEvent',
        'OPENHARMONY_CloseControl','OPENHARMONY_ControlCurrent','OPENHARMONY_ControlCacheApplied','OPENHARMONY_DeliverControl','OPENHARMONY_RetireControls',
        'OPENHARMONY_ControlReady','OPENHARMONY_SendKeyFromPlane','OPENHARMONY_SendButtonFromPlane',
        'SDL_AMCL_ObserveKeyboardPoll','SDL_AMCL_ObserveMousePoll','OPENHARMONY_LookCurrent','OPENHARMONY_LookCacheApplied',
        'OPENHARMONY_DeliverLookForMouse','OPENHARMONY_DeliverLook','SDL_AMCL_ObserveLookPoll','OPENHARMONY_DisableRelativeModeForHostLoss',
        'OPENHARMONY_ApplyTypedFocus','OPENHARMONY_PumpHostEvents','OPENHARMONY_PumpTypedEvents',
        'OPENHARMONY_PumpHostCursor','OPENHARMONY_PumpOrderedEvents']
    body='\n\n'.join(production(sdl,name) for name in names)
    constants='\n'.join(line for line in sdl.splitlines() if re.match(r'^#define AMCL_\w+\s+',line) and not line.endswith('\\'))
    event=re.search(r'typedef struct\s*\{[^}]*\}\s*AMCL_BackendInputEvent;',sdl).group(0)
    context='\n'.join(re.search(r'typedef struct '+name+r'\s*\{[^}]*\}\s*'+name+';',sdl).group(0)
        for name in ['OPENHARMONY_ControlContext','OPENHARMONY_LookContext'])
    fixture=(ROOT/'scripts/fixtures/input-consumer/sdl_control_production.c.in').read_text(encoding='utf-8')
    # patch27已给原look context/ready/cache/return正文增加可选latency依赖。
    # 从真实共同client头取得类型和resolver；这里只借端口，不能写一份空实现凑编译。
    include='#include "input/delivery/look_execution_client.h"'
    if fixture.count(include)!=1:raise ValueError('Control fixture look include missing/ambiguous')
    fixture=fixture.replace(include,include+'\n#include "input/input_latency_client.h"')
    declarations=[]
    for declaration in ['static const AmclInputLatencyPortV2 *host_latency_port;', 'static bool host_latency_attempted;']:
        # 冷借一次的两个状态逐字来自完整重建源；生产函数自己决定诊断缺席和pid验证。
        if sdl.count(declaration)!=1:raise ValueError('Product latency declaration missing/ambiguous')
        declarations.append(declaration)
    fixture=fixture.replace('@CONTEXT@','\n'.join(declarations)+'\n@CONTEXT@')
    fixture=fixture.replace('@CONSTANTS@',constants).replace('@EVENT@',event).replace('@CONTEXT@',context)
    # P5 已退出 grabbed 全局累计；公共 source 加工/不可变 prefix 的纵向正反例由
    # test-sdl-look-prefix.py 独立穿过真实 SDK。此控制夹具只提供菜单绝对位置边缘。
    fixture=fixture.replace('@BRIDGE@','')
    for token,rows in [('@TRACE@',TRACE),('@MOUSE_TRACE@',MOUSE_TRACE)]:
        fixture=fixture.replace(token,','.join('{'+','.join(map(str,row))+'}' for row in rows))
    return fixture,body

def build(options):
    started=datetime.now().astimezone().isoformat();COMMAND_RECEIPTS.clear()
    output=external_output_path(options.out)
    if output.exists():raise ValueError('output must be a new external directory: '+str(output))
    output.mkdir(parents=True);temp=output/'temp';temp.mkdir();os.environ['TEMP']=str(temp);os.environ['TMP']=str(temp)
    tracked=[Path(__file__).resolve(),ROOT/'scripts/test-sdl-cold-protocol.py',ROOT/'scripts/fixtures/input-consumer/sdl_control_production.c.in',
        *(ROOT/'entry/src/main/cpp/input'/name for name in
        ['delivery/control_delivery.cpp','delivery/control_delivery.h','delivery/control_delivery_client.h',
         'delivery/look_execution.cpp','delivery/look_execution.h','delivery/look_execution_client.h',
         'input_latency_observation.h','input_latency_client.h','amcl_input_event.h','input_state_core.cpp','adapters/backend_keymaps.cpp','amcl_input_host_descriptor.cpp','input_interaction_order.cpp']),
        *(ROOT/'entry/src/main/cpp/platform'/name for name in ['input_source.h','look_delta_math.cpp','look_delta_math.h','look_pipeline_stats.cpp','look_pipeline_stats.h'])]
    frozen={p:hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    lock=(ROOT/'deps.lock').read_text(encoding='utf-8')
    section=re.search(r'^\[sdl3-native\]\s*\n([\s\S]*?)(?=^\[|\Z)',lock,re.M).group(1)
    commit=re.search(r'^commit\s*=\s*([a-f0-9]{40})',section,re.M).group(1)
    source=output/'source';source.mkdir()
    # git archive也会按autocrlf转换正文；必须在取源这一命令钉为LF，
    # 不能仅给后续apply设置false。此处不改仓库/全局配置，也不放宽补丁校验。
    archive=subprocess.check_output(['git','-c','core.autocrlf=false','-C',str(options.source_repo),'archive',commit])
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        for member in tar:
            target=(source/member.name).resolve()
            if not target.is_relative_to(source.resolve()) or member.issym() or member.islnk():raise ValueError('bad archive member')
            tar.extract(member,source,filter='data')
    patches=ROOT/'prebuilt/sdl3/patches';applied=[]
    for line in (patches/'series').read_text(encoding='utf-8').splitlines():
        if not line.strip() or line.startswith('#'):continue
        # 使用canonical源码字节，不继承维护者全局autocrlf；与Linux受控重建采用同一patch正文。
        patch=patches/line.strip();run(['git','-c','core.autocrlf=false','apply','--check',patch],source,output/(line.strip()+'.check.log'))
        run(['git','-c','core.autocrlf=false','apply',patch],source,output/(line.strip()+'.apply.log'));applied.append(patch)
        frozen[patch]=hashlib.sha256(patch.read_bytes()).hexdigest()
    reconstructed=recipe.patch_sources()
    sdl=(source/'src/video/openharmony/SDL_openharmonyamcl.c').read_text(encoding='utf-8')
    if sdl!=reconstructed['SDL_openharmonyamcl.c']:raise ValueError('Full git series differs from production sparse recipe')
    if options.no_dynapi:
        # 宿主编译整个SDK的OHOS实际分支；只在外置树选master switch，不向编译命令定义宏绕SDK拒绝。
        master=source/'src/dynapi/SDL_dynapi.h';actual=master.read_bytes()
        needle=b'#if defined(SDL_PLATFORM_PRIVATE)'
        if actual.count(needle)!=1:raise ValueError('SDK master switch mismatch')
        master.write_bytes(actual.replace(needle,b'#if 1 /* Host compile of the same SDL_DYNAMIC_API=0 branch used by OHOS. */',1))
    cpp=ROOT/'entry/src/main/cpp'
    # 独占构建输入快照：其他agent可继续真实owner修复，本次编译不并行读正在变化的原文件。
    owner=output/'owner';shutil.copytree(cpp/'input',owner/'input')
    shutil.copytree(cpp/'tests/host/stubs',owner/'stubs')
    (owner/'platform').mkdir()
    for name in ['input_source.h','look_delta_math.h','look_delta_math.cpp','look_pipeline_stats.h','look_pipeline_stats.cpp']:
        shutil.copyfile(cpp/'platform'/name,owner/'platform'/name)
    # Core 的真实 L2 held reader 依赖生产 mapper；补完整强链接，不以 weak/noop 或假映射替代。
    sources=[owner/'input'/p for p in ['delivery/control_delivery.cpp','delivery/look_execution.cpp','input_state_core.cpp','adapters/backend_keymaps.cpp','amcl_input_host_descriptor.cpp','input_interaction_order.cpp']]
    sources += [owner/'platform'/name for name in ['look_delta_math.cpp','look_pipeline_stats.cpp']]
    for name in ['control_delivery.h','control_delivery_client.h']:
        if (source/'src/video/openharmony'/name).read_bytes()!=(owner/'input/delivery'/name).read_bytes():
            raise ValueError('SDL mirror differs byte-for-byte from neutral contract: '+name)
    fixture,body=render_fixture(sdl)
    path=output/'consumer.c';path.write_text(fixture.replace('@PRODUCTION@',body),encoding='utf-8')
    cmake=find_host_cmake(options.cmake)
    text='''cmake_minimum_required(VERSION 3.20)
project(sdl_control_production C CXX)
set(CMAKE_CXX_STANDARD 17)
if(NOT CMAKE_CONFIGURATION_TYPES)
 set(CMAKE_BUILD_TYPE Release CACHE STRING "native host configuration" FORCE)
endif()
set(SDL_SHARED ON CACHE BOOL "" FORCE)
set(SDL_STATIC ON CACHE BOOL "" FORCE)
set(SDL_TEST_LIBRARY OFF CACHE BOOL "" FORCE)
set(SDL_TESTS OFF CACHE BOOL "" FORCE)
set(SDL_EXAMPLES OFF CACHE BOOL "" FORCE)
set(SDL_AUDIO OFF CACHE BOOL "" FORCE)
set(SDL_RENDER OFF CACHE BOOL "" FORCE)
set(SDL_GPU OFF CACHE BOOL "" FORCE)
set(SDL_CAMERA OFF CACHE BOOL "" FORCE)
set(SDL_HIDAPI OFF CACHE BOOL "" FORCE)
set(SDL_SENSOR OFF CACHE BOOL "" FORCE)
# 此宿主门只创建真实dummy隐藏窗口，未验X11/Wayland桌面呈现；按锁定SDK README-cmake
# 的console构建契约允许headless QA，仍完整编译SDK并执行真实cache/queue/Poll，绝不skip。
if(UNIX AND NOT APPLE)
 set(SDL_UNIX_CONSOLE_BUILD ON CACHE BOOL "headless SDK host verification" FORCE)
endif()
add_subdirectory(source sdk)
set_source_files_properties("${CMAKE_CURRENT_SOURCE_DIR}/source/src/events/SDL_keyboard.c" "${CMAKE_CURRENT_SOURCE_DIR}/source/src/events/SDL_mouse.c"
 DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/source" PROPERTIES COMPILE_DEFINITIONS SDL_VIDEO_DRIVER_OPENHARMONY)
set_source_files_properties("${CMAKE_CURRENT_SOURCE_DIR}/source/src/SDL.c" "${CMAKE_CURRENT_SOURCE_DIR}/source/src/dynapi/SDL_dynapi.c"
 DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/source" PROPERTIES COMPILE_DEFINITIONS "SDL_VIDEO_DRIVER_OPENHARMONY;AMCL_CONTROL_DELIVERY_HOST_TESTING;_GNU_SOURCE=")
target_sources(SDL3-shared PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/cold_observer.c")
target_include_directories(SDL3-shared PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/source/src")
add_executable(sdl_control consumer.c '''+' '.join('"'+p.as_posix()+'"' for p in sources)+''')
add_library(amcl_owner_shared SHARED '''+' '.join('"'+p.as_posix()+'"' for p in sources)+''')
target_compile_definitions(amcl_owner_shared PRIVATE AMCL_CONTROL_DELIVERY_HOST_TESTING AMCL_INPUT_HOST_TESTING _CRT_SECURE_NO_WARNINGS)
target_include_directories(amcl_owner_shared PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/owner/input/delivery" "${CMAKE_CURRENT_SOURCE_DIR}/owner/stubs")
target_link_libraries(sdl_control PRIVATE SDL3::SDL3-static)
set_property(TARGET sdl_control PROPERTY C_STANDARD 11)
target_compile_definitions(sdl_control PRIVATE SDL_VIDEO_DRIVER_OPENHARMONY AMCL_CONTROL_DELIVERY_HOST_TESTING AMCL_INPUT_HOST_TESTING _CRT_SECURE_NO_WARNINGS)
target_include_directories(sdl_control PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/source/src" "${CMAKE_CURRENT_BINARY_DIR}/sdk/include-config-release/build_config" "${CMAKE_CURRENT_BINARY_DIR}/sdk/include-revision" "${CMAKE_CURRENT_SOURCE_DIR}/source/src/video/openharmony" "${CMAKE_CURRENT_SOURCE_DIR}/owner/input/delivery" "${CMAKE_CURRENT_SOURCE_DIR}/owner/stubs")
'''
    if os.name=='nt':text+='target_compile_options(sdl_control PRIVATE /utf-8)\ntarget_compile_options(amcl_owner_shared PRIVATE /utf-8)\nset_source_files_properties(consumer.c PROPERTIES COMPILE_OPTIONS "/experimental:c11atomics")\n'
    else:text+='target_compile_definitions(sdl_control PRIVATE _GNU_SOURCE)\ntarget_link_libraries(sdl_control PRIVATE ${CMAKE_DL_LIBS} pthread)\ntarget_link_options(sdl_control PRIVATE -rdynamic)\ntarget_link_libraries(amcl_owner_shared PRIVATE ${CMAKE_DL_LIBS} pthread)\n'
    # shared SDK只作cold/Init契约探针，不声明已建立输入来源。完整消费仍由下方static真实闭包执行。
    # Windows宿主不编译OHOS平台文件，这两个无订阅observer边界从不接收/模拟控制输入。
    (output/'cold_observer.c').write_text('''/* 宿主cold SDK的无订阅观测边缘；不管理贡献、不返回消费成功，实际SDK标准API保持。 */
#include "SDL_internal.h"
void SDL_AMCL_ObserveKeyboardPoll(const bool*states,int count){(void)states;(void)count;}
void SDL_AMCL_ObserveMousePoll(SDL_MouseButtonFlags state){(void)state;}
void SDL_AMCL_ObserveLookPoll(double x,double y){(void)x;(void)y;}
''',encoding='utf-8')
    (output/'CMakeLists.txt').write_text(text,encoding='utf-8');configure_host_cmake(cmake,output,output/'build')
    run([cmake,'--build',output/'build','--config','Release','--parallel','8'],output,output/'production-compile.log')
    binary=output/('build/Release/sdl_control.exe' if os.name=='nt' else 'build/sdl_control')
    shared=output/('build/sdk/Release/SDL3.dll' if os.name=='nt' else 'build/sdk/libSDL3.so')
    owner_shared=output/('build/Release/amcl_owner_shared.dll' if os.name=='nt' else 'build/libamcl_owner_shared.so')
    run([sys.executable,ROOT/'scripts/test-sdl-cold-protocol.py','--library',shared],output,output/'cold-shared-sdk.log')
    for mode in ([] if options.no_dynapi else ['standalone','host','late']):
        run([sys.executable,ROOT/'scripts/test-sdl-cold-protocol.py','--library',shared,'--dynapi',mode,'--owner-library',owner_shared],output,output/('dynapi-'+mode+'.log'))
    facts=[{'mode':'production','exit':run([binary],output,output/'production.log')}]
    if not options.production_only:
        # SDK的冷标识/实际Init/实际两映像路由同样必须由可编译负控击中，不能仅grep接线。
        sdk_core=source/'src/SDL.c';sdk_dynapi=source/'src/dynapi/SDL_dynapi.c'
        core_bytes=sdk_core.read_bytes();dynapi_bytes=sdk_dynapi.read_bytes()
        protocol_mutations=[
            ('sdk-marker-wrong-version',sdk_core,b'return SDL_AMCL_INPUT_CONTROL_PROTOCOL_V1;',b'return 2u;','cold'),
            ('sdk-init-skips-owner',sdk_core,b'if (input_host>0 && !SDL_AMCL_ValidateInputRuntimeV1(true)) return false;',b'/* wrong: skip actual owner gate */','cold'),
            ('sdk-dynapi-borrows-host-copy',sdk_dynapi,b'if (AMCL_SdlInputHostIdentityV1()>0) libname=NULL;',b'/* wrong: borrow override in host */','host'),
            ('sdk-late-init-follows-copy',sdk_dynapi,b'SDL_AMCL_INPUT_INIT_DISPATCH(fn,args,ret)   ',b'/* wrong: skip late host source gate */   ','late')]
        for mode,target,before,after,test_mode in protocol_mutations:
            # OHOS的master switch=0没有外部jump table；只测试实际活跃分支，不能靠unused变异报负控成功。
            if options.no_dynapi and test_mode in ['host','late']:continue
            original=core_bytes if target==sdk_core else dynapi_bytes
            if original.count(before)!=1:raise ValueError('SDK protocol mutation missing: '+mode)
            target.write_bytes(original.replace(before,after,1))
            run([cmake,'--build',output/'build','--config','Release','--parallel','8'],output,output/(mode+'-compile.log'))
            args=[sys.executable,ROOT/'scripts/test-sdl-cold-protocol.py','--library',shared]
            if test_mode!='cold':args+=['--dynapi',test_mode,'--owner-library',owner_shared,'--copy-label',mode]
            facts.append({'mode':mode,'exit':run(args,output,output/(mode+'.log'),negative=True)})
            target.write_bytes(original)
        run([cmake,'--build',output/'build','--config','Release','--parallel','8'],output,output/'sdk-protocol-restored-compile.log')
        run([sys.executable,ROOT/'scripts/test-sdl-cold-protocol.py','--library',shared],output,output/'sdk-protocol-restored-cold.log')
        mutations=[
            ('call-as-queue','receipt.posted ? AMCL_CONTROL_PULL_COMMITTED','true ? AMCL_CONTROL_PULL_COMMITTED'),
            ('poll-without-real-read','void SDL_AMCL_ObserveKeyboardPoll(const bool *states, int count)\n{','void SDL_AMCL_ObserveKeyboardPoll(const bool *states, int count)\n{\n    return;'),
            ('skip-sdk-reentry-guard','context->port->validate(&context->emission) != AMCL_CONTROL_EDGE','false'),
            ('reset-clears-sibling','host_control_port->retire(host_control_consumer, classes, device, only_device ? 1 : 0)',
                'host_control_port->retire(host_control_consumer, AMCL_CONTROL_MASK_ALL, device, only_device ? 1 : 0)'),
            ('lost-target-keeps-cache','const bool cache_only = emission->action == AMCL_CONTROL_UP',
                'const bool cache_only = false && emission->action == AMCL_CONTROL_UP'),
            ('bypass-neutral-key','static void OPENHARMONY_SendKeyFromPlane(Uint8 plane, Uint64 time, int raw, SDL_Scancode key, int action)\n{',
                'static void OPENHARMONY_SendKeyFromPlane(Uint8 plane, Uint64 time, int raw, SDL_Scancode key, int action)\n{\n    (void)SDL_SendKeyboardKey(time,SDL_DEFAULT_KEYBOARD_ID,raw,key,action!=0); return;'),
            ('typed-crosses-legacy-order','? bridge->TypedNextThrough(AMCL_BACKEND_ID_SDL3, &event, bridge->pump_order_limit)',
                '? bridge->TypedNextThrough(AMCL_BACKEND_ID_SDL3, &event, UINT64_MAX)'),
            ('source-pull-reentry','host_control_dispatch_depth || ',''),
        ]
        for mode,before,after in mutations:
            wrong=body.replace(before,after,-1 if mode=='source-pull-reentry' else 1)
            if wrong==body:raise ValueError('mutation does not match: '+mode)
            path.write_text(fixture.replace('@PRODUCTION@',wrong),encoding='utf-8')
            run([cmake,'--build',output/'build','--config','Release','--parallel','8'],output,output/(mode+'-compile.log'))
            facts.append({'mode':mode,'exit':run([binary],output,output/(mode+'.log'),negative=True)})
        # 旧“global cursor 重新包含 physical”运输已退出；不能以不再活动的源码负控假报覆盖。
        # 新 look 的 immutable prefix/raw 不混用、缓存与实际 ADD 负控由其独立全 SDK 入口执行。
        path.write_text(fixture.replace('@PRODUCTION@',body),encoding='utf-8')
        # SDK单正文负控：保留薄facade原样，仅移除SDK缓存之前的ticket再核证明测试穿过真实SDK。
        receipt=source/'src/events/SDL_inputdelivery_c.h';actual=receipt.read_bytes()
        before=b'return !receipt || (receipt->target && receipt->current && receipt->cacheApplied && receipt->current(receipt->context));'
        if actual.count(before)!=1:raise ValueError('SDK current hook not found')
        receipt.write_bytes(actual.replace(before,b'return true;',1))
        run([cmake,'--build',output/'build','--config','Release','--parallel','8'],output,output/'sdk-skips-reentry-guard-compile.log')
        facts.append({'mode':'sdk-skips-reentry-guard','exit':run([binary],output,output/'sdk-skips-reentry-guard.log',negative=True)})
        receipt.write_bytes(actual)
        run([cmake,'--build',output/'build','--config','Release','--parallel','8'],output,output/'restored-compile.log')
        facts.append({'mode':'restored-production','exit':run([binary],output,output/'restored-production.log')})
    source_hashes={p.relative_to(owner).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    # 只有实际恢复production并执行成功以后才授予restored事实；production-only不能借它。
    # 同时绑定真实最终静态库和SDK消费正文，后续入口回读验证而不是补写旧实验summary。
    static_sdk=output/('build/sdk/Release/SDL3-static.lib' if os.name=='nt' else 'build/sdk/libSDL3.a')
    sdk_final={'schema':'sdl-host-sdk-consumption/v1','recordedAt':datetime.now().astimezone().isoformat(),
      'restoredProduction':any(row['mode']=='restored-production' and row['exit']==0 for row in facts),
      'staticLibrary':sdk_identity(static_sdk,output),
      'consumptionSources':{name:sdk_identity(output/name,output) for name in SDK_CONSUMPTION_PATHS},
      # 后续portable consumer采用这些真实导出target的系统链接依赖，故也绑定生成正文。
      'cmakeExports':{name:sdk_identity(output/name,output) for name in SDK_CMAKE_EXPORT_PATHS},
      'generatedConsumer':sdk_identity(path,output),'series': [p.name for p in applied],
      'seriesRaw':sdk_identity(patches/'series',ROOT)}
    (output/'summary.json').write_text(json.dumps({'schema':2,'pin':commit,'modes':facts,'ownerSources':source_hashes,
        'startedAt':started,'completedAt':datetime.now().astimezone().isoformat(),'commands':COMMAND_RECEIPTS,
        'sdkFinal':sdk_final,
        'sdkDynamicApi':0 if options.no_dynapi else 1,
        'consumerSha256':hashlib.sha256(path.read_bytes()).hexdigest(),
        'frozenInputs':{p.relative_to(ROOT).as_posix():digest for p,digest in frozen.items()},
        'patches':{p.name:frozen[p] for p in applied}},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    changed=[str(p.relative_to(ROOT)) for p,digest in frozen.items() if hashlib.sha256(p.read_bytes()).hexdigest()!=digest]
    if changed:raise RuntimeError('production inputs changed during this snapshot test: '+', '.join(changed))

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-repo',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--cmake')
    parser.add_argument('--production-only',action='store_true',help='施工调试阶段仅生产闭包；交付必须执行默认负控')
    parser.add_argument('--no-dynapi',action='store_true',help='完整SDK选择OHOS使用的SDL_DYNAMIC_API=0分支；保持所有实际消费正例')
    build(parser.parse_args())
