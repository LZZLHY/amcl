/**
 * 更新准备失败的普通状态图标使用错误前景色，配合现有中性容器保证深色可读；
 * 只调整此单个图标，不改变Coordinator状态、安装确认或原有实色按钮。
 */
import { applyNativeTheme } from './AppTheme';
/**
 * R3 自更新弹窗内容：固定标题、版本对照、单一滚动中段和固定页脚，填满父容器给定的尺寸。
 * 登录回调、调试准备、下载、签名和安装仍由唯一 Coordinator 连续推进，ViewModel 仅投影。
 * 本组件只改变显示层级和命令入口，不产生第二份下载进度、安装许可或更新尝试。
 */
import { DeveloperLoginContent, developerLoginSheetOptions } from './DeveloperLoginContent';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { ThemeColors, ThemeMode, resolveTheme, resolveIsDark, APP_VERSION, DistributionPolicy } from 'commons';
import { LauncherSkillBus } from '../launcherskill/LauncherSkillBus';
import { SettingsSkillData, settingKeys, settingText, settingFailure } from '../launcherskill/SettingsSkillValues';
import { PreferenceManager } from 'feature_system';
import { SideloadUpdateViewModel, SideloadUpdatePageParams } from '../sideload/SideloadUpdateViewModel';

@Component
export struct SideloadUpdateContent {
  /** 与账号登录共用全局高度、宽度和居中规则；宽度读取主窗口，不能使用弹窗内部宽度。 */
  @StorageProp('phoneSheetHeightPercent') private phoneSheetHeightPercent_: number = 80;
  params: SideloadUpdatePageParams = {};
  /** 以下字段仅展示发行身份；不参与候选校验，也不覆盖 Coordinator 的真实目标版本。 */
  currentVersion: string = '';
  sizeLabel: string = '';
  releaseDate: string = '';
  /** 小窗口由父级几何统一决定紧凑排版，阶段切换不能自行改变外框或页脚基线。 */
  @Prop compact: boolean = false;
  onDismiss: () => void = (): void => {};
  /** 兼容路由和父controller复用本组件的显式退出协议，系统Back不能仅卸载观察者。 */
  onExitGuardReady: (exit: () => boolean) => void = (): void => {};
  @State @Watch('syncKeepScreenOn') viewModel: SideloadUpdateViewModel = new SideloadUpdateViewModel();
  @State theme: ThemeColors = resolveTheme(ThemeMode.SYSTEM, false);
  @State manualPort: boolean = false;
  @State detailsVisible: boolean = false;
  @StorageProp('screenHeightVp') screenHeight: number = 800;
  @StorageProp('screenWidthVp') screenWidth: number = 360;
  @StorageProp('topRectHeight') topSafe: number = 0;
  @StorageProp('bottomRectHeight') bottomSafe: number = 0;
  @StorageProp('currentColorMode') @Watch('applyTheme') colorMode: number = 0;
  /** 同进程主题确认后重建本页快照；不触发业务重载、偏好写入或新的窗口订阅。 */
  @StorageProp('appThemeRevision') @Watch('applyTheme') private appThemeRevision: number = 0;
  private stage: window.WindowStage | undefined = undefined;
  private appWindow: window.Window | undefined = undefined;
  private previousKeepScreenOn: boolean = false;
  private requestedKeepScreenOn: boolean = false;
  private initialized: boolean = false;
  private stagePaused: boolean = false;
  private factsTimer: number = -1;

  /** API20有序Stage生命周期只表示可见/可交互；焦点由实际主Window事件和查询补齐。 */
  private stageListener = (event: window.WindowStageLifecycleEventType): void => {
    if (event === window.WindowStageLifecycleEventType.RESUMED) {
      this.stagePaused = false; this.refreshWindowFacts();
    } else if (event === window.WindowStageLifecycleEventType.PAUSED || event === window.WindowStageLifecycleEventType.HIDDEN) {
      this.stagePaused = true; this.viewModel.onBackground();
    } else if (event === window.WindowStageLifecycleEventType.SHOWN) this.refreshWindowFacts();
  };
  /** Stage可交互不等于主窗口已获焦；失焦立即关门，获焦再采样，按钮不代替系统事实。 */
  private windowListener = (event: window.WindowEventType): void => {
    if (event === window.WindowEventType.WINDOW_ACTIVE || event === window.WindowEventType.WINDOW_SHOWN) this.refreshWindowFacts();
    else if (event === window.WindowEventType.WINDOW_INACTIVE || event === window.WindowEventType.WINDOW_HIDDEN) this.viewModel.onBackground();
  };

