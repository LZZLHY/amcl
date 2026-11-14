#ifndef AMCL_JVM_GAME_DIRECTORY_H
#define AMCL_JVM_GAME_DIRECTORY_H

#include <cerrno>
#include <fcntl.h>
#include <unistd.h>

namespace amcl::jvm {
/**
 * MC 启动选择目录的短命描述符。准备阶段只打开目录，不改变进程 cwd；目录无法打开时
 * 可在 RuntimeOnce 认领前准确拒绝。只有认领者在所有可失败的 JVM 前置工作完成后、
 * 紧挨 JNI_CreateJavaVM 之前调用 enter()，因此失败前不会遗留临时 cwd。
 *
 * nullptr 表示非 MC 调用，保持调用方/processor 自己的 cwd。绝不读取 Java 属性或环境
 * 来扩大适用范围。成功 enter 后立即进入真实 VM 创建，cwd 从此属于该次运行时，
 * 即使 CreateJavaVM 返回失败，也不能假定没有残留线程而擅自切回。
 */
class GameWorkingDirectory final {
    int directoryFd_ = -1;
public:
    GameWorkingDirectory() = default;
    GameWorkingDirectory(const GameWorkingDirectory&) = delete;
    GameWorkingDirectory& operator=(const GameWorkingDirectory&) = delete;
    ~GameWorkingDirectory() {
        // 关闭本层借用不改变 cwd；内核的进程 cwd 本身持有目录引用。
        const int saved = errno;
        if (directoryFd_ >= 0) close(directoryFd_);
        errno = saved;
    }
    /** 返回真实 errno；空指针是不启用，空字符串/相对路径不是合法的 MC 目录。 */
    int prepare(const char* path) noexcept {
        if (!path) return 0;
        if (path[0] != '/') return EINVAL;
        do { directoryFd_ = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC); }
        while (directoryFd_ < 0 && errno == EINTR);
        return directoryFd_ < 0 ? errno : 0;
    }
    /**
     * 失败的 fchdir 不改变原 cwd，无需进行一次有竞态的“先切换再恢复”。fd 固定实际
     * 选中的目录，避免检查路径后、创建 VM 前该路径被更名而进入另一目录。调用者必须
     * 持有现有 RuntimeOnce 创建认领，且成功后立即调用 CreateJavaVM，不能再加前置失败分支。
     */
    int enter() const noexcept {
        if (directoryFd_ < 0) return 0;
        int result;
        do { result = fchdir(directoryFd_); } while (result != 0 && errno == EINTR);
        return result == 0 ? 0 : errno;
    }
};
}
#endif
