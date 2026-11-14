/**
 * 实际release读取/条件默认与生产参数装配片段的宿主回归。
 * 测试树全在调用方独占输出内；不装载VM、不操作用户JDK，不能授游戏或性能资格。
 */
#include "jvm/jvm_cf_policy.h"
#include "jvm/jdk_directory_lease.h"
#include "jvm/jdk_native_temp_contract.h"
#include "jvm/jvm_common_args.cpp"
#include <cassert>
#include <algorithm>
#include <dirent.h>
#include <fstream>
#include <iostream>
#include <vector>
#define AMCL_LOG_I(...) ((void)0)
#define MC_OHOS_BUILD_TESTS
struct JavaVMOption {char* optionString;void* extraInfo;};
static bool g_forkChildMode=false,g_qualificationCfExplicit=false;
static std::vector<std::string> g_extraArgs;
using amcl::jvm::LegacyCfExclusion;

/** 编译调用者机械提取的完整decision和common/extra装配，显式参数尾部必须逐项相同。 */
static std::vector<std::string> options(const std::string& files,const char* jdkVersion,
    const std::vector<std::string>& supplied,bool explicitFixture=false,
    amcl::jvm::NativeTempContract nativeTempContract=amcl::jvm::NativeTempContract::Legacy) {
    amcl::jdk::DirectoryReadLease lease;std::string error;
    assert(lease.acquire(files,jdkVersion,error));
    const std::string jdkDataDir=files+"/jdk"+(jdkVersion&&jdkVersion[0]?"/"+std::string(jdkVersion):"");
    g_extraArgs=supplied;g_forkChildMode=explicitFixture;g_qualificationCfExplicit=explicitFixture;
    std::vector<JavaVMOption> optVec;
#include "cf_release_decision.inc"
#include "cf_common_extra_options.inc"
    std::vector<std::string> result;
    for(const auto& option:optVec)result.push_back(option.optionString);
    assert(result.size()>=supplied.size());
    assert(std::equal(supplied.begin(),supplied.end(),result.end()-supplied.size()));
    std::cout<<"IDENTITY "<<releaseIdentity.major<<" "<<releaseIdentity.status<<" automatic="<<addAutomaticCfExclusion<<"\n";
    return result;
}
static int descriptors(){DIR* dir=opendir("/proc/self/fd");assert(dir);int count=0;while(readdir(dir))++count;closedir(dir);return count;}
static void put(const std::string& file,const std::string& value){std::ofstream out(file,std::ios::binary);out<<value;assert(out.good());}
static size_t broad(const std::vector<std::string>& values){size_t count=0;for(const auto& value:values)if(value==LegacyCfExclusion)++count;return count;}
static bool contains(const std::vector<std::string>& values,const std::string& value){return std::find(values.begin(),values.end(),value)!=values.end();}

