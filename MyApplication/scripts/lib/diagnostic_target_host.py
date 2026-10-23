"""以真实CMake target policy编译逐字GLFW callback对象，验证宏而非仅mask。

这个窄宿主目标不链接/运行输入owner，不提供假的Source/consumer ABI。只有平台窗口
载体与函数声明；对象中未解析的生产依赖保留。因此它证明编译裁剪，不证明输入交付。
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from .host_cpp import find_host_cmake, configure_host_cmake
from .workspace_paths import external_output_path


def main(options):
    root=Path(__file__).resolve().parents[2]
    cpp=root/'entry/src/main/cpp'
    output=external_output_path(options.out);build=external_output_path(options.build_out)
    output.mkdir(parents=True,exist_ok=False);build.mkdir(parents=True,exist_ok=False)
    temp=build/'temp';temp.mkdir();os.environ['TEMP']=str(temp);os.environ['TMP']=str(temp)
    policy=cpp/'cmake/ProductDiagnostics.cmake'
    originalPolicyHash=hashlib.sha256(policy.read_bytes()).hexdigest()
    text=policy.read_text(encoding='utf-8')
    needle='target_compile_definitions(${target} PRIVATE AMCL_INPUT_TRACE=$<BOOL:${AMCL_INPUT_TRACE}>)'
    assert text.count(needle)==1
    if options.remove_define:
        # 唯一编译负控：原mask/config不动，撤CMake→C++宏。副本引用原模板/日志头，
        # 不改原产品文件，也不把漏宏导致的编译失败当行为识别成功。
        text=text.replace(needle,'# 负控：保mask但撤target宏。',1)
        text=text.replace('${CMAKE_CURRENT_LIST_DIR}',(cpp/'cmake').as_posix())
        policy=build/'negative-policy.cmake';policy.write_text(text,encoding='utf-8')
    glfwPath=cpp/'glfw/glfw_compat.cpp'
    originalGlfwHash=hashlib.sha256(glfwPath.read_bytes()).hexdigest()
    # TRACE ON的生产callback已经使用原私有延迟POD和bridge声明；对象探针也须读取
    # 同一头，不能删观察调用或手写替身声明来通过编译。目标仍只编OBJECT，不链接
    # collector/owner、不执行输入，因此只绑定这个必要声明输入的原字节身份。
    latencyHeader=cpp/'input/input_latency_observation.h'
    originalLatencyHeaderHash=hashlib.sha256(latencyHeader.read_bytes()).hexdigest()
    glfw=glfwPath.read_text(encoding='utf-8')
    start=glfw.index('static int bridgeLookPrefixCallback(');end=glfw.index('{',start)+1;depth=1
    while depth:
        if glfw[end]=='{':depth+=1
        elif glfw[end]=='}':depth-=1
        end+=1
    body=glfw[start:end]
    # 真实callback已沿现役跨DSO resolver取得look owner；对象测试也引入同一私有
    # client头及其control解析依赖，只编译真实inline正文，不造替身resolver或运行owner。
    fixture='''#include "input/adapters/glfw_source_plane_aggregate.h"
#include "input/delivery/look_execution_client.h"
#include "input/input_latency_observation.h"
#include <atomic>
#include <climits>
#include <cmath>
struct GLFWwindow { uint64_t windowId;double cursorX,cursorY;void(*cursorPosCb)(GLFWwindow*,double,double); };
GLFWwindow* g_currentWindow=nullptr;
static amcl::input::GlfwSourcePlaneAggregate g_sourcePlaneAggregate;
void amclExternalLogWrite(int,const char*,const char*,...);
#define LOG_TAG "GLFW_COMPAT"
'''+body+'''
// 对外保留实际函数地址，避免宿主优化删除未调用的static生产body；只编译对象，不运行。
extern "C" int (*amclHostDiagnosticCallback)(void*,uint64_t)=bridgeLookPrefixCallback;
#if AMCL_INPUT_TRACE
extern "C" const char* amclHostObservedTraceMacro="AMCL_INPUT_TRACE_VALUE_1";
#else
extern "C" const char* amclHostObservedTraceMacro="AMCL_INPUT_TRACE_VALUE_0";
#endif
'''
    (build/'probe.cpp').write_text(fixture,encoding='utf-8',newline='\n')
    # 原产品强制include使用Clang的-include；Windows原生MSVC宿主仅把同一头翻译
    # 成/FI，并忽略其不支持的GNU visibility语法。宏定义及真实policy不作替身。
    adapter=build/'msvc-preinclude.h'
    adapter.write_text('#pragma once\n#ifndef __clang__\n#define __attribute__(x)\n#endif\n#include "'+
        (cpp/'utils/product_hilog.h').as_posix()+'"\n',encoding='utf-8')
    project='cmake_minimum_required(VERSION 3.20)\nproject(input_trace_target LANGUAGES CXX)\n'
    project+=f'set(AMCL_BUILD_PRODUCT {options.product} CACHE STRING "host product" FORCE)\nset(MC_OHOS_BUILD_TESTS OFF)\nset(AMCL_INPUT_TRACE {options.trace})\n'
    project+='include("'+policy.as_posix()+'")\nadd_library(probe OBJECT "'+(build/'probe.cpp').as_posix()+'")\n'
    project+='target_compile_features(probe PRIVATE cxx_std_17)\ntarget_include_directories(probe PRIVATE "'+cpp.as_posix()+'" "'+(cpp/'tests/host/stubs').as_posix()+'")\n'
    project+='set(CMAKE_CURRENT_SOURCE_DIR "'+cpp.as_posix()+'")\namcl_apply_diagnostic_policy(probe)\n'
    project+='if(MSVC)\nset_property(TARGET probe PROPERTY COMPILE_OPTIONS "/FI'+adapter.as_posix()+'" /utf-8)\nendif()\n'
    project+='file(GENERATE OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/objects-$<CONFIG>.txt" CONTENT "$<JOIN:$<TARGET_OBJECTS:probe>,\\n>")\n'
    project+='file(GENERATE OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/defines-$<CONFIG>.txt" CONTENT "$<JOIN:$<TARGET_PROPERTY:probe,COMPILE_DEFINITIONS>,;>")\n'
    (build/'CMakeLists.txt').write_text(project,encoding='utf-8',newline='\n')
    cmake=find_host_cmake();configure_host_cmake(cmake,build,build/'build')
    run=subprocess.run([cmake,'--build',str(build/'build'),'--config','Release'],capture_output=True)
    (output/'compile.log').write_bytes(run.stdout+run.stderr)
    if run.returncode:raise RuntimeError((run.stdout+run.stderr).decode(errors='replace'))
    configuration='Release' if os.name=='nt' else ''
    paths=[Path(s) for s in (build/'build'/f'objects-{configuration}.txt').read_text().splitlines()]
    callback=next(p for p in paths if p.name in ('probe.cpp.obj','probe.cpp.o','probe.obj'))
    data=callback.read_bytes();definitions=(build/'build'/f'defines-{configuration}.txt').read_text()
    valueOne=b'AMCL_INPUT_TRACE_VALUE_1' in data;valueZero=b'AMCL_INPUT_TRACE_VALUE_0' in data
    assert valueOne!=valueZero,'actual macro positive-control marker must be unique and present'
    observed='1' if valueOne else '0'
    # 原真实marker正文与原C++预处理结果必须一致；对象不冒称运行时DSO或包修复。
    present=b'AMCL_LOOK_GLFW obs=' in data
    assert present==(observed=='1')
    expected='1' if options.trace=='ON' and not options.remove_define else '0'
    assert observed==expected
    if not options.remove_define:assert f'AMCL_INPUT_TRACE={expected}' in definitions
    if options.trace=='OFF':assert 'AMCL_INPUT_TRACE_SAMPLE_INTERVAL=0' in definitions
    assert hashlib.sha256(glfwPath.read_bytes()).hexdigest()==originalGlfwHash,'GLFW extraction source drift'
    assert hashlib.sha256((cpp/'cmake/ProductDiagnostics.cmake').read_bytes()).hexdigest()==originalPolicyHash,'target policy source drift'
    assert hashlib.sha256(latencyHeader.read_bytes()).hexdigest()==originalLatencyHeaderHash,'latency declaration source drift'
    receipt={'product':options.product,'trace':options.trace,'removeDefine':options.remove_define,
        'compileExitCode':run.returncode,'definitions':definitions,'macroObserved':observed,'producerPresent':present,
        'callbackObject':str(callback),'callbackObjectSha256':hashlib.sha256(data).hexdigest(),
        'policySha256':hashlib.sha256(policy.read_bytes()).hexdigest(),
        'originalPolicySha256':originalPolicyHash,'originalGlfwSha256':originalGlfwHash,'extractionSourceDrift':[],
        'originalLatencyHeaderSha256':originalLatencyHeaderHash,
        'generatedSourceSha256':hashlib.sha256((build/'probe.cpp').read_bytes()).hexdigest(),
        'scope':'real target macro/preprocess and original production callback object; no runtime owner/ABI/device claim'}
    (output/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(receipt,indent=2),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,required=True);parser.add_argument('--build-out',type=Path,required=True)
    parser.add_argument('--product',choices=['default','store','desktop','sideload'],required=True)
    parser.add_argument('--trace',choices=['ON','OFF'],required=True);parser.add_argument('--remove-define',action='store_true')
    main(parser.parse_args())
