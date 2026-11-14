/** 安装模块内部的有界 POSIX 辅助；不对外提供任意路径改写/权限绕过接口。 */
#pragma once
#include "../download/hmac_sha256.h"
#include <algorithm>
#include <array>
#include <cerrno>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <stdexcept>
#include <string>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace amcl::jdk::io {
constexpr uint64_t MaxBytes = 16ULL * 1024 * 1024 * 1024;
constexpr size_t MaxEntries = 200000, MaxDepth = 64, Chunk = 256 * 1024;
/** fd 唯一所有权；close 不重试（EINTR 后是否仍持有 fd 因系统而异，重试可能关闭复用者）。 */
class Fd {
    int value_ = -1;

  public:
    explicit Fd(int value = -1) : value_(value) {}
    ~Fd() {
        if (value_ >= 0)
            close(value_);
    }
    Fd(const Fd &) = delete;
    Fd &operator=(const Fd &) = delete;
    Fd(Fd &&from) noexcept : value_(from.value_) {
        from.value_ = -1;
    }
    Fd &operator=(Fd &&from) noexcept {
        if (value_ >= 0)
            close(value_);
        value_ = from.value_;
        from.value_ = -1;
        return *this;
    }
    int get() const {
        return value_;
    }
};
[[noreturn]] inline void Error(const std::string &what) {
    throw std::runtime_error(what + ": " + strerror(errno));
}
inline void Require(bool yes, const std::string &message) {
    if (!yes)
        throw std::runtime_error(message);
}
inline bool Hash(const std::string &value) {
    return value.size() == 64 && value.find_first_not_of("0123456789abcdef") == std::string::npos;
}
inline void Major(const std::string &major) {
    Require(!major.empty() && major.size() <= 3 && major[0] != '0' &&
                major.find_first_not_of("0123456789") == std::string::npos,
            "JDK 槽位无效");
}
/** 路径不做悄悄规范化：歧义名称直接拒绝，避免中央目录与实际写入解释不一致。 */
inline std::vector<std::string> Parts(const std::string &path) {
    Require(!path.empty() && path.size() <= 4096 && path.front() != '/' && path.back() != '/', "安装相对路径无效");
    std::vector<std::string> parts;
    for (size_t from = 0; from < path.size();) {
        const auto end = path.find('/', from);
        const auto part = path.substr(from, end == std::string::npos ? end : end - from);
        Require(!part.empty() && part != "." && part != ".." && part.size() <= 255, "安装路径包含空段或上级目录");
        for (unsigned char c : part)
            Require(c >= 32 && c != 127 && c != '\\' && c != ':', "安装路径包含歧义字符");
        parts.push_back(part);
        Require(parts.size() <= MaxDepth, "安装目录层级超过预算");
        if (end == std::string::npos)
            break;
        from = end + 1;
    }
    return parts;
}
inline Fd Directory(const std::string &path) {
    Fd fd(open(path.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW));
    if (fd.get() < 0)
        Error("无法打开安装目录 " + path);
    return fd;
}
inline Fd ChildDirectory(int root, const std::string &name, bool create = false) {
    Parts(name);
    Require(name.find('/') == std::string::npos, "目录名必须只有一段");
    if (create && mkdirat(root, name.c_str(), 0700) != 0 && errno != EEXIST)
        Error("无法建立目录 " + name);
    Fd fd(openat(root, name.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW));
    if (fd.get() < 0)
        Error("无法打开目录 " + name);
    return fd;
}
/** 从已经打开的根逐段下降，每一步 O_NOFOLLOW，杜绝中途链接把文件写出 staging。 */
inline Fd Parent(int root, const std::string &relative, bool create = false) {
    auto parts = Parts(relative);
    Fd at(fcntl(root, F_DUPFD_CLOEXEC, 0));
    if (at.get() < 0)
        Error("无法复制目录 fd");
    for (size_t i = 0; i + 1 < parts.size(); ++i)
        at = ChildDirectory(at.get(), parts[i], create);
    return at;
}
inline std::string Leaf(const std::string &path) {
    const auto p = path.rfind('/');
    return path.substr(p == std::string::npos ? 0 : p + 1);
}
inline void Sync(int fd) {
    int r;
    do {
        r = fsync(fd);
    } while (r != 0 && errno == EINTR);
    if (r != 0)
        Error("安装 fsync 失败");
}
inline void Write(int fd, const void *bytes, size_t size) {
    const auto *data = static_cast<const char *>(bytes);
    while (size) {
        ssize_t n;
        do {
            n = write(fd, data, size);
        } while (n < 0 && errno == EINTR);
        if (n <= 0)
            Error("安装文件写入失败");
        data += n;
        size -= static_cast<size_t>(n);
    }
}
inline void Read(int fd, void *bytes, size_t size, uint64_t offset) {
    auto *data = static_cast<char *>(bytes);
    while (size) {
        ssize_t n;
        do {
            n = pread(fd, data, size, static_cast<off_t>(offset));
        } while (n < 0 && errno == EINTR);
        if (n < 0)
            Error("安装文件读取失败");
        Require(n > 0, "安装文件已截断");
        data += n;
        size -= n;
        offset += n;
    }
}
inline std::string Digest(const std::string &bytes) {
    download::Sha256 sha;
    sha.update(bytes.data(), bytes.size());
    return sha.finalizeHex();
}
inline std::vector<std::string> Names(int fd) {
    // fdopendir 的游标属于复制的 open-file-description，因此重新 openat(".")，不复用原目录游标。
    const int copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (copy < 0)
        Error("无法枚举安装目录");
    DIR *dir = fdopendir(copy);
    if (!dir) {
        close(copy);
        Error("无法枚举安装目录");
    }
    std::vector<std::string> names;
    try {
        errno = 0;
        while (auto *entry = readdir(dir)) {
            const std::string name = entry->d_name;
            if (name == "." || name == "..")
                continue;
            Parts(name);
            names.push_back(name);
            Require(names.size() <= MaxEntries, "安装目录条目超过预算");
            errno = 0;
        }
        if (errno)
            Error("安装目录枚举失败");
    } catch (...) {
        closedir(dir);
        throw;
    }
    closedir(dir);
    std::sort(names.begin(), names.end());
    return names;
}
inline bool Exists(int fd, const std::string &name) {
    struct stat st {};
    if (fstatat(fd, name.c_str(), &st, AT_SYMLINK_NOFOLLOW) == 0)
        return true;
    if (errno != ENOENT)
        Error("无法检查安装路径 " + name);
    return false;
}
inline std::string SmallFile(int root, const std::string &name, size_t limit = 16384) {
    Fd file(openat(root, name.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
    if (file.get() < 0)
        Error("无法读取安装记录 " + name);
    struct stat st {};
    if (fstat(file.get(), &st))
        Error("无法读取安装记录属性");
    Require(S_ISREG(st.st_mode) && st.st_nlink == 1 && st.st_size >= 0 && uint64_t(st.st_size) <= limit,
            "安装记录类型或大小无效");
    std::string text(static_cast<size_t>(st.st_size), '\0');
    if (!text.empty())
        Read(file.get(), text.data(), text.size(), 0);
    return text;
}
/** 删除只沿已认领根的目录 fd；链接、硬链接、特殊项拒绝，未知现场留给诊断，不越界清理。 */
inline void Remove(int parent, const std::string &name, size_t &count, size_t depth = 0) {
    Require(++count <= MaxEntries && depth <= MaxDepth, "清理安装目录超过预算");
    struct stat st {};
    if (fstatat(parent, name.c_str(), &st, AT_SYMLINK_NOFOLLOW)) {
        if (errno == ENOENT)
            return;
        Error("无法检查待清理目录");
    }
    if (S_ISDIR(st.st_mode)) {
        auto dir = ChildDirectory(parent, name);
        for (const auto &child : Names(dir.get()))
            Remove(dir.get(), child, count, depth + 1);
        if (unlinkat(parent, name.c_str(), AT_REMOVEDIR))
            Error("无法移除安装目录");
    } else {
        Require(S_ISREG(st.st_mode) && st.st_nlink == 1, "拒绝清理安装目录内的链接或特殊文件");
        if (unlinkat(parent, name.c_str(), 0))
            Error("无法删除安装文件");
    }
}
} // namespace amcl::jdk::io
