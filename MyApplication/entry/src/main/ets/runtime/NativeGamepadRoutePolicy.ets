/**
 * 原生手柄的本局路由决议。进程平台事实、用户请求和实际输入 ABI 分别传入，
 * 此模块不启动采集、不调用 NAPI、不推进按键/轴，也不创建游戏 consumer。
 * GLFW/SDL 的出口上限来自已核验的标准查询/virtual joystick 接线；LWJGL2 的
 * GLFW 窗口提供者不能替代其缺席的 controller/JInput 输入出口。
 */
import { InputAbi, parseInputPlan, ResolvedInputPlan } from 'launch'

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

/** 玩家仅需确认已采用的操作方式。等待计划或释放旧输入时先不弹；明确降级时说明原因。 */
export function nativeGamepadRouteNotice(decision: NativeGamepadRouteDecision, previous?: GamepadOutputRoute): string {
  if (decision.applied === previous) return ''
  if (decision.status === NativeGamepadRouteStatus.Applied) {
    if (decision.applied === GamepadOutputRoute.Native) return '本局已启用原生手柄。'
    return previous === GamepadOutputRoute.Native ? '本局已切换为启动器手柄映射。' : ''
  }
  if (decision.applied !== GamepadOutputRoute.Mapped) return ''
  if (decision.reason === NativeGamepadRouteReason.CaptureUnavailable) return '手柄采集不可用，使用启动器映射。'
  if (decision.status === NativeGamepadRouteStatus.Unsupported) {
    return decision.reason === NativeGamepadRouteReason.AbiUnsupported
      ? '本局不支持原生手柄，使用启动器映射。' : '手柄路线无法确认，使用启动器映射。'
  }
  return ''
}

/**
 * 使用独立输入计划的正式 parser；不从 graphics/window provider 重新选择 ABI。
 * 空计划只 Pending 且继续 Mapped；坏计划和 L2 明确 Unsupported。平台不可用时
 * 保留合法映射与原生 desired，等待后续本局资格变化或下局重新初始化，不重放旧轴。
 * requested 在 prepare 冻结，platformCaptureReady 由本局实际 ABI 绑定后的注册结果确认；applied 在真实 setter 后
 * 重新读取，释放拒绝时仍为旧路线。本纯函数没有重试时钟或来源归约权限。
 */
export function resolveNativeGamepadRoute(requested: boolean, platformCaptureReady: boolean,
  inputPlanWire: string, applied: GamepadOutputRoute = GamepadOutputRoute.Mapped): NativeGamepadRouteDecision {
  return resolveBoundGamepadRoute(requested, platformCaptureReady, parseInputPlan(inputPlanWire), inputPlanWire.length > 0, applied)
}

/** 宿主只传由 bindPlan 已验证的计划；无计划与提供了无效计划的公开入口仍区别报告。 */
export function resolveBoundGamepadRoute(requested: boolean, platformCaptureReady: boolean,
  plan: ResolvedInputPlan | undefined, supplied: boolean, applied: GamepadOutputRoute): NativeGamepadRouteDecision {
  const abiNativeOutlet: boolean = plan !== undefined &&
    (plan.abi === InputAbi.GLFW || plan.abi === InputAbi.SDL3)
  const desired: GamepadOutputRoute = requested ? GamepadOutputRoute.Native : GamepadOutputRoute.Mapped
  let target: GamepadOutputRoute = GamepadOutputRoute.Mapped
  let status: NativeGamepadRouteStatus = NativeGamepadRouteStatus.Applied
  let reason: NativeGamepadRouteReason = NativeGamepadRouteReason.MappedRequested

  if (requested) {
    if (!supplied) {
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
