#pragma once

#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <unistd.h>

namespace amcl::storage {
// 只在游戏根独占创建普通文件，立即撤掉目录项。之后所有读写都使用同一 fd，
// 即使用户或其他窗口在原目录继续写入，也没有递归清理或按旧名称再次删除的步骤。
inline bool VerifyGameDirectoryWritable(std::string directory)
{
    if (directory.empty() || directory.front() != '/' || directory.find('\0') != std::string::npos) return false;
    directory += "/.amcl-storage-XXXXXX";
    const int fd = mkostemp(directory.data(), O_CLOEXEC);
    if (fd < 0) return false;
    constexpr char marker[] = "AMCL";
    constexpr size_t length = sizeof(marker) - 1;
    char bytes[length]{};
    const bool readable = unlink(directory.c_str()) == 0 &&
        pwrite(fd, marker, length, 0) == static_cast<ssize_t>(length) &&
        pread(fd, bytes, length, 0) == static_cast<ssize_t>(length) &&
        std::memcmp(bytes, marker, length) == 0;
    return close(fd) == 0 && readable;
}
}