  /** 先建立窗口和订阅，首次联网由根节点onAppear触发，避免未显示时启动官方登录。 */
  private skillPrompt_: boolean = false;

  /** 更新所有权留在同一窗口的 Coordinator；拒绝拿旧活动或旧阶段推进新的更新。 */
  private async skillUpdate_(method: string,args: SettingsSkillData): Promise<SettingsSkillData> {
    const vm = this.viewModel;
    if (!this.windowInteractive() || DistributionPolicy.isStore()) return settingFailure('notInteractive');
    if (method === 'getActiveLauncherUpdate' && settingKeys(args,[])) {
      return {'state':'ready','activityId':vm.activityId,'phase':vm.phase,'version':vm.version,'progress':vm.progress,
        'checkingConnection':vm.checking,'connectionReady':vm.connectionReady,'needsLogin':vm.needsLogin,
        'loginVisible':vm.loginVisible,'recovery':vm.recoveryAction,'failedPhase':vm.failedPhase,'canContinue':this.primaryEnabled()};
    }
    if (method !== 'controlActiveLauncherUpdate' || !settingKeys(args,['activityId','phase','operation']) ||
      args['activityId'] !== vm.activityId || args['phase'] !== vm.phase || this.skillPrompt_) return settingFailure('updateChanged');
    const op = settingText(args,'operation');
    if (op === 'details') { this.detailsVisible=true; return {'state':'needsUser','reason':'updateDetails'}; }
    if (op === 'viewActivity' && vm.activityId > 0 && !vm.finishing && !this.installationPending()) {
      return await this.openActivity() ? {'state':'needsUser','reason':'activity'} : settingFailure('activityPageUnavailable');
    }
    if (op === 'manualPort' || op === 'retryConnection' || op === 'wirelessSettings') {
      if (!vm.working || vm.connectionReady || this.installationPending() || vm.finishing || vm.runtimeRetired || vm.checking) return settingFailure('notAvailable');
      if (op === 'wirelessSettings') return await vm.openDebugSettings() ? {'state':'needsUser','reason':'wirelessSettings'} : settingFailure('systemSettingsUnavailable');
      if (!vm.connectionRetry && !this.manualPort) return settingFailure('notAvailable');
      if (op === 'manualPort') { this.manualPort=true; return {'state':'needsUser','reason':'enterPortInApp'}; }
      this.retryConnection(); return {'state':'accepted','activityId':vm.activityId};
    }
    if (op !== 'continue' && op !== 'close') return settingFailure('invalidOperation');
    if (op === 'continue' && !this.primaryEnabled()) return settingFailure('busy');
    const phase=vm.phase, id=vm.activityId, version=vm.version;
    const label=op === 'close' ? '退出当前更新界面' : this.primaryLabel();
    this.skillPrompt_=true;
    try {
      LauncherSkillBus.awaitingUser(method);
      const answer=await this.getUIContext().getPromptAction().showDialog({title:'应用更新',message:label+'？'+(version?' 目标版本 '+version:''),
        buttons:[{text:'取消',color:this.theme.textSecondary as string},{text:'确认',color:this.theme.actionText as string}]});
      if (answer.index !== 1) return {'state':'cancelled'};
      if (!this.windowInteractive() || vm !== this.viewModel || vm.phase !== phase || vm.activityId !== id || vm.version !== version ||
        (op === 'continue' && (!this.primaryEnabled() || this.primaryLabel() !== label))) return settingFailure('updateChanged');
      if (op === 'close') this.close(); else this.runPrimary();
      return {'state':'accepted','activityId':id};
    } finally {this.skillPrompt_=false;}
  }

  aboutToAppear(): void {
    LauncherSkillBus.bind('activeUpdate',this,(method: string,args: SettingsSkillData): Promise<SettingsSkillData> =>
      this.skillUpdate_(method,args), (): boolean => this.windowInteractive() && !DistributionPolicy.isStore());
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.stage = context.windowStage; this.appWindow = this.stage.getMainWindowSync();
    this.previousKeepScreenOn = this.appWindow.getWindowProperties().isKeepScreenOn;
    this.requestedKeepScreenOn = this.previousKeepScreenOn;
    this.viewModel.initialize(context, this.params); this.applyTheme();
    this.onExitGuardReady((): boolean => this.prepareExit());
    this.stage.on('windowStageLifecycleEvent', this.stageListener);
    this.appWindow.on('windowEvent', this.windowListener);
    this.refreshWindowFacts();
  }

