/** PERM-01目标测量输入：由常驻宿主在真实应用token下调用真实libc，绝不经过custom
 * loader的chmod拦截。只在调用方提供的已授权根中新建独占探针目录和普通文本文件。
 * 本文件仅由显式TestHooks资格入口调用；不执行文件、不碰既有数据，不以errno/路径名推断挂载语义。
 */
#pragma once
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <unistd.h>

namespace amcl::permissionprobe {
namespace detail {
struct Fd {
    int value;
    explicit Fd(int fd) : value(fd) {}
    ~Fd() { if (value >= 0) close(value); }
    Fd(const Fd&) = delete;
    Fd& operator=(const Fd&) = delete;
};
/** JSON文本转义，原始UTF-8和绝对路径保留；无法读取的数据用errno记录，不能补默认成功。 */
inline std::string Quote(const std::string& text) {
    std::ostringstream out; out << '"';
    for (unsigned char c : text) {
        if (c == '"' || c == '\\') out << '\\' << static_cast<char>(c);
        else if (c < 32) { char escaped[7]; std::snprintf(escaped, sizeof(escaped), "\\u%04x", unsigned(c)); out << escaped; }
        else out << static_cast<char>(c);
    }
    out << '"'; return out.str();
}
inline std::string Octal(mode_t value) { std::ostringstream out; out << std::oct << value; return out.str(); }
inline void Stat(std::ostringstream& out, int fd) {
    struct stat value{}; const int result = fstat(fd, &value), failure = result ? errno : 0;
    out << "{\"result\":" << result << ",\"errno\":" << failure;
    if (!result) {
        out << ",\"dev\":" << Quote(std::to_string(value.st_dev)) << ",\"ino\":" << Quote(std::to_string(value.st_ino))
            << ",\"uid\":" << value.st_uid << ",\"gid\":" << value.st_gid << ",\"nlink\":" << value.st_nlink
            << ",\"typeOctal\":" << Quote(Octal(value.st_mode & S_IFMT))
            << ",\"modeOctal\":" << Quote(Octal(value.st_mode & 07777))
            << ",\"ctimeSec\":" << Quote(std::to_string(value.st_ctim.tv_sec)) << ",\"ctimeNs\":" << value.st_ctim.tv_nsec;
    }
    struct statfs filesystem{}; const int fsResult = fstatfs(fd, &filesystem), fsFailure = fsResult ? errno : 0;
    out << ",\"statfsResult\":" << fsResult << ",\"statfsErrno\":" << fsFailure;
    if (!fsResult) {
        out << ",\"fsType\":" << Quote(std::to_string(filesystem.f_type))
            << ",\"fsId0\":" << Quote(std::to_string(filesystem.f_fsid.__val[0]))
            << ",\"fsId1\":" << Quote(std::to_string(filesystem.f_fsid.__val[1]))
            << ",\"fsFlags\":" << Quote(std::to_string(filesystem.f_flags));
    }
    out << '}';
}
inline void FdInfo(std::ostringstream& out, int fd) {
    const std::string path = "/proc/self/fdinfo/" + std::to_string(fd);
    Fd input(open(path.c_str(), O_RDONLY | O_CLOEXEC));
    if (input.value < 0) { out << "{\"errno\":" << errno << '}'; return; }
    char bytes[8192]; const ssize_t count = read(input.value, bytes, sizeof(bytes));
    if (count < 0) out << "{\"errno\":" << errno << '}';
    else out << "{\"errno\":0,\"text\":" << Quote(std::string(bytes, static_cast<size_t>(count)))
             << ",\"possiblyTruncated\":" << (count == static_cast<ssize_t>(sizeof(bytes)) ? "true" : "false") << '}';
}
} // namespace detail

/** 一次根测量：nonce只能是短ASCII标识；目录已存在就拒绝复用。文件保留供读回，调用方
 * 另按本轮返回路径清理。before/after为同一打开对象，pathAfter另核路径仍指向该对象。
 * sameBits是观测数据，不是本函数自动授予任何兼容权限的条件。
 */
inline std::string Run(const std::string& rootPath, const std::string& nonce) {
    using namespace detail;
    std::ostringstream out;
    out << "{\"schema\":1,\"root\":" << Quote(rootPath) << ",\"nonce\":" << Quote(nonce)
        << ",\"pid\":" << getpid() << ",\"uid\":" << getuid() << ",\"euid\":" << geteuid();
    if (rootPath.empty() || rootPath.front() != '/' || rootPath.find('\0') != std::string::npos || nonce.empty() ||
        nonce.size() > 48 || nonce.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-") != std::string::npos)
        return out.str() + ",\"inputError\":true}";
    Fd root(open(rootPath.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW));
    if (root.value < 0) { out << ",\"openRootErrno\":" << errno << '}'; return out.str(); }
    out << ",\"rootIdentity\":"; Stat(out, root.value);
    const std::string leaf = ".amcl-perm-" + nonce;
    if (mkdirat(root.value, leaf.c_str(), 0700)) { out << ",\"mkdirErrno\":" << errno << '}'; return out.str(); }
    Fd directory(openat(root.value, leaf.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW));
    if (directory.value < 0) { out << ",\"openDirectoryErrno\":" << errno << '}'; return out.str(); }
    out << ",\"directory\":"; Stat(out, directory.value);
    out << ",\"directoryFdInfo\":"; FdInfo(out, directory.value);
    out << ",\"fixturePath\":" << Quote(rootPath + "/" + leaf) << ",\"operations\":[";
    const char* apiNames[] = {"chmod", "fchmod", "fchmodat"};
    const char* requestNames[] = {"preserve-exact", "toggle-owner-execute", "tighten-0600", "remove-owner-write", "mode-zero"};
    bool comma = false;
    for (unsigned api = 0; api < 3; ++api) for (unsigned request = 0; request < 5; ++request) {
        if (comma) out << ',';
        comma = true;
        const std::string name = std::string(apiNames[api]) + "-" + requestNames[request];
        out << "{\"api\":" << Quote(apiNames[api]) << ",\"case\":" << Quote(requestNames[request]);
        Fd file(openat(directory.value, name.c_str(), O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0666));
        if (file.value < 0) { out << ",\"createErrno\":" << errno << '}'; continue; }
        static constexpr char payload[] = "AMCL owned permission metadata probe\n";
        const ssize_t written = write(file.value, payload, sizeof(payload) - 1);
        out << ",\"writeBytes\":" << written << ",\"writeErrno\":" << (written < 0 ? errno : 0);
        struct stat before{};
        if (fstat(file.value, &before)) { out << ",\"fstatErrno\":" << errno << '}'; continue; }
        const mode_t initial = before.st_mode & 07777;
        const mode_t mode = request == 0 ? initial : request == 1 ? initial ^ S_IXUSR :
            request == 2 ? 0600 : request == 3 ? initial & ~S_IWUSR : 0;
        out << ",\"requestedOctal\":" << Quote(Octal(mode)) << ",\"before\":"; Stat(out, file.value);
        const std::string absolute = rootPath + "/" + leaf + "/" + name;
        const int result = api == 0 ? chmod(absolute.c_str(), mode) : api == 1 ? fchmod(file.value, mode) :
            fchmodat(directory.value, name.c_str(), mode, 0);
        const int failure = result ? errno : 0; // 后续观测不能覆盖真正权限调用的errno。
        out << ",\"result\":" << result << ",\"errno\":" << failure << ",\"after\":"; Stat(out, file.value);
        struct stat pathAfter{};
        const int pathResult = fstatat(directory.value, name.c_str(), &pathAfter, AT_SYMLINK_NOFOLLOW);
        out << ",\"pathAfterErrno\":" << (pathResult ? errno : 0)
            << ",\"pathStillSameObject\":" << (!pathResult && pathAfter.st_dev == before.st_dev && pathAfter.st_ino == before.st_ino ? "true" : "false");
        Fd readable(openat(directory.value, name.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
        const int readError = readable.value < 0 ? errno : 0;
        Fd writable(openat(directory.value, name.c_str(), O_WRONLY | O_CLOEXEC | O_NOFOLLOW));
        out << ",\"reopenReadErrno\":" << readError << ",\"reopenWriteErrno\":" << (writable.value < 0 ? errno : 0) << '}';
    }
    out << "],\"qualification\":\"observations-only; no capability enabled\"}";
    return out.str();
}
} // namespace amcl::permissionprobe
