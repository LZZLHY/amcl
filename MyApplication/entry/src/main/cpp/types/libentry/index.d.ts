// JVM 模块
export const jvmInit: (appFilesDir: string, jdkVersion?: string) => number;
export const runJvmEmbedTest: (appFilesDir: string, callback?: (result: string) => void) => string | void;
export const isJvmTestRunning: () => boolean;

// P6: MC 启动器
// ⚰️ 2026-08-27：legacy mcLaunch 已退役（绕过 AmclClassLoader 隔离契约），见 napi_mc.cpp 墓碑。
export const mcLaunchWithProfile: (filesDir: string, gameDir: string, jdkVersion: string, xmxMb: number, mainClass: string, classpath: string, mcArgsStr: string, extraJvmArgs?: string) => number;
export const mcLaunchWithProfileV2: (filesDir: string, gameDir: string, jdkVersion: string, xmxMb: number, mainClass: string, classpath: string, mcArgs: string[], extraJvmArgs?: string[]) => number;
export const mcGetStatus: () => string;
/** 同步启动后的图形失败 JSON（v1）；读取必须与启动调用处于同一线程。 */
export const mcGetGraphicsLaunchFailure: () => string;
/** 只读 PID/后端/首帧/异步故障及呈现间隔摘要；无 current context 也可调用。 */
export const mcGetGraphicsRuntimeState: () => string;
export const mcGetGraphicsRuntimeFailure: () => string;
export const desktopProcessAlive: (pid: number) => number;
export const runtimeSlotCreateStage: (destination: string) => string;
export const runtimeSlotPublish: (stage: string, destination: string) => boolean;
export const runtimeSlotDiscardStage: (stage: string) => boolean;
export const runtimeSlotAcquire: (directory: string) => string;
export const runtimeSlotRelease: (handle: string) => boolean;
export const runtimeSlotRetire: (directory: string) => boolean;
export const runtimeSlotCollect: (activeDirectory: string) => number;
export const graphicsRecoveryMaintain: (directory: string, keepId: string) => number;
export const mcCheckFiles: (mcDir: string, mcVersion: string) => string;
export const mcIsRunning: () => boolean;
export const mcForceExit: () => void;
export const mcReadLog: (mcDir: string, maxBytes?: number) => string;

// 设备信息
export const getDeviceMemoryMB: () => number;
export const getRecommendedXmx: () => number;

// HarmonyOS XComponent scheduler hint. sourceBit must be one caller-owned bit;
// EntryAbility=1 and GameAbility=2. This does not create a render/VSync loop.
export const setOhosFrameRateForeground: (sourceBit: number, foreground: boolean) => boolean;
// Explicit known game FPS cap. 0 clears it; valid positive values are 30..240.
export const setOhosFrameRateCap: (fpsCap: number) => boolean;
// Re-query the current default-display refresh rate and force the XComponent
// scheduler hint to be recalculated. False means no live surface was available.
export const refreshOhosFrameRateHint: (displayRefreshRate?: number) => boolean;

// 沙箱外存储可行性探针（Phase 0）：对传入目录跑裸 POSIX mkdir/open/write/read/unlink，
// 返回逐步成败 + errno 报告。末行 "RESULT: NATIVE_RW_OK" = JVM 可在该目录运行。
export const probeNativePath: (dir: string) => string;

// AMCL 日志系统
export const amclLogInit: (logDir: string, maxFileSize?: number, maxFiles?: number) => void;
export const amclLogShutdown: () => void;
/** 读取启动器日志尾部。L1-b 起**跨轮转**（含 .1~.5.log），不再只读当前文件。 */
export const amclLogRead: (maxBytes?: number) => string;
export const amclLogFlush: () => boolean;
/** 当前 writer 健康快照，历史失败/缺口累计值不会随恢复可写而清零。 */
export const amclLogGetStatus: () => string;
export const amclLogGetPath: () => string;
// ---- 活动账本（L1-a）----
/** 打开活动账本 scope，此后归属该活动的日志行同时写入 <dir>/launcher.log。幂等。 */
export const amclLedgerBegin: (activityId: number, dir: string) => boolean;
/** 关闭活动账本 scope（flush + 关句柄）。 */
export const amclLedgerEnd: (activityId: number) => void;
/** 在原生工作线程等待writer有序关闭；未关闭时拒绝，完整性仍由native-io收据核验。 */
export const amclLedgerEndAsync: (activityId: number) => Promise<void>;
/** 关闭全部 scope。 */
export const amclLedgerEndAll: () => void;
/** 关联 native 下载任务与活动（activityId 传 0 解除）。 */
export const amclLedgerBindTask: (taskId: number, activityId: number) => void;
/** 任务终态时解绑，避免 32 槽关联表被占满。 */
export const amclLedgerUnbindTask: (taskId: number) => void;
/** 设置后续 MC 启动线程的日志归属活动（游戏会话账本）。 */
export const amclLedgerSetLaunchActivity: (activityId: number) => void;
// level: 0=DEBUG 1=INFO 2=WARN 3=ERROR 4=FATAL
export const amclLogWrite: (level: number, tag: string, message: string, activityId?: number) => void;

// 输入模块
/** @deprecated 触摸已全部由 native XComponent DispatchTouchEvent 处理；此 NAPI 是 no-op，仅为兼容保留。 */
export const sendTouchEvent: (x: number, y: number, action: number) => void;
export const sendKeyEvent: (key: number, scancode: number, action: number, mods: number) => void;
/**
 * Publish the compile-time product identity before surface/input setup.
 * productKind：0为mobile/tablet、1为desktop，runtimeApi为实际deviceInfo.sdkApiVersion。
 * 返回0已应用、1相同且幂等、2非法、3进程锁存冲突；5为唯一source owner冷契约不成立，
 * 该路径先于Native产品锁存/来源注册拒绝，不在当前namespace另建owner或尝试游戏类。
 */
export const configureInputProduct: (productKind: number, runtimeApi: number) => number;
export const hardwareRawMouseAvailable: () => boolean;
/**
 * Atomic physical key ingress: raw typed identity is preserved even when mappedKey is 0.
 *
 * Field contract (Phase 3.3):
 *   - `deviceId`: real ArkUI `KeyEvent.deviceId`, normalized to a non-negative
 *     integer. It is the owner dimension of the native HeldId, so two physical
 *     keyboards holding the same key keep independent owners. 0 means "not
 *     reported" and is counted as a missing field by the native trace.
 *   - `locks`: platform latch snapshot, bit layout mirrored from
 *     `amcl_input_event.h` AMCL_INPUT_LOCK_STATE_* / `KeyMap.ets`
 *     AMCL_LOCK_STATE_*: CAPS=1, NUM=2, SCROLL=4, VALID=1<<16. VALID must be
 *     set for the latch bits to mean anything; 0 means unknown. VALID sits
 *     above every GLFW modifier bit so a `modifiers` value accidentally passed
 *     here can never claim "the platform answered"; ingress additionally
 *     downgrades any out-of-mask value to unknown and counts it as unsupported.
 *     Never derive latches from held keys.
 *   - `hardwareScan` / `hidUsage`: still 0 — ArkUI KeyEvent does not expose
 *     them. This is the unresolved remainder of plan item P0-7.
 */
export const physicalKeyTransaction: (ohosKey: number, hardwareScan: number, hidUsage: number,
  typedAction: number, modifiers: number, locks: number, deviceId: number,
  mappedKey: number, mappedAction: number) => number;
/**
 * One ArkUI physical mouse-button edge. Native and ArkUI callbacks race for a
 * lifecycle-scoped first-valid-source owner so the same hardware edge cannot
 * drive both source planes.
 */
export const physicalMouseButtonTransaction: (deviceId: number, arkuiButton: number,
  glfwAction: number, modifiers: number, deviceClass?: number,
  monotonicTimeNs?: number) => void;
/**
 * 游戏内锁定系统鼠标光标（OH_WindowManager_LockCursor，since 22，dlsym 运行时探测）。
 *
 * 这是"物理鼠标与虚拟按键并列"的地基：锁定后光标不随鼠标移动，因此
 *   - 相对位移可以无限累积，不会因为光标撞到屏幕边缘而被截断；
 *   - 光标不可能停在虚拟控件上方，鼠标也就不可能按到虚拟按键。
 *
 * 仅获焦窗口可锁，失焦时窗口管理器会自动解锁，因此重新获焦后必须再锁一次。
 * 返回 AmclCursorLockResult：0=已应用 1=状态未变 2=设备/版本不支持
 * 3=windowId 非法 4=窗口管理器拒绝（具体平台码见 hilog）。
 */
export const setCursorLocked: (windowId: number, locked: boolean) => number;
/** 告知 native 窗口管理器已因失焦自动解锁，使下次加锁不被当作重复请求跳过。 */
export const noteCursorLockFocusLost: () => void;
/** 本设备/系统版本是否解析到了光标锁定符号。 */
export const isCursorLockSupported: () => boolean;

/**
 * 钉住模式（isCursorFollowMovement=false）的自愈看门狗。
 *
 * 钉住是"鼠标飘出窗口 / 视角到屏幕边缘就停"的正确修复：指针不动就永远碰不到边缘，
 * `rawDelta` 可以无限持续。但若某台设备钉住后连相对量也停了，视角会完全消失。
 * 本函数在"钉住后 2s 内一个相对样本都没来"时一次性降级回跟随模式。
 *
 * 返回 true 表示**刚刚降级**，调用方必须重新调用 `setCursorLocked` 加锁一次，
 * 新模式才会生效（窗口管理器只在 lock 时读该参数）。
 * 由页面既有的 250ms grab 对账轮询驱动即可，不要新开定时器。
 */
export const cursorLockWatchdogTick: () => boolean;
/**
 * 安装窗口级输入事件过滤器（路径 B），在 **ArkUI 组件分发之前**掐掉系统把鼠标左键
 * 与滚轮合成出来的触摸包，使游戏内只剩一条鼠标通道（onMouse + rawDelta，无界）。
 *
 * 底层是 `OH_NativeWindowManager_RegisterTouchEventFilter`（@since 15，无需权限）
 * 配合 `OH_Input_GetTouchEventToolType`（@since 24）判定 `TOOL_TYPE_MOUSE`。
 * 同时安装一个**永远返回 false** 的鼠标过滤探针，用于证明鼠标事件到过窗口层。
 *
 * 三条安全边界（详见 native window_event_filter.h）：
 *   1. 只在游戏内（光标已锁）过滤；菜单态放行，否则鼠标点不了任何菜单；
 *   2. toolType 不可用时只观测、永不过滤，避免误吞真手指；
 *   3. 自愈看门狗：若掐断后 onMouse 仍不投递，自动停止过滤并交还触摸镜像通道。
 *
 * 返回 AmclWindowInputFilterResult：0=已安装 1=状态未变 2=设备/版本不支持(API<15)
 * 3=windowId 非法 4=窗口管理器拒绝（1000/2000 见 hilog）5=已装但无法分类(API<24)。
 */
