/**
 * LayoutListPage.ets — 按键布局方案列表（Phase D 键鼠适配重构）
 *
 * 入口：SettingsTab 点 "按键布局" → router.pushUrl('pages/LayoutListPage')
 * 行为：
 *   - 不强制方向（手机自然竖屏，平板自然横屏均可）
 *   - 渲染所有方案的 16:9 缩略图卡片
 *   - 卡片操作：使用 / 编辑 / 克隆 / 删除（系统预设只能克隆不能删）；存储拒绝时显示原因
 *   - 顶部常驻布局存档加载异常的非阻塞提示（隔离 / 修复 / 改名 / 写入封锁，来自 getLoadIssues）
 *   - 点击 [编辑] → router.pushUrl('pages/LayoutEditorPage', { profileName }) → 横屏编辑器
 *   - 编辑器 router.back() → 自动回到本页
 *   - 本页再返回 → 回设置页
 */
import { router, window, promptAction } from '@kit.ArkUI'
import { common, ConfigurationConstant } from '@kit.AbilityKit'
import { PreferenceManager } from 'feature_system'
import { applyNativeTheme } from '../components/AppTheme'
import { picker } from '@kit.CoreFileKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { fileUri } from '@kit.CoreFileKit'
import { systemShare } from '@kit.ShareKit'
import { LayoutProfile, LayoutDeletionReview, ImportAnalysis, LayoutLoadIssues, initialControlGroupVisible } from 'gamecontrol'
import { LayoutThumbnail } from '../components/LayoutThumbnail'
import { getLayoutStore, LayoutStore } from 'gamecontrol'
import { AppIconName } from 'commons'
import { AppIcon } from '../components/AppIcon'
import { ThemeColors, ThemeMode, resolveTheme } from 'commons'
import { ImmersiveTitleScaffold } from '../components/ImmersiveTitleScaffold'
import { ProductInputProfile } from 'entry/ProductInputProfile'
import { GameRunAdmission } from '../runtime/GameRunAdmission';
import { LayoutDraftAccess } from '../launcherskill/LayoutDraftAccess';
import { LauncherSkillBus, SkillFields } from '../launcherskill/LauncherSkillBus';
import { layoutCatalogPage, layoutCatalogPageCount, clampLayoutCatalogPage, layoutCatalogContainingPage } from '../components/LayoutCatalogPaging'

/** 路由参数：从「打开方式」经 Index 跳入时携带待导入文件 uri。 */
interface LayoutListRouteParams {
  importUri?: string
}

@Entry
@Component
struct LayoutListPage {
  /** 目录chrome跟随应用快照；缩略图仍使用用户实际保存的按键颜色和样式。 */
  @State private titleTheme: ThemeColors = resolveTheme(ThemeMode.SYSTEM, false)
  @StorageProp('currentColorMode') @Watch('applyToolTheme_') private colorMode_: number = 0
  @StorageProp('appThemeRevision') @Watch('applyToolTheme_') private appThemeRevision_: number = 0
  @StorageProp('topRectHeight') private topSafeHeight: number = 0
  @State profileNames: string[] = []
  /** 大库只绘制一页卡片，全部目录仍可连续翻页或直接定位活动方案。 */
  @State profilePage: number = 0
  private catalogPageInitialized: boolean = false
  @State activeName: string = '默认'
  @State statusMsg: string = ''
  // 布局存档加载异常的非阻塞提示（隔离 / 修复 / 改名 / 写入封锁）；空串表示本次加载一切正常。
  // 与 statusMsg 分开：操作提示会被下一次操作覆盖，而这条提示必须在整个页面生命周期内可见。
  @State loadNotice: string = ''
  @State pageWidth: number = 360
  // 改名浮层：renameTarget 非空时显示，renameDraft 为输入草稿。
  @State renameTarget: string = ''
  @State renameDraft: string = ''
  @State private creatingCopy: boolean = false
  @State private mutationBusy: boolean = false
  /** 命名面板只持冻结来源，取消不调用Store，也不提前创建副本。 */
  private copySource: LayoutProfile | undefined = undefined

  private store: LayoutStore = getLayoutStore()
  /** 异步预览/确认属于当前页面代次，迟到对话框不能在页面离开后新增布局。 */
  private importPageGeneration: number = 0
  private importPageMounted: boolean = false
  @State importBusy: boolean = false
  private selectingLayout_: boolean = false
  private deletionState_: string = 'idle'
  private deletionId_: string = ''
  private lastImport_: SkillFields = { 'state':'idle' }

  private getAbilityContext(): common.UIAbilityContext {
    return AppStorage.get<common.UIAbilityContext>('uiAbilityContext')!
  }

  /** 主题变化只刷新外围显示，不触发目录重扫、预设激活或布局存档写入。 */
  private applyToolTheme_(): void {
    const preferences: PreferenceManager = new PreferenceManager(this.getAbilityContext())
    this.titleTheme = resolveTheme(preferences.themeMode,
      this.colorMode_ === ConfigurationConstant.ColorMode.COLOR_MODE_DARK, preferences.themeAccent)
    applyNativeTheme(this.titleTheme)
  }

