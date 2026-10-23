/* 无外部依赖的真实 AArch64 ELF；构造器回调由宿主计数，验证发布顺序。 */
extern void test_mark(int);
int good_value = 17;
__attribute__((constructor)) static void initialize(void) { test_mark(1); }
