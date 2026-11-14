// 在独立宿主HotSpot进程中运行真实JNI读回函数；每个进程只建一个VM。
// 只证明管理接口/Unicode/拒绝错误实况，OHOS映射与整包资格由真机另验。
#include "../../jvm/jvm_heap_backing_verification.h"
#include <cassert>
#include <cstdio>
#include <cstring>
#include <vector>
#include <cstdlib>
// 失败保留控制台证据后直接非零退出，避免测试断言制造宿主core或交互弹窗。
#undef assert
#define assert(x) do { if (!(x)) { std::fprintf(stderr,"check failed line=%d\n",__LINE__); std::_Exit(7); } } while(0)
int main(int argc,char** argv) {
    assert(argc==3);
    const bool ram=std::strcmp(argv[2],"ram")==0;
    const bool lenient=std::strcmp(argv[2],"lenient")==0;
    const bool observe=std::strcmp(argv[2],"observe")==0;
    std::string path=argv[1],location="-XX:AllocateHeapAt="+path;
    std::vector<JavaVMOption> options{{const_cast<char*>("-Xmx128m"),nullptr},
        {const_cast<char*>(lenient?"-XX:+IgnoreUnrecognizedVMOptions":"-XX:-IgnoreUnrecognizedVMOptions"),nullptr}};
    if(!ram)options.push_back({const_cast<char*>(location.c_str()),nullptr});
    JavaVMInitArgs args{};args.version=JNI_VERSION_10;args.nOptions=options.size();
    args.options=options.data();args.ignoreUnrecognized=lenient?JNI_TRUE:JNI_FALSE;
    JavaVM* vm=nullptr;JNIEnv* env=nullptr;
    assert(JNI_CreateJavaVM(&vm,reinterpret_cast<void**>(&env),&args)==JNI_OK && vm && env);
    uint64_t maximum=0;std::string error;
    const bool verified=amcl::jvm::VerifyHeapBackingVm(env,path,128ull*1048576,maximum,error);
    std::fprintf(stderr,"verification=%d actualMaximum=%llu reason=%s\n",verified,
        static_cast<unsigned long long>(maximum),error.c_str());
    // observe专门记录宿主JDK对非BMP flag字符串的行为，不要求其缺陷永远存在，
    // 也不将未能证明的目录强行记作文件堆通过。生产校验始终拒绝不匹配。
    if(!observe)assert(verified==(!ram&&!lenient));
    if(verified) {
        assert(maximum==128ull*1048576);
        assert(!amcl::jvm::VerifyHeapBackingVm(env,path+"-wrong",128ull*1048576,maximum,error));
        assert(!amcl::jvm::VerifyHeapBackingVm(env,path,32ull*1048576,maximum,error));
    }
    assert(!env->ExceptionCheck());
    assert(vm->DestroyJavaVM()==JNI_OK);
    std::puts("actual HotSpot management readback accepted correct file heap or rejected RAM/lenient mismatch");
}
