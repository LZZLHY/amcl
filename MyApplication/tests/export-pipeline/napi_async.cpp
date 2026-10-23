/**
 * 真实napi_export.cpp + 真实文件数据面；SDK替身仅模拟JS对象/队列/故障返回。
 * 每个SDK入口断言owner线程，worker必须完全不调用JS；env退出等实际完成回调再撤屏障。
 */
#define NAPI_EXTERN extern
// GCC宿主仅移除OHOS版本可用性注解，保留真实SDK类型、声明和其余编译器属性。
#define __availability__(...)
#include "../../entry/src/main/cpp/napi/napi_export.cpp"
#undef __availability__
#include "../../entry/src/main/cpp/download/hmac_sha256.h"
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <cstdlib>
#include <set>
#include <dirent.h>

#define CHECK(x) do { if(!(x)){std::cerr<<"EXPORT NAPI CHECK "<<__LINE__<<": "<<#x<<std::endl;std::exit(2);} }while(false)
struct napi_value__ {
    enum Type { Object, Number, Boolean, String, Array, Method, Promise } type=Object;
    double number=0;bool flag=false;std::string text;std::map<std::string,napi_value> properties;
    std::vector<napi_value> elements;int promiseState=0;napi_value resolution=nullptr;
};
// SDK deferred是一次性对象；宿主保留tombstone以确定报错，不能把已释放指针重用当成重试。
struct napi_deferred__ {napi_value promise;bool live=true;};
struct napi_callback_info__ {napi_value argument;void* data;};
struct Method {napi_callback callback;void* data;};
struct napi_async_work__ {napi_env env;napi_async_execute_callback execute;napi_async_complete_callback complete;void* data;};
struct napi_async_cleanup_hook_handle__ {napi_env env;napi_async_cleanup_hook hook;void* data;};
struct napi_handle_scope__ {napi_env env;};
struct napi_env__ {
    std::thread::id owner=std::this_thread::get_id();std::map<std::string,Method> methods;
    std::vector<std::unique_ptr<napi_value__>> values;std::vector<std::unique_ptr<napi_deferred__>> deferreds;
    std::vector<napi_async_work> queue;std::set<napi_async_work> live;
    napi_async_cleanup_hook_handle cleanup=nullptr;napi_value exception=nullptr;
    bool createFail=false,queueFail=false,cleanupStarted=false;
    unsigned deleteFailures=0,cleanupRemoveFailures=0,rejectFailures=0,resolveFailures=0,unsettledResolveFailures=0;
    unsigned errorValueFailures=0,created=0,deleted=0,settlements=0,resolveCalls=0,rejectCalls=0,insideSettlement=0;
    std::function<void()> settlementHook,objectHook;
    unsigned scopesOpened=0,scopesClosed=0,scopesLive=0,scopesPeak=0;
};
namespace {
void Owner(napi_env e){CHECK(e && e->owner==std::this_thread::get_id());}
napi_value New(napi_env e,napi_value__::Type type=napi_value__::Object){Owner(e);auto v=std::make_unique<napi_value__>();v->type=type;auto* p=v.get();e->values.push_back(std::move(v));return p;}
napi_value Num(napi_env e,double n){auto v=New(e,napi_value__::Number);v->number=n;return v;}
napi_value Str(napi_env e,const std::string& s){auto v=New(e,napi_value__::String);v->text=s;return v;}
napi_value Bool(napi_env e,bool b){auto v=New(e,napi_value__::Boolean);v->flag=b;return v;}
void Set(napi_value o,const char* k,napi_value v){o->properties[k]=v;}
napi_value Call(napi_env e,const char* name,napi_value arg){const auto m=e->methods.at(name);napi_callback_info__ info{arg,m.data};return m.callback(e,&info);}
uint64_t Id(napi_value h){CHECK(h);return h->properties.at("jobId")->number;}
bool Release(napi_env e,uint64_t id){auto v=Call(e,"exportJobRelease",Num(e,id));CHECK(v);return v->flag;}
napi_value Query(napi_env e,uint64_t id){return Call(e,"exportJobQuery",Num(e,id));}
size_t Fds(){DIR*d=opendir("/proc/self/fd");CHECK(d);size_t n=0;while(readdir(d))++n;closedir(d);return n;}
std::shared_ptr<amcl::napi::Context> Context(napi_env e){return static_cast<amcl::napi::Holder*>(e->methods.at("exportJobQuery").data)->context;}
void ClearValues(napi_env e){CHECK(e->queue.empty() && e->live.empty());e->values.clear();e->deferreds.clear();e->exception=nullptr;}
void Complete(napi_env e,bool execute=true,napi_status status=napi_ok,bool checkRelease=true){
    CHECK(e->queue.size()==1);auto work=e->queue.front();e->queue.clear();
    if(execute){std::thread t([&]{work->execute(nullptr,work->data);});t.join();}
    if(checkRelease){auto c=Context(e);CHECK(c->jobs.size()==1);const auto id=c->jobs.begin()->first;
        CHECK(!Release(e,id));auto q=Query(e,id);CHECK(q->properties.at("exists")->flag && !q->properties.at("settled")->flag);}
    work->complete(e,status,work->data);
}
napi_value Hash(napi_env e,int fd,size_t size,bool sha1=true){auto s=New(e);Set(s,"fd",Num(e,fd));Set(s,"size",Num(e,size));Set(s,"sha1",Bool(e,sha1));return Call(e,"exportFileHashStart",s);}
napi_value HashPurpose(napi_env e,int fd,size_t size,bool sha1,bool sha256){auto s=New(e);Set(s,"fd",Num(e,fd));Set(s,"size",Num(e,size));Set(s,"sha1",Bool(e,sha1));Set(s,"sha256",Bool(e,sha256));return Call(e,"exportFileHashStart",s);}
void Cleanup(napi_env e){CHECK(e->cleanup);e->cleanupStarted=true;auto h=e->cleanup;h->hook(h,h->data);}
std::string Sha(const std::string& s){download::Sha256 h;h.update(s.data(),s.size());return h.finalizeHex();}
void Put(const std::filesystem::path& p,const std::string& s){std::filesystem::create_directories(p.parent_path());std::ofstream f(p,std::ios::binary);f<<s;CHECK(f.good());}
unsigned passed=0;
void Test(const char* label,const std::function<void()>& fn){const char* filter=std::getenv("AMCL_EXPORT_NAPI_CASE");if(filter && std::string(label).find(filter)==std::string::npos)return;const auto f=Fds();fn();CHECK(Fds()==f);++passed;std::cout<<"PASS "<<label<<std::endl;}
void Microtasks(napi_env e) {auto hook=std::move(e->settlementHook);e->settlementHook={};++e->insideSettlement;if(hook)hook();--e->insideSettlement;}
void Drain(napi_env e,const std::vector<uint64_t>& ids){for(uint64_t id:ids){CHECK(!e->queue.empty());auto w=e->queue.front();e->queue.erase(e->queue.begin());std::thread t([&]{w->execute(nullptr,w->data);});t.join();w->complete(e,napi_ok,w->data);CHECK(Release(e,id));}}
}

