/**
 * CapePreview.ets — 披风缩略图组件
 *
 * Mojang 披风纹理是 64×32（旧）或 64×64（HD）PNG，整张里只有左上角一小块
 * **(1,1)–(11,17) = 10×16 像素**才是「玩家身后看到的披风外面」。其他区域是
 * 内衬 / 边缘 / 暂未使用的 alpha 黑边。
 *
 * v1（2026-05-23 初版）用 `Image(capeUrl).objectFit(Cover)` 直接贴整张 PNG
 *   → 容器里看到一坨 64×32 的方块，cape 区域只占左上一角，其余是黑色 alpha
 *     边和披风内衬，**视觉完全不是披风**。
 *
 * v2（这次重写）：和 SkinCanvas3D 走一样的路：
 *   1. `getRemotePixelMap(url)` 拉 PNG 并解码到 RGBA PixelMap（Image(httpsUrl)
 *      在 OpenHarmony API 14 上对部分 URL 静默不发请求，所以走 http 自取）。
 *   2. Canvas 里用 9 参 `drawImage(pm, sx, sy, sw, sh, dx, dy, dw, dh)` 把源
 *      矩形 (1,1)-(11,17) 拉伸贴到容器 (0,0)-(w,h) vp。
 *   3. `imageSmoothingEnabled = false` → nearest-neighbor 放大，保留像素风。
 *
 * 注意：用 9 参 drawImage 而不是 2 参（drawImage(pm, 0, 0)）是因为 ArkUI
 *   Canvas 上 2 参版本会把 PM 的「自然尺寸」按 device px 解释贴出来，3.x 密度
 *   屏上整张图缩在左上角（这是 SkinCanvas3D v6 初版踩过的坑，详见那边注释）。
 *   9 参版本明确给 dest = (w, h) vp，结果可控。
 *
 * 创建日期：2026-05-23（账户管理重设计）
 * 更新日期：2026-05-23（v2 → Canvas drawImage 裁切，修「整张 64×32 PNG 直接贴」）
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { image } from '@kit.ImageKit';
import { ThemeColors } from 'commons';
import { getRemotePixelMap } from 'commons';

const TAG = 'CapePreview';

/**
 * 披风纹理里「外面（别人看到的那面）」的源矩形：
 *   x=1, y=1, w=10, h=16
 * 对 64×32 旧版披风和 64×64 HD 披风都成立（HD 版只是右下加了内衬第二层，前
 * 面这个矩形位置不变）。如果哪天 Mojang 改格式，这个常量就要重新核对。
 */
const CAPE_SRC_X = 1;
const CAPE_SRC_Y = 1;
const CAPE_SRC_W = 10;
const CAPE_SRC_H = 16;

@Component
export struct CapePreview {
  @Prop @Watch('onUrlChange') capeUrl: string = '';
  /** 'Migrator' / 'Vanilla' / 'Cherry' / null —— 控制底色渐变 */
  @Prop alias: string = '';
  @Prop theme: ThemeColors = {} as ThemeColors;

  @Prop containerWidth: number = 32;
  @Prop containerHeight: number = 48;

  /** 是否显示 alias 文字 hint。空容器时关掉避免拥挤。 */
  @Prop showLabel: boolean = false;

  /**
   * 网络拉取失败 / 解码失败 → true。drawImage 阶段不会再尝试，UI 显示 dash 占位。
   * url 重新变化时 onUrlChange 会重置。
   */
  @State _failed: boolean = false;

  // ============================================================
  //  Canvas 渲染状态（私有，绕过 @State 重渲染，手动 tryDraw 控制）
  // ============================================================

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  /** Canvas onReady 触发 → 才能对 ctx 调用 drawImage */
  private _canvasReady: boolean = false;
  /**
   * **裁剪后**的 10×16 披风外面 PM（不是原始 64×32 / 64×64 整张披风纹理）。
   *
   * 为什么要裁剪一次：HarmonyOS Canvas 的 9 参 `drawImage(pm, sx,sy,sw,sh, dx,dy,dw,dh)`
   * dest 坐标会被当成 **device px** 解释（vp 大小贴出来缩在左上一小块，残余条带从源
   * 矩形右边渗出来 —— 详见 SkinCanvas3D v6 注释里的同款踩坑）。
   *
   * 解决：自己用 readPixelsToBuffer + createPixelMap 先裁出一张 10×16 的纯披风
   * PM，然后走 SkinCanvas3D 已验证可靠的 **5 参 drawImage(pm, dx, dy, dw, dh)** —
   * 这条路径上 dest 坐标是 vp，nearest-neighbor 放大成正确的容器尺寸。
   *
   * null = 没披风 / fetch 失败 / 还没裁完。
   */
  private _capePM: image.PixelMap | null = null;
  /** Canvas 实际像素尺寸（vp，由 onAreaChange 测出） */
  private _measuredW: number = 0;
  private _measuredH: number = 0;
  /** 短路：同一 url 不重复 fetch（getRemotePixelMap 自身也有 inflight cache，这是双保险） */
  private _lastFetchedUrl: string = '';

