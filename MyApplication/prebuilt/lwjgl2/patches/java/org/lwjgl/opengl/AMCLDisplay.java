/*
 * AMCLDisplay — HarmonyOS NEXT / AMCL 专用 DisplayImplementation
 * （替代 X11 的 LinuxDisplay）。真·LWJGL2，桥接到 AMCL 既有 libglfw+gl4es 基座。
 *
 * - 窗口/上下文由 GLFW 绑定，进程内单窗口；native 侧维护单例 GLFWwindow*（懒创建：
 *   context.create 早于 Display.createWindow，故首个需要时即建，使用 AMCL_NATIVE_WINDOW
 *   env 提供的 OHOS 原生窗口 + 尺寸）。
 * - 输入（InputImplementation）P2a 先 stub，P2b 接 touch_input 的 CallbackBridge。
 * - gamma/xrandr/pbuffer/cursor/icon 在移动端无意义 → 默认值/no-op。
 *
 * 见 docs/adaptation/LWJGL_MULTIVERSION_PLAN.md §11.13。
 */
package org.lwjgl.opengl;

import org.lwjgl.LWJGLException;
import org.lwjgl.input.Keyboard;
import org.lwjgl.input.Mouse;

import java.awt.Canvas;
import java.nio.ByteBuffer;
import java.nio.FloatBuffer;
import java.nio.IntBuffer;

final class AMCLDisplay implements DisplayImplementation {

	private DisplayMode currentMode;
	private boolean closeRequested;

	// ---- 输入状态（P2b：桥接 libglfw input_bridge）----
	private final int[] evTmp = new int[5];
	private EventQueue mouseEventQueue;
	private EventQueue keyboardEventQueue;
	// 事件暂存缓冲：用默认 big-endian（与 Mouse/Keyboard 的 readBuffer = ByteBuffer.allocate 一致），
	// 否则 readBuffer.getInt() 按 big-endian 解析会读出错位的值。
	private final ByteBuffer mouseEventBuf = ByteBuffer.allocate(Mouse.EVENT_SIZE);
	private final ByteBuffer keyboardEventBuf = ByteBuffer.allocate(Keyboard.EVENT_SIZE);
	private final byte[] keyDownState = new byte[Keyboard.KEYBOARD_SIZE]; // 按 LWJGL2 键码索引
	private final byte[] mouseButtonState = new byte[16];                 // 按钮按住状态
	private int accumWheel;        // poll 间累积滚轮（pollMouse 取走清零）
	private boolean grabbed;       // 当前抓取状态（== Mouse.isGrabbed()）
	private double lastCursorX, lastCursorY; // grabbed 模式增量基准（保留小数避免漂移）

	// ---- 窗口 ----
	public DisplayMode init() throws LWJGLException {
		int w = nGetDesktopWidth();
		int h = nGetDesktopHeight();
		if (w <= 0) w = 1280;
		if (h <= 0) h = 720;
		currentMode = new DisplayMode(w, h, 32, 60);
		return currentMode;
	}

	public void createWindow(DrawableLWJGL drawable, DisplayMode mode, Canvas parent, int x, int y) throws LWJGLException {
		this.currentMode = mode;
		if (!nCreateWindow(mode.getWidth(), mode.getHeight()))
			throw new LWJGLException("AMCL: failed to create window (glfw/egl)");
		closeRequested = false;
	}

	public void destroyWindow() {
		nDestroyWindow();
	}

	public void update() {
		nUpdate();
		if (nIsCloseRequested())
			closeRequested = true;
	}

	public void reshape(int x, int y, int width, int height) {
		// 嵌入式全屏，窗口尺寸由 XComponent surface 决定，no-op。
	}

	public boolean isCloseRequested() {
		boolean r = closeRequested;
		closeRequested = false;
		return r;
	}

	public boolean isVisible()  { return true; }
	public boolean isActive()   { return true; }
	public boolean isDirty()    { return false; }
	public void setTitle(String title) { nSetTitle(title); }

