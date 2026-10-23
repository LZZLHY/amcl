"""实际owner整表/reader与GLFW getter/resolve caller，连接真实Native当前context。

消费cache必须只合并同identity的显示元数据，不越过排队的新geometry；缺cache仅真实legacy
或textOnly可借owner基线。独占外置构建保留完整生产TU和行为收据，撤回负控必须实编后CHECK失败。
"""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import os
import subprocess
import uuid
from lib.host_cpp import find_host_cmake, configure_host_cmake
from lib.workspace_paths import external_output_path, workspace_path
ROOT=Path(__file__).resolve().parents[1];CPP=ROOT/'entry/src/main/cpp'

def main():
    """SDK仅替换resolver/adapter等端口；table、caller、getter、Core全来自现役源码。"""
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--cmake');parser.add_argument('--output');parser.add_argument('--build-dir');args=parser.parse_args()
    leaf='run-'+str(os.getpid())+'-'+uuid.uuid4().hex[:8]
    build=(external_output_path(args.build_dir) if args.build_dir else workspace_path('build','input-surface-reader'))/leaf
    output=(external_output_path(args.output) if args.output else workspace_path('run','input-surface-reader'))/leaf
    project=build/'source';project.mkdir(parents=True,exist_ok=False);output.mkdir(parents=True,exist_ok=False)
    spec=importlib.util.spec_from_file_location('surface_reader_extract',ROOT/'scripts/generate-desktop-review-tests.py')
    recipe=importlib.util.module_from_spec(spec);spec.loader.exec_module(recipe)
    bridge=(CPP/'glfw/input_bridge_ohos.c').read_text(encoding='utf-8');compat=(CPP/'glfw/glfw_compat.cpp').read_text(encoding='utf-8')
    adapter=(CPP/'input/adapters/glfw_input_adapter.h').read_text(encoding='utf-8')
    start=bridge.index('typedef struct InputBridgeInstanceV1 {');table=bridge[start:bridge.index('} InputBridgeInstanceV1;',start)+len('} InputBridgeInstanceV1;')]
    start=bridge.index('#define INPUT_BRIDGE_OWNER_HAS_TAIL');macro=bridge[start:bridge.index('\n\n',start)]
    types='\n'.join(recipe.block(adapter,adapter.index(signature))+';' for signature in ['enum class GlfwAdapterStatus','struct GlfwSurfaceContextSinkEvent'])
    # 完整 owner 表已追加真实 look 私有尾；带入生产类型声明，不能截短表或仿造类型掩盖缺闭包。
    parts={'@PRODUCED_TYPES@':types,'@OWNER_TABLE@':'#include "delivery/look_transport.h"\n'+table,'@TAIL_MACRO@':macro,
      '@BRIDGE_READER@':recipe.block(bridge,bridge.index('JNIEXPORT int inputBridge_readSurfaceContextV1(')),
      '@GETTERS@':'\n'.join(recipe.function(compat,n) for n in ['glfwOHOS_ReadInputSurfaceContext','glfwOHOS_ClearInputSurfaceContext','typedSurfaceContextSink']),
      '@CALLER@':recipe.function(compat,'typedInputAdapterHasConsumer')+'\n'+
        recipe.block(compat,compat.index('static int32_t typedInputAdapterClose('))+'\n'+recipe.function(compat,'ensureTypedInputOpen')}
    template=(CPP/'tests/host/input_surface_reader.cpp.in').read_text(encoding='utf-8')
    unit=template
    for marker,value in parts.items():unit=unit.replace(marker,value)
    candidate=project/'reader.cpp';candidate.write_text(unit,encoding='utf-8',newline='\n')
    names=['platform_input_ingress.cpp','input_shadow_consumer.cpp','input_trace.cpp','input_state_core.cpp','input_interaction_order.cpp']
    for name in names:(project/name).write_bytes((CPP/'input'/name).read_bytes())
    paths=' '.join('"'+(project/n).as_posix()+'"' for n in names)
    # reader 仍逐字使用完整 Core；新增强依赖只连真实 L2 mapper，不改变 owner/read/cutoff 判据。
    paths+=' "'+(CPP/'input/adapters/backend_keymaps.cpp').as_posix()+'"'
    cmake_text='''cmake_minimum_required(VERSION 3.16)
project(input_surface_reader LANGUAGES CXX)
add_executable(reader reader.cpp %s)
target_include_directories(reader PRIVATE "%s" "%s")
target_compile_features(reader PRIVATE cxx_std_17)
target_compile_definitions(reader PRIVATE AMCL_INPUT_HOST_EXPORTS AMCL_INPUT_HOST_TESTING AMCL_INPUT_SHADOW=1 AMCL_INPUT_QUEUE_CAPACITY=64 AMCL_INPUT_BLOB_POOL_CAPACITY=256)
if(MSVC)
 target_compile_options(reader PRIVATE /utf-8)
 target_compile_definitions(reader PRIVATE _CRT_SECURE_NO_WARNINGS)
endif()
'''%(paths,(CPP/'input').as_posix(),(CPP/'tests/host/stubs').as_posix())
    (project/'CMakeLists.txt').write_text(cmake_text,encoding='utf-8',newline='\n')
    cmake=find_host_cmake(args.cmake);configure_host_cmake(cmake,project,build/'native')
    binary=build/'native'/('Debug/reader.exe' if os.name=='nt' else 'reader')
    def run(body,label,negative=False):
        candidate.write_text(body,encoding='utf-8',newline='\n')
        subprocess.run([cmake,'--build',str(build/'native'),'--config','Debug','--parallel','2'],check=True)
        result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=30)
        (output/(label+'.cpp')).write_text(body,encoding='utf-8');(output/(label+'.log')).write_text(result.stdout+result.stderr,encoding='utf-8')
        if negative:
            if result.returncode==0 or 'READER CHECK' not in result.stderr:raise AssertionError('Behavioral negative required: '+label+'\n'+result.stdout+result.stderr)
        elif result.returncode!=0:raise AssertionError(result.stdout+result.stderr)
        else:print(result.stdout,end='')
    run(unit,'positive')
    mutations=[
      ('stale-metadata','outContext->refreshRateHz = fresh.refreshRateHz;','(void)fresh;'),
      ('queued-geometry-stolen','if (hasFresh && amcl::input::SameInputSurfaceContextIdentity(*outContext, fresh)) {','if (hasFresh) { *outContext = fresh;'),
      ('typed-cold-baseline','hasFresh && g_inputSurfaceOwnerBaselineAllowed.load(std::memory_order_acquire)','hasFresh'),
      ('missing-tail-local-core','? owner->readSurfaceContext(outContext) : 0;','? owner->readSurfaceContext(outContext) : amcl_input_owner_read_surface_context(outContext);'),
    ]
    for name,before,after in mutations:
        if unit.count(before)!=1:raise ValueError('Unique production mutation anchor required: '+name)
        run(unit.replace(before,after),name,True);print('PASS compiled behavioral negative '+name)
    tracked=['glfw/input_bridge_ohos.c','glfw/glfw_compat.cpp','input/input_surface_context_snapshot.h','input/input_surface_context_semantics.h',
      'input/input_state_core.h','input/delivery/look_transport.h','input/delivery/look_execution.h','input/adapters/backend_keymaps.cpp','input/adapters/glfw_typed_input_resolve_guard.h','input/adapters/glfw_input_adapter.h',*['input/'+n for n in names]]
    receipt={'scope':'host actual owner/Core/GLFW reader/caller; no SDK/device claim',
      'sources':{n:hashlib.sha256((CPP/n).read_bytes()).hexdigest() for n in tracked},'negatives':[n for n,_,_ in mutations]}
    (output/'evidence.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('PASS input surface reader source-bound evidence='+str(output))

if __name__=='__main__':main()
