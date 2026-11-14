/* 验证 DT_FINI 的独立入口，与 fini_array 分开计数。 */
extern void test_mark(int);
void finish_library(void) { test_mark(100); }
