/**
 * LayoutListPage.ets — 按键布局方案列表（Phase D 键鼠适配重构）
 *
 * 入口：SettingsTab 点 "按键布局" → router.pushUrl('pages/LayoutListPage')
 * 行为：
 *   - 不强制方向（手机自然竖屏，平板自然横屏均可）
 *   - 渲染所有方案的 16:9 缩略图卡片
 *   - 卡片操作：使用 / 编辑 / 克隆 / 删除（系统预设只能克隆不能删）
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
import { LayoutProfile, ImportAnalysis } from 'gamecontrol'
import { LayoutThumbnail } from '../components/LayoutThumbnail'
import { getLayoutStore, LayoutStore } from 'gamecontrol'
import { AppIconName } from 'commons'
import { AppIcon } from '../components/AppIcon'
import { ProductInputProfile } from 'entry/ProductInputProfile'

/** 路由参数：从「打开方式」经 Index 跳入时携带待导入文件 uri。 */
interface LayoutListRouteParams {
  importUri?: string
}

@Entry
@Component
struct LayoutListPage {
  @State profileNames: string[] = []
  @State activeName: string = '默认'
  @State statusMsg: string = ''
  @State pageWidth: number = 360
  // 改名浮层：renameTarget 非空时显示，renameDraft 为输入草稿。
  @State renameTarget: string = ''
  @State renameDraft: string = ''

  private store: LayoutStore = getLayoutStore()

  private getAbilityContext(): common.UIAbilityContext {
    return AppStorage.get<common.UIAbilityContext>('uiAbilityContext')!
  }

