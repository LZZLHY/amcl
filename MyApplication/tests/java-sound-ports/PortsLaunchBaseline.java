package com.sun.media.sound;

/** 与实际回归使用同一启动选项，但不初始化PortMixer、不装载测试JNI。
 * 该对照只定位启动器自身的CheckJNI诊断；不能替代真实Ports正例资格。 */
public final class PortsLaunchBaseline {
    public static void main(String[] args) {
        System.err.println("PORTS_BASELINE_MAIN_ENTER_NO_NATIVE_LOAD");
    }
}
