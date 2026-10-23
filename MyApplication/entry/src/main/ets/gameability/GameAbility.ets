import { isInputObservationTestWant, runInputObservationTestWant } from '../components/InputObservationTestWant';
import { getDesktopSystemBridge } from '../window/DesktopSystemBridge';
/** 游戏UI与JVM共享经过PID/锁核验的私有进程；初始化失败必须先回传并落盘，再关闭。 */
import { initializeGameProcess, initializeGameProcessLogging } from '../runtime/ProcessRuntime';
import { stopGameSession } from '../runtime/GameSessionHost';
import { PlatformDfxWatcher } from '../runtime/PlatformDfxWatcher';
import { DesktopLaunchSnapshot } from '../runtime/DesktopLaunchSnapshot';
import { GraphicsRecoveryStore } from '../runtime/GraphicsRecoveryStore';
import { common } from '@kit.AbilityKit';
import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { AppLogger, DiagnosticPolicy } from 'commons';
import { ProductBuildProfile } from 'entry/ProductBuildProfile';
import { ledgerBegin, LedgerBeginMeta } from 'commons';
import { ActivityCategory } from 'feature_core';
import { LogTags } from 'commons';
import { LOG_DOMAIN_LAUNCH } from 'commons';
import { getInputDeviceMonitor } from 'gamecontrol';
import { getInputSourceRegistry } from 'gamecontrol';
import testNapi from 'libentry.so';

const TAG = LogTags.GAME_ABILITY;
const FRAME_RATE_FOREGROUND_SOURCE_GAME: number = 2;

export default class GameAbility extends UIAbility {
  private isolated: boolean = false;
  // 隔离成立只授予进程退出权限，不等于快照/运行时初始化成功。窗口必须单独检查ready，
  // 避免失败后等待回传期间又加载页面，触发第二次启动或未初始化的HAR访问。
  private startupReady: boolean = false;
  private startupFailurePending: boolean = false;
  private startupStage: string = 'isolation';

