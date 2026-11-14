/* 只有确定返回值的独立 DSO，用于区分安装 native 路径与数据路径的系统装载资格。 */
__attribute__((visibility("default"))) int AmclJdkLoadProbe(void) { return 73; }
