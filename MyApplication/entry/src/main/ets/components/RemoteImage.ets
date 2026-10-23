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
 *   缓存：按 URL + 目标像素长边复用有界缩略图，并通过租约保护共享 PixelMap。
 *   离页/换图取消本消费者；停止显示后的下一帧空闲阶段归还租约，防止旧帧仍引用
 *   位图时被缓存显式释放。皮肤/披风的原图读取保留在 commons 的兼容入口。
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
import { FrameCallback } from '@kit.ArkUI';
import { AppIcon } from './AppIcon';
import { AppIconName } from 'commons';
import { acquireRemotePixelMap, RemoteImageLoadToken, RemotePixelMapLease, RemoteImageRetirementGuard } from 'commons';

/**
 * 在旧 Image 子树已经完成下一帧更新后归还租约。回调只持有租约，不捕获组件；
 * 空闲帧不一定到来，因此守卫最多等待 1000ms；超时只取消 pin、退化为 GC 回收。
 */
class RemoteImageLeaseRetirement extends FrameCallback {
  private guard_: RemoteImageRetirementGuard;

  /** lease 已从组件的当前显示槽中移出，但须等渲染层停止使用旧帧。 */
  constructor(lease: RemotePixelMapLease) { super(); this.guard_ = new RemoteImageRetirementGuard(lease); }

  /** SDK 在帧渲染完成且有空闲时调用；租约自身保证重复归还无副作用。 */
  onIdle(_timeLeftInNano: number): void { this.guard_.onIdle(); }

  /** 帧回调注册失败时立即结束守卫，清 timer 后仅交 GC 回收。 */
  releaseToGc(): void { this.guard_.releaseToGc(); }
}

// 注：HTTPS → PixelMap 的 fetch+decode 缓存已经抽到 common/RemoteImageCache.ets，
// 这里仅保留组件本身的视觉逻辑。SkinCanvas3D 也走同一个缓存（皮肤 PNG）。

// ============================================================
//  Component
// ============================================================

@Component
export struct RemoteImage {
  /** 远程图片 URL；为空 / null 视为加载失败 */
  @Prop @Watch('onInputsChange') url: string = '';
  /** 容器尺寸（vp）。组件内部同时控制 Image 和 fallback 的位置 */
  @Prop @Watch('onInputsChange') diameter: number = 44;
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
  /** 仅普通字段参与任务身份管理，不从缓存回调修改已消失组件的 @State。 */
  private active_: boolean = false;
  private generation_: number = 0;
  private loadToken_: RemoteImageLoadToken | null = null;
  private lease_: RemotePixelMapLease | null = null;

  /** 保持现有 V1 组件；首次挂载/重新挂载时按当前 UIContext 密度选择缩略规格。 */
  aboutToAppear(): void {
    this.active_ = true;
    this.kickOffLoad();
  }

  /** 消失时只撤销任务身份与普通字段，不在 aboutToDisappear 中修改状态变量。 */
  aboutToDisappear(): void {
    this.active_ = false;
    this.cancelLoad_();
    this.retireLease_();
  }

  /** URL 或显示尺寸变化时重取；未挂载期间只清掉旧状态，不发起网络工作。 */
  private onInputsChange(): void {
    this.kickOffLoad();
  }

  /** 取消本组件的消费者标记；共享同 URL 的其他组件仍可继续完成。 */
  private cancelLoad_(): void {
    this.generation_++;
    this.loadToken_?.cancel();
    this.loadToken_ = null;
  }

  /**
   * 从当前显示槽移走旧租约，并等待帧完成。UIContext 失效时降级到仅 GC 回收，
   * 避免为释放一个离页组件而销毁其他组件仍引用的共享 PixelMap。
   */
  private retireLease_(): void {
    const previous: RemotePixelMapLease | null = this.lease_;
    this.lease_ = null;
    if (previous === null) return;
    let retirement: RemoteImageLeaseRetirement | null = null;
    try {
      retirement = new RemoteImageLeaseRetirement(previous);
      this.getUIContext().postFrameCallback(retirement);
    } catch (e) {
      if (retirement !== null) retirement.releaseToGc();
      else previous.releaseToGc();
    }
  }

  /**
   * 以物理像素请求保持比例的缩略图；缓存再次钳制输出上限。每次请求绑定独立
   * generation/token，过期结果在写入 @State 之前归还，从未显示的结果可立即释放租约。
   */
  private kickOffLoad(): void {
    this.cancelLoad_();
    this.retireLease_();
    this.pixelMap = null;
    const url: string = this.url;
    if (!this.active_ || url === null || url === undefined || url.length === 0) return;
    const token: RemoteImageLoadToken = new RemoteImageLoadToken();
    this.loadToken_ = token;
    const generation: number = this.generation_;
    let targetPixels: number = 128;
    try { targetPixels = this.getUIContext().vp2px(this.diameter); }
    catch (e) { /* 极早上下文不可用时使用有界默认缩略图。 */ }
    acquireRemotePixelMap(url, targetPixels, token).then((lease: RemotePixelMapLease | null): void => {
      if (lease === null) return;
      if (!this.active_ || token.isCancelled() || generation !== this.generation_) {
        lease.release();
        return;
      }
      this.lease_ = lease;
      this.pixelMap = lease.pixelMap;
    }).catch((): void => {
      // 缓存已隔离通常的 I/O 失败；兜底吸收异常，图标位继续显示 fallback。
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
