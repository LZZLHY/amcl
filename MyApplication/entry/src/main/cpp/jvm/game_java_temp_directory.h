/**
 * 游戏Java临时目录的启动前准备。只在已授权实例根内创建固定AMCL目录，不迁移原数据、
 * 不改用户目录权限、不清理可能仍被shutdown hook或原生库持有的临时文件。
 * 显式用户java.io.tmpdir不走此helper；VM原生TMPDIR与processor路径也不受它影响。
 */
#pragma once
#include <cerrno>
#include <fcntl.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace amcl::jvm {
namespace game_temp_detail {
/** 只拥有本次打开的目录fd，不拥有目录内容；所有返回路径都恰好关闭一次。 */
class DirectoryFd final {
public:
    explicit DirectoryFd(int value) : value_(value) {}
    ~DirectoryFd() { if (value_ >= 0) close(value_); }
    DirectoryFd(const DirectoryFd&) = delete;
    DirectoryFd& operator=(const DirectoryFd&) = delete;
    int get() const { return value_; }
private:
    int value_;
};

/** 允许已存在的普通目录，拒绝符号链接/文件；不靠chmod把未知对象变成可用目录。 */
inline int OpenChild(int parent, const char* name, std::string& error) {
    if (mkdirat(parent, name, 0700) != 0 && errno != EEXIST) {
        error = "game_java_tmp_mkdir:" + std::to_string(errno); return -1;
    }
    const int fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) { error = "game_java_tmp_open:" + std::to_string(errno); return -1; }
    struct stat opened{}, named{};
    if (fstat(fd, &opened) != 0 || fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) != 0 ||
        !S_ISDIR(named.st_mode) || opened.st_dev != named.st_dev || opened.st_ino != named.st_ino) {
        close(fd); error = "game_java_tmp_identity_changed"; return -1;
    }
    return fd;
}
} // namespace game_temp_detail

/**
 * 在JVM/agent启动前创建默认根。仅校验既有实例与AMCL子目录，不能将公共sharefs目录
 * 宣称为私有存储，也不改变真实文件时间/权限API语义。命名位于同一实例树下，真正的
 * rename能力仍由目标环境及整合包复验确认，不用st_dev相等代替跨挂载的运行证据。
 */
inline bool PrepareGameJavaTempDirectory(const std::string& gameDir, std::string& error) {
    if (gameDir.empty() || gameDir.front() != '/' || gameDir.find('\0') != std::string::npos) {
        error = "game_java_tmp_root_invalid"; return false;
    }
    game_temp_detail::DirectoryFd root(open(gameDir.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW));
    if (root.get() < 0) { error = "game_java_tmp_root_open:" + std::to_string(errno); return false; }
    game_temp_detail::DirectoryFd owner(game_temp_detail::OpenChild(root.get(), ".amcl", error));
    if (owner.get() < 0) return false;
    game_temp_detail::DirectoryFd temporary(game_temp_detail::OpenChild(owner.get(), "java-tmp", error));
    if (temporary.get() < 0) return false;
    error.clear(); return true;
}
} // namespace amcl::jvm
