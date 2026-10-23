/* 此库交给系统 dlopen，专门证明外层注册锁没有跨系统构造器持有。 */
extern void test_concurrent_probe(void);
__attribute__((constructor)) static void initialize(void) { test_concurrent_probe(); }
int system_dependency_value = 33;
