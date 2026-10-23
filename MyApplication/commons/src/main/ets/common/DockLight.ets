/** 底部栏材质偏好。持久化使用稳定字符串，不依赖 SDK 枚举的数值。 */
export enum DockLightMode {
  AUTO = 'adaptive',
  EXQUISITE = 'exquisite',
  GENTLE = 'gentle',
  SMOOTH = 'smooth',
  OFF = 'off'
}

/** 旧安装没有该键、类型损坏或未知新值时均回到自动，不授予未确认的精美档位。 */
export function normalizeDockLightMode(value: string): DockLightMode {
  switch (value) {
    case DockLightMode.EXQUISITE: return DockLightMode.EXQUISITE;
    case DockLightMode.GENTLE: return DockLightMode.GENTLE;
    case DockLightMode.SMOOTH: return DockLightMode.SMOOTH;
    case DockLightMode.OFF: return DockLightMode.OFF;
    default: return DockLightMode.AUTO;
  }
}

/** 设置和降级提示共享中文名称；这里只描述 HDS 底部栏，不代表系统强弱设置。 */
export function dockLightModeLabel(mode: DockLightMode): string {
  switch (mode) {
    case DockLightMode.EXQUISITE: return '精美';
    case DockLightMode.GENTLE: return '轻柔';
    case DockLightMode.SMOOTH: return '流畅';
    case DockLightMode.OFF: return '关闭';
    default: return '自动';
  }
}

/**
 * 将用户偏好解析为当前设备的有效档位，不修改持久偏好。
 * 关闭始终生效；旧系统只保留兼容自动样式。精美、轻柔需要确认 IMMERSIVE，
 * 查询失败也按未确认处理并使用流畅；自动仍交给系统决定材质生效策略。
 */
export function resolveDockLightMode(mode: DockLightMode, floatingSupported: boolean,
  immersiveSupported: boolean): DockLightMode {
  if (mode === DockLightMode.OFF) return DockLightMode.OFF;
  if (!floatingSupported) return DockLightMode.AUTO;
  if (!immersiveSupported && (mode === DockLightMode.EXQUISITE || mode === DockLightMode.GENTLE)) {
    return DockLightMode.SMOOTH;
  }
  return mode;
}
