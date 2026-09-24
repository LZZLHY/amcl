/**
 * LayoutThumbnail.ets — 布局方案缩略图（Phase D 键鼠适配）
 *
 * 用途：LayoutListPage 列表卡片里的方案预览，让用户一眼看出"按钮大概布在哪儿"。
 *
 * 渲染模型（与游戏内 GameControls 同构）：
 *     - itemX = xPct * previewW、itemY = yPct * previewH（position() 左上角锚点）；
 *     - itemW = baseWidth * itemScale * globalScale * (previewW / refW)（对齐运行时绝对 vp）。
 *   参考屏幕（refW×refH，决定预览比例 + 按钮相对大小）**按方案的 targetDevice 选**：
 *     - 手机方案 → 手机横屏比例（≈19.5:9）；平板方案 → 平板横屏比例（≈16:10）；
 *     - any/未知 → 按当前设备类型。
 *   当"目标类型 == 当前设备类型"时，用当前设备**真实横屏 vp 尺寸**，与编辑器逐像素一致；
 *   否则用该类型的代表尺寸。由此实现用户诉求：
 *     · 平板上导入的手机布局 → 预览仍显示手机比例；
 *     · 该布局一经编辑（LayoutEditor 保存时把 targetDevice 归位当前设备）→ 变平板 → 预览转平板。
 *   手机侧同理。不挂 onTouch / 不发事件 / 不响应交互（纯展示）。
 *
 *   - 不挂 onTouch / 不发事件 / 不响应交互（纯展示）。
 *
 * @Prop:
 *   - profile:   LayoutProfile（要画的方案）
 *   - viewWidth: 缩略图容器宽（vp），高 = viewWidth * refH / refW
 */

import { ControlItem, ControlType, LayoutProfile, effectiveCornerRadius } from 'gamecontrol'
import { computeAutoGuiScale, computeHotbarRectPx, HotbarRectPx } from 'gamecontrol'
import { display } from '@kit.ArkUI'

// 各设备类型的代表横屏视口 vp 尺寸（当预览的目标类型 ≠ 当前设备类型时用）：
//   手机 19.5:9 ≈ 2.167；平板 16:10 = 1.6。
const PHONE_REF_W: number = 780
const PHONE_REF_H: number = 360
const TABLET_REF_W: number = 1200
const TABLET_REF_H: number = 750
// 代表物理分辨率（px，横屏），用于按 MC guiScale 模型现算物品栏矩形（其宽度=180·gs，随分辨率跳变）。
const PHONE_REF_PX_W: number = 2340
const PHONE_REF_PX_H: number = 1080
const TABLET_REF_PX_W: number = 2560
const TABLET_REF_PX_H: number = 1600

// 当前设备横屏游戏视口 vp 尺寸 + 物理 px + 类型（进程内算一次缓存）：长边=宽、短边=高。
let s_deviceRefW: number = 0
let s_deviceRefH: number = 0
let s_devicePxW: number = 0
let s_devicePxH: number = 0
let s_deviceType: string = ''   // 'phone' | 'tablet'
let s_deviceProbed: boolean = false

function ensureDeviceRef(): void {
  if (s_deviceProbed) return
  s_deviceProbed = true
  try {
    const d = display.getDefaultDisplaySync()
    const dens: number = (d.densityPixels && d.densityPixels > 0) ? d.densityPixels : 2.0
    const wVp: number = d.width / dens
    const hVp: number = d.height / dens
    s_deviceRefW = Math.max(wVp, hVp)   // 横屏长边
    s_deviceRefH = Math.min(wVp, hVp)   // 横屏短边
    s_devicePxW = Math.max(d.width, d.height)
    s_devicePxH = Math.min(d.width, d.height)
    // 与 LayoutStore.getCurrentDeviceType 同判据：短边 dp ≥ 600 → 平板。
    s_deviceType = Math.min(wVp, hVp) >= 600 ? 'tablet' : 'phone'
  } catch (e) {
    s_deviceRefW = 0
    s_deviceRefH = 0
    s_devicePxW = 0
    s_devicePxH = 0
    s_deviceType = ''
  }
}

@Component
export struct LayoutThumbnail {
  @Prop profile: LayoutProfile
  @Prop viewWidth: number = 240

  aboutToAppear(): void {
    ensureDeviceRef()
  }

  /** 该方案要渲染成的设备类型：tablet/foldable→tablet、phone→phone、any/未知→当前设备类型。 */
  private effectiveType(): string {
    const t = this.profile.targetDevice
    if (t === 'tablet' || t === 'foldable') return 'tablet'
    if (t === 'phone') return 'phone'
    return s_deviceType === 'tablet' ? 'tablet' : 'phone'
  }

  /** 参考屏宽/高（vp）：目标类型 == 当前设备类型 → 用当前设备真实横屏尺寸（与编辑器逐像素一致）；
   *  否则用该目标类型的代表尺寸（如平板上预览手机方案 → 手机 19.5:9）。 */
  private refW(): number {
    const et = this.effectiveType()
    if (s_deviceRefW > 0 && et === s_deviceType) return s_deviceRefW
    return et === 'tablet' ? TABLET_REF_W : PHONE_REF_W
  }

  private refH(): number {
    const et = this.effectiveType()
    if (s_deviceRefH > 0 && et === s_deviceType) return s_deviceRefH
    return et === 'tablet' ? TABLET_REF_H : PHONE_REF_H
  }