  async aboutToAppear(): Promise<void> {
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

  /** Phase D：从编辑器回到本页时刷一次列表（编辑器保存后名字 / active 可能变化）。 */
  onPageShow(): void {
    this.refreshList()
  }

  private refreshList(): void {
    this.profileNames = this.store.getProfileNames()
    this.activeName = this.store.getActiveProfile().name
  }

  private isPreset(name: string): boolean {
    const all = this.store.getAllProfiles()
    const p = all.find(pp => pp.name === name)
    return p ? !!p.isPreset : false
  }

  private getProfile(name: string): LayoutProfile | null {
    const all = this.store.getAllProfiles()
    return all.find(pp => pp.name === name) ?? null
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
    for (let i = 0; i < this.profileNames.length; i++) {
      const name = this.profileNames[i]
      const h = this.estimateCardHeight(name)
      if (lh <= rh) { left.push(name); lh += h }
      else { right.push(name); rh += h }
    }
    return col === 0 ? left : right
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
    Column() {
      // 顶部标题栏
      Row({ space: 8 }) {
        Row() {
          AppIcon({ name: AppIconName.Back, iconSize: 20, color: '#FFFFFF' })
        }
        .width(40).height(40).justifyContent(FlexAlign.Center)
        .onClick(() => { this.getUIContext().getRouter().back() })

        Text('按键布局方案').fontSize(20).fontColor('#FFFFFF').fontWeight(FontWeight.Bold).layoutWeight(1)

        Button('+ 新建')
          .fontSize(12).height(30).fontColor('#FFFFFF').fontWeight(FontWeight.Medium)
          .backgroundColor('#448AFF').borderRadius(15)
          .padding({ left: 12, right: 12 })
          .onClick(async () => {
            const name = '方案' + (this.profileNames.length + 1).toString()
            await this.store.createProfile(name)
            this.refreshList()
            this.statusMsg = '已创建: ' + name
          })

        Button('导入')
          .fontSize(12).height(30).fontColor('#FFFFFFB3').fontWeight(FontWeight.Medium)
          .backgroundColor('#1AFFFFFF').borderRadius(15)
          .padding({ left: 12, right: 12 })
          .margin({ left: 6 })
          .onClick(() => { this.doImport() })
      }
      .width('100%').padding({ left: 16, right: 16, top: 10, bottom: 8 })

      // 状态行
      if (this.statusMsg.length > 0) {
        Text(this.statusMsg)
          .fontSize(11).fontColor('#FFD54F')
          .width('100%').padding({ left: 12, right: 12, top: 4, bottom: 4 })
      }

      // 方案卡片列表
      Scroll() {
        if (this.isWide()) {
          // lg：两列 masonry——按预估高度把方案贪心分到"当前较短的列"，两列各自 Column 顺次堆叠，
          // 不因两列高度差在列中留空（每张卡紧接同列上一张）。
          Row({ space: 12 }) {
            Column({ space: 12 }) {
              ForEach(this.columnNames(0), (name: string) => {
                this.ProfileCard(name)
              }, (name: string) => name)
            }
            .layoutWeight(1).alignItems(HorizontalAlign.Start)

            Column({ space: 12 }) {
              ForEach(this.columnNames(1), (name: string) => {
                this.ProfileCard(name)
              }, (name: string) => name)
            }
            .layoutWeight(1).alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .padding({ left: 12, right: 12, top: 4, bottom: 24 })
        } else {
          // sm/md：单列
          Column({ space: 12 }) {
            ForEach(this.profileNames, (name: string) => {
              this.ProfileCard(name)
            }, (name: string) => name)
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 4, bottom: 24 })
        }
      }
      .layoutWeight(1)
      .width('100%')
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
              await this.store.setActiveProfile(name)
              this.refreshList()
              this.statusMsg = '已切换到: ' + name
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
              const cloned = await this.store.cloneAsUser(name)
              this.refreshList()
              if (cloned) this.statusMsg = '已克隆为: ' + cloned.name
            })
        } else if (this.profileNames.length > 1) {
          Button('删除')
            .fontSize(12).height(32).fontColor('#FF5252').fontWeight(FontWeight.Medium)
            .backgroundColor('#33FF5252').borderRadius(16)
            .layoutWeight(1)
            .onClick(async () => {
              const ok = await this.store.deleteProfile(name)
              this.refreshList()
              this.statusMsg = ok ? ('已删除: ' + name) : '删除失败'
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

  private cardDescription(name: string): string {
    const p = this.getProfile(name)
    if (!p) return ''
    let visibleCount = 0
    for (let i = 0; i < p.controls.length; i++) {
      if (!p.controls[i].hidden) visibleCount++
    }
    let parts: string[] = []
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

  private async doExport(name: string): Promise<void> {
    try {
      const json = this.store.exportToJson(name)
      const savePicker = new picker.DocumentSaveOptions()
      savePicker.newFileNames = ['layout_' + name + '.json']
      const documentPicker = new picker.DocumentViewPicker(this.getAbilityContext())
      const result = await documentPicker.save(savePicker)
      if (result && result.length > 0) {
        const file = fs.openSync(result[0], fs.OpenMode.WRITE_ONLY)
        try { fs.writeSync(file.fd, json) } finally { fs.closeSync(file) }
        this.statusMsg = '已导出: ' + name
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
    try {
      // 导入前分析：格式 / 合法性 / 设备类型 / 旧版本
      const a: ImportAnalysis = await this.store.analyzeImportFile(path)
      if (!a.ok) {
        this.statusMsg = '无法导入：' + a.reason
        return
      }
      // 需要用户确认的情形：设备不符 / 旧版迁移
      if (a.deviceMismatch || a.legacy) {
        let msg = '方案「' + a.name + '」'
        if (a.format === 'pojav') msg += '（PojavLauncher 格式）'
        if (a.controlCount > 0) msg += '，控件 ' + a.controlCount.toString() + ' 个'
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
            if (res.index === 1) { this.commitImport(path) }
          }).catch(() => { /* 点框外 = 取消 */ })
        } catch (e) {
          this.statusMsg = '导入失败: ' + (e as Error).message
        }
        return
      }
      // 无异常 → 直接导入
      this.commitImport(path)
    } catch (e) {
      this.statusMsg = '导入失败: ' + (e as Error).message
    }
  }

  /** 实际落盘导入（供直接导入与确认对话框复用）。 */
  private commitImport(path: string): void {
    this.store.importFromFile(path).then((p: LayoutProfile | null) => {
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
}