  /** API12的实际显示/焦点查询与Ability前后台合成，SHOWN或组件onAppear不能单独放行安装。 */
  private windowInteractive(): boolean {
    try {
      return !this.stagePaused && this.appWindow !== undefined && this.appWindow.isWindowShowing() && this.appWindow.isFocused();
    } catch (_) { return false; }
  }
  /** 当前展示面/Ability门禁仍由VM与Coordinator核对；此处只提交实际窗口查询结果。 */
  private syncWindowFacts(): void {
    if (this.windowInteractive()) this.viewModel.onForeground(); else this.viewModel.onBackground();
  }
  /** Sheet收起或焦点事件发生时立即采样，并在下一UI事件段再核实，避免过渡帧false永久锁存。 */
  private refreshWindowFacts(): void {
    this.syncWindowFacts();
    if (this.factsTimer >= 0) clearTimeout(this.factsTimer);
    this.factsTimer = setTimeout((): void => {
      this.factsTimer = -1;
      if (this.appWindow !== undefined && !this.viewModel.runtimeRetired) this.syncWindowFacts();
    }, 0);
  }
  /** 明确连接命令也使用真实当前窗口事实；先让VM保存端口再合成门禁，不强制设置前台。 */
  private retryConnection(): void {
    this.viewModel.retryConnection(this.windowInteractive()); this.refreshWindowFacts();
  }

  /** 框架卸载只解除本视图资源；显式退出由按钮/Back命令撤销本轮许可。 */
  aboutToDisappear(): void {
    LauncherSkillBus.unbind('activeUpdate',this);
    this.stage?.off('windowStageLifecycleEvent', this.stageListener); this.stage = undefined;
    this.appWindow?.off('windowEvent', this.windowListener);
    if (this.factsTimer >= 0) clearTimeout(this.factsTimer); this.factsTimer = -1;
    this.viewModel.dispose();
    this.appWindow?.setWindowKeepScreenOn(this.previousKeepScreenOn).catch((): void => {});
    this.appWindow = undefined;
  }

  private applyTheme(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const preferences: PreferenceManager = new PreferenceManager(context);
    const mode: ThemeMode = preferences.themeMode;
    this.theme = resolveTheme(mode, resolveIsDark(mode, this.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK), preferences.themeAccent);
    applyNativeTheme(this.theme);
  }

  /** 只在目标状态变化时调用窗口服务，进度tick不会重复IPC；不修改系统息屏设置。 */
  private syncKeepScreenOn(): void {
    const phase = this.viewModel.phase;
    const wanted = this.previousKeepScreenOn || this.viewModel.finishing ||
      phase === 'downloading' || phase === 'verifying' || phase === 'preparing-material' || phase === 'signing' || phase === 'transferring' || phase === 'dispatch-intent' || phase === 'installing' ||
      (this.viewModel.loginVisible && this.viewModel.loginBusy);
    if (this.appWindow === undefined || wanted === this.requestedKeepScreenOn) return;
    this.requestedKeepScreenOn = wanted;
    this.appWindow.setWindowKeepScreenOn(wanted).catch((): void => {});
  }

  /** 派发意图落盘后即属于安装保护阶段；按钮文案不能用 working 猜测是否仍可取消。 */
  private installationPending(): boolean {
    return this.viewModel.phase === 'dispatch-intent' || this.viewModel.phase === 'installing' ||
      this.viewModel.phase === 'confirmation-pending';
  }

  /**
   * 返回 true 才允许父容器退出。顶层登录优先收起，只关闭授权，不取消背后的更新尝试。
   * 派发前沿用原取消命令撤销许可；派发后仅卸载观察面，系统执行权及保护记录继续由 Coordinator 管理。
   */
  private prepareExit(): boolean {
    if (this.viewModel.runtimeRetired) return true;
    if (this.viewModel.loginVisible) { this.viewModel.closeLogin(); return false; }
    if (!this.installationPending()) this.viewModel.cancel();
    return true;
  }

  /** 显式按钮和系统返回共用同一退出语义，避免关闭 Sheet 的动作误关原模态。 */
  private close(): void {
    if (this.prepareExit()) this.onDismiss();
  }

