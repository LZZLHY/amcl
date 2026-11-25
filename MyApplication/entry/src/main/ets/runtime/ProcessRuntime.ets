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
import { ValidationTransportPort } from '../devtools/RuntimeDownloadValidation';
import {
  setDownloadNativeEngine, DownloadNativeEngine,
  NativeFetchTextResult, NativeTaskInfo, TransferProbeResult,
  DownloadTaskSpec, DownloadProgressEvent, DownloadCompleteEvent,
  copyDownloadFileSpec,
  setForgeNativeBridge, ForgeNativeBridge,
} from 'feature_core';
import { removeDirRecursive } from 'commons';
import { AppLogger } from 'commons';
import { NativeLogSink } from 'commons';
import { LedgerScopeSink, setLedgerScopeSink, ledgerBeginAsync, LedgerBeginMeta, configureLedgerMaintenanceOwner } from 'commons';
import { LogTags } from 'commons';
import { LOG_DOMAIN_LAUNCH } from 'commons';
import { SessionMarker, McSessionInfo } from 'launch';
import { setLaunchNativeBridge, LaunchNativeBridge } from 'launch';
import { setRuntimeSlotNativeOps, RuntimeSlotNativeOps } from 'launch';
import { setJdkInstallNativeOps, JdkInstallNativeOps } from 'launch';
import { getInputDeviceMonitor } from 'gamecontrol';
import { setControlNativeSink, ControlNativeSink, LookConfiguration, LookPolicySource } from 'gamecontrol';
import { getInputSourceRegistry } from 'gamecontrol';
import { setSystemNativeBridge, SystemNativeBridge } from 'feature_system';
import { GameStorage, PreferenceManager } from 'feature_system';
import { ModAudioRuntime } from './ModAudioRuntime';

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
  /** 工作线程确认文件和 scope 已准备；错误继续交给业务 owner 保留未准入与重试状态。 */
  async beginAsync(activityId: number, dir: string): Promise<boolean> {
    return await testNapi.amclLedgerBeginAsync(activityId, dir);
  }
  end(activityId: number): void {
    try { testNapi.amclLedgerEnd(activityId); } catch (e) { AppLogger.warn('DesktopGame', 'Ledger end failed', e, LOG_DOMAIN_LAUNCH); }
  }
  /** 真正等待native writer关闭；拒绝/超时继续抛给账本owner，不能catch后冒称关闭成功。 */
  async endAsync(activityId: number): Promise<void> { await testNapi.amclLedgerEndAsync(activityId); }
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
  // 跨HAR只传完整参数快照；native一次校验/一次加锁，false交还配置投递器保留待应用状态。
  applyLookConfiguration(config: LookConfiguration): boolean {
    return testNapi.applyLookConfiguration(config.sensitivity, config.invertY, config.smoothing, config.acceleration);
  }
  /** HAR来源名显式映射platform枚举；外部兼容0不能冒称物理设备，物理键鼠实际为3。 */
  applySourceLookConfiguration(source: LookPolicySource, config: LookConfiguration): boolean {
    const nativeSource: number = source === 'physical' ? 3 : source === 'touch' ? 1 : source === 'gamepad' ? 2 : 0;
    return testNapi.applySourceLookConfiguration(nativeSource, config.sensitivity, config.invertY,
      config.smoothing, config.acceleration);
  }
}

/**
 * 同上（D1=方案 a）：download 域的 DownloadManager 不直接依赖 libentry.so，
 * 由本 HAP 注入下载引擎实现（testNapi.download* 适配）。详见 DownloadManager.DownloadNativeEngine。
 */
