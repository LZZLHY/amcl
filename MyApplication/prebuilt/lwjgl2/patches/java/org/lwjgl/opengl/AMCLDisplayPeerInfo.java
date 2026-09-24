/*
 * AMCLDisplayPeerInfo — HarmonyOS NEXT / AMCL 专用 PeerInfo（替代 X11 的 LinuxDisplayPeerInfo）。
 *
 * LWJGL2 把"像素格式/帧缓冲配置"装在 PeerInfo 的 handle(ByteBuffer) 里，X11 版存 X11PeerInfo
 * 结构（Display 指针 / visual / glx config）。AMCL 走 GLFW+EGL+gl4es 基座，窗口与 GL 上下文由 GLFW 绑定、
 * 进程内单窗口，故 peer handle 不需要承载 X 配置——native 侧用单例 GLFWwindow*。这里 handle 只是
 * 一个小的 direct ByteBuffer 占位（native initDrawable 可往里写句柄，目前用单例无需）。
 *
 * 见 docs/adaptation/LWJGL_MULTIVERSION_PLAN.md §11.13。
 */
package org.lwjgl.opengl;

import org.lwjgl.LWJGLException;
import org.lwjgl.BufferUtils;

import java.nio.ByteBuffer;

final class AMCLDisplayPeerInfo extends PeerInfo {

	AMCLDisplayPeerInfo(PixelFormat pixel_format) throws LWJGLException {
		// 16 字节占位（足够存一个指针/句柄；当前单例模型 native 不依赖其内容）。
		super(BufferUtils.createByteBuffer(16));
	}

	protected void doLockAndInitHandle() throws LWJGLException {
		// GLFW/EGL 模型无需 X 锁；单例窗口已就绪，no-op。
	}

	protected void doUnlock() throws LWJGLException {
		// no-op
	}
}
