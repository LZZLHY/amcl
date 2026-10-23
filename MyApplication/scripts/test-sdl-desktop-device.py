"""执行最终有序SDL补丁中的DesktopHost，区分固定设备资格与可晚到的模块/owner。

只替换系统设备类型和动态加载器边界，不复制DesktopHost算法；负控必须在成功编译后
被相同断言拒绝。真实SDL产物、设备输入及呈现由正常构建与真机另行验证。
"""
import importlib.util
from pathlib import Path
import os
import subprocess
from lib.host_cpp import compile_cpp
from lib.workspace_paths import temporary_directory

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('desktop_extract', ROOT/'scripts/generate-desktop-review-tests.py')
extract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(extract)
patched = extract.patch_sources()['SDL_amcldesktop.c']
signature = 'static const AmclDesktopHostV1 *DesktopHost(void)'
assert patched.count(signature) == 1
production = extract.block(patched, patched.index(signature))
fixture = r'''
#include "@ROOT@/entry/src/main/cpp/platform/desktop_host_api.h"
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
// 系统和加载器边界只计数/提供可控时序，完整消费者函数在下方原样插入。
struct SDL_AtomicInt { std::atomic<int> value{0}; };
int SDL_GetAtomicInt(SDL_AtomicInt* v){return v->value.load();}
void SDL_SetAtomicInt(SDL_AtomicInt* v,int n){v->value.store(n);}
int SDL_strcmp(const char* a,const char* b){return std::strcmp(a,b);}
static const char* device;
static int type_calls,loads,symbols,resolves;
static bool load_ready=false,owner_ready=false;
const char* OH_GetDeviceType(){++type_calls;return device;}
struct SDL_SharedObject {};
static SDL_SharedObject module_object;
static AmclDesktopHostV1 api{};
const AmclDesktopHostV1* Resolve(){++resolves;return owner_ready?&api:nullptr;}
SDL_SharedObject* SDL_LoadObject(const char* name){
    if(std::strcmp(name,"libglfw.so"))std::abort();++loads;return load_ready?&module_object:nullptr;
}
using SDL_FunctionPointer=void(*)();
SDL_FunctionPointer SDL_LoadFunction(SDL_SharedObject*,const char* name){
    if(std::strcmp(name,"amclDesktopHostResolve"))std::abort();++symbols;
    return reinterpret_cast<SDL_FunctionPointer>(&Resolve);
}
void SDL_ClearError(){}
@PRODUCTION@
#define CHECK(v,message) do{if(!(v)){std::fprintf(stderr,"SDL DESKTOP GATE FAIL: %s\n",message);return 1;}}while(0)
int main(int argc,char** argv){
    CHECK(argc==2,"device argument");device=std::strcmp(argv[1],"null")?argv[1]:nullptr;
    api.magic=AMCL_DESKTOP_HOST_MAGIC;api.size=sizeof(api);
    if(!device||std::strcmp(device,"2in1")){
        for(int i=0;i<10000;++i)CHECK(DesktopHost()==nullptr,"non-desktop returned host");
        CHECK(loads==0&&symbols==0&&resolves==0,"non-desktop caused library load");
        CHECK(type_calls==1,"fixed device repeatedly queried");
    }else{
        CHECK(!DesktopHost()&&loads==1,"initial load failure");load_ready=true;
        CHECK(!DesktopHost()&&loads==2&&symbols==1,"module retry before owner publication");
        owner_ready=true;CHECK(DesktopHost()==&api,"late published host lost");
        api.magic=0;CHECK(!DesktopHost(),"bad magic accepted");api.magic=AMCL_DESKTOP_HOST_MAGIC;
        api.size=0;CHECK(!DesktopHost(),"bad size accepted");api.size=sizeof(api);
        CHECK(DesktopHost()==&api&&loads==2&&symbols==1,"valid owner recovery reloads module");
        CHECK(type_calls==1,"desktop device repeatedly queried");
    }
    std::printf("PASS device=%s typeQueries=%d loads=%d resolves=%d\n",argv[1],type_calls,loads,resolves);
}
'''
fixture = fixture.replace('@ROOT@', ROOT.as_posix())
with temporary_directory(prefix='sdl-desktop-device-') as temporary:
    folder=Path(temporary);source=folder/'probe.cpp';binary=folder/('probe.exe' if os.name=='nt' else 'probe')
    source.write_text(fixture.replace('@PRODUCTION@',production),encoding='utf-8')
    compile_cpp(source,binary)
    for device in ('tablet','phone','default','null','2in1'):
        subprocess.run([str(binary),device],check=True,timeout=10)
    for old,new,device,expected in [
        ('if (kind != 1) return NULL;','/* compiled negative: omitted device gate */','tablet','non-desktop caused library load'),
        ('const AmclDesktopHostV1 *api = resolve ? resolve() : NULL;',
         'static const AmclDesktopHostV1 *api = resolve ? resolve() : NULL;','2in1','late published host lost')]:
        assert production.count(old)==1
        source.write_text(fixture.replace('@PRODUCTION@',production.replace(old,new)),encoding='utf-8')
        compile_cpp(source,binary)
        result=subprocess.run([str(binary),device],capture_output=True,text=True,timeout=10)
        assert result.returncode and expected in result.stderr,result
        print('PASS compiled negative:',expected,flush=True)
