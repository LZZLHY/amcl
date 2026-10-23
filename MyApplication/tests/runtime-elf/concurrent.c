/* 构造器创建的查询线程不能看到半初始化句柄，也不能被 loader 注册锁卡死。 */
extern void test_concurrent_probe(void);
__attribute__((constructor)) static void initialize(void) { test_concurrent_probe(); }
int concurrent_value = 3;
