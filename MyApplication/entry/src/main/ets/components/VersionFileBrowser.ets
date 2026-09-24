import { DeviceProfile } from 'commons';
import { KeyCode } from '@kit.InputKit';
import { DiagnosticPolicy } from 'commons';
/**
 * VersionFileBrowser.ets — 版本文件夹「虚拟文件管理器」（沙箱内文件浏览 + 导入/导出/删除/重命名/新建）
 *
 * 背景：游戏文件存于应用沙箱（或沙箱外 Download 映射目录），用户无法用系统文件管理直接浏览/整理。
 * 本组件提供一个嵌入版本详情 sheet 的虚拟文件夹视图，让用户能：
 *   - 浏览版本根目录及其子目录（点文件夹进入、面包屑/上级返回）
 *   - 导入任意文件到当前目录（系统 picker 选文件 → 拷入）
 *   - 导出文件（另存 picker）/ 导出文件夹（压 zip 另存）
 *   - 删除（二次确认，递归删目录）、重命名、新建文件夹
 *
 * 根目录：版本隔离 → mcDir/versions/<id>；非隔离 → mcDir（.minecraft 根）。
 * 路径基于父级传入的 mcDir（已是「沙箱/沙箱外」位置感知），两种存储位置走同一套逻辑。
 *
 * 设计沿用 SavesManagerSheet：嵌入式 header（← 版本详情）、busy 遮罩、二次确认浮层，
 * 导入导出复用 GameArchiveIO（系统 picker + zlib + fileIo）。
 *
 * 创建日期：见 CHANGELOG。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ThemeColors } from 'commons';
import { AppIconName } from 'commons';
import { removeDirRecursive } from 'commons';
import { AppIcon } from './AppIcon';
import { GameArchiveIO } from './GameArchiveIO';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_UI } from 'commons';

const TAG = 'VersionFileBrowser';

/** 目录项。 */
interface FileEntry {
  name: string;
  isDir: boolean;
  /** 文件字节数；目录为 0 */
  size: number;
  /** 最后修改时间（毫秒）；0 = 未知 */
  mtimeMs: number;
  /** 目录子项数；文件为 -1 */
  childCount: number;
}

@Component
export struct VersionFileBrowser {
  @Prop theme: ThemeColors = {} as ThemeColors;
  @Prop bottomSafeHeight: number = 0;
  /** .minecraft 根（不带尾部 /） */
  @Prop mcDir: string = '';
  /** 目标版本 id；为空显示空态 */
  @Prop @Watch('onScopeChanged') versionId: string = '';
  @Prop versionIsolation: boolean = true;
  /** 嵌入 VersionManagerSheet 时为 true（用返回按钮取代拖拽指示条） */
  @Prop embedded: boolean = false;
  /** 仅当滑到本步时扫描磁盘 */
  @Prop @Watch('onScopeChanged') active: boolean = true;

  /** 相对根目录的当前路径（''=根）；用 / 分隔 */
  @State private rel: string = '';
  @State private rows: FileEntry[] = [];
  @State private loaded: boolean = false;
  @State private busy: boolean = false;
  @State private busyLabel: string = '';

  /** 删除二次确认：目标名（''=无对话框）+ 是否目录 */
  @State private pendingDelete: string = '';
  @State private pendingDeleteIsDir: boolean = false;

  /** 重命名浮层 */
  @State private renameTarget: string = '';
  @State private renameInput: string = '';
  @State private renameError: string = '';

  /** 新建文件夹浮层 */
  @State private showNewFolder: boolean = false;
  @State private newFolderInput: string = '';
  @State private newFolderError: string = '';

  onClose: () => void = () => {};
  onBack: () => void = () => {};
  onChanged: () => void = () => {};

  aboutToAppear() {
    if (this.active) this.refresh();
  }

