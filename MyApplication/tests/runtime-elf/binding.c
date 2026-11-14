/* 同一源码分别生成普通、PROTECTED、SYMBOLIC 三个库，验证三种真实链接语义。 */
#ifdef PROTECTED_BINDING
__attribute__((visibility("protected")))
#endif
int collision_value = 5;
int read_collision(void) { return collision_value; }
extern char absolute_zero;
static char* absolute_with_addend = &absolute_zero + 7;
long read_absolute(void) { return (long)absolute_with_addend; }