	public int getWidth()  { return nGetWidth(); }
	public int getHeight() { return nGetHeight(); }
	public int getX()      { return 0; }
	public int getY()      { return 0; }
	public float getPixelScaleFactor() { return 1.0f; }
	public boolean wasResized() {
		// 始终上报 resized：MC 1.12 仅在 wasResized()==true 时从 getWidth/getHeight 重读尺寸并
		// resize framebuffer/viewport。MC 初始 displayWidth=854（默认），实际 surface 是全屏
		// （如 2800x1840），单次上报在 1.12.2 实测不稳定（FBO 时机），持续上报最可靠。代价极小：
		// MC 的 resize 块自带 "尺寸未变则跳过"（if displayWidth!=old），稳定后每帧仅两次廉价
		// getWidth/getHeight 比较，不会反复 recreate framebuffer。
		return true;
	}
	public void setResizable(boolean resizable) { /* no-op */ }

	public PeerInfo createPeerInfo(PixelFormat pixel_format, ContextAttribs attribs) throws LWJGLException {
		return new AMCLDisplayPeerInfo(pixel_format);
	}

	// ---- 显示模式（嵌入式：仅当前 surface 尺寸一种）----
	public void switchDisplayMode(DisplayMode mode) throws LWJGLException { this.currentMode = mode; }
	public void resetDisplayMode() { /* no-op */ }
	public DisplayMode[] getAvailableDisplayModes() throws LWJGLException {
		if (currentMode == null) init();
		return new DisplayMode[] { currentMode };
	}

	// ---- gamma / 适配器信息（移动端无意义）----
	public int getGammaRampLength() { return 0; }
	public void setGammaRamp(FloatBuffer gammaRamp) throws LWJGLException { /* no-op */ }
	public String getAdapter() { return null; }
	public String getVersion() { return null; }

	// ---- pbuffer（不支持）----
	public int getPbufferCapabilities() { return 0; }
	public boolean isBufferLost(PeerInfo handle) { return false; }
	public PeerInfo createPbuffer(int width, int height, PixelFormat pixel_format, ContextAttribs attribs,
			IntBuffer pixelFormatCaps, IntBuffer pBufferAttribs) throws LWJGLException {
		throw new LWJGLException("AMCL: Pbuffer not supported");
	}
	public void setPbufferAttrib(PeerInfo handle, int attrib, int value) { }
	public void bindTexImageToPbuffer(PeerInfo handle, int buffer) { }
	public void releaseTexImageFromPbuffer(PeerInfo handle, int buffer) { }

	// ---- 图标（no-op）----
	public int setIcon(ByteBuffer[] icons) { return 0; }

	// ============================================================
	//  InputImplementation —— P2b：桥接 libglfw input_bridge
	//  poll = 当前状态（光标/按住）；read = 事件队列（Mouse.next()/Keyboard.next()）。
	// ============================================================
	public boolean hasWheel() { return true; }
	public int getButtonCount() { return 5; }

	public void createMouse() throws LWJGLException {
		mouseEventQueue = new EventQueue(Mouse.EVENT_SIZE);
		for (int i = 0; i < mouseButtonState.length; i++) mouseButtonState[i] = 0;
		accumWheel = 0;
	}
	public void destroyMouse() { mouseEventQueue = null; }

	public void createKeyboard() throws LWJGLException {
		keyboardEventQueue = new EventQueue(Keyboard.EVENT_SIZE);
		for (int i = 0; i < keyDownState.length; i++) keyDownState[i] = 0;
	}
	public void destroyKeyboard() { keyboardEventQueue = null; }

