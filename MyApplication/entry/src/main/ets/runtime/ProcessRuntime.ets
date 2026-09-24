import { setRelayNativeBridge, RelayStatsNative, RelayNativeBridge } from 'feature_core';
import { ProductBuildProfile } from 'entry/ProductBuildProfile';
import { ProductInputProfile } from 'entry/ProductInputProfile';
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
import { LedgerScopeSink, setLedgerScopeSink, ledgerResolveStale, ledgerBegin, LedgerBeginMeta } from 'commons';
import { LogTags } from 'commons';
import { LOG_DOMAIN_LAUNCH } from 'commons';
import { SessionMarker, McSessionInfo } from 'launch';
import { setLaunchNativeBridge, LaunchNativeBridge } from 'launch';
import { setRuntimeSlotNativeOps, RuntimeSlotNativeOps } from 'launch';
import { getInputDeviceMonitor } from 'gamecontrol';
import { setControlNativeSink, ControlNativeSink } from 'gamecontrol';
import { getInputSourceRegistry } from 'gamecontrol';
import { setSystemNativeBridge, SystemNativeBridge } from 'feature_system';
import { GameStorage, PreferenceManager } from 'feature_system';

class EntryRelayNativeBridge implements RelayNativeBridge {
  configure(base: string, ticket: string, key: string, proof: boolean, expires: number): void {
    testNapi.downloadSetRelay(base, ticket, key, proof, expires);
  }
  clear(): void { testNapi.downloadClearRelay(); }
  stats(): RelayStatsNative {
    const value = testNapi.downloadRelayStats();
    const stats: RelayStatsNative = { requests: value.requests, failures: value.failures,
      fallbacks: value.fallbacks, authRejects: value.authRejects,
      tripped: value.tripped, usable: value.usable };
    return stats;
  }
}



/**
 * 三层架构重构（D1=方案 a / 控制反转）：commons 的 AppLogger 不直接依赖 libentry.so，
 * 由本 HAP（持有 native）注入 testNapi 落盘实现。详见 AppLogger.NativeLogSink。
 */
/**
 * 活动账本的 native scope 实现（活动账本 · L1-c）。
 *
 * 与 NativeLogSink 同一套控制反转理由：commons 不能直接依赖 libentry.so。
 */
export class EntryLedgerScopeSink implements LedgerScopeSink {
  begin(activityId: number, dir: string): boolean {
    try { return testNapi.amclLedgerBegin(activityId, dir); } catch (e) { return false; }
  }
  end(activityId: number): void {
    try { testNapi.amclLedgerEnd(activityId); } catch (e) { AppLogger.warn('DesktopGame', 'Ledger end failed', e, LOG_DOMAIN_LAUNCH); }
  }
  endAll(): void {
    try { testNapi.amclLedgerEndAll(); } catch (e) { AppLogger.warn('DesktopGame', 'Ledger cleanup failed', e, LOG_DOMAIN_LAUNCH); }
  }
}

export class EntryNativeLogSink implements NativeLogSink {
  write(level: number, tag: string, message: string, activityId: number): void {
    // activityId 透传到 native（活动账本 · L2-a）：非 0 时该行会同时落进
    // ledger/<activityId>/launcher.log。ArkTS 侧必须显式带，见 ActivityLogger 注释。
    testNapi.amclLogWrite(level, tag, message, activityId);
  }
  flush(): void {
    testNapi.amclLogFlush();
  }
  getPath(): string {
    return testNapi.amclLogGetPath();
  }
  /** 仅查询当前进程 writer 的健康状态，不混同于历史活动的完整性。 */
  getStatus(): string { return testNapi.amclLogGetStatus(); }
}

/**
 * 同上（D1=方案 a）：gamecontrol 的 LayoutStore 不直接依赖 libentry.so，
 * 由本 HAP 注入控制层 native 参数实现。详见 LayoutStore.ControlNativeSink。
 */
class EntryControlNativeSink implements ControlNativeSink {
  setLookSensitivity(v: number): void {
    testNapi.setLookSensitivity(v);
  }
  setInvertY(v: boolean): void {
    testNapi.setInvertY(v);
  }
  // 方案 C（2026-07-11）：视角平滑 α + 加速强度注入 native（applyLookDelta 统一对三源生效）。
  setLookSmoothing(v: number): void {
    testNapi.setLookSmoothing(v);
  }
  setLookAccel(v: number): void {
    testNapi.setLookAccel(v);
  }
}

/**
 * 同上（D1=方案 a）：download 域的 DownloadManager 不直接依赖 libentry.so，
 * 由本 HAP 注入下载引擎实现（testNapi.download* 适配）。详见 DownloadManager.DownloadNativeEngine。
 */
