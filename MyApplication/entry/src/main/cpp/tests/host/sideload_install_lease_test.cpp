/** 安装共享租约的真实POSIX验证：flock、持久fence、legacy JSON和父释放后子FD存活。
 * 所有生产调用和系统调用都用始终执行的显式检查；编译模式不能删除取得租约等副作用。
 * 这是单线程宿主进程，fork子进程只使用poll/read/close/_exit，不初始化业务运行时。
 */
#include "../../jvm/update_install_lease.h"
#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <poll.h>
#include <signal.h>
#include <stdexcept>
#include <sys/wait.h>

namespace {
/** 失败立即终止当前用例并保留明确阶段；不允许用后续PASS掩盖前面的系统调用失败。 */
void Require(bool condition, const std::string& stage) {
    if (!condition) throw std::runtime_error(stage);
}

/** errno在失败后立即保存，避免后续日志/清理覆盖真实错误；成功调用不解释遗留errno。 */
void RequireSystem(bool condition, const char* stage) {
    if (condition) return;
    const int error = errno;
    throw std::runtime_error(std::string(stage) + ": " + std::strerror(error));
}

/** 每个FD只有一个父进程owner。正常关闭检查返回值，异常收尾也不会遗留自己的FD。 */
struct Descriptor {
    int value = -1;
    explicit Descriptor(int fd) : value(fd) {}
    Descriptor(const Descriptor&) = delete;
    Descriptor& operator=(const Descriptor&) = delete;
    ~Descriptor() { if (value >= 0) close(value); }
    void Close(const char* stage) {
        const int owned = value;
        value = -1; // close被中断后不盲目重试，避免关闭被系统重新分配的同号FD。
        RequireSystem(close(owned) == 0, stage);
    }
};

/** JSON夹具必须完成真实写入和关闭；打不开或短写不能伪装成生产parser拒绝坏JSON。 */
void Text(const std::string& path, const std::string& body) {
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    Require(output.is_open(), "打开JSON夹具: " + path);
    output.write(body.data(), static_cast<std::streamsize>(body.size()));
    output.flush();
    Require(output.good(), "完整写入JSON夹具: " + path);
    output.close();
    Require(!output.fail(), "关闭JSON夹具: " + path);
}

/** 非阻塞锁仅对中断有限重试；预期SH阻止EX时必须是锁冲突，不能借坏FD等错误过关。 */
int Lock(int fd, int operation) {
    for (int attempt = 0; attempt < 16; ++attempt) {
        const int result = flock(fd, operation);
        if (result == 0 || errno != EINTR) return result;
    }
    return -1;
}
void RequireBusy(int fd, const char* stage) {
    const int result = Lock(fd, LOCK_EX | LOCK_NB);
    const int error = errno;
    Require(result == -1 && (error == EWOULDBLOCK || error == EAGAIN), stage);
}

/** 只持有fork返回的真实子PID。正常等待有5秒期限，失败收尾终止并有限回收该子进程。 */
struct ChildOwner {
    pid_t pid;
    explicit ChildOwner(pid_t child) : pid(child) {}
    ~ChildOwner() {
        if (pid <= 0) return;
        kill(pid, SIGKILL);
        for (int attempt = 0; attempt < 200; ++attempt) {
            const pid_t result = waitpid(pid, nullptr, WNOHANG);
            if (result == pid || (result < 0 && errno == ECHILD)) return;
            usleep(10000);
        }
    }
    void Wait() {
        int status = 0;
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
        while (std::chrono::steady_clock::now() < deadline) {
            const pid_t result = waitpid(pid, &status, WNOHANG);
            if (result == pid) {
                pid = -1;
                Require(WIFEXITED(status) && WEXITSTATUS(status) == 0,
                        "子进程必须完整读到释放通知并正常退出，status=" + std::to_string(status));
                return;
            }
            RequireSystem(result == 0 || (result < 0 && errno == EINTR), "等待租约子进程");
            usleep(10000);
        }
        throw std::runtime_error("等待租约子进程超过5秒");
    }
};

/** 父进程write遇到已退出的child时检查EPIPE，不能先被SIGPIPE杀死而丢失失败阶段。 */
struct PipeSignalGuard {
    struct sigaction previous{};
    bool installed = false;
    PipeSignalGuard() {
        struct sigaction ignored{};
        ignored.sa_handler = SIG_IGN;
        RequireSystem(sigemptyset(&ignored.sa_mask) == 0, "配置pipe信号掩码");
        RequireSystem(sigaction(SIGPIPE, &ignored, &previous) == 0, "配置pipe写错误的显式返回");
        installed = true;
    }
    ~PipeSignalGuard() { if (installed) sigaction(SIGPIPE, &previous, nullptr); }
    void Restore() {
        RequireSystem(sigaction(SIGPIPE, &previous, nullptr) == 0, "恢复宿主pipe信号设置");
        installed = false;
    }
};

/** fork子进程不使用iostream/异常。5秒poll及一次有界read确认父通知，EOF/错误均非成功。 */
void RunChild(int readFd, int writeFd) {
    if (close(writeFd) != 0) _exit(10);
    pollfd input{readFd, POLLIN, 0};
    const int ready = poll(&input, 1, 5000);
    if (ready != 1 || !(input.revents & POLLIN) || (input.revents & (POLLERR | POLLNVAL))) _exit(11);
    char byte = 0;
    ssize_t amount = -1;
    for (int attempt = 0; attempt < 16; ++attempt) {
        amount = read(readFd, &byte, 1);
        if (amount >= 0 || errno != EINTR) break;
    }
    if (amount != 1 || byte != 'x') _exit(12);
    if (close(readFd) != 0) _exit(13);
    _exit(0); // 不执行继承的C++析构；进程退出关闭继承的SH租约FD。
}
} // namespace

