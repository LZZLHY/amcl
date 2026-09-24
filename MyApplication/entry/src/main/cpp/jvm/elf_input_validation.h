/**
 * ELF 输入完整性纯核心：仅校验装载前的文件头、程序头、段范围与精确读取协议。
 *
 * 不依赖 OHOS、系统 elf.h 或映射地址，因此产品和宿主测试执行同一份判断。
 * 所有字段按 ELF64 little-endian 字节读取，不把未验证输入强转成宿主结构体。
 * 本阶段不验证动态表指向的 hash/symbol/relocation 内容，不提供完整恶意 ELF 沙箱。
 * 函数不修改全局状态；输出仅在校验成功后提交，错误文本均为静态生命周期。
 */
#ifndef AMCL_ELF_INPUT_VALIDATION_H
#define AMCL_ELF_INPUT_VALIDATION_H

#include <cstddef>
#include <cstdint>
#include <limits>

namespace amcl::elfinput {

constexpr std::size_t HeaderBytes = 64;
constexpr std::size_t ProgramHeaderBytes = 56;
constexpr std::uint32_t Load = 1;
constexpr std::uint32_t Dynamic = 2;
constexpr std::uint32_t Tls = 7;
constexpr std::uint32_t Relro = 0x6474e552;

// 调用方只在检查了相应缓冲区长度后以 1～8 的固定 count 调用；逐字节读允许非对齐输入。
inline std::uint64_t ReadLittle(const unsigned char* bytes, std::size_t count)
{
    std::uint64_t result = 0;
    for (std::size_t index = 0; index < count; ++index) {
        result |= static_cast<std::uint64_t>(bytes[index]) << (index * 8);
    }
    return result;
}

// 使用减法检查半开区间，避免先计算 offset + length 引发无符号回绕。
inline bool InRange(std::uint64_t offset, std::uint64_t length, std::uint64_t limit)
{
    return offset <= limit && length <= limit - offset;
}

inline bool IsPowerOfTwo(std::uint64_t value)
{
    return value != 0 && (value & (value - 1)) == 0;
}

// 页舍入也必须受检查：调用方不可用已溢出的 end 再进行 PAGE_ALIGN。
inline bool AlignUp(std::uint64_t value, std::uint64_t alignment, std::uint64_t& result)
{
    if (!IsPowerOfTwo(alignment) || value > UINT64_MAX - (alignment - 1)) return false;
    result = (value + alignment - 1) & ~(alignment - 1);
    return true;
}

struct Header {
    std::uint64_t programOffset = 0;
    std::size_t programBytes = 0;
    std::size_t programCount = 0;
};

/**
 * 校验 AMCL 当前支持的 ELF64/AArch64 little-endian ET_DYN 固定布局。
 * PN_XNUM 需要另读 section[0]，现有 loader 不支持；在此明确拒绝而非误读为 65535 项。
 * 不限定 OSABI、节表、入口地址，避免把未使用的元数据变成新的兼容性门槛。
 */
inline bool ValidateHeader(const unsigned char* bytes, std::size_t available,
                          std::uint64_t fileBytes, Header& output, const char*& error)
{
    error = nullptr;
    if (!bytes || available < HeaderBytes || fileBytes < HeaderBytes) {
        error = "truncated ELF header"; return false;
    }
    if (bytes[0] != 0x7f || bytes[1] != 'E' || bytes[2] != 'L' || bytes[3] != 'F' ||
        bytes[4] != 2 || bytes[5] != 1 || bytes[6] != 1 ||
        ReadLittle(bytes + 16, 2) != 3 || ReadLittle(bytes + 18, 2) != 183 ||
        ReadLittle(bytes + 20, 4) != 1) {
        error = "unsupported ELF identity (requires ELF64 LE AArch64 ET_DYN version 1)"; return false;
    }
    if (ReadLittle(bytes + 52, 2) != HeaderBytes ||
        ReadLittle(bytes + 54, 2) != ProgramHeaderBytes) {
        error = "invalid ELF/program header entry size"; return false;
    }
    Header checked;
    checked.programCount = static_cast<std::size_t>(ReadLittle(bytes + 56, 2));
    if (checked.programCount == 0 || checked.programCount == 0xffff) {
        error = "empty or unsupported extended program header count"; return false;
    }
    checked.programOffset = ReadLittle(bytes + 32, 8);
    checked.programBytes = checked.programCount * ProgramHeaderBytes;
    if (checked.programOffset < HeaderBytes ||
        !InRange(checked.programOffset, checked.programBytes, fileBytes)) {
        error = "program header table outside file"; return false;
    }
    output = checked;
    return true;
}

struct Segment {
    std::uint32_t type;
    std::uint64_t offset;
    std::uint64_t address;
    std::uint64_t fileBytes;
    std::uint64_t memoryBytes;
    std::uint64_t alignment;
};

// 程序头缓冲区经 ValidateHeader 定长后才调用；不依赖 MSVC 与 OHOS 结构体布局相同。
inline Segment ReadSegment(const unsigned char* bytes)
{
    return {static_cast<std::uint32_t>(ReadLittle(bytes, 4)), ReadLittle(bytes + 8, 8),
        ReadLittle(bytes + 16, 8), ReadLittle(bytes + 32, 8), ReadLittle(bytes + 40, 8),
        ReadLittle(bytes + 48, 8)};
}

struct Layout {
    std::uint64_t loadBias = 0;
    std::uint64_t mapBytes = 0;
    std::uint64_t dynamicBytes = 0;
};

/**
 * 元数据模板必须确实由某个 PT_LOAD 的文件字节装入，不能落在预留空洞或 BSS 中。
 * 比较相同虚拟地址到文件偏移的映射，防止模板声明指向另一份未装载字节。
 * TLS 的 tbss 不必包含在 PT_LOAD 文件区间内，因此这里只检查非零初始化模板。
 */
inline bool HasFileImage(const unsigned char* headers, std::size_t count, const Segment& value)
{
    if (value.fileBytes == 0) return true;
    for (std::size_t index = 0; index < count; ++index) {
        const Segment load = ReadSegment(headers + index * ProgramHeaderBytes);
        if (load.type != Load || value.address < load.address) continue;
        const std::uint64_t delta = value.address - load.address;
        if (InRange(delta, value.fileBytes, load.fileBytes) &&
            InRange(load.offset, delta, UINT64_MAX) && load.offset + delta == value.offset) return true;
    }
    return false;
}

/**
 * 在 mmap/分配 TLS 前完成段级范围验证，拒绝会溢出长度或使拷贝超出映射的输入。
 * 空 PT_LOAD 合法但不参与映射；PT_NULL 和未消费的扩展类型不在本批擅自解释。
 * 不改变段重叠/页权限策略、符号来源、TLS 分配实现或构造器调用顺序。
 */
inline bool ValidateProgramHeaders(const unsigned char* headers, std::size_t bytes,
                                   std::uint64_t fileBytes, std::uint64_t pageBytes,
                                   Layout& output, const char*& error)
{
    error = nullptr;
    if (!headers || bytes == 0 || bytes % ProgramHeaderBytes != 0 || !IsPowerOfTwo(pageBytes)) {
        error = "invalid program header buffer or page size"; return false;
    }
    const std::size_t count = bytes / ProgramHeaderBytes;
    const std::uint64_t pointerLimit = static_cast<std::uint64_t>((std::numeric_limits<std::ptrdiff_t>::max)());
    std::uint64_t minimum = UINT64_MAX, maximum = 0;
    std::size_t dynamicCount = 0, tlsCount = 0;
    Layout checked;
    for (std::size_t index = 0; index < count; ++index) {
        const Segment segment = ReadSegment(headers + index * ProgramHeaderBytes);
        if (segment.type != Load && segment.type != Dynamic && segment.type != Tls && segment.type != Relro) continue;
        if (segment.fileBytes > segment.memoryBytes ||
            (segment.fileBytes != 0 && !InRange(segment.offset, segment.fileBytes, fileBytes))) {
            error = "segment file range outside file or larger than memory size"; return false;
        }
        if (!InRange(segment.address, segment.memoryBytes, UINT64_MAX)) {
            error = "segment virtual range overflow"; return false;
        }
        if (segment.type == Load) {
            if ((segment.alignment > 1 && (!IsPowerOfTwo(segment.alignment) ||
                    segment.address % segment.alignment != segment.offset % segment.alignment)) ||
                segment.address % pageBytes != segment.offset % pageBytes) {
                error = "invalid PT_LOAD alignment"; return false;
            }
            if (segment.memoryBytes == 0) continue;
            if (segment.address < minimum) minimum = segment.address;
            const std::uint64_t end = segment.address + segment.memoryBytes;
            if (end > maximum) maximum = end;
        } else if (segment.type == Dynamic) {
            if (++dynamicCount != 1 || segment.fileBytes < 16 || segment.fileBytes % 16 != 0) {
                error = "missing entries, partial entry or duplicate PT_DYNAMIC"; return false;
            }
            checked.dynamicBytes = segment.fileBytes;
        } else if (segment.type == Tls) {
            const std::uint64_t alignment = segment.alignment == 0 ? 16 : segment.alignment;
            std::uint64_t allocationBytes = 0;
            if (++tlsCount != 1 || !AlignUp(segment.memoryBytes, alignment, allocationBytes) ||
                alignment > pointerLimit || allocationBytes > pointerLimit) {
                error = "invalid PT_TLS alignment, allocation size or duplicate segment"; return false;
            }
        }
    }
    if (minimum == UINT64_MAX || !AlignUp(maximum, pageBytes, maximum)) {
        error = "no nonempty PT_LOAD or page-rounded virtual range overflow"; return false;
    }
    checked.loadBias = minimum & ~(pageBytes - 1);
    checked.mapBytes = maximum - checked.loadBias;
    if (checked.mapBytes == 0 || checked.mapBytes > pointerLimit) {
        error = "unsupported mapping span"; return false;
    }
    if (dynamicCount == 0) { error = "no PT_DYNAMIC"; return false; }
    for (std::size_t index = 0; index < count; ++index) {
        const Segment segment = ReadSegment(headers + index * ProgramHeaderBytes);
        if ((segment.type == Dynamic || segment.type == Tls) && !HasFileImage(headers, count, segment)) {
            error = "PT_DYNAMIC/PT_TLS template is not in a PT_LOAD file image"; return false;
        }
        if (segment.type == Relro && segment.memoryBytes != 0 &&
            (segment.address < checked.loadBias ||
             !InRange(segment.address - checked.loadBias, segment.memoryBytes, checked.mapBytes))) {
            error = "PT_GNU_RELRO outside reserved mapping"; return false;
        }
    }
    output = checked;
    return true;
}

// 在已验证的 PT_DYNAMIC 文件长度内查找 DT_NULL；后续旧迭代代码不得读取到段外。
inline bool HasDynamicTerminator(const unsigned char* bytes, std::size_t length)
{
    if (!bytes || length < 16 || length % 16 != 0) return false;
    for (std::size_t offset = 0; offset < length; offset += 16) {
        if (ReadLittle(bytes + offset, 8) == 0) return true;
    }
    return false;
}

enum class ReadStatus { Ok, EndOfFile, IoError, InvalidResult, OffsetOverflow };
struct ReadAttempt { std::int64_t count; bool interrupted; };

/**
 * 可注入 pread 的精确读取循环：短读累积，EINTR 重试，EOF 与 I/O 错误分别返回。
 * reader 仅写入给定剩余缓冲区，返回非负字节数或负值及是否 EINTR；不得超额返回。
 * 实际偏移须在有符号 64 位 off_t 范围内，确保每次系统调用前转换均有定义。
 */
template <typename Reader>
ReadStatus ReadFully(Reader&& reader, unsigned char* destination, std::size_t bytes, std::uint64_t offset)
{
    if (!InRange(offset, bytes, static_cast<std::uint64_t>((std::numeric_limits<std::int64_t>::max)()))) {
        return ReadStatus::OffsetOverflow;
    }
    std::size_t total = 0;
    while (total < bytes) {
        const ReadAttempt attempt = reader(destination + total, bytes - total, offset + total);
        if (attempt.count < 0) {
            if (attempt.interrupted) continue;
            return ReadStatus::IoError;
        }
        if (attempt.count == 0) return ReadStatus::EndOfFile;
        if (static_cast<std::uint64_t>(attempt.count) > bytes - total) return ReadStatus::InvalidResult;
        total += static_cast<std::size_t>(attempt.count);
    }
    return ReadStatus::Ok;
}

} // namespace amcl::elfinput
#endif
