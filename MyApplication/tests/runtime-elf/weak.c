/* 未解析 weak 数据引用合法，必须保持可装载及空值语义。 */
extern int absent_optional_value __attribute__((weak));
int weak_value(void) { return &absent_optional_value ? absent_optional_value : 0; }
/* 未解析 weak 的 S=0，ABS64 仍必须保留非零 addend。 */
static char* weak_address = (char*)&absent_optional_value + 5;
long weak_addend(void) { return (long)weak_address; }