export const installWindowInputFilters: (windowId: number) => number;
/** 注销窗口级输入事件过滤器。页面销毁/退出游戏必须调用。返回值同上。 */
export const uninstallWindowInputFilters: (windowId: number) => number;
/**
 * 当前是否**正在**掐断鼠标派生的合成触摸包。
 * false 的原因可能是未安装、API<24 无法分类，或看门狗已降级。
 */
export const windowInputFilterActive: () => boolean;
/**
 * native XComponent AXIS 回调是否真的投递过滚轮样本。
 *
 * 部分设备（实测 MatePad Pro / API 24）注册该回调成功却从不调用，滚轮只以 ArkTS
 * onAxisEvent 的形式到达。
 *
 * ⚠️ **这只是一个取证用的观测量，不要用它决定所有权。**
 * 这里曾写着「为此 ArkTS 只在本函数返回 false 时充当滚轮所有者」—— 那条协议已在 §35
 * 被 `wheelChannelClaim` / `input_channel_policy` 取代（四条通道 + 静态优先级表 +
 * 能力发现）。ArkTS 侧现在只把它的返回值用于取证日志（`McGamePage` 的 `nativeOwns`
 * 变量处有同样的说明）。
 * 照旧文写一个新的滚轮生产者会**跳过能力登记与优先级表**，重演"方向反了、
 * 快速滚动又时好时坏"（那是 §35 整轮的内容）。
 */
export const nativeWheelChannelActive: () => boolean;

/**
 * 滚轮通道申请。一次调用完成"登记本通道确实送来过样本" + "询问它是否为当前所有者"，
 * 返回 true 才允许发 scroll。
 *
 * channel 取值（与 native 的 `AmclInputChannel` 一致，见 `cpp/platform/input_channel_policy.h`）：
 *   **4 = native XComponent AXIS（首选）**
 *   5 = ArkTS onAxisEvent
 *   6 = 轴驱动 PanGesture
 *   **7 = 合成触摸流的运动学指纹（末选）**
 *
 * ⚠️ 这里曾只列 5 与 6。native 侧实际接受**四个**取值，而 4 与 7 都有真实生产者
 * （4 在 native AXIS 回调里、7 在合成触摸识别里）。上界的唯一权威是那个枚举，
 * 不是本注释。（与 `sendSource*` 的 `source` 曾漏 `4=平台手势` 是同一类错误。）
 *
 * 每个滚轮产出点都必须先过这一关，否则会出现两条通道同时产出且符号相反的
 * "方向反了、快速滚动又时好时坏"。
 */
export const wheelChannelClaim: (channel: number) => boolean;

/**
 * 记录一次"键盘 held 缓存陈旧并已自愈"。
 *
 * ArkTS 侧的 held 缓存只是 repeat 分类的提示，权威状态在 native。若某次 UP 丢失
 * （焦点/生命周期边界），该键会永久被判成自动重复，而 native 那边已无 owner，
 * 边沿被整条丢弃 —— 用户表现为"这个键失灵了"。ArkTS 用重复窗口识别出这种陈旧状态
 * 并按首次按下重发时调用本函数。
 *
 * 稳态下该计数应恒为 0；非零即说明某处在丢 UP，是一条必须追查的线索。
 */
export const noteKeyRepeatSelfHealed: () => void;
/**
 * 常开滚轮取证：把每一次 ArkTS `onAxisEvent` 原样记入 native 日志。
 *
 * 滚轮通道归属是本机最后一个未取证项（native AXIS 注册成功但零样本）。滚轮频率极低，
 * 因此逐条打印 action / SDK 原始数值 / 是否让位给 native，产品构建同样输出。
 */
export const noteArktsAxisEvent: (
  action: number, verticalValue: number, yieldedToNative: boolean) => void;
/**
 * 通知 native：轴驱动的 Pan 手势（鼠标滚轮 / 触控板双指）正在进行。
 *
 * 本机滚轮不走 AXIS 回调，而是被 ArkUI 归一化成合成的手指滑动投给 XComponent，
 * 落在虚拟控件之外时会被解释成空白 look（即"滚轮上下转视角"）。ArkTS 用带 tag 的
 * PanGesture 认领它（`axisVertical` 仅在轴驱动时有值），并在手势期间置位本标志，
 * native 据此**只**抑制空白 look，其余角色不受影响。
 */
export const noteAxisPanActive: (active: boolean) => void;
/**
 * 发布屏幕像素密度（display.densityPixels）。
 *
 * 触摸流里的位移单位是 surface 物理 px，而 ArkTS `rawDeltaX/Y` 已被系统按显示大小
 * 比例缩小（官方说明：API 26 之前返回的是原始数据缩小 X 倍）。两条视角来源要进同一个
 * 漏斗，必须先统一量纲，否则按住左键拖动的灵敏度是平时的 density 倍。
 */
export const setDisplayDensity: (density: number) => void;
/**
 * Physical device add/remove from ArkTS `inputDevice.on('change')`.
 *
 * REMOVED is the only path that releases held owners for exactly one device:
 * native emits a deterministic UP per owner of that `deviceId` and leaves every
 * other device untouched. Call it after synthesizing UP edges for the legacy
 * compatibility plane; the native release is idempotent once no owner remains.
 *
 * `deviceId <= 0` is rejected and counted as a missing-identity diagnostic —
 * 0 is the bucket shared by every edge whose identity was unavailable, so
 * releasing it would cancel unrelated owners. `capabilities` uses the
 * AMCL_INPUT_DEVICE_CAP_* bits mirrored in
 * gamecontrol/src/main/ets/InputDeviceAbi.ets; unknown bits are dropped and
 * counted instead of being forwarded.
 */
export const publishInputDeviceChange: (deviceId: number, added: boolean,
  capabilities: number, deviceClass?: number) => void;
/**
 * Publish the current game Window/display context. `validFields` uses the
 * INPUT_SURFACE_FIELD_* bits from gamecontrol/InputSurfaceContext. Generation
 * is publisher-lease owned and must be positive. The latest valid payload is
 * cached even when XComponent has not created its native input session yet.
 */
export const publishInputSurfaceContext: (windowId: number, displayId: number,
  leftPx: number, topPx: number, widthPx: number, heightPx: number,
  density: number, refreshRateHz: number, transform: number,
  validFields: number, generation: number) => boolean;
/**
 * One native-classified physical MOVE transaction; ArkTS never chooses the grab/source plane.
 *
 * `localVpX` / `localVpY` 必须是 `MouseEvent.x` / `MouseEvent.y`，即
 * **组件坐标系、单位 vp**。不要传 `windowX/windowY`：那是窗口坐标系，原点不同，
 * 而 native 在菜单态会把这一对换算成 MC 的菜单光标位置（组件内物理 px）。
 * 传错的后果是 MC 菜单光标恒在左上角 ⇒ 鼠标点不中菜单按钮、悬浮也不出高亮。
 * vp→px 的换算在 native 侧用已下发的 display density 完成。
 */
export const physicalPointerMotionTransaction: (rawDeltaPresent: boolean,
  rawDx: number, rawDy: number, localVpX: number, localVpY: number,
  deviceId?: number, deviceClass?: number, monotonicTimeNs?: number) => void;
/** Atomic typed/legacy ingress for platform-provided rawDelta fields; Gate 0 has not approved the delta semantics (R1/R2/R3, plan §83.8). */
export const physicalPointerRelativeTransaction: (dx: number, dy: number,
  deviceId?: number, deviceClass?: number, monotonicTimeNs?: number) => void;
/** Typed AxisEvent owner. true means caller must not also write the legacy ring. */
export const physicalPointerWheelTransaction: (x: number, y: number,
  precise: boolean, deviceId?: number, deviceClass?: number,
  monotonicTimeNs?: number) => boolean;
/** Atomic route for an unverified window-coordinate difference; typed mode rejects it instead of fabricating relative input. */
export const physicalPointerRelativeFallbackTransaction: (dx: number, dy: number) => void;
/** Physical menu cursor route: verified native absolute suppresses ArkTS window coordinates; otherwise legacy is preserved. */
export const physicalMenuCursorPositionTransaction: (x: number, y: number) => void;
/**
 * Trace that window coordinates with an unverified window→XComponent physical-px
 * transform were observed. Bumps a counter only.
 *
 * ⚠️ The two arguments are **read by nobody**: the implementation calls
 * `napi_get_cb_info` with `argc = 2` and then goes straight to the counter
 * without touching `args`. The doc used to read "Trace window coordinates",
 * which suggests the values are recorded somewhere — they are silently dropped.
 * Kept as-is because the counter is the whole point; the signature is retained
 * so callers do not have to change if the values are ever actually needed.
 * (ArkTS side currently has zero callers either way.)
 */
export const traceUnverifiedCursorPosition: (x: number, y: number) => void;
/** True only in an explicitly compiled, non-routing Gate 0 evidence build. */
export const gate0InputTelemetryEnabled: () => boolean;
/** Diagnostic-only observation of the production ArkTS .onMouse stream. */
export const traceGate0ArktsMouse: (
  timestamp: number,
  deviceId: number,
  source: number,
  sourceTool: number,
  action: number,
  button: number,
  presence: number,
  pressedButtonCount: number,
  mouseCapability: boolean,
  mcStarted: boolean,
  grabbed: boolean,
  localX: number,
  localY: number,
  windowX: number,
  windowY: number,
  displayX: number,
  displayY: number,
  globalX: number,
  globalY: number,
  rawDx: number,
  rawDy: number,
  density: number,
  schemaVersion: number) => void;
export const sendMouseEvent: (button: number, action: number, mods: number) => void;
export const sendScrollEvent: (xoffset: number, yoffset: number) => void;
/**
 * Legacy synthetic look delta for touch controls/gamepad only. Physical mouse
 * producers must use physicalPointerRelative*Transaction. Removed in Phase 7
 * after synthetic-source adapters replace this compatibility entry.
 */
export const sendCursorDelta: (dx: number, dy: number) => void;

/** 按下时冻结完整绑定；成功返回不复用的64位十进制token，拒绝返回空串。 */
export const acquireSourceControl: (source: number, deviceId: number, controlId: string, codes: number[], publicationToken?: string, memberId?: string, groupEligibility?: string) => string;
/** 精确释放token；已经被生命周期复位的旧token幂等成功，不会释放新一代控件。 */
export const releaseSourceControl: (token: string) => boolean;

