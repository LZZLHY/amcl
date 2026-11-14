package com.amcl.audio;

/** 仅策略测试的合成嵌套名：用属性观测静态初始化，不能进入生产 Agent 或 launcher JAR。 */
public final class AudioBackend$UnitInitialization {
    static { System.setProperty("amcl.audio.test.initialized", "true"); }
}
