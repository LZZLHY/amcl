package com.amcl.compat.test.foreign;

/** 组合测试业务哨兵；存在于 guard 之前即代表可能先访问游戏状态，不能据此宣布安全。 */
public final class ForeignHooks {
    private ForeignHooks() {}
    public static void touch() {}
}
