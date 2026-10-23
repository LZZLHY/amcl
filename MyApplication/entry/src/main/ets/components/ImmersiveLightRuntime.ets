/** 已确认光感偏好的 UI 发布与能力缓存；只协调当前两类 HDS 消费者，不扫描组件树。 */
import { PreferenceManager } from 'feature_system';
import { DockLightMode, ImmersiveLightPreferences, ImmersiveLightModule,
  decodeImmersiveLightPreferences, encodeImmersiveLightPreferences, resolveImmersiveLightMode } from 'commons';
import { DockLightCapabilities, readDockLightCapabilities, dockLightStatus } from './DockLightMaterial';

let capabilities: DockLightCapabilities | undefined = undefined;
let decodedRaw: string = '';
let decoded: ImmersiveLightPreferences = decodeImmersiveLightPreferences('');

/** 进程内只探测一次；旧系统不会进入 API23 HDS 查询分支。 */
export function immersiveLightCapabilities(): DockLightCapabilities {
  if (capabilities === undefined) capabilities = readDockLightCapabilities();
  return capabilities;
}

/** 同一序列化记录反复用于进度刷新时复用解码结果，不反复解析或查询硬件。 */
function currentPreferences(raw: string): ImmersiveLightPreferences {
  if (raw !== decodedRaw) { decodedRaw = raw; decoded = decodeImmersiveLightPreferences(raw); }
  return decoded;
}

/** 只有持久化确认后的整组配置才发布；相同字节不触发全局 UI 再通知。 */
export function publishImmersiveLightPreferences(value: ImmersiveLightPreferences): void {
  const raw: string = encodeImmersiveLightPreferences(value);
  if (AppStorage.get<string>('amclImmersiveLightConfig') !== raw) {
    AppStorage.setOrCreate<string>('amclImmersiveLightConfig', raw);
  }
}

/** 独立路由或 Sheet 首次显示时加载同一权威偏好；已有确认值遇初始化异常不被覆盖。 */
export function initializeImmersiveLightRuntime(context: Context): void {
  // StorageLink 可能先建立空字符串键，只有非空确认记录才算完成初始化。
  // 多页面／Sheet共用发布值，避免每出现一个标题都重新构造PreferenceManager读盘。
  const published: string | undefined = AppStorage.get<string>('amclImmersiveLightConfig');
  if (published !== undefined && published.length > 0) return;
  try { publishImmersiveLightPreferences(new PreferenceManager(context).immersiveLightPreferences); }
  catch (_) {
    if (!AppStorage.has('amclImmersiveLightConfig')) publishImmersiveLightPreferences(decodeImmersiveLightPreferences(''));
  }
}

/** 标题容器只接收有效档位；未初始化、总关闭或模块关闭时均为普通样式。 */
export function effectiveTitleLightMode(serializedConfig: string): DockLightMode {
  const support: DockLightCapabilities = immersiveLightCapabilities();
  return resolveImmersiveLightMode(currentPreferences(serializedConfig), ImmersiveLightModule.TITLE_BUTTONS,
    support.floatingSupported, support.immersiveSupported);
}

/** 供底部栏复用总开关和模块优先级，旧系统自动路径仍保留现有兼容样式。 */
export function effectiveBottomLightMode(value: ImmersiveLightPreferences): DockLightMode {
  const support: DockLightCapabilities = immersiveLightCapabilities();
  return resolveImmersiveLightMode(value, ImmersiveLightModule.BOTTOM_BAR, support.floatingSupported, support.immersiveSupported);
}

/** 设置页展示请求与有效状态，不把标题不支持或模块关闭写成配置已丢失。 */
export function immersiveLightStatus(value: ImmersiveLightPreferences): string {
  if (!value.enabled) return '已关闭本应用已适配区域的光感，模块选择已保留。';
  if (!value.bottomBar && !value.titleButtons) return '尚未开启任何模块。';
  const support: DockLightCapabilities = immersiveLightCapabilities();
  if (value.titleButtons && !support.floatingSupported) {
    return '当前系统的标题按钮使用普通背景，模块选择已保留' + (value.bottomBar ? '；底部栏使用兼容样式。' : '。');
  }
  return dockLightStatus(value.navigationMode, support).replace('仅调整底部栏，', '已启用模块的');
}