  onScopeChanged(): void {
    // 切版本 / 切到本步：回根目录重扫
    if (this.active) {
      this.rel = '';
      this.refresh();
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        if (this.embedded) {
          Row() {
            Row({ space: 4 }) {
              AppIcon({ name: AppIconName.ChevronLeft, iconSize: 14, color: this.theme.textPrimary })
              Text('版本详情').fontSize(12).fontWeight(600).fontColor(this.theme.textSecondary)
            }
            .height(32)
            .padding({ left: 10, right: 12 })
            .borderRadius(16)
            .backgroundColor(this.theme.bgInput)
            .alignItems(VerticalAlign.Center)
            .onClick(() => { this.onBack() })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 10, bottom: 4 })
          .justifyContent(FlexAlign.Start)
        } else {
          Row() {
            Column().width(36).height(4).backgroundColor(this.theme.divider).borderRadius(2)
          }
          .width('100%').justifyContent(FlexAlign.Center).padding({ top: 10, bottom: 6 })
        }

        this.Header()
        this.Breadcrumb()

        if (!this.loaded) {
          this.LoadingState()
        } else if (this.rows.length === 0) {
          this.EmptyState()
        } else {
          this.ListView()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.theme.bgPrimary)

      if (this.pendingDelete.length > 0) {
        this.DeleteConfirmOverlay()
      }
      if (this.renameTarget.length > 0) {
        this.RenameOverlay()
      }
      if (this.showNewFolder) {
        this.NewFolderOverlay()
      }
      if (this.busy) {
        this.BusyOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  Header() {
    Row() {
      Column({ space: 2 }) {
        Text('版本文件夹')
          .fontSize(22).fontWeight(700).fontColor(this.theme.textPrimary)
        Text(this.headerSubtitle())
          .fontSize(11).fontColor(this.theme.textHint)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Row({ space: 8 }) {
        Row() {
          AppIcon({ name: AppIconName.Plus, iconSize: 15, color: this.theme.textSecondary })
        }
        .width(32).height(32).borderRadius(16)
        .backgroundColor(this.theme.bgInput).justifyContent(FlexAlign.Center)
        .onClick(() => { this.openNewFolder() })

        Row() {
          AppIcon({ name: AppIconName.Refresh, iconSize: 14, color: this.theme.textSecondary })
        }
        .width(32).height(32).borderRadius(16)
        .backgroundColor(this.theme.bgInput).justifyContent(FlexAlign.Center)
        .onClick(() => { this.refresh() })

        Row({ space: 5 }) {
          AppIcon({ name: AppIconName.Import, iconSize: 13, color: this.theme.textOnPrimary })
          Text('导入').fontSize(12).fontWeight(600).fontColor(this.theme.textOnPrimary)
        }
        .height(32).padding({ left: 12, right: 12 }).borderRadius(16)
        .backgroundColor(this.theme.primary).alignItems(VerticalAlign.Center)
        .onClick(() => { this.doImport() })
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 6, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  /** 面包屑：根 / a / b，可点任意段跳转；非根时左侧「上级」按钮。 */
  @Builder
  Breadcrumb() {
    Row({ space: 6 }) {
      if (this.rel.length > 0) {
        Row({ space: 3 }) {
          AppIcon({ name: AppIconName.ChevronUp, iconSize: 12, color: this.theme.primary })
          Text('上级').fontSize(11).fontWeight(600).fontColor(this.theme.primary)
        }
        .height(26).padding({ left: 8, right: 10 }).borderRadius(13)
        .backgroundColor(this.theme.primaryLight).alignItems(VerticalAlign.Center)
        .onClick(() => { this.goUp() })
      }
      Scroll() {
        Row({ space: 2 }) {
          this.CrumbSeg('根目录', '')
          ForEach(this.crumbSegments(), (seg: string, idx: number) => {
            AppIcon({ name: AppIconName.ChevronRight, iconSize: 10, color: this.theme.textHint })
            this.CrumbSeg(seg, this.crumbPathAt(idx))
          }, (seg: string, idx: number) => idx + ':' + seg)
        }
        .alignItems(VerticalAlign.Center)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 20, right: 20, bottom: 10 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  CrumbSeg(label: string, targetRel: string) {
    Text(label)
      .fontSize(11).fontWeight(this.rel === targetRel ? 700 : 500)
      .fontColor(this.rel === targetRel ? this.theme.textPrimary : this.theme.textSecondary)
      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      .padding({ left: 4, right: 4 })
      .onClick(() => { if (this.rel !== targetRel) { this.rel = targetRel; this.refresh() } })
  }

  @Builder
  ListView() {
    List({ space: 8 }) {
      ForEach(this.rows, (row: FileEntry) => {
        ListItem() {
          this.RowItem(row)
        }
      }, (row: FileEntry) => (row.isDir ? 'd:' : 'f:') + row.name + '|' + row.mtimeMs + '|' + row.size)

      ListItem() {
        Text('共 ' + this.rows.length + ' 项 · 导入文件到当前目录 · 长按导出/重命名/删除')
          .fontSize(11).fontColor(this.theme.textHint)
          .width('100%').textAlign(TextAlign.Center)
          .padding({ top: 12, bottom: 30 })
      }
    }
    .layoutWeight(1).width('100%')
    .padding({ left: 20, right: 20 })
    .scrollBar(BarState.Off)
  }

  @Builder
  RowItem(row: FileEntry) {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.Center }) {
        Column().width(40).height(40).borderRadius(10)
          .backgroundColor(row.isDir ? this.theme.primaryLight : this.theme.bgInput)
        AppIcon({
          name: row.isDir ? AppIconName.Folder : AppIconName.Document,
          iconSize: 20,
          color: row.isDir ? this.theme.primary : this.theme.textSecondary,
        })
      }
      .width(40).height(40)

      Column({ space: 4 }) {
        Text(row.name)
          .fontSize(14).fontWeight(600).fontColor(this.theme.textPrimary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.subInfo(row))
          .fontSize(11).fontWeight(500).fontColor(this.theme.textHint)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (DeviceProfile.isPC()) {
        Button('⋯')
          .width(34).height(34).fontSize(18)
          .fontColor(this.theme.textSecondary).backgroundColor(this.theme.bgInput)
          .accessibilityText('文件操作')
          .bindMenu(this.RowMenu(row))
      }
      if (row.isDir) {
        AppIcon({ name: AppIconName.ChevronRight, iconSize: 14, color: this.theme.textHint })
      } else {
        Row() {
          AppIcon({ name: AppIconName.Export, iconSize: 15, color: this.theme.primary })
        }
        .width(34).height(34).borderRadius(9)
        .backgroundColor(this.theme.bgInput).justifyContent(FlexAlign.Center)
        .onClick(() => { this.doExport(row) })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 10, top: 9, bottom: 9 })
    .backgroundColor(this.theme.bgCard).borderRadius(14)
    .alignItems(VerticalAlign.Center)
    .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
    .onClick(() => { if (row.isDir) this.enterDir(row.name) })
    .focusable(true)
    .onKeyEvent((event: KeyEvent) => {
      if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ENTER && row.isDir) {
        this.enterDir(row.name)
        event.stopPropagation()
      }
    })
    .bindContextMenu(this.RowMenu(row), DeviceProfile.isPC() ? ResponseType.RightClick : ResponseType.LongPress)
  }

  /** 行长按 / 右侧菜单：导出（文件夹压 zip）/ 重命名 / 删除。 */
  @Builder
  RowMenu(row: FileEntry) {
    Menu() {
      MenuItem({ startIcon: $r('sys.symbol.arrow_up_circle'), content: row.isDir ? '导出为 zip' : '导出文件' })
        .onClick(() => { this.doExport(row) })
      MenuItem({ startIcon: $r('sys.symbol.square_and_pencil'), content: '重命名' })
        .onClick(() => { this.openRename(row.name) })
      MenuItem({ startIcon: $r('sys.symbol.trash'), content: '删除' })
        .onClick(() => { this.pendingDelete = row.name; this.pendingDeleteIsDir = row.isDir })
    }
  }

  @Builder
  EmptyState() {
    Column({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        Column().width(72).height(72).backgroundColor(this.theme.bgInput).borderRadius(18)
        AppIcon({ name: AppIconName.Folder, iconSize: 36, color: this.theme.textSecondary })
      }
      .width(72).height(72)
      Text(this.versionId.length === 0 ? '请先选择一个已装版本' : '此文件夹为空')
        .fontSize(16).fontWeight(500).fontColor(this.theme.textPrimary)
      Text(this.versionId.length === 0
        ? '从首页或版本管理切换到目标版本后再来'
        : '点右上角「导入」放入文件，或「＋」新建文件夹')
        .fontSize(12).fontColor(this.theme.textHint).textAlign(TextAlign.Center)
      if (this.versionId.length > 0) {
        Row({ space: 5 }) {
          AppIcon({ name: AppIconName.Import, iconSize: 12, color: this.theme.textOnPrimary })
          Text('导入文件').fontSize(13).fontWeight(600).fontColor(this.theme.textOnPrimary)
        }
        .height(36).padding({ left: 18, right: 18 }).borderRadius(18)
        .backgroundColor(this.theme.primary).alignItems(VerticalAlign.Center)
        .margin({ top: 8 })
        .onClick(() => { this.doImport() })
      }
    }
    .width('100%').layoutWeight(1)
    .alignItems(HorizontalAlign.Center).justifyContent(FlexAlign.Center)
    .padding({ left: 32, right: 32, bottom: 60 })
  }

  @Builder
  LoadingState() {
    Column({ space: 10 }) {
      LoadingProgress().width(36).height(36).color(this.theme.primary)
      Text('读取目录中…').fontSize(12).fontColor(this.theme.textHint)
    }
    .width('100%').layoutWeight(1)
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
  }

  @Builder
  BusyOverlay() {
    Column({ space: 12 }) {
      LoadingProgress().width(40).height(40).color(this.theme.primary)
      Text(this.busyLabel).fontSize(13).fontColor(this.theme.textPrimary)
    }
    .width('100%').height('100%')
    .position({ x: 0, y: 0 })
    .backgroundColor('#80000000')
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
  }

  @Builder
  DeleteConfirmOverlay() {
    Column() {
      Column() {
        Text('删除' + (this.pendingDeleteIsDir ? '文件夹' : '文件'))
          .fontSize(18).fontWeight(600).fontColor(this.theme.textPrimary)
          .margin({ bottom: 12 })
        Text('确定要删除「' + this.pendingDelete + '」吗？')
          .fontSize(14).fontColor(this.theme.textSecondary).margin({ bottom: 4 })
        Text(this.pendingDeleteIsDir
          ? '整个文件夹及其内容将被永久删除，无法恢复。'
          : '该文件将被永久删除，无法恢复。')
          .fontSize(12).fontColor(this.theme.textHint).margin({ bottom: 16 })
        Row({ space: 12 }) {
          Button('取消')
            .type(ButtonType.Capsule).height(36).fontSize(14).layoutWeight(1)
            .fontColor(this.theme.textSecondary).backgroundColor(this.theme.bgInput)
            .onClick(() => { this.pendingDelete = '' })
          Button('删除')
            .type(ButtonType.Capsule).height(36).fontSize(14).layoutWeight(1)
            .fontColor(this.theme.textOnPrimary).backgroundColor(this.theme.error)
            .onClick(() => { this.executeDelete() })
        }
        .width('100%')
      }
      .width('90%').padding(20)
      .backgroundColor(this.theme.bgCard).borderRadius(16)
      .shadow({ radius: 16, color: '#40000000', offsetX: 0, offsetY: 4 })
    }
    .width('100%').height('100%')
    .position({ x: 0, y: 0 })
    .backgroundColor('#80000000')
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    .onClick(() => { this.pendingDelete = '' })
  }

  @Builder
  RenameOverlay() {
    Column() {
      Column() {
        Text('重命名')
          .fontSize(18).fontWeight(600).fontColor(this.theme.textPrimary)
          .margin({ bottom: 12 })
        TextInput({ text: this.renameInput, placeholder: '新名称' })
          .fontSize(14).height(42).backgroundColor(this.theme.bgInput)
          .fontColor(this.theme.textPrimary).borderRadius(10)
          .onChange((v: string) => { this.renameInput = v; this.renameError = '' })
        if (this.renameError.length > 0) {
          Text(this.renameError).fontSize(11).fontColor(this.theme.error)
            .width('100%').margin({ top: 6 })
        }
        Row({ space: 12 }) {
          Button('取消')
            .type(ButtonType.Capsule).height(36).fontSize(14).layoutWeight(1)
            .fontColor(this.theme.textSecondary).backgroundColor(this.theme.bgInput)
            .onClick(() => { this.renameTarget = '' })
          Button('确定')
            .type(ButtonType.Capsule).height(36).fontSize(14).layoutWeight(1)
            .fontColor(this.theme.textOnPrimary).backgroundColor(this.theme.primary)
            .onClick(() => { this.executeRename() })
        }
        .width('100%').margin({ top: 16 })
      }
      .width('90%').padding(20)
      .backgroundColor(this.theme.bgCard).borderRadius(16)
      .shadow({ radius: 16, color: '#40000000', offsetX: 0, offsetY: 4 })
    }
    .width('100%').height('100%')
    .position({ x: 0, y: 0 })
    .backgroundColor('#80000000')
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
  }

  @Builder
  NewFolderOverlay() {
    Column() {
      Column() {
        Text('新建文件夹')
          .fontSize(18).fontWeight(600).fontColor(this.theme.textPrimary)
          .margin({ bottom: 12 })
        TextInput({ text: this.newFolderInput, placeholder: '文件夹名称' })
          .fontSize(14).height(42).backgroundColor(this.theme.bgInput)
          .fontColor(this.theme.textPrimary).borderRadius(10)
          .onChange((v: string) => { this.newFolderInput = v; this.newFolderError = '' })
        if (this.newFolderError.length > 0) {
          Text(this.newFolderError).fontSize(11).fontColor(this.theme.error)
            .width('100%').margin({ top: 6 })
        }
        Row({ space: 12 }) {
          Button('取消')
            .type(ButtonType.Capsule).height(36).fontSize(14).layoutWeight(1)
            .fontColor(this.theme.textSecondary).backgroundColor(this.theme.bgInput)
            .onClick(() => { this.showNewFolder = false })
          Button('创建')
            .type(ButtonType.Capsule).height(36).fontSize(14).layoutWeight(1)
            .fontColor(this.theme.textOnPrimary).backgroundColor(this.theme.primary)
            .onClick(() => { this.executeNewFolder() })
        }
        .width('100%').margin({ top: 16 })
      }
      .width('90%').padding(20)
      .backgroundColor(this.theme.bgCard).borderRadius(16)
      .shadow({ radius: 16, color: '#40000000', offsetX: 0, offsetY: 4 })
    }
    .width('100%').height('100%')
    .position({ x: 0, y: 0 })
    .backgroundColor('#80000000')
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
  }

  // ============================================================
  //  路径
  // ============================================================

  /** 版本根目录：隔离 → versions/<id>；非隔离 → .minecraft 根。 */
  private rootDir(): string {
    if (this.mcDir.length === 0) return ''
    if (!this.versionIsolation) return this.mcDir
    if (this.versionId.length === 0) return ''
    return this.mcDir + '/versions/' + this.versionId
  }

  /** 当前目录绝对路径。 */
  private curDir(): string {
    let root = this.rootDir()
    if (root.length === 0) return ''
    return this.rel.length === 0 ? root : root + '/' + this.rel
  }

  private crumbSegments(): string[] {
    if (this.rel.length === 0) return []
    return this.rel.split('/')
  }

  /** 面包屑第 idx 段对应的 rel 路径（前 idx+1 段拼接）。 */
  private crumbPathAt(idx: number): string {
    let segs = this.crumbSegments()
    return segs.slice(0, idx + 1).join('/')
  }

  private headerSubtitle(): string {
    if (this.versionId.length === 0 && this.versionIsolation) return '未选择版本'
    let loc = this.rel.length === 0 ? (this.versionIsolation ? this.versionId : '.minecraft') : this.rel
    return loc + ' · ' + this.rows.length + ' 项'
  }

  private subInfo(row: FileEntry): string {
    let t = this.formatMtime(row.mtimeMs)
    if (row.isDir) {
      return (row.childCount >= 0 ? row.childCount + ' 项' : '文件夹') + (t.length > 0 ? ' · ' + t : '')
    }
    return this.formatSize(row.size) + (t.length > 0 ? ' · ' + t : '')
  }

  // ============================================================
  //  扫描 / 导航
  // ============================================================

  private refresh(): void {
    this.loaded = false
    let dir = this.curDir()
    if (dir.length === 0) {
      this.rows = []
      this.loaded = true
      return
    }
    let entries: string[] = []
    try {
      entries = fs.listFileSync(dir)
    } catch (e) {
      this.rows = []
      this.loaded = true
      return
    }
    let result: FileEntry[] = []
    for (let name of entries) {
      let p = dir + '/' + name
      try {
        let st = fs.statSync(p)
        let isDir = st.isDirectory()
        let childCount = -1
        if (isDir) {
          try { childCount = fs.listFileSync(p).length } catch (e) { childCount = -1 }
        }
        result.push({
          name,
          isDir,
          size: isDir ? 0 : st.size,
          mtimeMs: st.mtime * 1000,
          childCount,
        })
      } catch (e) { /* skip */ }
    }
    // 目录在前，再按名称（不分大小写）升序
    result.sort((a: FileEntry, b: FileEntry): number => {
      if (a.isDir !== b.isDir) return a.isDir ? -1 : 1
      return a.name.toLowerCase() < b.name.toLowerCase() ? -1
        : (a.name.toLowerCase() > b.name.toLowerCase() ? 1 : 0)
    })
    this.rows = result
    this.loaded = true
    if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'refresh dir=%{public}s found=%{public}d', dir, result.length)
  }

  private enterDir(name: string): void {
    this.rel = this.rel.length === 0 ? name : this.rel + '/' + name
    this.refresh()
  }

  private goUp(): void {
    if (this.rel.length === 0) return
    let slash = this.rel.lastIndexOf('/')
    this.rel = slash >= 0 ? this.rel.substring(0, slash) : ''
    this.refresh()
  }

  // ============================================================
  //  导入 / 导出 / 删除 / 重命名 / 新建
  // ============================================================

  private getAbilityCtx(): common.UIAbilityContext | null {
    try {
      let ctx = AppStorage.get<common.UIAbilityContext>('uiAbilityContext')
      return ctx ? ctx : null
    } catch (e) {
      return null
    }
  }

  private safeToast(message: string, duration: number): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message, duration })
    } catch (e) {
      if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'showToast failed: %{public}s', (e as Error).message)
    }
  }

