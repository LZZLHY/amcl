/** 单一 LLVM unwinder 的映像索引桥：注册可失败，查询无分配，空表查询无锁。 */
#ifndef AMCL_UNWIND_IMAGES_HPP
#define AMCL_UNWIND_IMAGES_HPP
#include <stdlib.h>
#include <string.h>
#include "config.h"
#include "RWMutex.hpp"
#include "libunwind_ext.h"
#include "UnwindCursor.hpp"
#include "amcl_unwind_image.h"
using libunwind::RWMutex;
static_assert(int(AMCL_UNWIND_NOMEM) == int(UNW_ENOMEM) && int(AMCL_UNWIND_INVALID) == int(UNW_EINVAL),
              "checked registration status contract changed");
// AMCL 自加载映像只登记一份范围描述符，沿用 LLVM 的 EH header 二分查找。
// 不能把大型 libjvm 的数万 FDE 逐个塞入线性 cache；这里仅为系统 phdr 列表外的映像补入口。
namespace {
RWMutex imageLock;
amcl_unwind_image_v1* registeredImages = nullptr;
size_t registeredCount = 0;
size_t registeredCapacity = 0;

// 减法比较避免 base+size 溢出；展开节必须完全位于该映像的合法所有权范围内。
bool imageContains(const amcl_unwind_image_v1& image, uintptr_t start, size_t bytes) {
  return start >= image.image_base && start - image.image_base <= image.image_size &&
      bytes <= image.image_size - (start - image.image_base);
}
}

namespace libunwind {
bool findRegisteredImage(uintptr_t pc, amcl_unwind_image_v1& image) {
  // 没有自加载对象时，不给普通 SDK 展开路径增加锁或分配成本。
  if (__atomic_load_n(&registeredCount, __ATOMIC_ACQUIRE) == 0) return false;
  if (!imageLock.lock_shared()) return false;
  size_t low = 0, high = __atomic_load_n(&registeredCount, __ATOMIC_RELAXED);
  while (low < high) {
    const size_t mid = low + (high - low) / 2;
    if (registeredImages[mid].image_base <= pc) low = mid + 1;
    else high = mid;
  }
  const bool found = low && pc - registeredImages[low - 1].image_base < registeredImages[low - 1].image_size;
  if (found) image = registeredImages[low - 1];
  _LIBUNWIND_LOG_IF_FALSE(imageLock.unlock_shared());
  return found;
}
}

extern "C" _LIBUNWIND_EXPORT int amcl_unwind_register_image(const amcl_unwind_image_v1* input) {
  if (!input) return UNW_EINVAL;
  const amcl_unwind_image_v1 image = *input;
  if (!image.image_size || image.image_size > UINTPTR_MAX - image.image_base ||
      ((image.eh_frame_hdr == 0) != (image.eh_frame_hdr_size == 0)) ||
      image.eh_frame_size < 4 || !imageContains(image, image.eh_frame, image.eh_frame_size) ||
      (image.eh_frame_hdr_size && (image.eh_frame_hdr_size < 4 ||
       !imageContains(image, image.eh_frame_hdr, image.eh_frame_hdr_size)))) return UNW_EINVAL;
  if (!imageLock.lock()) return UNW_EUNSPEC;
  const size_t count = __atomic_load_n(&registeredCount, __ATOMIC_RELAXED);
  size_t low = 0, high = count;
  while (low < high) {
    const size_t mid = low + (high - low) / 2;
    if (registeredImages[mid].image_base < image.image_base) low = mid + 1;
    else high = mid;
  }
  // 已存在或重叠不能覆盖旧 owner；先完成全部可失败准备，再发布新条目。
  if ((low && registeredImages[low - 1].image_base + registeredImages[low - 1].image_size > image.image_base) ||
      (low < count && image.image_base + image.image_size > registeredImages[low].image_base)) {
    _LIBUNWIND_LOG_IF_FALSE(imageLock.unlock());
    return UNW_EINVAL;
  }
  if (count == registeredCapacity) {
    if (registeredCapacity > SIZE_MAX / (2 * sizeof(amcl_unwind_image_v1))) {
      _LIBUNWIND_LOG_IF_FALSE(imageLock.unlock());
      return UNW_ENOMEM;
    }
    const size_t capacity = registeredCapacity ? registeredCapacity * 2 : 8;
    auto* buffer = static_cast<amcl_unwind_image_v1*>(malloc(capacity * sizeof(amcl_unwind_image_v1)));
    if (!buffer) { _LIBUNWIND_LOG_IF_FALSE(imageLock.unlock()); return UNW_ENOMEM; }
    if (count) memcpy(buffer, registeredImages, count * sizeof(amcl_unwind_image_v1));
    free(registeredImages);
    registeredImages = buffer;
    registeredCapacity = capacity;
  }
  memmove(registeredImages + low + 1, registeredImages + low, (count - low) * sizeof(amcl_unwind_image_v1));
  registeredImages[low] = image;
  __atomic_store_n(&registeredCount, count + 1, __ATOMIC_RELEASE);
  return imageLock.unlock() ? UNW_ESUCCESS : UNW_EUNSPEC;
}

extern "C" _LIBUNWIND_EXPORT int amcl_unwind_unregister_image(uintptr_t base) {
  if (!imageLock.lock()) return UNW_EUNSPEC;
  const size_t count = __atomic_load_n(&registeredCount, __ATOMIC_RELAXED);
  size_t low = 0, high = count;
  while (low < high) {
    const size_t mid = low + (high - low) / 2;
    if (registeredImages[mid].image_base < base) low = mid + 1;
    else high = mid;
  }
  if (low == count || registeredImages[low].image_base != base) {
    _LIBUNWIND_LOG_IF_FALSE(imageLock.unlock());
    return UNW_ENOINFO;
  }
  // 无 .eh_frame_hdr 的合法对象会使用 LLVM 的普通 FDE cache。撤销映像时一并
  // 清掉以 dso_base 分组的条目，避免随后查到已卸载映射；两个内部锁不跨用户回调。
  const int cacheStatus = libunwind::DwarfFDECache<libunwind::LocalAddressSpace>::removeAllIn(base);
  if (cacheStatus != UNW_ESUCCESS) { _LIBUNWIND_LOG_IF_FALSE(imageLock.unlock()); return cacheStatus; }
  memmove(registeredImages + low, registeredImages + low + 1, (count - low - 1) * sizeof(amcl_unwind_image_v1));
  __atomic_store_n(&registeredCount, count - 1, __ATOMIC_RELEASE);
  if (count == 1) {
    // 所有对象均退休时释放表；持续 load/close 的资源与活跃映像数相关，不随历史次数增长。
    free(registeredImages);
    registeredImages = nullptr;
    registeredCapacity = 0;
  }
  return imageLock.unlock() ? UNW_ESUCCESS : UNW_EUNSPEC;
}


#endif
