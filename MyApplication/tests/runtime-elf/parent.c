/* 依赖已能链接，但根对象还有强符号缺失：整批回滚不得留下依赖构造副作用。 */
extern int good_value;
extern int missing_parent_function(void);
int parent_value(void) { return good_value + missing_parent_function(); }
