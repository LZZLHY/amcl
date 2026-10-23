"""以真实分离DSO证明control私有端口归属唯一neutral/Core owner。

frontend只编译正式client头，不链接owner实现；两个独立DSO分别编译完整正式owner。
版本/size/identity/缺函数反控只在外置候选中逐点修改正式getter，仍必须编译成功。
每例使用新进程，保持owner库直到进程退出，不以卸载或清descriptor绕过owner寿命。
"""
from pathlib import Path
import hashlib
import json
import os
import subprocess
from lib.host_cpp import find_host_cmake, configure_host_cmake
from lib.workspace_paths import temporary_directory

ROOT = Path(__file__).resolve().parents[1]
CPP = ROOT / 'entry/src/main/cpp'
INPUT = CPP / 'input'

FRONTEND = r'''
#include "control_delivery_client.h"
#include <stdio.h>
#include <string>
#include <cstdlib>
#define CHECK(v) do {if(!(v)){fprintf(stderr,"CONTROL OWNER IDENTITY %d: %s\n",__LINE__,#v);return 1;}}while(0)
typedef const AmclControlDeliveryPortV1* (*Getter)(void);
typedef void (*Publisher)(void);
struct Library {Getter getter;Publisher publish;};
Library load(const char* path) {
#ifdef _WIN32
    HMODULE image=LoadLibraryA(path);
    if(!image)return {};
    return {(Getter)GetProcAddress(image,"amclControlDeliveryGetPortV1"),
            (Publisher)GetProcAddress(image,"amclControlDeliveryPublishV1")};
#else
    void* image=dlopen(path,RTLD_NOW|RTLD_LOCAL);
    if(!image){fprintf(stderr,"%s\n",dlerror());return {};}
    return {(Getter)dlsym(image,"amclControlDeliveryGetPortV1"),
            (Publisher)dlsym(image,"amclControlDeliveryPublishV1")};
#endif
    // 禁止dlclose/FreeLibrary：owner表和函数地址在进程内始终保持真实借用寿命。
}
void describe(const char* value) {
#ifdef _WIN32
    _putenv_s(AMCL_CONTROL_ENV,value?value:"");
#else
    if(value)setenv(AMCL_CONTROL_ENV,value,1);else unsetenv(AMCL_CONTROL_ENV);
#endif
}
int main(int argc,char** argv) {
    CHECK(argc==4);const std::string mode=argv[1];const auto first=load(argv[2]);
    CHECK(first.getter&&first.publish);const auto* actual=first.getter();CHECK(actual);
    first.publish();const AmclControlDeliveryPortV1* resolved=nullptr;
    if(mode=="version"||mode=="size"||mode=="incomplete") {
        CHECK(amclControlDeliveryResolveV1(&resolved)==AMCL_CONTROL_REJECTED&&resolved==nullptr);
    } else if(mode=="identity") {
        CHECK(amclControlDeliveryResolveV1(&resolved)==AMCL_CONTROL_NOT_READY&&resolved==nullptr);
    } else {
        CHECK(amclControlDeliveryResolveV1(&resolved)==0&&resolved==actual);
        const std::string good=getenv(AMCL_CONTROL_ENV);uint64_t consumer=0;
        CHECK(resolved->open(1,42,&consumer)==0&&consumer);
        AmclControlEmissionV1 down{};CHECK(resolved->apply(consumer,1,0,1,65,30,1,&down)==1);
        CHECK(resolved->claim(&down)==1&&resolved->complete(&down,3)==0);
        if(mode=="missing") {
            describe(nullptr);CHECK(amclControlDeliveryResolveV1(&resolved)==AMCL_CONTROL_NOT_READY&&resolved==nullptr);
        } else if(mode=="malformed") {
            const char* samples[]={"AMCLCONTROL:2:1","AMCLCONTROL:1:","AMCLCONTROL:1:-1",
                "AMCLCONTROL:1:+1","AMCLCONTROL:1:1x","AMCLCONTROL:1:18446744073709551616",
                "AMCLCONTROL:1:0","AMCLCONTROL:1:1"};
            for(const auto* sample:samples){describe(sample);CHECK(amclControlDeliveryResolveV1(&resolved)==AMCL_CONTROL_REJECTED&&resolved==nullptr);}
        } else if(mode=="wrong-symbol") {
            char value[96]{};snprintf(value,sizeof(value),AMCL_CONTROL_PREFIX "%llu",(unsigned long long)(uintptr_t)first.publish);
            describe(value);CHECK(amclControlDeliveryResolveV1(&resolved)==AMCL_CONTROL_REJECTED&&resolved==nullptr);
        } else if(mode=="second-owner") {
            const auto second=load(argv[3]);CHECK(second.getter&&second.publish);
            const auto* other=second.getter();CHECK(other&&other!=actual&&other->ownerHost!=actual->ownerHost);
            // 正式getter尝试发布第二Core表会被既有跨DSO descriptor拒绝。
            CHECK(other->verifyOwner(other->ownerHost)==AMCL_CONTROL_NOT_READY);
            uint64_t rejected=1;CHECK(other->open(1,42,&rejected)==AMCL_CONTROL_NOT_READY&&rejected==0);
            second.publish();CHECK(amclControlDeliveryResolveV1(&resolved)==AMCL_CONTROL_NOT_READY&&resolved==nullptr);
        } else CHECK(mode=="production");
        describe(good.c_str());CHECK(amclControlDeliveryResolveV1(&resolved)==0&&resolved==actual);
        CHECK(resolved->query(consumer,1,65)==1);resolved->close(consumer);
    }
    printf("PASS separate frontend/neutral owner identity: %s\n",mode.c_str());return 0;
}
'''


