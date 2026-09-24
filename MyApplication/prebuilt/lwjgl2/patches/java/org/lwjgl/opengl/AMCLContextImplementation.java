/*
 * AMCLContextImplementation — HarmonyOS NEXT / AMCL 专用 GL 上下文实现
 * （替代 X11/GLX 的 LinuxContextImplementation）。
 *
 * 桥接到 AMCL 既有 libglfw 基座：GLFW 把窗口与 GL 上下文绑定，进程内单窗口/单上下文。
 * 故所有方法作用于 native 侧单例（context_handle/peer_info 仅作占位）。GL 函数翻译由 gl4es 提供
 * （见 extgl_ohos.c）。时序沿用 glfw_compat：创建后释放、渲染线程再 makeCurrent。
 *
 * 见 docs/adaptation/LWJGL_MULTIVERSION_PLAN.md §11.13。
 */
package org.lwjgl.opengl;

import org.lwjgl.LWJGLException;

import java.nio.ByteBuffer;
import java.nio.IntBuffer;

final class AMCLContextImplementation implements ContextImplementation {

	public ByteBuffer create(PeerInfo peer_info, IntBuffer attribs, ByteBuffer shared_context_handle) throws LWJGLException {
		ByteBuffer h = nCreate();
		if (h == null)
			throw new LWJGLException("AMCL: failed to create GL context (glfw/egl)");
		return h;
	}

	public void swapBuffers() throws LWJGLException {
		nSwapBuffers();
	}

	public void releaseDrawable(ByteBuffer context_handle) throws LWJGLException {
		// GLFW 模型无独立 drawable，no-op。
	}

	public void releaseCurrentContext() throws LWJGLException {
		nReleaseCurrentContext();
	}

	public void update(ByteBuffer context_handle) {
		// 窗口尺寸变化由 framebuffer 回调处理，no-op。
	}

	public void makeCurrent(PeerInfo peer_info, ByteBuffer handle) throws LWJGLException {
		nMakeCurrent();
	}

	public boolean isCurrent(ByteBuffer handle) throws LWJGLException {
		return nIsCurrent();
	}

	public void setSwapInterval(int value) {
		nSetSwapInterval(value);
	}

	public void destroy(PeerInfo peer_info, ByteBuffer handle) throws LWJGLException {
		nDestroy();
	}

	private static native ByteBuffer nCreate() throws LWJGLException;
	private static native void nSwapBuffers() throws LWJGLException;
	private static native void nReleaseCurrentContext() throws LWJGLException;
	private static native void nMakeCurrent() throws LWJGLException;
	private static native boolean nIsCurrent() throws LWJGLException;
	private static native void nSetSwapInterval(int value);
	private static native void nDestroy() throws LWJGLException;
}
