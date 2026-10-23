/**
 * 游戏包导出的公共数据契约。这里没有文件、网络、页面或渠道依赖，所有产品消费同一份计划。
 * 路径除 request 的三个源位置外均为规范的正斜杠相对路径；I/O 层必须自行拒绝符号链接。
 * issues 中 severity=error 表示必须阻断，warning 只描述已知限制，不能代替必需依赖检查。
 */
export type ExportFormat = 'full' | 'modrinth' | 'curseforge';
export type ExportLauncher = 'pcl' | 'hmcl';
export type ExportOperatingSystem = 'windows' | 'linux' | 'osx';
export type ExportArchitecture = 'x64' | 'arm64' | 'x86';
export type ExportLoaderKind = 'vanilla' | 'fabric' | 'forge' | 'neoforge' | 'quilt' | 'unknown';
export type ExportFileSource = 'mcRoot' | 'gameDir' | 'generated';

/** version 用于 Mojang os.version 正则；未知版本不能使带版本限制的依赖静默消失。 */
export interface ExportPlatform {
  os: ExportOperatingSystem;
  arch: ExportArchitecture;
  version: string;
}

/** 请求一经交给任务即复制固定，异步执行不得重新读取首页当前版本或隔离偏好。 */
export interface ExportRequest {
  mcRoot: string;
  versionId: string;
  gameDir: string;
  exportId: string;
  displayName: string;
  format: ExportFormat;
  launcher: ExportLauncher;
  platform: ExportPlatform;
  includeDirectories: string[];
  includeFiles: string[];
  selectedWorlds: string[];
  sharedGameDir: boolean;
  /** 省略表示旧首层选择；v2允许安全相对子路径，并由excludePaths明确裁剪父目录。 */
  selectionVersion?: number;
  /** 仅v2使用；排除优先于任何父目录包含，世界及资源包内部不允许零散排除。 */
  excludePaths?: string[];
}

/** 一个可解释的选择单元；世界/解压包使用整个目录，错误项仍保留来源以便明确排除。 */
export interface ExportContentItem {
  id: string;
  path: string;
  label: string;
  kind: 'directory' | 'file' | 'world';
  defaultSelected: boolean;
  /** 光影侧车设置依附于这一真实包；取消包时不能由“其它文件”重新带回设置。 */
  associatedPath?: string;
  size?: number;
  available: boolean;
  reason: string;
}

/** 分类只组织显示，不另外生成包含规则；有读取错误的分类不能退化为空分类。 */
export interface ExportContentGroup {
  id: string;
  label: string;
  description: string;
  items: ExportContentItem[];
  children: ExportContentGroup[];
  availability: 'available' | 'empty' | 'error';
  reason: string;
}

/** 发现不计算正文摘要；旧三列表保留给历史入口，groups是新树的权威分类事实。 */
export interface ExportContentTree {
  groups: ExportContentGroup[];
  issues: ExportIssue[];
  directories: string[];
  files: string[];
  worlds: string[];
}

/** 历史请求保守恢复的收据；不会把新默认套到用户以前确认的选择上。 */
export interface ExportContentSelectionResult { request: ExportRequest; issues: ExportIssue[]; }

/** 面向用户的问题不保存绝对源路径、认证参数或原始 JSON，避免说明文件泄漏本机资料。 */
export interface ExportIssue {
  code: string;
  severity: 'error' | 'warning';
  message: string;
  path: string;
}

/** 由只读适配器提供各版本原始 JSON，解析层不调用有副作用的启动、合并或修复入口。 */
export interface ExportVersionSource { id: string; jsonText: string; }
export interface ExportLoader {
  kind: ExportLoaderKind;
  version: string;
  /** 原始清单能确认时保留 group:artifact:精确发布版本，不能把 FML 自身版本当作加载器发布版本。 */
  coordinate?: string;
}
export interface ExportResolvedVersion {
  versionId: string;
  jarVersionId: string;
  vanillaVersion: string;
  loader: ExportLoader;
  json: Record<string, Object>;
  sourceIds: string[];
  issues: ExportIssue[];
}

/**
 * 单项电脑版必需依赖，path 相对于 mcRoot。generated 表示已知本地生成件，不得冒充远端原件。
 * sha1/size 缺少可信上游身份时保持空/0，I/O 必须报告而不能仅凭本地存在宣布完整。
 */