export class EntryDownloadEngine implements DownloadNativeEngine {
  setCaBundle(path: string): void {
    testNapi.downloadSetCaBundle(path);
  }
  computeFileSha1(path: string): string {
    return testNapi.downloadComputeFileSha1(path);
  }
  publishNoReplace(sourcePath: string, destinationPath: string): boolean {
    return testNapi.downloadPublishNoReplace(sourcePath, destinationPath);
  }
  fetchText(primaryUrl: string, mirrors: string[], timeoutSeconds: number,
            requestHeaders?: Record<string, string>, maxResponseBytes?: number): Promise<NativeFetchTextResult> {
    return testNapi.downloadFetchText(primaryUrl, mirrors, timeoutSeconds, requestHeaders, maxResponseBytes);
  }
  createTask(spec: DownloadTaskSpec): number {
    return testNapi.downloadCreateTask(spec);
  }
  bindActivity(taskId: number, activityId: number): void {
    testNapi.amclLedgerBindTask(taskId, activityId);
  }
  unbindActivity(taskId: number): void {
    testNapi.amclLedgerUnbindTask(taskId);
  }
  onProgress(taskId: number, cb: (ev: DownloadProgressEvent) => void): boolean {
    return testNapi.downloadOnProgress(taskId, cb);
  }
  onComplete(taskId: number, cb: (ev: DownloadCompleteEvent) => void): boolean {
    return testNapi.downloadOnComplete(taskId, cb);
  }
  start(taskId: number): boolean {
    return testNapi.downloadStart(taskId);
  }
  cancel(taskId: number): boolean {
    return testNapi.downloadCancel(taskId);
  }
  pause(taskId: number): boolean {
    return testNapi.downloadPauseTask(taskId);
  }
  resume(taskId: number): boolean {
    return testNapi.downloadResumeTask(taskId);
  }
  deleteTaskFiles(taskId: number): number {
    return testNapi.downloadDeleteTaskFiles(taskId);
  }
  retryFailed(taskId: number, localPaths: string[]): boolean {
    return testNapi.downloadRetryFailed(taskId, localPaths);
  }
  purgeTask(taskId: number): boolean {
    return testNapi.downloadPurgeTask(taskId);
  }
  listActive(): NativeTaskInfo[] {
    return testNapi.downloadListActive();
  }
  queryTask(taskId: number): NativeTaskInfo | null {
    return testNapi.downloadQueryTask(taskId);
  }
  shutdown(): void {
    testNapi.downloadShutdown();
  }
}

/**
 * 同上（D1=方案 a）：feature_core/modloader 的 ForgeService 不直连 libentry.so，
 * 由本 HAP 注入 Forge 安装相关 native 实现。详见 ForgeService.ForgeNativeBridge。
 */
class EntryForgeNativeBridge implements ForgeNativeBridge {
  checkJitAvailable(): boolean {
    return testNapi.checkJitAvailable();
  }
  getRecommendedXmx(): number {
    return testNapi.getRecommendedXmx();
  }
  runJavaProcessor(filesDir: string, jdkVersion: string, xmxMb: number,
                   classpath: string, mainClass: string, args: string[],
                   workDir: string, logFile: string): Promise<number> {
    return testNapi.runJavaProcessor(filesDir, jdkVersion, xmxMb, classpath, mainClass, args, workDir, logFile);
  }
}

/**
 * 同上（D1=方案 a）：feature_system 的 StorageProbe/VulkanCapability 不直连 libentry.so，
 * 由本 HAP 注入 system native 实现。详见 SystemNativeBridge。
 */
class EntrySystemNativeBridge implements SystemNativeBridge {
  getVulkanCapabilityJson(): string {
    return testNapi.getVulkanCapabilityJson();
  }
  /** 只转发已有设备检查，不维护扩展/特性名单；true 保证下载详情页不会占用窗口。 */
  getMinecraftVulkanDeviceCapabilityJson(requirementId: string, windowProvider: string): string {
    return testNapi.getGraphicsCapabilityJson('minecraft-vulkan', requirementId, windowProvider, true);
  }
  probeNativePath(probeDir: string): string {
    if (!DiagnosticPolicy.hasTestHooks()) return 'ERR: developer test hooks unavailable';
    return testNapi.probeNativePath(probeDir);
  }
}

/**
 * 同上（D1=方案 a）：launch 域的 LaunchProfileBuilder/PreLaunchValidator 不直连 libentry.so，
 * 由本 HAP 注入 launch native 实现（JVM 公共参数 SSOT + JIT 探测）。详见 LaunchNativeBridge。
 */
