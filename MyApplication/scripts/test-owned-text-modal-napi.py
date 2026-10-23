"""真实NAPI→owned文本core→native external ledger→bridge的模态组合与运行时负对照。"""
from pathlib import Path
import argparse
import os
import re
import subprocess
import sys
import hashlib
import json
from datetime import datetime
sys.dont_write_bytecode = True
from lib.workspace_paths import external_output_path, workspace_path
from lib.host_cpp import find_host_cmake, configure_host_cmake

root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output',help='仓库外证据目录；缺省自动外置')
parser.add_argument('--cmake',help='宿主CMake；缺省寻找原生工具')
args=parser.parse_args()
output=external_output_path(args.output) if args.output else workspace_path('run','owned-text-modal')
output.mkdir(parents=True,exist_ok=True)
started=datetime.now().astimezone().isoformat()
checks=[]
build_root=workspace_path('build','owned-text-modal');build=build_root/'build'
configure_source=build_root/'fixture';configure_source.mkdir(parents=True,exist_ok=True)
cmake_tool=find_host_cmake(args.cmake);cpp=root/'entry/src/main/cpp'
native=(cpp/'platform/touch_input.cpp').read_text(encoding='utf-8')
napi=(cpp/'napi/napi_input.cpp').read_text(encoding='utf-8')
def definition(source,signature):
    """逐字取真正函数体，平台参数替身不复制生产路由、模态或lease判据。"""
    start=re.search(re.escape(signature)+r'[^;{]*\{',source)
    assert start,signature
    position=start.end()-1;depth=0
    for end in range(position,len(source)):
        if source[end]=='{':depth+=1
        elif source[end]=='}':
            depth-=1
            if depth==0:return source[start.start():end+1]
    raise AssertionError(signature)
prefix=f'''
#define main inheritedTextOrderMain
#include "{(cpp/'tests/host/platform_input_text_key_order_test.cpp').as_posix()}"
#undef main
#include "{(cpp/'platform/touch_publication_state.h').as_posix()}"
#include "{(cpp/'platform/external_held_edge_router.h').as_posix()}"
#include "{(cpp/'platform/legacy_output_code.h').as_posix()}"
#include "{(cpp/'input/input_trace.h').as_posix()}"
#include "{(cpp/'input/delivery/look_transport.h').as_posix()}"
#include "{(cpp/'platform/source_control_client.h').as_posix()}"
#include <memory>
'''+r'''
using namespace amcl::input;
constexpr int GLFW_PRESS=1,GLFW_RELEASE=0,GLFW_REPEAT=2,napi_ok=0;
void inputBridge_pushEvent(int,int,int,int,int);
void inputBridge_setKeyCallback(void(*)(void*,int,int,int,int));
void inputBridgeStartPumping();void inputBridgePumpEvents(void*);void inputBridgeStopPumping();
void inputBridge_glfwSetActive(void*,int);void inputBridge_glfwSetTargetV1(uint64_t,uint64_t,uint64_t);
extern "C" int inputBridge_configureMenuCursorConsumerV1(int,uint64_t);int inputBridge_setInputReady(int);
std::vector<int>legacyKeys;
void legacyKeyCallback(void*,int key,int,int action,int){if(key==259)legacyKeys.push_back(action);}
void pumpLegacy(){inputBridgeStartPumping();inputBridgePumpEvents(reinterpret_cast<void*>(1));inputBridgeStopPumping();}
// SDK只替换值读取与返回对象，支持真实argc和有符号/无符号参数边界。
struct Value{int64_t n;};using napi_value=Value*;using napi_env=void*;
struct Call{std::vector<Value>values;};using napi_callback_info=Call*;
std::vector<std::unique_ptr<Value>>results;
int napi_get_cb_info(napi_env,napi_callback_info info,size_t*count,napi_value*out,void*,void*){
 size_t copied=std::min(*count,info->values.size());for(size_t i=0;i<copied;i++)out[i]=&info->values[i];*count=copied;return napi_ok;}
int napi_get_value_int32(napi_env,napi_value v,int32_t*out){if(!v||v->n<INT32_MIN||v->n>INT32_MAX)return 1;*out=static_cast<int32_t>(v->n);return napi_ok;}
int napi_get_value_uint32(napi_env,napi_value v,uint32_t*out){if(!v||v->n<0||v->n>UINT32_MAX)return 1;*out=static_cast<uint32_t>(v->n);return napi_ok;}
int napi_get_value_int64(napi_env,napi_value v,int64_t*out){if(!v)return 1;*out=v->n;return napi_ok;}
namespace amcl::napi{
napi_value MakeIntResult(napi_env,int value){results.emplace_back(new Value{value});return results.back().get();}
napi_value MakeBoolResult(napi_env env,bool value){return MakeIntResult(env,value?1:0);}}
TouchPublicationState publication;
namespace amcl::input {
class SurfaceInputGateTransaction{public:explicit operator bool()const{return true;}};
TouchPublicationReceipt QueryTouchPublication(){TouchPublicationContext context;context.surface=22;
 context.session=PlatformInputResetDomains().touch;context.policy=1;context.schema=1;return publication.Query(context);}
}
// 来源权威已经迁入neutral；测试不再自行建Registry/Ledger/owner计数模拟旧实现。
// 下方逐字带入生产thin proxy与真实Port，断言使用SourceSnapshot复制的当前事实。
std::recursive_mutex s_inputTransactionMutex;
void reconcileLegacyRingDiscontinuity(){}void resolveBridge(){}bool bridgeReady(){return true;}
'''
production='\n'.join(definition(native,name) for name in ['static AmclInputSource normalizeInputSource(',
 'static OwnerToken nextOwnerToken(', 'static amcl::input::SourcePhysicalProxy& physicalEdgeRouter(',
 'static amcl::input::SourceExternalProxy& externalHeldEdgeRouter(',
 'static bool externalHeldActionFromGlfw(', 'static bool routerKey(', 'extern "C" bool ohos_send_source_key_event_checked('])
