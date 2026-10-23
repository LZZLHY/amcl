/**
 * 导出专用数据面。只消费本owner的私有快照与已借用的只读fd，不接管下载/URI/页面。
 * Run返回前已关闭文件并join全部准备worker；NAPI完成回调再发布settled，二者不得混淆。
 */
#pragma once
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

namespace amcl::exporter {
constexpr uint64_t kSafeInteger = 9007199254740991ULL;
constexpr size_t kChunkBytes = 64 * 1024;
constexpr size_t kMaxEntries = 200000;

/** foldedPath只由NAPI owner线程用原字符串toLowerCase生成，不接受调用者自填。 */
struct Entry {
    std::string path, sha256, foldedPath;
    uint64_t size = 0;
    bool directory = false;
};
struct ArchiveSpec {
    std::string filesDir, jobRelative, snapshotRelative = "snapshot", archiveRelative = "export.zip";
    std::vector<Entry> entries;
    unsigned workers = 2;
};
struct Result {
    uint64_t files = 0, size = 0, payloadBytes = 0, archiveBytes = 0;
    std::string sha1, sha256;
};
enum class State { Queued, Running, Succeeded, Failed, Cancelled };

/**
 * 进度只存实际计数。错误首因在独立锁下写入；取消只发信号，不从调用线程关闭worker fd。
 * cv供单个作业的有界队列等待使用，cancel/error唤醒所有生产者和单writer。
 */
class Operation {
public:
    std::atomic<bool> cancelRequested{false}, coreFinished{false}, settled{false};
    std::atomic<State> state{State::Queued};
    std::atomic<uint64_t> filesDone{0}, filesTotal{0}, bytesDone{0}, bytesTotal{0}, archiveBytes{0};
    std::atomic<uint64_t> peakQueuedBytes{0}; // 同路径宿主验证有界payload队列，不进入用户内容。
    std::condition_variable cv;
    Result result; // 仅execute写；coreFinished release之后由complete读取。

    void cancel() noexcept { cancelRequested.store(true, std::memory_order_release); cv.notify_all(); }
    bool stopping() const noexcept { return cancelRequested.load(std::memory_order_acquire) || failed_.load(std::memory_order_acquire); }
    void fail(const char* code, const char* message, int nativeCode = 0) noexcept;
    void error(std::string& code, std::string& message) const;
    void finish() noexcept;
private:
    std::atomic<bool> failed_{false};
    mutable std::mutex errorMutex_;
    char code_[64]{}, message_[768]{};
    int nativeCode_ = 0;
};

/** 校验/规范化纯计划，不访问文件。NAPI owner与宿主用同一规则，失败抛有界错误。 */
void ValidateSpec(ArchiveSpec& spec);
void RunWrite(ArchiveSpec spec, Operation& operation) noexcept;
void RunVerify(ArchiveSpec spec, Operation& operation) noexcept;
/** 接管一个dup的只读fd，所有出口恰好close一次；pread不改变原借用者的offset。 */
void RunHash(int ownedFd, uint64_t expectedSize, bool sha1, bool sha256, Operation& operation) noexcept;
/** 既有内部/宿主调用保留原默认：SHA256必算；新调用显式声明两个算法用途。 */
inline void RunHash(int ownedFd, uint64_t expectedSize, bool sha1, Operation& operation) noexcept {
    RunHash(ownedFd, expectedSize, sha1, true, operation);
}
const char* StateName(State state) noexcept;
} // namespace amcl::exporter
