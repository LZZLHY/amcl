/**
 * CF自动兼容项的窄范围选择：仅从同一JDK SH租约下的release识别major，不按布局/marker/标签猜测。
 * 这里只决定本方自动项，绝不拒绝旧可用JDK、改写显式compiler规则或追加exclude=false。
 * 缺失/不可读/损坏/歧义/数字槽不符都保持旧broad；8/17/21恢复默认机会不等于该包已获游戏资格。
 */
#pragma once
#include <string>
#ifndef _WIN32
// 真实启动读取只在POSIX/OHOS；纯解析/参数策略也供既有Windows宿主Invocation夹具消费。
#include "../platform/jdk_install_io.h"
#endif

namespace amcl::jvm {
inline constexpr char LegacyCfExclusion[] = "-XX:CompileCommand=exclude,java/util/concurrent/CompletableFuture.*";

struct ReleaseMajorObservation {
    int major = 0; // 0表示unknown，不能据此声明读取失败的包已经认证为某代。
    const char* status = "release-unknown";
};

/** 读取唯一、完整的JAVA_VERSION双引号行；沿用release身份来源，额外识别经典1.8。
 * 版本值必须是有界可打印的版本字符，major没有前导零；重复声明即使相同也不任意择一。
 * JAVA_VERSION_DATE等其他键独立保留，不误判成重复JAVA_VERSION。
 */
inline ReleaseMajorObservation ParseReleaseMajor(const std::string& text, const char* selectedSlot) {
    if (text.empty() || text.size() > 65536 || text.find('\0') != std::string::npos)
        return {0, "release-invalid-content"};
    std::string version;
    unsigned declarations = 0;
    size_t offset = 0;
    while (offset < text.size()) {
        size_t end = text.find('\n', offset);
        if (end == std::string::npos) end = text.size();
        std::string line = text.substr(offset, end - offset);
        if (!line.empty() && line.back() == '\r') line.pop_back();
        const size_t first = line.find_first_not_of(" \t");
        if (first != std::string::npos && first > 0) line.erase(0, first);
        const std::string key = "JAVA_VERSION";
        if (line.compare(0, key.size(), key) == 0 && (line.size() == key.size() ||
            line[key.size()] == '=' || line[key.size()] == ' ' || line[key.size()] == '\t')) {
            if (++declarations != 1) return {0, "release-ambiguous"};
            const std::string prefix = key + "=\"";
            if (line.compare(0, prefix.size(), prefix) != 0 || line.size() <= prefix.size() || line.back() != '"')
                return {0, "release-invalid-version"};
            version = line.substr(prefix.size(), line.size() - prefix.size() - 1);
        }
        offset = end + 1;
    }
    if (declarations != 1 || version.empty()) return {0, "release-version-missing"};
    if (version.size() > 128 || version.find_first_not_of("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-+_") != std::string::npos)
        return {0, "release-invalid-version"};
    size_t begin = 0;
    if (version.compare(0, 4, "1.8.") == 0 || version == "1.8") begin = 2;
    else if (version.compare(0, 2, "1.") == 0) return {0, "release-unrecognized-legacy"};
    size_t stop = begin;
    int major = 0;
    while (stop < version.size() && version[stop] >= '0' && version[stop] <= '9') {
        if (stop - begin >= 3) return {0, "release-invalid-version"};
        major = major * 10 + version[stop++] - '0';
    }
    if (stop == begin || version[begin] == '0' || (stop < version.size() &&
        version[stop] != '.' && version[stop] != '-' && version[stop] != '+' && version[stop] != '_'))
        return {0, "release-invalid-version"};
    if (selectedSlot && selectedSlot[0] && selectedSlot != std::to_string(major))
        return {0, "release-slot-mismatch"};
    return {major, "release-known"};
}

/** 调用者已持有生产DirectoryReadLease的SH；这里复用安装IO的有界普通文件读取。
 * 不执行候选库/Java，不新增写锁或目录。所有文件错误转换为准确unknown状态，保持原启动兼容。
 */
#ifndef _WIN32
inline ReleaseMajorObservation ReadReleaseMajor(const std::string& jdkRoot, const char* selectedSlot) noexcept {
    try {
        auto root = amcl::jdk::io::Directory(jdkRoot);
        struct stat metadata{};
        if (fstatat(root.get(), "release", &metadata, AT_SYMLINK_NOFOLLOW) != 0)
            return {0, errno == ENOENT ? "release-missing" : "release-unreadable"};
        if (!S_ISREG(metadata.st_mode) || metadata.st_nlink != 1 || metadata.st_size <= 0 || metadata.st_size > 65536)
            return {0, "release-invalid-file"};
        return ParseReleaseMajor(amcl::jdk::io::SmallFile(root.get(), "release", 65536), selectedSlot);
    } catch (...) {
        return {0, "release-read-failed"};
    }
}
#endif

/** 25、未来未选定的major及unknown保留既有自动broad；不检查用户规则来猜其意图。 */
inline bool NeedsLegacyCfDefault(const ReleaseMajorObservation& identity) noexcept {
    return identity.major != 8 && identity.major != 17 && identity.major != 21;
}
} // namespace amcl::jvm
