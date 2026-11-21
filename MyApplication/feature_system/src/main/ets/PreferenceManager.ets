/**
 * PreferenceManager.ets — 统一偏好设置管理
 *
 * 封装 HarmonyOS preferences API，提供类型安全的读写接口。
 * 所有设置项集中管理，避免 get/put key 字符串分散在各处。
 */

import { ProcessPreferences, LaunchPreferenceStore, LaunchPreferenceValue, LaunchPreferenceSnapshot } from 'commons';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ThemeMode, ThemeAccent, ThemeSelection, THEME_SELECTION_KEY,
  decodeThemeSelection, encodeThemeSelection, normalizeThemeMode, normalizeThemeAccent } from 'commons';
import { DockLightMode, normalizeDockLightMode } from 'commons';
import { ImmersiveLightPreferences, migrateImmersiveLightPreferences,
  decodeImmersiveLightPreferences, encodeImmersiveLightPreferences } from 'commons';
import { SUPPORTED_JDK_VERSION, isJdkSlotVersion, JDK_AUTO } from 'commons';
import { DEFAULT_GAME_LANGUAGE, normalizeGlobalGameLanguage } from 'commons';
import { formatError } from 'commons';
import { normalizeResolutionPreference } from 'commons';
import { DEFAULT_PHONE_SHEET_HEIGHT_PERCENT, PHONE_SHEET_HEIGHT_STORAGE_KEY, normalizePhoneSheetHeightPercent } from 'commons';

const TAG = 'PreferenceManager'
const PREF_NAME = 'amcl_settings'
const OHOS_FRAME_RATE_CAP_MIN: number = 30
const OHOS_FRAME_RATE_CAP_MAX: number = 240
const GAME_KEEP_SCREEN_ON_KEY: string = 'gameKeepScreenOn';
const IMMERSIVE_LIGHT_KEY: string = 'immersiveLightPreferences';
const IMMERSIVE_LIGHT_ABSENT: string = '__amcl_immersive_light_absent__';
/** 用非数字哨兵区分“从未设置”与默认 80；失败时能恢复原来的键缺失状态。 */
const PHONE_SHEET_HEIGHT_ABSENT: string = '__amcl_phone_sheet_height_absent__';

/** 同一偏好目录的写入队列与确认值屏障；独立页面的读取也不能看到在途缓存。 */
class ImmersiveLightWriteState {
  tail: Promise<void> = Promise.resolve();
  original: LaunchPreferenceValue | undefined = undefined;
}

/**
 * 仅两项冻结设置的原owner写事务。tail按同一Preferences目录串行保存与回滚；originals
 * 只保存正在提交或回滚未确认的旧值，供getter避开put已改但flush尚未确认的缓存。
 * 真正持久权威仍是amcl_settings；这里不创建第二份偏好或运行政策。不同owner取得不同
 * 对象，旧异步续体一直持原对象；普通组件重建/manager重建不清掉在途事务或磁盘未知态。
 */
class FrozenSettingsWriteState {
  tail: Promise<void> = Promise.resolve();
  originals: Map<string, LaunchPreferenceValue> = new Map<string, LaunchPreferenceValue>();
}

/** store选择独立串行保存；不扩大现有两项冻结输入设置的允许键集合。 */
class StoreDebugWriteState {
  tail: Promise<void> = Promise.resolve();
  original: boolean | undefined = undefined;
}

/**
 * 分辨率与单版本JVM参数共用的记录写入所有者。两者可能写同一个verLaunch键，必须
 * 使用同目录队列及确认屏障，不能各建队列互相覆盖。jvmKeys仅标记在途或回滚未知的
 * JVM字段；普通JDK/语言void写入口据此保留该字段，不扩大冻结输入设置的允许键集合。
 */
class ResolutionWriteState {
  tail: Promise<void> = Promise.resolve();
  originals: Map<string, LaunchPreferenceValue> = new Map<string, LaunchPreferenceValue>();
  jvmKeys: Set<string> = new Set<string>();
}

/**
 * 全局 JVM 参数的专用单键写入所有者。
 *
 * 同一真实 preferencesDir 下的 manager 共用队列与确认值屏障；页面重新挂载不能
 * 把 put 已修改、但 flush 尚未确认的缓存当成保存结果。原值只在提交或回滚未确认
 * 期间保留，持久权威仍是 amcl_settings，不创建第二份参数记录或扩大冻结输入键集合。
 */
class CustomJvmArgsWriteState {
  tail: Promise<void> = Promise.resolve();
  original: LaunchPreferenceValue | undefined = undefined;
}

/** 同一真实目录的主题事务；单键JSON把显示模式与强调色一起确认，失败屏障不跨owner迁移。 */
class ThemeSelectionWriteState {
  tail: Promise<void> = Promise.resolve();
  original: LaunchPreferenceValue | undefined = undefined;
}

/** 手机 Sheet 高度的同目录单键事务；只在保存/回滚未确认期间保留旧确认值。 */
class PhoneSheetHeightWriteState {
  tail: Promise<void> = Promise.resolve();
  original: LaunchPreferenceValue | undefined = undefined;
}

/** 麦克风意图的单键提交队列；同目录实例共用已确认基线，不发布在途 Preferences 缓存。 */
class ModMicrophoneWriteState {
  tail: Promise<void> = Promise.resolve();
  original: boolean | undefined = undefined;
}
/** App订阅值和用户选择代次共用同一owner队列；完成回放不能覆盖后来明确的用户选择。 */
class AppUpdateChannelWriteState {
  tail: Promise<void> = Promise.resolve();
  requestedRevision: number = 0;
  selectionPending: number = 0;
  originalChannel: string | undefined = undefined;
  originalRevision: number | undefined = undefined;
}

export class PreferenceManager {
  // 同一启动器目录的读者共享在途保存前的值，避免游戏拿到尚未确认的缓存。
  private static gameKeepScreenOnBeforeSave: Map<string, boolean> = new Map<string, boolean>();
  private static appUpdateChannelOwners: Map<string,AppUpdateChannelWriteState> = new Map<string,AppUpdateChannelWriteState>();
  private appUpdateChannelWrites: AppUpdateChannelWriteState | undefined = undefined;
  private static microphoneOwners: Map<string, ModMicrophoneWriteState> = new Map<string, ModMicrophoneWriteState>();
  private microphoneWrites: ModMicrophoneWriteState | undefined = undefined;
  private static resolutionOwners: Map<string, ResolutionWriteState> = new Map<string, ResolutionWriteState>();
  private resolutionWrites: ResolutionWriteState | undefined = undefined;
  /** 模块随真实进程重建；目录+固定PREF_NAME识别同一owner，不用UIContext对象猜一轮保存。 */
  private static frozenSettingOwners: Map<string, FrozenSettingsWriteState> = new Map<string, FrozenSettingsWriteState>();
  private static storeDebugOwners: Map<string, StoreDebugWriteState> = new Map<string, StoreDebugWriteState>();
  private storeDebugState: StoreDebugWriteState | undefined = undefined;
  private static immersiveLightOwners: Map<string, ImmersiveLightWriteState> = new Map<string, ImmersiveLightWriteState>();
  private immersiveLightWrites: ImmersiveLightWriteState | undefined = undefined;
  private static customJvmArgsOwners: Map<string, CustomJvmArgsWriteState> = new Map<string, CustomJvmArgsWriteState>();
  private customJvmArgsWrites: CustomJvmArgsWriteState | undefined = undefined;
  private static themeSelectionOwners: Map<string, ThemeSelectionWriteState> = new Map<string, ThemeSelectionWriteState>();
  private themeSelectionWrites: ThemeSelectionWriteState | undefined = undefined;
  private static phoneSheetHeightOwners: Map<string, PhoneSheetHeightWriteState> = new Map<string, PhoneSheetHeightWriteState>();
  private phoneSheetHeightWrites: PhoneSheetHeightWriteState | undefined = undefined;

  /** 只读已确认值；保存期间不把Preferences的临时缓存当下局可采用的选择。 */
  get desktopNativeGamepad(): boolean { return this.readFrozenSetting_('desktopNativeGamepad', false) as boolean; }

  private pref: LaunchPreferenceStore;
  private readonly preferencesDirectory: string;
  /** 档位 put 后到 flush 确认前的读取屏障，防止 onPageShow 发布 Preferences 在途缓存。 */
  private dockLightConfirmedDuringSave: DockLightMode | undefined = undefined;
  private frozenSettings: FrozenSettingsWriteState | undefined = undefined;

  constructor(context: Context) {
    this.pref = ProcessPreferences.open(context, PREF_NAME);
    // 游戏快照只读，不与启动器写事务共享读屏障。缺真实目录的旧只读调用方仍可读原store，
    // 但两项新保存入口明确拒绝，不能把undefined或组件实例名拼成虚假的Preferences owner。
    const directory: string = context.preferencesDir;
    this.preferencesDirectory = directory;
    if (!ProcessPreferences.isGameProcess() && typeof directory === 'string' && directory.length > 0) {
      let channelState=PreferenceManager.appUpdateChannelOwners.get(directory);
      if(channelState===undefined){channelState=new AppUpdateChannelWriteState();PreferenceManager.appUpdateChannelOwners.set(directory,channelState);}
      this.appUpdateChannelWrites=channelState;
      let microphoneState: ModMicrophoneWriteState | undefined = PreferenceManager.microphoneOwners.get(directory);
      if (microphoneState === undefined) {
        microphoneState = new ModMicrophoneWriteState();
        PreferenceManager.microphoneOwners.set(directory, microphoneState);
      }
      this.microphoneWrites = microphoneState;
      let resolution: ResolutionWriteState | undefined = PreferenceManager.resolutionOwners.get(directory);
      if (resolution === undefined) {
        resolution = new ResolutionWriteState();
        PreferenceManager.resolutionOwners.set(directory, resolution);
      }
      this.resolutionWrites = resolution;
      let state: FrozenSettingsWriteState | undefined = PreferenceManager.frozenSettingOwners.get(directory);
      if (state === undefined) {
        state = new FrozenSettingsWriteState();
        PreferenceManager.frozenSettingOwners.set(directory, state);
      }
      this.frozenSettings = state;
      let debugState = PreferenceManager.storeDebugOwners.get(directory);
      if (debugState === undefined) {
        debugState = new StoreDebugWriteState();
        PreferenceManager.storeDebugOwners.set(directory, debugState);
      }
      this.storeDebugState = debugState;
      let lightState: ImmersiveLightWriteState | undefined = PreferenceManager.immersiveLightOwners.get(directory);
      if (lightState === undefined) {
        lightState = new ImmersiveLightWriteState();
        PreferenceManager.immersiveLightOwners.set(directory, lightState);
      }
      this.immersiveLightWrites = lightState;
      let jvmState: CustomJvmArgsWriteState | undefined = PreferenceManager.customJvmArgsOwners.get(directory);
      if (jvmState === undefined) {
        jvmState = new CustomJvmArgsWriteState();
        PreferenceManager.customJvmArgsOwners.set(directory, jvmState);
      }
      this.customJvmArgsWrites = jvmState;
      let themeState: ThemeSelectionWriteState | undefined = PreferenceManager.themeSelectionOwners.get(directory);
      if (themeState === undefined) {
        themeState = new ThemeSelectionWriteState();
        PreferenceManager.themeSelectionOwners.set(directory, themeState);
      }
      this.themeSelectionWrites = themeState;
      let sheetState: PhoneSheetHeightWriteState | undefined = PreferenceManager.phoneSheetHeightOwners.get(directory);
      if (sheetState === undefined) {
        sheetState = new PhoneSheetHeightWriteState();
        PreferenceManager.phoneSheetHeightOwners.set(directory, sheetState);
      }
      this.phoneSheetHeightWrites = sheetState;
    }
  }

