#pragma once

#include <cstdint>

namespace amcl::input {

constexpr bool IsUnicodeScalarValue(int32_t codepoint) {
    return codepoint > 0 && codepoint <= 0x10ffff &&
           (codepoint < 0xd800 || codepoint > 0xdfff);
}

} // namespace amcl::input
