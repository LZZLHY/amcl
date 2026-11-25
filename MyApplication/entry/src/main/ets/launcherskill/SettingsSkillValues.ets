/** Skill 只传递具名配置，不把用户输入用作路径、路由或可执行命令。 */
export type SettingsSkillData = Record<string, Object>;

// 引用仅关联当前应用进程中的一次展示，不能作为用户授权或跨进程恢复凭据。
let displaySerial: number = 0;
export function nextSettingsReceipt(): string {
  displaySerial++;
  return Date.now().toString(36) + '-' + displaySerial.toString(36);
}

export function settingFailure(reason: string): SettingsSkillData {
  return { 'state': 'failed', 'reason': reason };
}

/** 在产品入口做第二次参数边界检查，未知键不能悄悄改变一次写操作的含义。 */
export function settingKeys(args: SettingsSkillData, names: string[]): boolean {
  const keys = Object.keys(args);
  return keys.length === names.length && keys.every((key: string): boolean => names.includes(key));
}

export function settingText(args: SettingsSkillData, name: string): string {
  return typeof args[name] === 'string' ? args[name] as string : '';
}
