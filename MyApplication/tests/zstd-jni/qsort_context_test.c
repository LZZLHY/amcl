#include "../../prebuilt/mod-natives/zstd-jni/qsort_context.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>

/** 真实系统qsort内嵌套调用适配器，内层返回必须恢复外层方向与比较上下文。 */
typedef struct Context { int direction; int nested; } Context;
static int compare(const void* left, const void* right, void* opaque) {
    Context* context = opaque;
    if (context->nested) {
        int values[] = {5, 2, 8, 1}; Context child = {-context->direction, 0};
        AmclZstdQsortR(values, 4, sizeof(int), compare, &child);
        assert(child.direction > 0 ? values[0] == 1 : values[0] == 8);
    }
    int a = *(const int*)left, b = *(const int*)right;
    return context->direction * ((a > b) - (a < b));
}
/** 多线程用相反排序规则反复交错，单个全局上下文实现会破坏结果。 */
static void* worker(void* opaque) {
    Context context = {*(int*)opaque, 1};
    for (int round = 0; round < 100; ++round) {
        int values[73];
        for (int i = 0; i < 73; ++i) values[i] = (i * 29 + round) % 73;
        AmclZstdQsortR(values, 73, sizeof(int), compare, &context);
        for (int i = 0; i < 73; ++i) assert(values[i] == (context.direction > 0 ? i : 72 - i));
    }
    return NULL;
}
int main(void) {
    pthread_t threads[8]; int directions[8];
    for (int i = 0; i < 8; ++i) { directions[i] = (i & 1) ? -1 : 1; assert(!pthread_create(&threads[i], NULL, worker, &directions[i])); }
    for (int i = 0; i < 8; ++i) assert(!pthread_join(threads[i], NULL));
    puts("PASS qsort context: 8 threads, 800 nested sorts, exact opposite-direction results");
}
