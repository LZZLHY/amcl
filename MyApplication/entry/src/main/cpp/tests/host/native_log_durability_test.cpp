// 宿主故障探针：直接编入生产 writer，模拟独立 host/game 日志根；
// 正常 flush 后读取、flush 后 _Exit、writer 被暂停时请求封账分别独立进程执行。
// 除 Windows 平台符号适配外不替换 writer、文件或线程，避免把 stub 成功当成落盘成功。
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <filesystem>
#include <sys/stat.h>
#include <cstdarg>
#include <cstring>
#include <mutex>
#include <thread>
#include <condition_variable>

// 只在固定记录的格式化入口暂停 producer，此时它已经预留序号但尚未发布。
// 不持有 writer 内部锁调用公共 API，防止夹具与合法的通知同步互相死锁。
static std::mutex closePauseMutex;
static std::condition_variable closePauseCv;
static bool closePaused = false;
static bool closeReleased = false;
static int pauseCloseBoundary(char* output, size_t size, const char* format, va_list args) {
    if (std::strcmp(format, "CLOSE_BOUNDARY_EGL_300D") == 0) {
        std::unique_lock<std::mutex> lock(closePauseMutex);
        closePaused = true;
        closePauseCv.notify_all();
        closePauseCv.wait(lock, [] { return closeReleased; });
    }
    return std::vsnprintf(output, size, format, args);
}
#ifdef _WIN32
#include <direct.h>
#include <ctime>
static tm* portable_localtime_r(const time_t* value, tm* result) { return localtime_s(result, value) == 0 ? result : nullptr; }
#define localtime_r portable_localtime_r
#define mkdir(path, mode) _mkdir(path)
#endif
#define vsnprintf pauseCloseBoundary
#include "../../utils/amcl_log.cpp"
#undef vsnprintf

static std::string read(const std::string& path) {
    std::ifstream input(path); std::ostringstream buffer; buffer << input.rdbuf(); return buffer.str();
}
int main(int argc, char** argv) {
    if (argc != 3) return 2;
    const std::string root=argv[1];
    std::string mode=argv[2];
    const bool game=mode.find("-game") != std::string::npos;
    if(game) mode.resize(mode.size()-5);
    const std::string logDir=root+"/logs"+(game?"/game":"");
    std::filesystem::create_directories(root+"/logs");
    amclLogInit(logDir.c_str(),2*1024*1024,5);
    const long long id=1789050000000LL;
    const std::string ledger=root+"/logs/ledger/"+std::to_string(id);
    const std::string launcher=ledger+"/launcher/"+(game?"launcher-game.log":"launcher-host.log");
    std::filesystem::create_directories(ledger);
    if (!amclLedgerBegin(id,ledger.c_str())) return 3;
    if(mode=="close-before-flush") {
        // 封账目标包含尚未发布的预留；超时返回必须保留 scope，producer 恢复后才能封存。
        std::thread delayed([id] { amclLogWriteFor(id,AMCL_LOG_LEVEL_ERROR,"MC_LAUNCHER","CLOSE_BOUNDARY_EGL_300D"); });
        { std::unique_lock<std::mutex> lock(closePauseMutex); closePauseCv.wait(lock, [] { return closePaused; }); }
        amclLedgerEnd(id);
        bool deferred = false;
        { std::lock_guard<std::mutex> lock(g_scopeMutex); deferred = findScopeLocked(id) != nullptr; }
        { std::lock_guard<std::mutex> lock(closePauseMutex); closeReleased = true; }
        closePauseCv.notify_all();
        delayed.join();
        amclLogFlush();
        std::printf("{\"globalContains\":%s,\"ledgerContains\":%s}\n",
            read(logDir+"/amcl_launcher.log").find("CLOSE_BOUNDARY_EGL_300D")!=std::string::npos?"true":"false",
            read(launcher).find("CLOSE_BOUNDARY_EGL_300D")!=std::string::npos?"true":"false");
        amclLogShutdown();return deferred ? 0 : 4;
    }
    amclLogWriteFor(0,AMCL_LOG_LEVEL_INFO,"McGamePage","NATIVE_CAPABILITY_UNSCOPED GPU=TestGPU GL=4.2");
    amclLogWriteFor(id,AMCL_LOG_LEVEL_ERROR,"MC_LAUNCHER","SCOPED_RENDER_FAILURE EGL_BAD_SURFACE=0x300d");
    amclLogFlush();
    if(mode=="hard-exit")std::_Exit(0);
    const auto global=read(logDir+"/amcl_launcher.log");
    const auto before=read(launcher);
    amclLedgerEnd(id);
    const auto after=read(launcher);
    std::printf("{\"globalAfterFlush\":%s,\"ledgerAfterFlush\":%s,\"ledgerAfterClose\":%s,\"unscopedInGlobal\":%s,\"unscopedInLedger\":%s}\n",
        global.find("SCOPED_RENDER_FAILURE")!=std::string::npos?"true":"false",
        before.find("SCOPED_RENDER_FAILURE")!=std::string::npos?"true":"false",
        after.find("SCOPED_RENDER_FAILURE")!=std::string::npos?"true":"false",
        global.find("NATIVE_CAPABILITY_UNSCOPED")!=std::string::npos?"true":"false",
        after.find("NATIVE_CAPABILITY_UNSCOPED")!=std::string::npos?"true":"false");
    amclLogShutdown();
}
