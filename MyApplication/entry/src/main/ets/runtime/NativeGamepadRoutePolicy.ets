/**
 * 原生手柄的本局路由决议。进程平台事实、用户请求和实际输入 ABI 分别传入，
 * 此模块不启动采集、不调用 NAPI、不推进按键/轴，也不创建游戏 consumer。
 * GLFW/SDL 的出口上限来自已核验的标准查询/virtual joystick 接线；LWJGL2 的
 * GLFW 窗口提供者不能替代其缺席的 controller/JInput 输入出口。
 */
import { InputAbi, parseInputPlan, ResolvedInputPlan } from 'launch'

/** ProcessRuntime 在本局初始化时发布的用户请求；设置页变化只在下局重新采纳。 */
export const NATIVE_GAMEPAD_ROUTE_REQUESTED_KEY: string = 'nativeGamepadRouteRequested'
/** 已请求原生时，平台注册/枚举确实成功；不表示游戏 consumer 或模组已使用。 */
export const NATIVE_GAMEPAD_CAPTURE_READY_KEY: string = 'nativeGamepadCaptureReady'

/** 一种用途只有一条有副作用路线；Mapped 表示启动器键鼠映射，Native 表示游戏标准出口。 */
export enum GamepadOutputRoute { Mapped = 'mapped', Native = 'native' }

/**
 * Applied 仅证明调用方报告的来源开关与决议一致，不证明事件交付或游戏处理。
 * Pending 保持当前 applied，等待输入计划、平台采集或原持有释放；Unsupported
 * 保留原生 desired 请求，同时明确所选 ABI/计划不能提供该路线。
 */
export enum NativeGamepadRouteStatus {
  Applied = 'applied', Pending = 'pending', Unsupported = 'unsupported'
}

/** 具名原因供宿主只读状态/日志使用，不让缺计划、平台未准备和缺 ABI 出口混成 READY。 */
export enum NativeGamepadRouteReason {
  MappedRequested = 'mapped-requested',
  PlanUnbound = 'input-plan-unbound',
  PlanInvalid = 'input-plan-invalid',
  AbiUnsupported = 'input-abi-no-native-gamepad',
  CaptureUnavailable = 'platform-capture-unavailable',
  ApplyPending = 'source-route-apply-pending',
  NativeRequested = 'native-requested'
}

/**
 * 每次 resolve 返回独立快照。target/mappedOutputEnabled 是准备应用的政策值，
 * applied 必须来自 GamepadManager 的真实来源开关读取，不能直接复制 target。
 * abiNativeOutlet 只描述所选 ABI 的最大出口能力，不借此声称实际 consumer Ready，
 * 更不根据查询次数推定游戏或模组接管；用户已明确请求支持的原生路线时保持其选择。
 */
export interface NativeGamepadRouteDecision {
  readonly requestedNative: boolean
  readonly platformCaptureReady: boolean
  readonly planBound: boolean
  readonly inputAbi: string
  readonly abiNativeOutlet: boolean
  readonly desired: GamepadOutputRoute
  readonly target: GamepadOutputRoute
  readonly applied: GamepadOutputRoute
  readonly mappedOutputEnabled: boolean
  readonly status: NativeGamepadRouteStatus
  readonly reason: NativeGamepadRouteReason
}

/**
 * 将原会话的只读路由回执解释为用户提示。保存偏好不是本函数的输入；映射请求已完成时
 * 不增加提示，仍待切换时保留真实applied路线。Applied只说明实际来源开关已采用，
 * 不宣称游戏/模组消费过任何事件；Pending/Unsupported的目标不能替代仍保持的旧路线。
 * 缺席回执保持空值，调用方继续沿原会话维护取得事实，读取不申请采集或重试路由。
 */
