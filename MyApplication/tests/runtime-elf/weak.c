/* 未解析 weak 数据引用合法，必须保持可装载及空值语义。 */
extern int absent_optional_value __attribute__((weak));
int weak_value(void) { return &absent_optional_value ? absent_optional_value : 0; }
