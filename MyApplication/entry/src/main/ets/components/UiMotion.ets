/**
 * AMCL 轻量动效参数：参考 GSAP 的错峰/中断原则，以 ArkUI 原生合成属性实现。
 * 只读系统动画偏好，不更改系统设置、不申请额外权限，也不引入 Web/GSAP 运行时。
 */
import { common } from '@kit.AbilityKit';
import { settings } from '@kit.BasicServicesKit';

export class UiMotion {
  static readonly ENTER_MS: number = 340;
  static readonly FADE_MS: number = 180;
  static readonly ENTER_Y: number = 12;

  /** 最多六个错峰档位，长列表不会积累几秒的等待或同时创建大量动画。 */
  static stagger(order: number): number {
    return Math.max(0, Math.min(5, Math.floor(order))) * 40;
  }

  /** 系统关闭动画时立即呈现最终状态；旧设置键不可读时安全回退到轻量动画。 */
  static reduced(): boolean {
    const context = AppStorage.get<common.UIAbilityContext>('uiAbilityContext');
    if (context === undefined) return false;
    try {
      const transition: string = settings.getValueSync(context, settings.display.TRANSITION_ANIMATION_SCALE, '1');
      const animator: string = settings.getValueSync(context, settings.display.ANIMATOR_DURATION_SCALE, '1');
      // 未提供键的旧系统可能返回空串，不能把 Number('') 的 0 误当成用户关闭动画。
      return (transition.trim().length > 0 && Number(transition) === 0)
        || (animator.trim().length > 0 && Number(animator) === 0);
    } catch (e) { return false; }
  }
}