export interface ExportDependency {
  path: string;
  /** 旧 virtual/resources 布局可从同一对象复制；省略时源路径就是 path。 */
  sourcePath?: string;
  /**
   * 同一可信字节身份的候选源，均相对 mcRoot；旧资产可以来自 AMCL 命名布局或标准 hash 布局。
   * I/O 必须按 sha1/size 核验候选并把实选路径固定到 sourcePath，再用于准备与快照；
   * path 仍是电脑归档目标，不能把候选顺序或文件存在当成已经选中/校验成功。
   */
  sourceCandidates?: string[];
  url: string;
  sha1: string;
  size: number;
  kind: 'client' | 'library' | 'native' | 'assetIndex' | 'asset' | 'logging' | 'generated';
  generated: boolean;
  /** 安装器元数据或本地生成件的真实来源；expectedSha1 为空表示没有官方预期字节摘要。 */
  provenance?: ExportArtifactProvenance;
  /** 只能由 I/O 完整校验 JAR 后填写，不能由纯计划层把“存在”转成已经验证。 */
  generatedIdentity?: ExportGeneratedIdentity;
}
export interface ExportDependencyPlan { dependencies: ExportDependency[]; issues: ExportIssue[]; }

/** 精确安装器描述符。path 仅用于导出专用工作区，不是要求在原游戏根下载或保存安装器。 */
export interface ExportForgelikeInstaller {
  coordinate: string;
  path: string;
  url: string;
  sha1Url: string;
  loaderKind: 'forge' | 'neoforge';
  loaderVersion: string;
  minecraftVersion: string;
}

/** I/O 先核验安装器 SHA-1 并从同一归档读取两个 JSON；纯层只消费已绑定的内容及身份。 */
export interface ExportForgelikeEvidence {
  installerProfileJson: string;
  installerVersionJson: string;
  installerSha1: string;
  profileSha256: string;
}

/**
 * 来源与实测身份严格分开。生成件可能没有官方 SHA-1，此时校验只能称为“本地生成件完整性”。
 * expectedEntries 全部必须存在；expectedEntryPrefixes 中每一项至少有一个非空普通文件匹配。
 */
export interface ExportArtifactProvenance {
  installerCoordinate: string;
  installerSha1: string;
  profileSha256: string;
  role: string;
  validation: 'installer-output-sha1' | 'local-generated-jar' | 'installer-entry' | 'upstream-sha1';
  expectedSha1: string;
  entryPath: string;
  expectedEntries: string[];
  expectedEntryPrefixes: string[];
  /** 由实际准备层填写：无上游摘要的 processor 产物只有可信私有根重建后才可进入最终包。 */
  preparation?: 'installer-entry' | 'verified-source' | 'verified-processor-rebuild';
}

/** 完整 ZIP 条目/CRC32/角色内容校验后计算的实际摘要；sha1 不自动意味着它来自上游。 */
export interface ExportGeneratedIdentity {
  sha1: string;
  sha256: string;
  size: number;
  validation: 'installer-output-sha1' | 'jar-crc32';
}

/** 安装器元数据尚未准备时仅标明 profileRequired，重任务取得证据后必须重新规划完整运行闭包。 */
export interface ExportForgelikePlan extends ExportDependencyPlan {
  installer: ExportForgelikeInstaller;
  runtimePaths: string[];
  profileRequired: boolean;
}

/**
 * 实际读取的实例库存。文件大小及 SHA 是读取当时的事实，不能从来源记录直接照抄。
 * sha512 仅在需要生成 MR 下载条目时使用；没有来源时文件合法地进入 overrides。
 */
export interface ExportInventoryFile {
  path: string;
  size: number;
  sha1: string;
  sha256: string;
  directory: boolean;
  sha512?: string;
}

/** 精确来源必须与本次库存的实际字节核对；禁用文件不转成下载条目，保留原路径覆盖。 */
export interface ExportResourceSource {
  path: string;
  size: number;
  sha1: string;
  sha512: string;
  downloads: string[];
  curseforgeProjectId: number;
  curseforgeFileId: number;
  disabled: boolean;
}

/**
 * 快照条目：sourcePath 对相应源根相对；generated 的正文只写到工作副本。
 * 空目录也显式保存。必需依赖的上游摘要仍保留在该项，复制器还须保存实际 SHA256 复核。
 */
export interface ExportPlannedFile {
  source: ExportFileSource;
  sourcePath: string;
  archivePath: string;
  size: number;
  sha1: string;
  sha256: string;
  content: string;
  directory: boolean;
  required: boolean;
  /** 归档报告应如实保留生成件的验证方法和安装器身份，不把本地摘要写成官方原件证明。 */
  provenance?: ExportArtifactProvenance;
}
export interface ExportFilePlanResult {
  files: ExportPlannedFile[];
  issues: ExportIssue[];
  totalBytes: number;
}

/** 检查错误的共同入口；调用方在补全、冻结、压缩前都须重新应用，不能只在页面禁用按钮。 */
export function exportHasErrors(issues: ExportIssue[]): boolean {
  return issues.some((issue: ExportIssue): boolean => issue.severity === 'error');
}