  /** 装载告警、方案 ID 和修订均来自 LayoutStore 的提交快照；写入重新核对三者。 */
  private async catalogSkill_(method: string,args: SkillFields): Promise<SkillFields> {
    if (!this.importPageMounted || !ProductInputProfile.supportsTouchLayouts()) return { 'state':'unavailable' };
    if (this.importBusy || this.mutationBusy || this.selectingLayout_ || this.renameTarget) return { 'state':'busy' };
    if (method === 'readWorkbenchOutcome') return LayoutDraftAccess.outcome(String(args['draftRef']));
    if (method === 'listControlLayouts') {
      this.refreshList();
      const offset = Number(args['offset'] ?? 0);
      if (!Number.isSafeInteger(offset) || offset < 0) return { 'state':'failed','reason':'invalidOffset' };
      const rows: SkillFields[] = [];
      for (const name of this.profileNames.slice(offset,offset+24)) {
        const p = this.store.getProfile(name);
        if (p) rows.push({ 'name':name,'id':p.profileId ?? '', 'revision':p.profileRevision ?? 1,
          'preset':p.isPreset === true,'active':this.activeName===name,'controls':p.controls.length });
      }
      return { 'state':'ready','total':this.profileNames.length,'items':rows,'hasWarnings':!!this.loadNotice,
        'deletionState':this.deletionState_,'deletionId':this.deletionId_, 'lastImport':this.lastImport_ };
    }
    if (this.deletionState_ === 'pending') return { 'state':'needsUser','surface':'confirmDelete' };
    if (method === 'importControlLayout') return this.doImport();
    const name = String(args['name']);
    const p = this.store.getProfile(name);
    if (!p || !p.profileId || p.profileId !== args['layoutId'] || (p.profileRevision ?? 1) !== args['revision']) return { 'state':'unavailable','reason':'staleLayout' };
    if (method === 'useControlLayout') {
      await this.useProfile_(name,p);
      return { 'state':this.store.getActiveProfile().profileId===p.profileId ? 'ready':'unknown' };
    }
    if (method === 'copyControlLayout' || method === 'renameControlLayout') {
      const next = String(args['newName']).trim();
      if (!next || next.length>40 || (method === 'renameControlLayout' && p.isPreset)) return { 'state':'failed','reason':'invalidNameOrPreset' };
      const copy = method === 'copyControlLayout';
      this.copySource=copy ? p : undefined; this.creatingCopy=copy; this.renameTarget=name; this.renameDraft=next;
      const result = await this.doRename(p);
      return result ? { 'state':'ready','id':result.profileId ?? '', 'name':result.name,'revision':result.profileRevision ?? 1 } : { 'state':'unknown' };
    }
    if (method === 'requestRemoveControlLayout') {
      if (!this.store.reviewProfileDeletion(name)) return { 'state':'unavailable','reason':'protected' };
      this.confirmDelete_(name); return { 'state':'needsUser','id':p.profileId };
    }
    if (method === 'exportControlLayout') {
      const legacy=args['legacy']===true;
      if (legacy && !this.canExportLegacy_(name)) return { 'state':'unavailable','reason':'notLegacyCompatible' };
      return this.doExport(name,legacy);
    }
    if (method === 'shareControlLayout') return this.doShare(name);
    if (method === 'openLayoutWorkbench') {
      const options = args['view'];
      if (options !== 'geometry' && options !== 'input') return { 'state':'failed','reason':'view' };
      const opened=await this.openProfileEditor_(name,options==='input');
      return { 'state':opened ? 'needsUser':'failed','name':name };
    }
    return { 'state':'failed','reason':'unknownOperation' };
  }

  async aboutToAppear(): Promise<void> {
    this.applyToolTheme_()
    this.importPageGeneration++
    this.importPageMounted = true
    this.selectingLayout_=false; this.deletionState_='idle'; this.deletionId_=''
    this.mutationBusy=false; this.renameTarget=''; this.copySource=undefined; this.creatingCopy=false
    if (!ProductInputProfile.supportsTouchLayouts()) {
      this.getUIContext().getRouter().back()
      return
    }
    const context = this.getAbilityContext()
    await this.store.init(context)
    if (!this.importPageMounted) return
    this.refreshList()
    LauncherSkillBus.bind('layouts',this,(m: string,a: SkillFields): Promise<SkillFields> => this.catalogSkill_(m,a),(): boolean => {
      const page=this.getUIContext().getRouter().getState().name;
      return this.importPageMounted && GameRunAdmission.isAllowed() && (page==='LayoutListPage' || page==='pages/LayoutListPage');
    });
    // 不强制方向：手机竖屏 / 平板横屏都自然显示
    try {
      let win = await window.getLastWindow(context)
      if (!ProductInputProfile.selection().desktopWindow) win.setPreferredOrientation(window.Orientation.UNSPECIFIED)
      win.setWindowLayoutFullScreen(false)
      try { if (!ProductInputProfile.selection().desktopWindow) win.setWindowSystemBarEnable(['status', 'navigation']) } catch (e) { /* ignore */ }
    } catch (e) { /* ignore */ }
    // 「打开方式」跳入：带 importUri 则走导入流程（分析→设备/合法性检测→导入）。
    const rp = this.getUIContext().getRouter().getParams()
    if (rp) {
      const params = rp as LayoutListRouteParams
      if (params.importUri !== undefined && params.importUri.length > 0) {
        const uri = params.importUri
        const generation=this.importPageGeneration;
        this.lastImport_={ 'state':'accepted' };
        setTimeout(() => {
          if (this.importPageMounted && this.importPageGeneration===generation) this.analyzeAndImport(uri).then((result:SkillFields):void=>{
            if(this.importPageMounted && this.importPageGeneration===generation)this.lastImport_=result;
          });
        }, 60)
      }
    }
  }

