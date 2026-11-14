/**
 * TestHooks固定进程路线探针：只执行当前HAP中的既有签名PIE，以及它实际声明的系统解释器。
 * 不修改权限、不复制代码、不运行Java、不接受Want命令；posix_spawn后的父侧保留真实wait。
 * 该观测不能证明手机/API20可用，也不将NCP回调数值解释为POSIX退出状态。
 */
#pragma once
#include "processor_child_owner.h"
#include "../platform/jdk_install_io.h"
#include <chrono>
#include <cstdio>
#include <dlfcn.h>
#include <elf.h>
#include <poll.h>
#include <spawn.h>
#include <sstream>
#include <sys/statvfs.h>
#include <vector>

extern char** environ;

namespace amcl::jvm::execprobe {
namespace io = amcl::jdk::io;
using Clock = std::chrono::steady_clock;

inline std::string quote(const std::string& text) {
    const char digits[] = "0123456789abcdef";
    std::string result = "\"";
    for (unsigned char value : text) {
        if (value == '\\' || value == '"') { result += '\\'; result += static_cast<char>(value); }
        else if (value < 32) { result += "\\u00"; result += digits[value >> 4]; result += digits[value & 15]; }
        else result += static_cast<char>(value);
    }
    return result + '"';
}

/** 实际路径DAC/挂载事实单独记录；stat成功或X_OK成功都不冒充exec许可。 */
inline std::string metadata(const std::string& path) {
    struct stat info{}; struct statvfs mount{};
    const int stated = stat(path.c_str(), &info), statError = stated ? errno : 0;
    const int accessed = access(path.c_str(), X_OK), accessError = accessed ? errno : 0;
    const int mounted = statvfs(path.c_str(), &mount), mountError = mounted ? errno : 0;
    std::ostringstream out;
    out << "{\"path\":" << quote(path) << ",\"statErrno\":" << statError
        << ",\"mode\":" << (info.st_mode & 07777) << ",\"uid\":" << info.st_uid
        << ",\"gid\":" << info.st_gid << ",\"device\":" << static_cast<unsigned long long>(info.st_dev)
        << ",\"inode\":\"" << static_cast<unsigned long long>(info.st_ino) << "\",\"bytes\":" << info.st_size
        << ",\"accessErrno\":" << accessError << ",\"mountErrno\":" << mountError
        << ",\"mountFlags\":" << mount.f_flag << '}';
    return out.str();
}

struct ProbeImage { std::string interpreter, sha256; uint64_t bytes = 0; };

/** 从同一已打开的真实文件读取ELF与摘要；只接受当前SDK固定AArch64 PIE解释器合同。 */
inline ProbeImage inspect(const std::string& path) {
    io::Fd file(open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
    if (file.get() < 0) io::Error("cannot open installed exec fixture");
    struct stat before{}, after{};
    io::Require(!fstat(file.get(), &before) && S_ISREG(before.st_mode) && before.st_size >= static_cast<off_t>(sizeof(Elf64_Ehdr))
        && before.st_size <= 16 * 1024 * 1024, "installed probe is not the expected bounded regular ELF");
    std::string bytes(static_cast<size_t>(before.st_size), '\0');
    size_t done = 0;
    while (done < bytes.size()) {
        const ssize_t got = read(file.get(), bytes.data() + done, bytes.size() - done);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) io::Error("cannot read installed exec fixture");
        done += static_cast<size_t>(got);
    }
    io::Require(!fstat(file.get(), &after) && before.st_dev == after.st_dev && before.st_ino == after.st_ino &&
        before.st_size == after.st_size && before.st_mtime == after.st_mtime, "exec fixture changed while reading");
    Elf64_Ehdr header{}; memcpy(&header, bytes.data(), sizeof(header));
    io::Require(!memcmp(header.e_ident, ELFMAG, SELFMAG) && header.e_ident[EI_CLASS] == ELFCLASS64 &&
        header.e_ident[EI_DATA] == ELFDATA2LSB && header.e_machine == EM_AARCH64 && header.e_type == ET_DYN && header.e_entry,
        "installed probe must be a real AArch64 PIE with entry");
    io::Require(header.e_phentsize == sizeof(Elf64_Phdr) && header.e_phnum > 0 && header.e_phnum <= 128 &&
        header.e_phoff <= bytes.size() && header.e_phnum <= (bytes.size() - header.e_phoff) / sizeof(Elf64_Phdr),
        "invalid probe program header table");
    ProbeImage result; unsigned found = 0;
    for (unsigned index = 0; index < header.e_phnum; ++index) {
        Elf64_Phdr item{}; memcpy(&item, bytes.data() + header.e_phoff + index * sizeof(item), sizeof(item));
        if (item.p_type != PT_INTERP) continue;
        ++found;
        io::Require(item.p_filesz >= 2 && item.p_filesz <= 512 && item.p_offset <= bytes.size() &&
            item.p_filesz <= bytes.size() - item.p_offset, "invalid probe PT_INTERP");
        result.interpreter.assign(bytes.data() + item.p_offset, static_cast<size_t>(item.p_filesz));
        io::Require(result.interpreter.find('\0') == result.interpreter.size() - 1, "unterminated/embedded-null PT_INTERP");
        result.interpreter.pop_back();
    }
    io::Require(found == 1 && result.interpreter == "/lib/ld-musl-aarch64.so.1", "unexpected installed probe interpreter");
    result.sha256 = io::Digest(bytes); result.bytes = bytes.size();
    return result;
}

struct Execution {
    int spawnError = 0, waitError = 0, killError = 0, readError = 0;
    pid_t pid = -1, waited = -1;
    int rawStatus = 0;
    bool timedOut = false, overflow = false;
    std::string output;
};

/**
 * 不运行fork子分支C++：posix_spawn负责创建/exec。输出持续排空以避免pipe背压误判挂起。
 * 超时只在waitpid仍报告本次直接子进程存活时发送KILL；随后仍要求真实wait，ECHILD绝不kill。
 * OOM等父异常由既有child owner停止/回收；OS拒绝终止时不伪称已退出或放弃租约。
 */
inline Execution execute(const std::string& program, const std::vector<std::string>& arguments,
                         unsigned timeoutMs = 5000) {
    Execution result; result.output.reserve(4096);
    std::vector<char*> argv; argv.reserve(arguments.size() + 1);
    for (const auto& value : arguments) argv.push_back(const_cast<char*>(value.c_str()));
    argv.push_back(nullptr);
    int descriptors[2];
    if (pipe2(descriptors, O_CLOEXEC) != 0) { result.spawnError = errno; return result; }
    io::Fd input(descriptors[0]), output(descriptors[1]);
    // 父进程可能关闭了标准流；把控制管道移到3以上，避免file_actions关闭刚dup到stdout的FD。
    if (input.get() < 3) {
        const int moved = fcntl(input.get(), F_DUPFD_CLOEXEC, 3);
        if (moved < 0) { result.spawnError = errno; return result; }
        input = io::Fd(moved);
    }
    if (output.get() < 3) {
        const int moved = fcntl(output.get(), F_DUPFD_CLOEXEC, 3);
        if (moved < 0) { result.spawnError = errno; return result; }
        output = io::Fd(moved);
    }
    const int flags = fcntl(input.get(), F_GETFL);
    if (flags < 0 || fcntl(input.get(), F_SETFL, flags | O_NONBLOCK) < 0) { result.spawnError = errno; return result; }
    posix_spawn_file_actions_t actions;
    result.spawnError = posix_spawn_file_actions_init(&actions);
    if (result.spawnError) return result;
    struct ActionOwner { posix_spawn_file_actions_t* value; ~ActionOwner() { posix_spawn_file_actions_destroy(value); } } owner{&actions};
    int error = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, output.get(), STDOUT_FILENO);
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, output.get(), STDERR_FILENO);
    if (!error) error = posix_spawn_file_actions_addclose(&actions, input.get());
    if (!error) error = posix_spawn_file_actions_addclose(&actions, output.get());
    if (error) { result.spawnError = error; return result; }
    result.spawnError = posix_spawn(&result.pid, program.c_str(), &actions, nullptr, argv.data(), environ);
    PosixChildOwnership childSystem;
    ProcessorChildOwner<> child(result.spawnError ? -1 : result.pid, childSystem);
    output = io::Fd();
    if (result.spawnError) return result;
    const auto deadline = Clock::now() + std::chrono::milliseconds(timeoutMs);
    bool killSent = false;
    auto drain = [&] {
        char buffer[1024];
        // 即使目标持续洪泛stdout，也必须回到wait/deadline检查，不能无限陷入drain。
        size_t drained = 0;
        while (drained < 65536) {
            const ssize_t count = read(input.get(), buffer, sizeof(buffer));
            if (count < 0 && errno == EINTR) continue;
            if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK) result.readError = errno;
            if (count <= 0) return;
            drained += static_cast<size_t>(count);
            const size_t kept = std::min(static_cast<size_t>(count), size_t(4096) - result.output.size());
            result.output.append(buffer, kept);
            if (kept != static_cast<size_t>(count)) result.overflow = true;
        }
    };
    for (;;) {
        drain();
        result.waited = waitpid(result.pid, &result.rawStatus, WNOHANG);
        const int waitError = result.waited < 0 ? errno : 0;
        if (result.waited == result.pid) {
            child.observe({true, result.rawStatus, 0, result.waited}); drain(); return result;
        }
        if (result.waited < 0 && waitError == EINTR) continue;
        if (result.waited < 0) {
            result.waitError = waitError;
            child.observe({false, 0, waitError, result.waited}); return result;
        }
        if (!killSent && Clock::now() >= deadline) {
            result.timedOut = true; killSent = true;
            int sent; do { sent = kill(result.pid, SIGKILL); } while (sent < 0 && errno == EINTR);
            if (sent < 0) result.killError = errno;
        }
        pollfd pending{input.get(), POLLIN, 0};
        if (poll(&pending, 1, 10) > 0 && (pending.revents & POLLHUP)) poll(nullptr, 0, 10);
    }
}

