/**
 * 从实际选中libjvm的只读文件映像识别原生临时根合同；不调用未创建VM中的函数。
 * 缺marker保持旧包默认参数；自称有marker却范围/权限/版本不对时拒绝，不能降级成旧包。
 * 调用方复用JDK安装槽租约，并在冷启动只读取一次；marker不是目标Attach资格证明。
 */
#pragma once
#include "elf_input_validation.h"
#include <cstring>

namespace amcl::jvm {
enum class NativeTempContract { Legacy, StartupTmpdirV1, Invalid };
constexpr char NativeTempSection[] = ".amcl.nativetemp";
constexpr char NativeTempMarker[] = "AMCL_OHOS_NATIVE_TMPDIR_V1";

inline NativeTempContract ReadNativeTempContract(const unsigned char* file, std::size_t size,
                                                const char*& error) {
    using namespace amcl::elfinput;
    Header header;
    if (!ValidateHeader(file, size, size, header, error)) return NativeTempContract::Invalid;
    Layout layout;
    const auto* programs = file + header.programOffset;
    if (!ValidateProgramHeaders(programs, header.programBytes, size, 4096, layout, error))
        return NativeTempContract::Invalid;
    const std::uint64_t sectionOffset = ReadLittle(file + 40, 8);
    const auto sectionBytes = ReadLittle(file + 58, 2);
    auto count = ReadLittle(file + 60, 2), stringIndex = ReadLittle(file + 62, 2);
    // 无节表的旧strip映像仍按旧包处理，不能仅因没发布新合同就阻断现有运行时。
    if (count == 0 && sectionOffset == 0) return NativeTempContract::Legacy;
    // ELF扩展节编号仅从有界的SHT_NULL第0项读取数量/名字表索引，不遍历额外文件。
    if ((count == 0 || stringIndex == 0xffff) && sectionBytes == 64 && InRange(sectionOffset, 64, size)) {
        const auto* zero = file + sectionOffset;
        if (ReadLittle(zero + 4, 4) != 0) {
            error = "invalid native temp extended section zero"; return NativeTempContract::Invalid;
        }
        if (count == 0) count = ReadLittle(zero + 32, 8);
        if (stringIndex == 0xffff) stringIndex = ReadLittle(zero + 40, 4);
    }
    if (sectionBytes != 64 || count == 0 || count > size / sectionBytes || stringIndex >= count ||
        !InRange(sectionOffset, count * sectionBytes, size)) {
        error = "invalid native temp section table"; return NativeTempContract::Invalid;
    }
    // SHN_UNDEF表示合法地不提供节名表。旧loader不需要这些元数据，不能因没有新合同
    // 的名字索引就拒绝合法旧import；只能保守保留旧自动参数，不能推测marker存在。
    if (stringIndex == 0) return NativeTempContract::Legacy;
    const auto* strings = file + sectionOffset + stringIndex * sectionBytes;
    const auto namesOffset = ReadLittle(strings + 24, 8), namesSize = ReadLittle(strings + 32, 8);
    if (ReadLittle(strings + 4, 4) != 3 || namesSize == 0 || !InRange(namesOffset, namesSize, size)) {
        error = "invalid native temp section names"; return NativeTempContract::Invalid;
    }
    const unsigned char* found = nullptr;
    for (std::uint64_t index = 0; index < count; ++index) {
        const auto* section = file + sectionOffset + index * sectionBytes;
        const auto name = ReadLittle(section, 4);
        if (!InRange(name, 1, namesSize) || !std::memchr(file + namesOffset + name, 0, namesSize - name)) {
            error = "unterminated native temp section name"; return NativeTempContract::Invalid;
        }
        if (std::strcmp(reinterpret_cast<const char*>(file + namesOffset + name), NativeTempSection) != 0) continue;
        if (found) { error = "duplicate native temp marker"; return NativeTempContract::Invalid; }
        found = section;
    }
    if (!found) return NativeTempContract::Legacy;
    const auto flags = ReadLittle(found + 8, 8), address = ReadLittle(found + 16, 8);
    const auto offset = ReadLittle(found + 24, 8), bytes = ReadLittle(found + 32, 8);
    // GNU_RETAIN仅用于防止GC丢弃本合同；不能让write/execute或其它未知属性成为豁免。
    if (ReadLittle(found + 4, 4) != 1 || (flags & 2) == 0 || (flags & ~(UINT64_C(2) | UINT64_C(0x200000))) ||
        bytes != sizeof(NativeTempMarker) || !InRange(offset, bytes, size) ||
        std::memcmp(file + offset, NativeTempMarker, sizeof(NativeTempMarker)) != 0) {
        error = "unsupported or non-readonly native temp marker"; return NativeTempContract::Invalid;
    }
    for (std::size_t index = 0; index < header.programCount; ++index) {
        const auto* raw = programs + index * ProgramHeaderBytes;
        const auto load = ReadSegment(raw);
        const auto permissions = ReadLittle(raw + 4, 4);
        if (load.type != Load || !(permissions & 4) || (permissions & 2) || address < load.address) continue;
        const auto delta = address - load.address;
        if (InRange(delta, bytes, load.fileBytes) && InRange(load.offset, delta, size) &&
            load.offset + delta == offset) return NativeTempContract::StartupTmpdirV1;
    }
    error = "native temp marker is not in an exact readonly PT_LOAD file range";
    return NativeTempContract::Invalid;
}

// 只过滤宿主自动默认值；调用方随后追加用户显式参数，保持原有last-value-wins合同。
inline bool OmitLegacyTempDefault(NativeTempContract contract, const char* option) {
    return contract == NativeTempContract::StartupTmpdirV1 && option &&
        (std::strcmp(option, "-XX:-UsePerfData") == 0 ||
         std::strcmp(option, "-XX:+DisableAttachMechanism") == 0);
}
}
