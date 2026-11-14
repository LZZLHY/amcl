/* 真实本模块 TLSDESC；构造计数用于证明失败发生在构造器之前。 */
extern void test_mark(int);
static __thread int local_value = 37;
__attribute__((visibility("default"))) int* tls_address(void) { return &local_value; }
__attribute__((constructor)) static void initialized(void) { test_mark(1); }