/**
 * 按端申报的输入注入（三端平级架构的 NAPI 接缝，见 cpp/platform/input_source.h）。
 *
 * `source` 取 AmclInputSource：**0=未申报（告警值） 1=触控虚拟按键 2=手柄 3=物理键鼠
 * 4=平台手势**（系统返回键/返回手势合成的 ESC —— 有正当来源但不属任何端）。
 * ArkTS 侧的常量在 gamecontrol 的 InputSourceRegistry.ets（`AmclInputSource`）。
 *
 * ⚠️ 这行曾漏掉 `4`（只写到 3）。上界的唯一权威是 native 的 `AMCL_INPUT_SOURCE_COUNT`
 * （`cpp/platform/input_source.h`），`napi_input.cpp` 的 `ReadInputSourceArg` 按它校验，
 * 而 `McGamePage.onBackPress` 实际就传 4。照这行写一个 `0..3` 的校验会**静默吞掉返回键的
 * ESC**，而那条路径没有其它生产者，故障表现是"返回键有时不弹菜单"且日志无痕。
 *
 * 与上面未申报端身份的 sendKeyEvent / sendMouseEvent / sendCursorDelta 并存：
 * 旧入口保留只为 fail-soft，新调用点一律用这一组。端身份带来三件事 ——
 * 持有记录按端隔离（RELEASE 只与同端配对）、按端选择性释放、视角量纲按端归一。
 * Key/Mouse 返回 true = 本端持有变更已生效：PRESS 已登记、REPEAT 已送出、RELEASE 已摘除，与别端共用该键
 * 而未发最终边沿也算；false = native 未改变本端记录（门关闭、复位中、无配对记录、未知动作），调用方应保留
 * 自身按下态以便重试。判据实现见 cpp/platform/external_held_edge_router.h。
 */
export const sendSourceKeyEvent: (source: number, key: number, scancode: number,
  action: number, mods: number) => boolean;
export const sendSourceMouseEvent: (source: number, button: number,
  action: number, mods: number) => boolean;
export const sendSourceScrollEvent: (source: number, xoffset: number,
  yoffset: number) => boolean;
export const sendSourceCursorDelta: (source: number, dx: number, dy: number) => boolean;
/** 触控增量已经过vp→surface px；手柄为virtual px。monotonicNs是采样时间，0为旧入口兼容。 */
export const sendSourceCursorSample: (source: number, dx: number, dy: number, monotonicNs: number) => boolean;
/** 冷能力只表示唯一neutral生产owner可借，不能代表consumer/窗口已经Ready。 */
export const sharedLookExecutionSupported: () => boolean;
/** gyro政策+真实资源的只读opaque签名；Hz变化不推进，空表示当前资格不可用。 */
export const touchGyroLeaseContext: () => string;
/** 冻结schema/policy/resource为私有gyro流；token字符串保全Native uint64身份。 */
export const beginTouchGyroLease: (schemaGeneration: number) => string;
/** completed gyro delta无二次dt积分，sensorTimeNs保持SDK number精度并只检查该原流顺序。 */
export const submitTouchGyroLease: (lease: string, dx: number, dy: number, sensorTimeNs: number) => boolean;
/** 停源无需前台/surface gate；精确原token幂等，不退休后来gyro流。 */
export const retireTouchGyroLease: (lease: string) => boolean;
/** counts/second来自1080×lookScale；Native采样同域时钟并按family求和后统一加工。 */
export const setMappedLookVelocity: (device: number, connection: number, vx: number, vy: number) => boolean;
/** timer只推进neutral owner；动作前缀由Native运输批次封存。 */
export const advanceMappedLookExecution: () => boolean;
/** 精确停本设备连接，拒绝控制release也不保留运动；旧连接不得改绑新资源。 */
export const retireMappedLookConnection: (device: number, connection: number) => boolean;
/**
 * 只释放该端在 native external 表里持有的输出，其余端不受影响。
 * 设备插拔与端级生命周期边界用它，取代"全局 releaseAll 连带误放其它端"。
 */
export const releaseSourceHeld: (source: number) => void;
/** ArkTS 侧的端自己复位之后记一笔，让端级复位日志各栏都有生产者。 */
export const noteSourceReset: (source: number) => void;
/**
 * 输入不变量自检的心跳。稳态零输出；账目失衡时 native 打一行 `AMCL_INVARIANT` error。
 *
 * 检查的关系（见 cpp/platform/input_invariants.h）：look/scroll 总数是否等于各端之和、
 * 每端"登记数 - 释放数 == 存活数"、`untagged` 栏是否为 0、平台手势是否误入 look 路径。
 * 目的是把"用户报告卡键 → 我们回溯"变成"日志自己先报警"。
 */
export const inputInvariantTick: () => void;
export const sendCursorPos: (x: number, y: number) => void;
/** Additive V1 typed TextInputSession availability. */
export const textInputSessionSupported: () => boolean;
export const beginTextInputSession: (generation: number) => boolean;
export const endTextInputSession: (generation: number) => boolean;
export const abortTextInputSession: (generation: number) => boolean;
/** Strict UTF-8 commit delivered as one owned native packet. */
export const commitTextInput: (generation: number, text: string) => boolean;
/**
 * 文本会话内的有序编辑键：把一次“按下+抬起”作为 typed 物理键提交，与 commitTextInput
 * 共用 core 序号，所以同一 IME 回合里的“先删后插”到 GLFW/SDL3/LWJGL2 仍保持先删后插。
 * 只接受成对的 (ohosKeyCode, glfwKey)：退格 2055/259、前删 2071/261、回车 2054/257、
 * 小键盘回车 2119/335、Esc 2070/256；其余一律拒绝。generation 是宿主会话号（可为 0，
 * 表示尚未重建，此时仍会先回答是否处于 typed 路由）。
 * 返回值（与 native PlatformInputTextKeyTapResult、gamecontrol 的 TextInputKeyTapResult 镜像）：
 * 0 = 已提交；1 = 进程不在 typed 物理路由，调用方必须改走原 sendSourceKeyEvent 按键对；
 * 2 = 被拒（键不在白名单、门禁关闭、会话号不是当前会话或 core 拒收），调用方不得回退 ring，
 * 否则编辑键会越过已排队的提交文本。
 */
export const textInputKeyTap: (generation: number, ohosKeyCode: number,
  glfwKey: number) => number;
/** selectionStart/selectionLength are Unicode-scalar indices. */
export const updateTextInputEditing: (generation: number, text: string,
  selectionStart: number, selectionLength: number) => boolean;
export const updateTextInputSelection: (generation: number,
  selectionStart: number, selectionLength: number) => boolean;
export const submitTextInputCandidates: (generation: number, items: string[],
  selected: number, pageStart: number, pageSize: number) => boolean;
/** Records the named platform gap; preview/commit text is never a candidate list. */
export const noteTextInputCandidatesUnsupported: () => void;
export const getTextInputCandidatesUnsupportedCount: () => number;
/** 阶段 2.8：可打印字符（IME / 物理键盘）。codepoint 为 Unicode 码位。 */
export const sendCharEvent: (codepoint: number) => void;
/** 阶段 2.8：可打印字符 + 修饰键 mask。 */
export const sendCharModsEvent: (codepoint: number, mods: number) => void;
export const isGrabbed: () => boolean;
/**
 * 方案 B：注册 grabbed 状态变化回调。MC 的 GLFW 层翻转 grab 时经 native 即时推送
 * （threadsafe function 回到 UI 线程），取代旧的 300ms 轮询 —— 无延迟、无 env 竞争。
 * 传 undefined / 省略参数 = 注销。重复调用会替换上一个回调。
 */
export const onGrabChange: (callback?: (grabbed: boolean) => void) => void;
/**
 * 注册按钮按下态回调。C 层接管按钮后，按下/抬起态经此推回 ArkTS 更新高亮
 * （键与视觉同源，支持 toggle/长按/双击等全部触发模式）。传 undefined / 省略 = 注销。
 */
export const onButtonPressed: (callback?: (id: string, pressed: boolean) => void) => boolean;
/** native PRESS 触觉请求；回调在 UI 线程执行，队列有界，传空注销。 */
/** 反馈产生时冻结的触控身份；Native有界队列及年龄校验，ArkTS只比较不解析uint64身份。 */
export interface TouchFeedbackIdentity {
  version: number;
  registration: string;
  controlId: string;
  schemaGeneration: string;
  session: string;
  grabEpoch: string;
  generatedNs: string;
}
export const onHaptic: (callback?: (strength: number, identity: TouchFeedbackIdentity) => void) => boolean;
/*
 * ⚠️ registerButton / registerJoystick / clearButtons / clearJoystick 已删除。
 *
 * 它们把"按钮矩形 / 摇杆矩形"填进 C 层，而那张表的唯一读取方（hitButton / isInJoystick）
 * 位于一个永不执行的分支里 —— ArkTS 每次布局重建都在跨语言填一张没人读的表。
 * 触控虚拟按键端的权威表述是 `setControlSchema`（含 hit-test、hitSlop、handledBy、
 * 四种 trigger），不要再加回这条并行路径。
 *
 * ⚠️ 墓碑: `setCompSize` 已删除（2026-08-21）—— 同一个形状的第二例：它写入的
 * `s_compWidth`/`s_compHeight` 终点零读者。组件尺寸由 `setControlSchema` 的
 * `compWidth`/`compHeight` 携带，那两个字段是活的（两层各做一次矩形越界校验）。
 * 详见计划 §64.3。
 */


export const setTouchPaused: (paused: boolean) => void;
/**
 * 统一释放全部 native/ArkTS 兼容输入 owner。
 *
 * reason（上界的权威是 `cpp/platform/touch_input.h` 的 `AmclInputCancelReason`）：
 *   1=pause 2=background 3=surface 4=page 5=window **6=focus-lost**
 *
 * ⚠️ 曾漏写 `6`。ArkTS 侧只传 2 与 4，`6` 由 native 在失焦时内部使用，
 * 所以漏写目前没有造成故障；但照这行写一个 `1..5` 的校验会**静默吞掉失焦复位**，
 * 而失焦是 reset-epoch 对账最主要的触发源之一（`输入架构规范.md` §3.2）。
 */
export const cancelAllInput: (reason: number) => void;
/** 精确十进制 reset epoch；仅用于相等比较，变化表示页面 held/repeat/modifier 缓存必须清空。 */
export const getInputResetEpoch: () => string;
/** IRS1:总代次:触控代次:手柄代次:实体代次:文本代次；每域累计，可识别多次未观测复位。 */
export const getInputResetDomains: () => string;
/** 阶段 1.3：视角灵敏度系数，默认 1.0，clamp 到 0.1..5.0。 */
export const setLookSensitivity: (v: number) => void;
/** 全部字段校验后原子生效；false表示未修改任何参数，调用方应保留待应用版本。 */
export const applyLookConfiguration: (sensitivity: number, invertY: boolean, smoothing: number, acceleration: number) => boolean;
/** 原子应用单个真实platform来源的完整政策，0兼容/1触控/2映射手柄/3物理；不改变其它来源。 */
export const applySourceLookConfiguration: (source: number, sensitivity: number, invertY: boolean, smoothing: number, acceleration: number) => boolean;
/** 阶段 1.3：Y 轴倒置。 */
export const setInvertY: (b: boolean) => void;
/** 守恒 backlog 的响应系数（0.1..1.0，1.0=立即输出）；正常手势 UP 会补齐余量，不改变总灵敏度。 */
export const setLookSmoothing: (alpha: number) => void;
/** 方案 C：视角加速强度（0..1，0=关闭）。手速越快增益越高、慢速微调 1:1；对触摸/鼠标/手柄三源统一生效。 */
export const setLookAccel: (v: number) => void;

