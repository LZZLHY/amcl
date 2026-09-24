/**
 * GLFWWindowProperties.java — Window property storage for GLFW OHOS
 *
 * Stores window dimensions and other properties that MC/LWJGL code
 * accesses directly by field name (via reflection or direct access).
 *
 * Fields must match what MC expects:
 *   - mGLFWWindowWidth / mGLFWWindowHeight: logical window size
 *   - mGLFWWindowX / mGLFWWindowY: window position (always 0 on mobile)
 */
package org.lwjgl.glfw;

public class GLFWWindowProperties {
    public int mGLFWWindowWidth = 1280;
    public int mGLFWWindowHeight = 720;
    public int mGLFWWindowX = 0;
    public int mGLFWWindowY = 0;

    public GLFWWindowProperties() {
    }

    public GLFWWindowProperties(int width, int height) {
        this.mGLFWWindowWidth = width;
        this.mGLFWWindowHeight = height;
    }
}
