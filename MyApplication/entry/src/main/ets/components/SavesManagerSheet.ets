/**
 * SavesManagerSheet.ets — 当前版本「存档管理」Sheet（世界文件夹的导入 / 导出 / 删除）
 *
 * 与 InstalledResourcesSheet（文件级：模组/资源包/光影/数据包）并列的第 5 个资源板块。
 * 存档区别于其它资源：每个存档是 saves/<世界名>/ 文件夹（非单文件），因此单独成组件：
 *   - 列表项 = saves/ 下的子文件夹（含 level.dat 视为有效世界，仍全部展示便于排障）
 *   - 导入：多选 .zip → 解压整理成 saves/<世界名>/（GameArchiveIO.importSaveZips）
 *   - 导出：把 saves/<世界名>/ 压成 .zip 另存（GameArchiveIO.exportSaveZip）
 *   - 删除：二次确认后递归删除该世界文件夹
 *
 * 路径基于父级传入的 mcDir（已是「沙箱 / 沙箱外」位置感知），沙箱外存档走同一套逻辑。
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

const TAG = 'SavesManagerSheet';

interface SaveRow {
  /** 文件夹名（= 世界名） */
  name: string;
  /** 最后修改时间（毫秒）；0 = 未知 */
  mtimeMs: number;
  /** 是否含 level.dat（有效 MC 世界） */
  valid: boolean;
}

@Component
export struct SavesManagerSheet {
  @Prop theme: ThemeColors = {} as ThemeColors;
  @Prop bottomSafeHeight: number = 0;
  /** .minecraft 根（不带尾部 /） */
  @Prop mcDir: string = '';
  /** 目标版本 id；为空显示空态 */
  @Prop @Watch('onScopeChanged') versionId: string = '';
  @Prop versionIsolation: boolean = true;
  /** 嵌入 VersionManagerSheet 第四步时为 true（用返回按钮取代拖拽指示条） */
  @Prop embedded: boolean = false;
  /** 仅当滑到本步时扫描磁盘 */
  @Prop @Watch('onScopeChanged') active: boolean = true;

  @State private rows: SaveRow[] = [];
  @State private loaded: boolean = false;
  /** 二次确认删除的世界名；空 = 无对话框 */
  @State private pendingDelete: string = '';
  /** 导入 / 导出 / 压缩进行中：显示遮罩并禁用按钮 */
  @State private busy: boolean = false;
  @State private busyLabel: string = '';

  onClose: () => void = () => {};
  onBack: () => void = () => {};
  onChanged: () => void = () => {};

  aboutToAppear() {
    if (this.active) this.refresh();
  }

