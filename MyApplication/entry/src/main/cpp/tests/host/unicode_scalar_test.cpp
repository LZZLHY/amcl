#include "../../platform/unicode_scalar.h"
#include "host_test_check.h"

#include <cstdlib>
#include <iostream>

int main() {
    using amcl::input::IsUnicodeScalarValue;
    CHECK(IsUnicodeScalarValue(1));
    CHECK(IsUnicodeScalarValue(0x20));
    CHECK(IsUnicodeScalarValue(0x4e2d));
    CHECK(IsUnicodeScalarValue(0x10ffff));
    CHECK(!IsUnicodeScalarValue(0));
    CHECK(!IsUnicodeScalarValue(-1));
    CHECK(!IsUnicodeScalarValue(0xd800));
    CHECK(!IsUnicodeScalarValue(0xdfff));
    CHECK(!IsUnicodeScalarValue(0x110000));
    std::cout << "unicode_scalar_test: PASS\n";
    return 0;
}
