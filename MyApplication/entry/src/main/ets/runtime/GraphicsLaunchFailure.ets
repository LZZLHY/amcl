/**
 * 同步 native 启动失败的展示协议。返回码与固定 JSON 字段同时核验，旧 native、损坏
 * 快照或不相关错误保留原状态文案；这里不根据字符串猜测可重试，也不触发自动降级。
 */
export interface GraphicsLaunchFailure {
  stage: string;
  code: string;
  profile: string;
  restartRequired: boolean;
  diagnosticInjected?: boolean;
}

/** 动态 JSON 使用固定字符串键，防止 Release 属性混淆改变 native wire 的读取方式。 */
export function parseGraphicsLaunchFailure(wire: string, returnCode: number): GraphicsLaunchFailure | undefined {
  if (returnCode >= 0 || wire.length === 0 || wire.length > 4096) return undefined;
  try {
    const value: Record<string, Object> = JSON.parse(wire) as Record<string, Object>;
    if (value === null || typeof value !== 'object' || value['schemaVersion'] !== 1
      || value['returnCode'] !== returnCode || typeof value['stage'] !== 'string'
      || typeof value['code'] !== 'string' || typeof value['profile'] !== 'string'
      || typeof value['restartRequired'] !== 'boolean') return undefined;
    const stage: string = value['stage'] as string;
    const code: string = value['code'] as string;
    const profile: string = value['profile'] as string;
    const stages: string[] = ['plan', 'activation', 'admission', 'artifacts', 'bootstrap', 'preference', 'runtime', 'binding'];
    if (stages.indexOf(stage) < 0 || code.length === 0 || code.length > 256 || profile.length > 128) return undefined;
    return { stage: stage, code: code, profile: profile, restartRequired: value['restartRequired'] as boolean,
      diagnosticInjected: value['diagnosticInjected'] === true };
  } catch (error) {
    // 失败快照只增强恢复指引；解析失败不能遮盖原始启动故障或使页面再次异常。
    return undefined;
  }
}

/** 保留具体错误信息，仅在 native 已确认进程不可复用时补充现有“返回”入口的恢复步骤。 */
export function graphicsLaunchFailureMessage(status: string, failure: GraphicsLaunchFailure | undefined): string {
  if (failure === undefined) return status;
  if (failure.restartRequired) {
    return status + '\n请返回启动器后重新启动游戏；如需更换图形后端，请先在设置中选择。';
  }
  return status + '\n请检查图形后端设置与启动参数，再重新启动游戏。';
}
