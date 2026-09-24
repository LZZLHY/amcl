/**
 * POSIX 集成回归直接编译产品适配，并只在专用测试子进程调用真正的非返回 hook。
 * 每例父进程保持未授权，fork 后全新子进程才拿锁；验证真实文件、flock 与退出码。
 * 不使用设备、JVM 或游戏数据。Windows 应跳过，不把 fake I/O 当 POSIX 通过。
 */
#include "../../jvm/game_process_exit.cpp"
#include <climits>
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>
#include <sys/wait.h>
#include <thread>

namespace {
void Check(bool ok, const char* why)
{
    if (!ok) { std::cerr << "FAIL POSIX: " << why << '\n'; _exit(90); }
}

int NewLock(const std::string& directory, bool held = true)
{
    const int fd = open((directory + "/.desktop-game.lock").c_str(), O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    Check(fd >= 0 && (!held || flock(fd, LOCK_EX | LOCK_NB) == 0), "create test lock");
    return fd;
}

void Arm(const std::string& directory, int parent, int fd)
{
    Check(amclGameExitAuthorize(directory.c_str(), parent, fd) == 0, "real held lock accepted");
    Check(amclGameExitPrepare(directory.c_str(), 42) == 0 && amclGameExitArmedForCurrentProcess(), "record prearmed");
}

int Wait(pid_t child)
{
    int status = 0;
    pid_t found;
    do { found = waitpid(child, &status, 0); } while (found < 0 && errno == EINTR);
    Check(found == child && WIFEXITED(status), "child exits without signal");
    return WEXITSTATUS(status);
}

std::string Read(const std::string& path)
{
    std::ifstream input(path);
    return std::string(std::istreambuf_iterator<char>(input), {});
}

// 仅删除本测试固定创建的文件和空目录；不使用递归清理或用户提供路径。
void Cleanup(const std::string& directory)
{
    for (const char* name : {"/game-exits/42.json", "/game-exits/42.json.tmp", "/game-exits/42.handoff.log",
                             "/.desktop-game.lock", "/.other-lock"}) {
        unlink((directory + name).c_str());
    }
    rmdir((directory + "/game-exits").c_str());
    rmdir(directory.c_str());
}
} // namespace

int main()
{
    char base[] = "/tmp/amcl-game-exit-posix-XXXXXX";
    Check(mkdtemp(base) != nullptr, "mkdtemp");
    const int launcher = static_cast<int>(getpid());
    for (int scenario = 0; scenario < 5; ++scenario) {
        const std::string directory = std::string(base) + "/case" + std::to_string(scenario);
        Check(mkdir(directory.c_str(), 0700) == 0, "create case directory");
        const pid_t child = fork();
        Check(child >= 0, "fork test process");
        if (child == 0) {
            if (scenario == 0) {
                Check(amclGameExitPrepare(directory.c_str(), 42) == 1, "unowned real process does not arm");
                Check(amclGameExitAuthorize(directory.c_str(), launcher, -1) < 0, "bad real fd rejected");
                const int fd = NewLock(directory, false);
                Check(amclGameExitAuthorize(directory.c_str(), launcher, fd) < 0, "unheld flock rejected");
                Check(fcntl(fd, F_GETFD) >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0, "borrowed fd remains open and usable");
                Arm(directory, launcher, fd);
                Check(amclGameExitPrepare(directory.c_str(), 42) == 0 && amclGameExitPrepare(directory.c_str(), 43) < 0,
                      "same session idempotent, different session rejected");
                // 仅宿主 fixture 模拟前台 UI 的现有轮询；生产模块没有新建任何 worker。
                std::thread([] {
                    for (int attempt = 0; attempt < 5000; ++attempt) {
                        if (amclGameExitPendingForCurrentProcess()) {
                            Check(amclGameExitAuthorizedForCurrentProcess() && amclGameExitAcknowledgeRequested(),
                                  "real UI acknowledgement delivered");
                            return;
                        }
                        std::this_thread::sleep_for(std::chrono::milliseconds(1));
                    }
                    _exit(92);
                }).detach();
                amclGameJvmExitHook(300);
            }
            if (scenario == 1) {
                const int fd = NewLock(directory); Arm(directory, launcher, fd);
                const pid_t nested = fork(); Check(nested >= 0, "fork inherited identity");
                if (nested == 0) {
                    Check(!amclGameExitArmedForCurrentProcess() && !amclGameExitAuthorizedForCurrentProcess() &&
                          !amclGameExitPendingForCurrentProcess() && !amclGameExitAcknowledgeRequested() &&
                          amclGameExitPrepare(directory.c_str(), 42) == 1,
                          "fork inherited fds do not authorize");
                    amclGameJvmExitHook(9);
                }
                Check(Wait(nested) == 9 && access((directory + "/game-exits/42.json").c_str(), F_OK) != 0,
                      "fork hook preserves exit code without parent record");
                Check(amclGameExitArmedForCurrentProcess(), "owner still armed after fork");
                amclGameJvmExitHook(0);
            }
            if (scenario == 2 || scenario == 3) {
                const int fd = NewLock(directory);
                Check(amclGameExitAuthorize(directory.c_str(), launcher, fd) == 0, "collision setup authorized");
                Check(mkdir((directory + "/game-exits").c_str(), 0700) == 0, "collision setup directory");
                const std::string name = directory + (scenario == 2 ? "/game-exits/42.json" : "/game-exits/42.json.tmp");
                const int existing = open(name.c_str(), O_CREAT | O_WRONLY | O_EXCL, 0600);
                Check(existing >= 0 && write(existing, "old", 3) == 3, "create existing evidence"); close(existing);
                Check(amclGameExitPrepare(directory.c_str(), 42) < 0 && !amclGameExitArmedForCurrentProcess(),
                      "existing final/temp prevents arming");
                amclGameJvmExitHook(0);
            }
            if (scenario == 4) {
                const int actual = NewLock(directory); (void)actual;
                const int other = open((directory + "/.other-lock").c_str(), O_CREAT | O_RDWR, 0600);
                Check(other >= 0 && flock(other, LOCK_EX | LOCK_NB) == 0, "lock wrong inode");
                Check(amclGameExitAuthorize(directory.c_str(), launcher, other) < 0, "wrong lock inode rejected");
                amclGameJvmExitHook(0);
            }
            _exit(91);
        }
        Check(Wait(child) == (scenario == 0 ? (300 & 255) : 0), "raw requested exit status retained by kernel");
        const std::string record = Read(directory + "/game-exits/42.json");
        if (scenario < 2) {
            Check(record.find("\"pid\":" + std::to_string(child)) != std::string::npos, "record belongs to actual owner PID");
            Check(record.find("\"parentPid\":" + std::to_string(launcher)) != std::string::npos, "launcher identity retained");
            Check(record.find(scenario == 0 ? "\"exitCode\":300" : "\"exitCode\":0") != std::string::npos, "record stores full code");
            Check(record.find("\"source\":\"jvm-exit\"") != std::string::npos && record.back() == '\n', "complete request record published");
            const std::string handoff = Read(directory + "/game-exits/42.handoff.log");
            Check(handoff.find(scenario == 0 ? "acknowledged" : "timeout") != std::string::npos,
                  "real pipe acknowledgement or monotonic timeout diagnosed honestly");
        } else if (scenario == 2) Check(record == "old", "existing final evidence untouched");
        else if (scenario == 3) Check(record.empty() && Read(directory + "/game-exits/42.json.tmp") == "old", "existing temp untouched");
        else Check(record.empty(), "invalid authority produced no record");
        Cleanup(directory);
    }
    rmdir(base);
    std::cout << "PASS 5 POSIX game exit process cases: fd, flock, fork identity, record, pipe acknowledgement/timeout, raw exit status\n";
}
