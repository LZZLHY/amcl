/** sideload更新的公开状态和资产身份；不含口令、私钥或开发者令牌。 */
export enum SideloadUpdatePhase {
  Idle = 'idle', Resolving = 'resolving', Queued = 'queued', PreparingMaterial = 'preparing-material',
  Transferring = 'transferring', DispatchIntent = 'dispatch-intent', StorageBlocked = 'storage-blocked',
  Downloading = 'downloading', Verifying = 'verifying', Downloaded = 'downloaded', Signing = 'signing',
  Ready = 'ready', Installing = 'installing', AwaitingRestart = 'awaiting-restart',
  Verified = 'verified', Failed = 'failed', Cancelled = 'cancelled', ConfirmationPending = 'confirmation-pending'
}

/** 由固定发布源核实的原始unsigned HAP；来源摘要在重签前验证。 */
export interface SideloadUpdateAsset {
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
