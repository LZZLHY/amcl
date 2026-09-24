import { DesktopGameResults } from '../runtime/DesktopGameResults';
import { GameLayoutJournal, GameLayoutImportReport } from '../runtime/GameLayoutJournal';
import { runLogShareConnectivityWant } from '../components/LogShareConnectivityProbe';
import { EntryDownloadEngine, EntryNativeLogSink, EntryLedgerScopeSink, installProcessNativeBridges } from '../runtime/ProcessRuntime';
import { PlatformDfxWatcher } from '../runtime/PlatformDfxWatcher';
import { setRelayNativeBridge, RelayStatsNative, RelayNativeBridge } from 'feature_core';
import { ProductBuildProfile } from 'entry/ProductBuildProfile';
import { ProductInputProfile } from 'entry/ProductInputProfile';
import { collectProductIdentity } from '../product/ProductIdentityCollector';
import { formatProductIdentity } from 'commons';
import { DistributionPolicy, DistributionChannel, DiagnosticPolicy } from 'commons';
import { AbilityConstant, ConfigurationConstant, Configuration, UIAbility, Want, common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import testNapi from 'libentry.so';
import { ProductLauncherWindowChrome } from 'entry/ProductLauncherWindowChrome';
import { DownloadManager } from 'feature_core';
import {
  setDownloadNativeEngine, DownloadNativeEngine,
  NativeFetchTextResult, NativeTaskInfo,
  DownloadTaskSpec, DownloadProgressEvent, DownloadCompleteEvent,
  setForgeNativeBridge, ForgeNativeBridge,
} from 'feature_core';
import { removeDirRecursive } from 'commons';
import { AppLogger } from 'commons';
import { NativeLogSink } from 'commons';
import { LedgerScopeSink, setLedgerScopeSink, ledgerResolveStale } from 'commons';
import { LogTags } from 'commons';
import { LOG_DOMAIN_LAUNCH } from 'commons';
import { SessionMarker, McSessionInfo, listJvmExitSessions } from 'launch';
import { setLaunchNativeBridge, LaunchNativeBridge } from 'launch';
import { getInputDeviceMonitor } from 'gamecontrol';
import { setControlNativeSink, ControlNativeSink } from 'gamecontrol';
import { getInputSourceRegistry } from 'gamecontrol';
import { setSystemNativeBridge, SystemNativeBridge } from 'feature_system';
import { GameStorage, PreferenceManager } from 'feature_system';

// 2026-05-10（LOG-P0-3）：从 'testTag' 占位符迁移到 LogTags.ENTRY_ABILITY，
// 全部走 AppLogger 让启动期失败现场也能拉回 filesDir/logs/amcl_launcher.log。
const TAG = LogTags.ENTRY_ABILITY;
const FRAME_RATE_FOREGROUND_SOURCE_ENTRY: number = 1;

export default class EntryAbility extends UIAbility {
  private windowClass: window.Window | null = null;
  private downloadEngine_: EntryDownloadEngine | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    DiagnosticPolicy.configure(ProductBuildProfile.developerDiagnostics, testNapi.getDiagnosticCapabilities());
    DistributionPolicy.configure(ProductBuildProfile.storeChannel ? DistributionChannel.Store : DistributionChannel.Sideload);
    ProductInputProfile.initialize(this.context);
    // 2026-05-23 API NEXT 迁移：把 UIAbilityContext 缓存到 AppStorage。
    // 所有 @Entry 页面后续都通过 AppStorage.get('uiAbilityContext') 取，不再调
    // 已弃用的 getContext(this)。详见 docs/guides/api-migration-2026-05.md。
    AppStorage.setOrCreate<common.UIAbilityContext>('uiAbilityContext', this.context);

    // U05：平台崩溃/被杀事件必须尽早订阅。回调只落 pending 事件文件，
    // 账本归属和用户分享在后续冷启动/活动页处理，避免系统事件回调阻塞主流程。
    PlatformDfxWatcher.start(this.context.filesDir);
    PlatformDfxWatcher.recordLastExit(this.context.filesDir,
      launchParam.lastExitReason, launchParam.lastExitMessage ?? '');

    // Phase 3.3：监听归 InputDeviceMonitor 进程单例所有。EntryAbility 与 GameAbility
    // 都可以先启动；任意一方只做幂等 ensure，某个 WindowStage 销毁不会让另一个
    // 活跃游戏窗口丢失 DEVICE_REMOVED。
    getInputDeviceMonitor().ensureStarted();

    // 存储当前深色模式状态到 AppStorage（供 UI 层通过 @StorageProp 读取）
    AppStorage.setOrCreate<ConfigurationConstant.ColorMode>('currentColorMode', this.context.config.colorMode);

    // 「打开方式」冷启动：若由点击 .json 文件拉起（viewData），把文件 uri 暂存，
    // 供 Index/LayoutListPage 拾取并走布局导入流程（分析→设备/合法性检测→导入）。
    AppStorage.setOrCreate<string>('pendingLayoutImportUri', this.extractImportUri(want));

    // M5：进程已退出时点系统通知会走冷启动，这里也要解析 sessionKey，
    // 否则「点通知回到 Sheet」只在热启动下生效。
    this.consumeNotificationWant(want);
    this.consumeDesktopLaunchWant(want);

    // ⚠️ 顺序敏感：先 init amcl_log（这样后续启动期错误能落盘），再做其他事。
    // 注意：日志初始化和 native bridge 注入各自独立 try-catch，互不影响。
    // 历史 bug：曾合并在同一个 try-catch 里，导致审核/沙箱环境 amclLogInit 抛异常后
    // setDownloadNativeEngine 被跳过 → CA bundle 无法注入 → 所有 HTTPS 请求失败。
    try {
      let logDir = this.context.filesDir + '/logs';
      testNapi.amclLogInit(logDir, 2 * 1024 * 1024, 5);
      AppLogger.setNativeLogSink(new EntryNativeLogSink());
      AppLogger.info(TAG, `AMCL Log system initialized: ${logDir}`, LOG_DOMAIN_LAUNCH);

      // 产品身份 banner（批次 D8）。⚠️ 位置是判据的一部分，不是风格：
      // 必须在 setNativeLogSink **之后** —— 在它之前的 AppLogger 输出只进 hilog、不落盘
      // （施工记录 §S03.3 的落盘窗口，hilog 一滚即失）。`scripts/check-product-identity-banner.mjs`
      // 机械断言这个顺序。
      // 为什么要这一行：onCreate 第一行就解析了产品身份与诊断能力位，但结果从不落到任何
      // 地方 ⇒ "这个包是哪条产品轨、开关实际是几"在日志里无法反查（真机探针 A7 不通过）。
      AppLogger.info(TAG, formatProductIdentity(collectProductIdentity()), LOG_DOMAIN_LAUNCH);

      // 活动账本（L1-c）：注入 native scope 能力 + 收尾上次残留的 RUNNING 账本。
      // resolveStale 必须在这里做 —— 「新进程刚启动时还标着 RUNNING」是「上次被中断」
      // 唯一可靠的判据，晚做就分不清是残留还是本次刚开的。
      setLedgerScopeSink(new EntryLedgerScopeSink());
      try {
        const stale: number = testNapi.desktopGameProcessState(this.context.filesDir, 0) === 0
          ? ledgerResolveStale(this.context.filesDir) : 0;
        if (stale > 0) {
          AppLogger.info(TAG, `ledger: marked ${stale} interrupted activities`, LOG_DOMAIN_LAUNCH);
        }
      } catch (e) {
        AppLogger.warn(TAG, 'ledgerResolveStale failed', e, LOG_DOMAIN_LAUNCH);
      }
    } catch (e) {
      // amcl_log 还没起来，AppLogger 自动降级到 hilog-only
      AppLogger.warn(TAG, 'Failed to init AMCL log', e as Object, LOG_DOMAIN_LAUNCH);
    }

    // native bridge 注入独立一块，确保即使日志初始化失败也能正常运行。
    // 须在 initializeCaBundle 之前完成（downloadEngine 是 CA 初始化的前置）。
    try {
      this.downloadEngine_ = installProcessNativeBridges();
      AppLogger.info(TAG, 'All native bridges injected', LOG_DOMAIN_LAUNCH);
    } catch (e) {
      AppLogger.error(TAG, 'Failed to inject native bridges — download/launch will not work', e as Object, LOG_DOMAIN_LAUNCH);
    }

    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      AppLogger.error(TAG, 'Failed to set colorMode', err as Object, LOG_DOMAIN_LAUNCH);
    }

    // 注：此处历史上调过 appRecovery.enableAppRecovery(ALWAYS_RESTART, ...)，
    //   预期 MC 的 System.exit 杀掉进程后由 appRecovery 自动重启 app。
    //   2026-05-10 真机日志和官方文档双重确认：appRecovery.RestartFlag 的取值
    //   只覆盖 JS_CRASH 和 APP_FREEZE，对 native 层 SIGABRT/SIGSEGV 不触发自动重启；
    //   MC 的 System.exit 会被 libappspawn_helper 拦截并 abort()，进程死亡后
    //   appRecovery 不会做任何事。该调用对当前架构没有实际作用，已移除以避免误导。
    //   "MC 退出后回到启动器" 的 UX 改用 SessionMarker（启动时写 / 冷启动读）实现。

    // 冷启动与仍存活启动器的前台恢复使用同一入口。原生退出文件可以补上
    // mcLaunch 已退出、ArkTS 尚未来得及写 marker 的窗口；不得把残留 marker 直接称作崩溃。
    this.recoverExitedGameSessions_();

    // 初始化下载引擎的 CA bundle（抽 rawfile/cacert.pem → filesDir/cacert.pem → NAPI set）
    // OHOS 没有标准 /etc/ssl/certs，不在启动期 set 的话首次 HTTPS 下载会报
    // "SSL certificate problem: self-signed certificate in certificate chain" (curl rc=60)。
    try {
      let downloadManager = DownloadManager.instance();
      downloadManager.initializeCaBundle(this.context);
      // 新 Ability/env attach 后，从仍在运行的进程级 native engine 恢复并重新订阅任务。
      downloadManager.refreshFromNative();
    } catch (e) {
      AppLogger.error(TAG, 'initialize/reconcile download engine failed at boot', e as Object, LOG_DOMAIN_LAUNCH);
    }

    // 注入手机端「外部存储」缓存路径（…/Download/com.amcl.launcher）。
    // 手机路线下 GameStorage.resolveMcDir 据此同步解析外部 .minecraft 根，无需启动期 picker/激活。
    // 平板路线此值通常为空（走 Environment），注入空串无副作用。
    try {
      let pref = new PreferenceManager(this.context);
      GameStorage.setPhoneExternalDir(pref.phoneExternalDir);
    } catch (e) {
      AppLogger.warn(TAG, 'inject phoneExternalDir failed', e as Object, LOG_DOMAIN_LAUNCH);
    }

    // 清理孤儿 Forge 安装沙箱: 上次运行中用户强杀/进程崩溃/断电时,
    // DownloadTask 的 finally 子句没跑, filesDir/forge-install-sandbox/<sid>/ 会残留.
    // 每个残留 50-100 MB (vanilla jar + installer + patches libs), 累积会吃磁盘.
    //
    // 关键修复：以前同步跑在 onCreate 主线程，5 个残留 ≈ 500 MB 同步删除可能触发 ANR。
    // 推迟到 setTimeout(0) 让 onCreate 先返回，UI 立刻能起来，扫描在 microtask 异步进行。
    setTimeout(() => { this.cleanupOrphanSandboxes(); }, 0);

    AppLogger.info(TAG, 'Ability onCreate', LOG_DOMAIN_LAUNCH);
    runLogShareConnectivityWant(this.context, want);
  }

  /** 「打开方式」热启动：app 已在运行时点击 .json 文件会走这里，暂存 uri 触发导入。 */
  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    this.consumeDesktopLaunchWant(want);
    // 平板 forResult 的父窗口返回请求只是恢复提示，不带游戏结局。
    // 真正读取仍须经过统一入口的进程锁和 journal 身份校验，不能信任外部 Want 推断成功。
    const returnedActivity = want.parameters?.['gameExitActivityId'];
    if (typeof returnedActivity === 'number' && Number.isSafeInteger(returnedActivity) && returnedActivity > 0) {
      this.recoverExitedGameSessions_();
      // 信号不授权重试；Index 还须匹配私有票据、旧 PID、游戏锁、用户当前实例与偏好。
      AppStorage.setOrCreate<number>('graphicsRecoverySignal', returnedActivity);
    }
    runLogShareConnectivityWant(this.context, want);
    const uri = this.extractImportUri(want);
    if (uri.length > 0) {
      AppStorage.setOrCreate<string>('pendingLayoutImportUri', uri);
      AppLogger.info(TAG, 'onNewWant received layout import uri', LOG_DOMAIN_LAUNCH);
    }
    this.consumeNotificationWant(want);
  }

  /**
   * 点击系统通知回到应用（M5）。
   *
   * `AppNotifier` 构造的 WantAgent 里带了 `amclSessionKey`，这里解析出来写进
   * AppStorage —— 与活动记录「查看详情」、消息中心点击**共用同一条回流通道**，
   * 由 `Index` 的 @Watch 消费后打开对应会话的错误 Sheet。
   */
  private consumeNotificationWant(want: Want): void {
    try {
      let params = want.parameters;
      if (params === undefined) return;
      let raw = params['amclSessionKey'];
      if (typeof raw !== 'string' || (raw as string).length === 0) return;
      let key = Number.parseInt(raw as string, 10);
      if (Number.isNaN(key) || key <= 0) return;
      AppStorage.setOrCreate<number>('amcl_open_error_sheet_session', key);
      AppLogger.info(TAG, 'notification tap → open error sheet key=' + key, LOG_DOMAIN_LAUNCH);
    } catch (e) {
      AppLogger.warn(TAG, 'consumeNotificationWant failed', e, LOG_DOMAIN_LAUNCH);
    }
  }

  private consumeDesktopLaunchWant(want: Want): void {
    const desktopError = want.parameters?.['desktopLaunchError'];
    if (typeof desktopError === 'string' && desktopError.length > 0) {
      AppStorage.setOrCreate<string>('desktopLaunchError', desktopError);
    }
  }

  /** 从 viewData Want 取文件 uri（「打开方式」单文件走 want.uri）。 */
  private extractImportUri(want: Want): string {
    if (!want) return '';
    if (want.uri !== undefined && want.uri !== null && want.uri.length > 0) return want.uri;
    return '';
  }

  /**
   * 启动时扫 filesDir/forge-install-sandbox/ 下所有子目录并删除.
   * 正常安装路径下, finally 会在任务结束时清理自己的沙箱, 这里只能扫到 上次运行 的孤儿.
   * 当前运行并发创建的沙箱 sid 包含 Date.now() + random, 所以不会被误杀.
   *
   * 调用方式：onCreate 里通过 setTimeout(0) 异步调度，避免阻塞 ArkTS 主线程。
   */
  private cleanupOrphanSandboxes(): void {
    try {
      let sandboxRoot = this.context.filesDir + '/forge-install-sandbox';
      let st = fs.statSync(sandboxRoot);
      if (!st.isDirectory()) return;
      let orphans = fs.listFileSync(sandboxRoot);
      let cleanedCount = 0;
      for (let name of orphans) {
        let dir = sandboxRoot + '/' + name;
        try {
          removeDirRecursive(dir);
          cleanedCount++;
        } catch (e) {
          AppLogger.warn(TAG, `Failed to clean sandbox ${dir}`, e as Object, LOG_DOMAIN_LAUNCH);
        }
      }
      if (cleanedCount > 0) {
        AppLogger.info(TAG, `Cleaned ${cleanedCount} orphan Forge sandbox(es) at boot`, LOG_DOMAIN_LAUNCH);
      }
    } catch (e) { /* sandbox root not exist, first launch or never installed Forge */ }
  }

  onDestroy(): void {
    try {
      testNapi.setOhosFrameRateForeground(FRAME_RATE_FOREGROUND_SOURCE_ENTRY, false);
    } catch (e) { /* 老 native 兼容 */ }
    // DownloadEngine is process-owned. Ability/env recreation must only detach this env's
    // TSFN bridges; shutting the singleton down here is permanent and would make the next
    // Ability unable to create downloads in the same process.
    this.downloadEngine_ = null;
    setDownloadNativeEngine(null);
    try {
      testNapi.downloadDetachCallbacks();
    } catch (e) {
      AppLogger.warn(TAG, 'download callback detach failed', e as Object, LOG_DOMAIN_LAUNCH);
    }

    // 在关闭日志前先 flush 一次，确保最后一条 onDestroy 日志能落盘
    AppLogger.info(TAG, 'Ability onDestroy (download callbacks detached; process engine retained)', LOG_DOMAIN_LAUNCH);
    AppLogger.flush();
    try { testNapi.amclLogShutdown(); } catch (e) { /* ignore */ }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    AppLogger.info(TAG, 'Ability onWindowStageCreate', LOG_DOMAIN_LAUNCH);

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        AppLogger.error(TAG, 'Failed to load the content', err as Object, LOG_DOMAIN_LAUNCH);
        return;
      }
      AppLogger.info(TAG, 'Succeeded in loading the content.', LOG_DOMAIN_LAUNCH);
      this.windowClass = windowStage.getMainWindowSync();

      // 沉浸式全屏
      this.windowClass.setWindowLayoutFullScreen(true);

      // 安全区域高度存入 AppStorage 供页面使用
      let topArea = this.windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      let bottomArea = this.windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      // 2026-05-23 API NEXT 迁移：UIAbility 里没有 this.getUIContext()，
      // 改走 windowClass.getUIContext().px2vp(...)（旧的全局 px2vp 已弃用）。
      let uiContext = this.windowClass.getUIContext();
      AppStorage.setOrCreate<number>('topRectHeight', uiContext.px2vp(topArea.topRect.height));
      AppStorage.setOrCreate<number>('bottomRectHeight', uiContext.px2vp(bottomArea.bottomRect.height));
      // 2026-05-23：屏幕高度（vp）也缓存进来，给 SheetSizes 这种非组件工具函数读，
      // 让它们不必再调已弃用的全局 px2vp（display API 在工具函数里没有 UIContext）。
      try {
        let winRect = this.windowClass.getWindowProperties().windowRect;
        AppStorage.setOrCreate<number>('screenHeightVp', uiContext.px2vp(winRect.height));
      } catch (e) {
        AppLogger.warn(TAG, 'Failed to cache screenHeightVp', e as Object, LOG_DOMAIN_LAUNCH);
      }

      // product seam：phone/tablet 跟随系统旋转锁；2in1 不调用平台明确标为
      // unavailable 的方向 API，交给桌面窗口管理器。
      ProductLauncherWindowChrome.applyInitial(this.windowClass).catch((e: Error) => {
        AppLogger.warn(TAG, 'Failed to set orientation', e as Object, LOG_DOMAIN_LAUNCH);
      })

    });
  }

  onWindowStageDestroy(): void {
    AppLogger.info(TAG, 'Ability onWindowStageDestroy', LOG_DOMAIN_LAUNCH);
  }

  onForeground(): void {
    // 平板隔离仍是触控窗口；恢复取决于实际进程边界，不能再以 desktopWindow 排除平板。
    try {
      if (ProductInputProfile.selection().isolatedGameProcess) this.recoverExitedGameSessions_();
    } catch (e) { AppLogger.warn(TAG, 'Game process recovery unavailable', e, LOG_DOMAIN_LAUNCH); }
    AppLogger.info(TAG, 'Ability onForeground', LOG_DOMAIN_LAUNCH);
    try {
      testNapi.setOhosFrameRateForeground(FRAME_RATE_FOREGROUND_SOURCE_ENTRY, true);
    } catch (e) { /* 老 native 兼容 */ }
    // M5：消息投递按前后台分流（前台=灵动弹窗，后台=系统通知），见 AppNotifier。
    AppStorage.setOrCreate<boolean>('appInForeground', true);
  }

  /**
   * 仅在游戏锁明确空闲时发布恢复候选；活跃或不可确认时既不消费 marker，也不扫描退出文件。
   * 两个进程共用活动主键，数组一次发布避免多次同步覆盖 lastMcSession 只通知到最后一局。
   * 原生记录始终保留，最终结论、历史和展示去重由 Index 的串行恢复链处理。
   */
  private recoverExitedGameSessions_(): void {
    try {
      if (testNapi.desktopGameProcessState(this.context.filesDir, 0) !== 0) return;
      // 布局与日志终态分别恢复；owner store 有真实编辑草稿时只延后，journal 不会被删除。
      GameLayoutJournal.importPending(this.context).then((result: GameLayoutImportReport): void => {
        if (result.imported > 0) AppLogger.info(TAG, `已同步 ${result.imported} 份游戏布局提交`, LOG_DOMAIN_LAUNCH);
        if (result.conflicts.length > 0) {
          AppStorage.setOrCreate<string>('gameLayoutSyncNotice', '布局存在同时修改，已保留双方方案，请在布局管理中查看。');
        }
        if (result.deferred) AppLogger.info(TAG, '布局编辑事务仍活跃，游戏布局同步已延后', LOG_DOMAIN_LAUNCH);
      }).catch((error: Error) => {
        AppLogger.warn(TAG, '游戏布局导入失败，提交原文保留，下一次启动前重试', error, LOG_DOMAIN_LAUNCH);
        AppStorage.setOrCreate<string>('gameLayoutSyncNotice', '游戏布局暂未同步，提交记录已保留；请稍后重试启动。');
      });
      DesktopGameResults.importPending(this.context).then((message: string) => {
        if (message.length > 0) AppStorage.setOrCreate<string>('desktopLaunchError', message);
      }).catch((error: Error) => { AppLogger.warn(TAG, 'Game result import failed', error, LOG_DOMAIN_LAUNCH); });
      const sessions: McSessionInfo[] = listJvmExitSessions(this.context.filesDir);
      const marker: McSessionInfo | null = SessionMarker.readAndClear(this.context.filesDir);
      if (marker !== null && !sessions.some((session: McSessionInfo): boolean => session.startedAt === marker.startedAt)) {
        sessions.push(marker);
      }
      if (sessions.length === 0) return;
      sessions.sort((a: McSessionInfo, b: McSessionInfo): number => a.startedAt - b.startedAt);
      AppStorage.setOrCreate<McSessionInfo[]>('pendingJvmExitSessions', sessions);
      const revision: number = AppStorage.get<number>('desktopSessionRevision') ?? 0;
      AppStorage.setOrCreate<number>('desktopSessionRevision', revision + 1);
    } catch (e) {
      // 包括锁查询错误：未知不能当空闲；下一次前台或冷启动仍可从保留原文恢复。
      AppLogger.warn(TAG, 'Game session recovery deferred', e, LOG_DOMAIN_LAUNCH);
    }
  }

  onBackground(): void {
    // 后台期间系统可能不再派发触摸 UP/CANCEL；与 GameAbility 保持同一取消边界。
    // 三端平级：先经注册表对每个已注册端各说一次，再 native 兜底。
    // 启动器进程通常没有端注册（游戏页面不在这里），此时 releaseAllEnds 是空转 ——
    // 但同一个进程里也可能存在已注册的端（单进程形态），所以这个边界必须一致处理。
    getInputSourceRegistry().releaseAllEnds('entry-ability-background');
    try { testNapi.cancelAllInput(2); } catch (e) { /* 老 native 兼容 */ }
    try {
      testNapi.setOhosFrameRateForeground(FRAME_RATE_FOREGROUND_SOURCE_ENTRY, false);
    } catch (e) { /* 老 native 兼容 */ }
    // M5：切后台后产生的消息改走系统通知，见 AppNotifier 的分流表。
    AppStorage.setOrCreate<boolean>('appInForeground', false);
    AppLogger.info(TAG, 'Ability onBackground', LOG_DOMAIN_LAUNCH);
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    const currentColorMode: ConfigurationConstant.ColorMode | undefined = AppStorage.get('currentColorMode');
    if (this.windowClass && currentColorMode !== newConfig.colorMode) {
      AppStorage.setOrCreate<ConfigurationConstant.ColorMode>('currentColorMode', newConfig.colorMode);
      const isDark: boolean =
        newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK
      ProductLauncherWindowChrome.applyTheme(this.windowClass, isDark).catch((e: Error) => {
        AppLogger.warn(TAG, 'setWindowSystemBarProperties failed', e as Object, LOG_DOMAIN_LAUNCH);
      })
    }
  }
}
