/**
 * 下载、导入、已安装状态共用的宿主声明检查。用户ZIP里的受管收据虽不能授权认领，
 * 其中显式的宿主要求仍不能在导入时抹掉；未知导入保持未知，不伪造为协议1。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { runtimeHostProtocols, runtimeRequiredCapabilities } from './RuntimeHostProtocol';
import { declaredRuntimeCapabilities, missingRuntimeCapability, runtimeCapabilityRepairReason, RuntimeCapabilityMetadata, RuntimeCapabilityBuildMetadata } from './RuntimeCapabilityContract';
import { RUNTIME_INSTALL_RECEIPT_LIMIT } from './RuntimeCatalogTypes';
interface HostMetadata extends RuntimeCapabilityMetadata { requiredHostProtocol?: number; build?: HostBuildMetadata; runtime?: HostRuntimeMetadata; }
interface HostBuildMetadata extends RuntimeCapabilityBuildMetadata { requiredHostProtocol?: number; }
interface HostRuntimeMetadata { loaderProtocol?: number; }
interface HostMetadataError { code?: number | string; message?: string; }

/** 当前App下载、导入、已装启动使用相同判据；目录中的能力承诺还要由包内来源声明印证。 */
export function validateRuntimeHostDeclaration(root: string, frozenRequirement: number = 0, frozenCapabilities: string[] = []): string {
  const required = runtimeRequiredCapabilities();
  for (const value of frozenCapabilities) if (required.indexOf(value) < 0) required.push(value);
  return validateRuntimeForHost(root, runtimeHostProtocols(), required, frozenRequirement);
}

/** App组合计划按目标HAP实际要求检查，不能拿当前App要求替代旧目标或忽略新目标的行为变化。 */
export function validateRuntimeForHost(root: string, protocols: number[], requiredCapabilities: string[], frozenRequirement: number = 0): string {
  try {
    const requirements: number[] = [];
    let capabilities: string[] = [];
    if (frozenRequirement > 0) requirements.push(frozenRequirement);
    for (const name of ['amcl-runtime.json','.amcl-runtime-receipt.json']) {
      const path = root + '/' + name; let exists = true;
      try { fs.statSync(path); } catch (error) {
        const detail = error as HostMetadataError;
        if (detail.code === 13900002 || detail.code === 'ENOENT' || detail.message === 'ENOENT') exists = false;
        else throw error as Error;
      }
      if (!exists) continue;
      const stat = fs.statSync(path);
      // 构建清单还包含全部ELF符号和冻结输入，真实四代候选约1.4–1.6MB；与发行端
      // 同用16MiB上限。安装收据仍保持1MiB，不能把两种不同格式机械套同一预算。
      const limit = name === 'amcl-runtime.json' ? 16777216 : RUNTIME_INSTALL_RECEIPT_LIMIT;
      if (!stat.isFile() || stat.size <= 0 || stat.size > limit) throw new Error('运行时宿主声明大小无效');
      const metadata = JSON.parse(fs.readTextSync(path)) as HostMetadata;
      // 安装收据不能替缺失的包内能力作证明；用户导入也不能借ZIP中的受管receipt假认领。
      if (name === 'amcl-runtime.json') capabilities = declaredRuntimeCapabilities(metadata);
      for (const value of [metadata.requiredHostProtocol,metadata.build?.requiredHostProtocol,metadata.runtime?.loaderProtocol]) {
        if (value === undefined) continue;
        if (!Number.isSafeInteger(value) || value < 1 || value > 999) throw new Error('运行时宿主声明无效');
        requirements.push(value);
      }
      // 已冻结R12/code1/code2原件尚无显式字段，但schema1构建收据中的0025补丁明确
      // 引入签名宿主回调ABI2。这里只收紧要求，不授予信任或把用户包认领为官方包。
      // 保留原件与原SHA；新打包器直接写requiredHostProtocol，不依赖文件名猜协议。
      const duplexPatch = metadata.build?.patches?.['0025-ohos-javasound-duplex-host-callbacks.patch'];
      if (metadata.schema === 1 && duplexPatch !== undefined) {
        if (!new RegExp('^[0-9a-f]{64}$').test(duplexPatch)) throw new Error('运行时构建契约摘要无效');
        requirements.push(2);
      }
    }
    for (const required of requirements) {
      if (frozenRequirement > 0 && required !== frozenRequirement) return 'JDK包内宿主声明与冻结目录不一致';
      if (protocols.indexOf(required) < 0) return '此JDK与目标AMCL不兼容，请先使用支持它的AMCL版本；未安装或启动此JDK';
    }
    const missing = missingRuntimeCapability(requiredCapabilities, capabilities);
    if (missing !== '') return runtimeCapabilityRepairReason(missing);
    return '';
  } catch (error) { return '无法确认JDK宿主要求：' + (error as Error).message; }
}
