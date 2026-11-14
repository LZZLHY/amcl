/**
 * 同一应用UID下的原生文件时间观察，不经过JVM、自定义ELF重定位或权限兼容层。
 * 每个API/参数组合使用新建文件；既有用户文件不作为试验目标。记录真实返回值、errno、
 * owner/mode、文件系统和调用前后时间，尤其区分显式当前值、UTIME_NOW和UTIME_OMIT。
 * “完成观察”不表示时间修改成功；失败样本保留，全部调用成功时只删除本轮精确创建的文件。
 */
#pragma once
#include "permission_probe.h"
#include <array>
#include <cstring>
#include <dlfcn.h>
#include <stdexcept>
#include <sys/time.h>
#include <vector>

namespace amcl::nativetimeprobe {
namespace detail {
using amcl::permissionprobe::detail::Fd;
using amcl::permissionprobe::detail::Quote;

/** 只读取有界进程权限字段；不采集环境、命令行、账户或其他进程的信息。 */
inline std::string ProcessIdentity() {
    Fd input(open("/proc/self/status", O_RDONLY | O_CLOEXEC));
    if (input.value < 0) return "{\"readable\":false,\"errno\":" + std::to_string(errno) + "}";
    char data[8193]{};
    const ssize_t count = read(input.value, data, sizeof(data) - 1);
    if (count < 0) return "{\"readable\":false,\"errno\":" + std::to_string(errno) + "}";
    std::istringstream lines(std::string(data, static_cast<size_t>(count)));
    std::string line, kept;
    while (std::getline(lines, line)) {
        for (const char* key : {"Uid:", "Gid:", "Groups:", "CapEff:", "CapPrm:"}) {
            if (line.compare(0, std::strlen(key), key) == 0) { kept += line + "\n"; break; }
        }
    }
    return "{\"readable\":true,\"possiblyTruncated\":" + std::string(count == 8192 ? "true" : "false") +
        ",\"fields\":" + Quote(kept) + "}";
}

/** stat在内容读回之前完成，避免读操作更新atime后覆盖真实改时结果。 */
inline std::string State(int fd) {
    struct stat value{};
    if (fstat(fd, &value) != 0) return "{\"readable\":false,\"errno\":" + std::to_string(errno) + "}";
    std::ostringstream out;
    out << "{\"readable\":true,\"dev\":" << Quote(std::to_string(value.st_dev))
        << ",\"ino\":" << Quote(std::to_string(value.st_ino)) << ",\"uid\":" << value.st_uid
        << ",\"gid\":" << value.st_gid << ",\"mode\":" << (value.st_mode & 07777)
        << ",\"nlink\":" << value.st_nlink << ",\"size\":" << value.st_size
        << ",\"atimeSec\":" << value.st_atim.tv_sec << ",\"atimeNs\":" << value.st_atim.tv_nsec
        << ",\"mtimeSec\":" << value.st_mtim.tv_sec << ",\"mtimeNs\":" << value.st_mtim.tv_nsec
        << ",\"ctimeSec\":" << value.st_ctim.tv_sec << ",\"ctimeNs\":" << value.st_ctim.tv_nsec << '}';
    return out.str();
}

/** 保存真实系统函数所在映像；不把同名符号或测试标签当作实现来源。 */
inline std::string Provider(const void* function) {
    Dl_info info{};
    return function && dladdr(function, &info) && info.dli_fname ? Quote(info.dli_fname) : "null";
}
} // namespace detail

/**
 * 只接受已有绝对根和短nonce。根的真实dev/ino/type均保存；sharefs名称/dev0不触发任何豁免。
 * 父调用者负责把root绑定到UIAbility filesDir/GameStorage，不能从Want传任意路径。
 */
inline std::string Run(const std::string& rootPath, const std::string& nonce) {
    using namespace detail;
    if (rootPath.empty() || rootPath.front() != '/' || nonce.empty() || nonce.size() > 48 ||
        nonce.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_") != std::string::npos)
        throw std::runtime_error("native time probe root/nonce invalid");
    Fd root(open(rootPath.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW));
    if (root.value < 0) throw std::runtime_error("native time probe root unavailable errno=" + std::to_string(errno));
    const std::string leaf = "amcl-native-times-" + nonce;
    if (mkdirat(root.value, leaf.c_str(), 0700) != 0)
        throw std::runtime_error("native time probe requires fresh directory errno=" + std::to_string(errno));
    Fd directory(openat(root.value, leaf.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW));
    if (directory.value < 0) throw std::runtime_error("native time probe directory unavailable");
    struct statfs filesystem{};
    const int fsResult = fstatfs(directory.value, &filesystem), fsError = fsResult ? errno : 0;
    // futimesat不是所有平台都导出；缺符号明确NOT-RUN，不能调用空指针或模拟成功。
    using FutimesAt = int (*)(int, const char*, const struct timeval*);
    auto futimesAt = reinterpret_cast<FutimesAt>(dlsym(RTLD_DEFAULT, "futimesat"));
    std::ostringstream out;
    out << "{\"schema\":1,\"root\":" << Quote(rootPath) << ",\"fixturePath\":" << Quote(rootPath + '/' + leaf)
        << ",\"pid\":" << getpid() << ",\"uid\":" << getuid() << ",\"euid\":" << geteuid()
        << ",\"gid\":" << getgid() << ",\"egid\":" << getegid() << ",\"processIdentity\":" << ProcessIdentity()
        << ",\"rootState\":" << State(root.value) << ",\"directoryState\":" << State(directory.value)
        << ",\"statfsResult\":" << fsResult << ",\"statfsErrno\":" << fsError
        << ",\"filesystemType\":" << (fsResult ? "null" : Quote(std::to_string(filesystem.f_type)))
        << ",\"providers\":{\"futimens\":" << Provider(reinterpret_cast<const void*>(&futimens))
        << ",\"utimensat\":" << Provider(reinterpret_cast<const void*>(&utimensat))
        << ",\"futimes\":" << Provider(reinterpret_cast<const void*>(&futimes))
        << ",\"utimes\":" << Provider(reinterpret_cast<const void*>(&utimes))
        << ",\"futimesat\":" << Provider(reinterpret_cast<const void*>(futimesAt)) << "},\"operations\":[";
    std::vector<std::string> created;
    unsigned failures = 0, observed = 0;
    bool first = true;
    for (const std::string api : {"futimens", "utimensat", "futimes", "utimes", "futimesat"}) {
        const bool precise = api == "futimens" || api == "utimensat";
        const std::vector<std::string> modes = precise
            ? std::vector<std::string>{"same-explicit", "fixed-explicit", "null-now", "both-now", "mtime-now-atime-omit", "both-omit", "mtime-fixed-atime-omit"}
            : std::vector<std::string>{"same-explicit", "fixed-explicit", "null-now"};
        for (const auto& mode : modes) {
            if (!first) out << ',';
            first = false;
            out << "{\"api\":" << Quote(api) << ",\"mode\":" << Quote(mode);
            if (api == "futimesat" && !futimesAt) { out << ",\"status\":\"NOT-RUN\",\"reason\":\"symbol-unavailable\"}"; continue; }
            const std::string name = api + '-' + mode;
            Fd file(openat(directory.value, name.c_str(), O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600));
            if (file.value < 0) throw std::runtime_error("native time fixture create failed errno=" + std::to_string(errno));
            created.push_back(name);
            const char data[] = "amcl-native-time-probe";
            errno = 0;
            const ssize_t written = pwrite(file.value, data, sizeof(data), 0);
            const int writeError = written < 0 ? errno : 0;
            if (written != static_cast<ssize_t>(sizeof(data))) throw std::runtime_error("native time fixture pwrite incomplete");
            struct stat before{};
            if (fstat(file.value, &before)) throw std::runtime_error("native time fixture stat failed");
            const std::string beforeJson = State(file.value);
            std::array<timespec, 2> times{{before.st_atim, before.st_mtim}};
            if (mode == "fixed-explicit") times = {{{1600000000, 123456000}, {1600000010, 654321000}}};
            if (mode == "both-now") times = {{{0, UTIME_NOW}, {0, UTIME_NOW}}};
            if (mode == "mtime-now-atime-omit") times = {{{0, UTIME_OMIT}, {0, UTIME_NOW}}};
            if (mode == "both-omit") times = {{{0, UTIME_OMIT}, {0, UTIME_OMIT}}};
            if (mode == "mtime-fixed-atime-omit") times = {{{0, UTIME_OMIT}, {1600000010, 654321000}}};
            std::array<timeval, 2> micros{{{times[0].tv_sec, times[0].tv_nsec / 1000}, {times[1].tv_sec, times[1].tv_nsec / 1000}}};
            const bool nullTimes = mode == "null-now";
            const std::string absolute = rootPath + '/' + leaf + '/' + name;
            errno = 0;
            int result;
            if (api == "futimens") result = futimens(file.value, nullTimes ? nullptr : times.data());
            else if (api == "utimensat") result = utimensat(directory.value, name.c_str(), nullTimes ? nullptr : times.data(), 0);
            else if (api == "futimes") result = futimes(file.value, nullTimes ? nullptr : micros.data());
            else if (api == "utimes") result = utimes(absolute.c_str(), nullTimes ? nullptr : micros.data());
            else result = futimesAt(file.value, nullptr, nullTimes ? nullptr : micros.data());
            const int failure = result < 0 ? errno : 0;
            const std::string afterJson = State(file.value);
            struct stat after{}, pathAfter{};
            const bool sameObject = !fstat(file.value, &after) && !fstatat(directory.value, name.c_str(), &pathAfter, AT_SYMLINK_NOFOLLOW)
                && before.st_dev == after.st_dev && before.st_ino == after.st_ino
                && after.st_dev == pathAfter.st_dev && after.st_ino == pathAfter.st_ino;
            char actual[sizeof(data)]{};
            const bool bytesPreserved = pread(file.value, actual, sizeof(actual), 0) == static_cast<ssize_t>(sizeof(actual)) && std::memcmp(data, actual, sizeof(data)) == 0;
            if (result < 0 || !sameObject || !bytesPreserved) ++failures;
            ++observed;
            out << ",\"status\":\"OBSERVED\",\"pwriteBytes\":" << written << ",\"pwriteErrno\":" << writeError
                << ",\"before\":" << beforeJson << ",\"result\":" << result << ",\"errno\":" << failure
                << ",\"after\":" << afterJson << ",\"sameObject\":" << (sameObject ? "true" : "false")
                << ",\"bytesPreserved\":" << (bytesPreserved ? "true" : "false") << ",\"attributesBeforeContentRead\":true}";
        }
    }
    // 能力失败保留精确样本；成功才清理登记名称，不递归或遍历共享根。
    bool cleaned = failures == 0;
    if (cleaned) {
        for (const auto& name : created) if (unlinkat(directory.value, name.c_str(), 0) != 0) cleaned = false;
        if (cleaned && unlinkat(root.value, leaf.c_str(), AT_REMOVEDIR) != 0) cleaned = false;
    }
    out << "],\"observationComplete\":true,\"observedOperations\":" << observed << ",\"failedOperations\":" << failures
        << ",\"fixturesCleaned\":" << (cleaned ? "true" : "false") << '}';
    return out.str();
}
} // namespace amcl::nativetimeprobe
