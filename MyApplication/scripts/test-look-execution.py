"""编译实际neutral look/Core/control实现并执行来源兼容与不可变前缀回归。"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import hashlib
import re
import runpy
from datetime import datetime
from lib.host_cpp import find_host_cmake, configure_host_cmake
from lib.workspace_paths import external_output_path

ROOT=Path(__file__).resolve().parents[1]

def build_visible(cmake,build,output):
    """普通MSVC构建保持前台并逐行显示；同一字节流落盘，失败正文不能被后续尝试覆盖。"""
    with output.open('wb') as log:
        child=subprocess.Popen([cmake,'--build',str(build),'--config','Release'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        for line in child.stdout:
            log.write(line);log.flush();print(line.decode(errors='replace'),end='',flush=True)
        return child.wait()

def run_two_image(options,output,build,cpp,sources,callback):
    """两个DLL均编真实bridge和neutral，产品callback逐字进入各自映像；不模拟函数表。"""
    if os.name!='nt':raise RuntimeError('two-image bridge validation requires the native Windows DLL host')
    output.mkdir(parents=True,exist_ok=False);build.mkdir(parents=True,exist_ok=False)
    started=datetime.now().astimezone().isoformat(timespec='seconds')
    tracked={*sources,cpp/'glfw/input_bridge_ohos.c',cpp/'glfw/glfw_compat.cpp',
        cpp/'tests/host/look_bridge_identity_fixture.cpp.in',cpp/'tests/host/look_bridge_identity_driver.cpp',Path(__file__),
        cpp/'input/delivery/look_transport.h',cpp/'input/delivery/look_execution_client.h',
        cpp/'input/delivery/control_delivery_client.h',cpp/'glfw/input_bridge_instance_descriptor.h',
        cpp/'input/input_look_core_hook.h',cpp/'input/source/source_control.h'}
    beforeHashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    if options.image_negative=='resume':
        original=cpp/'input/delivery/look_execution.cpp';body=original.read_text(encoding='utf-8')
        before='bool replacing=it!=r.consumers.end()&&!backendRestartOnly;'
        assert body.count(before)==1;body=body.replace(before,'bool replacing=it!=r.consumers.end(); /* 负控：撤backend-only首笔保护。 */',1)
        body=re.sub(r'#include "([^\"]+)"',lambda match:'#include "'+(original.parent/match[1]).resolve().as_posix()+'"',body)
        mutated=build/'mutated_look.cpp';mutated.write_text(body,encoding='utf-8')
        sources=[mutated if p==original else p for p in sources]
    bridge=cpp/'glfw/input_bridge_ohos.c'
    if options.image_negative=='getter':
        before='const AmclLookExecutionPortV1* look=g_sourcePlaneAggregate.LookPort();\n    if(!look)return finish(0,"owner-missing");'
        assert callback.count(before)==1
        callback=callback.replace(before,'const auto* look=amclLookExecutionGetPortV1();if(!look)return finish(0,"owner-missing");',1)
    if options.image_negative in ('registration','replay','retirement','tail-length','tail-version') or options.image_contract:
        body=bridge.read_text(encoding='utf-8')
        if options.image_negative=='registration':
            before='if(owner){if(bridgeOwnerHasLookTransportV1(owner))owner->setLookPrefixCallback(callback);return;}'
            assert body.count(before)==1;body=body.replace(before,'if(owner)return; // 负控：不转发实际注册。',1)
        elif options.image_negative=='replay':
            before='owner->setLookPrefixCallback(g_lookPrefixCallback);'
            assert body.count(before)==1;body=body.replace(before,'/* 负控：撤掉实际late owner回放。 */',1)
        elif options.image_negative=='retirement':
            before='if(owner){if(bridgeOwnerHasLookTransportV1(owner))owner->setLookPrefixCallback(callback);return;}'
            assert body.count(before)==1;body=body.replace(before,'if(owner){if(callback&&bridgeOwnerHasLookTransportV1(owner))owner->setLookPrefixCallback(callback);return;}',1)
        elif options.image_negative=='tail-length':
            before='owner && INPUT_BRIDGE_OWNER_HAS_TAIL(owner, submitProcessedLook) &&'
            assert body.count(before)==1;body=body.replace(before,'owner && owner->submitProcessedLook &&',1)
        elif options.image_negative=='tail-version':
            before='owner->lookTransportVersion == AMCL_LOOK_TRANSPORT_VERSION &&'
            assert body.count(before)==1;body=body.replace(before,'true && /* 负控：忽略实际look版本。 */',1)
        if options.image_contract=='short':
            before='g_bridgeInstance.structSize = (unsigned int)sizeof(InputBridgeInstanceV1);'
            assert body.count(before)==1;body=body.replace(before,'g_bridgeInstance.structSize = (unsigned int)offsetof(InputBridgeInstanceV1, lookTransportVersion);',1)
        elif options.image_contract=='version':
            before='g_bridgeInstance.lookTransportVersion = AMCL_LOOK_TRANSPORT_VERSION;'
            assert body.count(before)==1;body=body.replace(before,'g_bridgeInstance.lookTransportVersion = AMCL_LOOK_TRANSPORT_VERSION + 1u;',1)
        body=re.sub(r'#include "([^\"]+)"',lambda match:'#include "'+(bridge.parent/match[1]).resolve().as_posix()+'"',body)
        bridge=build/'mutated_bridge.cpp';bridge.write_text(body,encoding='utf-8')
    fixture='#include \"input/input_latency_observation.h\"\n'+(cpp/'tests/host/look_bridge_identity_fixture.cpp.in').read_text(encoding='utf-8').replace('@LOOK_CALLBACK@',callback)
    (build/'image.cpp').write_text(fixture,encoding='utf-8')
    full=[*sources,bridge,cpp/'input/adapters/glfw_source_plane_aggregate.cpp',
        cpp/'input/adapters/lwjgl2_event_translate.cpp',cpp/'platform/physical_wheel_quantizer.cpp',
        cpp/'tests/host/backend_input_bridge_host_stub.cpp',cpp/'input/source/source_control.cpp',
        cpp/'platform/input_ledger.cpp',cpp/'platform/external_held_registry.cpp',
        cpp/'platform/external_held_edge_router.cpp',cpp/'platform/legacy_output_runtime.cpp',
        cpp/'platform/legacy_physical_edge_router.cpp',build/'image.cpp']
    # 只生成owner映像的受控冷混搭/关联撤回，consumer始终编同一候选；不回写来源文件。
    owner_bridge=bridge
    if options.diag_owner in ('short','version','null') or options.diag_negative:
        changed=bridge.read_text(encoding='utf-8')
        if options.diag_owner=='short':changed=changed.replace('g_bridgeInstance.latencyVersion=1;',
            'g_bridgeInstance.latencyVersion=1;g_bridgeInstance.structSize=(unsigned int)offsetof(InputBridgeInstanceV1,latencyVersion);',1)
        if options.diag_owner=='version':changed=changed.replace('g_bridgeInstance.latencyVersion=1;','g_bridgeInstance.latencyVersion=99;',1)
        # 全尾部声明但函数缺席必须只有观察缺失，不能以NULL诊断指针崩溃影响输入。
        if options.diag_owner=='null':changed=changed.replace('g_bridgeInstance.drainInputLatency=&inputBridge_drainInputLatencyV1;',
            'g_bridgeInstance.drainInputLatency=nullptr; /* 真冷尾部NULL能力反例。 */',1)
        if options.diag_negative=='order':changed=changed.replace('note.ringOrder=g_events[(next-1)%EVENT_WINDOW_SIZE].interactionOrder;',
            'note.ringOrder=prefix.order; /* 负控：误把prefixOrder借作ringOrder。 */',1)
        changed=re.sub(r'#include "([^\"]+)"',lambda m:'#include "'+(bridge.parent/m[1]).resolve().as_posix()+'"',changed)
        owner_bridge=build/'diagnostic-owner-bridge.cpp';owner_bridge.write_text(changed,encoding='utf-8')
    project='cmake_minimum_required(VERSION 3.20)\nproject(look_bridge_images LANGUAGES CXX)\n'
    for target in ['bridge_owner','bridge_consumer']:
        native=[owner_bridge if target=='bridge_owner' and p==bridge else p for p in full]
        project+='add_library('+target+' SHARED '+' '.join('"'+p.as_posix()+'"' for p in native)+')\n'
        project+='target_compile_features('+target+' PRIVATE cxx_std_17)\ntarget_compile_options('+target+' PRIVATE /utf-8)\n'
        project+='target_include_directories('+target+' PRIVATE "'+cpp.as_posix()+'" "'+(cpp/'platform').as_posix()+'" "'+(cpp/'tests/host/stubs').as_posix()+'")\n'
        # facade和control采用生产的显式owner解析/绑定路径；旧HOST宏会自行发布本地owner，
        # 会把双image验证变成另一条测试路径。仅typed transport stub禁止伪造第二份Core。
        trace='1' if options.trace=='on' and not(target=='bridge_owner' and options.diag_owner=='off') else '0'
        project+='target_compile_definitions('+target+' PRIVATE AMCL_INPUT_TRACE='+trace+' AMCL_INPUT_LATENCY_HOST_TESTING AMCL_INPUT_LATENCY_SAMPLE_INTERVAL=1 AMCL_INPUT_HOST_EXPORTS AMCL_INPUT_BRIDGE_HOST_TESTING EVENT_WINDOW_SIZE=16 _CRT_SECURE_NO_WARNINGS)\n'
    project+='set_source_files_properties("'+(cpp/'tests/host/backend_input_bridge_host_stub.cpp').as_posix()+'" PROPERTIES COMPILE_DEFINITIONS AMCL_CONTROL_DELIVERY_HOST_TESTING)\n'
    project+='set_source_files_properties("'+bridge.as_posix()+'" PROPERTIES LANGUAGE CXX)\n'
    project+='add_executable(image_driver "'+(cpp/'tests/host/look_bridge_identity_driver.cpp').as_posix()+'")\n'
    project+='target_compile_options(image_driver PRIVATE /utf-8)\n'
    project+='target_compile_definitions(image_driver PRIVATE AMCL_INPUT_TRACE='+('1' if options.trace=='on' else '0')+' AMCL_ILAT_EXPECT_AVAILABLE='+('1' if options.diag_owner=='on' else '0')+')\n'
    (build/'CMakeLists.txt').write_text(project,encoding='utf-8')
    cmake=find_host_cmake(options.cmake);configure_host_cmake(cmake,build,build/'build')
    if build_visible(cmake,build/'build',output/'compile.log'):raise RuntimeError('two-image production compile failed')
    results=[]
    modes=['normal','early','early-null','reentry','blocked','blocked-retire','no-callback','full','busy','clock-fail']
    if options.trace=='on' and options.diag_owner=='on':modes.append('pre-dispatch-retire')
    for mode in (['short'] if options.image_contract else modes):
        args=[str(build/'build/Release/image_driver.exe'),str(build/'build/Release/bridge_owner.dll'),
            str(build/'build/Release/bridge_consumer.dll'),mode]
        run=subprocess.run(args,capture_output=True,timeout=15);(output/(mode+'.log')).write_bytes(run.stdout+run.stderr)
        print((run.stdout+run.stderr).decode(errors='replace'),flush=True);results.append({'mode':mode,'exitCode':run.returncode})
    identities={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in full if ROOT in p.parents}
    afterHashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    assert beforeHashes==afterHashes,'two-image actual source drift during compile/run'
    (output/'receipt.json').write_text(json.dumps({'results':results,'sources':identities,'negative':options.image_negative,'contract':options.image_contract,
        'started':started,'completed':datetime.now().astimezone().isoformat(timespec='seconds'),
        'compileSourceBefore':beforeHashes,'compileSourceAfter':afterHashes,'sourceDrift':[],
        'generatedCallbackSha256':hashlib.sha256((build/'image.cpp').read_bytes()).hexdigest(),
        'bridgeSha256':hashlib.sha256(bridge.read_bytes()).hexdigest(),
        'generatedSourceSha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in full if build in p.parents},
        'binarySha256':{name:hashlib.sha256((build/'build/Release'/name).read_bytes()).hexdigest()
            for name in ['bridge_owner.dll','bridge_consumer.dll','image_driver.exe']},
        'layer':'two actual production neutral/Core/control/bridge DLLs + literal product callback; host ABI only'},indent=2)+'\n',encoding='utf-8')
    if options.image_negative:
        failed=[row for row in results if row['exitCode']]
        assert failed and all(b'LOOK IMAGE FAIL' in (output/(row['mode']+'.log')).read_bytes() for row in failed),'negative must fail actual ABI behavior assertion'
        mode='short' if options.image_contract else 'early' if options.image_negative=='replay' else 'normal'
        needle=b'consumer.submit(12)==0' if options.image_contract else b'cursor[0]==127' if options.image_negative in ('resume','retirement') else b'cursor[0]==112'
        assert needle in (output/(mode+'.log')).read_bytes(),'negative must hit the original affected behavior assertion'
    elif options.diag_negative:
        assert any(row['exitCode'] for row in results),'diagnostic withdrawal must fail actual behavior'
        assert b'LOOK IMAGE FIXTURE FAIL' in (output/'normal.log').read_bytes(),'negative must compile then fail correlation assertion'
    elif any(row['exitCode'] for row in results):raise RuntimeError('two-image production behavior failed')

def main(options):
    """输出和构建树显式仓外；只对子进程设置临时目录，不更改用户全局TEMP。"""
    output=external_output_path(options.out)
    build=external_output_path(options.build_out)
    output.mkdir(parents=True,exist_ok=False)
    build.mkdir(parents=True,exist_ok=False)
    temp=build/'temp';temp.mkdir()
    os.environ['TEMP']=str(temp);os.environ['TMP']=str(temp)
    cpp=ROOT/'entry/src/main/cpp'
    sources=[cpp/'input/input_latency_observation.cpp',cpp/'input/delivery/look_execution.cpp',cpp/'input/delivery/control_delivery.cpp',
        cpp/'input/input_state_core.cpp',cpp/'input/amcl_input_host_descriptor.cpp',cpp/'input/input_interaction_order.cpp',
        cpp/'platform/source_look_processor.cpp',cpp/'platform/look_delta_math.cpp',cpp/'platform/look_pipeline_stats.cpp',
        cpp/'input/adapters/backend_keymaps.cpp']
    project='cmake_minimum_required(VERSION 3.20)\nproject(look_execution LANGUAGES CXX)\n'
    # GLFW边缘函数体从产品源码逐函数提取，fixture只提供窗口结构与平台/typed transport；
    # 不在测试里重写prefix状态机或实际callback围栏。
    glfw=(cpp/'glfw/glfw_compat.cpp').read_text(encoding='utf-8')
    start=glfw.index('static int bridgeLookPrefixCallback(');bodyStart=glfw.index('{',start);depth=1;end=bodyStart+1
    while depth:
        if glfw[end]=='{':depth+=1
        elif glfw[end]=='}':depth-=1
        end+=1
    callback='#include \"input/input_latency_observation.h\"\n'+glfw[start:end]
    if options.two_image_only:
        run_two_image(options,output/'two-image',build/'two-image',cpp,sources,callback)
        return
    fixture=(cpp/'tests/host/look_transport_test.cpp.in').read_text(encoding='utf-8').replace('@LOOK_CALLBACK@',callback)
    touch=(cpp/'platform/touch_input.cpp').read_text(encoding='utf-8')
    gyroStart=touch.index('namespace {\n/** 仅保存租约身份')
    gyroEnd=touch.index('// ==================== 阶段 2.8：char 事件',gyroStart)
    fixture=fixture.replace('@GYRO_LEASE@',touch[gyroStart:gyroEnd])
    # 独立时钟组复用现有transport的宿主边缘及逐字callback；不复制产品Source/owner
    # 算法。默认矩阵也运行它，--target clock只编该组供单点复现与撤回编译反控。
    clock_fixture=None
    if options.target in ('all','clock'):
        clock_fixture=(cpp/'tests/host/look_clock_test.cpp.in').read_text(encoding='utf-8')
        clock_fixture=clock_fixture.replace('@TRANSPORT_PREFIX@',fixture[:fixture.index('int main(){')])
        (build/'clock.cpp').write_text(clock_fixture,encoding='utf-8')
    # 新纵向仅借现有touch装配数据；显式recipe-only不给任何旧测试PASS，也不复写schema算法。
    # 普通test-touch-production仍执行原矩阵，本目标编译它提取出的逐字生产函数。
    native_fixture=None
    if options.target=='native-touch':
        native=runpy.run_path(str(ROOT/'scripts/test-touch-production.py'),init_globals={'AMCL_TOUCH_RECIPE_ONLY':True})
        nativePrefix=native['prefix']
        old='bool applyLookDelta(int,double x,double y,int64_t){++looks;lookX+=x;lookY+=y;return true;}\nvoid flushLookPending(bool,int){}'
        assert nativePrefix.count(old)==1
        nativePrefix=nativePrefix.replace(old,'',1)
        oldCensus='namespace amcl::input::census { enum class Channel{LookFromSchemaTouch,SchemaTouchScroll};void Bump(Channel){} }'
        assert nativePrefix.count(oldCensus)==1
        nativePrefix=nativePrefix.replace(oldCensus,'#include "platform/input_channel_census.h"',1)
        nativePrefix=nativePrefix.replace('#define OH_LOG_INFO(...) ((void)0)\n','',1)
        actualLook='\n'.join(native['definition'](name) for name in ['static void recordInvalidLookDelta(',
            'static bool applyLookDelta(', 'static void flushLookPending('])
        native_fixture=(cpp/'tests/host/native_schema_look_test.cpp.in').read_text(encoding='utf-8')
        native_fixture=native_fixture.replace('@TOUCH_PREFIX@',nativePrefix).replace('@REAL_LOOK_FUNCTIONS@',actualLook)
        native_fixture=native_fixture.replace('@TOUCH_PRODUCTION@',native['production']).replace('@LOOK_CALLBACK@',glfw[start:end])
        if options.negative in ('normal-up-retire','cancel-keep'):
            before='lookFinishMode = (ev.type == OH_NATIVEXCOMPONENT_UP) ? 1 : -1;'
            assert native_fixture.count(before)==1
            after='lookFinishMode = -1;' if options.negative=='normal-up-retire' else 'lookFinishMode = 1;'
            native_fixture=native_fixture.replace(before,after+' // 负控：仅撤生产终点分工。',1)
        (build/'native_touch.cpp').write_text(native_fixture,encoding='utf-8')
    bridge=cpp/'glfw/input_bridge_ohos.c'
    clock_owner=None
    if options.negative=='idle-clock':
        original=cpp/'input/delivery/look_execution.cpp';body=original.read_text(encoding='utf-8')
        before='if(flush!=2){'
        assert body.count(before)==1
        # 只在生成树恢复旧零delta采样/两层时钟推进，真实资源与运输门仍保持修复版。
        body=body.replace(before,'if(true){ /* 负控：撤idle/UP的seal-only，恢复旧采样clock污染。 */',1)
        body=re.sub(r'#include "([^\"]+)"',lambda match:'#include "'+(original.parent/match[1]).resolve().as_posix()+'"',body)
        clock_owner=build/'idle_clock_owner.cpp';clock_owner.write_text(body,encoding='utf-8')
    if options.negative=='cache':
        before='win->cursorX=floor(emission.x);win->cursorY=floor(emission.y);'
        assert fixture.count(before)==1
        fixture=fixture.replace(before,'/* 负控：真正GLFW cache写入被撤，仍调用callback。 */',1)
    elif options.negative=='trace-budget':
        assert options.trace=='on','trace-budget负控必须启用真实产品trace分支'
        before='if(sample||(failed&&(failure==1||(failure&(failure-1))==0)))'
        assert fixture.count(before)==1
        fixture=fixture.replace(before,'if(true) /* 负控：撤实际callback日志预算，不改变输入输出。 */',1)
    elif options.negative=='pressure':
        body=bridge.read_text(encoding='utf-8')
        before='write-oldest>EVENT_WINDOW_SIZE-count'
        assert body.count(before)==1
        body=body.replace(before,'0 /* 负控：取消真实运输容量拒绝。 */',1)
        # 原始相对include按该生产文件目录转为绝对路径，唯一行为变异仅上面一处。
        body=re.sub(r'#include "([^\"]+)"',lambda match:'#include "'+(bridge.parent/match[1]).resolve().as_posix()+'"',body)
        bridge=build/'pressure_bridge.cpp';bridge.write_text(body,encoding='utf-8')
    (build/'transport.cpp').write_text(fixture,encoding='utf-8')
    targets=[('native_touch',None)] if options.target=='native-touch' else [('clock',None)] if options.target=='clock' else [('compat','source_look_processor_test.cpp'),('prefix','look_execution_test.cpp'),('transport',None),('physical','look_physical_core_test.cpp'),('clock',None),('latency','input_latency_observation_test.cpp')]
    compiledInputs=set()
    for target,test in targets:
        targetSources=[cpp/'tests/host'/test,*sources] if test else [build/('native_touch.cpp' if target=='native_touch' else 'clock.cpp' if target=='clock' else 'transport.cpp'),*sources,
            bridge,cpp/'input/adapters/glfw_source_plane_aggregate.cpp',
            cpp/'input/adapters/lwjgl2_event_translate.cpp',cpp/'platform/physical_wheel_quantizer.cpp',
            cpp/'tests/host/backend_input_bridge_host_stub.cpp']
        if not test:targetSources += [cpp/'platform/mapped_look_producer.cpp',cpp/'platform/source_look_producer.cpp']
        if not test:targetSources += [cpp/'input/source/source_control.cpp',cpp/'platform/input_ledger.cpp',
            cpp/'platform/external_held_registry.cpp',cpp/'platform/external_held_edge_router.cpp',
            cpp/'platform/legacy_output_runtime.cpp',cpp/'platform/legacy_physical_edge_router.cpp']
        if target=='native_touch':targetSources += [cpp/'platform/input_source.cpp']
        if target=='physical':targetSources += [cpp/'input/adapters/backend_input_bridge.cpp',cpp/'input/adapters/glfw_input_adapter.cpp',
            cpp/'input/adapters/backend_keymaps.cpp',cpp/'platform/physical_wheel_quantizer.cpp',cpp/'platform/input_source.cpp']
        if target=='clock' and clock_owner is not None:
            targetSources=[clock_owner if p==cpp/'input/delivery/look_execution.cpp' else p for p in targetSources]
        compiledInputs.update(path for path in targetSources if path.is_relative_to(ROOT))
        project+='add_executable('+target+' '+ ' '.join('"'+p.as_posix()+'"' for p in targetSources)+')\n'
        project+='target_compile_features('+target+' PRIVATE cxx_std_17)\n'
        project+='target_include_directories('+target+' PRIVATE "'+cpp.as_posix()+'" "'+(cpp/'platform').as_posix()+'" "'+(cpp/'tests/host/stubs').as_posix()+'")\n'
        project+='target_compile_definitions('+target+' PRIVATE AMCL_INPUT_HOST_EXPORTS AMCL_CONTROL_DELIVERY_HOST_TESTING _CRT_SECURE_NO_WARNINGS)\n'
        project+='if(MSVC)\n target_compile_options('+target+' PRIVATE /utf-8)\nelse()\n target_link_libraries('+target+' PRIVATE dl pthread)\nendif()\n'
        if not test:project+='set_source_files_properties("'+bridge.as_posix()+'" PROPERTIES LANGUAGE CXX)\ntarget_compile_definitions('+target+' PRIVATE AMCL_INPUT_BRIDGE_HOST_TESTING EVENT_WINDOW_SIZE=8)\n'
        # 仅transport逐字产品callback开关；Owner/算法不改，ON/OFF都执行相同真实输出/重入/压力场景。
        if not test:project+='target_compile_definitions('+target+' PRIVATE AMCL_INPUT_TRACE='+('1' if options.trace=='on' else '0')+')\n'
        # 固定表故障/生命周期机制是永久正常look门的一项。它明确单独编ON，不以它冒称
        # OFF产品含诊断；实际OFF裁剪仍由transport/双映像原编译分支和对象审计承接。
        if target=='latency':project+='target_compile_definitions(latency PRIVATE AMCL_INPUT_TRACE=1 AMCL_INPUT_LATENCY_HOST_TESTING AMCL_INPUT_LATENCY_SAMPLE_INTERVAL=1)\n'
        if target=='native_touch':project+='target_compile_definitions(native_touch PRIVATE NOMINMAX AMCL_DESKTOP_EVENT_BRIDGE=1)\n'
        if target=='physical':project+='target_compile_definitions(physical PRIVATE AMCL_GLFW_TYPED_PHYSICAL_DEFAULT=1 AMCL_GLFW_RAW_RELATIVE_VERIFIED=1 AMCL_GLFW_API26_RAW_MOUSE_MOTION=1 AMCL_GATE0_EVIDENCE_IDS="host-typed-look-fixture")\n'
    (build/'CMakeLists.txt').write_text(project,encoding='utf-8')
    if os.name=='nt' and options.target=='all':
        # 使用两份真正生产owner DLL证明混映像不能仅凭PID/合法代码取得另一个Core状态。
        for library in ['look_owner_a','look_owner_b']:
            project+='add_library('+library+' SHARED '+' '.join('"'+p.as_posix()+'"' for p in sources)+')\n'
            project+='target_compile_features('+library+' PRIVATE cxx_std_17)\ntarget_compile_options('+library+' PRIVATE /utf-8)\n'
            project+='target_include_directories('+library+' PRIVATE "'+(cpp/'tests/host/stubs').as_posix()+'")\n'
            project+='target_compile_definitions('+library+' PRIVATE AMCL_INPUT_HOST_EXPORTS _CRT_SECURE_NO_WARNINGS)\n'
        project+='add_executable(identity "'+(cpp/'tests/host/look_execution_identity_test.cpp').as_posix()+'")\n'
        project+='target_compile_features(identity PRIVATE cxx_std_17)\ntarget_compile_options(identity PRIVATE /utf-8)\n'
        (build/'CMakeLists.txt').write_text(project,encoding='utf-8')
    cmake=find_host_cmake(options.cmake)
    # 真编译前后冻结所有实际TU及逐字提取源；外置负控变体另以generated SHA登记，不借
    # 源码HEAD或测试名称代替编译材料。这个检查只报告漂移，不自动重建/修改产品。
    frozenInputs=compiledInputs|{*sources,cpp/'platform/touch_input.cpp',cpp/'glfw/glfw_compat.cpp',Path(__file__),
        cpp/'tests/host/look_transport_test.cpp.in',cpp/'input/delivery/look_transport.h',
        cpp/'input/delivery/look_execution_client.h',cpp/'input/delivery/control_delivery_client.h'}
    if native_fixture is not None:frozenInputs.update({ROOT/'scripts/test-touch-production.py',ROOT/'scripts/test-control-schema-lifecycle.py',
        cpp/'tests/host/native_schema_look_test.cpp.in'})
    if clock_fixture is not None:frozenInputs.add(cpp/'tests/host/look_clock_test.cpp.in')
    beforeHashes={str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in frozenInputs}
    configure_host_cmake(cmake,build,build/'build')
    if build_visible(cmake,build/'build',output/'compile.log'):raise RuntimeError('actual owner compile failed')
    receipts=[]
    for target,_ in targets:
        binary=build/'build'/('Release/'+target+'.exe' if os.name=='nt' else target)
        try:run=subprocess.run([str(binary)],capture_output=True,timeout=10)
        except subprocess.TimeoutExpired as failure:
            (output/(target+'.timeout.log')).write_bytes((failure.stdout or b'')+(failure.stderr or b''))
            print(((failure.stdout or b'')+(failure.stderr or b'')).decode(errors='replace'),flush=True)
            raise
        (output/(target+'.log')).write_bytes(run.stdout+run.stderr)
        print((run.stdout+run.stderr).decode(errors='replace'),flush=True)
        receipts.append({'target':target,'exitCode':run.returncode})
        if target in ('transport','clock'):
            # OFF必须由真实编译裁剪产品日志正文；ON必须含逐字产品callback的日志。
            # fixture logger只是格式边缘，不能替代这项实际二进制检查。
            markerPresent=b'AMCL_LOOK_GLFW' in binary.read_bytes()
            assert markerPresent==(options.trace=='on'),'actual transport trace compile branch mismatch'
            receipts[-1].update({'binarySha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'traceMarkerPresent':markerPresent})
        if target=='clock' and options.negative=='idle-clock':
            assert run.returncode!=0 and b'LOOK TRANSPORT FAIL' in run.stderr and b'queuedAccepted==AMCL_LOOK_PREFIX_READY' in run.stderr,'idle-clock negative must compile and reject the original legal delayed SDK sample'
        elif target=='native_touch' and options.negative:
            expected=b'window.cursorX==200&&window.cursorY==100&&cursorCallbacks==2' if options.negative=='normal-up-retire' else b'window.cursorX==cachedX&&window.cursorY==cachedY'
            assert run.returncode!=0 and b'NATIVE LOOK VERTICAL FAIL' in run.stderr and expected in run.stderr,'native negative must compile and hit original vertical behavior assertion'
        elif target=='transport' and options.negative:
            assert run.returncode!=0 and b'LOOK TRANSPORT FAIL' in run.stderr,'negative must fail actual behavior, not linkage/timeout'
        elif run.returncode:raise RuntimeError('actual owner behavior failed '+target)
    if os.name=='nt' and options.target=='all':
        run=subprocess.run([str(build/'build/Release/identity.exe'),str(build/'build/Release/look_owner_a.dll'),
            str(build/'build/Release/look_owner_b.dll')],capture_output=True,timeout=30)
        (output/'identity.log').write_bytes(run.stdout+run.stderr);print((run.stdout+run.stderr).decode(errors='replace'),flush=True)
        receipts.append({'target':'identity','exitCode':run.returncode})
        if run.returncode:raise RuntimeError('actual DLL identity failed')
    identities={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [*sources,
        cpp/'glfw/glfw_compat.cpp',cpp/'glfw/input_bridge_ohos.c',cpp/'input/delivery/look_execution.h',cpp/'input/delivery/look_execution_client.h',
        cpp/'tests/host/look_transport_test.cpp.in',Path(__file__),cpp/'platform/touch_input.cpp',cpp/'platform/source_look_producer.cpp']}
    if native_fixture is not None:
        for relative in ['scripts/test-touch-production.py','scripts/test-control-schema-lifecycle.py','entry/src/main/cpp/tests/host/native_schema_look_test.cpp.in']:
            identities[relative]=hashlib.sha256((ROOT/relative).read_bytes()).hexdigest()
    if clock_fixture is not None:identities['entry/src/main/cpp/tests/host/look_clock_test.cpp.in']=hashlib.sha256((cpp/'tests/host/look_clock_test.cpp.in').read_bytes()).hexdigest()
    afterHashes={str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in frozenInputs}
    assert beforeHashes==afterHashes,'actual compiled source drift'
    layer='real Native schema/apply/flush + Source/Core/math/ring/GLFW; controlled deadline scheduling boundary; no OS thread/event or game tick claim' if native_fixture is not None else 'real Source/Core/owner/bridge+literal GLFW callback; delayed SDK timestamp host cases, no device/game claim' if options.target=='clock' else 'real neutral/Core/control/bridge+product callback function body+actual DLL identities; no game camera claim'
    (output/'receipt.json').write_text(json.dumps({'target':options.target,'negative':options.negative,'trace':options.trace,'results':receipts,'sources':identities,
        'compileSourceBefore':beforeHashes,'compileSourceAfter':afterHashes,'sourceDrift':[],
        # Windows write_text按文本规则生成CRLF；制品身份必须取实际落盘字节，不能把
        # 内存LF字符串的摘要冒称文件SHA。另列canonical LF只供跨平台配方比较。
        'generatedNativeSha256':hashlib.sha256((build/'native_touch.cpp').read_bytes()).hexdigest() if native_fixture is not None else None,
        'generatedNativeCanonicalLfSha256':hashlib.sha256(native_fixture.encode('utf-8')).hexdigest() if native_fixture is not None else None,
        'generatedClockSha256':hashlib.sha256((build/'clock.cpp').read_bytes()).hexdigest() if clock_fixture is not None else None,
        'generatedClockOwnerSha256':hashlib.sha256(clock_owner.read_bytes()).hexdigest() if clock_owner is not None else None,
        'layer':layer},indent=2)+'\n',encoding='utf-8')
    if os.name=='nt' and options.target=='all':run_two_image(options,output/'two-image',build/'two-image',cpp,sources,callback)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--build-out',type=Path,required=True)
    parser.add_argument('--cmake')
    parser.add_argument('--two-image-only',action='store_true',help='只编真实双DLL bridge/callback，不替代正常owner回归')
    parser.add_argument('--image-negative',choices=['registration','getter','replay','retirement','resume','tail-length','tail-version'],help='仅生成树撤实际跨image接缝，必须编译并命中真实行为断言')
    parser.add_argument('--image-contract',choices=['short','version'],help='真实owner只公告短尾部或未知版本，delegate必须NotReady')
    parser.add_argument('--negative',choices=['cache','pressure','trace-budget','normal-up-retire','cancel-keep','idle-clock'])
    parser.add_argument('--target',choices=['all','native-touch','clock'],default='all',help='缺省完整look矩阵；native-touch只跑真实schema纵向，clock只跑真实SDK采样/idle时钟组')
    parser.add_argument('--trace',choices=['on','off'],default='off',help='实际GLFW产品callback的AMCL_INPUT_TRACE编译分支；缺省仍关闭')
    parser.add_argument('--diag-owner',choices=['on','off','short','version','null'],default='on',help='仅诊断能力缺席仍保原look/输入')
    parser.add_argument('--diag-negative',choices=['order'],help='成功编译后撤回两种原order关联的承重反控')
    options=parser.parse_args()
    if (options.image_negative or options.image_contract) and not options.two_image_only:parser.error('image反例必须指定--two-image-only')
    if options.image_negative=='tail-length' and options.image_contract!='short':parser.error('tail-length负控需short owner')
    if options.image_negative=='tail-version' and options.image_contract!='version':parser.error('tail-version负控需version owner')
    if options.negative in ('normal-up-retire','cancel-keep') and options.target!='native-touch':parser.error('Native终点负控需--target native-touch')
    if options.target=='native-touch' and options.negative not in (None,'normal-up-retire','cancel-keep'):parser.error('native-touch只接受normal-up-retire/cancel-keep终点负控')
    if options.negative=='idle-clock' and options.target!='clock':parser.error('idle-clock负控需--target clock')
    if options.target=='clock' and options.negative not in (None,'idle-clock'):parser.error('clock只接受idle-clock采样时钟负控')
    main(options)
