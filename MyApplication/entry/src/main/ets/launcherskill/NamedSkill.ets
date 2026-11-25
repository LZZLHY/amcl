import { LauncherSkillBus, SkillFields, UserDecisionObserver } from './LauncherSkillBus';
import { parseSkillArguments } from './SkillArguments';
import { launcherMethodSpec, LauncherMethodSpec } from './SkillMethodCatalog';

/** 方法名固定来自同一产品契约；业务归属及产品准入继续由前台业务所有者判断。 */
export function isLauncherSkillMethod(method: string): boolean {
  return launcherMethodSpec(method) !== undefined;
}

async function dispatch(spec: LauncherMethodSpec, method: string, values: string[], userDecision?: UserDecisionObserver): Promise<SkillFields> {
  const parsed = parseSkillArguments(values, spec.fields);
  if (parsed === undefined) return { 'state': 'failed', 'reason': 'invalidArguments' };
  // 分支必填项也在进入业务、消耗一次性引用之前检查。false 和 0 均为有效值。
  if (spec.cases?.some(rule => parsed[rule.key] === rule.value &&
    rule.required.some(key => parsed[key] === undefined))) return { 'state': 'failed', 'reason': 'invalidArguments' };
  return LauncherSkillBus.call(spec.domain, method, parsed, userDecision);
}

/** 系统脚本按位置提供字符串；收回执是外层平台适配器的职责。 */
export async function callPositionalLauncherSkill(method: string, values: string[]): Promise<SkillFields> {
  const spec = launcherMethodSpec(method);
  if (spec === undefined) return { 'state': 'failed', 'reason': 'unknownMethod' };
  return dispatch(spec, method, values);
}

/** 命名调用只接受声明的原生标量。省略可选参数时保留其位置，复用系统脚本的范围及枚举校验。 */
export async function callNamedLauncherSkill(method: string, args: SkillFields, userDecision?: UserDecisionObserver): Promise<SkillFields> {
  const spec = launcherMethodSpec(method);
  if (spec === undefined) return { 'state': 'failed', 'reason': 'unknownMethod' };
  const keys = Object.keys(args);
  const values: string[] = [];
  let supplied = 0;
  for (const field of spec.fields) {
    if (!keys.includes(field.name)) {
      if (field.required) return { 'state': 'failed', 'reason': 'invalidArguments' };
      values.push('');
      continue;
    }
    const value = args[field.name];
    if ((field.kind === 'string' && typeof value !== 'string') ||
      (field.kind === 'boolean' && typeof value !== 'boolean') ||
      (field.kind === 'integer' && (typeof value !== 'number' || !Number.isSafeInteger(value)))) {
      return { 'state': 'failed', 'reason': 'invalidArguments' };
    }
    supplied++;
    values.push(String(value));
  }
  if (supplied !== keys.length) return { 'state': 'failed', 'reason': 'invalidArguments' };
  return dispatch(spec, method, values, userDecision);
}
