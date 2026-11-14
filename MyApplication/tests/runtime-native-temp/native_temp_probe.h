/**
 * native temp 的固定平台前置观察：只触碰自建唯一目录内的三个固定对象。
 * 不创建VM、不加载可执行、不fork，也不把本进程Unix socket/mmap等同于跨VM工具资格。
 * 所有原始系统调用结果/errno逐项落报告；父NCP必须另有10s身份约束看门狗，
 * 因为本地单次文件系统/NSS调用不保证可由本线程取消。短轮询只用于非阻塞socket。
 */
#pragma once
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <poll.h>
#include <pwd.h>
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <vector>

namespace amcl::nativetempprobe {
using Clock = std::chrono::steady_clock;

/** 文本只用于本轮结构化报告；JSON结构字符和控制字节必须转义。 */
inline std::string Quote(const std::string& value) {
    static const char hex[] = "0123456789abcdef";
    std::string out = "\"";
    for (unsigned char byte : value) {
        if (byte == '"' || byte == '\\') { out += '\\'; out += char(byte); }
        else if (byte < 32) { out += "\\u00"; out += hex[byte >> 4]; out += hex[byte & 15]; }
        else out += char(byte);
    }
    return out + '"';
}

inline bool ValidNonce(const std::string& value) {
    return !value.empty() && value.size() <= 32 && std::all_of(value.begin(), value.end(), [](unsigned char ch) {
        return (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '-';
    });
}

inline bool ValidPath(const std::string& value) {
    return value.size() > 1 && value.size() < 4096 && value.front() == '/' &&
           value.find('\0') == std::string::npos && value.find('\n') == std::string::npos && value.find('\r') == std::string::npos;
}

/** descriptor只在当前调用内拥有；正常路径显式close并记录，异常析构只是最后保底。 */
struct Fd {
    int value = -1;
    explicit Fd(int fd = -1) : value(fd) {}
    ~Fd() { if (value >= 0) ::close(value); }
    Fd(const Fd&) = delete;
    Fd& operator=(const Fd&) = delete;
};

/** 结果>=0时errno不构成错误；失败后的errno必须在其它调用之前保存。 */
struct Calls {
    std::vector<std::string> rows;
    void Add(const char* operation, int64_t result, int error, const std::string& path = "", bool system = true) {
        rows.push_back("{\"operation\":" + Quote(operation) + ",\"result\":" + std::to_string(result) +
                       ",\"errno\":" + std::to_string(error) + ",\"kind\":" + Quote(system ? "syscall" : "contract") +
                       ",\"path\":" + Quote(path) + '}');
    }
    void Check(const char* operation, int error, const std::string& path = "") { Add(operation, -1, error, path, false); }
    int Posix(const char* operation, int result, const std::string& path = "") {
        const int error = result < 0 ? errno : 0; Add(operation, result, error, path); return result;
    }
    void Close(Fd& fd, const char* operation) {
        if (fd.value < 0) return;
        const int value = fd.value; fd.value = -1;
        // close出错也不按数字fd重试；其它线程可能已复用该编号。
        Posix(operation, ::close(value));
    }
    std::string Json() const {
        std::string out = "[";
        for (size_t i = 0; i < rows.size(); ++i) { if (i) out += ','; out += rows[i]; }
        return out + ']';
    }
};

inline std::string Metadata(const struct stat& info) {
    return "{\"dev\":" + std::to_string(uint64_t(info.st_dev)) + ",\"ino\":" + std::to_string(uint64_t(info.st_ino)) +
        ",\"mode\":" + std::to_string(info.st_mode & 07777) + ",\"type\":" + std::to_string(info.st_mode & S_IFMT) +
        ",\"uid\":" + std::to_string(info.st_uid) +
        ",\"gid\":" + std::to_string(info.st_gid) + ",\"size\":" + std::to_string(info.st_size) + '}';
}

/** 只查本进程真实/有效UID，不查询别人的文件。getpwuid_r返回码与errno分开记录。 */
inline std::string UserMapping(uid_t uid) {
    struct passwd item{};
    struct passwd* found = nullptr;
    std::vector<char> buffer(4096);
    int result = 0, saved = 0;
    do {
        errno = 0; result = getpwuid_r(uid, &item, buffer.data(), buffer.size(), &found); saved = errno;
        if (result != ERANGE || buffer.size() == 65536) break;
        buffer.resize(buffer.size() * 2);
    } while (true);
    // 名字保留原始字节hex，避免把本地编码错误解释成UTF-8而毁掉完整JSON；不记录home/shell。
    std::string nameHex;
    bool nameComplete = true;
    if (!result && found && found->pw_name) {
        static const char hex[] = "0123456789abcdef";
        const size_t length = strnlen(found->pw_name, 1024);
        nameComplete = length < 1024;
        for (size_t i = 0; i < length; ++i) {
            const unsigned char value = static_cast<unsigned char>(found->pw_name[i]);
            nameHex += hex[value >> 4]; nameHex += hex[value & 15];
        }
    }
    return "{\"requestedUid\":" + std::to_string(uid) + ",\"returnCode\":" + std::to_string(result) +
        ",\"errnoAfter\":" + std::to_string(saved) + ",\"found\":" + (!result && found ? "true" : "false") +
        ",\"bufferBytes\":" + std::to_string(buffer.size()) + ",\"nameComplete\":" + (nameComplete ? "true" : "false") +
        ",\"nameHex\":" + Quote(nameHex) + ",\"mappedUid\":" + std::to_string(!result && found ? int64_t(found->pw_uid) : -1) +
        ",\"mappedGid\":" + std::to_string(!result && found ? int64_t(found->pw_gid) : -1) + '}';
}

/** 非阻塞socket最多等固定250ms，且不延长整组预算；超时与poll错误都单独保留。 */
inline bool Wait(Calls& calls, int fd, short events, Clock::time_point deadline) {
    const auto now = Clock::now();
    if (now >= deadline) { calls.Check("poll-deadline", ETIMEDOUT); return false; }
    const int remaining = int(std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count());
    pollfd pending{fd, events, 0};
    int result;
    do { result = poll(&pending, 1, std::min(250, std::max(1, remaining))); } while (result < 0 && errno == EINTR && Clock::now() < deadline);
    calls.Posix("poll", result);
    if (result == 0) { calls.Check("poll-timeout", ETIMEDOUT); return false; }
    calls.Add("poll-revents", pending.revents, 0);
    return result > 0 && (pending.revents & events) != 0;
}

/** Unix socket只在本进程两端之间交换固定字节，并核SO_PEERCRED；没有fork或Attach命令。 */
inline bool UnixSocket(int directory, const std::string& path, Calls& calls, Clock::time_point deadline,
                       std::string& peer, std::string& metadata, bool& created) {
    struct sockaddr_un address{};
    if (path.size() >= sizeof(address.sun_path)) {
        calls.Check("socket-path-limit-no-syscall", ENAMETOOLONG, path); return false;
    }
    struct stat byFd{}, byPath{};
    if (calls.Posix("socket-directory-fstat", fstat(directory, &byFd)) < 0 ||
        calls.Posix("socket-directory-stat", stat(path.substr(0, path.find_last_of('/')).c_str(), &byPath)) < 0 ||
        byFd.st_dev != byPath.st_dev || byFd.st_ino != byPath.st_ino) {
        calls.Check("socket-directory-identity-check", ESTALE); return false;
    }
    Fd server(socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0));
    calls.Posix("socket-server", server.value);
    Fd client, accepted;
    bool result = false;
    do {
        if (server.value < 0) break;
        address.sun_family = AF_UNIX; std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
        const int bound = bind(server.value, reinterpret_cast<sockaddr*>(&address), sizeof(address));
        if (bound == 0) created = true;
        if (calls.Posix("bind", bound, path) < 0) break;
        if (calls.Posix("socket-chmod", fchmodat(directory, "s", 0600, 0), path) < 0 ||
            calls.Posix("socket-chown-self", fchownat(directory, "s", geteuid(), getegid(), AT_SYMLINK_NOFOLLOW), path) < 0 ||
            calls.Posix("listen", listen(server.value, 1)) < 0) break;
        struct stat socketInfo{};
        if (calls.Posix("socket-lstat", fstatat(directory, "s", &socketInfo, AT_SYMLINK_NOFOLLOW), path) < 0) break;
        metadata = Metadata(socketInfo);
        if (!S_ISSOCK(socketInfo.st_mode) || (socketInfo.st_mode & 0777) != 0600 ||
            socketInfo.st_uid != geteuid() || socketInfo.st_gid != getegid()) break;
        client.value = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
        calls.Posix("socket-client", client.value);
        if (client.value < 0) break;
        const int connected = connect(client.value, reinterpret_cast<sockaddr*>(&address), sizeof(address));
        const int connectError = connected < 0 ? errno : 0;
        calls.Add("connect", connected, connectError, path);
        // EINPROGRESS是非阻塞进展，最终结果必须由SO_ERROR确认，不能把它当成功或隐藏原errno。
        if (connected < 0 && connectError != EINPROGRESS && connectError != EAGAIN) break;
        if (connected < 0 && !Wait(calls, client.value, POLLOUT, deadline)) break;
        int socketError = -1; socklen_t errorBytes = sizeof(socketError);
        if (calls.Posix("getsockopt-SO_ERROR", getsockopt(client.value, SOL_SOCKET, SO_ERROR, &socketError, &errorBytes)) < 0 ||
            errorBytes != sizeof(socketError) || socketError != 0) {
            calls.Check("connect-completion", socketError > 0 ? socketError : EIO); break;
        }
        if (!Wait(calls, server.value, POLLIN, deadline)) break;
        accepted.value = accept4(server.value, nullptr, nullptr, SOCK_CLOEXEC | SOCK_NONBLOCK);
        calls.Posix("accept4", accepted.value);
        if (accepted.value < 0) break;
        struct ucred credentials{}; socklen_t bytes = sizeof(credentials);
        if (calls.Posix("getsockopt-SO_PEERCRED", getsockopt(accepted.value, SOL_SOCKET, SO_PEERCRED, &credentials, &bytes)) < 0) break;
        peer = "{\"bytes\":" + std::to_string(bytes) + ",\"pid\":" + std::to_string(credentials.pid) +
               ",\"uid\":" + std::to_string(credentials.uid) + ",\"gid\":" + std::to_string(credentials.gid) + '}';
        if (bytes != sizeof(credentials) || credentials.pid != getpid() || credentials.uid != geteuid() || credentials.gid != getegid()) break;
        const unsigned char token = 0x6d;
        const ssize_t sent = send(client.value, &token, 1, MSG_NOSIGNAL);
        calls.Add("send-fixed-byte", sent, sent < 0 ? errno : 0);
        if (sent != 1 || !Wait(calls, accepted.value, POLLIN, deadline)) break;
        unsigned char actual = 0;
        const ssize_t received = recv(accepted.value, &actual, 1, 0);
        calls.Add("recv-fixed-byte", received, received < 0 ? errno : 0);
        result = received == 1 && actual == token;
    } while (false);
    calls.Close(accepted, "close-accepted"); calls.Close(client, "close-client"); calls.Close(server, "close-server");
    return result;
}

/** 一页真实共享映射，两份独立mapping加pread验证同一文件；只证明本进程可见性。 */
inline bool SharedMap(int directory, Calls& calls, bool& created) {
    const long page = sysconf(_SC_PAGESIZE);
    if (page <= 0 || page > 1024 * 1024) { calls.Check("page-size-contract", EINVAL); return false; }
    Fd file(openat(directory, "m", O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600));
    if (file.value >= 0) created = true;
    calls.Posix("mmap-file-open", file.value);
    if (file.value < 0) return false;
    struct Mapping {
        void* value = MAP_FAILED; size_t bytes;
        explicit Mapping(size_t size) : bytes(size) {}
        ~Mapping() { if (value != MAP_FAILED) munmap(value, bytes); }
        void Close(Calls& output, const char* name) {
            if (value == MAP_FAILED) return;
            void* previous = value; value = MAP_FAILED;
            output.Posix(name, munmap(previous, bytes));
        }
    } first{size_t(page)}, second{size_t(page)};
    bool okay = false;
    do {
        if (calls.Posix("ftruncate", ftruncate(file.value, page)) < 0) break;
        first.value = mmap(nullptr, size_t(page), PROT_READ | PROT_WRITE, MAP_SHARED, file.value, 0);
        calls.Add("mmap-write", first.value == MAP_FAILED ? -1 : 0, first.value == MAP_FAILED ? errno : 0);
        if (first.value == MAP_FAILED) break;
        second.value = mmap(nullptr, size_t(page), PROT_READ, MAP_SHARED, file.value, 0);
        calls.Add("mmap-read", second.value == MAP_FAILED ? -1 : 0, second.value == MAP_FAILED ? errno : 0);
        if (second.value == MAP_FAILED) break;
        const unsigned char value[4] = {0x41, 0x4d, 0x43, 0x4c};
        std::memcpy(first.value, value, sizeof(value));
        if (calls.Posix("msync", msync(first.value, size_t(page), MS_SYNC)) < 0) break;
        unsigned char actual[4]{};
        const ssize_t size = pread(file.value, actual, sizeof(actual), 0);
        calls.Add("mmap-pread", size, size < 0 ? errno : 0);
        okay = size == 4 && std::memcmp(second.value, value, 4) == 0 && std::memcmp(actual, value, 4) == 0;
    } while (false);
    second.Close(calls, "munmap-read"); first.Close(calls, "munmap-write");
    calls.Close(file, "close-mmap-file");
    return okay;
}

/** 不列目录、不打开已有nonce内容。只有mkdirat成功的scratch才归本轮所有并允许清理。 */
inline std::string Root(int root, const std::string& path, const std::string& nonce, bool requireOwner,
                        Clock::time_point deadline) {
    Calls calls;
    const std::string leaf = ".nt-" + nonce + '-' + std::to_string(getpid());
    const std::string scratchPath = path + '/' + leaf;
    struct stat rootStat{}, scratchStat{}, before{}, after{};
    bool made = false, sourceCreated = false, renamed = false, mapCreated = false, socketCreated = false;
    bool ordinary = false, renameIdentity = false, unixObserved = false, mappingObserved = false, removed = false, absent = false;
    bool unixAttempted = false, mappingAttempted = false;
    std::string peer = "null", socketMetadata = "null", rootMetadata = "null", scratchMetadata = "null", fileBefore = "null", fileAfter = "null";
    Fd scratch, file;
    // 正文/日志分配若抛异常也只清理本轮已成功创建的已知对象，不遍历或删除其它内容。
    struct Cleanup {
        int parent; const char* name; Fd& directory;
        bool& made; bool& source; bool& renamed; bool& mapped; bool& socket;
        bool active = true;
        ~Cleanup() {
            if (!active) return;
            if (directory.value >= 0) {
                if (socket) unlinkat(directory.value, "s", 0);
                if (mapped) unlinkat(directory.value, "m", 0);
                if (renamed) unlinkat(directory.value, "b", 0);
                if (source) unlinkat(directory.value, "a", 0);
            }
            if (made) unlinkat(parent, name, AT_REMOVEDIR);
        }
    } cleanup{root, leaf.c_str(), scratch, made, sourceCreated, renamed, mapCreated, socketCreated};
    do {
        if (root < 0) { calls.Check("root-unavailable", EBADF, path); break; }
        if (calls.Posix("root-fstat", fstat(root, &rootStat), path) < 0) break;
        rootMetadata = Metadata(rootStat);
        if (!S_ISDIR(rootStat.st_mode) || (requireOwner && rootStat.st_uid != geteuid())) {
            calls.Check("root-ownership-contract", EPERM, path); break;
        }
        if (Clock::now() >= deadline) { calls.Check("group-deadline", ETIMEDOUT); break; }
        const int created = mkdirat(root, leaf.c_str(), 0700);
        if (created == 0) made = true;
        if (calls.Posix("mkdirat-exclusive", created, scratchPath) < 0) break;
        scratch.value = openat(root, leaf.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        calls.Posix("scratch-open", scratch.value, scratchPath);
        if (scratch.value < 0) break;
        if (calls.Posix("scratch-fstat", fstat(scratch.value, &scratchStat), scratchPath) < 0) break;
        scratchMetadata = Metadata(scratchStat);
        if (!S_ISDIR(scratchStat.st_mode) || scratchStat.st_uid != geteuid() ||
            (scratchStat.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
            calls.Check("scratch-security-contract", EPERM, scratchPath); break;
        }
        file.value = openat(scratch.value, "a", O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (file.value >= 0) sourceCreated = true;
        calls.Posix("file-open-exclusive", file.value);
        if (file.value < 0) break;
        const char token[] = "AMCL-NATIVE-TEMP-1\n";
        const ssize_t wrote = write(file.value, token, sizeof(token) - 1);
        calls.Add("file-write", wrote, wrote < 0 ? errno : 0);
        if (wrote != ssize_t(sizeof(token) - 1) || calls.Posix("file-fsync", fsync(file.value)) < 0 ||
            calls.Posix("file-fstat-before", fstat(file.value, &before)) < 0) break;
        fileBefore = Metadata(before);
        char actual[sizeof(token)]{};
        const ssize_t read = pread(file.value, actual, sizeof(token) - 1, 0);
        calls.Add("file-pread", read, read < 0 ? errno : 0);
        ordinary = read == wrote && std::memcmp(actual, token, sizeof(token) - 1) == 0;
        calls.Close(file, "file-close");
        const int moved = renameat(scratch.value, "a", scratch.value, "b");
        if (moved == 0) { sourceCreated = false; renamed = true; }
        if (calls.Posix("renameat", moved) < 0) break;
        if (calls.Posix("file-fstat-after", fstatat(scratch.value, "b", &after, AT_SYMLINK_NOFOLLOW)) < 0) break;
        fileAfter = Metadata(after);
        renameIdentity = before.st_dev == after.st_dev && before.st_ino == after.st_ino &&
                         before.st_size == after.st_size && S_ISREG(after.st_mode);
        file.value = openat(scratch.value, "b", O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        calls.Posix("file-reopen-after-rename", file.value);
        if (file.value < 0) { ordinary = false; break; }
        std::memset(actual, 0, sizeof(actual));
        const ssize_t reopened = pread(file.value, actual, sizeof(token) - 1, 0);
        calls.Add("file-read-after-reopen", reopened, reopened < 0 ? errno : 0);
        ordinary = ordinary && reopened == wrote && std::memcmp(actual, token, sizeof(token) - 1) == 0;
        calls.Close(file, "file-close-after-reopen");
        calls.Posix("directory-fsync-after-rename", fsync(scratch.value));
        unixAttempted = true;
        unixObserved = UnixSocket(scratch.value, scratchPath + "/s", calls, deadline, peer, socketMetadata, socketCreated);
        if (Clock::now() >= deadline) { calls.Check("group-deadline", ETIMEDOUT); break; }
        mappingAttempted = true;
        mappingObserved = SharedMap(scratch.value, calls, mapCreated);
    } while (false);
    calls.Close(file, "file-close-cleanup");
    auto removeKnown = [&](bool& owned, const char* name, const char* operation) {
        if (!owned) return;
        owned = false; // 路径只尝试一次；记录失败也不能再删除可能已经被复用的同名对象。
        calls.Posix(operation, unlinkat(scratch.value, name, 0));
    };
    if (scratch.value >= 0) {
        removeKnown(socketCreated, "s", "unlink-socket"); removeKnown(mapCreated, "m", "unlink-mmap-file");
        removeKnown(renamed, "b", "unlink-renamed-file"); removeKnown(sourceCreated, "a", "unlink-source-file");
    }
    calls.Close(scratch, "close-scratch");
    const bool createdAtAll = made;
    if (made) {
        made = false;
        removed = calls.Posix("rmdir-owned-scratch", unlinkat(root, leaf.c_str(), AT_REMOVEDIR), scratchPath) == 0;
        if (removed) {
            struct stat check{};
            const int checked = fstatat(root, leaf.c_str(), &check, AT_SYMLINK_NOFOLLOW);
            const int checkedError = checked < 0 ? errno : 0;
            calls.Add("cleanup-fstatat", checked, checkedError, scratchPath);
            absent = checked < 0 && checkedError == ENOENT;
            calls.Posix("root-fsync-after-cleanup", fsync(root), path);
        }
    }
    cleanup.active = false; // 已按逐项结果完成清理尝试；失败原件保留，不在析构中悄悄重试同名对象。
    return "{\"path\":" + Quote(path) + ",\"pathBytes\":" + std::to_string(path.size()) +
        ",\"rootMetadata\":" + rootMetadata + ",\"scratch\":" + Quote(scratchPath) + ",\"scratchMetadata\":" + scratchMetadata +
        ",\"socketPathBytes\":" + std::to_string(scratchPath.size() + 2) + ",\"socketCapacity\":" +
        std::to_string(sizeof(sockaddr_un::sun_path)) + ",\"created\":" + (createdAtAll ? "true" : "false") +
        ",\"ordinaryFileObserved\":" + (ordinary ? "true" : "false") + ",\"renameIdentityObserved\":" + (renameIdentity ? "true" : "false") +
        ",\"fileBefore\":" + fileBefore + ",\"fileAfter\":" + fileAfter +
        ",\"unixAttempted\":" + (unixAttempted ? "true" : "false") +
        ",\"sameProcessUnixObserved\":" + (unixObserved ? "true" : "false") + ",\"peer\":" + peer + ",\"socketMetadata\":" + socketMetadata +
        ",\"mappingAttempted\":" + (mappingAttempted ? "true" : "false") + ",\"sameProcessSharedMapObserved\":" + (mappingObserved ? "true" : "false") +
        ",\"cleanupComplete\":" + (removed && absent ? "true" : "false") +
        ",\"cleanupAbsenceObserved\":" + (absent ? "true" : "false") + ",\"calls\":" + calls.Json() + '}';
}

/** caller提供的sandbox fd已与真实Context-derived路径核对。/tmp仅打开根元数据及自建唯一scratch。 */
inline std::string Run(int sandbox, const std::string& path, const std::string& nonce) {
    if (!ValidNonce(nonce) || !ValidPath(path)) throw std::runtime_error("native temp probe input contract failed");
    const auto start = Clock::now(); const auto deadline = start + std::chrono::seconds(5);
    const std::string realUser = UserMapping(getuid());
    const std::string effectiveUser = geteuid() == getuid() ? realUser : UserMapping(geteuid());
    const std::string app = Root(sandbox, path, nonce, true, deadline);
    errno = 0;
    Fd tmp(open("/tmp", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    const int tmpOpenResult = tmp.value;
    const int tmpError = tmp.value < 0 ? errno : 0;
    std::string control = "null";
    if (tmp.value >= 0) control = Root(tmp.value, "/tmp", nonce, false, deadline);
    Calls finish;
    finish.Close(tmp, "close-tmp-root");
    return "{\"protocol\":\"AMCL_NATIVE_TEMP_PREFLIGHT_V1\",\"status\":\"OBSERVED\",\"pid\":" + std::to_string(getpid()) +
        ",\"ppid\":" + std::to_string(getppid()) + ",\"uid\":" + std::to_string(getuid()) + ",\"euid\":" + std::to_string(geteuid()) +
        ",\"gid\":" + std::to_string(getgid()) + ",\"egid\":" + std::to_string(getegid()) + ",\"nonce\":" + Quote(nonce) +
        ",\"passwdReal\":" + realUser + ",\"passwdEffective\":" + effectiveUser +
        ",\"sandbox\":" + app + ",\"tmpOpenResult\":" + std::to_string(tmpOpenResult) +
        ",\"tmpOpenErrno\":" + std::to_string(tmpError) + ",\"tmpControl\":" + control +
        ",\"finishCalls\":" + finish.Json() + ",\"operationBudgetMillis\":5000,\"requiredParentDeadlineMillis\":10000,\"elapsedMillis\":" +
        std::to_string(std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - start).count()) +
        ",\"deadlineExceeded\":" + (Clock::now() >= deadline ? "true" : "false") +
        ",\"jvmStarted\":false,\"crossVmAttachQualified\":false,\"crossProcessMmapQualified\":false,\"defaultCliQualified\":false}\n";
}
} // namespace amcl::nativetempprobe