// ============================================================
//  Control Schema v3：配置与几何同事务；v2只使用兼容缺省。
// ============================================================
/** 单个控件描述。坐标与 hitSlop 均为已乘 density 的物理 px。 */
export interface ControlSchemaEntry {
    id: string;          // 唯一 UTF-8 id，1..23 字节；禁止静默截断
    kind: number;        // 0=BUTTON 1=JOYSTICK 2=SCROLL 3=DRAWER 4=HOTBAR
    handledBy: number;   // 0=native 1=arkts；arkts 只按 exact rect 命中
    x: number; y: number; w: number; h: number;
    hitSlop: number;     // native 控件命中扩张物理 px，0..256
    keyOrMouse: number;
    keys: number[];      // 最多 6 个；PRESS 正序、RELEASE 倒序
    trigger: number;     // 0=press 1=toggle 2=doubleTap 3=longPress
    dragLook: boolean;
    haptic: boolean;     // native PRESS 是否请求 UI 触觉
    swipeGroup?: number; // v3：快照内滑动组；0/缺省不启用。
}
/** 与布局纯模型投影对应；动作数组顺序见 TouchActionBindings，0 表示解除绑定。 */
export interface TouchSchemaOptions {
    version: number;
    touchpad: boolean;
    menuSensitivity: number;
    menuScroll: boolean;
    menuHoldMs: number;
    floatingJoystick: boolean;
    sprint: boolean;
    autoWalk: boolean;
    sprintThreshold: number;
    hotbarSwap: boolean;
    hotbarDrop: boolean;
    holdMs: number;
    gestureMode: number;
    actions: number[];
}
export interface ControlSchemaMsg {
    schemaVersion: 2 | 3 | 4;
    groupSchema?: TouchGroupSchema;
    compWidth: number;
    compHeight: number;
    /** publication v1必须与Native实际窗口单位一致；旧setControlSchema兼容读取可不提供。 */
    contextDensity?: number;
    contextTransform?: number;
    grabbed: boolean;
    deadZone: number;
    controls: ControlSchemaEntry[]; // v3：256个用户控件及至多4个运行时辅助区域；v2最多256。
    touch?: TouchSchemaOptions; // v3 必须提供；v2 不读取扩展。
}
/** [菜单x,y,显示标记,摇杆中心x,y,归一化dx,dy,锁定,待锁定,长按进度,摇杆按住,使用物品按住,schema代次,摇杆条目索引,菜单手势活跃]。 */
/** 前15项保持视觉前缀；15..24为真实移动/选格/双指滚轮/工具鼠标累计反馈、活动触指与Native抓取态。 */
export const touchInteractionVisual: () => number[];
/** 显式生产维护grab公告/已交付光标；false表示真实mode端口尚不可用，视觉读取不执行这些动作。 */
export const maintainTouchInput: () => boolean;
/** 游戏线程采集的GUI快照；状态非2表示当前无可靠能力，禁止把旧值当作生效设置。 */
export const gameGuiState: (surfaceWidthPx: number, surfaceHeightPx: number, realGameVersion: string, guideActive?: boolean) => number[];
/** GUI异步观察的本局/来源端口。0表示真实未取得资格；uint32身份不回绕，不能重新绑旧前端。 */
export const gameGuiStartSession: (activityId: number) => number;
export const gameGuiCaptureSession: () => number;
export const gameGuiStopSession: (scope: number) => boolean;
export const gameGuiAttachSource: (originScope: number) => number;
export const gameGuiRetireSource: (source: number) => boolean;
/** 只取原source真实缓存并投递latest请求；不进入JNI，不等待停机worker。 */
export const gameGuiStateForSource: (source: number, surfaceWidthPx: number, surfaceHeightPx: number, realGameVersion: string, guideActive?: boolean) => number[];
/** real surface px增量，只移动菜单指针；游戏抓取、输入暂停或其它背景手势占用时拒绝。 */
export const moveTouchMenuPointer: (dxPx: number, dyPx: number, publicationToken?: string, panelPrefix?: string) => boolean;
/** 统一鼠标的菜单持有：-1左键、-2右键、340 Shift；owner由面板实例命名空间限定。 */
export const touchMenuButton: (owner: string, code: number, down: boolean, publicationToken?: string) => boolean;
/** 取消本panelPrefix认领的工具子域；旧实例确认结束但不伤新面板，成功后可清本UI租约。 */
export const cancelTouchMenuMouse: (panelPrefix: string) => boolean;
/** 菜单滚轮步进，真实grabbed时拒绝，不影响游戏快捷栏。 */
export const touchMenuScroll: (steps: number, publicationToken?: string, panelPrefix?: string) => boolean;
/** 悬浮鼠标排除区，surface px；宽高均为0清除，不改变持有或schema代次。 */
export const setTouchMenuMouseBounds: (xPx: number, yPx: number, widthPx: number, heightPx: number, publicationToken: string, panelPrefix?: string) => boolean;
/** 教学工具栏独立排除区，世界/菜单均生效；空矩形撤销，不触碰schema代次或真实按住状态。 */
export const setTouchGuideBounds: (xPx: number, yPx: number, widthPx: number, heightPx: number, publicationToken: string) => boolean;
/** 用户确认后的菜单缩放恢复；返回请求ID，0为未接受，必须用gameGuiState最终回执确认。 */
export const restoreGameGuiScale: (requestedScale: number, expectedRevision: number) => number;
/** 具名原source恢复，返回Native票据而非成功；读同source的requestId/result才是最终ACK。 */
export const restoreGameGuiScaleForSource: (source: number, requestedScale: number, expectedRevision: number) => number;
/** 已按采样ns积分的虚拟位移；独立加工时钟，失败不产生输入，不自动启用传感器。 */
export const sendTouchGyroSample: (dx: number, dy: number, timeNs: number, schemaGeneration: number) => boolean;
/** 成功返回非 0 generation；拒绝返回 0 且不改变当前 native generation。 */
export const setControlSchema: (schema: ControlSchemaMsg) => number;

/** 发布扩展v1；所有代次/token为不解析的十进制身份，status不借用旧setControlSchema返回值。 */
export interface TouchPublicationReceipt {
  groupRevision?: string;
  version: number;
  status: 'idle' | 'fenced' | 'committed' | 'unchanged' | 'stale' | 'invalid' | 'unavailable' | 'waiting';
  surface: string;
  session: string;
  policy: string;
  schemaGeneration: string;
  token: string;
  operationId: string;
  candidateId: string;
  fenced: boolean;
  nativeTouches: number;
  modalCount: number;
  /** Native当前解释单位；UI投影必须与此一致后才可提交。 */
  density: number;
  transform: number;
  /** Native真实grab公告身份独立于density/policy，不用UI回调是否到达代替场景事实。 */
  grabEpoch: string;
  grabbed: boolean;
}
/** 当前唯一active操作的状态，用于丢回执恢复；不保存无限操作历史。 */
export const touchPublicationState: () => TouchPublicationReceipt;
/** 先关新DOWN，再由回执/nativeTouches及ArkTS触点确认零触点条件。 */
export const beginTouchPublication: (operationId: string, candidateId: string, expectedSurface: string,
  expectedSession: string, expectedPolicy: string, expectedSchema: string, expectedGrabEpoch: string) => TouchPublicationReceipt;
export const publishTouchSchema: (schema: ControlSchemaMsg, operationId: string) => TouchPublicationReceipt;
/** 相同operation/token的已验证布局确认；旧确认不能解封新发布。 */
export const confirmTouchPublication: (operationId: string, token: string) => boolean;
export const abortTouchPublication: (operationId: string) => TouchPublicationReceipt;
/** 具名、不可复用的touch域模态租约；失败返回空串，关闭只归还自己的token。 */
export const acquireTouchModal: (owner: string) => string;
export const releaseTouchModal: (token: string) => boolean;
/** 包括publication fence、modal和当前token身份的Native复核。 */
export const isTouchPublicationCurrent: (publicationToken: string) => boolean;

/** v4 独立扩展；v3 条目 ABI 保持不变。phase 顺序为 press/longPress/click/doubleClick。 */
export interface TouchGroupSchemaAction { target: number; operation: number; }
export interface TouchGroupSchemaPhase { keys: number[]; autoKeep: boolean; actions: TouchGroupSchemaAction[]; }
export interface TouchGroupSchemaControl { group: number; phases: boolean; fcl: boolean; mouseTool: boolean; rank: number; bindings: TouchGroupSchemaPhase[]; }
export interface TouchGroupSchemaDefinition { id: string; initialVisible: boolean; }
export interface TouchGroupSchema { profile: string; groups: TouchGroupSchemaDefinition[]; controls: TouchGroupSchemaControl[]; }
export interface TouchGroupReceipt { token: string; revision: string; enabled: boolean; pending: boolean; mask: boolean[]; epochs: string[]; }
export interface TouchGroupCommandReceipt { status: 'pending' | 'committed' | 'presented' | 'stale' | 'rejected' | 'expired'; revision: string; }
export const readTouchGroups: (publicationToken: string) => TouchGroupReceipt;
export const confirmTouchGroups: (publicationToken: string, revision: string) => boolean;
export const isTouchGroupControlCurrent: (publicationToken: string, controlId: string, eligibility: string) => boolean;
export const bindTouchGroupMouseOwner: (publicationToken: string, controlId: string, eligibility: string) => boolean;
export const invokeTouchGroupControl: (publicationToken: string, controlId: string, eligibility: string, producer: string, sequence: string, phase: number) => TouchGroupCommandReceipt;
export const restoreTouchGroups: (publicationToken: string, producer: string, sequence: string) => TouchGroupCommandReceipt;
/** 返回独立注册身份；注销必须传原身份，旧页面不得取消新页面的必要通知。 */
export const onTouchGroupsChanged: (listener: (() => void) | null, registration?: string) => string;

// JIT 权限检测（同步，极快）— Forge/游戏启动前必检
export const checkJitAvailable: () => boolean;

// 单个 Forge/NeoForge processor（任意 args + 显式工作目录，fork + 干净 classpath 的独立 JVM）
export const runJavaProcessor: (filesDir: string, jdkVersion: string, xmxMb: number, classpath: string, mainClass: string, args: Array<string>, workDir: string, logFile: string) => Promise<number>;
/** 完整HDC私有host启动后返回真实端口；store返回负数unsupported。 */
export const startSideloadHdc: (identityRoot: string) => Promise<number>;
/** Entry最早固定app filesDir；失败时不得启动自动文件任务，不授予系统安装权限。 */
export const configureSideloadInstallRoot: (filesDir: string) => boolean;
/** 实际_POSIX CLK_TCK，用于严格绑定bm进程startTicks与hilog单调时间；未知返回0。 */
export const sideloadInstallClockTicks: () => number;
/** SH租约持有到实际Native/processor收敛；空filesDir使用已固定root，失败返回0。 */
export const acquireSideloadFileLease: (filesDir: string) => number;
/** 只释放本PID的确切token，重复/旧token不会解除新的租约。 */
export const releaseSideloadFileLease: (token: number) => boolean;
/** 使用本机 HDC 发现协议获取随机端口；0 表示未发现，不能据此声称系统已关闭调试。 */
export const discoverSideloadPort: () => Promise<number>;
/** 仅由更新服务串行构造固定操作，数值返回不替代新进程安装核验。 */
export const runSideloadHdcCommand: (arguments: string, privateOutputPath?: string) => Promise<number>;
/** 仅停止应用自己创建的更新host；不关闭设备daemon或其他HDC服务。 */
export const stopSideloadHdc: () => Promise<number>;

