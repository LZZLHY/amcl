/** 导出内部的fd/路径/短IO原语；与下载网络完全分离，所有长IO由异步owner执行。 */
#pragma once
#include "export_pipeline.h"
#include <exception>
#include <memory>
#include <sys/stat.h>
#include "../jvm/update_install_lease.h"

namespace amcl::exporter {
class Failure final : public std::exception {
public:
    const char* code; std::string message; int nativeCode;
    Failure(const char* kind, const std::string& text, int native = 0) : code(kind), message(text), nativeCode(native) {}
    const char* what() const noexcept override { return message.c_str(); }
};
/** move-only fd，close失败必须显式传播；析构只兜底且不抛异常。 */
class Fd {
    int fd_ = -1;
public:
    Fd() = default; explicit Fd(int fd) : fd_(fd) {}
    ~Fd(); Fd(Fd&& other) noexcept; Fd& operator=(Fd&& other) noexcept;
    Fd(const Fd&) = delete; Fd& operator=(const Fd&) = delete;
    int get() const noexcept { return fd_; }
    int release() noexcept { const int fd = fd_; fd_ = -1; return fd; }
    void closeChecked();
};
struct Stamp { struct stat value{}; };
Stamp StatFd(int fd);
bool SameStamp(const Stamp& left, const Stamp& right) noexcept;
void CheckActive(const Operation& operation);
std::string SafeRelative(const std::string& path, bool directory = false);
Fd OpenDirectoryAt(int root, const std::string& relative);
Fd OpenRegularAt(int root, const std::string& relative, Stamp& before);
void VerifyRegularAt(int root, const std::string& relative, int fd, const Stamp& before);
void ReadExact(int fd, uint8_t* buffer, size_t bytes, uint64_t offset, const Operation& operation);
void WriteExact(int fd, const uint8_t* buffer, size_t bytes, uint64_t offset, const Operation& operation);
void SyncFd(int fd);

/**
 * filesDir由Entry固定的安装域约束，job必须是game-export/work/<id>。只在该锚点以下
 * openat逐级NOFOLLOW，不从/误拒绝平台沙箱映射祖先。结束时重走锚点核验路径身份。
 */
class Roots {
    const ArchiveSpec& spec_;
    std::shared_ptr<amcl::UpdateInstallReadLease> lease_;
    Stamp appStamp_, jobStamp_, snapshotStamp_;
public:
    Fd app, job, snapshot;
    explicit Roots(const ArchiveSpec& spec);
    void verify() const;
};
} // namespace amcl::exporter
