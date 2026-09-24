#pragma once
/**
 * 游戏会话原始输出的进程级所有者。准备阶段允许分配/建目录，JVM 退出阶段只使用
 * 预先保存的路径和 fd，不调用 JVM、NAPI、stdio 锁或异步 logger；fork 子进程拒绝旧身份。
 * console 从 JVM 初始化之前持续追加，JVM 初始化独立文件只暂时接管 1/2 并恢复到 console。
 */
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <fcntl.h>
#include <sys/stat.h>
#ifdef _WIN32
#include <io.h>
#include <direct.h>
#include <process.h>
#else
#include <unistd.h>
#endif

namespace amcl::sessionlog {
inline int closeFd(int fd) {
#ifdef _WIN32
    return _close(fd);
#else
    return close(fd);
#endif
}
inline int syncFd(int fd) {
#ifdef _WIN32
    return _commit(fd);
#else
    return fsync(fd);
#endif
}
inline int pid() {
#ifdef _WIN32
    return _getpid();
#else
    return getpid();
#endif
}
inline int openFile(const char* path, bool truncate = false) {
#ifdef _WIN32
    return _open(path, _O_WRONLY | _O_CREAT | _O_BINARY | (truncate ? _O_TRUNC : _O_APPEND), _S_IREAD | _S_IWRITE);
#else
    return open(path, O_WRONLY | O_CREAT | O_CLOEXEC | (truncate ? O_TRUNC : O_APPEND), 0600);
#endif
}
inline int duplicate(int fd) {
#ifdef _WIN32
    return _dup(fd);
#else
    return dup(fd);
#endif
}
inline bool redirect(int source, int destination) {
#ifdef _WIN32
    return _dup2(source, destination) == 0;
#else
    return dup2(source, destination) >= 0;
#endif
}
/** 短写和 EINTR 必须继续写完；其他失败交给状态记录，不能当成成功字节。 */
inline bool writeAll(int fd, const char* bytes, size_t size) {
    size_t offset = 0;
    unsigned interrupted = 0;
    while (offset < size) {
#ifdef _WIN32
        const int count = _write(fd, bytes + offset, static_cast<unsigned>(size - offset));
#else
        const ssize_t count = write(fd, bytes + offset, size - offset);
#endif
        if (count < 0 && errno == EINTR && interrupted++ < 8) continue;
        if (count <= 0) return false;
        offset += static_cast<size_t>(count);
    }
    return true;
}
inline bool makeDirectory(const std::string& path) {
    struct stat st{};
    if (stat(path.c_str(), &st) == 0) return (st.st_mode & S_IFDIR) != 0;
#ifdef _WIN32
    return _mkdir(path.c_str()) == 0 || errno == EEXIST;
#else
    return mkdir(path.c_str(), 0700) == 0 || errno == EEXIST;
#endif
}
struct State {
    long long activity = 0;
    int ownerPid = 0;
    int consoleFd = -1;
    char directory[1024]{};
    char console[1200]{};
    char jvm[1200]{};
    char status[1200]{};
    char temporary[1240]{};
    std::atomic<int> error{0};
    std::atomic<bool> javaAttached{false};
    std::atomic<bool> gameStarted{false};
    std::atomic<bool> ended{false};
};
// C++17 inline 变量保证 libentry 内多个 TU 共用状态；独立 GLFW DSO 不包含本文件。
inline State state;
inline bool owned() { return state.activity > 0 && state.ownerPid == pid(); }

/** 固定容量状态原子替换；保存失败也保留 error，后续重试不抹掉本局失败事实。 */
inline bool saveStatus() {
    if (!owned()) return false;
    char json[512];
    const int length = snprintf(json, sizeof(json),
        "{\"schema\":1,\"activityId\":%lld,\"pid\":%d,\"consoleReady\":%s,\"javaAttached\":%s,\"gameStarted\":%s,\"ended\":%s,\"ioError\":%d}",
        state.activity, state.ownerPid, state.consoleFd >= 0 ? "true" : "false",
        state.javaAttached.load() ? "true" : "false", state.gameStarted.load() ? "true" : "false",
        state.ended.load() ? "true" : "false", state.error.load());
    const int fd = openFile(state.temporary, true);
    if (fd < 0) { state.error.store(errno); return false; }
    const bool written = length > 0 && length < static_cast<int>(sizeof(json))
        && writeAll(fd, json, static_cast<size_t>(length)) && syncFd(fd) == 0;
    const int error = errno;
    closeFd(fd);
    if (!written) { state.error.store(error ? error : EIO); return false; }
#ifdef _WIN32
    remove(state.status); // 宿主 Windows rename 不覆盖；设备走 POSIX 原子替换。
#endif
    if (rename(state.temporary, state.status) != 0) { state.error.store(errno); return false; }
    return true;
}

/** 仅在首次游戏启动、JVM 尚未创建时调用；重复同身份幂等，拒绝跨会话复用原件。 */
inline bool prepare(const char* filesDir, long long activity) {
    if (activity <= 0) return true; // 非游戏旧工具路径仍使用原来的诊断文件。
    if (owned() && state.consoleFd >= 0) return state.activity == activity && !state.ended.load();
    if (!filesDir || !*filesDir) return false;
    const std::string logs = std::string(filesDir) + "/logs";
    const std::string ledger = logs + "/ledger";
    const std::string directory = ledger + "/" + std::to_string(activity);
    if (directory.size() >= sizeof(state.directory)) return false;
    state.activity = activity; state.ownerPid = pid();
    std::snprintf(state.directory, sizeof(state.directory), "%s", directory.c_str());
    std::snprintf(state.console, sizeof(state.console), "%s/game/mc_output.log", state.directory);
    std::snprintf(state.jvm, sizeof(state.jvm), "%s/jvm/jvm-stderr.log", state.directory);
    std::snprintf(state.status, sizeof(state.status), "%s/native-io.json", state.directory);
    std::snprintf(state.temporary, sizeof(state.temporary), "%s.partial", state.status);
    if (!makeDirectory(logs) || !makeDirectory(ledger) || !makeDirectory(directory)
        || !makeDirectory(directory + "/game") || !makeDirectory(directory + "/jvm")) {
        state.error.store(errno ? errno : EIO); saveStatus(); return false;
    }
    const int fd = openFile(state.console);
    if (fd < 0) { state.error.store(errno); saveStatus(); return false; }
    const int out = duplicate(1), err = duplicate(2);
    if (out < 0 || err < 0 || !redirect(fd, 1) || !redirect(fd, 2)) {
        const int error = errno;
        if (out >= 0) { redirect(out, 1); closeFd(out); }
        if (err >= 0) { redirect(err, 2); closeFd(err); }
        closeFd(fd); state.error.store(error ? error : EIO); saveStatus(); return false;
    }
    closeFd(out); closeFd(err); state.consoleFd = fd;
    // C stdout/stderr 不再依赖进程退出才刷新；Java FileOutputStream 同样直接追加本文件。
    setvbuf(stdout, nullptr, _IONBF, 0); setvbuf(stderr, nullptr, _IONBF, 0);
    char banner[160];
    const int size = snprintf(banner, sizeof(banner), "##AMCL-SESSION-BEGIN {\"activityId\":%lld,\"epochMs\":%lld}\n", activity, activity);
    if (!writeAll(fd, banner, static_cast<size_t>(size)) || syncFd(fd) != 0) state.error.store(errno ? errno : EIO);
    return saveStatus() && state.error.load() == 0;
}

inline const char* consolePath() { return owned() ? state.console : ""; }
inline const char* jvmPath() { return owned() ? state.jvm : ""; }
inline void failure(int error) { if (owned()) { state.error.store(error ? error : EIO); saveStatus(); } }
inline void javaReady() { if (owned()) { state.javaAttached.store(true); saveStatus(); } }
inline void gameReady() { if (owned()) { state.gameStarted.store(true); saveStatus(); } }

/** JNI halt/main 已结束时调用；不等异步 logger，不触碰 JVM/stdio 锁，保留原退出码。 */
inline void finish() {
    if (!owned() || state.ended.exchange(true)) return;
    if (state.consoleFd >= 0) {
        const char end[] = "\n##AMCL-SESSION-END\n";
        if (!writeAll(state.consoleFd, end, sizeof(end) - 1) || syncFd(state.consoleFd) != 0) {
            state.error.store(errno ? errno : EIO);
        }
    }
    saveStatus();
}
} // namespace amcl::sessionlog