extern "C" napi_status napi_get_cb_info(napi_env e,napi_callback_info i,size_t* count,napi_value* args,napi_value*,void** data){Owner(e);*count=1;args[0]=i->argument;*data=i->data;return napi_ok;}
extern "C" napi_status napi_create_object(napi_env e,napi_value* out){const auto hook=e->objectHook;if(hook)hook();*out=New(e);return napi_ok;}
extern "C" napi_status napi_get_undefined(napi_env e,napi_value* out){if(e->errorValueFailures){--e->errorValueFailures;return napi_generic_failure;}*out=New(e);return napi_ok;}
extern "C" napi_status napi_get_null(napi_env e,napi_value* out){if(e->errorValueFailures){--e->errorValueFailures;return napi_generic_failure;}*out=New(e);return napi_ok;}
extern "C" napi_status napi_open_handle_scope(napi_env e,napi_handle_scope* out){Owner(e);*out=new napi_handle_scope__{e};++e->scopesOpened;++e->scopesLive;e->scopesPeak=std::max(e->scopesPeak,e->scopesLive);return napi_ok;}
extern "C" napi_status napi_close_handle_scope(napi_env e,napi_handle_scope scope){Owner(e);CHECK(scope->env==e && e->scopesLive);++e->scopesClosed;--e->scopesLive;delete scope;return napi_ok;}
extern "C" napi_status napi_create_double(napi_env e,double n,napi_value* out){*out=Num(e,n);return napi_ok;}
extern "C" napi_status napi_get_boolean(napi_env e,bool b,napi_value* out){*out=Bool(e,b);return napi_ok;}
extern "C" napi_status napi_get_value_bool(napi_env e,napi_value v,bool* out){Owner(e);if(v->type!=napi_value__::Boolean)return napi_boolean_expected;*out=v->flag;return napi_ok;}
extern "C" napi_status napi_get_value_double(napi_env e,napi_value v,double* out){Owner(e);if(v->type!=napi_value__::Number)return napi_number_expected;*out=v->number;return napi_ok;}
extern "C" napi_status napi_create_string_utf8(napi_env e,const char* s,size_t n,napi_value* out){*out=Str(e,std::string(s,n==NAPI_AUTO_LENGTH?std::strlen(s):n));return napi_ok;}
extern "C" napi_status napi_get_value_string_utf8(napi_env e,napi_value v,char* out,size_t n,size_t* actual){Owner(e);if(v->type!=napi_value__::String)return napi_string_expected;*actual=out?std::min(v->text.size(),n?n-1:0):v->text.size();if(out&&n){std::memcpy(out,v->text.data(),*actual);out[*actual]=0;}return napi_ok;}
extern "C" napi_status napi_set_named_property(napi_env e,napi_value o,const char*k,napi_value v){Owner(e);Set(o,k,v);return napi_ok;}
extern "C" napi_status napi_get_named_property(napi_env e,napi_value o,const char*k,napi_value* out){Owner(e);if(o->type==napi_value__::String && std::string(k)=="toLowerCase"){*out=New(e,napi_value__::Method);return napi_ok;}auto i=o->properties.find(k);if(i==o->properties.end())return napi_invalid_arg;*out=i->second;return napi_ok;}
extern "C" napi_status napi_has_named_property(napi_env e,napi_value o,const char*k,bool* out){Owner(e);*out=o->properties.count(k);return napi_ok;}
extern "C" napi_status napi_is_array(napi_env e,napi_value o,bool* out){Owner(e);*out=o->type==napi_value__::Array;return napi_ok;}
extern "C" napi_status napi_get_array_length(napi_env e,napi_value o,uint32_t* out){Owner(e);*out=o->elements.size();return napi_ok;}
extern "C" napi_status napi_get_element(napi_env e,napi_value o,uint32_t i,napi_value* out){Owner(e);if(i>=o->elements.size())return napi_invalid_arg;*out=o->elements[i];return napi_ok;}
extern "C" napi_status napi_coerce_to_object(napi_env e,napi_value v,napi_value* out){Owner(e);*out=v;return napi_ok;}
extern "C" napi_status napi_call_function(napi_env e,napi_value recv,napi_value f,size_t,const napi_value*,napi_value* out){Owner(e);CHECK(f->type==napi_value__::Method);auto text=recv->text;for(char& c:text)if(c>='A'&&c<='Z')c+='a'-'A';if(text=="Ä")text="ä";*out=Str(e,text);return napi_ok;}
extern "C" napi_status napi_is_exception_pending(napi_env e,bool* out){Owner(e);*out=e->exception!=nullptr;return napi_ok;}
extern "C" napi_status napi_get_and_clear_last_exception(napi_env e,napi_value* out){Owner(e);*out=e->exception;e->exception=nullptr;return napi_ok;}
extern "C" napi_status napi_throw_error(napi_env e,const char* code,const char* msg){e->exception=New(e);Set(e->exception,"code",Str(e,code));Set(e->exception,"message",Str(e,msg));return napi_ok;}
extern "C" napi_status napi_create_error(napi_env e,napi_value code,napi_value message,napi_value* out){if(e->errorValueFailures){--e->errorValueFailures;return napi_generic_failure;}*out=New(e);Set(*out,"code",code);Set(*out,"message",message);return napi_ok;}
extern "C" napi_status napi_create_promise(napi_env e,napi_deferred* out,napi_value* promise){*promise=New(e,napi_value__::Promise);auto d=std::make_unique<napi_deferred__>();d->promise=*promise;*out=d.get();e->deferreds.push_back(std::move(d));return napi_ok;}
extern "C" napi_status napi_resolve_deferred(napi_env e,napi_deferred d,napi_value v){
    Owner(e);CHECK(!e->cleanupStarted && d && d->live && d->promise->promiseState==0);d->live=false;++e->resolveCalls;
    // 对照OpenHarmony：提交会执行微任务并消费deferred，随后GET_RETURN_STATUS仍可能非ok。
    if(e->unsettledResolveFailures){--e->unsettledResolveFailures;Microtasks(e);return napi_generic_failure;}
    d->promise->promiseState=1;d->promise->resolution=v;e->settlements++;Microtasks(e);
    if(e->resolveFailures){--e->resolveFailures;return napi_generic_failure;}return napi_ok;
}
extern "C" napi_status napi_reject_deferred(napi_env e,napi_deferred d,napi_value v){
    Owner(e);CHECK(!e->cleanupStarted && d && d->live && d->promise->promiseState==0);d->live=false;++e->rejectCalls;
    d->promise->promiseState=2;d->promise->resolution=v;e->settlements++;Microtasks(e);
    if(e->rejectFailures){--e->rejectFailures;return napi_generic_failure;}return napi_ok;
}
extern "C" napi_status napi_create_async_work(napi_env e,napi_value,napi_value,napi_async_execute_callback x,napi_async_complete_callback c,void*d,napi_async_work* out){Owner(e);if(e->createFail)return napi_generic_failure;*out=new napi_async_work__{e,x,c,d};e->live.insert(*out);e->created++;return napi_ok;}
extern "C" napi_status napi_queue_async_work(napi_env e,napi_async_work w){Owner(e);if(e->queueFail)return napi_generic_failure;e->queue.push_back(w);return napi_ok;}
extern "C" napi_status napi_delete_async_work(napi_env e,napi_async_work w){Owner(e);CHECK(w->env==e && e->live.count(w));if(e->deleteFailures){--e->deleteFailures;return napi_generic_failure;}e->live.erase(w);e->deleted++;delete w;return napi_ok;}
extern "C" napi_status napi_define_properties(napi_env e,napi_value,size_t n,const napi_property_descriptor* p){Owner(e);for(size_t i=0;i<n;++i)e->methods[p[i].utf8name]={p[i].method,p[i].data};return napi_ok;}
extern "C" napi_status napi_add_async_cleanup_hook(napi_env e,napi_async_cleanup_hook hook,void* data,napi_async_cleanup_hook_handle* out){Owner(e);CHECK(!e->cleanup);e->cleanup=new napi_async_cleanup_hook_handle__{e,hook,data};if(out)*out=e->cleanup;return napi_ok;}
extern "C" napi_status napi_remove_async_cleanup_hook(napi_async_cleanup_hook_handle h){Owner(h->env);CHECK(h->env->cleanup==h);if(h->env->cleanupRemoveFailures){--h->env->cleanupRemoveFailures;return napi_generic_failure;}h->env->cleanup=nullptr;delete h;return napi_ok;}

