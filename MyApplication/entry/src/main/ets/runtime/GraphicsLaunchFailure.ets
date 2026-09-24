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

/**
 * 按结构化阶段与代码选择恢复动作，并始终保留 native 原始状态供日志定位。
 * 参数冻结发生在 JVM 前，但图形计划可能已经锁存，所以仍服从 restartRequired；
 * 参数/JNA 运行库错误不能给出“更换渲染器”建议，否则所有后端共用的故障会被误导成驱动问题。
 * 这里只解析错误中的属性键，不显示或改写任何可能含凭据的参数值，也不触发自动重试。
 */
export function graphicsLaunchFailureMessage(status: string, failure: GraphicsLaunchFailure | undefined): string {
  if (failure === undefined) return status;
  const bootstrapParameterFailure: boolean = failure.stage === 'bootstrap'
    && (failure.code === 'runtime_property_conflict' || failure.code.startsWith('runtime_property_conflict:')
      || failure.code.startsWith('runtime_path_override') || failure.code === 'runtime_invocation_hook_override');
  const jnaRuntimeFailure: boolean = (failure.stage === 'bootstrap' || failure.stage === 'runtime'
    || failure.stage === 'artifacts') && failure.code.startsWith('jna_');
  if (bootstrapParameterFailure || jnaRuntimeFailure) {
    let guidance: string;
    if (jnaRuntimeFailure && failure.code === 'jna_runtime_artifact_missing') {
      guidance = '启动器缺少当前游戏需要的 JNA 原生运行库。请更新或重新安装完整的启动器安装包后再试，并保留本次启动日志。';
    } else if (jnaRuntimeFailure) {
      guidance = 'JNA Java 依赖与原生运行库未能匹配或加载。请检查本次启动日志，重新准备该版本的运行库后再试。';
    } else if (status.indexOf('runtime_invocation_hook_override') >= 0
      || failure.code === 'runtime_invocation_hook_override') {
      guidance = '自定义 JVM 参数覆盖了启动器保留的运行回调。请移除 exit、abort 或 vfprintf 回调参数。';
    } else {
      // 当前 native 协议将具体 key 放在状态文本中，兼容将来直接放入 code 的形式。
      // 键仅接受 JVM 属性常见标识字符，不把完整状态或参数值拼成新的诊断字段。
      const propertyMatch: RegExpExecArray | null = new RegExp(
        '(?:runtime_property_conflict|runtime_path_override):([A-Za-z0-9_.-]+)').exec(failure.code + ' ' + status);
      const propertyKey: string = propertyMatch !== null ? propertyMatch[1] : '';
      guidance = propertyKey === 'jna.tmpdir'
        ? 'JNA 临时目录参数与当前实例冲突。请检查全局及此版本的自定义 JVM 参数，移除 jna.tmpdir，交由启动器设置。'
        : '启动参数与启动器的运行库配置冲突。请检查全局及此版本的自定义 JVM 参数和加载器配置，移除冲突项。';
    }
    const recovery: string = failure.restartRequired
      ? '请返回启动器后重新启动游戏。' : '修正后请重新启动游戏。';
    return status + '\n' + guidance + '\n' + recovery;
  }
  if (failure.restartRequired) {
    return status + '\n请返回启动器后重新启动游戏；如需更换图形后端，请先在设置中选择。';
  }
  return status + '\n请检查图形后端设置与启动参数，再重新启动游戏。';
}