  private async doImport(): Promise<void> {
    if (this.busy) return
    let ctx = this.getAbilityCtx()
    if (ctx === null) { this.safeToast('上下文不可用，无法导入', 1500); return }
    let dir = this.curDir()
    if (dir.length === 0) { this.safeToast('请先选择一个已装版本', 1500); return }
    this.busy = true
    this.busyLabel = '正在导入文件…'
    try {
      let r = await GameArchiveIO.importAnyFiles(ctx, dir)
      this.busy = false
      if (r.cancelled) return
      this.safeToast(r.message, r.failures.length > 0 ? 3500 : 1800)
      if (r.names.length > 0) {
        this.refresh()
        this.onChanged()
      }
    } catch (e) {
      this.busy = false
      AppLogger.warn(TAG, 'doImport failed', e, LOG_DOMAIN_UI)
      this.safeToast('导入失败：' + (e as Error).message, 2400)
    }
  }

  private async doExport(row: FileEntry): Promise<void> {
    if (this.busy) return
    let ctx = this.getAbilityCtx()
    if (ctx === null) { this.safeToast('上下文不可用，无法导出', 1500); return }
    let dir = this.curDir()
    if (dir.length === 0) return
    let src = dir + '/' + row.name
    this.busy = true
    this.busyLabel = row.isDir ? '正在打包文件夹…' : '正在导出文件…'
    try {
      let r = row.isDir
        ? await GameArchiveIO.exportDirZip(ctx, src, row.name)
        : await GameArchiveIO.exportFile(ctx, src, row.name)
      this.busy = false
      if (r.cancelled) return
      if (r.ok) {
        this.safeToast('已导出「' + r.name + (row.isDir ? '.zip' : '') + '」', 1800)
      } else {
        this.safeToast(r.message, 2400)
      }
    } catch (e) {
      this.busy = false
      AppLogger.warn(TAG, 'doExport failed', e, LOG_DOMAIN_UI)
      this.safeToast('导出失败：' + (e as Error).message, 2400)
    }
  }

