/**
 * AccountListSheet.ets — 账户管理半屏 Sheet（v2 · 2026-05-23 重设计）
 *
 * 新版结构（自上而下）：
 *   ┌──────────────────────────────────────────┐
 *   │ DragPill                              [+] │
 *   │ 账户管理                                  │
 *   ├──────────────────────────────────────────┤
 *   │ [HeroCard · 当前账户]                     │
 *   │   左：96x160 全身皮肤渲染                  │
 *   │   右：用户名 / 类型 + 令牌 badge / 披风行   │
 *   │   底：[刷新][皮肤详情][移除] 三按钮          │
 *   ├──────────────────────────────────────────┤
 *   │ 其他账户 (n)                              │
 *   │ [行] 头像 用户名 类型 [↕]                  │
 *   │ [行] ...                                  │
 *   └──────────────────────────────────────────┘
 *
 * 核心交互：
 *   - 当前账户在 Hero 卡突出展示，提供"管理动作"（刷新/详情/移除）
 *   - 其他账户列表，单击 → 切换到当前
 *   - HeroCard 的 "皮肤详情" → 弹出 SkinCapeDetailSheet（更大的皮肤+披风预览）
 *   - HeroCard 的 "刷新令牌" → 微软账户走 refresh()，离线账户禁用
 *   - 长按 / X 图标 → 二次确认删除
 *
 * 与 v1 的差异：
 *   - v1 把所有账户平铺成等大的行；选中态只在背景色区分
 *   - v2 引入"当前账户 vs 其他账户"双层视觉，对多账号场景更友好
 *   - v2 把皮肤/披风从子标题字符串提升为完整的视觉预览（用 SkinPreview / CapePreview）
 *
 * 创建日期：2026-05-23（v2 重设计）
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { ThemeColors } from 'commons';
import { Account, AccountType } from 'account';
import { getAccountManager } from 'account';
import { AuthlibInjectorAccount, AccountProfile } from 'account';
import { AddAccountSheet } from './AddAccountSheet';
import { SkinCapeDetailSheet } from './SkinCapeDetailSheet';
import { SkinCanvas3D } from './SkinCanvas3D';
import { CapePreview } from './CapePreview';
import { MinecraftHeadAvatar } from './MinecraftHeadAvatar';
import { AppIconName } from 'commons';
import { AppIcon } from './AppIcon';
import { centerSheetForLayout, sheetWidthForLayout, detailSheetHeightForLayout, largeSheetHeightForLayout } from 'commons';
import { Breakpoint, DeviceForm } from 'commons';

const TAG = 'AccountListSheet';

@Component
export struct AccountListSheet {
  @Prop theme: ThemeColors = {} as ThemeColors;
  @Prop bottomSafeHeight: number = 0;
  /** 顶部安全区高度 —— 给内嵌 sheet 用 */
  @Prop topSafeHeight: number = 0;
  // 一多适配（由 Index 透传）：决定内嵌 AddAccount/SkinDetail sheet 形态。
  // 手机(含横屏)→底部抽屉；平板/PC 宽屏→居中卡片。
  @Prop deviceForm: DeviceForm = DeviceForm.PHONE;
  @Prop appBreakpoint: Breakpoint = Breakpoint.SM;

  /** 用户主动关闭 sheet。 */
  onClose: () => void = () => {};
  /** 列表发生变化（add/select/remove）后回调，让父页刷新当前账户显示。 */
  onAccountsChanged: () => void = () => {};

  // ========= 状态 =========
  @State accounts: Account[] = [];
  @State selectedId: string = '';
  /** 当前账户对象快照 —— 避免 @Builder 里反复跑查找循环。refresh() 会同步刷新它。 */
  @State currentAcc: Account | null = null;
  /** 其他账户列表快照（不包含 currentAcc）—— ForEach 用。 */
  @State otherAccs: Account[] = [];
  @State showAddSheet: boolean = false;
  @State showSkinDetail: boolean = false;
  @State skinDetailAccount: Account | null = null;
  @State pendingDeleteId: string = '';

  // ========= 当前账户的皮肤 / 披风快照（@State 形式）=========
  //
  // 为什么单独再开 @State 而不是直接读 currentAcc.getCapeUrl() ？
  //
  // ArkUI 的 @State 对对象只看引用变化。`account.setActiveCape()` 会**原地修改**
  // Account 的 capeUrl / capeAlias 内部字段，引用没变 → `this.currentAcc = cur`
  // 重赋同一引用时 ArkUI 检测不到改动 → HeroCard 不重新渲染 → CapePreview 还是旧
  // 披风。同时 ArkUI 在 @Builder 里调用 `acc.getCapeUrl()` 这种"非响应式对象的方
  // 法调用"也可能被缓存优化跳过。
  //
  // 把这几个会变的 URL / alias 单独提成 @State 字符串后，ArkUI 按值比对即可可靠
  // 触发 @Prop / @Watch 链路 —— 这是切换披风 / 同步 profile 后 UI 即时刷新的关键。
  //
  // refresh() 末尾会从 currentAcc 同步这四个字段。
  @State currentSkinUrl: string = '';
  @State currentSkinVariant: string = '';
  @State currentCapeUrl: string = '';
  @State currentCapeAlias: string = '';

  // 同理：当前账户的【用户名 / 类型 / UUID / id】也提成 @State。
  // 切换账号时 HeroCard 是带参 @Builder，ArkUI 对其对象参数按引用比对、且 @Builder 内
  // 直接 `acc.getDisplayName()` 这类方法调用不保证重新求值 → 名字/状态徽章切了账号也不刷新。
  // 把它们提成 @State（按值比对）后，HeroCard 内的 Text/Badge 绑定 @State 即可原地刷新。
  @State currentName: string = '';
  @State currentType: AccountType = AccountType.OFFLINE;
  @State currentUuid: string = '';
  @State currentId: string = '';
  // 第三方皮肤站：当前账户的服务器名 + 可切换角色列表（切角色的 UI 依赖它）。
  @State currentServerName: string = '';
  @State currentAuthProfiles: AccountProfile[] = [];
  /** 切换角色进行中的账户 id（防重入 + 转圈提示）。 */
  @State switchingProfileId: string = '';

  /** Refresh 进行中 —— 防止重入；按 id 区分以便未来支持多账户并发刷新。 */
  @State refreshingId: string = '';
  /** 刷新失败提示横幅（短暂显示，3s 自动消失）。 */
  @State refreshErrorMsg: string = '';

  aboutToAppear() {
    this.refresh();
  }

  build() {
    Column() {
      // ===== 顶部标题栏 =====
      Row({ space: 8 }) {
        Text('账户管理')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.theme.textPrimary)
          .layoutWeight(1)
        Row() {
          AppIcon({ name: AppIconName.Plus, iconSize: 22, color: this.theme.primary, weight: FontWeight.Bold })
        }
        .width(36)
        .height(36)
        .borderRadius(18)
        .backgroundColor(this.theme.primaryLight)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .onClick(() => { this.showAddSheet = true; })
      }
      .width('100%')
      .padding({ left: 20, right: 16, top: 12, bottom: 8 })
      .alignItems(VerticalAlign.Center)

      // ===== 主体 =====
      if (this.accounts.length === 0) {
        this.EmptyView();
      } else {
        this.MainScroll();
      }

      // ===== Refresh 错误横幅（绝对定位在底部，3s 自动消失） =====
      if (this.refreshErrorMsg.length > 0) {
        this.ErrorToast(this.refreshErrorMsg);
      }

      // ===== 子 Sheet 锚点（与 Index.ets 模式保持一致） =====
      // 不可见锚点：承载 AddAccountSheet。把 bindSheet 绑在零尺寸 Column 上避免和后面
      // SkinDetailSheet 锚点冲突 —— 同一节点连续多次 bindSheet 在 ArkUI 里不可靠。
      //
      // AddAccountSheet 走 largeSheetHeight (92%)：因为它含 Microsoft OAuth WebView，
      // 80% 在小屏设备会把登录卡片下方挤出大块空白。这是项目里**唯一**走 92% 的 sheet
      // —— 其他详情 / 设置 sheet 都保持 80% 的统一节奏。
      Column().width(0).height(0)
        .bindSheet($$this.showAddSheet, this.AddAccountSheetBuilder(), {
          height: largeSheetHeightForLayout(this.deviceForm, this.appBreakpoint, this.bottomSafeHeight, this.topSafeHeight),
          width: sheetWidthForLayout(this.deviceForm, this.appBreakpoint),
          dragBar: !centerSheetForLayout(this.deviceForm, this.appBreakpoint),
          showClose: false,
          enableOutsideInteractive: false,
          preferType: centerSheetForLayout(this.deviceForm, this.appBreakpoint) ? SheetType.CENTER : SheetType.BOTTOM,
        })

      // 不可见锚点：承载 SkinCapeDetailSheet。皮肤/披风详情走 detailSheetHeight (80%)，
      // 与版本详情 / 模组详情等其他详情类 sheet 视觉一致。
      Column().width(0).height(0)
        .bindSheet($$this.showSkinDetail, this.SkinDetailSheetBuilder(), {
          height: detailSheetHeightForLayout(this.deviceForm, this.appBreakpoint, this.bottomSafeHeight, this.topSafeHeight),
          width: sheetWidthForLayout(this.deviceForm, this.appBreakpoint),
          dragBar: !centerSheetForLayout(this.deviceForm, this.appBreakpoint),
          showClose: false,
          enableOutsideInteractive: false,
          preferType: centerSheetForLayout(this.deviceForm, this.appBreakpoint) ? SheetType.CENTER : SheetType.BOTTOM,
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.bgSecondary)
    .padding({ bottom: this.bottomSafeHeight })
  }

  // ============================================================
  //  Builders
  // ============================================================

  @Builder
  AddAccountSheetBuilder() {
    AddAccountSheet({
      theme: this.theme,
      bottomSafeHeight: this.bottomSafeHeight,
      onSuccess: () => {
        this.showAddSheet = false;
        this.refresh();
        this.onAccountsChanged();
      },
      onClose: () => { this.showAddSheet = false; },
    })
  }

  @Builder
  SkinDetailSheetBuilder() {
    if (this.skinDetailAccount) {
      SkinCapeDetailSheet({
        theme: this.theme,
        bottomSafeHeight: this.bottomSafeHeight,
        account: this.skinDetailAccount,
        onClose: () => { this.showSkinDetail = false; },
        // 披风切换成功后：父 sheet 重读账户状态，让 Hero 卡 cape 行 + 大头像
        // 重渲染。同时 onAccountsChanged() 让外层 Index 页知道。
        onChanged: () => {
          this.refresh();
          this.onAccountsChanged();
        },
      })
    }
  }

  // ============================================================
  //  Empty / Main 视图
  // ============================================================

  @Builder
  EmptyView() {
    Column({ space: 12 }) {
      AppIcon({ name: AppIconName.Person, iconSize: 56, color: this.theme.textHint })
      Text('还没有账户')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.theme.textPrimary)
      Text('点击右上角 + 添加微软正版或离线账户')
        .fontSize(13)
        .fontColor(this.theme.textSecondary)
        .textAlign(TextAlign.Center)
      Button('立即添加')
        .type(ButtonType.Capsule)
        .height(40)
        .fontSize(14)
        .backgroundColor(this.theme.primary)
        .fontColor(this.theme.textOnPrimary)
        .margin({ top: 8 })
        .onClick(() => { this.showAddSheet = true; })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding(20)
  }

  @Builder
  MainScroll() {
    Scroll() {
      Column({ space: 14 }) {
        // 当前账户 Hero 卡 —— currentAcc 在 refresh() 时同步
        if (this.currentAcc !== null) {
          this.HeroCard();
        }

        // 其他账户列表 —— otherAccs 是已过滤掉当前账户的快照
        if (this.otherAccs.length > 0) {
          this.OthersHeader();
          ForEach(this.otherAccs, (acc: Account) => {
            this.AccountRow(acc);
          }, (acc: Account) => acc.id);
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 16 })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  // ============================================================
  //  Hero Card —— 当前账户
  // ============================================================

  @Builder
  HeroCard() {
    Column() {
      // 上半部分：皮肤 + 信息
      Row({ space: 14 }) {
        Stack() {
          SkinCanvas3D({
            skinUrl: this.currentSkinUrl,
            username: this.currentName,
            isOffline: this.currentType === AccountType.OFFLINE,
            slim: this.currentSkinVariant === 'SLIM',
            theme: this.theme,
          })
        }
        .width(96)
        .height(160)
        .borderRadius(this.theme.cardRadius - 2)
        .clip(true)

        Column({ space: 8 }) {
          // 用户名
          Text(this.currentName)
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.theme.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          // 类型 / 状态 badges
          Row({ space: 6 }) {
            this.HeroTypeBadge();
            if (this.currentType === AccountType.MICROSOFT) {
              Row({ space: 4 }) {
                AppIcon({ name: AppIconName.Check, iconSize: 12, color: this.theme.primary, weight: FontWeight.Bold })
                Text('令牌有效')
                  .fontSize(11)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.theme.primary)
              }
              .padding({ left: 6, right: 6, top: 3, bottom: 3 })
              .backgroundColor(this.theme.primaryLight)
              .borderRadius(8)
              .alignItems(VerticalAlign.Center)
            }
          }
          .alignItems(VerticalAlign.Center)

          // UUID hint（只对微软账户显示，offline UUID 是本地派生没意义）
          if (this.currentType === AccountType.MICROSOFT && this.currentUuid.length === 36) {
            Text('ID · ' + this.currentUuid.substring(0, 4) + '…' + this.currentUuid.substring(32))
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.theme.textHint)
              .maxLines(1)
          }

          // 披风行：所有账户都显示。微软账户展示真实披风 / 无披风；离线账户固定"无披风"。
          this.CapeRow();

          // 第三方皮肤站多角色：显示「切换角色」入口（bindMenu 列出全部角色）。
          if (this.currentType === AccountType.AUTHLIB_INJECTOR && this.currentAuthProfiles.length > 1) {
            this.AuthProfileSwitchRow();
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding(14)
      .alignItems(VerticalAlign.Top)

      // 下半部分：动作按钮
      Row({ space: 8 }) {
        this.ActionButton(
          AppIconName.Refresh,
          this.refreshingId === this.currentId ? '刷新中...' : '刷新令牌',
          this.theme.primary,
          (this.currentType === AccountType.MICROSOFT || this.currentType === AccountType.AUTHLIB_INJECTOR) && this.refreshingId !== this.currentId,
          () => { let a = this.currentAcc; if (a !== null) this.refreshAccount(a); },
        );
        this.ActionButton(
          AppIconName.ResourcePack,
          '皮肤详情',
          this.theme.textPrimary,
          true,
          () => {
            this.skinDetailAccount = this.currentAcc;
            this.showSkinDetail = true;
          },
        );
        this.ActionButton(
          AppIconName.Trash,
          this.pendingDeleteId === this.currentId ? '确定删除' : '移除',
          this.theme.error,
          true,
          () => {
            if (this.pendingDeleteId === this.currentId) {
              this.removeAccount(this.currentId);
            } else {
              this.armDelete(this.currentId);
            }
          },
        );
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 10, bottom: 12 })
    }
    .width('100%')
    .backgroundColor(this.theme.bgCard)
    .borderRadius(this.theme.cardRadius)
    .border({ width: { top: 0 }, color: this.theme.divider })
  }

  /**
   * Hero 卡专用类型徽章 —— 无参，直接读 @State this.currentType。
   * 不能复用带参 TypeBadge：ArkUI 对 @Builder 的【基本类型值参数】变化不重渲染
   * （把 currentType 当值参传进去，切账号时徽章不刷新——正是本次要修的坑）。
   * 直接读 @State 字段则能在 currentType 变化时原地更新。
   */
  @Builder
  HeroTypeBadge() {
    Row({ space: 4 }) {
      if (this.currentType === AccountType.MICROSOFT) {
        AppIcon({ name: AppIconName.CheckCircle, iconSize: 12, color: this.theme.success })
        Text('微软正版')
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.success)
      } else if (this.currentType === AccountType.AUTHLIB_INJECTOR) {
        AppIcon({ name: AppIconName.ResourcePack, iconSize: 12, color: this.theme.primary })
        Text(this.currentServerName.length > 0 ? this.currentServerName : '第三方皮肤站')
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.primary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      } else {
        AppIcon({ name: AppIconName.Person, iconSize: 12, color: this.theme.textSecondary })
        Text('离线账户')
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.textSecondary)
      }
    }
    .padding({ left: 6, right: 6, top: 3, bottom: 3 })
    .backgroundColor(this.heroBadgeBg())
    .borderRadius(8)
    .alignItems(VerticalAlign.Center)
  }

  private heroBadgeBg(): ResourceColor {
    if (this.currentType === AccountType.MICROSOFT) return this.theme.successBg;
    if (this.currentType === AccountType.AUTHLIB_INJECTOR) return this.theme.primaryLight;
    return this.theme.bgInput;
  }

  @Builder
  TypeBadge(type: AccountType) {
    Row({ space: 4 }) {
      if (type === AccountType.MICROSOFT) {
        AppIcon({ name: AppIconName.CheckCircle, iconSize: 12, color: this.theme.success })
        Text('微软正版')
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.success)
      } else if (type === AccountType.AUTHLIB_INJECTOR) {
        AppIcon({ name: AppIconName.ResourcePack, iconSize: 12, color: this.theme.primary })
        Text('第三方')
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.primary)
      } else {
        AppIcon({ name: AppIconName.Person, iconSize: 12, color: this.theme.textSecondary })
        Text('离线账户')
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.textSecondary)
      }
    }
    .padding({ left: 6, right: 6, top: 3, bottom: 3 })
    .backgroundColor(this.typeBadgeBg(type))
    .borderRadius(8)
    .alignItems(VerticalAlign.Center)
  }

  private typeBadgeBg(type: AccountType): ResourceColor {
    if (type === AccountType.MICROSOFT) return this.theme.successBg;
    if (type === AccountType.AUTHLIB_INJECTOR) return this.theme.primaryLight;
    return this.theme.bgInput;
  }

  @Builder
  CapeRow() {
    // capeUrl / alias / 文本均走 @State，确保切换披风 / 同步成功后这一行立刻反映。
    Row({ space: 10 }) {
      CapePreview({
        capeUrl: this.currentCapeUrl,
        alias: this.currentCapeAlias,
        theme: this.theme,
        containerWidth: 32,
        containerHeight: 48,
        showLabel: false,
      })
      Column({ space: 2 }) {
        Text(this.capeTitle())
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.capeSubtitle())
          .fontSize(11)
          .fontWeight(FontWeight.Regular)
          .fontColor(this.theme.textSecondary)
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      AppIcon({ name: AppIconName.ChevronRight, iconSize: 16, color: this.theme.textHint })
    }
    .width('100%')
    .padding(10)
    .backgroundColor(this.theme.bgInput)
    .borderRadius(12)
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.skinDetailAccount = this.currentAcc;
      this.showSkinDetail = true;
    })
  }

  @Builder
  AuthProfileSwitchRow() {
    Row({ space: 8 }) {
      AppIcon({ name: AppIconName.Person, iconSize: 14, color: this.theme.textSecondary })
      Text(this.switchingProfileId === this.currentId
        ? '切换角色中...'
        : '角色：' + this.currentName + ' · 点击切换')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.theme.textSecondary)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      AppIcon({ name: AppIconName.ChevronDown, iconSize: 14, color: this.theme.textHint })
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 7, bottom: 7 })
    .margin({ top: 6 })
    .backgroundColor(this.theme.bgInput)
    .borderRadius(10)
    .alignItems(VerticalAlign.Center)
    .bindMenu(this.ProfileMenu())
  }

  @Builder
  ProfileMenu() {
    Menu() {
      ForEach(this.currentAuthProfiles, (p: AccountProfile) => {
        MenuItem({
          content: p.name,
          // 当前角色前打勾（用 startIcon 不方便，用 content 后缀标记）
        })
          .selected(p.id === this.currentUuid)
          .enabled(this.switchingProfileId.length === 0)
          .onClick(() => {
            if (p.id !== this.currentUuid) this.switchToProfile(p.id);
          })
      }, (p: AccountProfile) => p.id)
    }
  }

  @Builder
  ActionButton(icon: AppIconName, label: string, color: ResourceColor, enabled: boolean, action: () => void) {
    Row({ space: 6 }) {
      AppIcon({ name: icon, iconSize: 14, color: color })
      Text(label)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(color)
        .maxLines(1)
    }
    .layoutWeight(1)
    .height(36)
    .backgroundColor(this.theme.bgInput)
    .borderRadius(10)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .opacity(enabled ? 1.0 : 0.45)
    .onClick(() => {
      if (enabled) action();
    })
  }

  // ============================================================
  //  其他账户列表
  // ============================================================

  @Builder
  OthersHeader() {
    Row({ space: 8 }) {
      Text('其他账户')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.theme.textSecondary)
        .layoutWeight(1)
      Text(this.otherAccs.length + ' 个')
        .fontSize(12)
        .fontWeight(FontWeight.Regular)
        .fontColor(this.theme.textHint)
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 6, bottom: 2 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  AccountRow(acc: Account) {
    Row({ space: 12 }) {
      // 头像：MinecraftHeadAvatar 内部 fetch + 解码 + fallback 字母都封装好了。
      // 离线账户 / UUID 不合法 → 传 '' 让 Avatar 走纯字母 fallback。
      // 注：原版用 `Image(httpsUrl)` 已废弃，OpenHarmony 5 / API 14 静默不发请求 quirk
      // 见 RemoteImage.ets / RemoteImageCache.ets 顶部的考古注释。
      MinecraftHeadAvatar({
        uuid: this.shouldFetchAvatar(acc) ? acc.uuid : '',
        diameter: 44,
        fallbackLetter: this.avatarLetter(acc),
        bgColor: this.theme.bgInput,
        letterColor: this.theme.textPrimary,
      })

      // 文字
      Column({ space: 4 }) {
        Text(acc.getDisplayName())
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 6 }) {
          this.TypeBadge(acc.type);
          if (acc.type === AccountType.MICROSOFT && (acc.getCapeAlias() ?? '').length > 0) {
            Text('披风：' + (acc.getCapeAlias() ?? ''))
              .fontSize(11)
              .fontColor(this.theme.textHint)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(VerticalAlign.Center)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 切换按钮
      Row() {
        AppIcon({ name: AppIconName.ArrowUpRight, iconSize: 16, color: this.theme.primary })
      }
      .width(32)
      .height(32)
      .borderRadius(8)
      .backgroundColor(this.theme.primaryLight)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(10)
    .backgroundColor(this.theme.bgCard)
    .borderRadius(this.theme.cardRadius)
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.selectAccount(acc.id);
    })
    .gesture(
      LongPressGesture({ repeat: false, duration: 600 })
        .onAction(() => {
          this.armDelete(acc.id);
        })
    )
  }

  @Builder
  ErrorToast(msg: string) {
    Row() {
      Row({ space: 8 }) {
        AppIcon({ name: AppIconName.Error, iconSize: 16, color: this.theme.error })
        Text(msg)
          .fontSize(12)
          .fontColor(this.theme.error)
          .layoutWeight(1)
      }
      .padding(12)
      .backgroundColor(this.theme.errorBg)
      .borderRadius(10)
      .layoutWeight(1)
    }
    .width('92%')
    .margin({ bottom: 12 })
    .justifyContent(FlexAlign.Center)
  }

  // ============================================================
  //  动作
  // ============================================================

  /**
   * 从 AccountManager 同步全部状态。同时计算 currentAcc / otherAccs 快照
   * 喂给 @Builder（避免 @Builder 内反复跑 O(n) 线性查找）。
   */
  private refresh(): void {
    let am = getAccountManager();
    this.accounts = am.list();
    let sel = am.getSelectedId();
    // 选中失效：fallback 到第一个账户（与 AccountManager.getSelected 保持一致语义）
    if (sel.length === 0 && this.accounts.length > 0) {
      sel = this.accounts[0].id;
    }
    this.selectedId = sel;

    // 计算 current / others 快照
    let cur: Account | null = null;
    let others: Account[] = [];
    for (let acc of this.accounts) {
      if (acc.id === sel) {
        cur = acc;
      } else {
        others.push(acc);
      }
    }
    this.currentAcc = cur;
    this.otherAccs = others;

    // 同步当前账户的皮肤 / 披风字段到 @State 字符串。这才是 HeroCard 内 SkinCanvas3D
    // / CapePreview 真正读到的"响应式"输入 —— 详见上方 @State 字段定义处的注释。
    if (cur !== null) {
      this.currentSkinUrl = cur.getSkinUrl() ?? '';
      this.currentSkinVariant = cur.getSkinVariant() ?? '';
      this.currentCapeUrl = cur.getCapeUrl() ?? '';
      this.currentCapeAlias = cur.getCapeAlias() ?? '';
      this.currentName = cur.getDisplayName();
      this.currentType = cur.type;
      this.currentUuid = cur.uuid;
      this.currentId = cur.id;
      // 第三方皮肤站专属：服务器名 + 可切换角色列表（向下转型读取）
      if (cur.type === AccountType.AUTHLIB_INJECTOR) {
        let authAcc = cur as AuthlibInjectorAccount;
        this.currentServerName = authAcc.getServerName();
        this.currentAuthProfiles = authAcc.getAvailableProfiles();
      } else {
        this.currentServerName = '';
        this.currentAuthProfiles = [];
      }
    } else {
      this.currentSkinUrl = '';
      this.currentSkinVariant = '';
      this.currentCapeUrl = '';
      this.currentCapeAlias = '';
      this.currentName = '';
      this.currentType = AccountType.OFFLINE;
      this.currentUuid = '';
      this.currentId = '';
      this.currentServerName = '';
      this.currentAuthProfiles = [];
    }

    hilog.info(0x0000, TAG,
      'refresh: %{public}d accounts, selected=%{public}s, others=%{public}d, capeUrl=%{public}s',
      this.accounts.length, this.selectedId, others.length,
      this.currentCapeUrl.length > 0 ? '<set>' : '<empty>');
  }

  private selectAccount(id: string): void {
    let am = getAccountManager();
    am.select(id);
    this.pendingDeleteId = '';
    // 走 refresh() 而不是直接赋值 selectedId，是为了顺手刷新 currentAcc / otherAccs
    // 快照 —— 这样 HeroCard 立即切到新账户，列表的"其他账户"行也自动重排。
    this.refresh();
    this.onAccountsChanged();
    hilog.info(0x0000, TAG, 'select: %{public}s', id);
  }

  private removeAccount(id: string): void {
    let am = getAccountManager();
    am.remove(id);
    this.pendingDeleteId = '';
    this.refresh();
    this.onAccountsChanged();
    hilog.info(0x0000, TAG, 'remove: %{public}s', id);
  }

  private armDelete(id: string): void {
    this.pendingDeleteId = id;
    setTimeout(() => {
      if (this.pendingDeleteId === id) {
        this.pendingDeleteId = '';
      }
    }, 3000);
  }

  /**
   * 强制刷新令牌（仅对微软账户）。失败 → 短暂 toast，3s 自动消失。
   * 成功 → 重新拉账户列表（refresh() 会同步皮肤/披风快照）。
   */
  private async refreshAccount(acc: Account): Promise<void> {
    if (acc.type !== AccountType.MICROSOFT && acc.type !== AccountType.AUTHLIB_INJECTOR) return;
    if (this.refreshingId.length > 0) return;
    this.refreshingId = acc.id;
    this.refreshErrorMsg = '';
    try {
      // MicrosoftAccount.refresh() 会绕过 isMcTokenFresh 短路（这里强制刷只对未过期的也重跑）
      // 临时方案：调一次 refresh()，若 token 还在有效期会立即返回，不报错（用户友好但
      // 不是"强制刷"）；要真正强制可以在 MicrosoftAccount 加 forceRefresh 参数（M3 计划）
      await acc.refresh();
      // 刷新可能轮换 token（Microsoft）/ accessToken+clientToken（第三方），写回存储
      try {
        await getAccountManager().persistOne(acc);
      } catch (e) {
        hilog.warn(0x0000, TAG, 'persistOne after refresh failed: %{public}s', (e as Error).message);
      }
      // 重新拉列表 → SkinPreview / CapePreview 用最新 url 重新 attach Image
      this.refresh();
      this.onAccountsChanged();
      hilog.info(0x0000, TAG, 'refresh succeeded for id=%{public}s', acc.id);
    } catch (e) {
      let msg = (e as Error).message;
      this.refreshErrorMsg = '刷新失败：' + msg;
      hilog.error(0x0000, TAG, 'refresh failed for id=%{public}s: %{public}s', acc.id, msg);
      setTimeout(() => {
        if (this.refreshErrorMsg === '刷新失败：' + msg) {
          this.refreshErrorMsg = '';
        }
      }, 3000);
    } finally {
      this.refreshingId = '';
    }
  }

  /**
   * 切换第三方皮肤站账户的当前角色（决策 #3）。
   * 走 AuthlibInjectorAccount.switchProfile（账密重登 + 绑定目标角色）→ 持久化 → 刷新 UI。
   */
  private async switchToProfile(profileId: string): Promise<void> {
    if (this.switchingProfileId.length > 0) return;
    let acc = this.currentAcc;
    if (acc === null || acc.type !== AccountType.AUTHLIB_INJECTOR) return;
    this.switchingProfileId = acc.id;
    this.refreshErrorMsg = '';
    try {
      let authAcc = acc as AuthlibInjectorAccount;
      await authAcc.switchProfile(profileId);
      await getAccountManager().persistOne(authAcc);
      this.refresh();
      this.onAccountsChanged();
      hilog.info(0x0000, TAG, 'switchProfile ok for id=%{public}s', acc.id);
    } catch (e) {
      let msg = (e as Error).message;
      this.refreshErrorMsg = '切换角色失败：' + msg;
      hilog.error(0x0000, TAG, 'switchProfile failed: %{public}s', msg);
      setTimeout(() => {
        if (this.refreshErrorMsg === '切换角色失败：' + msg) this.refreshErrorMsg = '';
      }, 3000);
    } finally {
      this.switchingProfileId = '';
    }
  }

  // ============================================================
  //  Helpers
  // ============================================================

  private avatarLetter(acc: Account): string {
    let n = acc.getDisplayName();
    if (!n || n.length === 0) return '?';
    return n.charAt(0).toUpperCase();
  }

  private capeTitle(): string {
    if (this.currentCapeAlias.length > 0) return '披风 · ' + this.currentCapeAlias;
    if (this.currentCapeUrl.length > 0) return '披风 · 已佩戴';
    return '无披风';
  }

  private capeSubtitle(): string {
    if (this.currentCapeUrl.length > 0) return '点击查看大图与切换';
    return '当前账户没有可用披风';
  }

  /**
   * 是否应该让 MinecraftHeadAvatar 去拉 Crafatar。
   *
   * 离线账户 → 传 '' 走字母 fallback。
   * 微软账户的 uuid 可能是 32 位无连字符或 36 位 dash 格式（早期版本 vs
   * formatCanonicalUuid 之后存的）。Crafatar 两种都接受。
   */
  private shouldFetchAvatar(acc: Account): boolean {
    if (acc.type !== AccountType.MICROSOFT) return false;
    return acc.uuid.length === 32 || acc.uuid.length === 36;
  }
}