  aboutToDisappear(): void {
    LauncherSkillBus.unbind('layouts',this);
    this.importPageMounted = false
    this.importPageGeneration++
  }

  /** Phase D：从编辑器回到本页时刷一次列表（编辑器保存后名字 / active 可能变化）。 */
  onPageShow(): void {
    this.applyToolTheme_()
    this.refreshList()
  }

  private refreshList(): void {
    this.profileNames = this.store.getProfileNames()
    this.activeName = this.store.getActiveProfile().name
    this.profilePage=this.catalogPageInitialized ? clampLayoutCatalogPage(this.profileNames,this.profilePage) :
      layoutCatalogContainingPage(this.profileNames,this.activeName)
    this.catalogPageInitialized=true
    this.loadNotice = this.describeLoadIssues(this.store.getLoadIssues())
  }

  /**
   * 把存储给出的加载异常摘要翻成一行用户提示。只描述数量与后果，不列出方案名或原文；
   * 写入封锁时附上存储给出的原因，让用户知道为什么“保存/新建”会失败，以及原数据仍然完整。
   */
  private describeLoadIssues(issues: LayoutLoadIssues): string {
    const parts: string[] = []
    if (issues.documentQuarantined) parts.push('布局存档无法解析，已原样隔离保存，当前仅显示系统预设')
    if (issues.quarantinedProfiles > 0) {
      parts.push(issues.quarantinedProfiles.toString() + ' 个方案无法读取，已原样隔离保存')
    }
    if (issues.repairedProfiles > 0) {
      parts.push(issues.repairedProfiles.toString() + ' 个方案的控件标识已自动修复（原数据已备份）')
    }
    if (issues.renamedProfiles > 0) parts.push(issues.renamedProfiles.toString() + ' 个重名方案已自动改名保留')
    if (issues.activeFallback) parts.push('上次使用的方案无法读取，已切换到系统预设')
    if (issues.writeBlocked && issues.writeBlockMessage.length > 0) parts.push(issues.writeBlockMessage)
    return parts.join('；')
  }

  private isPreset(name: string): boolean {
    const p = this.store.getProfile(name)
    return p ? !!p.isPreset : false
  }

  private getProfile(name: string): LayoutProfile | null {
    return this.store.getProfile(name)
  }

  /**
   * ForEach按键值复用整张卡片。编辑后名字不变，普通Store对象又不是ArkUI可观察状态，
   * 只用名字会继续显示旧缩略图和旧组数。把已持久化的方案修订纳入键，只有内容改变
   * 的当前页卡片重建；翻页仍只读取当前页payload，不能为刷新缩略图展开整个大库。
   */
  private profileCardKey_(name: string): string {
    const profile: LayoutProfile | null = this.getProfile(name)
    return name + ':' + (profile?.profileRevision ?? 0).toString()
  }

  /** lg 断点（≥840vp）走双列。简单按 pageWidth 判断。 */
  private isWide(): boolean {
    return this.pageWidth >= 840
  }

  /** 缩略图宽度：单列时按页面宽减边距，双列时减一半 + gap */
  private thumbnailWidth(): number {
    const padding = 32  // 卡片左右 padding 总和
    if (this.isWide()) {
      return Math.floor((this.pageWidth - 48) / 2 - padding)
    }
    return this.pageWidth - 24 - padding  // sm/md：单列 12vp 边距
  }

  /** 预估某卡片高度（用于两列 masonry 的贪心分配）。缩略图高随 targetDevice 比例 + 固定 chrome。 */
  private estimateCardHeight(name: string): number {
    const w = this.thumbnailWidth()
    const p = this.getProfile(name)
    // 缩略图高宽比：平板 ≈ 0.66（本机 3:2 / 通用 16:10），手机/其它 ≈ 0.462（19.5:9）。
    let ratio = 0.462
    if (p !== null && (p.targetDevice === 'tablet' || p.targetDevice === 'foldable')) ratio = 0.66
    // chrome：标题行 + 描述行 + 操作按钮行 + 卡片 padding/间距，约 130vp。
    return w * ratio + 130
  }

  /** 两列 masonry 分配：按顺序把方案放进当前累计高度较小的列。col=0 左列、1 右列。 */
  private columnNames(col: number): string[] {
    const left: string[] = []
    const right: string[] = []
    let lh = 0
    let rh = 0
    const page: string[] = this.profilePageNames_()
    for (let i = 0; i < page.length; i++) {
      const name = page[i]
      const h = this.estimateCardHeight(name)
      if (lh <= rh) { left.push(name); lh += h }
      else { right.push(name); rh += h }
    }
    return col === 0 ? left : right
  }