  aboutToAppear(): void {
    this.kickOffFetch();
  }

  /** @Watch 回调：capeUrl 变化（账户切换 / refresh）→ 重新拉 + 重绘 */
  onUrlChange(): void {
    this.kickOffFetch();
  }

  // ============================================================
  //  Fetch + 绘制
  // ============================================================

  private kickOffFetch(): void {
    if (this.capeUrl.length === 0) {
      // 没有披风 url（offline 账户 / 微软账户没披风）→ 清掉缓存的 PM，让 dash 占位显示
      this._capePM = null;
      this._failed = false;
      this._lastFetchedUrl = '';
      this.tryDraw();
      return;
    }
    if (this._lastFetchedUrl === this.capeUrl && this._capePM !== null) {
      // 已经拿过同一个 url 的裁剪 PM，直接画就行
      this.tryDraw();
      return;
    }
    this._lastFetchedUrl = this.capeUrl;
    let url = this.capeUrl;
    getRemotePixelMap(url).then(async (pm: image.PixelMap | null) => {
      // url 在 fetch 期间又变了 → 这次结果作废，等新 fetch 回来
      if (this.capeUrl !== url) return;
      if (pm === null) {
        hilog.warn(0x0000, TAG, 'cape fetch/decode failed for %{public}s', url);
        this._failed = true;
        this._capePM = null;
      } else {
        // 把 (1,1)-(11,17) 区域复制成独立的 10×16 PM（避开 9 参 drawImage 的
        // device-px 坑，让后续 5 参 drawImage 能正确按 vp 放大）。
        this._capePM = await this.cropCapePM(pm);
        this._failed = (this._capePM === null);
      }
      this.tryDraw();
    });
  }