	// 从 native 取所有待处理事件，分发到鼠标/键盘事件队列并更新按住状态。
	// 幂等：四个 poll/read 方法都先调它，谁先调谁把 native 队列排空到 Java 队列，
	// 后调者发现 native 队列空、各自只消费自己的 Java 队列，事件不丢不串。
	private void drainEvents() {
		if (mouseEventQueue == null && keyboardEventQueue == null) return;
		while (nNextEvent(evTmp)) {
			int type = evTmp[0];
				switch (type) {
				case 1009: { // EVENT_TYPE_INPUT_RESET：native ring overflow / window recreate
					/*
					 * native 与 Java 各自维护一份 polling state。overflow 时 native 会丢弃整批旧事件，
					 * 所以 Java 可能已经看过 PRESS、却永远收不到被覆盖的 RELEASE。reset 最常发生在
					 * Java EventQueue 已满时，直接追加 RELEASE 会被 putEvent 静默拒绝。必须先清除这批
					 * 已失去完整边界的旧排队事件，再为 Java 已观察到的 down state 排入 RELEASE；这样
					 * 队列容量优先留给收尾边沿，polling state 也在本次 drain 返回前归零。
					 */
					if (mouseEventQueue != null) mouseEventQueue.clearEvents();
					if (keyboardEventQueue != null) keyboardEventQueue.clearEvents();
					for (int button = 0; button < mouseButtonState.length; button++) {
						if (mouseButtonState[button] != 0) putMouseEvent(button, false, 0);
						mouseButtonState[button] = 0;
					}
					for (int key = 0; key < keyDownState.length; key++) {
						if (keyDownState[key] != 0) putKeyEvent(key, false, 0, false);
						keyDownState[key] = 0;
					}
					accumWheel = 0;
					break;
				}
				case 1006: { // EVENT_TYPE_MOUSE_BUTTON: i1=button, i2=action
					int button = evTmp[1];
					boolean pressed = evTmp[2] != 0;
					if (button >= 0 && button < mouseButtonState.length)
						mouseButtonState[button] = (byte)(pressed ? 1 : 0);
					putMouseEvent(button, pressed, 0);
					break;
				}
				case 1007: { // EVENT_TYPE_SCROLL: i2=yoffset（步进 ±1）
					int dwheel = evTmp[2] * 120; // LWJGL2 习惯每格 120（同 Win WHEEL_DELTA）
					accumWheel += dwheel;
					putMouseEvent(-1, false, dwheel);
					break;
				}
				case 1005: { // EVENT_TYPE_KEY: i1=glfwKey, i3=action(0 释放/1 按下/2 重复)
					int l2 = glfwToLwjgl2Key(evTmp[1]);
					int action = evTmp[3];
					boolean pressed = action != 0;
					if (l2 > 0 && l2 < keyDownState.length)
						keyDownState[l2] = (byte)(pressed ? 1 : 0);
					putKeyEvent(l2, pressed, 0, action == 2);
					break;
				}
				// ⭐ 2xxx 段：i1 **已经是** LWJGL2（DirectInput）编码，宿主直接从 raw OHOS
				// identity 翻到位，不再经 GLFW。所以这里**不调** glfwToLwjgl2Key ——
				// 那是二次翻译，是本次架构迁移要消除的东西（计划 §一 约束 4）。
				//
				// 为什么用另一组 type 号而不是加一个"编码"字段：老宿主 + 新 Java 与
				// 新宿主 + 老 Java 两个方向都必须自动退化正确。老宿主永不发 2xxx；
				// 老 Java 收到 2xxx 会落进 switch 的 default（丢弃，**不会错译成别的键**）。
				// 加字段做不到后一半：老 Java 读不到那个字段，会把 DirectInput 码当 GLFW 码。
				case 2005: { // 物理键，i1=LWJGL2 键码, i2=平台扫描码, i3=action
					int l2 = evTmp[1];
					int action = evTmp[3];
					boolean pressed = action != 0;
					if (l2 > 0 && l2 < keyDownState.length)
						keyDownState[l2] = (byte)(pressed ? 1 : 0);
					putKeyEvent(l2, pressed, 0, action == 2);
					break;
				}
				case 2006: { // 物理鼠标按钮，i1=LWJGL2 按钮索引（与 GLFW 同序）, i2=action
					int button = evTmp[1];
					boolean pressed = evTmp[2] != 0;
					if (button >= 0 && button < mouseButtonState.length)
						mouseButtonState[button] = (byte)(pressed ? 1 : 0);
					putMouseEvent(button, pressed, 0);
					break;
				}
				case 2007: { // 物理滚轮，i2=格数（宿主已按 LWJGL2 的"格"分好）
					int dwheel = evTmp[2] * 120; // 同 1007：LWJGL2 每格 120
					accumWheel += dwheel;
					putMouseEvent(-1, false, dwheel);
					break;
				}
				case 2009: { // typed 侧复位，处置与 1009 逐字相同（刻意不合并 case：
					// 1009 是 ring overflow / 窗口重建，2009 是 core 的会话/后端边界，
					// 成因不同而处置相同，合并会让将来只想改一边的人改错另一边）。
					if (mouseEventQueue != null) mouseEventQueue.clearEvents();
					if (keyboardEventQueue != null) keyboardEventQueue.clearEvents();
					for (int button = 0; button < mouseButtonState.length; button++) {
						if (mouseButtonState[button] != 0) putMouseEvent(button, false, 0);
						mouseButtonState[button] = 0;
					}
					for (int key = 0; key < keyDownState.length; key++) {
						if (keyDownState[key] != 0) putKeyEvent(key, false, 0, false);
						keyDownState[key] = 0;
					}
					accumWheel = 0;
					break;
				}
				case 1000: // EVENT_TYPE_CHAR
				case 1001: // EVENT_TYPE_CHAR_MODS: i1=codepoint
					// 字符事件用 key=0（KEY_NONE）+ character，MC 文本框据 character 写入；
					// 特殊键（退格/方向键等）走上面 KEY 事件的 keyCode 分支。
					putKeyEvent(0, true, evTmp[1], false);
					break;
			}
		}
	}