  private executeDelete(): void {
    let target = this.pendingDelete
    let isDir = this.pendingDeleteIsDir
    this.pendingDelete = ''
    if (target.length === 0) return
    let dir = this.curDir()
    if (dir.length === 0) return
    let p = dir + '/' + target
    try {
      if (isDir) {
        removeDirRecursive(p)
      } else {
        fs.unlinkSync(p)
      }
      this.safeToast('已删除「' + target + '」', 1500)
      this.refresh()
      this.onChanged()
    } catch (e) {
      AppLogger.warn(TAG, 'delete failed', e, LOG_DOMAIN_UI)
      this.safeToast('删除失败：' + (e as Error).message, 2200)
    }
  }

  private openRename(name: string): void {
    this.renameTarget = name
    this.renameInput = name
    this.renameError = ''
  }

  private executeRename(): void {
    let oldName = this.renameTarget
    let newName = this.sanitizeName(this.renameInput)
    if (oldName.length === 0) return
    if (newName.length === 0) { this.renameError = '名称不能为空'; return }
    if (newName === oldName) { this.renameTarget = ''; return }
    let dir = this.curDir()
    if (dir.length === 0) return
    let dest = dir + '/' + newName
    if (this.pathExists(dest)) { this.renameError = '已存在同名文件/文件夹'; return }
    try {
      fs.renameSync(dir + '/' + oldName, dest)
      this.renameTarget = ''
      this.safeToast('已重命名为「' + newName + '」', 1500)
      this.refresh()
      this.onChanged()
    } catch (e) {
      AppLogger.warn(TAG, 'rename failed', e, LOG_DOMAIN_UI)
      this.renameError = '重命名失败：' + (e as Error).message
    }
  }