  /** 预览高 = 预览宽 × (refH/refW)，即设备横屏真实比例。 */
  private thumbHeight(): number {
    return this.viewWidth * this.refH() / this.refW()
  }

  /** 缩放因子：预览宽 / 参考屏宽（把 vp 尺寸等比缩到预览框）。 */
  private vpScale(): number {
    return this.viewWidth / this.refW()
  }

  // 位置：左上角锚点，xPct/yPct 相对预览框宽高（与运行时 itemX/itemY 同构）。
  private itemX(c: ControlItem): number {
    return c.xPct * this.viewWidth
  }

  private itemY(c: ControlItem): number {
    return c.yPct * this.thumbHeight()
  }

  private itemW(c: ControlItem): number {
    const s = this.vpScale()
    const g = this.profile.globalScale ?? 1.0
    return c.baseWidth * c.itemScale * g * s
  }

  private itemH(c: ControlItem): number {
    const s = this.vpScale()
    const g = this.profile.globalScale ?? 1.0
    return c.baseHeight * c.itemScale * g * s
  }

  /** 目标类型对应的物理分辨率（px，横屏），用于现算物品栏矩形。 */
  private refPxW(): number {
    const et = this.effectiveType()
    if (s_devicePxW > 0 && et === s_deviceType) return s_devicePxW
    return et === 'tablet' ? TABLET_REF_PX_W : PHONE_REF_PX_W
  }

  private refPxH(): number {
    const et = this.effectiveType()
    if (s_devicePxH > 0 && et === s_deviceType) return s_devicePxH
    return et === 'tablet' ? TABLET_REF_PX_H : PHONE_REF_PX_H
  }

  /**
   * 物品栏直点条（HOTBAR_SELECTOR）专用矩形：其真实宽度 = 180·guiScale px，guiScale 随分辨率
   * 离散跳变（平板 gs 大→占屏比高、手机 gs 小→占屏比低）。存储的 baseWidth/xPct 是按【当前设备】
   * 对齐的，跨设备类型预览会失真（手机方案在平板上物品栏过长）。故按目标类型的分辨率用与运行时
   * 同一个 MC 模型 computeHotbarRectPx 现算矩形，再换算成预览框内像素。用户手动摆放过（hotbarUserPlaced）
   * 则尊重其存储值（走普通 item* 路径）。
   */
  private hotbarRect(): number[] {
    const pxW = this.refPxW()
    const pxH = this.refPxH()
    const gs = computeAutoGuiScale(pxW, pxH)
    const r: HotbarRectPx = computeHotbarRectPx(pxW, pxH, gs)
    const previewW = this.viewWidth
    const previewH = this.thumbHeight()
    // [x, y, w, h]
    return [
      (r.leftPx / pxW) * previewW,
      (r.topPx / pxH) * previewH,
      (r.widthPx / pxW) * previewW,
      (r.heightPx / pxH) * previewH,
    ]
  }

  private btnColor(c: ControlItem): string {
    // 颜色按类型区分，给用户视觉提示：
    //   摇杆        -> 蓝灰圆环
    //   鼠标按键    -> 橙色（atk/place）
    //   滚轮        -> 紫色
    //   键盘按钮    -> 灰色
    //   抽屉        -> 绿色
    if (c.type === ControlType.JOYSTICK) return '#5566AAFF'
    if (c.type === ControlType.SCROLL_WHEEL) return '#55AA66FF'
    if (c.type === ControlType.DRAWER) return '#5566BB6A'
    if (c.keyOrMouse < 0) return '#55FF9966'
    return '#55BBBBBB'
  }

  build() {
    Stack() {
      // 背景（模拟游戏画面：上天空 + 下地面）
      Column()
        .width(this.viewWidth)
        .height(this.thumbHeight())
        .backgroundColor('#1E2A38')
        .borderRadius(6)
      Column()
        .width(this.viewWidth)
        .height(this.thumbHeight() * 0.55)
        .backgroundColor('#3E5A78')
        .borderRadius({ topLeft: 6, topRight: 6 })
        .position({ x: 0, y: 0 })

      // 按钮（不渲染 hidden / force_hide 的）
      ForEach(this.profile.controls, (c: ControlItem) => {
        if (!c.hidden && c.visibilityOverride !== 'force_hide') {
          // 物品栏直点条：未手动摆放时按目标设备分辨率现算矩形（宽度随 guiScale 跳变），
          // 避免跨设备类型预览失真；手动摆放过则用存储值。
          if (c.type === ControlType.HOTBAR_SELECTOR && c.hotbarUserPlaced !== true) {
            Stack()
              .width(this.hotbarRect()[2])
              .height(this.hotbarRect()[3])
              .backgroundColor(this.btnColor(c))
              .borderRadius(effectiveCornerRadius(c) * Math.min(this.hotbarRect()[2], this.hotbarRect()[3]) / 2)
              .position({ x: this.hotbarRect()[0], y: this.hotbarRect()[1] })
          } else {
            Stack()
              .width(this.itemW(c))
              .height(this.itemH(c))
              .backgroundColor(this.btnColor(c))
              .borderRadius(effectiveCornerRadius(c) * Math.min(this.itemW(c), this.itemH(c)) / 2)
              .position({ x: this.itemX(c), y: this.itemY(c) })
          }
        }
      }, (c: ControlItem) => c.id)
    }
    .width(this.viewWidth)
    .height(this.thumbHeight())
    .clip(true)
  }
}