// SSOT: 主 JVM / Forge installer 子 JVM 共享的"OHOS 兼容性修复"参数清单
// 实现见 entry/src/main/cpp/jvm/jvm_common_args.cpp
// 给 ArkTS 层（LaunchProfileBuilder）做 version.json 参数去重用
export const getCommonJvmArgs: () => string[];

// GPU 信息
export const getGpuInfo: () => string;

// Vulkan 能力探针（VULKAN_ADAPTATION_PLAN.md Phase 0）
// 只读盘点本机 Vulkan：loader 版本 / 实例扩展（VK_KHR_surface + VK_OHOS_surface）/
// 物理设备 core 版本 / 关键设备扩展 / 真实 feature bit（vkGetPhysicalDeviceFeatures2）/
// 驱动信息（VK_KHR_driver_properties）。返回人类可读报告字符串。
export const getVulkanInfo: () => string;

// Vulkan 能力门控 JSON（VULKAN_ADAPTATION_PLAN.md §十）
// 返回机器可读 JSON 字符串：{ available, reason, warning, loaderVersion, deviceName, deviceType,
// vendorName, vendorId, deviceId, deviceApiVersion, deviceLocalMemoryMB, driverName,
// driverInfo, conformanceVersion, hasOhosSurface, hasSwapchain, hasDynamicRendering,
// hasPushDescriptor, hasSynchronization2, featuresQueried, dynamicRenderingFeature,
// synchronization2Feature, maxPushDescriptors }。
// 供 ArkTS 在用户选 MC 26.2+ 时静默调用，据此显示"Vulkan 可用 / 不可用"。
export const getVulkanCapabilityJson: () => string;
export const getGraphicsCapabilityJson: (profileId: string, requirementId: string, windowProvider: string, availabilityOnly?: boolean) => string;

// Vulkan 实战自检（VULKAN_ADAPTATION_PLAN.md Phase B · 端到端呈现链）
// 真的建 instance→device→OHOS surface→swapchain→clear→present 跑一遍，返回逐步 ✅/❌ 报告，
// 精确定位华为驱动在哪一环断。可选参数：XComponent 的 OHNativeWindow 指针（数值字符串），只用于
// 核对窗口宿主当前租约；窗口一律经窗口宿主取得（无窗口时仅验证到设备+队列层）。
export const runVulkanSelfTest: (nativeWindowPtr?: string) => string;

// ⚰️ 2026-08-27（渲染后端治理 §S6）：曾有 `runOSMesaSelfTest(logDir, driver)`（OSMesa + Zink 自检）。
// 随 zink 完全退役移除；native 侧实现与 NAPI 注册同批删除。
// 索引：prebuilt/mesa-zink/integration-archive/README.md

// 下载引擎 (P1-3 v3)
// ======================================================================
// Stage 1a: probe API — 验证 libcurl.so 真机加载 + 符号解析，无实际下载
export const downloadEngineProbe: () => string;      // 返回 libcurl 版本+feature 字符串
export const downloadEngineSelfTest: () => number;   // 自检 init/easy/setopt/cleanup 链路，0 = OK

// Stage 2: 完整下载任务 API
// 见 entry/src/main/cpp/download/download_napi.cpp 和
//    docs/guides/download-system-redesign-v3.md

/** 创建下载任务的配置 */
export interface DownloadFileSpec {
    /** 单源短时下载令牌，仅在内存使用，禁止写入 URL 或持久记录。 */
    bearerToken?: string;
    /** 短时权限消费规则，仅内存传递，单调持续时间由Native接收时建立截止。 */
    authorizedPolicy?: { singleUse: boolean; maxHttpAttempts: number; validForNewRequestMs: number; maxBytes: number; };
    /** 本地保存路径（绝对路径） */
    localPath: string;
    /** 镜像 URL 列表（按优先级排序，引擎会逐个 fallback） */
    urls: string[];
    /** 可信绝对根目录；localPath 必须严格位于其内。 */
    allowedRoot: string;
    /** 完整性校验（可选，但强烈推荐） */
    check?: {
        /** 预期 SHA-1，40 字符 hex；空 = 不校验 */
        sha1?: string;
        /** 预期文件大小（字节）；-1 = 不校验 */
        size?: number;
    };
    /**
     * 高并发分段数（可选，默认不传 = 0 = 按引擎默认 4 段分割）。
     *
     * 仅用于慢速镜像的大文件 —— 典型为 Forge installer.jar。BMCLAPI 对 forge 内容常 403
     * 回落到官方 Forge maven（maven.minecraftforge.net），后者支持 Range 但单连接限速很低
     * （实测 ~30KB/s），4 段并行也只有 ~120KB/s。设此项让引擎切更多并行段（如 16），用
     * 并发逼近网络真实上限。对齐 PCL2 "速度低时追加下载线程" 的策略。引擎会钳制到
     * worker 池上限与文件大小。
     *
     * 原版 client/libraries/assets 不设置此项 → 走默认 4 段分割，行为不变。
     */
    maxConnections?: number;
}

export interface DownloadTaskSpec {
    /** UI 显示名（任务卡片标题），例如 "1.20.4 Vanilla" */
    name: string;
    /** 任务包含的文件列表 */
    files: DownloadFileSpec[];
}

/** onProgress 回调参数 */
export interface DownloadProgressEvent {
    taskId: number;
    /** TSFN 观察者代次，不等于 executionEpoch，也不等于 ArkTS closure generation。 */
    registrationGeneration?: number;
    /** start/resume/retry generation；旧 epoch 事件必须丢弃。 */
    executionEpoch: number;
    overallProgress: number;   // 0.0 ~ 1.0
    speedBps: number;          // 当前瞬时速度（字节/秒）
    activeThreads: number;     // 正在下载的线程数
    currentFile: string;       // 当前正在下载的文件 localPath
    filesDone: number;
    filesTotal: number;
    bytesDone: number;
    bytesTotal: number;        // -1 表示部分文件 size 未知
    // v5: 剩余秒数，-1 = 未知（速度为 0 或 bytesTotal=-1）
    etaSeconds: number;
    // v5: 当前活跃下载的文件 basename 列表（最多 3 个）
    currentFiles: string[];
}

// v5: 单个失败文件的详情（Complete 事件里聚合返回）
/**
 * 所有错误出口共享同一 Native 值快照，complete/query/list/failedFiles 不再各自漏字段。
 * bytesWritten 保留现有 Native 兼容口径；授权状态由结构化字段表达，不能从 message 推断。
 * 新执行事实保持可选，以兼容旧 ArkTS mock/调用方构造的错误。
 */
export interface DownloadError {
    kind: string;
    message: string;
    nativeCode: number;
    httpStatus: number;
    url: string;
    triedUrls: string[];
    needsNewLease?: boolean;
    requestStarted?: boolean;
    successfulHeadersSeen?: boolean;
    bytesWritten?: number;
    httpAttempts?: number;
    retryAfterMs?: number;
}

export interface DownloadFailedFile {
    localPath: string;
    basename: string;
    lastError?: {
        kind: string;
        message: string;
        httpStatus: number;
        nativeCode: number;
        /** 新桥完整透传；旧四字段详情仍然合法。 */
        url?: string;
        triedUrls?: string[];
        needsNewLease?: boolean;
        requestStarted?: boolean;
        successfulHeadersSeen?: boolean;
        bytesWritten?: number;
        httpAttempts?: number;
        retryAfterMs?: number;
    };
    triedUrls: string[];
}

/** onComplete 回调参数 */
export interface DownloadCompleteEvent {
    taskId: number;
    registrationGeneration?: number;
    /** 该终态所属的 start/resume/retry generation。 */
    executionEpoch: number;
    /** true = 正常完成；false = 失败 或 被取消（看 aborted 字段） */
    success: boolean;
    // v5: 是否被用户主动取消（success=false && aborted=true）
    aborted: boolean;
    // v5: 任务总耗时（毫秒）
    durationMs: number;
    /** 失败时提供详细错误信息（aborted=true 且无底层错误时可能缺省） */
    error?: DownloadError;
    // v5: 失败文件列表（每个 Failed 文件的 basename + 错误 + 试过的源）
    failedFiles: DownloadFailedFile[];
    /**
     * 最终进度快照。Engine 在转终态前 computeProgress 一次填好。
     * UI 在 onComplete 里直接从这里读 bytesDone/filesDone，无需等 onProgress
     * 触达（小文件秒下时 onProgress 可能来不及）。
     */
    finalProgress: {
        overallProgress: number;
        speedBps: number;
        currentFile: string;
        filesDone: number;
        filesTotal: number;
        bytesDone: number;
        bytesTotal: number;
        // v5: 剩余秒数（-1 = 未知）
        etaSeconds: number;
        // v5: 活跃文件 basename 列表
        currentFiles: string[];
    };
}

/** listActive/queryTask 返回的完整任务快照 */
export interface DownloadTaskInfo {
    taskId: number;
    executionEpoch: number;
    name: string;
    state: string;             // "Waiting" / "Loading" / "Finished" / "Failed" / "Aborted"
    progress: number;
    overallProgress: number;
    filesDone: number;
    filesTotal: number;
    speedBps: number;
    activeThreads: number;
    currentFile: string;
    currentFiles: string[];
    bytesDone: number;
    bytesTotal: number;
    etaSeconds: number;
    durationMs: number;
    terminal: boolean;
    /** Engine startup/callback/file/transport 均已收敛；不等价于成功，也不代替 purge。 */
    executionSettled?: boolean;
    error?: DownloadError;
    failedFiles: DownloadFailedFile[];
}

/** 创建任务；返回 taskId */
export const downloadCreateTask: (spec: DownloadTaskSpec) => number;
/** 只读Native steady毫秒，下载权限不依赖可能回拨的用户系统时间。 */
export const downloadSteadyTime: () => number;

/** 启动任务（Waiting → Loading）；返回是否成功 */
export const downloadStart: (taskId: number) => boolean;

/** 取消任务（停所有线程，保留 meta 下次可续）；返回是否成功 */
export const downloadCancel: (taskId: number) => boolean;

/** 注册进度回调（每 200ms 由 Engine 节流触发）；返回是否成功 */
export const downloadOnProgress: (
    taskId: number,
    cb: (event: DownloadProgressEvent) => void
) => boolean;

/** 注册完成回调（任务结束时触发一次，无论成功/失败/取消） */
export const downloadOnComplete: (
    taskId: number,
    cb: (event: DownloadCompleteEvent) => void
) => boolean;