production+='\n// 原测试读held，只观察已准入source值快照，不建第二生产账本。\nSourceLedgerProxy ledger;\n'
production+='\n'+'\n'.join(definition(napi,name) for name in ['static bool ReadInputSourceArg(',
 'bool TouchSourceAdmission(', 'napi_value SendSourceKeyEvent(', 'napi_value TextInputKeyTap('])
production+=r'''
int callSource(int source,int key,int action){Call c{{{source},{key},{0},{action},{0}}};return SendSourceKeyEvent(nullptr,&c)->n;}
int callOwned(int64_t session,uint32_t code,int key){Call c{{{session},{code},{key}}};return TextInputKeyTap(nullptr,&c)->n;}
'''
template=(cpp/'tests/host/owned_text_modal_napi.cpp.in').read_text(encoding='utf-8')
candidate=output/'owned.cpp'
sources=['input/platform_input_ingress.cpp','input/input_shadow_consumer.cpp','input/input_trace.cpp',
 'input/delivery/look_execution.cpp','input/delivery/control_delivery.cpp',
 'input/source/source_control.cpp','platform/legacy_output_runtime.cpp','platform/legacy_physical_edge_router.cpp',
 'input/amcl_input_host_descriptor.cpp',
 'input/input_state_core.cpp','input/adapters/glfw_input_adapter.cpp','input/adapters/backend_input_bridge.cpp',
 'input/adapters/backend_keymaps.cpp','input/adapters/lwjgl2_event_translate.cpp','input/input_interaction_order.cpp',
 'platform/physical_wheel_quantizer.cpp','platform/source_look_processor.cpp','platform/look_delta_math.cpp',
 'platform/look_pipeline_stats.cpp','platform/input_source.cpp','platform/input_ledger.cpp',
 'platform/external_held_registry.cpp','platform/external_held_edge_router.cpp','glfw/input_bridge_ohos.c']
identity_paths=[cpp/name for name in sources]+[cpp/'platform/touch_input.cpp',cpp/'napi/napi_input.cpp',
 cpp/'platform/source_control_client.h',cpp/'input/source/source_control.h',cpp/'input/source/source_control_client.h',
 cpp/'tests/host/owned_text_modal_napi.cpp.in',cpp/'tests/host/platform_input_text_key_order_test.cpp',
 cpp/'input/input_state_core.h',cpp/'input/input_text_core_hook.h']
