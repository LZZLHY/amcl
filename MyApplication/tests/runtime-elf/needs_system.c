/* 依赖只存在于系统搜索路径，不在自定义 loader 的直接路径内。 */
extern int system_dependency_value;
int read_system_value(void) { return system_dependency_value + 1; }
