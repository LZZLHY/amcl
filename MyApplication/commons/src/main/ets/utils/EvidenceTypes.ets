/**
 * EvidenceTypes.ets — 会话证据清单与分享选择模型（统一日志系统 U02）
 *
 * 这里仅放跨产品共享的数据模型和纯策略：
 *   - 文件角色、来源和完整性；
 *   - LogShare 默认选择；
 *   - 外发相对路径安全校验。
 *
 * 文件如何采集、保存在哪里由 entry 的平台适配器负责。
 * 任何未进入清单的文件都不能被活动页或上传器隐式带出。
 */

/** 一份证据文件的语义角色。字符串值会写入 manifest，不能随意重命名。 */
export enum EvidenceRole {
  MINECRAFT_MAIN = 'minecraft-main',
  MINECRAFT_DEBUG = 'minecraft-debug',
  MINECRAFT_OUTPUT = 'minecraft-output',
  CRASH_REPORT = 'crash-report',
  LAUNCHER = 'launcher',
  JVM_STDERR = 'jvm-stderr',
  JVM_FATAL = 'jvm-fatal',
  JVM_GC = 'jvm-gc',
  RENDERER = 'renderer',
  RENDERER_PROBE = 'renderer-probe',
  RENDERER_TRACE = 'renderer-trace',
  MOBILEGLUES = 'mobileglues',
  INPUT = 'input',
  AUDIO = 'audio',
  NETWORK = 'network',
  INSTALLER = 'installer',
  AGENT = 'agent',
  SYSTEM_CRASH = 'system-crash',
  SYSTEM_TRACE = 'system-trace',
  PUBLIC_SUMMARY = 'public-summary',
  OTHER = 'other',
}

/** 证据来自哪里。用于判断归属精度，不是展示文案。 */
export enum EvidenceSource {
  MOJANG_LOG4J = 'mojang-log4j',
  MC_STDIO = 'mc-stdio',
  AMCL_LAUNCHER = 'amcl-launcher',
  JVM = 'jvm',
  PLATFORM_DFX = 'platform-dfx',
  AMCL_RENDERER = 'amcl-renderer',
  MOBILEGLUES = 'mobileglues',
  AMCL_INPUT = 'amcl-input',
  AMCL_AUDIO = 'amcl-audio',
  AMCL_NETWORK = 'amcl-network',
  LOADER_INSTALLER = 'loader-installer',
  JAVA_AGENT = 'java-agent',
  DERIVED = 'derived',
}

/** 证据文件捕获状态。 */
export enum EvidenceFileState {
  AVAILABLE = 'available',
  WRITING = 'writing',
  COMPLETE = 'complete',
  PARTIAL = 'partial',
  MISSING = 'missing',
  NOT_PRODUCED = 'not-produced',
  NOT_APPLICABLE = 'not-applicable',
  UNAVAILABLE = 'unavailable',
  CLEANED = 'cleaned',
}

/** 默认分享集合的原因。 */
export enum EvidenceUploadPolicy {
  DEFAULT = 'default',
  OPTIONAL = 'optional',
  NEVER = 'never',
}

/** 一份证据文件在清单中的记录。 */
export interface EvidenceFileRecord {
  /** manifest 内稳定 id；同一逻辑文件的轮转分片也不能靠 basename 混淆。 */
  fileId: string;
  /** 对外稳定、安全的相对路径。 */
  path: string;
  /** 账本内的实际路径；不进入公开 manifest。 */
  localPath: string;
  /** 文件角色。 */
  role: EvidenceRole;
  /** 实际生产者。 */
  source: EvidenceSource;
  /** 当前捕获状态。 */
  state: EvidenceFileState;
  /** 是否可被用户选择上传。 */
  uploadPolicy: EvidenceUploadPolicy;
  /** 是否包含在默认分享集合。 */
  defaultSelected: boolean;
  /** 文件字节数；未知时为 0，并由 state 表示未知原因。 */
  bytes: number;
  /** 行数；无法统计时为 0。 */
  lines: number;
  /** 捕获开始/结束时间，0 表示未知。 */
  capturedAt: number;
  completedAt: number;
  /** 精确、近似或未知归属。 */
  attribution: string;
  /** 截断、丢弃、复制失败等可见原因。 */
  reason: string;
  /** 本地原件摘要，可为空；不得写入访问令牌。 */
  digest: string;
  /** 封账收据描述原件，与导出后的脱敏摘要分开保存。 */
  rawSha256?: string;
  rawBytes?: number;
  captureMode?: string;
  verification?: string;
}

/** 公开给 LogShare/剪贴板的会话摘要。 */
export interface PublicEvidenceSummary {
  schema: number;
  activityId: number;
  product: string;
  category: string;
  title: string;
  gameVersion: string;
  loader: string;
  jdk: string;
  renderer: string;
  outcome: string;
  integrity: string;
  startedAt: number;
  endedAt: number;
}

/** 账本当前所有证据的清单。 */
export interface EvidenceManifest {
  schema: number;
  activityId: number;
  revision: number;
  captureState: string;
  integrityState: string;
  droppedEvents: number;
  missingReasons: string[];
  files: EvidenceFileRecord[];
}

/** 用户一次“分享所选文件”冻结的选择。 */
export interface EvidenceUploadSelection {
  activityId: number;
  revision: number;
  selectedFileIds: string[];
  createdAt: number;
  includePublicSummary: boolean;
}

