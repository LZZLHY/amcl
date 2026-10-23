/** 可信目录fd上的只读快照与独占ZIP写入边界；不删除目标、不跟随链接或特殊文件。 */
#include "export_trusted_io.h"
#include <algorithm>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <unistd.h>

namespace amcl::exporter {
namespace {
[[noreturn]] void Io(const char* text) { throw Failure("FileIo", text, errno); }
/** 元数据非普通/多硬链接时保守拒绝，防独占私有快照被别名写入。 */
void Regular(const Stamp& stat) {
    if (!S_ISREG(stat.value.st_mode) || stat.value.st_nlink != 1 || stat.value.st_size < 0)
        throw Failure("UnsafePath", "export input must be a single-link regular file");
}
std::pair<Fd, std::string> Parent(int root, const std::string& relative) {
    const auto path = SafeRelative(relative); const auto slash = path.rfind('/');
    if (slash == std::string::npos) return {Fd(::fcntl(root, F_DUPFD_CLOEXEC, 0)), path};
    return {OpenDirectoryAt(root, path.substr(0, slash)), path.substr(slash + 1)};
}
}
Fd::~Fd() { if (fd_ >= 0) ::close(fd_); }
Fd::Fd(Fd&& other) noexcept : fd_(other.fd_) { other.fd_ = -1; }
Fd& Fd::operator=(Fd&& other) noexcept {
    if (this != &other) { if (fd_ >= 0) ::close(fd_); fd_ = other.fd_; other.fd_ = -1; } return *this;
}
void Fd::closeChecked() { const int fd = fd_; fd_ = -1; if (fd >= 0 && ::close(fd) != 0) Io("export close failed"); }
Stamp StatFd(int fd) { Stamp stamp; if (::fstat(fd, &stamp.value) != 0) Io("export fstat failed"); return stamp; }
bool SameStamp(const Stamp& a, const Stamp& b) noexcept {
    return a.value.st_dev == b.value.st_dev && a.value.st_ino == b.value.st_ino && a.value.st_size == b.value.st_size &&
        a.value.st_mtim.tv_sec == b.value.st_mtim.tv_sec && a.value.st_mtim.tv_nsec == b.value.st_mtim.tv_nsec &&
        a.value.st_ctim.tv_sec == b.value.st_ctim.tv_sec && a.value.st_ctim.tv_nsec == b.value.st_ctim.tv_nsec;
}
void CheckActive(const Operation& operation) { if (operation.stopping()) throw Failure("Cancelled", "export operation stopped"); }
std::string SafeRelative(const std::string& input, bool directory) {
    std::string path = input;
    if (directory && !path.empty() && path.back() == '/') path.pop_back();
    if (path.empty() || path.front() == '/' || path.size() > 65535) throw Failure("UnsafePath", "export relative path is invalid");
    size_t start = 0;
    for (size_t end = 0; end <= path.size(); ++end) {
        if (end != path.size() && path[end] != '/') {
            const auto c = static_cast<unsigned char>(path[end]);
            if (c < 32 || c == 127 || c == '\\' || c == ':' || c == '*' || c == '?' || c == '"' || c == '<' || c == '>' || c == '|')
                throw Failure("UnsafePath", "export relative path contains forbidden characters");
            continue;
        }
        const auto part = path.substr(start, end - start);
        if (part.empty() || part == "." || part == ".." || part.back() == '.' || part.back() == ' ' || part.size() > 255)
            throw Failure("UnsafePath", "export relative path contains an invalid component");
        start = end + 1;
    }
    return path;
}
Fd OpenDirectoryAt(int root, const std::string& relative) {
    const auto path = SafeRelative(relative); Fd current(::fcntl(root, F_DUPFD_CLOEXEC, 0));
    if (current.get() < 0) Io("export directory dup failed");
    size_t start = 0;
    while (start < path.size()) {
        const auto slash = path.find('/', start); const auto part = path.substr(start, slash - start);
        Fd next(::openat(current.get(), part.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW));
        if (next.get() < 0) Io("export directory openat failed");
        current = std::move(next); if (slash == std::string::npos) break; start = slash + 1;
    }
    return current;
}
Fd OpenRegularAt(int root, const std::string& relative, Stamp& before) {
    auto parent = Parent(root, relative); if (parent.first.get() < 0) Io("export parent dup failed");
    Stamp pathStamp; if (::fstatat(parent.first.get(), parent.second.c_str(), &pathStamp.value, AT_SYMLINK_NOFOLLOW) != 0) Io("export input lookup failed");
    Regular(pathStamp);
    Fd file(::openat(parent.first.get(), parent.second.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK));
    if (file.get() < 0) Io("export input openat failed");
    before = StatFd(file.get()); Regular(before);
    if (!SameStamp(pathStamp, before)) throw Failure("SourceChanged", "export input changed while opening");
    return file;
}
void VerifyRegularAt(int root, const std::string& relative, int fd, const Stamp& before) {
    const auto after = StatFd(fd); Regular(after);
    if (!SameStamp(before, after)) throw Failure("SourceChanged", "export input changed during IO");
    Stamp current; auto check = OpenRegularAt(root, relative, current);
    if (!SameStamp(before, current)) throw Failure("SourceChanged", "export input path changed during IO");
    check.closeChecked();
}
void ReadExact(int fd, uint8_t* buffer, size_t bytes, uint64_t offset, const Operation& op) {
    size_t read = 0;
    while (read < bytes) {
        CheckActive(op); const auto n = ::pread(fd, buffer + read, bytes - read, static_cast<off_t>(offset + read));
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) Io("export read failed");
        if (n == 0) throw Failure("SizeMismatch", "export input was truncated");
        read += static_cast<size_t>(n);
    }
}
void WriteExact(int fd, const uint8_t* buffer, size_t bytes, uint64_t offset, const Operation& op) {
    size_t written = 0;
    while (written < bytes) {
        CheckActive(op); const auto n = ::pwrite(fd, buffer + written, bytes - written, static_cast<off_t>(offset + written));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) Io("export write failed");
        written += static_cast<size_t>(n);
    }
}
void SyncFd(int fd) { int status; do { status = ::fsync(fd); } while (status != 0 && errno == EINTR); if (status != 0) Io("export fsync failed"); }

