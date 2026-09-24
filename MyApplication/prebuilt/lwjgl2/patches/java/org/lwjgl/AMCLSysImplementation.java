/*
 * AMCLSysImplementation — HarmonyOS NEXT / AMCL 专用 SysImplementation
 * （替代 LinuxSysImplementation）。
 *
 * 与 LinuxSysImplementation 的关键差异：**去掉其静态块里的 AWT/jawt 加载**
 * （`java.awt.Toolkit.getDefaultToolkit()` + `System.loadLibrary("jawt")`）——
 * AMCL 走 headless，老 MC 用 Display 而非 AWT Canvas，加载 AWT 既无必要又可能
 * 在 headless-only JDK 上出问题。其余沿用 J2SESysImplementation（getTime/alert/clipboard）。
 *
 * getRequiredJNIVersion() 必须与 native getJNIVersion()（amcl_lwjgl2_backend.c）一致 = 19。
 * 见 docs/adaptation/LWJGL_MULTIVERSION_PLAN.md §11.13。
 */
package org.lwjgl;

final class AMCLSysImplementation extends J2SESysImplementation {

	/** 必须与 amcl_lwjgl2_backend.c 的 getJNIVersion() 返回值一致。 */
	private static final int JNI_VERSION = 19;

	public int getRequiredJNIVersion() {
		return JNI_VERSION;
	}

	public boolean openURL(final String url) {
		// 移动端不从游戏内开外链；no-op。
		return false;
	}

	public boolean has64Bit() {
		return true;
	}
}
