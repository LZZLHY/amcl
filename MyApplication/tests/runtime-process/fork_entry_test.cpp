/**
 * 真正编译生产 fork_run_java.cpp，替换 JVM/日志外部边界来验证 child 异常不能返回
 * NAPI调用栈、cwd属性与OS一致、8/现代布局、失败与取消回到真实父wait。这里不创建VM，
 * 不声称替身是Java功能验收；四代真实VM行为由runtime-jni及设备矩阵另行验证。
 */
#include "jvm/fork_run_java.h"
#include "jvm/jvm_launcher.h"
#include "utils/amcl_log.h"
#include <cassert>
#include <cstdio>
#include <cstring>
#include <cstdarg>
#include <filesystem>
#include <fstream>
#include <new>
#include <string>
#include <sys/wait.h>
#include <unistd.h>

namespace {
enum Mode { Normal, InitException, MainException, JavaFailure, FinishFailure, Hang,
    BeforeForkLogException, WaitingLogException, ReapedLogException };
Mode mode = Normal;
pid_t ownerPid = 0, recordedChild = 0;
bool reserved = false;
std::string expectedDirectory, expectedNative;
void marker(const char* name) { std::ofstream file(name); file << "observed\n"; assert(file.good()); }
}
extern "C" {
void amclLogPrint(AmclLogLevel, unsigned int, const char*, const char*, ...) {}
void amclLogWrite(AmclLogLevel, const char*, const char* format, ...) {
    assert(getpid() == ownerPid);
    if (std::strstr(format, "child pid=")) {
        va_list arguments; va_start(arguments, format); recordedChild = va_arg(arguments, int); va_end(arguments);
        if (mode == WaitingLogException) throw std::bad_alloc();
    }
    if (mode == BeforeForkLogException && std::strstr(format, "forkRunJava (JNI_CreateJavaVM")) throw std::bad_alloc();
    if (mode == ReapedLogException && std::strstr(format, "child exited with code")) throw std::bad_alloc();
}
int jvmReserveForFork() { assert(!reserved && getpid() == ownerPid); reserved = true; return 0; }
int jvmReleaseForkReservation() { assert(reserved && getpid() == ownerPid); reserved = false; return 0; }
int jvmResetForForkChild() { assert(reserved && getpid() != ownerPid); reserved = false; return 0; }
void jvmSetForkChildMode(int enabled) { assert(enabled == 1); }
void jvmSetClasspath(const char* value) { assert(value && !std::strcmp(value, "/fixture.jar")); }
void jvmSetXmx(int memory) { assert(memory == 512); }
int jvmInit(const char*, const char*) {
    assert(std::string(getenv("AMCL_GAME_DIR")) == expectedDirectory);
    assert(std::string(getenv("LD_LIBRARY_PATH")).find(expectedNative + "/server:" + expectedNative) == 0);
    char directory[4096]; assert(getcwd(directory, sizeof(directory)) && expectedDirectory == directory);
    if (mode == InitException) throw std::bad_alloc();
    if (mode == Hang || mode == WaitingLogException) for (;;) pause();
    return 0;
}
int jvmCallMain(const char* name, int argc, const char**) {
    assert(std::string(name) == "Fixture" && argc == 0);
    if (mode == MainException) throw std::bad_alloc();
    marker("main-observed"); return mode == JavaFailure ? -1 : 0;
}
int jvmFinishProcessor() { marker("finish-observed"); return mode == FinishFailure ? -1 : 0; }
const char* jvmGetStatus() { return "external VM boundary fixture"; }
}
void jvmSetExtraArgsList(const std::vector<std::string>& values) { assert(!values.empty()); }

int main(int argc, char** argv) {
    assert(argc == 2); const std::string root(argv[1]); ownerPid = getpid();
    std::filesystem::create_directories(root + "/parent");
    std::filesystem::create_directories(root + "/jdk/8/jre/lib/aarch64/server");
    { std::ofstream fake(root + "/jdk/8/jre/lib/aarch64/server/libjvm.so"); fake << "layout marker only"; }
    assert(chdir((root + "/parent").c_str()) == 0);
    for (int test = 0; test < 7; ++test) {
        mode = test == 3 ? InitException : test == 4 ? MainException : test == 5 ? JavaFailure : test == 6 ? FinishFailure : Normal;
        const std::string directory = test == 0 ? root + "/parent" : root + "/中文 空格 " + std::to_string(test);
        std::filesystem::create_directories(directory);
        expectedDirectory = directory;
        const bool classic = (test % 2) == 0;
        expectedNative = root + (classic ? "/jdk/8/jre/lib/aarch64" : "/jdk/21/lib");
        const std::string relative = "../中文 空格 " + std::to_string(test);
        const char* requested = test == 0 ? nullptr : test == 1 ? relative.c_str() : directory.c_str();
        const std::string log = directory + "/processor.log";
        assert(setenv("AMCL_GAME_DIR", "/wrong-parent-directory", 1) == 0);
        const int result = forkRunJavaCwd(root.c_str(), classic ? "8" : "21", "/fixture.jar", "Fixture", 0, nullptr,
            requested, log.c_str(), 512);
        const int expected = mode == InitException || mode == MainException || mode == FinishFailure ? 70 : mode == JavaFailure ? 1 : 0;
        assert(result == expected && std::string(getenv("AMCL_GAME_DIR")) == "/wrong-parent-directory");
        assert(std::filesystem::exists(directory + "/main-observed") == (mode != InitException && mode != MainException));
        assert(std::filesystem::exists(directory + "/finish-observed") == (mode != InitException && mode != MainException));
        if (mode == InitException || mode == MainException) {
            std::ifstream file(log); const std::string body{std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
            assert(body.find("native child initialization/execution exception; exiting 70") != std::string::npos);
        }
    }
    mode = Hang; expectedDirectory = root + "/parent"; expectedNative = root + "/jdk/21/lib";
    amcl::jvm::ProcessorControl control(30);
    assert(amcl::jvm::RunControlledProcessor(root.c_str(), "21", "/fixture.jar", "Fixture", 0, nullptr,
        nullptr, (root + "/timeout.log").c_str(), 512, control) == amcl::jvm::ProcessorTimedOut);
    for (const Mode injected : {BeforeForkLogException, WaitingLogException, ReapedLogException}) {
        mode = injected; recordedChild = 0;
        bool caught = false;
        try {
            forkRunJavaCwd(root.c_str(), "21", "/fixture.jar", "Fixture", 0, nullptr,
                nullptr, (root + "/parent-exception.log").c_str(), 512);
        } catch (const std::bad_alloc&) { caught = true; }
        assert(caught && !reserved);
        if (injected == BeforeForkLogException) assert(recordedChild == 0);
        else {
            assert(recordedChild > 0);
            // 父异常已传播时，目标必须真实回收；不能让NAPI先reject再留下后台processor。
            int status = 0; assert(waitpid(recordedChild, &status, WNOHANG) == -1 && errno == ECHILD);
            assert(kill(recordedChild, 0) == -1 && errno == ESRCH);
        }
    }
    int status = 0; assert(waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD);
    puts("PASS production fork entry: cwd/layout, 4 VM failures, timeout, 3 parent log bad_alloc points; reservation released and real children reaped before exception escapes");
}
