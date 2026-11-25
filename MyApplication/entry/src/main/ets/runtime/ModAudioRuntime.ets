/**
 * 模组音频的权限与 Ability 生命周期协调。偏好只保存用户意图；系统权限每次由 Native
 * AccessToken 查询。此类不录音、不传 PCM、不向 Java 线程同步弹窗，也不持有跨进程对象。
 */
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { AppLogger, LOG_DOMAIN_LAUNCH } from 'commons';
import { PreferenceManager } from 'feature_system';
import testNapi from 'libentry.so';
import { ModAudioPolicyStore } from './ModAudioPolicyStore';

const MICROPHONE: Permissions = 'ohos.permission.MICROPHONE';

export class ModAudioRuntime {
  private static context: common.UIAbilityContext | undefined = undefined;
  private static manager: abilityAccessCtrl.AtManager | undefined = undefined;
  private static preferences: PreferenceManager | undefined = undefined;
  private static foreground: boolean = false;
  private static generation: number = 0;
  /** 同一设置可由重建前后的视图请求；最新意图退休旧权限回包，关闭在提交期间仍优先拒绝。 */
  private static intentRevision: number = 0;
  private static pendingIntent: boolean | undefined = undefined;
  private static permissionListener: (change: abilityAccessCtrl.PermissionStateChangeInfo) => void =
    (_change: abilityAccessCtrl.PermissionStateChangeInfo): void => { ModAudioRuntime.refresh(); };

  /** 当前进程的真实 Ability 装配一次监听；独立游戏进程必须在快照安装后调用。 */
  static attach(context: common.UIAbilityContext): void {
    if (ModAudioRuntime.context === context) return;
    ModAudioRuntime.detach();
    ModAudioRuntime.context = context;
    ModAudioRuntime.preferences = new PreferenceManager(context);
    // 两进程共同读取同一模块私有目录；游戏只消费原owner记录，绝不把启动快照写回政策。
    try {
      ModAudioPolicyStore.ensure(context, ModAudioRuntime.preferences.modMicrophoneEnabled);
      if (!testNapi.audioConfigurePolicyRoot(context.filesDir)) throw new Error('音频政策根不可用');
    } catch (error) { AppLogger.warn('ModAudio', '无法建立跨进程录音政策，采集保持关闭', error, LOG_DOMAIN_LAUNCH); }
    ModAudioRuntime.manager = abilityAccessCtrl.createAtManager();
    try { ModAudioRuntime.manager.on('selfPermissionStateChange', [MICROPHONE], ModAudioRuntime.permissionListener); }
    catch (error) { AppLogger.warn('ModAudio', '麦克风权限监听未建立', error, LOG_DOMAIN_LAUNCH); }
    ModAudioRuntime.refresh();
  }

