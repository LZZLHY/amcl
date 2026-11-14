/**
 * 手工映射对象向同一应用 unwinder 提供已校验的 ELF 展开范围。
 * 只复制这一描述符；调用方拥有底层映射，注销成功且无活跃执行/展开后才允许 unmap。
 * 内部沿用 LLVM 的 .eh_frame_hdr 索引和 CFI 解释，不把每条 FDE 塞入线性动态缓存。
 */
#ifndef AMCL_UNWIND_IMAGE_H
#define AMCL_UNWIND_IMAGE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct amcl_unwind_image_v1 {
    uintptr_t image_base;
    size_t image_size;
    uintptr_t eh_frame;
    size_t eh_frame_size;
    uintptr_t eh_frame_hdr;
    size_t eh_frame_hdr_size;
} amcl_unwind_image_v1;
/* 与固定 LLVM UNW_* 数值一致；这两类失败保证没有发布新映像，可正常回滚。 */
enum { AMCL_UNWIND_NOMEM = -6541, AMCL_UNWIND_INVALID = -6547 };

/** 返回 libunwind UNW_* 状态。重叠/重复映像或无效范围拒绝；ENOMEM 时原表不变。 */
__attribute__((visibility("default")))
int amcl_unwind_register_image(const amcl_unwind_image_v1* image);
/** 按实际映像基址注销；未知地址返回 UNW_ENOINFO，不能凭调用返回就推定注销成功。 */
__attribute__((visibility("default")))
int amcl_unwind_unregister_image(uintptr_t image_base);
#ifdef __cplusplus
}
#endif
#endif