  /** 读取原owner的确认基线；回滚flush失败继续保旧值，但这个值不证明磁盘已经恢复。 */
  private readFrozenSetting_(key: string, fallback: LaunchPreferenceValue): LaunchPreferenceValue {
    const state: FrozenSettingsWriteState | undefined = this.frozenSettings;
    if (state !== undefined && state.originals.has(key)) return state.originals.get(key) as LaunchPreferenceValue;
    try { return this.pref.getSync(key, fallback); }
    catch (_) { return fallback; }
  }

  /**
   * 仅保存原amcl_settings中的两个已存在字段。先在原owner队列中读确认基线，再put和await
   * flush；失败只回滚本键，不覆盖另一键。回滚未确认时传播“磁盘未知”，保原基线供显式
   * 重试；后继事务仍串行，不能普通mount清墓碑或把旧任务接到后来owner。这个Promise
   * 只证明持久保存，不激活本局的Native手柄或已冻结交互路线。
   */
  private saveFrozenSetting_(key: string, value: LaunchPreferenceValue, fallback: LaunchPreferenceValue): Promise<void> {
    if (key !== 'desktopNativeGamepad' && key !== 'desktopInteraction') return Promise.reject(new Error('不是本次冻结设置字段'));
    const state: FrozenSettingsWriteState | undefined = this.frozenSettings;
    if (ProcessPreferences.isGameProcess()) return Promise.reject(new Error('请在启动器设置中修改本项设置'));
    if (state === undefined) return Promise.reject(new Error('无法确认设置存储目录，请重新打开启动器'));
    const task: Promise<void> = state.tail.then(async (): Promise<void> => {
      if (ProcessPreferences.isGameProcess()) throw new Error('请在启动器设置中修改本项设置');
      const previous: LaunchPreferenceValue = state.originals.has(key)
        ? state.originals.get(key) as LaunchPreferenceValue : await this.pref.get(key, fallback);
      if (ProcessPreferences.isGameProcess()) throw new Error('设置存储身份已改变，请重新打开启动器');
      // 同owner排队的重复选择在前笔确认后幂等返回；未知回滚的旧值只是读屏障，
      // 即使与请求相同也必须真正写盘重试，不能把磁盘未知态短路成成功。
      if (!state.originals.has(key) && previous === value) return;
      state.originals.set(key, previous);
      try {
        await this.pref.put(key, value);
        await this.pref.flush();
        state.originals.delete(key);
      } catch (error) {
        try {
          this.pref.putSync(key, previous);
          await this.pref.flush();
          state.originals.delete(key);
        } catch (rollbackError) {
          hilog.warn(0x0000, TAG, 'Frozen setting rollback unconfirmed %{public}s: %{public}s', key, formatError(rollbackError));
          throw new Error('保存失败，磁盘回滚尚未确认，请重试：' + formatError(error));
        }
        throw error as Error;
      }
    });
    // 队列只吞异常来允许下一次明确重试；原调用者仍收到task的原失败，不能虚报保存成功。
    state.tail = task.then((): void => {}, (): void => {});
    return task;
  }

  /** 原生手柄偏好只供下一局初始化；非法值或child写入在任何put以前拒绝。 */
  saveDesktopNativeGamepad(value: boolean): Promise<void> {
    if (typeof value !== 'boolean') return Promise.reject(new Error('手柄设置值非法'));
    return this.saveFrozenSetting_('desktopNativeGamepad', value, false);
  }

  /** 交互模式保存完成以后才由调用方更新desired；不得利用这个方法改变已冻结路线。 */
  saveDesktopInteraction(value: string): Promise<void> {
    if (value !== 'auto' && value !== 'touch' && value !== 'desktop') return Promise.reject(new Error('交互设置值非法'));
    return this.saveFrozenSetting_('desktopInteraction', value, 'auto');
  }

  // ===== 基础读写 =====

  getString(key: string, def: string): string {
    try { return this.pref.getSync(key, def) as string; }
    catch (e) { return def; }
  }

  getNumber(key: string, def: number): number {
    try { return this.pref.getSync(key, def) as number; }
    catch (e) { return def; }
  }

  getBool(key: string, def: boolean): boolean {
    try { return this.pref.getSync(key, def) as boolean; }
    catch (e) { return def; }
  }

  put(key: string, value: string | number | boolean): void {
    try {
      this.pref.putSync(key, value);
      this.pref.flush();
    } catch (e) {
      hilog.warn(0x0000, TAG, 'Failed to save %{public}s: %{public}s', key, formatError(e));
    }
  }

  /** 批量写入后统一 flush（性能优化） */
  putBatch(entries: Record<string, string | number | boolean>): void {
    try {
      let keys = Object.keys(entries);
      for (let key of keys) {
        this.pref.putSync(key, entries[key]);
      }
      this.pref.flush();
    } catch (e) {
      hilog.warn(0x0000, TAG, 'Failed to save batch: %{public}s', formatError(e));
    }
  }

  // ===== 业务属性 =====

  /** 缺省拒绝，非法类型也不授予运行；保存期间只暴露已经确认的旧值。 */
  get storeAllowDebug(): boolean {
    const state = this.storeDebugState;
    if (state !== undefined && state.original !== undefined) return state.original;
    try { const value = this.pref.getSync('storeAllowDebug', false); return typeof value === 'boolean' && value; }
    catch (_) { return false; }
  }

  /**
   * 等待本键flush后才承认保存；失败仅回滚本键，回滚未知时保留读屏障并向UI报告。
   * child不能写偏好；跨进程实时撤销由entry的GameRunAdmission私有门控承担。
   */
  saveStoreAllowDebug(value: boolean): Promise<void> {
    const state = this.storeDebugState;
    if (typeof value !== 'boolean' || ProcessPreferences.isGameProcess() || state === undefined) {
      return Promise.reject(new Error('运行调试选择只能在已初始化的启动器中保存'));
    }
    const task = state.tail.then(async (): Promise<void> => {
      const previous = this.storeAllowDebug;
      state.original = previous;
      try {
        await this.pref.put('storeAllowDebug', value);
        await this.pref.flush();
        state.original = undefined;
      } catch (error) {
        try {
          this.pref.putSync('storeAllowDebug', previous);
          await this.pref.flush();
          state.original = undefined;
        } catch (_) { throw new Error('运行调试选择保存失败，回滚尚未确认，请重试'); }
        throw error as Error;
      }
    });
    state.tail = task.then((): void => {}, (): void => {});
    return task;
  }

  get desktopInteraction(): string { return this.readFrozenSetting_('desktopInteraction', 'auto') as string; }

  /** 用户明确选择是否允许模组录音；损坏值、读取错误和首次安装均关闭，不等同系统已授权。 */
  get modMicrophoneEnabled(): boolean {
    if (this.microphoneWrites?.original !== undefined) return this.microphoneWrites.original;
    try { return this.pref.getSync('modMicrophoneEnabled', false) === true; }
    catch (_) { return false; }
  }

  /**
   * 原启动器是偏好唯一写者。完整 put/flush 后才确认；失败只恢复此键，回滚未确认保留基线。
   * 游戏进程消费启动快照，只读本项；设备授权与真实采集状态不存入 Preferences。
   */
  setModMicrophoneEnabled(enabled: boolean): Promise<void> {
    const state: ModMicrophoneWriteState | undefined = this.microphoneWrites;
    if (ProcessPreferences.isGameProcess() || state === undefined) {
      return Promise.reject(new Error('请在启动器设置中修改模组麦克风权限'));
    }
    const task: Promise<void> = state.tail.then(async (): Promise<void> => {
      const previous: boolean = this.modMicrophoneEnabled;
      state.original = previous;
      try {
        await this.pref.put('modMicrophoneEnabled', enabled);
        await this.pref.flush();
        state.original = undefined;
      } catch (error) {
        try {
          this.pref.putSync('modMicrophoneEnabled', previous);
          await this.pref.flush();
          state.original = undefined;
        } catch (_) { throw new Error('麦克风选择保存失败，回滚尚未确认，请重试'); }
        throw error as Error;
      }
    });
    state.tail = task.then((): void => {}, (): void => {});
    return task;
  }

  /**
   * 隔离启动快照与麦克风提交共用同一队列：不能让captureOwner.flush/getAllSync绕过确认屏障。
   * 在途提交完成或回滚后才捕获；回滚尚未确认则拒绝新局，避免把短暂true缓存当授权意图。
   */
  static captureConfirmedSettings(context: Context): Promise<LaunchPreferenceSnapshot> {
    const owner: PreferenceManager = new PreferenceManager(context);
    const state: ModMicrophoneWriteState | undefined = owner.microphoneWrites;
    if (state === undefined || ProcessPreferences.isGameProcess()) return Promise.reject(new Error('无法捕获启动器确认设置'));
    const task: Promise<LaunchPreferenceSnapshot> = state.tail.then(async (): Promise<LaunchPreferenceSnapshot> => {
      if (state.original !== undefined) throw new Error('麦克风设置回滚尚未确认，请重试');
      const snapshot: LaunchPreferenceSnapshot = await ProcessPreferences.captureOwner(context, PREF_NAME);
      snapshot.values[GAME_KEEP_SCREEN_ON_KEY] = owner.gameKeepScreenOn;
      return snapshot;
    });
    state.tail = task.then((): void => {}, (): void => {});
    return task;
  }

