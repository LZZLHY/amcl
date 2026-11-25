import { SkillFields } from './LauncherSkillBus';

/** 平台按 SKILL.md 中的 arg1…argN 传入字符串；用声明对应的顺序解析，避免宽松数值转换或隐式布尔值。 */
export interface SkillArgument {
  name: string;
  kind: string;
  required: boolean;
  choices?: string[];
}

export function parseSkillArguments(values: string[], fields: SkillArgument[]): SkillFields | undefined {
  if (values.length > fields.length) return undefined;
  const args: SkillFields = {};
  for (let i = 0; i < fields.length; i++) {
    const field = fields[i];
    const value = values[i];
    if (value === undefined || (value === '' && !field.required)) {
      if (field.required) return undefined;
      continue;
    }
    if (typeof value !== 'string' || value.length > 16384 || value.indexOf('\u0000') >= 0 ||
      (field.choices !== undefined && !field.choices.includes(value))) return undefined;
    if (field.kind === 'integer') {
      if (!/^-?(0|[1-9][0-9]*)$/.test(value) || !Number.isSafeInteger(Number(value))) return undefined;
      args[field.name] = Number(value);
    } else if (field.kind === 'boolean') {
      if (value !== 'true' && value !== 'false') return undefined;
      args[field.name] = value === 'true';
    } else if (field.kind === 'string') {
      args[field.name] = value;
    } else return undefined;
  }
  return args;
}