int main(int argc,char**argv){
    assert(argc==2);const std::string root=argv[1];assert(mkdir(root.c_str(),0700)==0);assert(mkdir((root+"/jdk").c_str(),0700)==0);
    using amcl::jvm::ParseReleaseMajor;using amcl::jvm::ReadReleaseMajor;using amcl::jvm::NeedsLegacyCfDefault;
    // 同一个release字段来源；经典1.8和现代发行/EA尾缀可识别，DATE键不得冒充第二个版本。
    for(const auto& entry:std::vector<std::pair<std::string,int>>{{"1.8.0_482-b06",8},{"8.0.1",8},{"17.0.13+11",17},{"21.0.5",21},{"25-ea+9",25},{"29",29}}){
        const auto parsed=ParseReleaseMajor("JAVA_VERSION=\""+entry.first+"\"\nJAVA_VERSION_DATE=\"2026-01-01\"\n",nullptr);
        assert(parsed.major==entry.second);
    }
    for(const std::string text:{"", "JAVA_VERSION=17\n", "JAVA_VERSION=\"17\"\nJAVA_VERSION=\"17\"\n",
        "JAVA_VERSION=\"17\"\n JAVA_VERSION=\"25\"\n", "JAVA_VERSION=\"017\"\n", "JAVA_VERSION=\"17junk\"\n",
        "JAVA_VERSION=\"1.9.0\"\n", "JAVA_VERSION=\"17\" suffix\n"}){
        const auto parsed=ParseReleaseMajor(text,nullptr);assert(parsed.major==0 && NeedsLegacyCfDefault(parsed));
    }
    assert(ParseReleaseMajor("JAVA_VERSION=\"21\"\n","17").major==0);
    assert(ParseReleaseMajor("JAVA_VERSION=\"17\"\r\n","").major==17);
    assert(ParseReleaseMajor(std::string(65537,'x'),nullptr).major==0);
    assert(ParseReleaseMajor(std::string("JAVA_VERSION=\"17\"\n\0",19),nullptr).major==0);
    const std::vector<std::string> supplied={LegacyCfExclusion,"-XX:CompileCommand=dontinline,pkg/Owner.method",
        "-XX:CompileOnly=pkg/Owner.method",LegacyCfExclusion,"-XX:CompileCommandFile=/user/compiler.rules",
        "-XX:CompilerDirectivesFile=/loader/directives.json","-XX:CompileCommand=inline,pkg/Owner.method"};
    for(const std::string major:{"8","17","21","25"}){
        const std::string home=root+"/jdk/"+major;assert(mkdir(home.c_str(),0700)==0);
        put(home+"/release","JAVA_VERSION=\""+(major=="8"?"1.8.0_482":major+".0.1")+"\"\n");
        const size_t automatic=major=="25"?1:0;
        assert(broad(options(root,major.c_str(),{}))==automatic);
        assert(broad(options(root,major.c_str(),supplied))==automatic+2);
        assert(broad(options(root,major.c_str(),supplied,true))==2); // 资格臂自行提供完整策略。
        assert(broad(options(root,major.c_str(),{},false,amcl::jvm::NativeTempContract::StartupTmpdirV1))==automatic);
        auto explicitGc=options(root,major.c_str(),{"-XX:+UseG1GC"});assert(contains(explicitGc,"-XX:+UseG1GC")&&!contains(explicitGc,"-XX:+UseParallelGC"));
        assert(unlink((home+"/release").c_str())==0);
        assert(std::string(ReadReleaseMajor(home,major.c_str()).status)=="release-missing");
        assert(broad(options(root,major.c_str(),{}))==1); // 无release保持未知旧默认，不拒绝槽位。
        put(home+"/release",std::string("JAVA_VERSION=\"")+(major=="25"?"21":"25")+"\"\n");
        assert(std::string(ReadReleaseMajor(home,major.c_str()).status)=="release-slot-mismatch");assert(broad(options(root,major.c_str(),{}))==1);
        put(home+"/release",std::string(65537,'x'));assert(ReadReleaseMajor(home,major.c_str()).major==0);
        assert(unlink((home+"/release").c_str())==0);assert(mkdir((home+"/release").c_str(),0700)==0);
        assert(std::string(ReadReleaseMajor(home,major.c_str()).status)=="release-invalid-file");assert(rmdir((home+"/release").c_str())==0);
    }
    // legacy无数字槽时也只信release；布局标记和native-temp marker不会构成major证明。
    put(root+"/jdk/release","JAVA_VERSION=\"21.0.1\"\n");assert(broad(options(root,nullptr,{}))==0);
    assert(unlink((root+"/jdk/release").c_str())==0);assert(broad(options(root,nullptr,{},false,amcl::jvm::NativeTempContract::StartupTmpdirV1))==1);
    const auto invalid=ReadReleaseMajor(root+"/absent",nullptr);assert(invalid.major==0 && std::string(invalid.status)=="release-read-failed");
    const int before=descriptors();for(int i=0;i<256;++i)ReadReleaseMajor(root+"/jdk/17","17");assert(descriptors()==before);
    for(const auto& value:amcl::getCommonJvmArgs())assert(value!=LegacyCfExclusion);
    std::ofstream exported(root+"/common-args.txt",std::ios::binary);for(const auto& value:amcl::getCommonJvmArgs())exported<<value<<"\n";
    puts("PASS CF actual-source defaults: parser/known/unknown/slot conflict, shared lease, explicit compiler tail/order, qualification override, independent temp marker, GC unchanged, FD balanced");
}
