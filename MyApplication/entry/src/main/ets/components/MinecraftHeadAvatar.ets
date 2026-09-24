/**
 * MinecraftHeadAvatar.ets — Minecraft 玩家正面平面头 + 字母 fallback
 *
 * 为什么单独抽这个组件？
 *   原本 HomeTab 和 AccountListSheet 都是直接 `Image(httpsUrl)` 的写法，
 *   但 OpenHarmony 5 / API 14 的 `Image(httpsUrl)` 有"静默不发请求"的 quirk
 *   —— hdc 抓包看不到任何流水，onError 也不触发。详见 RemoteImage.ets /
 *   RemoteImageCache.ets 顶部的考古注释。
 *
 *   workaround：走 RemoteImageCache.getRemotePixelMap → http.request → ImageKit 解码 →
 *   把 PixelMap 喂给 Image 控件。这条路径稳定。这个组件就是把这条路径 + 字母 fallback 封装。
 *
 * 头像服务选型（2026-05-23 实测记录）：
 *   - ❌ crafatar.com — 长期 Cloudflare 521 (origin down)，2024+ 多用户反馈不稳，已弃用
 *   - ✅ mc-heads.net — 独立基础设施、长期稳定。同样支持 uuid 任意格式（带 / 不带 dash）
 *   URL: `https://mc-heads.net/avatar/{uuid}/{px}` —— 默认包含 hat overlay 层（"正面平面头"）
 *
 * 视觉结构（Stack 三层）：
 *   1. 圆底（bgColor）
 *   2. 大写首字母（letter）—— pixelMap 还没好 / 加载失败 / 离线账户都看到这层
 *   3. Image(pixelMap)（圆形，cover 模式）—— 解码成功后盖住前两层
 *
 * 切 uuid（账户切换）→ @Watch 重置 pixelMap，重新拉新账户的头像。
 *
 * 用法：
 * ```typescript
 * MinecraftHeadAvatar({
 *   uuid: this.accountUuid,        // 36 位 dash UUID；空 / 长度不对 → 走 fallback
 *   diameter: 36,                  // vp
 *   fallbackLetter: 'E',           // 大写一位字母
 *   bgColor: this.theme.primary,
 *   letterColor: this.theme.textOnPrimary,
 *   letterFontSize: 15,            // 可选，默认 diameter * 0.42
 * })
 * ```
 *
 * 注意：
 *   - uuid 为空 / 长度不是 36 → 不发请求，直接显示 fallback（letter）
 *   - Crafatar 偶尔超时 → getRemotePixelMap 返 null → 静默保留 fallback（无错误 toast）
 *   - 同一 uuid 在进程内只 fetch + decode 一次（RemoteImageCache 全局缓存）
 */

import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { getRemotePixelMap } from 'commons';

const TAG = 'MinecraftHeadAvatar';

@Component
export struct MinecraftHeadAvatar {
  /**
   * 玩家皮肤 PNG URL（textures.minecraft.net）。**首选来源**：直接从皮肤里裁头（脸 + 帽子
   * overlay 合成），不依赖第三方头像服务（mc-heads/Crafatar 时常不可达，这正是头像"消失"的
   * 根因）。空 → 退回 uuid 走 mc-heads.net；再不行 → 字母兜底。
   */
  @Prop @Watch('onInputsChange') skinUrl: string = '';
  /** 36 位 dash UUID。空 / 长度不对 → 不 fetch，只显示 letter fallback。 */
  @Prop @Watch('onInputsChange') uuid: string = '';
  /** 容器尺寸（vp）。圆形头像，width === height === diameter，borderRadius = diameter/2。 */
  @Prop diameter: number = 36;
  /** fallback 大写一位字母（账户名首字母大写；空账户名传 '?'）。 */
  @Prop fallbackLetter: string = '?';
  /** 圆底背景色。 */
  @Prop bgColor: ResourceColor = '#3B82F6';
  /** 字母颜色。 */
  @Prop letterColor: ResourceColor = '#FFFFFF';
  /**
   * 字母字号（fp）。-1 = 自动按 diameter * 0.42 推算（36→15、44→18 经验值）。
   * 调用方一般不需要传这个；只有需要紧凑对齐其他文字时才覆盖。
   */
  @Prop letterFontSize: number = -1;
  /**
   * **Fallback** 形状（vp 圆角半径）—— 仅作用于"未加载/失败/离线"时的字母色块兜底层。
   *
   * 加载到头像后 Image 一律以**方形**显示（mc-heads.net 返的是方形 PNG，含 helm
   * overlay 全套像素，不裁角才算"完整显示"）。
   *
   * - -1（默认）= diameter / 2 → 兜底是正圆（列表 / 头像位场景）
   * - 0           → 兜底也是方形
   * - 其它值      → 兜底是圆角方形（推荐 6~10）
   */
  @Prop cornerRadius: number = -1;

