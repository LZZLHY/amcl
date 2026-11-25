/**
 * 离线账号的名称与外观编辑页。
 *
 * 共享皮肤/披风库与“此账号正在使用什么”分开展示。导入只扩充库，选中、手臂模型和
 * 用户名先保留为草稿，应用成功才通知账户页；离开页面会丢弃草稿，已导入的库条目保留。
 * 所有异步回调绑定 accountId 与 epoch，避免切账号或关闭页面后污染另一份编辑状态。
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { LauncherSkillBus, SkillFields } from '../launcherskill/LauncherSkillBus';
import { ThemeColors, AppIconName, AppLogger, LOG_DOMAIN_ACCOUNT } from 'commons';
import { AppearanceAsset, AppearanceKind, AppearanceModel, getAccountManager } from 'account';
import { AppIcon } from './AppIcon';
import { ImmersiveTitleScaffold } from './ImmersiveTitleScaffold';
import { SkinCanvas3D } from './SkinCanvas3D';
import { CapePreview } from './CapePreview';
import { MinecraftHeadAvatar } from './MinecraftHeadAvatar';
import { OfflineAppearanceEditorModel } from './OfflineAppearanceEditorModel';

@Component
export struct OfflineAppearanceEditor {
  @Prop theme: ThemeColors = {} as ThemeColors;
  @Prop bottomSafeHeight: number = 0;
  @Prop @Watch('onAccountChange_') accountId: string = '';
  onClose: () => void = (): void => {};
  onChanged: () => void = (): void => {};

  @State private username: string = '';
  @State private confirmedName: string = '';
  @State private selectedSkinId: string = '';
  @State private selectedCapeId: string = '';
  @State private model: AppearanceModel = 'CLASSIC';
  @State private skins: AppearanceAsset[] = [];
  @State private capes: AppearanceAsset[] = [];
  @State private ready: boolean = false;
  @State private busy: boolean = false;
  @State private saving: boolean = false;
  @State private error: string = '';
  @State private notice: string = '';
  @State private pendingDeleteId: string = '';
  private removingAsset_: string = '';
  /** 当前库页签与管理模式属于视图状态，切换时不提交或重置账号外观草稿。 */
  @State private activeKind: AppearanceKind = 'skin';
  @State private managing: boolean = false;
  /** 只读取实际内容宽度；不修改外层 SheetOptions，也不把平板容器拉宽。 */
  @State private contentWidth: number = 0;
  private readonly editor: OfflineAppearanceEditorModel = new OfflineAppearanceEditorModel();
  private revision: number = 0;
  private epoch: number = 0;
  private alive: boolean = false;

  /** 新建或重新绑定时重新加载草稿；耗时内容走异步服务，UI 不同步解码 PNG。 */
  /** 操作引用只在当前账号草稿有效；纹理取自应用库，不接受来源地址。 */
  private playerEditRef_: string = '';
  private observedDraft_: string = '';

  private async skillAppearance_(method: string, args: SkillFields): Promise<SkillFields> {
    if (!this.ready || !this.alive || this.busy) return { 'state': 'busy' };
    // 已保存的账号修订和仍在界面的草稿是两个对象。人手修改后，旧凭据不能覆盖或关闭该草稿。
    const current = JSON.stringify([this.accountId, this.revision, this.username, this.selectedSkinId, this.selectedCapeId, this.model]);
    if (current !== this.observedDraft_) {
      this.observedDraft_ = current;
      this.playerEditRef_ = util.generateRandomUUID();
    }
    if (method === 'readOfflineAppearance') {
      const assets = this.skins.concat(this.capes);
      return { 'state': 'ready', 'editorRef': this.playerEditRef_, 'revision': this.revision,
        'playerName':this.username,'storedName':this.confirmedName, 'skin': this.selectedSkinId, 'cape': this.selectedCapeId, 'model': this.model,
        'assets': assets.map((a: AppearanceAsset): SkillFields => ({ 'id': a.id, 'kind':a.kind,
          'width':a.width,'height':a.height,'used':getAccountManager().isAppearanceAssetUsed(a.id) })) };
    }
    if (args['editorRef'] !== this.playerEditRef_ || args['revision'] !== this.revision) return { 'state': 'failed', 'reason': 'staleDraft' };
    if (this.pendingDeleteId) return { 'state':'needsUser', 'reason':'assetConfirmation' };
    if (method === 'importAppearanceImage') {
      const kind = args['kind'];
      if (kind !== 'skin' && kind !== 'cape') return { 'state': 'failed', 'reason':'kind' };
      return this.import_(kind as AppearanceKind, method);
    }
    if (method === 'requestRemoveAppearanceAsset') {
      const asset = this.skins.concat(this.capes).find((a: AppearanceAsset): boolean => a.id === args['assetId']);
      if (!asset || getAccountManager().isAppearanceAssetUsed(asset.id)) return { 'state':'unavailable','reason':'missingOrInUse' };
      this.changeKind_(asset.kind); this.managing = true;
      await this.remove_(asset);
      const epoch = this.epoch;
      LauncherSkillBus.followUserCondition(method, (): boolean => this.removingAsset_ === asset.id ||
        (this.alive && this.epoch === epoch && this.pendingDeleteId === asset.id));
      return { 'state': this.pendingDeleteId === asset.id ? 'needsUser' : 'unknown' };
    }
    if (method === 'discardOfflineAppearance') { this.close_(); return { 'state': 'cancelled' }; }
    if (method !== 'saveOfflineAppearance') return { 'state': 'failed', 'reason': 'unknownOperation' };
    const name = String(args['playerName']);
    const skin = String(args['skin']); const cape = String(args['cape']); const model = args['model'];
    if (!name.trim() || name.length>16 || /[\u0000-\u001f\u007f]/.test(name) || (skin && !this.skins.some((a: AppearanceAsset): boolean => a.id === skin)) ||
      (cape && !this.capes.some((a: AppearanceAsset): boolean => a.id === cape)) || (model !== 'CLASSIC' && model !== 'SLIM')) {
      return { 'state':'failed','reason':'invalidDraft' };
    }
    const prev = this.revision;
    this.username = name; this.selectedSkinId = skin; this.selectedCapeId = cape;
    this.model = this.oldSkin_() ? 'CLASSIC' : model as AppearanceModel;
    await this.apply_();
    if (!this.alive || this.error || this.revision <= prev || this.confirmedName !== name.trim()) return { 'state':'unknown' };
    return { 'state':'ready','playerName':this.confirmedName,'skin':this.selectedSkinId,'cape':this.selectedCapeId,'model':this.model,'revision':this.revision };
  }

  aboutToAppear(): void {
    this.alive = true;
    LauncherSkillBus.bind('offlineAppearance',this,(m: string,a: SkillFields): Promise<SkillFields> => this.skillAppearance_(m,a),(): boolean => this.alive);
    this.reload_();
  }
  /** 关闭仅使回调退役，不取消已经由用户确认的共享库导入或账号保存事务。 */
  aboutToDisappear(): void { LauncherSkillBus.unbind('offlineAppearance',this); this.alive = false; this.epoch++; }
  private onAccountChange_(): void { if (this.alive) this.reload_(); }

  /** UIAbilityContext 由主 Ability 统一缓存，文件选择只从当前可用的界面上下文发起。 */
  private context_(): common.UIAbilityContext | undefined {
    return AppStorage.get<common.UIAbilityContext>('uiAbilityContext');
  }
  private current_(epoch: number, id: string): boolean {
    return this.alive && epoch === this.epoch && id === this.accountId;
  }

  /** 清空上次账号状态后读取当前账号，失败保留返回入口并展示可理解的错误。 */
  private async reload_(): Promise<void> {
    this.playerEditRef_ = util.generateRandomUUID();
    const epoch = ++this.epoch;
    const id = this.accountId;
    this.ready = false; this.busy = true; this.saving = false;
    this.error = ''; this.notice = ''; this.pendingDeleteId = '';
    this.activeKind = 'skin'; this.managing = false;
    const context = this.context_();
    if (context === undefined) { this.error = '界面尚未就绪，请返回后重试'; this.busy = false; return; }
    try {
      const snapshot = await this.editor.load(context, id);
      if (!this.current_(epoch, id)) return;
      this.username = snapshot.username; this.confirmedName = snapshot.username;
      this.revision = snapshot.appearance.revision;
      this.selectedSkinId = snapshot.appearance.skin?.id ?? '';
      this.selectedCapeId = snapshot.appearance.cape?.id ?? '';
      this.model = this.selectedSkinId.length > 0 ? snapshot.appearance.model : 'CLASSIC';
      this.skins = snapshot.skins; this.capes = snapshot.capes;
      this.ready = true;
    } catch (error) {
      if (this.current_(epoch, id)) this.error = (error as Error).message;
    } finally {
      if (this.current_(epoch, id)) this.busy = false;
    }
  }

  /** 请求返回时不提交草稿；账号的原配置仍由 AccountManager 持有。 */
  private close_(): void { if (!this.saving) this.onClose(); }

  /** 库管理是当前编辑层的内部状态；返回管理入口仍保留名称、模型和外观选择。 */
  private back_(): void {
    if (this.saving) return;
    if (this.managing) { this.managing = false; this.pendingDeleteId = ''; this.notice = ''; }
    else this.close_();
  }

  /** 520/600vp 原有平板 Sheet 在自身宽度足够时重排内部；窄窗口沿用手机编辑结构。 */
  private wide_(): boolean { return this.contentWidth >= 500; }
  /** 两个页签始终各取自己的最新库快照，不把另一类纹理误列到当前选择区。 */
  private items_(): AppearanceAsset[] { return this.activeKind === 'skin' ? this.skins : this.capes; }
  /** 页签、库标题与导入反馈共用同一名称映射。 */
  private kindName_(): string { return this.activeKind === 'skin' ? '皮肤' : '披风'; }
  /** 仅用于预览摘要，选择仍以资产ID为准，未选时明确呈现游戏默认皮肤。 */
  private selectedName_(): string {
    const asset = this.skins.find((item: AppearanceAsset): boolean => item.id === this.selectedSkinId);
    return asset === undefined ? '游戏默认皮肤' : asset.name;
  }
  /** 空披风引用是一项有效选择，不用空白名称掩盖“不佩戴”的状态。 */
  private selectedCapeName_(): string {
    const asset = this.capes.find((item: AppearanceAsset): boolean => item.id === this.selectedCapeId);
    return asset === undefined ? '不佩戴披风' : asset.name;
  }

  /** 页签与管理入口只改变浏览上下文；忙态拒绝重入，已导入文件不会因返回而回滚。 */
  private changeKind_(kind: AppearanceKind): void {
    if (this.busy || this.activeKind === kind) return;
    this.activeKind = kind; this.pendingDeleteId = ''; this.error = ''; this.notice = '';
  }
  private manage_(): void {
    if (this.busy) return;
    this.managing = true; this.pendingDeleteId = ''; this.error = ''; this.notice = '';
  }
  private chooseDefault_(): void {
    if (this.busy) return;
    if (this.activeKind === 'skin') { this.selectedSkinId = ''; this.model = 'CLASSIC'; }
    else this.selectedCapeId = '';
    this.pendingDeleteId = ''; this.error = ''; this.notice = '';
  }

  /** 确认区从最新库快照重新找目标，避免导入/删除后继续提交已不存在的旧条目。 */
  private async confirmDelete_(): Promise<void> {
    const target = this.items_().find((asset: AppearanceAsset): boolean => asset.id === this.pendingDeleteId);
    if (target !== undefined) await this.remove_(target);
  }
  private pendingDeleteName_(): string {
    return this.items_().find((asset: AppearanceAsset): boolean => asset.id === this.pendingDeleteId)?.name ?? '';
  }

  /** 当前草稿的内部纹理引用，只用于预览，真实路径解析仍由资产库统一完成。 */
  private source_(kind: AppearanceKind): string {
    const selected = kind === 'skin' ? this.selectedSkinId : this.selectedCapeId;
    const items = kind === 'skin' ? this.skins : this.capes;
    const asset = items.find((item: AppearanceAsset): boolean => item.id === selected);
    return asset === undefined ? '' : 'amcl-texture:' + asset.relativePath;
  }
  private oldSkin_(): boolean {
    return this.skins.some((item: AppearanceAsset): boolean => item.id === this.selectedSkinId && item.height === 32);
  }

  /** 选择只修改当前账号草稿；同一库条目仍可同时供其他账号使用。 */
  private choose_(asset: AppearanceAsset): void {
    if (this.busy) return;
    this.pendingDeleteId = ''; this.error = ''; this.notice = '';
    if (asset.kind === 'skin') {
      this.selectedSkinId = asset.id;
      if (asset.height === 32) this.model = 'CLASSIC';
    } else this.selectedCapeId = asset.id;
  }

  /**
   * 系统选择器返回后再导入共享库；关闭或切换期间的结果不改变视图草稿。
   * 导入完成并不自动改变任何账号的当前皮肤，用户仍需选择并点击应用。
   */
  private async import_(kind: AppearanceKind, method: string = ''): Promise<SkillFields> {
    if (this.busy) return { 'state': 'busy' };
    const context = this.context_();
    if (context === undefined) { this.error = '界面尚未就绪，无法选择文件'; return { 'state': 'unavailable' }; }
    const epoch = this.epoch, id = this.accountId;
    this.busy = true; this.error = ''; this.notice = ''; this.pendingDeleteId = '';
    try {
      if (method) LauncherSkillBus.awaitingUser(method);
      const imported = await this.editor.importFile(context, kind);
      if (!this.current_(epoch, id)) return { 'state':'unknown' };
      if (!imported) return { 'state':'cancelled' };
      this.skins = this.editor.list('skin'); this.capes = this.editor.list('cape');
      this.notice = '已加入共享' + (kind === 'skin' ? '皮肤库' : '披风库') + '，选择后可应用到此账号';
      return { 'state':'ready','assetId':imported.id,'kind':kind };
    } catch (error) {
      if (this.current_(epoch, id)) this.error = (error as Error).message;
      return { 'state':'failed','reason':'importFailure' };
    } finally {
      if (this.current_(epoch, id)) this.busy = false;
    }
  }

  /** 删除采用两次明确操作；在用条目必须先为相关账号解除选择，不能破坏共享引用。 */
  private async remove_(asset: AppearanceAsset): Promise<void> {
    if (this.busy) return;
    // 使用中条目仍可查看其保护原因，但绝不先显示一个看似可执行的删除确认。
    if (getAccountManager().isAppearanceAssetUsed(asset.id)) {
      this.pendingDeleteId = ''; this.notice = '';
      this.error = '有离线账号正在使用这张纹理，请先为这些账号更换或恢复默认';
      return;
    }
    if (this.pendingDeleteId !== asset.id) {
      this.pendingDeleteId = asset.id;
      this.notice = '再次点击“确定删除”将从共享库删除此纹理';
      return;
    }
    const epoch = this.epoch, id = this.accountId;
    this.busy = true; this.error = ''; this.notice = '';
    try {
      this.removingAsset_ = asset.id;
      await this.editor.removeAsset(asset.id);
      if (!this.current_(epoch, id)) return;
      if (this.selectedSkinId === asset.id) this.selectedSkinId = '';
      if (this.selectedCapeId === asset.id) this.selectedCapeId = '';
      this.skins = this.editor.list('skin'); this.capes = this.editor.list('cape');
      this.notice = '已从共享库删除';
    } catch (error) {
      if (this.current_(epoch, id)) this.error = (error as Error).message;
    } finally {
      this.removingAsset_ = '';
      if (this.current_(epoch, id)) { this.busy = false; this.pendingDeleteId = ''; }
    }
  }

  /** 用户名与外观使用一个持久化提交，成功后按新实例更新本页并通知列表和首页刷新。 */
  private async apply_(): Promise<void> {
    if (this.busy || !this.ready) return;
    const epoch = this.epoch, id = this.accountId;
    const notify = this.onChanged;
    let committed = false;
    this.busy = true; this.saving = true; this.error = ''; this.notice = ''; this.pendingDeleteId = '';
    try {
      const updated = await this.editor.save(id, this.revision, this.username,
        this.selectedSkinId, this.selectedCapeId, this.model);
      committed = true;
      if (this.current_(epoch, id)) {
        const appearance = updated.getOfflineAppearance();
        this.username = updated.username; this.confirmedName = updated.username;
        this.revision = appearance.revision; this.model = appearance.model;
        this.notice = '已应用到此账号，下次启动游戏生效';
      }
    } catch (error) {
      if (this.current_(epoch, id)) this.error = (error as Error).message;
    } finally {
      if (this.current_(epoch, id)) { this.busy = false; this.saving = false; }
    }
    // 拖拽或系统返回可能绕过页内忙态按钮。提交成功仍通知父owner，防止账号主卡/
    // 首页继续持有旧实例；已退役页的本地状态仍完全受epoch围栏保护。
    if (committed) {
      try { notify(); }
      catch (error) { AppLogger.warn('OfflineAppearanceEditor', '账号已保存，父界面刷新回调失败', error as Object, LOG_DOMAIN_ACCOUNT); }
    }
  }

  /**
   * 标题继续复用主工程紧凑宿主。返回先离开库管理，右侧关闭始终结束本次编辑；
   * 两个动作都不会隐式提交草稿，正在保存时统一禁用。
   */
  build() {
    Column() {
      ImmersiveTitleScaffold({
        title: this.managing ? '共享' + this.kindName_() + '库' : '编辑离线账号',
        contextLabel: this.confirmedName, contextTitle: '当前账户', theme: this.theme,
        surfaceColor: this.theme.bgPrimary, backLabel: this.managing ? '返回外观选择' : '返回账户管理',
        backId: 'offline-appearance-back', backEnabled: !this.saving,
        showClose: true, closeEnabled: !this.saving, closeLabel: '关闭离线账号编辑',
        onBack: (): void => { this.back_(); }, onClose: (): void => { this.close_(); },
        content: (): void => { this.Content_(); }
      })
    }
    .width('100%').height('100%').backgroundColor(this.theme.bgPrimary)
    .padding({ bottom: this.bottomSafeHeight })
    .onAreaChange((_old: Area, area: Area): void => {
      // Area.width 来自本组件实际布局。忽略零宽和微小抖动，不写外部窗口或 Sheet 配置。
      if (!this.alive) return;
      const width: number = Number(area.width);
      if (Number.isFinite(width) && width > 0 && Math.abs(width - this.contentWidth) >= 1) this.contentWidth = width;
    })
  }

  /** 正文可滚动，反馈和确认区固定；库再多、窗口再矮也不挤掉应用或返回按钮。 */
  @Builder
  private Content_() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.ready) {
          if (this.managing) {
            this.ManagementContent_();
          } else {
            if (this.wide_()) {
              this.WideIdentity_();
            } else {
              this.NameCard_();
              this.PreviewCard_();
            }
            this.LibraryControls_();
            this.LibraryGrid_();
          }
        } else if (this.busy) {
          Row({ space: 10 }) {
            LoadingProgress().width(22).height(22).color(this.theme.actionText)
            Text('正在读取账号与共享素材库…').fontSize(14).fontColor(this.theme.textSecondary)
          }.width('100%').justifyContent(FlexAlign.Center).padding(24)
        } else {
          Text('未能读取账号，可返回后重新打开。').fontSize(14).fontColor(this.theme.textSecondary)
            .width('100%').padding(20)
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
        .padding({ left: this.wide_() ? 24 : 16, right: this.wide_() ? 24 : 16, top: 4, bottom: 12 })
    }.layoutWeight(1).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
    this.Messages_();
    if (this.managing) {
      Row() {
        Button('完成管理').layoutWeight(1).height(48).fontSize(16).fontColor(this.theme.actionText)
          .backgroundColor(this.theme.primaryLight).borderRadius(24).enabled(!this.saving)
          .onClick((): void => { this.back_(); })
      }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 12 })
    } else {
      this.Footer_();
    }
  }

  /** 反馈不伪装成已经选择或应用；导入和保存的确认文本继续来自原异步事务。 */
  @Builder
  private Messages_() {
    if (this.error.length > 0) {
      Text(this.error).width('100%').fontSize(14).fontColor(this.theme.errorText)
        .padding({ left: 20, right: 20, top: 8, bottom: 8 }).backgroundColor(this.theme.errorBg)
    }
    if (this.notice.length > 0) {
      Text(this.notice).width('100%').fontSize(14).fontColor(this.theme.actionText)
        .padding({ left: 20, right: 20, top: 8, bottom: 8 }).backgroundColor(this.theme.primaryLight)
    }
  }

  /** 手机将名称单独呈现，输入仍只修改当前草稿，账号唯一性由原保存事务校验。 */
  @Builder
  private NameCard_() {
    Row({ space: 12 }) {
      Text('名称').fontSize(14).fontColor(this.theme.textSecondary)
      this.NameInput_();
    }.width('100%').padding({ left: 16, right: 16, top: 6, bottom: 6 })
      .backgroundColor(this.theme.bgCard).borderRadius(16)
  }

  /** 共用受控名称输入，切换响应式结构时读取同一个 username，不创建第二份名称状态。 */
  @Builder
  private NameInput_() {
    TextInput({ text: this.username, placeholder: '输入离线账号名称' })
      .fontSize(16).fontColor(this.theme.textPrimary).backgroundColor(this.theme.bgInput)
      .height(44).borderRadius(12).maxLength(16).layoutWeight(1)
      .enabled(!this.busy).id('offline-appearance-name')
      .onChange((value: string): void => { this.username = value; this.error = ''; })
  }

  /**
   * 平板只重排固定 Sheet 内部：左侧完整预览，右侧名称和模型。顶部成为横向摘要，
   * 让下方图库获得全部宽度；不再把图库挤进窄侧栏。
   */
  @Builder
  private WideIdentity_() {
    Row({ space: 24 }) {
      SkinCanvas3D({ skinUrl: this.source_('skin'), username: this.username, isOffline: true,
        slim: this.model === 'SLIM' && !this.oldSkin_(), containerWidth: 104, containerHeight: 132, theme: this.theme })
        .width(104).height(132).backgroundColor(this.theme.bgInput).borderRadius(12).clip(true)
      Column({ space: 8 }) {
        Text('玩家名称').fontSize(14).fontColor(this.theme.textSecondary).width('100%')
        Row() { this.NameInput_(); }.width('100%')
        if (this.activeKind === 'skin') {
          Row({ space: 12 }) {
            Text('模型').fontSize(14).fontColor(this.theme.textSecondary)
            Row() { this.ModelButtons_(); }.layoutWeight(1)
          }.width('100%')
        } else {
          this.CapeSummary_();
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').constraintSize({ minHeight: 164 }).padding(16)
      .backgroundColor(this.theme.bgCard).borderRadius(20).alignItems(VerticalAlign.Center)
  }

  /** 手机预览与当前选择紧邻；披风页直接显示所选纹理，避免只看角色正面无法确认结果。 */
  @Builder
  private PreviewCard_() {
    Row({ space: 20 }) {
      SkinCanvas3D({ skinUrl: this.source_('skin'), username: this.username, isOffline: true,
        slim: this.model === 'SLIM' && !this.oldSkin_(), containerWidth: 88, containerHeight: 120, theme: this.theme })
        .width(88).height(120).backgroundColor(this.theme.bgInput).borderRadius(12).clip(true)
      Column({ space: 8 }) {
        if (this.activeKind === 'skin') {
          Text(this.selectedName_()).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.theme.textPrimary)
            .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('角色模型').fontSize(14).fontColor(this.theme.textSecondary).width('100%')
          this.ModelButtons_();
        } else {
          Text('当前披风').fontSize(14).fontColor(this.theme.textSecondary).width('100%')
          this.CapeSummary_();
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').padding(12).constraintSize({ minHeight: 144 })
      .backgroundColor(this.theme.bgCard).borderRadius(20)
  }

  /** 模型属于账号草稿，不是共享纹理属性；旧版 64×32 和默认皮肤不能选择 Slim。 */
  @Builder
  private ModelButtons_() {
    Row({ space: 4 }) {
      Button('Classic').layoutWeight(1).height(44).fontSize(14).borderRadius(22)
        .fontColor(this.model === 'CLASSIC' ? this.theme.actionText : this.theme.textSecondary)
        .backgroundColor(this.model === 'CLASSIC' ? this.theme.bgCard : Color.Transparent)
        .enabled(!this.busy && this.selectedSkinId.length > 0)
        .onClick((): void => { this.model = 'CLASSIC'; })
      Button('Slim').layoutWeight(1).height(44).fontSize(14).borderRadius(22)
        .fontColor(this.model === 'SLIM' ? this.theme.actionText : this.theme.textSecondary)
        .backgroundColor(this.model === 'SLIM' ? this.theme.bgCard : Color.Transparent)
        .enabled(!this.busy && this.selectedSkinId.length > 0 && !this.oldSkin_())
        .onClick((): void => { this.model = 'SLIM'; })
    }.width('100%').height(48).padding(2).borderRadius(24).backgroundColor(this.theme.bgInput)
  }

  /** 选中的披风用真实本地预览呈现；空引用明确表示不佩戴。 */
  @Builder
  private CapeSummary_() {
    Row({ space: 12 }) {
      if (this.selectedCapeId.length > 0) {
        CapePreview({ capeUrl: this.source_('cape'), alias: this.selectedCapeName_(),
          containerWidth: 32, containerHeight: 52, theme: this.theme })
      } else {
        AppIcon({ name: AppIconName.Close, iconSize: 24, color: this.theme.textHint })
      }
      Column({ space: 4 }) {
        Text(this.selectedCapeName_()).fontSize(16).fontColor(this.theme.textPrimary)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('选择后点击应用保存').fontSize(12).fontColor(this.theme.actionText)
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%')
  }

  /** 固定 44vp 点击区的素材类型切换；不创建新的 Sheet 或重置另一类素材的草稿。 */
  @Builder
  private KindTabs_() {
    Row({ space: 4 }) {
      Button('皮肤').layoutWeight(1).height(44).fontSize(16).borderRadius(22)
        .fontColor(this.activeKind === 'skin' ? this.theme.actionText : this.theme.textSecondary)
        .backgroundColor(this.activeKind === 'skin' ? this.theme.bgCard : Color.Transparent)
        .enabled(!this.busy).onClick((): void => { this.changeKind_('skin'); })
      Button('披风').layoutWeight(1).height(44).fontSize(16).borderRadius(22)
        .fontColor(this.activeKind === 'cape' ? this.theme.actionText : this.theme.textSecondary)
        .backgroundColor(this.activeKind === 'cape' ? this.theme.bgCard : Color.Transparent)
        .enabled(!this.busy).onClick((): void => { this.changeKind_('cape'); })
    }.width('100%').height(52).padding(4).borderRadius(26).backgroundColor(this.theme.bgInput)
  }

  /** 导入操作保留旧自动化ID；文件选择和真实PNG校验继续交给既有协调器。 */
  @Builder
  private ImportButton_() {
    Button('＋ 导入').height(44).fontSize(14).fontColor(this.theme.actionText)
      .backgroundColor(this.theme.primaryLight).borderRadius(22).enabled(!this.busy)
      .id(this.activeKind === 'skin' ? 'offline-import-skin' : 'offline-import-cape')
      .onClick((): void => { this.import_(this.activeKind); })
  }

  /** 手机两行工具区、平板同行工具区，均给导入和管理提供至少44vp热区。 */
  @Builder
  private LibraryControls_() {
    if (this.wide_()) {
      Row({ space: 12 }) {
        Row() { this.KindTabs_(); }.width(216)
        Blank().layoutWeight(1)
        Button('管理').height(44).fontSize(14).fontColor(this.theme.textSecondary)
          .backgroundColor(this.theme.bgCard).enabled(!this.busy).onClick((): void => { this.manage_(); })
        this.ImportButton_();
      }.width('100%')
    } else {
      this.KindTabs_();
      Row({ space: 8 }) {
        Text('共享' + this.kindName_() + '库 · ' + this.items_().length)
          .fontSize(14).fontColor(this.theme.textSecondary).layoutWeight(1)
        Button('管理').height(44).fontSize(14).fontColor(this.theme.textSecondary)
          .backgroundColor(Color.Transparent).enabled(!this.busy).onClick((): void => { this.manage_(); })
        this.ImportButton_();
      }.width('100%')
    }
    if (this.wide_()) {
      Row() {
        Text('共享' + this.kindName_() + '库 · ' + this.items_().length)
          .fontSize(14).fontColor(this.theme.textSecondary).layoutWeight(1)
        Text('所有离线账号可用').fontSize(14).fontColor(this.theme.textHint)
      }.width('100%')
    }
  }

  /**
   * 通栏素材网格先放“默认/不佩戴”选项，再放稳定资产ID条目。栅格自然向下延伸，
   * 不固定图库高度，因此字体放大或更多素材时由外层 Scroll 承担滚动。
   */
  @Builder
  private LibraryGrid_() {
    GridRow({ columns: this.contentWidth > 0 && this.contentWidth < 360 ? 2 : 3, gutter: { x: 12, y: 12 } }) {
      GridCol({ span: 1 }) {
        OfflineAppearanceAssetTile({ theme: this.theme, kind: this.activeKind,
          name: this.activeKind === 'skin' ? '游戏默认' : '不佩戴', isDefault: true,
          selected: this.activeKind === 'skin' ? this.selectedSkinId.length === 0 : this.selectedCapeId.length === 0,
          busy: this.busy, wide: this.wide_(), onSelect: (): void => { this.chooseDefault_(); } })
      }
      ForEach(this.items_(), (asset: AppearanceAsset) => {
        GridCol({ span: 1 }) {
          OfflineAppearanceAssetTile({ theme: this.theme, source: 'amcl-texture:' + asset.relativePath,
            name: asset.name, kind: asset.kind, widthPx: asset.width, heightPx: asset.height,
            selected: asset.kind === 'skin' ? this.selectedSkinId === asset.id : this.selectedCapeId === asset.id,
            slim: asset.id === this.selectedSkinId && this.model === 'SLIM' && asset.height !== 32,
            busy: this.busy, wide: this.wide_(), onSelect: (): void => { this.choose_(asset); } })
            .id('offline-asset-' + asset.id)
        }
      }, (asset: AppearanceAsset): string => asset.id)
    }.width('100%')
    if (this.items_().length === 0) {
      Column({ space: 8 }) {
        Text('还没有导入' + this.kindName_()).fontSize(16).fontColor(this.theme.textPrimary)
        Text(this.activeKind === 'skin' ? '可先使用游戏默认皮肤，也可导入自己的 PNG。' : '可暂不佩戴披风，或导入自己的 PNG。')
          .fontSize(14).fontColor(this.theme.textSecondary)
      }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
    }
    Text(this.activeKind === 'skin' ? 'PNG ≤ 1 MiB · 皮肤支持 64×64 / 64×32' : 'PNG ≤ 1 MiB · 披风支持 64×32')
      .fontSize(this.wide_() ? 14 : 12).fontColor(this.theme.textHint).width('100%')
    if (this.activeKind === 'skin' && this.oldSkin_()) {
      Text('64×32 旧版皮肤固定使用 Classic。').fontSize(14).fontColor(this.theme.textSecondary).width('100%')
    }
  }

  /**
   * 管理库只浏览共享资产及其使用情况，不通过行点击切换外观。正常选择页不放红色删除，
   * 管理页也只在选定未使用素材后显示确认区，避免误触删除与外观选择混用。
   */
  @Builder
  private ManagementContent_() {
    Text('所有离线账号共用此素材库。导入后可分别选择，取消编辑也会保留导入。')
      .fontSize(14).fontColor(this.theme.textSecondary).width('100%')
    Row() {
      Text('已导入 ' + this.items_().length + ' 张' + this.kindName_())
        .fontSize(14).fontColor(this.theme.textSecondary).layoutWeight(1)
      this.ImportButton_();
    }.width('100%')
    Column() {
      ForEach(this.items_(), (asset: AppearanceAsset, index: number) => {
        if (index > 0) { Divider().color(this.theme.divider).strokeWidth(0.5).margin({ left: 16, right: 16 }) }
        OfflineTextureLibraryRow({ theme: this.theme, source: 'amcl-texture:' + asset.relativePath,
          name: asset.name, kind: asset.kind, widthPx: asset.width, heightPx: asset.height,
          busy: this.busy, used: getAccountManager().isAppearanceAssetUsed(asset.id),
          onMore: (): void => { this.remove_(asset); } })
      }, (asset: AppearanceAsset): string => asset.id)
    }.width('100%').backgroundColor(this.theme.bgCard).borderRadius(20).clip(true)
    if (this.items_().length === 0) {
      Text('共享' + this.kindName_() + '库为空，可先导入一张 PNG。')
        .fontSize(14).fontColor(this.theme.textHint).width('100%').padding(16)
    }
    if (this.pendingDeleteId.length > 0) {
      Column({ space: 12 }) {
        Text(this.pendingDeleteName_()).fontSize(14).fontColor(this.theme.textSecondary).width('100%')
        Text('从共享库删除此素材？').fontSize(16).fontColor(this.theme.errorText).width('100%')
        Text('再次确认后删除；正在被账号使用的素材不可删除。')
          .fontSize(14).fontColor(this.theme.textSecondary).width('100%')
        Row({ space: 12 }) {
          Button('保留').layoutWeight(1).height(44).fontSize(14).backgroundColor(this.theme.bgInput)
            .fontColor(this.theme.textPrimary).enabled(!this.busy).onClick((): void => { this.pendingDeleteId = ''; this.notice = ''; })
          Button('确定删除').layoutWeight(1).height(44).fontSize(14).backgroundColor(this.theme.errorBg)
            .fontColor(this.theme.errorText).enabled(!this.busy).id('offline-asset-delete-confirm')
            .onClick((): void => { this.confirmDelete_(); })
        }.width('100%')
      }.width('100%').padding(16).backgroundColor(this.theme.bgCard).borderRadius(20)
        .border({ width: 1, color: this.theme.divider })
    }
  }

  /** 固定底栏只提交当前账号：平板主次按钮收在右侧，手机继续使用方便单手操作的双按钮。 */
  @Builder
  private Footer_() {
    if (this.wide_()) {
      Row({ space: 16 }) {
        Text('仅应用到此账号\n下次启动游戏生效。').fontSize(14).fontColor(this.theme.textSecondary).layoutWeight(1)
        Button('取消').width(100).height(48).fontSize(16).fontColor(this.theme.textPrimary)
          .backgroundColor(this.theme.bgInput).borderRadius(24).enabled(!this.saving)
          .onClick((): void => { this.close_(); })
        Row() { this.ApplyButton_(); }.width(196).height(48)
      }.width('100%').padding({ left: 24, right: 24, top: 12, bottom: 12 })
    } else {
      Column({ space: 8 }) {
        Text('仅应用到此账号，下次启动游戏生效。').fontSize(14).fontColor(this.theme.textSecondary).width('100%')
        Row({ space: 12 }) {
          Button('取消').layoutWeight(1).height(48).fontSize(16).fontColor(this.theme.textPrimary)
            .backgroundColor(this.theme.bgInput).borderRadius(24).enabled(!this.saving)
            .onClick((): void => { this.close_(); })
          Row() { this.ApplyButton_(); }.layoutWeight(2).height(48)
        }.width('100%')
      }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
    }
  }

  /**
   * 两种底栏共用唯一应用按钮与自动化 ID。Builder 无值参数，直接读取当前保存/忙态，
   * 避免分支重复声明 ID 或把状态快照传给 Builder；固定宽度和权重由调用处控制。
   */
  @Builder
  private ApplyButton_() {
    Button(this.saving ? '正在保存…' : '应用到此账号').width('100%').height(48).fontSize(16)
      .fontColor(this.theme.textOnPrimary).backgroundColor(this.theme.actionPrimary).borderRadius(24)
      .enabled(this.ready && !this.busy).id('offline-appearance-apply').onClick((): void => { this.apply_(); })
  }
}

/**
 * 正常选择页的素材项。简单Prop承载选中/模型状态，避免Builder按值参数丢失后续更新。
 * 缩略图只是预览，不把纹理资产标成固定Classic/Slim；模型仍由当前账号独立选择。
 */
@Component
struct OfflineAppearanceAssetTile {
  @Prop theme: ThemeColors = {} as ThemeColors;
  @Prop source: string = '';
  @Prop name: string = '';
  @Prop kind: AppearanceKind = 'skin';
  @Prop widthPx: number = 64;
  @Prop heightPx: number = 64;
  @Prop selected: boolean = false;
  @Prop isDefault: boolean = false;
  @Prop slim: boolean = false;
  @Prop busy: boolean = false;
  @Prop wide: boolean = false;
  onSelect: () => void = (): void => {};

  build() {
    Column({ space: 8 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Row() {
          if (this.isDefault) {
            AppIcon({ name: this.kind === 'skin' ? AppIconName.Person : AppIconName.Close,
              iconSize: 28, color: this.theme.textHint })
          } else if (this.kind === 'skin') {
            SkinCanvas3D({ skinUrl: this.source, isOffline: true, slim: this.slim,
              containerWidth: 80, containerHeight: this.wide ? 128 : 100, theme: this.theme })
              .width('100%').height(this.wide ? 128 : 100)
          } else {
            CapePreview({ capeUrl: this.source, alias: this.name, containerWidth: 40,
              containerHeight: 64, theme: this.theme })
          }
        }.width('100%').height(this.wide ? 128 : 100).justifyContent(FlexAlign.Center)
        if (this.selected) {
          Row() {
            AppIcon({ name: AppIconName.Check, iconSize: 14, color: this.theme.textOnPrimary })
          }.width(24).height(24).justifyContent(FlexAlign.Center).borderRadius(12)
            .backgroundColor(this.theme.actionPrimary).margin(6).hitTestBehavior(HitTestMode.None)
        }
      }.width('100%').backgroundColor(this.selected ? this.theme.primaryLight : this.theme.bgCard)
        .borderRadius(16).clip(true).border({ width: this.selected ? 2 : 1, color: this.selected ? this.theme.actionText : this.theme.divider })
      Text(this.name).fontSize(this.wide ? 16 : 14).fontWeight(this.selected ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.selected ? this.theme.actionText : this.theme.textPrimary).width('100%')
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.wide) {
        Text(this.isDefault ? (this.kind === 'skin' ? '跟随游戏默认外观' : '不佩戴披风') : this.widthPx + ' × ' + this.heightPx)
          .fontSize(14).fontColor(this.theme.textSecondary).width('100%')
      }
    }.width('100%').enabled(!this.busy).accessibilityGroup(true)
      .accessibilityText(this.name + (this.selected ? '，已选中' : '，选择此' + (this.kind === 'skin' ? '皮肤' : '披风')))
      .onClick((): void => { this.onSelect(); })
  }
}

/** 管理行仅提供查看与更多操作，删除确认由父编辑器统一持有，防止列表各行独立武装。 */
@Component
struct OfflineTextureLibraryRow {
  @Prop theme: ThemeColors = {} as ThemeColors;
  @Prop source: string = '';
  @Prop name: string = '';
  @Prop kind: AppearanceKind = 'skin';
  @Prop widthPx: number = 64;
  @Prop heightPx: number = 64;
  @Prop busy: boolean = false;
  @Prop used: boolean = false;
  onMore: () => void = (): void => {};

  build() {
    Row({ space: 12 }) {
      if (this.kind === 'skin') {
        MinecraftHeadAvatar({ skinUrl: this.source, diameter: 44, fallbackLetter: '?',
          bgColor: this.theme.bgInput, letterColor: this.theme.textHint })
      } else {
        CapePreview({ capeUrl: this.source, containerWidth: 28, containerHeight: 44, theme: this.theme })
      }
      Column({ space: 4 }) {
        Text(this.name).fontSize(16).fontColor(this.theme.textPrimary).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.widthPx + ' × ' + this.heightPx + (this.used ? ' · 账号使用中' : ' · 未被使用'))
          .fontSize(14).fontColor(this.theme.textSecondary)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Button({ type: ButtonType.Circle }) {
        AppIcon({ name: AppIconName.More, iconSize: 20, color: this.theme.textSecondary })
      }.width(44).height(44).backgroundColor(Color.Transparent).enabled(!this.busy)
        .accessibilityText('管理 ' + this.name).onClick((): void => { this.onMore(); })
    }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 }).constraintSize({ minHeight: 76 })
  }
}
