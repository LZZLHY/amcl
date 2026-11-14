/** 直接包含生产解析TU，测试内部纯元数据函数；不为测试向产品暴露解析私有API。
 * 仅分配28字节扩展，验证合法4GiB附近数值而不创建巨型payload或降低正常预算。 */
#include "../../entry/src/main/cpp/platform/jdk_install_archive.cpp"
#include <cassert>
#include <iostream>
int main() {
    for (uint64_t expected : {0xffffffffULL, 0x100000000ULL, 0x100000001ULL}) {
        std::array<unsigned char, 28> extra{};
        extra[0] = 1;
        extra[2] = 24;
        for (size_t field = 0; field < 3; ++field)
            for (size_t byte = 0; byte < 8; ++byte)
                extra[4 + field * 8 + byte] = (expected >> (byte * 8)) & 255;
        uint64_t size = 0xffffffff, compressed = 0xffffffff, offset = 0xffffffff;
        amcl::jdk::Zip64(extra.data(), extra.size(), size, compressed, offset);
        assert(size == expected && compressed == expected && offset == expected);
        // 已解析值可等于32位哨兵；真正缺失的扩展仍必须拒绝，不能把修复变成放行缺字段。
        size = compressed = offset = 0xffffffff;
        bool rejected = false;
        try {
            amcl::jdk::Zip64(extra.data(), extra.size() - 1, size, compressed, offset);
        } catch (const std::runtime_error &) {
            rejected = true;
        }
        assert(rejected);
    }
    uint64_t size = 0xffffffff, compressed = 7, offset = 11;
    bool rejected = false;
    try {
        amcl::jdk::Zip64(nullptr, 0, size, compressed, offset);
    } catch (const std::runtime_error &) {
        rejected = true;
    }
    assert(rejected);
    std::cout << "ZIP64: actual 0xffffffff / 4GiB / 4GiB+1 accepted; truncated/missing extras rejected\n";
}