with temporary_directory(prefix='control-owner-identity-') as directory:
    work=Path(directory);cmake=find_host_cmake();build=work/'build'
    (work/'frontend.cpp').write_text(FRONTEND,encoding='utf-8')
    original=(INPUT/'delivery/control_delivery.cpp').read_text(encoding='utf-8')
    # 相对include只改为相同正式文件的绝对地址，保证候选离开源码仓仍编译真实依赖。
    relocated=original.replace('"../amcl_input_api.h"','"'+(INPUT/'amcl_input_api.h').as_posix()+'"')
    relocated=relocated.replace('"../amcl_input_host_descriptor.h"','"'+(INPUT/'amcl_input_host_descriptor.h').as_posix()+'"')
    variants={
        'version':('AMCL_CONTROL_MAGIC,1,sizeof(AmclControlDeliveryPortV1)','AMCL_CONTROL_MAGIC,2,sizeof(AmclControlDeliveryPortV1)'),
        'size':('AMCL_CONTROL_MAGIC,1,sizeof(AmclControlDeliveryPortV1)','AMCL_CONTROL_MAGIC,1,sizeof(AmclControlDeliveryPortV1)-1'),
        'identity':('reinterpret_cast<uintptr_t>(amclInputGetHostApiV1()),verify,open','reinterpret_cast<uintptr_t>(amclInputGetHostApiV1())+1,verify,open'),
        'incomplete':('amclInputGetHostApiV1()),verify,open','amclInputGetHostApiV1()),nullptr,open'),
    }
    definitions=[]
    for name in ['owner','second',*variants]:
        control=INPUT/'delivery/control_delivery.cpp'
        if name in variants:
            before,after=variants[name];assert relocated.count(before)==1,name
            control=work/(name+'.cpp');control.write_text(relocated.replace(before,after,1),encoding='utf-8')
        # Core 的真实 L2 held reader 依赖生产 mapper；补完整强链接，不以 weak/noop 或假映射替代。
        paths=[control,INPUT/'input_state_core.cpp',INPUT/'adapters/backend_keymaps.cpp',INPUT/'amcl_input_host_descriptor.cpp',INPUT/'input_interaction_order.cpp']
        definitions.append('add_library('+name+' SHARED '+' '.join('"'+p.as_posix()+'"' for p in paths)+')')
        definitions.append('target_include_directories('+name+' PRIVATE "'+(INPUT/'delivery').as_posix()+'" "'+(CPP/'tests/host/stubs').as_posix()+'")')
        definitions.append('target_compile_definitions('+name+' PRIVATE AMCL_CONTROL_DELIVERY_HOST_TESTING AMCL_INPUT_HOST_EXPORTS _CRT_SECURE_NO_WARNINGS)')
        # 独立目录内使用正式owner叶名，让ELF client的真实库名资格也生效。
        definitions.append('set_target_properties('+name+' PROPERTIES OUTPUT_NAME amcl_input_runtime RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/'+name+'" LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/'+name+'" ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/'+name+'")')
        definitions.append('if(MSVC)\n target_compile_options('+name+' PRIVATE /utf-8)\nendif()')
    project='''cmake_minimum_required(VERSION 3.20)
project(control_owner_identity LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
add_executable(frontend frontend.cpp)
target_include_directories(frontend PRIVATE "@HEADER@")
target_compile_definitions(frontend PRIVATE _CRT_SECURE_NO_WARNINGS)
if(MSVC)
 target_compile_options(frontend PRIVATE /utf-8)
else()
 add_compile_definitions(_GNU_SOURCE)
 target_link_libraries(frontend PRIVATE ${CMAKE_DL_LIBS})
endif()
'''.replace('@HEADER@',(INPUT/'delivery').as_posix())+'\n'+'\n'.join(definitions)+'\n'
    (work/'CMakeLists.txt').write_text(project,encoding='utf-8')
    configure_host_cmake(cmake,work,build)
    subprocess.run([cmake,'--build',str(build),'--config','Release'],check=True)
    frontend=build/'Release/frontend.exe' if os.name=='nt' else build/'frontend'
    def owner(name):
        return build/name/('Release/amcl_input_runtime.dll' if os.name=='nt' else 'libamcl_input_runtime.so')
    modes=['production','missing','malformed','wrong-symbol','second-owner',*variants]
    receipts=[]
    for mode in modes:
        first=owner(mode if mode in variants else 'owner')
        result=subprocess.run([str(frontend),mode,str(first),str(owner('second'))],capture_output=True,text=True,timeout=30)
        print(result.stdout,end='');assert result.returncode==0,result.stdout+result.stderr
        receipts.append({'mode':mode,'exitCode':result.returncode})
    receipt={'schema':1,'results':receipts,'layer':'real separate frontend/neutral owner DSO; no HAP or device claim',
        'sources':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [INPUT/'delivery/control_delivery.cpp',INPUT/'delivery/control_delivery.h',INPUT/'delivery/control_delivery_client.h',INPUT/'input_state_core.cpp',INPUT/'amcl_input_host_descriptor.cpp']}}
    (work/'receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('Receipt: '+str(work/'receipt.json'))