Roots::Roots(const ArchiveSpec& spec) : spec_(spec) {
    if (!amcl::ConfigureUpdateInstallFilesRoot(spec.filesDir)) throw Failure("UnsafeRoot", "export filesDir differs from configured application root");
    lease_ = amcl::AcquireConfiguredUpdateReadLease();
    if (!lease_) throw Failure("InstallFence", "export application file lease unavailable");
    app = Fd(::open(spec.filesDir.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW));
    if (app.get() < 0) Io("export application root open failed");
    appStamp_ = StatFd(app.get()); job = OpenDirectoryAt(app.get(), spec.jobRelative); jobStamp_ = StatFd(job.get());
    snapshot = OpenDirectoryAt(job.get(), spec.snapshotRelative); snapshotStamp_ = StatFd(snapshot.get()); verify();
}
void Roots::verify() const {
    Fd appNow(::open(spec_.filesDir.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW));
    if (appNow.get() < 0) Io("export application root recheck failed");
    auto jobNow = OpenDirectoryAt(appNow.get(), spec_.jobRelative);
    auto snapshotNow = OpenDirectoryAt(jobNow.get(), spec_.snapshotRelative);
    const auto sameDirectory = [](const Stamp& a, const Stamp& b) { return a.value.st_dev == b.value.st_dev && a.value.st_ino == b.value.st_ino; };
    if (!sameDirectory(appStamp_, StatFd(appNow.get())) || !sameDirectory(jobStamp_, StatFd(jobNow.get())) ||
        !sameDirectory(snapshotStamp_, StatFd(snapshotNow.get()))) throw Failure("SourceChanged", "export private root path changed");
}
} // namespace amcl::exporter