  /**
   * 已解码的 PixelMap；null = 未加载 / 加载中 / 加载失败 → 走 fallback。
   * @State 让 ArkUI 能在异步解码完成后重渲染（盖上 Image 层）。
   */
  @State private pixelMap: image.PixelMap | null = null;

  aboutToAppear(): void {
    hilog.info(0x0000, TAG, 'aboutToAppear: uuid=%{public}s len=%{public}d diameter=%{public}d',
      this.uuid.length === 0 ? '<empty>' : this.uuid,
      this.uuid.length, this.diameter);
    this.kickOffLoad();
  }

  /** 切账户 / 皮肤变化 → 清空旧头像 + 重新加载。 */
  private onInputsChange(): void {
    hilog.info(0x0000, TAG, 'onInputsChange: skinUrl=%{public}s uuid len=%{public}d',
      this.skinUrl.length === 0 ? '<empty>' : '<set>', this.uuid.length);
    this.pixelMap = null;
    this.kickOffLoad();
  }

  /**
   * 加载头像。优先级：
   *   1. skinUrl 非空 → 拉皮肤 PNG，本地裁「脸(8,8,8,8) + 帽子 overlay(40,8,8,8)」合成头像
   *      （走 textures.minecraft.net，与 3D 皮肤预览同一可靠路径，不依赖第三方头像服务）。
   *   2. skinUrl 失败 / 为空，且 uuid 合法 → 退回 mc-heads.net/avatar。
   *   3. 都不行 → 字母兜底（pixelMap 保持 null）。
   */
  private kickOffLoad(): void {
    if (this.skinUrl.length > 0) {
      let skin = this.skinUrl;
      getRemotePixelMap(skin).then(async (pm: image.PixelMap | null): Promise<void> => {
        if (this.skinUrl !== skin) return;           // 期间切了账户 → 丢弃
        if (pm !== null) {
          let head = await this.cropHeadPM(pm);
          if (this.skinUrl === skin && head !== null) {
            this.pixelMap = head;
            return;
          }
        }
        // 皮肤裁切失败 → 尝试 uuid 兜底
        this.loadFromUuid_();
      }).catch((e: Error) => {
        hilog.warn(0x0000, TAG, 'skin head load failed: %{public}s', e ? e.message : '');
        this.loadFromUuid_();
      });
      return;
    }
    this.loadFromUuid_();
  }

  /** mc-heads.net 头像兜底（仅当 skinUrl 不可用时）。 */
  private loadFromUuid_(): void {
    let uuid = this.uuid;
    if (uuid.length !== 32 && uuid.length !== 36) {
      return;
    }
    let url = 'https://mc-heads.net/avatar/' + uuid + '/' + this.targetPx();
    getRemotePixelMap(url).then((pm: image.PixelMap | null) => {
      if (this.uuid === uuid && this.skinUrl.length === 0 && pm !== null) {
        this.pixelMap = pm;
      }
    }).catch((e: Error) => {
      hilog.warn(0x0000, TAG, 'mc-heads load failed for %{public}s: %{public}s', uuid, e ? e.message : '');
    });
  }

