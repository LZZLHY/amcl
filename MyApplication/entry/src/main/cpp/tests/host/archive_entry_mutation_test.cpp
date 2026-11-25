#include "../../platform/archive_entry_mutation.h"
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <functional>
#include <stdexcept>
#include <string>
#include <fcntl.h>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;
namespace {
std::function<bool(const std::string &, int, const std::string &)> hook;
void require(bool good, const std::string &message) { if (!good) throw std::runtime_error(message); }
void put(const fs::path &file, const std::string &bytes) {
    std::ofstream out(file); out << bytes; require(out.good(), "write fixture");
}
bool contains(const fs::path &file, const std::string &value) {
    std::ifstream in(file); std::string data; in >> data; return data == value;
}
std::vector<fs::path> stages(const fs::path &root) {
    std::vector<fs::path> result;
    for (const auto &p : fs::directory_iterator(root))
        if (p.path().filename().string().rfind(".amcl-entry-", 0) == 0) result.push_back(p.path());
    return result;
}
std::string change(const fs::path &root, const std::string &name, const std::string &dest = {}) {
    int parent = open(root.c_str(), O_DIRECTORY | O_RDONLY | O_CLOEXEC);
    int selected = openat(parent, name.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    require(parent >= 0 && selected >= 0, "open selected fixture");
    const auto result = amcl::archive::MutateConfirmedEntry(parent, selected, name, dest);
    close(selected); close(parent); return result;
}
}
namespace amcl::archive {
bool MutationTestStep(const char *step, int fd, const std::string &name) {
    return !hook || hook(step, fd, name);
}
}
int main(int argc, char **argv) {
    // 只创建和回收本轮独占夹具；失败时保留所有字节，传入的共享父目录不做任何清理。
    fs::path base = argc == 2 ? fs::absolute(argv[1]) : fs::current_path();
    std::string pattern = (base / "archive-mutation-XXXXXX").string();
    if (!mkdtemp(pattern.data())) return 2;
    fs::path root(pattern), world = root / "World";
    try {
        fs::create_directories(world / "region");
        put(world / "region" / "a", "old"); put(root / "outside", "keep");
        fs::create_symlink(root/"outside", world/"outside-link");
        bool recovered=false;
        hook=[&](const std::string &step, int, const std::string &) {
            if (step=="child" && !recovered) { recovered=true; fs::create_directory(world); put(world/"level.dat","restored"); }
            return true;
        };
        const auto removed = change(root,"World");
        require(removed.empty() && recovered && contains(world/"level.dat","restored") &&
            contains(root/"outside","keep") && stages(root).empty(),"concurrent same-name world and symlink target preserved: "+removed);

        put(world/"second","left"); int children=0;
        hook=[&](const std::string &step,int,const std::string &) {
            if (step=="child" && ++children==2) { fs::create_directory(world); put(world/"backup","intact"); return false; }
            return true;
        };
        auto fail=change(root,"World");
        const auto retained=stages(root);
        require(!fail.empty() && retained.size()==1 && fail.find(retained[0].filename().string())!=std::string::npos &&
            contains(world/"backup","intact") && fs::directory_iterator(retained[0]/"World")!=fs::directory_iterator{},
            "partial failure retains remainder and never overwrites restored world");

        // 故障前原位置未重新占用，应该无覆盖地放回尚未删除的内容。
        hook=[](const std::string &step,int,const std::string &) {return step!="child";};
        require(!change(root,"World").empty() && contains(world/"backup","intact") && stages(root).size()==1,"partial rollback");

        bool swapped=false;
        hook=[&](const std::string &step,int,const std::string &) {
            if(step=="preMove" && !swapped){ swapped=true; fs::rename(world,root/"old");fs::create_directory(world);put(world/"survivor","correct"); }
            return true;
        };
        require(!change(root,"World").empty() && swapped && contains(world/"survivor","correct") &&
            contains(root/"old"/"backup","intact"),"swap between source check and quarantine");

        bool moved=false;
        hook=[&](const std::string &step,int fd,const std::string &) {
            if(step=="staged" && !moved){moved=true;require(renameat(fd,"World",AT_FDCWD,(root/"moved").c_str())==0,"move isolated world");}
            return true;
        };
        require(!change(root,"World").empty() && contains(root/"moved"/"survivor","correct"),"moved selected directory preserved");

        // 隔离位置本身被移走并替换时，不进入新目录，也不继续追删已移走的原目录。
        fs::create_directory(world);put(world/"marker","old");
        hook=[&](const std::string &step,int,const std::string &) {
            if(step=="staged"){
                fs::path current;
                for (const auto &dir : stages(root)) if (fs::exists(dir/"World"/"marker")) current=dir;
                require(!current.empty(),"find current private stage");fs::rename(current,root/"relocated-stage");
                fs::create_directories(current/"World");put(current/"World"/"marker","replacement");
            }
            return true;
        };
        require(!change(root,"World").empty() && contains(root/"relocated-stage"/"World"/"marker","old"),"moved private stage preserved");
        bool kept=false;
        for(const auto &dir : stages(root)) kept=kept || contains(dir/"World"/"marker","replacement");
        require(kept,"replacement private path untouched");

        put(root/"one","first");put(root/"two","second");hook={};
        require(!change(root,"one","two").empty() && contains(root/"one","first") && contains(root/"two","second"),"rename collision preserved both");
        require(change(root,"one","three").empty() && contains(root/"three","first"),"rename original file");
        fs::create_directory(world);put(world/"level.dat","kept");
        require(change(root,"World","Renamed").empty() && contains(root/"Renamed"/"level.dat","kept"),"rename original world");
        hook=[&](const std::string &step,int,const std::string &) {
            if(step=="staged"){put(root/"three","reborn");}
            return true;
        };
        require(change(root,"three").empty() && contains(root/"three","reborn"),"file deletion does not affect restored name");

        hook=[](const std::string &step,int,const std::string &) {return step!="exclusive";};
        require(!change(root,"Renamed","Other").empty() && contains(root/"Renamed"/"level.dat","kept"),"unsupported rename keeps original");
        require(change(root,"Renamed").empty() && !fs::exists(root/"Renamed"),"ordinary delete without renameat2");
        hook={};fs::remove_all(root);
        std::puts("PASS confirmed archive mutation: original, replacement, symlink, partial recovery, moved item, no-clobber rename, old filesystem");
        return 0;
    } catch(const std::exception &error) {
        std::fprintf(stderr,"FAIL %s; fixture %s\n",error.what(),root.c_str());return 1;
    }
}
