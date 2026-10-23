"""真owner/facade正常退出及仅撤回registry storage的确定性析构反控。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from lib.host_cpp import find_host_cmake, configure_host_cmake
from lib.workspace_paths import external_output_path
ROOT=Path(__file__).resolve().parents[1]

def main(options):
    """同TU析构观察只读marker；正例正常return，不用_Exit避开产品facade析构。"""
    output=external_output_path(options.out);output.mkdir(parents=True,exist_ok=False)
    build=external_output_path(options.build_out);build.mkdir(parents=True,exist_ok=False)
    temp=build/'temp';temp.mkdir();os.environ['TEMP']=str(temp);os.environ['TMP']=str(temp)
    cpp=ROOT/'entry/src/main/cpp';owner=cpp/'input/delivery/control_delivery.cpp'
    body=owner.read_text(encoding='utf-8')
    body=re.sub(r'#include "([^\"]+)"',lambda m:'#include "'+(owner.parent/m[1]).resolve().as_posix()+'"',body)
    marker='    const uint32_t process=pid();'
    assert body.count(marker)==1
    observed=body.replace(marker,marker+'\n    ~Registry(){registryDestroyed=true;}',1)
    begin=observed.index('Registry& registry(){');end=observed.index('// 本owner不支持fork继承',begin)
    negative=observed[:begin]+'Registry& registry(){static Registry value;return value;}\n'+observed[end:]
    template=(cpp/'tests/host/control_owner_teardown_test.cpp.in').read_text(encoding='utf-8')
    project='cmake_minimum_required(VERSION 3.20)\nproject(control_teardown LANGUAGES CXX)\n'
    for variant,source in [('production',observed),('old_storage',negative)]:
        fixture=build/(variant+'.cpp');fixture.write_text(template.replace('@OWNER_SOURCE@',source),encoding='utf-8')
        # Core 的真实 L2 held reader 依赖生产 mapper；补完整强链接，不以 weak/noop 或假映射替代。
        paths=[fixture,cpp/'input/adapters/glfw_source_plane_aggregate.cpp',cpp/'input/input_state_core.cpp',cpp/'input/adapters/backend_keymaps.cpp',
            cpp/'input/input_interaction_order.cpp',cpp/'input/amcl_input_host_descriptor.cpp']
        project+='add_executable('+variant+' '+' '.join('"'+p.as_posix()+'"' for p in paths)+')\n'
        project+='target_compile_features('+variant+' PRIVATE cxx_std_17)\n'
        project+='target_include_directories('+variant+' PRIVATE "'+cpp.as_posix()+'" "'+(cpp/'tests/host/stubs').as_posix()+'")\n'
        project+='target_compile_definitions('+variant+' PRIVATE AMCL_CONTROL_DELIVERY_HOST_TESTING AMCL_INPUT_HOST_EXPORTS _CRT_SECURE_NO_WARNINGS)\n'
        project+='if(MSVC)\n target_compile_options('+variant+' PRIVATE /utf-8)\nelse()\n target_link_libraries('+variant+' PRIVATE dl pthread)\nendif()\n'
    core=cpp/'input/input_state_core.cpp';coreBody=core.read_text(encoding='utf-8')
    coreBody=re.sub(r'#include "([^\"]+)"',lambda m:'#include "'+(core.parent/m[1]).resolve().as_posix()+'"',coreBody)
    needle='InputStateCore::~InputStateCore() = default;';assert coreBody.count(needle)==1
    coreBody='extern bool coreDestroyed,genericDestroyed;extern void* trackedHostCore;\n'+coreBody.replace(needle,
        'InputStateCore::~InputStateCore(){if(this==trackedHostCore)coreDestroyed=true;else genericDestroyed=true;}',1)
    start=coreBody.index('InputStateCore& HostInputStateCore() {');end=coreBody.index('}  // namespace amcl::input',start)
    owned=coreBody[start:end];assert owned.count('static InputStateCore* const core=new InputStateCore(')==2
    old=owned.replace('static InputStateCore* const core=new InputStateCore(','static InputStateCore core(').replace('return *core;','return core;')
    fixtureTemplate=(cpp/'tests/host/core_owner_teardown_test.cpp.in').read_text(encoding='utf-8')
    for variant,source in [('core_production',coreBody),('core_old_storage',coreBody[:start]+old+coreBody[end:])]:
        candidate=build/(variant+'_owner.cpp');candidate.write_text(source,encoding='utf-8')
        fixture=build/(variant+'.cpp');fixture.write_text(fixtureTemplate,encoding='utf-8')
        paths=[fixture,candidate,cpp/'input/adapters/glfw_input_adapter.cpp',cpp/'input/adapters/backend_keymaps.cpp',
            cpp/'input/input_interaction_order.cpp',cpp/'platform/physical_wheel_quantizer.cpp']
        project+='add_executable('+variant+' '+' '.join('"'+p.as_posix()+'"' for p in paths)+')\n'
        project+='target_compile_features('+variant+' PRIVATE cxx_std_17)\n'
        project+='target_include_directories('+variant+' PRIVATE "'+cpp.as_posix()+'" "'+(cpp/'tests/host/stubs').as_posix()+'")\n'
        project+='target_compile_definitions('+variant+' PRIVATE AMCL_INPUT_HOST_EXPORTS _CRT_SECURE_NO_WARNINGS)\n'
        project+='if(MSVC)\n target_compile_options('+variant+' PRIVATE /utf-8)\nelse()\n target_link_libraries('+variant+' PRIVATE dl pthread)\nendif()\n'
    (build/'CMakeLists.txt').write_text(project,encoding='utf-8');cmake=find_host_cmake(options.cmake)
    configure_host_cmake(cmake,build,build/'build')
    run=subprocess.run([cmake,'--build',str(build/'build'),'--config','Release'],capture_output=True)
    (output/'compile.log').write_bytes(run.stdout+run.stderr);print((run.stdout+run.stderr).decode(errors='replace'),flush=True)
    assert run.returncode==0
    results=[]
    for variant in ['production','old_storage','core_production','core_old_storage']:
        binary=build/'build'/('Release/'+variant+'.exe' if os.name=='nt' else variant)
        run=subprocess.run([str(binary)],capture_output=True,timeout=10)
        (output/(variant+'.log')).write_bytes(run.stdout+run.stderr);print((run.stdout+run.stderr).decode(errors='replace'),flush=True)
        if variant=='production':assert run.returncode==0 and b'registryDestroyed=0' in run.stderr
        elif variant=='core_production':assert run.returncode==0 and b'hostDestroyed=0' in run.stderr
        else:assert run.returncode!=0 and b'OWNER TEARDOWN FAIL' in run.stderr
        results.append({'variant':variant,'exitCode':run.returncode})
    (output/'receipt.json').write_text(json.dumps({'sourceSha256':hashlib.sha256(owner.read_bytes()).hexdigest(),
        'results':results,'scope':'actual owner/global facade normal exit; deterministic registry destructor observer; no device assertion'},indent=2)+'\n',encoding='utf-8')

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--build-out',type=Path,required=True);parser.add_argument('--cmake');main(parser.parse_args())