  private openNewFolder(): void {
    if (this.curDir().length === 0) { this.safeToast('请先选择一个已装版本', 1500); return }
    this.showNewFolder = true
    this.newFolderInput = ''
    this.newFolderError = ''
  }

  private executeNewFolder(): void {
    let name = this.sanitizeName(this.newFolderInput)
    if (name.length === 0) { this.newFolderError = '名称不能为空'; return }
    let dir = this.curDir()
    if (dir.length === 0) return
    let dest = dir + '/' + name
    if (this.pathExists(dest)) { this.newFolderError = '已存在同名文件/文件夹'; return }
    try {
      fs.mkdirSync(dest)
      this.showNewFolder = false
      this.safeToast('已创建「' + name + '」', 1500)
      this.refresh()
      this.onChanged()
    } catch (e) {
      AppLogger.warn(TAG, 'mkdir failed', e, LOG_DOMAIN_UI)
      this.newFolderError = '创建失败：' + (e as Error).message
    }
  }

  // ============================================================
  //  工具
  // ============================================================

  private pathExists(p: string): boolean {
    try { fs.statSync(p); return true } catch (e) { return false }
  }

  /** 清理非法路径字符；去首尾空白。 */
  private sanitizeName(name: string): string {
    return name.replace(/[\/\\:*?"<>|]/g, '_').trim()
  }

  private formatSize(bytes: number): string {
    if (bytes < 0) return '—'
    if (bytes < 1024) return bytes + ' B'
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB'
    if (bytes < 1024 * 1024 * 1024) return (bytes / 1024 / 1024).toFixed(1) + ' MB'
    return (bytes / 1024 / 1024 / 1024).toFixed(2) + ' GB'
  }

  private formatMtime(ms: number): string {
    if (ms <= 0) return ''
    let d = new Date(ms)
    let p = (n: number): string => (n < 10 ? '0' + n : n.toString())
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate())
      + ' ' + p(d.getHours()) + ':' + p(d.getMinutes())
  }
}
