/* 同一组真实 DSO 同时用于系统 glibc 对照与自定义 AArch64 loader；宏只选择库角色。 */
#include <dlfcn.h>
#if SCOPE_KIND == 0
extern int left_anchor(void), right_anchor(void);
extern int scope_choice;
int root_anchor(void) { return left_anchor() + right_anchor(); }
int root_relocated_choice(void) { return scope_choice; }
#elif SCOPE_KIND == 1
extern int leaf_anchor(void);
int left_anchor(void) { return leaf_anchor(); }
#elif SCOPE_KIND == 2
int scope_choice = 42;
int right_anchor(void) { return 2; }
#elif SCOPE_KIND == 3
int scope_choice = 7;
int leaf_anchor(void) { return 3; }
#elif SCOPE_KIND == 4
int scope_local = 91;
#elif SCOPE_KIND == 5
extern int scope_local;
int read_scope_local(void) { return scope_local; }
#elif SCOPE_KIND == 6
int scope_marker(void) { return 1; }
/* 保留真实调用帧，让 RTLD_NEXT 的返回地址确实属于本 DSO，而非编译器的尾调用上层。 */
__attribute__((noinline)) int read_next_marker(void) {
    int (*next)(void) = (int (*)(void))dlsym(RTLD_NEXT, "scope_marker");
    return next ? next() : -1;
}
#elif SCOPE_KIND == 7
int scope_marker(void) { return 2; }
#elif SCOPE_KIND == 8
extern void scope_initialization_gate(void);
__attribute__((constructor)) static void initialize(void) { scope_initialization_gate(); }
int scope_initialized = 123;
#elif SCOPE_KIND == 9
int scope_dynamic_global = 91;
#elif SCOPE_KIND == 10
int scope_dynamic_nodelete = 91;
#endif
