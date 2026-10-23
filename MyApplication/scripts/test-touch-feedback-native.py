"""重放真实NAPI反馈注册、生产入队和call-js函数，SDK替身保留旧TSFN排空顺序。

验证旧haptic不进入新注册、旧button wake不清新pending、过期/旧会话反馈丢弃。
负对照撤回注册身份检查，在实际callback出口违反断言才算捕获缺陷。
"""
from pathlib import Path
import subprocess
from lib.host_cpp import compile_cpp
from lib.workspace_paths import temporary_directory

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'entry/src/main/cpp/napi/napi_input.cpp').read_text(encoding='utf-8')
start = source.index('struct ButtonFeedbackContext {')
end = source.index('// ⚠️ `registerButton`', start)
callbacks = source[start:end]
start = source.index('extern "C" void amcl_fire_haptic_tagged(')
end = source.index('/** 只投递有界唤醒', start)
production = callbacks + source[start:end]
prefix = r'''
#include <string>
#include <map>
#include <vector>
#include <memory>
#include <mutex>
#include <cstdint>
#include <ctime>
#include <new>
#include <cstring>
#include <iostream>
#include <stdexcept>
#define CHECK(v) do {if(!(v)){std::cerr<<"CHECK failed "<<__LINE__<<" "<<#v<<"\n";return 1;}}while(0)
constexpr int AMCL_CONTROL_ID_MAX_BYTES=96,AMCL_CONTROL_SCHEMA_MAX_CONTROLS=384;
constexpr int napi_ok=0,napi_tsfn_release=0,napi_tsfn_nonblocking=0,NAPI_AUTO_LENGTH=-1;
#ifndef CLOCK_MONOTONIC
#define CLOCK_MONOTONIC 1
#endif
// SDK时钟边界用独立名字，Linux也不会与libc已有clock_gettime声明/异常规格冲突。
#define clock_gettime fake_clock_gettime
enum napi_valuetype{napi_undefined,napi_function,napi_string};
struct Value{int integer=0;std::string text;bool function=false;std::map<std::string,Value*>fields;};
using napi_value=Value*;using napi_env=void*;
struct Call{std::vector<napi_value>args;};using napi_callback_info=Call*;
using JsCall=void(*)(napi_env,napi_value,void*,void*);
using Finalize=void(*)(napi_env,void*,void*);
struct Tsfn{napi_value callback;size_t capacity;void*context;void*finalData;JsCall js;Finalize finalize;std::vector<void*>queue;bool released=false;};
using napi_threadsafe_function=Tsfn*;
std::vector<std::unique_ptr<Value>>values;
std::vector<std::unique_ptr<Tsfn>>registrations;
struct Delivered{std::string callback;int value;std::string id;};std::vector<Delivered>delivered;
int64_t clockNs=1000000000;uint64_t touchEpoch=10;bool failFeedbackObject=false;
int clock_gettime(int,timespec*out){out->tv_sec=clockNs/1000000000;out->tv_nsec=clockNs%1000000000;return 0;}
napi_value value(){values.emplace_back(new Value());return values.back().get();}
int napi_get_cb_info(napi_env,napi_callback_info info,size_t*count,napi_value*out,void*,void*){
 size_t copied=std::min(*count,info->args.size());for(size_t i=0;i<copied;i++)out[i]=info->args[i];*count=copied;return 0;}
int napi_typeof(napi_env,napi_value v,napi_valuetype*out){*out=v&&v->function?napi_function:napi_undefined;return 0;}
int napi_create_string_utf8(napi_env,const char*text,size_t length,napi_value*out){*out=value();(*out)->text=length==static_cast<size_t>(-1)?std::string(text):std::string(text,length);return 0;}
int napi_create_int32(napi_env,int n,napi_value*out){*out=value();(*out)->integer=n;return 0;}
int napi_get_boolean(napi_env,bool n,napi_value*out){return napi_create_int32(nullptr,n?1:0,out);}
int napi_create_object(napi_env,napi_value*out){if(failFeedbackObject)throw std::bad_alloc();*out=value();return 0;}
int napi_set_named_property(napi_env,napi_value object,const char*key,napi_value field){object->fields[key]=field;return 0;}
int napi_get_undefined(napi_env,napi_value*out){*out=nullptr;return 0;}
int napi_call_function(napi_env,napi_value,napi_value cb,size_t count,napi_value*args,napi_value*){
 const bool button=count==2&&args[1]->fields.empty();
 delivered.push_back({cb->text,button?args[1]->integer:args[0]->integer,
 count==2?(button?args[0]->text:args[1]->fields["controlId"]->text):""});return 0;}
int napi_create_threadsafe_function(napi_env,napi_value cb,void*,napi_value,size_t capacity,size_t,
 void*finalData,Finalize finalize,void*context,JsCall js,napi_threadsafe_function*out){
 registrations.emplace_back(new Tsfn{cb,capacity,context,finalData,js,finalize,{}});*out=registrations.back().get();return 0;}
int napi_release_threadsafe_function(napi_threadsafe_function fn,int){fn->released=true;return 0;}
int napi_call_threadsafe_function(napi_threadsafe_function fn,void*data,int){if(fn->queue.size()>=fn->capacity)return 1;fn->queue.push_back(data);return 0;}
namespace amcl::napi{napi_value MakeBoolResult(napi_env,bool v){napi_value out; napi_get_boolean(nullptr,v,&out);return out;}}
namespace amcl::input{struct ResetSnapshot{uint64_t touch;};ResetSnapshot PlatformInputResetDomains(){return {touchEpoch};}}
// SDK调度边界：release不提前丢排队数据，旧call-js在新注册之后仍会被调用。
void drain(Tsfn*fn){auto pending=fn->queue;fn->queue.clear();for(auto*data:pending)fn->js(reinterpret_cast<void*>(1),fn->callback,fn->context,data);if(fn->released){fn->finalize(nullptr,fn->finalData,nullptr);fn->context=nullptr;}}
napi_value callback(const char*name){auto v=value();v->function=true;v->text=name;return v;}
'''
main = r'''
int main(){
 napi_env env=reinterpret_cast<void*>(1);
 Call oldH{{callback("old-haptic")}},newH{{callback("new-haptic")}};
 CHECK(OnHaptic(env,&oldH)->integer==1);auto*old=registrations.back().get();
 amcl_fire_haptic_tagged(1,"button",5,touchEpoch,clockNs,7);
 CHECK(OnHaptic(env,&newH)->integer==1);auto*fresh=registrations.back().get();
 amcl_fire_haptic_tagged(1,"current",6,touchEpoch,clockNs,7);
 drain(old);CHECK(delivered.empty());drain(fresh);CHECK(delivered.size()==1&&delivered.back().callback=="new-haptic"&&delivered.back().id=="current");
 delivered.clear();amcl_fire_haptic_tagged(1,"expired",6,touchEpoch,clockNs,7);clockNs+=300000000;drain(fresh);CHECK(delivered.empty());
 amcl_fire_haptic_tagged(1,"old-session",6,touchEpoch,clockNs,7);++touchEpoch;drain(fresh);CHECK(delivered.empty());
 // 输入线程队列显式16项，满队丢本次载荷；SDK对象分配失败由真实call-js出口吞掉副作用。
 for(int i=0;i<40;i++)amcl_fire_haptic_tagged(1,"bounded",6,touchEpoch,clockNs,7);
 CHECK(fresh->queue.size()==16);failFeedbackObject=true;drain(fresh);failFeedbackObject=false;CHECK(delivered.empty());
 Call oldB{{callback("old-button")}},newB{{callback("new-button")}};
 CHECK(OnButtonPressed(env,&oldB)->integer==1);auto*previous=registrations.back().get();
 amcl_fire_button_pressed("old",1);CHECK(OnButtonPressed(env,&newB)->integer==1);auto*current=registrations.back().get();
 amcl_fire_button_pressed("new",1);amcl_fire_button_pressed("new",0);
 CHECK(current->queue.size()==1);drain(previous);CHECK(delivered.empty());drain(current);
 CHECK(delivered.size()==1&&delivered.back().callback=="new-button"&&delivered.back().value==0&&delivered.back().id=="new");
 // 按钮JS参数为(id,pressed)，明确核第二参数，不能用字符串对象缺省的integer=0冒充RELEASE。
 CHECK(g_btnFeedback->pending.empty()&&!g_btnFeedback->wakeQueued);
 std::cout<<"PASS production NAPI feedback: old drain isolation, final state container, bounded queues, age and session rejection\n";
}
'''
with temporary_directory(prefix='touch-feedback-native-') as directory:
    path, binary = Path(directory) / 'feedback.cpp', Path(directory) / 'feedback.exe'
    def check(body, negative=False):
        path.write_text(prefix + body + main, encoding='utf-8', newline='\n')
        compile_cpp(path, binary)
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
        if negative:
            assert result.returncode != 0 and 'CHECK failed' in result.stderr, result.stdout + result.stderr
        else:
            assert result.returncode == 0, result.stdout + result.stderr
            print(result.stdout.strip())
    check(production)
    needle = 'if (!context->active || g_hapticFeedback != context) return;'
    assert production.count(needle) == 1
    check(production.replace(needle, '/* negative: accept retired registration */', 1), True)
    print('PASS negative control: retired haptic registration drains after new lease')
    wrong = production.replace('if (!context || !context->active || g_btnFeedback != context) return;', 'if (!context) return;', 1)
    wrong = wrong.replace('pending.swap(context->pending);', 'pending.swap(g_btnFeedback->pending);', 1)
    assert wrong != production
    check(wrong, True)
    print('PASS negative control: old button wake consumes new registration state')
