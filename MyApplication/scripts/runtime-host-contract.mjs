/**
 * 实际应用宿主能力的构建事实源。JSON 仅由源码维护，不能被服务器推荐或构建环境变量
 * 扩大；协议2宿主已与当前恢复事务整合。ArkTS 镜像与 HAP 声明共用此源，目标资格另行记录。
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { PRODUCT_ROOT } from './product-contract.mjs';

/** 只接受显式、去重、递增的能力集合；支持新协议不隐含支持所有旧协议。 */
export function validateRuntimeHostConfiguration(value) {
  const allowed = ['schemaVersion','supportedProtocols','runtimePlanProtocol','runtimeCatalogProtocol','requiredRuntimeCapabilities','requiredRuntimeMajors'];
  if (!value || value.schemaVersion !== 1 || Object.keys(value).some(key => !allowed.includes(key)) ||
      !Number.isSafeInteger(value.runtimePlanProtocol) || value.runtimePlanProtocol < 1 || value.runtimePlanProtocol > 999 ||
      !Array.isArray(value.supportedProtocols) || value.supportedProtocols.length < 1 || value.supportedProtocols.length > 16 ||
      value.supportedProtocols.some((protocol, index, values) => !Number.isSafeInteger(protocol) || protocol < 1 ||
        protocol > 999 || (index > 0 && values[index - 1] >= protocol))) throw new Error('Invalid runtime host configuration');
  // 新App对JDK的行为要求与JDK对宿主ABI的要求是两个方向；旧配置缺省没有新行为要求。
  const capabilities = value.requiredRuntimeCapabilities ?? [], majors = value.requiredRuntimeMajors ?? [];
  if (!Array.isArray(capabilities) || capabilities.length > 24 || new Set(capabilities).size !== capabilities.length ||
      capabilities.some(capability => typeof capability !== 'string' || !/^[a-z0-9][a-z0-9._-]{0,95}$/.test(capability)) ||
      !Array.isArray(majors) || majors.length > 64 || majors.some((major,index) => !Number.isSafeInteger(major) || major < 8 || major > 999 || index > 0 && majors[index-1] >= major) ||
      capabilities.length > 0 && majors.length === 0) throw new Error('Invalid runtime capability requirements');
  // 目录读取能力独立于Native装载ABI和更新恢复reader。旧配置保守视为1，当前源码
  // 显式声明2；生成镜像由实际目录解析器消费，不能只在HAP里填写一个未实现的能力。
  const catalogProtocol=value.runtimeCatalogProtocol??1;
  if(value.runtimeCatalogProtocol===null||![1,2].includes(catalogProtocol))throw new Error('Invalid runtime catalog protocol');
  return { schemaVersion: 1, supportedProtocols: [...value.supportedProtocols], runtimePlanProtocol: value.runtimePlanProtocol,runtimeCatalogProtocol:catalogProtocol,
    requiredRuntimeCapabilities: [...capabilities], requiredRuntimeMajors: [...majors] };
}

/** 每次读取返回独立数组，不允许消费者修改后污染另一产品或另一份产物声明。 */
export function readRuntimeHostConfiguration(root = PRODUCT_ROOT) {
  return validateRuntimeHostConfiguration(JSON.parse(readFileSync(resolve(root, 'config/runtime-host.json'), 'utf8')));
}

/** 生成的纯 ArkTS 不依赖 Kit 或远程数据，JDK 准入直接读取实际编译进包的集合。 */
export function runtimeHostSource(configuration = readRuntimeHostConfiguration()) {
  const value = validateRuntimeHostConfiguration(configuration);
  return '/** 由 config/runtime-host.json 生成；请使用 sync-product-profiles 更新，禁止远程扩大宿主能力。 */\n' +
    'export class RuntimeHostCapabilities {\n' +
    '  /** 返回本次源码实际支持的协议副本；未整合的候选能力不得加入。 */\n' +
    `  static supportedProtocols(): number[] { return [${value.supportedProtocols.join(', ')}]; }\n` +
    '  /** 恢复读取协议独立于JDK装载ABI；2支持1MiB收据和耐久完成/续作，旧1仅兼容旧事务。 */\n' +
    `  static planProtocol(): number { return ${value.runtimePlanProtocol}; }\n` +
    '  /** 目录读取能力独立于装载ABI/恢复协议；生产解析器与HAP元数据使用同一声明。 */\n' +
    `  static catalogProtocol(): number { return ${value.runtimeCatalogProtocol}; }\n` +
    '  /** 本App正常工作流必需的JDK行为；不能由网络降低或由宿主ABI支持推断满足。 */\n' +
    `  static requiredCapabilities(): string[] { return ${JSON.stringify(value.requiredRuntimeCapabilities)}; }\n` +
    '  /** 发布前必须有兼容稳定推荐的Java槽位，实际发行门禁读取HAP中的同一声明。 */\n' +
    `  static requiredMajors(): number[] { return [${value.requiredRuntimeMajors.join(', ')}]; }\n` +
    '}\n';
}

/** 构建前只比对这一个轻量镜像，不扫描全仓或 Native 缓存。 */
export function assertRuntimeHostMirror(root = PRODUCT_ROOT) {
  const config = readRuntimeHostConfiguration(root);
  const actual = readFileSync(resolve(root, 'launch/src/main/ets/RuntimeHostCapabilities.ets'), 'utf8').replace(/\r\n/g, '\n');
  if (actual !== runtimeHostSource(config)) throw new Error('Runtime host ArkTS mirror is stale; run scripts/sync-product-profiles.mjs');
  return config;
}

/** 发行类型来自包内实际版本名，开发者版与产品/default/debug 是不同的轴。 */
export function releaseKindForVersion(versionName) {
  if (typeof versionName !== 'string') throw new Error('Invalid application version name');
  if (/^\d+\.\d+\.\d+-dev[1-9]\d*$/.test(versionName)) return 'developer';
  if (/^\d+\.\d+\.\d+-(?:pre[1-9]\d*|(?:alpha|beta|rc|pre)\.\d+)$/.test(versionName)) return 'preview';
  if (/^\d+\.\d+\.\d+$/.test(versionName)) return 'stable';
  throw new Error('Invalid application release version');
}

/** 对实际 HAP 元数据核能力和发行名；缺失字段不能在新构建中被当成合法旧包。 */
export function validateRuntimeHostMetadata(metadata, versionName, configuration = readRuntimeHostConfiguration()) {
  const normalized = validateRuntimeHostConfiguration(configuration), expected = normalized.supportedProtocols;
  if (JSON.stringify(metadata.runtimeHostProtocols) !== JSON.stringify(expected)) throw new Error('HAP runtime host protocols differ from source capability');
  if (metadata.runtimePlanProtocol !== configuration.runtimePlanProtocol) throw new Error('HAP runtime plan protocol differs from source capability');
  if (metadata.runtimeCatalogProtocol !== normalized.runtimeCatalogProtocol) throw new Error('HAP runtime catalog protocol differs from source capability');
  if (JSON.stringify(metadata.runtimeRequiredCapabilities ?? []) !== JSON.stringify(normalized.requiredRuntimeCapabilities) ||
      JSON.stringify(metadata.runtimeRequiredMajors ?? []) !== JSON.stringify(normalized.requiredRuntimeMajors)) throw new Error('HAP runtime requirements differ from source capability');
  if (metadata.releaseKind !== releaseKindForVersion(versionName)) throw new Error('HAP release kind differs from actual version name');
}
