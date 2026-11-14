/**
 * 嵌入JVM冷启动的原生临时根准备。必须在选中JDK的现有SH租约内读取libjvm合同，
 * 在RuntimeOnce认领前准备目录、认领后发布TMPDIR；不加载libjvm、不运行探针或改cwd。
 * 此处证明文件/目录身份与最低权限条件，真实AF_UNIX/共享PerfData资格另由目标专项证明。
 */
#pragma once
#include "jdk_native_temp_contract.h"
#include <cerrno>
#include <cstdlib>
#include <fcntl.h>
#include <limits>
#include <string>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

namespace amcl::jvm {

/** 冷路径映射同一个打开fd；更新器由外层现有安装租约排除，不用文件名或major猜能力。 */
inline NativeTempContract ReadNativeTempContractFile(const std::string& path, std::string& error) {
    const int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) { error = "无法打开libjvm合同: " + std::to_string(errno); return NativeTempContract::Invalid; }
    struct stat before{};
    if (fstat(fd, &before) != 0 || !S_ISREG(before.st_mode) || before.st_size <= 0 ||
        static_cast<uint64_t>(before.st_size) > std::numeric_limits<size_t>::max()) {
        error = "libjvm合同不是有效普通文件"; close(fd); return NativeTempContract::Invalid;
    }
    const size_t size = static_cast<size_t>(before.st_size);
    void* mapping = mmap(nullptr, size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (mapping == MAP_FAILED) {
        error = "无法映射libjvm合同: " + std::to_string(errno); close(fd); return NativeTempContract::Invalid;
    }
    const char* detail = nullptr;
    auto contract = ReadNativeTempContract(static_cast<const unsigned char*>(mapping), size, detail);
    struct stat after{};
    if (fstat(fd, &after) != 0 || before.st_dev != after.st_dev || before.st_ino != after.st_ino ||
        before.st_size != after.st_size || before.st_mtime != after.st_mtime || before.st_ctime != after.st_ctime) {
        contract = NativeTempContract::Invalid;
        error = "libjvm合同读取时文件身份变化";
    } else if (detail) error = detail;
    munmap(mapping, size);
    close(fd);
    return contract;
}


/** 只记录prepare已经观察到的输入和元数据，不另做探针、不枚举环境或修正权限。
 * path用UTF-8原字节的hex落在现有status记录，避免换行/引号使单条诊断难以解析。
 */
struct NativeTempPreparationTrace {
    const char* stage = "not-started";
    bool requestedPresent = false;
    bool requestedEmpty = false;
    bool explicitRoot = false;
    std::string selectedPath;
    bool parentObserved = false;
    bool directoryObserved = false;
    bool ownerObserved = false;
    uid_t expectedOwner = 0;
    struct stat parent{};
    struct stat directory{};
    static std::string hex(const std::string& input) {
        static const char digits[] = "0123456789abcdef";
        std::string result; result.reserve(input.size() * 2);
        for (unsigned char value : input) { result += digits[value >> 4]; result += digits[value & 15]; }
        return result;
    }
    static std::string metadata(bool observed, const struct stat& value) {
        if (!observed) return "null";
        return "{\"uid\":" + std::to_string(value.st_uid) + ",\"gid\":" + std::to_string(value.st_gid) +
            ",\"mode\":" + std::to_string(value.st_mode & 07777) +
            ",\"type\":" + std::to_string(value.st_mode & S_IFMT) +
            ",\"dev\":\"" + std::to_string(value.st_dev) + "\",\"ino\":\"" + std::to_string(value.st_ino) + "\"}";
    }
    std::string json(int result) const {
        return "{\"stage\":\"" + std::string(stage) + "\",\"errno\":" + std::to_string(result) +
            ",\"requestedTmpdirPresent\":" + (requestedPresent ? "true" : "false") +
            ",\"requestedTmpdirEmpty\":" + (requestedEmpty ? "true" : "false") +
            ",\"explicitRoot\":" + (explicitRoot ? "true" : "false") +
            ",\"selectedPathHex\":\"" + hex(selectedPath) + "\",\"selectedPathBytes\":" + std::to_string(selectedPath.size()) +
            ",\"expectedOwner\":" + (ownerObserved ? std::to_string(expectedOwner) : "null") +
            ",\"parent\":" + metadata(parentObserved, parent) +
            ",\"directory\":" + metadata(directoryObserved, directory) + "}";
    }
};

class PreparedNativeTempRoot final {
    int fd_ = -1;
    std::string path_;

