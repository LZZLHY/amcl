/** App原件携带的运行时要求。只验证明确声明，不从版本名、通道或宿主协议号猜测行为。 */
export interface AppRuntimeRequirements {
  runtimeRequiredCapabilities: string[];
  runtimeRequiredMajors: number[];
}

/** 历史包缺字段按无新增要求读取；未知类型、重复、越界和缺少槽位的能力声明拒绝。 */
export function parseAppRuntimeRequirements(capabilities?: string[], majors?: number[]): AppRuntimeRequirements {
  const caps = capabilities === undefined ? [] : capabilities;
  const slots = majors === undefined ? [] : majors;
  if (!Array.isArray(caps) || caps.length > 24 || caps.some((value: string,index: number): boolean =>
    typeof value !== 'string' || !new RegExp('^[a-z0-9][a-z0-9._-]{0,95}$').test(value) || caps.indexOf(value) !== index) ||
    !Array.isArray(slots) || slots.length > 64 || slots.some((value: number,index: number): boolean =>
      !Number.isSafeInteger(value) || value < 8 || value > 999 || slots.indexOf(value) !== index) || caps.length > 0 && slots.length === 0) {
    throw new Error('应用运行时要求声明无效');
  }
  return { runtimeRequiredCapabilities:caps.slice(), runtimeRequiredMajors:slots.slice() };
}
