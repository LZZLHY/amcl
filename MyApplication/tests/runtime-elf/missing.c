/* 具有真实强导入和构造器；正确 loader 必须在任何构造器运行前拒绝。 */
extern void test_mark(int);
extern int missing_platform_function(void);
int bad_export = 88;
int use_missing(void) { return missing_platform_function(); }
__attribute__((constructor)) static void initialize(void) { test_mark(100); }
