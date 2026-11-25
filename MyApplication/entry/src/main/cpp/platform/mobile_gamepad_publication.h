#pragma once
#include "gamepad_reader.h"
#include <cerrno>
#include <sys/stat.h>

namespace amcl::desktop {
// 只管理移动游戏一次原生采集所创建的文件。持有原 fd 可防止 inode 在清理前被回收复用。
// 调用方串行化配置和宿主退出；桌面窗口的共享文件从不交给本对象。
class MobileGamepadPublication {
public:
    bool OwnsFile() const { return fd_ >= 0; }
    bool Configure(bool enable, const char* path, const AmclGamepadReaderDescriptor& record, bool (*capture)(bool)) {
        if (!enable) {
            const bool stopped = capture(false);
            return Retire(path) && stopped;
        }
        if (record.desktopGetter || record.reader == 0 || !Publish(path, record) || !capture(true)) {
            capture(false);
            Retire(path);
            return false;
        }
        return true;
    }
private:
    int fd_ = -1;

    static bool SameFile(const struct stat& original, const struct stat& path) {
        return S_ISREG(path.st_mode) && path.st_dev == original.st_dev && path.st_ino == original.st_ino;
    }

    // 强杀可能来不及退休。PID 再次分配时，只替换应用私有且格式完整的旧移动记录。
    // 已加载的另一个生产映像仍拥有其入口；空文件、额外数据、硬链接或桌面服务都原地保留。
    static bool ReleaseOldMobileRecord(const char* path, const AmclGamepadReaderDescriptor& expected) {
        const int old = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
        if (old < 0) return false;
        bool removed = false;
        if (flock(old, LOCK_EX | LOCK_NB) == 0) {
            struct stat info{}, named{};
            AmclGamepadReaderDescriptor record{};
            if (fstat(old, &info) == 0 && lstat(path, &named) == 0 && SameFile(info, named) &&
                info.st_uid == geteuid() && (info.st_mode & 0777) == 0600 && info.st_nlink == 1 &&
                info.st_size == sizeof(record) && pread(old, &record, sizeof(record), 0) == sizeof(record) &&
                record.desktopGetter == 0 && record.version == expected.version && record.snapshotSize == expected.snapshotSize &&
                record.pid == expected.pid && record.reader >= 4096) {
                Dl_info live{};
                const void* address = reinterpret_cast<const void*>(record.reader);
                const bool otherOwner = record.reader != expected.reader && dladdr(address, &live) &&
                    live.dli_saddr == address && live.dli_sname && strcmp(live.dli_sname, "amclGamepadRead") == 0;
                if (!otherOwner) removed = unlink(path) == 0;
            }
            flock(old, LOCK_UN);
        }
        close(old);
        return removed;
    }

    bool Publish(const char* path, const AmclGamepadReaderDescriptor& record) {
        if (fd_ < 0) {
            constexpr int flags = O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW;
            fd_ = open(path, flags, 0600);
            if (fd_ < 0 && errno == EEXIST && ReleaseOldMobileRecord(path, record)) fd_ = open(path, flags, 0600);
        }
        if (fd_ < 0 || flock(fd_, LOCK_EX) != 0) return false;
        struct stat original{}, current{};
        uintptr_t prefix = 0;
        const bool ok = fstat(fd_, &original) == 0 && lstat(path, &current) == 0 && SameFile(original, current) &&
            pread(fd_, &prefix, sizeof(prefix), 0) >= 0 && prefix == 0 &&
            pwrite(fd_, &record, sizeof(record), 0) == sizeof(record) && ftruncate(fd_, sizeof(record)) == 0;
        flock(fd_, LOCK_UN);
        return ok;
    }

    bool Retire(const char* path) {
        if (fd_ < 0) return true;
        if (flock(fd_, LOCK_EX) != 0) return false;
        struct stat original{}, current{};
        bool done = false;
        if (fstat(fd_, &original) == 0) {
            if (lstat(path, &current) < 0) {
                done = errno == ENOENT;
            } else if (!SameFile(original, current)) {
                done = true; // 路径已替换，保留新所有者的文件。
            } else {
                uintptr_t prefix = 0;
                if (pread(fd_, &prefix, sizeof(prefix), 0) >= 0) {
                    // 即使同 inode 后来发布了桌面服务，也不得由移动会话移除。
                    done = prefix != 0 || unlink(path) == 0 || errno == ENOENT;
                }
            }
        }
        flock(fd_, LOCK_UN);
        if (done) {
            close(fd_);
            fd_ = -1;
        }
        return done;
    }
};
}
