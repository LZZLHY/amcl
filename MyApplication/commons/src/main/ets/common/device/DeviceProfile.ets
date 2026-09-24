/** Device form and window breakpoints only. Product/channel policy lives outside this module. */

import deviceInfo from '@ohos.deviceInfo';
import display from '@ohos.display';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'DeviceProfile';

/** 设备形态（出厂形态，用于选输入范式 / product 分支）。 */
export enum DeviceForm {
  /** 手机：触摸为主，竖屏窄屏。侧载轨主力。 */
  PHONE = 'phone',
  /** 平板：触摸 + 可选键鼠，宽屏。上架轨。 */
  TABLET = 'tablet',
  /** PC / 2in1：窗口化；通用包可选择桌面或触屏交互。 */
  PC = 'pc',
}

/** 响应式断点（HarmonyOS 官方栅格断点；随窗口宽度变化）。 */
export enum Breakpoint {
  /** 小屏 [0,600)dp：手机竖屏 / 窄窗口 → 单列。 */
  SM = 'sm',
  /** 中屏 [600,840)dp：平板竖屏 / 折叠展开 / 中等窗口 → 双列。 */
  MD = 'md',
  /** 大屏 [840,∞)dp：平板横屏 / PC 宽窗口 → 多列 / 侧栏。 */
  LG = 'lg',
}

/** 断点阈值（vp/dp）。对齐官方栅格 sm/md/lg 分界。 */
const BP_MD_MIN = 600;
const BP_LG_MIN = 840;

/** 设备短边判定手机/平板的分界（对齐 LayoutStore 既有约定）。 */
const SHORT_SIDE_TABLET_MIN = 600;

/**
 * 设备形态 / 响应式断点统一查询。
 *
 * 用法：
 *   - 选输入范式 / product 分支：`DeviceProfile.form()`（出厂形态，缓存）。
 *   - 响应式布局：在 UI 里监听窗口宽度（mediaquery / onAreaChange），
 *     调 `DeviceProfile.breakpointOf(widthVp)` 得当前断点。
 */
export class DeviceProfile {
  /** 形态缓存（出厂形态不变，首次判定后缓存）。 */
  private static cachedForm: DeviceForm | null = null;

  /**
   * 当前设备出厂形态。
   * 判定顺序：① deviceInfo.deviceType 明确是 2in1 → PC；② 否则按屏幕短边 dp 分手机/平板。
   * 任意 API 异常 → 兜底 PHONE（最保守，触摸 UI 在所有设备都可用）。
   */
  static form(): DeviceForm {
    if (DeviceProfile.cachedForm !== null) return DeviceProfile.cachedForm;
    let result: DeviceForm = DeviceForm.PHONE;
    try {
      // deviceInfo.deviceType: "phone" | "tablet" | "2in1" | "default" | "tv" | ...
      const dt = deviceInfo.deviceType;
      if (dt === '2in1') {
        result = DeviceForm.PC;
      } else {
        // tablet / phone / default 等：用屏幕短边 dp 兜底判定（对齐 LayoutStore）。
        let shortDp = SHORT_SIDE_TABLET_MIN; // 取不到时按平板算（偏宽屏更安全，不至于把平板当手机）
        try {
          const d = display.getDefaultDisplaySync();
          const widthDp = d.width / d.densityPixels;
          const heightDp = d.height / d.densityPixels;
          shortDp = Math.min(widthDp, heightDp);
        } catch (e) {
          hilog.warn(0x0000, TAG, 'display query failed, assume tablet short side: %{public}s', (e as Error).message);
        }
        if (dt === 'tablet') {
          result = DeviceForm.TABLET;
        } else if (dt === 'phone') {
          result = DeviceForm.PHONE;
        } else {
          // "default" / 未知：按短边 dp 分。
          result = shortDp >= SHORT_SIDE_TABLET_MIN ? DeviceForm.TABLET : DeviceForm.PHONE;
        }
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, 'deviceType query failed, fallback PHONE: %{public}s', (e as Error).message);
      result = DeviceForm.PHONE;
    }
    DeviceProfile.cachedForm = result;
    hilog.info(0x0000, TAG, 'device form resolved: %{public}s', result);
    return result;
  }

  /** 是否手机形态（触摸 UI 主力 / 侧载轨）。 */
  static isPhone(): boolean { return DeviceProfile.form() === DeviceForm.PHONE; }

  /** 是否平板形态。 */
  static isTablet(): boolean { return DeviceProfile.form() === DeviceForm.TABLET; }

  /** 是否 PC/2in1 形态。 */
  static isPC(): boolean { return DeviceProfile.form() === DeviceForm.PC; }

  /**
   * 是否"宽屏形态"（平板 + PC）。本次重构平板与 PC 共用宽屏布局分支，
   * 故提供此合并查询；待第 5 步 PC 精细化时再细分 PC 专属键鼠 UI。
   */
  static isWide(): boolean {
    const f = DeviceProfile.form();
    return f === DeviceForm.TABLET || f === DeviceForm.PC;
  }


  /**
   * 是否桌面键鼠环境（PC/2in1）。供 UI 决定是否启用右键 / hover / 滚轮 / 窗口化交互。
   * 注：平板也可外接键鼠，但默认仍按触摸设计；真正的键鼠优先 UI 仅 PC 形态开启。
   */
  static isDesktopInput(): boolean { return DeviceProfile.form() === DeviceForm.PC; }

  /**
   * 把窗口宽度（vp/dp）映射到响应式断点。
   * @param widthVp 当前窗口宽度（vp）。调用方从 mediaquery / onAreaChange / px2vp 得到。
   */
  static breakpointOf(widthVp: number): Breakpoint {
    if (widthVp >= BP_LG_MIN) return Breakpoint.LG;
    if (widthVp >= BP_MD_MIN) return Breakpoint.MD;
    return Breakpoint.SM;
  }

  /**
   * 当前窗口断点（同步读默认 display 宽度）。
   * 适合一次性取值；需要随窗口变化实时更新的场景请在 UI 监听宽度后调 breakpointOf。
   */
  static currentBreakpoint(): Breakpoint {
    try {
      const d = display.getDefaultDisplaySync();
      const widthDp = d.width / d.densityPixels;
      return DeviceProfile.breakpointOf(widthDp);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'currentBreakpoint display query failed, fallback SM: %{public}s', (e as Error).message);
      return Breakpoint.SM;
    }
  }

  /** 测试 / 异常恢复用：清形态缓存（下次 form() 重新判定）。 */
  static resetCache(): void { DeviceProfile.cachedForm = null; }
}