  /**
   * 平板独立游戏进程的持久选择；不复用历史 useNewWindow（窗口样式并不等于进程边界）。
   * 缺省开启，只有真实布尔值参与决策；损坏或不可读取的值安全关闭，不以字符串真值猜测。
   * 本属性只是下次启动器进程的选择，实际会话路线由 RuntimeProductProfile 首次初始化锁存。
   */
  get tabletIndependentGameProcess(): boolean {
    try {
      const value = this.pref.getSync('tabletIndependentGameProcess', true);
      return typeof value === 'boolean' ? value : false;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'Cannot read tablet process preference: %{public}s', formatError(e));
      return false;
    }
  }

  /**
   * 此开关保存后通常会紧接着重启，不能使用普通 put 的异步即忘语义。
   * 仅启动器可写，等待 flush 成功才让 UI 显示已保存；失败恢复本进程缓存并尝试落盘回滚，
   * 原错误继续交给 UI。回滚也失败时不冒充磁盘一致，用户仍会看到保存失败并可重试。
   */
  async saveTabletIndependentGameProcess(value: boolean): Promise<void> {
    if (ProcessPreferences.isGameProcess()) throw new Error('请在启动器设置中修改独立游戏进程');
    const previous: boolean = this.tabletIndependentGameProcess;
    try {
      await this.pref.put('tabletIndependentGameProcess', value);
      await this.pref.flush();
    } catch (e) {
      try {
        this.pref.putSync('tabletIndependentGameProcess', previous);
        await this.pref.flush();
      } catch (rollbackError) {
        hilog.warn(0x0000, TAG, 'Tablet process preference rollback failed: %{public}s', formatError(rollbackError));
      }
      throw e as Error;
    }
  }

  /** 老数据与缺失快照字段默认开启，只有明确保存的 false 才关闭游戏保亮。 */
  get gameKeepScreenOn(): boolean {
    const confirmed: boolean | undefined = PreferenceManager.gameKeepScreenOnBeforeSave.get(this.preferencesDirectory);
    if (confirmed !== undefined) return confirmed;
    return this.getBool(GAME_KEEP_SCREEN_ON_KEY, true) !== false;
  }

  /** 启动器确认落盘后再更新开关；隔离游戏从本局只读启动快照取值。 */
  async saveGameKeepScreenOn(enabled: boolean): Promise<void> {
    if (ProcessPreferences.isGameProcess()) throw new Error('请在启动器设置中修改游戏常亮');
    const pending: Map<string, boolean> = PreferenceManager.gameKeepScreenOnBeforeSave;
    if (pending.has(this.preferencesDirectory)) throw new Error('游戏常亮设置正在保存');
    const previous: boolean = this.gameKeepScreenOn;
    pending.set(this.preferencesDirectory, previous);
    try {
      this.pref.putSync(GAME_KEEP_SCREEN_ON_KEY, enabled);
      await this.pref.flush();
    } catch (error) {
      try {
        this.pref.putSync(GAME_KEEP_SCREEN_ON_KEY, previous);
        await this.pref.flush();
      } catch (rollbackError) {
        hilog.warn(0x0000, TAG, 'Game keep screen on rollback failed: %{public}s', formatError(rollbackError));
      }
      throw error as Error;
    } finally {
      pending.delete(this.preferencesDirectory);
    }
  }

  /** 单键新配置优先；缺失或损坏才回退旧明暗。保存及回滚未知期间只读原确认值。 */
  get themeSelection(): ThemeSelection {
    const legacy: ThemeMode = normalizeThemeMode(this.getNumber('themeMode', ThemeMode.SYSTEM));
    try {
      const state: ThemeSelectionWriteState | undefined = this.themeSelectionWrites;
      const raw: LaunchPreferenceValue = state !== undefined && state.original !== undefined
        ? state.original : this.pref.getSync(THEME_SELECTION_KEY, '');
      return decodeThemeSelection(typeof raw === 'string' ? raw : '', legacy);
    } catch (_) { return decodeThemeSelection('', legacy); }
  }

  get themeMode(): ThemeMode { return this.themeSelection.mode; }
  get themeAccent(): ThemeAccent { return this.themeSelection.accent; }

  /** 旧赋值入口仍走同一owner队列；需要显示保存结果的新UI必须await专用方法。 */
  set themeMode(v: ThemeMode) {
    this.saveThemeSelection(new ThemeSelection(v, this.themeAccent)).catch((error: Error): void => {
      hilog.warn(0x0000, TAG, '主题保存失败：%{public}s', formatError(error));
    });
  }

  /**
   * 明确“应用主题”的唯一持久入口。单键put/flush成功以后才解除读取屏障；同目录请求
   * 串行执行，多页面不能看到Preferences已put但未flush的在途值。失败只回滚本键，
   * 回滚也失败则保留旧确认值并报告未知磁盘态，下一次同值重试不能幂等虚报成功。
   * 游戏快照只读，本方法不会变更运行中游戏的显示、输入或布局身份。
   */
  saveThemeSelection(value: ThemeSelection): Promise<void> {
    const state: ThemeSelectionWriteState | undefined = this.themeSelectionWrites;
    if (value === undefined || value === null || normalizeThemeMode(value.mode) !== value.mode ||
      normalizeThemeAccent(value.accent) !== value.accent || ProcessPreferences.isGameProcess() || state === undefined) {
      return Promise.reject(new Error('主题只能在已初始化的启动器中保存有效预设'));
    }
    const encoded: string = encodeThemeSelection(value);
    const task: Promise<void> = state.tail.then(async (): Promise<void> => {
      if (ProcessPreferences.isGameProcess()) throw new Error('请在启动器中更改主题');
      const previous: LaunchPreferenceValue = state.original !== undefined
        ? state.original : await this.pref.get(THEME_SELECTION_KEY, '');
      if (ProcessPreferences.isGameProcess()) throw new Error('主题存储身份已改变，请重新打开启动器');
      if (state.original === undefined && previous === encoded) return;
      state.original = previous;
      try {
        await this.pref.put(THEME_SELECTION_KEY, encoded);
        await this.pref.flush();
        state.original = undefined;
      } catch (error) {
        try {
          this.pref.putSync(THEME_SELECTION_KEY, previous);
          await this.pref.flush();
          state.original = undefined;
        } catch (rollbackError) {
          hilog.warn(0x0000, TAG, '主题回滚尚未确认：%{public}s', formatError(rollbackError));
          throw new Error('主题保存失败，磁盘回滚尚未确认，请重试：' + formatError(error));
        }
        throw error as Error;
      }
    });
    state.tail = task.then((): void => {}, (): void => {});
    return task;
  }

  /**
   * 手机 Sheet 的已确认展开比例。缺失、异常类型或损坏数字使用公共读取规则；同目录
   * manager 在 put/flush 或失败回滚期间只读旧确认值，不把缓存改动当成已保存选择。
   */
  get phoneSheetHeightPercent(): number {
    try {
      const state: PhoneSheetHeightWriteState | undefined = this.phoneSheetHeightWrites;
      const raw: LaunchPreferenceValue = state !== undefined && state.original !== undefined
        ? state.original : this.pref.getSync(PHONE_SHEET_HEIGHT_STORAGE_KEY, DEFAULT_PHONE_SHEET_HEIGHT_PERCENT);
      return normalizePhoneSheetHeightPercent(typeof raw === 'number' ? raw : DEFAULT_PHONE_SHEET_HEIGHT_PERCENT);
    } catch (_) { return DEFAULT_PHONE_SHEET_HEIGHT_PERCENT; }
  }

  /**
   * 只保存手机面板比例，沿真实 preferencesDir 串行执行单键 put/flush。
   * 合法输入必须已经满足范围和步进；失败恢复原键（含首次未设置），回滚未确认时继续
   * 保留读取屏障并报错。游戏快照和缺少存储 owner 的页面不允许写入，不修改冻结设置。
   */
  savePhoneSheetHeightPercent(value: number): Promise<void> {
    const state: PhoneSheetHeightWriteState | undefined = this.phoneSheetHeightWrites;
    if (typeof value !== 'number' || !Number.isFinite(value) || normalizePhoneSheetHeightPercent(value) !== value ||
      ProcessPreferences.isGameProcess() || state === undefined) {
      return Promise.reject(new Error('请在启动器中保存有效的手机面板高度'));
    }
    const task: Promise<void> = state.tail.then(async (): Promise<void> => {
      if (ProcessPreferences.isGameProcess()) throw new Error('请在启动器中修改手机面板高度');
      const previous: LaunchPreferenceValue = state.original !== undefined
        ? state.original : await this.pref.get(PHONE_SHEET_HEIGHT_STORAGE_KEY, PHONE_SHEET_HEIGHT_ABSENT);
      if (ProcessPreferences.isGameProcess()) throw new Error('面板高度存储身份已改变，请重新打开启动器');
      if (state.original === undefined && previous === value) return;
      state.original = previous;
      try {
        await this.pref.put(PHONE_SHEET_HEIGHT_STORAGE_KEY, value);
        await this.pref.flush();
        state.original = undefined;
      } catch (error) {
        try {
          if (previous === PHONE_SHEET_HEIGHT_ABSENT) this.pref.deleteSync(PHONE_SHEET_HEIGHT_STORAGE_KEY);
          else this.pref.putSync(PHONE_SHEET_HEIGHT_STORAGE_KEY, previous);
          await this.pref.flush();
          state.original = undefined;
        } catch (rollbackError) {
          hilog.warn(0x0000, TAG, '手机面板高度回滚尚未确认：%{public}s', formatError(rollbackError));
          throw new Error('手机面板高度保存失败，磁盘回滚尚未确认，请重试：' + formatError(error));
        }
        throw error as Error;
      }
    });
    state.tail = task.then((): void => {}, (): void => {});
    return task;
  }

  /** 独立外观键不进入旧 saveAll 快照，避免其他设置的批量保存覆盖正在确认的档位。 */
  get dockLightMode(): DockLightMode {
    if (this.dockLightConfirmedDuringSave !== undefined) return this.dockLightConfirmedDuringSave;
    return normalizeDockLightMode(this.getString('dockLightMode', DockLightMode.AUTO));
  }

  /** 新键缺失才兼容旧五档；无效新键安全关闭，同目录各 manager 共用确认读取屏障。 */
  get immersiveLightPreferences(): ImmersiveLightPreferences {
    try {
      const state: ImmersiveLightWriteState | undefined = this.immersiveLightWrites;
      const raw: LaunchPreferenceValue = state !== undefined && state.original !== undefined
        ? state.original : this.pref.getSync(IMMERSIVE_LIGHT_KEY, IMMERSIVE_LIGHT_ABSENT);
      if (raw === IMMERSIVE_LIGHT_ABSENT) return migrateImmersiveLightPreferences(this.dockLightMode);
      return decodeImmersiveLightPreferences(typeof raw === 'string' ? raw : '');
    } catch (_) {
      return decodeImmersiveLightPreferences('');
    }
  }

  /**
   * 一次确认总开关、档位和两个模块；写事务按原目录串行，确认前所有页面仍读旧整组。
   * 首次保存失败时恢复键缺失，允许下次仍按旧五档读取；回滚失败保留确认值屏障。
   * 不双写旧键、不触碰主题和启动快照，进程重建后重新以真实持久记录为准。
   */
  saveImmersiveLightPreferences(value: ImmersiveLightPreferences): Promise<void> {
    const serialized: string = encodeImmersiveLightPreferences(value);
    const state: ImmersiveLightWriteState | undefined = this.immersiveLightWrites;
    if (state === undefined || ProcessPreferences.isGameProcess()) return Promise.reject(new Error('当前进程无法保存沉浸光感设置'));
    const task: Promise<void> = state.tail.then(async (): Promise<void> => {
      if (ProcessPreferences.isGameProcess()) throw new Error('请在启动器中修改沉浸光感设置');
      const previous: LaunchPreferenceValue = state.original !== undefined ? state.original
        : this.pref.getSync(IMMERSIVE_LIGHT_KEY, IMMERSIVE_LIGHT_ABSENT);
      state.original = previous;
      try {
        await this.pref.put(IMMERSIVE_LIGHT_KEY, serialized);
        await this.pref.flush();
        state.original = undefined;
      } catch (error) {
        try {
          if (previous === IMMERSIVE_LIGHT_ABSENT) this.pref.deleteSync(IMMERSIVE_LIGHT_KEY);
          else this.pref.putSync(IMMERSIVE_LIGHT_KEY, previous);
          await this.pref.flush();
          state.original = undefined;
        } catch (_) { throw new Error('沉浸光感保存失败，回滚尚未确认，请重试'); }
        throw error as Error;
      }
    });
    state.tail = task.then((): void => {}, (): void => {});
    return task;
  }

  /**
   * Index 在保存期间禁用切换；只有 flush 成功后才发布新档位。
   * 本方法仅写本键，不改主题或启动设置；失败恢复旧缓存并等待回滚，错误交回 UI。
   * 即使回滚失败也不虚报成功，保留用户可重试的错误信息；游戏进程不允许写入。
   */
  async saveDockLightMode(mode: DockLightMode): Promise<void> {
    if (normalizeDockLightMode(mode) !== mode || ProcessPreferences.isGameProcess()) {
      throw new Error('底部栏光感设置无效或当前进程不可保存');
    }
    const previous: DockLightMode = this.dockLightMode;
    this.dockLightConfirmedDuringSave = previous;
    try {
      await this.pref.put('dockLightMode', mode);
      await this.pref.flush();
      this.dockLightConfirmedDuringSave = undefined;
    } catch (error) {
      try {
        this.pref.putSync('dockLightMode', previous);
        await this.pref.flush();
        this.dockLightConfirmedDuringSave = undefined;
      } catch (_) {
        throw new Error('底部栏光感保存失败，回滚尚未确认，请重试');
      }
      throw error as Error;
    }
  }

  get mcVersion(): string { return this.getString('mcVersion', '1.20.4'); }
  set mcVersion(v: string) { this.put('mcVersion', v); }

  get useNewWindow(): boolean { return this.getBool('useNewWindow', false); }
  set useNewWindow(v: boolean) { this.put('useNewWindow', v); }

  /**
   * 是否已同意隐私政策（开屏隐私弹窗用）。默认 false → 首次启动弹政策同意框。
   * 上架（平板）合规要求：用户须先同意隐私政策方可使用。同意后落盘，后续不再弹。
   */
  get privacyAgreed(): boolean { return this.getBool('privacyAgreed', false); }
  set privacyAgreed(v: boolean) { this.put('privacyAgreed', v); }

  get versionIsolation(): boolean { return this.getBool('versionIsolation', true); }
  set versionIsolation(v: boolean) { this.put('versionIsolation', v); }

  get mcXmx(): number { return this.getNumber('mcXmx', 0); }
  set mcXmx(v: number) { this.put('mcXmx', v); }

  /**
   * 虚拟内存（堆文件）模式。默认 false。
   *
   * 开启后启动时向 JVM 注入 marker `-Damcl.heapfile=1`，C 层据此用
   * `-XX:AllocateHeapAt=<沙箱目录>`（JEP 316）把 Java 堆分配到存储文件上，
   * 使堆内存「文件背书、可被系统回收」，避免低内存设备跑重型整合包时
   * 世界生成峰值被系统 lowmemkiller 强杀（SIGKILL）。
   *
   * 代价：堆落在 UFS 存储上，GC/世界生成会明显变慢、增加存储写入。
   * 仅建议在「可用内存不足以支撑整合包」时开启。
   */
  get virtualMemoryMode(): boolean { return this.getBool('virtualMemoryMode', false); }
  set virtualMemoryMode(v: boolean) { this.put('virtualMemoryMode', v); }

  /**
   * GL 渲染器偏好。默认 `'mobileglues'`。
   *
   * 可选值由 `launch` 的渲染后端注册表（`RENDERER_BACKENDS` 里 `userSelectable=true` 的那些）
   * 决定，**刻意不在本文件里枚举** —— 那会变成第二份可漂移的清单。
   * 契约见 `docs/guides/renderer-backend-governance.md` §2/§4。
   *
   * 📌 历史：这里曾列出 `'zink'`（Mesa Zink / OSMesa GL4.6 on Vulkan）。
   * 它已于 2026-08-27 完全退役（施工记录 §S6），偏好里的旧值由解析器落默认。
   */
  // ⚠️⚠️ **本 getter 刻意不做归一化。** 归一化归解析器
  // （`resolveRendererBackend` 对未知 / 不可选的 id 一律落默认，见施工记录 §S2.2 ③）。
  //
  // 为什么不在这里做：本类是**偏好存储**，它不知道也不该知道"哪些后端当前可选" ——
  // 那需要 import `launch`，而 `feature_system` 在依赖图里比 `launch` 更底层。
  // 在这里塞一份"合法值列表"就是治理规范 §1 缺陷 1 那个形状（同一事实两处各说一套）。
  //
  // ⇒ **已退役后端的偏好会原样读出来**（例如 2026-08-27 退役的 `'zink'`：
  // 老用户的持久化偏好里仍然存着它）。解析器把它当"不可选"落默认，**不抛错、不清空存储**。
  // 刻意不清空：清空不可逆，而保留能让"这个用户曾选过 zink"在诊断日志里可见
  // （解析器会打 `preference 'zink' is not user-selectable (lifecycle=retired) -> default`）。
  get glRenderer(): string { return this.getString('glRenderer', 'mobileglues'); }
  set glRenderer(v: string) { this.put('glRenderer', v); }

  /** Canonical peer graphics profile preference. The legacy glRenderer key is
   * retained as the on-disk compatibility format; selection and availability
   * are owned by launch's profile registry. */
  get graphicsProfile(): string { return this.glRenderer; }
  set graphicsProfile(v: string) {
    this.glRenderer = v;
    // Distinguish an explicit launcher choice from the historical default
    // value. A user choice can intentionally override Minecraft's in-game API
    // preference; old installs without this marker keep game preference flow.
    this.put('graphicsProfileExplicit', true);
  }
  get graphicsProfileExplicit(): boolean { return this.getBool('graphicsProfileExplicit', false); }

  /**
   * 开发验证产品的渲染后端覆盖（candidate/experimental 验证通道）。空串 = 无覆盖。
   * 旧 DevTools 验证入口继续读取此键；设置页平级选择使用 graphicsProfile，
   * 选择任一 profile 时清除旧覆盖，避免两份偏好竞争。
   * （McGamePage → LaunchProfileBuilder.setDevRendererOverride → 解析器）。
   * 与 `glRenderer` 同一条"不在存储层归一化"的纪律：坏值/退役值由解析器判定并
   * 打可 grep 的日志（`dev override '<id>' is not a candidate/experimental backend`），
   * 不在这里静默清洗。
   */
  get devRendererOverride(): string { return this.getString('devRendererOverride', ''); }
  set devRendererOverride(v: string) { this.put('devRendererOverride', v); }

  /**
   * HarmonyOS 给游戏 XComponent 的调度帧率。0 = 自动跟随当前显示刷新率；
   * 30..240 = 用户明确设置的帧率，native 侧把 min/max/expected 全部固定为该值，
   * 防止 LTPO 动态降频。它不读写 Minecraft options.txt，也不冒充
   * 游戏自身的 FPS limiter。非法/旧脏值在读取和写入时都归一化为 Auto。
   */
  get ohosFrameRateCap(): number {
    return this.normalizeOhosFrameRateCap(this.getNumber('ohosFrameRateCap', 0));
  }
  set ohosFrameRateCap(v: number) {
    this.put('ohosFrameRateCap', this.normalizeOhosFrameRateCap(v));
  }

  private normalizeOhosFrameRateCap(v: number): number {
    if (v === 0) return 0;
    if (v < OHOS_FRAME_RATE_CAP_MIN || v > OHOS_FRAME_RATE_CAP_MAX || Math.floor(v) !== v) {
      return 0;
    }
    return v;
  }

  /**
   * 游戏数据(.minecraft)存储位置：'sandbox'(默认) | 'external'。
   * external = 公共 Download/com.amcl.launcher/.minecraft（文件管理器显示为 AMCL），卸载应用后数据仍保留
   * （需 Phase 0 探针确认设备支持）。
   * 切换是带权限申请 + 可选迁移的独立动作，故不进 loadAll/saveAll 批量快照，避免被批量覆盖。
   */
  get mcStorageLocation(): string { return this.getString('mcStorageLocation', 'sandbox'); }
  set mcStorageLocation(v: string) { this.put('mcStorageLocation', v); }

  /**
   * 手机端「外部存储」学到的公共应用目录（…/Download/com.amcl.launcher）。'' = 尚未学到。
   *
   * 手机上 Environment.getUserDownloadDir() 报 801，无法凭空构造 Download 路径；首次启用外部
   * 时用 DocumentViewPicker DOWNLOAD 模式（无弹窗）「学」一次该路径并落盘，之后冷启动直接读回
   * 按原始路径用（所有权式访问，无需 picker/persist/activate）。平板不用此字段（走 Environment）。
   * 详见 docs/adaptation/手机端沙箱外存储适配方案.md。
   * 与 mcStorageLocation 一样不进 loadAll/saveAll 批量快照，避免被覆盖。
   */
  get phoneExternalDir(): string { return this.getString('phoneExternalDir', ''); }
  set phoneExternalDir(v: string) { this.put('phoneExternalDir', v); }

  /**
   * 用户自定义 JVM 参数（全局，空格分隔；支持引号包裹含空格的值）。
   *
   * 语义对齐 FoldCraftLauncher / HMCL 的 javaArguments：**用户参数优先级最高**——
   * LaunchProfileBuilder.mergeUserJvmArgs 会让同 `-Dkey` / `-Xmx` 等的用户值覆盖
   * version.json 与 SSOT 默认参数（见该方法注释）。
   *
   * 典型用途：临时调试（-Dsodium.checks.issue2561=true 恢复 Sodium 检查）、
   * 加 -XX 调参、覆盖 file.encoding 等。空串 = 不加任何额外参数。
   *
   * 与 mcStorageLocation 一样在专门的设置页编辑，不进 loadAll/saveAll 批量快照，
   * 避免被批量覆盖。
   */
  /** 保存期间及回滚未知时只读取原确认值；损坏的非字符串参数按默认空值处理。 */
  get customJvmArgs(): string {
    try {
      const state: CustomJvmArgsWriteState | undefined = this.customJvmArgsWrites;
      const value: LaunchPreferenceValue = state !== undefined && state.original !== undefined
        ? state.original : this.pref.getSync('customJvmArgs', '');
      return typeof value === 'string' ? value : '';
    } catch (_) { return ''; }
  }
  set customJvmArgs(v: string) { this.put('customJvmArgs', v); }

  /** 仅给分辨率相关读者提供确认屏障；不改变其他设置既有读写语义。 */
  private readResolutionSetting_(key: string, fallback: LaunchPreferenceValue): LaunchPreferenceValue {
    if (this.resolutionWrites?.originals.has(key)) return this.resolutionWrites.originals.get(key) as LaunchPreferenceValue;
    try { return this.pref.getSync(key, fallback); } catch (_) { return fallback; }
  }

  /** 0 为缺省兼容旧 marker，100 为玩家明确选择原生分辨率，两者不可合并存储。 */
  get resolutionScalePercent(): number {
    const value: LaunchPreferenceValue = this.readResolutionSetting_('resolutionScalePercent', 0);
    return normalizeResolutionPreference(typeof value === 'number' ? value : 0);
  }

  /**
   * 保存全局或一个实例的分辨率选择，0 表示缺省/继承。游戏进程使用只读偏好快照，
   * 运行中调节属于会话政策，不能经本方法偷偷修改下一局设置。
   * 失败仅在该键仍等于本次写入时回滚，避免覆盖期间其他设置对同一实例记录的修改。
   */
  saveResolutionScalePercent(percent: number, versionId: string = ''): Promise<void> {
    const state: ResolutionWriteState | undefined = this.resolutionWrites;
    if ((percent !== 0 && normalizeResolutionPreference(percent) === 0)
      || ProcessPreferences.isGameProcess() || state === undefined) {
      return Promise.reject(new Error('无法保存分辨率：比例无效或当前不是启动器设置进程'));
    }
    const task: Promise<void> = state.tail.then(async (): Promise<void> => {
      if (ProcessPreferences.isGameProcess()) throw new Error('设置存储进程已改变，请重新打开设置');
      const key: string = versionId.length > 0 ? 'verLaunch.' + versionId : 'resolutionScalePercent';
      const fallback: LaunchPreferenceValue = versionId.length > 0 ? '' : 0;
      let previous: LaunchPreferenceValue = this.readResolutionSetting_(key, fallback);
      let value: LaunchPreferenceValue = percent;
      if (versionId.length > 0) {
        let override: VersionLaunchOverride = this.getVersionOverride(versionId);
        if (state.jvmKeys.has(key)) {
          // 前笔JVM回滚未知时仍使用旧JVM确认值，但保留随后void入口已修改的其他字段。
          // 本次分辨率保存/回滚若flush成功，会一起确认这份完整记录并解除共享屏障。
          const confirmedJvm: string = override.customJvmArgs;
          override = this.versionOverrideForWrite_(this.pref.getSync(key, ''));
          override.customJvmArgs = confirmedJvm;
          previous = JSON.stringify(override);
        }
        override.renderScalePercent = percent;
        value = JSON.stringify(override);
      }
      state.originals.set(key, previous);
      try {
        this.pref.putSync(key, value);
        await this.pref.flush();
        state.originals.delete(key);
        state.jvmKeys.delete(key);
      } catch (error) {
        if (this.pref.getSync(key, fallback) !== value) {
          state.originals.delete(key);
          state.jvmKeys.delete(key);
          throw new Error('保存失败且该实例设置已变化，请重新读取后重试');
        }
        try {
          this.pref.putSync(key, previous);
          await this.pref.flush();
          state.originals.delete(key);
          state.jvmKeys.delete(key);
        } catch (_) { throw new Error('分辨率保存失败，磁盘恢复尚未确认，请重试'); }
        throw error as Error;
      }
    });
    state.tail = task.then((): void => {}, (): void => {});
    return task;
  }

  /**
   * 为显式“保存 JVM 参数”提供可等待的持久提交结果，输入首尾空白沿用旧编辑器规则。
   *
   * 仅启动器在真实偏好目录中允许写入；同目录的多页面请求按原 owner 串行执行。
   * put 与 flush 均成功后才清除读取屏障。失败时只回滚本键并等待回滚落盘；回滚也
   * 失败则保留旧确认值并报告磁盘未知，后续同值重试仍须真正写入，不能幂等跳过。
   * 返回的 Promise 只代表偏好保存，不修改已经运行的 JVM，也不替代单版本参数合并。
   */
  saveCustomJvmArgs(value: string): Promise<void> {
    const state: CustomJvmArgsWriteState | undefined = this.customJvmArgsWrites;
    if (typeof value !== 'string' || ProcessPreferences.isGameProcess() || state === undefined) {
      return Promise.reject(new Error('JVM 参数只能在已初始化的启动器中保存'));
    }
    const normalized: string = value.trim();
    const task: Promise<void> = state.tail.then(async (): Promise<void> => {
      if (ProcessPreferences.isGameProcess()) throw new Error('请在启动器中修改 JVM 参数');
      const previous: LaunchPreferenceValue = state.original !== undefined
        ? state.original : await this.pref.get('customJvmArgs', '');
      if (ProcessPreferences.isGameProcess()) throw new Error('JVM 参数存储身份已改变，请重新打开启动器');
      // 只有已经确认的相同值可以跳过；回滚未知时即使恢复旧值也要真正写盘。
      if (state.original === undefined && previous === normalized) return;
      state.original = previous;
      try {
        await this.pref.put('customJvmArgs', normalized);
        await this.pref.flush();
        state.original = undefined;
      } catch (error) {
        try {
          this.pref.putSync('customJvmArgs', previous);
          await this.pref.flush();
          state.original = undefined;
        } catch (rollbackError) {
          hilog.warn(0x0000, TAG, 'JVM 参数回滚尚未确认：%{public}s', formatError(rollbackError));
          throw new Error('JVM 参数保存失败，磁盘回滚尚未确认，请重试：' + formatError(error));
        }
        throw error as Error;
      }
    });
    // 仅队列尾消化异常来保留显式重试机会；原任务仍把失败交给调用它的编辑器。
    state.tail = task.then((): void => {}, (): void => {});
    return task;
  }

  /**
   * 全局游戏语言（Minecraft `options.txt` 的 `lang` 键）。默认简体中文 `zh_cn`。
   *
   * 语义（对齐 PCL2 的 options.txt lang 写入 + AMCL 字段级继承模型）：
   *   - 这是"启动器权威"的全局默认语言：每个版本若未单独指定语言，则跟随此值。
   *   - 启动时由 resolveLaunch 注入 `-Damcl.gamelang=<code>` marker，C 层
   *     applyGameLanguage 据此写进该版本 gameDir/options.txt 的 `lang`。
   * 非法 / 未知值读盘时归一化回默认（避免脏数据写坏 options.txt）。
   */
  get gameLanguage(): string { return normalizeGlobalGameLanguage(this.getString('gameLanguage', DEFAULT_GAME_LANGUAGE)); }
  set gameLanguage(v: string) { this.put('gameLanguage', v); }

  // ===== 单版本启动配置覆盖（字段级继承模型：每个字段独立"留空=沿用全局"） =====
  //
  // 设计变更（2026-06：UI 重构）：
  //   旧模型是 HMCL 式 useGlobal 整体开关（要么全沿用全局、要么全覆盖），
  //   导致"只想给某版本加一条自定义 JVM 参数"时会连带丢掉全局内存设置。
  //   新模型改为【字段级继承】——override 里每个字段都用"空值"表示沿用全局：
  //     - xmx <= 0        → 沿用全局 mcXmx
  //     - jdkVersion ''   → 不指定（调用方按纪元自动路由）
  //     - customJvmArgs   → 与全局 customJvmArgs 拼接（全局在前、单版本在后，
  //                          单版本优先级更高，最终由 LaunchProfileBuilder.mergeUserJvmArgs 去重）
  //   当前 UI 只暴露"单版本自定义 JVM 参数"（版本详情 sheet 内联编辑），
  //   xmx / jdkVersion 字段保留供未来扩展，模型本身已支持。

  private defaultVersionOverride(): VersionLaunchOverride {
    return { xmx: 0, jdkVersion: '', customJvmArgs: '', gameLanguage: '' };
  }

  /**
   * 写事务严格解析共享实例记录：空串代表尚无覆盖；损坏JSON或非对象必须报错，不能
   * 像只读展示的兜底一样当作全默认并覆盖用户其他字段。字段默认与原getter保持一致。
   */
  private versionOverrideForWrite_(stored: LaunchPreferenceValue): VersionLaunchOverride {
    if (typeof stored !== 'string') throw new Error('实例设置不可读取，请重新打开版本详情');
    if (stored.length === 0) return this.defaultVersionOverride();
    const fields = JSON.parse(stored) as Record<string, Object>;
    if (fields === null || typeof fields !== 'object' || Array.isArray(fields)) {
      throw new Error('实例设置记录已损坏，请先恢复后重试');
    }
    return {
      xmx: typeof fields['xmx'] === 'number' ? fields['xmx'] as number : 0,
      jdkVersion: typeof fields['jdkVersion'] === 'string' ? fields['jdkVersion'] as string : '',
      customJvmArgs: typeof fields['customJvmArgs'] === 'string' ? fields['customJvmArgs'] as string : '',
      gameLanguage: typeof fields['gameLanguage'] === 'string' ? fields['gameLanguage'] as string : '',
      renderScalePercent: normalizeResolutionPreference(typeof fields['renderScalePercent'] === 'number'
        ? fields['renderScalePercent'] as number : 0),
    };
  }

  /** 同步更改一个实例记录的缓存；耐久确认由调用事务显式等待flush，失败必须向上传递。 */
  private writeVersionOverrideSync_(key: string, value: VersionLaunchOverride): void {
    if (value.xmx <= 0 && value.jdkVersion.length === 0 && value.customJvmArgs.length === 0
      && value.gameLanguage.length === 0 && normalizeResolutionPreference(value.renderScalePercent) === 0) {
      this.pref.deleteSync(key);
    } else this.pref.putSync(key, JSON.stringify(value));
  }

  /**
   * 显式保存一个固定实例的JVM参数。只改customJvmArgs，首尾空白沿用旧编辑器trim规则；
   * 空串恢复“仅用全局参数”。同目录请求与分辨率共用队列，put/flush完成前getter仍给
   * 旧确认值。失败重新读取最新记录并只回滚JVM字段，保留同期JDK/语言/内存等修改。
   * 回滚也失败则保留屏障与保护标记，返回拒绝供原编辑器重试；同值也必须实际写盘。
   */
  saveVersionJvmArgs(versionId: string, value: string): Promise<void> {
    const state: ResolutionWriteState | undefined = this.resolutionWrites;
    if (typeof versionId !== 'string' || versionId.trim().length === 0 || typeof value !== 'string'
      || ProcessPreferences.isGameProcess() || state === undefined) {
      return Promise.reject(new Error('单版本JVM参数只能在已初始化的启动器中保存，且必须指定版本'));
    }
    const normalized: string = value.trim();
    const task: Promise<void> = state.tail.then(async (): Promise<void> => {
      if (ProcessPreferences.isGameProcess()) throw new Error('设置存储进程已改变，请重新打开版本详情');
      const key: string = 'verLaunch.' + versionId;
      // 不使用展示getter的读取失败兜底；读取异常必须发生在写入之前，不能猜空记录。
      const original: LaunchPreferenceValue = state.originals.has(key)
        ? state.originals.get(key) as LaunchPreferenceValue : this.pref.getSync(key, '');
      const previous: VersionLaunchOverride = this.versionOverrideForWrite_(original);
      const next: VersionLaunchOverride = this.versionOverrideForWrite_(this.pref.getSync(key, ''));
      // 共用队列进入时仍存在屏障，代表前笔回滚未知。此次仅明确修改JVM，不能顺带
      // 采用缓存中尚未确认的分辨率；其他void字段仍保留最新同步缓存语义。
      if (state.originals.has(key)) next.renderScalePercent = previous.renderScalePercent;
      next.customJvmArgs = normalized;
      state.originals.set(key, original);
      state.jvmKeys.add(key);
      try {
        this.writeVersionOverrideSync_(key, next);
        await this.pref.flush();
        state.originals.delete(key);
        state.jvmKeys.delete(key);
      } catch (error) {
        try {
          const restored: VersionLaunchOverride = this.versionOverrideForWrite_(this.pref.getSync(key, ''));
          restored.customJvmArgs = previous.customJvmArgs;
          // 只投影最新其他字段与原JVM确认值；这仍不证明磁盘已恢复，须等待回滚flush。
          state.originals.set(key, JSON.stringify(restored));
          this.writeVersionOverrideSync_(key, restored);
          await this.pref.flush();
          state.originals.delete(key);
          state.jvmKeys.delete(key);
        } catch (rollbackError) {
          hilog.warn(0x0000, TAG, '单版本JVM参数回滚尚未确认：%{public}s', formatError(rollbackError));
          throw new Error('单版本JVM参数保存失败，磁盘回滚尚未确认，请重试：' + formatError(error));
        }
        throw error as Error;
      }
    });
    // 队列尾独立消化失败以允许重试；返回的原任务保留拒绝，编辑器不能提前发布保存成功。
    state.tail = task.then((): void => {}, (): void => {});
    return task;
  }

  /**
   * 读取某版本的启动配置覆盖。无记录 / 解析失败 → 全字段默认（即全沿用全局）。
   * key = `verLaunch.<versionId>`，值为 JSON 编码的 VersionLaunchOverride。
   */
  getVersionOverride(versionId: string): VersionLaunchOverride {
    if (!versionId || versionId.length === 0) return this.defaultVersionOverride();
    const stored: LaunchPreferenceValue = this.readResolutionSetting_('verLaunch.' + versionId, '');
    let raw: string = typeof stored === 'string' ? stored : '';
    if (raw.length === 0) return this.defaultVersionOverride();
    try {
      let o = JSON.parse(raw) as Record<string, Object>;
      return {
        xmx: typeof o['xmx'] === 'number' ? (o['xmx'] as number) : 0,
        jdkVersion: typeof o['jdkVersion'] === 'string' ? (o['jdkVersion'] as string) : '',
        customJvmArgs: typeof o['customJvmArgs'] === 'string' ? (o['customJvmArgs'] as string) : '',
        gameLanguage: typeof o['gameLanguage'] === 'string' ? (o['gameLanguage'] as string) : '',
        renderScalePercent: normalizeResolutionPreference(typeof o['renderScalePercent'] === 'number'
          ? o['renderScalePercent'] as number : 0),
      };
    } catch (e) {
      hilog.warn(0x0000, TAG, 'getVersionOverride parse failed: %{public}s', formatError(e));
      return this.defaultVersionOverride();
    }
  }

  /**
   * 写入某版本的启动配置覆盖。全字段都为空（=全沿用全局）时删除 key，
   * 避免存储里堆空记录。
   */
  setVersionOverride(versionId: string, o: VersionLaunchOverride): void {
    if (!versionId || versionId.length === 0) return;
    let key = 'verLaunch.' + versionId;
    // 共享记录保存期间，普通读者只看到确认基线；旧void入口仍可更改JDK/语言等字段，
    // 但不能把确认快照里的旧分辨率或旧JVM文本覆盖到在途值。读取/解析异常交回调用者，
    // 不猜空记录；合并仅发生在事务期间，普通同步调用的原有语义与签名保持不变。
    const next: VersionLaunchOverride = {
      xmx: o.xmx, jdkVersion: o.jdkVersion, customJvmArgs: o.customJvmArgs,
      gameLanguage: o.gameLanguage, renderScalePercent: o.renderScalePercent,
    };
    let legacyConfirmed: VersionLaunchOverride | undefined = undefined;
    if (this.resolutionWrites?.originals.has(key)) {
      const current: VersionLaunchOverride = this.versionOverrideForWrite_(this.pref.getSync(key, ''));
      next.renderScalePercent = normalizeResolutionPreference(current.renderScalePercent);
      if (this.resolutionWrites.jvmKeys.has(key)) {
        const baseline: VersionLaunchOverride = this.versionOverrideForWrite_(
          this.resolutionWrites.originals.get(key) as LaunchPreferenceValue);
        // 只应用调用者相对确认快照实际改动的其他字段，连续JDK/语言写入不会互带旧快照。
        if (next.xmx === baseline.xmx) next.xmx = current.xmx;
        if (next.jdkVersion === baseline.jdkVersion) next.jdkVersion = current.jdkVersion;
        if (next.gameLanguage === baseline.gameLanguage) next.gameLanguage = current.gameLanguage;
        next.customJvmArgs = current.customJvmArgs;
        // 旧void字段维持原有“同步缓存可读”语义；只保留JVM/分辨率的确认屏障。
        // 更新这些字段的读取基线后，下次明确选回旧JDK/语言也会被识别为真正改动。
        baseline.xmx = next.xmx;
        baseline.jdkVersion = next.jdkVersion;
        baseline.gameLanguage = next.gameLanguage;
        legacyConfirmed = baseline;
      }
    }
    if (next.xmx <= 0 && next.jdkVersion.length === 0 && next.customJvmArgs.length === 0
        && next.gameLanguage.length === 0 && normalizeResolutionPreference(next.renderScalePercent) === 0) {
      try {
        this.pref.deleteSync(key);
        this.pref.flush();
        if (legacyConfirmed !== undefined && this.resolutionWrites !== undefined
          && this.pref.getSync(key, '') === '') {
          this.resolutionWrites.originals.set(key, JSON.stringify(legacyConfirmed));
        }
      } catch (e) { /* 不存在也无妨，旧void入口仍维持原失败契约。 */ }
      return;
    }
    const encoded: string = JSON.stringify(next);
    this.put(key, encoded);
    // put()保留旧void错误处理；只有缓存确实接受本次值才发布其他字段的读取基线。
    if (legacyConfirmed !== undefined && this.resolutionWrites !== undefined
      && this.pref.getSync(key, '') === encoded) {
      this.resolutionWrites.originals.set(key, JSON.stringify(legacyConfirmed));
    }
  }

  /**
   * 解析某版本【实际生效】的启动配置——统一控制点，逐字段在"单版本覆盖"与"全局"间继承：
   *   - xmx           : 单版本 > 0 时用单版本，否则用全局 mcXmx
   *   - jdkVersion    : 单版本非空时用单版本（调用方校验已安装），否则 '' = 按纪元自动路由
   *   - customJvmArgs : 全局参数 + 单版本参数 拼接（单版本在后，优先级更高）
   * fromGlobal = 该版本无任何覆盖（纯沿用全局）。
   */
  resolveLaunch(versionId: string): EffectiveLaunchConfig {
    let o = this.getVersionOverride(versionId);
    let merged: string[] = [];
    let g = this.customJvmArgs.trim();
    if (g.length > 0) merged.push(g);
    let v = o.customJvmArgs.trim();
    if (v.length > 0) merged.push(v);
    // 虚拟内存（堆文件）模式：注入 marker，由 C 层 launchWithProfileImpl 识别并
    // 转成 -XX:AllocateHeapAt。放在末尾即可（marker 无覆盖语义、不参与去重）。
    if (this.virtualMemoryMode) merged.push('-Damcl.heapfile=1');
    // 游戏语言（启动器权威）：单版本非空则用单版本，否则跟随全局；作为 marker 注入，
    // 由 C 层 applyGameLanguage 写进该版本 options.txt 的 lang。lang 恒非空（全局默认
    // zh_cn），故每次启动都会按选择校正语言。marker 本身不下传 JVM（native 消费）。
    let lang = o.gameLanguage.length > 0 ? o.gameLanguage : this.gameLanguage;
    if (lang.length > 0) merged.push('-Damcl.gamelang=' + lang);
    return {
      xmx: o.xmx > 0 ? o.xmx : this.mcXmx,
      jdkVersion: o.jdkVersion,
      customJvmArgs: merged.join(' '),
      gameLanguage: lang,
      renderScalePercent: normalizeResolutionPreference(o.renderScalePercent) || this.resolutionScalePercent,
      fromGlobal: o.xmx <= 0 && o.jdkVersion.length === 0 && o.customJvmArgs.length === 0
        && o.gameLanguage.length === 0 && normalizeResolutionPreference(o.renderScalePercent) === 0,
    };
  }

  /**
   * JDK 版本（全局默认 Java 运行时选择）。
   *
   * 取值：'auto'（按游戏要求自动选择）或规范数字主版本，离线时也保留用户选择。
   * 历史：旧默认是 '17'。已显式存过具体版本的用户保留其值（仍当作"偏好 hint"，
   *      由 LaunchCoordinator/resolveLaunchJdk 在兼容时采用、不兼容回退纪元路由——行为同旧版）；
   *      新用户拿到 'auto'。只有非法槽位语法才回退，不能因当前目录没有某版本就清空偏好。
   *
   * 性能：getter 在 Index.onPageShow / updateJdkReadyState 等热路径里高频调用；
   * `migratedOnce_` 标志保证 disk write 每个 Preferences 实例最多一次。
   */
  private migratedJdkVersionOnce_: boolean = false;
  get jdkVersion(): string {
    let saved = this.getString('jdkVersion', JDK_AUTO);
    // 目录离线/下架不能擦除用户对未来主版本的偏好；启动时另验适配与真实安装内容。
    if (saved !== JDK_AUTO && !isJdkSlotVersion(saved)) {
      if (!this.migratedJdkVersionOnce_) {
        hilog.warn(0x0000, TAG,
          'Migrate unknown jdkVersion %{public}s -> %{public}s',
          saved, JDK_AUTO);
        this.put('jdkVersion', JDK_AUTO);
        this.migratedJdkVersionOnce_ = true;
      }
      return JDK_AUTO;
    }
    return saved;
  }
  set jdkVersion(v: string) { this.put('jdkVersion', v); }

  // ===== P1-MODS §6.4: 模组下载相关偏好 =====

  /** 模组源偏好：'auto' 走 SourceProber，'mcim' 强制镜像，'official' 强制官方 */
  get modSource(): string { return this.getString('modSource', 'auto'); }
  set modSource(v: string) { this.put('modSource', v); }

  /**
   * MC 版本下载源偏好（client.jar / libraries / assets / 版本清单）：
   *   - 'auto'     自动：按 RTT 探测选更快的源（默认）
   *   - 'mirror'   强制镜像优先（BMCLAPI）
   *   - 'official' 强制官方优先（Mojang / piston-data）
   *
   * 2026-08-04 新增。在此之前**根本不存在**这个偏好：设置页里的 auto/mcim/official
   * 只作用于模组（modSource → ModrinthSourceMode），版本下载的源顺序完全由
   * SourceProber 的 RTT 探测决定，用户怎么切都不可能生效。
   *
   * 语义与 PCL2 的 ToolDownloadSource 对齐：**只重排，不删源**。选了"官方"时官方排前面，
   * 但镜像仍在候选列表里兜底，官方挂了引擎会自动回退。
   *
   * 未知脏数据回退 'auto'。
   */
  get mcSource(): string {
    let v = this.getString('mcSource', 'auto');
    if (v !== 'auto' && v !== 'mirror' && v !== 'official') return 'auto';
    return v;
  }
  set mcSource(v: string) { this.put('mcSource', v); }

  /**
   * JDK 下载源偏好：
   *   - 'auto'   自动（Gitee 国内直连优先 → 失败回退 GitHub 镜像/直连，推荐）
   *   - 'github' GitHub 源站优先（适合开代理/VPN 的用户，直连 GitHub 常满速，比任何镜像都快）
   *   - 'gitee'  强制 Gitee 国内镜像（失败仍回退 GitHub 保证可用）
   *   - 'mirror' 强制 GitHub 代理镜像（不走 Gitee，交给下载引擎按 RTT 选最快镜像）
   * 未知脏数据回退到 'auto'。
   */
  get jdkSource(): string {
    let v = this.getString('jdkSource', 'auto');
    if (v !== 'auto' && v !== 'github' && v !== 'gitee' && v !== 'mirror' && v !== 'web') return 'auto';
    return v;
  }
  set jdkSource(v: string) { this.put('jdkSource', v); }

  /** JDK 独立偏好：默认稳定、自动检查开启，自有服务器必须由用户显式启用。 */
  get jdkChannel(): string { return this.getString('jdkChannel','stable') === 'preview' ? 'preview' : 'stable'; }
  set jdkChannel(v: string) { this.put('jdkChannel',v === 'preview' ? 'preview' : 'stable'); }
  get jdkWebEnabled(): boolean { return this.getBool('jdkWebEnabled',false); }
  set jdkWebEnabled(v: boolean) { this.put('jdkWebEnabled',v); }
  get jdkAutoCheck(): boolean { return this.getBool('jdkAutoCheck',true); }
  set jdkAutoCheck(v: boolean) { this.put('jdkAutoCheck',v); }
  get jdkLastCheck(): number { return this.getNumber('jdkLastCheck',0); }
  set jdkLastCheck(v: number) { this.put('jdkLastCheck',v); }
  get jdkDeferredAt(): number { return this.getNumber('jdkDeferredAt',0); }
  set jdkDeferredAt(v: number) { this.put('jdkDeferredAt',v); }
  get jdkDeferredTarget(): string { return this.getString('jdkDeferredTarget',''); }
  set jdkDeferredTarget(v: string) { this.put('jdkDeferredTarget',v); }

  /** 是否缓存远程元数据（项目详情 / 版本列表 TTL 缓存） */
  get cacheRemoteMeta(): boolean { return this.getBool('cacheRemoteMeta', true); }
  set cacheRemoteMeta(v: boolean) { this.put('cacheRemoteMeta', v); }

  /**
   * 加速下载（经 AMCL 加速网关）。
   *
   * 打开后：把**官方源** URL（Mojang / cdn.modrinth.com / GitHub / 官方 Maven）改写成
   * 经由加速网关。镜像源 URL 不改写也不移除。
   *
   * ⚠️ 2026-08-04 修正描述：原注释写「用户原有的镜像/源偏好一律不生效」，与实现不符。
   * native 侧 `relayCanAccelerate` 只对官方主机放行，候选 URL 列表既不重排也不删项；
   * 唯一真的会覆盖用户选择的地方是 JDK 源（getJdkDownloadSource），且已改为**只覆盖
   * 'auto'**，显式选择照办。原则统一为：**用户选了就用用户的**。
   *
   * 为什么这样设计：网关部署在美国，到各官方源实测 3~5MB/s 且不会被地域重定向甩到
   * 慢节点（真机对比：国内直连 cdn-alt.modrinth.com 3~5KB/s，经网关 1343KB/s）。
   * 此时再走国内镜像只会多一层转发、还可能命中镜像自身的缓存未命中回源，纯亏。
   *
   * 默认关闭：网关是可选增强，关掉就是完全原来的行为（不依赖我们的服务器）。
   */
  get accelDownload(): boolean { return this.getBool('accelDownload', false); }
  set accelDownload(v: boolean) { this.put('accelDownload', v); }

  /**
   * 加速网关的设备标识（首次生成后固定）。
   * 作用：让加速面板能按设备聚合流量/配额/封禁，出问题可溯源到具体一台设备。
   * 不含任何个人信息，就是一串随机 hex。
   */
  get relayDeviceId(): string { return this.getString('relayDeviceId', ''); }
  set relayDeviceId(v: string) { this.put('relayDeviceId', v); }

  /** 模组并发下载数（同时下载几个 mod 文件） */
  get modConcurrentDownloads(): number { return this.getNumber('modConcurrentDownloads', 3); }
  set modConcurrentDownloads(v: number) { this.put('modConcurrentDownloads', v); }

  // ===== 上次启动时间（用于首页 Quick Stats "上次游戏" 卡片） =====

  /**
   * 上次启动 MC 的 wall-clock 时间戳（ms），0 = 从未启动过。
   *
   * 与 SessionMarker 的差异：
   *   - SessionMarker 标记"上次会话**未正常关闭**"（用于冷启动 toast 提示）；
   *   - lastPlayedAt 是"最近一次成功执行 launch 流程"的时间，正常退出 / 进程被杀
   *     都不影响其值。HomeTab 只关心"最近一次玩"。
   *
   * 由 Index.launchMC 在拉起 MC 之前写入；HomeTab 通过 prop 读取。
   */
  get lastPlayedAt(): number { return this.getNumber('lastPlayedAt', 0); }
  set lastPlayedAt(v: number) { this.put('lastPlayedAt', v); }

  /** 上次启动的版本 id（与 lastPlayedAt 配对，未来 HomeTab 可显示"上次：1.20.4"） */
  get lastPlayedVersion(): string { return this.getString('lastPlayedVersion', ''); }
  set lastPlayedVersion(v: string) { this.put('lastPlayedVersion', v); }

  // ===== 检查更新（节流 + 红点持久化） =====

  /** App 订阅独立于 jdkChannel；旧安装默认稳定，不沿用未知或损坏的选择。 */
  get appUpdateChannel(): string {return this.appUpdateChannelWrites?.originalChannel ?? (this.getString('appUpdateChannel','stable')==='preview'?'preview':'stable');}
  /** 兼容旧void调用；真实页面使用可等待入口，失败可见而不把在途缓存当保存成功。 */
  set appUpdateChannel(value: string) {this.selectAppUpdateChannel(value).catch((error: Error): void=>{hilog.warn(0x0000,TAG,'更新订阅保存失败：%{public}s',error.message);});}
  private readAppUpdateRevision_(): number {
    const value=this.pref.getSync('appUpdateChannelRevision',0);
    if(typeof value!=='number'||!Number.isSafeInteger(value)||value<0)throw new Error('更新订阅代次无效，请重新核实设置');
    return value;
  }
  /** 在App原事务创建时同步冻结用户选择代次；不存在的新键按历史基线0，旧事务无字段不补造。 */
  appUpdateSelectionRevision(): number {
    const state=this.appUpdateChannelWrites;
    if(state===undefined||ProcessPreferences.isGameProcess())throw new Error('更新订阅缺少启动器写owner');
    if(state.selectionPending>0||state.originalRevision!==undefined)throw new Error('更新订阅保存尚未确认，请稍后重试更新');
    return Math.max(state.originalRevision ?? this.readAppUpdateRevision_(),state.requestedRevision);
  }
  /** 明确用户选择生成新代次；值和代次在同一put/await flush中确认，同目录请求串行。 */
  selectAppUpdateChannel(value: string): Promise<void> {
    const state=this.appUpdateChannelWrites;
    if(state===undefined||ProcessPreferences.isGameProcess())return Promise.reject(new Error('更新订阅缺少启动器写owner'));
    let revision: number;
    try{revision=Math.max(this.readAppUpdateRevision_(),state.requestedRevision)+1;}catch(error){return Promise.reject(error as Error);}
    if(!Number.isSafeInteger(revision))return Promise.reject(new Error('更新订阅代次超限'));
    state.requestedRevision=revision;state.selectionPending++;
    const work=state.tail.catch((): void=>{}).then(async (): Promise<void>=>{await this.writeAppUpdateSelection_(state,value,revision);});
    // 失败且回滚已确认的用户请求没有产生耐久新代次；最后请求结束后收回内存预约。
    // 回滚仍未知时继续保留确认屏障，新App事务不能捕获尚未存在的磁盘代次。
    const settled=work.finally((): void=>{state.selectionPending--;if(state.selectionPending===0&&state.originalRevision===undefined)state.requestedRevision=this.readAppUpdateRevision_();});
    state.tail=settled.catch((): void=>{});return settled;
  }
  /** 原完成步骤只在捕获代次未变化时写入；返回false表示后来选择或旧schema优先，不覆盖。 */
  commitAppUpdateChannel(value: string,expectedRevision?: number): Promise<boolean> {
    const state=this.appUpdateChannelWrites;
    if(expectedRevision===undefined)return Promise.resolve(false);
    if(state===undefined||ProcessPreferences.isGameProcess())return Promise.reject(new Error('更新订阅缺少启动器写owner'));
    const work=state.tail.catch((): void=>{}).then(async (): Promise<boolean>=>{
      if(!Number.isSafeInteger(expectedRevision)||expectedRevision<0)throw new Error('原更新订阅代次无效');
      if(state.requestedRevision>expectedRevision || this.readAppUpdateRevision_()!==expectedRevision)return false;
      await this.writeAppUpdateSelection_(state,value,expectedRevision);return true;
    });
    state.tail=work.then((): void=>{},(): void=>{});return work;
  }
  /** 只回滚本域两键；回滚未知时保留确认屏障，不把失败缓存发布给其他页面。 */
  private async writeAppUpdateSelection_(state: AppUpdateChannelWriteState,value: string,revision: number): Promise<void> {
    const previousChannel=state.originalChannel ?? (this.pref.getSync('appUpdateChannel','stable')==='preview'?'preview':'stable');
    const previousRevision=state.originalRevision ?? this.readAppUpdateRevision_();
    state.originalChannel=previousChannel;state.originalRevision=previousRevision;
    try {
      this.pref.putSync('appUpdateChannel',value==='preview'?'preview':'stable');this.pref.putSync('appUpdateChannelRevision',revision);
      await this.pref.flush();state.originalChannel=undefined;state.originalRevision=undefined;
    } catch (_) {
      this.pref.putSync('appUpdateChannel',previousChannel);this.pref.putSync('appUpdateChannelRevision',previousRevision);
      try{await this.pref.flush();state.originalChannel=undefined;state.originalRevision=undefined;}catch(_){throw new Error('更新订阅保存及回滚尚未确认，请重新核实存储');}
      throw new Error('更新订阅尚未保存，请重试');
    }
  }
  /** 每个产品／通道拥有独立节流与推荐缓存，旧全局缓存不自动迁为稳定版事实。 */
  private appUpdateKey(product: string, channel: string, field: string): string {
    return 'appUpdate.' + (product === 'desktop' ? 'desktop' : 'sideload') + '.' + (channel === 'preview' ? 'preview' : 'stable') + '.' + field;
  }
  appUpdateLastCheck(product: string, channel: string): number { return this.getNumber(this.appUpdateKey(product,channel,'checkedAt'),0); }
  appUpdateLatestSeen(product: string, channel: string): number { return this.getNumber(this.appUpdateKey(product,channel,'latestCode'),0); }
  /** 目标键已绑定 tag/code/hash；从已保存 tag 恢复发行名，旧缓存无合法名字时只按 code 判断。 */
  appUpdateLatestName(product: string, channel: string): string {
    const tag = this.getString(this.appUpdateKey(product,channel,'target'),'').split(':')[0];
    return tag.startsWith('v') ? tag.substring(1) : '';
  }
  appUpdateDeferredAt(product: string, channel: string): number { return this.getNumber(this.appUpdateKey(product,channel,'deferredAt'),0); }
  /** 切换通道后允许立即检查；只清该通道节流，不动其它订阅与安装事务。 */
  resetAppUpdateCheck(product: string, channel: string): void { this.put(this.appUpdateKey(product,channel,'checkedAt'),0); }
  /** 只记录成功的可信候选。目标改变清除旧延后；新推荐较低也如实替换红点事实。 */
  rememberAppUpdate(product: string, channel: string, code: number, target: string): void {
    const key=this.appUpdateKey(product,channel,'target');
    if(this.getString(key,'')!==target) this.put(this.appUpdateKey(product,channel,'deferredAt'),0);
    this.put(key,target); this.put(this.appUpdateKey(product,channel,'latestCode'),code);
    this.put(this.appUpdateKey(product,channel,'checkedAt'),Date.now());
  }
  /** 延后绑定展示时目标与通道，旧弹窗关闭不会压制后来发现的新候选。 */
  deferAppUpdate(product: string, channel: string, target: string): void {
    if(this.getString(this.appUpdateKey(product,channel,'target'),'')===target) this.put(this.appUpdateKey(product,channel,'deferredAt'),Date.now());
  }

  /** 上次成功检查更新（自动或手动）的 wall-clock 时间戳（ms），0 = 从未。用于自动节流。 */
  get lastUpdateCheckAt(): number { return this.getNumber('lastUpdateCheckAt', 0); }
  set lastUpdateCheckAt(v: number) { this.put('lastUpdateCheckAt', v); }

  /**
   * 用户上次在更新弹窗点击「稍后再说」的 wall-clock 时间戳（ms），0 = 未延后。
   * 红点不受它影响；只在 24 小时内压制启动自动检查/弹窗。
   */
  get updatePromptDeferredAt(): number { return this.getNumber('updatePromptDeferredAt', 0); }
  set updatePromptDeferredAt(v: number) { this.put('updatePromptDeferredAt', v); }

  /**
   * 见过的线上最新 versionCode（来自 update.json）。冷启动时若 > 已装 versionCode →
   * 立即显示红点（无需联网）；用户真正升级后已装 versionCode 追上，红点自然消失。
   */
  get latestSeenVersionCode(): number { return this.getNumber('latestSeenVersionCode', 0); }
  set latestSeenVersionCode(v: number) { this.put('latestSeenVersionCode', v); }

  // ===== 已装资源 sheet 的行排序（按 versionId + kind 维度持久化） =====

  /**
   * 已装模组 / 资源包 / 光影 / 数据包 sheet 的行顺序。
   *
   * 设计：
   *   - key  = `resOrder.<versionId>.<kind>`，例如 `resOrder.fabric-loader-0.18.6-1.20.4.mod`
   *   - val  = JSON 编码的 `string[]`，每项是"逻辑文件名"
   *            （`.jar.disabled` 会被剥成 `.jar`，下面用 enableFilename 归一化），
   *            这样切换启用/禁用导致 filename 变化时仍能命中同一项，行不会跳。
   *   - 行为 = 真相源是磁盘文件目录；本数组只用作"已知项的顺序提示"。
   *            refresh 时：磁盘里有但数组里没有的项 → 按字母序追加到末尾；
   *                        数组里有但磁盘里没的 → 从持久化清掉；
   *                        两边都有 → 用数组里的相对顺序排。
   *
   * 为什么不直接 sort by filename？
   *   - 用户可能手动安装"我的整合包推荐顺序"或者按依赖顺序排版，简单字母序会破坏这个意图。
   *   - 用户切 toggle 时，原版 `enabled !== a.enabled ? -1 : 1` 排序键会让行跳到顶部 / 底部，
   *     体感像 sheet 重新洗牌了一次，非常糟糕。
   *
   * 失败语义：JSON 损坏 / 不存在 → 当作空数组（→ 全按字母序）。
   */
  getResOrder(versionId: string, kindKey: string): string[] {
    if (versionId.length === 0 || kindKey.length === 0) return [];
    let key = 'resOrder.' + versionId + '.' + kindKey;
    let raw = this.getString(key, '');
    if (raw.length === 0) return [];
    try {
      let arr = JSON.parse(raw) as Object;
      if (!Array.isArray(arr)) return [];
      let result: string[] = [];
      for (let item of arr as Object[]) {
        if (typeof item === 'string') result.push(item as string);
      }
      return result;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'getResOrder parse failed: %{public}s', formatError(e));
      return [];
    }
  }

  setResOrder(versionId: string, kindKey: string, names: string[]): void {
    if (versionId.length === 0 || kindKey.length === 0) return;
    let key = 'resOrder.' + versionId + '.' + kindKey;
    if (names.length === 0) {
      // 空列表 → 删 key（避免存储里堆一堆空 entry）
      try { this.pref.deleteSync(key); this.pref.flush(); }
      catch (e) { /* 不存在也无所谓 */ }
      return;
    }
    this.put(key, JSON.stringify(names));
  }

  // ===== 版本列表的用户自定义拖拽顺序 =====

  /**
   * 版本管理列表的行顺序（用户拖拽决定）。
   *   - key = `versionOrder`，val = JSON 编码的 `string[]`（版本目录名，自上而下）。
   *   - 真相源是磁盘 versions/ 目录；本数组只是"已知项的顺序提示"。
   *   - 合并规则（见 Index.applyVersionOrder）：磁盘有但数组没有的【新下载】版本按
   *     mtime 倒序排在最上面；数组里有且磁盘仍在的按数组顺序；数组里有但磁盘没的忽略。
   *   - 失败语义：JSON 损坏 / 不存在 → 空数组（→ 全按"最新下载在上"）。
   */
  get versionOrder(): string[] {
    let raw = this.getString('versionOrder', '');
    if (raw.length === 0) return [];
    try {
      let arr = JSON.parse(raw) as Object;
      if (!Array.isArray(arr)) return [];
      let result: string[] = [];
      for (let item of arr as Object[]) {
        if (typeof item === 'string') result.push(item as string);
      }
      return result;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'get versionOrder parse failed: %{public}s', formatError(e));
      return [];
    }
  }
  set versionOrder(names: string[]) {
    if (names.length === 0) {
      try { this.pref.deleteSync('versionOrder'); this.pref.flush(); } catch (e) { /* */ }
      return;
    }
    this.put('versionOrder', JSON.stringify(names));
  }

  /**
   * 一次性加载所有设置到目标对象（用于 ViewModel 初始化）
   */
  loadAll(): PreferenceSnapshot {
    return {
      themeMode: this.themeMode,
      mcVersion: this.mcVersion,
      useNewWindow: this.useNewWindow,
      versionIsolation: this.versionIsolation,
      mcXmx: this.mcXmx,
      jdkVersion: this.jdkVersion,
    };
  }

  /**
   * 保存旧游戏设置快照。主题和光感均有独立确认事务，不得由其他设置的批量保存
   * 覆盖临时预览或正在flush的确认值；themeMode只保留在loadAll返回值用于兼容读取。
   */
  saveAll(snapshot: PreferenceSnapshot): void {
    this.putBatch({
      'mcVersion': snapshot.mcVersion,
      'useNewWindow': snapshot.useNewWindow,
      'versionIsolation': snapshot.versionIsolation,
      'mcXmx': snapshot.mcXmx,
      'jdkVersion': snapshot.jdkVersion,
    });
  }
}

