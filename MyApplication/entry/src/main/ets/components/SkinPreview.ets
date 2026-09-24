/**
 * SkinPreview.ets — 皮肤渲染组件（账户管理 / 皮肤详情用）
 *
 * 三种粒度：
 *   - 头像（48-64vp）：Crafatar `/avatars/{uuid}` —— 8x8 head crop（已在 AccountListSheet 用）
 *   - 全身（96-180vp）：Crafatar `/renders/body/{uuid}?scale=N&overlay=true`
 *     渲染 32x64 的 isometric body PNG，scale=4 → 128x256
 *   - 全身大图（详情 sheet，140-220vp）：scale=8 → 256x512，更清晰
 *
 * 失败 fallback：底部一个圆角矩形 + 用户名首字母（与 AccountListSheet 头像逻辑一致）
 *   失败原因可能是：
 *     - OfflineAccount 的 UUID 是本地派生（非 Mojang），Crafatar 返回默认 Steve
 *       → 这里我们用一个 isOffline 旗标完全跳过 Image，直接显示首字母色块
 *     - 网络问题 / Crafatar API 偶发 5xx / UUID 无 profile（小概率）
 *       → onError 翻 _failed=true，下次渲染走 fallback
 *
 * 不缓存失败状态：本组件实例的生命周期很短（sheet 关闭就销毁），加缓存反而复杂。
 * 头像位（44×44 圆形）已迁到独立的 MinecraftHeadAvatar 组件，那条路径走 PixelMap
 * 解码（避开 OpenHarmony Image(httpsUrl) 静默不发请求 quirk）。
 *
 * 创建日期：2026-05-23（账户管理重设计）
 */

import { ThemeColors } from 'commons';

/** Crafatar 全身渲染 URL。size 参考：scale=4 → 128x256，scale=6 → 192x384 */
function bodyRenderUrl(uuid: string, scale: number): string {
  return 'https://crafatar.com/renders/body/' + uuid + '?scale=' + scale + '&overlay=true';
}

/**
 * 全身皮肤预览。
 *
 * 用法：
 *   SkinPreview({
 *     uuid: account.uuid,
 *     username: account.username,
 *     isOffline: account.type === AccountType.OFFLINE,
 *     theme: this.theme,
 *     containerWidth: 96,
 *     containerHeight: 160,
 *     bodyScale: 5,   // optional, 默认按 containerWidth 自适应
 *   })
 *
 * ⚠️ 命名陷阱：
 *   prop 用 `bodyScale` 而不是 `scale` —— ArkUI CustomComponent 基类已经有内置
 *   属性 `scale`（接受 ScaleOptions 用于 transform），子组件**不能重新声明** `scale` 当
 *   prop 名，否则 ArkTS 报 10505001："is not assignable to the same property in base type"。
 *   同样的 trap 见 AppIcon.ets 里对 `iconSize`（不是 `size`）的注释。
 */
@Component
export struct SkinPreview {
  @Prop uuid: string = '';
  @Prop username: string = '';
  @Prop isOffline: boolean = false;
  @Prop theme: ThemeColors = {} as ThemeColors;

  /** 外层容器宽（vp） */
  @Prop containerWidth: number = 96;
  /** 外层容器高（vp） */
  @Prop containerHeight: number = 160;

  /**
   * Crafatar scale 参数。不传默认按 containerWidth 推导：
   *   - <=64 → 3 (96x192)
   *   - <=120 → 5 (160x320)
   *   - <=200 → 7 (224x448)
   *   - 其它 → 8 (256x512)
   *
   * scale 越大，PNG 字节越大，但视觉更清晰。Crafatar 服务端缓存命中后返还很快。
   *
   * 叫 `bodyScale` 而不是 `scale` 是因为后者在 CustomComponent 基类占位（transform。scale）。
   */
  @Prop bodyScale: number = 0;

  /** 渲染失败 fallback 标志（onError 翻这个）。下划线前缀表示组件内部用，不期望外部覆盖。 */
  @State _failed: boolean = false;

  build() {
    Stack() {
      // 底层：渐变背景（避免 PNG 加载中纯色突兀）
      Column()
        .width('100%')
        .height('100%')
        .borderRadius(this.theme.cardRadius - 2)
        .linearGradient({
          angle: 180,
          colors: [['#60A5FA', 0.0], ['#1E40AF', 1.0]],
        })

      // 中层：网络皮肤渲染（Microsoft 账户 + uuid 合法 + 没失败时才挂载）
      if (this.shouldShowImage()) {
        Image(bodyRenderUrl(this.uuid, this.resolveScale()))
          .width('80%')
          .height('92%')
          .objectFit(ImageFit.Contain)
          .interpolation(ImageInterpolation.None) // 像素风：禁插值，保留 Minecraft 原汁
          .onError(() => {
            this._failed = true;
          })
      } else {
        // Offline / 失败 fallback：用户名首字母大块字
        Text(this.fallbackLetter())
          .fontSize(Math.floor(this.containerWidth * 0.55))
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
      }
    }
    .width(this.containerWidth)
    .height(this.containerHeight)
    .borderRadius(this.theme.cardRadius - 2)
    .clip(true)
  }

  private shouldShowImage(): boolean {
    if (this.isOffline) return false;
    if (this._failed) return false;
    // UUID 必须是 36 字符（带连字符）才能给 Crafatar
    if (!this.uuid || this.uuid.length !== 36) return false;
    return true;
  }

  private resolveScale(): number {
    if (this.bodyScale > 0) return this.bodyScale;
    if (this.containerWidth <= 64) return 3;
    if (this.containerWidth <= 120) return 5;
    if (this.containerWidth <= 200) return 7;
    return 8;
  }

  private fallbackLetter(): string {
    if (!this.username || this.username.length === 0) return '?';
    return this.username.charAt(0).toUpperCase();
  }
}
