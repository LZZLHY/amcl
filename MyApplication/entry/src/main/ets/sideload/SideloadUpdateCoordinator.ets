/**
 * 主包自更新事务：下载与原始摘要验证→手机内重签/验签→完整HDC派发→新进程身份确认。
 * 只使用已授权调试连接和兼容的用户材料，不自动卸载，也不从旧进程Promise判定安装成功。
 */
import { common, bundleManager } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { deviceInfo } from '@kit.BasicServicesKit';
import { DownloadManager, DownloadTaskView, DownloadFileSpec, DownloadTaskRegistry, UnifiedTaskView } from 'feature_core';
import { DiagnosticPolicy, LedgerState, AppLogger, LOG_DOMAIN_DOWNLOAD } from 'commons';
import { SideloadUpdateAsset, SideloadUpdateTransaction, SideloadUpdatePhase, SideloadTransactionPolicy, AppUpdatePolicy } from 'update';
import testNapi from 'libentry.so';
// 必须使用产品源集别名，直接相对引用main会把default身份带入sideload/store/desktop。
import { ProductBuildProfile } from 'entry/ProductBuildProfile';
import { SigningVault } from './SigningVault';
import { SideloadFiles } from './SideloadFiles';
import { SideloadConnection } from './SideloadConnection';
import { DeveloperAuthSession, DeveloperAuthState } from './DeveloperAuthSession';
import { SideloadTransactionRepository } from './SideloadTransactionRepository';
import { SideloadUpdatePageParams } from './SideloadUpdateTestSession';
import { SideloadFixtureHttp } from './SideloadFixtureHttp';
import { SideloadUpdateTestSession } from './SideloadUpdateTestSession';
import { SideloadUpdateSnapshot } from './SideloadUpdateSnapshot';
import { GitHubUpdateAssetResolver, UpdateManifest, UpdateChecker } from 'update';
import { formatBytes } from 'commons';
import { DeveloperSigningService } from './DeveloperSigningService';
import { UpdateInstallGate } from './UpdateInstallGate';
import { InstallFence } from './InstallFence';
import { SideloadInstallExecutor, InstallExecutionIdentity, InstallExecutionObservation, InstallExecutionGuards, InstallExecutionError } from './SideloadInstallExecutor';
import { SideloadDownloadSources, SideloadDownloadSource } from './SideloadDownloadSources';
import { SideloadUpdateActivity } from './SideloadUpdateActivity';
import { SideloadDownloadTask } from './SideloadDownloadTask';

const SIGNER_SHA256 = '9cee965bb292080a0d29fb48450091f5dcc9d010bb18da39175f581ffed7c4f4';

/** 手机签名器的稳定JSON输入；可选设备身份只在真实HDC回传完成后加入。 */
interface SigningJob {
  sha256: string; bundleName: string; versionCode: number; versionName: string; product: string; apiVersion: number;
  fingerprint: string; appId: string; appIdentifier: string; deviceUdid?: string; deviceType: string;
}

/** UI 只能提交内部导入令牌；来源路径仍由唯一协调器拥有。 */
export interface PreparedSideloadImport { token: string; manifest: UpdateManifest; }
interface SideloadImportSource { token: string; path: string; manifest: UpdateManifest; sha256: string; }

export class SideloadUpdateCoordinator {
  private message: string = '正在准备更新';
  private version: string = '';
  private phase: string = 'idle';
  private materialReady: boolean = false;
  private working: boolean = false;
  private finishing: boolean = false;
  private checking: boolean = false;
  private connectionReady: boolean = false;
  private connectionRetry: boolean = false;
  private connectionMessage: string = '等待检查开发者选项和无线调试';
  private accountMessage: string = '等待检查华为登录状态';
  private accountReady: boolean = false;
  private checkingAccount: boolean = false;
  private accountRetry: boolean = false;
  private loginVisible: boolean = false;
  private loginUrl: string = '';
  private loginMessage: string = '';
  private loginBusy: boolean = false;
  private loginReason: string = '';
  private needsLogin: boolean = false;
  private needsImport: boolean = false;
  private port: string = '10178';
  private progress: number = 0;
  private transfer: string = '';
  private failedPhase: string = '';
  private recoveryAction: string = '';
  private currentActivityId: number = 0;
  private currentDownloadTaskId: string = '';
  private downloadState: string = '';
  private manifest: UpdateManifest | undefined = undefined;
  /** 本轮解析后持有独立资产副本；UI 清单、旧持久事务及镜像临时令牌都不能改写安装目标。 */
  private attemptTarget: SideloadUpdateAsset | undefined = undefined;
  private attemptChannel: string = 'stable';
  private preparedImport: SideloadImportSource | undefined = undefined;
  private importSource: SideloadImportSource | undefined = undefined;
  private authSession: DeveloperAuthSession | undefined = undefined;
  /** 登录effect独立于整轮Attempt；同轮关闭再登录也必须使旧begin/回调失效。 */
  private loginEffectGeneration: number = 0;
  private automatic: boolean = false;
  private epoch: number = 0;
  private udid: string = '';
  private failure: string = '';
  private testAsset: SideloadUpdateAsset | undefined = undefined;
  private sameVersionTest: boolean = false;
  private foreground: boolean = false;
  private abilityForeground: boolean = false;
  private windowInteractive: boolean = true;
  private loginCancelled: boolean = false;
  private connectionTimer: number = -1;
  private connectionAttempts: number = 0;
  /** Runtime换代的旧连接回收必须收敛；新owner不能复用旧check Promise或被迟到close停止host。 */
  private runtimeConnectionReset: Promise<void> | undefined = undefined;
  private runtimeConnectionResetFailed: boolean = false;
  private attemptId: string = '';
  private runtimeGeneration: number = 1;
  private snapshotRevision: number = 0;
  private finishingEpoch: number = -1;
  private presentations: Map<string, boolean> = new Map();
  /** 授权会话属于协调器；只有真实本轮账号操作才初始化，不在恢复构造时联网。 */
  private get auth(): DeveloperAuthSession {
    if (this.authSession === undefined) { this.authSession = new DeveloperAuthSession(); this.authSession.initialize(this.context); }
    return this.authSession;
  }
  private static instance_: SideloadUpdateCoordinator | undefined = undefined;
  private context: common.UIAbilityContext;
  private root: string;
  private vault: SigningVault | undefined = undefined;
  private transaction: SideloadUpdateTransaction | undefined = undefined;
  readonly connection: SideloadConnection;
  /** 下载进度只保留内存，避免每个tick同步写事务文件；每次回调通知视图读取真实字节。 */
  private bytesDone: number = 0;
  private bytesTotal: number = 0;
  private speedBps: number = 0;
  private operation: string = '';
  private downloadTaskId: number = 0;
  private cancelled: boolean = false;
  private installTimer: number = -1;
  /** 每次真实回到前台最多自动观察三次；不会以自动轮询撤销尚未领取的安装执行权。 */
  private recoveryObservations: number = 0;
  private busy: boolean = false;
  private listeners: Map<number, (snapshot: SideloadUpdateSnapshot) => void> = new Map();
  private nextListener: number = 0;
  private repository: SideloadTransactionRepository;
  private storageBlocked: boolean = false;
  private executor: SideloadInstallExecutor;
  private installEffectActive: boolean = false;
  private confirmOnForeground: boolean = false;
  private diagnosticAttempt: boolean = false;
  private pumpScheduled: boolean = false;
  private attentionPublished: boolean = false;
  private gate: UpdateInstallGate = new UpdateInstallGate();
  private releaseFiles: (() => void) | undefined = undefined;
  private activity: SideloadUpdateActivity;
  private downloadAdapter: SideloadDownloadTask | undefined = undefined;
  private downloadEnqueued: boolean = false;
  private downloadActivityId: number = 0;

