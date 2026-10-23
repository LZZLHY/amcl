/**
 * ZIP64 STORE writer：最多4个准备worker、每entry最多2个64KiB块、一个按序writer。
 * hash/CRC与本来读取流融合，不增加全量预读；writer保持独立SHA，输出仍由另一解析器读回。
 */
#include "export_trusted_io.h"
#include "../download/hmac_sha256.h"
#include <algorithm>
#include <array>
#include <cerrno>
#include <cstring>
#include <chrono>
#include <deque>
#include <fcntl.h>
#include <limits>
#include <thread>
#include <zlib.h>

namespace amcl::exporter {
namespace {
using Bytes = std::vector<uint8_t>;
void U16(Bytes& b, size_t at, uint16_t value) { b[at] = value; b[at + 1] = value >> 8; }
void U32(Bytes& b, size_t at, uint32_t value) { for (unsigned i = 0; i < 4; ++i) b[at + i] = value >> (i * 8); }
void U64(Bytes& b, size_t at, uint64_t value) { for (unsigned i = 0; i < 8; ++i) b[at + i] = value >> (i * 8); }
std::string Name(const Entry& entry) { return entry.path + (entry.directory ? "/" : ""); }
Bytes Local(const Entry& entry) {
    const auto name = Name(entry); Bytes b(50 + name.size());
    U32(b, 0, 0x04034b50); U16(b, 4, 45); U16(b, 6, 0x0808); U16(b, 12, 33);
    U32(b, 18, 0xffffffff); U32(b, 22, 0xffffffff); U16(b, 26, name.size()); U16(b, 28, 20);
    std::copy(name.begin(), name.end(), b.begin() + 30); const auto extra = 30 + name.size();
    U16(b, extra, 1); U16(b, extra + 2, 16); U64(b, extra + 4, entry.size); U64(b, extra + 12, entry.size); return b;
}
Bytes Descriptor(uint32_t crc, uint64_t size) {
    Bytes b(24); U32(b, 0, 0x08074b50); U32(b, 4, crc); U64(b, 8, size); U64(b, 16, size); return b;
}
Bytes Central(const Entry& entry, uint32_t crc, uint64_t offset) {
    const auto name = Name(entry); Bytes b(74 + name.size()); U32(b, 0, 0x02014b50); U16(b, 4, 45); U16(b, 6, 45);
    U16(b, 8, 0x0808); U16(b, 14, 33); U32(b, 16, crc); U32(b, 20, 0xffffffff); U32(b, 24, 0xffffffff);
    U16(b, 28, name.size()); U16(b, 30, 28); U32(b, 38, entry.directory ? 16 : 0); U32(b, 42, 0xffffffff);
    std::copy(name.begin(), name.end(), b.begin() + 46); const auto extra = 46 + name.size();
    U16(b, extra, 1); U16(b, extra + 2, 24); U64(b, extra + 4, entry.size); U64(b, extra + 12, entry.size);
    U64(b, extra + 20, offset); return b;
}
Bytes End(uint64_t entries, uint64_t size, uint64_t offset) {
    Bytes b(98); U32(b, 0, 0x06064b50); U64(b, 4, 44); U16(b, 12, 45); U16(b, 14, 45);
    U64(b, 24, entries); U64(b, 32, entries); U64(b, 40, size); U64(b, 48, offset);
    U32(b, 56, 0x07064b50); U64(b, 64, offset + size); U32(b, 72, 1); U32(b, 76, 0x06054b50);
    U16(b, 84, 65535); U16(b, 86, 65535); U32(b, 88, 0xffffffff); U32(b, 92, 0xffffffff); return b;
}

/**
 * 固定窗口给每entry独占两个块额度，当前/下一entry不会被更远任务挤掉。
 * 消费完成前buffer唯一归队列/writer所有；producer只移动所有权，不复用已交出的存储。
 */
class PreparationPool {
    struct Pipe { size_t sequence = SIZE_MAX; std::deque<Bytes> chunks; bool done = false; uint32_t crc = 0; std::string sha; };
    const ArchiveSpec& spec_; int snapshot_; Operation& op_;
    std::mutex mutex_; std::vector<Pipe> pipes_; std::vector<std::thread> workers_;
    size_t next_ = 0, consumed_ = 0, queued_ = 0; bool stopped_ = false;

    /**
     * cancel/error由作业owner以原子标志发布，不获取Pool锁，避免锁序反转。
     * 因而通知可能恰好落在predicate检查与阻塞之间；最多50ms重新核验，不能永久漏醒。
     * 正常队列通知仍立即唤醒，不按轮询速率推进字节流，也不在超时后假定条件成立。
     */
    template<class Predicate> void wait(std::unique_lock<std::mutex>& lock, Predicate ready) {
        while (!ready()) op_.cv.wait_for(lock, std::chrono::milliseconds(50));
    }

