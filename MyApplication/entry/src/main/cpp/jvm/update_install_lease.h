/**
 * 应用文件执行的共享租约。游戏、下载和 processor 在第一次打开业务文件前取得 SH，
 * 并一直持有到实际执行收敛。更新在同一稳定 inode 取得 EX 后先写持久 fence；旧进程
 * 被替换导致 FD 关闭时，新进程仍须在 SH 下检查 fence，不能仅凭锁空认定安装结束。
 * 本头文件不依赖 ArkTS 单例或其他图形 DSO 的 JSON 库，独立游戏进程同样检查本域文件。
 */
#pragma once
#include <cerrno>
#include <cctype>
#include <fcntl.h>
#include <memory>
#include <mutex>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <string>
namespace amcl {
namespace installlease {
inline std::mutex rootMutex;
inline std::string configuredRoot;

/** 只接受本机绝对目录；根身份在同进程固定，旧 Ability 不能把租约切到另一个目录。 */
inline bool validRoot(const std::string& root) {
    return !root.empty() && root.front() == '/' && root.size() <= 4096 &&
        root.find_first_of("\r\n\t") == std::string::npos && root.find('\0') == std::string::npos;
}

/**
 * legacy journal 的最小有界 JSON 阅读器。验证全部语法，但只消费根对象唯一 phase；
 * 损坏、重复 phase、未知阶段全部阻断。它不解析任何路径，也不把持久文本变成命令。
 */
class LegacyPhaseReader {
    const std::string& text_; size_t at_{0}; std::string phase_; bool seen_{false};
    void space() { while (at_ < text_.size() && std::isspace(static_cast<unsigned char>(text_[at_]))) ++at_; }
    bool take(char c) { space(); if (at_ >= text_.size() || text_[at_] != c) return false; ++at_; return true; }
    bool string(std::string& result) {
        if (!take('"')) return false;
        while (at_ < text_.size()) {
            unsigned char c = text_[at_++];
            if (c == '"') return true;
            if (c < 32) return false;
            if (c != '\\') { result += static_cast<char>(c); continue; }
            if (at_ >= text_.size()) return false;
            c = text_[at_++];
            if (c == 'u') {
                unsigned value = 0;
                for (int i = 0; i < 4; ++i) {
                    if (at_ >= text_.size()) return false;
                    const unsigned char hex = text_[at_++];
                    if (!std::isxdigit(hex)) return false;
                    value = value * 16 + (hex <= '9' ? hex - '0' : std::tolower(hex) - 'a' + 10);
                }
                result += value < 128 ? static_cast<char>(value) : '?';
            } else if (c == '"' || c == '\\' || c == '/') result += static_cast<char>(c);
            else if (c == 'b' || c == 'f' || c == 'n' || c == 'r' || c == 't') result += '?';
            else return false;
        }
        return false;
    }
    bool value(unsigned depth) {
        if (depth > 32) return false;
        space(); if (at_ >= text_.size()) return false;
        if (text_[at_] == '{') return object(depth);
        if (text_[at_] == '[') {
            ++at_; if (take(']')) return true;
            do { if (!value(depth + 1)) return false; } while (take(','));
            return take(']');
        }
        if (text_[at_] == '"') { std::string ignored; return string(ignored); }
        for (const char* literal : {"true", "false", "null"}) {
            const std::string expected(literal);
            if (text_.compare(at_, expected.size(), expected) == 0) { at_ += expected.size(); return true; }
        }
        const size_t before = at_;
        if (text_[at_] == '-') ++at_;
        if (at_ >= text_.size() || !std::isdigit(static_cast<unsigned char>(text_[at_]))) return false;
        if (text_[at_] == '0') ++at_;
        else while (at_ < text_.size() && std::isdigit(static_cast<unsigned char>(text_[at_]))) ++at_;
        if (at_ < text_.size() && text_[at_] == '.') {
            ++at_; const size_t start = at_;
            while (at_ < text_.size() && std::isdigit(static_cast<unsigned char>(text_[at_]))) ++at_;
            if (start == at_) return false;
        }
        if (at_ < text_.size() && (text_[at_] == 'e' || text_[at_] == 'E')) {
            ++at_; if (at_ < text_.size() && (text_[at_] == '+' || text_[at_] == '-')) ++at_;
            const size_t start = at_;
            while (at_ < text_.size() && std::isdigit(static_cast<unsigned char>(text_[at_]))) ++at_;
            if (start == at_) return false;
        }
        return at_ > before;
    }
    bool object(unsigned depth) {
        if (!take('{')) return false;
        if (take('}')) return true;
        do {
            std::string key; if (!string(key) || !take(':')) return false;
            if (depth == 0 && key == "phase") {
                if (seen_ || !string(phase_)) return false;
                seen_ = true;
            } else if (!value(depth + 1)) return false;
        } while (take(','));
        return take('}');
    }
public:
    explicit LegacyPhaseReader(const std::string& text) : text_(text) {}
    bool permits() {
        if (!object(0)) return false;
        space(); if (at_ != text_.size() || !seen_) return false;
        for (const char* phase : {"idle", "resolving", "queued", "preparing-material", "transferring",
                "downloading", "verifying", "downloaded", "signing", "ready",
                "awaiting-restart", "verified", "failed", "cancelled"}) if (phase_ == phase) return true;
        return false;
    }
};

/** 有 fence 即拒绝；仅 ENOENT 是无文件，权限/符号链接/IO 错误都不能变为放行。 */
inline bool permitsFiles(const std::string& root) {
    const std::string fence = root + "/sideload-update/install-fence.json";
    const int fenceFd = open(fence.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fenceFd >= 0) { close(fenceFd); return false; }
    if (errno != ENOENT) return false;
    const int fd = open((root + "/sideload-update/transaction.json").c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return errno == ENOENT;
    struct stat st{};
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size <= 0 || st.st_size > 512 * 1024) { close(fd); return false; }
    std::string body(static_cast<size_t>(st.st_size), '\0'); size_t done = 0;
    while (done < body.size()) {
        const ssize_t size = read(fd, body.data() + done, body.size() - done);
        if (size < 0 && errno == EINTR) continue;
        if (size <= 0) { close(fd); return false; }
        done += static_cast<size_t>(size);
    }
    close(fd); return LegacyPhaseReader(body).permits();
}
}

inline bool ConfigureUpdateInstallFilesRoot(const std::string& root) {
    if (!installlease::validRoot(root)) return false;
    std::lock_guard<std::mutex> lock(installlease::rootMutex);
    if (!installlease::configuredRoot.empty()) return installlease::configuredRoot == root;
    installlease::configuredRoot = root; return true;
}

class UpdateInstallReadLease {
    int fd_{-1};
public:
    explicit UpdateInstallReadLease(const char* files) {
        if (!files || !installlease::validRoot(files) || !ConfigureUpdateInstallFilesRoot(files)) return;
        fd_ = open((std::string(files) + "/.sideload-install.lock").c_str(), O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
        struct stat st{};
        if (fd_ >= 0 && (fstat(fd_, &st) || !S_ISREG(st.st_mode) || flock(fd_, LOCK_SH | LOCK_NB))) {
            close(fd_); fd_ = -1;
        }
        // SH 与 fence 检查不可分开：安装者必须先取得 EX，不能穿过本次已准入的执行。
        if (fd_ >= 0 && !installlease::permitsFiles(files)) { close(fd_); fd_ = -1; }
    }
    ~UpdateInstallReadLease() { if (fd_ >= 0) close(fd_); }
    UpdateInstallReadLease(const UpdateInstallReadLease&) = delete;
    UpdateInstallReadLease& operator=(const UpdateInstallReadLease&) = delete;
    bool acquired() const { return fd_ >= 0; }
};

/** 下载引擎没有 UI context；使用 Entry 最早固定的 app root，未知根不得启动业务写入。 */
inline std::shared_ptr<UpdateInstallReadLease> AcquireConfiguredUpdateReadLease() {
    std::string root;
    { std::lock_guard<std::mutex> lock(installlease::rootMutex); root = installlease::configuredRoot; }
    auto lease = std::make_shared<UpdateInstallReadLease>(root.c_str());
    return lease->acquired() ? lease : nullptr;
}
}
