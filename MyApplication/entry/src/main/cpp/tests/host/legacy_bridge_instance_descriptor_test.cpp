// legacy_bridge_instance_descriptor_test.cpp
//
// legacy input bridge 的**跨 image 实例描述符**编解码断言。
//
// 为什么这一层值得单独钉住：它是 2026-09-03 那条回归的修复所依赖的唯一跨 image 通道
// （成因见 `docs/reports/2026-09-03_LEGACY_GLFW_ROUTE_INPUT_REGRESSION_INVESTIGATION.md`）。
// 解析出错的后果不是"少一点功能"，而是**一份 image 会继续用自己那条永远为空的 ring**，
// 且在日志里与"工作正常"完全一样 —— 所以这里每一条失败原因都必须能被单独区分出来。

#include "../../glfw/input_bridge_instance_descriptor.h"

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>

namespace {

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "LEGACY BRIDGE DESCRIPTOR FAIL line " << line << ": "
              << expression << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

AmclLegacyBridgeDescriptorStatus Parse(const char* encoded,
                                       unsigned long long* out) {
    return amclLegacyBridgeParseInstanceEnv(encoded, out);
}

void TestRoundTrip() {
    char buffer[AMCL_LEGACY_BRIDGE_INSTANCE_ENV_CAPACITY];
    const unsigned long long address = 0x7f1234abcdefULL;
    CHECK(amclLegacyBridgeEncodeInstanceEnv(buffer, sizeof(buffer), address) ==
          AMCL_LEGACY_BRIDGE_DESCRIPTOR_OK);

    unsigned long long parsed = 0ULL;
    CHECK(Parse(buffer, &parsed) == AMCL_LEGACY_BRIDGE_DESCRIPTOR_OK);
    CHECK(parsed == address);

    // 容量常量必须容得下最坏情况的地址，否则 64 位内核上一个高位地址会被编码拒绝，
    // 而那个拒绝发生在**发布方**：所有消费者都会静默留在自己的私有 ring 上。
    CHECK(amclLegacyBridgeEncodeInstanceEnv(buffer, sizeof(buffer),
                                            UINT64_MAX) ==
          AMCL_LEGACY_BRIDGE_DESCRIPTOR_OK);
    parsed = 0ULL;
    CHECK(Parse(buffer, &parsed) == AMCL_LEGACY_BRIDGE_DESCRIPTOR_OK);
    CHECK(parsed == UINT64_MAX);
}

void TestEncodeRejections() {
    char buffer[AMCL_LEGACY_BRIDGE_INSTANCE_ENV_CAPACITY];

    // 地址 0 = 发布方自己写坏了。必须报出来，且把缓冲清空 —— 一个半写的描述符比没有
    // 描述符更糟：读方会拿它去解引用。
    std::memset(buffer, 'x', sizeof(buffer));
    CHECK(amclLegacyBridgeEncodeInstanceEnv(buffer, sizeof(buffer), 0ULL) ==
          AMCL_LEGACY_BRIDGE_DESCRIPTOR_NULL_ADDRESS);
    CHECK(buffer[0] == '\0');

    // 缓冲太小同样必须清空而不是留下截断结果。
    char tiny[6];
    std::memset(tiny, 'x', sizeof(tiny));
    CHECK(amclLegacyBridgeEncodeInstanceEnv(tiny, sizeof(tiny), 0x1234ULL) ==
          AMCL_LEGACY_BRIDGE_DESCRIPTOR_BUFFER_TOO_SMALL);
    CHECK(tiny[0] == '\0');

    CHECK(amclLegacyBridgeEncodeInstanceEnv(nullptr, 0u, 0x1234ULL) ==
          AMCL_LEGACY_BRIDGE_DESCRIPTOR_BUFFER_TOO_SMALL);
}

void TestAbsentIsDistinctFromMalformed() {
    unsigned long long parsed = 1ULL;
    // ⭐ 这两条必须是**不同的**状态码（AGENTS.md §二.9）：ABSENT 是"宿主还没发布，下一帧
    // 再来"，其余都是"两侧不一致，永远不会好"。合并成一个值到了真机就查不下去。
    CHECK(Parse(nullptr, &parsed) == AMCL_LEGACY_BRIDGE_DESCRIPTOR_ABSENT);
    CHECK(parsed == 0ULL);
    parsed = 1ULL;
    CHECK(Parse("", &parsed) == AMCL_LEGACY_BRIDGE_DESCRIPTOR_ABSENT);
    CHECK(parsed == 0ULL);
}

void TestParseRejections() {
    unsigned long long parsed = 1ULL;

    CHECK(Parse("AMCLSDLV:1:4096", &parsed) ==
          AMCL_LEGACY_BRIDGE_DESCRIPTOR_BAD_MAGIC);
    CHECK(parsed == 0ULL);
    // magic 是另一条通道的前缀时也必须落在 BAD_MAGIC：三条 env 通道并存，认错一条就会把
    // 一串 v7 的函数地址当成一张实例表去解引用。
    CHECK(Parse("AMCLINPV:7:1,2,3,4,5,6,4096", &parsed) ==
          AMCL_LEGACY_BRIDGE_DESCRIPTOR_BAD_MAGIC);
    // magic 对但后面没有分隔符。
    CHECK(Parse("AMCLLBIV", &parsed) ==
          AMCL_LEGACY_BRIDGE_DESCRIPTOR_BAD_MAGIC);
    CHECK(Parse("AMCLLBIV_1_4096", &parsed) ==
          AMCL_LEGACY_BRIDGE_DESCRIPTOR_BAD_MAGIC);

    // 版本不符 ⇒ 两份 image 不是同一次构建出来的。fail closed。
    CHECK(Parse("AMCLLBIV:2:4096", &parsed) ==
          AMCL_LEGACY_BRIDGE_DESCRIPTOR_BAD_VERSION);
    CHECK(Parse("AMCLLBIV:0:4096", &parsed) ==
          AMCL_LEGACY_BRIDGE_DESCRIPTOR_BAD_VERSION);

    CHECK(Parse("AMCLLBIV::4096", &parsed) ==
          AMCL_LEGACY_BRIDGE_DESCRIPTOR_MALFORMED);
    CHECK(Parse("AMCLLBIV:x:4096", &parsed) ==
          AMCL_LEGACY_BRIDGE_DESCRIPTOR_MALFORMED);
    CHECK(Parse("AMCLLBIV:1", &parsed) ==
          AMCL_LEGACY_BRIDGE_DESCRIPTOR_MALFORMED);
    CHECK(Parse("AMCLLBIV:1:", &parsed) ==
          AMCL_LEGACY_BRIDGE_DESCRIPTOR_MALFORMED);

    // ⭐ 尾随垃圾必须被拒。这一条正是"不用 sscanf(\"%llu\")"的全部理由：`%llu` 会静默
    // 接受 "4096junk" 并交出 4096，把一个格式错误变成一个看起来合法的地址。
    CHECK(Parse("AMCLLBIV:1:4096junk", &parsed) ==
          AMCL_LEGACY_BRIDGE_DESCRIPTOR_MALFORMED);
    CHECK(Parse("AMCLLBIV:1:4096:4096", &parsed) ==
          AMCL_LEGACY_BRIDGE_DESCRIPTOR_MALFORMED);
    CHECK(Parse("AMCLLBIV:1:-4096", &parsed) ==
          AMCL_LEGACY_BRIDGE_DESCRIPTOR_MALFORMED);
    CHECK(Parse("AMCLLBIV:1: 4096", &parsed) ==
          AMCL_LEGACY_BRIDGE_DESCRIPTOR_MALFORMED);

    // 溢出的地址与一个被截断的合法地址在类型上无法区分 ⇒ 只能当格式错误。
    CHECK(Parse("AMCLLBIV:1:18446744073709551616", &parsed) ==
          AMCL_LEGACY_BRIDGE_DESCRIPTOR_MALFORMED);

    CHECK(Parse("AMCLLBIV:1:0", &parsed) ==
          AMCL_LEGACY_BRIDGE_DESCRIPTOR_NULL_ADDRESS);

    // 全部失败分支都必须把出参清成 0：调用方不该在每个失败分支里再清一次，
    // 漏掉任何一处都会拿一个上一次的旧地址去解引用。
    CHECK(parsed == 0ULL);
}

void TestOutAddressMayBeNull() {
    // 只想知道"发布了吗"的调用方不必提供出参。
    CHECK(Parse("AMCLLBIV:1:4096", nullptr) ==
          AMCL_LEGACY_BRIDGE_DESCRIPTOR_OK);
    CHECK(Parse("", nullptr) == AMCL_LEGACY_BRIDGE_DESCRIPTOR_ABSENT);
}

}  // namespace

int main() {
    TestRoundTrip();
    TestEncodeRejections();
    TestAbsentIsDistinctFromMalformed();
    TestParseRejections();
    TestOutAddressMayBeNull();
    std::cout << "legacy_bridge_instance_descriptor_test: PASS\n";
    return 0;
}