int main(int argc,char**argv){
    CHECK(argc==2);namespace fs=std::filesystem;const auto root=fs::absolute(argv[1])/"napi-application";fs::create_directories(root);CHECK(amcl::ConfigureUpdateInstallFilesRoot(root.string()));
    const auto file=root/"hash";const std::string bytes(130003,'x');Put(file,bytes);
    Test("registered six methods real fd hash and query/release settlement",[&]{
        napi_env__ e;amcl::napi::registerExportNapi(&e,nullptr);CHECK(e.methods.size()==6);
        const int fd=open(file.c_str(),O_RDONLY|O_CLOEXEC);CHECK(fd>=0 && lseek(fd,19,SEEK_SET)==19);auto h=Hash(&e,fd,bytes.size());const auto id=Id(h);auto p=h->properties.at("completion");CHECK(p->promiseState==0);Complete(&e);CHECK(p->promiseState==1);
        const auto result=p->resolution;CHECK(result->properties.at("sha256")->text==Sha(bytes) && result->properties.at("sha1")->text.size()==40 && lseek(fd,0,SEEK_CUR)==19);close(fd);
        CHECK(Query(&e,id)->properties.at("settled")->flag);CHECK(Release(&e,id) && Release(&e,id));auto q=Query(&e,id);CHECK(!q->properties.at("exists")->flag && q->properties.at("released")->flag && q->properties.at("settled")->flag);CHECK(!Release(&e,9007199254740990ULL));Cleanup(&e);CHECK(!e.cleanup && e.created==e.deleted);
    });
    Test("fd duplicated at Start optional SHA1 and caller close safe",[&]{napi_env__ e;amcl::napi::registerExportNapi(&e,nullptr);const int fd=open(file.c_str(),O_RDONLY);auto h=Hash(&e,fd,bytes.size(),false);close(fd);Complete(&e);CHECK(h->properties.at("completion")->resolution->properties.at("sha1")->text.empty());CHECK(Release(&e,Id(h)));Cleanup(&e);});
    Test("explicit digest purposes keep legacy default and byte counters",[&]{
        for(const auto& input:std::vector<std::string>{"","abc",std::string(190003,'q')})for(unsigned mode=0;mode<3;++mode){
            napi_env__ e;amcl::napi::registerExportNapi(&e,nullptr);Put(root/"purpose",input);const int fd=open((root/"purpose").c_str(),O_RDONLY);CHECK(fd>=0 && lseek(fd,23,SEEK_SET)==23);
            const bool a=mode!=1,b=mode!=0;auto h=HashPurpose(&e,fd,input.size(),a,b);Complete(&e);auto p=h->properties.at("completion");CHECK(p->promiseState==1);
            const auto v=p->resolution;CHECK(v->properties.at("size")->number==input.size() && v->properties.at("payloadBytes")->number==input.size());
            CHECK(v->properties.at("sha1")->text.empty()==!a && v->properties.at("sha256")->text.empty()==!b);
            if(a && input.empty())CHECK(v->properties.at("sha1")->text=="da39a3ee5e6b4b0d3255bfef95601890afd80709");
            if(a && input=="abc")CHECK(v->properties.at("sha1")->text=="a9993e364706816aba3e25717850c26c9cd0d89d");
            // 独立Python hashlib固定的多块expected，避免只用同一产品SHA生成expected自证。
            if(a && input.size()==190003)CHECK(v->properties.at("sha1")->text=="02df062f872897cd74ee6480be270265acd0cb5a");
            if(b)CHECK(v->properties.at("sha256")->text==Sha(input));
            auto q=Query(&e,Id(h));CHECK(q->properties.at("bytesDone")->number==input.size() && q->properties.at("bytesTotal")->number==input.size() && lseek(fd,0,SEEK_CUR)==23);
            close(fd);CHECK(Release(&e,Id(h)));Cleanup(&e);
        }
        // 原Hash helper完全不提供sha256字段，前面的默认双hash/SHA256-only正式组继续覆盖兼容。
    });
    Test("invalid hash purposes reject before dup queue or registry changes",[&]{
        napi_env__ e;amcl::napi::registerExportNapi(&e,nullptr);const auto before=Fds();
        CHECK(HashPurpose(&e,INT32_MAX,0,false,false)==nullptr && e.exception && e.exception->properties.at("code")->text=="InvalidConfig");
        CHECK(Fds()==before && e.queue.empty() && e.live.empty() && e.created==0 && Context(&e)->jobs.empty());e.exception=nullptr;
        for(const char* field:{"sha1","sha256"}){auto s=New(&e);Set(s,"fd",Num(&e,INT32_MAX));Set(s,"size",Num(&e,0));Set(s,field,Str(&e,"false"));CHECK(Call(&e,"exportFileHashStart",s)==nullptr && e.exception && e.created==0 && Context(&e)->jobs.empty());e.exception=nullptr;}
        const int fd=open(file.c_str(),O_RDONLY);auto h=HashPurpose(&e,fd,bytes.size(),true,false);close(fd);CHECK(Call(&e,"exportJobCancel",Num(&e,Id(h)))->flag);Complete(&e,false,napi_cancelled);CHECK(h->properties.at("completion")->promiseState==2 && Query(&e,Id(h))->properties.at("settled")->flag && Release(&e,Id(h)));Cleanup(&e);
    });
    Test("create queue and SDK delete failures keep truthful resource ownership",[&]{
        napi_env__ e;amcl::napi::registerExportNapi(&e,nullptr);const int fd=open(file.c_str(),O_RDONLY);
        for(int mode=0;mode<2;++mode){e.createFail=mode==0;e.queueFail=mode==1;const auto n=Fds();auto h=Hash(&e,fd,bytes.size());CHECK(h && h->properties.at("completion")->promiseState==2 && e.queue.empty() && Fds()==n);CHECK(Release(&e,Id(h)));}e.createFail=e.queueFail=false;
        auto h=Hash(&e,fd,bytes.size());e.deleteFailures=1;Complete(&e);CHECK(h->properties.at("completion")->promiseState==0 && !Context(&e)->jobs.at(Id(h))->core.settled && e.live.size()==1);
        // 与实际Parent相同：仍在await completion时timer只query；query回收成功才允许Promise拒绝。
        CHECK(Query(&e,Id(h))->properties.at("settled")->flag && h->properties.at("completion")->promiseState==2 && e.live.empty());CHECK(Release(&e,Id(h)));close(fd);Cleanup(&e);CHECK(e.created==e.deleted);
    });
    Test("cancel queued work closes dup only at actual completion",[&]{napi_env__ e;amcl::napi::registerExportNapi(&e,nullptr);const int fd=open(file.c_str(),O_RDONLY);auto h=Hash(&e,fd,bytes.size());close(fd);CHECK(Call(&e,"exportJobCancel",Num(&e,Id(h)))->flag);CHECK(!Release(&e,Id(h)));Complete(&e,false,napi_cancelled);CHECK(h->properties.at("completion")->promiseState==2 && Query(&e,Id(h))->properties.at("settled")->flag);CHECK(Release(&e,Id(h)));Cleanup(&e);});
    Test("SDK consume then nonok never reuses resolve or reject deferred",[&]{
        for(unsigned mode=0;mode<3;++mode){napi_env__ e;amcl::napi::registerExportNapi(&e,nullptr);const int fd=open(file.c_str(),O_RDONLY);auto h=Hash(&e,fd,bytes.size()+(mode==1?1:0));close(fd);
            if(mode==0)e.resolveFailures=1;
            if(mode==1)e.rejectFailures=1;
            if(mode==2)e.unsettledResolveFailures=1;
            Complete(&e);
            CHECK(Context(&e)->jobs.at(Id(h))->core.settled && e.live.empty());
            for(unsigned i=0;i<4;++i){auto q=Query(&e,Id(h));CHECK(q->properties.at("settled")->flag && q->properties.at("errorCode")->text=="DeliveryFailed");}
            CHECK(e.resolveCalls+e.rejectCalls==1 && (mode!=2 || h->properties.at("completion")->promiseState==0));CHECK(Release(&e,Id(h)));Cleanup(&e);
        }
    });
    Test("queue failure keeps consumed SDK rejection failure observable",[&]{
        for(bool create:{false,true}){napi_env__ e;amcl::napi::registerExportNapi(&e,nullptr);e.createFail=create;e.queueFail=!create;e.rejectFailures=1;const int fd=open(file.c_str(),O_RDONLY);auto h=Hash(&e,fd,bytes.size());close(fd);CHECK(h && e.queue.empty() && e.live.empty() && e.rejectCalls==1);
            auto q=Query(&e,Id(h));CHECK(q->properties.at("exists")->flag && q->properties.at("settled")->flag && q->properties.at("errorCode")->text=="DeliveryFailed");CHECK(e.rejectCalls==1 && Release(&e,Id(h)));Cleanup(&e);}
    });
    Test("only unsubmitted error-value preparation may retry",[&]{
        napi_env__ e;amcl::napi::registerExportNapi(&e,nullptr);const int fd=open(file.c_str(),O_RDONLY);auto h=Hash(&e,fd,bytes.size()+1);close(fd);e.rejectFailures=1;Complete(&e);
        CHECK(h->properties.at("completion")->promiseState==2 && e.rejectCalls==1);CHECK(Release(&e,Id(h)));Cleanup(&e);
        napi_env__ retry;amcl::napi::registerExportNapi(&retry,nullptr);const int next=open(file.c_str(),O_RDONLY);auto pending=Hash(&retry,next,bytes.size()+1);close(next);retry.errorValueFailures=6;Complete(&retry);
        CHECK(pending->properties.at("completion")->promiseState==0 && retry.rejectCalls==0 && !Release(&retry,Id(pending)));
        CHECK(Query(&retry,Id(pending))->properties.at("settled")->flag && pending->properties.at("completion")->promiseState==2 && retry.rejectCalls==1);CHECK(Release(&retry,Id(pending)));Cleanup(&retry);
    });
    Test("Promise microtasks reenter Query Release and cancellation exactly once",[&]{
        for(bool reject:{false,true}){napi_env__ e;amcl::napi::registerExportNapi(&e,nullptr);const int fd=open(file.c_str(),O_RDONLY);auto h=Hash(&e,fd,bytes.size()+(reject?1:0));close(fd);const auto id=Id(h);
            e.settlementHook=[&]{CHECK(!Release(&e,id));auto q=Query(&e,id);CHECK(q->properties.at("exists")->flag && q->properties.at("settled")->flag);CHECK(!Call(&e,"exportJobCancel",Num(&e,id))->flag);CHECK(!Release(&e,id));};
            Complete(&e);CHECK(e.resolveCalls+e.rejectCalls==1 && h->properties.at("completion")->promiseState==(reject?2:1));CHECK(Release(&e,id));Cleanup(&e);
        }
    });
    Test("result construction reentry cannot steal deferred or release owner",[&]{
        napi_env__ e;amcl::napi::registerExportNapi(&e,nullptr);const int fd=open(file.c_str(),O_RDONLY);auto h=Hash(&e,fd,bytes.size());close(fd);const auto id=Id(h);unsigned reentries=0;
        e.objectHook=[&]{e.objectHook={};++reentries;CHECK(h->properties.at("completion")->promiseState==0 && e.resolveCalls==0);CHECK(!Release(&e,id));auto q=Query(&e,id);CHECK(q->properties.at("exists")->flag && q->properties.at("settled")->flag);};
        Complete(&e,true,napi_ok,false);CHECK(reentries==1 && e.resolveCalls==1 && h->properties.at("completion")->promiseState==1 && Release(&e,id));Cleanup(&e);
    });
    Test("Query pins shared owner across release and registry rehash in NAPI",[&]{
        napi_env__ e;amcl::napi::registerExportNapi(&e,nullptr);Put(root/"pin-empty","");const int fd=open((root/"pin-empty").c_str(),O_RDONLY);auto h=Hash(&e,fd,0);const auto id=Id(h);e.deleteFailures=1;Complete(&e);CHECK(h->properties.at("completion")->promiseState==0);
        std::vector<uint64_t> ids;
        // SDK delete失败已记core首因，query回收后将reject；任意实际终态均可触发此post-Deliver重入。
        e.objectHook=[&]{if(h->properties.at("completion")->promiseState==0 || e.insideSettlement)return;e.objectHook={};CHECK(Release(&e,id));for(unsigned i=0;i<80;++i)ids.push_back(Id(Hash(&e,fd,0)));};
        auto q=Query(&e,id);CHECK(q && q->properties.at("jobId")->number==id && q->properties.at("settled")->flag && ids.size()==80);CHECK(Release(&e,id));Drain(&e,ids);close(fd);Cleanup(&e);
    });
    Test("preexisting SDK exception rejects once before resolving",[&]{
        napi_env__ e;amcl::napi::registerExportNapi(&e,nullptr);const int fd=open(file.c_str(),O_RDONLY);auto h=Hash(&e,fd,bytes.size());close(fd);e.exception=Str(&e,"existing SDK error");Complete(&e);CHECK(h->properties.at("completion")->promiseState==2 && e.rejectCalls==1 && e.resolveCalls==0);CHECK(Release(&e,Id(h)));Cleanup(&e);
    });
    Test("real write and verify methods match plan and Unicode collision rejection",[&]{
        napi_env__ e;amcl::napi::registerExportNapi(&e,nullptr);const std::string job="game-export/work/napi-real";Put(root/job/"snapshot/版本.json","{}\n");
        auto spec=New(&e);Set(spec,"filesDir",Str(&e,root.string()));Set(spec,"jobRelative",Str(&e,job));Set(spec,"snapshotRelative",Str(&e,"snapshot"));Set(spec,"archiveRelative",Str(&e,"export.zip"));Set(spec,"workerCount",Num(&e,4));
        auto entries=New(&e,napi_value__::Array);auto entry=New(&e);Set(entry,"path",Str(&e,"版本.json"));Set(entry,"size",Num(&e,3));Set(entry,"sha256",Str(&e,Sha("{}\n")));Set(entry,"directory",Bool(&e,false));entries->elements.push_back(entry);Set(spec,"entries",entries);
        auto h=Call(&e,"exportArchiveStart",spec);Complete(&e);auto promise=h->properties.at("completion");CHECK(promise->promiseState==1 && promise->resolution->properties.at("operation")->text=="write" && promise->resolution->properties.at("payloadBytes")->number==3);const auto digest=promise->resolution->properties.at("sha256")->text;CHECK(Release(&e,Id(h)));
        h=Call(&e,"exportArchiveVerifyStart",spec);Complete(&e);CHECK(h->properties.at("completion")->promiseState==1 && h->properties.at("completion")->resolution->properties.at("sha256")->text==digest);CHECK(Release(&e,Id(h)));
        auto copy=New(&e);copy->properties=entry->properties;Set(entry,"path",Str(&e,"Ä"));Set(copy,"path",Str(&e,"ä"));entries->elements.push_back(copy);CHECK(Call(&e,"exportArchiveStart",spec)==nullptr && e.exception && e.queue.empty() && Context(&e)->jobs.empty());
        CHECK(e.scopesOpened==4 && e.scopesOpened==e.scopesClosed && e.scopesLive==0 && e.scopesPeak==1);Cleanup(&e);
    });
    Test("async env teardown waits running/queued work and suppresses JS settlement",[&]{
        for(bool execute:{false,true}){napi_env__ e;amcl::napi::registerExportNapi(&e,nullptr);const int fd=open(file.c_str(),O_RDONLY);auto h=Hash(&e,fd,bytes.size());(void)h;close(fd);CHECK(e.queue.size()==1);auto w=e.queue[0];e.queue.clear();
            std::thread t;if(execute)t=std::thread([w]{w->execute(nullptr,w->data);});Cleanup(&e);CHECK(e.cleanup);e.deleteFailures=1;e.cleanupRemoveFailures=1;if(execute)t.join();w->complete(&e,execute?napi_ok:napi_cancelled,w->data);CHECK(!e.cleanup && e.live.empty() && e.created==e.deleted && e.settlements==0);}
    });
    Test("ten thousand hashes release storage bounded and env IDs isolated",[&]{
        napi_env__ a,b;amcl::napi::registerExportNapi(&a,nullptr);amcl::napi::registerExportNapi(&b,nullptr);Put(root/"empty","");const int fd=open((root/"empty").c_str(),O_RDONLY);uint64_t first=0,last=0;
        for(unsigned i=0;i<10000;++i){napi_env e=i%2?&a:&b;auto h=Hash(e,fd,0);last=Id(h);if(!first)first=last;CHECK(!Release(e==&a?&b:&a,last));Complete(e);CHECK(h->properties.at("completion")->promiseState==1 && Release(e,last));CHECK(Context(e)->jobs.empty() && Context(e)->retired.size()<=256);ClearValues(e);}
        CHECK(Context(&a)->retired.size()==256 && Context(&b)->retired.size()==256);CHECK(!Release(&a,first) && !Release(&b,first));CHECK(Release(&a,last) && !Release(&b,last));close(fd);Cleanup(&a);Cleanup(&b);
    });
    Test("foreign env callback rejected before work and all SDK calls stay owner",[&]{napi_env__ a,b;amcl::napi::registerExportNapi(&a,nullptr);amcl::napi::registerExportNapi(&b,nullptr);auto m=a.methods.at("exportJobQuery");napi_callback_info__ info{Num(&b,1),m.data};CHECK(m.callback(&b,&info)==nullptr && b.exception && a.queue.empty() && b.queue.empty());Cleanup(&a);Cleanup(&b);});
    CHECK(passed>0);std::cout<<"EXPORT_NAPI_TOTAL "<<passed<<" PASS"<<std::endl;return 0;
}