export class EntryDownloadEngine implements DownloadNativeEngine, ValidationTransportPort {
  private validationTransport_: ((url: string) => string) | null = null;
  private transportUsed_: boolean = false;
  /** 只在default进程第一次网络操作前安装传输夹具；生产HAR业务完全不感知该入口。 */
  installValidationTransport(resolver: (url: string) => string): void {
    if (!DiagnosticPolicy.hasTestHooks() || this.transportUsed_ || this.validationTransport_ !== null) throw new Error('运行时验收传输不允许在此进程阶段启用');
    this.validationTransport_=resolver;
  }
  private transportUrl_(url: string): string {
    this.transportUsed_=true;
    return this.validationTransport_ === null ? url : this.validationTransport_(url);
  }
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
            requestHeaders?: Record<string, string>, maxResponseBytes?: number,
            allowRelay: boolean = false): Promise<NativeFetchTextResult> {
    // 第六参显式透传到Native；只在JS包装器新增选项却漏掉本桥会令真机仍然直连。
    // 缺省false使现有metadata消费者不受本次JDK目录路由修复影响。
    const primary=this.transportUrl_(primaryUrl), mapped=mirrors.map((url: string): string => this.transportUrl_(url));
    const changed=primary !== primaryUrl || mapped.some((url: string,index: number): boolean => url !== mirrors[index]);
    if (changed && requestHeaders !== undefined && Object.keys(requestHeaders).some((key: string): boolean => ['authorization','cookie'].indexOf(key.toLowerCase()) >= 0)) {
      throw new Error('授权请求不能进入运行时验收回环');
    }
    return testNapi.downloadFetchText(primary, mapped, timeoutSeconds, requestHeaders, maxResponseBytes, changed ? false : allowRelay);
  }
  createTask(spec: DownloadTaskSpec): number {
    this.transportUsed_=true;
    if (this.validationTransport_ === null) return testNapi.downloadCreateTask(spec);
    const copy: DownloadTaskSpec={name:spec.name,files:spec.files.map(file=>{
      const cloned=copyDownloadFileSpec(file);
      cloned.urls=file.urls.map((url: string): string => this.transportUrl_(url));
      if (cloned.urls.some((url: string,index: number): boolean => url !== file.urls[index]) && (file.bearerToken !== undefined || file.authorizedPolicy !== undefined)) {
        throw new Error('授权下载不能进入运行时验收回环');
      }
      return cloned;
    })};
    if (spec.activityId !== undefined) copy.activityId=spec.activityId;
    return testNapi.downloadCreateTask(copy);
  }
  /** 测量入口逐参交给Native，不能误用fetchText的字符串体积错误作为下载成功。 */
  probeTransfer(url: string, expectedSize: number, sampleBytes: number, timeoutSeconds: number,
    userAgent: string): Promise<TransferProbeResult> {
    return testNapi.downloadProbeTransfer(this.transportUrl_(url), expectedSize, sampleBytes, timeoutSeconds, userAgent);
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
                   workDir: string, logFile: string, requestId?: string, timeoutMs?: number): Promise<number> {
    return testNapi.runJavaProcessor(filesDir, jdkVersion, xmxMb, classpath, mainClass, args, workDir, logFile,
      requestId, timeoutMs);
  }
  /** 只提交意图，Native Promise 在精确 wait 回收后才完成。 */
  cancelJavaProcessor(requestId: string): boolean { return testNapi.cancelJavaProcessor(requestId); }
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
  /** 存储目录确认属于所有产品，直接使用独占临时文件探针。 */
  verifyGameDirectoryWritable(directory: string): boolean {
    return testNapi.verifyGameDirectoryWritable(directory);
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

/** JDK 安装只经当前进程的原生边界执行，异步 I/O 不持有 Context/NAPI 对象到 worker。 */
class EntryJdkInstallStore implements JdkInstallNativeOps {
  operation(action: string, filesDir: string, major: string, path: string, writerFd: number, useFd: number): string {
    return testNapi.jdkInstallOperation(action, filesDir, major, path, writerFd, useFd);
  }
  extract(archive: string, stage: string, archiveSha256: string, timeoutMs: number): Promise<boolean> {
    return testNapi.jdkInstallExtract(archive, stage, archiveSha256, timeoutMs);
  }
  seal(root: string, major: string, archiveSha256: string): Promise<boolean> {
    return testNapi.jdkInstallSeal(root, major, archiveSha256);
  }
}

/** 每个应用进程必须在消费者运行前安装自己的 HAR 端口；不复用另一个进程的函数对象。 */
export function installProcessNativeBridges(): EntryDownloadEngine {
  // 输入来源的 Native 端口归进程装配；前端重建不再替换持有这份函数表的权威。
  getInputSourceRegistry().setNativeSink({
    releaseSourceHeld: (source: number): void => { testNapi.releaseSourceHeld(source); },
    noteSourceReset: (source: number): void => { testNapi.noteSourceReset(source); }
  });
  setRuntimeSlotNativeOps(new EntryRuntimeSlotStore());
  setJdkInstallNativeOps(new EntryJdkInstallStore());
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
  // 游戏只拥有本局writer和发布journal；全账本索引/淘汰始终由启动器owner合并执行。
  configureLedgerMaintenanceOwner(false);
  try {
    testNapi.amclLogInit(context.filesDir + '/logs/game', 2 * 1024 * 1024, 5);
    AppLogger.setNativeLogSink(new EntryNativeLogSink());
  } catch (error) { AppLogger.warn('DesktopGame', 'Game log initialization failed', error, LOG_DOMAIN_LAUNCH); }
}

/**
 * 仅在私有启动快照验证并安装后读取游戏偏好、注册HAR端口和初始化输入。
 * 持久日志已由GameAbility更早开启，此处不重复初始化writer，避免旋转/覆盖启动失败证据。
 * 本局scope真实异步开账结果兑现后才安装运行时；日志失败按游戏既有契约明确降级继续，
 * 不能把诊断故障升级为游戏不可用。isCurrent由Ability世代提供，
 * 销毁后的异步开账可以留下可恢复原件，但不得继续挂接音频、输入或发布页面所需状态。
 */
export async function initializeGameProcess(context: common.UIAbilityContext,
  activityId: number = 0, launchMeta?: LedgerBeginMeta, isCurrent?: () => boolean): Promise<void> {
  configureLedgerMaintenanceOwner(false);
  DiagnosticPolicy.configure(ProductBuildProfile.developerDiagnostics, testNapi.getDiagnosticCapabilities());
  DistributionPolicy.configure(ProductBuildProfile.storeChannel ? DistributionChannel.Store : DistributionChannel.Sideload);
  if (isCurrent !== undefined && !isCurrent()) throw new Error('游戏进程初始化已取消');
  setLedgerScopeSink(new EntryLedgerScopeSink());
  // 快照通过后才有可承认的本局身份，此处打开会话scope。更早的进程创建/快照失败
  // 已由游戏进程独立日志留存，不在未验证的activityId下提前建立账本。
  // activityId=0 保留给独立诊断/旧调用方，不创建虚假游戏活动。
  if (activityId > 0 && launchMeta !== undefined) {
    let captureIssue: string = '';
    try {
      if (!await ledgerBeginAsync(context.filesDir, activityId, launchMeta)) captureIssue = '本局活动日志基线未能建立';
    } catch (error) {
      captureIssue = '本局活动日志开账失败：' + ((error as Error).message ?? '未知存储错误');
    }
    // 取消属于生命周期失效，不能被上方诊断故障降级catch吞掉，也不能继续装配任何producer。
    if (isCurrent !== undefined && !isCurrent()) throw new Error('游戏进程初始化已取消');
    AppStorage.setOrCreate<number>('gameLedgerCaptureIssueActivityId', activityId);
    AppStorage.setOrCreate<string>('gameLedgerCaptureIssue', captureIssue);
    if (captureIssue.length > 0) {
      // 游戏既有契约允许诊断降级；保留全局writer和现有原件，明确记录本局缺口，不冒称完整。
      // 日志端口本身失效也不能把捕获故障升级成新的游戏启动失败。
      try { AppLogger.warn('DesktopGame', captureIssue + '；继续启动，捕获完整性降级', undefined, LOG_DOMAIN_LAUNCH, activityId); }
      catch (_) { /* 现有全局/平台原件仍由原恢复链收集，不覆盖或删除。 */ }
    }
  }
  if (isCurrent !== undefined && !isCurrent()) throw new Error('游戏进程初始化已取消');
  ProductInputProfile.initialize(context);
  AppStorage.setOrCreate<common.UIAbilityContext>('uiAbilityContext', context);
  // 独立进程只在快照和异步scope基线确认后装配音频；迟到续体不能复活已销毁Ability。
  ModAudioRuntime.attach(context);
  AppStorage.setOrCreate<ConfigurationConstant.ColorMode>('currentColorMode', context.config.colorMode);
  installProcessNativeBridges();
  DownloadManager.instance().initializeCaBundle(context);
  const preferences: PreferenceManager = new PreferenceManager(context);
  GameStorage.setPhoneExternalDir(preferences.phoneExternalDir);
  getInputDeviceMonitor().ensureStarted();
}
