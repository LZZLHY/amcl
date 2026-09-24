/**
 * jni_mutf8.h — 标准 UTF-8 → JNI Modified UTF-8（CESU-8 变体）转换。
 *
 * 为什么需要（2026-08-27 加载链审查修复批次）：
 *   JNI 的 NewStringUTF 要求 **Modified UTF-8**，不是标准 UTF-8。两者对
 *   BMP 字符（含全部中文）编码一致，但有两处分歧：
 *     1. 增补平面字符（U+10000+，如 emoji）：标准 UTF-8 用 4 字节；
 *        MUTF-8 要求先拆 UTF-16 代理对、再对每个代理各用 3 字节编码（6 字节）。
 *     2. U+0000：MUTF-8 用 0xC0 0x80（避免串内出现 NUL）。
 *   把标准 UTF-8（含 4 字节序列）直接喂给 NewStringUTF 是未定义行为 ——
 *   HotSpot debug 构建直接 abort，release 构建产出损坏字符串。
 *   离线用户名 / 版本目录名是用户自由输入，完全可能带 emoji，
 *   所以所有承载用户内容的 NewStringUTF 调用点都必须先过本转换。
 *
 * 纯函数、无 JNI/平台依赖（host 测试：tests/host/jni_mutf8_test.cpp）。
 * 非法 UTF-8 字节不透传（那对 NewStringUTF 同样是 UB），逐字节替换为 '?'。
 */
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace amcl {

/**
 * 将 JNI GetStringChars 借出的 UTF-16 码元转换为标准 UTF-8，供 native 路径快照比较。
 * GetStringUTFChars 返回的是 Modified UTF-8，增补字符会变成两个三字节代理，不能直接
 * 与 ArkTS/NAPI 的标准 UTF-8 比较。模板只接收两个字节的码元，兼容 jchar 与 char16_t。
 * 完整代理对合成一个码点；孤立代理或空指针配非零长度返回 false，且不修改输出，避免
 * 以替换字符掩盖被修改的 Java 属性。嵌入 NUL 保留为字节零，比较仍使用完整 string 长度。
 * 输入归调用者所有；本函数不取得 JNI 引用，调用后仍须 ReleaseStringChars。
 */
template<class CodeUnit>
inline bool utf16ToUtf8(const CodeUnit* input, std::size_t length, std::string& output) {
    static_assert(sizeof(CodeUnit) == 2, "UTF-16 requires two-byte code units");
    if (!input && length != 0) return false;
    std::string converted;
    converted.reserve(length);
    for (std::size_t index = 0; index < length; ++index) {
        std::uint32_t codepoint = static_cast<std::uint16_t>(input[index]);
        if (codepoint >= 0xD800U && codepoint <= 0xDBFFU) {
            if (index + 1 == length) return false;
            const auto low = static_cast<std::uint16_t>(input[++index]);
            if (low < 0xDC00U || low > 0xDFFFU) return false;
            codepoint = 0x10000U + ((codepoint - 0xD800U) << 10) + (low - 0xDC00U);
        } else if (codepoint >= 0xDC00U && codepoint <= 0xDFFFU) {
            return false;
        }
        if (codepoint < 0x80U) {
            converted += static_cast<char>(codepoint);
        } else if (codepoint < 0x800U) {
            converted += static_cast<char>(0xC0U | (codepoint >> 6));
            converted += static_cast<char>(0x80U | (codepoint & 0x3FU));
        } else if (codepoint < 0x10000U) {
            converted += static_cast<char>(0xE0U | (codepoint >> 12));
            converted += static_cast<char>(0x80U | ((codepoint >> 6) & 0x3FU));
            converted += static_cast<char>(0x80U | (codepoint & 0x3FU));
        } else {
            converted += static_cast<char>(0xF0U | (codepoint >> 18));
            converted += static_cast<char>(0x80U | ((codepoint >> 12) & 0x3FU));
            converted += static_cast<char>(0x80U | ((codepoint >> 6) & 0x3FU));
            converted += static_cast<char>(0x80U | (codepoint & 0x3FU));
        }
    }
    output.swap(converted);
    return true;
}

inline std::string toModifiedUtf8(const std::string& in) {
    std::string out;
    out.reserve(in.size() + 8);
    const unsigned char* s = reinterpret_cast<const unsigned char*>(in.data());
    const std::size_t n = in.size();
    std::size_t i = 0;
    while (i < n) {
        const unsigned char b0 = s[i];
        const bool cont1 = (i + 1 < n) && ((s[i + 1] & 0xC0U) == 0x80U);
        const bool cont2 = (i + 2 < n) && ((s[i + 2] & 0xC0U) == 0x80U);
        const bool cont3 = (i + 3 < n) && ((s[i + 3] & 0xC0U) == 0x80U);
        if (b0 < 0x80U) {
            if (b0 == 0U) {
                out += static_cast<char>(0xC0);
                out += static_cast<char>(0x80);
            } else {
                out += static_cast<char>(b0);
            }
            i += 1;
        } else if ((b0 & 0xE0U) == 0xC0U && cont1) {
            // 2 字节序列（U+0080..U+07FF）：MUTF-8 同形，原样透传。
            out.append(reinterpret_cast<const char*>(s + i), 2);
            i += 2;
        } else if ((b0 & 0xF0U) == 0xE0U && cont1 && cont2) {
            // 3 字节序列（BMP，含中文）：MUTF-8 同形，原样透传。
            out.append(reinterpret_cast<const char*>(s + i), 3);
            i += 3;
        } else if ((b0 & 0xF8U) == 0xF0U && cont1 && cont2 && cont3) {
            // 4 字节序列（增补平面）：拆 UTF-16 代理对，各按 3 字节形态编码。
            const std::uint32_t cp = (static_cast<std::uint32_t>(b0 & 0x07U) << 18)
                                   | (static_cast<std::uint32_t>(s[i + 1] & 0x3FU) << 12)
                                   | (static_cast<std::uint32_t>(s[i + 2] & 0x3FU) << 6)
                                   | static_cast<std::uint32_t>(s[i + 3] & 0x3FU);
            if (cp >= 0x10000U && cp <= 0x10FFFFU) {
                const std::uint32_t v = cp - 0x10000U;
                const std::uint32_t hi = 0xD800U + (v >> 10);
                const std::uint32_t lo = 0xDC00U + (v & 0x3FFU);
                out += static_cast<char>(0xE0U | (hi >> 12));
                out += static_cast<char>(0x80U | ((hi >> 6) & 0x3FU));
                out += static_cast<char>(0x80U | (hi & 0x3FU));
                out += static_cast<char>(0xE0U | (lo >> 12));
                out += static_cast<char>(0x80U | ((lo >> 6) & 0x3FU));
                out += static_cast<char>(0x80U | (lo & 0x3FU));
            } else {
                out += '?';  // 4 字节形态但码点越界（overlong / >U+10FFFF）
            }
            i += 4;
        } else {
            out += '?';  // 非法首字节 / 续字节缺失：不透传（对 NewStringUTF 是 UB）
            i += 1;
        }
    }
    return out;
}

} // namespace amcl
