/**
 * 呈现颜色遵循父层主题快照：操作文字与焦点独立于按钮填充，状态小字独立于进度填充。
 * 本域不读取主题偏好，不改变原事件、任务或账户生命周期；资源类别与第三方品牌保持独立。
 */
/**
 * 账号管理半模态：当前身份、外观入口和切换列表分区显示。
 *
 * 当前账号的刷新、完整信息及移除集中在内部管理页；第三方多角色沿用原
 * switchProfile 持久化流程。内部页面复用现有标题和同一 Sheet，既不放大容器，
 * 登录样式保持原有结构，手机嵌套面板与外层共同遵循已保存的默认高度。
 * 账号选择、删除和外观更新只发布持久化确认结果，离开后的异步续体仍须退役。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { ThemeColors } from 'commons';
import { getTaskActivityOwner } from 'feature_core';
import { Account, AccountType } from 'account';
import { getAccountManager } from 'account';
import { AuthlibInjectorAccount, AccountProfile } from 'account';
import { ProductQaAccounts } from 'entry/ProductQaAccounts';
import { util } from '@kit.ArkTS';
import { LauncherSkillBus, SkillFields } from '../launcherskill/LauncherSkillBus';
import { AccountRemovalChoice, AccountSheetActions, AddAccountActions } from '../runtime/AccountSheetActions';
import { AddAccountSheet } from './AddAccountSheet';
import { SkinCapeDetailSheet } from './SkinCapeDetailSheet';
import { SkinCanvas3D } from './SkinCanvas3D';
import { MinecraftHeadAvatar } from './MinecraftHeadAvatar';
import { AppIconName } from 'commons';
import { AppIcon } from './AppIcon';
import { ImmersiveTitleScaffold } from './ImmersiveTitleScaffold';
import { centerSheetForLayout, sheetWidthForLayout, detailSheetHeightForLayout, largeSheetHeightForLayout } from 'commons';
import { Breakpoint, DeviceForm } from 'commons';

const TAG = 'AccountListSheet';

@Component
export struct AccountListSheet {
  /** 观察确认比例，使嵌套的登录和外观详情在下一次打开时使用最新选择。 */
  @StorageProp('phoneSheetHeightPercent') private phoneSheetHeightPercent_: number = 80;
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
  /** 更多入口只在当前半模态内切换正文，不创建额外模态或改动父层宽高。 */
  @State showAccountSettings: boolean = false;
  /** 只描述本地可恢复凭据；不能把 isUsable 的 true 误写成远端令牌仍有效。 */
  @State currentLoginState: string = 'checking';
  private loginStateEpoch: number = 0;
  /** 同一账号重复打开确认也要区分，避免上一枚弹窗的迟到确认复用新的授权。 */
  private deleteConfirmationEpoch: number = 0;
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
  /** 账号选择/移除等待持久确认期间禁用重复动作，避免界面先显示未确认的状态。 */
  @State accountMutationId: string = '';
  @State accountMutationAction: string = '';
  private accountMutationEpoch: number = 0;
  private alive: boolean = false;
  /** 刷新失败提示横幅（短暂显示，3s 自动消失）。 */
  @State refreshErrorMsg: string = '';

  // 随当前面板分配匿名账号引用；对象被替换或重新打开后不得误操作同编号的另一份账号。
  private accountRefs_: WeakMap<Account, string> = new WeakMap<Account, string>();
  private roleRefs_: Map<string,string> = new Map<string,string>();
  private loginRef_: string = '';
  private loginState_: string = '';
  private loginPhase_: string = '';
  private removalState_: string = 'idle';
  private removalRef_: string = '';
  private closeAck_: (() => void) | undefined = undefined;
  private loginAccount_: Account | undefined = undefined;

  private accountRef_(acc: Account): string {
    let ref = this.accountRefs_.get(acc);
    if (!ref) { ref = util.generateRandomUUID(); this.accountRefs_.set(acc, ref); }
    return ref;
  }

  private loginOutcome_(ref: string, state: string, id: string): void {
    if (!this.alive || !ref || ref !== this.loginRef_ || this.loginState_ !== 'needsUser') return;
    this.loginState_ = state; this.loginPhase_ = state;
    if (state === 'ready') {
      this.loginAccount_ = getAccountManager().findById(id);
      if (!this.loginAccount_) this.loginState_ = 'unknown';
    }
  }

  private async playerAccountAction_(method: string, args: SkillFields): Promise<SkillFields> {
    const manager = getAccountManager();
    if (!manager.isReady() || !this.alive) return { 'state': 'unavailable' };
    const accounts = manager.list();
    if (method === 'listPlayerAccounts') {
      const selected = manager.getSelectedId() || (accounts.length ? accounts[0].id : '');
      return { 'state': 'ready', 'removalState': this.removalState_, 'removalRef': this.removalRef_,
        'accounts': accounts.map((a: Account): SkillFields => ({ 'accountRef': this.accountRef_(a), 'type': a.type, 'selected': a.id === selected })) };
    }
    if (method === 'readPlayerLogin') {
      if (!this.loginRef_ || args['loginRef'] !== this.loginRef_) return { 'state': 'unknown' };
      const result: SkillFields = { 'state': this.loginState_, 'loginRef': this.loginRef_, 'phase': this.loginPhase_ };
      const saved = this.loginAccount_;
      if (saved && manager.findById(saved.id) === saved) result['accountRef'] = this.accountRef_(saved);
      return result;
    }
    if (this.busy_() || this.showAddSheet || this.showSkinDetail || this.pendingDeleteId.length > 0) return { 'state': 'busy' };
    if (method === 'closePlayerAccounts') {
      return new Promise<SkillFields>((resolve): void => {
        const timer = setTimeout((): void => { this.closeAck_=undefined; resolve({ 'state':'unknown' }); },3000);
        this.closeAck_=():void => { clearTimeout(timer); this.closeAck_=undefined; resolve({ 'state':'ready','closed':true }); };
        this.onClose();
      });
    }
    if (method === 'addOfflinePlayer' || method === 'beginPlayerLogin') {
      const name = String(args['playerName'] ?? '');
      if (method === 'addOfflinePlayer' && (name.length>16 || /[\u0000-\u001f\u007f]/.test(name))) return { 'state': 'failed', 'reason': 'invalidPlayerName' };
      const ref = util.generateRandomUUID();
      this.loginRef_ = ref; this.loginState_ = 'needsUser'; this.loginPhase_='opening'; this.loginAccount_ = undefined;
      if (method === 'beginPlayerLogin') {
        LauncherSkillBus.followUserCondition(method, (): boolean => this.alive && this.loginRef_ === ref && this.loginState_ === 'needsUser');
      }
      const command: SkillFields = { 'loginRef': ref, 'provider': String(args['provider'] ?? ''), 'playerName': name };
      const response = await LauncherSkillBus.forward(this,'playerForm',method,command);
      if (response['state'] !== 'needsUser' && this.loginState_ === 'needsUser') this.loginState_ = String(response['state']);
      if (method === 'addOfflinePlayer' && this.loginAccount_) response['accountRef'] = this.accountRef_(this.loginAccount_);
      response['loginRef'] = ref;
      return response;
    }
    const account = accounts.find((a: Account): boolean => this.accountRefs_.get(a) === args['accountRef'] && typeof args['accountRef'] === 'string');
    if (!account) return { 'state': 'failed', 'reason': 'staleAccount' };
    if (method === 'selectPlayerAccount') {
      const ok = await this.commitAccountMutation_(account.id, false, account);
      return { 'state': ok && manager.findById(account.id) === account && manager.getSelectedId() === account.id ? 'ready' : 'unknown' };
    }
    if (method === 'checkPlayerAccount') {
      const usable = account.type === AccountType.OFFLINE ? true : await account.isUsable();
      if (manager.findById(account.id) !== account) return { 'state': 'unknown' };
      return { 'state': 'ready', 'type': account.type, 'credential': account.type === AccountType.OFFLINE ? 'offline' : (usable ? 'local' : 'loginRequired') };
    }
    if (method === 'requestRemovePlayer') {
      this.armDelete(account.id);
      return { 'state': this.pendingDeleteId === account.id ? 'needsUser' : 'unavailable', 'accountRef': this.accountRef_(account) };
    }
    if (this.currentId !== account.id || manager.getSelected() !== account) return { 'state': 'failed', 'reason': 'selectAccountFirst' };
    if (method === 'showPlayerProfile') { this.showAccountInformation_(); return { 'state': 'needsUser' }; }
    if (method === 'refreshPlayerCredentials') {
      if (account.type === AccountType.OFFLINE) return { 'state': 'unavailable' };
      return { 'state': await this.refreshAccount(account) ? 'ready' : 'unknown' };
    }
    if (account.type === AccountType.AUTHLIB_INJECTOR && (method === 'readPlayerRoles' || method === 'choosePlayerRole')) {
      const profiles = (account as AuthlibInjectorAccount).getAvailableProfiles();
      const roles: SkillFields[] = [];
      const prefix = this.accountRef_(account) + ':';
      for (const profile of profiles) {
        const key = prefix + profile.id;
        let ref = this.roleRefs_.get(key);
        if (!ref) { ref = util.generateRandomUUID(); this.roleRefs_.set(key,ref); }
        if (method === 'choosePlayerRole' && ref === args['roleRef']) {
          const ok = await this.switchToProfile(profile.id);
          return { 'state': ok && manager.findById(account.id) === account && account.uuid === profile.id ? 'ready' : 'unknown', 'roleRef': ref };
        }
        roles.push({ 'roleRef': ref, 'selected': profile.id === account.uuid });
      }
      if (method === 'choosePlayerRole') return { 'state':'failed','reason':'roleChanged' };
      this.showAccountSettings = true;
      return { 'state':'ready', 'roles': roles };
    }
    if (method === 'openPlayerAppearance') {
      this.openAppearance_();
      return { 'state': this.showSkinDetail ? 'needsUser' : 'unavailable', 'hasSkin': this.currentSkinUrl.length > 0,
        'hasCape': this.currentCapeUrl.length > 0, 'model': this.currentSkinVariant };
    }
    return { 'state': 'failed', 'reason': 'unknownOperation' };
  }

  aboutToAppear() {
    this.accountRefs_ = new WeakMap<Account,string>(); this.roleRefs_.clear();
    this.loginRef_ = ''; this.loginState_ = ''; this.loginAccount_ = undefined;
    LauncherSkillBus.bind('accounts',this,(method: string, args: SkillFields): Promise<SkillFields> => this.playerAccountAction_(method,args), (): boolean => this.alive);
    LauncherSkillBus.bindOpener('playerForm',this, (_method: string, args: SkillFields): boolean => {
      if (!this.alive || this.busy_() || this.showAddSheet || this.showSkinDetail || this.pendingDeleteId || args['loginRef'] !== this.loginRef_) return false;
      this.showAddSheet = true; return true;
    });
    this.alive = true;
    this.accountMutationEpoch++;
    this.accountMutationId = ''; this.accountMutationAction = '';
    this.refreshingId = ''; this.switchingProfileId = ''; this.refreshErrorMsg = '';
    this.refresh();
    ProductQaAccounts.bind(this, (): AccountSheetActions => ({
      ready: (): boolean => this.alive && !this.busy_() && !this.showAddSheet && !this.showSkinDetail
        && AppStorage.get<boolean>('appInForeground') === true,
      hasConfirmation: (): boolean => this.pendingDeleteId.length > 0,
      openAdd: (): void => { this.showAddSheet = true; },
      close: (): void => { this.onClose(); },
      select: (target: Account): Promise<boolean> => this.commitAccountMutation_(target.id, false, target),
      prepareRemove: (id: string): AccountRemovalChoice | undefined => this.prepareRemoval_(id),
      confirmRemove: (choice: AccountRemovalChoice): Promise<boolean> => this.confirmRemoval_(choice),
      cancelRemove: (choice: AccountRemovalChoice): boolean => this.cancelRemoval_(choice)
    }));
  }

  /** 只退役本页状态回调，已经提交的账号操作仍需通知外层首页重读确认结果。 */
  aboutToDisappear(): void {
    this.closeAck_?.();
    LauncherSkillBus.unbind('accounts', this); LauncherSkillBus.unbindOpener('playerForm', this);
    ProductQaAccounts.unbind(this); this.alive = false; this.accountMutationEpoch++; this.loginStateEpoch++; this.deleteConfirmationEpoch++; this.pendingDeleteId = '';
  }

  build() {
    Column() {
      // 主列表标题与圆形新增入口共享真实标题宿主；新增仍只打开原 AddAccount 子 Sheet。
      // X 继续调用父层 onClose，选择账户、刷新令牌、皮肤预览与自动登录均不由标题接管。
      ImmersiveTitleScaffold({ title: this.showAccountSettings
          ? (this.currentType === AccountType.AUTHLIB_INJECTOR ? '第三方账号' : '账号管理') : '账户管理',
        theme: this.theme, surfaceColor: this.theme.bgPrimary,
        modal: !this.showAccountSettings, showBack: this.showAccountSettings, showClose: true,
        backLabel: '返回账户管理', onBack: (): void => { this.showAccountSettings = false; },
        closeLabel: '关闭账户管理', onClose: (): void => { this.onClose(); },
        menuActions: this.showAccountSettings ? [] : [{ id: 'add-account', label: '新增账户', icon: AppIconName.Plus, enabled: this.accountMutationId.length === 0 && this.refreshingId.length === 0 && this.switchingProfileId.length === 0 }],
        onMenuAction: (id: string): void => { if (id === 'add-account' && !this.busy_()) this.showAddSheet = true; },
        content: (): void => { this.ImmersiveTitleContent1_(); }
      })

      // ===== 子 Sheet 锚点（与 Index.ets 模式保持一致） =====
      // 不可见锚点：承载 AddAccountSheet。把 bindSheet 绑在零尺寸 Column 上避免和后面
      // SkinDetailSheet 锚点冲突 —— 同一节点连续多次 bindSheet 在 ArkUI 里不可靠。
      //
      // 登录内容含 Microsoft OAuth WebView：手机使用用户高度，非手机保留原 92% 策略，
      // WebView 继续填充面板剩余空间；用户降低手机比例时内容仍由原登录页滚动处理。
      Column().width(0).height(0)
        .bindSheet($$this.showAddSheet, this.AddAccountSheetBuilder(), {
          height: largeSheetHeightForLayout(this.deviceForm, this.appBreakpoint, this.bottomSafeHeight, this.topSafeHeight, this.phoneSheetHeightPercent_),
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
          height: detailSheetHeightForLayout(this.deviceForm, this.appBreakpoint, this.bottomSafeHeight, this.topSafeHeight, this.phoneSheetHeightPercent_),
          width: sheetWidthForLayout(this.deviceForm, this.appBreakpoint),
          dragBar: !centerSheetForLayout(this.deviceForm, this.appBreakpoint),
          showClose: false,
          enableOutsideInteractive: false,
          preferType: centerSheetForLayout(this.deviceForm, this.appBreakpoint) ? SheetType.CENTER : SheetType.BOTTOM,
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.bgPrimary)
    .padding({ bottom: this.bottomSafeHeight })
  }

  // ============================================================
  //  Builders
  // ============================================================

  @Builder
  AddAccountSheetBuilder() {
    AddAccountSheet({
      onActionsReady: (actions: AddAccountActions): void => { ProductQaAccounts.addShown(this, actions); },
      onPlayerLoginOutcome: (ref: string, state: string, id: string): void => { this.loginOutcome_(ref, state, id); },
      onPlayerLoginPhase: (ref: string, phase: string): void => { if (this.loginState_==='needsUser' && ref===this.loginRef_) this.loginPhase_=phase; },
      theme: this.theme,
      bottomSafeHeight: this.bottomSafeHeight,
      onSuccess: () => {
        this.showAddSheet = false;
        this.showAccountSettings = false;
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
          // 离线编辑采用不可变账号替换，详情入口也必须更新为列表里的新实例。
          const detailId = this.skinDetailAccount?.id ?? '';
          this.skinDetailAccount = getAccountManager().findById(detailId) ?? null;
          this.refresh();
          this.onAccountsChanged();
        },
      })
    }
  }

  // ============================================================
  //  Empty / Main 视图
  // ============================================================

  /** 空态仍通过原 AddAccountSheet 添加账号，不在本次重建任何登录表单。 */
  @Builder
  EmptyView() {
    Column({ space: 20 }) {
      Row() {
        AppIcon({ name: AppIconName.Person, iconSize: 32, color: this.theme.actionText })
      }.width(72).height(72).justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
        .backgroundColor(this.theme.primaryLight).borderRadius(24)
      Text('添加你的第一个账号').fontSize(22).fontWeight(FontWeight.Medium)
        .fontColor(this.theme.textPrimary).textAlign(TextAlign.Center)
      Text('登录微软或皮肤站账号，也可以创建离线账号开始本地游戏。')
        .fontSize(16).fontColor(this.theme.textSecondary).textAlign(TextAlign.Center)
      Button('添加账号').type(ButtonType.Capsule).height(48).width('100%')
        .fontSize(16).fontWeight(FontWeight.Medium)
        .backgroundColor(this.theme.actionPrimary).fontColor(this.theme.textOnPrimary)
        .onClick((): void => { this.showAddSheet = true; })
    }.width('100%').layoutWeight(1).padding(32)
      .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
  }

  /**
   * 正文分成当前账号和统一切换列表。内容仍可滚动，长名称、字号放大和更多账号
   * 不依赖画稿的固定行高；外层 80%／居中 520、600vp 的尺寸策略保持不变。
   */
  @Builder
  MainScroll() {
    Scroll() {
      Column({ space: 24 }) {
        if (this.currentAcc !== null) {
          Column({ space: 8 }) {
            Text('当前使用').fontSize(14).fontColor(this.theme.textSecondary)
              .width('100%').padding({ left: 4, right: 4 })
            this.HeroCard();
          }.width('100%').alignItems(HorizontalAlign.Start)
        }
        if (this.otherAccs.length > 0) {
          Column({ space: 8 }) {
            this.OthersHeader();
            Column() {
              ForEach(this.otherAccs, (acc: Account, index: number) => {
                if (index > 0) {
                  this.GroupDivider_();
                }
                this.AccountRow(acc);
              }, (acc: Account): string => acc.id)
            }.width('100%').backgroundColor(this.theme.bgCard).borderRadius(20).clip(true)
          }.width('100%')
          Text('点击账号即可切换，外观随账号保留。')
            .fontSize(14).fontColor(this.theme.textHint).width('100%')
        }
      }.width('100%').padding({ left: 16, right: 16, top: 4, bottom: 20 })
    }.layoutWeight(1).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
  }

  /** 组内只有一条分隔线，不为每个账号再嵌套独立卡片。 */
  @Builder
  private GroupDivider_() {
    Row().width('100%').height(0.5).backgroundColor(this.theme.divider)
  }

  /** 当前身份独占一行，头像和更多操作均不挤占外观说明的文字列。 */
  @Builder
  HeroCard() {
    Column() {
      this.CurrentIdentity_();
      this.GroupDivider_();
      this.AppearanceEntry_();
    }.width('100%').backgroundColor(this.theme.bgCard).borderRadius(20).clip(true)
  }

  /**
   * 身份全部读取独立的 @State 快照，切账号、改名和换肤都会刷新原位。
   * 更多按钮使用真实 Button，44vp 命中范围同时覆盖触摸、焦点和键盘操作。
   */
  @Builder
  private CurrentIdentity_() {
    Row({ space: 12 }) {
      MinecraftHeadAvatar({ uuid: this.currentType === AccountType.MICROSOFT ? this.currentUuid : '',
        skinUrl: this.currentSkinUrl, diameter: 52, fallbackLetter: this.currentName.charAt(0).toUpperCase(),
        bgColor: this.theme.bgInput, letterColor: this.theme.textPrimary, cornerRadius: 8 })
      Column({ space: 4 }) {
        Text(this.currentName).fontSize(22).fontWeight(FontWeight.Medium)
          .fontColor(this.theme.textPrimary).width('100%').maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.currentSource_()).fontSize(14).fontColor(this.theme.textSecondary)
          .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.currentType !== AccountType.OFFLINE) {
          Text(this.loginStateText_()).fontSize(14)
            .fontColor(this.currentLoginState === 'usable' ? this.theme.successText : this.theme.textSecondary)
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (!this.showAccountSettings) {
      Button({ type: ButtonType.Circle }) {
        AppIcon({ name: AppIconName.More, iconSize: 20, color: this.theme.textPrimary })
      }.width(44).height(44).padding(0).backgroundColor(this.theme.bgCard)
        .accessibilityText('管理当前账号').id('account-current-more')
        .enabled(this.accountMutationId.length === 0 && this.refreshingId.length === 0 && this.switchingProfileId.length === 0)
        .onClick((): void => { if (!this.busy_()) this.showAccountSettings = true; })
      }
    }.width('100%').padding(16).alignItems(VerticalAlign.Center)
  }

  /** 外观入口独立提供完整角色和说明，点击继续使用原来的详情／离线编辑子层。 */
  @Builder
  private AppearanceEntry_() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 20 }) {
        Stack() {
          SkinCanvas3D({ skinUrl: this.currentSkinUrl, username: this.currentName,
            isOffline: this.currentType === AccountType.OFFLINE, slim: this.currentSkinVariant === 'SLIM', theme: this.theme })
        }.width(76).height(112).backgroundColor(this.theme.bgInput).borderRadius(12).clip(true)
        Column({ space: 6 }) {
          Text(this.currentType === AccountType.OFFLINE ? '编辑账号与外观' : '皮肤与披风')
            .fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.theme.textPrimary).width('100%')
          Text(this.appearanceSummary_()).fontSize(14).fontColor(this.theme.textSecondary)
            .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.currentType === AccountType.OFFLINE ? '更改名称、皮肤或披风' : '查看外观与披风')
            .fontSize(14).fontColor(this.theme.actionText).width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        AppIcon({ name: AppIconName.ChevronRight, iconSize: 20, color: this.theme.textSecondary })
      }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)
    }.width('100%').padding(0).constraintSize({ minHeight: 136 }).backgroundColor(this.theme.bgCard)
      .enabled(this.accountMutationId.length === 0 && this.refreshingId.length === 0 && this.switchingProfileId.length === 0)
      .id('account-appearance-entry').onClick((): void => { this.openAppearance_(); })
  }

  /** 其他账号的来源仅陈述已保存类型，不额外联网验证或伪造“令牌有效”。 */
  @Builder
  OthersHeader() {
    Row() {
      Text('切换账号').fontSize(14).fontColor(this.theme.textSecondary).layoutWeight(1)
      Text('其他 ' + this.otherAccs.length + ' 个').fontSize(14).fontColor(this.theme.textHint)
    }.width('100%').padding({ left: 4, right: 4 }).alignItems(VerticalAlign.Center)
  }

  /** 整行切换沿用持久化屏障；长按仅打开明确确认，不会触碰头像或新建登录页。 */
  @Builder
  AccountRow(acc: Account) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        MinecraftHeadAvatar({ uuid: this.shouldFetchAvatar(acc) ? acc.uuid : '', skinUrl: acc.getSkinUrl() ?? '',
          diameter: 44, fallbackLetter: this.avatarLetter(acc), bgColor: this.theme.bgInput,
          letterColor: this.theme.textPrimary, cornerRadius: 8 })
        Column({ space: 4 }) {
          Text(acc.getDisplayName()).fontSize(16).fontWeight(FontWeight.Medium)
            .fontColor(this.theme.textPrimary).width('100%').maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.accountSource_(acc)).fontSize(14).fontColor(this.theme.textSecondary)
            .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (this.accountMutationAction === 'select' && this.accountMutationId === acc.id) {
          LoadingProgress().width(20).height(20).color(this.theme.actionText)
        } else {
          AppIcon({ name: AppIconName.ArrowRight, iconSize: 20, color: this.theme.textSecondary })
        }
      }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 }).alignItems(VerticalAlign.Center)
    }.width('100%').padding(0).constraintSize({ minHeight: 76 }).backgroundColor(this.theme.bgCard)
      .enabled(this.accountMutationId.length === 0 && this.refreshingId.length === 0 && this.switchingProfileId.length === 0)
      .onClick((): void => { this.selectAccount(acc.id); })
      .gesture(LongPressGesture({ repeat: false, duration: 600 })
        .onAction((): void => { this.armDelete(acc.id); }))
  }

  /**
   * 同一半模态内部的管理页：刷新、完整身份及危险操作离开主操作区；第三方角色
   * 使用明确的当前标记与原 switchProfile 流程，不创建第二套账号或角色持久化。
   */
  @Builder
  private AccountSettings_() {
    Scroll() {
      Column({ space: 24 }) {
        this.CurrentIdentity_();
        if (this.currentType !== AccountType.OFFLINE && this.currentLoginState === 'unavailable') {
          Column({ space: 12 }) {
            Text('需要重新登录').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.theme.warningText)
            Text('此账号没有可恢复的登录凭据，请通过原登录页面重新添加。')
              .fontSize(14).fontColor(this.theme.warningText)
            Button('添加登录账号').width('100%').height(44).fontSize(16)
              .backgroundColor(this.theme.bgCard).fontColor(this.theme.actionText)
              .onClick((): void => { this.showAddSheet = true; })
          }.width('100%').padding(16).backgroundColor(this.theme.warningBg).borderRadius(16)
        }
        if (this.currentType === AccountType.AUTHLIB_INJECTOR && this.currentAuthProfiles.length > 1) {
          Column({ space: 8 }) {
            Text('选择角色').fontSize(14).fontColor(this.theme.textSecondary).width('100%')
            Column() {
              ForEach(this.currentAuthProfiles, (profile: AccountProfile, index: number) => {
                if (index > 0) {
                  this.GroupDivider_();
                }
                this.AuthProfileRow_(profile);
              }, (profile: AccountProfile): string => profile.id)
            }.width('100%').backgroundColor(this.theme.bgCard).borderRadius(20).clip(true)
          }.width('100%')
        }
        Column() {
          if (this.currentType === AccountType.AUTHLIB_INJECTOR) {
            this.ManagementAppearanceRow_();
            this.GroupDivider_();
          }
          if (this.currentType !== AccountType.OFFLINE) {
            this.RefreshManagementRow_();
            this.GroupDivider_();
          }
          this.AccountInformationRow_();
          this.GroupDivider_();
          this.RemoveManagementRow_();
        }.width('100%').backgroundColor(this.theme.bgCard).borderRadius(20).clip(true)
      }.width('100%').padding({ left: 16, right: 16, top: 4, bottom: 20 })
    }.layoutWeight(1).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
  }

  /** 角色行直接绑定 currentUuid，选中变化不经过基本类型 Builder 值参缓存。 */
  @Builder
  private AuthProfileRow_(profile: AccountProfile) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        AppIcon({ name: AppIconName.Person, iconSize: 24, color: this.theme.textSecondary })
        Column({ space: 4 }) {
          Text(profile.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.theme.textPrimary).width('100%')
          Text(profile.id === this.currentUuid ? '当前角色' : '来自同一皮肤站账号').fontSize(14)
            .fontColor(profile.id === this.currentUuid ? this.theme.actionText : this.theme.textSecondary).width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (this.switchingProfileId === this.currentId) {
          LoadingProgress().width(20).height(20).color(this.theme.actionText)
        } else if (profile.id === this.currentUuid) {
          AppIcon({ name: AppIconName.CheckCircle, iconSize: 20, color: this.theme.actionText })
        }
      }.width('100%').padding(16).alignItems(VerticalAlign.Center)
    }.width('100%').padding(0).constraintSize({ minHeight: 76 }).backgroundColor(this.theme.bgCard)
      .enabled(this.accountMutationId.length === 0 && this.refreshingId.length === 0 && this.switchingProfileId.length === 0)
      .onClick((): void => { if (profile.id !== this.currentUuid) this.switchToProfile(profile.id); })
  }

  /** 第三方角色的外观入口继续打开既有详情，不提供微软专属的披风同步操作。 */
  @Builder
  private ManagementAppearanceRow_() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        AppIcon({ name: AppIconName.ResourcePack, iconSize: 20, color: this.theme.textPrimary })
        Column({ space: 4 }) {
          Text('皮肤与披风').fontSize(16).fontColor(this.theme.textPrimary).width('100%')
          Text('查看此角色的在线外观').fontSize(14).fontColor(this.theme.textSecondary).width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        AppIcon({ name: AppIconName.ChevronRight, iconSize: 20, color: this.theme.textHint })
      }.width('100%').padding(16).alignItems(VerticalAlign.Center)
    }.width('100%').padding(0).constraintSize({ minHeight: 76 }).backgroundColor(this.theme.bgCard)
      .enabled(this.accountMutationId.length === 0 && this.refreshingId.length === 0 && this.switchingProfileId.length === 0)
      .onClick((): void => { this.openAppearance_(); })
  }

  /** 在线账号才显示刷新，离线账号不再为一个禁用按钮占位。 */
  @Builder
  private RefreshManagementRow_() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        AppIcon({ name: AppIconName.Refresh, iconSize: 20, color: this.theme.textPrimary })
        Text(this.refreshingId === this.currentId ? '正在刷新登录状态…' : '刷新登录状态')
          .fontSize(16).fontColor(this.theme.textPrimary).layoutWeight(1).textAlign(TextAlign.Start)
        if (this.refreshingId === this.currentId) {
          LoadingProgress().width(20).height(20).color(this.theme.actionText)
        } else {
          AppIcon({ name: AppIconName.ChevronRight, iconSize: 20, color: this.theme.textHint })
        }
      }.width('100%').padding(16).alignItems(VerticalAlign.Center)
    }.width('100%').padding(0).constraintSize({ minHeight: 60 }).backgroundColor(this.theme.bgCard)
      .enabled(this.accountMutationId.length === 0 && this.refreshingId.length === 0 && this.switchingProfileId.length === 0)
      .onClick((): void => { const acc = this.currentAcc; if (acc !== null && !this.busy_()) this.refreshAccount(acc); })
  }

  /** UUID 与服务器信息只在有意查看时出现，不再挤占主卡身份列。 */
  @Builder
  private AccountInformationRow_() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        AppIcon({ name: AppIconName.Info, iconSize: 20, color: this.theme.textPrimary })
        Column({ space: 4 }) {
          Text('账号信息').fontSize(16).fontColor(this.theme.textPrimary).width('100%')
          Text('UUID、账号类型与服务来源').fontSize(14).fontColor(this.theme.textSecondary).width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        AppIcon({ name: AppIconName.ChevronRight, iconSize: 20, color: this.theme.textHint })
      }.width('100%').padding(16).alignItems(VerticalAlign.Center)
    }.width('100%').padding(0).constraintSize({ minHeight: 76 }).backgroundColor(this.theme.bgCard)
      .onClick((): void => { this.showAccountInformation_(); })
  }

  /** 危险操作在管理组内单独着色；真正删除仍由明确确认和原持久化屏障控制。 */
  @Builder
  private RemoveManagementRow_() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        AppIcon({ name: AppIconName.Trash, iconSize: 20, color: this.theme.errorText })
        Column({ space: 4 }) {
          Text(this.accountMutationAction === 'remove' ? '正在移除账号…' : '移除此账号')
            .fontSize(16).fontColor(this.theme.errorText).width('100%')
          Text('仅移除本机保存的账号信息').fontSize(14).fontColor(this.theme.textSecondary).width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        AppIcon({ name: AppIconName.ChevronRight, iconSize: 20, color: this.theme.textHint })
      }.width('100%').padding(16).alignItems(VerticalAlign.Center)
    }.width('100%').padding(0).constraintSize({ minHeight: 76 }).backgroundColor(this.theme.bgCard)
      .enabled(this.accountMutationId.length === 0 && this.refreshingId.length === 0 && this.switchingProfileId.length === 0)
      .onClick((): void => { this.armDelete(this.currentId); })
  }

  @Builder
  ErrorToast(msg: string) {
    Row() {
      Row({ space: 8 }) {
        AppIcon({ name: AppIconName.Error, iconSize: 16, color: this.theme.errorText })
        Text(msg)
          .fontSize(12)
          .fontColor(this.theme.errorText)
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
    if (cur === null) this.showAccountSettings = false;

    // 同步独立的皮肤、披风和身份快照，保证主卡预览及外观摘要在切换后原位刷新。
    // 非响应式账号对象的方法结果不作为 Builder 的唯一刷新依据。
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

    if (cur !== null) this.refreshLoginState_(cur);
    else { this.loginStateEpoch++; this.currentLoginState = 'offline'; }

    hilog.info(0x0000, TAG,
      'refresh: %{public}d accounts, selected=%{public}s, others=%{public}d, capeUrl=%{public}s',
      this.accounts.length, this.selectedId, others.length,
      this.currentCapeUrl.length > 0 ? '<set>' : '<empty>');
  }

  /** 只有账号管理器确认选中态持久成功后，才重排当前主卡并通知首页。 */
  private async selectAccount(id: string): Promise<void> {
    await this.commitAccountMutation_(id, false);
  }

  /** 删除与新增/外观编辑共用管理器队列，不在等待期间先从UI移走账号。 */
  private async removeAccount(id: string, choice?: AccountRemovalChoice): Promise<boolean> {
    return this.commitAccountMutation_(id, true, choice?.target, choice?.selectedId);
  }

  /**
   * 选择和删除的共同确认屏障。生命周期世代只限制本页状态写入；保存已经成功后，
   * 即使用户通过系统手势收起本页，也要通知仍存活的父owner更新首页账号快照。
   */
  private async commitAccountMutation_(id: string, remove: boolean, expected?: Account, expectedSelection?: string): Promise<boolean> {
    if (this.busy_()) return false;
    const epoch = ++this.accountMutationEpoch;
    const notify = this.onAccountsChanged;
    this.accountMutationId = id; this.accountMutationAction = remove ? 'remove' : 'select';
    this.refreshErrorMsg = '';
    let committed = false;
    try {
      const am = getAccountManager();
      if (remove) await am.remove(id, expected, expectedSelection);
      else await am.select(id, expected);
      committed = true;
      if (remove) {
        // 新主线的活动摘要必须跟随真实持久确认，记录失败不能推翻已经成功的账号删除。
        try { getTaskActivityOwner().recordSummary('account', '删除账户', 'success', '已移除所选账户'); }
        catch (error) { hilog.warn(0x0000, TAG, '账户已移除，活动摘要记录失败'); }
      }
      if (this.alive && epoch === this.accountMutationEpoch) {
        this.pendingDeleteId = '';
        this.refresh();
      }
      hilog.info(0x0000, TAG, 'account mutation committed: %{public}s %{public}s', remove ? 'remove' : 'select', id);
    } catch (error) {
      if (this.alive && epoch === this.accountMutationEpoch) {
        this.refreshErrorMsg = (remove ? '移除失败：' : '切换失败：') + (error as Error).message;
      }
      hilog.warn(0x0000, TAG, 'account mutation failed: %{public}s', (error as Error).message);
    } finally {
      if (this.alive && epoch === this.accountMutationEpoch) {
        this.accountMutationId = ''; this.accountMutationAction = '';
      }
    }
    // 父层刷新异常不能把已经确认的账号提交再解释成存储失败。
    if (committed) {
      try { notify(); }
      catch (error) { hilog.warn(0x0000, TAG, 'account owner notification failed: %{public}s', (error as Error).message); }
    }
    return committed;
  }

  /**
   * 删除确认冻结目标 id 与本页世代，第二次明确点击才进入原删除提交队列。
   * 弹窗展示期间如果发生切换或页面退役，旧确认回调被拒绝；取消不改变账号。
   */
  private prepareRemoval_(id: string): AccountRemovalChoice | undefined {
    if (!this.alive || this.busy_()) return undefined;
    const manager = getAccountManager();
    const target = manager.findById(id);
    if (target === undefined) return undefined;
    this.pendingDeleteId = id;
    return { target:target, selectedId:manager.getSelectedId(), epoch:this.accountMutationEpoch,
      confirmation:++this.deleteConfirmationEpoch };
  }

  /** 同一页、同一目标、同一次确认才能消费计划，普通点击与开发会话共用。 */
  private async confirmRemoval_(choice: AccountRemovalChoice): Promise<boolean> {
    const manager = getAccountManager();
    if (!this.alive || this.busy_() || choice.epoch !== this.accountMutationEpoch ||
      this.pendingDeleteId !== choice.target.id || choice.confirmation !== this.deleteConfirmationEpoch ||
      manager.getSelectedId() !== choice.selectedId || manager.findById(choice.target.id) !== choice.target) return false;
    this.deleteConfirmationEpoch++;
    this.pendingDeleteId = ''; this.showAccountSettings = false;
    return this.removeAccount(choice.target.id, choice);
  }

  private cancelRemoval_(choice: AccountRemovalChoice): boolean {
    if (choice.confirmation !== this.deleteConfirmationEpoch || choice.target.id !== this.pendingDeleteId) return false;
    this.deleteConfirmationEpoch++; this.pendingDeleteId = ''; return true;
  }

  private armDelete(id: string): void {
    const choice = this.prepareRemoval_(id);
    if (choice === undefined) return;
    this.removalRef_=this.accountRef_(choice.target); this.removalState_='pending';
    let committing = false, offered = true;
    LauncherSkillBus.followUserCondition('requestRemovePlayer', (): boolean => committing ||
      (offered && this.alive && this.pendingDeleteId === id && this.deleteConfirmationEpoch === choice.confirmation));
    const cancel=():void => { offered=false; if(this.cancelRemoval_(choice)) this.removalState_='cancelled'; };
    this.getUIContext().showAlertDialog({ title: '移除 ' + choice.target.getDisplayName() + '？', cancel:cancel,
      message: '仅移除此设备保存的账号。游戏文件与共享皮肤、披风素材库会继续保留。',
      primaryButton: { value: '取消', action: cancel },
      secondaryButton: { value: '移除账号', fontColor: this.theme.errorText,
        action: (): void => { offered=false; committing = true; this.confirmRemoval_(choice).then((ok:boolean):void=>{
          if (this.removalRef_===this.accountRef_(choice.target)) this.removalState_=ok?'ready':'unknown';
        }).finally((): void => { committing = false; }); } } });
  }

  /**
   * 刷新账号的原登录凭据并确认持久化，再刷新当前页面和首页。
   * 与选择、删除及角色切换共享 busy 屏障，不能只检查自己的 refreshingId；已经
   * 排队的旧角色点击在刷新开始后也必须被拒绝。局部状态和错误计时器绑定本次
   * 页／操作世代与目标账号，页面退休后只保留已确认提交的父层通知。
   */
  private async refreshAccount(acc: Account): Promise<boolean> {
    if (!this.alive || this.busy_()) return false;
    if (acc.type !== AccountType.MICROSOFT && acc.type !== AccountType.AUTHLIB_INJECTOR) return false;
    const epoch = ++this.accountMutationEpoch;
    const id = acc.id;
    const notify = this.onAccountsChanged;
    let committed = false;
    this.refreshingId = id;
    this.refreshErrorMsg = '';
    try {
      // 保持原账号实现的刷新语义；凭据轮换后的持久化失败必须按失败呈现，不能
      // 吞掉异常后再通知首页“成功”。UI 不自行读取或记录访问令牌。
      await acc.refresh();
      await getAccountManager().persistOne(acc);
      committed = true;
      if (this.currentOperation_(epoch, id)) this.refresh();
      hilog.info(0x0000, TAG, 'refresh committed for id=%{public}s', id);
    } catch (error) {
      const message = '刷新失败：' + (error as Error).message;
      if (this.currentOperation_(epoch, id)) {
        this.refreshErrorMsg = message;
        setTimeout((): void => {
          if (this.currentOperation_(epoch, id) && this.refreshErrorMsg === message) this.refreshErrorMsg = '';
        }, 3000);
      }
      hilog.error(0x0000, TAG, 'refresh failed for id=%{public}s: %{public}s', id, (error as Error).message);
    } finally {
      // refresh() 可能读到另一个已确认选中账号，此时仍须释放本操作自己的忙态。
      // 世代与目标标记都相同才清除，不能影响新页面或新一轮刷新。
      if (this.alive && epoch === this.accountMutationEpoch && this.refreshingId === id) this.refreshingId = '';
    }
    if (committed) this.notifyConfirmedChange_(notify);
    return committed;
  }

  /**
   * 第三方角色切换保持原服务调用和持久化顺序。与所有账号写操作互斥；await及
   * 错误计时器只能更新发起页与目标账号，成功保存即使遇到关闭也仍通知父owner。
   */
  private async switchToProfile(profileId: string): Promise<boolean> {
    if (!this.alive || this.busy_()) return false;
    const acc = this.currentAcc;
    if (acc === null || acc.type !== AccountType.AUTHLIB_INJECTOR) return false;
    const epoch = ++this.accountMutationEpoch;
    const id = acc.id;
    const notify = this.onAccountsChanged;
    let committed = false;
    this.switchingProfileId = id;
    this.refreshErrorMsg = '';
    try {
      const authAcc = acc as AuthlibInjectorAccount;
      await authAcc.switchProfile(profileId);
      await getAccountManager().persistOne(authAcc);
      committed = true;
      if (this.currentOperation_(epoch, id)) this.refresh();
      hilog.info(0x0000, TAG, 'switchProfile committed for id=%{public}s', id);
    } catch (error) {
      const message = '切换角色失败：' + (error as Error).message;
      if (this.currentOperation_(epoch, id)) {
        this.refreshErrorMsg = message;
        setTimeout((): void => {
          if (this.currentOperation_(epoch, id) && this.refreshErrorMsg === message) this.refreshErrorMsg = '';
        }, 3000);
      }
      hilog.error(0x0000, TAG, 'switchProfile failed for id=%{public}s: %{public}s', id, (error as Error).message);
    } finally {
      if (this.alive && epoch === this.accountMutationEpoch && this.switchingProfileId === id) this.switchingProfileId = '';
    }
    if (committed) this.notifyConfirmedChange_(notify);
    return committed;
  }

  /** 界面状态发布资格同时绑定页面世代及操作对象，不能只凭账号ID判断仍属于当前页。 */
  private currentOperation_(epoch: number, id: string): boolean {
    return this.alive && epoch === this.accountMutationEpoch && id === this.currentId;
  }

  /** 持久化已确认后独立通知原父owner；通知异常不反转存储成功，也不向退役页面写状态。 */
  private notifyConfirmedChange_(notify: () => void): void {
    try { notify(); }
    catch (error) { hilog.warn(0x0000, TAG, 'account owner notification failed: %{public}s', (error as Error).message); }
  }

  // ============================================================
  //  Helpers
  // ============================================================

  private avatarLetter(acc: Account): string {
    let n = acc.getDisplayName();
    if (!n || n.length === 0) return '?';
    return n.charAt(0).toUpperCase();
  }

  /** 同一入口内的任何持久化、登录刷新或角色切换都禁止重复提交。 */
  private busy_(): boolean {
    return this.accountMutationId.length > 0 || this.refreshingId.length > 0 || this.switchingProfileId.length > 0;
  }

  /** 当前来源读取 @State，其他行读取其不可变账号快照；均不包含秘密凭据。 */
  private currentSource_(): string {
    if (this.currentType === AccountType.MICROSOFT) return '微软正版';
    if (this.currentType === AccountType.AUTHLIB_INJECTOR) return '第三方账号 · ' + (this.currentServerName || '皮肤站');
    return '离线账号 · 本地游戏';
  }

  private accountSource_(acc: Account): string {
    if (acc.type === AccountType.MICROSOFT) return '微软正版';
    if (acc.type === AccountType.AUTHLIB_INJECTOR) return '第三方账号 · ' + (acc as AuthlibInjectorAccount).getServerName();
    return '离线账号 · ' + ((acc.getSkinUrl() ?? '').length > 0 ? '本地皮肤' : '游戏默认皮肤');
  }

  /** 无网络检查的本地凭据状态，明确区分“可恢复”和“已验证有效”。 */
  private loginStateText_(): string {
    if (this.currentLoginState === 'usable') return '可自动登录';
    if (this.currentLoginState === 'unavailable') return '需重新登录';
    return '登录状态待确认';
  }

  private appearanceSummary_(): string {
    const skin = this.currentSkinUrl.length > 0
      ? (this.currentType === AccountType.OFFLINE ? '本地皮肤' : '在线皮肤') : '游戏默认皮肤';
    const cape = this.currentCapeUrl.length > 0 ? (this.currentCapeAlias || '已佩戴披风') : '未佩戴披风';
    return skin + ' · ' + cape;
  }

  /** 详情只接收当前确认账号；关闭后的迟到事件不会重新打开子层。 */
  private openAppearance_(): void {
    if (!this.alive || this.busy_() || this.currentAcc === null) return;
    this.skinDetailAccount = this.currentAcc;
    this.showSkinDetail = true;
  }

  /** 查看稳定账号身份，不序列化 encrypted 字段或任何 token。 */
  private showAccountInformation_(): void {
    const acc = this.currentAcc;
    if (!this.alive || acc === null) return;
    const lines: string[] = ['玩家：' + this.currentName, '类型：' + this.currentSource_(), 'UUID：' + this.currentUuid];
    if (acc.type === AccountType.AUTHLIB_INJECTOR) lines.push('服务：' + (acc as AuthlibInjectorAccount).getApiRoot());
    this.getUIContext().showAlertDialog({ title: '账号信息', message: lines.join('\n'),
      confirm: { value: '知道了', action: (): void => {} } });
  }

  /**
   * isUsable 只读本地可恢复凭据，不发送验证请求。结果只属于本次账号快照和生命周期
   * 世代；切账号、更新外观或关闭之后，迟到结果不能覆盖另一个账号的状态。
   */
  private async refreshLoginState_(acc: Account): Promise<void> {
    const epoch = ++this.loginStateEpoch;
    this.currentLoginState = acc.type === AccountType.OFFLINE ? 'offline' : 'checking';
    if (acc.type === AccountType.OFFLINE) return;
    try {
      const usable = await acc.isUsable();
      if (this.alive && epoch === this.loginStateEpoch && acc.id === this.currentId) {
        this.currentLoginState = usable ? 'usable' : 'unavailable';
      }
    } catch (_) {
      if (this.alive && epoch === this.loginStateEpoch && acc.id === this.currentId) this.currentLoginState = 'checking';
    }
  }

  /**
   * 是否允许头像组件使用公开 UUID 作为纹理解码失败时的远程头像后备。
   *
   * 离线账号优先使用其本地 skinUrl，失败后仅显示字母，不把离线 UUID 发到远端。
   * 微软账户的 uuid 可能是 32 位无连字符或 36 位 dash 格式（早期版本 vs
   * formatCanonicalUuid 之后存的）。既有头像服务接受这两种形式。
   */
  private shouldFetchAvatar(acc: Account): boolean {
    if (acc.type !== AccountType.MICROSOFT) return false;
    return acc.uuid.length === 32 || acc.uuid.length === 36;
  }

  /** 保留原正文的父组件状态与业务回调；具名content只转调此真正@Builder，避免this漂移。 */
  @Builder
  private ImmersiveTitleContent1_() {
      // ===== 主体 =====
      if (this.showAccountSettings && this.currentAcc !== null) {
        this.AccountSettings_();
      } else if (this.accounts.length === 0) {
        this.EmptyView();
      } else {
        this.MainScroll();
      }

      // ===== Refresh 错误横幅（绝对定位在底部，3s 自动消失） =====
      if (this.refreshErrorMsg.length > 0) {
        this.ErrorToast(this.refreshErrorMsg);
      }
      }
}