  /** 统一版本前缀只用于展示；恢复旧事务时以 VM 的真实目标为准。 */
  private versionLabel(version: string): string {
    return version.length === 0 ? '—' : version.startsWith('v') ? version : 'v' + version;
  }

  /** 文件任务未完成时维持真实下载主视图；账号与调试检查仍可并行，不能画成串行步骤。 */
  private showDownload(): boolean {
    return !this.viewModel.runtimeRetired && this.viewModel.phase !== 'failed' && this.viewModel.phase !== 'cancelled' &&
      !this.installationPending() && this.viewModel.phase !== 'verified' && this.viewModel.phase !== 'superseded' && this.viewModel.phase !== 'storage-blocked' &&
      this.viewModel.downloadTaskId.length > 0 && this.viewModel.downloadState !== 'done';
  }

  /** 百分比仅来自安装包下载投影；签名、传送和系统安装永远不借用此值表示整体完成。 */
  private progressLabel(): string {
    return Math.floor(Math.max(0, Math.min(100, this.viewModel.progress))).toString() + '%';
  }

  /** Coordinator 的 transfer 固定为“已下载 / 总量 · 速率”，拆分只影响排版，原始详情仍可展开。 */
  private transferSize(): string {
    // 有真实进度时优先显示已下载/总量；尚未传输时才使用发行清单提供的大小。
    return this.viewModel.transfer.split(' · ')[0] || (this.sizeLabel.length > 0 ? '安装包 ' + this.sizeLabel : '等待下载队列');
  }

  /** 尚无速率时显示真实队列/校验状态，不生成占位速度或预估剩余时间。 */
  private transferSpeed(): string {
    const parts = this.viewModel.transfer.split(' · ');
    return parts.length > 1 ? '↓ ' + parts[1] : this.viewModel.downloadState === 'waiting' ? '等待队列' :
      this.viewModel.phase === 'verifying' ? '正在校验' : '等待传输';
  }

  /** 当前真正阻塞项优先；不把网络核实失败冒充账号过期，也不隐藏已派发安装的状态。 */
  private statusTitle(): string {
    const phase = this.viewModel.phase;
    if (this.viewModel.runtimeRetired) return '请重新打开更新';
    if (phase === 'verified') return '更新完成';
    if (phase === 'superseded') return '原安装已结束';
    if (phase === 'confirmation-pending') return this.viewModel.finishing ? '正在检查更新结果' : '等待更新结果';
    if (phase === 'storage-blocked') return '无法读取上次更新记录';
    if (phase === 'dispatch-intent' || phase === 'installing') return '等待系统安装结果';
    if (phase === 'failed') return '更新暂时遇到问题';
    if (phase === 'cancelled') return '更新已取消';
    if (phase === 'awaiting-restart') return '请重新打开 AMCL';
    if (phase === 'idle' || phase === 'resolving') return '正在准备更新';
    if (this.viewModel.needsLogin) return '登录后继续';
    if (this.viewModel.accountRetry) return '登录状态待核实';
    if (this.viewModel.signingIssue.length > 0) return '签名准备暂未完成';
    if (phase === 'signing') return '正在为本机签名';
    if (phase === 'preparing-material') return '正在准备更新';
    if (phase === 'transferring') return '正在传送安装包';
    if (!this.viewModel.connectionReady && !this.viewModel.checking) return '调试连接待确认';
    if (this.viewModel.checking) return '正在检查调试连接';
    if (phase === 'verifying') return '正在校验安装包';
    if (phase === 'queued') return '安装包排队中';
    if (phase === 'downloading') return '正在下载安装包';
    return '正在准备安装';
  }

  /** 一条状态辅文说明下一步；完整错误、账号和连接事实保留在原中段的详情中。 */
  private statusHint(): string {
    const phase = this.viewModel.phase;
    if (this.viewModel.runtimeRetired || phase === 'failed' || phase === 'storage-blocked' ||
      phase === 'awaiting-restart' || phase === 'idle' || phase === 'resolving') return this.viewModel.message;
    if (phase === 'verified') return '已确认运行新版本';
    if (phase === 'superseded') return this.viewModel.message;
    if (phase === 'confirmation-pending') return '系统结果确认后会自动完成；暂时无法确认时可重新检查';
    if (phase === 'dispatch-intent' || phase === 'installing') return '可以关闭界面，安装保护记录会保留';
    if (phase === 'cancelled') return '已下载的数据会按原校验规则复用';
    if (this.viewModel.needsLogin) return '下载会继续，登录成功后自动返回';
    if (this.viewModel.accountRetry) return this.viewModel.accountMessage;
    if (this.viewModel.signingIssue.length > 0) return this.viewModel.message;
    if (!this.viewModel.connectionReady) return this.viewModel.checking ? '正在自动发现本机端口' : '返回后自动检查并继续';
    if (this.viewModel.accountReady) return '完成后会自动安装并重新打开 AMCL';
    return '准备完成后自动继续';
  }