  /** 只更新 UI 状态；真实采集仍由 Native 在每次 open/start 查询，缓存不能授权录音。 */
  static permissionGranted(): boolean {
    const context: common.UIAbilityContext | undefined = ModAudioRuntime.context;
    if (context === undefined || ModAudioRuntime.manager === undefined) return false;
    try {
      return ModAudioRuntime.manager.checkAccessTokenSync(context.applicationInfo.accessTokenId, MICROPHONE)
        === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (_) { return false; }
  }

  /** 当前确认的用户意图可来自原 owner 或独立游戏只读快照。 */
  static enabled(): boolean { return ModAudioRuntime.preferences?.modMicrophoneEnabled ?? false; }

  /** Skill 回读单独报告无法读取；Native 的采集拒绝仍沿用原来的保守检查。 */
  static strictAccess(): Record<string,Object> {
    const ctx=ModAudioRuntime.context, manager=ModAudioRuntime.manager, prefs=ModAudioRuntime.preferences;
    if (!ctx || !manager || !prefs) return {'state':'unknown','reason':'audioOwnerUnavailable'};
    try {
      const enabled=prefs.strictLauncherField('modMicrophoneEnabled');
      const permission=manager.checkAccessTokenSync(ctx.applicationInfo.accessTokenId,MICROPHONE);
      if (permission!==abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED && permission!==abilityAccessCtrl.GrantStatus.PERMISSION_DENIED) {
        return {'state':'unknown','reason':'permissionUnknown'};
      }
      return {'state':'ready','enabled':enabled,'permissionGranted':permission===abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED};
    } catch (_) { return {'state':'unknown','reason':'audioStateUnreadable'}; }
  }

  /** 把最新事实交给 Native；同步原子拒绝先发生，设备收敛通过 Promise 离开 UI 线程。 */
  static refresh(): void {
    // 旧视图已授权的持久事务可在新Ability挂接后完成。只有没有在途关闭意图时，当前
    // 原owner按确认值收敛共享记录；游戏只读快照进程的ensure始终为空操作。
    if (ModAudioRuntime.context !== undefined && ModAudioRuntime.pendingIntent === undefined) {
      try { ModAudioPolicyStore.ensure(ModAudioRuntime.context, ModAudioRuntime.enabled()); }
      catch (error) { AppLogger.warn('ModAudio', '录音政策确认态未收敛，采集保持拒绝', error, LOG_DOMAIN_LAUNCH); }
    }
    AppStorage.setOrCreate<boolean>('modAudioUserEnabled', ModAudioRuntime.enabled());
    AppStorage.setOrCreate<boolean>('modAudioPermissionGranted', ModAudioRuntime.permissionGranted());
    try {
      testNapi.audioSetPolicy(ModAudioRuntime.pendingIntent === false ? false : ModAudioRuntime.enabled(), ModAudioRuntime.foreground).then((result: number): void => {
        if (result !== 0) AppLogger.warn('ModAudio', '音频政策应用失败，code=' + result, undefined, LOG_DOMAIN_LAUNCH);
      }).catch((error: Error): void => {
        AppLogger.warn('ModAudio', '音频政策未完成', error, LOG_DOMAIN_LAUNCH);
      });
    } catch (error) { AppLogger.warn('ModAudio', '音频政策桥不可用', error, LOG_DOMAIN_LAUNCH); }
  }

  /** 后台只撤销采集资格，不把 UI 焦点等同授权；重新前台也不自动打开录音设备。 */
  static setForeground(foreground: boolean): void {
    ModAudioRuntime.foreground = foreground;
    ModAudioRuntime.refresh();
  }

  /**
   * 仅显式设置操作可以请求权限。权限响应绑定当前 Ability 代次，页面销毁后的旧回包不启用。
   * 偏好保存确认后才发布开启；关闭则立即撤销，避免等待 flush 期间继续使用麦克风。
   */
  static async setEnabled(enabled: boolean, beforePermission?: () => void): Promise<void> {
    const context: common.UIAbilityContext | undefined = ModAudioRuntime.context;
    const preferences: PreferenceManager | undefined = ModAudioRuntime.preferences;
    if (context === undefined || preferences === undefined) throw new Error('无法取得当前应用上下文，请重试');
    const generation: number = ModAudioRuntime.generation;
    const revision: number = ++ModAudioRuntime.intentRevision;
    ModAudioRuntime.pendingIntent = enabled;
    try {
      if (!enabled) {
        // 共享撤销先于私有偏好提交；正在独立进程采集的旧局也能观察到epoch变化。
        ModAudioPolicyStore.publish(context, false);
        try {
          const result: number = await testNapi.audioSetPolicy(false, ModAudioRuntime.foreground);
          if (result !== 0) throw new Error('audio policy code=' + result);
        }
        catch (error) { throw new Error('暂时无法关闭录音，请退出游戏后重试'); }
      }
      if (enabled && !ModAudioRuntime.permissionGranted()) {
        const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
        if (beforePermission) beforePermission();
        const result = await manager.requestPermissionsFromUser(context, [MICROPHONE]);
        if (result.authResults.length !== 1 || result.authResults[0] !== 0) {
          throw new Error('系统未授予麦克风权限，请在系统设置中允许后重试');
        }
      }
      if (ModAudioRuntime.context !== context || generation !== ModAudioRuntime.generation || revision !== ModAudioRuntime.intentRevision)
        throw new Error('授权操作已过期，请重新打开设置');
      await preferences.setModMicrophoneEnabled(enabled);
      if (ModAudioRuntime.context === context && generation === ModAudioRuntime.generation && revision === ModAudioRuntime.intentRevision && enabled) {
        ModAudioPolicyStore.publish(context, true);
      }
    } finally {
      if (ModAudioRuntime.context === context && generation === ModAudioRuntime.generation && revision === ModAudioRuntime.intentRevision) {
        ModAudioRuntime.pendingIntent = undefined;
        ModAudioRuntime.refresh();
      } else if (ModAudioRuntime.context !== undefined && ModAudioRuntime.context.preferencesDir === context.preferencesDir) {
        // 已开始的owner提交不能依赖旧视图寿命；只刷新同一真实owner，不携旧授权或旧开关值。
        ModAudioRuntime.refresh();
      }
    }
  }

  /** Ability 退役先拒绝 Native 采集，再解除监听和 Context；不在 UI 上等待设备释放。 */
  static detach(): void {
    ModAudioRuntime.generation++;
    ModAudioRuntime.intentRevision++;
    ModAudioRuntime.pendingIntent = undefined;
    ModAudioRuntime.foreground = false;
    try {
      testNapi.audioSetPolicy(false, false).catch((error: Error): void => {
        AppLogger.warn('ModAudio', '退役音频政策未完成', error, LOG_DOMAIN_LAUNCH);
      });
    } catch (error) { AppLogger.warn('ModAudio', '退役音频政策桥不可用', error, LOG_DOMAIN_LAUNCH); }
    if (ModAudioRuntime.manager !== undefined) {
      try { ModAudioRuntime.manager.off('selfPermissionStateChange', [MICROPHONE], ModAudioRuntime.permissionListener); }
      catch (_) {}
    }
    ModAudioRuntime.manager = undefined;
    ModAudioRuntime.context = undefined;
    ModAudioRuntime.preferences = undefined;
  }
}