  /** 主模块单例明确注入生命周期；store入口立即拒绝，不触发HDC或签名工具下载。 */
  static get(context: common.UIAbilityContext): SideloadUpdateCoordinator {
    // UIContext.getHostContext可能是同一Ability的包装对象，不能用该引用误抬Runtime代次。
    // Entry在onCreate最早发布的Context才是本进程权威；调用方files域先核对，禁止跨域借用单例。
    const canonical = AppStorage.get<common.UIAbilityContext>('uiAbilityContext') ?? context;
    if (context.filesDir !== canonical.filesDir) throw new Error('更新调用方存储身份不一致');
    if (SideloadUpdateCoordinator.instance_ === undefined) SideloadUpdateCoordinator.instance_ = new SideloadUpdateCoordinator(canonical);
    else SideloadUpdateCoordinator.instance_.bindRuntime(canonical);
    return SideloadUpdateCoordinator.instance_;
  }
  private constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.root = context.filesDir + '/sideload-update';
    this.activity = new SideloadUpdateActivity(context.filesDir, this.root + '/activity.json');
    this.connection = new SideloadConnection(this.root);
    this.executor = new SideloadInstallExecutor(context.filesDir, this.connection);
    DownloadTaskRegistry.instance().setFileLeaseProvider(
      (): number => testNapi.acquireSideloadFileLease(this.context.filesDir),
      (token: number): void => { testNapi.releaseSideloadFileLease(token); });
    this.repository = new SideloadTransactionRepository(this.root, this.allowSameVersionTest());
    try {
      SideloadFiles.ensureDirectory(this.root); this.vault = new SigningVault(context);
      InstallFence.init(context.filesDir); this.cleanInterruptedSecrets();
      const value = this.repository.load();
      if (value !== undefined) {
        this.transaction = JSON.parse(JSON.stringify(value)) as SideloadUpdateTransaction; this.version = value.asset.versionName;
        // 准备阶段也可能已持久fence；跨进程没有NoInvocation凭据，统一进入核实而不新派发。
        if (this.fenceBlocked() && value.phase !== SideloadUpdatePhase.Verified) {
          value.phase = SideloadUpdatePhase.ConfirmationPending;
          value.error = '上次安装执行权尚未核实，请查看更新状态'; this.save(value);
        }
        if (value.phase === SideloadUpdatePhase.Verified) this.cleanPackages();
        if (value.phase === SideloadUpdatePhase.Ready) { value.phase = SideloadUpdatePhase.Downloaded; this.save(value); }
        if (value.phase === SideloadUpdatePhase.Downloading || value.phase === SideloadUpdatePhase.Verifying || value.phase === SideloadUpdatePhase.Signing) {
          value.failedPhase = value.phase; value.phase = SideloadUpdatePhase.Failed;
          value.error = '上次更新被中断，可重试并复用已下载的数据'; value.updatedAt = Date.now(); this.save(value);
        }
      }
    } catch (_) { this.storageBlocked = true; this.message = '更新记录暂不可安全读取，请保留现场并核实安装结果'; }
  }
  /** 每次订阅取得独立所有权；旧视图解除时只能删除自己的编号。 */
  subscribe(listener: (snapshot: SideloadUpdateSnapshot) => void): () => void {
    const id = ++this.nextListener; this.listeners.set(id, listener); listener(this.snapshot());
    let removed = false;
    return (): void => { if (!removed) { removed = true; this.listeners.delete(id); } };
  }
  /** 外部取得独立公开副本，不能在UI或测试调用方直接改写持久事务。 */
  state(): SideloadUpdateTransaction | undefined {
    return this.transaction === undefined ? undefined : JSON.parse(JSON.stringify(this.transaction)) as SideloadUpdateTransaction;
  }
  materialAvailable(): boolean { try { return this.vault?.available() ?? false; } catch (_) { return false; } }
  isBusy(): boolean { return this.busy || this.downloadEnqueued; }
  downloadView(): UnifiedTaskView | undefined { return this.downloadAdapter?.view; }
  activityId(): number { return this.activity.activityId(); }
  /** 用户点击时先开账，资产元数据获取失败也有记录；恢复已下载文件仍归本轮新尝试。 */
  beginAttempt(version: string, _reusePrepared: boolean = false, retryOf: number = 0): void {
    if (this.activity.isRunning() && this.attemptId.length > 0) return;
    // 公开入口也不能直接凭retryOf造关系；先以原Owner/活动和当前完整候选核实，再分配新Owner。
    // reusePrepared只控制已下载事务复用，不充当重试意图或目标身份的证明。
    const retryParent = this.retryActivityForTarget(retryOf, version);
    this.attemptId = util.generateRandomUUID().replace(new RegExp('-', 'g'), '');
    this.activity.begin('AMCL 应用更新 · ' + version, 0, 0, retryParent);
    this.version = version; this.phase = SideloadUpdatePhase.Resolving;
    this.failure = ''; this.failedPhase = ''; this.recoveryAction = '';
    this.downloadAdapter = undefined; this.progress = 0; this.transfer = '';
    this.bytesDone = 0; this.bytesTotal = 0; this.speedBps = 0;
    this.operation = '正在核实更新版本';
    // reusePrepared 仅保留旧调用签名；可继续事务必须在完整候选解析、基线与文件核验后
    // 才能转移 owner。这里按显示版本提前接管，会让并行账号/连接链误推进旧产品事务。
    this.publish();
  }
  record(stage: string, message: string): void { this.activity.event(stage, message); this.publish(); }
  finishAttempt(error: string, cancelled: boolean = false): void {
    if (this.storageBlocked) { this.record('记录待核实', error); return; }
    // 安装派发后断连可能来自进程替换，普通调用方的 catch/cancel 不能抢先封账。
    // 真实失败由 reconcile 先转 Failed，真实成功由 recover 转 Verified 后分别结账。
    if (this.transaction?.phase === SideloadUpdatePhase.Installing || this.transaction?.phase === SideloadUpdatePhase.ConfirmationPending) {
      this.record('等待安装确认', error); return;
    }
    this.activity.finish(cancelled ? LedgerState.ABORTED : LedgerState.FAILED, error);
  }
  /** 仅凭匹配的持久事务豁免正在等待安装确认的主活动；下载/签名中断都必须封账。 */
  recoverActivity(): number[] {
    const task = this.state();
    if (this.activity.hasPendingTerminal()) {
      // 业务结局已有耐久原件，通用stale不能抢先改为INTERRUPTED；按原身份续作日志收尾。
      this.activity.waitForFinishAsync().catch((error: Error): void => {
        AppLogger.warn('SideloadUpdate', '更新活动收尾待重试，保留原结局与安装保护', error, LOG_DOMAIN_DOWNLOAD);
      });
      return [this.activity.activityId()];
    }
    this.activity.resume();
    if (task !== undefined && task.activityId === this.activity.activityId()) {
      if (task.phase === SideloadUpdatePhase.Verified) this.activity.finish(LedgerState.SUCCESS, '已由新进程确认目标版本、UID 与安装载荷');
      else if (task.phase === SideloadUpdatePhase.Installing || task.phase === SideloadUpdatePhase.ConfirmationPending) {
        this.record('恢复', '安装已派发，等待目标版本确认'); return [this.activity.activityId()];
      } else if (task.phase === SideloadUpdatePhase.Failed) this.activity.finish(LedgerState.INTERRUPTED, task.error || '上次更新被中断');
      else if (task.phase === SideloadUpdatePhase.Cancelled) this.activity.finish(LedgerState.ABORTED, '更新已取消');
      else this.activity.finish(LedgerState.INTERRUPTED, '应用重新启动，等待用户继续更新');
    } else this.activity.finish(LedgerState.INTERRUPTED, '上次更新尚未派发安装便结束，重试会创建新记录');
    // finish的void兼容入口已排队真实异步关闭；完成之前仍需豁免本局，失败由原件续作。
    return this.activity.hasPendingTerminal() ? [this.activity.activityId()] : [];
  }
  /** Ability/窗口事实与用户许可分开；旧运行绑定的回调不能覆盖当前Context。 */
  setForeground(value: boolean, generation: number = 0): void {
    if (generation > 0 && generation !== this.runtimeGeneration) return;
    const wasForeground=this.foreground;
    this.windowInteractive = value; this.foreground = this.abilityForeground && this.windowInteractive;
    this.gate.setForeground(this.foreground && this.hasPresentation());
    if(this.foreground && !wasForeground) {this.recoveryObservations=0;this.recover();}
    else if(!this.foreground) this.scheduleRecovery();
    if (!this.foreground) { this.clearConnectionTimer(); return; }
    if (this.automatic && !this.finishing) {
      if (!this.connectionReady && !this.connectionRetry) this.checkConnection();
      this.advance();
    }
  }
  /** 用户明确选择更新配置后才退役加密材料，失败不会悄悄删除原配置。 */
  renewMaterial(): void { if (this.busy) return; this.signingVault().invalidate(); this.publish(); }
  /** 显式材料导入独占当前操作，Runtime/新轮变化会阻止迟到的加密提交。 */
  async importMaterial(body: string): Promise<void> {
    if (this.busy || this.finishing || this.installationPending()) throw new Error('更新操作正在进行，暂不可替换签名配置');
    const epoch = this.epoch; const owner = this.attemptId; this.busy = true;
    try {
      await this.signingVault().importBundle(body, (): void => {
        if (epoch !== this.epoch || owner !== this.attemptId) throw new InstallExecutionError('stale-effect', '材料导入所属尝试已改变');
      });
    } finally { this.busy = false; this.publish(); }
  }

  /** 自动化旧入口复用下载与签名两步，产品页面可以在下载期间并行准备授权。 */
  async prepare(asset: SideloadUpdateAsset, sameVersionTest: boolean = false): Promise<void> {
    if (ProductBuildProfile.product !== 'default' || !DiagnosticPolicy.hasTestHooks()) throw new Error('直接准备仅用于已启用的诊断夹具');
    if (!SideloadUpdateTestSession.allowedAssetUrl(asset.url) || (asset.url.startsWith('http://') && !SideloadFixtureHttp.registered(asset.url))) throw new Error('诊断来源未由当前固定夹具注册');
    this.diagnosticAttempt = true;
    try { await this.download(asset, sameVersionTest); await this.signPrepared(); }
    catch (error) { this.finishAttempt((error as Error).message, this.cancelled); throw error as Error; }
  }

  /** 所有入口统一排队；整个下载和摘要核验占一个队列槽，结束后才允许获取覆盖安装租约。 */
  async download(asset: SideloadUpdateAsset, sameVersionTest: boolean = false): Promise<void> {
    if (this.storageBlocked) throw new Error('更新存储仍待核实');
    if (this.isBusy()) throw new Error('已有更新任务正在进行');
    if (ProductBuildProfile.storeChannel) throw new Error('当前产品不支持侧载自更新');
    if (this.installationPending() || this.fenceBlocked()) throw new Error('请先核实上一次安装结果');
    // 自动流程先冻结候选；诊断直接下载也复制输入，避免调用方在排队期间改写资产字段。
    if (this.attemptTarget !== undefined && this.automatic && !this.sameAssetIdentity(this.attemptTarget, asset)) {
      throw new Error('本轮更新目标已改变，请重新检查更新');
    }
    this.attemptTarget = JSON.parse(JSON.stringify(asset)) as SideloadUpdateAsset;
    if (!this.automatic) this.sameVersionTest = sameVersionTest;
    this.attemptChannel = this.manifest?.updateChannel ?? 'stable';
    asset = JSON.parse(JSON.stringify(this.attemptTarget)) as SideloadUpdateAsset;
    this.beginAttempt(asset.versionName); this.cancelled = false;
    // 公开目标身份随每轮活动保留，后续重试或新版本覆盖 transaction.json 也不会丢失旧诊断依据。
    this.record('目标安装包', asset.tag + ' · ' + asset.product + ' · versionCode=' + asset.versionCode +
      ' · bytes=' + asset.sizeBytes + ' · SHA-256=' + asset.sha256);
    const adapter = new SideloadDownloadTask(this.context.filesDir, asset.sha256, 'AMCL ' + asset.versionName + ' 安装包',
      this.activity.activityId(), async (activityId: number): Promise<void> => {
        this.downloadActivityId = activityId; await this.downloadDirect(asset, sameVersionTest);
      }, (): void => { this.cancelTransfer(); }, (): void => { this.publish(); });
    this.downloadAdapter = adapter; this.downloadEnqueued = true;
    this.phase = SideloadUpdatePhase.Queued; this.operation = '更新包已加入统一下载队列'; this.publish();
    try { await DownloadTaskRegistry.instance().enqueue(adapter); }
    catch (error) { this.finishAttempt((error as Error).message, this.cancelled); throw error as Error; }
    finally { this.downloadEnqueued = false; this.publish(); }
  }

  /** 仅由统一适配器调用；同目标重试复用原路径，使既有下载器能够恢复分段。 */
  private async downloadDirect(asset: SideloadUpdateAsset, sameVersionTest: boolean = false): Promise<void> {
    if (ProductBuildProfile.storeChannel) throw new Error('当前产品不支持侧载自更新');
    if (this.busy) throw new Error('已有更新任务正在进行');
    if (this.installationPending() || this.fenceBlocked()) throw new Error('请先核实上一次安装结果');
    this.gate.assertNoGame(this.context.filesDir);
    const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION |
      bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_SIGNATURE_INFO);
    // 订阅身份冻结到本轮事务；同编号预览不借用诊断开关，低编号安装仍被拒绝。
    const channel = this.attemptChannel;
    const versionMatches = sameVersionTest ? this.allowSameVersionTest() && asset.versionCode === info.versionCode :
      AppUpdatePolicy.canInstall(info.versionCode,info.versionName,asset.versionCode,asset.versionName,channel);
    if (!versionMatches || !new RegExp('^[0-9a-f]{64}$').test(asset.sha256)) throw new Error('更新目标版本或摘要无效');
    const previous = this.state();
    // 分段缓存也绑定完整发行/产品/来源身份和当前安装基线，不能只靠摘要复用旧目录。
    const reusable = previous !== undefined && this.sameAssetIdentity(previous.asset, asset) &&
      this.sameInstalledBaseline(previous) && previous.sameVersionTest === sameVersionTest &&
      (previous.updateChannel ?? 'stable') === channel;
    const id = reusable && previous !== undefined ? previous.id : util.generateRandomUUID().replace(new RegExp('-', 'g'), '');
    const directory = this.root + '/tasks/' + id;
    SideloadFiles.ensureDirectory(directory);
    const draft: SideloadUpdateTransaction = { schema: 2, revision: this.transaction?.revision ?? 0, ownerAttemptId: this.attemptId, id: id, activityId: this.activity.activityId(), phase: SideloadUpdatePhase.Downloading, asset: asset,
      beforeVersionCode: info.versionCode, beforeVersionName: info.versionName, updateChannel: channel,
      beforeUid: info.appInfo.uid, expectedPayloadIdentity: '',
      sameVersionTest: sameVersionTest,
      unsignedPath: directory + '/unsigned.hap', signedPath: directory + '/signed.hap', signedSha256: '',
      restartNonce: '', confirmedAt: 0,
      createdAt: Date.now(), updatedAt: Date.now(), error: '' };
    this.busy = true;
    this.cancelled = false;
    this.bytesDone = 0; this.bytesTotal = asset.sizeBytes; this.speedBps = 0;
    this.operation = '正在下载更新包';
    try {
      this.save(draft);
      const committed = this.state();
      if (committed === undefined) throw new Error('更新事务尚未提交');
      const unsignedPath = committed.unsignedPath;
      // 手动包只替代字节获取；排队、原始摘要、签名与安装仍走同一事务和准入。
      if(this.importSource!==undefined && this.importSource.sha256===asset.sha256 && !fs.accessSync(unsignedPath)) {
        this.operation='正在准备本地安装包';
        await SideloadFiles.copyBounded(this.importSource.path,unsignedPath,asset.sizeBytes);
        this.assertActive();
      }
      const cached = fs.accessSync(unsignedPath) && fs.statSync(unsignedPath).size === asset.sizeBytes &&
        await SideloadFiles.sha256(unsignedPath) === asset.sha256;
      if(this.importSource!==undefined && !cached) throw new Error('本地安装包已变化，请重新选择');
      if (!cached) {
        if (fs.accessSync(unsignedPath)) fs.unlinkSync(unsignedPath);
        const run = async (source: SideloadDownloadSource): Promise<void> => {
          this.assertActive(); this.operation = '正在从' + source.label + '下载更新包'; this.updateDownloadView();
          const file: DownloadFileSpec = { localPath: unsignedPath,
            allowedRoot: directory, urls: [source.url], check: { size: asset.sizeBytes }, maxConnections: 1 };
          if (source.token !== undefined) { file.bearerToken = source.token; file.authorizedPolicy = source.authorizedPolicy; }
          const manager = DownloadManager.instance();
          let nativeId = 0;
          try {
            await manager.createAndWait({ name: 'AMCL 应用更新 · ' + source.label, files: [file], activityId: this.downloadActivityId },
              (view: DownloadTaskView): void => { if (view.taskId > 0) nativeId = view.taskId; this.downloadProgress(view); });
          } finally {
            // 每个来源（含成功、取消及需新lease）均须先实际退出，再哈希、删除坏包、
            // 切源或结束下载子任务。这里不重试GET、不刷新次数/字节/TTL，也不更换
            // installId；持续持有当前Registry action，超时不能清ID冒充已经空闲。
            if (nativeId > 0) {
              let released = false;
              try { released = manager.purgeTask(nativeId); } catch (_) { /* 桥异常继续保留当前执行资格。 */ }
              if (!released) await manager.awaitTaskReleased(nativeId, true);
            }
            if (this.downloadTaskId === nativeId) this.downloadTaskId = 0;
          }
          this.assertActive(); this.operation = '正在校验更新包'; this.updateDownloadView(true);
          if (fs.statSync(unsignedPath).size !== asset.sizeBytes || await SideloadFiles.sha256(unsignedPath) !== asset.sha256) {
            if (fs.accessSync(unsignedPath)) fs.unlinkSync(unsignedPath);
            throw new Error('更新包摘要不一致，正在切换来源');
          }
        };
        if (ProductBuildProfile.product === 'default' && DiagnosticPolicy.hasTestHooks() &&
          (asset.url.startsWith('https://amcl.lovedhy.cn/uploads/self-update-tests/') || SideloadFixtureHttp.registered(asset.url))) await run({ label: '测试源', url: asset.url });
        else await SideloadDownloadSources.download(asset, (): boolean => !this.cancelled, run);
      } else { this.bytesDone = asset.sizeBytes; this.bytesTotal = asset.sizeBytes; }
      this.assertActive();
      this.operation = '正在校验更新包';
      this.transition(SideloadUpdatePhase.Verifying);
      this.updateDownloadView(true);
      if (fs.statSync(unsignedPath).size !== asset.sizeBytes || await SideloadFiles.sha256(unsignedPath) !== asset.sha256) {
        // 大小正确的坏文件不能交回下载器复用；只删除本事务已收敛的最终文件。
        if (fs.accessSync(unsignedPath)) fs.unlinkSync(unsignedPath);
        throw new Error('更新包摘要不一致，重试将重新下载');
      }
      this.assertActive();
      this.operation = '更新包已下载，正在准备安装条件';
      this.transition(SideloadUpdatePhase.Downloaded);
    } catch (error) { this.fail(error as Error); throw error as Error; }
    finally { testNapi.cancelSideloadPow(); this.busy = false; this.downloadTaskId = 0; this.speedBps = 0; this.publish(); }
  }

  /** 下载、授权和调试连接均准备好后调用；锁在第一个await之前取得，重复回调不会重复签名。 */
  async signPrepared(): Promise<void> {
    if (ProductBuildProfile.storeChannel) throw new Error('当前产品不支持侧载自更新');
    if (this.busy) throw new Error('已有更新任务正在进行');
    if (this.transaction === undefined || (this.transaction.phase !== SideloadUpdatePhase.Downloaded &&
      this.transaction.phase !== SideloadUpdatePhase.AwaitingRestart)) throw new Error('请先完成更新包下载');
    if (!this.signingVault().available()) throw new Error('请完成华为授权或导入兼容的签名配置');
    if (testNapi.mcIsRunning()) throw new Error('请先保存并退出游戏');
    this.busy = true; this.cancelled = false;
    const epoch = this.epoch; const owner = this.attemptId;
    try {
      const draft = this.state()!; draft.error = ''; draft.failedPhase = undefined; draft.recoveryAction = ''; this.save(draft);
      await this.sign(epoch, owner);
    } catch (error) {
      if (epoch === this.epoch && owner === this.attemptId) this.fail(error as Error);
      throw error as Error;
    } finally {
      this.busy = false; this.downloadTaskId = 0;
      const current = this.state();
      if (!this.storageBlocked && current !== undefined && current.ownerAttemptId === this.attemptId && !this.installationPending()) {
        if (this.cancelled) this.transition(SideloadUpdatePhase.Cancelled, current);
        else if (epoch !== this.epoch && this.automatic && current.phase === SideloadUpdatePhase.Signing) {
          this.operation = '运行环境已重新绑定，正在重新核实签名'; this.transition(SideloadUpdatePhase.Downloaded, current);
        }
      }
      this.publish();
    }
  }

  /** 安装开始前允许取消；不删除原始包，下载器终态收敛后才允许再次开始。 */
  /** 用户撤销本轮许可；排队状态同样取消，历史Verified不能阻挡新Attempt。 */
  cancel(): void {
    if (this.installationPending() || [SideloadUpdatePhase.Verified, SideloadUpdatePhase.Failed, SideloadUpdatePhase.Cancelled].indexOf(this.phase as SideloadUpdatePhase) >= 0) return;
    this.epoch++; this.automatic = false; this.working = false; this.checking = false;
    this.checkingAccount = false; this.accountReady = false; this.clearConnectionTimer();
    this.invalidateLoginEffect(); this.loginBusy = false; this.loginVisible = false; this.loginUrl = '';
    if (this.downloadEnqueued && this.downloadAdapter !== undefined) {
      DownloadTaskRegistry.instance().cancel(this.downloadAdapter.view.id).catch((): void => {});
    } else if (this.installEffectActive) { this.cancelled = true; }
    else this.cancelTransfer();
    if (!this.installEffectActive) this.phase = SideloadUpdatePhase.Cancelled; this.operation = '更新已取消，已下载的数据会保留供重试'; this.message = this.operation;
    if (!this.installEffectActive) this.connection.close(); this.publish();
  }
  /** 适配器回调直接到执行层，避免 service.cancel 与 registry.cancel 相互递归。 */
  private cancelTransfer(): void {
    if (this.installationPending()) return;
    this.cancelled = true; testNapi.cancelSideloadPow();
    if (this.downloadTaskId > 0) DownloadManager.instance().cancel(this.downloadTaskId);
    const task = this.state();
    if (!this.busy && task !== undefined && task.ownerAttemptId === this.attemptId) this.transition(SideloadUpdatePhase.Cancelled, task);
    this.finishAttempt('更新已取消，已下载数据保留供重试', true);
  }
  private assertActive(): void { if (this.cancelled) throw new Error('更新已取消'); }
  private downloadProgress(view: DownloadTaskView): void {
    this.downloadTaskId = view.taskId;
    this.bytesDone = view.bytesDone; this.bytesTotal = view.bytesTotal; this.speedBps = view.speedBps;
    if (this.cancelled && !view.finished) DownloadManager.instance().cancel(view.taskId);
    this.updateDownloadView();
  }
  private updateDownloadView(verifying: boolean = false): void {
    this.downloadAdapter?.progress(this.bytesDone, this.bytesTotal, this.speedBps, this.operation, verifying);
    this.publish();
  }

  /** 下载已经结束后准备云端材料；密钥、令牌及云端响应不穿过View层。 */
  async prepareMaterial(auth: DeveloperAuthSession, udid: string): Promise<void> {
    if (ProductBuildProfile.storeChannel) throw new Error('当前产品不支持侧载自更新');
    if (this.busy) throw new Error('请等待当前更新步骤完成');
    this.busy = true; this.cancelled = false;
    const epoch = this.epoch; const owner = this.attemptId;
    try {
      const signer = await this.ensureSigner(); this.assertEffect(epoch, owner);
      const runner = this.root + '/amcl-signing-runner.jar';
      SideloadFiles.write(runner, this.context.resourceManager.getRawFileContentSync('sideload/amcl-signing-runner.jar'));
      this.operation = '正在获取华为签名证书'; this.publish();
      await DeveloperSigningService.prepare(this.context, auth, this.signingVault(), udid, signer, runner, this.jdk(),
        (): void => { this.assertEffect(epoch, owner); });
      this.assertEffect(epoch, owner);
    } finally { this.busy = false; this.downloadTaskId = 0; this.publish(); }
  }

  /** 固定开源签名器随包携带，每次提取核对摘要；主镜像可用时不再被 GitHub 工具下载拖住。 */
  /**
   * 手动预检不授予安装许可。保存有界副本、读取真实信息，再匹配官方历史收据；
   * busy/fence 与自动更新共用，游戏运行时不启动手机 Java 处理器。
   */
  async preparePickedPackage(uri: string, channel: string): Promise<PreparedSideloadImport> {
    if(ProductBuildProfile.storeChannel || this.busy || this.working || this.installationPending() || this.fenceBlocked()) throw new Error('请先完成当前更新任务');
    this.gate.assertNoGame(this.context.filesDir); this.discardPreparedPackage();
    const token=util.generateRandomUUID().replace(new RegExp('-','g'),'');
    const directory=this.root+'/imports/'+token; SideloadFiles.ensureDirectory(directory);
    const path=directory+'/candidate.hap'; this.busy=true; this.cancelled=false;
    const generation=this.runtimeGeneration;
    try {
      const size=await SideloadFiles.copyBounded(uri,path,2*1024*1024*1024);
      const signer=await this.ensureSigner();
      const runner=directory+'/runner.jar', result=directory+'/metadata.json';
      SideloadFiles.write(runner,this.context.resourceManager.getRawFileContentSync('sideload/amcl-signing-runner.jar'));
      const code=await testNapi.runJavaProcessor(this.context.filesDir,this.jdk(),512,runner+':'+signer,
        'AmclSigningRunner',['--inspect-hap',path,result],directory,directory+'/inspect.log');
      if(code===-7 || code===-8) throw new Error('请重新打开 AMCL 后再选择安装包');
      if(code!==0 || !fs.accessSync(result)) throw new Error('无法读取安装包信息');
      const metadata=JSON.parse(fs.readTextSync(result)) as Record<string,Object>;
      const product=GitHubUpdateAssetResolver.assetProduct(ProductBuildProfile.product);
      if(metadata['inspected']!==true || metadata['bundleName']!=='com.amcl.launcher' || metadata['product']!==product) throw new Error('请选择当前产品的官方未签名 HAP');
      const devices=metadata['deviceTypes']; const minimum=Number(metadata['minApi']);
      if(!Array.isArray(devices) || (devices as string[]).indexOf(deviceInfo.deviceType)<0 || !Number.isInteger(minimum) || minimum<1 || minimum>deviceInfo.sdkApiVersion) throw new Error('此安装包不支持当前设备或系统版本');
      const tag='v'+String(metadata['versionName'] ?? '');
      if(channel==='stable' && AppUpdatePolicy.prerelease(tag)) throw new Error('这是测试版本，请先切换到测试通道再选择');
      const manifest=await UpdateChecker.publishedVersion(tag,ProductBuildProfile.product,channel);
      const asset=GitHubUpdateAssetResolver.fromDelivery(manifest,ProductBuildProfile.product);
      if(manifest.versionCode!==Number(metadata['versionCode']) || !UpdateChecker.canInstall(manifest,channel)) throw new Error('此安装包不是当前通道可安装的更新；低编号包不支持覆盖安装');
      const hash=await SideloadFiles.sha256(path);
      if(size!==asset.sizeBytes || hash!==asset.sha256) throw new Error('请选择 GitHub 发布的原始未签名包；此文件与官方摘要不一致');
      if(generation!==this.runtimeGeneration) throw new Error('更新页面已重新打开，请重新选择安装包');
      this.preparedImport={token:token,path:path,manifest:manifest,sha256:hash};
      return {token:token,manifest:JSON.parse(JSON.stringify(manifest)) as UpdateManifest};
    } catch(error) {this.removeImportDirectory(directory);throw error as Error;}
    finally {this.busy=false;this.publish();}
  }
  /** 只回收预检创建的固定文件；活动更新持有的副本不由页面退出清理。 */
  discardPreparedPackage(token: string = ''): void {
    const value=this.preparedImport;if(value===undefined || (token.length>0 && value.token!==token)) return;
    this.preparedImport=undefined;this.removeImportDirectory(value.path.substring(0,value.path.lastIndexOf('/')));
  }
  private removeImportDirectory(directory: string): void {
    if(!new RegExp('^[0-9a-f]{32}$').test(directory.substring(directory.lastIndexOf('/')+1)) || !directory.startsWith(this.root+'/imports/')) return;
    try {for(const leaf of ['candidate.hap','runner.jar','metadata.json','inspect.log']) {const file=directory+'/'+leaf;if(fs.accessSync(file))fs.unlinkSync(file);}fs.rmdirSync(directory);} catch(_) { /* 中断原件保留，不扩大删除范围。 */ }
  }

  /** 固定工具每次提取仍核对原有 pin；预检和签名共用同一可信工具。 */
  private async ensureSigner(): Promise<string> {
    const signer = this.root + '/hap-sign-tool.jar';
    this.assertActive();
    if (!fs.accessSync(signer) || await SideloadFiles.sha256(signer) !== SIGNER_SHA256) {
      this.operation = '正在准备签名组件'; this.publish();
      SideloadFiles.write(signer, this.context.resourceManager.getRawFileContentSync('sideload/hap-sign-tool.jar'));
      if (await SideloadFiles.sha256(signer) !== SIGNER_SHA256) throw new Error('签名工具完整性校验失败');
    }
    this.assertActive(); return signer;
  }

  /** 复用应用已经安装的JDK；不存在时给出可恢复原因，不能借用宿主签名伪装手机完成。 */
  private jdk(): string {
    for (const version of ['17', '21', '25']) if (fs.accessSync(this.context.filesDir + '/jdk/' + version + '/lib/server/libjvm.so')) return version;
    const draft = this.state(); if (draft !== undefined) { draft.recoveryAction = 'runtime'; this.save(draft); }
    throw new Error('请先到设置中的运行时管理安装 JDK 17 或更新版本，再继续更新');
  }

  /** 提取固定开源签名器并核对摘要；JVM只接收路径，口令不进入NAPI argv。 */
  private async sign(epoch: number = this.epoch, owner: string = this.attemptId): Promise<void> {
    const transaction = this.state();
    if (transaction === undefined) throw new Error('更新事务不存在');
    this.assertTargetBinding(transaction);
    const directory = this.root + '/tasks/' + transaction.id;
    const signer = await this.ensureSigner(); this.assertEffect(epoch, owner); this.assertTargetBinding(transaction);
    const runner = directory + '/amcl-signing-runner.jar';
    SideloadFiles.write(runner, this.context.resourceManager.getRawFileContentSync('sideload/amcl-signing-runner.jar'));
    const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_SIGNATURE_INFO);
    const job = directory + '/job.json';
    const jobData: SigningJob = { sha256: transaction.asset.sha256, bundleName: info.name,
      versionCode: transaction.asset.versionCode, versionName: transaction.asset.versionName,
      product: transaction.asset.product, apiVersion: deviceInfo.sdkApiVersion,
      deviceType: deviceInfo.deviceType,
      fingerprint: info.signatureInfo.fingerprint, appId: info.signatureInfo.appId,
      appIdentifier: info.signatureInfo.appIdentifier };
    const udid = this.connection.deviceUdid();
    if (udid) jobData.deviceUdid = udid;
    SideloadFiles.write(job, JSON.stringify(jobData));
    const privateRoot = directory + '/private';
    try {
      // 先标记阶段再解密，损坏的缓存材料也会提供更新/导入入口。
      this.operation = '正在为本机准备安装包';
      this.transition(SideloadUpdatePhase.Signing);
      // materialize中途失败也必须进入finally，清除可能已写出的部分明文材料。
      await this.signingVault().materialize(privateRoot); this.assertEffect(epoch, owner); this.assertTargetBinding(transaction);
      const code = await testNapi.runJavaProcessor(this.context.filesDir, this.jdk(), 1024, runner + ':' + signer,
        'AmclSigningRunner', [privateRoot + '/config.json', transaction.unsignedPath, transaction.signedPath,
          directory + '/signer-result.json', job], directory, directory + '/signer-runtime.log');
      this.assertEffect(epoch, owner); this.assertTargetBinding(transaction);
      if (code === -7 || code === -8) {
        this.transition(SideloadUpdatePhase.AwaitingRestart);
        throw new Error('请重新打开 AMCL 后继续签名');
      }
      if (code !== 0 || !fs.accessSync(directory + '/signer-result.json')) throw new Error('手机签名执行失败');
      this.assertActive();
      const result = JSON.parse(fs.readTextSync(directory + '/signer-result.json')) as Record<string, Object>;
      if (result['signed'] !== true || result['verified'] !== true || typeof result['payloadIdentity'] !== 'string') {
        const reasons: Record<string, string> = {
          'Profile identifier mismatch': '签名配置与当前安装身份不一致，请使用原安装账号或导入原配置',
          'Profile certificate mismatch': '证书与调试配置不匹配，请重新导入完整配置',
          'Profile expired': '调试配置已过期，请导入有效的签名配置',
          'Profile device missing': '调试配置未包含当前设备，请更新设备授权',
          'Profile JIT permission missing': '调试配置缺少应用运行所需的 JIT 权限',
          'Signing certificate missing from chain': '签名私钥与证书不匹配，请导入同一份完整配置'
          , 'Profile identifier trust unavailable': '导入配置的公钥发生变化，请核实原账号的云端身份或导入原安装配置'
          , 'Signature material proof mismatch': '签名材料来源证明与实际材料不一致，请重新获取或导入'
          , 'HAP device incompatible': '更新包不支持当前设备类型，请重新检查本产品更新'
        };
        const message = reasons[String(result['failureReason'] ?? '')];
        if (result['failureReason'] === 'HAP device incompatible') {
          const next = this.state()!; next.recoveryAction = 'package'; this.save(next);
        }
        if (message) throw new Error(message);
        throw new Error('更新包签名或身份核验未通过');
      }
      transaction.signedSha256 = await SideloadFiles.sha256(transaction.signedPath); this.assertEffect(epoch, owner); this.assertTargetBinding(transaction);
      transaction.expectedPayloadIdentity = result['payloadIdentity'] as string;
      const validFrom = Number(result['signatureValidFrom']);
      const validUntil = Number(result['signatureValidUntil']);
      const verifiedAt = Number(result['signatureVerifiedAt']);
      if (!Number.isFinite(validFrom) || !Number.isFinite(validUntil) || !Number.isFinite(verifiedAt) ||
        validUntil <= validFrom || verifiedAt < validFrom || verifiedAt >= validUntil || typeof result['materialRevision'] !== 'string') {
        throw new Error('签名有效期或材料修订证明缺失，请重新准备签名配置');
      }
      transaction.signatureValidFrom = validFrom; transaction.signatureValidUntil = validUntil;
      transaction.signatureVerifiedAt = verifiedAt; transaction.signingFreshUntil = validUntil;
      transaction.materialRevision = result['materialRevision'] as string;
      transaction.identityMode = String(result['identityMode'] ?? ''); transaction.profileTrust = String(result['profileTrust'] ?? '');
      this.operation = '更新包已准备完成';
      this.transition(SideloadUpdatePhase.Ready, transaction);
    } finally { this.signingVault().clearTemporary(privateRoot); }
  }

  /** 已验证事务唯一目标；设备侧先核对摘要，安装返回不等于最终成功。 */
  /**
   * 一次性安装边界由Executor裁决。Coordinator只持业务许可/Repository/Registry租约，
   * CLI返回、旧版本、断连、磁盘未知均不能推断BMS失败或再次派发。
   */
  async install(pumpEpoch: number = -1): Promise<void> {
    if (ProductBuildProfile.storeChannel) throw new Error('当前产品不支持侧载自更新');
    if (this.finishing && pumpEpoch !== this.finishingEpoch) throw new Error('已有更新步骤正在进行，请等待其完成');
    const transaction = this.state();
    if (transaction === undefined || transaction.phase !== SideloadUpdatePhase.Ready || this.busy || this.storageBlocked) throw new Error('更新包尚未准备完成');
    this.assertTargetBinding(transaction);
    this.busy = true; this.installEffectActive = true;
    const epoch = this.epoch; const owner = this.attemptId;
    transaction.ownerAttemptId = owner || transaction.ownerAttemptId || transaction.id;
    transaction.installProtocol = 2; transaction.installId = util.generateRandomUUID().replace(new RegExp('-', 'g'), '');
    transaction.restartNonce = util.generateRandomUUID().replace(new RegExp('-', 'g'), '');
    const identity = this.executionIdentity(transaction);
    const guards: InstallExecutionGuards = {
      assertCurrent: (): void => {
        this.assertActive();
        if (epoch !== this.epoch || owner !== this.attemptId) throw new InstallExecutionError('cancelled', '本轮更新已撤销');
        this.assertTargetBinding(transaction);
      },
      assertForeground: (): void => {
        if (!this.foreground || (!this.hasPresentation() && !this.diagnosticAttempt)) throw new InstallExecutionError('foreground', '已暂停安装，返回 AMCL 后会继续');
      }
    };
    let proof: InstallExecutionObservation | undefined = undefined;
    let enteredExecutor = false;
    try {
      if (!(await this.signatureFresh())) { this.transition(SideloadUpdatePhase.Downloaded); throw new Error('安装包签名证明已失效，请重新准备后更新'); }
      guards.assertCurrent(); guards.assertForeground();
      this.releaseFiles = DownloadTaskRegistry.instance().acquireReplacementLease();
      this.operation = '正在传送并核实安装准备'; this.transition(SideloadUpdatePhase.Transferring, transaction);
      enteredExecutor = true; await this.executor.prepare(identity, guards);
      if (!(await this.signatureFresh())) throw new InstallExecutionError('preparation', '传送期间签名证明已失效，请重新准备更新包');
      guards.assertCurrent(); guards.assertForeground();
      proof = await this.executor.dispatch(identity, (): void => {
        const next = this.state()!;
        this.assertTargetBinding(next);
        if (!this.signatureTimeValid(next)) throw new InstallExecutionError('preparation', '签名证明已过期或系统时间改变，请重新准备');
        this.operation = '安装请求已可靠保存，正在派发';
        this.transition(SideloadUpdatePhase.DispatchIntent, next);
      }, guards);
      this.operation = '安装已请求，等待应用重新打开并核实系统结果';
      this.transition(SideloadUpdatePhase.Installing);
    } catch (error) {
      // prepare未派发可由本进程NoInvocation证明；派发可能成功时必须竞争remote撤销/观察。
      if (!enteredExecutor && !this.fenceBlocked()) {
        // 没安排安装effect，不能因Registry忙/前台消失凭空制造OutcomeUnknown或fence。
        if (!this.storageBlocked) {
          if ((error instanceof InstallExecutionError && error.kind === 'foreground') || (epoch !== this.epoch && this.automatic && owner === this.attemptId)) {
            this.operation = '安装包已准备好，返回 AMCL 后继续'; this.transition(SideloadUpdatePhase.Ready);
          } else this.fail(error as Error);
        }
        throw error as Error;
      }
      proof = await this.executor.revoke(identity);
      if (proof.safeToRelease && !this.storageBlocked) {
        const next = this.state()!;
        if ((error instanceof InstallExecutionError && error.kind === 'foreground') || (epoch !== this.epoch && this.automatic && owner === this.attemptId && !this.cancelled)) {
          next.error = ''; this.operation = '安装包已准备好，返回 AMCL 后继续'; this.transition(SideloadUpdatePhase.Ready, next);
        } else {
          next.error = this.cancelled ? '更新已取消，原应用已保留' : (error as Error).message;
          next.failedPhase = next.phase; next.recoveryAction = 'retry';
          this.transition(this.cancelled ? SideloadUpdatePhase.Cancelled : SideloadUpdatePhase.Failed, next);
        }
        this.executor.complete(identity, proof, false);
        try { await this.executor.cleanupPayload(identity); } catch (_) { this.record('清理待重试', '安装载荷暂未清理，已保留诊断'); }
        this.releaseInstallGates();
      } else if (!this.storageBlocked) {
        const next = this.state()!; next.error = '安装副作用尚未核实，已保留保护，请查看更新状态';
        this.transition(SideloadUpdatePhase.ConfirmationPending, next);
      }
      throw error as Error;
    } finally {
      this.busy = false; this.installEffectActive = false;
      this.executor.releaseProcessLeases(identity);
      if (!this.fenceBlocked()) this.releaseInstallGates();
      await this.connection.close(); this.scheduleRecovery(); this.publish();
    }
  }

  /**
   * 新版本身份和旧执行权分别确认；启动恢复不调用安装，不以 CLI/AA 回调直接解 fence。
   * 完整匹配当前 installId/restartNonce 的 AA 只提前唤醒既有安全撤销/观察裁决路径：
   * BMS 失败或回执待重采时即使仍运行原版本，也无需先等五分钟才能开始核实。
   * 该唤醒不建立新更新许可，不重派 bm，更不能代替版本、UID 和载荷身份的成功证明。
   */
  recover(launchId: string = '', launchNonce: string = ''): void {
    const transaction = this.state();
    if (transaction === undefined || !this.installationPending()) return;
    const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
    const profile = JSON.parse(new util.TextDecoder().decodeWithStream(this.context.resourceManager.getRawFileContentSync('product-profile.json'))) as Record<string, Object>;
    const installedIdentityConfirmed = SideloadTransactionPolicy.confirms(transaction, info.versionCode, info.appInfo.uid,
      String(profile['sourceRevision'] ?? ''), launchId, launchNonce, this.allowSameVersionTest(), info.versionName);
    if (installedIdentityConfirmed) {
      if (transaction.installedIdentityVerified !== true) {
        transaction.installedIdentityVerified = true; transaction.confirmedAt = Date.now();
        transaction.error = '目标版本已运行，正在核实原安装执行权';
        this.transition(SideloadUpdatePhase.ConfirmationPending, transaction);
      }
    }
    // 缓存事务 id 与安装执行 id 是不同身份；这里不回退到 transaction.id，
    // 不接纳缺少 installId、错误 nonce 或别轮执行者的回调。目标确认标志也不在此写入。
    const matchingExecutionCallback = transaction.installId !== undefined &&
      launchId === transaction.installId && new RegExp('^[0-9a-f]{32}$').test(launchId) &&
      launchNonce === transaction.restartNonce && new RegExp('^[0-9a-f]{32}$').test(launchNonce);
    if (installedIdentityConfirmed || matchingExecutionCallback) {
      // 后台或已有核实操作时只保留前台核实意图；沿用现有 foreground/busy Guard，
      // 不在 AA 回调中绕过守卫、开放安装许可或启动另一轮更新。
      this.confirmOnForeground = true;
      if (this.foreground && !this.busy) this.reconcileInstallation().catch((): void => {});
    } else if (Date.now() - transaction.updatedAt > 5 * 60 * 1000 && transaction.phase !== SideloadUpdatePhase.ConfirmationPending) {
      transaction.error = '尚未确认系统安装结果，请查看更新状态并核实';
      this.transition(SideloadUpdatePhase.ConfirmationPending, transaction);
    }
    this.scheduleRecovery();
  }
  /** 使用持久化派发时间计算剩余期限，冷启动恢复也不会重新获得完整五分钟。 */
  private scheduleRecovery(): void {
    if (this.installTimer >= 0) clearTimeout(this.installTimer);
    this.installTimer = -1;
    if (this.transaction?.phase === SideloadUpdatePhase.Installing) {
      const delay = Math.max(1, this.transaction.updatedAt + 5 * 60 * 1000 + 1 - Date.now());
      this.installTimer = setTimeout((): void => { this.installTimer = -1; this.recover(); }, delay);
    } else if(this.transaction?.phase===SideloadUpdatePhase.ConfirmationPending && this.foreground && this.recoveryObservations<3) {
      const delays: number[]=[1000,3000,10000];
      this.installTimer=setTimeout((): void=>{
        this.installTimer=-1;
        if(!this.foreground || this.busy || this.finishing) return;
        this.recoveryObservations++;
        // observe 只收取原执行证据，不再次派发 bm，也不抢先 revoke 正常延迟启动的 worker。
        this.reconcileInstallation(false).catch((): void=>{
          this.message='暂未取得更新结果，请连接无线调试后重新检查';this.publish();
        }).finally((): void=>{this.scheduleRecovery();});
      },delays[this.recoveryObservations]);
    }
  }
  /** 同版本只用于受控default真机实验，正式渠道不能靠修改journal开启此模式。 */
  private allowSameVersionTest(): boolean { return ProductBuildProfile.product === 'default' && DiagnosticPolicy.hasTestHooks(); }

  private transition(phase: SideloadUpdatePhase, draft?: SideloadUpdateTransaction): void {
    const next = draft ?? this.state();
    if (next === undefined) return;
    next.phase = phase; next.updatedAt = Math.max(next.createdAt, next.updatedAt, Date.now()); this.save(next);
    if (next.ownerAttemptId === this.attemptId || this.attemptId.length === 0) this.phase = phase;
    this.record(phase, next.error || this.operation || phase);
    if (phase === SideloadUpdatePhase.Verified) this.activity.finish(LedgerState.SUCCESS, '已由新进程确认目标身份和一次性安装执行权收尾');
    else if (phase === SideloadUpdatePhase.Failed) this.finishAttempt(next.error || '更新失败');
    else if (phase === SideloadUpdatePhase.Cancelled) this.finishAttempt('更新已取消', true);
    this.publish();
  }
  private fail(error: Error): void {
    if (this.storageBlocked || this.installationPending()) { this.record('等待核实', error.message); return; }
    const next = this.state(); if (next === undefined) return;
    next.error = error.message; next.failedPhase = next.phase;
    if (next.recoveryAction !== 'runtime' && next.recoveryAction !== 'package') next.recoveryAction = next.phase === SideloadUpdatePhase.Signing ? 'material' : 'retry';
    if (this.cancelled) this.transition(SideloadUpdatePhase.Cancelled, next);
    else if (next.phase === SideloadUpdatePhase.AwaitingRestart) this.save(next);
    else this.transition(SideloadUpdatePhase.Failed, next);
  }
  /** 冷启动后复用已校验的原始包，不重复下载或绕开JVM生命周期保留态。 */
  async continuePreparing(): Promise<void> {
    if (!this.allowSameVersionTest()) throw new Error('直接继续仅用于诊断入口');
    this.diagnosticAttempt = true;
    if (this.transaction === undefined || this.transaction.phase !== SideloadUpdatePhase.AwaitingRestart || this.busy) return;
    if (testNapi.mcIsRunning()) throw new Error('请先保存并退出游戏');
    this.busy = true;
    try {
      if (await SideloadFiles.sha256(this.transaction.unsignedPath) !== this.transaction.asset.sha256) throw new Error('已下载更新包不完整');
      const draft = this.state()!; draft.error = ''; this.save(draft);
      await this.sign();
    } catch (error) { this.fail(error as Error); throw error as Error; }
    finally { this.busy = false; this.publish(); }
  }
  /** 先可靠持久提交，再替换内存；未知耐久性封所有后续effect，不写第二次假失败覆盖现场。 */
  private save(value: SideloadUpdateTransaction): void {
    try {
      const next = this.repository.commit(value, this.transaction?.revision ?? 0);
      this.transaction = next; this.publish();
    } catch (error) {
      this.storageBlocked = true; this.automatic = false; this.working = false;
      this.invalidateLoginEffect(); this.loginBusy = false; this.loginVisible = false; this.loginUrl = '';
      this.phase = SideloadUpdatePhase.StorageBlocked; this.clearConnectionTimer();
      this.failure = SideloadTransactionRepository.durabilityUnknown(error as Error)
        ? '更新记录的持久化结果暂不确定，已停止安装，请重新打开并核实'
        : '更新记录保存失败，已停止安装，请检查存储后重新核实';
      this.message = this.failure; this.publish(); throw error as Error;
    }
  }

  /** 冷启动只清本域固定临时文件，包括写入中断的 pending；加密保险库与用户原文件不动。 */
  private cleanInterruptedSecrets(): void {
    try {
      const tasks = this.root + '/tasks';
      if (fs.accessSync(tasks)) {
        for (const id of fs.listFileSync(tasks)) {
          if (!new RegExp('^[0-9a-f]{32}$').test(id)) continue;
          const directory = tasks + '/' + id + '/private';
          if (!fs.accessSync(directory)) continue;
          // Vault掌握固定材料名单及新pending-dir规则，不能保留另一份过时的明文清理器。
          this.signingVault().clearTemporary(directory);
        }
      }
      for (const name of fs.listFileSync(this.root)) {
        if (new RegExp('^(transaction\\.json|activity\\.json|install-fence\\.json|amcl-signing-runner\\.jar|hap-sign-tool\\.jar|connection-port\\.json)\\.[0-9a-f-]{36}\\.pending-dir$').test(name)) {
          const directory = this.root + '/' + name;
          if (fs.statSync(directory).isDirectory()) {
            const files = fs.listFileSync(directory);
            if (files.every((file: string): boolean => file === 'content.pending')) {
              const content = directory + '/content.pending'; if (fs.accessSync(content)) fs.unlinkSync(content);
              fs.rmdirSync(directory);
            }
          }
          continue;
        }
        if (!new RegExp('^key-[0-9a-f]{32}$').test(name)) continue;
        for (const file of ['result.json', 'new.p12', 'new.csr']) {
          const path = this.root + '/' + name + '/' + file;
          if (fs.accessSync(path)) fs.unlinkSync(path);
        }
      }
    } catch (_) { /* 文件暂不可访问时保留；不依据外部名称扩大清理范围。 */ }
  }

  /** 成功后清原始包与签名包，保留事务和诊断小文件；旧事务包在下次成功时一并回收。 */
  private cleanPackages(): void {
    try {
      // 成功后释放活动导入副本；预检未开始安装的副本由其页面生命周期单独管理。
      if(this.importSource!==undefined) {
        this.removeImportDirectory(this.importSource.path.substring(0,this.importSource.path.lastIndexOf('/')));
        this.importSource=undefined;
      }
      const tasks = this.root + '/tasks';
      if (!fs.accessSync(tasks)) return;
      for (const id of fs.listFileSync(tasks)) {
        if (!new RegExp('^[0-9a-f]{32}$').test(id)) continue;
        for (const name of ['unsigned.hap', 'signed.hap']) {
          const path = tasks + '/' + id + '/' + name;
          if (fs.accessSync(path)) fs.unlinkSync(path);
        }
      }
    } catch (_) { /* 清理失败不撤销已确认的安装成功，下次维护可重试。 */ }
  }

  /**
   * 显式核实只观察或撤销原执行权，不重派。未知持久化先重新可靠提交再恢复业务；
   * BMS成功还须真实已装身份，旧script protocol1保持unknown而不伪造新CAS能力。
   */
  async reconcileInstallation(allowRevoke: boolean = true): Promise<void> {
    if (this.busy || !this.foreground) return;
    if (this.storageBlocked) {
      const loaded = this.repository.load();
      if (loaded === undefined) throw new Error('更新记录缺失，请保留现场核实');
      const committed = this.repository.commit(loaded, loaded.revision ?? 0);
      this.transaction = committed; this.storageBlocked = false; this.failure = ''; this.publish();
    }
    const task = this.state();
    if (task === undefined || (!this.installationPending() && !this.fenceBlocked())) return;
    this.busy = true;
    const identity = this.executionIdentity(task);
    try {
      let proof = allowRevoke ? await this.executor.revoke(identity) : await this.executor.observe(identity);
      if (allowRevoke && !proof.safeToRelease) proof = await this.executor.observe(identity);
      if (!proof.safeToRelease || (proof.kind === 'bms-success' && task.installedIdentityVerified !== true)) {
        const next = this.state()!;
        next.error = task.installedIdentityVerified === true ? '目标版本已运行，旧安装执行权仍待核实' : proof.message;
        this.transition(SideloadUpdatePhase.ConfirmationPending, next); return;
      }
      const next = this.state()!;
      const installed = next.installedIdentityVerified === true;
      if (installed) { next.error = ''; next.confirmedAt = Date.now(); this.transition(SideloadUpdatePhase.Verified, next); }
      else {
        next.error = proof.kind === 'revoked' || proof.kind === 'pre-install-failed' ? '安装执行权已安全撤销，可重试更新' : '系统已确认本次安装失败，原应用已保留';
        next.failedPhase = task.phase; next.recoveryAction = 'retry'; this.transition(SideloadUpdatePhase.Failed, next);
      }
      // Verified/Failed已由权威平台proof保存；日志IO失败只阻断安全收尾并留可重试原件，
      // 不能经过普通fail路径改写该BMS事实。下一次核实仍消费相同执行权与固定终态。
      await this.activity.waitForFinishAsync();
      this.executor.complete(identity, proof, installed);
      try { await this.executor.cleanupPayload(identity); } catch (_) { this.record('清理待重试', '安装载荷暂未清理，已保留诊断'); }
      this.releaseInstallGates();
      if (installed) { this.cleanPackages(); AppStorage.setOrCreate<boolean>('amclSideloadUpdateCompleted', true); }
      this.confirmOnForeground = false;
    } finally {
      this.busy = false; this.executor.releaseProcessLeases(identity); await this.connection.close(); this.publish();
    }
  }

  /** 两层租约一起结束；幂等用于安装异常、新进程确认和明确失败后的重试。 */
  private releaseInstallGates(): void {
    const release = this.releaseFiles; this.releaseFiles = undefined; release?.();
  }

  /**
   * 安装内容与固定可信定位组成同一身份；镜像 ready/租约只影响传输可用性，不代表换包。
   * 官网 URL 自带摘要与文件名，旧事务缺失时不凭相同 tag/code 扩大其可信范围。
   */
  private sameAssetIdentity(left: SideloadUpdateAsset, right: SideloadUpdateAsset): boolean {
    return left.tag === right.tag && left.versionCode === right.versionCode && left.versionName === right.versionName &&
      left.product === right.product && left.name === right.name && left.sha256 === right.sha256 &&
      left.sizeBytes === right.sizeBytes && left.legacyUniversal === right.legacyUniversal &&
      left.url === right.url && left.websiteUrl === right.websiteUrl;
  }

  /** 原安装基线也是复用条件；UID、发行名或编号改变后必须重新建立事务和签名证明。 */
  private sameInstalledBaseline(task: SideloadUpdateTransaction): boolean {
    const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
    return task.beforeVersionCode === info.versionCode && task.beforeUid === info.appInfo.uid &&
      task.beforeVersionName === info.versionName;
  }

  /**
   * 签名前、各异步返回及安装 Guard 重核同一冻结目标和持久 owner；Java 只能证明原件
   * 符合 job，不能代替这里对“用户本次选择”与 job/执行事务的绑定。只抛错，不撤销 fence。
   */
  private assertTargetBinding(task: SideloadUpdateTransaction): void {
    const current = this.state(); const target = this.attemptTarget;
    if (target === undefined || !this.sameAssetIdentity(task.asset, target) ||
      current === undefined || current.id !== task.id || !this.sameAssetIdentity(current.asset, target) ||
      current.ownerAttemptId !== this.attemptId || task.ownerAttemptId !== this.attemptId ||
      !this.sameInstalledBaseline(task) || !this.sameInstalledBaseline(current) ||
      task.sameVersionTest !== this.sameVersionTest || (task.updateChannel ?? 'stable') !== this.attemptChannel) {
      throw new InstallExecutionError('preparation', '更新目标或当前安装身份已改变，请重新检查更新');
    }
  }

  /**
   * 重试关系仅是诊断元数据，不授予更新许可。调用方须明确传当前活动id，且该活动
   * 必须绑定到原持久事务的可继续阶段。当前候选还需按完整安装资产身份匹配，不能
   * 用相同标题/versionName把不同版本或同tag换包连成重试；Activity再核实失败结局。
   * 旧清单若尚无delivery摘要、需联网解析，保守省略重试关系，仍立即独立开账，
   * 不为获得可选关联延迟正常流程，也不事后改写已记录manifest。
   */
  private retryActivityForTarget(requested: number, requestedVersion: string): number {
    if (!Number.isSafeInteger(requested) || requested <= 0 || requested !== this.activity.activityId()) return 0;
    const task = this.state();
    if (task === undefined || task.activityId !== requested ||
      [SideloadUpdatePhase.Failed, SideloadUpdatePhase.Cancelled, SideloadUpdatePhase.Downloaded,
        SideloadUpdatePhase.Ready, SideloadUpdatePhase.AwaitingRestart].indexOf(task.phase) < 0 ||
      task.sameVersionTest !== this.sameVersionTest) return 0;
    let candidate = this.testAsset;
    if (candidate === undefined) {
      if (this.manifest === undefined || this.manifest.delivery === undefined) return 0;
      try { candidate = GitHubUpdateAssetResolver.fromDelivery(this.manifest, ProductBuildProfile.product); }
      catch (_) { return 0; }
    }
    const asset = task.asset;
    // 显示版本只作完整性附加核对；tag/code/product/摘要等资产身份仍须全部匹配。
    if (candidate.versionName !== requestedVersion) return 0;
    return this.sameAssetIdentity(candidate, asset) && this.sameInstalledBaseline(task) ? requested : 0;
  }

  // 以下前置授权和唯一推进器由原VM迁入；UI只观察其公开快照。
  /** 一次显式更新在首个await前开账并建立新许可；重复/忙态不另建推进器。 */
  private startWorkflow(retryOf: number = 0): void {
      if (this.working || this.finishing || this.isBusy() || this.storageBlocked) return;
      if (ProductBuildProfile.storeChannel) { this.message = '请通过应用市场更新'; return; }
      if (this.phase === SideloadUpdatePhase.Installing) { this.message = '系统正在安装，请等待应用重新打开'; return; }
      if (this.phase === SideloadUpdatePhase.ConfirmationPending) { this.reconcile(); return; }
      if (this.phase === SideloadUpdatePhase.Verified && this.testAsset === undefined &&
        (this.manifest === undefined || !UpdateChecker.canInstall(this.manifest,this.manifest.updateChannel ?? 'stable'))) return;
      // 先撤下上一轮内存候选。异步解析完成前 advance 不得凭旧 Ready/Downloaded 事务推进。
      this.attemptTarget = undefined;
      try { this.beginAttempt(this.version, true, retryOf); }
      catch (error) { this.message = (error as Error).message; return; }
      this.epoch++; this.automatic = true; this.working = true; this.needsImport = false;
      this.message = '正在核实更新版本'; this.failure = ''; this.connectionReady = false;
      this.connectionRetry = false; this.connectionAttempts = 0;
      this.accountReady = false; this.accountRetry = false; this.loginCancelled = false;
      this.needsLogin = false; this.loginReason = ''; this.clearConnectionTimer();
      const epoch = this.epoch;
      // 三条异步链独立推进；有旧证书也必须检查账号，未打开调试不影响用户先完成登录。
      this.downloadWorkflow(epoch);
      this.checkConnection();
      this.checkAccount();
    }

  /** 在线核实本轮账号，Missing/Expired转官方登录；网络故障保留凭据与重试能力。 */
  async checkAccount(): Promise<void> {
      if (!this.automatic || this.checkingAccount || this.finishing || this.loginVisible || this.loginCancelled) return;
      const epoch = this.epoch;
      this.checkingAccount = true; this.accountReady = false; this.accountRetry = false;
      this.accountMessage = '正在检查华为登录状态'; this.publish();
      try {
        const status = await this.auth.restore();
        if (!this.active(epoch)) return;
        if (status === DeveloperAuthState.Valid) {
          this.accountReady = true; this.needsLogin = false;
          this.accountMessage = '华为登录有效，将自动校验签名配置并继续更新';
        } else if (status === DeveloperAuthState.Missing || status === DeveloperAuthState.Expired) {
          this.loginReason = status === DeveloperAuthState.Expired ? '华为登录已过期，请重新登录后继续更新' :
            '尚未登录华为账号，请登录后继续更新';
          this.accountMessage = this.loginReason; this.needsLogin = true;
        } else if (status !== DeveloperAuthState.Cancelled) {
          this.accountMessage = '暂时无法核实登录状态，请稍后重试或重新登录'; this.accountRetry = true;
        }
      } catch (_) {
        if (this.active(epoch)) { this.accountMessage = '暂时无法核实华为登录状态，请重试'; this.accountRetry = true; }
      } finally { if (epoch === this.epoch) this.checkingAccount = false; }
      if (!this.active(epoch)) return;
      this.record('账号检查', this.accountMessage);
      if (this.needsLogin) await this.login();
      else if (this.accountReady) await this.advance();
    }

  /** 只为匹配本轮代次的候选排队，原件复用不复用旧活动或安装许可。 */
  private async downloadWorkflow(epoch: number): Promise<void> {
      const service = this;
      try {
        if (this.manifest === undefined) throw new Error('请返回检查更新后重试');
        // 无论是否有缓存，都先经产品解析器取得本次完整候选。解析后复制，防止外部对象
        // 在排队/账号授权期间变化；镜像健康和临时 lease 不属于安装内容身份。
        const resolved = this.testAsset ?? await GitHubUpdateAssetResolver.resolve(this.manifest, ProductBuildProfile.product);
        if (!this.active(epoch)) return;
        const asset = JSON.parse(JSON.stringify(resolved)) as SideloadUpdateAsset;
        this.attemptChannel = this.manifest.updateChannel ?? 'stable';
        const state = service.state();
        const reusable = state !== undefined && this.sameAssetIdentity(state.asset, asset) &&
          this.sameInstalledBaseline(state) && state.sameVersionTest === this.sameVersionTest &&
          (state.updateChannel ?? 'stable') === this.attemptChannel &&
          (state.phase === SideloadUpdatePhase.Downloaded || state.phase === SideloadUpdatePhase.AwaitingRestart ||
            state.phase === SideloadUpdatePhase.Ready);
        // 真实原件仍须同时符合大小与摘要；Ready 不能只凭旧签名证明跳过此处。
        const cached = reusable && state !== undefined && fs.accessSync(state.unsignedPath) &&
          fs.statSync(state.unsignedPath).size === asset.sizeBytes && await SideloadFiles.sha256(state.unsignedPath) === asset.sha256;
        if (!this.active(epoch)) return;
        if (cached && state !== undefined) {
          this.gate.assertNoGame(this.context.filesDir);
          if (this.installationPending() || this.fenceBlocked()) throw new Error('请先核实上一次安装结果');
          state.activityId = this.activity.activityId(); state.ownerAttemptId = this.attemptId;
          this.save(state);
          this.attemptTarget = asset;
          this.assertTargetBinding(state);
        } else {
          await service.download(asset, this.sameVersionTest);
        }
        if (this.active(epoch)) { this.synchronize(); await this.advance(); }
      } catch (error) {
        if (this.active(epoch)) {
          this.failure = (error as Error).message; this.message = this.failure; this.working = false; this.automatic = false;
          service.finishAttempt(this.failure, service.state()?.phase === SideloadUpdatePhase.Cancelled);
          this.phase = service.state()?.phase === SideloadUpdatePhase.Cancelled ? 'cancelled' : 'failed';
          this.invalidateLoginEffect(); this.loginBusy = false; this.loginVisible = false; this.loginUrl = ''; this.clearConnectionTimer();
          service.connection.close();
        }
      }
    }

  /** 前台有界发现/完整信任验证；旧代次结果不向新尝试写入UDID或就绪事实。 */
  async checkConnection(): Promise<void> {
      if (this.checking || this.finishing || !this.automatic || !this.foreground) return;
      const epoch = this.epoch;
      this.clearConnectionTimer();
      this.checking = true; this.connectionReady = false;
      this.connectionAttempts++;
      this.connectionMessage = '正在检查开发者调试连接，请留意系统授权提示'; this.publish();
      try {
        if (this.runtimeConnectionReset !== undefined) await this.runtimeConnectionReset;
        // 回收等待期间可再次换代/后台；新检查只在当前许可和窗口事实仍成立时启动。
        if (!this.active(epoch) || !this.foreground) return;
        this.connection.setDevicePort(this.port);
        const udid = await this.connection.check();
        if (!this.active(epoch)) return;
        this.udid = udid; this.connectionReady = true;
        this.port = String(this.connection.currentPort());
        this.connectionMessage = '开发者选项、无线调试和设备信任已通过连接验证';
        this.record('调试连接', '自动检查及设备信任验证通过');
        this.synchronize();
        await this.advance();
      } catch (error) {
        if (this.active(epoch)) {
          this.port = String(this.connection.currentPort());
          this.connectionMessage = (this.connection.discoveryMethod === 'local-discovery' ? '已自动获取端口 ' + this.port + '。' : '') + (error as Error).message;
          this.record('调试连接', this.connectionMessage);
          // 信任提示被拒绝或等待结束后不反复唤起系统授权；端口尚未发现最多自动检查三次。
          this.connectionRetry = this.connectionMessage.includes('调试提示') || this.connectionAttempts >= 3;
        }
      } finally {
        if (epoch === this.epoch) {
          this.checking = false;
          // 用户在系统弹窗允许或开启无线调试后，自动重试实际连接，无需再手动推进流程。
          if (this.active(epoch) && this.foreground && !this.connectionReady && !this.connectionRetry) {
            this.connectionTimer = setTimeout((): void => { this.connectionTimer = -1; this.checkConnection(); }, 5000);
          }
        }
      }
    }

  /** 用户明确复检启动新一组有界尝试，不重复下载。 */
  retryConnection(): void {
      if (this.checking) return;
      if (this.runtimeConnectionResetFailed) this.resetRuntimeConnection();
      this.connectionRetry = false; this.connectionAttempts = 0; this.checkConnection();
    }

  /** 仅打开公开系统设置入口，helper往返保留Attempt，不读/代改安全开关。 */
  async openDebugSettings(): Promise<void> {
      if (this.context === undefined || this.finishing) return;
      this.connectionReady = false;
      this.connectionRetry = false; this.connectionAttempts = 0;
      this.connectionMessage = '请在开发者选项中开启无线调试，返回 AMCL 后会自动检查并继续';
      for (const uri of ['system_wireless_commissioning:', 'system_and_updates:', 'settings:']) {
        try {
          await this.context.startAbility({ bundleName: 'com.huawei.hmos.settings',
            abilityName: 'com.huawei.hmos.settings.MainAbility', uri: uri });
          return;
        } catch (_) { /* 深链不可用时只回退公开设置入口，不修改任何系统开关。 */ }
      }
      this.connectionMessage = '无法直接打开设置，请手动进入“设置 → 系统 → 开发者选项”开启无线调试';
    }

  /** 每轮最多一个连接复检timer；后台、取消及旧绑定回收都解除。 */
  private clearConnectionTimer(): void {
      if (this.connectionTimer >= 0) clearTimeout(this.connectionTimer);
      this.connectionTimer = -1;
    }

  /**
   * 官方登录effect捕获独立会话对象和代次。同Attempt关闭/重开与Runtime重绑都会退役旧effect；
   * 旧begin返回不再通过this.auth getter清理，避免把新会话当成旧会话关闭。
   */
  async login(): Promise<void> {
      if (this.loginBusy || this.finishing || !this.automatic) return;
      const epoch = this.epoch;
      this.invalidateLoginEffect();
      const effect = this.loginEffectGeneration;
      this.loginCancelled = false; this.accountReady = false;
      this.needsLogin = true;
      if (!this.loginReason) this.loginReason = '请登录华为账号以继续更新';
      this.accountMessage = this.loginReason;
      this.loginBusy = true; this.loginVisible = true; this.loginUrl = '';
      this.loginMessage = '正在建立安全登录会话…'; this.publish();
      let capturedAuth: DeveloperAuthSession | undefined = undefined;
      try {
        // 私有登录目录初始化也可能失败，仍进入本effect的固定错误投影，不让异常穿出命令入口。
        const auth = this.auth;
        capturedAuth = auth;
        const url = await auth.begin((success: boolean, message: string): void => {
          if (!this.loginEffectCurrent(epoch, effect, auth)) return;
          // 消费终态一次。成功保留已验证的captured Auth供签名使用；失败关闭本对象并允许显式重登。
          this.loginEffectGeneration++;
          if (!success) { auth.close(); this.authSession = undefined; }
          this.loginMessage = message;
          this.loginBusy = false; this.loginVisible = !success; this.loginUrl = '';
          this.needsLogin = !success;
          this.accountReady = success && auth.signedIn(); if (this.accountReady) this.accountRetry = false;
          this.accountMessage = success ? '华为登录已验证，正在准备签名证书' : message;
          this.record('华为授权', this.accountMessage);
          if (success) this.advance();
        });
        if (!this.loginEffectCurrent(epoch, effect, auth)) return;
        this.loginUrl = url; this.loginVisible = true; this.loginMessage = '登录成功后将自动返回并继续更新'; this.publish();
      } catch (_) {
        if (this.loginEffectCurrent(epoch, effect, capturedAuth)) {
          this.invalidateLoginEffect();
          this.loginBusy = false; this.loginVisible = true; this.loginUrl = '';
          this.loginMessage = '无法打开华为授权页面，请检查网络后重试'; this.accountMessage = this.loginMessage; this.publish();
        }
      }
    }

  /** 用户关闭登录只取消此AuthSession，原件下载仍保留，整轮安装等待新的授权。 */
  closeLogin(): void {
      this.invalidateLoginEffect(); this.loginBusy = false; this.loginVisible = false; this.loginUrl = ''; this.needsLogin = true;
      this.accountReady = false; this.loginCancelled = true;
      this.accountMessage = '授权已取消，下载完成后将等待你继续';
      this.record('华为授权', this.accountMessage);
    }

  /** 当前主文档失败撤销旧授权，保留本轮和可恢复Sheet，错误正文不含Token。 */
  loginFailed(message: string): void {
      this.invalidateLoginEffect(); this.loginBusy = false; this.loginUrl = ''; this.loginMessage = message;
      this.needsLogin = true; this.accountReady = false; this.loginVisible = true;
      this.record('华为授权', message);
    }

  /** 只清已经拥有的旧对象，不使用getter初始化新会话；调用处同步撤销旧effect后才允许重开。 */
  private invalidateLoginEffect(): void {
    this.loginEffectGeneration++;
    const previous = this.authSession;
    this.authSession = undefined;
    previous?.close();
  }
  /** begin URL、交换回调、异常都必须同时匹配Attempt代次、登录effect及会话对象。 */
  private loginEffectCurrent(epoch: number, effect: number, auth: DeveloperAuthSession | undefined): boolean {
    return this.active(epoch) && effect === this.loginEffectGeneration && this.authSession === auth;
  }

  /** 唯一签名/安装pump；锁归finishingEpoch，await后再次核许可、前台和目标。 */
  private async advance(): Promise<void> {
      const service = this;
      if (!this.automatic || this.attemptTarget === undefined || this.finishing || !this.foreground || !this.hasPresentation() || this.loginVisible || this.loginCancelled ||
        !this.connectionReady || service === undefined || service.isBusy()) return;
      const phase = service.state()?.phase;
      if (phase !== SideloadUpdatePhase.Downloaded && phase !== SideloadUpdatePhase.AwaitingRestart && phase !== SideloadUpdatePhase.Ready) return;
      // Unavailable等待用户显式重检；进度/订阅publish不能形成无界账号轮询。
      if (!this.accountReady && this.accountRetry) return;
      // 无论是否保存过签名配置，都不能绕过本轮登录核实；长下载期间过期也会自动重新核实/登录。
      if (!this.accountReady || !this.auth.signedIn()) { await this.checkAccount(); return; }
      this.finishing = true; this.finishingEpoch = this.epoch; this.publish();
      const epoch = this.epoch;
      let waitForLogin: boolean = false;
      let waitForForeground: boolean = false;
      try {
        if (!service.materialAvailable()) {
          this.accountMessage = '正在获取当前应用的签名证书';
          await service.prepareMaterial(this.auth, this.udid);
          if (!this.active(epoch)) return;
          this.synchronize();
        }
      if (phase === SideloadUpdatePhase.Ready && !(await this.signatureFresh())) this.transition(SideloadUpdatePhase.Downloaded);
      if (this.state()?.phase !== SideloadUpdatePhase.Ready) await service.signPrepared();
        if (!this.active(epoch)) return;
        if (!this.foreground) { waitForForeground = true; this.message = '安装包已准备好，返回 AMCL 后继续'; return; }
      await service.install(epoch);
      } catch (error) {
        if (this.active(epoch)) {
          if (service.state()?.phase === SideloadUpdatePhase.Installing || service.state()?.phase === SideloadUpdatePhase.ConfirmationPending) {
            this.failure = ''; this.message = '安装已派发，等待应用重新打开确认';
            service.record('等待安装确认', '调试连接已结束，保留待确认状态');
          } else if (error instanceof InstallExecutionError && error.kind === 'foreground') {
            waitForForeground = true; this.message = '已暂停安装，返回 AMCL 后继续';
          } else if (DeveloperAuthSession.isExpired(error as Error)) {
            waitForLogin = true; this.accountReady = false; this.needsLogin = true;
            this.loginReason = '华为登录已过期，请重新登录后继续更新'; this.accountMessage = this.loginReason;
          } else {
            this.failure = (error as Error).message; this.message = this.failure;
            service.finishAttempt(this.failure);
            this.needsImport = service.state()?.recoveryAction !== 'runtime' &&
              (!service.materialAvailable() || service.state()?.recoveryAction === 'material');
            this.accountMessage = this.needsImport ? this.message : this.accountMessage;
          }
        }
      } finally {
        // 已取消的一轮仍须释放推进锁，否则下一次重试会永久被finishing拦住。
        if (this.finishingEpoch === epoch) { this.finishing = false; this.finishingEpoch = -1; }
        if (epoch === this.epoch && !waitForLogin && !waitForForeground) {
          this.working = false; this.automatic = false; this.publish();
          this.clearConnectionTimer();
          if (this.phase !== SideloadUpdatePhase.Installing) service.connection.close();
        }
      }
      this.publish();
      if (waitForLogin && this.active(epoch)) await this.login();
    }

  /** 用户明确换材才退役加密旧材料，并通过完整账号/连接/候选流程重试。 */
  renewAndContinue(): void {
      if (this.finishing || this.isBusy() || this.storageBlocked) return;
      try { this.renewMaterial(); this.startWorkflow(this.activity.activityId()); }
      catch (_) { this.message = '无法更新签名配置，请尝试导入原配置'; }
    }

  /** UI核实命令只观察/撤销旧执行权，不调用第二次安装；失败继续保留保护。 */
  async reconcile(): Promise<void> {
      const epoch = this.epoch;
      if (this.finishing) return;
      this.finishing = true; this.finishingEpoch = this.epoch; this.publish();
      try { await this.reconcileInstallation(); this.failure = ''; }
      catch (_) { this.failure = '暂未取得安装回执，请检查无线调试或重新打开 AMCL 后再核实'; this.message = this.failure; }
      finally { if (this.finishingEpoch === epoch) { this.finishing = false; this.finishingEpoch = -1; } this.publish(); }
    }

  /** Promise结果仅能提交给仍获许可且代次相同的Attempt。 */
  private active(epoch: number): boolean { return this.automatic && epoch === this.epoch; }

  /** 显式绑定当前Context；同files域的Ability重建沿用业务状态，旧事件用generation拒绝。 */
  bindRuntime(context: common.UIAbilityContext): number {
    if (context.filesDir !== this.context.filesDir) throw new Error('更新运行环境存储身份不一致');
    if (context !== this.context) {
      this.context = context; this.runtimeGeneration++; this.epoch++;
      this.presentations.clear(); this.foreground = false; this.windowInteractive = false; this.gate.setForeground(false);
      this.checking = false; this.checkingAccount = false; this.connectionReady = false; this.accountReady = false;
      this.connectionRetry = false; this.connectionAttempts = 0;
      this.connectionMessage = '运行环境已重新绑定，等待核实当前调试连接';
      this.accountMessage = '运行环境已重新绑定，等待重新核实华为登录';
      this.clearConnectionTimer(); this.invalidateLoginEffect();
      this.loginBusy = false; this.loginVisible = false; this.loginUrl = ''; this.loginCancelled = false;
      try { this.vault = new SigningVault(context); } catch (_) { this.storageBlocked = true; }
      this.resetRuntimeConnection();
      // 立即通知旧投影退役；旧UI不能等到下一次登录成功才发现自己不再有展示/写命令归属。
      this.publish();
      // 候选解析/原件散列尚未完成时没有可推进的 attemptTarget。Runtime 换代会使旧 await
      // 返回失去写权，必须按新 epoch 重做这段只读核验；继续使用原 Attempt/清单副本，
      // 不重新开账、不从旧 transaction 补造已核实目标，也不重开下载/签名/安装 effect。
      if (this.automatic && this.working && this.attemptTarget === undefined && !this.isBusy() &&
        !this.storageBlocked && !this.installationPending()) this.downloadWorkflow(this.epoch);
    }
    return this.runtimeGeneration;
  }
  runtime(): number { return this.runtimeGeneration; }
  /** 串行回收跨Runtime连接；错误保留给check投影，只有显式重检或新绑定再试，不产生未处理拒绝。 */
  private resetRuntimeConnection(): void {
    const previous = this.runtimeConnectionReset;
    const reset = (previous ?? Promise.resolve()).catch((): void => {}).then((): Promise<void> => this.connection.close());
    this.runtimeConnectionReset = reset; this.runtimeConnectionResetFailed = false;
    reset.catch((): void => { if (this.runtimeConnectionReset === reset) this.runtimeConnectionResetFailed = true; });
  }
  /** Ability是实际前后台事实源，窗口ACTIVE只能更新交互性，不能单独绕过后台。 */
  setAbilityForeground(value: boolean): void {
    this.abilityForeground = value; this.setForeground(this.windowInteractive, this.runtimeGeneration);
    if (value && this.confirmOnForeground && !this.busy) this.reconcileInstallation().catch((): void => {});
  }
  /** UI端口输入只改变本轮待验证值，网络连接仍经SideloadConnection严格校验。 */
  setPort(value: string): void { this.port = value; }

  attachPresentation(id: string): void { this.presentations.set(id, true); this.gate.setForeground(this.foreground); }
  detachPresentation(id: string): void { this.presentations.delete(id); this.gate.setForeground(this.foreground && this.hasPresentation()); }
  /** 写命令与窗口事实必须来自当前Runtime下仍挂载的专属展示面，UUID不充当永久许可。 */
  ownsPresentation(id: string, generation: number): boolean {
    return generation === this.runtimeGeneration && this.presentations.has(id);
  }
  private hasPresentation(): boolean { return this.presentations.size > 0; }
  private installationPending(): boolean {
    const p = this.transaction?.phase;
    return p === SideloadUpdatePhase.Installing || p === SideloadUpdatePhase.ConfirmationPending || p === SideloadUpdatePhase.DispatchIntent;
  }
  /** 开始命令只有一个Owner；忙态附着当前快照而非另建VM推进器。 */
  requestUpdate(params: SideloadUpdatePageParams, retryOf: number = 0): string {
    if (this.storageBlocked || this.installationPending() || this.fenceBlocked()) { this.reconcile(); this.publish(); return 'reconciling'; }
    if (this.working || this.finishing || this.isBusy()) return 'attached';
    if(params.importToken!==undefined) {
      const imported=this.preparedImport?.token===params.importToken ? this.preparedImport : this.importSource;
      if(imported===undefined || imported.token!==params.importToken || params.manifest===undefined ||
        UpdateChecker.targetKey(imported.manifest,ProductBuildProfile.product)!==UpdateChecker.targetKey(params.manifest,ProductBuildProfile.product)) return 'rejected';
      this.importSource=imported;this.preparedImport=undefined;
      params={manifest:JSON.parse(JSON.stringify(imported.manifest)) as UpdateManifest,autoStart:true};
    } else {
      if(this.importSource!==undefined) this.removeImportDirectory(this.importSource.path.substring(0,this.importSource.path.lastIndexOf('/')));
      this.importSource=undefined;
    }
    this.diagnosticAttempt = false; this.testAsset = undefined; this.sameVersionTest = false;
    // 路由只提供值快照，后续修改调用方的 manifest 不能改变本轮通道或资产来源。
    this.manifest = params.manifest === undefined ? undefined : JSON.parse(JSON.stringify(params.manifest)) as UpdateManifest;
    if (ProductBuildProfile.product === 'default' && DiagnosticPolicy.hasTestHooks() && params.testAsset !== undefined && SideloadUpdateTestSession.allowedAssetUrl(params.testAsset.url) &&
      (!params.testAsset.url.startsWith('http://') || SideloadFixtureHttp.registered(params.testAsset.url))) {
      this.testAsset = params.testAsset; this.sameVersionTest = params.sameVersionTest === true;
    }
    this.version = params.manifest?.versionName ?? this.transaction?.asset.versionName ?? '';
    this.startWorkflow(retryOf); this.publish(); return this.working ? 'started' : 'rejected';
  }
  requestCancel(id: string): boolean {
    if (id.length > 0 && id !== this.attemptId) return false;
    if (this.installationPending()) return false;
    this.cancel(); return true;
  }
  /** Snapshot永不导出密钥/Token/UDID/nonce，也不把内部对象引用交给外部写入。 */
  snapshot(): SideloadUpdateSnapshot {
    this.synchronize(); const value = new SideloadUpdateSnapshot();
    value.revision = this.snapshotRevision; value.attemptId = this.attemptId; value.runtimeGeneration = this.runtimeGeneration;
    value.bytesDone = this.downloadView()?.bytesDone ?? this.bytesDone;
    value.bytesTotal = this.downloadView()?.bytesTotal ?? this.bytesTotal;
    value.speedBps = this.downloadView()?.speedBps ?? this.speedBps;
    value.message = this.message;
    value.version = this.version;
    value.phase = this.phase;
    value.materialReady = this.materialReady;
    value.working = this.working;
    value.finishing = this.finishing;
    value.checking = this.checking;
    value.connectionReady = this.connectionReady;
    value.connectionRetry = this.connectionRetry;
    value.connectionMessage = this.connectionMessage;
    value.accountMessage = this.accountMessage;
    value.accountReady = this.accountReady;
    value.checkingAccount = this.checkingAccount;
    value.accountRetry = this.accountRetry;
    value.loginVisible = this.loginVisible;
    value.loginUrl = this.loginUrl;
    value.loginMessage = this.loginMessage;
    value.loginBusy = this.loginBusy;
    value.loginReason = this.loginReason;
    value.needsLogin = this.needsLogin;
    value.needsImport = this.needsImport;
    value.port = this.port;
    value.progress = this.progress;
    value.transfer = this.transfer;
    value.failedPhase = this.failedPhase;
    value.recoveryAction = this.recoveryAction;
    value.activityId = this.currentActivityId;
    value.downloadTaskId = this.currentDownloadTaskId;
    value.downloadState = this.downloadState;
    return value;
  }
  private publish(): void {
    this.snapshotRevision++; const value = this.snapshot();
    const attention = this.needsAttention();
    if (attention !== this.attentionPublished) {
      this.attentionPublished = attention;
      const revision = AppStorage.get<number>('amclSideloadUpdateAttentionRevision') ?? 0;
      AppStorage.setOrCreate<number>('amclSideloadUpdateAttentionRevision', revision + 1);
    }
    if (this.automatic && !this.pumpScheduled && !this.finishing && !this.isBusy() && !this.storageBlocked) {
      this.pumpScheduled = true;
      Promise.resolve().then((): void => { this.pumpScheduled = false; this.advance(); });
    }
    this.listeners.forEach((listener: (snapshot: SideloadUpdateSnapshot) => void): void => { try { listener(JSON.parse(JSON.stringify(value)) as SideloadUpdateSnapshot); } catch (_) { /* 单个失效UI不能阻断提交或其他观察者。 */ } });
  }
  private synchronize(): void {
    this.materialReady = this.materialAvailable(); const transaction = this.transaction;
    if (this.storageBlocked) { this.phase = SideloadUpdatePhase.StorageBlocked; this.message = this.failure || this.message; }
    if (!this.storageBlocked && transaction !== undefined && (this.attemptId.length === 0 || transaction.ownerAttemptId === this.attemptId)) {
      this.phase = transaction.phase; this.failedPhase = transaction.failedPhase ?? ''; this.recoveryAction = transaction.recoveryAction ?? '';
      if (this.failure) this.message = this.failure;
      else if (transaction.error) this.message = transaction.error;
      else if (transaction.phase === SideloadUpdatePhase.Verified) this.message = '更新完成，已运行新版本';
      else if (this.operation) this.message = this.operation;
    } else if (this.operation && !this.failure) this.message = this.operation;
    const download = this.downloadView(); this.currentActivityId = this.activity.activityId(); this.currentDownloadTaskId = download?.id ?? '';
    this.downloadState = download?.state ?? ''; const total = download?.bytesTotal ?? this.bytesTotal;
    const done = download?.bytesDone ?? this.bytesDone; const speed = download?.speedBps ?? this.speedBps;
    this.progress = download?.progress ?? (total > 0 ? Math.min(100, done * 100 / total) : 0);
    this.transfer = total > 0 ? formatBytes(done) + ' / ' + formatBytes(total) : '';
    if (speed > 0) this.transfer += ' · ' + formatBytes(speed) + '/s';
    if (!this.storageBlocked && !this.installEffectActive && transaction !== undefined && transaction.phase !== SideloadUpdatePhase.Installing && transaction.phase !== SideloadUpdatePhase.DispatchIntent && transaction.phase !== SideloadUpdatePhase.ConfirmationPending && this.fenceBlocked()) { this.phase = SideloadUpdatePhase.ConfirmationPending; this.message = transaction.error || '安装执行权仍待核实，请查看更新状态'; }
    if (download?.state === 'waiting') this.message = '更新包排队中 · 前方还有 ' + Math.max(0, download.queuePosition - 1) + ' 个任务';
  }

  /** 只消费当前picker选择的URI，文件大小限制和加密在域层，正文不出现在UI/日志。 */
  async importPickedMaterial(uri: string): Promise<void> {
    if (this.finishing || this.isBusy() || this.installationPending()) return;
    const epoch = this.epoch; const owner = this.attemptId; this.busy = true;
    let file: fs.File | undefined = undefined; let imported = false;
    try {
      file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      if (fs.statSync(file.fd).size > 64 * 1024) throw new Error('签名配置文件过大');
      await this.signingVault().importBundle(fs.readTextSync(uri), (): void => { this.assertEffect(epoch, owner); });
      this.assertEffect(epoch, owner); this.needsImport = false; imported = true;
    } catch (_) {
      if (epoch === this.epoch && owner === this.attemptId) this.message = '签名配置导入失败，请检查原安装工具导出的配置';
    } finally {
      if (file !== undefined) fs.closeSync(file);
      this.busy = false;
      const current = this.state();
      if (this.cancelled && !this.storageBlocked && current?.ownerAttemptId === owner && owner === this.attemptId) this.transition(SideloadUpdatePhase.Cancelled, current);
      this.publish();
    }
    if (imported && epoch === this.epoch && owner === this.attemptId) {
      if (this.automatic) await this.advance(); else this.startWorkflow(this.activity.activityId());
    }
  }

  /** 仅由可信已提交事务构造Executor输入，不使用UI、网页或用户材料的任意字段。 */
  private executionIdentity(task: SideloadUpdateTransaction): InstallExecutionIdentity {
    return { installId: task.installId ?? task.id, ownerAttemptId: task.ownerAttemptId ?? task.id,
      nonce: task.restartNonce, bundleName: 'com.amcl.launcher', product: task.asset.product,
      beforeVersionCode: task.beforeVersionCode, beforeUid: task.beforeUid, versionCode: task.asset.versionCode,
      expectedPayloadIdentity: task.expectedPayloadIdentity, signedPath: task.signedPath, signedSha256: task.signedSha256,
      protocol: task.installProtocol ?? 1, legacyTransactionId: task.id };
  }
  /** 签名器证明按真实时间/材料修订检查；时钟回拨与材料变化都回到重签。 */
  private async signatureFresh(): Promise<boolean> {
    const task = this.state(); if (task === undefined) return false;
    if (!this.signatureTimeValid(task)) return false;
    if (!Number.isFinite(task.signatureValidFrom) || !Number.isFinite(task.signatureValidUntil) || !Number.isFinite(task.signatureVerifiedAt) ||
      !task.materialRevision) return false;
    try { return await this.signingVault().materialRevision() === task.materialRevision; } catch (_) { return false; }
  }
  /** 没有新清单也必须提供恢复入口，不能让已装latest但未知执行权的用户无处核实。 */
  needsAttention(): boolean { return !(this.confirmOnForeground && this.busy) && (this.storageBlocked || this.installationPending() || this.fenceBlocked()); }

  /** 平台创建失败只保留保护状态，UI快照不能因为Vault不可用再抛启动异常。 */
  private signingVault(): SigningVault {
    if (this.vault === undefined) throw new InstallExecutionError('storage', '签名存储暂不可用，请检查存储后核实');
    return this.vault;
  }
  /** 读取保护记录异常按blocked处理，绝不能变成“没有fence”。 */
  private fenceBlocked(): boolean { try { return new InstallFence(this.context.filesDir).blocked(); } catch (_) { return true; } }
  /** 旧runtime/Attempt异步结果只能清理自己的资源，不能提交签名或材料到新绑定。 */
  private assertEffect(epoch: number, owner: string): void {
    this.assertActive();
    if (epoch !== this.epoch || owner !== this.attemptId) throw new InstallExecutionError('stale-effect', '更新运行环境已改变，请等待当前资源收尾');
  }

  /** 同步派发checkpoint也检查时间窗，上传或HUKS核实期间过期不得发起bm。 */
  private signatureTimeValid(task: SideloadUpdateTransaction): boolean {
    const now = Date.now(); const from = task.signatureValidFrom ?? NaN;
    const until = task.signatureValidUntil ?? NaN; const verified = task.signatureVerifiedAt ?? NaN;
    return Number.isFinite(from) && Number.isFinite(until) && Number.isFinite(verified) && now >= from && now >= verified && now < until;
  }
}
