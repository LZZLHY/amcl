/**
 * file_checker.cpp — sha1 / size 校验
 *
 * SHA-1：自实现（见 sha1.{h,cpp}）。不用 libcurl 内联的 OpenSSL EVP：虽然
 *        符号在，但头文件不在，且我们不想被 OpenSSL 的 ABI 绑死。自实现
 *        成本 ~80 行，性能够用（MC 下载校验非热路径）。
 */
#include "file_checker.h"

#include <hilog/log.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <vector>

#include "sha1.h"

#include "../utils/amcl_log.h"

#undef LOG_TAG
#define LOG_TAG "DL_CHECK"

namespace download {

namespace {

bool openRegularNoFollow(const std::string& path, int& fd, struct stat& st,
                         std::string& error) {
    fd = -1;
    struct stat before{};
    if (::lstat(path.c_str(), &before) != 0) {
        const int saved = errno;
        error = "lstat failed: " + path + " errno=" + std::to_string(saved);
        return false;
    }
    if (!S_ISREG(before.st_mode)) {
        error = "refusing symlink or non-regular file: " + path;
        return false;
    }

    int flags = O_RDONLY | O_CLOEXEC | O_NONBLOCK;
#ifdef O_NOFOLLOW
    flags |= O_NOFOLLOW;
#endif
    fd = ::open(path.c_str(), flags);
    if (fd < 0) {
        const int saved = errno;
        error = "safe open failed: " + path + " errno=" + std::to_string(saved);
        return false;
    }

    if (::fstat(fd, &st) != 0) {
        const int saved = errno;
        ::close(fd);
        fd = -1;
        error = "fstat failed: " + path + " errno=" + std::to_string(saved);
        return false;
    }
    if (!S_ISREG(st.st_mode) || st.st_dev != before.st_dev || st.st_ino != before.st_ino) {
        ::close(fd);
        fd = -1;
        error = "file changed during safe open or is not regular: " + path;
        return false;
    }
    return true;
}

bool hashFd(int fd, std::string& digest, int& read_errno) {
    Sha1 hasher;
    std::vector<char> buf(64 * 1024);
    while (true) {
        ssize_t n = ::read(fd, buf.data(), buf.size());
        if (n > 0) {
            hasher.update(buf.data(), static_cast<size_t>(n));
            continue;
        }
        if (n == 0) {
            digest = hasher.finalizeHex();
            return true;
        }
        if (errno == EINTR) continue;
        read_errno = errno;
        return false;
    }
}

bool closeChecked(int fd, int& close_errno) {
    if (::close(fd) == 0) return true;
    close_errno = errno;
    return false;
}

std::string lowerAscii(std::string value) {
    for (char& c : value) {
        if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    }
    return value;
}

} // namespace

std::string computeFileSha1(const std::string& path) {
    struct stat st{};
    int fd = -1;
    std::string error;
    if (!openRegularNoFollow(path, fd, st, error)) {
        AMCL_LOG_W(LOG_TAG, "computeFileSha1: %{public}s", error.c_str());
        return {};
    }

    std::string digest;
    int io_errno = 0;
    const bool read_ok = hashFd(fd, digest, io_errno);
    int close_errno = 0;
    const bool close_ok = closeChecked(fd, close_errno);
    if (!read_ok) {
        AMCL_LOG_W(LOG_TAG, "computeFileSha1: read error on %{public}s errno=%{public}d",
                    path.c_str(), io_errno);
        return {};
    }
    if (!close_ok) {
        AMCL_LOG_W(LOG_TAG, "computeFileSha1: close error on %{public}s errno=%{public}d",
                    path.c_str(), close_errno);
        return {};
    }
    return digest;
}

DownloadExceptionPtr FileChecker::check(const std::string& local_path) const {
    if (!needsAnyCheck()) return nullptr;

    struct stat st{};
    int fd = -1;
    std::string open_error;
    if (!openRegularNoFollow(local_path, fd, st, open_error)) {
        return makeException(ErrorKind::FileIoError, open_error);
    }

    const int64_t actual_size = static_cast<int64_t>(st.st_size);
    if (expected_size >= 0 && actual_size != expected_size) {
        int close_errno = 0;
        if (!closeChecked(fd, close_errno)) {
            return makeException(ErrorKind::FileIoError,
                                 "close failed: " + local_path +
                                 " errno=" + std::to_string(close_errno));
        }
        return makeException(ErrorKind::SizeMismatch,
                             "expected " + std::to_string(expected_size) +
                             " got " + std::to_string(actual_size));
    }

    if (expected_sha1.empty()) {
        int close_errno = 0;
        if (!closeChecked(fd, close_errno)) {
            return makeException(ErrorKind::FileIoError,
                                 "close failed: " + local_path +
                                 " errno=" + std::to_string(close_errno));
        }
        return nullptr;
    }

    std::string actual;
    int read_errno = 0;
    const bool read_ok = hashFd(fd, actual, read_errno);
    int close_errno = 0;
    const bool close_ok = closeChecked(fd, close_errno);
    if (!read_ok) {
        return makeException(ErrorKind::FileIoError,
                             "sha1 read failed: " + local_path +
                             " errno=" + std::to_string(read_errno));
    }
    if (!close_ok) {
        return makeException(ErrorKind::FileIoError,
                             "close failed after sha1 read: " + local_path +
                             " errno=" + std::to_string(close_errno));
    }

    const std::string exp_lower = lowerAscii(expected_sha1);
    if (actual != exp_lower) {
        return makeException(ErrorKind::ChecksumMismatch,
                             "expected " + exp_lower + " got " + actual);
    }
    return nullptr;
}

DownloadExceptionPtr FileChecker::checkFast(const std::string& local_path,
                                            const std::string& precomputed_sha1) const {
    if (!needsAnyCheck()) return nullptr;

    // 即使不重读内容，也通过 lstat + O_NOFOLLOW/open + fstat 固定并验证对象，
    // 避免 symlink/FIFO/device 和 lstat→stat 的替换竞态。
    struct stat st{};
    int fd = -1;
    std::string open_error;
    if (!openRegularNoFollow(local_path, fd, st, open_error)) {
        return makeException(ErrorKind::FileIoError, open_error);
    }
    int close_errno = 0;
    if (!closeChecked(fd, close_errno)) {
        return makeException(ErrorKind::FileIoError,
                             "close failed: " + local_path +
                             " errno=" + std::to_string(close_errno));
    }

    if (expected_size >= 0) {
        const int64_t actual = static_cast<int64_t>(st.st_size);
        if (actual != expected_size) {
            return makeException(ErrorKind::SizeMismatch,
                                 "expected " + std::to_string(expected_size) +
                                 " got " + std::to_string(actual));
        }
    }

    if (!expected_sha1.empty()) {
        if (precomputed_sha1.empty()) {
            return makeException(ErrorKind::InternalError,
                "checkFast invariant violated: expected_sha1 set but precomputed_sha1 empty; "
                "caller must use check() (re-read SHA1) instead of checkFast()");
        }
        const std::string exp_lower = lowerAscii(expected_sha1);
        if (lowerAscii(precomputed_sha1) != exp_lower) {
            return makeException(ErrorKind::ChecksumMismatch,
                                 "expected " + exp_lower + " got " + precomputed_sha1);
        }
    }

    return nullptr;
}

} // namespace download
