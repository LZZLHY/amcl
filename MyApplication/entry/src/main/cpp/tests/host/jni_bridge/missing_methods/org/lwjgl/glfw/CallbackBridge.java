/** 负例专用同名类：缺失方法必须使产品 RegisterNatives 失败，不能仍报告库初始化成功。 */
package org.lwjgl.glfw;
public final class CallbackBridge {
    static { System.loadLibrary("jni_reregister"); }
}
