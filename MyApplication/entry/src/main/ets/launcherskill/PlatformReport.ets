import { scriptManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppLogger, LogTags } from 'commons';
import { SkillFields } from './LauncherSkillBus';
import { callPositionalLauncherSkill } from './NamedSkill';

/** 官方脚本独占平台回执。参数无效时不进入业务；平台回传失败也不会重做业务操作。 */
export async function invokeSkill(info: scriptManager.ArkTSScriptInfo, method: string, values: string[]): Promise<void> {
  if (!canIUse('SystemCapability.Ability.AgentRuntime.Core')) {
    throw new Error('当前系统不支持应用 Skill 执行结果回传');
  }
  let payload: SkillFields;
  try {
    payload = await callPositionalLauncherSkill(method, values);
  } catch (_) {
    // 回调可能已产生副作用。未知结果留给调用方读取产品状态，不上报异常中的本地路径或凭据。
    payload = { 'state': 'unknown', 'reason': 'businessOutcomeUnknown' };
  }
  const result: scriptManager.ExecuteResult = {
    code: payload['state'] === 'failed' ? -1 : 0,
    result: payload
  };
  try {
    await scriptManager.completeArkTSScriptInApp(info.context, info.requestCode, result);
  } catch (error) {
    // 回传失败与业务失败分别记录；参数、操作引用、用户内容及系统请求码不入日志。
    const code = error instanceof Error ? (error as BusinessError).code : undefined;
    AppLogger.warn(LogTags.ENTRY_ABILITY, 'Skill result delivery failed method=' + method + ' code=' + String(code));
    if (error instanceof Error) throw error;
    throw new Error('Skill result delivery failed');
  }
}
