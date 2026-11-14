/**
 * 工具滚动条展示适配器：API22+才设置颜色，API20/21保留系统滚动条。
 * 不替代滚动行为，不读取偏好；颜色只随宿主palette更新，不增加游戏帧或输入订阅。
 */
import { deviceInfo } from '@kit.BasicServicesKit';

export class ThemeScrollStyle implements AttributeModifier<ScrollAttribute> {
  private color: ResourceColor;

  /** 接受宿主已解析的颜色，不推导新主题或改变滚动状态。 */
  constructor(color: ResourceColor) { this.color = color; }

  /** 兼容条件内才调用API22方法；不改变尺寸、命中区域与现有Scoller。 */
  applyNormalAttribute(instance: ScrollAttribute): void {
    if (deviceInfo.sdkApiVersion >= 22) instance.scrollBarColor(this.color);
  }
}