  onScopeChanged(): void {
    if (this.active) this.refresh();
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
        Text('存档管理')
          .fontSize(22).fontWeight(700).fontColor(this.theme.textPrimary)
        Text(this.headerSubtitle())
          .fontSize(11).fontColor(this.theme.textHint)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Row({ space: 8 }) {
        Row({ space: 5 }) {
          AppIcon({ name: AppIconName.Refresh, iconSize: 13, color: this.theme.textSecondary })
          Text('刷新').fontSize(12).fontWeight(600).fontColor(this.theme.textSecondary)
        }
        .height(32).padding({ left: 12, right: 12 }).borderRadius(16)
        .backgroundColor(this.theme.bgInput).alignItems(VerticalAlign.Center)
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
    .padding({ left: 20, right: 20, top: 6, bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  ListView() {
    List({ space: 10 }) {
      ForEach(this.rows, (row: SaveRow) => {
        ListItem() {
          this.RowItem(row)
        }
      }, (row: SaveRow) => row.name + '|' + row.mtimeMs)

      ListItem() {
        Text('共 ' + this.rows.length + ' 个存档 · 导入会自动解压为文件夹')
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
  RowItem(row: SaveRow) {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.Center }) {
        Column().width(40).height(40).borderRadius(10)
          .backgroundColor(row.valid ? this.theme.primaryLight : this.theme.bgInput)
        AppIcon({
          name: AppIconName.Save,
          iconSize: 20,
          color: row.valid ? this.theme.primary : this.theme.textHint,
        })
      }
      .width(40).height(40)

      Column({ space: 4 }) {
        Text(row.name)
          .fontSize(14).fontWeight(600).fontColor(this.theme.textPrimary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 6 }) {
          if (!row.valid) {
            Text('缺 level.dat')
              .fontSize(10).fontWeight(700).fontColor(this.theme.error)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(5).backgroundColor(this.theme.errorBg)
          }
          Text(this.formatMtime(row.mtimeMs))
            .fontSize(11).fontWeight(500).fontColor(this.theme.textHint)
        }
        .alignItems(VerticalAlign.Center)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Row({ space: 8 }) {
        Row() {
          AppIcon({ name: AppIconName.Export, iconSize: 15, color: this.theme.primary })
        }
        .width(36).height(36).borderRadius(10)
        .backgroundColor(this.theme.bgInput).justifyContent(FlexAlign.Center)
        .onClick(() => { this.doExport(row.name) })

        Row() {
          AppIcon({ name: AppIconName.Trash, iconSize: 15, color: this.theme.error })
        }
        .width(36).height(36).borderRadius(10)
        .backgroundColor(this.theme.errorBg).justifyContent(FlexAlign.Center)
        .onClick(() => { this.pendingDelete = row.name })
      }
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 12, right: 10, top: 10, bottom: 10 })
    .backgroundColor(this.theme.bgCard).borderRadius(14)
    .alignItems(VerticalAlign.Center)
    .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
  }

  @Builder
  EmptyState() {
    Column({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        Column().width(72).height(72).backgroundColor(this.theme.bgInput).borderRadius(18)
        AppIcon({ name: AppIconName.Save, iconSize: 36, color: this.theme.textSecondary })
      }
      .width(72).height(72)
      Text(this.versionId.length === 0 ? '请先选择一个已装版本' : '尚无存档')
        .fontSize(16).fontWeight(500).fontColor(this.theme.textPrimary)
      Text(this.versionId.length === 0
        ? '从首页或版本管理切换到目标版本后再来管理'
        : '点右上角「导入」选择一个存档 .zip 文件')
        .fontSize(12).fontColor(this.theme.textHint).textAlign(TextAlign.Center)
      if (this.versionId.length > 0) {
        Row({ space: 5 }) {
          AppIcon({ name: AppIconName.Import, iconSize: 12, color: this.theme.textOnPrimary })
          Text('导入存档').fontSize(13).fontWeight(600).fontColor(this.theme.textOnPrimary)
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
      Text('扫描 saves/ 中…').fontSize(12).fontColor(this.theme.textHint)
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
        Text('删除存档')
          .fontSize(18).fontWeight(600).fontColor(this.theme.textPrimary)
          .margin({ bottom: 12 })
        Text('确定要删除「' + this.pendingDelete + '」吗？')
          .fontSize(14).fontColor(this.theme.textSecondary).margin({ bottom: 4 })
        Text('整个世界文件夹将被永久删除，无法恢复。建议先导出备份。')
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

  // ============================================================
  //  数据 / 行为
  // ============================================================

  private savesDir(): string {
    if (this.mcDir.length === 0) return ''
    if (!this.versionIsolation) return this.mcDir + '/saves'
    if (this.versionId.length === 0) return ''
    return this.mcDir + '/versions/' + this.versionId + '/saves'
  }

  private headerSubtitle(): string {
    if (this.versionId.length === 0) return '未选择版本'
    if (this.rows.length === 0) return this.versionId + ' · 暂无存档'
    return this.versionId + ' · ' + this.rows.length + ' 个存档'
  }

  private refresh(): void {
    this.loaded = false
    let dir = this.savesDir()
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
    let result: SaveRow[] = []
    for (let name of entries) {
      let p = dir + '/' + name
      try {
        let st = fs.statSync(p)
        if (!st.isDirectory()) continue
        let valid = false
        try { fs.statSync(p + '/level.dat'); valid = true } catch (e) { /* */ }
        result.push({ name, mtimeMs: st.mtime * 1000, valid })
      } catch (e) { /* skip */ }
    }
    // 按修改时间倒序（最近玩的在上）
    result.sort((a: SaveRow, b: SaveRow): number => b.mtimeMs - a.mtimeMs)
    this.rows = result
    this.loaded = true
    hilog.info(0x0000, TAG, 'refresh dir=%{public}s found=%{public}d', dir, result.length)
  }

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
      hilog.warn(0x0000, TAG, 'showToast failed: %{public}s', (e as Error).message)
    }
  }

  private async doImport(): Promise<void> {
    if (this.busy) return
    let ctx = this.getAbilityCtx()
    if (ctx === null) { this.safeToast('上下文不可用，无法导入', 1500); return }
    let dir = this.savesDir()
    if (dir.length === 0) { this.safeToast('请先选择一个已装版本', 1500); return }
    this.busy = true
    this.busyLabel = '正在导入存档…'
    try {
      let r = await GameArchiveIO.importSaveZips(ctx, dir)
      this.busy = false
      if (r.cancelled) return
      this.safeToast(r.message, r.failures.length > 0 ? 3500 : 1800)
      if (r.names.length > 0) {
        this.refresh()
        this.onChanged()
      }
    } catch (e) {
      this.busy = false
      hilog.warn(0x0000, TAG, 'doImport failed: %{public}s', (e as Error).message)
      this.safeToast('导入失败：' + (e as Error).message, 2400)
    }
  }

  private async doExport(name: string): Promise<void> {
    if (this.busy) return
    let ctx = this.getAbilityCtx()
    if (ctx === null) { this.safeToast('上下文不可用，无法导出', 1500); return }
    let dir = this.savesDir()
    if (dir.length === 0) return
    this.busy = true
    this.busyLabel = '正在打包存档…'
    try {
      let r = await GameArchiveIO.exportSaveZip(ctx, dir, name)
      this.busy = false
      if (r.cancelled) return
      if (r.ok) {
        this.safeToast('已导出「' + r.name + '.zip」', 1800)
      } else {
        this.safeToast(r.message, 2400)
      }
    } catch (e) {
      this.busy = false
      hilog.warn(0x0000, TAG, 'doExport failed: %{public}s', (e as Error).message)
      this.safeToast('导出失败：' + (e as Error).message, 2400)
    }
  }

  private executeDelete(): void {
    let target = this.pendingDelete
    this.pendingDelete = ''
    if (target.length === 0) return
    let dir = this.savesDir()
    if (dir.length === 0) return
    try {
      removeDirRecursive(dir + '/' + target)
      this.safeToast('已删除「' + target + '」', 1500)
      this.refresh()
      this.onChanged()
    } catch (e) {
      hilog.warn(0x0000, TAG, 'delete failed: %{public}s', (e as Error).message)
      this.safeToast('删除失败：' + (e as Error).message, 2200)
    }
  }

  /** 把秒级 mtime 格式化成 "YYYY-MM-DD HH:mm"；0 显示占位。 */
  private formatMtime(ms: number): string {
    if (ms <= 0) return '—'
    let d = new Date(ms)
    let p = (n: number): string => (n < 10 ? '0' + n : n.toString())
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate())
      + ' ' + p(d.getHours()) + ':' + p(d.getMinutes())
  }
}