	private void putMouseEvent(int button, boolean state, int dwheel) {
		if (mouseEventQueue == null) return;
		int x, y;
		if (grabbed) {
			// 抓取模式：视角靠 poll 增量；按钮事件不需要坐标（MC 游戏内点击不读 eventX/Y）。
			x = 0; y = 0;
		} else {
			// 菜单模式：MC GuiScreen 用 getEventX/getEventY 定位点击，必须是绝对像素（左下原点）。
			int h = getHeight();
			x = (int)Math.round(nGetCursorX());
			y = h - (int)Math.round(nGetCursorY());
		}
		mouseEventBuf.clear();
		mouseEventBuf.put((byte) button);
		mouseEventBuf.put((byte)(state ? 1 : 0));
		mouseEventBuf.putInt(x);
		mouseEventBuf.putInt(y);
		mouseEventBuf.putInt(dwheel);
		mouseEventBuf.putLong(System.nanoTime());
		mouseEventBuf.flip();
		mouseEventQueue.putEvent(mouseEventBuf);
	}

	private void putKeyEvent(int key, boolean state, int character, boolean repeat) {
		if (keyboardEventQueue == null) return;
		keyboardEventBuf.clear();
		keyboardEventBuf.putInt(key);
		keyboardEventBuf.put((byte)(state ? 1 : 0));
		keyboardEventBuf.putInt(character);
		keyboardEventBuf.putLong(System.nanoTime());
		keyboardEventBuf.put((byte)(repeat ? 1 : 0));
		keyboardEventBuf.flip();
		keyboardEventQueue.putEvent(keyboardEventBuf);
	}

