/** 编译实际映像登记桥，验证资源失败与并发查询；此夹具不把虚拟测试地址交给 CFI 解释器。 */
#include <cassert>
#include <cstdlib>
#include <cstdio>
#include <atomic>
#include <thread>
#include <vector>
#include <stdlib.h>
#include "libunwind.h"
#include "config.h"
#include "RWMutex.hpp"
static std::atomic<bool> failAllocation{false};
static void* image_malloc(size_t bytes) { return failAllocation.load() ? nullptr : std::malloc(bytes); }
#define malloc image_malloc
#include "amcl_unwind_images.hpp"
#undef malloc

static amcl_unwind_image_v1 makeImage(uintptr_t base) {
    return {base, 4096, base + 128, 256, base + 512, 128};
}
int main() {
    auto first = makeImage(65536);
    amcl_unwind_image_v1 result{};
    failAllocation = true;
    assert(amcl_unwind_register_image(&first) == UNW_ENOMEM);
    assert(!libunwind::findRegisteredImage(first.image_base, result));
    failAllocation = false;
    for (unsigned i = 0; i < 8; ++i) {
        auto image = makeImage(65536 + i * 8192);
        assert(amcl_unwind_register_image(&image) == 0);
    }
    assert(amcl_unwind_register_image(&first) == UNW_EINVAL);
    auto overlap = makeImage(first.image_base + 100);
    assert(amcl_unwind_register_image(&overlap) == UNW_EINVAL);
    auto invalid = first; invalid.eh_frame_size = SIZE_MAX;
    assert(amcl_unwind_register_image(&invalid) == UNW_EINVAL);
    invalid = first; invalid.eh_frame_hdr_size = 0;
    assert(amcl_unwind_register_image(&invalid) == UNW_EINVAL);
    auto ninth = makeImage(65536 + 8 * 8192);
    failAllocation = true;
    assert(amcl_unwind_register_image(&ninth) == UNW_ENOMEM);
    for (unsigned i = 0; i < 8; ++i) {
        const uintptr_t base = 65536 + i * 8192;
        assert(libunwind::findRegisteredImage(base, result) && result.image_base == base);
        assert(libunwind::findRegisteredImage(base + 4095, result));
        assert(!libunwind::findRegisteredImage(base + 4096, result));
    }
    failAllocation = false;
    assert(amcl_unwind_register_image(&ninth) == 0);
    using Cache = libunwind::DwarfFDECache<libunwind::LocalAddressSpace>;
    assert(Cache::add(first.image_base, first.image_base, first.image_base + 4, 77) == 0);
    // 不同 owner 的并发登记/精确查找/注销互不覆盖；成功退出后不存在历史遗留条目。
    std::vector<std::thread> workers;
    for (uintptr_t owner = 0; owner < 8; ++owner) workers.emplace_back([owner] {
        auto image = makeImage(1048576 + owner * 8192);
        for (unsigned repeat = 0; repeat < 2000; ++repeat) {
            amcl_unwind_image_v1 found{};
            assert(amcl_unwind_register_image(&image) == 0);
            assert(libunwind::findRegisteredImage(image.image_base + 10, found));
            assert(found.eh_frame == image.eh_frame && found.eh_frame_hdr == image.eh_frame_hdr);
            assert(amcl_unwind_unregister_image(image.image_base) == 0);
        }
    });
    for (auto& worker : workers) worker.join();
    for (unsigned i = 0; i < 9; ++i) assert(amcl_unwind_unregister_image(65536 + i * 8192) == 0);
    assert(Cache::findFDE(Cache::kSearchAll, first.image_base) == 0);
    assert(amcl_unwind_unregister_image(first.image_base) == UNW_ENOINFO);
    assert(registeredImages == nullptr && registeredCapacity == 0);
    assert(!libunwind::findRegisteredImage(first.image_base, result));
    std::puts("PASS image registry OOM rollback, range/identity, 16000 concurrent registration lifetimes and complete release");
}
