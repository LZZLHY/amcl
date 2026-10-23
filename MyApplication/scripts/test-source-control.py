"""执行真 neutral 来源 owner、完整 bridge/JNI、生产 GLFW 写读点及真实双 DLL 冷身份。

生成源码与构建显式仓外；只控制窗口/平台 host 边缘，不复刻来源、容量或消费者归约算法。
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from datetime import datetime
sys.dont_write_bytecode = True
from lib.host_cpp import find_host_cmake, configure_host_cmake
from lib.workspace_paths import external_output_path
ROOT = Path(__file__).resolve().parents[1]

def block(text, name):
    """只提取指定生产函数完整正文，配方失败不降级到复制实现。"""
    hit = re.search(r'^(?:static )?(?:void|int|bool) '+re.escape(name)+r'\([^;{}]*\)\s*\{', text, re.M)
    if not hit:
        raise ValueError('Production function missing: '+name)
    brace=text.index('{',hit.start()); depth=1; end=brace+1
    while depth:
        if text[end]=='{': depth+=1
        elif text[end]=='}': depth-=1
        end+=1
    return text[hit.start():end]

def main(options):
    """只对子进程配置临时目录；receipt 保存原始编译/行为输出及准确源字节身份。"""
    out=external_output_path(options.out); build=external_output_path(options.build_out)
    out.mkdir(parents=True,exist_ok=False); build.mkdir(parents=True,exist_ok=options.reuse_build)
    temp=build/'temp';temp.mkdir(exist_ok=options.reuse_build);os.environ['TEMP']=str(temp);os.environ['TMP']=str(temp)
    cpp=ROOT/'entry/src/main/cpp'; started=datetime.now().astimezone().isoformat()
    capacity=getattr(options,'tap_capacity',8)
    if capacity!=8 and options.negative in ('compat-bypass','budget2'):
        raise ValueError('Original complete Source controls use capacity8; default4096 targets only owned terminal recovery')
    sources=[cpp/name for name in [
        'input/source/source_control.cpp','platform/input_ledger.cpp','platform/external_held_registry.cpp',
        'platform/external_held_edge_router.cpp','platform/legacy_output_runtime.cpp','platform/legacy_physical_edge_router.cpp',
        'input/delivery/look_execution.cpp','input/delivery/control_delivery.cpp','input/input_state_core.cpp',
        'input/amcl_input_host_descriptor.cpp','input/input_interaction_order.cpp','platform/look_delta_math.cpp',
        'platform/look_pipeline_stats.cpp','input/adapters/glfw_source_plane_aggregate.cpp','input/adapters/glfw_input_adapter.cpp','input/adapters/backend_keymaps.cpp',
        'input/adapters/lwjgl2_event_translate.cpp','platform/physical_wheel_quantizer.cpp',
        'tests/host/backend_input_bridge_host_stub.cpp']]
    bridge=cpp/'glfw/input_bridge_ohos.c'; compat=(cpp/'glfw/glfw_compat.cpp').read_text(encoding='utf-8')
    callbacks=(cpp/'glfw/glfw_callbacks.cpp').read_text(encoding='utf-8')
    control='\n'.join(block(compat,name) for name in ['glfwOHOS_RecordControlPoll','currentModifierMask','dispatchAggregateKey','dispatchAggregateButton'])
    # 真实文字提交sink/UTF8 decode正文与真实bridge char出口一起消费owned包；
    # 测试只提供preedit/错误观察边缘，不以无操作textSink冒称字符消费。
    control+='\n'+'\n'.join(block(compat,name) for name in ['decodeTypedUtf8','typedTextCommitSink'])
    control+='\n'+'\n'.join(block(callbacks,name) for name in ['glfwGetKey','glfwGetMouseButton'])
    fixture=(cpp/'tests/host/source_control_transport_test.cpp.in').read_text(encoding='utf-8')
    fixture=fixture.replace('@GLFW_CONTROL@',control).replace('@LOOK_CALLBACK@',block(compat,'bridgeLookPrefixCallback'))
    touch=(cpp/'platform/touch_input.cpp').read_text(encoding='utf-8')
    start=touch.index('struct SchemaButtonRuntime {');end=touch.index('{',start)+1;depth=1
    while depth:
        if touch[end]=='{':depth+=1
        elif touch[end]=='}':depth-=1
        end+=1
    assert touch[end]==';';end+=1
    native=touch[start:end]+'\nstd::map<std::string,SchemaButtonRuntime> s_schemaButtons;\n'
    native+='\n'.join(block(touch,name) for name in ['schemaDispatchButton','schemaTriggerFirstDown','schemaTriggerLastUp','schemaPollLongPressLocked'])
    fixture=fixture.replace('@NATIVE_BUTTON@',native)
    if capacity==4096:
        # 原完整Source/六码/窗口组合继续以8槽运行；4k只截取真实初始化/正常pair前提，
        # 接同一生产同码恢复与三槽预算场。不能机械替换原8槽压力断言使其失真。
        prefixEnd='    textStart.payload.textSession.change=AMCL_INPUT_TEXT_SESSION_ENDED;CHECK(core->submitEvent(&textStart)==0);'
        assert prefixEnd in fixture
        recovery=fixture.split('/* SOURCE_OWNED_TAP_RECOVERY_BEGIN */',1)[1].split('/* SOURCE_OWNED_TAP_RECOVERY_END */',1)[0]
        fixture=fixture[:fixture.index(prefixEnd)]+prefixEnd+'\n    CHECK(textAdapter.Close()==GlfwAdapterStatus::kOk);\n    GLFWwindow& newWindow=window;\n'+recovery+'\n}\n'
    (build/'transport.cpp').write_text(fixture,encoding='utf-8')
    originalSources=list(sources)
    original=bridge.read_text(encoding='utf-8')
    if options.negative=='same-tap-dedup':
        # 只撤Source的新DOWN去重围栏；编译后必须重现同码最终cache/callback故障。
        source=sources[0].read_text(encoding='utf8');needle='if(edge.action==1)pending.erase(edge.output);'
        assert source.count(needle)==1
        source=source.replace(needle,'/* compiled negative: old terminal dedup survives new DOWN */')
        source=re.sub(r'#include "([^\"]+)"',lambda m:'#include "'+(sources[0].parent/m[1]).resolve().as_posix()+'"',source)
        negativeSource=build/'negative_source.cpp';negativeSource.write_text(source,encoding='utf8');sources[0]=negativeSource
    elif options.negative:
        if options.negative=='compat-bypass':
            before='(void)amclSourceControlCompatEdgeV1(0u,key,scancode,action,mods);'
            assert original.count(before)==1
            original=original.replace(before,'inputBridge_pushEvent(EVENT_TYPE_KEY,key,scancode,action,mods);',1)
        else:
            before='lookRingReserveLocked(count+(grabbed?1u:0u))'
            assert original.count(before)==1
            original=original.replace(before,'lookRingReserveLocked(2)',1)
        original=re.sub(r'#include "([^\"]+)"',lambda m:'#include "'+(bridge.parent/m[1]).resolve().as_posix()+'"',original)
        bridge=build/'negative_bridge.cpp';bridge.write_text(original,encoding='utf-8')
    all_sources=[*sources,bridge]
    project='cmake_minimum_required(VERSION 3.20)\nproject(source_control LANGUAGES CXX)\n'
    project+='set_source_files_properties("'+bridge.as_posix()+'" PROPERTIES LANGUAGE CXX)\n'
    def target(name,kind,extra):
        """每个目标都链接同一实际生产 owner 和 bridge，DLL 身份测试不靠假表。"""
        nonlocal project
        project+=('add_executable(' if kind=='exe' else 'add_library(')+name+(' ' if kind=='exe' else ' SHARED ')
        project+=' '.join('"'+p.as_posix()+'"' for p in [*extra,*all_sources])+')\n'
        project+='target_compile_features('+name+' PRIVATE cxx_std_17)\n'
        # 客户端以真实动态符号验证宿主owner；GNU可执行文件也须导出getter，不能只靠Windows pragma。
        if kind=='exe':project+='set_target_properties('+name+' PROPERTIES ENABLE_EXPORTS ON)\n'
        project+='target_compile_definitions('+name+' PRIVATE AMCL_INPUT_HOST_EXPORTS AMCL_INPUT_BRIDGE_HOST_TESTING AMCL_CONTROL_DELIVERY_HOST_TESTING NOMINMAX _CRT_SECURE_NO_WARNINGS EVENT_WINDOW_SIZE='+str(capacity)+')\n'
        project+='target_include_directories('+name+' PRIVATE "'+cpp.as_posix()+'" "'+(cpp/'tests/host/stubs').as_posix()+'")\n'
        project+='if(MSVC)\n target_compile_options('+name+' PRIVATE /utf-8)\nelse()\n target_link_libraries('+name+' PRIVATE dl pthread)\nendif()\n'
    target('transport','exe',[build/'transport.cpp'])
    # 只有行为目标使用可观测实际 notify 接点；冷身份 DLL/分配目标不需要平台 frame 服务。
    project+='target_compile_definitions(transport PRIVATE AMCL_DESKTOP_EVENT_BRIDGE=1)\n'
    # 只在Linux宿主用链接器包装实际Resolve计数；转发真实实现，不向产品加入热路径探针。
    project+='if(CMAKE_SYSTEM_NAME STREQUAL "Linux")\n target_compile_definitions(transport PRIVATE AMCL_SOURCE_RESOLVE_COUNT_TEST)\n target_link_options(transport PRIVATE -Wl,--wrap=amclInputHostDescriptorResolveV1)\nendif()\n'
    target('allocation','exe',[cpp/'tests/host/source_control_allocation_test.cpp'])
    if os.name=='nt' and not options.negative:
        target('source_owner_a','dll',[]);target('source_owner_b','dll',[])
        project+='add_executable(identity "'+(cpp/'tests/host/source_control_identity_test.cpp').as_posix()+'")\n'
        project+='target_compile_features(identity PRIVATE cxx_std_17)\ntarget_compile_options(identity PRIVATE /utf-8)\n'
    (build/'CMakeLists.txt').write_text(project,encoding='utf-8'); cmake=find_host_cmake(options.cmake)
    paths=[*originalSources,cpp/'glfw/input_bridge_ohos.c',cpp/'glfw/glfw_compat.cpp',cpp/'glfw/glfw_callbacks.cpp',
        cpp/'platform/touch_input.cpp',cpp/'platform/source_control_client.h',cpp/'input/source/source_control.h',
        cpp/'input/source/source_control_client.h',
        cpp/'input/input_state_core.h',cpp/'input/input_text_core_hook.h',cpp/'input/text_utf8_codec.h',
        cpp/'input/source/source_control_client.h',cpp/'input/delivery/look_execution.h',cpp/'input/delivery/look_execution_client.h',
        cpp/'tests/host/source_control_transport_test.cpp.in',cpp/'tests/host/source_control_allocation_test.cpp',
        cpp/'tests/host/source_control_identity_test.cpp',Path(__file__)]
    paths += [cpp/'platform'/name for name in ['input_ledger.h','external_held_registry.h','external_held_edge_router.h',
        'legacy_output_runtime.h','legacy_physical_edge_router.h','input_source.h','legacy_output_code.h','control_schema_abi.h']]
    before={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    configure_host_cmake(cmake,build,build/'build')
    run=subprocess.run([cmake,'--build',str(build/'build'),'--config','Release'],capture_output=True)
    (out/'compile.log').write_bytes(run.stdout+run.stderr);print((run.stdout+run.stderr).decode(errors='replace'),flush=True)
    if run.returncode:raise RuntimeError('actual source owner compilation failed')
    suffix='Release/transport.exe' if os.name=='nt' else 'transport'
    run=subprocess.run([str(build/'build'/suffix)],capture_output=True,timeout=20)
    (out/'transport.log').write_bytes(run.stdout+run.stderr);print((run.stdout+run.stderr).decode(errors='replace'),flush=True)
    if options.negative:
        assert run.returncode!=0 and b'SOURCE TRANSPORT FAIL' in run.stderr,'negative must fail real behavior, not linkage or timeout'
        if options.negative=='same-tap-dedup':
            assert b'COUNTER_FINAL poll259=1' in run.stdout,'old dedup negative must reach actual same-code cache failure'
    elif run.returncode:raise RuntimeError('actual source owner behavior failed')
    results=[{'name':'transport','exitCode':run.returncode}]
    if not options.negative:
        modes=['allocation','constructor'] if os.name=='nt' else ['allocation']
        for mode in modes:
            binary=build/'build'/('Release/allocation.exe' if os.name=='nt' else 'allocation')
            run=subprocess.run([str(binary),mode],capture_output=True,timeout=10)
            (out/('cold-'+mode+'.log')).write_bytes(run.stdout+run.stderr)
            print((run.stdout+run.stderr).decode(errors='replace'),flush=True)
            results.append({'name':'cold-'+mode,'exitCode':run.returncode})
            if run.returncode:raise RuntimeError('actual source cold allocation failure proof failed')
    if os.name=='nt' and not options.negative:
        run=subprocess.run([str(build/'build/Release/identity.exe'),str(build/'build/Release/source_owner_a.dll'),str(build/'build/Release/source_owner_b.dll')],capture_output=True,timeout=20)
        (out/'identity.log').write_bytes(run.stdout+run.stderr);print((run.stdout+run.stderr).decode(errors='replace'),flush=True)
        results.append({'name':'identity','exitCode':run.returncode})
        if run.returncode:raise RuntimeError('actual DLL source identity failed')
    after={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    drift=[name for name in before if before[name]!=after[name]]
    (out/'receipt.json').write_text(json.dumps({'startedAt':started,'completedAt':datetime.now().astimezone().isoformat(),
        'negative':options.negative,'tapCapacity':capacity,'results':results,'sourcesBefore':before,'sources':after,'sourceDrift':drift,
        'boundary':'real source/Core/look/control/bridge/JNI/GLFW cache/callback/poll and DLL identities; no JVM/game tick/SDK/device claim'},indent=2)+'\n',encoding='utf-8')
    if drift:raise RuntimeError('source changed during actual build/test: '+', '.join(drift))

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--build-out',type=Path,required=True);parser.add_argument('--cmake')
    parser.add_argument('--reuse-build',action='store_true',help='显式复用当前任务已登记宿主缓存，日志仍写新输出目录')
    parser.add_argument('--tap-capacity',type=int,choices=[8,4096],default=8,help='8保全部原Source组；4096只验同码owned恢复/三记录真实预算')
    parser.add_argument('--negative',choices=['compat-bypass','budget2','same-tap-dedup']);main(parser.parse_args())
