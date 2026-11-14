/* 此库交给系统 dlopen，专门证明外层注册锁没有跨系统构造器持有。 */
extern void test_concurrent_probe(void);
extern void test_mark(int);
__attribute__((constructor)) static void initialize(void) { test_concurrent_probe(); }
/* 系统 dlclose 同样会执行任意用户代码，注册锁不能跨过这个析构回调。 */
__attribute__((destructor)) static void finalize(void) { test_concurrent_probe(); test_mark(4000); }
int system_dependency_value = 33;