int main(int argc, char** argv) {
    try {
        Require(argc == 2, "必须提供一个仓库外fixture绝对目录");
        const std::string root = argv[1];
        std::error_code directoryError;
        std::filesystem::create_directories(root + "/sideload-update", directoryError);
        Require(!directoryError, "创建fixture目录: " + directoryError.message());
        Require(amcl::ConfigureUpdateInstallFilesRoot(root), "配置生产安装共享租约根");
        Require(!amcl::ConfigureUpdateInstallFilesRoot(root + "/other"), "生产根固定后拒绝切换");
        auto lease = amcl::AcquireConfiguredUpdateReadLease();
        Require(lease && lease->acquired(), "取得实际SH共享租约");
        Descriptor exclusive(open((root + "/.sideload-install.lock").c_str(), O_RDWR));
        RequireSystem(exclusive.value >= 0, "打开同inode安装锁");
        RequireBusy(exclusive.value, "实际SH共享租约必须阻止EX安装锁");
        lease.reset();
        RequireSystem(Lock(exclusive.value, LOCK_EX | LOCK_NB) == 0, "释放SH后取得EX安装锁");
        Text(root + "/sideload-update/install-fence.json", "{}");
        RequireSystem(Lock(exclusive.value, LOCK_UN) == 0, "释放安装EX锁");
        Require(!amcl::AcquireConfiguredUpdateReadLease(), "持久fence在锁空时仍拒绝SH准入");
        std::error_code removeError;
        const bool removed = std::filesystem::remove(root + "/sideload-update/install-fence.json", removeError);
        Require(removed && !removeError, "移除本次fence夹具: " + removeError.message());
        for (const auto& invalid : {"{", "{\"phase\":\"installing\"}", "{\"phase\":\"confirmation-pending\"}",
                "{\"phase\":\"ready\",\"phase\":\"verified\"}", "{\"phase\":\"ready\"} trailing"}) {
            Text(root + "/sideload-update/transaction.json", invalid);
            Require(!amcl::AcquireConfiguredUpdateReadLease(), "legacy坏文件必须拒绝: " + std::string(invalid));
        }
        Text(root + "/sideload-update/transaction.json", "{\"phase\":\"ready\",\"x\":[1,true,{\"s\":\"\\u0061\"}]} ");
        Require(static_cast<bool>(amcl::AcquireConfiguredUpdateReadLease()), "完整legacy JSON允许合法嵌套与转义");
        for (const auto* phase : {"resolving", "queued", "preparing-material", "transferring"}) {
            Text(root + "/sideload-update/transaction.json", std::string("{\"phase\":\"") + phase + "\"}");
            Require(static_cast<bool>(amcl::AcquireConfiguredUpdateReadLease()), "legacy合法准备阶段准入: " + std::string(phase));
        }
        Text(root + "/sideload-update/transaction.json", "{\"phase\":\"ready\"}");
        lease = amcl::AcquireConfiguredUpdateReadLease();
        Require(static_cast<bool>(lease), "fork前取得生产SH租约");
        int pipeFd[2]{-1, -1};
        RequireSystem(pipe(pipeFd) == 0, "建立真实父子通知pipe");
        Descriptor reader(pipeFd[0]), writer(pipeFd[1]);
        PipeSignalGuard pipeSignals;
        const pid_t child = fork();
        if (child == 0) RunChild(reader.value, writer.value);
        RequireSystem(child > 0, "创建真实租约继承子进程");
        ChildOwner childOwner(child);
        reader.Close("父进程关闭pipe读端");
        lease.reset();
        // 父已释放SH，但child继承同一open-file-description，仍必须阻止EX。
        RequireBusy(exclusive.value, "父释放SH后子进程继承FD必须继续阻止EX");
        ssize_t written = -1;
        for (int attempt = 0; attempt < 16; ++attempt) {
            written = write(writer.value, "x", 1);
            if (written >= 0 || errno != EINTR) break;
        }
        RequireSystem(written == 1, "父进程完整发送子进程退出通知");
        writer.Close("父进程关闭pipe写端");
        childOwner.Wait();
        pipeSignals.Restore();
        RequireSystem(Lock(exclusive.value, LOCK_EX | LOCK_NB) == 0, "子正常退出后安装EX锁才能取得");
        exclusive.Close("关闭本次安装EX锁FD");
        std::cout << "PASS sideload lease: SH/EX, persisted fence, strict legacy JSON, fork-child lifetime\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL sideload lease: " << error.what() << '\n';
        return 1;
    }
}