  /**
   * 从 64×32 / 64×64 整张披风纹理 PM 里把 (1,1)-(11,17) 这块切出来成 10×16 的独立 PM。
   *
   * 路径：
   *   1. readPixelsToBuffer 把整张纹理读到 RGBA Uint8Array
   *   2. 复制 10×16 矩形到一个新的 10*16*4 字节 buffer
   *   3. createPixelMap(buf, {size: 10×16, RGBA_8888}) 生成新 PM
   *
   * 返回 null = 读 / 解码 / 创建失败。调用方走 dash 占位 fallback。
   */
  private async cropCapePM(srcPm: image.PixelMap): Promise<image.PixelMap | null> {
    try {
      let info: image.ImageInfo = await srcPm.getImageInfo();
      let srcW = info.size.width;
      let srcH = info.size.height;
      // 防御：纹理至少要够 11×17（cape 区域 + 起点 1,1），不然按 64×32 / 64×64 标准就是
      // 坏图（比如某些第三方皮肤站给的非标准 PNG）。直接放弃裁剪。
      if (srcW < CAPE_SRC_X + CAPE_SRC_W || srcH < CAPE_SRC_Y + CAPE_SRC_H) {
        hilog.warn(0x0000, TAG, 'cape PM too small: %{public}dx%{public}d (need %{public}d+x%{public}d+)',
          srcW, srcH, CAPE_SRC_X + CAPE_SRC_W, CAPE_SRC_Y + CAPE_SRC_H);
        return null;
      }
      // 整张读到 buf（RGBA_8888 → 4 字节/像素）
      let srcBuf = new ArrayBuffer(srcW * srcH * 4);
      await srcPm.readPixelsToBuffer(srcBuf);
      let srcBytes = new Uint8Array(srcBuf);
      // 拷贝 (1,1)-(11,17) 矩形到 cropBytes（10*16*4 字节）。一行一行拷比逐像素快。
      let cropBuf = new ArrayBuffer(CAPE_SRC_W * CAPE_SRC_H * 4);
      let cropBytes = new Uint8Array(cropBuf);
      for (let y = 0; y < CAPE_SRC_H; y++) {
        let srcOff = ((CAPE_SRC_Y + y) * srcW + CAPE_SRC_X) * 4;
        let dstOff = y * CAPE_SRC_W * 4;
        // 用 Uint8Array.set + subarray 让 V8 / ArkTS 引擎走 memcpy 内置实现，
        // 比逐字节循环快 5-10x（虽然在 10×16 量级上差异 <1ms，但好习惯）
        cropBytes.set(srcBytes.subarray(srcOff, srcOff + CAPE_SRC_W * 4), dstOff);
      }
      let opts: image.InitializationOptions = {
        size: { width: CAPE_SRC_W, height: CAPE_SRC_H },
        srcPixelFormat: image.PixelMapFormat.RGBA_8888,
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: false,
      };
      return await image.createPixelMap(cropBuf, opts);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'cropCapePM failed: %{public}s', (e as Error).message);
      return null;
    }
  }

  private tryDraw(): void {
    if (!this._canvasReady) return;
    if (this._measuredW <= 0 || this._measuredH <= 0) return;
    let w = this._measuredW;
    let h = this._measuredH;
    let ctx = this.ctx;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.imageSmoothingEnabled = false;
    ctx.clearRect(0, 0, w, h);
    if (this._capePM !== null) {
      // 保持披风原生比例（10:16 = 0.625），不拉伸 —— 匹配 minecraft.net 披风选择
      // 页那种"披风居中 + 周围留 padding"的视觉。这里走 contain-fit：
      //   - 容器比披风更宽 → 顶满高度，左右居中留 padding
      //   - 容器比披风更高 → 顶满宽度，上下居中留 padding
      let srcAspect = CAPE_SRC_W / CAPE_SRC_H;
      let dstAspect = w / h;
      let dw: number;
      let dh: number;
      if (dstAspect > srcAspect) {
        dh = h;
        dw = h * srcAspect;
      } else {
        dw = w;
        dh = w / srcAspect;
      }
      let dx = (w - dw) / 2;
      let dy = (h - dh) / 2;
      try {
        // 5 参 drawImage(pm, dx, dy, dw, dh) —— SkinCanvas3D v6 验证过的可靠路径。
        // 这版 PM 已经是裁剪好的 10×16 纯披风，dest 矩形按 vp 解释，imageSmoothing
        // 关掉走 nearest-neighbor 放大，像素风视觉。
        ctx.drawImage(this._capePM, dx, dy, dw, dh);
      } catch (e) {
        hilog.warn(0x0000, TAG, 'cape blit failed: %{public}s', (e as Error).message);
      }
    }
  }

  build() {
    Column() {
      Stack() {
        // 底色：统一暗灰（matching minecraft.net 披风选择页的 tile 底色）。
        //
        // 旧版根据 alias 区分（Migrator 红、Vanilla 蓝、Cherry 粉…），但 minecraft.net
        // 自己也是统一暗灰底，让披风纹理颜色自身去呈现 brand 感更合理。
        //
        // #1F2937 ≈ Tailwind slate-800，对所有披风颜色（红/绿/蓝/粉/黑）都是稳定背景。
        Column()
          .width('100%')
          .height('100%')
          .borderRadius(4)
          .backgroundColor('#1F2937')

        // Canvas 渲染层 —— 撑满父容器，自己用 onAreaChange 测尺寸。
        // 有披风时贴像素，没披风 / 加载失败时保持透明（露出底层底色）。
        Canvas(this.ctx)
          .width('100%')
          .height('100%')
          .onReady(() => {
            this._canvasReady = true;
            this.tryDraw();
          })
          .onAreaChange((_old: Area, neu: Area) => {
            let w = Math.round(Number(neu.width));
            let h = Math.round(Number(neu.height));
            if (w > 0 && h > 0 && (w !== this._measuredW || h !== this._measuredH)) {
              this._measuredW = w;
              this._measuredH = h;
              this.tryDraw();
            }
          })

        // 没有披风（url 空 / 拉失败）→ 显示「无披风」占位文字（而不是空白），让用户明确
        // 知道这是"无披风"状态。Canvas 此时透明，文字叠在底色上居中。
        if (!this.hasCape()) {
          Text('无披风')
            .fontSize(Math.max(9, this.containerWidth * 0.26))
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFFB0')
            .textAlign(TextAlign.Center)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .width(this.containerWidth)
      .height(this.containerHeight)
      .borderRadius(4)
      .clip(true)

      if (this.showLabel && this.alias.length > 0) {
        Text(this.alias)
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.textSecondary)
          .margin({ top: 4 })
      }
    }
    .width(this.containerWidth)
  }

  private hasCape(): boolean {
    return !this._failed && this.capeUrl.length > 0;
  }
}
