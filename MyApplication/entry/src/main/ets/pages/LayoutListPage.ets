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
import { common } from '@kit.AbilityKit'
import { picker } from '@kit.CoreFileKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { fileUri } from '@kit.CoreFileKit'
import { systemShare } from '@kit.ShareKit'
import { LayoutProfile, ImportAnalysis, LayoutLoadIssues, initialControlGroupVisible } from 'gamecontrol'
import { LayoutThumbnail } from '../components/LayoutThumbnail'
import { getLayoutStore, LayoutStore } from 'gamecontrol'
import { AppIconName } from 'commons'
import { AppIcon } from '../components/AppIcon'
import { ThemeColors, ThemeMode, resolveTheme } from 'commons'
import { ImmersiveTitleScaffold } from '../components/ImmersiveTitleScaffold'
import { ProductInputProfile } from 'entry/ProductInputProfile'
import { layoutCatalogPage, layoutCatalogPageCount, clampLayoutCatalogPage, layoutCatalogContainingPage } from '../components/LayoutCatalogPaging'

/** 路由参数：从「打开方式」经 Index 跳入时携带待导入文件 uri。 */
interface LayoutListRouteParams {
  importUri?: string
}

@Entry
@Component
struct LayoutListPage {
  /** 编辑器目录沿用原固定深色视觉；只让共享标题接管返回与顶部安全区。 */
  private titleTheme: ThemeColors = resolveTheme(ThemeMode.DARK, false)
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

  private store: LayoutStore = getLayoutStore()
  /** 异步预览/确认属于当前页面代次，迟到对话框不能在页面离开后新增布局。 */
  private importPageGeneration: number = 0
  private importPageMounted: boolean = false
  @State importBusy: boolean = false

  private getAbilityContext(): common.UIAbilityContext {
    return AppStorage.get<common.UIAbilityContext>('uiAbilityContext')!
  }