	public void pollMouse(IntBuffer coord_buffer, ByteBuffer buttons) {
		drainEvents();
		if (grabbed) {
			// 返回自上次 poll 以来的增量（截断取整、保留小数余量避免长期漂移）。
			double dxRaw = nGetCursorX() - lastCursorX;
			double dyRaw = nGetCursorY() - lastCursorY;
			int dx = (int) dxRaw;
			int dy = (int) dyRaw;
			lastCursorX += dx;
			lastCursorY += dy;
			coord_buffer.put(0, dx);
			coord_buffer.put(1, -dy); // 屏幕向下为正 → LWJGL2 向上为正，翻转
		} else {
			int h = getHeight();
			coord_buffer.put(0, (int)Math.round(nGetCursorX()));
			coord_buffer.put(1, h - (int)Math.round(nGetCursorY()));
		}
		coord_buffer.put(2, accumWheel);
		accumWheel = 0;
		int n = buttons.remaining();
		for (int i = 0; i < n && i < mouseButtonState.length; i++)
			buttons.put(buttons.position() + i, mouseButtonState[i]);
	}

	public void readMouse(ByteBuffer buffer) {
		drainEvents();
		if (mouseEventQueue != null) mouseEventQueue.copyEvents(buffer);
	}

	public void grabMouse(boolean grab) {
		if (grab != grabbed) {
			grabbed = grab;
			nSetGrab(grab);
			// 重置增量基准，避免切换瞬间产生巨大 delta。
			lastCursorX = nGetCursorX();
			lastCursorY = nGetCursorY();
		}
	}

	public int getNativeCursorCapabilities() { return 0; }
	public void setCursorPosition(int x, int y) { /* 增量模型，无需设置 */ }
	public void setNativeCursor(Object handle) throws LWJGLException { }
	public int getMinCursorSize() { return 0; }
	public int getMaxCursorSize() { return 0; }

	public void pollKeyboard(ByteBuffer keyDownBuffer) {
		drainEvents();
		int n = keyDownBuffer.remaining();
		int base = keyDownBuffer.position();
		for (int i = 0; i < n && i < keyDownState.length; i++)
			keyDownBuffer.put(base + i, keyDownState[i]);
	}

	public void readKeyboard(ByteBuffer buffer) {
		drainEvents();
		if (keyboardEventQueue != null) keyboardEventQueue.copyEvents(buffer);
	}

	public Object createCursor(int width, int height, int xHotspot, int yHotspot, int numImages,
			IntBuffer images, IntBuffer delays) throws LWJGLException { return null; }
	public void destroyCursor(Object cursor_handle) { }
	public boolean isInsideWindow() { return true; }