  /** 右侧仅在当前存在可执行命令时出现，自动阶段不显示禁用的占位按钮。 */
  private primaryLabel(): string {
    const phase = this.viewModel.phase;
    if (this.viewModel.runtimeRetired) return '关闭界面';
    if (phase === 'awaiting-restart') return '关闭界面';
    if (phase === 'verified') return '完成';
    if (phase === 'superseded') return '关闭界面';
    if (phase === 'confirmation-pending') return '重新检查';
    if (phase === 'storage-blocked') return '重试读取';
    if (phase === 'dispatch-intent' || phase === 'installing') return '安装中';
    if (this.viewModel.finishing) return phase === 'signing' ? '签名中' : '准备中';
    if (this.viewModel.recoveryAction === 'runtime') return '前往设置';
    if (this.viewModel.recoveryAction === 'package') return '重新检查';
    if (this.viewModel.working && this.viewModel.needsLogin) return '登录华为账号';
    if (this.viewModel.working && this.viewModel.accountRetry) return '重新检查登录';
    if (this.viewModel.signingIssue.length > 0 && !this.viewModel.working) return '重试更新';
    if (!this.viewModel.working) return '重试更新';
    if (!this.viewModel.connectionReady && !this.viewModel.checking) return this.manualPort ? '连接并继续' : '打开设置';
    if (this.viewModel.checking && this.manualPort) return '检查连接中';
    return this.showDownload() ? '下载中' : '准备中';
  }

  /** 自动推进和终态核实的忙锁由 VM 提供，禁用按钮不为业务增加新的确认门。 */
  private primaryEnabled(): boolean {
    if (this.viewModel.runtimeRetired || this.viewModel.phase === 'verified' || this.viewModel.phase === 'superseded' ||
      this.viewModel.phase === 'awaiting-restart') return true;
    if (this.viewModel.finishing) return false;
    if (this.viewModel.phase === 'confirmation-pending' || this.viewModel.phase === 'storage-blocked') return true;
    if (this.installationPending()) return false;
    if (!this.viewModel.working || this.viewModel.recoveryAction === 'runtime' || this.viewModel.recoveryAction === 'package' ||
      this.viewModel.needsLogin || this.viewModel.accountRetry) return true;
    return !this.viewModel.connectionReady && !this.viewModel.checking;
  }

  /** 命令全部转交既有 VM；恢复设置/产品入口沿用原 AppStorage 请求协议。 */
  private runPrimary(): void {
    if (!this.primaryEnabled()) return;
    const phase = this.viewModel.phase;
    if (this.viewModel.runtimeRetired || phase === 'verified' || phase === 'superseded' || phase === 'awaiting-restart') { this.close(); return; }
    if (phase === 'confirmation-pending' || phase === 'storage-blocked') { this.viewModel.reconcile(); return; }
    if (this.viewModel.recoveryAction === 'runtime' || this.viewModel.recoveryAction === 'package') {
      const key = this.viewModel.recoveryAction === 'runtime' ? 'amclUpdateOpenSettings' : 'amclUpdateRecoveryRequested';
      this.close(); AppStorage.setOrCreate<number>(key, Date.now());
      this.getUIContext().getRouter().back({ url: 'pages/Index' }); return;
    }
    // 当前尝试的授权优先于材料恢复；登录成功后由原推进器自动复用私钥或刷新证书/Profile。
    if (this.viewModel.working && this.viewModel.needsLogin) { this.viewModel.login(); return; }
    if (this.viewModel.working && this.viewModel.accountRetry) { this.viewModel.checkAccount(); return; }
    if (!this.viewModel.working) { this.viewModel.start(); return; }
    if (!this.viewModel.connectionReady) {
      if (this.manualPort) this.retryConnection(); else this.viewModel.openDebugSettings();
    }
  }

