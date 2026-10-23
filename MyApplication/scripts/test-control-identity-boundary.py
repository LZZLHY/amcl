"""执行完整生产owner的身份耗尽反例；POSIX另执行有界fork继承锁拒绝反例。

测试唯一注入为同TU设置实际registry临界身份及后台持真实mutex；每份外置负控只去掉
一处正式守卫，必须编译成功且由真实行为断言失败。输出目录显式外置，不调用Docker。
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from lib.host_cpp import find_host_cmake, configure_host_cmake
from lib.workspace_paths import external_output_path

ROOT=Path(__file__).resolve().parents[1]
INPUT=ROOT/'entry/src/main/cpp/input'
TEST=ROOT/'entry/src/main/cpp/tests/host/control_delivery_identity_boundary_test.cpp'


def execute(args, folder, log, negative=False,marker='CONTROL IDENTITY BOUNDARY'):
    result=subprocess.run(list(map(str,args)),cwd=folder,capture_output=True,timeout=90)
    log.write_bytes(result.stdout+result.stderr)
    text=(result.stdout+result.stderr).decode('utf-8',errors='replace')
    print(text[-4000:],end='',flush=True)
    if negative:
        assert result.returncode!=0 and marker in text, str(log)
    else:
        assert result.returncode==0,str(log)
    return result.returncode


def main(options):
    output=external_output_path(options.out)
    if output.exists():raise ValueError('Test output must be a new directory: '+str(output))
    builds=external_output_path(options.build_out)
    if builds.exists():raise ValueError('Build output must be a new directory: '+str(builds))
    output.mkdir(parents=True);builds.mkdir(parents=True);temp=builds/'temp';temp.mkdir()
    os.environ['TEMP']=str(temp);os.environ['TMP']=str(temp);os.environ['TMPDIR']=str(temp)
    original=(INPUT/'delivery/control_delivery.cpp').read_text(encoding='utf-8')
    relocated=original.replace('"control_delivery.h"','"'+(INPUT/'delivery/control_delivery.h').as_posix()+'"')
    relocated=relocated.replace('"../amcl_input_api.h"','"'+(INPUT/'amcl_input_api.h').as_posix()+'"')
    relocated=relocated.replace('"../amcl_input_host_descriptor.h"','"'+(INPUT/'amcl_input_host_descriptor.h').as_posix()+'"')
    variants={
        'bind-activation-wrap':('if(c->stats.activation==UINT64_MAX)return AMCL_CONTROL_PRESSURE;','/* negative: bind wraps activation */'),
        'retire-activation-wrap':('if(mask==15u&&!only&&kind==0&&c->stats.activation==UINT64_MAX)return AMCL_CONTROL_PRESSURE;','/* negative: all-retire wraps activation */'),
        'abandon-activation-wrap':('if(c->stats.activation==UINT64_MAX){r.consumers.erase(handle);return;}','/* negative: abandon wraps activation */'),
        'source-up-as-recovery':('makeEmission(r,*c,control,next,outputAction)','makeEmission(r,*c,control,next,action)'),
        'orphan-up-not-recovered':('if((before&&held.owners.empty())||orphanApplied)','if(before&&held.owners.empty())'),
    }
    if os.name!='nt':
        variants['fork-lock-before-pid']=(
            'if(foreignOwner())return AMCL_CONTROL_STALE;auto& r=registry();if(inherited(r))return AMCL_CONTROL_STALE;std::lock_guard<std::mutex> lock(r.mutex);if(r.session&&r.session!=session)',
            'auto& r=registry();std::lock_guard<std::mutex> lock(r.mutex);if(r.session&&r.session!=session)')
    facts=[]
    for mode in ['production',*variants]:
        folder=builds/mode;folder.mkdir();logs=output/mode;logs.mkdir();body=relocated
        if mode in variants:
            before,after=variants[mode];assert body.count(before)==1,mode;body=body.replace(before,after,1)
        (folder/'owner.cpp').write_text(body,encoding='utf-8')
        harness=TEST.read_text(encoding='utf-8').replace('#include "../../input/delivery/control_delivery.cpp"','#include "owner.cpp"')
        harness=harness.replace('"../../input/adapters/glfw_source_plane_aggregate.cpp"','"'+(INPUT/'adapters/glfw_source_plane_aggregate.cpp').as_posix()+'"')
        if mode in ('source-up-as-recovery','orphan-up-not-recovered'):
            # 实际常驻port反例也用于该单点变异；不是把期望输出复制为影子状态机。
            harness='#include "owner.cpp"\n'+(TEST.parent/'control_delivery_test.cpp').read_text(encoding='utf-8')
            harness=harness.replace('"../../input/delivery/control_delivery_client.h"','"'+(INPUT/'delivery/control_delivery_client.h').as_posix()+'"')
        (folder/'fixture.cpp').write_text(harness,encoding='utf-8')
        # Core 的真实 L2 held reader 依赖生产 mapper；补完整强链接，不以 weak/noop 或假映射替代。
        sources=[folder/'fixture.cpp',INPUT/'input_state_core.cpp',INPUT/'adapters/backend_keymaps.cpp',INPUT/'amcl_input_host_descriptor.cpp',INPUT/'input_interaction_order.cpp']
        if os.name=='nt':
            cmake=find_host_cmake(options.cmake)
            project='cmake_minimum_required(VERSION 3.20)\nproject(control_identity_boundary LANGUAGES CXX)\nadd_executable(boundary '+ ' '.join('"'+p.as_posix()+'"' for p in sources)+')\n'
            project+='target_compile_features(boundary PRIVATE cxx_std_17)\ntarget_compile_options(boundary PRIVATE /utf-8)\n'
            project+='target_compile_definitions(boundary PRIVATE AMCL_CONTROL_DELIVERY_HOST_TESTING AMCL_INPUT_HOST_EXPORTS _CRT_SECURE_NO_WARNINGS)\n'
            # 外置 owner 完整正文仍解析同一 delivery 私有头；新 L2 scope/source 头不靠仿制声明。
            project+='target_include_directories(boundary PRIVATE "'+(INPUT/'delivery').as_posix()+'" "'+(ROOT/'entry/src/main/cpp/tests/host/stubs').as_posix()+'")\n'
            (folder/'CMakeLists.txt').write_text(project,encoding='utf-8')
            configure_host_cmake(cmake,folder,folder/'build')
            execute([cmake,'--build',folder/'build','--config','Release'],folder,logs/'compile.log')
            binary=folder/'build/Release/boundary.exe'
        else:
            compiler=shutil.which(options.compiler)
            if not compiler:raise FileNotFoundError('Actual POSIX C++ compiler missing: '+options.compiler)
            binary=folder/'boundary'
            execute([compiler,'-std=c++17','-pthread','-rdynamic','-DAMCL_CONTROL_DELIVERY_HOST_TESTING',
                '-DAMCL_INPUT_HOST_EXPORTS','-D_GNU_SOURCE','-I'+(INPUT/'delivery').as_posix(),'-I'+(ROOT/'entry/src/main/cpp/tests/host/stubs').as_posix(),
                *sources,'-ldl','-o',binary],folder,logs/'compile.log')
        marker='CONTROL DELIVERY FAIL' if mode in ('source-up-as-recovery','orphan-up-not-recovered') else 'CONTROL IDENTITY BOUNDARY'
        code=execute([binary],folder,logs/'behavior.log',mode!='production',marker)
        facts.append({'mode':mode,'exitCode':code,'negativeExpected':mode!='production'})
        print('PASS '+mode,flush=True)
    (output/'receipt.json').write_text(json.dumps({'schema':1,'platform':os.name,'buildDirectory':str(builds),'results':facts,
        'layer':'actual owner registry/identity; POSIX held-mutex fork child bounded to one second',
        'sources':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [INPUT/'delivery/control_delivery.cpp',INPUT/'delivery/control_delivery.h',TEST,TEST.parent/'control_delivery_test.cpp']}},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--build-out',type=Path,required=True,help='仓外独立构建目录，与证据/日志目录分别指定')
    parser.add_argument('--cmake')
    parser.add_argument('--compiler',default='g++')
    main(parser.parse_args())
