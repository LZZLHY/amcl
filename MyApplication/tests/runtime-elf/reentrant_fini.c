/* 关闭过程重开同一路径，必须得到新对象，旧对象清理不能删掉新名字索引。 */
extern void test_fini_reopen(void);
int reentrant_value = 23;
__attribute__((destructor)) static void finalize(void) { test_fini_reopen(); }