  /** 生命周期同步部分只核验和准备本局状态；失败回传由独立异步方法按顺序收尾。 */
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 转发检查到旧进程后仍可能竞态冷建Ability。诊断Want绝不消费启动快照、建立Host/
    // Source或加载游戏窗口。仅初始化原诊断政策并经过同一双门写不可用回执，不能把
    // startAbility完成当作观察关闭成功，也不能借冷请求建立任何游戏资源。
    if (isInputObservationTestWant(want)) {
      try {
        DiagnosticPolicy.configure(ProductBuildProfile.developerDiagnostics,testNapi.getDiagnosticCapabilities());
        runInputObservationTestWant(this.context,want,false);
      } catch (error) {
        // 冷诊断失败仍是未知回执，只报告原异常；日志故障不能阻止下方终止冷Ability。
        // 这里不能进入正常游戏启动补救，也不能为记录错误创建Host或输入来源。
        try { AppLogger.warn(TAG, 'Cold input observation request failed', error, LOG_DOMAIN_LAUNCH); }
        catch (_) { /* 日志观察失败仍继续终止原冷Ability。 */ }
      }
      try { this.context.terminateSelf().catch((): void => {}) } catch (_) {}
      return
    }
    // 独立游戏进程可以先冷启动；下载/processor准入前固定自己的可信files根，不启动HDC。
    try {
      if (!testNapi.configureSideloadInstallRoot(this.context.filesDir)) throw new Error('无法固定游戏文件事务保护目录');
    } catch (error) { this.failStartup_('无法建立游戏文件保护，请重新打开启动器。', error); return; }
    const parentPid: number = (want.parameters?.['parentPid'] as number) ?? 0;
    let isolationState: number = -1;
    try {
      if (parentPid > 0) isolationState = testNapi.desktopGameProcessState(this.context.filesDir, parentPid);
    } catch (error) {
      this.failStartup_('无法核验独立游戏进程，请重新启动应用。', error);
      return;
    }
    if (isolationState !== 1) {
      this.failStartup_('无法创建独立游戏进程，请重新启动应用。',
        new Error('isolation state=' + isolationState + ' parentPid=' + parentPid));
      return;
    }
    this.isolated = true;
    initializeGameProcessLogging(this.context);
    this.checkpointStartup_('process-create');
    try {
      // 桌面独立游戏进程也订阅平台事件；不同进程各自只写 pending，
      // 账本归属仍由启动器侧冷启动统一合并。
      PlatformDfxWatcher.start(this.context.filesDir, 'game');
      const activityId: number = (want.parameters?.['activityId'] as number) ?? 0;
      const version: string = (want.parameters?.['mcVersion'] as string) ?? 'unknown';
      const launchMeta: LedgerBeginMeta = {
        category: ActivityCategory.LAUNCH, title: version, gameVersionId: version,
        mcDir: (want.parameters?.['mcDir'] as string) ?? '',
        gameDir: (want.parameters?.['gameDir'] as string) ?? '',
        jdk: (want.parameters?.['jdkVersion'] as string) ?? '',
        appFilesDir: this.context.getApplicationContext().filesDir,
      };
      this.checkpointStartup_('snapshot');
      DesktopLaunchSnapshot.consume(this.context, (want.parameters?.['snapshotId'] as string) ?? '',
        (want.parameters?.['accountSnapshot'] as string) ?? '', parentPid, activityId, testNapi.desktopProcessId(), version);
      // 只在私有启动快照验证成功后承认恢复票据；Want 本身不能指定任意后端重试。
      const recoveryId: string = (want.parameters?.['snapshotId'] as string) ?? '';
      const recovery = GraphicsRecoveryStore.ticket(this.context.filesDir, recoveryId);
      if (recovery !== undefined && recovery.parentPid === parentPid && recovery.activityId === activityId
        && recovery.version === version && Date.now() - recovery.createdAt <= 300000) {
        AppStorage.setOrCreate<string>('graphicsRecoveryId', recoveryId);
      } else {
        AppStorage.setOrCreate<string>('graphicsRecoveryId', '');
      }
      // 快照安装后才允许读取游戏配置；日志已在验证快照前开启，失败不会落入无文件窗口。
      this.checkpointStartup_('runtime-init');
      initializeGameProcess(this.context, activityId, launchMeta);
      if (activityId > 0) {
        try { testNapi.amclLedgerSetLaunchActivity(activityId); }
        catch (e) { AppLogger.debug(TAG, 'Launch activity bridge unavailable; native banner uses time identity', LOG_DOMAIN_LAUNCH); }
      }
      this.checkpointStartup_('page-params');
      AppStorage.setOrCreate<boolean>('desktopGameProcess', true);
      AppLogger.info(TAG, 'Desktop game process parent=' + parentPid + ' pid=' + testNapi.desktopProcessId(), LOG_DOMAIN_LAUNCH);
      // GameAbility 可能在 EntryAbility 的 WindowStage 已销毁后继续运行。监听由进程
      // 单例幂等持有，确保独立游戏窗口仍能收到带 deviceId 的热插拔事件。
      getInputDeviceMonitor().ensureStarted();
      // 将 want 参数存到 AppStorage，供 McGamePage 读取
      let params = want.parameters
      // 关键参数缺失标记：让 McGamePage 显示 "请通过启动器进入" 的友好提示，
      // 而不是用默认值悄悄进入"1.20.4 但实际未安装"导致 LaunchProfileBuilder 失败的迷惑链路。
      let hasFilesDir = false
      let hasMcDir = false
      let hasMcVersion = false
      if (params) {
        let filesDir = (params['filesDir'] as string) || ''
        let mcDir = (params['mcDir'] as string) || ''
        let mcVersion = (params['mcVersion'] as string) || ''
        hasFilesDir = filesDir.length > 0
        hasMcDir = mcDir.length > 0
        hasMcVersion = mcVersion.length > 0
        AppStorage.setOrCreate('mcFilesDir', filesDir)
        AppStorage.setOrCreate('mcDir', mcDir)
        // mcGameDir：版本隔离时为 .minecraft/versions/<ver>/，否则等于 mcDir。
        // McGamePage 读取键名是 'mcGameDir'，Index.launchMC 传过来的 want key 是 'gameDir'，
        // 此处做 key 名映射；漏写会导致版本隔离失效（gameDir 退化到 mcDir 根目录）。
        AppStorage.setOrCreate('mcGameDir', (params['gameDir'] as string) || '')
        // 注意：mcVersion 不再 fallback 到 '1.20.4'。空值传到 McGamePage 让它正确报错。
        AppStorage.setOrCreate('mcVersion', mcVersion)
        AppStorage.setOrCreate('mcXmx', params['mcXmx'] as number || 0)
        AppStorage.setOrCreate('jdkVersion', params['jdkVersion'] as string || '17')
        AppStorage.setOrCreate('mcLaunchActivityId', (params['activityId'] as number) || 0)
      }
      // 用 AppStorage 给 McGamePage 一个明确信号：本次启动是否经过 Index 派发。
      // McGamePage 检测到 false 时显示「请通过启动器首页进入游戏」按钮回退。
      AppStorage.setOrCreate('gameAbilityHasValidParams', hasFilesDir && hasMcDir && hasMcVersion)
      this.startupReady = true;
      this.checkpointStartup_('ready');
    } catch (error) {
      this.failStartup_('游戏进程初始化失败，请查看启动日志。', error);
    }
  }

  /** 仅记录固定阶段及进程身份，不输出Want中的账号/凭据；在下一个高风险边界前刷盘。 */
  private checkpointStartup_(stage: string): void {
    this.startupStage = stage;
    AppLogger.info(TAG, 'Game startup stage=' + stage + ' pid=' + testNapi.desktopProcessId(), LOG_DOMAIN_LAUNCH);
    AppLogger.flush();
  }

  /**
   * 只收尾第一次启动失败。startAbility完成/失败之后才能terminateSelf：后者可触发
   * onDestroy中的进程退出，旧的并发调用会使尚未完成的错误回传随进程一起丢失。
   * 回传本身失败也要记录并关闭；不重试、不降级到启动器进程运行游戏。
   */
  private async failStartup_(message: string, error: Object): Promise<void> {
    if (this.startupFailurePending) return;
    this.startupFailurePending = true;
    this.startupReady = false;
    AppLogger.error(TAG, 'Game startup failed stage=' + this.startupStage, error, LOG_DOMAIN_LAUNCH);
    AppLogger.flush();
    const failureWant: Want = { bundleName: this.context.applicationInfo.name, abilityName: 'EntryAbility',
      parameters: { 'desktopLaunchError': message + '（阶段：' + this.startupStage + '）' } };
    try {
      await this.context.startAbility(failureWant);
    } catch (reportError) {
      AppLogger.error(TAG, 'Cannot report game startup failure', reportError, LOG_DOMAIN_LAUNCH);
    }
    AppLogger.flush();
    try {
      await this.context.terminateSelf();
    } catch (closeError) {
      AppLogger.error(TAG, 'Cannot close failed game window', closeError, LOG_DOMAIN_LAUNCH);
      AppLogger.flush();
    }
  }

  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    // 真实私有热入口只控制本Host/原前端观察，正常聚焦仍保留原启动参数。
    if (runInputObservationTestWant(this.context,want,this.startupReady)) return;
    AppLogger.info(TAG, 'Existing game session focused; launch parameters retained', LOG_DOMAIN_LAUNCH);
  }

  onDestroy(): void {
    if (!this.isolated) return;
    // 撤销原生手柄焦点（native 随即中和全部手柄）。它抛错（如混淆改名）不能跳过下面的桌面桥
    // 停止、三端释放与进程退出：同步生命周期回调里逃出的异常就是 JS Crash。
    // 这句调用须保持原文（含分号）：check-desktop-runtime.mjs 要求两个生命周期正文含它，
    // 其自测按含分号的原文做删除变异。
    try {
      testNapi.desktopGamepadFocus(false);
    } catch (e) {
      AppLogger.warn(TAG, 'Desktop gamepad focus reset failed; continuing destroy release', e, LOG_DOMAIN_LAUNCH);
    }
    getDesktopSystemBridge().stop();
    // Ability 销毁不保证页面/surface 回调顺序；统一 cancel 是幂等的，多层调用只会让 ledger 保持为空。
    //
    // 三端平级：`cancelAllInput` 只能触达 native 状态。手柄端的状态机整体在 ArkTS，
    // 触控端也有一份 ArkTS 兼容态，这个边界此前对它们**零覆盖**。走注册表就能对每个
    // 已注册端各说一次，且不需要在 Ability 里去拿页面的私有字段。
    // 顺序纪律：先各端自释放，再 native 兜底（见 InputSourceRegistry.ets）。
    if (!stopGameSession('game-ability-destroy')) {
      // 页面尚未装配宿主的启动失败仍要沿原端口结束；不为清理创建虚假的会话。
      getInputSourceRegistry().releaseAllEnds('game-ability-destroy')
      try { testNapi.cancelAllInput(4) } catch (e) { /* 老 native 兼容 */ }
    }
    try {
      testNapi.setOhosFrameRateForeground(FRAME_RATE_FOREGROUND_SOURCE_GAME, false)
    } catch (e) { /* 老 native 兼容 */ }
    AppLogger.info(TAG, 'onDestroy', LOG_DOMAIN_LAUNCH);
    AppLogger.flush();
    if (this.isolated) testNapi.mcForceExit();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    if (!this.isolated || !this.startupReady || this.startupFailurePending) return;
    this.checkpointStartup_('load-content');
    // loadContent既可能同步抛错，也可能通过回调报告失败，两条路径共享回传/退出协议。
    try {
      windowStage.loadContent('pages/McGamePage', (err) => {
        if (err.code) {
          this.failStartup_('游戏页面加载失败，请查看启动日志。', err);
          return;
        }
        if (!this.startupFailurePending) this.checkpointStartup_('page-loaded');
      });
    } catch (error) {
      this.failStartup_('游戏页面加载失败，请查看启动日志。', error);
    }
  }

  onWindowStageDestroy(): void {
    getDesktopSystemBridge().stop();
    AppLogger.info(TAG, 'onWindowStageDestroy', LOG_DOMAIN_LAUNCH);
  }

  onForeground(): void {
    try {
      testNapi.setOhosFrameRateForeground(FRAME_RATE_FOREGROUND_SOURCE_GAME, true)
    } catch (e) { /* 老 native 兼容 */ }
    // 页面未重建且组件焦点未改变时也必须解除Ability后台限制；不改写真实焦点。
    getInputSourceRegistry().notifyAbilityForeground()
    AppLogger.info(TAG, 'onForeground', LOG_DOMAIN_LAUNCH);
  }

  onBackground(): void {
    if (!this.isolated) return;
    // 同 onDestroy：焦点撤销失败只记录，下面的三端释放与 native 兜底必须照常执行。
    try {
      testNapi.desktopGamepadFocus(false);
    } catch (e) {
      AppLogger.warn(TAG, 'Desktop gamepad focus reset failed; continuing background release', e, LOG_DOMAIN_LAUNCH);
    }
    // 后台期间系统可能不再派发触摸 UP/CANCEL，必须在 Ability 边界同步释放所有持续输出。
    // 同 onDestroy：先对三端各说一次，再 native 兜底。
    getInputSourceRegistry().releaseAllEnds('game-ability-background')
    try { testNapi.cancelAllInput(2) } catch (e) { /* 老 native 兼容 */ }
    try {
      testNapi.setOhosFrameRateForeground(FRAME_RATE_FOREGROUND_SOURCE_GAME, false)
    } catch (e) { /* 老 native 兼容 */ }
    AppLogger.info(TAG, 'onBackground', LOG_DOMAIN_LAUNCH);
  }
}