/** 查询所有任务（不管状态） */
export const downloadListActive: () => DownloadTaskInfo[];

/** 查询单个任务终态/进度快照；任务不存在时返回 null */
export const downloadQueryTask: (taskId: number) => DownloadTaskInfo | null;

/** 撤销当前 napi_env 的本轮观察者；同 env 可重绑，不停止进程级任务。真正 env cleanup 永久关闭。 */
export const downloadDetachCallbacks: () => void;

/** 进程退出前调用：停所有任务 + curl_global_cleanup */
export const downloadShutdown: () => void;

/**
 * 设置 CA bundle（PEM 文件）绝对路径。
 * OHOS 没有 /etc/ssl/certs/，所有 HTTPS 握手会失败。ArkTS 应在 App 启动时
 * 把 rawfile/cacert.pem 抽到 filesDir，然后用绝对路径调此方法。
 * 传空串可回退 curl 默认行为（通常也不 work）。
 */
export const downloadSetCaBundle: (path: string) => void;
/** 对普通文件做 no-follow SHA-1；失败抛异常。 */
export const downloadComputeFileSha1: (path: string) => string;

/**
 * 注入加速网关配置（由 RelayClient 握手成功后调用）。
 *
 * native 侧负责两件 ArkTS 做不到的事：
 *   1. 把官方源 URL 改写成经网关的 URL（贴着真正发出的那次请求，换源/重定向都不会错位）；
 *   2. 为**每个分段请求**单独生成持有证明签名（各段独立 nonce，无法预先算好）。
 *
 * @param base          网关基址，如 https://amcl.lovedhy.cn/dl（必须 https）
 * @param ticket        握手换来的票据
 * @param sessionKey    持有证明密钥；requireProof=true 时必填。**仅内存**，不要落盘
 * @param requireProof  服务端是否强制持有证明（取握手响应的 requireProof）
 * @param expiresAtMs   票据到期时刻（本地时钟毫秒）；native 会留 30s 余量提前停用
 */
export const downloadSetRelay: (
  base: string, ticket: string, sessionKey: string, requireProof: boolean, expiresAtMs: number
) => void;
/** 关闭加速（用户关开关 / 握手失败 / 退出加速模式） */
export const downloadClearRelay: () => void;
/** 加速网关运行统计（诊断用） */
export const downloadRelayStats: () => RelayStatsNative;

export interface RelayStatsNative {
  requests: number;
  failures: number;
  fallbacks: number;
  authRejects: number;
  /** 连续失败过多，正在熔断（期间自动回退直连） */
  tripped: boolean;
  /** 当前配置是否可用（已启用 + 票据未过期 + 字段齐全） */
  usable: boolean;
}
/** 同目录 no-replace 发布并 fsync 父目录；目标已存在或持久化失败返回 false。 */
export const downloadPublishNoReplace: (sourcePath: string, destinationPath: string) => boolean;

// ======================================================================
// v5: 扩展 API — 暂停 / 继续 / 清理 / 重试 / Purge
// ======================================================================

/**
 * Phase 3 (S2-2): 同步拉一个 URL 到内存 buffer。带多镜像 fallback 。
 * 为元数据（version_manifest_v2 / asset_index / Forge file_list）提供与
 * NetThread 一致的 curl 配置（CA bundle / UA / 超时 / follow redirect）。
 * 不走 task 队列、不写磁盘、不分段、不 sha1。
 *
 * @param primaryUrl     首选 URL
 * @param mirrors        次源 URL 列表（可选，首源失败后按顺序尝试）
 * @param timeoutSec     单次尝试总超时（含 connect），默认 30 秒
 * @returns Promise 解析为：
 *   成功: { ok: true, body: string }
 *   失败: { ok: false, errorKind: string, errorMessage: string }
 *           errorKind 取值： 'DnsFail' / 'ConnectFail' / 'Timeout' / 'SslFail' /
 *                          'HttpStatus' / 'PerformFail' / 'Unknown'
 */
export interface DownloadFetchTextResult {
    ok: boolean;
    body?: string;
    /** Phase 2.3: HTTP 响应码，0 = 未拿到响应。200/304 时 ok=true。 */
    statusCode?: number;
    /** Phase 2.3: 响应头（key 小写）。仅 ok=true 时填，对 304 也会带 ETag。 */
    headers?: Record<string, string>;
    errorKind?: string;
    errorMessage?: string;
}
export const downloadFetchText: (
    primaryUrl: string,
    mirrors?: string[],
    timeoutSec?: number,
    /** Phase 2.3: 请求头（如 If-None-Match / If-Modified-Since），可选 */
    requestHeaders?: Record<string, string>,
    /** NAPI/JS body 硬上限，默认 16 MiB，可由调用方下调。 */
    maxResponseBytes?: number
) => Promise<DownloadFetchTextResult>;

/**
 * v5: 暂停任务（等价 cancel，但保留 meta 供 resume 续传）。
 * 后端等所有 NetThread 收敛后会触发 onComplete(aborted=true)。
 */
export const downloadPauseTask: (taskId: number) => boolean;

/**
 * v5: 恢复 Aborted / Failed 的任务。
 * 引擎会对非 Finished 的文件做 resetForRetry + 重走 start()（含 sha1 预检
 * 与 meta 恢复），已经下好的部分不会被重下。
 */
export const downloadResumeTask: (taskId: number) => boolean;

/**
 * v5: 清理任务的磁盘残留（local + .download-meta）。
 * 仅在 Aborted / Failed 状态允许。返回释放的字节数。
 */
export const downloadDeleteTaskFiles: (taskId: number) => number;

/**
 * v5: 只重试指定路径的失败文件；传空数组表示重试所有 Failed 文件。
 * 任务状态必须是 Failed / Aborted。
 */
export const downloadRetryFailed: (taskId: number, localPaths: string[]) => boolean;

/**
 * v5: 从任务注册表移除终态任务（Finished / Failed / Aborted 才允许）。
 * 供下载历史管理时使用 — 调用方确保不再持有任务引用。
 */
export const downloadPurgeTask: (taskId: number) => boolean;

// 测试模块（MC_OHOS_BUILD_TESTS）
export const runJitTests: (sandboxPath: string) => string;
export const runJvmTests: (appDir: string) => string;
export const runGlfwTest: () => string;
export const runGl4Test: () => string;
export const runMgTest: () => string;
/** default/TestHooks冷启动诊断的真实MG深度与uniform声明初值共享场景；两份查询/像素计数独立，返回完成身份，完成后必须重启。 */
export const runMgDepthRangeTest: () => string;
/** 冷诊断进程的MG生产factory身份。0低版本首次，1高版本首次；完成须重启。 */
export const runMgContextIdentityTest: (highFirst: number) => string;
/** 冷诊断进程的MGL精度限制/失败重链与旧current像素；不授予完整Core资格。 */
export const runMobileGlProgramTest: () => string;
export const runLwjglTest: (filesDir?: string) => string;
/**
 * SDL3 移植 C2 关卡真机探针：验证 SDL_GL_GetProcAddress("glGetError") 是否与
 * dlsym(libglfw.so, "glGetError") 同址——MC 26.3 的 GlBackend.loadLibrary() 会
 * 硬校验这一点，不等就抛 BackendCreationException(OPENGL_MISSING)。
 * 必须在应用进程内跑（linker namespace 按应用配置）。
 * 见 docs/adaptation/SDL3_MIGRATION_PLAN.md §四 C2。
 * @param sdl3Path libSDL3.so 绝对路径；传空则按名字 dlopen 走默认搜索路径。
 */
export const runSdl3C2Test: (sdl3Path?: string) => string;
/**
 * SDL3 窗口创建探针：验证 prebuilt/sdl3/patches/0001（宿主注入 native window）。
 * 走通 SDL_CreateWindow → SDL_GL_CreateContext → SDL_GL_MakeCurrent → glGetString。
 *
 * ⚠️ 必须从**带 XComponent 的页面**调用（RenderPage / VulkanPage）：它经窗口宿主快照取
 * OnSurfaceCreated 发布的 NativeWindow（宿主不再发布窗口指针环境变量）。
 * 在 DevTools 页调用只会得到 INCOMPLETE（那里没有 surface）；本进程已认领 JVM 后返回 SKIP。
 * 见 docs/adaptation/SDL3_MIGRATION_PLAN.md §C1.3。
 */
export const runSdl3WindowTest: (sdl3Path?: string) => string;

/**
 * default/TestHooks的现成MobileGL生产资格诊断：真实shader/FBO读回、pbuffer/window
 * 两轮切换、present递增及完整资源退休。必须在冷进程、无游戏占用且RenderPage
 * 已有真实XComponent窗口时调用；两个历史按钮是同一executor的alias。
 * 原capability/admission文本保持，独立MOBILEGL_QUAL字段补本次实际加载DSO的
 * checked副本/唯一run/PID与报告关闭后外部RETURN。I/O失败使artifact资格不完整，
 * 不篡改原功能结果；函数正常返回不代表app自然退出或lifecycle_smoke已测。
 */
export const runMobileglProbe: () => string;
export const runMobileglPbufferProbe: () => string;

/**
 * JDK IPv6 能力探针（Phase 0 诊断，docs/adaptation/JDK_IPV6_ADAPTATION_PLAN.md §3 P0-a）。
 *
 * 逐条复现 libnet `IPv6_supported()` 的判据并分别打印：
 *   C1 socket(AF_INET6)  C2 getsockname(fd 0)（仅 JDK 17）
 *   C3 fopen(/proc/net/if_inet6)+fgets  C4 dlsym(RTLD_DEFAULT,"inet_pton")
 * 另外枚举 getifaddrs 的 IPv6 地址，并预演"若要合成 if_inet6，数据够不够、格式对不对"。
 *
 * ⚠️ 必须在应用进程内跑（hdc shell 域与应用域是两套 SELinux 上下文，而要测的正是
 *   沙箱能不能读 /proc/net/if_inet6）。**只观测**：不安装插桩、不改 JDK、不写文件。
 * 不依赖 XComponent surface，DevTools 页直接可跑。
 */
export const runIpv6Probe: () => string;

/**
 * Java 侧 IPv6 诊断驱动（Phase 0 · P0-b / Q5，同 JDK_IPV6_ADAPTATION_PLAN.md §3）。
 *
 * fork 一个子进程建 JVM，跑 `com.amcl.launcher.Ipv6Diagnostics`，把它的输出取回来。
 * 回答 native 探针答不了的那一半：
 *   - SocketChannel 的实际地址族（= `Net.isIPv6Available()` 的可观测投影）
 *   - 连 IPv6 字面量时抛出的**第一条**异常的类名与 message
 *   - `NetworkInterface` 枚举到的 IPv6 地址条数（第二个消费者的基线）
 *
 * ⚠️ **同步阻塞数秒**（fork + JNI_CreateJavaVM），调用方应有 loading 态。
 * ⚠️ 需要 `filesDir/amcl-launcher.jar`：装完新版后**先启动过一次游戏**才会有。
 * ⚠️ 只观测，不安装插桩、不改 JDK。
 *
 * @param filesDir 应用 filesDir
 * @param testAddr 测试用 IPv6 字面量；传空串则用 `2001:db8::1`（RFC 3849 文档前缀，永不可路由）
 */