  /** 登录承载在真实主窗口，复用统一登录Sheet尺寸；自更新的固定小弹窗不是尺寸参考系。 */
  private loginSheetOptions(): SheetOptions {
    return developerLoginSheetOptions({ theme: this.theme,
      uiContext: this.appWindow?.getUIContext() ?? this.getUIContext(),
      width: this.screenWidth, height: this.screenHeight, topSafe: this.topSafe, bottomSafe: this.bottomSafe,
      phoneHeightPercent: this.phoneSheetHeightPercent_,
      onDisappear: (): void => { this.refreshWindowFacts(); },
      onClose: (): void => { this.viewModel.closeLogin(); }
    });
  }

  /** 记录仅在原流程允许的非忙态打开，先完成原取消/关闭协议，再使用已有活动记录页面。 */
  private async openActivity(): Promise<boolean> {
    if (this.viewModel.activityId <= 0 || this.viewModel.working || this.viewModel.finishing ||
      this.viewModel.phase === 'dispatch-intent' || this.viewModel.phase === 'installing') return false;
    const id = this.viewModel.activityId;
    this.close();
    try { await this.getUIContext().getRouter().pushUrl({ url: 'pages/ActivityLogPage', params: { 'activityId': id, 'view': 'overview' } }); return true; }
    catch (_) { return false; }
  }

  /** 标题只说明更新状态；容量归下载正文，日期归已有详情区，固定高度同步收紧为一行。 */
  @Builder
  private header() {
    Row() {
      Text(this.viewModel.phase === 'superseded' ? '原安装已结束' : this.viewModel.phase === 'verified' ? '更新完成' :
        this.viewModel.working || this.viewModel.finishing ? '正在更新 AMCL' : '更新 AMCL')
        .fontSize(this.compact ? 18 : 20).fontWeight(FontWeight.Medium).fontColor(this.theme.textPrimary)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
    }.width('100%').height(28).alignItems(VerticalAlign.Center).flexShrink(0)
  }

