"""编译真实来源政策NAPI函数、唯一neutral/Core/数学实现，验证单源原子应用与失败保持。"""
from pathlib import Path
import argparse
from datetime import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
sys.dont_write_bytecode = True
from lib.host_cpp import find_host_cmake, configure_host_cmake
from lib.workspace_paths import external_output_path, workspace_path

ROOT=Path(__file__).resolve().parents[1]
CPP=ROOT/'entry/src/main/cpp'

def definition(source):
    """逐字提取真实入口，括号定位跳过注释和字符串；不在夹具复写校验或调用政策。"""
    match=re.search(r'napi_value ApplySourceLookConfiguration\([^;{]*\{',source)
    assert match
    depth=0
    tokens=re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[{}]')
    for token in tokens.finditer(source,match.end()-1):
        if token.group()=='{':depth+=1
        elif token.group()=='}':
            depth-=1
            if not depth:return source[match.start():token.end()]
    raise AssertionError('actual NAPI function is incomplete')

def main(args):
    """所有生成源码/日志/编译树显式外置，负控必须真编译后在生产行为断言失败。"""
    out=external_output_path(args.output) if args.output else workspace_path('run','source-look-native')
    build=external_output_path(args.build_root) if args.build_root else workspace_path('build','source-look-native-'+datetime.now().strftime('%H%M%S%f'))
    out.mkdir(parents=True,exist_ok=False);build.mkdir(parents=True,exist_ok=False)
    # 只改变本脚本进程及其编译子进程；MSVC/CMake额外临时文件也留D外置构建树。
    temporary=build/'temp';temporary.mkdir()
    os.environ['TEMP']=str(temporary);os.environ['TMP']=str(temporary)
    started=datetime.now().astimezone().isoformat()
    actual=definition((CPP/'napi/napi_input.cpp').read_text(encoding='utf-8'))
    changes={'global':('source, sensitivity, invertY, smoothing, acceleration','-1, sensitivity, invertY, smoothing, acceleration'),
      'fractional':('std::floor(sourceNumber) == sourceNumber','true'),
      'gesture':('sourceNumber <= 3','sourceNumber <= 4')}
    if args.negative:
        before,after=changes[args.negative];assert actual.count(before)==1;actual=actual.replace(before,after,1)
    fixture=ROOT/'scripts/fixtures/input-policy/source_look_policy_napi.cpp.in'
    source=fixture.read_text(encoding='utf-8').replace('@CPP@',CPP.as_posix()).replace('@NAPI_FUNCTION@',actual)
    (build/'napi.cpp').write_text(source,encoding='utf-8')
    # Core 的真实 L2 held reader 依赖生产 mapper；补完整强链接，不以 weak/noop 或假映射替代。
    files=['input/delivery/look_execution.cpp','input/delivery/control_delivery.cpp','input/input_state_core.cpp','input/adapters/backend_keymaps.cpp',
      'input/amcl_input_host_descriptor.cpp','input/input_interaction_order.cpp','platform/source_look_processor.cpp',
      'platform/look_delta_math.cpp','platform/look_pipeline_stats.cpp']
    project='cmake_minimum_required(VERSION 3.20)\nproject(source_look_native LANGUAGES CXX)\n'
    project+='add_executable(policy "'+(build/'napi.cpp').as_posix()+'" '+ ' '.join('"'+(CPP/p).as_posix()+'"' for p in files)+')\n'
    project+='target_compile_features(policy PRIVATE cxx_std_17)\n'
    project+='target_include_directories(policy PRIVATE "'+(CPP/'tests/host/stubs').as_posix()+'")\n'
    project+='target_compile_definitions(policy PRIVATE AMCL_INPUT_HOST_EXPORTS _CRT_SECURE_NO_WARNINGS)\n'
    project+='if(MSVC)\n target_compile_options(policy PRIVATE /utf-8)\nelse()\n target_link_libraries(policy PRIVATE dl pthread)\nendif()\n'
    (build/'CMakeLists.txt').write_text(project,encoding='utf-8')
    cmake=find_host_cmake(args.cmake);configure_host_cmake(cmake,build,build/'build')
    compile_run=subprocess.run([cmake,'--build',str(build/'build'),'--config','Release'],capture_output=True)
    (out/'compile.log').write_bytes(compile_run.stdout+compile_run.stderr)
    print((compile_run.stdout+compile_run.stderr).decode(errors='replace'),flush=True)
    compile_run.check_returncode()
    binary=build/'build'/('Release/policy.exe' if os.name=='nt' else 'policy')
    result=subprocess.run([str(binary)],capture_output=True,timeout=30)
    (out/'behavior.log').write_bytes(result.stdout+result.stderr)
    print((result.stdout+result.stderr).decode(errors='replace'),flush=True)
    if args.negative:assert result.returncode!=0 and b'SOURCE POLICY FAIL' in result.stderr
    else:result.check_returncode()
    (out/'receipt.json').write_text(json.dumps({'startedAt':started,'finishedAt':datetime.now().astimezone().isoformat(),
      'negative':args.negative,'actualFunctionSha256':hashlib.sha256(actual.encode()).hexdigest(),
      'exitCode':result.returncode,'sources':{p:hashlib.sha256((CPP/p).read_bytes()).hexdigest() for p in files},
      'layer':'actual NAPI function + neutral/Core owner; SDK value boundary only, no OHOS/device claim'},indent=2)+'\n',encoding='utf-8')

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output');parser.add_argument('--build-root');parser.add_argument('--cmake')
    parser.add_argument('--negative',choices=['global','fractional','gesture'])
    main(parser.parse_args())
