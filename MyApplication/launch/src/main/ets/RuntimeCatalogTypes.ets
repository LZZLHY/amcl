/**
 * 运行时目录 v1 的数据契约。接口只描述数据，不能取代 RuntimeCatalogValidation 的边界校验。
 * 所有路径由客户端根据 javaMajor/adapter 生成；远程数据没有脚本或本地安装路径字段。
 */
export interface RuntimeArchive { type: string; fileName: string; sizeBytes: number; sha256: string; }
export interface RuntimePart { url: string; sizeBytes: number; sha256: string; }
export interface RuntimeDownload { sourceId: string; transport: string; url?: string; parts?: RuntimePart[]; }
export interface RuntimeProvenance {
  kind: string; sourceRepository: string; sourceCommit: string; manifestSha256: string; evidence: string[];
}
export interface RuntimeBuild {
  id: string; runtimeId: string; javaVersion: string; legacyTags: string[]; archive: RuntimeArchive;
  downloads: RuntimeDownload[]; notes: string[]; capabilities: string[]; validationLevel: string;
  provenance: RuntimeProvenance; status: string;
}
/** 明确回退指令：只提示这些已安装 build，原因必须展示；不是降低目录/推荐代次。 */
export interface RuntimeRollback { fromBuildIds: string[]; reason: string; }
export interface RuntimeDefinition {
  id: string; javaMajor: number; displayName: string; os: string; arch: string; libc: string; adapter: string;
  minimumCatalogProtocol: number; minimumApi: number; loaderProtocol: number;
  recommendationRevision: number; recommendedBuildId: string;
  rollback?: RuntimeRollback;
}
export interface RuntimeCatalog {
  schemaVersion: number; catalogRevision: number; channel: string; issuedAt: string; expiresAt: string;
  runtimes: RuntimeDefinition[]; builds: RuntimeBuild[];
}
export interface RuntimeSignedEnvelope { protected: string; payload: string; signature: string; }
export interface RuntimeProtectedHeader { alg: string; typ: string; kid: string; }
export interface RuntimeTrustedKey { kid: string; algorithm: string; spki: string; }
export interface RuntimeTrustedKeys { schemaVersion: number; keys: RuntimeTrustedKey[]; }
/** receipt 随 staging 一起发布；legacy tag 只标识旧官方来源，不能冒充完整包已重新校验。 */
export interface RuntimeInstallReceipt {
  schemaVersion: number; runtimeId: string; javaMajor: number; buildId: string; recommendationRevision: number;
  archiveSha256: string; archiveSizeBytes: number; installedAt: string; origin: string;
  runtime: RuntimeDefinition; build: RuntimeBuild;
}
export interface RuntimeRefreshResult { ok: boolean; error: string; catalog: RuntimeCatalog; }