source_before={str(path.relative_to(root)):hashlib.sha256(path.read_bytes()).hexdigest() for path in identity_paths}
paths='\n'.join(' "'+(cpp/name).as_posix()+'"' for name in sources)
typed_candidate=configure_source/'typed-order.cpp'
typed_candidate.write_text(f'''// 原测试全部正文保留，唯一差异是执行真实预线程owner发布而非descriptor替身。
#define main originalTypedTextOrderMain
#include "{(cpp/'tests/host/platform_input_text_key_order_test.cpp').as_posix()}"
#undef main
#include "{(cpp/'input/source/source_control.h').as_posix()}"
int main(){{SelectRoute();const auto* api=amclInputGetHostApiV1();
 CHECK(amclInputHostDescriptorPublishV1(api)==0);amclSourceControlPublishV1();CHECK(amclSourceControlPrepareV1()==1);
 return originalTypedTextOrderMain();}}
''',encoding='utf-8')
cmake=f'''cmake_minimum_required(VERSION 3.16)
project(owned_text_modal LANGUAGES CXX)
find_package(Threads REQUIRED)
set_source_files_properties("{(cpp/'glfw/input_bridge_ohos.c').as_posix()}" PROPERTIES LANGUAGE CXX)
# 本组合使用真实backend transport。bridge不能继承供可编程stub使用的同名宏，
# 否则会调用本目标根本未链接的stub路由；这里只保留正常Core capability读取。
if(MSVC)
 set_property(SOURCE "{(cpp/'glfw/input_bridge_ohos.c').as_posix()}" APPEND PROPERTY COMPILE_OPTIONS /UAMCL_CONTROL_DELIVERY_HOST_TESTING)
else()
 set_property(SOURCE "{(cpp/'glfw/input_bridge_ohos.c').as_posix()}" APPEND PROPERTY COMPILE_OPTIONS -UAMCL_CONTROL_DELIVERY_HOST_TESTING)
endif()
add_executable(owned "{candidate.as_posix()}" {paths})
target_compile_features(owned PRIVATE cxx_std_17)
# legacy和typed两个真实owner进程均须向descriptor提供动态getter，Linux不能借本地假解析。
set_target_properties(owned PROPERTIES ENABLE_EXPORTS ON)
target_link_libraries(owned PRIVATE Threads::Threads ${{CMAKE_DL_LIBS}})
# 宿主将真实owner链接进EXE，显式采用既有host契约；PID、getter和函数同映像校验仍全部执行。
target_compile_definitions(owned PRIVATE AMCL_INPUT_HOST_EXPORTS AMCL_INPUT_SHADOW=0 AMCL_TEXT_KEY_ORDER_TYPED=0 AMCL_TEXT_ORDER_REAL_DESCRIPTOR=1 AMCL_INPUT_BRIDGE_HOST_TESTING AMCL_CONTROL_DELIVERY_HOST_TESTING _CRT_SECURE_NO_WARNINGS NOMINMAX)
target_include_directories(owned PRIVATE "{cpp.as_posix()}" "{(cpp/'platform').as_posix()}" "{(cpp/'input').as_posix()}" "{(cpp/'tests/host/stubs').as_posix()}")
if(MSVC)
 target_compile_options(owned PRIVATE /utf-8)
endif()
# 原typed编辑键正文仍走Core submitBatch；本轮legacy Source修复不能把该分支改成ring。
# 独立进程锁存typed选择，完整旧whitelist/ordered文字/压力/reset前提一并保留。
add_executable(typed_text_order "{typed_candidate.as_posix()}" {paths})
target_compile_features(typed_text_order PRIVATE cxx_std_17)
set_target_properties(typed_text_order PROPERTIES ENABLE_EXPORTS ON)
target_link_libraries(typed_text_order PRIVATE Threads::Threads ${{CMAKE_DL_LIBS}})
target_compile_definitions(typed_text_order PRIVATE AMCL_INPUT_HOST_EXPORTS AMCL_INPUT_SHADOW=0 AMCL_TEXT_KEY_ORDER_TYPED=1 AMCL_TEXT_ORDER_REAL_DESCRIPTOR=1 AMCL_INPUT_BRIDGE_HOST_TESTING AMCL_CONTROL_DELIVERY_HOST_TESTING _CRT_SECURE_NO_WARNINGS NOMINMAX)
target_include_directories(typed_text_order PRIVATE "{cpp.as_posix()}" "{(cpp/'platform').as_posix()}" "{(cpp/'input').as_posix()}" "{(cpp/'tests/host/stubs').as_posix()}")
if(MSVC)
 target_compile_options(typed_text_order PRIVATE /utf-8)
endif()
'''
(configure_source/'CMakeLists.txt').write_text(cmake,encoding='utf-8')
(output/'CMakeLists.txt').write_text(cmake,encoding='utf-8')
candidate.write_text(template.replace('@FIXTURE@',prefix+production),encoding='utf-8')
configure_host_cmake(cmake_tool,configure_source,build)
def check(name,body,negative=False):
    candidate.write_text(template.replace('@FIXTURE@',prefix+body),encoding='utf-8')
    subprocess.run([cmake_tool,'--build',str(build),'--config','Release','--target','owned'],check=True)
    binary=build/'Release'/'owned.exe' if os.name=='nt' else build/'owned'
    result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=30)
    (output/(name+'.log')).write_text(result.stdout+result.stderr,encoding='utf-8')
    checks.append({'name':name,'negative':negative,'exitCode':result.returncode})
    if negative:
        assert result.returncode!=0 and 'TEXT KEY ORDER FAIL' in result.stderr,result.stdout+result.stderr
        print('PASS negative control: '+name+' -> '+result.stderr.strip())
    else:
        assert result.returncode==0,result.stdout+result.stderr
        print(result.stdout.strip())
