/**
 * JDK行为兼容的纯数据契约。目录能力用于下载选包，包内声明用于安装/导入/已装检查；
 * 声明不授予官方来源，来源仍由完整归档SHA、签名目录、安装封存及用户导入选择管理。
 */
export const ZIPFS_TRANSACTION_CAPABILITY: string = 'zipfs-transaction-v1';
export interface RuntimeCapabilityBuildMetadata { patches?: Record<string, string>; }
export interface RuntimeCapabilityMetadata {
  schema?: number;
  capabilities?: string[] | Record<string, string>;
  build?: RuntimeCapabilityBuildMetadata;
}

/** 当前已冻结R12/code原件采用schema1构建清单；只按有效补丁来源推导其明确行为，不猜文件名。 */
export function declaredRuntimeCapabilities(metadata: RuntimeCapabilityMetadata): string[] {
  const result: string[] = [];
  if (metadata.capabilities !== undefined) {
    // 冻结的schema1原件把capabilities用于AWT/音频等描述映射，并非新版行为标签。
    // 只验证旧映射形状，不把“implemented”等文本当作已满足的新要求；ZIPFS仍靠精确补丁来源。
    if (!Array.isArray(metadata.capabilities)) {
      const descriptions = metadata.capabilities as Record<string, string>;
      if (metadata.schema !== 1 || descriptions === null || typeof descriptions !== 'object' || Object.keys(descriptions).length > 64) {
        throw new Error('JDK能力声明无效');
      }
      for (const key of Object.keys(descriptions)) {
        if (!new RegExp('^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$').test(key) ||
          typeof descriptions[key] !== 'string' || descriptions[key].length > 256) throw new Error('JDK能力声明无效');
      }
    } else {
      const tags = metadata.capabilities as string[];
      if (tags.length > 24) throw new Error('JDK能力声明无效');
      for (const value of tags) {
      if (typeof value !== 'string' || !new RegExp('^[a-z0-9][a-z0-9._-]{0,95}$').test(value) || result.indexOf(value) >= 0) {
        throw new Error('JDK能力声明无效');
      }
      result.push(value);
      }
    }
  }
  const patch = metadata.build?.patches?.['0019-zipfs-permission-copy-transaction.patch'];
  if (metadata.schema === 1 && patch !== undefined) {
    if (!new RegExp('^[0-9a-f]{64}$').test(patch)) throw new Error('JDK ZIP写回修复来源声明无效');
    if (result.indexOf(ZIPFS_TRANSACTION_CAPABILITY) < 0) result.push(ZIPFS_TRANSACTION_CAPABILITY);
  }
  return result;
}

/** 返回缺少的第一项要求，空串才是全部满足；未知新能力保持拒绝，不由版本号推定。 */
export function missingRuntimeCapability(required: string[], actual: string[]): string {
  for (const capability of required) if (actual.indexOf(capability) < 0) return capability;
  return '';
}

/** 页面不暴露内部协议号；已知问题给出用户可执行的修复方向，未知要求仍如实阻断。 */
export function runtimeCapabilityRepairReason(missing: string): string {
  return missing === ZIPFS_TRANSACTION_CAPABILITY
    ? '此旧JDK缺少当前应用必需的ZIP/JAR写回修复，请在当前JDK通道修复后使用'
    : '此JDK尚不能满足当前应用的运行要求，请在当前JDK通道选择兼容运行时';
}
