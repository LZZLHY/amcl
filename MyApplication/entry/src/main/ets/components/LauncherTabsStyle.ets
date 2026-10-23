import { deviceInfo } from '@kit.BasicServicesKit';
import { HdsTabsAttribute, hdsMaterial } from '@kit.UIDesignKit';
import { DockLightMode } from 'commons';

/** 只维护底部栏样式；调用方传入有效档位，不在 UI 刷新阶段读存储或探测设备。 */
export class LauncherTabsStyle implements AttributeModifier<HdsTabsAttribute> {
  private bottomSafeHeight: number;
  private mode: DockLightMode;
  private plainBackground: ResourceColor;

  /** 普通背景随应用主题变化；关闭再开启时必须显式清除它，避免盖住系统材质。 */
  constructor(bottomSafeHeight: number, mode: DockLightMode, plainBackground: ResourceColor) {
    this.bottomSafeHeight = bottomSafeHeight;
    this.mode = mode;
    this.plainBackground = plainBackground;
  }

  /**
   * 每次状态变化完整写回颜色、模糊和材质，不依赖上一轮分支遗留值。
   * API23+ 的模糊由系统材质负责；旧系统自动档沿用原 COMPONENT_THICK 回退。
   * 渐变、安全区和悬浮位置保持原有语义，关闭材质不等于删除所有导航渐变。
   */
  applyNormalAttribute(instance: HdsTabsAttribute): void {
    const off: boolean = this.mode === DockLightMode.OFF;
    instance.barBackgroundColor(off ? this.plainBackground : Color.Transparent);
    if (deviceInfo.apiAvailable('6.1.0')) {
      let level: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.ADAPTIVE;
      if (this.mode === DockLightMode.EXQUISITE) level = hdsMaterial.MaterialLevel.EXQUISITE;
      else if (this.mode === DockLightMode.GENTLE) level = hdsMaterial.MaterialLevel.GENTLE;
      else if (this.mode === DockLightMode.SMOOTH) level = hdsMaterial.MaterialLevel.SMOOTH;
      instance.barBackgroundBlurStyle(BlurStyle.NONE);
      instance.barFloatingStyle({
        barBottomMargin: Math.max(this.bottomSafeHeight, 16) + 8,
        systemMaterialEffect: {
          materialType: off ? hdsMaterial.MaterialType.NONE : hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: level,
        },
      });
      instance.cachedMaxCount(2, TabsCacheMode.CACHE_BOTH_SIDE);
    } else {
      // 旧系统不调用 HDS 新接口；关闭档连同兼容模糊一起关闭，但不改变布局占位。
      instance.barOverlap(true);
      instance.barBackgroundBlurStyle(off ? BlurStyle.NONE : BlurStyle.COMPONENT_THICK);
    }
  }
}