class EntryLaunchNativeBridge implements LaunchNativeBridge {
  getCommonJvmArgs(): string[] {
    return testNapi.getCommonJvmArgs() as string[];
  }
  checkJitAvailable(): boolean {
    return testNapi.checkJitAvailable();
  }
}


/** HAR 通过显式适配类访问当前进程的 native 存储器，避免接口方法被当作函数属性赋值。 */
class EntryRuntimeSlotStore implements RuntimeSlotNativeOps {
  createStage(destination: string): string { return testNapi.runtimeSlotCreateStage(destination); }
  publish(stage: string, destination: string): void { testNapi.runtimeSlotPublish(stage, destination); }
  discardStage(stage: string): void { testNapi.runtimeSlotDiscardStage(stage); }
  acquire(directory: string): string { return testNapi.runtimeSlotAcquire(directory); }
  release(handle: string): boolean { return testNapi.runtimeSlotRelease(handle); }
  retire(directory: string): boolean { return testNapi.runtimeSlotRetire(directory); }
  collect(activeDirectory: string): number { return testNapi.runtimeSlotCollect(activeDirectory); }
}

/** 每个应用进程必须在消费者运行前安装自己的 HAR 端口；不复用另一个进程的函数对象。 */
export function installProcessNativeBridges(): EntryDownloadEngine {
  setRuntimeSlotNativeOps(new EntryRuntimeSlotStore());
  const engine: EntryDownloadEngine = new EntryDownloadEngine();
  setControlNativeSink(new EntryControlNativeSink());
  setDownloadNativeEngine(engine);
  setRelayNativeBridge(new EntryRelayNativeBridge());
  setForgeNativeBridge(new EntryForgeNativeBridge());
  setSystemNativeBridge(new EntrySystemNativeBridge());
  setLaunchNativeBridge(new EntryLaunchNativeBridge());
  return engine;
}

/**
 * GameAbility通过native PID/独占锁确认隔离后立即调用，早于快照解析和任何游戏配置读取。
 * 不读取Preferences、不建立输入/图形运行时，也不碰启动器日志文件。失败保留hilog，
 * 不能因日志不可写跳过后续必要的native bridge安装；不能在未隔离的进程里调用。
 */
export function initializeGameProcessLogging(context: common.UIAbilityContext): void {
  try {
    testNapi.amclLogInit(context.filesDir + '/logs/game', 2 * 1024 * 1024, 5);
    AppLogger.setNativeLogSink(new EntryNativeLogSink());
  } catch (error) { AppLogger.warn('DesktopGame', 'Game log initialization failed', error, LOG_DOMAIN_LAUNCH); }
}

/**
 * 仅在私有启动快照验证并安装后读取游戏偏好、注册HAR端口和初始化输入。
 * 持久日志已由GameAbility更早开启，此处不重复初始化writer，避免旋转/覆盖启动失败证据。
 */
export function initializeGameProcess(context: common.UIAbilityContext,
  activityId: number = 0, launchMeta?: LedgerBeginMeta): void {
  DiagnosticPolicy.configure(ProductBuildProfile.developerDiagnostics, testNapi.getDiagnosticCapabilities());
  DistributionPolicy.configure(ProductBuildProfile.storeChannel ? DistributionChannel.Store : DistributionChannel.Sideload);
  ProductInputProfile.initialize(context);
  AppStorage.setOrCreate<common.UIAbilityContext>('uiAbilityContext', context);
  AppStorage.setOrCreate<ConfigurationConstant.ColorMode>('currentColorMode', context.config.colorMode);
  setLedgerScopeSink(new EntryLedgerScopeSink());
  // 快照通过后才有可承认的本局身份，此处打开会话scope。更早的进程创建/快照失败
  // 已由游戏进程独立日志留存，不在未验证的activityId下提前建立账本。
  // activityId=0 保留给独立诊断/旧调用方，不创建虚假游戏活动。
  if (activityId > 0 && launchMeta !== undefined) {
    ledgerBegin(context.filesDir, activityId, launchMeta);
  }
  installProcessNativeBridges();
  DownloadManager.instance().initializeCaBundle(context);
  const preferences: PreferenceManager = new PreferenceManager(context);
  GameStorage.setPhoneExternalDir(preferences.phoneExternalDir);
  const nativePad: boolean = preferences.desktopNativeGamepad;
  const padReady: boolean = testNapi.desktopSetGamepadNativeMode(nativePad);
  AppStorage.setOrCreate<boolean>('nativeGamepadOutputActive', nativePad && padReady);
  if (nativePad && !padReady) AppLogger.warn('DesktopGamepad', 'Native gamepad unavailable; launcher mapping retained', undefined, LOG_DOMAIN_LAUNCH);
  getInputDeviceMonitor().ensureStarted();
}
