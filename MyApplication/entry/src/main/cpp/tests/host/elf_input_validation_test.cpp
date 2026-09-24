/**
 * 直接测试产品 ELF 输入纯核心：构造合法最小输入，再逐项破坏结构和读取结果。
 * --stdin 模式只检查输入字节、不装载/执行 ELF，供锁定 JDK 发布 ZIP 的只读正例使用。
 * 这里的通过不表示动态符号内容安全，也不代替 OHOS mmap/TLS/JVM 真机回归。
 */
#include "../../jvm/elf_input_validation.h"
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

namespace {
using namespace amcl::elfinput;
using Bytes = std::vector<unsigned char>;
std::size_t cases = 0;

// 检查不依赖调试宏，发布优化与调试构建都必须执行判断并返回真实失败。
void Require(bool condition, const char* description)
{
    if (!condition) { std::cerr << "FAIL: " << description << '\n'; std::exit(1); }
}

// 按文件字节写入字段，避免构造宿主 ELF 结构体掩盖错误大小或字节序。
void Put(Bytes& bytes, std::size_t offset, std::uint64_t value, std::size_t count)
{
    for (std::size_t index = 0; index < count; ++index) {
        bytes[offset + index] = static_cast<unsigned char>(value >> (index * 8));
    }
}

void PutSegment(Bytes& bytes, std::size_t index, std::uint32_t type, std::uint64_t offset,
                std::uint64_t address, std::uint64_t fileBytes, std::uint64_t memoryBytes,
                std::uint64_t alignment)
{
    const std::size_t base = HeaderBytes + index * ProgramHeaderBytes;
    Put(bytes, base, type, 4); Put(bytes, base + 8, offset, 8); Put(bytes, base + 16, address, 8);
    Put(bytes, base + 32, fileBytes, 8); Put(bytes, base + 40, memoryBytes, 8); Put(bytes, base + 48, alignment, 8);
}

Bytes ValidImage()
{
    Bytes bytes(1024, 0);
    bytes[0] = 0x7f; bytes[1] = 'E'; bytes[2] = 'L'; bytes[3] = 'F';
    bytes[4] = 2; bytes[5] = 1; bytes[6] = 1;
    Put(bytes, 16, 3, 2); Put(bytes, 18, 183, 2); Put(bytes, 20, 1, 4);
    Put(bytes, 32, HeaderBytes, 8); Put(bytes, 52, HeaderBytes, 2);
    Put(bytes, 54, ProgramHeaderBytes, 2); Put(bytes, 56, 4, 2);
    PutSegment(bytes, 0, Load, 0, 0, 768, 4096, 4096);
    PutSegment(bytes, 1, Dynamic, 512, 512, 32, 32, 8);
    // 第三、四项默认 PT_NULL。动态表的终止项放在最后一个完整 Elf64_Dyn 内。
    Put(bytes, 512, 1, 8);
    return bytes;
}

// 宿主文件入口与生产分阶段入口使用相同的三个 validator，拒绝在失败后继续取偏移。
bool ValidateImage(const Bytes& bytes, Layout& layout, const char*& error)
{
    Header header;
    if (!ValidateHeader(bytes.data(), bytes.size(), bytes.size(), header, error)) return false;
    const unsigned char* programs = bytes.data() + static_cast<std::size_t>(header.programOffset);
    if (!ValidateProgramHeaders(programs, header.programBytes, bytes.size(), 4096, layout, error)) return false;
    for (std::size_t index = 0; index < header.programCount; ++index) {
        const Segment segment = ReadSegment(programs + index * ProgramHeaderBytes);
        if (segment.type == Dynamic && !HasDynamicTerminator(bytes.data() + static_cast<std::size_t>(segment.offset),
                                                             static_cast<std::size_t>(segment.fileBytes))) {
            error = "PT_DYNAMIC has no in-range DT_NULL"; return false;
        }
    }
    return true;
}

// 每次仅破坏一个目标契约，同时要求错误分类命中预期，避免因为其他错误而假阳性。
void Reject(const char* name, const std::function<void(Bytes&)>& mutate, const char* message)
{
    Bytes bytes = ValidImage(); mutate(bytes);
    Layout layout; const char* error = nullptr;
    Require(!ValidateImage(bytes, layout, error), name);
    if (!error || !std::strstr(error, message)) {
        std::cerr << name << ": expected " << message << ", got " << (error ? error : "no error") << '\n';
        std::exit(1);
    }
    ++cases;
}

void Accept(const char* name, const std::function<void(Bytes&)>& mutate)
{
    Bytes bytes = ValidImage(); mutate(bytes);
    Layout layout; const char* error = nullptr;
    if (!ValidateImage(bytes, layout, error)) {
        std::cerr << name << ": " << (error ? error : "no error") << '\n'; std::exit(1);
    }
    Require(layout.loadBias == 0 && layout.mapBytes == 4096 && layout.dynamicBytes == 32, name);
    ++cases;
}

void TestImages()
{
    Accept("ordinary ELF", [](Bytes&) {});
    Accept("OSABI not unnecessarily restricted", [](Bytes& b) { b[7] = 3; });
    Accept("PT_NULL members ignored", [](Bytes& b) { PutSegment(b, 2, 0, UINT64_MAX, UINT64_MAX, 100, 1, 3); });
    Accept("zero-sized PT_LOAD ignored", [](Bytes& b) { PutSegment(b, 2, Load, 0, 0x1000000, 0, 0, 4096); });
    Accept("unaligned LOAD with congruent file offset", [](Bytes& b) {
        PutSegment(b, 0, Load, 1, 1, 767, 4095, 1);
    });
    Accept("TLS tbss not required to fit file image", [](Bytes& b) {
        PutSegment(b, 2, Tls, 640, 640, 16, 8192, 16);
    });
    Accept("TLS with no initialization image", [](Bytes& b) {
        PutSegment(b, 2, Tls, 0, 0, 0, 32, 0);
    });
    Accept("RELRO is allowed to include final page padding", [](Bytes& b) {
        PutSegment(b, 2, Relro, 512, 512, 256, 3584, 1);
    });
    Reject("short header", [](Bytes& b) { b.resize(63); }, "truncated ELF");
    Reject("bad magic", [](Bytes& b) { b[0] = 0; }, "identity");
    Reject("32-bit class", [](Bytes& b) { b[4] = 1; }, "identity");
    Reject("big endian", [](Bytes& b) { b[5] = 2; }, "identity");
    Reject("bad ident version", [](Bytes& b) { b[6] = 2; }, "identity");
    Reject("non-DYN", [](Bytes& b) { Put(b, 16, 2, 2); }, "identity");
    Reject("wrong machine", [](Bytes& b) { Put(b, 18, 62, 2); }, "identity");
    Reject("bad header version", [](Bytes& b) { Put(b, 20, 0, 4); }, "identity");
    Reject("undersized ELF header", [](Bytes& b) { Put(b, 52, 63, 2); }, "entry size");
    Reject("undersized program entry", [](Bytes& b) { Put(b, 54, 1, 2); }, "entry size");
    Reject("oversized program entry", [](Bytes& b) { Put(b, 54, 57, 2); }, "entry size");
    Reject("no program headers", [](Bytes& b) { Put(b, 56, 0, 2); }, "count");
    Reject("unsupported extended count", [](Bytes& b) { Put(b, 56, 0xffff, 2); }, "count");
    Reject("program table overlaps header", [](Bytes& b) { Put(b, 32, 1, 8); }, "outside file");
    Reject("program table truncated", [](Bytes& b) { Put(b, 32, 1000, 8); }, "outside file");
    Reject("program table offset wraps", [](Bytes& b) { Put(b, 32, UINT64_MAX - 4, 8); }, "outside file");
    Reject("LOAD exceeds memory", [](Bytes& b) { Put(b, 64 + 40, 16, 8); }, "larger than memory");
    Reject("truncated segment file", [](Bytes& b) { b.resize(767); }, "outside file");
    Reject("segment file offset wraps", [](Bytes& b) { Put(b, 64 + 8, UINT64_MAX - 4, 8); }, "outside file");
    Reject("segment virtual address wraps", [](Bytes& b) { Put(b, 64 + 16, UINT64_MAX - 4, 8); }, "virtual range overflow");
    Reject("page-rounding wraps", [](Bytes& b) {
        PutSegment(b, 2, Load, 0, UINT64_MAX - 4095, 0, 4095, 4096);
    }, "page-rounded");
    Reject("mapping cannot use pointer arithmetic", [](Bytes& b) {
        PutSegment(b, 2, Load, 0, (UINT64_C(1) << 63), 0, 4096, 4096);
    }, "mapping span");
    Reject("LOAD non-power alignment", [](Bytes& b) { Put(b, 64 + 48, 3, 8); }, "alignment");
    Reject("LOAD mismatched page offsets", [](Bytes& b) { Put(b, 64 + 8, 1, 8); }, "alignment");
    Reject("no nonempty LOAD", [](Bytes& b) { PutSegment(b, 0, Load, 0, 0, 0, 0, 1); }, "nonempty");
    Reject("no DYNAMIC", [](Bytes& b) { Put(b, 120, 0, 4); }, "no PT_DYNAMIC");
    Reject("duplicate DYNAMIC", [](Bytes& b) { PutSegment(b, 2, Dynamic, 512, 512, 32, 32, 8); }, "duplicate PT_DYNAMIC");
    Reject("partial dynamic entry", [](Bytes& b) { Put(b, 120 + 32, 31, 8); }, "partial entry");
    Reject("dynamic table absent in file image", [](Bytes& b) { Put(b, 120 + 16, 8000, 8); }, "not in a PT_LOAD");
    Reject("dynamic template mismatched file bytes", [](Bytes& b) { Put(b, 120 + 8, 513, 8); }, "not in a PT_LOAD");
    Reject("dynamic terminator missing", [](Bytes& b) { Put(b, 528, 1, 8); }, "DT_NULL");
    Reject("TLS truncated template", [](Bytes& b) { PutSegment(b, 2, Tls, 1020, 1020, 16, 32, 16); }, "outside file");
    Reject("TLS template outside mapped file", [](Bytes& b) { PutSegment(b, 2, Tls, 800, 800, 16, 32, 16); }, "not in a PT_LOAD");
    Reject("TLS invalid alignment", [](Bytes& b) { PutSegment(b, 2, Tls, 640, 640, 16, 32, 3); }, "PT_TLS alignment");
    Reject("TLS rounded allocation overflow", [](Bytes& b) { PutSegment(b, 2, Tls, 0, 0, 0, UINT64_MAX, 16); }, "PT_TLS alignment");
    Reject("TLS oversized alignment", [](Bytes& b) { PutSegment(b, 2, Tls, 0, 0, 0, 0, UINT64_C(1) << 63); }, "PT_TLS alignment");
    Reject("duplicate TLS", [](Bytes& b) {
        PutSegment(b, 2, Tls, 0, 0, 0, 16, 16); PutSegment(b, 3, Tls, 0, 0, 0, 16, 16);
    }, "PT_TLS alignment");
    Reject("RELRO outside reservation", [](Bytes& b) { PutSegment(b, 2, Relro, 0, 4096, 0, 16, 1); }, "RELRO outside");

    // 失败不得污染上次成功的计划；调用方不能从半填充输出误取映射大小。
    auto bytes = ValidImage(); Layout untouched{7, 11, 13}; const char* error = nullptr;
    Put(bytes, 120, 0, 4);
    Require(!ValidateProgramHeaders(bytes.data() + 64, 224, bytes.size(), 4096, untouched, error), "failure status");
    Require(untouched.loadBias == 7 && untouched.mapBytes == 11 && untouched.dynamicBytes == 13, "transactional output");
    Require(!ValidateProgramHeaders(bytes.data() + 64, 223, bytes.size(), 4096, untouched, error), "partial program buffer");
    Require(!ValidateProgramHeaders(bytes.data() + 64, 224, bytes.size(), 3, untouched, error), "invalid page geometry");
    cases += 3;

    // 非零 loadBias 不能被当作映射内偏移；RELRO 向前越界会在旧减法中发生下溢。
    bytes = ValidImage();
    PutSegment(bytes, 0, Load, 0, 8192, 768, 4096, 4096);
    PutSegment(bytes, 1, Dynamic, 512, 8704, 32, 32, 8);
    Layout shifted;
    Require(ValidateImage(bytes, shifted, error) && shifted.loadBias == 8192 && shifted.mapBytes == 4096,
            "nonzero loadBias remains supported");
    PutSegment(bytes, 2, Relro, 0, 4096, 0, 16, 1);
    Require(!ValidateImage(bytes, shifted, error) && std::strstr(error, "RELRO outside"), "RELRO before loadBias");
    cases += 2;
}

void TestReads()
{
    unsigned char buffer[8]{};
    std::size_t calls = 0;
    const auto shortReader = [&calls](unsigned char* target, std::size_t remaining, std::uint64_t offset) -> ReadAttempt {
        ++calls;
        if (calls == 1) return {-1, true};
        const std::size_t count = (std::min)(remaining, std::size_t(2));
        for (std::size_t index = 0; index < count; ++index) target[index] = static_cast<unsigned char>(offset + index);
        return {static_cast<std::int64_t>(count), false};
    };
    Require(ReadFully(shortReader, buffer, sizeof(buffer), 10) == ReadStatus::Ok, "short read + EINTR");
    Require(calls == 5 && buffer[0] == 10 && buffer[7] == 17, "short read preserves offset and content");
    Require(ReadFully([](unsigned char*, std::size_t, std::uint64_t) { return ReadAttempt{0, false}; },
                      buffer, 8, 0) == ReadStatus::EndOfFile, "EOF separated from errno");
    Require(ReadFully([](unsigned char*, std::size_t, std::uint64_t) { return ReadAttempt{-1, false}; },
                      buffer, 8, 0) == ReadStatus::IoError, "I/O error propagated");
    Require(ReadFully([](unsigned char*, std::size_t, std::uint64_t) { return ReadAttempt{9, false}; },
                      buffer, 8, 0) == ReadStatus::InvalidResult, "over-reported read rejected");
    calls = 0;
    Require(ReadFully(shortReader, buffer, 8, UINT64_MAX - 3) == ReadStatus::OffsetOverflow && calls == 0,
            "offset overflow rejected before I/O");
    Require(ReadFully(shortReader, buffer, 0, 0) == ReadStatus::Ok && calls == 0, "empty read does no I/O");
    const auto truncatedReader = [&calls](unsigned char*, std::size_t, std::uint64_t) {
        return ReadAttempt{++calls == 1 ? 2 : 0, false};
    };
    Require(ReadFully(truncatedReader, buffer, 8, 0) == ReadStatus::EndOfFile && calls == 2,
            "partial data followed by EOF is not success");
    cases += 7;
}
} // namespace

int main(int argc, char** argv)
{
    if (argc == 2 && std::string(argv[1]) == "--stdin") {
#ifdef _WIN32
        // Windows 文本 stdin 会把 CRLF 和 0x1a 当控制字符，必须保留 ELF 原始字节。
        _setmode(_fileno(stdin), _O_BINARY);
#endif
        const Bytes bytes(std::istreambuf_iterator<char>(std::cin), {});
        Layout layout; const char* error = nullptr;
        if (!ValidateImage(bytes, layout, error)) { std::cerr << (error ? error : "invalid ELF") << '\n'; return 1; }
        std::cout << "PASS ELF input bytes=" << bytes.size() << " map=" << layout.mapBytes << '\n';
        return 0;
    }
    TestImages(); TestReads();
    std::cout << "PASS " << cases << " ELF input/range/read cases\n";
}
