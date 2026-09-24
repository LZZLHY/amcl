#pragma once
// 仅开发诊断包可消费的启动期一次性故障。沙箱文件明确指定 profile 与短期过期时间，
// 以 unlink 成功作为唯一消费权；发布产品编译常量关闭时不会读取文件。
// 这只模拟准入失败，不更改恢复白名单、不触碰已创建的 JVM/世界/活动 renderer。
#include <cstdio>
#include <string>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
namespace amcl::graphics {
inline bool ConsumeGraphicsAdmissionFault(const std::string& filesDir, const std::string& profile,
                                         long long nowSeconds, bool enabled) {
    if (!enabled) return false;
    const std::string path = filesDir + "/graphics-admission-fail-once";
    const int fd = open(path.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return false;
    struct stat info{}; char bytes[257]{};
    const bool regular = fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_size > 0 && info.st_size < 256;
    const ssize_t length = regular ? read(fd, bytes, sizeof(bytes) - 1) : -1;
    close(fd);
    if (length <= 0 || length != info.st_size) return false;
    char requested[65]{}, nonce[65]{}; long long expiry = 0; int end = 0;
    if (std::sscanf(bytes, "v1\n%64[a-z0-9-]\n%lld\n%64[a-z0-9-]\n%n", requested, &expiry, nonce, &end) != 3 ||
        end != length || profile != requested || std::string(nonce).size() < 16 ||
        expiry < nowSeconds || expiry - nowSeconds > 300) return false;
    return unlink(path.c_str()) == 0;
}
}