/** marker绑定真实子PID/父PID和argv数量；request或spawn=0本身都不是程序执行成功证据。 */
inline bool marker(const Execution& result, pid_t parent) {
    int pid = -1, ppid = -1, argc = -1, consumed = -1;
    return sscanf(result.output.c_str(), "AMCL_EXEC_PROBE pid=%d ppid=%d argc=%d%n", &pid, &ppid, &argc, &consumed) == 3 &&
        pid == result.pid && ppid == parent && argc == 2 && consumed > 0 &&
        result.output.substr(static_cast<size_t>(consumed)) == "\n";
}

inline std::string describe(const char* route, const std::string& program, const std::vector<std::string>& args,
                            const Execution& result, pid_t parent) {
    const bool reaped = result.pid > 0 && result.waited == result.pid && !result.waitError;
    std::ostringstream out;
    out << "{\"route\":" << quote(route) << ",\"program\":" << quote(program) << ",\"argv\":[";
    for (size_t index = 0; index < args.size(); ++index) { if (index) out << ','; out << quote(args[index]); }
    out << "],\"spawnError\":" << result.spawnError << ",\"pid\":" << result.pid << ",\"waitedPid\":" << result.waited
        << ",\"waitError\":" << result.waitError << ",\"rawWaitStatus\":" << (reaped ? std::to_string(result.rawStatus) : "null")
        << ",\"exitCode\":" << (reaped && WIFEXITED(result.rawStatus) ? std::to_string(WEXITSTATUS(result.rawStatus)) : "null")
        << ",\"signal\":" << (reaped && WIFSIGNALED(result.rawStatus) ? std::to_string(WTERMSIG(result.rawStatus)) : "null")
        << ",\"timedOut\":" << (result.timedOut ? "true" : "false") << ",\"killError\":" << result.killError
        << ",\"stdout\":" << quote(result.output) << ",\"readError\":" << result.readError
        << ",\"overflow\":" << (result.overflow ? "true" : "false") << ",\"markerVerified\":" << (marker(result, parent) ? "true" : "false") << '}';
    return out.str();
}