check('positive',production)
for name,before,after in [
 ('generic-touch-ignores-modal','state.modalCount == 0','true'),
 ('owned-key-ignores-lease','amcl::input::PlatformInputOwnedTextSessionMatches(static_cast<uint64_t>(generation))','true'),
 # 新 NAPI 等待前冻结原 Keyboard scope；只适配反控锚，仍恢复原匿名 DOWN/UP 并执行原行为断言。
 ('owned-key-restores-anonymous-pair',
  'const bool accepted = (originalText.textSession == static_cast<uint64_t>(generation) && amcl::input::SourceOwnedTextKeyTap(originalText, glfwKey, originalKeyboardScope));',
  'const bool pressed=ohos_send_source_key_event_checked(1,glfwKey,0,1,0);const bool released=pressed&&ohos_send_source_key_event_checked(1,glfwKey,0,0,0);const bool accepted=pressed&&released;')]:
    assert production.count(before)==1,name
    check(name,production.replace(before,after,1),negative=True)
check('restored-production',production)
subprocess.run([cmake_tool,'--build',str(build),'--config','Release','--target','typed_text_order'],check=True)
typed_binary=build/'Release'/'typed_text_order.exe' if os.name=='nt' else build/'typed_text_order'
typed_result=subprocess.run([str(typed_binary)],capture_output=True,text=True,timeout=30)
(output/'typed-route-original.log').write_text(typed_result.stdout+typed_result.stderr,encoding='utf-8')
checks.append({'name':'typed-route-original','negative':False,'exitCode':typed_result.returncode})
assert typed_result.returncode==0,typed_result.stdout+typed_result.stderr
print(typed_result.stdout.strip())
after={str(path.relative_to(root)):hashlib.sha256(path.read_bytes()).hexdigest() for path in identity_paths}
drift=[name for name in source_before if source_before[name]!=after[name]]
(output/'receipt.json').write_text(json.dumps({'startedAt':started,'finishedAt':datetime.now().astimezone().isoformat(),
 'checks':checks,'sourcesBefore':source_before,'sourcesAfter':after,'sourceDrift':drift,
 'boundary':'actual NAPI bodies/Core/Source port/registry/bridge; SDK values and Surface facts explicit host boundary; no device claim'},indent=2)+'\n',encoding='utf-8')
if drift:raise RuntimeError('source changed during actual owned-text compile: '+', '.join(drift))
