#include "qsort_context.h"
#include <stdlib.h>

/** 栈上调用帧保存本次比较器和上下文；每个线程独立，嵌套排序退回时恢复外层帧。 */
typedef struct SortFrame {
    int (*compare)(const void*, const void*, void*);
    void* context;
    struct SortFrame* previous;
} SortFrame;
static _Thread_local SortFrame* current_frame;

/** 系统qsort保持真实排序语义，只通过当前线程帧补上第三个参数，不分配内存。 */
static int compare_current(const void* left, const void* right) {
    return current_frame->compare(left, right, current_frame->context);
}

void AmclZstdQsortR(void* base, size_t count, size_t width,
                   int (*compare)(const void*, const void*, void*), void* context) {
    SortFrame frame = {compare, context, current_frame};
    current_frame = &frame;
    qsort(base, count, width, compare_current);
    current_frame = frame.previous;
}
