import { callNamedLauncherSkill, isLauncherSkillMethod } from './ets/launcherskill/NamedSkill';
import { SkillFields, UserDecisionObserver } from './ets/launcherskill/LauncherSkillBus';

/** 开发设备协议只授予显式声明的具名方法；前缀本身不代表任何能力。 */
export function isQaLauncherSkill(action: string): boolean {
  return action.startsWith('skill.') && isLauncherSkillMethod(action.substring(6));
}

/** 外层描述本次设备请求，完整业务收据在 data 内保留；等待与部分完成必须继续核对原对象。 */
function transportStatus(state: string): string {
  switch (state) {
    case 'ready':
    case 'draft': return 'ok';
    case 'accepted': return 'accepted';
    case 'needsUser': return 'needsUser';
    case 'failed':
    case 'unavailable':
    case 'busy':
    case 'cancelled': return 'rejected';
    default: return 'unknown';
  }
}

/** 仅由已认领的会话请求进入；QA 回执和平台回执各由自己的传输方保存。 */
export async function runQaLauncherSkill(action: string, argsJson: string, _requestId: string, userDecision?: UserDecisionObserver): Promise<string> {
  const method = action.substring(6);
  const payload = await callNamedLauncherSkill(method, JSON.parse(argsJson) as SkillFields, userDecision);
  const state = payload['state'];
  const reason = payload['reason'];
  return JSON.stringify({ status: transportStatus(typeof state === 'string' ? state : ''), data: payload,
    reason: typeof reason === 'string' ? reason : '' });
}
