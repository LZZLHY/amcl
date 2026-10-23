/**
 * ArkUI V1自更新展示投影。此类不再拥有Auth、timer、事务或签名/安装推进器。
 * 每次订阅有自己的解除函数；框架卸载只detach，用户明确退出通过cancel撤销指定Attempt。
 */
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { SideloadUpdateCoordinator } from './SideloadUpdateCoordinator';
import { SideloadUpdateSnapshot } from './SideloadUpdateSnapshot';
import { SideloadUpdatePageParams } from './SideloadUpdateTestSession';
export { SideloadUpdatePageParams } from './SideloadUpdateTestSession';

@Observed
export class SideloadUpdateViewModel {
  message: string = '正在准备更新';
  version: string = '';
  phase: string = 'idle';
  materialReady: boolean = false;
  working: boolean = false;
  finishing: boolean = false;
  checking: boolean = false;
  connectionReady: boolean = false;
  connectionRetry: boolean = false;
  connectionMessage: string = '等待检查开发者选项和无线调试';
  accountMessage: string = '等待检查华为登录状态';
  accountReady: boolean = false;
  checkingAccount: boolean = false;
  accountRetry: boolean = false;
  loginVisible: boolean = false;
  loginUrl: string = '';
  loginMessage: string = '';
  loginBusy: boolean = false;
  loginReason: string = '';
  needsLogin: boolean = false;
  needsImport: boolean = false;
  port: string = '10178';
  progress: number = 0;
  transfer: string = '';
  failedPhase: string = '';
  recoveryAction: string = '';
  activityId: number = 0;
  downloadTaskId: string = '';
  downloadState: string = '';
  /** 真正Ability换代使本投影退役。它是展示状态，不能从新快照无条件继承许可或窗口事实。 */
  runtimeRetired: boolean = false;
  private coordinator: SideloadUpdateCoordinator | undefined = undefined;
  private context: common.UIAbilityContext | undefined = undefined;
  private params: SideloadUpdatePageParams = {};
  private subscription: (() => void) | undefined = undefined;
  private surfaceId: string = '';
  private attemptId: string = '';
  private runtimeGeneration: number = 0;
  private autoStart: boolean = false;
  private disposed: boolean = false;

