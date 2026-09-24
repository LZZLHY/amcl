// renderer_backend_ids_test.cpp — native 侧渲染后端镜像表的契约钉子
//
// 施工记录 docs/refactor/渲染后端治理施工记录.md §S4。
//
// ⭐ 这份测试存在的直接原因：我在 §S4 把 `else if (glBackend == "zink")` 那个
// fail-closed 分支改成表驱动时，**第一版把 fail-closed 语义整个弄丢了** ——
// 表里 zink 映射到 libOSMesa.so，于是 opengl.libname 会真的指向一个拿不到
// host hook 的库。那是一个真实回归，而且当时没有任何东西会拦住它。
//
// ⇒ 本文件钉的就是"缺件后端必须 fail closed 到默认"这条语义。

#include "renderer_backend_ids.h"

#include <cstdlib>
#include <iostream>
#include <string>

namespace {

int g_failures = 0;

void require(bool condition, const char* message) {
    if (condition) return;
    std::cerr << "renderer_backend_ids_test: FAIL: " << message << '\n';
    ++g_failures;
}

} // namespace

int main() {
    using amcl::renderer::BackendGlLibrary;
    using amcl::renderer::DefaultBackendGlLibrary;
    using amcl::renderer::FindBackendGlLibrary;
    using amcl::renderer::kBackendGlLibraries;
    using amcl::renderer::kBackendGlLibraryCount;
    using amcl::renderer::kDefaultBackendId;

    // ── 表结构不变量 ────────────────────────────────────────────────
    require(kBackendGlLibraryCount > 0, "mirror table must not be empty");

    for (std::size_t i = 0; i < kBackendGlLibraryCount; ++i) {
        const BackendGlLibrary& b = kBackendGlLibraries[i];
        require(b.id != nullptr && b.id[0] != '\0', "every row needs a non-empty id");
        require(b.glLibName != nullptr && b.glLibName[0] != '\0',
                "every row needs a non-empty glLibName");

        // 治理规范 §3.2：id 一律小写、不得含缩写记号（禁 MGL 一族）。
        for (const char* p = b.id; *p != '\0'; ++p) {
            require(!(*p >= 'A' && *p <= 'Z'), "backend id must be lowercase");
        }
        require(std::string(b.id).find("mgl") == std::string::npos,
                "backend id must not contain the forbidden 'mgl' abbreviation");

        // 不可用的行必须给出**具体**原因；可用的行不得带原因。
        if (b.availableInThisBuild) {
            require(b.unavailableReason == nullptr,
                    "available backends must not carry an unavailableReason");
        } else {
            require(b.unavailableReason != nullptr && b.unavailableReason[0] != '\0',
                    "unavailable backends must record a falsifiable reason");
        }
    }

    // id 不得重复 —— 重复会让查表结果取决于顺序。
    for (std::size_t i = 0; i < kBackendGlLibraryCount; ++i) {
        for (std::size_t j = i + 1; j < kBackendGlLibraryCount; ++j) {
            require(std::string(kBackendGlLibraries[i].id) != kBackendGlLibraries[j].id,
                    "duplicate backend id in mirror table");
        }
    }

    // ── 默认后端 ────────────────────────────────────────────────────
    const BackendGlLibrary* def = DefaultBackendGlLibrary();
    require(def != nullptr, "mirror table must contain the default backend");
    if (def != nullptr) {
        require(std::string(def->id) == kDefaultBackendId, "default lookup returns the default row");
        // ⚠️ 默认后端**必须**在本构建里可用，否则整条渲染路径无出口。
        require(def->availableInThisBuild, "the default backend must be available");
    }

    // ── 查表语义 ────────────────────────────────────────────────────
    // 空串 = 默认：ArkTS 在决策 == 默认时刻意不注入 marker（施工记录 §S3.1 ①）。
    const BackendGlLibrary* viaEmpty = FindBackendGlLibrary("");
    require(viaEmpty != nullptr && std::string(viaEmpty->id) == kDefaultBackendId,
            "empty marker must resolve to the default backend");

    // 精确匹配、大小写敏感。
    require(amcl::renderer::HasBackendGlLibrary("gl4es"), "known id resolves");
    require(FindBackendGlLibrary("GL4ES") == nullptr, "lookup is case-sensitive");
    require(FindBackendGlLibrary("gl4es ") == nullptr, "lookup does not trim");
    // 未知 id 返回 nullptr，**不静默落默认** —— 调用方据此打一条可证伪的日志。
    require(FindBackendGlLibrary("nope") == nullptr, "unknown id must return nullptr");
    require(amcl::renderer::HasBackendGlLibrary("mobilegl"),
            "registered renderer resolves through the native mirror");

    // ── ⭐ 缺件后端必须 fail closed（本文件存在的理由）──────────────
    const BackendGlLibrary* zink = FindBackendGlLibrary("zink");
    if (zink != nullptr) {
        // zink 仍在表里（§S4 是等价性重构，退役在 §S6），但**必须**标为不可用：
        // OSMesa/Zink host hook 已于 2026-08-09 从 libglfw.so 退役。
        require(!zink->availableInThisBuild,
                "zink must be marked unavailable while its host hooks are retired");
        require(zink->unavailableReason != nullptr,
                "zink must record why it is unavailable");
    }

    // 表里若存在任何不可用的行，调用方的处置只能是落默认 —— 这条在
    // mc_launcher.cpp 里实现（本测试只能钉数据，钉不到那段控制流）。
    // ⇒ 这里断言的是"数据侧的前提成立"：默认后端可用，所以 fail closed 有落点。
    require(def != nullptr && def->availableInThisBuild,
            "fail-closed requires an available default to fall back to");

    if (g_failures != 0) {
        std::cerr << "renderer_backend_ids_test: " << g_failures << " failure(s)\n";
        return 1;
    }
    std::cout << "renderer_backend_ids_test: PASS (" << kBackendGlLibraryCount
              << " backends)\n";
    return 0;
}
