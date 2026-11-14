import { AppUpdateCompletionEvent, AppUpdateSuperseder } from 'commons';
/** sideload更新的公开状态和资产身份；不含口令、私钥或开发者令牌。 */
export enum SideloadUpdatePhase {
  Idle = 'idle', Resolving = 'resolving', Queued = 'queued', PreparingMaterial = 'preparing-material',
  Transferring = 'transferring', DispatchIntent = 'dispatch-intent', StorageBlocked = 'storage-blocked',
  Downloading = 'downloading', Verifying = 'verifying', Downloaded = 'downloaded', Signing = 'signing',
  Ready = 'ready', Installing = 'installing', AwaitingRestart = 'awaiting-restart',
  Verified = 'verified', Superseded = 'superseded', Failed = 'failed', Cancelled = 'cancelled', ConfirmationPending = 'confirmation-pending'
}

/** 由固定发布源核实的原始unsigned HAP；来源摘要在重签前验证。 */
export interface SideloadUpdateAsset {
  /** 同一真实HAP对稳定JDK供给的要求；历史原件缺字段不追认新能力。 */
  runtimeRequiredCapabilities?: string[];
  runtimeRequiredMajors?: number[];
  tag: string;
  name: string;
  url: string;
  sha256: string;
  sizeBytes: number;
  versionCode: number;
  versionName: string;
  product: string;
  legacyUniversal: boolean;
  /** 服务端已核实的镜像资产定位信息，不包含下载令牌。 */
  mirrors?: SideloadMirror[];
  websiteUrl?: string;
  /** 官网精确原件的发行类型/来源。developer 仅供已持 importToken 的手动意图，不是订阅。 */
  releaseKind?: string;
  source?: string;
  artifactId?: string;
  baseStable?: AppStableBaseline;
  /** 真实 HAP 的宿主支持集合；历史包无声明只按现役协议 1 解释。 */
  runtimeHostProtocols?: number[];
  /** 目标App恢复reader：历史缺失0；1为旧64KiB/旧意图，2支持1MiB收据与schema2耐久交接。 */
  runtimePlanProtocol?: number;
  sourceRevision?: string;
}

/** 正式基线随原件身份冻结，服务器新头不得改写已经安装的预览/开发系列。 */
export interface AppStableBaseline { tag: string; versionName: string; versionCode: number; }

/** 官网按产品及 SHA 精确定位的原件收据；不承担推荐头或安装许可的职责。 */
export interface AppArtifactReceipt {
  schema: number; kind: string; verified: boolean; revoked?: boolean;
  releaseKind: string; source: string; artifactId: string;
  versionName: string; versionCode: number; product: string; name: string;
  sha256: string; sizeBytes: number; websiteUrl: string;
  tag?: string; githubUrl?: string; baseStable?: AppStableBaseline;
  audit: AppArtifactAudit;
}

/** 发布端从同一 HAP 字节读得的身份；客户端仍以手机检查结果独立核对，不能只信表单。 */
export interface AppArtifactAudit {
  runtimeRequiredCapabilities?: string[];
  runtimeRequiredMajors?: number[];
  bundleName: string; versionName: string; versionCode: number; product: string;
  sourceRevision: string; minApi: number; targetApi?: number; abi: string;
  deviceTypes: string[]; runtimeHostProtocols?: number[];
  runtimePlanProtocol?: number;
}

export interface SideloadMirror {
  provider: string;
  projectId: string;
  assetId?: string;
  filePath?: string;
  ready: boolean;
}

export interface SideloadDelivery {
  schema: number;
  ready: boolean;
  assets: SideloadUpdateAsset[];
}

/** 原子持久化事务；新进程只有核对真实版本及载荷身份后才进入Verified。 */
export interface SideloadUpdateTransaction {
  /** 关键完成步骤与原终态身份一起耐久保存；Verified不再意味着所有跨域交接已经完成。 */
  completion?: SideloadUpdateCompletion;
  /** 已无执行权/fence/plan的历史终结记录被更高维修版替代，只归档事实，不生成新完成许可。 */
  legacySuperseded?: SideloadLegacySuperseded;
  /** 只有从明确JDK依赖选择携带的代次才绑定本App事务，普通更新不挪用历史许可。 */
  runtimeIntentId?: string;
  /** 原App事务冻结的用户订阅选择代次；旧事务缺失时完成回放不得覆盖现有选择。 */
  subscriptionRevision?: number;
  /** 整轮更新的持久账本身份；旧事务无此字段仍能恢复，但不伪造历史记录。 */
  activityId?: number;
  schema: number;
  /** schema2 持久提交的单调修订；仅 Repository 成功写盘后才发布到内存。 */
  revision?: number;
  /** 每次明确更新/重试的独立所有者，不能用缓存目录或旧成功事务代替本轮许可。 */
  ownerAttemptId?: string;
  /** 旧配方为1；新一次性执行权协议为2，迁移不会伪造旧执行者支持新CAS。 */
  installProtocol?: number;
  /** 一次性安装执行身份，每次派发重新分配，不随原件缓存复用。 */
  installId?: string;
  /** 已装目标身份与执行权结束分别确认；身份成立本身不能清除未裁决fence。 */
  installedIdentityVerified?: boolean;
  /** 材料与签名证明的最早失效时间，热Ready恢复也必须重检。 */
  signingFreshUntil?: number;
  /** 签名器根据实际证书/Profile取交集期限，不能以账号有效代替。 */
  signatureValidFrom?: number;
  signatureValidUntil?: number;
  signatureVerifiedAt?: number;
  /** 当前加密材料内容修订；导入或换材后必须重新签名。 */
  materialRevision?: string;
  identityMode?: string;
  profileTrust?: string;
  id: string;
  phase: SideloadUpdatePhase;
  asset: SideloadUpdateAsset;
  beforeVersionCode: number;
  /** 同编号发行切换必须保存原版本名和订阅通道；旧事务缺失时不能获得同 code 安装资格。 */
  beforeVersionName?: string;
  updateChannel?: string;
  /** 用户先选JDK时冻结的目标宿主要求；不是自动安装许可，真实HAP还须再次证明支持。 */
  requiredHostProtocol?: number;
  requiredHostProtocols?: number[];
  beforeUid: number;
  /** 仅 default TestHooks 的受控同编号覆盖实验；生产预览切换通过独立版本名规则准入。 */
  sameVersionTest: boolean;
  expectedPayloadIdentity: string;
  unsignedPath: string;
  signedPath: string;
  signedSha256: string;
  /** 独立安装执行者带回的一次性凭据，用于确认本事务自动重启。 */
  restartNonce: string;
  confirmedAt: number;
  createdAt: number;
  updatedAt: number;
  error: string;
  /** 失败保留原阶段，UI 不把签名/安装失败显示为重新下载。旧事务缺省使用当前阶段。 */
  failedPhase?: SideloadUpdatePhase;
  /** 固定恢复分类，不依赖显示文案判断业务动作。 */
  recoveryAction?: string;
}

/** 终态只保留重核所需固定字段，不把完整日志、账号材料或HUKS内容写入交接记录。 */
export interface SideloadUpdateCompletion {
  schema: number; event: AppUpdateCompletionEvent;
  mode: string; superseder?: AppUpdateSuperseder;
  subscriptionResult?: string;
  terminalKind: string; terminalCode: number; terminalBmSubmitted: boolean;
  executionReleased: boolean; runtimeClosed: boolean; subscriptionCommitted: boolean; intentConfirmed: boolean; done: boolean;
}
export interface SideloadLegacySuperseded { schema: number; current: AppUpdateSuperseder; recordedAt: number; }
