/**
 * 生产目录核心的 POSIX 回归。仅在独占测试子进程内改变 cwd，输出根由标准 QA 指定；
 * 不创建 JVM，不伪称目标资格。真实四代 VM/agent/编译日志另由专项原件证明。
 */
#include "../../entry/src/main/cpp/jvm/jvm_game_directory.h"
#include "../../entry/src/main/cpp/jvm/runtime_bootstrap_contract.h"
#include <cassert>
#include <cstdio>
#include <dirent.h>
#include <string>
#include <sys/stat.h>

static int descriptors() {
    DIR* d=opendir("/proc/self/fd");assert(d);int count=0;
    while(dirent* e=readdir(d)) if(e->d_name[0]!='.') ++count;
    assert(closedir(d)==0);return count;
}
static std::string current() { char p[4096];assert(getcwd(p,sizeof(p)));return p; }
int main(int argc,char** argv) {
    assert(argc==2 && argv[1][0]=='/');
    const std::string root=argv[1],target=root+"/game",missing=root+"/missing",file=root+"/file";
    assert(mkdir(target.c_str(),0700)==0);
    FILE* f=fopen(file.c_str(),"w");assert(f);assert(fclose(f)==0);
    assert(chdir(root.c_str())==0);const std::string before=current();const int count=descriptors();
    for(int i=0;i<128;++i) {
        {amcl::jvm::GameWorkingDirectory d;assert(d.prepare(nullptr)==0);assert(d.enter()==0);assert(current()==before);}
        {amcl::jvm::GameWorkingDirectory d;assert(d.prepare("relative")==EINVAL);assert(current()==before);}
        {amcl::jvm::GameWorkingDirectory d;assert(d.prepare(missing.c_str())==ENOENT);assert(current()==before);}
        {amcl::jvm::GameWorkingDirectory d;assert(d.prepare(file.c_str())==ENOTDIR);assert(current()==before);}
        {amcl::jvm::GameWorkingDirectory d;assert(d.prepare(target.c_str())==0);assert(descriptors()==count+1);assert(current()==before);}
        assert(descriptors()==count);
    }
    {
        amcl::jvm::RuntimeOnce runtime;assert(runtime.reserveFork(static_cast<unsigned>(getpid()))==0);
        amcl::jvm::GameWorkingDirectory d;assert(d.prepare(target.c_str())==0);
        assert(runtime.beginResult()==amcl::jvm::RuntimeOnce::ForkBusy);assert(current()==before);
        // 认领失败不调用 enter，也不释放或重置另一个拥有者的 ForkReserved。
        assert(runtime.state()==amcl::jvm::RuntimeOnce::ForkReserved);
    }
    {
        amcl::jvm::RuntimeOnce runtime;amcl::jvm::GameWorkingDirectory d;
        assert(d.prepare(target.c_str())==0);assert(runtime.beginResult()==0);
        // 任一真实 CreateVM 前置失败发生时尚未调用 enter；原 cwd 无需猜测恢复。
        assert(current()==before);assert(runtime.state()==amcl::jvm::RuntimeOnce::Creating);
    }
    {amcl::jvm::GameWorkingDirectory d;assert(d.prepare(target.c_str())==0);assert(d.enter()==0);assert(current()==target);}
    // 成功提交给 VM 后，关闭短命 fd 不把进程 cwd 切回；与原游戏运行期合同一致。
    assert(current()==target && descriptors()==count);
    puts("PASS game directory: 128 FD rounds, disabled/relative/missing/file, fork claim, precreate failure, retained cwd");
}