  /** 同一双列版本条贯穿各阶段，目标来自 VM，当前版本由父级读取已安装应用信息。 */
  @Builder
  private versionComparison() {
    Row({ space: 8 }) {
      Text(this.versionLabel(this.currentVersion || APP_VERSION))
        .fontSize(14).fontColor(this.theme.textSecondary).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      SymbolGlyph($r('sys.symbol.arrow_right')).fontSize(14).fontColor([this.theme.textSecondary])
      Text(this.versionLabel(this.viewModel.version || this.params.manifest?.versionName || ''))
        .fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.theme.actionText)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
    }.width('100%').height(28).flexShrink(0)
  }

  /** 下载采用突出数字和细进度条；容量、速率和百分比均消费同一真实投影。 */
  @Builder
  private downloadProgress() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        Text(this.progressLabel()).fontSize(32).fontWeight(FontWeight.Bold).fontColor(this.theme.textPrimary)
          .accessibilityText('安装包已下载百分之' + Math.floor(this.viewModel.progress).toString())
        Column({ space: 5 }) {
          Text(this.viewModel.downloadState === 'waiting' ? '安装包排队中' : this.viewModel.phase === 'verifying' ? '正在校验安装包' : '正在下载安装包')
            .fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.theme.textPrimary)
          Text(this.transferSize()).fontSize(12).fontColor(this.theme.textSecondary)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%').alignItems(VerticalAlign.Center)
      Progress({ value: this.viewModel.progress, total: 100, type: ProgressType.Linear })
        .width('100%').color(this.theme.actionText).backgroundColor(this.theme.bgInput).style({ strokeWidth: 6 })
      Row() {
        Text(this.transferSpeed()).fontSize(12).fontColor(this.theme.actionText).layoutWeight(1)
        Text('完成后自动继续').fontSize(12).fontColor(this.theme.textSecondary)
      }.width('100%')
      if (this.viewModel.needsLogin || this.viewModel.accountRetry || (!this.viewModel.connectionReady && this.viewModel.connectionRetry)) {
        Text(this.statusTitle()).fontSize(13).fontColor(this.theme.textSecondary).width('100%')
      }
    }.width('100%').padding({ top: this.compact ? 4 : 16, bottom: 12 })
  }

  /** 文件校验后显示完成摘要与真实准备阶段；未知结果保留核实语义，不显示成功勾。 */
  @Builder
  private stageStatus() {
    Column({ space: this.compact ? 12 : 16 }) {
      Column({ space: 16 }) {
        if (this.viewModel.phase === 'verified') {
          SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(32).fontColor([this.theme.successText])
        } else if (this.viewModel.phase === 'failed' || this.viewModel.phase === 'storage-blocked') {
          SymbolGlyph($r('sys.symbol.exclamationmark_circle')).fontSize(28).fontColor([this.theme.errorText])
        } else if (this.viewModel.phase === 'confirmation-pending' || this.viewModel.phase === 'cancelled' || this.viewModel.runtimeRetired) {
          SymbolGlyph($r('sys.symbol.clock')).fontSize(28).fontColor([this.theme.textSecondary])
        } else if (this.viewModel.needsLogin || this.viewModel.accountRetry ||
          (!this.viewModel.connectionReady && !this.viewModel.checking)) {
          SymbolGlyph($r('sys.symbol.info_circle')).fontSize(28).fontColor([this.theme.actionText])
        } else {
          LoadingProgress().width(40).height(40).color(this.theme.actionText)
        }
        Text(this.statusTitle()).fontSize(this.compact ? 18 : 20).fontWeight(FontWeight.Medium).fontColor(this.theme.textPrimary)
          .width('100%').textAlign(TextAlign.Center)
      }.width('100%').alignItems(HorizontalAlign.Center)
      Text(this.statusHint()).fontSize(13).lineHeight(20).fontColor(this.theme.textSecondary)
        .width('100%').textAlign(TextAlign.Center).maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
    }.width('100%').padding({ top: 16, bottom: 16 })
  }

  /** 恢复入口和手填端口只在需要时展开，均留在唯一中段，不另弹任务或帮助 Sheet。 */
  @Builder
  private recoveryDetails() {
    Column({ space: 8 }) {
      if (!this.installationPending() && !this.viewModel.finishing && !this.viewModel.runtimeRetired) {
        if (!this.viewModel.connectionReady && this.viewModel.working && (this.viewModel.connectionRetry || this.manualPort)) {
          Row() {
            Button(this.manualPort ? '收起手动端口' : '手动端口').height(40).fontSize(13)
              .backgroundColor(Color.Transparent).fontColor(this.theme.actionText)
              .onClick((): void => { this.manualPort = !this.manualPort; })
            Blank()
            if (this.viewModel.connectionRetry) {
              Button('重新检查').height(40).fontSize(13).backgroundColor(Color.Transparent).fontColor(this.theme.actionText)
                .enabled(!this.viewModel.checking).onClick((): void => { this.retryConnection(); })
            }
          }.width('100%')
          if (this.manualPort) {
            Text('输入系统无线调试页面的端口，无需 IP 地址。')
              .fontSize(12).lineHeight(19).fontColor(this.theme.textSecondary).width('100%')
            TextInput({ text: this.viewModel.port, placeholder: '例如 10178' }).caretColor(this.theme.actionText).type(InputType.Number).maxLength(5)
              .height(44).fontColor(this.theme.textPrimary).backgroundColor(this.theme.bgInput)
              .onChange((value: string): void => { this.viewModel.port = value; })
            // 主按钮可能优先承载登录/材料恢复，端口区域保留连接命令，不能被另一阻塞项藏掉。
            Button('连接并继续').height(44).width('100%').fontSize(13)
              .backgroundColor(this.theme.bgInput).fontColor(this.theme.actionText).enabled(!this.viewModel.checking)
              .onClick((): void => { this.retryConnection(); })
          }
        }
      }
      if (this.detailsVisible) {
        // 延用现有“查看详情”开关；发行事实只在需要时展开，不挤占每个更新阶段的固定标题。
        if (this.sizeLabel.length > 0) {
          Text('下载大小：' + this.sizeLabel).fontSize(12).lineHeight(20).fontColor(this.theme.textSecondary).width('100%')
        }
        if (this.releaseDate.length > 0) {
          Text('发布日期：' + this.releaseDate).fontSize(12).lineHeight(20).fontColor(this.theme.textSecondary).width('100%')
        }
        Text(this.viewModel.message).fontSize(13).lineHeight(21).fontColor(this.theme.textPrimary).width('100%')
        if (!this.installationPending() && this.viewModel.phase !== 'verified' && this.viewModel.phase !== 'superseded' && !this.viewModel.runtimeRetired) {
          Text(this.viewModel.accountMessage).fontSize(12).lineHeight(20).fontColor(this.theme.textSecondary).width('100%')
          Text(this.viewModel.connectionMessage).fontSize(12).lineHeight(20).fontColor(this.theme.textSecondary).width('100%')
          if (!this.viewModel.connectionReady) {
            Text('找不到开发者选项时，在设置的设备信息中连续点击软件版本七次，按系统提示开启。')
              .fontSize(12).lineHeight(20).fontColor(this.theme.textSecondary).width('100%')
          }
        }
        if (this.viewModel.activityId > 0 && !this.viewModel.working && !this.viewModel.finishing &&
          this.viewModel.phase !== 'dispatch-intent' && this.viewModel.phase !== 'installing') {
          Button('查看本次更新记录').height(40).width('100%').fontSize(13)
            .backgroundColor(Color.Transparent).fontColor(this.theme.actionText).onClick((): void => { this.openActivity(); })
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  /** 单一滚动中段吸收长错误、端口输入及大字体；标题、版本与页脚始终保持父容器确定的基线。 */
  build() {
    Column({ space: this.compact ? 8 : 14 }) {
      this.header()
      this.versionComparison()
      Scroll() {
        Column() {
          if (this.showDownload()) { this.downloadProgress() } else { this.stageStatus() }
          this.recoveryDetails()
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.width('100%').layoutWeight(1).align(Alignment.Center).scrollBar(BarState.Auto)
      // 进行态只提供当前过程详情；发行说明保留在更新开始前的发现界面。
      Row() {
        Blank().layoutWeight(1)
        Button(this.detailsVisible ? '收起详情' : '查看详情').height(44).fontSize(13)
          .padding({ left: 8, right: 0 }).backgroundColor(Color.Transparent).fontColor(this.theme.textSecondary)
          .id('sideload-update-details').onClick((): void => { this.detailsVisible = !this.detailsVisible; })
      }.width('100%').flexShrink(0)
      Row({ space: 10 }) {
        Button(this.installationPending() ? '关闭界面' : this.viewModel.working || this.viewModel.finishing ? '取消更新' : '关闭')
          .layoutWeight(1).height(this.compact ? 44 : 48).fontSize(14).fontWeight(FontWeight.Medium)
          .backgroundColor(this.theme.bgInput).fontColor(this.theme.textSecondary).borderRadius(16)
          .onClick((): void => { this.close(); })
        // 自动阶段只显示真实进度和取消，不把“准备中”画成第二个不可操作的主按钮。
        if (this.primaryEnabled()) {
        Button(this.primaryLabel()).layoutWeight(1).height(this.compact ? 44 : 48).fontSize(14).fontWeight(FontWeight.Medium)
          .backgroundColor(this.theme.primary).fontColor(this.theme.textOnPrimary).borderRadius(16)
          .enabled(this.primaryEnabled()).opacity(this.primaryEnabled() ? 1 : 0.5)
          .onClick((): void => { this.runPrimary(); })
        }
      }.width('100%').flexShrink(0)
    }.width('100%').height('100%')
      .padding({ left: this.compact ? 16 : 24, right: this.compact ? 16 : 24, top: this.compact ? 16 : 24, bottom: this.compact ? 16 : 24 })
      .backgroundColor(this.theme.bgCard).borderRadius(20)
      .onAppear((): void => {
        if (!this.initialized) { this.initialized = true; this.viewModel.onShown(); }
      })
      // 绑定稳定根节点，不额外插入零尺寸子项产生 Column gap；保证页脚与发现态基线一致。
      // 成功回调由 Coordinator 将 loginVisible 置 false；收起回调只采样窗口，不撤销成功授权。
      .bindSheet(this.viewModel.loginVisible, this.loginSheet(), this.loginSheetOptions())
  }

  /** 设置与更新复用同一官方登录内容；上下文说明仍由当前更新状态提供。 */
  @Builder
  private loginSheet() {
    DeveloperLoginContent({ theme: this.theme, url: this.viewModel.loginUrl, message: this.viewModel.loginMessage,
      busy: this.viewModel.loginBusy, bottomSafe: this.bottomSafe, closeId: 'sideload-login-close',
      footer: this.viewModel.loginUrl.length > 0 ? (this.viewModel.loginMessage || '登录成功后自动继续更新') : '关闭授权后，下载仍会继续',
      onClose: (): void => { this.viewModel.closeLogin(); }, onRetry: (): void => { this.viewModel.login(); },
      onFailure: (message: string): void => { this.viewModel.loginFailed(message); } })
  }
}