  private profilePageNames_(): string[] { return layoutCatalogPage(this.profileNames,this.profilePage) }
  private profilePageCount_(): number { return layoutCatalogPageCount(this.profileNames) }
  private moveProfilePage_(delta: number): void {
    this.profilePage=clampLayoutCatalogPage(this.profileNames,this.profilePage+delta)
  }
  private showCurrentProfilePage_(): void {
    this.profilePage=layoutCatalogContainingPage(this.profileNames,this.activeName)
  }

  /** 新建仍经过原存储拒绝与错误反馈入口，标题菜单不改变方案编号和刷新时机。 */
  private async createProfile_(): Promise<void> {
    if (this.mutationBusy || this.importBusy) return
    this.copySource=this.store.getActiveProfile()
    this.creatingCopy=true; this.renameTarget=this.copySource.name; this.renameDraft=this.copySource.name+' 副本'
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
    Column() {
      // 外层 Stack 继续拥有改名遮罩；导航容器只承载原目录正文，不改浮层层级。
      ImmersiveTitleScaffold({ title: '操控方案', theme: this.titleTheme,
        topSafeHeight: this.topSafeHeight, surfaceColor: this.titleTheme.bgPrimary,
        menuActions: [{ id: 'create-layout', label: '复制当前方案' }, { id: 'import-layout', label: '导入' }],
        onBack: (): void => { this.getUIContext().getRouter().back(); },
        onMenuAction: (id: string): void => {
          if (id === 'create-layout') this.createProfile_();
          else if (id === 'import-layout') this.doImport();
        },
        content: (): void => { this.ImmersiveTitleContent1_(); }
      })
    }
    .width('100%').height('100%').backgroundColor(this.titleTheme.bgPrimary)
    .onAreaChange((_old: Area, newVal: Area) => {
      this.pageWidth = newVal.width as number
    })

      // 改名浮层（点击卡片标题旁铅笔进入）
      if (this.renameTarget.length > 0) {
        this.RenameOverlay()
      }
    }
    .width('100%').height('100%')
  }

  /** 改名浮层：半透明遮罩 + 居中卡片（TextInput + 取消/确定）。 */
  @Builder
  RenameOverlay() {
    Column() {
      Column({ space: 14 }) {
        Text(this.creatingCopy ? '复制当前方案并使用' : '重命名方案').fontSize(16).fontColor(this.titleTheme.textPrimary).fontWeight(FontWeight.Bold)
        TextInput({ text: this.renameDraft, placeholder: '输入新名称' }).caretColor(this.titleTheme.actionText)
          .height(44).fontSize(14).width('100%')
          .maxLength(40)
          .onChange((v: string) => { this.renameDraft = v })
        Row({ space: 10 }) {
          Button('取消').fontSize(13).height(44).fontColor(this.titleTheme.textPrimary).layoutWeight(1)
            .backgroundColor(this.titleTheme.bgInput).borderRadius(19)
            .onClick(() => { if (!this.mutationBusy) { this.renameTarget = ''; this.renameDraft = ''; this.copySource=undefined; this.creatingCopy=false } })
          Button('确定').fontSize(13).height(44).fontColor(this.titleTheme.textOnPrimary).layoutWeight(1)
            .backgroundColor(this.titleTheme.actionPrimary).borderRadius(19)
            .onClick(() => { this.doRename() })
        }.width('100%')
      }
      .width('80%').constraintSize({ maxWidth: 360 })
      .padding(20)
      .backgroundColor(this.titleTheme.bgCard).borderRadius(16)
      .border({ width: 1, color: this.titleTheme.controlBorder })
      .onClick(() => { })   // 吞掉卡片内点击，避免冒泡到遮罩触发关闭
    }
    .width('100%').height('100%')
    .backgroundColor(this.titleTheme.overlayShade)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => { if (!this.mutationBusy) { this.renameTarget = ''; this.renameDraft = ''; this.copySource=undefined; this.creatingCopy=false } })
  }

  private async doRename(expected?:LayoutProfile): Promise<LayoutProfile | undefined> {
    if (this.mutationBusy || this.importBusy || !this.importPageMounted) return undefined
    const name: string=this.renameDraft.trim(), target: string=this.renameTarget
    const generation: number=this.importPageGeneration, copying: boolean=this.creatingCopy
    if (name.length===0 || name.length>40) { this.statusMsg='请输入1至40字的方案名'; return }
    const source: LayoutProfile | undefined=this.copySource
    this.mutationBusy=true
    try {
      let committed:LayoutProfile | undefined=undefined;
      if (copying) {
        if (source===undefined) throw new Error('复制来源已失效，请重新选择')
        const created: LayoutProfile=await this.store.createProfile(name,source)
        if (!this.importPageMounted || generation!==this.importPageGeneration) return
        committed=created; this.statusMsg='已复制并使用：'+created.name
      } else {
        const ok: boolean=await this.store.renameProfile(target,name,expected?.profileId,expected?.profileRevision ?? 1)
        if (!this.importPageMounted || generation!==this.importPageGeneration) return
        if (!ok) throw new Error('名称重复、预设不可改名或原方案已改变')
        committed=this.store.getProfile(name) ?? undefined; this.statusMsg='已重命名：'+name
      }
      this.renameTarget=''; this.renameDraft=''; this.creatingCopy=false; this.copySource=undefined; this.refreshList()
      return committed
    } catch (error) {
      if (this.importPageMounted && generation===this.importPageGeneration) {
        this.statusMsg=(copying ? '复制失败：' : '改名失败：')+(error as Error).message; this.refreshList()
      }
      return undefined
    } finally { if (generation===this.importPageGeneration) this.mutationBusy=false }
  }


  /** 路由明确携带所选方案；输入设置不会误编辑当前活动方案。 */
  private async openProfileEditor_(name: string, settings: boolean): Promise<boolean> {
    try { await this.getUIContext().getRouter().pushUrl({url:'pages/LayoutEditorPage',params:{profileName:name,settingsOnly:settings}}); return true }
    catch (error) { this.statusMsg='无法打开方案：'+(error as Error).message; return false }
  }

  private profileMenu_(name: string): MenuElement[] {
    const menu: MenuElement[]=[
      {value:'手感与输入',action:(): void => { this.openProfileEditor_(name,true) }},
      {value:'复制并使用',action:(): void => {
        const source: LayoutProfile | null=this.store.getProfile(name)
        if (source===null) { this.statusMsg='方案已不存在'; return }
        this.copySource=source; this.creatingCopy=true; this.renameTarget=name; this.renameDraft=name+' 副本'
      }},
      {value:'重命名',enabled:!this.isPreset(name),action:(): void => {
        this.creatingCopy=false; this.copySource=undefined; this.renameTarget=name; this.renameDraft=name
      }},
      {value:'导出',action:(): void => { this.doExport(name) }},
      {value:'分享',action:(): void => { this.doShare(name) }},
      {value:'删除…',enabled:!this.isPreset(name),action:(): void => { this.confirmDelete_(name) }}
    ]
    if (this.canExportLegacy_(name)) menu.push({value:'导出旧版兼容副本',action:(): void => { this.doExport(name,true) }})
    return menu
  }

  /** “使用”采用整份配置；在途禁重入，迟到结果不更新后来页面。 */
  private async useProfile_(name: string, expected?:LayoutProfile): Promise<void> {
    if (this.mutationBusy || this.importBusy) return
    const generation: number=this.importPageGeneration; this.mutationBusy=true
    try {
      await this.store.setActiveProfile(name,expected?.profileId,expected?.profileRevision ?? 1)
      if (this.importPageMounted && generation===this.importPageGeneration) { this.refreshList(); this.statusMsg='已使用完整操控方案：'+name }
    } catch (error) {
      if (this.importPageMounted && generation===this.importPageGeneration) { this.refreshList(); this.statusMsg='采用失败：'+(error as Error).message }
    } finally { if (generation===this.importPageGeneration) this.mutationBusy=false }
  }

  /** 原生确认只冻结意图，不预删卡片；Store在事务内再次核对ID、修订与回退身份。 */
  private confirmDelete_(name: string): void {
    if (this.mutationBusy || this.importBusy) return
    const review: LayoutDeletionReview | null=this.store.reviewProfileDeletion(name)
    if (review===null) { this.statusMsg='该方案不能删除，或没有可用的回退方案'; return }
    const generation: number=this.importPageGeneration
    this.deletionId_=review.profileId; this.deletionState_='pending'
    let committing = false, offered = true;
    LauncherSkillBus.followUserCondition('requestRemoveControlLayout', (): boolean => committing ||
      (offered && this.importPageMounted && generation===this.importPageGeneration && this.deletionId_===review.profileId && this.deletionState_==='pending'));
    const cancelled=():void=>{offered=false;if(this.importPageMounted && generation===this.importPageGeneration && this.deletionId_===review.profileId)this.deletionState_='cancelled'}
    this.getUIContext().showAlertDialog({title:'删除操控方案「'+review.name+'」', cancel:cancelled,
      message:'将删除此方案的布局、触控、视角和手柄设置。'+
        (review.profileId===review.activeId ? '\n删除后将使用「'+review.fallbackName+'」。' : '')+'\n确认后不能在此页面撤销。',
      primaryButton:{value:'取消',action:cancelled},secondaryButton:{value:'删除方案',action:(): void=>{
        offered = false;
        if (this.importPageMounted && generation===this.importPageGeneration) {
          committing = true;
          this.deleteConfirmed_(review,generation).finally((): void => { committing = false; });
        }
      }}})
  }

  private async deleteConfirmed_(review: LayoutDeletionReview,generation: number): Promise<void> {
    if (this.mutationBusy || this.importBusy || !this.importPageMounted) return
    this.mutationBusy=true
    try {
      const deleted: boolean=await this.store.deleteReviewedProfile(review)
      if (!this.importPageMounted || generation!==this.importPageGeneration) return
      this.refreshList()
      this.deletionState_=deleted ? 'ready' : 'changed'
      this.statusMsg=deleted ? '已删除：'+review.name : '方案或回退选择已改变，本次未删除，请重新确认'
    } catch (error) {
      if (this.importPageMounted && generation===this.importPageGeneration) {
        this.deletionState_='failed'; this.refreshList(); this.statusMsg='删除失败，原方案保留：'+(error as Error).message
      }
    } finally { if (generation===this.importPageGeneration) this.mutationBusy=false }
  }

  @Builder
  ProfileCard(name: string) {
    Column({ space: 10 }) {
      // 标题行
      Row({ space: 8 }) {
        Row().width(9).height(9).borderRadius(5)
          .backgroundColor(name === this.activeName ? this.titleTheme.actionText : this.titleTheme.disabledText)
        Text(name)
          .fontSize(15)
          .fontColor(name === this.activeName ? this.titleTheme.textPrimary : this.titleTheme.textSecondary)
          .fontWeight(name === this.activeName ? FontWeight.Bold : FontWeight.Medium)
          .layoutWeight(1)
        // 改名：仅非系统预设可改（默认两个预设不可改名）。
        if (!this.isPreset(name)) {
          Row() {
            AppIcon({ name: AppIconName.Edit, iconSize: 15, color: this.titleTheme.textSecondary })
          }
          .width(30).height(30).justifyContent(FlexAlign.Center)
          .onClick(() => { this.creatingCopy=false; this.copySource=undefined; this.renameTarget = name; this.renameDraft = name })
        }
        if (this.isPreset(name)) {
          Text('系统').fontSize(10).fontColor(this.titleTheme.actionText).fontWeight(FontWeight.Medium)
            .backgroundColor(this.titleTheme.primaryLight)
            .borderRadius(8).padding({ left: 7, right: 7, top: 3, bottom: 3 })
        }
        if (name === this.activeName) {
          Text('当前').fontSize(10).fontColor(this.titleTheme.textOnPrimary).fontWeight(FontWeight.Medium)
            .backgroundColor(this.titleTheme.actionPrimary)
            .borderRadius(8).padding({ left: 7, right: 7, top: 3, bottom: 3 })
        }
      }

      // 缩略图（按 targetDevice 的真实屏幕比例：手机≈19.5:9 / 平板≈16:10）
      if (this.getProfile(name) !== null) {
        LayoutThumbnail({
          profile: this.getProfile(name)!,
          viewWidth: this.thumbnailWidth()
        })
      }

      // 描述行：按钮数量
      Row() {
        Text(this.cardDescription(name))
          .fontSize(11).fontColor(this.titleTheme.textSecondary).layoutWeight(1)
      }

      Text('含布局、触控、视角与手柄设置').fontSize(12).fontColor(this.titleTheme.textSecondary).width('100%')
      Row({space:8}) {
        Button(name===this.activeName ? '当前使用' : '使用').height(44).fontSize(13).layoutWeight(1)
          .enabled(name!==this.activeName && !this.mutationBusy && !this.importBusy)
          .backgroundColor(this.titleTheme.primaryLight).fontColor(this.titleTheme.actionText)
          .onClick((): void => { this.useProfile_(name) })
        Button('编辑布局').height(44).fontSize(13).layoutWeight(1).enabled(!this.mutationBusy && !this.importBusy)
          .backgroundColor(this.titleTheme.actionPrimary).fontColor(this.titleTheme.textOnPrimary)
          .onClick((): void => { this.openProfileEditor_(name,false) })
        Button('更多').height(44).fontSize(13).layoutWeight(1).enabled(!this.mutationBusy && !this.importBusy)
          .backgroundColor(this.titleTheme.bgInput).fontColor(this.titleTheme.textPrimary)
          .bindMenu(this.profileMenu_(name)).accessibilityText(name+'，更多操作')
      }.width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor(name === this.activeName ? this.titleTheme.primaryLight : this.titleTheme.bgCard)
    .borderRadius(14)
    .border({
      width: name === this.activeName ? 1.5 : 0,
      color: this.titleTheme.actionText
    })
  }

  /** 组方案不能降写成不含引用关系的旧格式；只提供仍可无损表达的来源政策兼容导出。 */
  private canExportLegacy_(name: string): boolean {
    const profile: LayoutProfile | null=this.getProfile(name)
    return profile !== null && profile.lookPolicies !== undefined && profile.controlGroups === undefined
  }

  private cardDescription(name: string): string {
    const p = this.getProfile(name)
    if (!p) return ''
    let visibleCount = 0
    for (let i = 0; i < p.controls.length; i++) {
      if (!p.controls[i].hidden && p.controls[i].visibilityOverride !== 'force_hide' && initialControlGroupVisible(p,p.controls[i])) visibleCount++
    }
    let parts: string[] = []
    if (p.controlGroups !== undefined) parts.push(p.controlGroups.length.toString()+' 组 · 初始显示')
    parts.push(visibleCount.toString() + ' 个按钮')
    parts.push('缩放 ' + Math.round(p.globalScale * 100).toString() + '%')
    if (p.targetDevice && p.targetDevice !== 'any') {
      let label: string = p.targetDevice as string
      if (label === 'phone') label = '手机'
      else if (label === 'tablet') label = '平板'
      else if (label === 'foldable') label = '折叠机'
      parts.push(label)
    }
    return parts.join('  ·  ')
  }

  private async doExport(name: string, legacyCompatible: boolean = false): Promise<SkillFields> {
    try {
      const json = this.store.exportToJson(name, legacyCompatible)
      const savePicker = new picker.DocumentSaveOptions()
      savePicker.newFileNames = ['layout_' + name + (legacyCompatible ? '_v3' : '') + '.json']
      const documentPicker = new picker.DocumentViewPicker(this.getAbilityContext())
      LauncherSkillBus.awaitingUser('exportControlLayout');
      const result = await documentPicker.save(savePicker)
      if (result && result.length > 0) {
        const file = fs.openSync(result[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
        try { fs.writeSync(file.fd, json) } finally { fs.closeSync(file) }
        this.statusMsg = legacyCompatible ? '已导出旧版兼容副本；原独立来源方案仍保留' : '已导出: ' + name
        return { 'state':'ready','saved':true }
      }
      return { 'state':'cancelled' }
    } catch (e) {
      this.statusMsg = '导出失败: ' + (e as Error).message
      return { 'state':'failed','reason':'exportFailed' }
    }
  }

  /** 用鸿蒙原生系统分享面板分享该方案（写临时 .json 到缓存目录再以文件形式分享）。 */
  private async doShare(name: string): Promise<SkillFields> {
    try {
      const json = this.store.exportToJson(name)
      const ctx = this.getAbilityContext()
      const safe = name.replace(/[\\/:*?"<>|]/g, '_')
      const path = ctx.cacheDir + '/layout_' + safe + '.json'
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
      try { fs.writeSync(file.fd, json) } finally { fs.closeSync(file) }
      const uri = fileUri.getUriFromPath(path)
      const record: systemShare.SharedRecord = {
        utd: 'general.json',
        uri: uri,
        title: name,
        label: 'AMCL 按键布局方案'
      }
      const data = new systemShare.SharedData(record)
      const controller = new systemShare.ShareController(data)
      LauncherSkillBus.awaitingUser('shareControlLayout');
      await controller.show(ctx, {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DETAIL
      })
      return { 'state':'needsUser','surface':'systemShare' }
    } catch (e) {
      this.statusMsg = '分享失败: ' + (e as Error).message
      return { 'state':'failed','reason':'shareUnavailable' }
    }
  }

  private deviceLabel(d: string): string {
    if (d === 'phone') return '手机'
    if (d === 'tablet') return '平板'
    if (d === 'foldable') return '折叠机'
    if (d === 'any') return '通用'
    return '未知'
  }

  private async doImport(): Promise<SkillFields> {
    if (!this.importPageMounted || this.importBusy || this.selectingLayout_) return { 'state':'busy' }
    const generation=this.importPageGeneration; this.selectingLayout_=true
    try {
      const openPicker = new picker.DocumentSelectOptions()
      const documentPicker = new picker.DocumentViewPicker(this.getAbilityContext())
      LauncherSkillBus.awaitingUser('importControlLayout');
      const result = await documentPicker.select(openPicker)
      if (!this.importPageMounted || generation!==this.importPageGeneration) return { 'state':'unknown' }
      if (!result || result.length === 0) return { 'state':'cancelled' }
      const outcome = await this.analyzeAndImport(result[0]);
      if (this.importPageMounted && this.importPageGeneration===generation) this.lastImport_=outcome;
      return outcome
    } catch (e) {
      this.statusMsg = '导入失败: ' + (e as Error).message
      return { 'state':'failed','reason':'importFailed' }
    } finally { if (generation===this.importPageGeneration) this.selectingLayout_=false }
  }

  /** 分析并导入指定路径/uri（文件选择器与「打开方式」共用）。 */
  private async analyzeAndImport(path: string): Promise<SkillFields> {
    if (this.importBusy || !this.importPageMounted) return { 'state':'busy' }
    const generation: number = this.importPageGeneration
    this.importBusy = true
    try {
      // 导入前分析：格式 / 合法性 / 设备类型 / 旧版本
      const a: ImportAnalysis = await this.store.analyzeImportFile(path)
      if (!this.importPageMounted || generation !== this.importPageGeneration) return { 'state':'unknown' }
      if (!a.ok) {
        this.statusMsg = '无法导入：' + a.reason
        return { 'state':'failed','reason':'invalidLayout' }
      }
      // 需要用户确认的情形：设备不符 / 旧版迁移
      if (a.deviceMismatch || a.legacy || a.format !== 'amcl') {
        let msg = '方案「' + a.name + '」'
        if (a.format !== 'amcl') msg += '（' + a.format + ' 格式）'
        if (a.controlCount > 0) msg += '，控件 ' + a.controlCount.toString() + ' 个'
        if ((a.skippedControls ?? 0)>0) msg+='\n将跳过 '+(a.skippedControls ?? 0).toString()+' 个无法转换的控件。'
        if ((a.warnings ?? []).length>0) msg+='\n\n兼容说明：\n'+(a.warnings ?? []).join('\n')
        if (a.deviceMismatch) {
          msg += '\n\n⚠ 该方案面向' + this.deviceLabel(a.sourceDevice)
            + '，当前设备是' + this.deviceLabel(a.currentDevice)
            + '。布局按屏幕比例摆放，直接导入可能不合理，建议导入后进编辑器微调。'
        }
        if (a.legacy) {
          msg += '\n\n该方案为旧版本（v' + a.sourceVersion.toString() + '），导入时将自动迁移到最新格式。'
        }
        msg += '\n\n仍要导入吗？'
        // 2026-05-23 API NEXT 迁移：全局 AlertDialog.show 弃用，改走
        // this.getUIContext().getPromptAction().showDialog(...)。res.index===1 = 仍要导入。
        try {
          const res = await this.getUIContext().getPromptAction().showDialog({
            title: '导入布局方案',
            message: msg,
            buttons: [
              // 本应用palette使用不透明HEX字符串；原生Dialog参数不接受ResourceColor的number分支。
              { text: '取消', color: this.titleTheme.textSecondary as string },
              { text: '仍要导入', color: this.titleTheme.actionText as string },
            ],
          })
          if (res.index !== 1) return { 'state':'cancelled' }
          if (!this.importPageMounted || generation !== this.importPageGeneration) return { 'state':'unknown' }
        } catch (_) { return { 'state':'cancelled' } }
      }
      // 无异常 → 直接导入
      return await this.commitImport(a, generation)
    } catch (e) {
      this.statusMsg = '导入失败: ' + (e as Error).message
      return { 'state':'failed','reason':'invalidLayout' }
    } finally { if (generation === this.importPageGeneration) this.importBusy = false }
  }

  /** 实际落盘导入（供直接导入与确认对话框复用）。 */
  private async commitImport(review: ImportAnalysis, generation: number): Promise<SkillFields> {
    if (!this.importPageMounted || generation !== this.importPageGeneration) return { 'state':'unknown' }
    try {
      const p = await this.store.commitReviewedImport(review.reviewId ?? '')
      if (!this.importPageMounted || generation !== this.importPageGeneration) return { 'state':'unknown' }
      if (!p) { this.statusMsg = '导入失败：文件格式错误'; return { 'state':'failed','reason':'invalidLayout' } }
      this.refreshList(); this.statusMsg = '已导入: ' + p.name
      return { 'state':'ready','name':p.name,'id':p.profileId ?? '', 'revision':p.profileRevision ?? 1 }
    } catch (e) {
      if (this.importPageMounted && generation===this.importPageGeneration) this.statusMsg = '导入失败: ' + (e as Error).message
      return { 'state':'unknown','reason':'importUnconfirmed' }
    }
  }

  /** 保留原正文的父组件状态与业务回调；具名content只转调此真正@Builder，避免this漂移。 */
  @Builder
  private ImmersiveTitleContent1_() {

      // 加载异常提示（非阻塞）：常驻在状态行上方，不遮挡列表、不需要用户确认。
      if (this.loadNotice.length > 0) {
        Text(this.loadNotice)
          .fontSize(11).fontColor(this.titleTheme.warningText)
          .backgroundColor(this.titleTheme.warningBg).borderRadius(8)
          .width('100%').padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .margin({ bottom: 4 })
      }

      // 状态行
      if (this.statusMsg.length > 0) {
        Text(this.statusMsg)
          .fontSize(11).fontColor(this.titleTheme.warningText)
          .width('100%').padding({ left: 12, right: 12, top: 4, bottom: 4 })
      }

      if (this.profileNames.length > 32) {
        Row({space:8}) {
          Button('上一页').fontSize(13).height(36).enabled(this.profilePage>0)
            .onClick((): void => { this.moveProfilePage_(-1) })
          Text((this.profilePage+1).toString()+'/'+this.profilePageCount_().toString()).fontSize(13).fontColor(this.titleTheme.textSecondary).layoutWeight(1)
          Button('当前').fontSize(13).height(36).onClick((): void => { this.showCurrentProfilePage_() })
          Button('下一页').fontSize(13).height(36).enabled(this.profilePage+1<this.profilePageCount_())
            .onClick((): void => { this.moveProfilePage_(1) })
        }.width('100%').padding({left:12,right:12,bottom:6})
      }
      // 方案卡片列表只读取当前页payload；翻页保留完整名字目录，不通过裁库降低容量。
      Scroll() {
        if (this.isWide()) {
          // lg：两列 masonry——按预估高度把方案贪心分到"当前较短的列"，两列各自 Column 顺次堆叠，
          // 不因两列高度差在列中留空（每张卡紧接同列上一张）。
          Row({ space: 12 }) {
            Column({ space: 12 }) {
              ForEach(this.columnNames(0), (name: string) => {
                this.ProfileCard(name)
              }, (name: string) => this.profileCardKey_(name))
            }
            .layoutWeight(1).alignItems(HorizontalAlign.Start)

            Column({ space: 12 }) {
              ForEach(this.columnNames(1), (name: string) => {
                this.ProfileCard(name)
              }, (name: string) => this.profileCardKey_(name))
            }
            .layoutWeight(1).alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .padding({ left: 12, right: 12, top: 4, bottom: 24 })
        } else {
          // sm/md：单列
          Column({ space: 12 }) {
            ForEach(this.profilePageNames_(), (name: string) => {
              this.ProfileCard(name)
            }, (name: string) => this.profileCardKey_(name))
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 4, bottom: 24 })
        }
      }
      .layoutWeight(1)
      .width('100%')
      }
}
