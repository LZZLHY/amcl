/** 机械消费生产TestHooks三臂构造及Fresh开关；不启动VM，不将测试规则混入产品默认。 */
#include "jvm/jvm_cf_policy.h"
#include "napi/jdk_java_fixture.h"
#include <cassert>
#include <fstream>
#include <iostream>
#include <vector>
namespace io=amcl::jdk::io;
struct RuntimeState {int value=0;int state()const{return value;}} g_runtimeOnce;
static void* g_jvm=nullptr;
static bool g_forkChildMode=false,g_qualificationCfExplicit=false;
#include "cf_explicit_setter.inc"
static void writeNew(int directory,const std::string& name,const std::string& text){
    io::Fd file(openat(directory,name.c_str(),O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600));assert(file.get()>=0);
    io::Write(file.get(),text.data(),text.size());
}
static bool cfProfile(const std::string& profile){return profile=="broad"||profile=="full"||profile=="c2-only";}
int main(int argc,char**argv){
    assert(argc==2);std::string root=argv[1];assert(mkdir(root.c_str(),0700)==0);
    assert(jvmSetQualificationCfExplicit(1)==-1);g_forkChildMode=true;
    g_runtimeOnce.value=1;assert(jvmSetQualificationCfExplicit(1)==-1);g_runtimeOnce.value=0;
    g_jvm=reinterpret_cast<void*>(1);assert(jvmSetQualificationCfExplicit(1)==-1);g_jvm=nullptr;
    unsigned count=0;
    for(const std::string major:{"8","17","21","25"})for(const std::string profile:{"broad","full","c2-only"}){
        if(major=="8"&&profile=="c2-only")continue;
        const std::string runPath=root+"/"+major+"-"+profile;assert(mkdir(runPath.c_str(),0700)==0);auto run=io::Directory(runPath);
        g_qualificationCfExplicit=false;
        std::vector<std::string> extraArgs;
#include "cf_explicit_arm.inc"
        assert(g_qualificationCfExplicit);
        std::vector<std::string> rules;
        for(const auto& option:extraArgs)if(option.rfind("-XX:CompileCommand=",0)==0)rules.push_back(option);
        std::vector<std::string> expected;
        if(major!="8"||profile!="full")expected.push_back(amcl::jvm::LegacyCfExclusion);
        if(major!="8"&&profile!="broad")expected.push_back(std::string(amcl::jvm::LegacyCfExclusion)+",false");
        assert(rules==expected);
        if(profile=="c2-only")assert(io::SmallFile(run.get(),"directives.json")==amcl::jdkqualification::CfC2OnlyDirectives);
        else assert(!io::Exists(run.get(),"directives.json"));
        std::cout<<major<<" "<<profile<<" rules="<<rules.size()<<"\n";++count;
    }
    assert(count==11);puts("PASS actual fixed CF construction: 11 arms and Fresh/tool/VM guards; original v2 ordered rules unchanged");
}