export const runIpv6JavaProbe: (filesDir: string, testAddr?: string) => string;

// 下载子系统测试（仅 MC_OHOS_BUILD_TESTS 构建注册）
//   见 docs/guides/download-system-implementation-plan.md §Phase 3/4
//   触发入口：DevToolsPage 的"运行下载测试"按钮
/** Phase 4: 增量 SHA1 一致性测试。无网络，纯内存，秒回。 */
export const runDownloadSha1IncrementalTests: () => string;
/** Phase 3: engine.fetchToBuffer 文本下载测试。需真实网络 + caBundlePath。 */
export const runDownloadTextFetchTests: (caBundlePath: string) => string;
/** Phase 8: NetSource 评分滑动窗口 + pickBestSourceWeighted。无网络，纯内存。 */
export const runDownloadSourceScoringTests: () => string;
/** Phase 7: exception + NetSource recordFailure/recordSuccess 生命周期。无网络，纯内存。 */
export const runDownloadErrorAndSourceLifecycleTests: () => string;

// ============================================================
//  Default export
// ============================================================
//
// 2026-05-04 修复：HarmonyOS SDK 新版本（arkts-no-any-unknown 严格模式）
// 要求 NAPI 模块的默认导入必须有显式类型。所有 .ets 里的
//   `import testNapi from 'libentry.so'`
// 依赖的就是此 default export。所有函数通过 typeof <name> 引用上方的
// named export 签名，不重复定义（DRY）。新增 NAPI 函数时，记得同时
// 追加到下面的对象类型里。
//
// 若只想引用单个函数，也可以继续用：
//   `import { jvmInit } from 'libentry.so'`
// ============================================================

declare const testNapi: {
  getDiagnosticCapabilities: typeof getDiagnosticCapabilities;
  // JVM 模块
  jvmInit: typeof jvmInit;
  runJvmEmbedTest: typeof runJvmEmbedTest;
  isJvmTestRunning: typeof isJvmTestRunning;

  // MC 启动器
  mcLaunchWithProfile: typeof mcLaunchWithProfile;
  mcLaunchWithProfileV2: typeof mcLaunchWithProfileV2;
  mcGetStatus: typeof mcGetStatus;
    mcGetGraphicsLaunchFailure: typeof mcGetGraphicsLaunchFailure;
    mcGetGraphicsRuntimeState: typeof mcGetGraphicsRuntimeState;
    mcGetGraphicsRuntimeFailure: typeof mcGetGraphicsRuntimeFailure;
    desktopProcessAlive: typeof desktopProcessAlive;
    runtimeSlotCreateStage: typeof runtimeSlotCreateStage;
    runtimeSlotPublish: typeof runtimeSlotPublish;
    runtimeSlotDiscardStage: typeof runtimeSlotDiscardStage;
    runtimeSlotAcquire: typeof runtimeSlotAcquire;
    runtimeSlotRelease: typeof runtimeSlotRelease;
    runtimeSlotRetire: typeof runtimeSlotRetire;
    runtimeSlotCollect: typeof runtimeSlotCollect;
    graphicsRecoveryMaintain: typeof graphicsRecoveryMaintain;
  mcCheckFiles: typeof mcCheckFiles;
  mcIsRunning: typeof mcIsRunning;
  mcForceExit: typeof mcForceExit;
  mcReadLog: typeof mcReadLog;

  // 设备信息
  getDeviceMemoryMB: typeof getDeviceMemoryMB;
  getRecommendedXmx: typeof getRecommendedXmx;
  probeNativePath: typeof probeNativePath;
  setOhosFrameRateForeground: typeof setOhosFrameRateForeground;
  setOhosFrameRateCap: typeof setOhosFrameRateCap;
  refreshOhosFrameRateHint: typeof refreshOhosFrameRateHint;

  // AMCL 日志系统
  amclLogInit: typeof amclLogInit;
  amclLogShutdown: typeof amclLogShutdown;
  amclLogRead: typeof amclLogRead;
  amclLogFlush: typeof amclLogFlush;
  amclLogGetStatus: typeof amclLogGetStatus;
  amclLogGetPath: typeof amclLogGetPath;
  amclLedgerBegin: typeof amclLedgerBegin;
  amclLedgerEnd: typeof amclLedgerEnd;
  amclLedgerEndAsync: typeof amclLedgerEndAsync;
  amclLedgerEndAll: typeof amclLedgerEndAll;
  amclLedgerBindTask: typeof amclLedgerBindTask;
  amclLedgerUnbindTask: typeof amclLedgerUnbindTask;
  amclLedgerSetLaunchActivity: typeof amclLedgerSetLaunchActivity;
  amclLogWrite: typeof amclLogWrite;

  // 输入模块
  sendTouchEvent: typeof sendTouchEvent;
  sendKeyEvent: typeof sendKeyEvent;
  configureInputProduct: typeof configureInputProduct;
  hardwareRawMouseAvailable: typeof hardwareRawMouseAvailable;
  physicalKeyTransaction: typeof physicalKeyTransaction;
  physicalMouseButtonTransaction: typeof physicalMouseButtonTransaction;
  setCursorLocked: typeof setCursorLocked;
  noteCursorLockFocusLost: typeof noteCursorLockFocusLost;
  isCursorLockSupported: typeof isCursorLockSupported;
  cursorLockWatchdogTick: typeof cursorLockWatchdogTick;
  installWindowInputFilters: typeof installWindowInputFilters;
  uninstallWindowInputFilters: typeof uninstallWindowInputFilters;
  windowInputFilterActive: typeof windowInputFilterActive;
  nativeWheelChannelActive: typeof nativeWheelChannelActive;
  wheelChannelClaim: typeof wheelChannelClaim;
  noteKeyRepeatSelfHealed: typeof noteKeyRepeatSelfHealed;
  noteArktsAxisEvent: typeof noteArktsAxisEvent;
  noteAxisPanActive: typeof noteAxisPanActive;
  setDisplayDensity: typeof setDisplayDensity;
  publishInputDeviceChange: typeof publishInputDeviceChange;
  publishInputSurfaceContext: typeof publishInputSurfaceContext;
  physicalPointerMotionTransaction: typeof physicalPointerMotionTransaction;
  physicalPointerRelativeTransaction: typeof physicalPointerRelativeTransaction;
  physicalPointerWheelTransaction: typeof physicalPointerWheelTransaction;
  physicalPointerRelativeFallbackTransaction: typeof physicalPointerRelativeFallbackTransaction;
  physicalMenuCursorPositionTransaction: typeof physicalMenuCursorPositionTransaction;
  traceUnverifiedCursorPosition: typeof traceUnverifiedCursorPosition;
  gate0InputTelemetryEnabled: typeof gate0InputTelemetryEnabled;
  traceGate0ArktsMouse: typeof traceGate0ArktsMouse;
  sendMouseEvent: typeof sendMouseEvent;
  sendScrollEvent: typeof sendScrollEvent;
  sendCursorDelta: typeof sendCursorDelta;
  sendSourceKeyEvent: typeof sendSourceKeyEvent;
  acquireSourceControl: typeof acquireSourceControl;
  releaseSourceControl: typeof releaseSourceControl;
  sendSourceMouseEvent: typeof sendSourceMouseEvent;
  sendSourceScrollEvent: typeof sendSourceScrollEvent;
  sendSourceCursorDelta: typeof sendSourceCursorDelta;
  sendSourceCursorSample: typeof sendSourceCursorSample;
  sharedLookExecutionSupported: typeof sharedLookExecutionSupported;
  touchGyroLeaseContext: typeof touchGyroLeaseContext;
  beginTouchGyroLease: typeof beginTouchGyroLease;
  submitTouchGyroLease: typeof submitTouchGyroLease;
  retireTouchGyroLease: typeof retireTouchGyroLease;
  setMappedLookVelocity: typeof setMappedLookVelocity;
  advanceMappedLookExecution: typeof advanceMappedLookExecution;
  retireMappedLookConnection: typeof retireMappedLookConnection;
  releaseSourceHeld: typeof releaseSourceHeld;
  noteSourceReset: typeof noteSourceReset;
  inputInvariantTick: typeof inputInvariantTick;
  sendCursorPos: typeof sendCursorPos;
  textInputSessionSupported: typeof textInputSessionSupported;
  beginTextInputSession: typeof beginTextInputSession;
  endTextInputSession: typeof endTextInputSession;
  abortTextInputSession: typeof abortTextInputSession;
  commitTextInput: typeof commitTextInput;
  textInputKeyTap: typeof textInputKeyTap;
  updateTextInputEditing: typeof updateTextInputEditing;
  updateTextInputSelection: typeof updateTextInputSelection;
  submitTextInputCandidates: typeof submitTextInputCandidates;
  noteTextInputCandidatesUnsupported: typeof noteTextInputCandidatesUnsupported;
  getTextInputCandidatesUnsupportedCount: typeof getTextInputCandidatesUnsupportedCount;
  sendCharEvent: typeof sendCharEvent;
  sendCharModsEvent: typeof sendCharModsEvent;
  isGrabbed: typeof isGrabbed;
  onGrabChange: typeof onGrabChange;
  onButtonPressed: typeof onButtonPressed;
  onHaptic: typeof onHaptic;

  setTouchPaused: typeof setTouchPaused;
  cancelAllInput: typeof cancelAllInput;
  getInputResetEpoch: typeof getInputResetEpoch;
  getInputResetDomains: typeof getInputResetDomains;
  setLookSensitivity: typeof setLookSensitivity;
  applyLookConfiguration: typeof applyLookConfiguration;
  applySourceLookConfiguration: typeof applySourceLookConfiguration;
  setInvertY: typeof setInvertY;
  setLookSmoothing: typeof setLookSmoothing;
  setLookAccel: typeof setLookAccel;
  setControlSchema: typeof setControlSchema;
  touchPublicationState: typeof touchPublicationState;
  readTouchGroups: typeof readTouchGroups;
  confirmTouchGroups: typeof confirmTouchGroups;
  isTouchGroupControlCurrent: typeof isTouchGroupControlCurrent;
  bindTouchGroupMouseOwner: typeof bindTouchGroupMouseOwner;
  invokeTouchGroupControl: typeof invokeTouchGroupControl;
  restoreTouchGroups: typeof restoreTouchGroups;
  onTouchGroupsChanged: typeof onTouchGroupsChanged;
  beginTouchPublication: typeof beginTouchPublication;
  publishTouchSchema: typeof publishTouchSchema;
  confirmTouchPublication: typeof confirmTouchPublication;
  abortTouchPublication: typeof abortTouchPublication;
  acquireTouchModal: typeof acquireTouchModal;
  releaseTouchModal: typeof releaseTouchModal;
  isTouchPublicationCurrent: typeof isTouchPublicationCurrent;
  touchInteractionVisual: typeof touchInteractionVisual;
  maintainTouchInput: typeof maintainTouchInput;
  gameGuiState: typeof gameGuiState;
  gameGuiStartSession: typeof gameGuiStartSession;
  gameGuiCaptureSession: typeof gameGuiCaptureSession;
  gameGuiStopSession: typeof gameGuiStopSession;
  gameGuiAttachSource: typeof gameGuiAttachSource;
  gameGuiRetireSource: typeof gameGuiRetireSource;
  gameGuiStateForSource: typeof gameGuiStateForSource;
  moveTouchMenuPointer: typeof moveTouchMenuPointer;
  touchMenuButton: typeof touchMenuButton;
  cancelTouchMenuMouse: typeof cancelTouchMenuMouse;
  touchMenuScroll: typeof touchMenuScroll;
  setTouchMenuMouseBounds: typeof setTouchMenuMouseBounds;
  setTouchGuideBounds: typeof setTouchGuideBounds;
  restoreGameGuiScale: typeof restoreGameGuiScale;
  restoreGameGuiScaleForSource: typeof restoreGameGuiScaleForSource;
  sendTouchGyroSample: typeof sendTouchGyroSample;

  // JIT / Forge / JVM 参数
  checkJitAvailable: typeof checkJitAvailable;
  runJavaProcessor: typeof runJavaProcessor;
  startSideloadHdc: typeof startSideloadHdc;
  configureSideloadInstallRoot: typeof configureSideloadInstallRoot;
  sideloadInstallClockTicks: typeof sideloadInstallClockTicks;
  acquireSideloadFileLease: typeof acquireSideloadFileLease;
  releaseSideloadFileLease: typeof releaseSideloadFileLease;
  discoverSideloadPort: typeof discoverSideloadPort;
  runSideloadHdcCommand: typeof runSideloadHdcCommand;
  stopSideloadHdc: typeof stopSideloadHdc;
  solveSideloadPow: typeof solveSideloadPow;
  cancelSideloadPow: typeof cancelSideloadPow;
  getCommonJvmArgs: typeof getCommonJvmArgs;
  desktopProcessId: typeof desktopProcessId;
  desktopGameProcessState: typeof desktopGameProcessState;
  desktopAttach: typeof desktopAttach;
  desktopDetach: typeof desktopDetach;
  desktopTakeCommand: typeof desktopTakeCommand;
  desktopCompleteCommand: typeof desktopCompleteCommand;
  desktopPublishState: typeof desktopPublishState;
  desktopRequestClose: typeof desktopRequestClose;
  desktopSetGamepadNativeMode: typeof desktopSetGamepadNativeMode;
  desktopGamepadFocus: typeof desktopGamepadFocus;
  getNativeGlCapability: typeof getNativeGlCapability;
  nativeGlValidationEnabled: typeof nativeGlValidationEnabled;
  desktopPublishDrop: typeof desktopPublishDrop;

  // GPU 信息
  getGpuInfo: typeof getGpuInfo;
  getVulkanInfo: typeof getVulkanInfo;
  getVulkanCapabilityJson: typeof getVulkanCapabilityJson;
  getGraphicsCapabilityJson: typeof getGraphicsCapabilityJson;
  runVulkanSelfTest: typeof runVulkanSelfTest;
  // ⚰️ 2026-08-27（§S6）：曾有 runOSMesaSelfTest，随 zink 退役移除。

  // 下载引擎
  downloadEngineProbe: typeof downloadEngineProbe;
  downloadEngineSelfTest: typeof downloadEngineSelfTest;
  downloadCreateTask: typeof downloadCreateTask;
  downloadSteadyTime: typeof downloadSteadyTime;
  downloadStart: typeof downloadStart;
  downloadCancel: typeof downloadCancel;
  downloadOnProgress: typeof downloadOnProgress;
  downloadOnComplete: typeof downloadOnComplete;
  downloadListActive: typeof downloadListActive;
  downloadQueryTask: typeof downloadQueryTask;
  downloadDetachCallbacks: typeof downloadDetachCallbacks;
  downloadShutdown: typeof downloadShutdown;
  downloadSetCaBundle: typeof downloadSetCaBundle;
  downloadComputeFileSha1: typeof downloadComputeFileSha1;
  downloadPublishNoReplace: typeof downloadPublishNoReplace;
  downloadSetRelay: typeof downloadSetRelay;
  downloadClearRelay: typeof downloadClearRelay;
  downloadRelayStats: typeof downloadRelayStats;
  downloadFetchText: typeof downloadFetchText;
  downloadPauseTask: typeof downloadPauseTask;
  downloadResumeTask: typeof downloadResumeTask;
  downloadDeleteTaskFiles: typeof downloadDeleteTaskFiles;
  downloadRetryFailed: typeof downloadRetryFailed;
  downloadPurgeTask: typeof downloadPurgeTask;

  // 导出数据面：每个Native job独立查询、取消、真实收敛后释放。
  exportArchiveStart: typeof exportArchiveStart;
  exportArchiveVerifyStart: typeof exportArchiveVerifyStart;
  exportFileHashStart: typeof exportFileHashStart;
  exportJobQuery: typeof exportJobQuery;
  exportJobCancel: typeof exportJobCancel;
  exportJobRelease: typeof exportJobRelease;

  // 测试模块
  runJitTests: typeof runJitTests;
  runJvmTests: typeof runJvmTests;
  runGlfwTest: typeof runGlfwTest;
  runGl4Test: typeof runGl4Test;
  runMgTest: typeof runMgTest;
  runMgDepthRangeTest: typeof runMgDepthRangeTest;
  runMgContextIdentityTest: typeof runMgContextIdentityTest;
  runMobileGlProgramTest: typeof runMobileGlProgramTest;
  runLwjglTest: typeof runLwjglTest;
  runSdl3C2Test: typeof runSdl3C2Test;
  runSdl3WindowTest: typeof runSdl3WindowTest;
  runMobileglProbe: typeof runMobileglProbe;
  runMobileglPbufferProbe: typeof runMobileglPbufferProbe;
  runIpv6Probe: typeof runIpv6Probe;
  runIpv6JavaProbe: typeof runIpv6JavaProbe;
  runDownloadSha1IncrementalTests: typeof runDownloadSha1IncrementalTests;
  runDownloadTextFetchTests: typeof runDownloadTextFetchTests;
  runDownloadSourceScoringTests: typeof runDownloadSourceScoringTests;
  runDownloadErrorAndSourceLifecycleTests: typeof runDownloadErrorAndSourceLifecycleTests;
};