export function nativeGamepadRouteStatusMessage(decision: NativeGamepadRouteDecision | undefined): string {
  if (decision === undefined || (!decision.requestedNative && decision.status === NativeGamepadRouteStatus.Applied)) return ''
  // 这是原来源开关的实际读回值。目标为Mapped并不证明旧Native已经结束，不能将
  // 准备中的target或已保存requested当成成功；当前Host冻结事实之外的合法回执也保持诚实。
  const currentRoute: string = decision.applied === GamepadOutputRoute.Native
    ? '本局仍保持原生手柄路线。' : '本局仍使用启动器映射。'
  if (decision.status === NativeGamepadRouteStatus.Unsupported) {
    return decision.reason === NativeGamepadRouteReason.AbiUnsupported
      ? '当前游戏输入接口不支持原生手柄；' + currentRoute
      : '当前游戏的手柄路线无法确认；' + currentRoute
  }
  if (decision.status === NativeGamepadRouteStatus.Pending) {
    if (decision.reason === NativeGamepadRouteReason.ApplyPending) return '手柄路线正在等待原输入结束，尚未完成切换；' + currentRoute
    if (decision.reason === NativeGamepadRouteReason.CaptureUnavailable) return '原生手柄采集暂不可用，正在等待确认；' + currentRoute
    return '本局手柄路线正在等待游戏输入准备；' + currentRoute
  }
  return decision.applied === GamepadOutputRoute.Native
    ? '本局已启用原生手柄路线；当前游戏还需支持控制器。'
    : '本局继续使用启动器手柄映射。'
}

/**
 * 使用独立输入计划的正式 parser；不从 graphics/window provider 重新选择 ABI。
 * 空计划只 Pending 且继续 Mapped；坏计划和 L2 明确 Unsupported。平台不可用时
 * 保留合法映射与原生 desired，等待后续本局资格变化或下局重新初始化，不重放旧轴。
 * requested/platformCaptureReady 由宿主在 prepare 冻结；applied 在真实 setter 后
 * 重新读取，释放拒绝时仍为旧路线。本纯函数没有重试时钟或来源归约权限。
 */
export function resolveNativeGamepadRoute(requested: boolean, platformCaptureReady: boolean,
  inputPlanWire: string, applied: GamepadOutputRoute = GamepadOutputRoute.Mapped): NativeGamepadRouteDecision {
  const plan: ResolvedInputPlan | undefined = parseInputPlan(inputPlanWire)
  const abiNativeOutlet: boolean = plan !== undefined &&
    (plan.abi === InputAbi.GLFW || plan.abi === InputAbi.SDL3)
  const desired: GamepadOutputRoute = requested ? GamepadOutputRoute.Native : GamepadOutputRoute.Mapped
  let target: GamepadOutputRoute = GamepadOutputRoute.Mapped
  let status: NativeGamepadRouteStatus = NativeGamepadRouteStatus.Applied
  let reason: NativeGamepadRouteReason = NativeGamepadRouteReason.MappedRequested

  if (requested) {
    if (inputPlanWire.length === 0) {
      status = NativeGamepadRouteStatus.Pending
      reason = NativeGamepadRouteReason.PlanUnbound
    } else if (plan === undefined) {
      status = NativeGamepadRouteStatus.Unsupported
      reason = NativeGamepadRouteReason.PlanInvalid
    } else if (!abiNativeOutlet) {
      status = NativeGamepadRouteStatus.Unsupported
      reason = NativeGamepadRouteReason.AbiUnsupported
    } else if (!platformCaptureReady) {
      status = NativeGamepadRouteStatus.Pending
      reason = NativeGamepadRouteReason.CaptureUnavailable
    } else {
      target = GamepadOutputRoute.Native
      reason = NativeGamepadRouteReason.NativeRequested
    }
  }
  // 平台/计划资格不能代替旧持有真正释放。尚未应用的有效目标显式 Pending；
  // 不支持/缺资格的原因仍保留，让调用方同时看见应回到 Mapped 与实际旧开关。
  if (status === NativeGamepadRouteStatus.Applied && applied !== target) {
    status = NativeGamepadRouteStatus.Pending
    reason = NativeGamepadRouteReason.ApplyPending
  }
  return {
    requestedNative: requested, platformCaptureReady: platformCaptureReady,
    planBound: plan !== undefined, inputAbi: plan?.abi ?? '', abiNativeOutlet: abiNativeOutlet,
    desired: desired, target: target, applied: applied, mappedOutputEnabled: target === GamepadOutputRoute.Mapped,
    status: status, reason: reason
  }
}