    /** 子目录只允许当前euid拥有且owner可读写进入；不接收其他用户可写的临时根。 */
    static int validateDirectory(int fd, NativeTempPreparationTrace* trace = nullptr) noexcept {
        if (trace) trace->stage = "directory-fstat";
        struct stat value{};
        if (fstat(fd, &value) != 0) return errno;
        if (trace) { trace->directoryObserved = true; trace->directory = value; trace->stage = "directory-type"; }
        if (!S_ISDIR(value.st_mode)) return ENOTDIR;
        const uid_t owner = geteuid();
        if (trace) { trace->ownerObserved = true; trace->expectedOwner = owner; trace->stage = "directory-owner-mode"; }
        if (value.st_uid != owner || (value.st_mode & 0700) != 0700 || (value.st_mode & 0022) != 0)
            return EACCES;
        return 0;
    }
public:
    PreparedNativeTempRoot() = default;
    PreparedNativeTempRoot(const PreparedNativeTempRoot&) = delete;
    PreparedNativeTempRoot& operator=(const PreparedNativeTempRoot&) = delete;
    ~PreparedNativeTempRoot() {
        const int saved = errno;
        if (fd_ >= 0) close(fd_);
        errno = saved;
    }
    const std::string& path() const noexcept { return path_; }

    /** 嵌入入口只使用调用者的真实应用父根，不把系统继承TMPDIR误判为用户选择。
     * 当前OHOS真机已观察到0777的cache目录，它不满足Attach/PerfData的私有根合同。
     * 这里只选择/准备filesDir/tmp，不读取或更改进程环境；环境仍由后续单owner
     * publish负责，在CreateVM前失败时精确恢复原系统值。独立JDK的TMPDIR合同不变。 */
    int prepareEmbedded(const char* appFilesDir, NativeTempPreparationTrace* trace = nullptr) {
        return prepare(appFilesDir, nullptr, trace);
    }

    /** Unix地址按平台字节核算；既留listener临时名.tmp，也留工具的/proc/<pid>/root前缀。 */
    static int addressBudget(const std::string& path) {
        const size_t pidBytes = std::to_string(std::numeric_limits<pid_t>::max()).size();
        const size_t addressBytes = sizeof(((struct sockaddr_un*)nullptr)->sun_path);
        const size_t listenerTail = sizeof("/.java_pid") - 1 + pidBytes + sizeof(".tmp") - 1;
        const size_t namespacePrefix = sizeof("/proc/") - 1 + pidBytes + sizeof("/root") - 1;
        const size_t clientTail = sizeof("/.java_pid") - 1 + pidBytes;
        return path.size() + listenerTail >= addressBytes ||
               namespacePrefix + path.size() + clientTail >= addressBytes ? ENAMETOOLONG : 0;
    }

    /** 发布前以最终路径重新核对持有fd；rename/替换不能把旧对象的通过检查套到新名字。 */
    int revalidate() const noexcept {
        if (fd_ < 0 || path_.empty()) return EINVAL;
        const int usable = validateDirectory(fd_);
        if (usable != 0) return usable;
        struct stat held{}, named{};
        if (fstat(fd_, &held) != 0) return errno;
        if (lstat(path_.c_str(), &named) != 0) return errno == ENOENT ? ESTALE : errno;
        if (!S_ISDIR(named.st_mode) || held.st_dev != named.st_dev || held.st_ino != named.st_ino)
            return ESTALE;
        return named.st_uid == geteuid() && (named.st_mode & 0700) == 0700 && (named.st_mode & 0022) == 0 ? 0 : EACCES;
    }