export default testNapi;

/** 导出私有快照中的一个标准ZIP entry；目录长度为0，普通文件绑定真实SHA256。 */
export interface NativeExportEntry { path: string; size: number; sha256: string; directory: boolean; }
/** 只允许filesDir/game-export/work/<job>内的snapshot→export.zip，不接受源绝对路径写入。 */
export interface NativeExportArchiveSpec {
  filesDir: string; jobRelative: string; snapshotRelative: string; archiveRelative: string;
  entries: NativeExportEntry[]; workerCount?: number;
}
/** 原SDK只读fd的能力副本；Native使用dup+pread，不改变调用者offset，也不接收source路径。 */
/** sha1/sha256分别默认true；用途可关闭一种算法，两者同时false拒绝且不创建job。 */
export interface NativeExportHashSpec { fd: number; size: number; sha1?: boolean; sha256?: boolean; }
/** Promise只在实际worker/fd结束后完成；write/verify的size是ZIP长度，hash的size是源长度。 */
export interface NativeExportResult {
  jobId: number; operation: string; files: number; size: number; payloadBytes: number; archiveBytes: number;
  sha1: string; sha256: string;
}
/** 终态与收敛分开；只有本env仍保留的真实近期退役receipt才released=true，过旧/未知均不猜已退出。 */
export interface NativeExportProgress {
  exists: boolean; released: boolean; jobId: number; operation: string; state: string;
  filesDone: number; filesTotal: number; bytesDone: number; bytesTotal: number; archiveBytes: number;
  settled: boolean; errorCode: string; errorMessage: string;
}
/** 同步获得取消/查询身份，完成Promise由NAPI异步作业结算；页面不拥有Native句柄。 */
export interface NativeExportHandle { jobId: number; completion: Promise<NativeExportResult>; }
export const exportArchiveStart: (spec: NativeExportArchiveSpec) => NativeExportHandle;
export const exportArchiveVerifyStart: (spec: NativeExportArchiveSpec) => NativeExportHandle;
export const exportFileHashStart: (spec: NativeExportHashSpec) => NativeExportHandle;
export const exportJobQuery: (jobId: number) => NativeExportProgress;
export const exportJobCancel: (jobId: number) => boolean;
export const exportJobRelease: (jobId: number) => boolean;

/** Immutable native diagnostic capability mask; zero on non-default products. */
export const getDiagnosticCapabilities: () => number;

/** Process isolation/lease facts; negative state codes are failures, never inactive. */
export const desktopProcessId: () => number;
export const desktopGameProcessState: (filesDir: string, parentPid: number) => number;

export interface DesktopHostCommand {
  sequence: number; generation: number; kind: number;
  a: number; b: number; c: number; d: number; text: string;
}
export const desktopAttach: (onCommands: () => void) => number;
export const desktopDetach: (generation: number) => void;
export const desktopTakeCommand: () => DesktopHostCommand | undefined;
export const desktopCompleteCommand: (generation: number, sequence: number, error: number) => boolean;
export const desktopPublishState: (generation: number, window: number[], displays: number[], names: string[]) => boolean;

export const desktopRequestClose: (requested: boolean) => void;

export interface NativeGlCapability {
  /** AppScope启动声明与设备支持分开；清理失败保留首错并要求结束当前进程。 */
  bootstrapConfigured: boolean;
  cleanupComplete: boolean; restartRequired: boolean;
  cleanupError: number; cleanupStage: string; errorDomain: string;
  systemLibrary: boolean;
  requiredByProduct: boolean;
  ready: boolean; queryAvailable: boolean; querySupported: boolean;
  contextCreated: boolean; pixelVerified: boolean; error: number;
  stage: string; version: string; vendor: string; renderer: string;
  renderDiagnostics: string;
}
export const getNativeGlCapability: (detailed?: boolean, availabilityOnly?: boolean) => Promise<NativeGlCapability>;
export const nativeGlValidationEnabled: () => boolean;
export const desktopPublishDrop: (paths: string[]) => boolean;

export const desktopSetGamepadNativeMode: (enabled: boolean) => boolean;
export const desktopGamepadFocus: (focused: boolean) => void;
/** 枫源公开 V2 挑战的后台顺序模平方；输入输出为固定 768 位十六进制，失败返回空串。 */
export const solveSideloadPow: (modulus: string, base: string, iterations: number) => Promise<string>;
/** 更新取消或另一来源已完成后，撤销在途公开挑战计算。 */
export const cancelSideloadPow: () => void;
