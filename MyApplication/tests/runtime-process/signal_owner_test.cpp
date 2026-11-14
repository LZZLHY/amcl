/** 生产同步 SIG_IGN 归一的范围与回滚；合法自定义 handler 必须保留，测试隔离在子进程。 */
#include "../../entry/src/main/cpp/jvm/jvm_signal_ownership.h"
#include <cassert>
#include <cstdio>
#include <map>
#include <sys/wait.h>
#include <unistd.h>

namespace {
volatile sig_atomic_t received = 0;
void existingHandler(int signal) { if (signal == SIGUSR1) received = 1; }
struct FakeActions {
    std::map<int, struct sigaction> values;
    unsigned calls = 0, failAt = 0;
    FakeActions() {
        for (int signal : {SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGUSR1}) {
            struct sigaction action{}; sigemptyset(&action.sa_mask);
            action.sa_handler = signal == SIGABRT || signal == SIGUSR1 ? existingHandler : SIG_IGN;
            values[signal] = action;
        }
    }
    int action(int signal, const struct sigaction* next, struct sigaction* old) {
        // 本函数精确断言只出现合同中的四个同步 signal，未以“全部操作数”替代范围判断。
        assert(signal == SIGSEGV || signal == SIGBUS || signal == SIGILL || signal == SIGFPE);
        if (++calls == failAt) { errno = EACCES; return -1; }
        if (old) *old = values.at(signal);
        if (next) values.at(signal) = *next;
        return 0;
    }
};
}
int main() {
    for (unsigned fail = 1; fail <= 8; ++fail) {
        FakeActions actions; actions.failAt = fail;
        const auto result = amcl::jvm::NormalizeIgnoredJvmSignals(actions);
        assert(!result.ok() && result.error == EACCES && result.rollbackError == 0);
        for (const auto& entry : actions.values)
            assert(entry.second.sa_handler == (entry.first == SIGABRT || entry.first == SIGUSR1 ? existingHandler : SIG_IGN));
    }
    const pid_t child = fork(); assert(child >= 0);
    if (child == 0) {
        const int preserved[]{SIGUSR1, SIGUSR2, SIGQUIT, SIGTERM, SIGCHLD, SIGABRT, SIGPIPE};
        for (int signal : preserved) {
            struct sigaction action{}; sigemptyset(&action.sa_mask);
            action.sa_handler = signal == SIGPIPE ? SIG_IGN : existingHandler;
            assert(sigaction(signal, &action, nullptr) == 0);
        }
        for (int signal : {SIGSEGV, SIGBUS, SIGILL, SIGFPE}) {
            struct sigaction action{}; sigemptyset(&action.sa_mask);
            action.sa_handler = signal == SIGILL ? existingHandler : SIG_IGN;
            assert(sigaction(signal, &action, nullptr) == 0);
        }
        amcl::jvm::PosixSignalActions actions;
        assert(amcl::jvm::NormalizeIgnoredJvmSignals(actions).ok());
        for (int signal : {SIGSEGV, SIGBUS, SIGILL, SIGFPE}) {
            struct sigaction action{}; assert(sigaction(signal, nullptr, &action) == 0);
            assert(action.sa_handler == (signal == SIGILL ? existingHandler : SIG_DFL));
        }
        for (int signal : preserved) {
            struct sigaction action{}; assert(sigaction(signal, nullptr, &action) == 0);
            assert(action.sa_handler == (signal == SIGPIPE ? SIG_IGN : existingHandler));
        }
        assert(raise(SIGUSR1) == 0 && received == 1);
        int pipefd[2]; assert(pipe(pipefd) == 0); close(pipefd[0]);
        assert(write(pipefd[1], "x", 1) == -1 && errno == EPIPE); close(pipefd[1]);
        _exit(0);
    }
    int status = 0; assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    puts("PASS production signal ownership: 8 query/install failures rolled back; only synchronous IGN normalized; custom SIGILL and 7 unrelated owners plus live SIGPIPE/SIGUSR1 retained");
}
