/** 使用真实 dlopen/dladdr、槽文件、SHA、环境/CWD和fd；只对系统字体路径做明确替身映射。 */
#include <unistd.h>
#include <cstdlib>
#include <cstring>
static int FixtureAccess(const char* path,int flags) {
    if (strcmp(path,"/system/fonts/fixture.ttf")==0) return access(getenv("AMCL_INSTALLED_FONT_FILE"),flags);
    return access(path,flags);
}
#define access FixtureAccess
#define MC_OHOS_BUILD_TESTS
#define AMCL_FONTCONFIG_USE_PUBLIC_HEADER
#include "napi/jdk_font_defaults_qualification.h"
#undef access
#include <filesystem>
#include <fstream>
#include <iostream>

static std::string searchPath, errorText, modeName, foreignPath;
static int opens=0, closes=0;
extern "C" void elf_set_search_path(const char* paths) {
    searchPath=paths;
    if(modeName=="search-throw" && !searchPath.empty()) throw std::runtime_error("controlled setter failure");
}
extern "C" void* elf_dlopen(const char* path,int flags) {
    void* result=dlopen(path,flags);
    if(result)++opens;else {const char* error=dlerror();errorText=error?error:"unknown";}
    return result;
}
extern "C" void* elf_dlsym(void* handle,const char* name){return dlsym(handle,name);}
extern "C" int elf_dladdr(const void* address,void* output){
    auto* info=static_cast<Dl_info*>(output);const int result=dladdr(address,info);
    if(result && modeName=="wrong-origin" && strstr(info->dli_fname,"libfontconfig.so")) info->dli_fname=foreignPath.c_str();
    return result;
}
extern "C" int elf_dlclose(void* handle){++closes;int result=dlclose(handle);return modeName=="close-fails"?-1:result;}
extern "C" const char* elf_error(){return errorText.c_str();}
static void Require(bool good,const char* message){if(!good)throw std::runtime_error(message);}

int main(int argc,char** argv){
    try {
        Require(argc==4,"arguments");modeName=argv[1];
        // 子进程使用真实非root UID：/ 确实不可写，资格头无须伪造此权限结果。
        if(geteuid()==0){Require(setgid(65534)==0 && setuid(65534)==0,"nonroot test identity");}
        const std::filesystem::path work=argv[2],fixtures=argv[3];
        std::filesystem::create_directories(work/"runtime/lib/server");
        std::filesystem::create_directories(work/"report");
        for(const char* name:{"libfontconfig.so","libfreetype.so"})
            std::filesystem::copy_file(fixtures/name,work/"runtime/lib"/name);
        std::filesystem::copy_file(fixtures/"libfontconfig.so",work/"foreign.so");foreignPath=(work/"foreign.so").string();
        {std::ofstream file(work/"runtime/sentinel");file<<"unchanged";}
        {std::ofstream file(work/"fixture.ttf");file<<"fixture font is not real";}
        const auto root=std::filesystem::canonical(work/"runtime").string();
        setenv("AMCL_INSTALLED_MODE",modeName.c_str(),1);setenv("AMCL_INSTALLED_ROOT",root.c_str(),1);
        setenv("AMCL_INSTALLED_CACHE",(work/".amcl-fontconfig-cache/fontconfig").c_str(),1);
        setenv("AMCL_INSTALLED_FONT_FILE",(work/"fixture.ttf").c_str(),1);
        setenv("FONTCONFIG_FILE","original-config-sentinel",1);setenv("HOME","original-home-sentinel",1);
        Require(chdir(work.c_str())==0,"initial cwd");char before[4096];Require(getcwd(before,sizeof(before)),"save cwd");
        namespace probe=amcl::jdkqualification::fontdefaults;
        const auto fc=probe::ReadAbsolute(root+"/lib/libfontconfig.so"),ft=probe::ReadAbsolute(root+"/lib/libfreetype.so");
        auto report=amcl::jdk::io::Directory((work/"report").string());
        if(modeName=="collision"){std::ofstream file(work/"report/font-defaults-report.json");file<<"existing report";}
        bool value=false,threw=false;
        try {value=amcl::jdkqualification::RunInstalledFontDefaultsQualification(report.get(),root,"17",
            modeName=="wrong-hash"?std::string(64,'0'):fc.sha,ft.sha,"");}
        catch(const std::exception&){threw=true;}
        const bool expected=modeName=="good";
        Require(value==expected,"qualification result mismatch");
        Require(threw==(modeName=="collision"),"unexpected report failure");
        Require(searchPath.empty(),"search path not restored");
        Require(std::string(getenv("FONTCONFIG_FILE"))=="original-config-sentinel" &&
            std::string(getenv("HOME"))=="original-home-sentinel","environment not restored");
        char after[4096];Require(getcwd(after,sizeof(after)) && std::string(before)==after,"cwd not restored");
        Require(opens==closes,"owned module reference leak");
        const auto body=amcl::jdk::io::SmallFile(report.get(),"font-defaults-report.json",1024*1024);
        if(modeName=="collision")Require(body=="existing report" && opens==0,"collision touched existing state");
        else Require(body.find(expected?"\"passed\":true":"\"passed\":false")!=std::string::npos,"report result mismatch");
        std::cout<<"PASS installed font probe boundary "<<modeName<<" uid="<<geteuid()<<'\n';return 0;
    }catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
}
