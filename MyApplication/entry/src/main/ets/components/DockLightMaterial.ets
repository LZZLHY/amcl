/** HDS 能力边界与设置提示；只有 entry 依赖 UI Design Kit，共享偏好保持纯数据。 */
import { deviceInfo } from '@kit.BasicServicesKit';
import { hdsMaterial } from '@kit.UIDesignKit';
import { DockLightMode, dockLightModeLabel, resolveDockLightMode } from 'commons';

/** 一次启动器实例内查询一次，避免主题、进度或页面刷新反复探测设备。 */
export class DockLightCapabilities {
  floatingSupported: boolean = false;
  immersiveSupported: boolean = false;
  queryFailed: boolean = false;
}

/**
 * HDS 属于 HarmonyOS 专有接口，使用编译器支持的 apiAvailable 保护其 6.1.0 起始版本。
 * 在旧系统不触碰 getSystemMaterialTypes；查询抛错时保留自动／流畅回退，不中断首页。
 */
export function readDockLightCapabilities(): DockLightCapabilities {
  const result: DockLightCapabilities = new DockLightCapabilities();
  if (deviceInfo.apiAvailable('6.1.0')) {
    result.floatingSupported = true;
    try {
      result.immersiveSupported = hdsMaterial.getSystemMaterialTypes().indexOf(hdsMaterial.MaterialType.IMMERSIVE) >= 0;
    } catch (_) {
      result.queryFailed = true;
    }
  }
  return result;
}

/** 显示用户选择与有效结果的区别；旧系统、能力不足和查询失败各有准确提示。 */
export function dockLightStatus(mode: DockLightMode, capabilities: DockLightCapabilities): string {
  if (mode === DockLightMode.OFF) return '已关闭底部栏光感，使用普通背景。';
  if (!capabilities.floatingSupported) return '当前系统使用兼容样式，仅支持自动和关闭。';
  const effective: DockLightMode = resolveDockLightMode(mode, true, capabilities.immersiveSupported);
  if (effective !== mode) {
    return '已选' + dockLightModeLabel(mode) + '，' + (capabilities.queryFailed ? '暂时无法确认设备能力' : '当前设备不支持此档位')
      + '，使用流畅效果。';
  }
  if (capabilities.queryFailed && mode === DockLightMode.AUTO) return '暂时无法查询设备能力，使用系统自动效果。';
  return '仅调整底部栏，实际效果随设备能力与系统设置变化。';
}
