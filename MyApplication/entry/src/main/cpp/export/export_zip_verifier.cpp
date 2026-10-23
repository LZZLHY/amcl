/**
 * 独立ZIP64 STORE解析器。逐字段读取实际central/local/descriptor，不调用writer编码器。
 * 一次必要读取流内完成entry CRC/SHA和整包SHA，中央目录只缓存有界元数据，不增全量预读。
 */
#include "export_trusted_io.h"
#include "../download/hmac_sha256.h"
#include <algorithm>
#include <cstring>
#include <zlib.h>

namespace amcl::exporter {
namespace {
using Bytes = std::vector<uint8_t>;
void Require(bool value) { if (!value) throw Failure("InvalidArchive", "export ZIP structure, entries or digest differs from plan"); }
uint16_t Get16(const uint8_t* b) { return static_cast<uint16_t>(b[0]) | static_cast<uint16_t>(b[1]) << 8; }
uint32_t Get32(const uint8_t* b) { return static_cast<uint32_t>(b[0]) | static_cast<uint32_t>(b[1]) << 8 |
    static_cast<uint32_t>(b[2]) << 16 | static_cast<uint32_t>(b[3]) << 24; }
uint64_t Get64(const uint8_t* b) {
    const uint64_t value = Get32(b) | static_cast<uint64_t>(Get32(b + 4)) << 32;
    Require(value <= kSafeInteger); return value;
}
/** 此读取器统计实际读取字节；所有长度在验证区间后才分配，payload始终64KiB分块。 */
class Reader {
    int fd_; Operation& op_;
public:
    Reader(int fd, Operation& op) : fd_(fd), op_(op) {}
    Bytes read(uint64_t offset, size_t size) {
        Bytes bytes(size); size_t done = 0;
        while (done < size) {
            const auto count = std::min(kChunkBytes, size - done);
            ReadExact(fd_, bytes.data() + done, count, offset + done, op_); done += count;
            op_.archiveBytes.fetch_add(count, std::memory_order_release);
        }
        return bytes;
    }
};
}

void RunVerify(ArchiveSpec spec, Operation& op) noexcept {
    op.state = State::Running;
    try {
        ValidateSpec(spec); CheckActive(op); op.filesTotal = spec.entries.size();
        uint64_t total = 0; for (const auto& entry : spec.entries) total += entry.size; op.bytesTotal = total;
        Result result;
        { Roots roots(spec); Stamp before; auto archive = OpenRegularAt(roots.job.get(), spec.archiveRelative, before);
          const uint64_t length = before.value.st_size; Require(length >= 98 && length <= kSafeInteger);
          Reader reader(archive.get(), op); const auto tail = reader.read(length - 98, 98); const auto* t = tail.data();
          Require(Get32(t) == 0x06064b50 && Get64(t + 4) == 44 && Get16(t + 12) == 45 && Get16(t + 14) == 45 &&
              Get32(t + 16) == 0 && Get32(t + 20) == 0 && Get64(t + 24) == spec.entries.size() && Get64(t + 32) == spec.entries.size());
          const auto centralSize = Get64(t + 40), centralStart = Get64(t + 48);
          Require(centralSize <= 64 * 1024 * 1024 && centralStart <= length - 98 && centralSize == length - 98 - centralStart &&
              Get32(t + 56) == 0x07064b50 && Get32(t + 60) == 0 && Get64(t + 64) == length - 98 && Get32(t + 72) == 1 &&
              Get32(t + 76) == 0x06054b50 && Get32(t + 80) == 0 && Get16(t + 84) == 65535 && Get16(t + 86) == 65535 &&
              Get32(t + 88) == 0xffffffff && Get32(t + 92) == 0xffffffff && Get16(t + 96) == 0);
          const auto central = reader.read(centralStart, static_cast<size_t>(centralSize));
          size_t cursor = 0; uint64_t localOffset = 0, payloadDone = 0; download::Sha256 whole;
          for (size_t index = 0; index < spec.entries.size(); ++index) {
              CheckActive(op); const auto& entry = spec.entries[index]; const auto name = entry.path + (entry.directory ? "/" : "");
              Require(cursor <= central.size() && central.size() - cursor >= 46); const auto* c = central.data() + cursor;
              const size_t nameBytes = Get16(c + 28), extraBytes = Get16(c + 30);
              Require(Get32(c) == 0x02014b50 && Get16(c + 4) == 45 && Get16(c + 6) == 45 && Get16(c + 8) == 0x0808 &&
                  Get16(c + 10) == 0 && Get16(c + 12) == 0 && Get16(c + 14) == 33 && Get32(c + 20) == 0xffffffff &&
                  Get32(c + 24) == 0xffffffff && extraBytes == 28 && Get16(c + 32) == 0 && Get16(c + 34) == 0 &&
                  Get16(c + 36) == 0 && Get32(c + 38) == (entry.directory ? 16U : 0U) && Get32(c + 42) == 0xffffffff);
              Require(nameBytes == name.size() && central.size() - cursor >= 46 + nameBytes + extraBytes &&
                  std::memcmp(c + 46, name.data(), name.size()) == 0);
              const auto* extra = c + 46 + nameBytes;
              Require(Get16(extra) == 1 && Get16(extra + 2) == 24 && Get64(extra + 4) == entry.size &&
                  Get64(extra + 12) == entry.size && Get64(extra + 20) == localOffset);
              const uint64_t metadata = 50 + nameBytes + 24;
              Require(localOffset <= centralStart && metadata <= centralStart - localOffset && entry.size <= centralStart - localOffset - metadata);
              const auto local = reader.read(localOffset, 50 + nameBytes); const auto* l = local.data();
              Require(Get32(l) == 0x04034b50 && Get16(l + 4) == 45 && Get16(l + 6) == 0x0808 && Get16(l + 8) == 0 &&
                  Get16(l + 10) == 0 && Get16(l + 12) == 33 && Get32(l + 14) == 0 && Get32(l + 18) == 0xffffffff &&
                  Get32(l + 22) == 0xffffffff && Get16(l + 26) == nameBytes && Get16(l + 28) == 20 &&
                  std::memcmp(l + 30, name.data(), name.size()) == 0);
              const auto* localExtra = l + 30 + nameBytes;
              Require(Get16(localExtra) == 1 && Get16(localExtra + 2) == 16 && Get64(localExtra + 4) == entry.size && Get64(localExtra + 12) == entry.size);
              whole.update(local.data(), local.size()); const uint64_t bodyOffset = localOffset + local.size();
              download::Sha256 sha; uint32_t crc = 0; uint64_t size = 0;
              while (size < entry.size) {
                  const auto bytes = reader.read(bodyOffset + size, static_cast<size_t>(std::min<uint64_t>(kChunkBytes, entry.size - size)));
                  crc = static_cast<uint32_t>(::crc32(crc, bytes.data(), bytes.size())); sha.update(bytes.data(), bytes.size()); whole.update(bytes.data(), bytes.size());
                  size += bytes.size(); payloadDone += bytes.size(); op.bytesDone.store(payloadDone, std::memory_order_release);
              }
              Require(crc == Get32(c + 16) && (entry.directory || sha.finalizeHex() == entry.sha256));
              const auto descriptor = reader.read(bodyOffset + size, 24); const auto* d = descriptor.data();
              Require(Get32(d) == 0x08074b50 && Get32(d + 4) == crc && Get64(d + 8) == size && Get64(d + 16) == size);
              whole.update(descriptor.data(), descriptor.size()); localOffset = bodyOffset + size + 24;
              cursor += 46 + nameBytes + extraBytes; op.filesDone = index + 1;
          }
          Require(localOffset == centralStart && cursor == central.size()); whole.update(central.data(), central.size()); whole.update(tail.data(), tail.size());
          VerifyRegularAt(roots.job.get(), spec.archiveRelative, archive.get(), before); roots.verify(); archive.closeChecked(); CheckActive(op);
          result.files = spec.entries.size(); result.size = length; result.payloadBytes = total; result.archiveBytes = length; result.sha256 = whole.finalizeHex();
        }
        op.result = std::move(result);
    } catch (const Failure& error) { if (!(op.cancelRequested && std::strcmp(error.code, "Cancelled") == 0)) op.fail(error.code, error.what(), error.nativeCode); }
    catch (const std::bad_alloc&) { op.fail("OutOfMemory", "export verifier allocation failed"); }
    catch (const std::exception& error) { op.fail("NativeError", error.what()); }
    catch (...) { op.fail("NativeError", "export verifier failed"); }
    op.finish();
}
} // namespace amcl::exporter
