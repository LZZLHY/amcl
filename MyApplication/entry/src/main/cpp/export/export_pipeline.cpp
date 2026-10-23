/** 纯计划与fd摘要原语；所有摘要复用现有实现，不更改下载引擎或其网络状态。 */
#include "export_pipeline.h"
#include "export_trusted_io.h"
#include "../download/sha1.h"
#include "../download/hmac_sha256.h"
#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <memory>
#include <unordered_map>

namespace amcl::exporter {
void Operation::fail(const char* code, const char* text, int native) noexcept {
    { std::lock_guard<std::mutex> lock(errorMutex_);
      if (failed_.load(std::memory_order_relaxed)) return;
      std::snprintf(code_, sizeof(code_), "%s", code); std::snprintf(message_, sizeof(message_), "%s", text);
      nativeCode_ = native; failed_.store(true, std::memory_order_release); }
    cv.notify_all();
}
void Operation::error(std::string& code, std::string& text) const {
    std::lock_guard<std::mutex> lock(errorMutex_); code = code_; text = message_;
    if (nativeCode_) text += " errno=" + std::to_string(nativeCode_);
}
void Operation::finish() noexcept {
    state.store(failed_.load(std::memory_order_acquire) ? State::Failed : cancelRequested.load(std::memory_order_acquire)
        ? State::Cancelled : State::Succeeded, std::memory_order_release);
    coreFinished.store(true, std::memory_order_release); cv.notify_all();
}
const char* StateName(State state) noexcept {
    switch (state) { case State::Queued: return "queued"; case State::Running: return "running";
      case State::Succeeded: return "succeeded"; case State::Failed: return "failed"; case State::Cancelled: return "cancelled"; }
    return "failed";
}
namespace {
std::string LowerAscii(std::string text) { for (char& c : text) if (c >= 'A' && c <= 'Z') c += 'a' - 'A'; return text; }
bool Hex256(const std::string& text) {
    if (text.size() != 64) return false;
    for (char c : text) if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
    return true;
}
void CheckReserved(const std::string& path) {
    size_t start = 0;
    while (start < path.size()) {
        const auto slash = path.find('/', start); auto component = LowerAscii(path.substr(start, slash - start));
        component = component.substr(0, component.find('.'));
        if (component == "con" || component == "prn" || component == "aux" || component == "nul" ||
            (component.size() == 4 && (component.substr(0, 3) == "com" || component.substr(0, 3) == "lpt") && component[3] >= '1' && component[3] <= '9'))
            throw Failure("UnsafePath", "export path contains a Windows reserved component");
        if (slash == std::string::npos) break;
        start = slash + 1;
    }
}
}
void ValidateSpec(ArchiveSpec& spec) {
    if (spec.filesDir.empty() || spec.filesDir.front() != '/' || spec.filesDir.size() > 4096 ||
        spec.filesDir.find_first_of("\\\r\n\t") != std::string::npos || spec.filesDir.find('\0') != std::string::npos)
        throw Failure("UnsafeRoot", "export filesDir is invalid");
    // filesDir以下才做应用自有no-follow路径检查；绝对根本身仍拒绝点段/空段。
    size_t start = 1;
    for (size_t end = 1; end <= spec.filesDir.size(); ++end) if (end == spec.filesDir.size() || spec.filesDir[end] == '/') {
        const auto part = spec.filesDir.substr(start, end - start);
        if (part.empty() || part == "." || part == "..") throw Failure("UnsafeRoot", "export filesDir contains invalid components");
        start = end + 1;
    }
    spec.jobRelative = SafeRelative(spec.jobRelative);
    const std::string prefix = "game-export/work/";
    if (spec.jobRelative.compare(0, prefix.size(), prefix) != 0 || spec.jobRelative.size() == prefix.size() ||
        spec.jobRelative.find('/', prefix.size()) != std::string::npos || spec.snapshotRelative != "snapshot" || spec.archiveRelative != "export.zip")
        throw Failure("UnsafeRoot", "export job must use its private work/snapshot/export.zip layout");
    if (spec.entries.empty() || spec.entries.size() > kMaxEntries || spec.workers < 1 || spec.workers > 4)
        throw Failure("InvalidConfig", "export entries or worker bound is invalid");
    std::unordered_map<std::string, bool> paths;
    uint64_t payload = 0, names = 0;
    for (auto& entry : spec.entries) {
        entry.path = SafeRelative(entry.path, entry.directory); CheckReserved(entry.path);
        if (entry.path.size() + (entry.directory ? 1 : 0) > 65535 || entry.size > kSafeInteger || (entry.directory && entry.size))
            throw Failure("InvalidConfig", "export entry length is invalid");
        entry.sha256 = LowerAscii(entry.sha256);
        if (!entry.directory && !Hex256(entry.sha256)) throw Failure("InvalidConfig", "export file requires SHA256");
        const auto key = entry.foldedPath.empty() ? LowerAscii(entry.path) : entry.foldedPath;
        if (!paths.emplace(key, entry.directory).second) throw Failure("InvalidConfig", "export duplicate or case-folded path");
        payload += entry.size; names += entry.path.size() + (entry.directory ? 1 : 0);
        if (payload > kSafeInteger || names > 32 * 1024 * 1024) throw Failure("InvalidConfig", "export plan exceeds bounded sizes");
    }
    for (const auto& pair : paths) for (auto slash = pair.first.find('/'); slash != std::string::npos; slash = pair.first.find('/', slash + 1)) {
        const auto parent = paths.find(pair.first.substr(0, slash));
        if (parent != paths.end() && !parent->second) throw Failure("InvalidConfig", "export file/directory prefix collision");
    }
    // 全ZIP长度也必须能被ArkTS安全整数表达，避免只验证payload而让结构开销溢出。
    if (payload > kSafeInteger - names * 2 - static_cast<uint64_t>(spec.entries.size()) * 148 - 98)
        throw Failure("InvalidConfig", "export ZIP length exceeds safe integer");
}

void RunHash(int ownedFd, uint64_t expectedSize, bool includeSha1, bool includeSha256, Operation& op) noexcept {
    op.state.store(State::Running, std::memory_order_release); op.filesTotal = 1; op.bytesTotal = expectedSize;
    try {
        Fd file(ownedFd); CheckActive(op);
        // 直接core调用已经移交owned fd，错误也须RAII关闭；在任何lease/stat/read前拒绝无用途请求。
        if (!includeSha1 && !includeSha256) throw Failure("InvalidConfig", "export hash requires at least one digest");
        auto lease = amcl::AcquireConfiguredUpdateReadLease();
        if (!lease) throw Failure("InstallFence", "export hash file lease unavailable");
        const auto before = StatFd(file.get());
        if (!S_ISREG(before.value.st_mode) || before.value.st_size < 0 || expectedSize > kSafeInteger ||
            static_cast<uint64_t>(before.value.st_size) != expectedSize) throw Failure("SizeMismatch", "export hash fd is not a matching regular file");
        download::Sha1 sha1; download::Sha256 sha256;
        // Debug libc++的vector(size)会逐元素构造/析构整块，少量小文件字节也付出64KiB成本。
        // 字节数组故意不作值初始化：ReadExact只有完全填满本次size才返回，之后才允许hash。
        // 空文件不分配，小文件只分配实际长度，大文件上限仍64KiB；失败/取消由同栈RAII归还。
        const auto capacity = static_cast<size_t>(std::min<uint64_t>(kChunkBytes, expectedSize));
        std::unique_ptr<uint8_t[]> buffer(capacity == 0 ? nullptr : new uint8_t[capacity]);
        uint64_t offset = 0;
        while (offset < expectedSize) {
            const auto size = static_cast<size_t>(std::min<uint64_t>(capacity, expectedSize - offset));
            ReadExact(file.get(), buffer.get(), size, offset, op);
            if (includeSha1) sha1.update(buffer.get(), size);
            if (includeSha256) sha256.update(buffer.get(), size);
            offset += size; op.bytesDone.store(offset, std::memory_order_release);
        }
        CheckActive(op); const auto after = StatFd(file.get());
        if (!S_ISREG(after.value.st_mode) || !SameStamp(before, after)) throw Failure("SourceChanged", "export hash fd changed during read");
        Result result; result.files = 1; result.size = expectedSize; result.payloadBytes = expectedSize;
        // 空串明确表示该算法未请求，不得把它作为已计算摘要的凭据。
        result.sha1 = includeSha1 ? sha1.finalizeHex() : ""; result.sha256 = includeSha256 ? sha256.finalizeHex() : "";
        file.closeChecked(); CheckActive(op); op.result = std::move(result); op.filesDone = 1;
    } catch (const Failure& error) { if (!(op.cancelRequested && std::strcmp(error.code, "Cancelled") == 0)) op.fail(error.code, error.what(), error.nativeCode); }
    catch (const std::bad_alloc&) { op.fail("OutOfMemory", "export hash allocation failed"); }
    catch (const std::exception& error) { op.fail("NativeError", error.what()); }
    catch (...) { op.fail("NativeError", "export hash failed with unknown exception"); }
    op.finish();
}
} // namespace amcl::exporter
