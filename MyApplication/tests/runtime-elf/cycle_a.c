/* A/B 构成 DT_NEEDED 环；B 构造调用 A，必须等 A/B 重定位都完成后才能执行。 */
extern int cycle_b_value;
int cycle_a_value = 11;
int cycle_sum(void) { return cycle_a_value + cycle_b_value; }
