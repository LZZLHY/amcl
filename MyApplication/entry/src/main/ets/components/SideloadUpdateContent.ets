/**
 * R3 自更新弹窗内容：固定标题、版本对照、单一滚动中段和固定页脚，填满父容器给定的尺寸。
 * 登录回调、调试准备、下载、签名和安装仍由唯一 Coordinator 连续推进，ViewModel 仅投影。
 * 本组件只改变显示层级和命令入口，不产生第二份下载进度、安装许可或更新尝试。
 */
import { ImmersiveTitleScaffold } from './ImmersiveTitleScaffold';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { window } from '@kit.ArkUI';
import { ThemeColors, ThemeMode, resolveTheme, resolveIsDark } from 'commons';
import { PreferenceManager } from 'feature_system';
import { UpdateNoteEntry, noteTypeLabel } from 'update';
import { SideloadUpdateViewModel, SideloadUpdatePageParams } from '../sideload/SideloadUpdateViewModel';

@Component
export struct SideloadUpdateContent {
  params: SideloadUpdatePageParams = {};
  /** 以下字段仅展示发行身份；不参与候选校验，也不覆盖 Coordinator 的真实目标版本。 */
  currentVersion: string = '';
  sizeLabel: string = '';
  releaseDate: string = '';
  /** 小窗口由父级几何统一决定紧凑排版，阶段切换不能自行改变外框或页脚基线。 */
  @Prop compact: boolean = false;
  /** 原发行说明只在本模态中段展开；打开说明不能关闭更新或撤销当前许可。 */
  entries: UpdateNoteEntry[] = [];
  showChangelogEntry: boolean = true;
  onDismiss: () => void = (): void => {};
  /** 兼容路由和父controller复用本组件的显式退出协议，系统Back不能仅卸载观察者。 */
  onExitGuardReady: (exit: () => boolean) => void = (): void => {};
  @State @Watch('syncKeepScreenOn') viewModel: SideloadUpdateViewModel = new SideloadUpdateViewModel();
  @State theme: ThemeColors = resolveTheme(ThemeMode.SYSTEM, false);
  @State manualPort: boolean = false;
  @State detailsVisible: boolean = false;
  @State releaseNotesVisible: boolean = false;
  @StorageProp('screenHeightVp') screenHeight: number = 800;
  @StorageProp('topRectHeight') topSafe: number = 0;
  @StorageProp('bottomRectHeight') bottomSafe: number = 0;
  @StorageProp('currentColorMode') @Watch('applyTheme') colorMode: number = 0;
  private webController: webview.WebviewController = new webview.WebviewController();
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
  aboutToAppear(): void {
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
    this.stage?.off('windowStageLifecycleEvent', this.stageListener); this.stage = undefined;
    this.appWindow?.off('windowEvent', this.windowListener);
    if (this.factsTimer >= 0) clearTimeout(this.factsTimer); this.factsTimer = -1;
    this.viewModel.dispose();
    this.appWindow?.setWindowKeepScreenOn(this.previousKeepScreenOn).catch((): void => {});
    this.appWindow = undefined;
  }