  /** 挂载只绑定和订阅，不创建任务、不执行恢复或账号检查。 */
  initialize(context: common.UIAbilityContext, params: SideloadUpdatePageParams): void {
    this.context = context; this.params = params; this.autoStart = params.autoStart === true;
    // 将原UI Context交给唯一工厂先验证files域，再使用权威Entry Context规范化，不能在此跳过调用方校验。
    this.surfaceId = util.generateRandomUUID(); this.coordinator = SideloadUpdateCoordinator.get(context);
    this.runtimeGeneration = this.coordinator.runtime();
    this.coordinator.attachPresentation(this.surfaceId);
    this.subscription = this.coordinator.subscribe((value: SideloadUpdateSnapshot): void => { if (!this.disposed) this.apply(value); });
  }
  /** 首次“立即更新”是新请求，不因快照里有旧失败/SUCCESS就伪装成重试；参数只消费一次。 */
  onShown(): void { if (this.autoStart) { this.autoStart = false; this.ownedCoordinator()?.requestUpdate(this.params); } }
  onForeground(): void { this.ownedCoordinator()?.setForeground(true, this.runtimeGeneration); }
  onBackground(): void { this.ownedCoordinator()?.setForeground(false, this.runtimeGeneration); }
  private apply(value: SideloadUpdateSnapshot): void {
    if (value.runtimeGeneration !== this.runtimeGeneration) { this.retireRuntime(); return; }
    this.attemptId = value.attemptId;
    this.message = value.message;
    this.version = value.version;
    this.phase = value.phase;
    this.materialReady = value.materialReady;
    this.working = value.working;
    this.finishing = value.finishing;
    this.checking = value.checking;
    this.connectionReady = value.connectionReady;
    this.connectionRetry = value.connectionRetry;
    this.connectionMessage = value.connectionMessage;
    this.accountMessage = value.accountMessage;
    this.accountReady = value.accountReady;
    this.checkingAccount = value.checkingAccount;
    this.accountRetry = value.accountRetry;
    this.loginVisible = value.loginVisible;
    this.loginUrl = value.loginUrl;
    this.loginMessage = value.loginMessage;
    this.loginBusy = value.loginBusy;
    this.loginReason = value.loginReason;
    this.needsLogin = value.needsLogin;
    this.needsImport = value.needsImport;
    this.port = value.port;
    this.progress = value.progress;
    this.transfer = value.transfer;
    this.failedPhase = value.failedPhase;
    this.recoveryAction = value.recoveryAction;
    this.activityId = value.activityId;
    this.downloadTaskId = value.downloadTaskId;
    this.downloadState = value.downloadState;
  }
  /** 用户点击“重试更新”才提交当前原活动提示；Core继续核实持久目标和终态，UI不能单独决定关系。 */
  start(): void { this.ownedCoordinator()?.requestUpdate(this.params, this.activityId); }
  checkAccount(): void { this.ownedCoordinator()?.checkAccount(); }
  checkConnection(): void { this.ownedCoordinator()?.checkConnection(); }
  /** 手动端口先提交给当前owner，再以View实际查询的窗口事实重新合成门禁，避免自动复检抢用旧输入。 */
  retryConnection(windowInteractive?: boolean): void {
    const owner = this.ownedCoordinator(); if (owner === undefined) return;
    owner.setPort(this.port);
    if (windowInteractive !== undefined) owner.setForeground(windowInteractive, this.runtimeGeneration);
    owner.retryConnection();
  }
  openDebugSettings(): void { this.ownedCoordinator()?.openDebugSettings(); }
  login(): void { this.ownedCoordinator()?.login(); }
  closeLogin(): void { this.ownedCoordinator()?.closeLogin(); }
  loginFailed(message: string): void { this.ownedCoordinator()?.loginFailed(message); }
  renewMaterial(): void { this.ownedCoordinator()?.renewAndContinue(); }
  reconcile(): void { this.ownedCoordinator()?.reconcile(); }
  /** 系统picker由当前UIContext打开；私有读取/加密和后续更新仍由域所有者执行。 */
  async importMaterial(): Promise<void> {
    const owner = this.ownedCoordinator();
    if (this.context === undefined || owner === undefined || this.finishing) return;
    try {
      const document = new picker.DocumentViewPicker(this.context);
      const uris = await document.select({ maxSelectNumber: 1, fileSuffixFilters: ['签名配置|.json'] });
      if (uris.length > 0 && this.ownedCoordinator() === owner) await owner.importPickedMaterial(uris[0]);
    } catch (_) { if (this.ownedCoordinator() === owner) this.message = '签名配置选择失败，请重新选择原安装工具导出的配置'; }
  }
  /** 用户命令绑定当前Attempt，过时视图没有取消新轮的权限。 */
  cancel(): void { this.ownedCoordinator()?.requestCancel(this.attemptId); }
  /** 一处守卫覆盖全部写命令，包括迟到Web错误、picker结果与旧面板退出，不只保护foreground。 */
  private ownedCoordinator(): SideloadUpdateCoordinator | undefined {
    if (this.disposed || this.runtimeRetired || this.coordinator === undefined) return undefined;
    if (!this.coordinator.ownsPresentation(this.surfaceId, this.runtimeGeneration)) { this.retireRuntime(); return undefined; }
    return this.coordinator;
  }
  /** 旧快照停止订阅且明确显示重开出口；业务Attempt保留，由新真实展示面重新核实后继续。 */
  private retireRuntime(): void {
    if (this.runtimeRetired || this.disposed) return;
    this.runtimeRetired = true; this.subscription?.(); this.subscription = undefined;
    this.coordinator?.detachPresentation(this.surfaceId);
    this.working = false; this.finishing = false; this.checking = false; this.checkingAccount = false;
    this.loginVisible = false; this.loginBusy = false; this.loginUrl = ''; this.accountReady = false; this.connectionReady = false;
    this.needsLogin = false; this.needsImport = false; this.accountRetry = false; this.connectionRetry = false;
    this.message = '此更新界面已失效，请关闭后重新打开更新';
    this.accountMessage = '请在当前更新界面重新核实登录'; this.connectionMessage = '请在当前更新界面重新核实调试连接';
  }
  /** 解除本组件自己的资源；不清共享订阅，不把系统后台/框架卸载误当用户cancel。 */
  dispose(): void {
    if (this.disposed) return;
    this.disposed = true; this.subscription?.(); this.subscription = undefined;
    this.coordinator?.detachPresentation(this.surfaceId); this.coordinator = undefined;
  }
}
