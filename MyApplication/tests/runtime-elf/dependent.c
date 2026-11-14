/* 两个独立根共享 libgood；任一根关闭都不能提前破坏另一个根的 GOT 或数据。 */
extern int good_value;
extern void test_mark(int);
int dependency_value(void) { return good_value; }
__attribute__((destructor)) static void finalize(void) { test_mark(good_value == 17 ? 2000 : 900000); }