/** UI 展示用的角色名称。 */
export function evidenceRoleLabel(role: EvidenceRole): string {
  if (role === EvidenceRole.MINECRAFT_MAIN) return 'MC 主日志';
  if (role === EvidenceRole.MINECRAFT_DEBUG) return 'MC Debug';
  if (role === EvidenceRole.MINECRAFT_OUTPUT) return '游戏输出';
  if (role === EvidenceRole.CRASH_REPORT) return 'Minecraft 崩溃报告';
  if (role === EvidenceRole.LAUNCHER) return '启动器';
  if (role === EvidenceRole.JVM_STDERR) return 'JVM 启动输出';
  if (role === EvidenceRole.JVM_FATAL) return 'JVM 崩溃现场';
  if (role === EvidenceRole.JVM_GC) return 'GC 日志';
  if (role === EvidenceRole.RENDERER) return '渲染日志';
  if (role === EvidenceRole.RENDERER_PROBE) return '渲染探针';
  if (role === EvidenceRole.RENDERER_TRACE) return '渲染追踪';
  if (role === EvidenceRole.MOBILEGLUES) return 'MobileGlues';
  if (role === EvidenceRole.INPUT) return '输入日志';
  if (role === EvidenceRole.AUDIO) return '音频日志';
  if (role === EvidenceRole.NETWORK) return '网络日志';
  if (role === EvidenceRole.INSTALLER) return '加载器安装器';
  if (role === EvidenceRole.AGENT) return 'Java Agent';
  if (role === EvidenceRole.SYSTEM_CRASH) return '系统崩溃现场';
  if (role === EvidenceRole.SYSTEM_TRACE) return '系统现场附加日志';
  if (role === EvidenceRole.PUBLIC_SUMMARY) return '公开会话摘要';
  if (role === EvidenceRole.OTHER) return '其他证据';
  return '其他证据';
}

/** 真实 MC/JVM/平台故障报告属于默认“崩溃”集合。 */
export function isDefaultCrashEvidence(role: EvidenceRole): boolean {
  return role === EvidenceRole.CRASH_REPORT
    || role === EvidenceRole.JVM_FATAL
    || role === EvidenceRole.SYSTEM_CRASH;
}

/** 计算默认分享选择。用户可在页面逐项取消；optional 永远不会被隐式加入。 */
export function isDefaultEvidenceFile(file: EvidenceFileRecord): boolean {
  if (file.bytes <= 0) return false;
  if (file.uploadPolicy === EvidenceUploadPolicy.NEVER) return false;
  if (file.state === EvidenceFileState.NOT_PRODUCED || file.state === EvidenceFileState.MISSING
    || file.state === EvidenceFileState.NOT_APPLICABLE || file.state === EvidenceFileState.UNAVAILABLE
    || file.state === EvidenceFileState.CLEANED) return false;
  if (file.attribution === 'ambiguous' || file.attribution === 'previous-session') return false;
  if (file.role === EvidenceRole.MINECRAFT_MAIN) return true;
  // 原始输出/JVM 初始化覆盖 latest 尚未建立的失败，以及只输出到控制台的异常。
  if (file.role === EvidenceRole.MINECRAFT_OUTPUT || file.role === EvidenceRole.JVM_STDERR) return true;
  if (file.role === EvidenceRole.LAUNCHER) return true;
  return isDefaultCrashEvidence(file.role)
    && (file.attribution === 'exact' || file.attribution === 'source-baseline');
}

/** 外发相对路径安全校验：拒绝绝对路径、父目录、控制字符和空段。 */
export function isSafeEvidencePath(path: string): boolean {
  if (!path || path.length === 0 || path.length > 240) return false;
  if (path.indexOf('\\') >= 0 || path.startsWith('/') || path.startsWith('\\')) return false;
  if (path.indexOf(':') >= 0 || path.indexOf('\u0000') >= 0) return false;
  for (let i = 0; i < path.length; i++) {
    const code: number = path.charCodeAt(i);
    if (code < 32 || code === 127) return false;
  }
  const parts: string[] = path.split('/');
  if (parts.length === 0) return false;
  for (const part of parts) {
    if (part.length === 0 || part === '.' || part === '..') return false;
    if (part.indexOf('\u0000') >= 0) return false;
  }
  return true;
}

/** 取文件的稳定默认选择，集中在模型层避免页面和上传器两套规则。 */
export function defaultEvidenceSelection(files: EvidenceFileRecord[]): string[] {
  const out: string[] = [];
  for (const file of files) {
    if (isDefaultEvidenceFile(file)) out.push(file.fileId);
  }
  return out;
}

/** 只保留存在、可上传且用户明确选择的文件 id。 */
export function normalizeEvidenceSelection(files: EvidenceFileRecord[],
  selectedFileIds: string[]): string[] {
  const out: string[] = [];
  for (const file of files) {
    if (file.bytes <= 0) continue;
    if (file.uploadPolicy === EvidenceUploadPolicy.NEVER) continue;
    if (file.state === EvidenceFileState.MISSING
      || file.state === EvidenceFileState.NOT_PRODUCED
      || file.state === EvidenceFileState.NOT_APPLICABLE
      || file.state === EvidenceFileState.UNAVAILABLE
      || file.state === EvidenceFileState.CLEANED) continue;
    if (selectedFileIds.indexOf(file.fileId) < 0) continue;
    if (out.indexOf(file.fileId) < 0) out.push(file.fileId);
  }
  return out;
}

/** 选择快照的轻量摘要，用于分享记录复用判断；不替代文件内容校验。 */
export function evidenceSelectionDigest(selection: EvidenceUploadSelection): string {
  const seed: string = selection.activityId + '|' + selection.revision + '|'
    + selection.selectedFileIds.join(',') + '|' + selection.includePublicSummary;
  let hash: number = 7;
  for (let i = 0; i < seed.length; i++) {
    hash = (hash * 31 + seed.charCodeAt(i)) % 2147483647;
  }
  return 'selection-v1-' + hash.toString(16);
}