export interface PreferenceSnapshot {
  themeMode: ThemeMode;
  mcVersion: string;
  useNewWindow: boolean;
  versionIsolation: boolean;
  mcXmx: number;
  jdkVersion: string;
}

/** 单版本启动配置覆盖（字段级继承模型）。每个字段的"空值"表示沿用全局：
 *  xmx<=0 → 全局内存；customJvmArgs '' → 仅用全局参数。
 *  jdkVersion 取值：'' = 跟随全局设置；'auto' = 该版本按纪元自动路由；
 *               具体版本（'8'/'17'/'21'/'25'）= 硬覆盖（即便与纪元不匹配也照用，供调试）。 */
export interface VersionLaunchOverride {
  xmx: number;          // MB，<=0 = 沿用全局
  jdkVersion: string;   // '' = 跟随全局 | 'auto' = 自动路由 | 具体版本 = 硬覆盖
  customJvmArgs: string;
  /** 缺失/0 继承全局；50–100 是该实例的显式选择，100 不等于继承。 */
  renderScalePercent?: number;
  gameLanguage: string; // '' = 跟随全局设置 | 具体 code（'zh_cn'/'en_us'…）= 单版本硬覆盖
}

/** 某版本实际生效的启动配置（resolveLaunch 的返回）。 */
export interface EffectiveLaunchConfig {
  xmx: number;
  jdkVersion: string;   // '' = 调用方按纪元自动路由
  customJvmArgs: string;
  /** 显式政策的继承结果；0 让 Builder 继续消费兼容的旧 JVM marker。 */
  renderScalePercent: number;
  gameLanguage: string; // 实际生效的游戏语言 code（单版本覆盖 or 全局默认；恒非空）
  fromGlobal: boolean;
}
