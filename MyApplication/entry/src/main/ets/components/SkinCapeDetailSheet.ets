/**
 * 呈现颜色遵循父层主题快照：操作文字与焦点独立于按钮填充，状态小字独立于进度填充。
 * 本域不读取主题偏好，不改变原事件、任务或账户生命周期；资源类别与第三方品牌保持独立。
 */
import { AppTitleAction } from './AppTitleAction';
import { ImmersiveTitleScaffold } from './ImmersiveTitleScaffold';
import { DiagnosticPolicy } from 'commons';
/**
 * 账号外观详情：在线账号展示身份、紧凑角色预览和已拥有的披风；
 * 离线账号仍分流到共享素材库编辑器，两者不共用保存语义。
 *
 * 微软披风点击后继续走真实setActiveCape与persistOne确认；第三方账号
 * 只展示其服务返回的外观，不出现Mojang同步或微软网页管理入口。
 * 本组件不改变父层Sheet尺寸，也不接管添加账号/登录页面。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { ThemeColors, DistributionPolicy } from 'commons';
import { Account, AccountCape, AccountType, AccountError } from 'account';
import { getAccountManager } from 'account';
import { AppIconName } from 'commons';
import { AppIcon } from './AppIcon';
import { CapePreview } from './CapePreview';
import { SkinCanvas3D } from './SkinCanvas3D';
import { MinecraftHeadAvatar } from './MinecraftHeadAvatar';
import { OfflineAppearanceEditor } from './OfflineAppearanceEditor';

import { AppLogger } from 'commons';
import { LOG_DOMAIN_ACCOUNT } from 'commons';
import { getTaskActivityOwner } from 'feature_core';

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

  /** 视图世代只控制展示权；已派发的账号持久化仍按原目标完成。 */
  private pageEpoch: number = 0;
  private alive: boolean = false;

  /** 确认续体仍属于同一次打开和同一个账号，关闭后不再写本地状态。 */
  private currentPage_(epoch: number, id: string): boolean {
    return this.alive && this.pageEpoch === epoch && this.account?.id === id;
  }

  aboutToDisappear(): void { this.alive = false; this.pageEpoch++; }

  aboutToAppear(): void {
    this.alive = true;
    this.pageEpoch++;
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


  /** 同步仍只对微软账户开放，忙态通过共同菜单的 enabled 投影，不能并发请求。 */
  private skinTitleActions_(): AppTitleAction[] {
    if (!this.canSync()) return [];
    return [{ id: 'sync', label: this.syncing ? '同步中' : '同步披风', icon: AppIconName.Refresh, enabled: !this.syncing && !this.isBusy() }];
  }

  build() {
    // Stack 作根：主内容 + 预览浮层（z-order 由 child 顺序决定，浮层在最上）。
    // 旧版根是 Column，加预览时改 Stack 不影响布局——主内容自己 width/height 100%。
    Stack() {
      // 离线账号使用共享库编辑器；微软和第三方的远端 profile 详情继续保留原行为。
      if (this.account !== null && (this.account as Account).type === AccountType.OFFLINE) {
        OfflineAppearanceEditor({ theme: this.theme, bottomSafeHeight: this.bottomSafeHeight,
          accountId: (this.account as Account).id, onClose: (): void => { this.onClose(); },
          onChanged: (): void => {
            // 编辑返回新账号实例；重新按稳定ID查找，不能继续读打开页面时的旧对象。
            const id = this.account?.id ?? '';
            this.account = getAccountManager().findById(id) ?? null;
            this.refreshCapeStateFromAccount();
            this.onChanged();
          } })
      } else {
      Column() {
      // 账户是修改对象，保留为标题同行胶囊；完整名称由胶囊详情读取，不再另占一行。
      ImmersiveTitleScaffold({ title: '皮肤与披风', contextLabel: this.headerAccountName_(), contextTitle: '当前账户', theme: this.theme, modal: false, surfaceColor: this.theme.bgPrimary, backLabel: '返回账户管理', backId: 'skin-cape-back', menuActions: this.skinTitleActions_(), onMenuAction: (id: string): void => { if (id === 'sync' && this.canSync() && !this.syncing) this.syncProfileNow(); }, onBack: (): void => { this.onClose(); },
        content: (): void => { this.ImmersiveTitleContent1_(); }
      })
    }
      .width('100%')
      .height('100%')
      .backgroundColor(this.theme.bgPrimary)
      .padding({ bottom: this.bottomSafeHeight })

      // 预览浮层（长按 tile 弹出大图，松手关闭）—— 主内容上方独立一层
      if (this.previewCape !== null || this.previewIsNoCape) {
        this.CapePreviewOverlay();
      }
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 原业务错误条继续独立显示；标题同步动作由skinTitleActions_统一投影忙态。 */


  @Builder
  ErrorToast(msg: string) {
    Row({ space: 8 }) {
      AppIcon({ name: AppIconName.Error, iconSize: 16, color: this.theme.errorText })
      Text(msg)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.theme.errorText)
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
      AppIcon({ name: AppIconName.CheckCircle, iconSize: 16, color: this.theme.successText })
      Text(msg)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.theme.successText)
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

  /** 身份、外观和管理入口分组展示，正文由外层Scroll负责小窗口与大字体可达性。 */
  @Builder
  MainBody() {
    if (this.account !== null) {
      this.OnlineIdentity_(this.account as Account);
      this.SkinCard(this.account as Account);
      if ((this.account as Account).type === AccountType.MICROSOFT) {
        this.CapeSwitcherSection(this.account as Account);
      } else {
        this.CapeCard(this.account as Account);
      }
      this.AccountInformation_(this.account as Account);
      this.InfoNote();
    }
  }

  /** 用户名获得独立伸缩空间，来源另行展示，避免挤在角色右侧的多枚小徽章里。 */
  @Builder
  private OnlineIdentity_(acc: Account) {
    Row({ space: 12 }) {
      MinecraftHeadAvatar({ skinUrl: this.activeSkinUrl, uuid: acc.uuid, diameter: 44,
        fallbackLetter: acc.getDisplayName().slice(0, 1).toUpperCase(), cornerRadius: 8,
        bgColor: this.theme.primaryLight, letterColor: this.theme.actionText })
      Column({ space: 4 }) {
        Text(acc.getDisplayName()).fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor(this.theme.textPrimary).width('100%').maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(acc.type === AccountType.MICROSOFT ? '微软正版 · 资料来自 Mojang' : '第三方账号 · 外观由皮肤站提供')
          .fontSize(14).fontColor(this.theme.textSecondary).width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').padding({ left: 4, right: 4 }).alignItems(VerticalAlign.Center)
  }

  /** UUID等低频资料通过明确入口查看，不再常驻主卡挤占姓名和外观空间。 */
  @Builder
  private AccountInformation_(acc: Account) {
    Row({ space: 12 }) {
      AppIcon({ name: AppIconName.Info, iconSize: 20, color: this.theme.textSecondary })
      Text('账号信息').fontSize(16).fontColor(this.theme.textPrimary).layoutWeight(1)
      AppIcon({ name: AppIconName.ChevronRight, iconSize: 18, color: this.theme.textHint })
    }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor(this.theme.bgCard).borderRadius(16)
      .onClick((): void => {
        this.getUIContext().showAlertDialog({ title: '账号信息',
          message: acc.getDisplayName() + '\n' + (acc.type === AccountType.MICROSOFT ? '微软正版' : '第三方账号') + '\nUUID：' + acc.uuid,
          confirm: { value: '完成', action: (): void => {} } });
      })
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
        .backgroundColor(this.theme.overlayShade)
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

  /** 只读取当前账户的显示名；无账户时不生成上下文占位，避免误认另一个编辑对象。 */
  private headerAccountName_(): string {
    let acc = this.account;
    if (acc === null) return '';
    return acc.getDisplayName();
  }

  // ============================================================
  //  Cards
  // ============================================================

  /**
   * 角色预览和在线皮肤信息并排，避免旧320高舞台把披风选择推到多屏之外。
   * 预览仍消费确认态URL/模型，网页按钮只对非商店微软账号开放。
   */
  @Builder
  SkinCard(acc: Account) {
    Row({ space: 20 }) {
      Stack() {
        SkinCanvas3D({ skinUrl: this.activeSkinUrl, username: acc.getDisplayName(),
          isOffline: false, slim: this.activeSkinVariant === 'SLIM', theme: this.theme })
      }.width(88).height(152).backgroundColor(this.theme.bgInput).borderRadius(12).clip(true)
      Column({ space: 8 }) {
        Text('当前皮肤').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.theme.textPrimary)
        Text(this.activeSkinVariant === 'SLIM' ? 'Slim · 纤细手臂' : 'Classic · 普通手臂')
          .fontSize(14).fontColor(this.theme.textSecondary)
        if (acc.type === AccountType.MICROSOFT && !DistributionPolicy.isStore()) {
          Row({ space: 6 }) {
            Text('前往网页修改').fontSize(14).fontColor(this.theme.actionText)
            AppIcon({ name: AppIconName.ArrowUpRight, iconSize: 16, color: this.theme.actionText })
          }.constraintSize({ minHeight: 44 }).alignItems(VerticalAlign.Center)
            .onClick((): void => { this.openMinecraftProfile(); })
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').constraintSize({ minHeight: 184 }).padding(16)
      .backgroundColor(this.theme.bgCard).borderRadius(20).alignItems(VerticalAlign.Center)
  }

  /** 第三方外观仅展示远端返回的当前披风，不混入微软已拥有披风和同步命令。 */
  @Builder
  CapeCard(acc: Account) {
    Row({ space: 16 }) {
      if (this.hasCape()) {
        CapePreview({ capeUrl: this.activeCapeUrl, alias: this.activeCapeAlias, theme: this.theme,
          containerWidth: 40, containerHeight: 64, showLabel: false })
      } else {
        Row() {
          AppIcon({ name: AppIconName.Shader, iconSize: 24, color: this.theme.textHint })
        }.width(40).height(64).justifyContent(FlexAlign.Center)
      }
      Column({ space: 6 }) {
        Text(this.hasCape() ? (this.activeCapeAlias || '当前披风') : '未佩戴披风')
          .fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.theme.textPrimary)
        Text('由第三方皮肤站提供').fontSize(14).fontColor(this.theme.textSecondary)
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').padding(16).backgroundColor(this.theme.bgCard).borderRadius(20)
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
      // 库标题、真实拥有数量与同步入口同行；同步和切换共用原命令的互斥守卫。
      Row({ space: 8 }) {
        Text('我的披风')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.theme.textPrimary)
        Text(this.switcherSubtitle())
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.textSecondary)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        // 就近保留同步入口，标题菜单和这里调用同一命令，不建立第二套数据源。
        this.InlineSyncButton();
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 老记录可能只有当前纹理，没有已拥有披风列表。此时展示已知预览并引导同步，
      // 不能把“缺少active ID”误当成“未佩戴”，也不能凭纹理URL伪造可选披风ID。
      if (this.activeCapeUrl.length > 0 && this.activeCapeId.length === 0) {
        Row({ space: 12 }) {
          CapePreview({ capeUrl: this.activeCapeUrl, alias: this.activeCapeAlias, theme: this.theme,
            containerWidth: 30, containerHeight: 48, showLabel: false })
          Column({ space: 4 }) {
            Text(this.activeCapeAlias || '当前佩戴的披风').fontSize(16).fontColor(this.theme.textPrimary)
            Text('同步后可查看已拥有的披风').fontSize(14).fontColor(this.theme.textSecondary)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%').padding(12).backgroundColor(this.theme.bgCard).borderRadius(16)
      }
      // 不佩戴是独立有效选项；空库也能明确表达当前无披风，未知远端状态不编造素材。
      Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start,
        alignItems: ItemAlign.Start }) {
        this.NoCapeTile(acc);
        ForEach(this.ownedCapes, (cape: AccountCape) => { this.CapeTile(acc, cape); },
          (cape: AccountCape) => cape.id);
      }.width('100%')
      if (this.ownedCapes.length === 0) {
        Text('暂无已拥有的披风，可同步获取最新资料。').fontSize(14).fontColor(this.theme.textSecondary)
      }

      // 底部 hint：长按可预览（仅在有披风时展示，避免空状态时重复信息）
      if (this.ownedCapes.length > 0) {
        Row({ space: 6 }) {
          AppIcon({ name: AppIconName.Info, iconSize: 12, color: this.theme.textHint })
          Text('点击切换 · 长按查看大图')
            .fontSize(14)
            .fontColor(this.theme.textHint)
            .maxLines(1)
        }
        .alignItems(VerticalAlign.Center)
        .padding({ top: 4 })
      }
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
    .alignItems(HorizontalAlign.Start)
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
          .color(this.theme.actionText)
      } else {
        AppIcon({ name: AppIconName.Refresh, iconSize: 12, color: this.theme.actionText })
      }
      Text(this.syncing ? '同步中…' : '同步')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.theme.actionText)
    }
    .constraintSize({ minWidth: 60, minHeight: 44 })
    .padding({ left: 12, right: 12 })
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.theme.primaryLight)
    .borderRadius(8)
    .alignItems(VerticalAlign.Center)
    .opacity(this.syncing ? 0.7 : 1.0)
    .onClick(() => {
      if (this.syncing || this.isBusy()) return;
      this.syncProfileNow();
    })
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
          .backgroundColor(this.isNoCapeSelected() ? this.theme.primaryLight : this.theme.bgCard)
          // 选中态：primary 色边框（与 CapeTile 高亮一致）
          .border({
            width: this.isNoCapeSelected() ? 2 : 1,
            color: this.isNoCapeSelected() ? this.theme.actionText : this.theme.divider,
            radius: 16,
          })

        // 未佩戴项使用主题容器；选中同时显示描边、标签和勾选，深浅主题都可辨。
        AppIcon({
          name: AppIconName.Close,
          iconSize: 28,
          color: this.isNoCapeSelected() ? this.theme.actionText : this.theme.textHint,
        })

        // Spinner / check 角标
        if (this.isSwitchingThisTile('__none__')) {
          this.TileBusyOverlay();
        } else if (this.isNoCapeSelected()) {
          this.TileActiveCheck();
        }
      }
      .width('100%')
      .height(112)

      Text('不佩戴')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.isNoCapeSelected() ? this.theme.actionText : this.theme.textSecondary)
        .maxLines(1)
    }
    .width('33%')
    .padding(6)
    .alignItems(HorizontalAlign.Center)
    .opacity((this.isBusy() || this.syncing) && !this.isSwitchingThisTile('__none__') ? 0.5 : 1.0)
    .onClick(() => {
      if (this.isBusy() || this.syncing) return;            // 防并发
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
            color: this.isCapeSelected(cape.id) ? this.theme.actionText : this.theme.divider,
            radius: 16,
          })
        // 复用实际披风纹理裁剪，外层选中边框不改动内部像素颜色。
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
      .width('100%')
      .height(112)

      Text(cape.alias.length > 0 ? cape.alias : '披风')
        .fontSize(14)
        .fontWeight(this.isCapeSelected(cape.id) ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.isCapeSelected(cape.id) ? this.theme.actionText : this.theme.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('33%')
    .padding(6)
    .alignItems(HorizontalAlign.Center)
    .opacity((this.isBusy() || this.syncing) && !this.isSwitchingThisTile(cape.id) ? 0.5 : 1.0)
    .onClick(() => {
      if (this.isBusy() || this.syncing) return;
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
      AppIcon({ name: AppIconName.Check, iconSize: 12, color: this.theme.textOnPrimary, weight: FontWeight.Bold })
    }
    .width(20)
    .height(20)
    .borderRadius(10)
    .backgroundColor(this.theme.actionPrimary)
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
        .color(this.theme.actionText)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.overlayShade)
    .borderRadius(8)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /** 文案按实际账号来源说明归属，第三方不会被错误标记为Mojang资料。 */
  @Builder
  InfoNote() {
    Text(this.account?.type === AccountType.MICROSOFT
      ? '点击披风后即时提交，成功后同步账号资料。'
      : '此角色的皮肤与披风由登录的第三方皮肤站提供。')
      .fontSize(14).fontColor(this.theme.textSecondary).width('100%')
  }

  // ============================================================
  //  Helpers
  // ============================================================

  private hasCape(): boolean {
    return this.activeCapeUrl.length > 0;
  }

  /** "我的披风" section 标题右边的副标题（数量 / 状态提示）。 */
  private switcherSubtitle(): string {
    if (this.syncing) return '正在从 Mojang 同步…';
    if (this.ownedCapes.length === 0) return '点击右侧刷新加载';
    return '共 ' + this.ownedCapes.length + ' 个';
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
    // 缓存资料缺少ownedCapes时仍可能持有真实capeUrl，不能误高亮“不佩戴”。
    return this.activeCapeId.length === 0 && this.activeCapeUrl.length === 0;
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
    if (!this.alive || this.account?.id !== acc.id || acc.type !== AccountType.MICROSOFT || this.isBusy() || this.syncing) return;
    const epoch: number = this.pageEpoch;
    const id: string = acc.id;
    const notify: () => void = this.onChanged;
    const busyKey: string = capeId === null ? '__none__' : capeId;
    this.switchingCapeId = busyKey;
    this.capeErrorMsg = ''; this.capeSuccessMsg = '';
    try {
      await acc.setActiveCape(capeId);
      // 账号写入以原始目标为准；页面关闭只退休显示，不能跳过已经成功的远端操作落库。
      await getAccountManager().persistOne(acc);
      this.recordCapeActivity_('success', capeId === null ? '已脱下披风' : '披风切换成功');
      try { notify(); } catch (error) { AppLogger.warn(TAG, '披风已保存，父界面刷新失败', error as Object, LOG_DOMAIN_ACCOUNT); }
      if (this.currentPage_(epoch, id)) {
        this.refreshCapeStateFromAccount();
        this.showSuccess(capeId === null ? '已脱下披风' : '披风切换成功');
      }
    } catch (error) {
      const message: string = error instanceof AccountError ? (error as AccountError).message : '切换披风失败：' + (error as Error).message;
      AppLogger.error(TAG, message, error as Object, LOG_DOMAIN_ACCOUNT);
      this.recordCapeActivity_('failed', message);
      if (this.currentPage_(epoch, id)) this.showFailure_(message);
    } finally {
      if (this.currentPage_(epoch, id)) this.switchingCapeId = '';
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
    const acc: Account | null = this.account;
    if (!this.alive || acc === null || acc.type !== AccountType.MICROSOFT || this.syncing || this.isBusy()) return;
    const epoch: number = this.pageEpoch;
    const id: string = acc.id;
    const notify: () => void = this.onChanged;
    const beforeCount: number = this.ownedCapes.length;
    this.syncing = true;
    this.capeErrorMsg = ''; this.capeSuccessMsg = '';
    try {
      await acc.syncProfile();
      await getAccountManager().persistOne(acc);
      try { notify(); } catch (error) { AppLogger.warn(TAG, '资料已保存，父界面刷新失败', error as Object, LOG_DOMAIN_ACCOUNT); }
      if (this.currentPage_(epoch, id)) {
        this.refreshCapeStateFromAccount();
        const afterCount: number = this.ownedCapes.length;
        this.showSuccess(afterCount > beforeCount ? '同步成功 · 新增 ' + (afterCount - beforeCount) + ' 个披风'
          : (afterCount === 0 ? '同步完成 · 当前账户没有披风' : '同步成功 · 披风列表已更新'));
      }
    } catch (error) {
      const message: string = error instanceof AccountError ? (error as AccountError).message : '同步披风列表失败：' + (error as Error).message;
      AppLogger.error(TAG, message, error as Object, LOG_DOMAIN_ACCOUNT);
      if (this.currentPage_(epoch, id)) this.showFailure_(message);
    } finally {
      if (this.currentPage_(epoch, id)) this.syncing = false;
    }
  }

  /** 活动归属继续使用主线统一owner；摘要故障不能把已确认的账号操作改写为失败。 */
  private recordCapeActivity_(status: string, message: string): void {
    try { getTaskActivityOwner().recordSummary('skin', '切换披风', status, message); }
    catch (error) { AppLogger.warn(TAG, '披风操作摘要记录失败', error as Object, LOG_DOMAIN_ACCOUNT); }
  }

  /** 临时反馈绑定当前视图和目标；旧计时器不能清除重新打开后的新消息。 */
  private showSuccess(msg: string): void {
    const epoch: number = this.pageEpoch, id: string = this.account?.id ?? '';
    this.capeErrorMsg = ''; this.capeSuccessMsg = msg;
    setTimeout((): void => {
      if (this.currentPage_(epoch, id) && this.capeSuccessMsg === msg) this.capeSuccessMsg = '';
    }, 2000);
  }

  /** 失败保留原确认态；提示只在所属页面仍存活时显示和定时撤下。 */
  private showFailure_(msg: string): void {
    const epoch: number = this.pageEpoch, id: string = this.account?.id ?? '';
    this.capeSuccessMsg = ''; this.capeErrorMsg = msg;
    setTimeout((): void => {
      if (this.currentPage_(epoch, id) && this.capeErrorMsg === msg) this.capeErrorMsg = '';
    }, 3000);
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
    // 此处是登录后的皮肤网站管理，不是 Microsoft 认证步骤；商店只保留应用内账户 API。
    if (DistributionPolicy.isStore()) return;
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

  /** 保留原正文的父组件状态与业务回调；具名content只转调此真正@Builder，避免this漂移。 */
  @Builder
  private ImmersiveTitleContent1_() {
        // 主内容滚动区
        Scroll() {
          Column({ space: 16 }) {
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
}
