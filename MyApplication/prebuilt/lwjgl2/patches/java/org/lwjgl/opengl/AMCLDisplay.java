/*
 * AMCLDisplay — HarmonyOS NEXT / AMCL 专用 DisplayImplementation
 * （替代 X11 的 LinuxDisplay）。真·LWJGL2，桥接到 AMCL 既有 libglfw+gl4es 基座。
 *
 * - 窗口/上下文由 GLFW 绑定，进程内单窗口；native 侧维护单例 GLFWwindow*（懒创建：
 *   context.create 早于 Display.createWindow，故首个需要时即建，使用 AMCL_NATIVE_WINDOW
 *   env 提供的 OHOS 原生窗口 + 尺寸）。
 * - 输入保留LWJGL2真实缓存/字节队列，控制贡献仅由neutral owner裁决，next领取旁带ticket。
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
import java.util.LinkedList;

final class AMCLDisplay implements DisplayImplementation {
	// 私有运行期配对协议：只有实际L2初始化才握手，不为能力探测提前加载游戏类。
	// Sys的既有公开JNI_VERSION保持19；独立协议禁止旧Java owner与新neutral模型混跑。
	private static final int AMCL_CONTROL_PROTOCOL = 0x4c324432;
	private static final int AMCL_LOOK_PROTOCOL = 0x4c324c31;

	private DisplayMode currentMode;
	private boolean closeRequested;

	// ---- 真实LWJGL2 ABI缓存、事件队列与neutral交付旁带 ----
	private final int[] evTmp = new int[5];
	private EventQueue mouseEventQueue;
	private EventQueue keyboardEventQueue;
	// 事件暂存缓冲：用默认 big-endian（与 Mouse/Keyboard 的 readBuffer = ByteBuffer.allocate 一致），
	// 否则 readBuffer.getInt() 按 big-endian 解析会读出错位的值。
	private final ByteBuffer mouseEventBuf = ByteBuffer.allocate(Mouse.EVENT_SIZE);
	private final ByteBuffer keyboardEventBuf = ByteBuffer.allocate(Keyboard.EVENT_SIZE);
	private final byte[] keyDownState = new byte[Keyboard.KEYBOARD_SIZE]; // 按 LWJGL2 键码索引
	private final byte[] mouseButtonState = new byte[16];                 // 按钮按住状态
	// Java只保存真实ABI缓存与事件ticket旁带，所有owner规则由neutral端口唯一裁决。
	// 两段FIFO分别对应EventQueue和上游readBuffer；null对应字符/滚轮/移动记录。
	// 不改18字节Keyboard或22字节Mouse记录，不把enqueue/copy冒充游戏next领取。
	// 真实Keyboard/Mouse/Display调用都沿上游GlobalLock串行，包含不同线程next/poll与销毁；
	// JNI沿原GlobalLock允许不同线程串行poll/next；不新增创建线程门，不重绑旧窗口。
	private long controlConsumer;
	private final long[] controlTmp = new long[9];
	private final long[] lookTmp = new long[11];
	private final LinkedList<long[]> keyboardQueued = new LinkedList<long[]>();
	private final LinkedList<long[]> mouseQueued = new LinkedList<long[]>();
	private final LinkedList<long[]> keyboardRead = new LinkedList<long[]>();
	private final LinkedList<long[]> mouseRead = new LinkedList<long[]>();
	// Keyboard独立寿命由完整上游create成功后取得的原lease界定，不能借Mouse先开的consumer。
	// long[3]固定为consumer/target/generation；字符虽无control ticket，也必须保同一资源旁带。
	// 两段scope FIFO与18字节记录、ticket FIFO逐条同移，next核原scope而不从current补戳。
	private long[] keyboardLease;
	private final LinkedList<long[]> keyboardQueuedScopes = new LinkedList<long[]>();
	private final LinkedList<long[]> keyboardReadScopes = new LinkedList<long[]>();
	// supplementary scalar的两个18B记录共享同一私有组对象：0未开始、1已实际返回第一
	// 单元、2完整返回、-1取消。null表示原单记录；绝不从surrogate值或timestamp猜组。
	// 两FIFO与原scope/ticket逐条同移，仅原GlobalLock下修改，不新增Native资格或公开载荷。
	private final LinkedList<long[]> keyboardQueuedScalars = new LinkedList<long[]>();
	private final LinkedList<long[]> keyboardReadScalars = new LinkedList<long[]>();
	// 原drain的JNI边缘可能同步回入。领取前flight不能递归使用同一个evTmp或原缓冲。
	private boolean inputDraining;
	private int accumWheel;        // poll 间累积滚轮（pollMouse 取走清零）
	private boolean grabbed;       // 当前抓取状态（== Mouse.isGrabbed()）
	private double lastCursorX, lastCursorY; // grabbed 模式增量基准（保留小数避免漂移）
	// 这些值仅是本ABI已经安装的prefix cursor及整数记录舍入基准，不是producer尾量/
	// 平滑/速度政策。grabbed poll不能再从未来全局snapshot取得尚未运输到此consumer的量。
	private double lookCursorX, lookCursorY, lookEventCursorX, lookEventCursorY;
	private boolean lookReady;
	// 只借已 clone 的11槽生产 emission；最多各一份待缓存读回和本次 poll view。
	// 它们不持生产 ticket、不延迟 STATE_FINAL，不从最新坐标或消费者重建原身份。
	// 可选能力缺席时保持 null，原输入 API 不保存影子、不热调用新的诊断 JNI。
	private boolean lookLatencyAvailable;
	private long[] lookLatencyPending, lookLatencyPoll;

	/** 覆写或生命周期退休只结束诊断；先清引用，防止同步重入再借原影子。 */
	private void clearLookLatency(int outcome) {
		long[] pending = lookLatencyPending, view = lookLatencyPoll;
		lookLatencyPending = null; lookLatencyPoll = null;
		if (lookLatencyAvailable) {
			if (pending != null) nLookLatencyFinish(pending, outcome);
			if (view != null && view != pending) nLookLatencyFinish(view, outcome);
		}
	}

	/** 原 cache write 后复制身份，旧缓存未读回只记 SKIPPED，不冒称 Mouse.poll。 */
	private void cacheLookLatency(long[] emission) {
		if (!lookLatencyAvailable) return;
		clearLookLatency(8);
		nLookLatencyNote(emission, 4);
		lookLatencyPending = emission;
	}

	/** drainEvents 已完成、本 view 写入前冻结原 emission；此前未读的 view 只记缺段。 */
	private void beginLookLatencyPoll() {
		if (!lookLatencyAvailable) return;
		long[] previous = lookLatencyPoll;
		lookLatencyPoll = lookLatencyPending; lookLatencyPending = null;
		if (previous != null && previous != lookLatencyPoll) nLookLatencyFinish(previous, 8);
	}

	// ---- 窗口 ----
	public DisplayMode init() throws LWJGLException {
		verifyInputContract();
		int w = nGetDesktopWidth();
		int h = nGetDesktopHeight();
		if (w <= 0) w = 1280;
		if (h <= 0) h = 720;
		currentMode = new DisplayMode(w, h, 32, 60);
		return currentMode;
	}

	public void createWindow(DrawableLWJGL drawable, DisplayMode mode, Canvas parent, int x, int y) throws LWJGLException {
		clearLookLatency(3);
		verifyInputContract();
		this.currentMode = mode;
		if (!nCreateWindow(mode.getWidth(), mode.getHeight()))
			throw new LWJGLException("AMCL: failed to create window (glfw/egl)");
		closeRequested = false;
	}

	public void destroyWindow() {
		clearLookLatency(3);
		fenceKeyboard();
		// 同步JNI重入可早于上游Mouse/Keyboard.destroy：保留旧readBuffer槽的取消标记，
		// 让随后next安全跳过它们；不能先丢旁带、留下可被新consumer误认的旧字节。
		cancelRecords(1); cancelRecords(2);
		if (controlConsumer != 0) nControlClose(controlConsumer);
		controlConsumer = 0;
		lookReady = false;
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
	// 焦点事实由宿主有序FOCUS更新；查询前排空已到达事件，不用窗口存在推断前台。
    private boolean inputFocused = true;
    public boolean isActive()   { drainEvents(); return inputFocused; }
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
	//  InputImplementation：兼容运输→neutral末级贡献→真实LWJGL2 ABI
	//  poll = 当前状态（光标/按住）；read = 事件队列（Mouse.next()/Keyboard.next()）。
	// ============================================================
	public boolean hasWheel() { return true; }
	public int getButtonCount() { return 5; }

	public void createMouse() throws LWJGLException {
		clearLookLatency(3);
		openControls();
		double basisX = grabbed ? 0.0 : nGetCursorX(), basisY = grabbed ? 0.0 : nGetCursorY();
		// 先有实际ABI队列，再公布独立Mouse出口。Keyboard或window ready不替代此事实。
		mouseEventQueue = new EventQueue(Mouse.EVENT_SIZE);
		// 先验证原control/basis，再激活实际出口，最后绑定激活后新look epoch；0→1会
		// 推进该backend epoch，不能只在此前bind一次就把首票误当旧资格。
		if (nLookBind(controlConsumer, basisX, basisY) < 0 || nLookSetActive(controlConsumer, true) < 0 ||
				nLookBind(controlConsumer, basisX, basisY) < 0) {
			nLookClose(controlConsumer); mouseEventQueue = null;
			throw new LWJGLException("AMCL: neutral look consumer unavailable");
		}
		lookCursorX = lastCursorX = lookEventCursorX = basisX;
		lookCursorY = lastCursorY = lookEventCursorY = basisY;
		lookReady = true;
		// 新 Java 遇旧 SO 缺可选 JNI 只关闭观察；生产 control/look 配对仍按原协议执行。
		try {
			lookLatencyAvailable = nLookLatencyAvailable();
			if (lookLatencyAvailable) {
				// 三个可选 JNI 必须在同一 Mouse.create 冷边界全部能链接。只保 available
				// 的半组旧/坏 SO 也只能关闭诊断，不能到首次热 cache/poll 才破坏输入。
				// C 的 stage=0/null 分支严格不读钟、不记录、不改 input/票；这是整组
				// 链接探测，不是空票完成，也不授生产强reader或设备READY资格。
				nLookLatencyNote(null, 0);
				nLookLatencyFinish(null, 0);
			}
		}
		catch (LinkageError oldDiagnosticNative) { lookLatencyAvailable = false; }
		for (int i = 0; i < mouseButtonState.length; i++) mouseButtonState[i] = 0;
		accumWheel = 0;
	}
	public void destroyMouse() {
		clearLookLatency(3);
		retireControls(15, 2); discardRecords(2); mouseEventQueue = null;
		lookReady = false;
		if (controlConsumer != 0) nLookClose(controlConsumer);
	}

	public void createKeyboard() throws LWJGLException {
		openControls();
		// 这里只建立implementation队列；上游仍须分配readBuffer并reset，不能在此宣布成功。
		keyboardEventQueue = new EventQueue(Keyboard.EVENT_SIZE);
		for (int i = 0; i < keyDownState.length; i++) keyDownState[i] = 0;
	}
	public void destroyKeyboard() {
		// 先围栏原lease，使运输、cache及原readBuffer里的键/字符立即失权；Mouse保持独立寿命。
		fenceKeyboard();
		try { retireKeyboardControls(); }
		finally { discardRecords(1); keyboardEventQueue = null; }
	}

	/**
	 * 由真实Keyboard.create在readBuffer分配及reset全部完成后、仍持原GlobalLock调用。
	 * 新资源只从当前权威仍held的来源建立基线，走原applyKeyPlane写真实cache/队列；
	 * 瞬时tap、已UP及旧字符不在held集合内，绝不能重放退休transport或旧事件记录。
	 */
	void keyboardCompleteCreate() throws LWJGLException {
		if (keyboardEventQueue == null || keyboardLease != null)
			throw new LWJGLException("AMCL: invalid Keyboard final create state");
		long[] origin = new long[3];
		if (nKeyboardCompleteCreate(controlConsumer, origin) != 1)
			throw new LWJGLException("AMCL: Keyboard final create lease unavailable");
		keyboardLease = origin;
		// 仅此资源创建边界读取持有事实。legacy保GLFW命名空间并翻译一次，typed已是L2码。
		for (int code = 1; code <= 348; code++) {
			if (glfwToLwjgl2Key(code) == 0) continue;
			int held = nKeyboardHeld(origin, 1, code);
			if (held < 0) throw new LWJGLException("AMCL: Keyboard legacy baseline lease stale");
			if (held == 1) applyKeyPlane(1, glfwToLwjgl2Key(code), 0, 1);
		}
		for (int code = 1; code < keyDownState.length; code++) {
			int held = nKeyboardHeld(origin, 2, code);
			if (held < 0) throw new LWJGLException("AMCL: Keyboard typed baseline lease stale");
			if (held == 1) applyKeyPlane(2, code, 0, 1);
		}
		if (nKeyboardValidate(origin) != 1)
			throw new LWJGLException("AMCL: Keyboard final create lease retired");
	}

	/** 失败与销毁均撤原资源，不用current查询修补身份；未成功create没有lease可宣布ready。 */
	private void fenceKeyboard() {
		long[] origin = keyboardLease;
		keyboardLease = null;
		if (origin != null) nKeyboardFence(origin);
		for (int i = 0; i < keyDownState.length; i++) keyDownState[i] = 0;
	}

	/** 原Keyboard缓存/记录只在完整create的同一lease仍有效时有资格交付。 */
	boolean keyboardStateReady() {
		long[] origin = keyboardLease;
		return origin != null && nKeyboardValidate(origin) == 1;
	}

	/** 必须在真实窗口及游戏设备初始化后登记；缺新JNI/port不进入半新半旧输入路线。 */
	private void openControls() throws LWJGLException {
		verifyInputContract();
		if (controlConsumer != 0) return;
		controlConsumer = nControlOpen();
		if (controlConsumer == 0) throw new LWJGLException("AMCL: neutral control delivery unavailable");
	}

	/** 新Java遇旧SO在实际初始化立即明确拒绝；不走旧owner、也不临时加载另一个native。 */
	private static void verifyInputContract() throws LWJGLException {
		try {
			if (nInputContract(AMCL_CONTROL_PROTOCOL) != AMCL_CONTROL_PROTOCOL)
				throw new LWJGLException("InputContractMismatch: LWJGL2 delivery protocol differs");
			if (nLookContract(AMCL_LOOK_PROTOCOL) != AMCL_LOOK_PROTOCOL)
				throw new LWJGLException("InputContractMismatch: LWJGL2 look protocol differs");
		} catch (LinkageError missingNative) {
			throw new LWJGLException("InputContractMismatch: LWJGL2 JNI delivery handshake unavailable (" + missingNative + ")");
		}
	}

	// 从 native 取所有待处理事件，分发到鼠标/键盘事件队列并更新按住状态。
	// 幂等：四个 poll/read 方法都先调它，谁先调谁把 native 队列排空到 Java 队列，
	// 后调者发现 native 队列空、各自只消费自己的 Java 队列，事件不丢不串。
	private void drainEvents() { drainEvents(Integer.MAX_VALUE); }

	/**
	 * 领取前只沿原有有序运输做有限工作；普通poll/read保原排空入口。
	 * 返回true仅表示实际Next已报告本轮为空；256条耗尽或原consumer换代只暂缓领取，
	 * 不弹旧readBuffer、不制造取消、不补current身份。递归调用同样暂缓，由外层完成。
	 */
	private boolean drainEvents(int budget) {
		if (mouseEventQueue == null && keyboardEventQueue == null) return true;
		if (inputDraining) return false;
		// cursor JNI允许同步重入退休本实例并创建新target。原排空循环只能消费原consumer，
		// 不能继续调用全局Next取走新target记录，再因旧handle已关闭而把新DOWN丢掉。
		// 这里只核本实例原身份，不临时查询global current补handle；下一合法poll由新实例领取。
		final long originConsumer = controlConsumer;
		// 字符也固定本轮排空的原Keyboard寿命；JNI同步回入后不能借新lease接旧字符。
		final long[] originKeyboard = keyboardLease;
		inputDraining = true;
		try {
		int remaining = budget;
		while (controlConsumer == originConsumer && remaining-- > 0) {
			if (!nNextEvent(evTmp)) return true;
			int type = evTmp[0];
				switch (type) {
				case 1020: { // opaque前缀：完整64bit token，禁止以低32bit身份代替。
					long prefix = (evTmp[1] & 0xffffffffL) | ((long)evTmp[2] << 32);
					if (evTmp[3] != 0 || evTmp[4] != 0 || prefix == 0)
						throw new IllegalStateException("AMCL: invalid look prefix transport");
					applyLookPrefix(prefix);
					break;
				}
				case 1009: { // legacy通道恢复，只释放该平面，不能清实体持有。
					resetInputPlane(1);
					break;
				}
				case 1006: {
					applyMousePlane(1, evTmp[1], evTmp[2]);
					break;
				}
				case 1010: { // 有序绝对坐标；每条MOVE都在两条按钮边沿之间进入Mouse.next队列。
					// Native ABI把double的低/高32位按顺序放入i1/i2及i3/i4；用无符号低位
					// 拼回原始bits，不能把整数值当像素，也不能从最新全局cursor覆盖本条样本。
					long xBits = ((long)evTmp[2] << 32) | (evTmp[1] & 0xffffffffL);
					long yBits = ((long)evTmp[4] << 32) | (evTmp[3] & 0xffffffffL);
					putMousePosition(Double.longBitsToDouble(xBits), Double.longBitsToDouble(yBits));
					break;
				}
				case 1007: { // EVENT_TYPE_SCROLL: i2=yoffset（步进 ±1）
					int dwheel = evTmp[2] * 120; // LWJGL2 习惯每格 120（同 Win WHEEL_DELTA）
					accumWheel += dwheel;
					putMouseEvent(-1, false, dwheel);
					break;
				}
				case 1005: { // legacy编码只在此翻译一次。
					applyKeyPlane(1, glfwToLwjgl2Key(evTmp[1]), evTmp[2], evTmp[3]);
					break;
				}
				case 2005: { // typed已经是L2编码，禁止再次翻译。
					applyKeyPlane(2, evTmp[1], evTmp[2], evTmp[3]);
					break;
				}
				case 2006: {
					applyMousePlane(2, evTmp[1], evTmp[2]);
					break;
				}
				case 2007: { // 物理滚轮，i2=格数（宿主已按 LWJGL2 的"格"分好）
					int dwheel = evTmp[2] * 120; // 同 1007：LWJGL2 每格 120
					accumWheel += dwheel;
					putMouseEvent(-1, false, dwheel);
					break;
				}
				case 2010: { // FOCUS，与仅清局部held的RESET分开。
                    inputFocused = evTmp[1] != 0;
                    if (!inputFocused) resetInputPlane(3);
                    break;
                }
				case 2009: { // typed局部恢复，不影响触控/映射手柄平面。
					resetInputPlane(2);
					break;
				}
				case 1000: // EVENT_TYPE_CHAR
				case 1001: // EVENT_TYPE_CHAR_MODS: i1=codepoint
					// 字符事件用 key=0（KEY_NONE）+ character，MC 文本框据 character 写入；
					// 特殊键（退格/方向键等）走上面 KEY 事件的 keyCode 分支。
					putCharacterEvent(evTmp[1], originKeyboard);
					break;
			}
		}
		return false;
		} finally { inputDraining = false; }
	}

	/**
	 * 真实Keyboard.next/getNum在尚未移动原readBuffer时调用一次。预算耗尽保持原字节
	 * 与旁带供下一次合法API继续，不能为了排到FOCUS而在热领取中无限追生产者。
	 */
	boolean keyboardReadPreflight() { return drainEvents(256); }

	/**
	 * 一条已运输的不可变前缀最多尝试两次。owner可在claim/validate之间退休一份来源，
	 * 撤原票后重prepare剩余兄弟贡献；持续stale/pressure显式放弃本backend token，不
	 * 堵住Keyboard/Mouse独立队列，也不拿global latest cursor补偿原票。
	 */
	private void applyLookPrefix(long prefix) {
		if (mouseEventQueue == null || !grabbed || !lookReady) {
			// 真实window/control身份仍可登记丢弃上下文；bind不声称Mouse缓存已安装。
			if (controlConsumer != 0 && nLookBind(controlConsumer, lookCursorX, lookCursorY) >= 0)
				nLookAbandon(controlConsumer, prefix);
			return;
		}
		for (int attempt = 0; attempt < 2; attempt++) {
			int result = nLookPrepare(controlConsumer, prefix, lookTmp);
			if (result == -3) {
				nLookAbandon(controlConsumer, prefix);
				throw new IllegalStateException("AMCL: look delivery pressure");
			}
			if (result != 1) continue;
			long[] emission = lookTmp.clone();
			if (nLookValidate(emission) != 1) { nLookComplete(emission, 5); continue; }
			// claim不是实际应用。写入可被合法poll取得的本ABI cursor以后才终结票，
			// 保留整数截断余量；MOVE另外进入真实22byte队列，不冒充game next完成。
			lookCursorX = Double.longBitsToDouble(emission[9]);
			lookCursorY = Double.longBitsToDouble(emission[10]);
			int dx = (int)(lookCursorX - lookEventCursorX), dy = (int)(lookCursorY - lookEventCursorY);
			lookEventCursorX += dx; lookEventCursorY += dy;
			cacheLookLatency(emission);
			if (dx != 0 || dy != 0) putMouseRecordAt(-1, false, 0, dx, -dy, null);
			if (nLookComplete(emission, 3) < 0) {
				// cache写已经发生，不能逆向“撤回相机”。关闭原look上下文并明确失败，
				// 此Mouse实例随后只丢弃前缀，重建/重锚才重新获取执行资格。
				lookReady = false; nLookClose(controlConsumer);
				clearLookLatency(4);
				throw new IllegalStateException("AMCL: look cache receipt rejected");
			}
			return;
		}
		nLookAbandon(controlConsumer, prefix);
	}

	/** 由完整上游Mouse.poll实际取得坐标view后调用，统计真实API读取而非drain/入队。 */
	void lookPollView(IntBuffer coordinates) {
		long[] originalView = lookLatencyPoll;
		lookLatencyPoll = null;
		if (lookReady && grabbed && controlConsumer != 0) {
			nLookObservePoll(controlConsumer, coordinates.get(0), coordinates.get(1));
			// 完整 Mouse.poll 已读取同一次 coord_buffer；只交回写 view 前冻结的原票。
			if (lookLatencyAvailable && originalView != null && originalView[1] == controlConsumer) {
				nLookLatencyNote(originalView, 5);
				// note 的 try-lock 忙只丢时点；另以原票确认已实际 copy，不补造第六段钟值。
				nLookLatencyFinish(originalView, 10);
			} else if (lookLatencyAvailable && originalView != null) {
				nLookLatencyFinish(originalView, 3);
			}
		} else if (lookLatencyAvailable && originalView != null) {
			nLookLatencyFinish(originalView, 3);
		}
	}

	/** 只提交backend-native键码；legacy一次编码已在drainEvents完成，typed不再翻译。 */
	private void applyKeyPlane(int plane, int key, int scan, int action) {
		if (keyboardEventQueue == null || !keyboardStateReady() || key <= 0 || key >= keyDownState.length) return;
		applyControl(plane, 1, key, scan, action);
	}

	/** Native adapter已汇总typed设备，owner0表示一份aggregate，Java不再复制owner数组。 */
	private void applyMousePlane(int plane, int button, int action) {
		if (mouseEventQueue == null || button < 0 || button >= mouseButtonState.length) return;
		applyControl(plane, 2, button, 0, action);
	}

	/** JNI只负责真实端口调用；Edge的原consumer/activation/revision/target随记录保留。 */
	private void applyControl(int plane, int kind, int code, int scan, int action) {
		int result = nControlApply(controlConsumer, plane, kind, code, scan, action, controlTmp);
		if (result == 1) applyEmission(controlTmp.clone());
		else if (result == -3) throw new IllegalStateException("AMCL: control delivery pressure");
	}

	/**
	 * 先改实际Java polling缓存，再报告phase0；记录入队失败只报告discarded。
	 * 不以JNI返回Edge代替缓存证据，不以EventQueue.putEvent成功代替game next。
	 */
	private void applyEmission(long[] emission) {
		int kind = (int)emission[0], code = (int)emission[1], action = (int)emission[3];
		boolean queued;
		if (kind == 1) {
			long[] origin = keyboardLease;
			// claim并非cache资格；目标或Keyboard局部寿命已退休时只丢原票，不写新资源缓存。
			if (origin == null || nKeyboardValidate(origin) != 1) { nControlComplete(emission, 5); return; }
			keyDownState[code] = (byte)(action != 0 ? 1 : 0);
			nControlComplete(emission, 0);
			queued = putKeyRecord(code, action != 0, 0, action == 2, emission, origin);
		} else {
			mouseButtonState[code] = (byte)(action != 0 ? 1 : 0);
			nControlComplete(emission, 0);
			queued = putMouseRecord(code, action != 0, 0, emission);
		}
		if (!queued) nControlComplete(emission, 5);
	}

	/** 局部reset不清兄弟排队事件；完整失焦撤销旧队列后在原目标生成cache release。 */
	private void resetInputPlane(int plane) {
		if (plane == 3) { cancelRecords(1); cancelRecords(2); }
		retireControls(plane == 1 ? 1 : plane == 2 ? 6 : 15, 0);
	}

	/** kind0为全实例；Keyboard/Mouse独立销毁只撤销相应kind，不误退休兄弟设备。 */
	private void retireControls(int mask, int kind) {
		if (controlConsumer == 0) return;
		int result = nControlRetire(controlConsumer, mask, kind);
		if (result == -3) throw new IllegalStateException("AMCL: control retirement pressure");
		while (nControlNextRetired(controlConsumer, controlTmp) == 1) applyEmission(controlTmp.clone());
	}

	/**
	 * 仅完整Keyboard销毁/失败收尾使用：原lease已经围栏，真实旧keycache必须清零，
	 * 而原Keyboard事件队列不再有交付资格。原retireKind/claim的UP经control原票复核后
	 * 写旧cache并报告STATE_ONLY，随后DISCARDED终结；不入队、不伪报PULL_COMMITTED。
	 * 这使共同owner的已应用事实与实际清零一致，新资源合法held基线才能产生新DOWN。
	 * FOCUS/平面reset仍使用上面的正常资源路径，不以scope==0猜测通用退休权限。
	 */
	private void retireKeyboardControls() {
		if (controlConsumer == 0) return;
		int result = nControlRetire(controlConsumer, 15, 1);
		if (result == -3) throw new IllegalStateException("AMCL: Keyboard retirement pressure");
		while (nControlNextRetired(controlConsumer, controlTmp) == 1) {
			long[] origin = controlTmp.clone();
			int code = (int)origin[1];
			if (origin[0] != 1 || origin[3] != 0 || code < 0 || code >= keyDownState.length) {
				nControlComplete(origin, 5);
				throw new IllegalStateException("AMCL: invalid Keyboard retirement edge");
			}
			// 围栏Keyboard不授权新cache，但销毁仍可清原cache；只认原control target/ticket。
			if (nControlValidate(origin) == 1) {
				keyDownState[code] = 0;
				nControlComplete(origin, 0);
			}
			nControlComplete(origin, 5);
		}
	}

	/** EventQueue→readBuffer仍属内部拷贝，按完整记录同移ticket及原Keyboard scope，不报告交付。 */
	private void copyRecords(int kind, ByteBuffer buffer) {
		EventQueue queue = kind == 1 ? keyboardEventQueue : mouseEventQueue;
		if (queue == null) return;
		LinkedList<long[]> queued = kind == 1 ? keyboardQueued : mouseQueued;
		LinkedList<long[]> read = kind == 1 ? keyboardRead : mouseRead;
		int size = kind == 1 ? Keyboard.EVENT_SIZE : Mouse.EVENT_SIZE;
		int start = buffer.position(), limit = buffer.limit();
		int records = Math.min(buffer.remaining() / size, queued.size());
		if (kind == 1) {
			if (keyboardQueuedScopes.size() != queued.size() || keyboardQueuedScalars.size() != queued.size())
				throw new IllegalStateException("AMCL: Keyboard queued sidecar mismatch");
			// 只剩一槽时整个pair留在EventQueue，保证高可被next之前低已经同入readBuffer。
			if (records > 0 && records < queued.size()) {
				long[] last = keyboardQueuedScalars.get(records - 1);
				if (last != null && last == keyboardQueuedScalars.get(records)) records--;
			}
			int tickets = 0, scopes = 0, scalars = 0;
			boolean copied = false;
			try {
				// 所有LinkedList节点分配先于bulk复制；OOM不会留下只有字节的第3FIFO洞。
				for (int i = 0; i < records; i++) {
					read.addLast(queued.get(i)); tickets++;
					keyboardReadScopes.addLast(keyboardQueuedScopes.get(i)); scopes++;
					keyboardReadScalars.addLast(keyboardQueuedScalars.get(i)); scalars++;
				}
				buffer.limit(start + records * size);
				queue.copyEvents(buffer);
				if (buffer.position() - start != records * size)
					throw new IllegalStateException("AMCL: Keyboard byte/sidecar mismatch");
				copied = true;
				// 复制成功后只做无分配的原头节点移除，scope/group/ticket仍逐条同移。
				for (int i = 0; i < records; i++) {
					queued.removeFirst(); keyboardQueuedScopes.removeFirst(); keyboardQueuedScalars.removeFirst();
				}
			} finally {
				buffer.limit(limit);
				if (!copied) {
					while (tickets-- > 0) read.removeLast();
					while (scopes-- > 0) keyboardReadScopes.removeLast();
					while (scalars-- > 0) keyboardReadScalars.removeLast();
				}
			}
			return;
		}
		// Mouse保原22B拷贝与ticket路径，scalar政策不扩成鼠标取消或另一次pull。
		buffer.limit(start + records * size);
		queue.copyEvents(buffer);
		int count = (buffer.position() - start) / size;
		buffer.limit(limit);
		for (int i = 0; i < count; i++) read.addLast(queued.removeFirst());
	}

	/** 完整失焦已丢旧票但保留readBuffer槽数；next跳过零长sentinel，绝不把它当新事件。 */
	private void cancelRecords(int kind) {
		LinkedList<long[]> queued = kind == 1 ? keyboardQueued : mouseQueued;
		LinkedList<long[]> read = kind == 1 ? keyboardRead : mouseRead;
		while (!queued.isEmpty()) { long[] e = queued.removeFirst(); if (e != null) nControlComplete(e, 5); }
		if (kind == 1) { keyboardQueuedScopes.clear(); keyboardQueuedScalars.clear(); }
		for (int i = 0; i < read.size(); i++) {
			long[] e = read.get(i);
			if (kind == 1) {
				if (keyboardReadScalars.size() != read.size() || keyboardReadScopes.size() != read.size())
					throw new IllegalStateException("AMCL: Keyboard cancel sidecar mismatch");
				long[] scalar = keyboardReadScalars.get(i);
				// 第一单元已经真实next返回且原资源仍合法，保该组剩余低单元。普通END
				// 不进入这里；Keyboard/target已围栏时validate拒绝，绝不续给新scope。
				if (scalar != null && scalar[0] == 1 && keyboardLease != null &&
					nKeyboardValidate(keyboardReadScopes.get(i)) == 1) continue;
				if (scalar != null) scalar[0] = -1;
			}
			if (e != null && e.length != 0) nControlComplete(e, 5);
			read.set(i, new long[0]);
		}
		EventQueue queue = kind == 1 ? keyboardEventQueue : mouseEventQueue;
		if (queue != null) queue.clearEvents();
	}

	/** 核旁带取消标记及原Keyboard寿命；窥探不推进队列，同一资源的旧revision短脉冲仍可读。 */
	boolean controlRecordReady(int kind, int offset) {
		LinkedList<long[]> read = kind == 1 ? keyboardRead : mouseRead;
		if (offset < 0 || offset >= read.size()) throw new IllegalStateException("AMCL: input ticket sidecar mismatch");
		long[] e = read.get(offset);
		if (e != null && e.length == 0) return false;
		if (kind != 1) return true;
		if (keyboardReadScopes.size() != read.size() || keyboardReadScalars.size() != read.size())
			throw new IllegalStateException("AMCL: Keyboard scope/scalar sidecar mismatch");
		long[] scalar = keyboardReadScalars.get(offset);
		return (scalar == null || scalar[0] >= 0) && nKeyboardValidate(keyboardReadScopes.get(offset)) == 1;
	}

	/** 由真实Keyboard/Mouse next调用；repeat过滤或reset丢弃采用phase5，不伪报领取。 */
	void controlRead(int kind, boolean delivered) {
		LinkedList<long[]> read = kind == 1 ? keyboardRead : mouseRead;
		if (read.isEmpty()) throw new IllegalStateException("AMCL: input ticket sidecar mismatch");
		long[] emission = read.removeFirst();
		if (kind == 1) {
			if (keyboardReadScopes.isEmpty()) throw new IllegalStateException("AMCL: Keyboard scope sidecar mismatch");
			long[] origin = keyboardReadScopes.removeFirst();
			delivered = delivered && nKeyboardValidate(origin) == 1;
			if (keyboardReadScalars.isEmpty()) throw new IllegalStateException("AMCL: Keyboard scalar sidecar mismatch");
			long[] scalar = keyboardReadScalars.removeFirst();
			// 只在真实next已写公共event字段并允许返回时推进；getNum窥探不进入本方法。
			// 过滤/资源失权/显式丢弃将整个原组标取消，不能把低单元另当新scalar开始。
			if (scalar != null) scalar[0] = delivered && scalar[0] >= 0 ? scalar[0] + 1 : -1;
		}
		if (emission != null && emission.length != 0) nControlComplete(emission, delivered ? 2 : 5);
	}

	/** Mouse.setGrabbed的既有resetMouse丢弃已读缓冲；仅discard对应数量的旁带记录。 */
	void controlDiscardRead(int kind, int count) {
		for (int i = 0; i < count; i++) controlRead(kind, false);
	}

	/** 游戏实际isKeyDown/isButtonDown读缓存以后调用，统计归原consumer而非全局current。 */
	void controlPoll(int kind, int code, boolean held) {
		if (controlConsumer != 0) nControlObservePoll(controlConsumer, kind, code, held);
	}

	/** 上游真正poll取得的direct缓存只观测一次；位置/长度显式传入，不改buffer游标。 */
	void controlPollView(int kind, ByteBuffer states) {
		if (controlConsumer != 0)
			nControlObservePollView(controlConsumer, kind, states, states.position(), states.remaining());
	}

	/** 销毁才直接丢本实例记录；完整失焦使用保留readBuffer槽的cancelRecords。 */
	private void discardRecords(int kind) {
		LinkedList<long[]> queued = kind == 1 ? keyboardQueued : mouseQueued;
		LinkedList<long[]> read = kind == 1 ? keyboardRead : mouseRead;
		while (!queued.isEmpty()) { long[] e = queued.removeFirst(); if (e != null) nControlComplete(e, 5); }
		while (!read.isEmpty()) { long[] e = read.removeFirst(); if (e != null && e.length != 0) nControlComplete(e, 5); }
		if (kind == 1) {
			keyboardQueuedScopes.clear(); keyboardReadScopes.clear();
			keyboardQueuedScalars.clear(); keyboardReadScalars.clear();
		}
		EventQueue queue = kind == 1 ? keyboardEventQueue : mouseEventQueue;
		if (queue != null) queue.clearEvents();
	}

	/**
	 * 提交一个已冻结的菜单位置样本。button=-1表示移动，不改mouseButtonState；
	 * 鼠标左键仍由此前已交付的PRESS保持，UP的终点MOVE因此能被游戏作为拖动处理。
	 * grabbed状态只读取poll相对增量，绝对菜单坐标不得进入世界视角事件队列。
	 */
	private void putMousePosition(double sourceX, double sourceY) {
		if (grabbed || Double.isNaN(sourceX) || Double.isInfinite(sourceX) ||
				Double.isNaN(sourceY) || Double.isInfinite(sourceY)) return;
		putMouseEventAt(-1, false, 0, (int)Math.round(sourceX), getHeight() - (int)Math.round(sourceY));
	}

	/** 按钮/滚轮在当前消费快照取坐标；1010位置事件则直接使用自己冻结的载荷。 */
	private void putMouseEvent(int button, boolean state, int dwheel) {
		putMouseRecord(button, state, dwheel, null);
	}

	/** 按钮ticket与字节记录一起入队，非control事件使用null旁带。 */
	private boolean putMouseRecord(int button, boolean state, int dwheel, long[] emission) {
		if (mouseEventQueue == null) return false;
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
		return putMouseRecordAt(button, state, dwheel, x, y, emission);
	}

	/**
	 * Mouse事件唯一序列化出口：绝对位置已在调用方完成左下原点转换，按当前顺序
	 * 拷贝到独立队列记录。后续native光标变化不能重写游戏尚未读取的PRESS/MOVE/UP。
	 */
	private void putMouseEventAt(int button, boolean state, int dwheel, int x, int y) {
		putMouseRecordAt(button, state, dwheel, x, y, null);
	}

	/** 保留既有22字节记录；只有putEvent真实成功才增加对应旁带。 */
	private boolean putMouseRecordAt(int button, boolean state, int dwheel, int x, int y, long[] emission) {
		if (mouseEventQueue == null) return false;
		// getCursorX/Y是真实JNI边界，允许同步重入取得新owner或销毁原目标。
		// 旧release已更新过缓存，但不能随后排到重入的新DOWN后面误释放它。
		if (emission != null && nControlValidate(emission) != 1) return false;
		mouseEventBuf.clear();
		mouseEventBuf.put((byte) button);
		mouseEventBuf.put((byte)(state ? 1 : 0));
		mouseEventBuf.putInt(x);
		mouseEventBuf.putInt(y);
		mouseEventBuf.putInt(dwheel);
		mouseEventBuf.putLong(System.nanoTime());
		mouseEventBuf.flip();
		boolean accepted = mouseEventQueue.putEvent(mouseEventBuf);
		if (accepted) mouseQueued.addLast(emission);
		return accepted;
	}

	/**
	 * 将真实CHAR运输中的supplementary scalar编码为两条原18B UTF-16记录。
	 * Core文本入口交付Unicode scalar，legacy sendChar(char)则本来就是UTF-16单元；
	 * 因此BMP（含legacy合法surrogate单元）保原路，负数/超U+10FFFF不能截断成字符。
	 * KEY_NONE仅表示字符载荷，不调用control贡献、不改keyDownState，也不制造repeat。
	 * 本函数由完整上游poll/read持原GlobalLock调用；EventQueue自身再串行bulk提交。
	 */
	private boolean putCharacterEvent(int character, long[] origin) {
		final EventQueue queue = keyboardEventQueue;
		if (queue == null || origin == null || nKeyboardValidate(origin) != 1) return false;
		if (character < 0 || character > Character.MAX_CODE_POINT) return false;
		if (character <= Character.MAX_VALUE)
			return putKeyRecord(0, true, character, false, null, origin);
		// 全部格式化、scope复制与分配先于队列变动；失败不能留下半对或部分旁带。
		final long[] highScope = origin.clone(), lowScope = origin.clone();
		// 组身份从这一次真实scalar构造点分配；两单元只共享该对象，不复制状态值。
		final long[] scalar = new long[1];
		final ByteBuffer events = ByteBuffer.allocate(2 * Keyboard.EVENT_SIZE);
		final long nanos = System.nanoTime();
		for (int unit = 0; unit < 2; unit++) {
			events.putInt(0);
			events.put((byte)1);
			events.putInt(unit == 0 ? Character.highSurrogate(character) : Character.lowSurrogate(character));
			events.putLong(nanos);
			events.put((byte)0);
		}
		events.flip();
		// 先调可能同步回入的原Native验证，再复核Java资源身份；旧请求不能写新队列。
		// 后续只执行私有LinkedList/ByteBuffer操作，没有用户/Native回调重新选current。
		if (nKeyboardValidate(origin) != 1 || keyboardEventQueue != queue || keyboardLease != origin) return false;
		int tickets = 0, scopes = 0, scalars = 0;
		boolean accepted = false;
		try {
			// LinkedList节点可能分配失败；先完整安装旁带，再一次bulk写36B。
			// 原GlobalLock下没有消费者可见这段暂态；拒绝/异常均只回滚本批尾节点。
			keyboardQueued.addLast(null); tickets++;
			keyboardQueuedScopes.addLast(highScope); scopes++;
			keyboardQueuedScalars.addLast(scalar); scalars++;
			keyboardQueued.addLast(null); tickets++;
			keyboardQueuedScopes.addLast(lowScope); scopes++;
			keyboardQueuedScalars.addLast(scalar); scalars++;
			accepted = queue.putEvents(events);
			return accepted;
		} finally {
			if (!accepted) {
				while (tickets-- > 0) keyboardQueued.removeLast();
				while (scopes-- > 0) keyboardQueuedScopes.removeLast();
				while (scalars-- > 0) keyboardQueuedScalars.removeLast();
			}
		}
	}

	private void putKeyEvent(int key, boolean state, int character, boolean repeat) {
		putKeyRecord(key, state, character, repeat, null, keyboardLease);
	}

	/** 保留18字节Keyboard记录与字符/repeat字段；原scope旁带同入队，不占旧事件槽。 */
	private boolean putKeyRecord(int key, boolean state, int character, boolean repeat, long[] emission, long[] origin) {
		if (keyboardEventQueue == null || origin == null || nKeyboardValidate(origin) != 1) return false;
		if (emission != null && nControlValidate(emission) != 1) return false;
		keyboardEventBuf.clear();
		keyboardEventBuf.putInt(key);
		keyboardEventBuf.put((byte)(state ? 1 : 0));
		keyboardEventBuf.putInt(character);
		keyboardEventBuf.putLong(System.nanoTime());
		keyboardEventBuf.put((byte)(repeat ? 1 : 0));
		keyboardEventBuf.flip();
		// 新增组旁带也必须在真实putEvent之前完整安装；任何节点分配/预算失败按原
		// 尾节点回滚，不能留下已入18B字节却缺scope/group的半记录。单记录组明确为null。
		long[] scope = origin.clone();
		int tickets = 0, scopes = 0, scalars = 0;
		boolean accepted = false;
		try {
			keyboardQueued.addLast(emission); tickets++;
			keyboardQueuedScopes.addLast(scope); scopes++;
			keyboardQueuedScalars.addLast(null); scalars++;
			accepted = keyboardEventQueue.putEvent(keyboardEventBuf);
			return accepted;
		} finally {
			if (!accepted) {
				while (tickets-- > 0) keyboardQueued.removeLast();
				while (scopes-- > 0) keyboardQueuedScopes.removeLast();
				while (scalars-- > 0) keyboardQueuedScalars.removeLast();
			}
		}
	}

	public void pollMouse(IntBuffer coord_buffer, ByteBuffer buttons) {
		drainEvents();
		beginLookLatencyPoll();
		if (grabbed) {
			// 返回自上次 poll 以来的增量（截断取整、保留小数余量避免长期漂移）。
			double dxRaw = lookCursorX - lastCursorX;
			double dyRaw = lookCursorY - lastCursorY;
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
		copyRecords(2, buffer);
	}

	public void grabMouse(boolean grab) {
		if (grab != grabbed) {
			clearLookLatency(3);
			grabbed = grab;
			nSetGrab(grab);
			// world从本次实际mode的中立零基线开始，菜单则保留原绝对cursor合同。
			// nSetGrab已公告新mode，owner据原consumer身份重锚，不继承上一模式尾量。
			double x = grab ? 0.0 : nGetCursorX(), y = grab ? 0.0 : nGetCursorY();
			lookCursorX = lastCursorX = lookEventCursorX = x;
			lookCursorY = lastCursorY = lookEventCursorY = y;
			lookReady = controlConsumer != 0 && nLookBind(controlConsumer, x, y) >= 0;
			if (!lookReady) throw new IllegalStateException("AMCL: look mode reanchor unavailable");
		}
	}

	public int getNativeCursorCapabilities() { return 0; }
	public void setCursorPosition(int x, int y) { /* 增量模型，无需设置 */ }
	public void setNativeCursor(Object handle) throws LWJGLException { }
	public int getMinCursorSize() { return 0; }
	public int getMaxCursorSize() { return 0; }

	public void pollKeyboard(ByteBuffer keyDownBuffer) {
		drainEvents();
		// 外部target退休可早于上游destroy；已失权的implementation缓存不能继续装入旧API view。
		if (!keyboardStateReady()) for (int i = 0; i < keyDownState.length; i++) keyDownState[i] = 0;
		int n = keyDownBuffer.remaining();
		int base = keyDownBuffer.position();
		for (int i = 0; i < n && i < keyDownState.length; i++)
			keyDownBuffer.put(base + i, keyDownState[i]);
	}

	public void readKeyboard(ByteBuffer buffer) {
		drainEvents();
		copyRecords(1, buffer);
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
	private static native int nInputContract(int protocol);
	private static native int nLookContract(int protocol);
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
	// 新私有JNI仅连接经身份核对的neutral端口，不改变旧五整数NextEvent含义。
	private static native long nControlOpen();
	private static native void nControlClose(long consumer);
	private static native int nControlApply(long consumer, int plane, int kind, int code, int scan, int action, long[] emission);
	private static native int nControlRetire(long consumer, int mask, int kind);
	private static native int nControlNextRetired(long consumer, long[] emission);
	private static native int nControlComplete(long[] emission, int phase);
	private static native int nControlValidate(long[] emission);
	private static native int nControlObservePoll(long consumer, int kind, int code, boolean held);
	private static native int nControlObservePollView(long consumer, int kind, ByteBuffer states, int offset, int count);
	private static native int nControlSnapshot(long consumer, long[] snapshot);
	// 独立Keyboard原lease端口；long[3]不占18字节事件载荷，也不改变标准control/look ABI。
	private static native int nKeyboardCompleteCreate(long consumer, long[] lease);
	private static native int nKeyboardFence(long[] lease);
	private static native int nKeyboardValidate(long[] lease);
	private static native int nKeyboardHeld(long[] lease, int plane, int code);
	// 独立look-v1资格/票，double以long原bits运输；与原control emission互不冒认。
	private static native int nLookBind(long consumer, double x, double y);
	private static native int nLookSetActive(long consumer, boolean active);
	private static native int nLookPrepare(long consumer, long prefix, long[] emission);
	private static native int nLookValidate(long[] emission);
	private static native int nLookComplete(long[] emission, int phase);
	private static native void nLookClose(long consumer);
	private static native int nLookAbandon(long consumer, long prefix);
	private static native int nLookObservePoll(long consumer, double x, double y);
	// 可选私有观测 JNI；缺席只由冷 available 探测降级，所有热调用携原11槽 emission。
	private static native boolean nLookLatencyAvailable();
	private static native void nLookLatencyNote(long[] emission, int stage);
	private static native void nLookLatencyFinish(long[] emission, int outcome);
	private static native int nLookSnapshot(long consumer, long[] snapshot);
}