/** installedEntry必须来自本HAP libentry中的固定导出，不从用户文本推测安装目录。 */
inline std::string run(const void* installedEntry, const char* context) {
    std::ostringstream report;
    report << "{\"schema\":1,\"kind\":\"FixedProcessorExecRoute\",\"context\":" << quote(context)
        << ",\"observerPid\":" << getpid() << ",\"observerPpid\":" << getppid();
    try {
        Dl_info library{};
        io::Require(dladdr(installedEntry, &library) && library.dli_fname && library.dli_fname[0] == '/', "cannot identify installed libentry");
        const std::string owner(library.dli_fname);
        const auto separator = owner.find_last_of('/');
        io::Require(separator != std::string::npos && owner.substr(separator + 1) == "libentry.so", "entry is not installed libentry.so");
        const std::string probe = owner.substr(0, separator + 1) + "libamcl_exec_probe.so";
        const auto image = inspect(probe);
        const std::string probeMetadata = metadata(probe), interpreterMetadata = metadata(image.interpreter);
        const std::vector<std::vector<std::string>> args = {{"/system/bin/true", "--probe"}, {probe, "--probe"},
            {image.interpreter, probe, "--probe"}};
        const char* names[] = {"system-control", "direct-installed-pie", "declared-interpreter-installed-pie"};
        std::ostringstream observations;
        for (size_t index = 0; index < args.size(); ++index) {
            if (index) observations << ',';
            const auto observed = execute(args[index][0], args[index]);
            observations << describe(names[index], args[index][0], args[index], observed, getpid());
        }
        report << ",\"ownerLibrary\":" << quote(owner) << ",\"probeSha256\":" << quote(image.sha256)
            << ",\"probeMetadata\":" << probeMetadata << ",\"ptInterp\":" << quote(image.interpreter)
            << ",\"interpreterMetadata\":" << interpreterMetadata << ",\"observations\":["
            << observations.str() << "],\"error\":null";
    } catch (const std::exception& error) { report << ",\"error\":" << quote(error.what()); }
    report << "}\n";
    return report.str();
}
} // namespace amcl::jvm::execprobe
