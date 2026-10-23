"""完整锁定 SDL SDK 的不可变 look-prefix 正反例；中立执行体使用本轮生产源码快照。

只读 git archive，输出必须为全新外置目录。SDL 标准 API 与 cache/ADD/Poll 均来自 SDK，
只抽取 OHOS pump/窗口边缘供宿主运行。负控必须编译通过并命中行为 CHECK 才算有效。
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
from datetime import datetime
# 宿主脚本的 bytecode 是中间材料；不让导入在正式项目 scripts 目录落回缓存。
sys.dont_write_bytecode=True
from lib.host_cpp import configure_host_cmake,find_host_cmake
from lib.workspace_paths import external_output_path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('control_test',ROOT/'scripts/test-sdl-control-delivery.py')
control=importlib.util.module_from_spec(spec);spec.loader.exec_module(control)
def fixture(sdl):
    """只使用完整已应用源的实际正文；前序控制合同不变，增加 look 边缘而非复制状态机。"""
    prelude=(ROOT/'scripts/fixtures/input-consumer/sdl_control_production.c.in').read_text(encoding='utf-8').split('@PRODUCTION@')[0]
    prelude=prelude.replace('#include "control_delivery_client.h"','#include "control_delivery_client.h"\n#include "input/delivery/look_execution_client.h"\n#include "input/input_latency_client.h"\n#include "amcl_input_api.h"\n#include "amcl_input_host_descriptor.h"')
    prelude=prelude.replace('#include "amcl_input_host_descriptor.h"','#include "amcl_input_host_descriptor.h"\n#include "adapters/backend_input_bridge.h"\nstatic bool actualBackendInput;')
    prelude=prelude.replace('#include "adapters/backend_input_bridge.h"','#include "adapters/backend_input_bridge.h"\n#include "input_interaction_order.h"')
    prelude=prelude.replace('static AMCL_BackendInputEvent typed[4096];static int typedBegin,typedEnd;',
        'static AMCL_BackendInputEvent typed[4096],lastActualRelative;static int typedBegin,typedEnd,actualRelativeCount;')
    # 物理正反例使用真正 backend adapter/ordered envelope；虚拟材料仍由原五整数边缘提供。
    prelude=prelude.replace('static Uint64 frameFence(void) { return frameLimit; }',
        'static Uint64 frameFence(void) { return actualBackendInput ? amclInputGetHostApiV1()->interactionFence() : frameLimit; }')
    needle='static int nextTypedThrough(Uint32 backend,AMCL_BackendInputEvent*out,Uint64 limit) {\n'
    if prelude.count(needle)!=1:raise ValueError('Typed fixture boundary changed')
    prelude=prelude.replace(needle,needle+''' /* 此分支直接穿过生产 adapter，保留其 sequence=interactionOrder 的真实 ordered 合同。 */
 if(actualBackendInput){AmclBackendInputEvent native;int result=amclBackendInputNextThrough(backend,&native,limit);
  if(result==AMCL_BACKEND_INPUT_EVENT){CHECK(sizeof(native)==sizeof(*out));SDL_memcpy(out,&native,sizeof(native));
   if(out->eventType==AMCL_BACKEND_EVENT_RELATIVE){lastActualRelative=*out;++actualRelativeCount;}}return result;}
''',1)
    if 'static const AmclLookExecutionPortV1 *host_look_port;' not in prelude:
        prelude=prelude.replace('static const AmclControlDeliveryPortV1 *host_control_port;','static const AmclControlDeliveryPortV1 *host_control_port;\nstatic const AmclLookExecutionPortV1 *host_look_port;')
    # 这两项只借端口/冷解析事实，取真实产品声明；不复制或替代collector状态。
    for declaration in ['static const AmclInputLatencyPortV2 *host_latency_port;', 'static bool host_latency_attempted;']:
        if sdl.count(declaration)!=1:raise ValueError('Product latency declaration missing/ambiguous')
        prelude+='\n'+declaration+'\n'
    constants='\n'.join(line for line in sdl.splitlines() if re.match(r'^#define AMCL_\w+\s+',line) and not line.endswith('\\'))
    event=re.search(r'typedef struct\s*\{[^}]*\}\s*AMCL_BackendInputEvent;',sdl).group(0)
    context='\n'.join(re.search(r'typedef struct '+name+r'\s*\{[^}]*\}\s*'+name+';',sdl).group(0)
        for name in ['OPENHARMONY_ControlContext','OPENHARMONY_LookContext'])
    names=['OPENHARMONY_MouseIDFromHost','OPENHARMONY_ValidPointerIdentity','OPENHARMONY_ValidateTypedEvent',
        'OPENHARMONY_CloseControl','OPENHARMONY_ControlCurrent','OPENHARMONY_ControlCacheApplied','OPENHARMONY_DeliverControl','OPENHARMONY_RetireControls',
        'OPENHARMONY_ControlReady','OPENHARMONY_SendKeyFromPlane','OPENHARMONY_SendButtonFromPlane',
        'SDL_AMCL_ObserveKeyboardPoll','SDL_AMCL_ObserveMousePoll','OPENHARMONY_LookCurrent','OPENHARMONY_LookCacheApplied',
        'OPENHARMONY_DeliverLookForMouse','OPENHARMONY_DeliverLook','SDL_AMCL_ObserveLookPoll','OPENHARMONY_DisableRelativeModeForHostLoss','OPENHARMONY_ApplyTypedFocus',
        'OPENHARMONY_PumpHostEvents','OPENHARMONY_PumpTypedEvents','OPENHARMONY_PumpHostCursor','OPENHARMONY_PumpOrderedEvents']
    body='\n\n'.join(control.production(sdl,name) for name in names)
    prelude=prelude.replace('@CONSTANTS@',constants).replace('@EVENT@',event).replace('@CONTEXT@',context)
    prelude+='\n'+body+'''
static OPENHARMONY_HostBridge bridge={nextLegacy,getCursor,isGrabbing,frameFence,nextTypedThrough,peekLegacyOrder,nextLegacyThrough,UINT64_MAX,0,false};
/* 夹具只存原材料及原序号，所有执行/资格来自上面的逐字生产正文。 */
static void pushLegacy(Uint64 order,int type,int a,int b,int c,int d) {
 CHECK(legacyEnd<4096);int*e=legacy[legacyEnd];e[0]=type;e[1]=a;e[2]=b;e[3]=c;e[4]=d;legacyOrders[legacyEnd++]=order;
}
'''
    return (ROOT/'scripts/fixtures/input-consumer/sdl_look_production.c.in').read_text(encoding='utf-8').replace('@PRELUDE@',prelude)
def verify(output,cmake,production_only=False,latency_negative=None):
    """可复用已封存构建执行行为矩阵；负控分别移除生产 SDK 和边缘的承重检查。"""
    source=output/'source';consumer=output/'consumer.c';owner=output/'owner';binary=output/('build/Release/sdl_look.exe' if os.name=='nt' else 'build/sdl_look')
    result=control.run([binary],output,output/'production.log',negative=bool(latency_negative))
    results=[{'mode':'latency-'+latency_negative if latency_negative else 'production','exit':result}]
    if latency_negative:
        if b'SDL_LATENCY_CHECK ' not in (output/'production.log').read_bytes():
            raise RuntimeError('Latency withdrawal failed outside intended consumer assertion')
        return results
    if not production_only:
        mutations=[
            ('no-prefix',consumer,'OPENHARMONY_DeliverLook(token);','/* 负控：故意丢弃实际 prefix 交付。 */'),
            ('future-grabbed-snapshot',consumer,'if (grabbing) return;','if (false) return;'),
            ('fake-add',consumer,'complete(&emission, receipt.posted ? AMCL_CONTROL_PULL_COMMITTED','complete(&emission, true ? AMCL_CONTROL_PULL_COMMITTED'),
            ('no-motion-reentry',consumer,'context->port->validate(&context->emission) != AMCL_LOOK_PREFIX_READY','false'),
            ('poll-without-read',source/'src/events/SDL_mouse.c','if (x || y) SDL_AMCL_ObserveLookPoll(mouse->x, mouse->y);','SDL_AMCL_ObserveLookPoll(mouse->x, mouse->y);'),
            ('sdk-skips-motion-guard',source/'src/events/SDL_inputdelivery_c.h','return !receipt || (receipt->target && receipt->current && receipt->cacheApplied && receipt->current(receipt->context));','return true;'),
            ('sdk-look-marker-wrong',source/'src/SDL.c','return SDL_AMCL_INPUT_LOOK_PROTOCOL_V1;','return 2u;'),
            ('owner-target-replay',owner/'input/delivery/look_execution.cpp','if(replacing)for(auto& prefix:r.prefixes)prefix.second.receivers&=~(1u<<(facts.backend-1));','/* 负控：故意让旧 prefix 跨入新 target。 */')]
        # 新 physical 回归必须打断真实 ordered/编码/设备/时钟接缝，避免只靠虚拟 prefix 过关。
        mutations += [
            ('physical-core-order-alias',consumer,'physicalPrefixByOrder(event.sequence, &token)','physicalPrefix(event.sequence, &token)'),
            ('physical-raw-direct',consumer,
                'OPENHARMONY_DeliverLookForMouse(token, OPENHARMONY_MouseIDFromHost(event.deviceId), event.monotonicTimeNs);',
                'SDL_SendMouseMotion(event.monotonicTimeNs, input_window, OPENHARMONY_MouseIDFromHost(event.deviceId), true, event.wheelX, event.wheelY);'),
            ('physical-mouse-folded',consumer,
                'OPENHARMONY_DeliverLookForMouse(token, OPENHARMONY_MouseIDFromHost(event.deviceId), event.monotonicTimeNs);',
                'OPENHARMONY_DeliverLookForMouse(token, SDL_DEFAULT_MOUSE_ID, event.monotonicTimeNs);'),
            ('physical-timestamp-discard',consumer,
                'OPENHARMONY_DeliverLookForMouse(token, OPENHARMONY_MouseIDFromHost(event.deviceId), event.monotonicTimeNs);',
                'OPENHARMONY_DeliverLookForMouse(token, OPENHARMONY_MouseIDFromHost(event.deviceId), 0);')]
        for mode,target,before,after in mutations:
            original=target.read_bytes()
            if original.count(before.encode())!=1:raise ValueError('Mutation missing/ambiguous: '+mode)
            target.write_bytes(original.replace(before.encode(),after.encode(),1))
            control.run([cmake,'--build',output/'build','--config','Release','--parallel','8'],output,output/(mode+'-compile.log'))
            results.append({'mode':mode,'exit':control.run([binary],output,output/(mode+'.log'),negative=True)})
            target.write_bytes(original)
        control.run([cmake,'--build',output/'build','--config','Release','--parallel','8'],output,output/'restored-compile.log')
        control.run([binary],output,output/'restored-production.log')
    return results
def build(args):
    """封存生产输入后前台编译完整 SDK；独立路径保存日志和源码摘要，不污染现役制品。"""
    started=datetime.now().astimezone().isoformat();output=external_output_path(args.out)
    if output.exists():raise ValueError('Refuse existing output: '+str(output))
    output.mkdir(parents=True);temp=output/'temp';temp.mkdir();os.environ['TEMP']=str(temp);os.environ['TMP']=str(temp)
    source=output/'source';source.mkdir()
    lock=(ROOT/'deps.lock').read_text(encoding='utf-8');section=re.search(r'^\[sdl3-native\]\s*\n([\s\S]*?)(?=^\[|\Z)',lock,re.M).group(1)
    pin=re.search(r'^commit\s*=\s*([a-f0-9]{40})',section,re.M).group(1)
    # git archive也会按autocrlf转换正文；必须在取源这一命令钉为LF，
    # 不能仅给后续apply设置false。此处不改仓库/全局配置，也不放宽补丁校验。
    archive=subprocess.check_output(['git','-c','core.autocrlf=false','-C',str(args.source_repo),'archive',pin])
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        for member in tar:
            target=(source/member.name).resolve()
            if not target.is_relative_to(source.resolve()) or member.issym() or member.islnk():raise ValueError('bad archive member')
            tar.extract(member,source,filter='data')
    frozen={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__).resolve(),
        ROOT/'scripts/test-sdl-control-delivery.py',ROOT/'scripts/fixtures/input-consumer/sdl_control_production.c.in',
        ROOT/'scripts/fixtures/input-consumer/sdl_look_production.c.in',ROOT/'scripts/test-sdl-look-owner-init.py']};patches=ROOT/'prebuilt/sdl3/patches'
    for line in (patches/'series').read_text(encoding='utf-8').splitlines():
        if not line.strip() or line.startswith('#'):continue
        patch=patches/line.strip();frozen[str(patch)]=hashlib.sha256(patch.read_bytes()).hexdigest()
        control.run(['git','-c','core.autocrlf=false','apply','--check',patch],source,output/(patch.name+'.check.log'))
        control.run(['git','-c','core.autocrlf=false','apply',patch],source,output/(patch.name+'.apply.log'))
    cpp=ROOT/'entry/src/main/cpp';owner=output/'owner';shutil.copytree(cpp/'input',owner/'input');shutil.copytree(cpp/'tests/host/stubs',owner/'stubs')
    (owner/'platform').mkdir()
    for name in ['input_source.h','look_delta_math.h','look_delta_math.cpp','look_pipeline_stats.h','look_pipeline_stats.cpp','physical_wheel_quantizer.h','physical_wheel_quantizer.cpp']:
        shutil.copyfile(cpp/'platform'/name,owner/'platform'/name)
    for path in owner.rglob('*'):
        if path.is_file():
            relative=path.relative_to(owner);original=cpp/'tests/host'/relative if relative.parts[0]=='stubs' else cpp/relative
            frozen[str(original)]=hashlib.sha256(path.read_bytes()).hexdigest()
    for name in ['delivery/look_execution.h','delivery/look_execution_client.h','delivery/control_delivery.h','delivery/control_delivery_client.h','amcl_input_event.h','input_latency_observation.h','input_latency_client.h']:
        actual=(source/'src/video/openharmony/input'/name).read_bytes();expected=(owner/'input'/name).read_bytes()
        # 现有 Core event 源为 CRLF；git patch 规范为 LF，仅规范行尾，不改变任何声明正文。
        if actual!=expected.replace(b'\r\n',b'\n'):raise ValueError('SDL mirror mismatch: '+name)
    master=source/'src/dynapi/SDL_dynapi.h';raw=master.read_bytes();needle=b'#if defined(SDL_PLATFORM_PRIVATE)'
    if raw.count(needle)!=1:raise ValueError('SDK master switch changed')
    master.write_bytes(raw.replace(needle,'#if 1 /* 宿主验证选择 OHOS 实际使用的 SDL_DYNAMIC_API=0 分支。 */'.encode(),1))
    sdl=(source/'src/video/openharmony/SDL_openharmonyamcl.c').read_text(encoding='utf-8');consumer=output/'consumer.c';consumer.write_text(fixture(sdl),encoding='utf-8')
    # 撤回只触及这次实际提取的产品调用，保SDK cache/ADD与原业务complete不变。
    # fake-posted在真实filter拒入队时错误记终点，cache撤回则应缺原ticket-bound观察。
    if args.latency_negative:
        text=consumer.read_text(encoding='utf-8')
        before,after={
            'cache':('context->latency->note(AMCL_ILAT_CACHE, AMCL_BACKEND_ID_SDL3,\n            AMCL_ILAT_ENDPOINT_SDL_QUEUE_ADD, &context->observation);', '(void)context; /* compiled withdrawal: real cache observation removed */'),
            'posted':('if (receipt.posted) {\n                context.latency->note', 'if (true) {\n                context.latency->note')}[args.latency_negative]
        if text.count(before)!=1:raise ValueError('Latency withdrawal anchor changed')
        consumer.write_text(text.replace(before,after,1),encoding='utf-8')
    sources=[owner/'input'/p for p in ['delivery/control_delivery.cpp','delivery/look_execution.cpp','input_state_core.cpp','amcl_input_host_descriptor.cpp','input_interaction_order.cpp']]
    sources.append(owner/'input/input_latency_observation.cpp')
    sources+=[owner/'platform'/name for name in ['look_delta_math.cpp','look_pipeline_stats.cpp','physical_wheel_quantizer.cpp']]
    sources+=[owner/'input/adapters'/name for name in ['backend_input_bridge.cpp','backend_keymaps.cpp','glfw_input_adapter.cpp']]
    # shared SDK 的三个 observer 没有订阅/输入，不模拟 Ready。static SDK 链接上面实际 OHOS getter 边缘。
    (output/'cold_observer.c').write_text('''/* shared 冷标识探针无 consumer，真实 static 输入闭包另行链接。 */
#include "SDL_internal.h"
void SDL_AMCL_ObserveKeyboardPoll(const bool*s,int n){(void)s;(void)n;}
void SDL_AMCL_ObserveMousePoll(SDL_MouseButtonFlags s){(void)s;}
void SDL_AMCL_ObserveLookPoll(double x,double y){(void)x;(void)y;}
''',encoding='utf-8')
    text='''cmake_minimum_required(VERSION 3.20)
project(sdl_look_production C CXX)
set(CMAKE_CXX_STANDARD 17)
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
add_subdirectory(source sdk)
set_source_files_properties("${CMAKE_CURRENT_SOURCE_DIR}/source/src/events/SDL_keyboard.c" "${CMAKE_CURRENT_SOURCE_DIR}/source/src/events/SDL_mouse.c"
 DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/source" PROPERTIES COMPILE_DEFINITIONS SDL_VIDEO_DRIVER_OPENHARMONY)
set_source_files_properties("${CMAKE_CURRENT_SOURCE_DIR}/source/src/SDL.c" "${CMAKE_CURRENT_SOURCE_DIR}/source/src/dynapi/SDL_dynapi.c"
 DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/source" PROPERTIES COMPILE_DEFINITIONS "SDL_VIDEO_DRIVER_OPENHARMONY;AMCL_CONTROL_DELIVERY_HOST_TESTING;_GNU_SOURCE=")
target_sources(SDL3-shared PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/cold_observer.c")
target_include_directories(SDL3-shared PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/source/src")
add_executable(sdl_look consumer.c '''+' '.join('"'+p.as_posix()+'"' for p in sources)+''')
add_library(amcl_look_owner SHARED '''+' '.join('"'+p.as_posix()+'"' for p in sources)+''')
target_compile_definitions(amcl_look_owner PRIVATE AMCL_CONTROL_DELIVERY_HOST_TESTING AMCL_INPUT_HOST_TESTING _CRT_SECURE_NO_WARNINGS)
target_compile_definitions(amcl_look_owner PRIVATE AMCL_GLFW_TYPED_PHYSICAL_DEFAULT=1 AMCL_GLFW_RAW_RELATIVE_VERIFIED=1 AMCL_GLFW_API26_RAW_MOUSE_MOTION=1 "AMCL_GATE0_EVIDENCE_IDS=\\\"host-sdl-look-prefix\\\"")
target_include_directories(amcl_look_owner PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/owner/input" "${CMAKE_CURRENT_SOURCE_DIR}/owner/stubs")
target_link_libraries(sdl_look PRIVATE SDL3::SDL3-static)
set_property(TARGET sdl_look PROPERTY C_STANDARD 11)
target_compile_definitions(sdl_look PRIVATE SDL_VIDEO_DRIVER_OPENHARMONY AMCL_CONTROL_DELIVERY_HOST_TESTING AMCL_INPUT_HOST_TESTING _CRT_SECURE_NO_WARNINGS)
target_compile_definitions(sdl_look PRIVATE AMCL_GLFW_TYPED_PHYSICAL_DEFAULT=1 AMCL_GLFW_RAW_RELATIVE_VERIFIED=1 AMCL_GLFW_API26_RAW_MOUSE_MOTION=1 "AMCL_GATE0_EVIDENCE_IDS=\\\"host-sdl-look-prefix\\\"")
target_include_directories(sdl_look PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/source/src" "${CMAKE_CURRENT_BINARY_DIR}/sdk/include-config-release/build_config" "${CMAKE_CURRENT_BINARY_DIR}/sdk/include-revision" "${CMAKE_CURRENT_SOURCE_DIR}/source/src/video/openharmony" "${CMAKE_CURRENT_SOURCE_DIR}/owner/input" "${CMAKE_CURRENT_SOURCE_DIR}/owner/stubs")
'''
    # 单一真实collector与Core/look同映像；仅测试构建的getter提供原函数，正式bridge另验。
    text+='target_compile_definitions(sdl_look PRIVATE AMCL_INPUT_TRACE='+('0' if args.latency_mode=='off' else '1')+' AMCL_INPUT_LATENCY_SAMPLE_INTERVAL=1 AMCL_INPUT_HOST_EXPORTS)\n'
    if args.latency_mode=='foreign':text+='target_compile_definitions(sdl_look PRIVATE AMCL_SDL_LATENCY_FOREIGN)\n'
    if os.name=='nt':text+='target_compile_options(sdl_look PRIVATE /utf-8)\ntarget_compile_options(amcl_look_owner PRIVATE /utf-8)\nset_source_files_properties(consumer.c PROPERTIES COMPILE_OPTIONS "/experimental:c11atomics")\n'
    else:text+='target_compile_definitions(sdl_look PRIVATE _GNU_SOURCE)\ntarget_link_libraries(sdl_look PRIVATE ${CMAKE_DL_LIBS} pthread)\ntarget_link_options(sdl_look PRIVATE -rdynamic)\ntarget_link_libraries(amcl_look_owner PRIVATE ${CMAKE_DL_LIBS} pthread)\n'
    (output/'CMakeLists.txt').write_text(text,encoding='utf-8');cmake=find_host_cmake(args.cmake);configure_host_cmake(cmake,output,output/'build')
    control.run([cmake,'--build',output/'build','--config','Release','--parallel','8'],output,output/'compile.log')
    sdk_library=output/('build/sdk/Release/SDL3.dll' if os.name=='nt' else 'build/sdk/libSDL3.so')
    owner_library=output/('build/Release/amcl_look_owner.dll' if os.name=='nt' else 'build/libamcl_look_owner.so')
    control.run([sys.executable,ROOT/'scripts/test-sdl-look-owner-init.py','--sdk-library',sdk_library,
        '--owner-library',owner_library,'--receipt',output/'owner-init-receipt.json'],output,output/'owner-init.log')
    results=verify(output,cmake,args.production_only,args.latency_negative)
    (output/'receipt.json').write_text(json.dumps({'startedAt':started,'finishedAt':datetime.now().astimezone().isoformat(),
        'sourcePin':pin,'layer':'full-host-SDL-SDK-production-prefix','latencyMode':args.latency_mode,'latencyNegative':args.latency_negative,
        'inputSha256':frozen,'results':results},ensure_ascii=False,indent=2),encoding='utf-8')
if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--source-repo',type=Path,required=True);parser.add_argument('--out',required=True)
    parser.add_argument('--cmake');parser.add_argument('--production-only',action='store_true')
    parser.add_argument('--latency-mode',choices=['off','on','foreign'],default='off',help='同image真实collector的可选观察接缝；不授正式bridge提供者')
    parser.add_argument('--latency-negative',choices=['cache','posted'],help='编译成功的consumer诊断反控，仅用于定向ON门')
    args=parser.parse_args()
    if args.latency_negative and (not args.production_only or args.latency_mode!='on'):
        parser.error('--latency-negative requires --production-only --latency-mode on')
    build(args)
