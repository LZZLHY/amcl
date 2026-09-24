#include "../../input/adapters/glfw_typed_look_route.h"

#include <cstdlib>
#include <iostream>
#include <limits>
#include <string>

using namespace amcl::input;

namespace {
[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "GLFW TYPED LOOK ROUTE FAIL line " << line << ": "
              << expression << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

int gCalls = 0;
double gLastDx = 0.0;
double gLastDy = 0.0;
bool gAccept = true;

bool RecordingSink(double dx, double dy) {
    ++gCalls;
    gLastDx = dx;
    gLastDy = dy;
    return gAccept;
}

bool OtherSink(double, double) { return true; }
}  // namespace

int main() {
    // env 文本解析：静默解析出"半个地址"是这类反向通道最容易出的失败，逐条拒绝。
    CHECK(ParseGlfwTypedLookTrampoline(nullptr) == 0u);
    CHECK(ParseGlfwTypedLookTrampoline("") == 0u);
    CHECK(ParseGlfwTypedLookTrampoline("0") == 0u);
    CHECK(ParseGlfwTypedLookTrampoline("0x1f") == 0u);
    CHECK(ParseGlfwTypedLookTrampoline(" 123") == 0u);
    CHECK(ParseGlfwTypedLookTrampoline("123 ") == 0u);
    CHECK(ParseGlfwTypedLookTrampoline("123abc") == 0u);
    CHECK(ParseGlfwTypedLookTrampoline("-123") == 0u);
    CHECK(ParseGlfwTypedLookTrampoline("+123") == 0u);
    CHECK(ParseGlfwTypedLookTrampoline("1.5") == 0u);
    CHECK(ParseGlfwTypedLookTrampoline("123") == static_cast<uintptr_t>(123));

    // 超长数字串必须拒绝。⚠️ 它走的是 `strtoull` 的 **ERANGE**，不是那条 32 位截断护栏
    // —— 后者在 64 位宿主上恒假，本仓没有能执行它的环境（计划 §86.10）。
    {
        const std::string huge = "99999999999999999999999999";
        CHECK(ParseGlfwTypedLookTrampoline(huge.c_str()) == 0u);
    }

    // 真实地址往返：把本进程一个函数指针按 %llu 打成字符串再解析回来。
    {
        const unsigned long long address = static_cast<unsigned long long>(
            reinterpret_cast<uintptr_t>(&RecordingSink));
        const std::string text = std::to_string(address);
        const uintptr_t parsed = ParseGlfwTypedLookTrampoline(text.c_str());
        CHECK(parsed == reinterpret_cast<uintptr_t>(&RecordingSink));
    }

    // 未闭锁时不得崩溃，也不得把样本当成已投递。
    {
        GlfwTypedLookRoute route;
        CHECK(!route.HasSink());
        CHECK(route.Apply(1.0, 2.0) == GlfwTypedLookStatus::kNoSink);
        CHECK(route.RejectCount() == 1u);
        CHECK(gCalls == 0);

        // ⭐ 未闭锁 **且** 坏数据：必须报 kNonFinite 而不是 kNoSink。这一格此前
        // 没有任何用例走到 —— 把两个检查对调，全部断言仍然全绿（计划 §86.9）。
        CHECK(route.Apply(std::numeric_limits<double>::quiet_NaN(), 1.0) ==
              GlfwTypedLookStatus::kNonFinite);
        CHECK(route.RejectCount() == 2u);
    }

    // 一次性闭锁：nullptr 拒绝、重复同一个接受、换成另一个必须拒绝。
    {
        GlfwTypedLookRoute route;
        CHECK(!route.Latch(nullptr));
        CHECK(!route.HasSink());
        CHECK(route.Latch(RecordingSink));
        CHECK(route.HasSink());
        CHECK(route.Latch(RecordingSink));
        CHECK(!route.Latch(OtherSink));
        CHECK(!route.Latch(nullptr));
    }

    // ⭐ 非有限值绝不跨 DSO：漏斗的持久 backlog 不可被污染（计划 §85）。
    {
        GlfwTypedLookRoute route;
        CHECK(route.Latch(RecordingSink));
        gCalls = 0;
        gAccept = true;
        const double invalid[] = {
            std::numeric_limits<double>::quiet_NaN(),
            std::numeric_limits<double>::infinity(),
            -std::numeric_limits<double>::infinity(),
        };
        uint64_t expected = 0u;
        for (double value : invalid) {
            CHECK(route.Apply(value, 1.0) == GlfwTypedLookStatus::kNonFinite);
            CHECK(route.Apply(1.0, value) == GlfwTypedLookStatus::kNonFinite);
            expected += 2u;
            CHECK(route.RejectCount() == expected);
        }
        CHECK(gCalls == 0);
    }

    // 正常投递：恰好一次、参数逐位相等、不计入拒绝。
    {
        GlfwTypedLookRoute route;
        CHECK(route.Latch(RecordingSink));
        gCalls = 0;
        gAccept = true;
        CHECK(route.Apply(-4.235294, 9.5) == GlfwTypedLookStatus::kApplied);
        CHECK(gCalls == 1);
        CHECK(gLastDx == -4.235294 && gLastDy == 9.5);
        CHECK(route.RejectCount() == 0u);
    }

    // sink 拒绝（桥不可用）与坏数据是**两种不同原因**，状态码必须分开。
    {
        GlfwTypedLookRoute route;
        CHECK(route.Latch(RecordingSink));
        gCalls = 0;
        gAccept = false;
        CHECK(route.Apply(1.0, 1.0) == GlfwTypedLookStatus::kSinkRejected);
        CHECK(gCalls == 1);
        CHECK(route.RejectCount() == 1u);
        gAccept = true;
        CHECK(route.Apply(1.0, 1.0) == GlfwTypedLookStatus::kApplied);
        CHECK(route.RejectCount() == 1u);
    }

    // 零位移是合法样本，必须照常交给漏斗（它在那里参与 backlog 与 census）。
    {
        GlfwTypedLookRoute route;
        CHECK(route.Latch(RecordingSink));
        gCalls = 0;
        gAccept = true;
        CHECK(route.Apply(0.0, 0.0) == GlfwTypedLookStatus::kApplied);
        CHECK(gCalls == 1);
    }

    std::cout << "glfw_typed_look_route_test: PASS\n";
    return 0;
}