  private applyTheme(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const mode = new PreferenceManager(context).themeMode;
    this.theme = resolveTheme(mode, resolveIsDark(mode, this.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK));
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

  /** 发行元数据缺项时省略分隔符，不能用设计示例冒充真实容量或日期。 */
  private releaseLabel(): string {
    let label = 'AMCL';
    if (this.sizeLabel.length > 0) label += ' · ' + this.sizeLabel;
    if (this.releaseDate.length > 0) label += ' · ' + this.releaseDate;
    return label;
  }

  /** 文件任务未完成时维持真实下载主视图；账号与调试检查仍可并行，不能画成串行步骤。 */
  private showDownload(): boolean {
    return !this.viewModel.runtimeRetired && this.viewModel.phase !== 'failed' && this.viewModel.phase !== 'cancelled' &&
      !this.installationPending() && this.viewModel.phase !== 'verified' && this.viewModel.phase !== 'storage-blocked' &&
      this.viewModel.downloadTaskId.length > 0 && this.viewModel.downloadState !== 'done';
  }

  /** 百分比仅来自安装包下载投影；签名、传送和系统安装永远不借用此值表示整体完成。 */
  private progressLabel(): string {
    return Math.floor(Math.max(0, Math.min(100, this.viewModel.progress))).toString() + '%';
  }

  /** Coordinator 的 transfer 固定为“已下载 / 总量 · 速率”，拆分只影响排版，原始详情仍可展开。 */
  private transferSize(): string {
    return this.viewModel.transfer.split(' · ')[0] || '等待下载队列';
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
    if (phase === 'confirmation-pending') return this.viewModel.finishing ? '正在检查更新结果' : '等待更新结果';
    if (phase === 'storage-blocked') return '无法读取上次更新记录';
    if (phase === 'dispatch-intent' || phase === 'installing') return '等待系统安装结果';
    if (phase === 'failed') return '更新暂时遇到问题';
    if (phase === 'cancelled') return '更新已取消';
    if (phase === 'awaiting-restart') return '请重新打开 AMCL';
    if (phase === 'idle' || phase === 'resolving') return '正在准备更新';
    if (this.viewModel.needsLogin) return '登录后继续';
    if (this.viewModel.accountRetry) return '登录状态待核实';
    if (this.viewModel.needsImport) return '需要原安装签名配置';
    if (phase === 'signing') return '正在为本机签名';
    if (phase === 'preparing-material') return '正在准备签名配置';
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
    if (phase === 'confirmation-pending') return '系统结果确认后会自动完成；暂时无法确认时可重新检查';
    if (phase === 'dispatch-intent' || phase === 'installing') return '可以关闭界面，安装保护记录会保留';
    if (phase === 'cancelled') return '已下载的数据会按原校验规则复用';
    if (this.viewModel.needsLogin) return '下载会继续，登录成功后自动返回';
    if (this.viewModel.accountRetry) return this.viewModel.accountMessage;
    if (this.viewModel.needsImport) return '请选择首次安装时使用的配置';
    if (!this.viewModel.connectionReady) return this.viewModel.checking ? '正在自动发现本机端口' : '返回后自动检查并继续';
    if (this.viewModel.accountReady) return '账号与调试连接已就绪';
    return '准备完成后自动继续';
  }

  /** 双按钮的右侧只承担当前可执行命令；自动阶段保留禁用状态，页脚位置不变。 */
  private primaryLabel(): string {
    const phase = this.viewModel.phase;
    if (this.viewModel.runtimeRetired) return '关闭界面';
    if (phase === 'awaiting-restart') return '关闭界面';
    if (phase === 'verified') return '完成';
    if (phase === 'confirmation-pending') return '重新检查';
    if (phase === 'storage-blocked') return '重试读取';
    if (phase === 'dispatch-intent' || phase === 'installing') return '安装中';
    if (this.viewModel.finishing) return phase === 'signing' ? '签名中' : '准备中';
    if (this.viewModel.recoveryAction === 'runtime') return '前往设置';
    if (this.viewModel.recoveryAction === 'package') return '重新检查';
    if (this.viewModel.working && this.viewModel.needsLogin) return '登录华为账号';
    if (this.viewModel.working && this.viewModel.accountRetry) return '重新检查登录';
    if (this.viewModel.needsImport) return this.viewModel.materialReady ? '重新获取配置' : '导入签名配置';
    if (!this.viewModel.working) return '重试更新';
    if (!this.viewModel.connectionReady && !this.viewModel.checking) return this.manualPort ? '连接并继续' : '打开设置';
    if (this.viewModel.checking && this.manualPort) return '检查连接中';
    return this.showDownload() ? '下载中' : '准备中';
  }

  /** 自动推进和终态核实的忙锁由 VM 提供，禁用按钮不为业务增加新的确认门。 */
  private primaryEnabled(): boolean {
    if (this.viewModel.runtimeRetired || this.viewModel.phase === 'verified' ||
      this.viewModel.phase === 'awaiting-restart') return true;
    if (this.viewModel.finishing) return false;
    if (this.viewModel.phase === 'confirmation-pending' || this.viewModel.phase === 'storage-blocked') return true;
    if (this.installationPending()) return false;
    if (!this.viewModel.working || this.viewModel.recoveryAction === 'runtime' || this.viewModel.recoveryAction === 'package' ||
      this.viewModel.needsImport || this.viewModel.needsLogin || this.viewModel.accountRetry) return true;
    return !this.viewModel.connectionReady && !this.viewModel.checking;
  }

  /** 命令全部转交既有 VM；恢复设置/产品入口沿用原 AppStorage 请求协议。 */
  private runPrimary(): void {
    if (!this.primaryEnabled()) return;
    const phase = this.viewModel.phase;
    if (this.viewModel.runtimeRetired || phase === 'verified' || phase === 'awaiting-restart') { this.close(); return; }
    if (phase === 'confirmation-pending' || phase === 'storage-blocked') { this.viewModel.reconcile(); return; }
    if (this.viewModel.recoveryAction === 'runtime' || this.viewModel.recoveryAction === 'package') {
      const key = this.viewModel.recoveryAction === 'runtime' ? 'amclUpdateOpenSettings' : 'amclUpdateRecoveryRequested';
      this.close(); AppStorage.setOrCreate<number>(key, Date.now());
      this.getUIContext().getRouter().back({ url: 'pages/Index' }); return;
    }
    // 当前尝试的授权优先于材料恢复；登录成功仍由原推进器决定是否复用、重新获取或导入材料。
    if (this.viewModel.working && this.viewModel.needsLogin) { this.viewModel.login(); return; }
    if (this.viewModel.working && this.viewModel.accountRetry) { this.viewModel.checkAccount(); return; }
    if (this.viewModel.needsImport) {
      if (this.viewModel.materialReady) this.viewModel.renewMaterial(); else this.viewModel.importMaterial();
      return;
    }
    if (!this.viewModel.working) { this.viewModel.start(); return; }
    if (!this.viewModel.connectionReady) {
      if (this.manualPort) this.retryConnection(); else this.viewModel.openDebugSettings();
    }
  }

  /** 记录仅在原流程允许的非忙态打开，先完成原取消/关闭协议，再使用已有活动记录页面。 */
  private openActivity(): void {
    if (this.viewModel.activityId <= 0 || this.viewModel.working || this.viewModel.finishing ||
      this.viewModel.phase === 'dispatch-intent' || this.viewModel.phase === 'installing') return;
    const id = this.viewModel.activityId;
    this.close();
    this.getUIContext().getRouter().pushUrl({ url: 'pages/ActivityLogPage', params: { 'activityId': id, 'view': 'overview' } });
  }

  /** 固定标题使用发行元数据，状态变化只替换文字与图标，不重建外框。 */
  @Builder
  private header() {
    Row({ space: 12 }) {
      Row() {
        SymbolGlyph($r('sys.symbol.cloud_and_arrow_down')).fontSize(22).fontColor([this.theme.primary])
      }.width(this.compact ? 40 : 44).height(this.compact ? 40 : 44).justifyContent(FlexAlign.Center)
        .backgroundColor(this.theme.primaryLight).borderRadius(16)
      Column({ space: 3 }) {
        Text(this.viewModel.phase === 'verified' ? '更新完成' : '正在更新 AMCL')
          .fontSize(this.compact ? 17 : 18).fontWeight(FontWeight.Bold).fontColor(this.theme.textPrimary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.releaseLabel()).fontSize(12).fontColor(this.theme.textSecondary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').height(this.compact ? 40 : 52).flexShrink(0)
  }

  /** 同一双列版本条贯穿各阶段，目标来自 VM，当前版本由父级读取已安装应用信息。 */
  @Builder
  private versionComparison() {
    Row() {
      Column({ space: 1 }) {
        Text('当前版本').fontSize(12).fontColor(this.theme.textSecondary)
        Text(this.currentVersion.length > 0 ? this.versionLabel(this.currentVersion) : '当前安装')
          .fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.theme.textPrimary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.arrow_right')).fontSize(15).fontColor([this.theme.textSecondary]).margin({ left: 8, right: 8 })
      Column({ space: 1 }) {
        Text('新版本').fontSize(12).fontColor(this.theme.actionPrimary)
        Text(this.versionLabel(this.viewModel.version || this.params.manifest?.versionName || ''))
          .fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.theme.actionPrimary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.layoutWeight(1).alignItems(HorizontalAlign.End)
    }.width('100%').height(this.compact ? 36 : 44).padding({ left: 12, right: 12 })
      .backgroundColor(this.theme.bgInput).borderRadius(12).flexShrink(0)
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
        .width('100%').color(this.theme.primary).backgroundColor(this.theme.bgInput).style({ strokeWidth: 6 })
      Row() {
        Text(this.transferSpeed()).fontSize(12).fontColor(this.theme.primary).layoutWeight(1)
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
    Column({ space: this.compact ? 12 : 18 }) {
      if (this.viewModel.downloadState === 'done' && !this.installationPending() && this.viewModel.phase !== 'verified') {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.checkmark_circle')).fontSize(15).fontColor([this.theme.successText])
          Text('安装包已校验').fontSize(13).fontColor(this.theme.textSecondary)
        }.width('100%').padding(12).backgroundColor(this.theme.bgInput).borderRadius(12)
      }
      Row({ space: 12 }) {
        if (this.viewModel.phase === 'verified') {
          SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(32).fontColor([this.theme.successText])
        } else if (this.viewModel.phase === 'failed' || this.viewModel.phase === 'storage-blocked') {
          SymbolGlyph($r('sys.symbol.exclamationmark_circle')).fontSize(28).fontColor([this.theme.error])
        } else if (this.viewModel.phase === 'confirmation-pending' || this.viewModel.phase === 'cancelled' || this.viewModel.runtimeRetired) {
          SymbolGlyph($r('sys.symbol.clock')).fontSize(28).fontColor([this.theme.textSecondary])
        } else if (this.viewModel.needsLogin || this.viewModel.accountRetry || this.viewModel.needsImport ||
          (!this.viewModel.connectionReady && !this.viewModel.checking)) {
          SymbolGlyph($r('sys.symbol.info_circle')).fontSize(28).fontColor([this.theme.primary])
        } else {
          LoadingProgress().width(28).height(28).color(this.theme.primary)
        }
        Text(this.statusTitle()).fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.theme.textPrimary)
          .layoutWeight(1)
      }.width('100%')
      Text(this.statusHint()).fontSize(13).lineHeight(20).fontColor(this.theme.textSecondary)
        .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
    }.width('100%').padding({ top: this.compact ? 4 : 12, bottom: 8 })
  }

  /** 恢复入口和手填端口只在需要时展开，均留在唯一中段，不另弹任务或帮助 Sheet。 */
  @Builder
  private recoveryDetails() {
    Column({ space: 8 }) {
      if (!this.installationPending() && !this.viewModel.finishing && !this.viewModel.runtimeRetired) {
        if (this.viewModel.accountRetry && this.viewModel.working) {
          Button('重新登录华为账号').height(40).width('100%').fontSize(13)
            .backgroundColor(Color.Transparent).fontColor(this.theme.primary)
            .onClick((): void => { this.viewModel.login(); })
        }
        if (!this.viewModel.connectionReady && this.viewModel.working) {
          Row() {
            Button(this.manualPort ? '收起手动端口' : '手动端口').height(40).fontSize(13)
              .backgroundColor(Color.Transparent).fontColor(this.theme.primary)
              .onClick((): void => { this.manualPort = !this.manualPort; })
            Blank()
            if (this.viewModel.connectionRetry) {
              Button('重新检查').height(40).fontSize(13).backgroundColor(Color.Transparent).fontColor(this.theme.primary)
                .enabled(!this.viewModel.checking).onClick((): void => { this.retryConnection(); })
            }
          }.width('100%')
          if (this.manualPort) {
            Text('输入系统无线调试页面的端口，无需 IP 地址。')
              .fontSize(12).lineHeight(19).fontColor(this.theme.textSecondary).width('100%')
            TextInput({ text: this.viewModel.port, placeholder: '例如 10178' }).type(InputType.Number).maxLength(5)
              .height(44).fontColor(this.theme.textPrimary).backgroundColor(this.theme.bgInput)
              .onChange((value: string): void => { this.viewModel.port = value; })
            // 主按钮可能优先承载登录/材料恢复，端口区域保留连接命令，不能被另一阻塞项藏掉。
            Button('连接并继续').height(44).width('100%').fontSize(13)
              .backgroundColor(this.theme.bgInput).fontColor(this.theme.primary).enabled(!this.viewModel.checking)
              .onClick((): void => { this.retryConnection(); })
          }
        }
        if (this.viewModel.needsImport && this.viewModel.materialReady) {
          Button('导入原安装签名配置').height(40).width('100%').fontSize(13)
            .backgroundColor(Color.Transparent).fontColor(this.theme.primary)
            .onClick((): void => { this.viewModel.importMaterial(); })
        }
      }
      if (this.detailsVisible) {
        Text(this.viewModel.message).fontSize(13).lineHeight(21).fontColor(this.theme.textPrimary).width('100%')
        if (!this.installationPending() && this.viewModel.phase !== 'verified' && !this.viewModel.runtimeRetired) {
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
            .backgroundColor(Color.Transparent).fontColor(this.theme.primary).onClick((): void => { this.openActivity(); })
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  /** 发行说明占用同一滚动中段；仅切换局部显示状态，VM、下载与登录会话持续挂载。 */
  @Builder
  private releaseNotes() {
    Column({ space: 12 }) {
      Text('本版本更新日志').fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.theme.textPrimary).width('100%')
      if (this.entries.length > 0) {
        ForEach(this.entries, (entry: UpdateNoteEntry) => {
          Column({ space: 4 }) {
            Text(noteTypeLabel(entry.type)).fontSize(11).fontWeight(FontWeight.Medium).fontColor(this.theme.primary)
            Text(entry.text).fontSize(13).lineHeight(21).fontColor(this.theme.textSecondary).width('100%')
          }.width('100%').alignItems(HorizontalAlign.Start)
        }, (entry: UpdateNoteEntry, index: number): string => index.toString() + ':' + entry.text)
      } else {
        Text('本次更新未提供详细说明。').fontSize(13).fontColor(this.theme.textSecondary).width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 4, bottom: 8 })
  }

  /** 单一滚动中段吸收长错误、端口输入及大字体；标题、版本与页脚始终保持父容器确定的基线。 */
  build() {
    Column({ space: this.compact ? 8 : 14 }) {
      this.header()
      this.versionComparison()
      Scroll() {
        Column() {
          if (this.releaseNotesVisible) {
            this.releaseNotes()
          } else {
            if (this.showDownload()) { this.downloadProgress() } else { this.stageStatus() }
            this.recoveryDetails()
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.width('100%').layoutWeight(1).align(Alignment.Center).scrollBar(BarState.Auto)
      Row() {
        if (this.showChangelogEntry) {
          Button(this.releaseNotesVisible ? '返回更新进度' : '查看完整更新日志').height(32).fontSize(12)
            .padding({ left: 0, right: 4 }).backgroundColor(Color.Transparent).fontColor(this.theme.primary)
            .layoutWeight(1).onClick((): void => { this.releaseNotesVisible = !this.releaseNotesVisible; })
        } else {
          Blank().layoutWeight(1)
        }
        Button(this.detailsVisible && !this.releaseNotesVisible ? '收起详情' : '查看详情').height(32).fontSize(12)
          .padding({ left: 4, right: 0 }).backgroundColor(Color.Transparent).fontColor(this.theme.textSecondary)
          .onClick((): void => {
            this.detailsVisible = this.releaseNotesVisible || !this.detailsVisible; this.releaseNotesVisible = false;
          })
      }.width('100%').flexShrink(0).border({ width: { top: 0.5 }, color: this.theme.divider })
      Row({ space: 10 }) {
        Button(this.installationPending() ? '关闭界面' : this.viewModel.working || this.viewModel.finishing ? '取消更新' : '关闭')
          .layoutWeight(1).height(this.compact ? 44 : 46).fontSize(14).fontWeight(FontWeight.Medium)
          .backgroundColor(this.theme.bgInput).fontColor(this.theme.textSecondary).borderRadius(12)
          .onClick((): void => { this.close(); })
        Button(this.primaryLabel()).layoutWeight(1).height(this.compact ? 44 : 46).fontSize(14).fontWeight(FontWeight.Medium)
          .backgroundColor(this.theme.primary).fontColor(this.theme.textOnPrimary).borderRadius(12)
          .enabled(this.primaryEnabled()).opacity(this.primaryEnabled() ? 1 : 0.5)
          .onClick((): void => { this.runPrimary(); })
      }.width('100%').flexShrink(0)
    }.width('100%').height('100%')
      .padding({ left: this.compact ? 12 : 20, right: this.compact ? 12 : 20, top: this.compact ? 12 : 20, bottom: this.compact ? 12 : 16 })
      .backgroundColor(this.theme.bgCard).borderRadius(20)
      .onAppear((): void => {
        if (!this.initialized) { this.initialized = true; this.viewModel.onShown(); }
      })
      // 绑定稳定根节点，不额外插入零尺寸子项产生 Column gap；保证页脚与发现态基线一致。
      // 成功回调由 Coordinator 将 loginVisible 置 false；收起回调只采样窗口，不撤销成功授权。
      .bindSheet(this.viewModel.loginVisible, this.loginSheet(), {
        height: Math.max(1, (this.screenHeight - this.topSafe - this.bottomSafe) * 0.92),
        preferType: SheetType.BOTTOM, showClose: false, dragBar: true,
        backgroundColor: this.theme.bgCard, enableOutsideInteractive: false,
        onDisappear: (): void => { this.refreshWindowFacts(); },
        onWillDismiss: (action: DismissSheetAction): void => { this.viewModel.closeLogin(); action.dismiss(); }
      })
  }

  /**
   * 登录复用微软登录的高 Sheet 承载思路：约 92% 安全高度、固定标题、官方 Web 占剩余空间。
   * 不重画官方账号表单，不重复下载卡；关闭只结束授权会话，成功自动收起并保留同一背后模态。
   */
  @Builder
  private loginSheet() {
    Column({ space: 12 }) {
      // 一个完整标题宿主接管导航按钮；正文、任务订阅和原回调保持在当前组件。
      ImmersiveTitleScaffold({ title: '登录华为账号', subtitle: '登录成功后自动返回并继续更新', theme: this.theme, modal: true, surfaceColor: this.theme.bgCard, closeLabel: '关闭授权', closeId: 'sideload-login-close', onClose: (): void => { this.viewModel.closeLogin(); },
        content: (): void => { this.ImmersiveTitleContent1_(); }
      })
    }.width('100%').height('100%').padding({ left: 20, right: 20, top: 8, bottom: Math.max(16, this.bottomSafe) })
      .backgroundColor(this.theme.bgCard)
  }

  /** 保留原正文的父组件状态与业务回调；具名content只转调此真正@Builder，避免this漂移。 */
  @Builder
  private ImmersiveTitleContent1_() {
      if (this.viewModel.loginUrl.length > 0) {
        Web({ src: this.viewModel.loginUrl, controller: this.webController, incognitoMode: true })
          .javaScriptAccess(true).domStorageAccess(true).fileAccess(false).width('100%').layoutWeight(1)
          .onErrorReceive((event): void => {
            if (event.request.isMainFrame()) this.viewModel.loginFailed('登录页面加载失败，请检查网络后重试');
          })
      } else {
        Column({ space: 16 }) {
          if (this.viewModel.loginBusy) { LoadingProgress().width(40).height(40).color(this.theme.primary) }
          Text(this.viewModel.loginMessage).fontSize(16).lineHeight(24).fontColor(this.theme.textPrimary)
          if (!this.viewModel.loginBusy) {
            Button('重新登录').height(48).width('100%').backgroundColor(this.theme.primary).fontColor(this.theme.textOnPrimary)
              .onClick((): void => { this.viewModel.login(); })
          }
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      }
      Text(this.viewModel.loginUrl.length > 0 ? this.viewModel.loginMessage : '关闭授权后，下载仍会继续')
        .fontSize(12).lineHeight(19).fontColor(this.theme.textSecondary).width('100%').flexShrink(0)

      }
}
