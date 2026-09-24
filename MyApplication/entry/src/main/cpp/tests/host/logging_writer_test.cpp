// 直接编译生产 writer；只适配宿主平台并暂停一个 printf 调用来固定竞争时序。
#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <ctime>
#include <string>
#include <vector>
#include <mutex>
#include <thread>
#include <atomic>
#include <condition_variable>
#include <filesystem>
#include <fstream>
#include <sstream>
#ifdef _WIN32
#include <direct.h>
#define mkdir(path, mode) _mkdir(path)
#endif
/** 捕获生产 writer 对隐式时区转换的回归；旧实现即使宿主没有崩溃也必须被此判据拒绝。 */
static std::atomic<unsigned> localTimeCalls{0};
static tm* observed_localtime_r(const time_t* value, tm* result) {
    ++localTimeCalls;
#ifdef _WIN32
    return localtime_s(result, value) == 0 ? result : nullptr;
#else
    return ::localtime_r(value, result);
#endif
}
#define localtime_r observed_localtime_r
static std::mutex pauseMutex;
static std::condition_variable pauseCv;
static bool paused = false, released = false;
static int controlled_vsnprintf(char* out, size_t size, const char* fmt, va_list args) {
    if (std::strcmp(fmt, "PAUSE_OWNER") == 0) {
        std::unique_lock<std::mutex> lock(pauseMutex);
        paused = true; pauseCv.notify_all(); pauseCv.wait(lock, [] { return released; });
    }
    return std::vsnprintf(out, size, fmt, args);
}
#define vsnprintf controlled_vsnprintf
#include "../../utils/amcl_log.cpp"
#undef vsnprintf
#undef localtime_r
#include "../../utils/amcl_log_bridge.h"
static std::string readFile(const std::string& path) { std::ifstream file(path); std::ostringstream out; out << file.rdbuf(); return out.str(); }
static void expect(bool value, const char* reason) { if (!value) { std::fprintf(stderr, "FAIL: %s\n", reason); std::exit(1); } }
int main(int argc, char** argv) {
    if (argc != 3) return 2;
    const std::string base = argv[1], mode = argv[2];
    std::filesystem::create_directories(base);
    if (mode == "utc-time") {
        // 固定已知 epoch，覆盖闰日、2038 边界以及小缓冲区，不借用被测格式化器生成期望值。
        char formatted[32];
        expect(amclFormatLogTime(0, formatted, sizeof(formatted)) &&
            std::string(formatted) == "1970-01-01T00:00:00Z", "epoch UTC formatting failed");
        expect(amclFormatLogTime(1709164800LL, formatted, sizeof(formatted)) &&
            std::string(formatted) == "2024-02-29T00:00:00Z", "leap day UTC formatting failed");
        expect(amclFormatLogTime(2147483648LL, formatted, sizeof(formatted)) &&
            std::string(formatted) == "2038-01-19T03:14:08Z", "post-2038 UTC formatting failed");
        char tiny[4];
        expect(!amclFormatLogTime(0, tiny, sizeof(tiny)) && tiny[3] == '\0', "small output overflowed");
        expect(!amclFormatLogTime(0, nullptr, 0), "null output accepted");
        amclLogInit(base.c_str(), 20 * 1024 * 1024, 2);
        // 与真实 writer 并发修改时区/环境条目；日志不能读取进程 environ 或依赖 TZ 当前值。
        std::thread environmentWriter([] {
            for (int i = 0; i < 2000; ++i) {
#ifdef _WIN32
                _putenv_s("TZ", (i & 1) ? "UTC0" : "EST5EDT");
#else
                setenv("TZ", (i & 1) ? "UTC0" : "EST5EDT", 1);
#endif
            }
        });
        for (int i = 0; i < 2000; ++i) amclLogWriteFor(0, AMCL_LOG_LEVEL_ERROR, "TIME", "sequence=%d", i);
        environmentWriter.join();
        amclLogFlush();
        amclLogShutdown();
        expect(localTimeCalls.load() == 0, "writer called localtime while environment was mutable");
        const auto text = readFile(base + "/amcl_launcher.log");
        expect(text.find("Z][E][TIME]") != std::string::npos, "writer omitted UTC marker");
    } else if (mode == "reservation" || mode == "wrap") {
        const unsigned int start = mode == "wrap" ? 0xffffff00u : 0;
        g_writeIndex.store(start); g_readIndex = start;
        for (unsigned int offset = 0; offset < LOG_BUFFER_SIZE; ++offset) {
            g_buffer[(start + offset) % LOG_BUFFER_SIZE].sequence.store(start + offset);
        }
        g_initialized.store(true);
        std::thread owner([] { amclLogWriteFor(1, AMCL_LOG_LEVEL_ERROR, "TEST", "PAUSE_OWNER"); });
        { std::unique_lock<std::mutex> lock(pauseMutex); pauseCv.wait(lock, [] { return paused; }); }
        for (int i = 1; i <= LOG_BUFFER_SIZE; ++i) amclLogWriteFor(2, AMCL_LOG_LEVEL_ERROR, "TEST", "OTHER_%d", i);
        expect(g_writeIndex.load() - start == LOG_BUFFER_SIZE, "unpublished reservation was overwritten");
        expect(g_droppedTotal.load() == 1, "full ring must count exactly one dropped event");
        { std::lock_guard<std::mutex> lock(pauseMutex); released = true; } pauseCv.notify_all(); owner.join();
        expect(g_buffer[start % LOG_BUFFER_SIZE].activityId == 1, "activity owner must survive wrap");
        expect(std::string(g_buffer[start % LOG_BUFFER_SIZE].message) == "PAUSE_OWNER", "reserved content lost");
        for (unsigned int offset = 0; offset < LOG_BUFFER_SIZE; ++offset) {
            const unsigned int position = start + offset;
            LogEntry& entry = g_buffer[position % LOG_BUFFER_SIZE];
            expect(entry.sequence.load() == position + 1, "published sequence has a hole");
            entry.sequence.store(position + LOG_BUFFER_SIZE);
        }
        amclLogWriteFor(3, AMCL_LOG_LEVEL_ERROR, "TEST", "AFTER_DRAIN");
        expect(g_writeIndex.load() - start == LOG_BUFFER_SIZE + 1, "queue cannot resume after full");
    } else if (mode == "prepublished-wakeup") {
        // 固定「通知先于首次 wait」的时序：不创建 writer，先发布正文，再执行同一等待函数。
        // 队列非空时应直接消费，而不是用完 500 ms 刷新超时后才偶然醒来。
        for (unsigned int index = 0; index < LOG_BUFFER_SIZE; ++index) g_buffer[index].sequence.store(index);
        g_initialized.store(true);
        amclLogWriteFor(1, AMCL_LOG_LEVEL_ERROR, "TEST", "ALREADY_PUBLISHED");
        const auto started = std::chrono::steady_clock::now();
        waitForWriterWork();
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started).count();
        expect(elapsed < LOG_FLUSH_INTERVAL_MS / 2, "published work waited for the idle timeout");
    } else if (mode == "retention") {
        const std::string dir = base + "/ledger";
        expect(amclLedgerBegin(101, dir.c_str()) == 1, "scope failed to open");
        auto* scope = findScopeLocked(101);
        const std::string body(4000, 'x');
        for (int i = 0; i < 1200; ++i) { const std::string line = "SEQ=" + std::to_string(i) + " " + body + "\n"; writeToScopeLocked(scope, line.c_str(), static_cast<int>(line.size())); }
        for (int i = 0; i < 650; ++i) { const std::string line = "RENDER=" + std::to_string(i) + " " + body + "\n"; writeRenderToScopeLocked(scope, line.c_str(), static_cast<int>(line.size())); }
        amclLedgerEndAll();
        const std::string launcher = readFile(dir + "/launcher/launcher-host.log"), renderer = readFile(dir + "/render/renderer.log");
        for (int i = 0; i < 1200; ++i) expect(launcher.find("SEQ=" + std::to_string(i) + " ") != std::string::npos, "launcher has a middle gap");
        for (int i = 0; i < 650; ++i) expect(renderer.find("RENDER=" + std::to_string(i) + " ") != std::string::npos, "renderer hit former size cap");
        expect(readFile(dir + "/capture-host.json").find("\"sealed\":true") != std::string::npos, "capture seal missing");
    } else if (mode == "flush" || mode == "close") {
        amclLogInit(base.c_str(), 20 * 1024 * 1024, 2);
        const std::string dir = base + "/ledger"; amclLedgerBegin(101, dir.c_str());
        const std::string longText = "LONG_START" + std::string(30000, 'z') + "LONG_END";
        amclLogWriteFor(101, AMCL_LOG_LEVEL_ERROR, "TEST", "%s", longText.c_str());
        for (int i = 0; i < 10; ++i) amclLogWriteFor(101, AMCL_LOG_LEVEL_ERROR, "TEST", "REPEAT");
        if (mode == "flush") amclLogFlush(); else amclLedgerEnd(101);
        const std::string launcher = readFile(dir + "/launcher/launcher-host.log");
        expect(launcher.find(longText) != std::string::npos, "long stack was truncated");
        expect(launcher.find("repeated 9 more times") != std::string::npos, "flush lost pending repeat count");
        amclLogShutdown();
    } else if (mode == "global-recovery") {
        // 用临时目录里的普通文件阻挡日志目录，随后解除故障；必须在同一 writer 进程恢复。
        const std::string blocker = base + "/blocked";
        { std::ofstream file(blocker); file << "blocked"; }
        const std::string logs = blocker + "/logs";
        amclLogInit(logs.c_str(), 20 * 1024 * 1024, 2);
        amclLogWriteFor(0, AMCL_LOG_LEVEL_ERROR, "TEST", "DURING_FAILURE");
        expect(amclLogFlushChecked() == 0, "unwritable sink reported flush success");
        expect(g_globalFailures.load() > 0 && g_globalLostWrites.load() > 0, "missing global failure evidence");
        std::filesystem::remove(blocker);
        std::filesystem::create_directories(logs);
        amclLogInit(logs.c_str(), 20 * 1024 * 1024, 2);
        amclLogWriteFor(0, AMCL_LOG_LEVEL_ERROR, "TEST", "AFTER_STORAGE_RECOVERY");
        expect(amclLogFlushChecked() == 1, "sink did not reopen after storage recovered");
        expect(readFile(logs + "/amcl_launcher.log").find("AFTER_STORAGE_RECOVERY") != std::string::npos, "recovered output missing");
        expect(std::string(amclLogGetStatus()).find("\"writable\":true") != std::string::npos, "status did not recover");
        expect(g_globalLostWrites.load() > 0, "recovery erased historical gap");
        amclLogShutdown();
    } else if (mode == "long-message-budget") {
        // 固定无消费者的高峰，直接填充真实队列；不能用快速消费掩盖总量预算缺失。
        for (unsigned int i = 0; i < LOG_BUFFER_SIZE; ++i) g_buffer[i].sequence.store(i);
        g_initialized.store(true);
        const std::string longText(64 * 1024, 'x');
        for (int i = 0; i < LOG_BUFFER_SIZE; ++i) amclLogWriteFor(0, AMCL_LOG_LEVEL_ERROR, "TEST", "%s", longText.c_str());
        expect(g_longMessageBytes.load() > 0 && g_longMessageBytes.load() <= LOG_LONG_MESSAGE_BUDGET, "global long-message budget exceeded");
        bool marked = false;
        for (auto& entry : g_buffer) {
            marked = marked || std::string(entry.message).find("memory budget exhausted") != std::string::npos;
            releaseLongMessage(entry);
            expect(entry.extendedMessage.capacity() < 4096, "consumed slot retained a large allocation");
        }
        expect(marked, "budget loss must be explicit");
        expect(g_longMessageBytes.load() == 0, "consumed slots did not return budget");
    } else if (mode == "failed-open") {
        const std::string blocker = base + "/file"; { std::ofstream file(blocker); file << "block"; }
        expect(amclLedgerBegin(101, (blocker + "/ledger").c_str()) == 0, "failed open reported success");
        expect(findScopeLocked(101) && findScopeLocked(101)->failures > 0, "failed open was silently complete");
        amclLedgerEndAll();
    } else if (mode == "external-sink") {
        amclLogInit(base.c_str(), 2 * 1024 * 1024, 2);
        const std::string dir = base + "/ledger";
        amclLedgerBegin(101, dir.c_str());
        amclLedgerSetLaunchActivity(101);
        int evaluations = 0;
        AMCL_EXTERNAL_LOG_E("GLFW_EGL", "SIDE_EFFECT=%d", ++evaluations);
        expect(evaluations == 1, "external failure arguments must be evaluated once");
        AMCL_LOG_E("TEST", "HOST_SIDE_EFFECT=%d", ++evaluations);
        expect(evaluations == 2, "host failure arguments must be evaluated once");
        amclExternalLogWrite(3, "GLFW_EGL", "EXTERNAL_FAILURE=%{public}d", 123);
        amclLogFlush();
        expect(readFile(dir + "/render/renderer.log").find("EXTERNAL_FAILURE=123") != std::string::npos, "external provider failed to reach host writer");
        expect(readFile(dir + "/launcher/launcher-host.log").find("EXTERNAL_FAILURE") == std::string::npos, "optional render leaked into launcher");
#ifdef _WIN32
        _putenv_s("AMCL_LOG_SINK_V1", "0:1");
#else
        setenv("AMCL_LOG_SINK_V1", "0:1", 1);
#endif
        amclExternalLogWrite(3, "GLFW_EGL", "WRONG_PID");
        amclLogShutdown();
    } else if (mode == "routing") {
        for (const char* tag : {"GLFW_EGL", "AMCL_FRAME_RATE", "AMCL_MG_BENCH", "AMCL_VULKAN_WSI", "GraphicsCapability"}) expect(isRenderTag(tag), "render detail leaked into launcher");
        expect(!isRenderTag("JVM_LAUNCHER"), "launcher summary misclassified");
    } else return 3;
    std::printf("PASS %s\n", mode.c_str()); return 0;
}
