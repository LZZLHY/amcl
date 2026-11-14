#pragma once
// 文件堆目录准入：仅创建一个应用私有子目录，保持原目录内容，不做通配清理。
// 持有fd到CreateJavaVM结束，最终路径与fd身份必须仍相同；不修改进程环境。
#include "jvm_heap_backing.h"
#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>

namespace amcl::jvm {
class PreparedHeapBackingDirectory final {
    int fd_=-1;
    std::string path_;
    uint64_t maximum_=0;
    uint64_t free_=0;
    uint64_t required_=0;
public:
    PreparedHeapBackingDirectory()=default;
    PreparedHeapBackingDirectory(const PreparedHeapBackingDirectory&)=delete;
    PreparedHeapBackingDirectory& operator=(const PreparedHeapBackingDirectory&)=delete;
    ~PreparedHeapBackingDirectory() { if(fd_>=0)close(fd_); }
    const std::string& path() const noexcept { return path_; }
    uint64_t freeBytes() const noexcept { return free_; }
    uint64_t requiredBytes() const noexcept { return required_; }

    /** 未知空间、路径替换、symlink或非私有子目录均明确失败，不退回大RAM堆。 */
    bool revalidate(std::string& error) {
        struct stat held{},named{};
        if(fd_<0 || fstat(fd_,&held)!=0 || lstat(path_.c_str(),&named)!=0 ||
           !S_ISDIR(named.st_mode) || held.st_dev!=named.st_dev || held.st_ino!=named.st_ino ||
           held.st_uid!=geteuid() || (held.st_mode&0700)!=0700 || (held.st_mode&0022)!=0) {
            error="heapfile_directory_identity"; return false;
        }
        struct statvfs disk{};
        const bool known=fstatvfs(fd_,&disk)==0 && disk.f_frsize &&
            static_cast<uint64_t>(disk.f_bavail)<=std::numeric_limits<uint64_t>::max()/disk.f_frsize;
        free_=known?static_cast<uint64_t>(disk.f_bavail)*disk.f_frsize:0;
        return ValidateHeapFileSpace(maximum_,known,free_,required_,error);
    }

    bool prepare(const char* appFilesDir, const HeapBackingRequest& request,
                 uint64_t maximumBytes, std::string& error) {
        if(fd_>=0 || !path_.empty() || !request.enabled) { error="heapfile_prepare_state"; return false; }
        maximum_=maximumBytes;
        if(request.privateDirectory) {
            if(!appFilesDir || appFilesDir[0]!='/') { error="heapfile_private_root"; return false; }
            std::string base=appFilesDir;
            while(base.size()>1 && base.back()=='/')base.pop_back();
            const int parent=open(base.c_str(),O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
            struct stat info{};
            if(parent<0) { error="heapfile_parent_open"; return false; }
            if(fstat(parent,&info)!=0 || !S_ISDIR(info.st_mode) || info.st_uid!=geteuid()) {
                close(parent); error="heapfile_parent_identity"; return false;
            }
            if(mkdirat(parent,"jvm-heap",0700)!=0 && errno!=EEXIST) {
                close(parent); error="heapfile_directory_create"; return false;
            }
            fd_=openat(parent,"jvm-heap",O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
            close(parent); path_=base+"/jvm-heap";
        } else {
            path_=request.explicitDirectory;
            while(path_.size()>1 && path_.back()=='/')path_.pop_back();
            fd_=open(path_.c_str(),O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
        }
        if(fd_<0) { error="heapfile_directory_open"; return false; }
        return revalidate(error);
    }
};
}