  /**
   * 从 64×64 / 64×32 皮肤里裁头：脸 (8,8,8,8) 作底，帽子 overlay (40,8,8,8) alpha 合成在上。
   * 返回 8×8 RGBA PixelMap；尺寸不足 / 失败 → null。
   */
  private async cropHeadPM(srcPm: image.PixelMap): Promise<image.PixelMap | null> {
    try {
      let info: image.ImageInfo = await srcPm.getImageInfo();
      let srcW = info.size.width;
      let srcH = info.size.height;
      if (srcW < 48 || srcH < 16) return null;   // 脸在(8,8)、帽子在(40,8)，都要 x<48,y<16
      let srcBuf = new ArrayBuffer(srcW * srcH * 4);
      await srcPm.readPixelsToBuffer(srcBuf);
      let s = new Uint8Array(srcBuf);
      let out = new Uint8Array(8 * 8 * 4);
      for (let y = 0; y < 8; y++) {
        for (let x = 0; x < 8; x++) {
          let faceOff = ((8 + y) * srcW + (8 + x)) * 4;
          let hatOff = ((8 + y) * srcW + (40 + x)) * 4;
          let dst = (y * 8 + x) * 4;
          let ha = s[hatOff + 3];
          if (ha === 0xFF) {
            out[dst] = s[hatOff]; out[dst + 1] = s[hatOff + 1]; out[dst + 2] = s[hatOff + 2]; out[dst + 3] = 0xFF;
          } else if (ha === 0) {
            out[dst] = s[faceOff]; out[dst + 1] = s[faceOff + 1]; out[dst + 2] = s[faceOff + 2]; out[dst + 3] = 0xFF;
          } else {
            // alpha 合成 over
            let a = ha / 255;
            out[dst] = Math.round(s[hatOff] * a + s[faceOff] * (1 - a));
            out[dst + 1] = Math.round(s[hatOff + 1] * a + s[faceOff + 1] * (1 - a));
            out[dst + 2] = Math.round(s[hatOff + 2] * a + s[faceOff + 2] * (1 - a));
            out[dst + 3] = 0xFF;
          }
        }
      }
      let opts: image.InitializationOptions = {
        size: { width: 8, height: 8 },
        srcPixelFormat: image.PixelMapFormat.RGBA_8888,
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: false,
      };
      return await image.createPixelMap(out.buffer, opts);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'cropHeadPM failed: %{public}s', (e as Error).message);
      return null;
    }
  }

  /** Crafatar size 参数；按 2x DPI 取，36→72、44→88，避免高分屏糊。 */
  private targetPx(): number {
    return Math.max(32, Math.round(this.diameter * 2));
  }

  /** 字母字号自动推算（diameter * 0.42 经验值，可被 letterFontSize 覆盖）。 */
  private resolvedLetterFontSize(): number {
    return this.letterFontSize > 0 ? this.letterFontSize : Math.round(this.diameter * 0.42);
  }

  /** 圆角半径自动推算（-1 = 圆形 = diameter / 2）。 */
  private resolvedCornerRadius(): number {
    return this.cornerRadius >= 0 ? this.cornerRadius : this.diameter / 2;
  }

  build() {
    Stack() {
      // 层 1：背景色块 + 字母 fallback（始终在最底层，PixelMap 还没好 / 失败时也兜得住）。
      // bg 走配置的 cornerRadius —— 列表场景默认正圆；HomeTab 这种独立位可以传圆角方
      // 形。Image 加载到之前用户看到的就是这一层的形状。
      Column()
        .width(this.diameter)
        .height(this.diameter)
        .backgroundColor(this.bgColor)
        .borderRadius(this.resolvedCornerRadius())
      Text(this.fallbackLetter)
        .fontSize(this.resolvedLetterFontSize())
        .fontWeight(FontWeight.Bold)
        .fontColor(this.letterColor)

      // 层 2：解码完成的 mc-heads.net 头像。
      // 故意**不**加 borderRadius —— mc-heads.net 的 PNG 已经是方形完整头像（含 helm
      // overlay），原样方形展示，**不被裁角**才算"完整"。bg 层的圆角在这一刻被 Image
      // 整块盖住，不影响视觉。失败时 Image 不挂载，bg 的圆角自然显露兜底。
      //
      // 不要在 outer Stack 上加 .clip(true) + borderRadius —— 会反过来把 Image 也
      // 裁掉，前功尽弃。这里 Stack 是纯方形 container，Image 正好对齐填满。
      if (this.pixelMap !== null) {
        Image(this.pixelMap)
          .width(this.diameter)
          .height(this.diameter)
          .objectFit(ImageFit.Cover)
          .interpolation(ImageInterpolation.None)
          .borderRadius(this.resolvedCornerRadius())
          .clip(true)
      }
    }
    .width(this.diameter)
    .height(this.diameter)
  }
}
