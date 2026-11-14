/* 已有局部同名定义不允许满足另一库的强导入；保留到 .symtab 供负例真实触发旧路径。 */
__attribute__((used, noinline)) static int local_only(void) { return 91; }
__attribute__((visibility("hidden"))) int missing_platform_function(void) { return 92; }
int collision_value = 31;
/* SHN_ABS 的零值和普通整数值都不是 loadBias 相对地址。 */
__asm__(".globl absolute_zero\n.set absolute_zero, 0\n.globl absolute_number\n.set absolute_number, 123\n");
