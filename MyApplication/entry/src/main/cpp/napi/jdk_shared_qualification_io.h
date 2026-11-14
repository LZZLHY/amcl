/** TestHooks共享工具的stdio恢复责任；不建立线程/管道，不修改CWD或清空进程环境。
 * 仅用于专属冷启动诊断进程。VM正常或失败返回后恢复原描述符，进程仍须重启。
 */
#pragma once
#ifdef MC_OHOS_BUILD_TESTS
#include "../platform/jdk_install_io.h"
#include <cstdio>

namespace amcl::jdkqualification {
class SharedQualificationStdio final {
    amcl::jdk::io::Fd stdout_, stderr_;
    bool pending_ = false;
public:
    /** 保存两个已有stdio身份后才允许调用方开始重定向；保存失败没有修改stdio。 */
    explicit SharedQualificationStdio(bool enabled) {
        if (!enabled) return;
        stdout_ = amcl::jdk::io::Fd(fcntl(STDOUT_FILENO, F_DUPFD_CLOEXEC, 3));
        if (stdout_.get() < 0) amcl::jdk::io::Error("无法保存共享资格stdout");
        stderr_ = amcl::jdk::io::Fd(fcntl(STDERR_FILENO, F_DUPFD_CLOEXEC, 3));
        if (stderr_.get() < 0) amcl::jdk::io::Error("无法保存共享资格stderr");
        pending_ = true;
    }
    SharedQualificationStdio(const SharedQualificationStdio&) = delete;
    SharedQualificationStdio& operator=(const SharedQualificationStdio&) = delete;
    ~SharedQualificationStdio() { (void)restore(); }
    /** 正常路径显式核对错误；异常析构再次兜底。失败不能宣告共享测试成功。 */
    int restore() noexcept {
        if (!pending_) return 0;
        fflush(stdout); fflush(stderr);
        int error = 0;
        if (dup2(stdout_.get(), STDOUT_FILENO) < 0) error = errno;
        if (dup2(stderr_.get(), STDERR_FILENO) < 0 && error == 0) error = errno;
        if (!error) pending_ = false;
        return error;
    }
};
}
#endif
