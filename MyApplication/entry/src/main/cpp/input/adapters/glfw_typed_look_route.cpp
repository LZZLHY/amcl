#include "glfw_typed_look_route.h"

#include <cerrno>
#include <cmath>
#include <cstdlib>

namespace amcl::input {

uintptr_t ParseGlfwTypedLookTrampoline(const char* text) {
    if (text == nullptr || text[0] == '\0') return 0u;
    // 只接受纯十进制。`strtoull` 自己会跳过前导空白、接受 `0x` 前缀、也接受尾随垃圾 ——
    // 那三种都必须判失败，否则一个被截断或拼错的 env 会解析出**半个地址**。
    for (const char* cursor = text; *cursor != '\0'; ++cursor) {
        if (*cursor < '0' || *cursor > '9') return 0u;
    }
    errno = 0;
    char* end = nullptr;
    const unsigned long long value = std::strtoull(text, &end, 10);
    // ⚠️ `end == text || *end != '\0'` 在上面那道白名单之后是**不可达的**（实测：删掉它们
    // 断言全绿）。**刻意保留为冗余**：白名单是这里唯一的正确性依赖，万一有人放宽它
    // （比如为了接受十六进制），这两条就是第二道网。别把它们当"正在防御的活代码"读。
    if (errno != 0 || end == text || *end != '\0' || value == 0ull) return 0u;
    const uintptr_t address = static_cast<uintptr_t>(value);
    // ⚠️ 仅 ILP32 生效。本仓的断言宿主（MSVC x64 / aarch64）都是 64 位 ⇒ 这一行在**任何
    // 可执行的测试环境里都测不到**（实测：删掉它断言全绿）。超长数字串走的是上面的 ERANGE。
    if (static_cast<unsigned long long>(address) != value) return 0u;
    return address;
}

bool GlfwTypedLookRoute::Latch(GlfwTypedLookSink sink) {
    if (sink == nullptr) return false;
    if (sink_ != nullptr) return sink_ == sink;
    sink_ = sink;
    return true;
}

bool GlfwTypedLookRoute::HasSink() const { return sink_ != nullptr; }

GlfwTypedLookStatus GlfwTypedLookRoute::Apply(double dx, double dy) {
    const auto reject = [this](GlfwTypedLookStatus status) {
        rejectCount_.fetch_add(1u, std::memory_order_relaxed);
        return status;
    };
    // 数据校验先于 sink 存在性：坏数据不该因为"恰好还没解析到 sink"而被记成另一种原因。
    if (!std::isfinite(dx) || !std::isfinite(dy)) {
        return reject(GlfwTypedLookStatus::kNonFinite);
    }
    if (sink_ == nullptr) return reject(GlfwTypedLookStatus::kNoSink);
    if (!sink_(dx, dy)) return reject(GlfwTypedLookStatus::kSinkRejected);
    return GlfwTypedLookStatus::kApplied;
}

uint64_t GlfwTypedLookRoute::RejectCount() const {
    return rejectCount_.load(std::memory_order_relaxed);
}

}  // namespace amcl::input
