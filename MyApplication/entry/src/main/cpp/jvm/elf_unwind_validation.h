/**
 * 自加载 .eh_frame 的有界结构验收。所有读取先验证长度和已映射范围，避免把损坏的
 * 长度、CIE 回指、LEB、指针编码或 CFI 操作数直接交给真实 unwinder 的无界读取。
 * 本模块不执行代码、不登记展开表，也不解释运行时栈上的 DWARF expression 结果。
 */
#ifndef AMCL_ELF_UNWIND_VALIDATION_H
#define AMCL_ELF_UNWIND_VALIDATION_H
#include <cstdint>
#include <cstring>
#include <limits>
#include <unordered_map>
#include <vector>

namespace amcl::unwindinput {
using Address = uintptr_t;

struct Memory {
    void* context;
    bool (*readable)(void*, Address, size_t);
    bool (*executable)(void*, Address, size_t);
    bool (*ownedExecutable)(void*, Address, size_t); // FDE PC 必须属于本映像，personality 可以来自依赖。
};

struct Frame {
    Address record;
    Address begin;
    Address end;
    Address personality;
    Address lsda;
};

/** 单条记录的读取游标；失败保持 failed，所有后续方法立即返回，不能越界继续解释。 */
class Cursor {
public:
    Cursor(const Memory& memory, Address begin, Address end)
        : at(begin), limit(end), memory_(memory), checkedBegin_(begin), checkedEnd_(end) {
        // 记录内存由 loader 的装载事务保持稳定。一次验证整段，之后只做整数边界检查，
        // 不为数万 FDE 的每个字节重复遍历全部 DSO 或段表。
        failed = end < begin || !memory_.readable(memory_.context, begin, end - begin);
    }
    template<class T> T read() {
        T value{};
        if (failed || at < checkedBegin_ || limit > checkedEnd_ || at > limit || sizeof(T) > limit - at) {
            failed = true; return value;
        }
        std::memcpy(&value, reinterpret_cast<const void*>(at), sizeof(T));
        at += sizeof(T);
        return value;
    }
    bool skip(size_t bytes) {
        if (failed || at < checkedBegin_ || limit > checkedEnd_ || at > limit || bytes > limit - at) {
            failed = true; return false;
        }
        at += bytes; return true;
    }
    uint64_t uleb() {
        uint64_t result = 0;
        for (unsigned index = 0; index < 10; ++index) {
            const uint8_t byte = read<uint8_t>();
            if (failed || (index == 9 && (byte & 0xfe))) { failed = true; return 0; }
            result |= uint64_t(byte & 0x7f) << (index * 7);
            if (!(byte & 0x80)) return result;
        }
        failed = true; return 0;
    }
    int64_t sleb() {
        uint64_t result = 0;
        for (unsigned index = 0; index < 10; ++index) {
            const uint8_t byte = read<uint8_t>();
            if (failed || (index == 9 && byte != 0 && byte != 0x7f)) { failed = true; return 0; }
            result |= uint64_t(byte & 0x7f) << (index * 7);
            if (!(byte & 0x80)) {
                const unsigned bits = (index + 1) * 7;
                if ((byte & 0x40) && bits < 64) result |= (~uint64_t(0)) << bits;
                int64_t signedResult;
                std::memcpy(&signedResult, &result, sizeof(result));
                return signedResult;
            }
        }
        failed = true; return 0;
    }
    /** 只支持所选真实 LLVM 15 能解释的编码；非法相对基址或间接读取必须失败。 */
    Address encoded(uint8_t encoding, Address dataBase = 0, bool nullable = false) {
        const Address field = at;
        uint64_t raw = 0;
        bool isSigned = false;
        switch (encoding & 15) {
        case 0: raw = read<uint64_t>(); break;
        case 1: raw = uleb(); break;
        case 2: raw = read<uint16_t>(); break;
        case 3: raw = read<uint32_t>(); break;
        case 4: raw = read<uint64_t>(); break;
        case 9: raw = uint64_t(sleb()); isSigned = true; break;
        case 10: raw = uint64_t(int64_t(read<int16_t>())); isSigned = true; break;
        case 11: raw = uint64_t(int64_t(read<int32_t>())); isSigned = true; break;
        case 12: raw = uint64_t(read<int64_t>()); isSigned = true; break;
        default: failed = true; return 0;
        }
        if (failed || (nullable && raw == 0)) return 0;
        Address base = 0;
        switch (encoding & 0x70) {
        case 0: break;
        case 0x10: base = field; break;
        case 0x30: if (!dataBase) { failed = true; return 0; } base = dataBase; break;
        default: failed = true; return 0;
        }
        Address value = 0;
        if (isSigned && (raw >> 63)) {
            const uint64_t magnitude = 0 - raw;
            if (base < magnitude) { failed = true; return 0; }
            value = base - magnitude;
        } else {
            if (raw > UINTPTR_MAX - base) { failed = true; return 0; }
            value = base + raw;
        }
        if (encoding & 0x80) {
            if (!memory_.readable(memory_.context, value, sizeof(Address))) { failed = true; return 0; }
            std::memcpy(&value, reinterpret_cast<const void*>(value), sizeof(value));
        }
        return value;
    }
    Address at;
    Address limit;
    bool failed = false;
private:
    const Memory& memory_;
    Address checkedBegin_, checkedEnd_;
};

struct Cie {
    uint8_t pointerEncoding = 0;
    uint8_t lsdaEncoding = 0xff;
    bool augmented = false;
    Address personality = 0;
    Address instructions = 0;
    Address end = 0;
};

/** 验证 CFI 操作数与内嵌 expression 块边界；表达式的栈值/地址由真实 unwinder 执行。 */
inline bool instructions(Cursor& input, unsigned& remembered, uint8_t pointerEncoding) {
    auto reg = [&]() { const auto value = input.uleb(); if (value > 95) input.failed = true; };
    auto expression = [&]() { const auto length = input.uleb(); input.skip(length); };
    while (!input.failed && input.at < input.limit) {
        const uint8_t opcode = input.read<uint8_t>();
        if (opcode & 0xc0) {
            if ((opcode & 0xc0) == 0x80) input.uleb();
            continue;
        }
        switch (opcode) {
        case 0: break;
        case 1: input.encoded(pointerEncoding); break;
        case 2: input.read<uint8_t>(); break;
        case 3: input.read<uint16_t>(); break;
        case 4: input.read<uint32_t>(); break;
        case 5: reg(); input.uleb(); break;
        case 6: case 7: case 8: case 13: reg(); break;
        case 9: reg(); reg(); break;
        case 10: if (remembered == UINT32_MAX) input.failed = true; else ++remembered; break;
        case 11: if (!remembered) input.failed = true; else --remembered; break;
        case 12: reg(); input.uleb(); break;
        case 14: case 0x2e: input.uleb(); break;
        case 15: expression(); break;
        case 16: case 22: reg(); expression(); break;
        case 17: case 18: case 21: reg(); input.sleb(); break;
        case 19: input.sleb(); break;
        case 20: case 0x2f: reg(); input.uleb(); break;
        case 0x2d: break; // AArch64 的返回地址签名状态切换，无额外操作数。
        default: input.failed = true; break;
        }
    }
    return !input.failed;
}

/** 同一真实记录内的 DWARF32/64 长度；零长度终止另由调用方识别。 */
inline bool record(const Memory& memory, Address begin, Address sectionEnd, Cursor& payload) {
    Cursor header(memory, begin, sectionEnd);
    uint64_t length = header.read<uint32_t>();
    if (length == UINT32_MAX) length = header.read<uint64_t>();
    if (header.failed || length < 4 || length > sectionEnd - header.at ||
        !memory.readable(memory.context, header.at, length)) return false;
    payload.at = header.at;
    payload.limit = header.at + length;
    return true;
}

inline bool parseCie(const Memory& memory, Cursor& input, Cie& cie) {
    const uint8_t version = input.read<uint8_t>();
    if (version != 1 && version != 3) return false;
    std::vector<uint8_t> augmentation;
    for (uint8_t byte = input.read<uint8_t>(); byte && !input.failed; byte = input.read<uint8_t>())
        augmentation.push_back(byte);
    const uint64_t codeAlign = input.uleb();
    const int64_t dataAlign = input.sleb();
    const uint64_t returnRegister = version == 1 ? input.read<uint8_t>() : input.uleb();
    if (input.failed || !codeAlign || codeAlign > UINT32_MAX || dataAlign < INT32_MIN ||
        dataAlign > INT32_MAX || returnRegister > 95) return false;
    if (!augmentation.empty()) {
        if (augmentation[0] != 'z') return false;
        cie.augmented = true;
        const uint64_t size = input.uleb();
        if (input.failed || size > input.limit - input.at) return false;
        Cursor data(memory, input.at, input.at + size);
        for (size_t i = 1; i < augmentation.size() && !data.failed; ++i) {
            switch (augmentation[i]) {
            case 'R': cie.pointerEncoding = data.read<uint8_t>(); break;
            case 'L': cie.lsdaEncoding = data.read<uint8_t>(); break;
            case 'P': {
                const auto encoding = data.read<uint8_t>();
                cie.personality = data.encoded(encoding);
                if (!cie.personality || !memory.executable(memory.context, cie.personality, 1)) data.failed = true;
                break;
            }
            case 'S': case 'B': break;
            default: data.failed = true; break;
            }
        }
        if (data.failed || data.at != data.limit) return false;
        input.at = data.limit;
    }
    cie.instructions = input.at;
    cie.end = input.limit;
    return !input.failed;
}

/** 验证完整有界 section，输出供后续 EH header 对照与真实 unwinder 查询的 PC 范围。 */
inline bool validate(const Memory& memory, Address begin, size_t bytes, std::vector<Frame>& frames,
                     const char*& error) {
    auto fail = [&](const char* reason) { error = reason; return false; };
    if (bytes < 4 || bytes > UINTPTR_MAX - begin || !memory.readable(memory.context, begin, bytes))
        return fail("EH section outside readable image");
    const Address end = begin + bytes;
    std::unordered_map<Address, Cie> cies;
    Address current = begin;
    while (current < end) {
        Cursor marker(memory, current, end);
        const auto length = marker.read<uint32_t>();
        if (marker.failed) return fail("truncated EH record length");
        if (!length) {
            // 链接器可以在末尾保留零对齐填充；非零后缀不能被终止项悄悄隐藏。
            while (marker.at < end && !marker.failed) if (marker.read<uint8_t>() != 0) return fail("data after EH terminator");
            return !marker.failed;
        }
        Cursor data(memory, current, end);
        if (!record(memory, current, end, data)) return fail("invalid EH record extent");
        const Address idAddress = data.at;
        const uint32_t id = data.read<uint32_t>();
        if (!id) {
            Cie cie;
            if (!parseCie(memory, data, cie)) return fail("invalid CIE fields or augmentation");
            // CIE 状态指令随后同每个引用它的 FDE 一起验证，保持 remember/restore 的整体顺序。
            cies.emplace(current, cie);
        } else {
            if (id > idAddress - begin) return fail("CIE reference before section");
            const auto found = cies.find(idAddress - id);
            if (found == cies.end()) return fail("FDE does not reference an earlier CIE");
            const Cie& cie = found->second;
            const Address pc = data.encoded(cie.pointerEncoding);
            const Address range = data.encoded(cie.pointerEncoding & 15);
            if (data.failed || range > UINTPTR_MAX - pc ||
                (range && !memory.ownedExecutable(memory.context, pc, range)))
                return fail("invalid FDE executable range");
            Address lsda = 0;
            if (cie.augmented) {
                const uint64_t size = data.uleb();
                if (data.failed || size > data.limit - data.at) return fail("invalid FDE augmentation length");
                Cursor augmentation(memory, data.at, data.at + size);
                if (cie.lsdaEncoding != 0xff) lsda = augmentation.encoded(cie.lsdaEncoding, 0, true);
                if (augmentation.failed || (lsda && !memory.readable(memory.context, lsda, 1)))
                    return fail("invalid FDE LSDA pointer");
                data.at = augmentation.limit;
            }
            unsigned remembered = 0;
            Cursor initial(memory, cie.instructions, cie.end);
            if (!instructions(initial, remembered, cie.pointerEncoding) || !instructions(data, remembered, cie.pointerEncoding))
                return fail("invalid CFI operand or state boundary");
            frames.push_back({current, pc, pc + range, cie.personality, lsda});
        }
        current = data.limit;
    }
    return true;
}
}
#endif