    /**
     * 仅新合同包调用。显式TMPDIR必须是已经存在的合法私有目录，绝不在未知根递归建树。
     * 无显式值时从调用者真实appFilesDir的fd创建一个tmp子目录；父目录可保持平台原0770。
     * 全程不setenv，因此认领前失败不会改变进程环境，legacy包完全不进入此函数。
     */
    int prepare(const char* appFilesDir, const char* explicitTmpdir, NativeTempPreparationTrace* trace = nullptr) {
        if (trace) {
            *trace = NativeTempPreparationTrace{};
            trace->stage = "fresh-state";
            trace->requestedPresent = explicitTmpdir != nullptr;
            trace->requestedEmpty = explicitTmpdir && !explicitTmpdir[0];
        }
        if (fd_ >= 0 || !path_.empty()) return EALREADY;
        const bool explicitRoot = explicitTmpdir && explicitTmpdir[0];
        if (trace) { trace->explicitRoot = explicitRoot; trace->stage = "absolute-input"; }
        const char* selected = explicitRoot ? explicitTmpdir : appFilesDir;
        if (trace && selected) trace->selectedPath = selected;
        if (!selected || selected[0] != '/') return EINVAL;
        path_ = selected;
        while (path_.size() > 1 && path_.back() == '/') path_.pop_back();
        if (trace) trace->stage = "path-length";
        if (path_.size() >= 4096) return ENAMETOOLONG;
        const std::string finalPath = explicitRoot ? path_ : path_ + (path_ == "/" ? "tmp" : "/tmp");
        if (trace) { trace->selectedPath = finalPath; trace->stage = "address-budget"; }
        const int addressError = addressBudget(finalPath);
        if (addressError != 0) return addressError;
        if (explicitRoot) {
            if (trace) trace->stage = "explicit-open";
            fd_ = open(path_.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
            if (fd_ < 0) return errno;
            const int result = validateDirectory(fd_, trace);
            if (trace && result == 0) trace->stage = "ready";
            return result;
        }
        if (trace) trace->stage = "parent-open";
        const int root = open(path_.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (root < 0) return errno;
        struct stat parent{};
        int result = 0;
        if (trace) trace->stage = "parent-fstat";
        if (fstat(root, &parent) != 0) result = errno;
        else {
            if (trace) { trace->parentObserved = true; trace->parent = parent; trace->stage = "parent-owner"; }
            // 与原短路条件相同：非目录不读owner，也不继续mkdir。
            if (!S_ISDIR(parent.st_mode)) result = EACCES;
            else {
                const uid_t owner = geteuid();
                if (trace) { trace->ownerObserved = true; trace->expectedOwner = owner; }
                if (parent.st_uid != owner) result = EACCES;
                else {
                    if (trace) trace->stage = "child-mkdir";
                    if (mkdirat(root, "tmp", 0700) != 0 && errno != EEXIST) result = errno;
                }
            }
        }
        if (result == 0) {
            if (trace) trace->stage = "child-open";
            fd_ = openat(root, "tmp", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
            if (fd_ < 0) result = errno;
            else result = validateDirectory(fd_, trace);
        }
        // 与原实现相同，只核既有持有fd/目录项；诊断不新增stat或修改目录。
        if (result == 0) {
            struct stat opened{}, named{};
            if (trace) trace->stage = "identity-held-fstat";
            if (fstat(fd_, &opened) != 0) result = errno;
            else {
                if (trace) trace->stage = "identity-entry-fstatat";
                if (fstatat(root, "tmp", &named, AT_SYMLINK_NOFOLLOW) != 0) result = errno;
                else if (!S_ISDIR(named.st_mode) || opened.st_dev != named.st_dev || opened.st_ino != named.st_ino) {
                    if (trace) trace->stage = "identity-compare";
                    result = ESTALE;
                }
            }
        }
        close(root);
        if (result != 0) return result;
        path_ += path_ == "/" ? "tmp" : "/tmp";
        if (trace) trace->stage = path_.size() < 4096 ? "ready" : "path-length";
        return path_.size() < 4096 ? 0 : ENAMETOOLONG;
    }
};

/**
 * TMPDIR唯一环境写者。仅fresh进程在创建认领后publish；任何CreateJavaVM之前的早退
 * 都恢复原来的缺席/空字符串/正文。进入VM前retainAfterVmEntry解除回滚，之后即使VM
 * 返回失败也维持restart boundary，不能在可能已有JVM线程时释放/重写环境正文。
 */
class NativeTempEnvironment final {
    bool published_ = false;
    bool changed_ = false;
    bool hadValue_ = false;
    bool retain_ = false;
    std::string original_;
    void (*rollbackFailure_)(int);
public:
    explicit NativeTempEnvironment(void (*rollbackFailure)(int)) : rollbackFailure_(rollbackFailure) {}
    NativeTempEnvironment(const NativeTempEnvironment&) = delete;
    NativeTempEnvironment& operator=(const NativeTempEnvironment&) = delete;
    ~NativeTempEnvironment() {
        const int saved = errno;
        const int failure = restoreBeforeVm();
        if (failure != 0 && rollbackFailure_) rollbackFailure_(failure);
        errno = saved;
    }
    int publish(const std::string& selected) {
        if (published_) return EALREADY;
        const char* before = getenv("TMPDIR");
        hadValue_ = before != nullptr;
        original_ = before ? before : "";
        published_ = true;
        if (hadValue_ && original_ == selected) return 0;
        if (setenv("TMPDIR", selected.c_str(), 1) != 0) return errno;
        changed_ = true;
        return 0;
    }
    int restoreBeforeVm() noexcept {
        if (!changed_ || retain_) return 0;
        changed_ = false; // 失败只报告一次，不在析构中隐式反复重试并掩盖第一项错误。
        const int result = hadValue_ ? setenv("TMPDIR", original_.c_str(), 1) : unsetenv("TMPDIR");
        return result == 0 ? 0 : errno;
    }
    void retainAfterVmEntry() noexcept { retain_ = true; }
};
}