  async aboutToAppear(): Promise<void> {
    this.importPageGeneration++
    this.importPageMounted = true
    if (!ProductInputProfile.supportsTouchLayouts()) {
      this.getUIContext().getRouter().back()
      return
    }
    const context = this.getAbilityContext()
    await this.store.init(context)
    this.refreshList()
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
        setTimeout(() => { this.analyzeAndImport(uri) }, 60)
      }
    }
  }

  aboutToDisappear(): void {
    this.importPageMounted = false
    this.importPageGeneration++
  }

  /** Phase D：从编辑器回到本页时刷一次列表（编辑器保存后名字 / active 可能变化）。 */
  onPageShow(): void {
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
    try {
      const created: LayoutProfile = await this.store.createProfile('方案' + (this.profileNames.length + 1).toString())
      this.refreshList()
      this.statusMsg = '已创建: ' + created.name
    } catch (e) {
      this.refreshList()
      this.statusMsg = '新建失败: ' + (e as Error).message
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
    Column() {
      // 外层 Stack 继续拥有改名遮罩；导航容器只承载原目录正文，不改浮层层级。
      ImmersiveTitleScaffold({ title: '按键布局方案', theme: this.titleTheme,
        topSafeHeight: this.topSafeHeight, surfaceColor: '#141414',
        menuActions: [{ id: 'create-layout', label: '新建' }, { id: 'import-layout', label: '导入' }],
        onBack: (): void => { this.getUIContext().getRouter().back(); },
        onMenuAction: (id: string): void => {
          if (id === 'create-layout') this.createProfile_();
          else if (id === 'import-layout') this.doImport();
        },
        content: (): void => { this.ImmersiveTitleContent1_(); }
      })
    }
    .width('100%').height('100%').backgroundColor('#141414')
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
        Text('重命名方案').fontSize(16).fontColor('#FFFFFF').fontWeight(FontWeight.Bold)
        TextInput({ text: this.renameDraft, placeholder: '输入新名称' })
          .height(42).fontSize(14).width('100%')
          .maxLength(40)
          .onChange((v: string) => { this.renameDraft = v })
        Row({ space: 10 }) {
          Button('取消').fontSize(13).height(38).fontColor('#FFFFFF').layoutWeight(1)
            .backgroundColor('#33FFFFFF').borderRadius(19)
            .onClick(() => { this.renameTarget = ''; this.renameDraft = '' })
          Button('确定').fontSize(13).height(38).fontColor('#FFFFFF').layoutWeight(1)
            .backgroundColor('#448AFF').borderRadius(19)
            .onClick(() => { this.doRename() })
        }.width('100%')
      }
      .width('80%').constraintSize({ maxWidth: 360 })
      .padding(20)
      .backgroundColor('#242424').borderRadius(16)
      .border({ width: 1, color: '#22FFFFFF' })
      .onClick(() => { })   // 吞掉卡片内点击，避免冒泡到遮罩触发关闭
    }
    .width('100%').height('100%')
    .backgroundColor('#99000000')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => { this.renameTarget = ''; this.renameDraft = '' })
  }

  private doRename(): void {
    const oldName = this.renameTarget
    const newName = this.renameDraft
    this.store.renameProfile(oldName, newName).then((ok: boolean) => {
      this.renameTarget = ''
      this.renameDraft = ''
      if (ok) {
        this.refreshList()
        this.statusMsg = '已重命名为: ' + newName.trim()
      } else {
        this.statusMsg = '重命名失败：名称为空 / 过长 / 与现有方案重名'
      }
    }).catch((e: Error) => {
      this.renameTarget = ''
      this.refreshList()
      this.statusMsg = '重命名失败: ' + e.message
    })
  }

  @Builder
  ProfileCard(name: string) {
    Column({ space: 10 }) {
      // 标题行
      Row({ space: 8 }) {
        Circle({ width: 9, height: 9 })
          .fill(name === this.activeName ? '#448AFF' : '#888888')
        Text(name)
          .fontSize(15)
          .fontColor(name === this.activeName ? '#FFFFFF' : '#CCCCCC')
          .fontWeight(name === this.activeName ? FontWeight.Bold : FontWeight.Medium)
          .layoutWeight(1)
        // 改名：仅非系统预设可改（默认两个预设不可改名）。
        if (!this.isPreset(name)) {
          Row() {
            AppIcon({ name: AppIconName.Edit, iconSize: 15, color: '#88FFFFFF' })
          }
          .width(30).height(30).justifyContent(FlexAlign.Center)
          .onClick(() => { this.renameTarget = name; this.renameDraft = name })
        }
        if (this.isPreset(name)) {
          Text('系统').fontSize(10).fontColor('#448AFF').fontWeight(FontWeight.Medium)
            .backgroundColor('#33448AFF')
            .borderRadius(8).padding({ left: 7, right: 7, top: 3, bottom: 3 })
        }
        if (name === this.activeName) {
          Text('当前').fontSize(10).fontColor('#FFFFFF').fontWeight(FontWeight.Medium)
            .backgroundColor('#448AFF')
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
          .fontSize(11).fontColor('#66FFFFFF').layoutWeight(1)
      }

      // 操作按钮行（胶囊，语义色对齐设计稿）
      Row({ space: 6 }) {
        if (name !== this.activeName) {
          Button('使用')
            .fontSize(12).height(32).fontColor('#448AFF').fontWeight(FontWeight.Medium)
            .backgroundColor('#33448AFF').borderRadius(16)
            .layoutWeight(1)
            .onClick(async () => {
              // 所有 mutation 都可能因写入封锁或写盘失败而拒绝；失败原因原样显示，列表按存储回滚后的状态刷新。
              try {
                await this.store.setActiveProfile(name)
                this.refreshList()
                this.statusMsg = '已切换到: ' + name
              } catch (e) {
                this.refreshList()
                this.statusMsg = '切换失败: ' + (e as Error).message
              }
            })
        }
        Button('编辑')
          .fontSize(12).height(32).fontColor('#FFFFFF').fontWeight(FontWeight.Medium)
          .backgroundColor('#448AFF').borderRadius(16)
          .layoutWeight(1)
          .onClick(() => {
            // 把方案名作为 params 传给 LayoutEditorPage
            this.getUIContext().getRouter().pushUrl({
              url: 'pages/LayoutEditorPage',
              params: { profileName: name }
            })
          })
        if (this.isPreset(name)) {
          Button('克隆')
            .fontSize(12).height(32).fontColor('#FFFFFF').fontWeight(FontWeight.Medium)
            .backgroundColor('#4466BB6A').borderRadius(16)
            .layoutWeight(1)
            .onClick(async () => {
              try {
                const cloned = await this.store.cloneAsUser(name)
                this.refreshList()
                if (cloned) this.statusMsg = '已克隆为: ' + cloned.name
              } catch (e) {
                this.refreshList()
                this.statusMsg = '克隆失败: ' + (e as Error).message
              }
            })
        } else if (this.profileNames.length > 1) {
          Button('删除')
            .fontSize(12).height(32).fontColor('#FF5252').fontWeight(FontWeight.Medium)
            .backgroundColor('#33FF5252').borderRadius(16)
            .layoutWeight(1)
            .onClick(async () => {
              try {
                const ok = await this.store.deleteProfile(name)
                this.refreshList()
                this.statusMsg = ok ? ('已删除: ' + name) : '删除失败'
              } catch (e) {
                this.refreshList()
                this.statusMsg = '删除失败: ' + (e as Error).message
              }
            })
        }
        Button('导出')
          .fontSize(12).height(32).fontColor('#FFFFFFB3').fontWeight(FontWeight.Medium)
          .backgroundColor('#1AFFFFFF').borderRadius(16)
          .layoutWeight(1)
          .onClick(() => { this.doExport(name) })
        Button('分享')
          .fontSize(12).height(32).fontColor('#66BB6A').fontWeight(FontWeight.Medium)
          .backgroundColor('#3366BB6A').borderRadius(16)
          .layoutWeight(1)
          .onClick(() => { this.doShare(name) })
      }
      if (this.canExportLegacy_(name)) {
        Button('导出旧版兼容副本（使用保留的全来源手感）')
          .fontSize(12).height(30).fontColor('#FFFFFFB3').backgroundColor('#1AFFFFFF')
          .width('100%').margin({ top: 6 })
          .onClick(() => { this.doExport(name, true) })
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(name === this.activeName ? '#1E3357' : '#242424')
    .borderRadius(14)
    .border({
      width: name === this.activeName ? 1.5 : 0,
      color: '#448AFF'
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

  private async doExport(name: string, legacyCompatible: boolean = false): Promise<void> {
    try {
      const json = this.store.exportToJson(name, legacyCompatible)
      const savePicker = new picker.DocumentSaveOptions()
      savePicker.newFileNames = ['layout_' + name + (legacyCompatible ? '_v3' : '') + '.json']
      const documentPicker = new picker.DocumentViewPicker(this.getAbilityContext())
      const result = await documentPicker.save(savePicker)
      if (result && result.length > 0) {
        const file = fs.openSync(result[0], fs.OpenMode.WRITE_ONLY)
        try { fs.writeSync(file.fd, json) } finally { fs.closeSync(file) }
        this.statusMsg = legacyCompatible ? '已导出旧版兼容副本；原独立来源方案仍保留' : '已导出: ' + name
      }
    } catch (e) {
      this.statusMsg = '导出失败: ' + (e as Error).message
    }
  }

  /** 用鸿蒙原生系统分享面板分享该方案（写临时 .json 到缓存目录再以文件形式分享）。 */
  private async doShare(name: string): Promise<void> {
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
      await controller.show(ctx, {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DETAIL
      })
    } catch (e) {
      this.statusMsg = '分享失败: ' + (e as Error).message
    }
  }

  private deviceLabel(d: string): string {
    if (d === 'phone') return '手机'
    if (d === 'tablet') return '平板'
    if (d === 'foldable') return '折叠机'
    if (d === 'any') return '通用'
    return '未知'
  }

  private async doImport(): Promise<void> {
    try {
      const openPicker = new picker.DocumentSelectOptions()
      const documentPicker = new picker.DocumentViewPicker(this.getAbilityContext())
      const result = await documentPicker.select(openPicker)
      if (!result || result.length === 0) return
      await this.analyzeAndImport(result[0])
    } catch (e) {
      this.statusMsg = '导入失败: ' + (e as Error).message
    }
  }

  /** 分析并导入指定路径/uri（文件选择器与「打开方式」共用）。 */
  private async analyzeAndImport(path: string): Promise<void> {
    if (this.importBusy || !this.importPageMounted) return
    const generation: number = this.importPageGeneration
    this.importBusy = true
    try {
      // 导入前分析：格式 / 合法性 / 设备类型 / 旧版本
      const a: ImportAnalysis = await this.store.analyzeImportFile(path)
      if (!this.importPageMounted || generation !== this.importPageGeneration) return
      if (!a.ok) {
        this.statusMsg = '无法导入：' + a.reason
        return
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
          this.getUIContext().getPromptAction().showDialog({
            title: '导入布局方案',
            message: msg,
            buttons: [
              { text: '取消', color: '#8A8A8A' },
              { text: '仍要导入', color: '#448AFF' },
            ],
          }).then((res: promptAction.ShowDialogSuccessResponse) => {
            if (res.index === 1 && this.importPageMounted && generation === this.importPageGeneration) {
              this.commitImport(a, generation)
            }
          }).catch(() => { /* 点框外 = 取消，冻结预览保留到缓存回收。 */ })
        } catch (e) {
          this.statusMsg = '导入失败: ' + (e as Error).message
        }
        return
      }
      // 无异常 → 直接导入
      this.commitImport(a, generation)
    } catch (e) {
      this.statusMsg = '导入失败: ' + (e as Error).message
    } finally { if (generation === this.importPageGeneration) this.importBusy = false }
  }

  /** 实际落盘导入（供直接导入与确认对话框复用）。 */
  private commitImport(review: ImportAnalysis, generation: number): void {
    if (!this.importPageMounted || generation !== this.importPageGeneration) return
    // 回执中私有 candidate 已完成转换与系统补齐；不重新读取文件，也不随新 viewport 转换坐标。
    const operation: Promise<LayoutProfile | null> = this.store.commitReviewedImport(review.reviewId ?? '')
    operation.then((p: LayoutProfile | null) => {
      if (!this.importPageMounted || generation !== this.importPageGeneration) return
      if (p) {
        this.refreshList()
        this.statusMsg = '已导入: ' + p.name
      } else {
        this.statusMsg = '导入失败：文件格式错误'
      }
    }).catch((e: Error) => {
      this.statusMsg = '导入失败: ' + e.message
    })
  }

  /** 保留原正文的父组件状态与业务回调；具名content只转调此真正@Builder，避免this漂移。 */
  @Builder
  private ImmersiveTitleContent1_() {

      // 加载异常提示（非阻塞）：常驻在状态行上方，不遮挡列表、不需要用户确认。
      if (this.loadNotice.length > 0) {
        Text(this.loadNotice)
          .fontSize(11).fontColor('#FFB74D')
          .backgroundColor('#26FFB74D').borderRadius(8)
          .width('100%').padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .margin({ bottom: 4 })
      }

      // 状态行
      if (this.statusMsg.length > 0) {
        Text(this.statusMsg)
          .fontSize(11).fontColor('#FFD54F')
          .width('100%').padding({ left: 12, right: 12, top: 4, bottom: 4 })
      }

      if (this.profileNames.length > 32) {
        Row({space:8}) {
          Button('上一页').fontSize(13).height(36).enabled(this.profilePage>0)
            .onClick((): void => { this.moveProfilePage_(-1) })
          Text((this.profilePage+1).toString()+'/'+this.profilePageCount_().toString()).fontSize(13).fontColor('#CCCCCC').layoutWeight(1)
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