    void produce(size_t index) {
        const auto& entry = spec_.entries[index]; uint32_t crc = 0; download::Sha256 sha;
        if (entry.directory) {
            auto folder = OpenDirectoryAt(snapshot_, entry.path); folder.closeChecked();
        } else {
            Stamp before; auto file = OpenRegularAt(snapshot_, entry.path, before);
            if (static_cast<uint64_t>(before.value.st_size) != entry.size) throw Failure("SizeMismatch", "export snapshot file size differs from plan");
            uint64_t offset = 0;
            while (offset < entry.size) {
                Bytes chunk(static_cast<size_t>(std::min<uint64_t>(kChunkBytes, entry.size - offset)));
                ReadExact(file.get(), chunk.data(), chunk.size(), offset, op_);
                sha.update(chunk.data(), chunk.size()); crc = static_cast<uint32_t>(::crc32(crc, chunk.data(), chunk.size()));
                offset += chunk.size();
                std::unique_lock<std::mutex> lock(mutex_); auto& pipe = pipes_[index % pipes_.size()];
                wait(lock, [&] { return stopped_ || op_.stopping() || pipe.chunks.size() < 2; });
                if (stopped_) throw Failure("Cancelled", "export producer stopped");
                CheckActive(op_);
                queued_ += chunk.size(); op_.peakQueuedBytes.store(std::max<uint64_t>(op_.peakQueuedBytes.load(), queued_));
                pipe.chunks.push_back(std::move(chunk)); lock.unlock(); op_.cv.notify_all();
            }
            if (sha.finalizeHex() != entry.sha256) throw Failure("ChecksumMismatch", "export snapshot SHA256 differs from plan");
            VerifyRegularAt(snapshot_, entry.path, file.get(), before); file.closeChecked();
        }
        CheckActive(op_);
        { std::lock_guard<std::mutex> lock(mutex_); auto& pipe = pipes_[index % pipes_.size()];
          pipe.crc = crc; pipe.sha = entry.directory ? "" : sha.finalizeHex(); pipe.done = true; }
        op_.cv.notify_all();
    }
    void worker() noexcept {
        try {
            while (true) {
                size_t index;
                { std::unique_lock<std::mutex> lock(mutex_);
                  wait(lock, [&] { return stopped_ || op_.stopping() || next_ >= spec_.entries.size() || next_ < consumed_ + pipes_.size(); });
                  if (stopped_ || op_.stopping() || next_ >= spec_.entries.size()) return;
                  index = next_++; auto& pipe = pipes_[index % pipes_.size()];
                  if (pipe.sequence != SIZE_MAX) throw Failure("Invariant", "export preparation window reused before consumption");
                  pipe.sequence = index; }
                op_.cv.notify_all(); produce(index);
            }
        } catch (const Failure& error) { if (!(op_.cancelRequested && std::strcmp(error.code, "Cancelled") == 0)) op_.fail(error.code, error.what(), error.nativeCode); }
        catch (const std::bad_alloc&) { op_.fail("OutOfMemory", "export preparation allocation failed"); }
        catch (const std::exception& error) { op_.fail("NativeError", error.what()); }
        catch (...) { op_.fail("NativeError", "export preparation failed"); }
    }
public:
    PreparationPool(const ArchiveSpec& spec, int snapshot, Operation& op) : spec_(spec), snapshot_(snapshot), op_(op), pipes_(spec.workers) {
        workers_.reserve(spec.workers);
        try { for (unsigned i = 0; i < spec.workers; ++i) workers_.emplace_back([this] { worker(); }); }
        catch (...) { stopAndJoin(); throw; }
    }
    ~PreparationPool() { stopAndJoin(); }
    void stopAndJoin() noexcept {
        { std::lock_guard<std::mutex> lock(mutex_); stopped_ = true; } op_.cv.notify_all();
        for (auto& worker : workers_) if (worker.joinable()) worker.join();
    }
    /** 返回false表示entry所有已验证字节已经交付；crc/sha仅在其fd校验关闭后可见。 */
    bool take(size_t index, Bytes& bytes, uint32_t& crc, std::string& sha) {
        std::unique_lock<std::mutex> lock(mutex_); auto& pipe = pipes_[index % pipes_.size()];
        wait(lock, [&] { return stopped_ || op_.stopping() || (pipe.sequence == index && (!pipe.chunks.empty() || pipe.done)); });
        if (stopped_) throw Failure("Cancelled", "export consumer stopped");
        CheckActive(op_);
        if (!pipe.chunks.empty()) { bytes = std::move(pipe.chunks.front()); pipe.chunks.pop_front(); queued_ -= bytes.size(); lock.unlock(); op_.cv.notify_all(); return true; }
        crc = pipe.crc; sha = pipe.sha; return false;
    }
    void consumed(size_t index) {
        { std::lock_guard<std::mutex> lock(mutex_); pipes_[index % pipes_.size()] = Pipe{}; consumed_ = index + 1; }
        op_.cv.notify_all();
    }
};

/** 聚合小header/descriptor/central write；进度只在写入成功后推进，不把预读算已提交。 */
class BufferedWriter {
    int fd_; Operation& op_; Bytes buffer_; uint64_t written_ = 0, logical_ = 0, payload_ = 0;
    uint64_t bufferedPayload_ = 0; download::Sha256 sha_;
    struct Completed { uint64_t offset, count; }; std::deque<Completed> completed_;
    void advanceEntries() { while (!completed_.empty() && completed_.front().offset <= written_) { op_.filesDone = completed_.front().count; completed_.pop_front(); } }
public:
    BufferedWriter(int fd, Operation& op) : fd_(fd), op_(op) { buffer_.reserve(256 * 1024); }
    uint64_t position() const { return logical_; }
    void flush() {
        if (buffer_.empty()) return;
        WriteExact(fd_, buffer_.data(), buffer_.size(), written_, op_); sha_.update(buffer_.data(), buffer_.size());
        written_ += buffer_.size(); payload_ += bufferedPayload_; op_.archiveBytes = written_; op_.bytesDone = payload_;
        buffer_.clear(); bufferedPayload_ = 0; advanceEntries();
    }
    void append(const Bytes& bytes, bool payload = false) {
        size_t offset = 0;
        while (offset < bytes.size()) {
            CheckActive(op_); const auto size = std::min<size_t>(256 * 1024 - buffer_.size(), bytes.size() - offset);
            buffer_.insert(buffer_.end(), bytes.begin() + offset, bytes.begin() + offset + size);
            offset += size; logical_ += size; if (payload) bufferedPayload_ += size;
            if (buffer_.size() == 256 * 1024) flush();
        }
    }
    void completeEntry(size_t count) { completed_.push_back({logical_, count}); advanceEntries(); }
    std::string hash() { return sha_.finalizeHex(); }
};
}

void RunWrite(ArchiveSpec spec, Operation& op) noexcept {
    op.state = State::Running;
    try {
        ValidateSpec(spec); CheckActive(op); op.filesTotal = spec.entries.size();
        uint64_t total = 0; for (const auto& entry : spec.entries) total += entry.size; op.bytesTotal = total;
        Result result;
        { Roots roots(spec);
          Fd output(::openat(roots.job.get(), spec.archiveRelative.c_str(), O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0600));
          if (output.get() < 0) throw Failure("FileIo", "export archive create failed; existing target preserved", errno);
          const auto before = StatFd(output.get());
          if (!S_ISREG(before.value.st_mode) || before.value.st_nlink != 1) throw Failure("UnsafePath", "export archive is not exclusive regular file");
          BufferedWriter writer(output.get(), op); std::vector<std::pair<uint64_t, uint32_t>> directory; directory.reserve(spec.entries.size());
          { PreparationPool pool(spec, roots.snapshot.get(), op);
            for (size_t i = 0; i < spec.entries.size(); ++i) {
                const auto& entry = spec.entries[i]; const auto localOffset = writer.position(); writer.append(Local(entry));
                Bytes chunk; uint32_t crc = 0; std::string producerSha; download::Sha256 writerSha; uint64_t size = 0;
                while (pool.take(i, chunk, crc, producerSha)) {
                    writerSha.update(chunk.data(), chunk.size()); size += chunk.size(); writer.append(chunk, true); chunk.clear();
                }
                if (size != entry.size || (!entry.directory && (writerSha.finalizeHex() != entry.sha256 || producerSha != entry.sha256)))
                    throw Failure("ChecksumMismatch", "export writer independent SHA256 or length differs");
                writer.append(Descriptor(crc, size)); directory.emplace_back(localOffset, crc); writer.completeEntry(i + 1); pool.consumed(i);
            }
          } // pool先停止并join；output/root的owner仍在，失败也不会提前清理其fd。
          const auto centralOffset = writer.position();
          for (size_t i = 0; i < spec.entries.size(); ++i) writer.append(Central(spec.entries[i], directory[i].second, directory[i].first));
          writer.append(End(spec.entries.size(), writer.position() - centralOffset, centralOffset)); writer.flush(); SyncFd(output.get());
          auto after = StatFd(output.get());
          if (!S_ISREG(after.value.st_mode) || after.value.st_nlink != 1 || after.value.st_dev != before.value.st_dev ||
              after.value.st_ino != before.value.st_ino || static_cast<uint64_t>(after.value.st_size) != writer.position())
              throw Failure("SourceChanged", "export archive identity or length changed");
          VerifyRegularAt(roots.job.get(), spec.archiveRelative, output.get(), after); roots.verify();
          result.files = spec.entries.size(); result.size = writer.position(); result.payloadBytes = total; result.archiveBytes = writer.position();
          result.sha256 = writer.hash(); output.closeChecked(); SyncFd(roots.job.get()); CheckActive(op);
        }
        op.result = std::move(result);
    } catch (const Failure& error) { if (!(op.cancelRequested && std::strcmp(error.code, "Cancelled") == 0)) op.fail(error.code, error.what(), error.nativeCode); }
    catch (const std::bad_alloc&) { op.fail("OutOfMemory", "export writer allocation failed"); }
    catch (const std::exception& error) { op.fail("NativeError", error.what()); }
    catch (...) { op.fail("NativeError", "export writer failed"); }
    op.finish();
}
} // namespace amcl::exporter
