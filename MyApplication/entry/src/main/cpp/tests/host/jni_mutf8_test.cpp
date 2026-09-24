#include "jni_mutf8.h"

#include <cstdlib>
#include <iostream>
#include <string>

namespace {

void Require(bool condition, const char* message) {
    if (condition) return;
    std::cerr << "jni_mutf8_test: FAIL: " << message << '\n';
    std::exit(1);
}

std::string Bytes(std::initializer_list<int> values) {
    std::string out;
    for (int v : values) out += static_cast<char>(v);
    return out;
}

} // namespace

int main() {
    using amcl::toModifiedUtf8;

    // ASCII 与 BMP（中文 3 字节形态）与 MUTF-8 同形：必须逐字节不变。
    Require(toModifiedUtf8("MCPlayer") == "MCPlayer", "ASCII must pass through unchanged");
    const std::string chinese = Bytes({0xE4, 0xB8, 0xAD, 0xE6, 0x96, 0x87});  // "中文"
    Require(toModifiedUtf8(chinese) == chinese, "BMP (Chinese) must pass through unchanged");
    const std::string twoByte = Bytes({0xC3, 0xA9});  // U+00E9 é
    Require(toModifiedUtf8(twoByte) == twoByte, "2-byte sequences must pass through unchanged");

    // U+0000 → 0xC0 0x80（MUTF-8 的嵌入 NUL 表示）。
    Require(toModifiedUtf8(std::string("\0", 1)) == Bytes({0xC0, 0x80}),
            "NUL must become C0 80");

    // 增补平面（U+1F600 😀，标准 UTF-8 F0 9F 98 80）→ 代理对 D83D/DE00 的
    // 3+3 字节形态 ED A0 BD ED B8 80。这正是 NewStringUTF 的 UB 输入被修正后的形态。
    const std::string emoji = Bytes({0xF0, 0x9F, 0x98, 0x80});
    const std::string cesu = Bytes({0xED, 0xA0, 0xBD, 0xED, 0xB8, 0x80});
    Require(toModifiedUtf8(emoji) == cesu, "supplementary char must become a CESU-8 surrogate pair");
    Require(toModifiedUtf8("a" + emoji + "b") == "a" + cesu + "b",
            "conversion must preserve surrounding text");

    // 增补平面边界：U+10000（F0 90 80 80）→ D800/DC00。
    Require(toModifiedUtf8(Bytes({0xF0, 0x90, 0x80, 0x80}))
                == Bytes({0xED, 0xA0, 0x80, 0xED, 0xB0, 0x80}),
            "U+10000 boundary must convert correctly");

    // 非法输入不透传：孤立续字节 / 截断的 4 字节序列 / overlong 4 字节。
    Require(toModifiedUtf8(Bytes({0x80})) == "?", "stray continuation byte must be replaced");
    Require(toModifiedUtf8(Bytes({0xF0, 0x9F, 0x98})) == "???",
            "truncated 4-byte sequence must be replaced per byte");
    Require(toModifiedUtf8(Bytes({0xF0, 0x80, 0x80, 0x80})) == "?",
            "overlong 4-byte encoding must be replaced");
    Require(toModifiedUtf8(Bytes({0xFF})) == "?", "invalid lead byte must be replaced");

    // 属性回读必须恢复标准 UTF-8，而不是拿 MUTF-8 字节与 native 路径比较。
    // 长度显式传递：验证嵌入 NUL、空串，以及两端补充平面的代理对边界。
    std::string decoded = "unchanged";
    const std::u16string path = u"/game/中文\U0001F600\U0002000B/natives/jna";
    Require(amcl::utf16ToUtf8(path.data(), path.size(), decoded) &&
        decoded == u8"/game/中文\U0001F600\U0002000B/natives/jna", "UTF-16 path must become standard UTF-8");
    const char16_t boundaries[] = {0xD800, 0xDC00, 0xDBFF, 0xDFFF};
    Require(amcl::utf16ToUtf8(boundaries, 4, decoded) &&
        decoded == Bytes({0xF0, 0x90, 0x80, 0x80, 0xF4, 0x8F, 0xBF, 0xBF}), "supplementary bounds");
    const char16_t nul[] = {u'a', 0, u'b'};
    Require(amcl::utf16ToUtf8(nul, 3, decoded) && decoded == std::string("a\0b", 3), "embedded NUL preserved");
    Require(amcl::utf16ToUtf8(static_cast<const char16_t*>(nullptr), 0, decoded) && decoded.empty(), "empty UTF-16");
    // 不合法的 Java 字符串不能被替换成同一个占位字符而获得错误通过；失败保持输出不变。
    decoded = "retained";
    const char16_t high[] = {0xD800}, low[] = {0xDC00}, broken[] = {0xD800, u'a'};
    Require(!amcl::utf16ToUtf8(high, 1, decoded) && decoded == "retained", "unpaired high surrogate rejected");
    Require(!amcl::utf16ToUtf8(low, 1, decoded) && decoded == "retained", "unpaired low surrogate rejected");
    Require(!amcl::utf16ToUtf8(broken, 2, decoded) && decoded == "retained", "broken pair rejected");
    Require(!amcl::utf16ToUtf8(static_cast<const char16_t*>(nullptr), 1, decoded), "missing UTF-16 buffer rejected");

    std::cout << "jni_mutf8_test: PASS\n";
    return 0;
}
