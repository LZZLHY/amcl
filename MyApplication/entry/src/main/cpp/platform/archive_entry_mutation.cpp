#include "archive_entry_mutation.h"
#include <atomic>
#include <cerrno>
#include <chrono>
#include <dirent.h>
#include <fcntl.h>
#include <memory>
#include <string>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

namespace amcl::archive {
#ifdef AMCL_ARCHIVE_MUTATION_HOST_TEST
// 仅宿主测试编译此声明，以便在真实系统调用之间安排同名恢复、移动和只读错误。
extern bool MutationTestStep(const char *step, int fd, const std::string &name);
#else
static bool MutationTestStep(const char *, int, const std::string &) { return true; }
#endif

namespace {
struct Fd {
    int fd;
    explicit Fd(int value) : fd(value) {}
    ~Fd() { if (fd >= 0) close(fd); }
    Fd(const Fd &) = delete;
    Fd &operator=(const Fd &) = delete;
};

bool leaf(const std::string &s) {
    return !s.empty() && s != "." && s != ".." && s.find('/') == std::string::npos &&
        s.find('\\') == std::string::npos && s.find('\0') == std::string::npos;
}

bool same(const struct stat &a, const struct stat &b) {
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino && (a.st_mode & S_IFMT) == (b.st_mode & S_IFMT);
}

bool stillAt(int parent, const std::string &name, const struct stat &pinned) {
    struct stat current{};
    return fstatat(parent, name.c_str(), &current, AT_SYMLINK_NOFOLLOW) == 0 && same(current, pinned);
}

bool stillAt(int parent, const std::string &name, int opened) {
    struct stat pinned{};
    return fstat(opened, &pinned) == 0 && stillAt(parent, name, pinned);
}

// 正式名称可能由外部文件管理器同时恢复，绝不以“先检查不存在，再普通 rename”写回。
bool moveExclusive(int from, const std::string &source, int to, const std::string &dest) {
#ifdef AMCL_ARCHIVE_MUTATION_HOST_TEST
    if (!MutationTestStep("exclusive", from, source)) { errno = EOPNOTSUPP; return false; }
#endif
#ifdef SYS_renameat2
    constexpr unsigned noReplace = 1;
    if (syscall(SYS_renameat2, from, source.c_str(), to, dest.c_str(), noReplace) == 0) return true;
#else
    errno = ENOSYS;
#endif
    return false;
}

std::string makeStage(int parent) {
    static std::atomic<unsigned long long> serial{0};
    const auto ticks = std::chrono::steady_clock::now().time_since_epoch().count();
    for (int i = 0; i < 8; ++i) {
        const std::string name = ".amcl-entry-" + std::to_string(getpid()) + "-" + std::to_string(ticks) +
            "-" + std::to_string(serial.fetch_add(1));
        if (mkdirat(parent, name.c_str(), 0700) == 0) return name;
        if (errno != EEXIST) break;
    }
    return {};
}

// 每层 fd 固定到原对象。离开隔离目录或换成链接后，不继续在移动后的子树内删除。
struct BoundDir {
    const BoundDir *above;
    int parent;
    const std::string &name;
    int fd;
    bool attached() const { return (!above || above->attached()) && stillAt(parent, name, fd); }
};

bool emptyContents(const BoundDir &dir, unsigned depth = 0) {
    using Directory = std::unique_ptr<DIR, int(*)(DIR*)>;
    if (depth >= 256 || !dir.attached()) return false;
    const int scan = fcntl(dir.fd, F_DUPFD_CLOEXEC, 0);
    if (scan < 0) return false;
    Directory list(fdopendir(scan), closedir);
    if (!list) { close(scan); return false; }
    while (true) {
        errno = 0;
        const auto *next = readdir(list.get());
        if (!next) return errno == 0 && dir.attached();
        const std::string name = next->d_name;
        if (name == "." || name == "..") continue;
        if (!MutationTestStep("child", dir.fd, name) || !dir.attached()) return false;
        struct stat before{};
        if (fstatat(dir.fd, name.c_str(), &before, AT_SYMLINK_NOFOLLOW) != 0) return false;
        if (S_ISDIR(before.st_mode)) {
            Fd child(openat(dir.fd, name.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
            struct stat pinned{};
            if (child.fd < 0 || fstat(child.fd, &pinned) != 0 || !same(before, pinned)) return false;
            BoundDir nested{&dir, dir.fd, name, child.fd};
            if (!emptyContents(nested, depth + 1) || !nested.attached() || unlinkat(dir.fd, name.c_str(), AT_REMOVEDIR) != 0) return false;
        } else {
            // 对符号链接仅移除链接本身。遇到变化或系统拒绝时留下其余成员供恢复。
            struct stat current{};
            if (!dir.attached() || fstatat(dir.fd, name.c_str(), &current, AT_SYMLINK_NOFOLLOW) != 0 ||
                !same(before, current) || unlinkat(dir.fd, name.c_str(), 0) != 0) return false;
        }
    }
}
}

std::string MutateConfirmedEntry(int parent, int entry, const std::string &name, const std::string &newName) {
    struct stat original{};
    if (!leaf(name) || (!newName.empty() && (!leaf(newName) || newName == name)) || fstat(entry, &original) != 0 ||
        (!S_ISDIR(original.st_mode) && !S_ISREG(original.st_mode)) || !stillAt(parent, name, entry))
        return "原项目已变化，操作已停止";
    const std::string stageName = makeStage(parent);
    if (stageName.empty()) return "无法在原目录中创建本次操作的暂存目录";
    Fd stage(openat(parent, stageName.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    if (stage.fd < 0) return "暂存目录无法打开，请检查 " + stageName;
    BoundDir guarded{nullptr, parent, stageName, stage.fd};
    const auto clearStage = [&]() {
        if (guarded.attached()) unlinkat(parent, stageName.c_str(), AT_REMOVEDIR);
    };
    // 旧内核或公共存储可能只支持普通 rename。改名必须无覆盖，先用独占目录内的空目录
    // 实际验证支持度，使拒绝不改变用户文件；日常删除进私有空槽不依赖此扩展。
    if (!newName.empty()) {
        const bool created = mkdirat(stage.fd, ".cap", 0700) == 0;
        const bool supported = created && moveExclusive(stage.fd, ".cap", stage.fd, ".cap-ok");
        if (created) unlinkat(stage.fd, supported ? ".cap-ok" : ".cap", AT_REMOVEDIR);
        if (!supported) { clearStage(); return "当前目录不支持安全改名，原项目已保留"; }
    }
    if (!MutationTestStep("beforeStage", parent, name) || !guarded.attached() || !stillAt(parent, name, entry)) {
        clearStage(); return "原项目已变化，操作已停止";
    }
    // 私有目录新建且为空；不支持 renameat2 的文件系统仍可正常把条目移进本次隔离区。
    // 只有这个初始私有空槽可用普通 renameat，回迁及公开的改名目标永远要求内核无覆盖语义。
    if (!MutationTestStep("preMove", parent, name)) { clearStage(); return "操作已停止"; }
    bool staged = moveExclusive(parent, name, stage.fd, name);
    if (!staged && (errno == ENOSYS || errno == EINVAL || errno == EOPNOTSUPP)) {
        struct stat occupied{};
        if (guarded.attached() && fstatat(stage.fd, name.c_str(), &occupied, AT_SYMLINK_NOFOLLOW) < 0 &&
            errno == ENOENT) staged = renameat(parent, name.c_str(), stage.fd, name.c_str()) == 0;
    }
    if (!staged) { clearStage(); return "无法隔离原项目，操作已停止"; }

    const auto recover = [&](bool justMoved = false) -> std::string {
        // 对隔离后发现的换代条目也只尝试原样放回。已经恢复的同名世界及隔离区中的其它文件均保留。
        if (!guarded.attached()) return "暂存目录已移动或替换，请查找本次暂存目录 " + stageName;
        if (!justMoved && !stillAt(stage.fd, name, original)) return "原项目已从暂存目录移走或被替换，请检查 " + stageName;
        if (moveExclusive(stage.fd, name, parent, name)) {
            clearStage(); return "操作未完成，保留内容已放回原位置";
        }
        return "操作未完成，请在原目录的 " + stageName + "/" + name + " 查找保留内容";
    };
    if (!guarded.attached() || !stillAt(stage.fd, name, original)) return recover(true);
    if (!MutationTestStep("staged", stage.fd, name) || !guarded.attached() || !stillAt(stage.fd, name, original)) return recover();
    if (!newName.empty()) {
        if (!moveExclusive(stage.fd, name, parent, newName)) return recover();
    } else {
        const bool directory = S_ISDIR(original.st_mode);
        if (directory) {
            // 某些共享文件系统不能从改名前的目录 fd 继续 openat(".")。在隔离目录内重开，
            // 再与最初仍持有的 fd 比较 dev/inode，随后使用隔离位置取得的目录句柄遍历。
            Fd isolated(openat(stage.fd, name.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
            struct stat pinned{};
            if (isolated.fd < 0 || fstat(isolated.fd, &pinned) != 0 || !same(original, pinned)) return recover();
            BoundDir selected{&guarded, stage.fd, name, isolated.fd};
            if (!emptyContents(selected)) return recover();
        }
        if (!guarded.attached() || !stillAt(stage.fd, name, original) ||
            unlinkat(stage.fd, name.c_str(), directory ? AT_REMOVEDIR : 0) != 0) return recover();
    }
    clearStage();
    return {};
}
}
