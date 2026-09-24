import { DiagnosticPolicy } from 'commons';
/**
 * SkinCapeDetailSheet.ets — 皮肤 / 披风 详情 Sheet（v2 · 2026-05-23）
 *
 * 在 AccountListSheet 的 Hero 卡按"皮肤详情"或点击披风行时弹出。
 *
 * 结构：
 *   ┌──────────────────────────────────────────┐
 *   │ [<] 皮肤与披风                             │
 *   │      · 用户名                              │
 *   ├──────────────────────────────────────────┤
 *   │ [SkinCard]                               │
 *   │   渐变 stage：大尺寸全身皮肤渲染            │
 *   │   底部：CLASSIC/SLIM badge + 跳转按钮       │
 *   │                                          │
 *   │ [CapeCard]                               │
 *   │   渐变 stage：当前披风（大）               │
 *   │   底部：alias badge                       │
 *   │                                          │
 *   │ [InfoNote] 数据由 Mojang Profile 提供      │
 *   └──────────────────────────────────────────┘
 *
 * 编辑能力：
 *   皮肤 / 披风的"修改"功能在 minecraft.net 网页或 Minecraft 启动器内完成 ——
 *   AMCL 不内嵌皮肤上传 UI（M3 计划，需先解决 Bearer token 上传 PUT 风险）。
 *   "前往修改"按钮跳浏览器到 minecraft.net/profile。
 *
 * 创建日期：2026-05-23
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { ThemeColors } from 'commons';
import { Account, AccountCape, AccountType, AccountError } from 'account';
import { getAccountManager } from 'account';
import { AppIconName } from 'commons';
import { AppIcon } from './AppIcon';
import { CapePreview } from './CapePreview';
import { SkinCanvas3D } from './SkinCanvas3D';

import { AppLogger } from 'commons';
import { LOG_DOMAIN_ACCOUNT } from 'commons';

const TAG = 'SkinCapeDetailSheet';

const MINECRAFT_PROFILE_URL = 'https://www.minecraft.net/zh-hans/msaprofile';

@Component
export struct SkinCapeDetailSheet {
  @Prop theme: ThemeColors = {} as ThemeColors;
  @Prop bottomSafeHeight: number = 0;

  /** 入口账户 —— 由 AccountListSheet 设置后再 show. */
  account: Account | null = null;

  onClose: () => void = () => {};
  /**
   * 披风切换成功后回调，让父 sheet（AccountListSheet）重新读账户状态、
   * 刷 Hero 卡 / cape 行 UI。无回调时只更新本 sheet 内部 @State。
   */
  onChanged: () => void = () => {};

  // ============================================================
  //  披风切换状态（M2.6 引入）
  // ============================================================

  /**
   * 玩家拥有的披风列表快照。aboutToAppear 从 account.getOwnedCapes() 拷一份；
   * setActiveCape 成功后从 account 重新读，触发 ForEach 重渲染。
   */
  @State ownedCapes: AccountCape[] = [];
  /** 当前 active cape id（用于 tile 高亮）。无披风时空字符串。 */
  @State activeCapeId: string = '';
  /** 切换中的 cape id —— 该 tile 显示 spinner，整个 grid 禁点防止并发。空 = 闲。 */
  @State switchingCapeId: string = '';
  /** 错误横幅（3s 自动消失）。 */
  @State capeErrorMsg: string = '';
  /** 成功提示横幅（2s 自动消失，提示切披风 / 同步成功）。 */
  @State capeSuccessMsg: string = '';
  /** 是否正在从 Mojang 同步 profile（按下"刷新披风列表"后变 true）。 */
  @State syncing: boolean = false;
  /**
   * 当前预览中的披风。null 表示没在预览。
   * 长按 tile 触发显示 → 在浮层里以 200×320 大尺寸渲染披风，方便用户**查看**披风纹理。
   */
  @State previewCape: AccountCape | null = null;
  /** 是否正在预览"无披风" tile（与 previewCape 二选一）。 */
  @State previewIsNoCape: boolean = false;

  // ========= 当前账户的皮肤 / 披风快照（@State 形式）=========
  //
  // 同 AccountListSheet：ArkUI 的 @State 对对象只看引用，Account 内部 mutation
  // 拿不到。SkinCard 顶部的 SkinCanvas3D、CapeCard 顶部的大尺寸 CapePreview 都要在
  // 切换披风 / 同步成功后立刻刷新。把这几个会变的字段抽成 @State 字符串，让
  // ArkUI 按值比对触发 @Prop / @Watch。
  //
  // refreshCapeStateFromAccount() 会同步它们；aboutToAppear / applyCape /
  // syncProfileNow 都通过此函数走统一刷新路径。
  @State activeSkinUrl: string = '';
  @State activeSkinVariant: string = '';
  @State activeCapeUrl: string = '';
  @State activeCapeAlias: string = '';

  aboutToAppear(): void {
    // 显式重置 transient 状态，防止 sheet 复用时残留上次的 preview / toast
    this.previewCape = null;
    this.previewIsNoCape = false;
    this.capeErrorMsg = '';
    this.capeSuccessMsg = '';
    this.syncing = false;
    this.switchingCapeId = '';
    if (this.account !== null) {
      this.refreshCapeStateFromAccount();
    }
  }

  build() {
    // Stack 作根：主内容 + 预览浮层（z-order 由 child 顺序决定，浮层在最上）。
    // 旧版根是 Column，加预览时改 Stack 不影响布局——主内容自己 width/height 100%。
    Stack() {
      Column() {
        // 顶部 header：返回 + 标题 + (微软账户) 同步按钮
        Row({ space: 12 }) {
          Row() {
            AppIcon({ name: AppIconName.ChevronLeft, iconSize: 22, color: this.theme.textPrimary })
          }
          .width(36)
          .height(36)
          .borderRadius(18)
          .backgroundColor(this.theme.bgInput)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .onClick(() => { this.onClose(); })

          Column({ space: 2 }) {
            Text('皮肤与披风')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.theme.textPrimary)
              .maxLines(1)
            Text(this.headerSubtitle())
              .fontSize(11)
              .fontColor(this.theme.textSecondary)
              .maxLines(1)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          // 仅微软账户显示"同步"按钮——主动从 Mojang 拉最新 profile（皮肤 / 披风 / ownedCapes）
          if (this.canSync()) {
            this.HeaderSyncButton();
          }
        }
        .width('100%')
        .padding({ top: 8, bottom: 12, left: 16, right: 16 })
        .alignItems(VerticalAlign.Center)

        // 主内容滚动区
        Scroll() {
          Column({ space: 12 }) {
            this.MainBody();
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 20 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)

        // 错误横幅（披风切换失败 / 网络问题），3s 自动消失
        if (this.capeErrorMsg.length > 0) {
          this.ErrorToast(this.capeErrorMsg);
        }
        // 成功横幅（披风切换 / 披风同步成功），2s 自动消失
        if (this.capeSuccessMsg.length > 0) {
          this.SuccessToast(this.capeSuccessMsg);
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.theme.bgSecondary)
      .padding({ bottom: this.bottomSafeHeight })

      // 预览浮层（长按 tile 弹出大图，松手关闭）—— 主内容上方独立一层
      if (this.previewCape !== null || this.previewIsNoCape) {
        this.CapePreviewOverlay();
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * Header 右上角的"同步披风"按钮。点击调 syncProfileNow → 从 Mojang 重新拉一遍
   * profile，用于"用户在 minecraft.net 新获得披风后 AMCL 本地缓存没更新"的场景。
   *
   * syncing 状态下显示 spinner + 禁点（防止并发请求 Mojang）。
   */
  @Builder
  HeaderSyncButton() {
    Row() {
      if (this.syncing) {
        LoadingProgress()
          .width(20)
          .height(20)
          .color(this.theme.primary)
      } else {
        AppIcon({ name: AppIconName.Refresh, iconSize: 18, color: this.theme.primary })
      }
    }
    .width(36)
    .height(36)
    .borderRadius(18)
    .backgroundColor(this.theme.primaryLight)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .opacity(this.syncing ? 0.7 : 1.0)
    .onClick(() => {
      if (this.syncing) return;
      this.syncProfileNow();
    })
  }

  @Builder
  ErrorToast(msg: string) {
    Row({ space: 8 }) {
      AppIcon({ name: AppIconName.Error, iconSize: 16, color: this.theme.error })
      Text(msg)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.theme.error)
        .layoutWeight(1)
        .maxLines(2)
    }
    .width('92%')
    .padding({ top: 10, bottom: 10, left: 12, right: 12 })
    .backgroundColor(this.theme.errorBg)
    .borderRadius(12)
    .alignItems(VerticalAlign.Center)
    .margin({ bottom: 12 })
  }

  /**
   * 成功 toast。结构镜像 ErrorToast，色板用 success 系（绿底 + check 图标）。
   * 用同一个横幅位（紧贴底部 safe area），错误 / 成功不会同框（capeErrorMsg /
   * capeSuccessMsg 在 applyCape / syncProfileNow 中互斥置位）。
   */
  @Builder
  SuccessToast(msg: string) {
    Row({ space: 8 }) {
      AppIcon({ name: AppIconName.CheckCircle, iconSize: 16, color: this.theme.success })
      Text(msg)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.theme.success)
        .layoutWeight(1)
        .maxLines(2)
    }
    .width('92%')
    .padding({ top: 10, bottom: 10, left: 12, right: 12 })
    .backgroundColor(this.theme.successBg)
    .borderRadius(12)
    .alignItems(VerticalAlign.Center)
    .margin({ bottom: 12 })
  }

  @Builder
  MainBody() {
    // 这里有意把 this.account 的非 null 判断写在 @Builder 里 —— ArkTS 编译器
    // 对 this 字段的类型收窄不像本地变量稳定（API 18 个测试），所以 SkinCard /
    // CapeCard 接受 Account 形参，外面把 this.account 强转后传进去。
    if (this.account !== null) {
      this.SkinCard(this.account as Account);
      this.CapeCard(this.account as Account);
      this.InfoNote();
    }
  }

  /**
   * 披风大图预览浮层。长按某个 cape tile（含"无披风"）触发显示，覆盖在主内容上方。
   *
   * 结构：
   *   ┌─────────────────────────────┐
   *   │  半透明黑底（点击关闭）        │
   *   │  ┌──────────────────────┐   │
   *   │  │     [大图 200×320]    │   │
   *   │  │                       │   │
   *   │  │  披风名称              │   │
   *   │  │  状态：已佩戴 / 未佩戴 │   │
   *   │  │                       │   │
   *   │  │  [关闭]               │   │
   *   │  └──────────────────────┘   │
   *   └─────────────────────────────┘
   *
   * 关闭路径：① 点底层蒙层；② 点关闭按钮。
   */
  @Builder
  CapePreviewOverlay() {
    Stack() {
      // 半透明蒙层 —— 点击空白处关闭浮层
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#000000B0')
        .onClick(() => { this.closePreview(); })

      // 中央卡片：大图 + 元数据 + 关闭按钮。点击卡片本身不关闭（只有点蒙层才关闭）。
      Column({ space: 16 }) {
        // 大图区域
        Stack() {
          Column()
            .width('100%')
            .height('100%')
            .linearGradient({
              angle: 180,
              colors: [['#1F2937', 0.0], ['#0F172A', 1.0]],
            })
            .borderRadius(12)

          if (this.previewIsNoCape) {
            Column({ space: 12 }) {
              AppIcon({ name: AppIconName.Close, iconSize: 64, color: '#FFFFFFAA' })
              Text('未佩戴披风')
                .fontSize(13)
                .fontColor('#FFFFFFCC')
            }
            .alignItems(HorizontalAlign.Center)
          } else if (this.previewCape !== null) {
            // 大尺寸 200×320 vp（10×16 源像素 × 20 倍放大），保持像素风
            CapePreview({
              capeUrl: (this.previewCape as AccountCape).url,
              alias: (this.previewCape as AccountCape).alias,
              theme: this.theme,
              containerWidth: 200,
              containerHeight: 320,
              showLabel: false,
            })
          }
        }
        .width(240)
        .height(360)
        .borderRadius(12)
        .clip(true)

        // 元数据 + 状态
        Column({ space: 4 }) {
          Text(this.previewTitle())
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.theme.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.previewSubtitle())
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.textSecondary)
            .maxLines(1)
        }
        .alignItems(HorizontalAlign.Center)

        // 关闭按钮 —— 显式关闭，比 "点空白" 更明确
        Row({ space: 6 }) {
          AppIcon({ name: AppIconName.Close, iconSize: 14, color: this.theme.textPrimary })
          Text('关闭预览')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.textPrimary)
        }
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
        .backgroundColor(this.theme.bgInput)
        .borderRadius(10)
        .alignItems(VerticalAlign.Center)
        .onClick(() => { this.closePreview(); })
      }
      .padding(20)
      .backgroundColor(this.theme.bgCard)
      .borderRadius(16)
      .alignItems(HorizontalAlign.Center)
      // hitTestBehavior：避免点击卡片穿透到底层蒙层而触发关闭
      .hitTestBehavior(HitTestMode.Block)
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }

  /** 预览浮层标题：cape alias 或 "无披风"。 */
  private previewTitle(): string {
    if (this.previewIsNoCape) return '无披风';
    if (this.previewCape !== null) {
      let alias = (this.previewCape as AccountCape).alias;
      return alias.length > 0 ? alias : '披风';
    }
    return '';
  }

  /** 预览浮层副标题：当前是否 active + 切换提示。 */
  private previewSubtitle(): string {
    if (this.previewIsNoCape) {
      return this.isNoCapeSelected() ? '已应用 · 点击 tile 可恢复披风' : '未应用 · 点击 tile 即可脱下披风';
    }
    if (this.previewCape !== null) {
      let id = (this.previewCape as AccountCape).id;
      return this.isCapeSelected(id) ? '当前佩戴中' : '已拥有 · 点击 tile 切换为此披风';
    }
    return '';
  }

  private headerSubtitle(): string {
    let acc = this.account;
    if (acc === null) return '';
    return acc.getDisplayName();
  }

  // ============================================================
  //  Cards
  // ============================================================

  @Builder
  SkinCard(acc: Account) {
    Column() {
      // 渐变 stage：大尺寸 3D 皮肤渲染
      Stack() {
        // 底色：让 WebView 透明背景下能看到一层渐变 + Canvas 降级时背景不至于全黑
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 180,
            colors: [['#60A5FA', 0.0], ['#1E40AF', 1.0]],
          })
          .borderRadius({ topLeft: 16, topRight: 16 })

        // 皮肤渲染（Canvas 软件投影；fetch 走 RemoteImageCache —— 见 SkinCanvas3D
        // 文件头的"为什么不用 ImageBitmap"注释）。
        // v6 起 SkinCanvas3D 自己 width('100%').height('100%') + onAreaChange 测尺寸，
        // 不再需要 containerWidth/Height props 限定大小，由外层 Stack 的 .height(320) 决定。
        // skinUrl / slim 走 @State —— 详见类字段定义处的注释（ArkUI 引用比对 quirk）。
        SkinCanvas3D({
          skinUrl: this.activeSkinUrl,
          username: acc.getDisplayName(),
          isOffline: acc.type === AccountType.OFFLINE,
          slim: this.activeSkinVariant === 'SLIM',
          theme: this.theme,
        })
      }
      .width('100%')
      .height(320)

      // Meta 行
      Row({ space: 10 }) {
        Column({ space: 3 }) {
          Row({ space: 6 }) {
            AppIcon({ name: AppIconName.ResourcePack, iconSize: 14, color: this.theme.textPrimary })
            Text('皮肤')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.theme.textPrimary)
            this.SkinVariantBadge();
          }
          .alignItems(VerticalAlign.Center)
          Text(this.skinSubtitle(acc))
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.textHint)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (acc.type === AccountType.MICROSOFT) {
          Row({ space: 6 }) {
            AppIcon({ name: AppIconName.ArrowUpRight, iconSize: 13, color: this.theme.primary })
            Text('前往修改')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.theme.primary)
          }
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .backgroundColor(this.theme.primaryLight)
          .borderRadius(10)
          .alignItems(VerticalAlign.Center)
          .onClick(() => { this.openMinecraftProfile(); })
        }
      }
      .width('100%')
      .padding({ top: 12, bottom: 12, left: 14, right: 14 })
      .alignItems(VerticalAlign.Center)
      .border({ width: { top: 1 }, color: this.theme.divider })
    }
    .width('100%')
    .backgroundColor(this.theme.bgCard)
    .borderRadius(16)
    .clip(true)
  }

  @Builder
  SkinVariantBadge() {
    Row() {
      Text(this.skinVariantText())
        .fontSize(10)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.theme.primary)
    }
    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
    .backgroundColor(this.theme.primaryLight)
    .borderRadius(6)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  CapeCard(acc: Account) {
    Column() {
      // Cape stage —— 灰底渐变，更突出披风颜色
      Stack() {
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 180,
            colors: [['#1F2937', 0.0], ['#0F172A', 1.0]],
          })
          .borderRadius({ topLeft: 16, topRight: 16 })

        if (this.hasCape()) {
          // capeUrl / alias 走 @State —— 详见类字段定义处的注释。
          CapePreview({
            capeUrl: this.activeCapeUrl,
            alias: this.activeCapeAlias,
            theme: this.theme,
            containerWidth: 96,
            containerHeight: 160,
            showLabel: false,
          })
        } else {
          Column({ space: 8 }) {
            AppIcon({ name: AppIconName.EmptySad, iconSize: 36, color: '#FFFFFF60' })
            Text('未佩戴披风')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFFBB')
            Text('在 Minecraft Realms 或活动中获取披风后即可显示')
              .fontSize(11)
              .fontWeight(FontWeight.Regular)
              .fontColor('#FFFFFF80')
              .textAlign(TextAlign.Center)
              .maxLines(2)
          }
          .alignItems(HorizontalAlign.Center)
          .padding({ left: 24, right: 24 })
        }
      }
      .width('100%')
      .height(200)

      // Meta 行
      Row({ space: 10 }) {
        Column({ space: 3 }) {
          Row({ space: 6 }) {
            AppIcon({ name: AppIconName.Shader, iconSize: 14, color: this.theme.textPrimary })
            Text('披风')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.theme.textPrimary)
            if (this.hasCape()) {
              this.CapeAliasBadge();
            }
          }
          .alignItems(VerticalAlign.Center)
          Text(this.capeSubtitle(acc))
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.textHint)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (acc.type === AccountType.MICROSOFT) {
          Row({ space: 6 }) {
            AppIcon({ name: AppIconName.ArrowUpRight, iconSize: 13, color: this.theme.textPrimary })
            Text('管理')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.theme.textPrimary)
          }
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .backgroundColor(this.theme.bgInput)
          .borderRadius(10)
          .alignItems(VerticalAlign.Center)
          .onClick(() => { this.openMinecraftProfile(); })
        }
      }
      .width('100%')
      .padding({ top: 12, bottom: 12, left: 14, right: 14 })
      .alignItems(VerticalAlign.Center)
      .border({ width: { top: 1 }, color: this.theme.divider })

      // ===== 我的披风 grid（M2.6 + M2.7）=====
      // 微软账户始终显示 section（即使 ownedCapes=0 也展示空状态 + 同步按钮，
      // 让玩家能主动从 Mojang 拉最新披风列表）；离线账户跳过整个 section。
      if (acc.type === AccountType.MICROSOFT) {
        this.CapeSwitcherSection(acc);
      }
    }
    .width('100%')
    .backgroundColor(this.theme.bgCard)
    .borderRadius(16)
    .clip(true)
  }

  /**
   * 我的披风 grid —— PCL 同款交互：玩家拥有的所有披风（含 active）平铺，
   * 加一个"无披风"特殊 tile 让玩家可以脱掉披风。
   *
   * 数据源：this.ownedCapes（aboutToAppear 时从 account.getOwnedCapes() 拷贝；
   * setActiveCape / syncProfile 成功后从 account 重读触发 ForEach 重渲染）。
   *
   * 交互：
   *   - 点击 tile → 切换披风（applyCape）
   *   - 长按 tile → 弹出大图预览（openPreview）
   *   - 点击右上角同步按钮 → 从 Mojang 拉最新 ownedCapes（syncProfileNow）
   *
   * 状态：this.switchingCapeId 非空时所有 tile 禁点 + 该 tile 显示 spinner，
   * 避免并发 PUT 导致 Mojang 端不一致。
   */
  @Builder
  CapeSwitcherSection(acc: Account) {
    Column({ space: 10 }) {
      // 子标题：「我的披风 · N 个」+ 切换 hint + 内联同步按钮（与 header 同步按钮等价，
      // 这里离 grid 更近、玩家更容易找到）
      Row({ space: 8 }) {
        Text('我的披风')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.theme.textPrimary)
        Text(this.switcherSubtitle())
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.textSecondary)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        // 内联同步按钮：图标 + "刷新" 文字，比 header 那个 icon-only 更醒目
        this.InlineSyncButton();
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.ownedCapes.length === 0) {
        // 空状态：本地缓存里没披风。可能是首次登录还没拉过 / 玩家就是没披风。
        // 提示玩家点同步按钮主动从 Mojang 拉一遍。
        this.EmptyCapesPrompt();
      } else {
        // tile 网格：3 列。用 Flex.Wrap 而不是 Grid —— 后者要预知行高，前者根据
        // tile 内容自然撑开，加 / 减 cape 不用调列表布局。
        Flex({
          direction: FlexDirection.Row,
          wrap: FlexWrap.Wrap,
          justifyContent: FlexAlign.Start,
          alignItems: ItemAlign.Start,
        }) {
          // "无披风" tile（始终在最前；点击 → DELETE /capes/active）
          this.NoCapeTile(acc);
          // 其余披风，按 owned 顺序展示
          ForEach(this.ownedCapes, (cape: AccountCape) => {
            this.CapeTile(acc, cape);
          }, (cape: AccountCape) => cape.id);
        }
        .width('100%')
      }

      // 底部 hint：长按可预览（仅在有披风时展示，避免空状态时重复信息）
      if (this.ownedCapes.length > 0) {
        Row({ space: 6 }) {
          AppIcon({ name: AppIconName.Info, iconSize: 12, color: this.theme.textHint })
          Text('点击切换 · 长按可查看大图')
            .fontSize(11)
            .fontColor(this.theme.textHint)
            .maxLines(1)
        }
        .alignItems(VerticalAlign.Center)
        .padding({ top: 4 })
      }
    }
    .width('100%')
    .padding({ top: 14, bottom: 14, left: 14, right: 14 })
    .alignItems(HorizontalAlign.Start)
    .border({ width: { top: 1 }, color: this.theme.divider })
  }

  /**
   * 内联同步按钮（在 grid section 标题右侧）。比 header 上的 icon-only 按钮更醒目，
   * 点击调 syncProfileNow → 从 Mojang 重新拉一遍 profile。
   */
  @Builder
  InlineSyncButton() {
    Row({ space: 4 }) {
      if (this.syncing) {
        LoadingProgress()
          .width(14)
          .height(14)
          .color(this.theme.primary)
      } else {
        AppIcon({ name: AppIconName.Refresh, iconSize: 12, color: this.theme.primary })
      }
      Text(this.syncing ? '同步中…' : '刷新')
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.theme.primary)
    }
    .padding({ left: 8, right: 8, top: 5, bottom: 5 })
    .backgroundColor(this.theme.primaryLight)
    .borderRadius(8)
    .alignItems(VerticalAlign.Center)
    .opacity(this.syncing ? 0.7 : 1.0)
    .onClick(() => {
      if (this.syncing) return;
      this.syncProfileNow();
    })
  }

  /**
   * ownedCapes 为空时的占位提示。可能是：
   *   1. 首次登录 + 上次 fromInteractiveLogin 没拉到（profile 调用失败但登录成功）
   *   2. 该账户从未获得过披风（这是大多数玩家的情况）
   *   3. 老账户记录（< M2.6）没有 ownedCapes 字段，需要 sync 一次
   *
   * 显示一个友好的引导："点上方刷新按钮从 Mojang 同步"。
   */
  @Builder
  EmptyCapesPrompt() {
    Column({ space: 8 }) {
      AppIcon({ name: AppIconName.EmptySad, iconSize: 32, color: this.theme.textHint })
      Text('暂无披风信息')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.theme.textPrimary)
      Text(this.emptyCapesHintText())
        .fontSize(11)
        .fontWeight(FontWeight.Regular)
        .fontColor(this.theme.textSecondary)
        .textAlign(TextAlign.Center)
        .maxLines(3)
    }
    .width('100%')
    .padding({ top: 16, bottom: 16, left: 12, right: 12 })
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.theme.bgInput)
    .borderRadius(12)
  }

  /**
   * "无披风" 特殊 tile —— 用 X 图标代替 cape 图。点击 → setActiveCape(null)。
   *
   * 高亮条件：activeCapeId === '' （账户当前无 active cape）。
   *
   * 注意：ArkTS @Builder 不允许在第一个 UI 元素之前写 let 语句（10905209），
   * 所以 selected / busy / mineHover 全用 isXxx() 私有方法在使用点求值。
   */
  @Builder
  NoCapeTile(acc: Account) {
    Column({ space: 4 }) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%')
          .height('100%')
          .borderRadius(8)
          .backgroundColor('#1F2937')
          // 选中态：primary 色边框（与 CapeTile 高亮一致）
          .border({
            width: this.isNoCapeSelected() ? 2 : 1,
            color: this.isNoCapeSelected() ? this.theme.primary : this.theme.divider,
            radius: 8,
          })

        // 居中 X / 斜杠图标占位
        AppIcon({
          name: AppIconName.Close,
          iconSize: 28,
          color: this.isNoCapeSelected() ? this.theme.primary : '#FFFFFFAA',
        })

        // Spinner / check 角标
        if (this.isSwitchingThisTile('__none__')) {
          this.TileBusyOverlay();
        } else if (this.isNoCapeSelected()) {
          this.TileActiveCheck();
        }
      }
      .width(72)
      .height(96)

      Text('无披风')
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.isNoCapeSelected() ? this.theme.primary : this.theme.textSecondary)
        .maxLines(1)
    }
    .width('33%')
    .padding(6)
    .alignItems(HorizontalAlign.Center)
    .opacity(this.isBusy() && !this.isSwitchingThisTile('__none__') ? 0.5 : 1.0)
    .onClick(() => {
      if (this.isBusy()) return;            // 防并发
      if (this.isNoCapeSelected()) return;   // 已是"无披风"，no-op
      this.applyCape(acc, null);
    })
    .gesture(
      LongPressGesture({ repeat: false, duration: 500 })
        .onAction(() => { this.openPreviewNoCape(); })
    )
  }

  /**
   * 单个披风 tile：cape 图 + alias + 选中状态。
   *
   * 点击 → setActiveCape(cape.id)（已 active 的不发请求，onClick 短路）。
   * 局部 selected/busy/mineHover 用 isXxx() 方法替代 let（ArkTS @Builder 限制）。
   */
  @Builder
  CapeTile(acc: Account, cape: AccountCape) {
    Column({ space: 4 }) {
      Stack({ alignContent: Alignment.Center }) {
        // 边框 + 选中高亮容器
        Column()
          .width('100%')
          .height('100%')
          .borderRadius(8)
          .border({
            width: this.isCapeSelected(cape.id) ? 2 : 1,
            color: this.isCapeSelected(cape.id) ? this.theme.primary : this.theme.divider,
            radius: 8,
          })
        // CapePreview 内部自带 #1F2937 暗灰底，无需再叠
        CapePreview({
          capeUrl: cape.url,
          alias: cape.alias,
          theme: this.theme,
          containerWidth: 70,
          containerHeight: 94,
          showLabel: false,
        })
        if (this.isSwitchingThisTile(cape.id)) {
          this.TileBusyOverlay();
        } else if (this.isCapeSelected(cape.id)) {
          this.TileActiveCheck();
        }
      }
      .width(72)
      .height(96)

      Text(cape.alias.length > 0 ? cape.alias : '披风')
        .fontSize(11)
        .fontWeight(this.isCapeSelected(cape.id) ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.isCapeSelected(cape.id) ? this.theme.primary : this.theme.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('33%')
    .padding(6)
    .alignItems(HorizontalAlign.Center)
    .opacity(this.isBusy() && !this.isSwitchingThisTile(cape.id) ? 0.5 : 1.0)
    .onClick(() => {
      if (this.isBusy()) return;
      if (this.isCapeSelected(cape.id)) return;
      this.applyCape(acc, cape.id);
    })
    .gesture(
      LongPressGesture({ repeat: false, duration: 500 })
        .onAction(() => { this.openPreview(cape); })
    )
  }

  /** Tile 右上角的"已选中"对勾。 */
  @Builder
  TileActiveCheck() {
    Row() {
      AppIcon({ name: AppIconName.Check, iconSize: 12, color: '#FFFFFF', weight: FontWeight.Bold })
    }
    .width(20)
    .height(20)
    .borderRadius(10)
    .backgroundColor(this.theme.primary)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .position({ top: 4, right: 4 })
  }

  /** Tile 切换中遮罩 —— 半透明黑底 + 旋转圈。 */
  @Builder
  TileBusyOverlay() {
    Column() {
      LoadingProgress()
        .width(28)
        .height(28)
        .color(this.theme.primary)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#00000080')
    .borderRadius(8)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  CapeAliasBadge() {
    Row() {
      Text((this.activeCapeAlias.length > 0 ? this.activeCapeAlias : '已佩戴').toUpperCase())
        .fontSize(10)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.theme.warning)
    }
    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
    .backgroundColor(this.theme.warningBg)
    .borderRadius(6)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  InfoNote() {
    Row({ space: 10 }) {
      AppIcon({ name: AppIconName.Info, iconSize: 16, color: this.theme.primary })
      Text('皮肤与披风数据来自 Mojang Profile · 更新令牌后会自动同步')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.theme.primary)
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10, left: 12, right: 12 })
    .backgroundColor(this.theme.primaryLight)
    .borderRadius(12)
    .alignItems(VerticalAlign.Top)
  }

  // ============================================================
  //  Helpers
  // ============================================================

  private hasCape(): boolean {
    return this.activeCapeUrl.length > 0;
  }

  private skinSubtitle(acc: Account): string {
    if (acc.type === AccountType.OFFLINE) {
      return '离线账户 · 仅本地展示';
    }
    if (this.activeSkinUrl.length > 0) return 'textures.minecraft.net · 自动同步';
    return '使用默认 Steve 皮肤';
  }

  private skinVariantText(): string {
    let v = this.activeSkinVariant.toUpperCase();
    if (v === 'CLASSIC' || v === 'SLIM') return v;
    return 'CLASSIC';
  }

  private capeSubtitle(acc: Account): string {
    if (acc.type === AccountType.OFFLINE) return '离线账户没有披风';
    if (this.ownedCapes.length === 0) {
      // M2.7 起即使 ownedCapes=0 也展示 grid section（含同步按钮），subtitle 引导玩家去同步
      return this.hasCape()
        ? '已佩戴 · 下方刷新可查看更多披风'
        : '点击下方刷新从 Mojang 同步披风';
    }
    // 有 ownedCapes 时下面就有切换 grid 了，subtitle 简洁点
    return this.hasCape()
      ? '已佩戴 · 在下方切换'
      : '未佩戴 · 在下方选择';
  }

  /** "我的披风" section 标题右边的副标题（数量 / 状态提示）。 */
  private switcherSubtitle(): string {
    if (this.syncing) return '正在从 Mojang 同步…';
    if (this.ownedCapes.length === 0) return '点击右侧刷新加载';
    return '共 ' + this.ownedCapes.length + ' 个';
  }

  /** EmptyCapesPrompt 里的引导文字（按账户来源给出不同建议）。 */
  private emptyCapesHintText(): string {
    let acc = this.account;
    if (acc !== null && acc.type === AccountType.MICROSOFT) {
      return '点击右上角的刷新按钮从 Mojang 同步，\n或在 Minecraft Realms / 活动中获取披风';
    }
    return '只有微软正版账户能查看与切换披风';
  }

  /** 是否允许显示"同步"按钮（header / inline）。仅微软正版账户。 */
  private canSync(): boolean {
    let acc = this.account;
    if (acc === null) return false;
    return acc.type === AccountType.MICROSOFT;
  }

  // ============================================================
  //  披风切换实现（M2.6）
  // ============================================================

  // ---- @Builder 内"局部 selected/busy"判断（ArkTS 不让在 builder 顶部写 let） ----

  /** 该 cape 当前是否选中（active） */
  private isCapeSelected(capeId: string): boolean {
    return capeId === this.activeCapeId;
  }
  /** "无披风" tile 当前是否选中（账户无 active cape） */
  private isNoCapeSelected(): boolean {
    return this.activeCapeId.length === 0;
  }
  /** 整个 grid 是否处于切换中（任何 tile busy 都禁点其它 tile） */
  private isBusy(): boolean {
    return this.switchingCapeId.length > 0;
  }
  /** 该 tile 是否是当前正在切换的那个（显示 spinner overlay） */
  private isSwitchingThisTile(busyKey: string): boolean {
    return this.switchingCapeId === busyKey;
  }

  /**
   * 从 account 重新读 ownedCapes / activeCapeId 到本地 @State。
   * aboutToAppear + setActiveCape 成功后都调一次。
   */
  private refreshCapeStateFromAccount(): void {
    let acc = this.account;
    if (acc === null) {
      this.ownedCapes = [];
      this.activeCapeId = '';
      this.activeSkinUrl = '';
      this.activeSkinVariant = '';
      this.activeCapeUrl = '';
      this.activeCapeAlias = '';
      return;
    }
    let capes = acc.getOwnedCapes();
    this.ownedCapes = capes;
    let activeId = '';
    for (let cape of capes) {
      if (cape.isActive) {
        activeId = cape.id;
        break;
      }
    }
    this.activeCapeId = activeId;
    // 同步皮肤 / 披风字段到 @State 字符串。HeroCard 内 SkinCanvas3D / CapePreview
    // 的 @Prop 来源就是这几个 —— 改完 ArkUI 才能立即重 paint。
    this.activeSkinUrl = acc.getSkinUrl() ?? '';
    this.activeSkinVariant = acc.getSkinVariant() ?? '';
    this.activeCapeUrl = acc.getCapeUrl() ?? '';
    this.activeCapeAlias = acc.getCapeAlias() ?? '';
    if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG,
      'cape state refreshed: %{public}d capes, active=%{public}s, capeUrl=%{public}s',
      capes.length, activeId.length === 0 ? '<none>' : activeId,
      this.activeCapeUrl.length > 0 ? '<set>' : '<empty>');
  }

  /**
   * 处理披风 tile 的点击。capeId === null → 取消佩戴。
   *
   * 流程（async）：
   *   1. 标记 switchingCapeId 进入 busy 态（tile 显示 spinner，整个 grid 禁点）
   *   2. await account.setActiveCape(...) —— Mojang PUT/DELETE
   *   3. 成功：await accountManager.persistOne 落库，刷本地 @State，触发 onChanged
   *   4. 失败：弹错误横幅 3s 自动消失
   *   5. finally 清 switchingCapeId
   *
   * 失败时本地 @State 不变（activeCapeId 仍然是旧值，UI 会回到原状态），
   * 因为 setActiveCape 抛错后 account 内部状态没变。
   */
  private async applyCape(acc: Account, capeId: string | null): Promise<void> {
    // 用 '__none__' 作为 NoCapeTile 的虚拟 id —— 本地状态用，不会发给服务器
    let busyKey = capeId === null ? '__none__' : capeId;
    if (this.switchingCapeId.length > 0) return;
    // 防竞态：sync 在飞 → 跳过这次切换。否则切换完成可能被尚未返回的 sync 用旧
    // profile 覆盖回去（race window：sync GET 已发但 cape PUT 也已发的情况）
    if (this.syncing) return;
    this.switchingCapeId = busyKey;
    this.capeErrorMsg = '';
    AppLogger.info(TAG, `applyCape start: ${busyKey}`, LOG_DOMAIN_ACCOUNT);
    try {
      await acc.setActiveCape(capeId);
      // 落库（持久化新的 active cape + ownedCapes 状态）
      await getAccountManager().persistOne(acc);
      // 重新读快照刷 UI
      this.refreshCapeStateFromAccount();
      // 通知父 sheet 刷 Hero 卡 / 列表
      this.onChanged();
      AppLogger.info(TAG, `applyCape ok: ${busyKey}`, LOG_DOMAIN_ACCOUNT);
      // 成功 toast：友好提示玩家"切换成功"，2s 自动消失
      this.showSuccess(capeId === null ? '已脱下披风' : '披风切换成功');
    } catch (e) {
      let msg = (e instanceof AccountError)
        ? (e as AccountError).message
        : ('切换披风失败：' + (e as Error).message);
      this.capeErrorMsg = msg;
      this.capeSuccessMsg = '';   // 互斥：失败时清成功 toast
      AppLogger.error(TAG, `applyCape failed: ${msg}`, null, LOG_DOMAIN_ACCOUNT);
      setTimeout(() => {
        if (this.capeErrorMsg === msg) this.capeErrorMsg = '';
      }, 3000);
    } finally {
      this.switchingCapeId = '';
    }
  }

  /**
   * 主动从 Mojang 同步 profile（皮肤 / 披风 / ownedCapes），用于"用户在
   * minecraft.net 新获得披风后 AMCL 没看到"的场景。
   *
   * 流程（async）：
   *   1. syncing=true（按钮显示 spinner，禁点防并发）
   *   2. await account.syncProfile() —— Mojang GET /minecraft/profile
   *   3. 成功：await accountManager.persistOne 落库，刷本地 @State，触发 onChanged
   *   4. 失败：弹错误横幅 3s 自动消失
   *   5. finally 清 syncing
   */
  private async syncProfileNow(): Promise<void> {
    let acc = this.account;
    if (acc === null) return;
    if (acc.type !== AccountType.MICROSOFT) return;
    if (this.syncing) return;
    // 防竞态：cape 切换在飞 → 让切换先完成（切换后会拿到最新 profile，sync 暂时
    // 不需要；用户可在切换完后再点 sync）
    if (this.switchingCapeId.length > 0) return;
    this.syncing = true;
    this.capeErrorMsg = '';
    this.capeSuccessMsg = '';
    let beforeCount = this.ownedCapes.length;
    AppLogger.info(TAG, `syncProfileNow start: id=${acc.id} before=${beforeCount}`, LOG_DOMAIN_ACCOUNT);
    try {
      await acc.syncProfile();
      // 同步成功后落库（serialize 包含 skinUrl / capeUrl / ownedCapes 等明文字段）
      await getAccountManager().persistOne(acc);
      this.refreshCapeStateFromAccount();
      this.onChanged();
      let afterCount = this.ownedCapes.length;
      // 给出更具体的 toast：是新增了披风还是没变
      let msg: string;
      if (afterCount > beforeCount) {
        msg = '同步成功 · 新增 ' + (afterCount - beforeCount) + ' 个披风';
      } else if (afterCount < beforeCount) {
        msg = '同步成功 · 披风列表已更新';
      } else if (afterCount === 0) {
        msg = '同步完成 · 当前账户没有披风';
      } else {
        msg = '同步成功 · 披风列表已是最新';
      }
      this.showSuccess(msg);
      AppLogger.info(TAG, `syncProfileNow ok: after=${afterCount}`, LOG_DOMAIN_ACCOUNT);
    } catch (e) {
      let msg = (e instanceof AccountError)
        ? (e as AccountError).message
        : ('同步披风列表失败：' + (e as Error).message);
      this.capeErrorMsg = msg;
      this.capeSuccessMsg = '';
      AppLogger.error(TAG, `syncProfileNow failed: ${msg}`, null, LOG_DOMAIN_ACCOUNT);
      setTimeout(() => {
        if (this.capeErrorMsg === msg) this.capeErrorMsg = '';
      }, 3000);
    } finally {
      this.syncing = false;
    }
  }

  /**
   * 设置成功 toast 并 2s 后自动清除。多次连续调用以最后一次为准（idempotent
   * 通过 closure 比对当前消息实现）。
   */
  private showSuccess(msg: string): void {
    this.capeSuccessMsg = msg;
    setTimeout(() => {
      if (this.capeSuccessMsg === msg) this.capeSuccessMsg = '';
    }, 2000);
  }

  // ============================================================
  //  披风预览（M2.7 长按 tile → 大图查看）
  // ============================================================

  /** 长按 cape tile 触发的预览。previewCape 非 null 触发浮层渲染。 */
  private openPreview(cape: AccountCape): void {
    this.previewCape = cape;
    this.previewIsNoCape = false;
  }

  /** 长按 "无披风" tile 触发的预览。 */
  private openPreviewNoCape(): void {
    this.previewCape = null;
    this.previewIsNoCape = true;
  }

  /** 关闭预览浮层。 */
  private closePreview(): void {
    this.previewCape = null;
    this.previewIsNoCape = false;
  }

  /**
   * 打开系统浏览器到 minecraft.net/profile（皮肤/披风修改页）。
   * 不嵌内 WebView——Mojang profile 页要求 cookie 登录态，且本 sheet 是
   * "快速管理"而非"完整 profile 编辑"。
   *
   * 2026-05-23 API NEXT 迁移：UIAbilityContext 从 EntryAbility 缓存的
   * AppStorage['uiAbilityContext'] 取（getContext(this) 在 API 18+ 已弃用）。
   */
  private openMinecraftProfile(): void {
    let ctx = AppStorage.get<common.UIAbilityContext>('uiAbilityContext');
    if (!ctx) {
      AppLogger.warn(TAG, 'openMinecraftProfile: uiAbilityContext missing', null, LOG_DOMAIN_ACCOUNT);
      return;
    }
    ctx.startAbility({
      action: 'ohos.want.action.viewData',
      uri: MINECRAFT_PROFILE_URL,
    }).catch((e: Error) => {
      AppLogger.warn(TAG, 'open profile failed', e, LOG_DOMAIN_ACCOUNT);
    });
  }
}
