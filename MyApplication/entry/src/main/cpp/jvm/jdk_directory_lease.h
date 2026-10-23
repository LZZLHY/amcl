/**
 * JVM 的 JDK 共享目录租约。与 ArkTS File.tryLock 使用同一 flock 文件协议。
 * 临时对象在参数/文件校验失败时关闭 fd；进入不可逆 JVM 初始化后将 fd 交给进程。
 * 锁文件不可放在会被替换的版本目录内部，否则 rename 后新 inode 会绕过锁。
 */
#pragma once
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

namespace amcl::jdk {
class DirectoryReadLease {
    int fd_{-1};
public:
    DirectoryReadLease() = default;
    DirectoryReadLease(const DirectoryReadLease&) = delete;
    DirectoryReadLease& operator=(const DirectoryReadLease&) = delete;
    ~DirectoryReadLease() { if (fd_ >= 0) close(fd_); }

    /** 在映射或打开运行时数据前取得共享锁；冲突不等待，保持 Fresh 状态可重试。 */
    bool acquire(const std::string& filesDir, const char* version, std::string& error) {
        const std::string key = version && version[0] ? version : "legacy";
        if (key != "legacy" && (key.size() > 3 || key.find_first_not_of("0123456789") != std::string::npos)) {
            error = "JDK 槽位标识无效";
            return false;
        }
        const std::string parent = filesDir + "/jdk";
        const std::string locks = parent + "/.locks";
        for (const auto& directory : {parent, locks}) {
            if (mkdir(directory.c_str(), 0700) != 0 && errno != EEXIST) {
                error = "无法准备 JDK 租约目录: " + std::string(strerror(errno));
                return false;
            }
        }
        fd_ = open((locks + "/" + key + ".use").c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0600);
        if (fd_ < 0) { error = "无法打开 JDK 租约: " + std::string(strerror(errno)); return false; }
        if (flock(fd_, LOCK_SH | LOCK_NB) != 0) {
            error = (errno == EWOULDBLOCK || errno == EAGAIN) ? "JDK 正在更新或删除，请稍后重试"
                : "无法锁定 JDK: " + std::string(strerror(errno));
            close(fd_); fd_ = -1;
            return false;
        }
        return true;
    }

    /** 不再由栈对象释放，JVM 已认领后持有到游戏/processor 进程退出。 */
    int releaseToProcess() { const int fd = fd_; fd_ = -1; return fd; }
};
}
