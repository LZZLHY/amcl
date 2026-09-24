import { deviceInfo } from '@kit.BasicServicesKit';
import { HdsTabsAttribute, hdsMaterial } from '@kit.UIDesignKit';

export class LauncherTabsStyle implements AttributeModifier<HdsTabsAttribute> {
  private bottomSafeHeight: number;

  constructor(bottomSafeHeight: number) {
    this.bottomSafeHeight = bottomSafeHeight;
  }

  applyNormalAttribute(instance: HdsTabsAttribute): void {
    if (deviceInfo.sdkApiVersion >= 23) {
      instance.barFloatingStyle({
        barBottomMargin: Math.max(this.bottomSafeHeight, 16) + 8,
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
        },
      });
      instance.cachedMaxCount(2, TabsCacheMode.CACHE_BOTH_SIDE);
    } else {
      // 旧 API 仍覆盖在全屏内容上，不退回挤占 TabContent 高度的布局。
      instance.barOverlap(true);
      instance.barBackgroundBlurStyle(BlurStyle.COMPONENT_THICK);
    }
  }
}