	// GLFW 键码 → LWJGL2（org.lwjgl.input.Keyboard.KEY_*，基于 DirectInput 扫描码）。
	// touch_input / NAPI 虚拟键盘发的是 GLFW 键码，这里翻译成 LWJGL2 键码。
	private static int glfwToLwjgl2Key(int g) {
		switch (g) {
			// 字母 A-Z（GLFW 65-90）
			case 65: return 0x1E; case 66: return 0x30; case 67: return 0x2E; case 68: return 0x20;
			case 69: return 0x12; case 70: return 0x21; case 71: return 0x22; case 72: return 0x23;
			case 73: return 0x17; case 74: return 0x24; case 75: return 0x25; case 76: return 0x26;
			case 77: return 0x32; case 78: return 0x31; case 79: return 0x18; case 80: return 0x19;
			case 81: return 0x10; case 82: return 0x13; case 83: return 0x1F; case 84: return 0x14;
			case 85: return 0x16; case 86: return 0x2F; case 87: return 0x11; case 88: return 0x2D;
			case 89: return 0x15; case 90: return 0x2C;
			// 数字 0-9（GLFW 48-57）
			case 48: return 0x0B; case 49: return 0x02; case 50: return 0x03; case 51: return 0x04;
			case 52: return 0x05; case 53: return 0x06; case 54: return 0x07; case 55: return 0x08;
			case 56: return 0x09; case 57: return 0x0A;
			// 符号
			case 32: return 0x39; // SPACE
			case 39: return 0x28; // APOSTROPHE
			case 44: return 0x33; // COMMA
			case 45: return 0x0C; // MINUS
			case 46: return 0x34; // PERIOD
			case 47: return 0x35; // SLASH
			case 59: return 0x27; // SEMICOLON
			case 61: return 0x0D; // EQUAL
			case 91: return 0x1A; // LEFT_BRACKET
			case 92: return 0x2B; // BACKSLASH
			case 93: return 0x1B; // RIGHT_BRACKET
			case 96: return 0x29; // GRAVE_ACCENT
			// 控制键
			case 256: return 0x01; // ESCAPE
			case 257: return 0x1C; // ENTER → RETURN
			case 258: return 0x0F; // TAB
			case 259: return 0x0E; // BACKSPACE → BACK
			case 260: return 0xD2; // INSERT
			case 261: return 0xD3; // DELETE
			case 262: return 0xCD; // RIGHT
			case 263: return 0xCB; // LEFT
			case 264: return 0xD0; // DOWN
			case 265: return 0xC8; // UP
			case 266: return 0xC9; // PAGE_UP → PRIOR
			case 267: return 0xD1; // PAGE_DOWN → NEXT
			case 268: return 0xC7; // HOME
			case 269: return 0xCF; // END
			case 280: return 0x3A; // CAPS_LOCK → CAPITAL
			case 281: return 0x46; // SCROLL_LOCK → SCROLL
			case 282: return 0x45; // NUM_LOCK → NUMLOCK
			case 284: return 0xC5; // PAUSE
			// 功能键 F1-F12（GLFW 290-301）
			case 290: return 0x3B; case 291: return 0x3C; case 292: return 0x3D; case 293: return 0x3E;
			case 294: return 0x3F; case 295: return 0x40; case 296: return 0x41; case 297: return 0x42;
			case 298: return 0x43; case 299: return 0x44; case 300: return 0x57; case 301: return 0x58;
			// 小键盘（GLFW 320-336）
			case 320: return 0x52; case 321: return 0x4F; case 322: return 0x50; case 323: return 0x51;
			case 324: return 0x4B; case 325: return 0x4C; case 326: return 0x4D; case 327: return 0x47;
			case 328: return 0x48; case 329: return 0x49;
			case 330: return 0x53; // KP_DECIMAL
			case 331: return 0xB5; // KP_DIVIDE
			case 332: return 0x37; // KP_MULTIPLY
			case 333: return 0x4A; // KP_SUBTRACT
			case 334: return 0x4E; // KP_ADD
			case 335: return 0x9C; // KP_ENTER → NUMPADENTER
			case 336: return 0x8D; // KP_EQUAL → NUMPADEQUALS
			// 修饰键
			case 340: return 0x2A; // LEFT_SHIFT → LSHIFT
			case 341: return 0x1D; // LEFT_CONTROL → LCONTROL
			case 342: return 0x38; // LEFT_ALT → LMENU
			case 343: return 0xDB; // LEFT_SUPER → LMETA
			case 344: return 0x36; // RIGHT_SHIFT → RSHIFT
			case 345: return 0x9D; // RIGHT_CONTROL → RCONTROL
			case 346: return 0xB8; // RIGHT_ALT → RMENU
			case 347: return 0xDC; // RIGHT_SUPER → RMETA
			case 348: return 0xDD; // MENU → APPS
			default: return 0;     // KEY_NONE
		}
	}

	// ============================================================
	//  native（实现于 amcl_lwjgl2_backend.c，桥接 libglfw）
	// ============================================================
	private static native int nGetDesktopWidth();
	private static native int nGetDesktopHeight();
	private static native boolean nCreateWindow(int width, int height);
	private static native void nDestroyWindow();
	private static native void nUpdate();
	private static native boolean nIsCloseRequested();
	private static native int nGetWidth();
	private static native int nGetHeight();
	private static native void nSetTitle(String title);
	// 输入桥接（P2b）
	private static native double nGetCursorX();
	private static native double nGetCursorY();
	private static native boolean nNextEvent(int[] out);
	private static native void nSetGrab(boolean grab);
}
