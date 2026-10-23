/** 应用已接入区域的光感偏好；不修改系统光感强弱，也不包含尚未实现的模块。 */
import { DockLightMode, normalizeDockLightMode, resolveDockLightMode } from './DockLight';

/** 整组配置以一个版本化记录保存；新标题按钮默认关闭，保留原有底部栏范围。 */
export class ImmersiveLightPreferences {
  version: number = 1;
  enabled: boolean = true;
  navigationMode: DockLightMode = DockLightMode.AUTO;
  bottomBar: boolean = true;
  titleButtons: boolean = false;
}

/** 模块库存固定为当前已接入的两类，不依赖 SDK 枚举数字或动态扫描组件。 */
export enum ImmersiveLightModule {
  BOTTOM_BAR = 'bottomBar',
  TITLE_BUTTONS = 'titleButtons'
}

/** 复制已确认配置，保证设置页和调用者无法原地修改共享状态。 */
export function copyImmersiveLightPreferences(value: ImmersiveLightPreferences): ImmersiveLightPreferences {
  const result: ImmersiveLightPreferences = new ImmersiveLightPreferences();
  result.version = value.version;
  result.enabled = value.enabled;
  result.navigationMode = value.navigationMode;
  result.bottomBar = value.bottomBar;
  result.titleButtons = value.titleButtons;
  return result;
}

/** 新记录缺失时才迁移旧五档；旧关闭转为总关闭，不默认开启新标题按钮模块。 */
export function migrateImmersiveLightPreferences(legacyMode: DockLightMode): ImmersiveLightPreferences {
  const result: ImmersiveLightPreferences = new ImmersiveLightPreferences();
  const mode: DockLightMode = normalizeDockLightMode(legacyMode);
  result.enabled = mode !== DockLightMode.OFF;
  result.navigationMode = mode === DockLightMode.OFF ? DockLightMode.AUTO : mode;
  return result;
}

/** 严格验证整组写入，OFF 只能通过总开关表达，不能混入四档导航偏好。 */
export function validImmersiveLightPreferences(value: ImmersiveLightPreferences): boolean {
  return value !== null && typeof value === 'object' && value.version === 1 &&
    typeof value.enabled === 'boolean' && typeof value.bottomBar === 'boolean' &&
    typeof value.titleButtons === 'boolean' && typeof value.navigationMode === 'string' &&
    value.navigationMode !== DockLightMode.OFF && normalizeDockLightMode(value.navigationMode) === value.navigationMode;
}

/** 损坏或未来版本记录安全关闭，不回头复活可能已过时的旧键。 */
export function decodeImmersiveLightPreferences(serialized: string): ImmersiveLightPreferences {
  try {
    const value: ImmersiveLightPreferences = JSON.parse(serialized) as ImmersiveLightPreferences;
    if (validImmersiveLightPreferences(value)) return copyImmersiveLightPreferences(value);
  } catch (_) { /* 无法解码的记录使用下方安全缺省，不影响页面进入。 */ }
  const fallback: ImmersiveLightPreferences = new ImmersiveLightPreferences();
  fallback.enabled = false;
  return fallback;
}

/** 一次序列化整组配置；非法输入在任何 Preferences 写入前拒绝。 */
export function encodeImmersiveLightPreferences(value: ImmersiveLightPreferences): string {
  if (!validImmersiveLightPreferences(value)) throw new Error('沉浸光感配置无效');
  return JSON.stringify(copyImmersiveLightPreferences(value));
}

/** 总关闭优先于模块，再应用各自能力回退；标题按钮在旧系统始终使用普通背景。 */
export function resolveImmersiveLightMode(value: ImmersiveLightPreferences, module: ImmersiveLightModule,
  floatingSupported: boolean, immersiveSupported: boolean): DockLightMode {
  const selected: boolean = module === ImmersiveLightModule.BOTTOM_BAR ? value.bottomBar : value.titleButtons;
  if (!value.enabled || !selected) return DockLightMode.OFF;
  if (module === ImmersiveLightModule.TITLE_BUTTONS && !floatingSupported) return DockLightMode.OFF;
  return resolveDockLightMode(value.navigationMode, floatingSupported, immersiveSupported);
}
