/* 对端构造通过真实函数/GOT 读取两库数据，避免只测“返回一个句柄”的空验收。 */
extern int cycle_sum(void);
extern void test_mark(int);
int cycle_b_value = 7;
__attribute__((constructor)) static void initialize(void) { test_mark(cycle_sum()); }
