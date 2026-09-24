/**
 * RemoteImage.ets — 远程图片 + 失败回退到 AppIcon 的复合组件
 *
 * v2 (2026-05-18) — 自己拉、自己解码：
 *   原版用 `Image(url)` 直接喂 HTTPS URL 给 ArkUI。在本机上稳定复现：URL 没问题
 *   （curl / 浏览器都能拉到），但 ArkUI 的 Image 控件**根本没发出网络请求**
 *   （hdc shell hilog | grep cdn.modrinth 只能看到我自己 fetchIconsAsync 里的日志，
 *   没有任何 system Image 的网络流水）。
 *
 *   排查路径见 InstalledResourcesSheet.ets 注释 / 真机调试历史。这是 OpenHarmony 5
 *   API 14 的已知 quirk —— `Image(string)` 对 https URL 在某些情况下静默不发请求，
 *   也不触发 onError。
 *
 *   workaround：自己用 @kit.NetworkKit 的 http.request 拿 ArrayBuffer，
 *   再用 @kit.ImageKit 的 image.createImageSource(...).createPixelMap(...)
 *   解码成 PixelMap，然后把 PixelMap 喂给 Image。这条链路在本项目上是可靠的。
 *
 *   缓存：每个 url 只下载一次，进程内存，下次同 url 直接从 cache 取 PixelMap。
 *
 * 用途：
 *   - mod / 资源包 / 光影的图标（来自 Modrinth icon_url / CurseForge logo.url）
 *   - 任何"网络拿到的可能失败"的图标位
 *
 * 行为：
 *   - url 为空 / null / 加载失败 → 显示 fallbackIcon（AppIcon）
 *   - url 有效 → 异步 http.request → image.createImageSource → createPixelMap → 显示
 *   - 整体在固定尺寸的 Stack 里，外面包圆角背景；视觉上等价于"占位框 + 图标"
 *
 * ArkUI 注意事项：
 *   - 不能给 Image 设置 .borderRadius —— 圆角必须在外层 Stack/Column；ArkTS 旧版本里
 *     Image 自带 borderRadius 会和 objectFit 联动失败导致裁剪溢出。
 *   - Image(pixelMap) 形式渲染本地解码的 PixelMap，**保证发出请求 / 真渲染**，
 *     不像 Image(url) 那样静默丢弃。
 */

import { image } from '@kit.ImageKit';
import { AppIcon } from './AppIcon';
import { AppIconName } from 'commons';
import { getRemotePixelMap } from 'commons';

// 注：HTTPS → PixelMap 的 fetch+decode 缓存已经抽到 common/RemoteImageCache.ets，
// 这里仅保留组件本身的视觉逻辑。SkinCanvas3D 也走同一个缓存（皮肤 PNG）。

// ============================================================
//  Component
// ============================================================

@Component
export struct RemoteImage {
  /** 远程图片 URL；为空 / null 视为加载失败 */
  @Prop @Watch('onUrlChange') url: string = '';
  /** 容器尺寸（vp）。组件内部同时控制 Image 和 fallback 的位置 */
  @Prop diameter: number = 44;
  /** 圆角（vp）；默认是 diameter * 0.27（≈ 12/44）保持视觉协调 */
  @Prop cornerRadius: number = -1;
  /** 失败 / 空 url 时显示的 AppIcon 名 */
  @Prop fallbackIcon: AppIconName = AppIconName.Mod;
  /** fallback 图标颜色 */
  @Prop fallbackColor: ResourceColor = '#5C6470';
  /** fallback 占位背景色 */
  @Prop fallbackBg: ResourceColor = '#F0F2F5';
  /** fallback 图标字号；默认 diameter * 0.55 */
  @Prop fallbackIconSize: number = -1;

  /**
   * 解码完成的 PixelMap；空 = 还在加载 / 失败 → 走 fallback。
   * 用 image.PixelMap 作为类型，让 Image 控件直接拿 PixelMap 渲染（这条路径稳定）。
   */
  @State private pixelMap: image.PixelMap | null = null;

  aboutToAppear() {
    this.kickOffLoad();
  }

  private onUrlChange(): void {
    // url 变了（外层 row.iconUrl 异步填充后，@Prop 同步过来）→ 重拉
    this.pixelMap = null;
    this.kickOffLoad();
  }

  private kickOffLoad(): void {
    let url = this.url;
    if (url === null || url === undefined || url.length === 0) return;
    getRemotePixelMap(url).then((pm: image.PixelMap | null) => {
      // 异步回来时 url 可能已经被 onUrlChange 改成新值；只有当当前 url 与发起时的
      // url 一致才 commit 这次结果，否则丢弃（避免快速切换时显示错图）
      if (this.url === url && pm !== null) {
        this.pixelMap = pm;
      }
    });
  }

  build() {
    Stack() {
      // 占位背景 / fallback 卡：始终在最底层，url 加载失败时也兜住
      Column()
        .width(this.diameter)
        .height(this.diameter)
        .borderRadius(this.resolvedCornerRadius())
        .backgroundColor(this.fallbackBg)

      if (this.pixelMap !== null) {
        // PixelMap 渲染路径 —— 解码完成后走这里
        Image(this.pixelMap)
          .width(this.diameter)
          .height(this.diameter)
          .borderRadius(this.resolvedCornerRadius())
          .objectFit(ImageFit.Cover)
          .interpolation(ImageInterpolation.Medium)
      } else {
        // fallback 图标：url 为空 / 加载中 / 加载失败统一展示
        AppIcon({
          name: this.fallbackIcon,
          iconSize: this.resolvedFallbackIconSize(),
          color: this.fallbackColor,
        })
      }
    }
    .width(this.diameter)
    .height(this.diameter)
    .clip(true)
  }

  private resolvedCornerRadius(): number {
    return this.cornerRadius >= 0 ? this.cornerRadius : Math.round(this.diameter * 0.27);
  }

  private resolvedFallbackIconSize(): number {
    return this.fallbackIconSize >= 0 ? this.fallbackIconSize : Math.round(this.diameter * 0.55);
  }
}
