/** 图形恢复的纯判定：只处理已授权自动策略的首帧前图形故障，不根据任意错误文本重启。 */
import { ResolvedGraphicsPlan, graphicsProfileById } from 'launch';

export interface GraphicsRecoveryTicket {
  id: string; parentPid: number; activityId: number; rootActivityId: number; attempt: number;
  createdAt: number; version: string; mcDir: string; gameDir: string; jdk: string; xmx: number;
  preferenceStamp: string; retryProfile: string;
  diagnosticInjected?: boolean;
}
export interface GraphicsRecoveryFailure {
  id: string; parentPid: number; activityId: number; childPid: number; createdAt: number;
  profile: string; nextProfile: string; stage: string; code: string; presentCount: number;
  automatic: boolean;
  diagnosticInjected?: boolean;
}
export interface GraphicsRuntimeState {
  pid: number; profile: string; provider: string; apiFamily: string; presentCount: number; failureSequence: number;
  failureStage: string; failureCode: number; failurePresentCount: number; surfaceGeneration: number;
}
export interface GraphicsRecoveryDispatch { rootActivityId: number; attempt: number; profile: string; diagnosticInjected?: boolean; }

/**
 * 候选来自已完成的 resolver，下一进程仍须重做完整准入。自动 Vulkan 可能在后续 native
 * surface/shader 阶段被拒绝，允许沿既有冷进程协议尝试下一 OpenGL 候选；显式 Vulkan
 * 的 GAME_API/PREFERENCE 来源不获得此资格。是否属于可恢复故障仍由下方故障规则裁决。
 */
export function graphicsRecoveryCandidate(plan: ResolvedGraphicsPlan | undefined): string {
  if (plan === undefined) return '';
  let afterSelected: boolean = false;
  for (const candidate of plan.candidateDetails) {
    if (candidate.selected) {
      const automaticGl: boolean = String(plan.apiFamily) === 'OPENGL' && String(candidate.source) === 'DEFAULT';
      const automaticVulkan: boolean = String(plan.apiFamily) === 'VULKAN' && String(candidate.source) === 'GAME_DEFAULT';
      if (!automaticGl && !automaticVulkan) return '';
      afterSelected = true;
      continue;
    }
    if (afterSelected && candidate.admitted && candidate.id !== plan.profile && candidate.profile !== undefined
      && String(candidate.profile.api) === 'OPENGL' && String(candidate.source) === 'DEFAULT') return candidate.id;
  }
  return '';
}

/** 明确的准入/初始窗口/上下文故障才可重试；缺文件、bootstrap、偏好冲突和游戏异常不在名单。 */
export function graphicsFailureRetryable(stage: string, code: string, presentCount: number): boolean {
  if (presentCount !== 0) return false;
  if (stage === 'admission') return code === 'vulkan_capability_rejected' || code.startsWith('native_gl_');
  if (stage !== 'render') return false;
  // 首次 swap 失败也可能已开始 quick-play 世界加载，不能仅凭“尚未出帧”认定可重开。
  const permitted: string[] = ['window-create-failed'];
  return permitted.indexOf(code) >= 0;
}

/** 父进程还须分别核验 OS 游戏锁与旧 PID；未知状态也拒绝。新用户启动会替换 expectedId。 */
export function graphicsRecoveryPermitted(ticket: GraphicsRecoveryTicket, failure: GraphicsRecoveryFailure,
  expectedId: string, parentPid: number, processState: number, childAlive: number,
  version: string, mcDir: string, preferenceStamp: string, now: number): boolean {
  const next = graphicsProfileById(failure.nextProfile);
  if (next === undefined || String(next.api) !== 'OPENGL' || String(next.lifecycle) === 'retired'
    || String(next.selectionRole) === 'fixed-function') return false;
  return ticket.activityId > 0 && ticket.rootActivityId > 0 && parentPid > 0
    && ticket.id === expectedId && failure.id === ticket.id && ticket.parentPid === parentPid
    && failure.parentPid === parentPid && ticket.activityId === failure.activityId
    && ticket.attempt === 0 && ticket.retryProfile.length === 0 && failure.childPid > 0 && failure.childPid !== parentPid
    && failure.automatic && failure.profile.length > 0 && failure.nextProfile.length > 0 && failure.nextProfile !== failure.profile
    && processState === 0 && childAlive === 0 && ticket.version === version && ticket.mcDir === mcDir
    && ticket.preferenceStamp === preferenceStamp && now >= ticket.createdAt && now - ticket.createdAt <= 300000
    && failure.createdAt >= ticket.createdAt && failure.createdAt <= now + 1000
    && graphicsFailureRetryable(failure.stage, failure.code, failure.presentCount);
}

/** Native JSON 必须按原始字符串键读取，不能依赖 Release 混淆后的接口属性名。 */
export function parseGraphicsRuntimeState(wire: string): GraphicsRuntimeState | undefined {
  if (!wire || wire.length > 8192) return undefined;
  try {
    const value: Record<string, Object> = JSON.parse(wire) as Record<string, Object>;
    if (value === null || value['schemaVersion'] !== 1 || typeof value['profile'] !== 'string'
      || typeof value['provider'] !== 'string' || typeof value['failureStage'] !== 'string') return undefined;
    const numbers: string[] = ['pid', 'presentCount', 'failureSequence', 'failureCode', 'failurePresentCount', 'surfaceGeneration'];
    for (const key of numbers) if (typeof value[key] !== 'number' || !Number.isSafeInteger(value[key] as number)
      || (value[key] as number) < 0) return undefined;
    if ((value['pid'] as number) <= 0) return undefined;
    const state: GraphicsRuntimeState = {
      pid: value['pid'] as number, profile: value['profile'] as string, provider: value['provider'] as string,
      apiFamily: typeof value['apiFamily'] === 'string' ? value['apiFamily'] as string : 'UNKNOWN',
      presentCount: value['presentCount'] as number, failureSequence: value['failureSequence'] as number,
      failureStage: value['failureStage'] as string, failureCode: value['failureCode'] as number,
      failurePresentCount: value['failurePresentCount'] as number, surfaceGeneration: value['surfaceGeneration'] as number
    };
    return state;
  } catch (_) { return undefined; }
}
