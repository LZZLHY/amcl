/** 有界 EH 结构验收的内存反例；只验证数据，不将伪造 PC 或指令交给真实 unwinder。 */
#include "../../entry/src/main/cpp/jvm/elf_unwind_validation.h"
#include <array>
#include <cassert>
#include <cstdio>
#include <functional>
using namespace amcl::unwindinput;
struct TestImage { alignas(16) std::array<unsigned char, 1024> bytes{}; };
static bool readable(void* context, Address address, size_t bytes) {
    const auto* image = static_cast<TestImage*>(context);
    const auto begin = reinterpret_cast<Address>(image->bytes.data());
    return address >= begin && address - begin <= image->bytes.size() && bytes <= image->bytes.size() - (address - begin);
}
static bool code(void* context, Address address, size_t bytes) {
    const auto begin = reinterpret_cast<Address>(static_cast<TestImage*>(context)->bytes.data()) + 512;
    return address >= begin && address - begin <= 256 && bytes <= 256 - (address - begin);
}
template<class T> static void put(TestImage& image, size_t offset, T value) {
    std::memcpy(image.bytes.data() + offset, &value, sizeof(value));
}
/** 一条 CIE(zR, absptr) 与一条 FDE，末尾具有标准零长度终止项。 */
static TestImage fixture() {
    TestImage image;
    put<uint32_t>(image, 0, 16);
    const unsigned char cie[] = {1, 'z', 'R', 0, 1, 0x78, 30, 1, 0, 12, 31, 0};
    std::memcpy(image.bytes.data() + 8, cie, sizeof(cie));
    put<uint32_t>(image, 20, 24); put<uint32_t>(image, 24, 24);
    put<uint64_t>(image, 36, 16);
    return image;
}
int main() {
    size_t rejected = 0;
    auto run = [&](const std::function<void(TestImage&)>& mutate, bool expectOk, const char* reason) {
        TestImage image = fixture();
        const Address begin = reinterpret_cast<Address>(image.bytes.data());
        put<uint64_t>(image, 28, begin + 512); // 只在实际对象落定后写入本轮 PC。
        mutate(image);
        Memory memory{&image, readable, code, code};
        std::vector<Frame> frames;
        const char* error = nullptr;
        const bool success = validate(memory, begin, 60, frames, error);
        assert(success == expectOk);
        if (success) assert(frames.size() == 1 && frames[0].begin == begin + 512 && frames[0].end == begin + 528);
        else { assert(error && std::strstr(error, reason)); ++rejected; }
    };
    run([](auto&) {}, true, "");
    run([](auto& i) { put<uint32_t>(i, 0, 1000); }, false, "record extent");
    run([](auto& i) { i.bytes[8] = 4; }, false, "CIE fields");
    run([](auto& i) { i.bytes[10] = 'X'; }, false, "CIE fields");
    run([](auto& i) { i.bytes[12] = 0; }, false, "CIE fields");
    run([](auto& i) { i.bytes[14] = 96; }, false, "CIE fields");
    run([](auto& i) { i.bytes[15] = 20; }, false, "CIE fields");
    run([](auto& i) { put<uint32_t>(i, 24, 25); }, false, "CIE reference");
    run([](auto& i) { put<uint32_t>(i, 24, 23); }, false, "earlier CIE");
    run([](auto& i) { put<uint64_t>(i, 28, 1); }, false, "executable range");
    run([](auto& i) { put<uint64_t>(i, 36, UINT64_MAX); }, false, "executable range");
    run([](auto& i) { i.bytes[44] = 10; }, false, "augmentation length");
    run([](auto& i) { i.bytes[45] = 11; }, false, "CFI operand");
    run([](auto& i) { i.bytes[45] = 7; i.bytes[46] = 96; }, false, "CFI operand");
    run([](auto& i) { i.bytes[45] = 15; i.bytes[46] = 0xff; i.bytes[47] = 1; }, false, "CFI operand");
    run([](auto& i) { i.bytes[45] = 1; }, false, "CFI operand");
    run([](auto& i) { i.bytes[16] = 0x5b; }, false, "executable range");
    run([](auto& i) { i.bytes[55] = 1; }, false, "terminator");
    TestImage leb;
    const auto begin = reinterpret_cast<Address>(leb.bytes.data());
    Memory memory{&leb, readable, code, code};
    std::memset(leb.bytes.data(), 0xff, 9); leb.bytes[9] = 1;
    Cursor maximum(memory, begin, begin + 10);
    assert(maximum.uleb() == UINT64_MAX && !maximum.failed);
    leb.bytes[9] = 2;
    Cursor overflow(memory, begin, begin + 10);
    overflow.uleb(); assert(overflow.failed);
    std::printf("PASS bounded EH structure: %zu malformed records and LEB overflow rejected\n", rejected);
}
