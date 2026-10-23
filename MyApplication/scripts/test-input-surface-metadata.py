"""真实McGamePage→Native producer/core的同代显示元数据回归。

小型宿主探针直接链接现役ingress/shadow/trace/core/公共order生产TU，只把进程输入与输出做CLI接缝。
页面方法由现役ETS AST提取，Native接受态与late-consumer当前context来自实际生产API；旧页面
仅按generation跳过元数据的负控先通过转译，再由实际行为断言失败。所有构建/证据逐次外置隔离。
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import uuid
from lib.host_cpp import find_host_cmake, configure_host_cmake
from lib.workspace_paths import external_output_path, workspace_path

ROOT=Path(__file__).resolve().parents[1]

def main():
    """只编独立生产探针；不执行SDK或重复NativeBuild全目标，也不接受编译失败冒充负控成功。"""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cmake');parser.add_argument('--build-dir');parser.add_argument('--output')
    args=parser.parse_args();leaf='run-'+str(os.getpid())+'-'+uuid.uuid4().hex[:8]
    build_base=external_output_path(args.build_dir) if args.build_dir else workspace_path('build','input-surface-metadata')
    output_base=external_output_path(args.output) if args.output else workspace_path('run','input-surface-metadata')
    build=build_base/leaf;output=output_base/leaf;project=build/'source';project.mkdir(parents=True,exist_ok=False);output.mkdir(parents=True,exist_ok=False)
    fixture=ROOT/'entry/src/main/cpp/tests/host/input_surface_metadata.cpp.in'
    (project/'metadata.cpp').write_bytes(fixture.read_bytes())
    native_names=['platform_input_ingress.cpp','input_shadow_consumer.cpp','input_trace.cpp','input_state_core.cpp','input_interaction_order.cpp']
    native_dir=ROOT/'entry/src/main/cpp/input';sources=[]
    # 使用完整真实TU的独占快照，不在构建中读取并发变化的工程源码；头文件沿生产include目录。
    for name in native_names:
        destination=project/name;destination.write_bytes((native_dir/name).read_bytes());sources.append('"'+destination.as_posix()+'"')
    # 完整 Core 已包含真实 L2 held reader；连入其生产 mapper，显示元数据断言及 host 接缝不变。
    sources.append('"'+(native_dir/'adapters/backend_keymaps.cpp').as_posix()+'"')
    cmake_text='''cmake_minimum_required(VERSION 3.16)
project(input_surface_metadata LANGUAGES CXX)
add_executable(metadata metadata.cpp %s)
target_include_directories(metadata PRIVATE "%s" "%s")
target_compile_features(metadata PRIVATE cxx_std_17)
target_compile_definitions(metadata PRIVATE AMCL_INPUT_HOST_EXPORTS AMCL_INPUT_HOST_TESTING AMCL_INPUT_SHADOW=1 AMCL_INPUT_QUEUE_CAPACITY=64 AMCL_INPUT_BLOB_POOL_CAPACITY=256)
if(MSVC)
target_compile_options(metadata PRIVATE /W4 /WX /utf-8)
target_compile_definitions(metadata PRIVATE _CRT_SECURE_NO_WARNINGS)
else()
target_compile_options(metadata PRIVATE -Wall -Wextra -Werror -pedantic)
endif()
'''%(' '.join(sources),native_dir.as_posix(),(ROOT/'entry/src/main/cpp/tests/host/stubs').as_posix())
    (project/'CMakeLists.txt').write_text(cmake_text,encoding='utf-8',newline='\n')
    cmake=find_host_cmake(args.cmake);configure_host_cmake(cmake,project,build/'native')
    subprocess.run([cmake,'--build',str(build/'native'),'--config','Debug','--parallel','2'],check=True)
    binary=build/'native'/('Debug/metadata.exe' if os.name=='nt' else 'metadata')
    node=shutil.which('node')
    if not node:raise FileNotFoundError('Node required for actual ArkTS source method')
    runner=ROOT/'scripts/fixtures/input-surface-metadata/publication.mjs'
    base=[node,str(runner),'--native',str(binary),'--output',str(output)]
    positive=subprocess.run(base,capture_output=True,text=True,timeout=90)
    (output/'positive.log').write_text(positive.stdout+positive.stderr,encoding='utf-8')
    if positive.returncode!=0:raise AssertionError(positive.stdout+positive.stderr)
    page=ROOT/'entry/src/main/ets/pages/McGamePage.ets';original=page.read_text(encoding='utf-8')
    anchor='this.nativeSurfaceContextGeneration !== context.generation || this.nativeSurfaceContextMetadata !== metadata'
    if original.count(anchor)!=1:raise ValueError('Actual page metadata-cache anchor must be unique')
    changed=original.replace(anchor,'this.nativeSurfaceContextGeneration !== context.generation')
    old=output/'old-generation-only.ets';old.write_text(changed,encoding='utf-8',newline='\n')
    negative=subprocess.run(base+['--source',str(old)],capture_output=True,text=True,timeout=90)
    (output/'negative.log').write_text(negative.stdout+negative.stderr,encoding='utf-8')
    if negative.returncode==0 or 'AssertionError' not in negative.stderr or 'NATIVE_METADATA_MIRROR_UPDATED' not in negative.stderr:
        raise AssertionError('Old generation-only page must execute and fail native mirror behavior: '+negative.stdout+negative.stderr)
    # 另一个负控只撤回诊断去重，必须先转译并执行同一真实publisher，命中实际日志次数断言。
    # 不用Native语法/装载失败冒充证明，也不把观察静默改成生产refresh不执行。
    diagnostic_anchor='diagnostic !== this.surfaceContextDiagnosticFingerprint_'
    if original.count(diagnostic_anchor)!=1:raise ValueError('Actual page diagnostic anchor must be unique')
    noisy_text=original.replace(diagnostic_anchor,'true')
    noisy=output/'old-heartbeat-diagnostic.ets';noisy.write_text(noisy_text,encoding='utf-8',newline='\n')
    noisy_result=subprocess.run(base+['--source',str(noisy),'--label','noisy.json'],capture_output=True,text=True,timeout=90)
    (output/'diagnostic-negative.log').write_text(noisy_result.stdout+noisy_result.stderr,encoding='utf-8')
    if noisy_result.returncode==0 or 'AssertionError' not in noisy_result.stderr or 'SAME_SURFACE_DIAGNOSTIC_QUIET' not in noisy_result.stderr:
        raise AssertionError('Withdrawn diagnostic guard must compile and fail log-count behavior: '+noisy_result.stdout+noisy_result.stderr)
    names=['entry/src/main/ets/pages/McGamePage.ets','gamecontrol/src/main/ets/InputSurfaceContext.ets',
        'entry/src/main/cpp/input/input_surface_context_semantics.h','entry/src/main/cpp/input/adapters/backend_keymaps.cpp',*[str(Path('entry/src/main/cpp/input')/n).replace('\\','/') for n in native_names],
        'entry/src/main/cpp/tests/host/input_surface_metadata.cpp.in','scripts/test-input-surface-metadata.py',
        'scripts/fixtures/input-surface-metadata/publication.mjs']
    receipt={'scope':'host actual page/native metadata; no SDK/device claim','positiveExit':positive.returncode,'negativeExit':negative.returncode,
        'diagnosticNegativeExit':noisy_result.returncode,'diagnosticNegativeSourceSHA256':hashlib.sha256(noisy_text.encode()).hexdigest(),
        'sources':{n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in names},
        'negativeSourceSHA256':hashlib.sha256(changed.encode()).hexdigest(),'binary':str(binary)}
    (output/'evidence.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(positive.stdout,end='');print('PASS generation-only negative executes native mirror failure; evidence='+str(output))

if __name__=='__main__':main()
