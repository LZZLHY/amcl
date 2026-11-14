/* 同一原始 DSO 图用于 glibc 对照和 custom/system 混合回归；系统部分只能位于 system-only。 */
#if MIXED_KIND == 0
extern int mixed_left_anchor(void), mixed_right_anchor(void), mixed_choice;
int mixed_root_anchor(void) { return mixed_left_anchor() + mixed_right_anchor(); }
int mixed_relocated_choice(void) { return mixed_choice; }
int mixed_resolver_visible = 61;
#elif MIXED_KIND == 1
extern int mixed_leaf_anchor(void);
int mixed_left_anchor(void) { return mixed_leaf_anchor(); }
#elif MIXED_KIND == 2
int mixed_choice = 42;
int mixed_right_anchor(void) { return 2; }
#elif MIXED_KIND == 3
int mixed_choice = 7;
int mixed_leaf_anchor(void) { return 3; }
/* 私有边不能取得NOLOAD句柄，但真实公开祖先dlsym仍可按原生规则返回这些定义。 */
__thread int mixed_private_tls = 57;
__attribute__((visibility("hidden"))) int mixed_private_hidden = 123;
extern void scope_resolver_probe(void);
static int private_implementation(void) { return 73; }
static void* private_resolver(void) { scope_resolver_probe(); return (void*)private_implementation; }
int mixed_private_ifunc(void) __attribute__((ifunc("private_resolver")));
#elif MIXED_KIND == 4
extern int mixed_middle_anchor(void);
int mixed_right_anchor(void) { return mixed_middle_anchor(); }
#elif MIXED_KIND == 5
extern int mixed_deep_anchor(void);
int mixed_middle_anchor(void) { return mixed_deep_anchor(); }
#elif MIXED_KIND == 6
int mixed_choice = 99;
int mixed_deep_anchor(void) { return 6; }
#elif MIXED_KIND == 7
extern int mixed_leaf_anchor(void);
int mixed_choice = 13;
int mixed_left_anchor(void) { return mixed_leaf_anchor(); }
#elif MIXED_KIND == 8
/* resolver 由真实系统 dlsym 进入，不能由测试驱动直接调用替代。 */
extern void scope_resolver_probe(void);
extern void scope_resolver_finalized(void);
static int implementation(void) { return 73; }
static void* resolver(void) { scope_resolver_probe(); return (void*)implementation; }
int mixed_ifunc(void) __attribute__((ifunc("resolver")));
int mixed_ifunc_anchor(void) { return 8; }
__attribute__((destructor)) static void finish(void) { scope_resolver_finalized(); }
#elif MIXED_KIND == 9
extern int mixed_ifunc_anchor(void);
int mixed_custom_anchor(void) { return mixed_ifunc_anchor(); }
int mixed_resolver_visible = 61;
#elif MIXED_KIND == 10
/* 经生产重定位得到真实 libc 三个入口；返回值和 errno 分开传回，避免把 -1 当成功。 */
#include <errno.h>
#include <sys/stat.h>
int permission_path(const char* path, int* error) {
    errno = 0; int result = chmod(path, 0600); *error = errno; return result;
}
int permission_fd(int fd, int* error) {
    errno = 0; int result = fchmod(fd, 0600); *error = errno; return result;
}
int permission_at(int fd, const char* path, int* error) {
    errno = 0; int result = fchmodat(fd, path, 0600, 0); *error = errno; return result;
}
#elif MIXED_KIND == 11
/* 刻意没有 DT_NEEDED；该导入必须由 GLOBAL 查询形成实际 provider 所有权边。 */
extern int mixed_ifunc_anchor(void);
int mixed_bound_anchor(void) { return mixed_ifunc_anchor(); }
#elif MIXED_KIND == 12
/* 绑定 IFUNC 时 resolver 主动关闭提供者；consumer 必须在查询临时保活结束前取得依赖。 */
extern int mixed_ifunc(void);
int mixed_bound_ifunc(void) { return mixed_ifunc(); }
#endif
