/**
 * 呈现颜色遵循父层主题快照：操作文字与焦点独立于按钮填充，状态小字独立于进度填充。
 * 本域不读取主题偏好，不改变原事件、任务或账户生命周期；资源类别与第三方品牌保持独立。
 */
import { AppRoundIconButton } from './AppRoundIconButton';
import { ImmersiveTitleScaffold } from './ImmersiveTitleScaffold';
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
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ThemeColors } from 'commons';
import { resolveInstanceGameDir } from 'commons';
import { AppIconName } from 'commons';
import { AppIcon } from './AppIcon';
import { GameArchiveIO } from './GameArchiveIO';
import { ArchiveEntryConfirmation, ArchiveSelectionScope, missingEntry } from './ArchiveSelectionScope';
import { LauncherSkillBus } from '../launcherskill/LauncherSkillBus';
import { SkillFileScope } from '../launcherskill/SkillFileScope';
import { textArg, result } from '../launcherskill/LibraryResult';
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
  /** 同名版本也可能切换存储根或隔离目录；文件列表和未确认操作归属原目录。 */
  @Prop @Watch('onScopeChanged') mcDir: string = '';
  /** 目标版本 id；为空显示空态 */
  @Prop @Watch('onScopeChanged') versionId: string = '';
  @Prop @Watch('onScopeChanged') versionIsolation: boolean = true;
  /** 嵌入 VersionManagerSheet 时为 true（用返回按钮取代拖拽指示条） */
  @Prop embedded: boolean = false;
  /** 仅当滑到本步时扫描磁盘 */
  @Prop @Watch('onScopeChanged') active: boolean = true;

  /** 相对根目录的当前路径（''=根）；用 / 分隔 */
  @State private rel: string = '';
  @State private rows: FileEntry[] = [];
  @State private loaded: boolean = false;
  @State @Watch('publishNavigationBlocked_') private busy: boolean = false;
  @State private busyLabel: string = '';

  /** 删除二次确认：目标名（''=无对话框）+ 是否目录 */
  @State @Watch('publishNavigationBlocked_') private pendingDelete: string = '';
  @State private pendingDeleteIsDir: boolean = false;

  /** 重命名浮层 */
  @State @Watch('publishNavigationBlocked_') private renameTarget: string = '';
  @State private renameInput: string = '';
  @State private renameError: string = '';

  /** 新建文件夹浮层 */
  @State @Watch('publishNavigationBlocked_') private showNewFolder: boolean = false;
  @State private newFolderInput: string = '';
  @State private newFolderError: string = '';

  onClose: () => void = () => {};
  onBack: () => void = () => {};
  /** 只投影本面板原遮罩/事务是否阻止导航，父宿主不复制文件业务状态。 */
  onNavigationBlocked: (blocked: boolean) => void = () => {};
  onChanged: () => void = () => {};

  aboutToAppear() {
    this.navigationProjectionAlive_ = true;
    this.bindFileSkill_();
    if (this.active) this.refresh();
  }

  onScopeChanged(): void {
    this.dismissEntry_();
    this.showNewFolder = false;
    // 新作用域从根目录重新浏览，不将旧位置的建目录草稿带到新位置。
    if (this.active) {
      this.rel = '';
      this.refresh();
    }
  }


  /** 卸载后不再向父标题发布迟到状态；文件任务和扫描的原所有权不变。 */
  private navigationProjectionAlive_: boolean = false;

  private skillScope_: SkillFileScope = new SkillFileScope();
  private skillScanError_: boolean = false;
  private pendingEntry_: ArchiveEntryConfirmation | undefined = undefined;

  private bindFileSkill_(): void {
    LauncherSkillBus.bind('instanceFiles',this,(method:string,args:Record<string,Object>):Promise<Record<string,Object>>=>this.fileSkill_(method,args),
      ():boolean=>this.navigationProjectionAlive_ && this.active && AppStorage.get<boolean>('appInForeground')===true);
  }

  /** 目录和行引用均取自本次业务查询；异步选择器沿用面板的 busy / toast / 刷新逻辑。 */
  private async fileSkill_(method:string,args:Record<string,Object>):Promise<Record<string,Object>> {
    if (!this.active || !this.navigationProjectionAlive_ || textArg(args,'instance')!==this.versionId) return result('failed','instanceChanged');
    if (this.navigationBlocked_()) return result('needsUser','panelBusy');
    const dir=this.curDir();
    if (method==='listInstanceFiles') {
      this.refresh();
      if (this.skillScanError_) return result('failed','directoryUnreadable');
      const folder=this.skillScope_.list(this.mcDir,dir,this.versionId,false);
      if (!folder) return result('failed','directoryUnavailable');
      return {'state':'ready','instance':this.versionId,'folder':folder,'shared':resolveInstanceGameDir(this.mcDir,this.versionId,this.versionIsolation)===this.mcDir,'segments':this.crumbSegments(),
        'entries':this.rows.map((item):Record<string,Object>=>({'ref':this.skillScope_.row(item.name),'name':item.name,'directory':item.isDir,'bytes':item.size,'modified':item.mtimeMs}))};
    }
    const folder=textArg(args,'folder');
    if (!this.skillScope_.belongs(this.mcDir,dir,this.versionId,folder)) return result('failed','directoryChanged');

    if (method==='navigateInstanceParent') { this.goUp(); return result('ready'); }
    if (method==='createInstanceFolder') {
      const name=textArg(args,'name');
      if (!name || name!==this.sanitizeName(name) || name==='.' || name==='..' || this.pathExists(dir+'/'+name)) return result('failed','invalidName');
      this.openNewFolder(); this.newFolderInput=name; this.executeNewFolder();
      return this.showNewFolder?result('failed','createFailed'):{'state':'ready','created':name};
    }
    if (method==='importInstanceFiles') return await this.doImport(folder);
    const ref=textArg(args,'ref');
    const name=this.skillScope_.resolve(this.mcDir,dir,this.versionId,folder,ref);
    const item=this.rows.find(r=>r.name===name);
    if (!name || !item) return result('failed','entryChanged');

    if (method==='enterInstanceFolder' && item.isDir) { this.enterDir(name); return result('ready'); }
    if (method==='requestInstanceFileRename') {
      const next=textArg(args,'newName');
      if (!next || next!==this.sanitizeName(next) || next==='.' || next==='..') return result('failed','invalidName');
      if (next===name || this.pathExists(dir+'/'+next)) return result('failed','nameUnavailable');
      const shared=resolveInstanceGameDir(this.mcDir,this.versionId,this.versionIsolation)===this.mcDir;
      const target = ArchiveEntryConfirmation.capture(this.mcDir, dir, this.versionId, name, item.isDir);
      if (!target) return result('failed','entryChanged');
      try {
        LauncherSkillBus.awaitingUser(method);
        const accepted=await this.getUIContext().getPromptAction().showDialog({title:'将「'+name+'」改为「'+next+'」？',
          message:shared?'目标属于共享目录。':'目标属于所选实例。',buttons:[{text:'取消',color:this.theme.textSecondary as string},{text:'确认',color:this.theme.actionText as string}]}).catch(():undefined=>undefined);
        if (accepted?.index!==1) return result('cancelled');
        if (!this.active || !this.navigationProjectionAlive_ || this.navigationBlocked_() || this.skillScope_.resolve(this.mcDir,this.curDir(),this.versionId,folder,ref)!==name) return result('failed','entryChanged');
        return this.renameConfirmed_(target, next) ? {'state':'ready','renamed':next,'shared':shared} : result('failed','renameFailed');
      } finally { target.close(); }
    }
    if (method==='exportInstanceFile') return await this.doExport(item);
    if (method==='requestInstanceFileDeletion') {
      const shared=resolveInstanceGameDir(this.mcDir,this.versionId,this.versionIsolation)===this.mcDir;
      const target = ArchiveEntryConfirmation.capture(this.mcDir, dir, this.versionId, name, item.isDir);
      if (!target) return result('failed','entryChanged');
      try {
        LauncherSkillBus.awaitingUser(method);
        const accepted=await this.getUIContext().getPromptAction().showDialog({title:'删除「'+name+'」？',
          message:shared?'目标属于共享目录，将影响使用此目录的实例。':'目标属于所选实例。',buttons:[
          {text:'取消',color:this.theme.textSecondary as string},{text:'删除',color:this.theme.errorText as string}]}).catch(():undefined=>undefined);
        if (accepted?.index!==1) return result('cancelled');
        if (!this.active || !this.navigationProjectionAlive_ || this.navigationBlocked_() || this.skillScope_.resolve(this.mcDir,this.curDir(),this.versionId,folder,ref)!==name) return result('failed','entryChanged');
        return this.removeConfirmed_(target) ? {'state':'ready','removed':name,'shared':shared} : result('failed','deleteFailed');
      } finally { target.close(); }
    }
    return result('failed','unsupportedOperation');
  }


  /** 导航只观察原遮罩事实，不取消任务或跳过原确认；未屏蔽正文时仍允许原返回。 */
  private navigationBlocked_(): boolean { return this.busy || this.pendingDelete.length > 0 || this.renameTarget.length > 0 || this.showNewFolder; }

  /** 业务状态变化后只发一个布尔投影，供已有父标题同步禁用状态。 */
  private publishNavigationBlocked_(): void {
    if (this.navigationProjectionAlive_) this.onNavigationBlocked(this.navigationBlocked_());
  }

  /** 仅注销标题状态投影，不新增任务取消或覆盖原文件事务。 */
  aboutToDisappear(): void {
    this.dismissEntry_();
    this.navigationProjectionAlive_ = false; LauncherSkillBus.unbind('instanceFiles',this);
  }

  build() {
    if (this.embedded) {
      this.PanelBody_();
    } else {
      ImmersiveTitleScaffold({ title: '版本文件夹', contextLabel: this.versionId, contextTitle: '当前实例', theme: this.theme, modal: true,
        surfaceColor: this.theme.bgPrimary, closeLabel: '关闭管理面板',
        closeId: 'versionfilebrowser-close', closeEnabled: !this.navigationBlocked_(),
        onClose: (): void => { if (!this.navigationBlocked_()) this.onClose(); },
        content: (): void => { this.ImmersiveTitleContent1_(); }
      })
    }
  }

  /** 原面板正文与覆盖层保持原组件所有权，宿主只接管导航动作。 */
  @Builder
  private PanelBody_() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
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
        // 路径只在面包屑出现，工具行仅保留当前目录的列表统计。
        Text(this.loaded ? this.rows.length + ' 项' : '正在读取…')
          .fontSize(11).fontColor(this.theme.textHint)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Row({ space: 8 }) {
        // 文件工具保留原32vp视觉，44vp命中与原遮罩禁用由共同普通按钮负责。
        AppRoundIconButton({ name: AppIconName.Plus, theme: this.theme, visualDiameter: 32,
          color: this.theme.textSecondary, containerBg: this.theme.bgInput, accessibilityLabel: '新建文件夹',
          actionEnabled: !this.navigationBlocked_(), controlId: 'version-file-new-folder',
          onAction: (): void => { this.openNewFolder(); } })
        AppRoundIconButton({ name: AppIconName.Refresh, theme: this.theme, visualDiameter: 32,
          color: this.theme.textSecondary, containerBg: this.theme.bgInput, accessibilityLabel: '刷新版本文件夹',
          actionEnabled: !this.navigationBlocked_(), controlId: 'version-file-refresh',
          onAction: (): void => { this.refresh(); } })

        Row({ space: 5 }) {
          AppIcon({ name: AppIconName.Import, iconSize: 13, color: this.theme.textOnPrimary })
          Text('导入').fontSize(12).fontWeight(600).fontColor(this.theme.textOnPrimary)
        }
        .height(32).padding({ left: 12, right: 12 }).borderRadius(16)
        .backgroundColor(this.theme.actionPrimary).alignItems(VerticalAlign.Center)
        .onClick(() => { this.doImport() })
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 6, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  /** 根节点明确共享/隔离目录；实例名由页头负责，其余路径只在这一条面包屑出现。 */
  @Builder
  Breadcrumb() {
    Row({ space: 6 }) {
      if (this.rel.length > 0) {
        Row({ space: 3 }) {
          AppIcon({ name: AppIconName.ChevronUp, iconSize: 12, color: this.theme.actionText })
          Text('上级').fontSize(11).fontWeight(600).fontColor(this.theme.actionText)
        }
        .height(26).padding({ left: 8, right: 10 }).borderRadius(13)
        .backgroundColor(this.theme.primaryLight).alignItems(VerticalAlign.Center)
        .onClick(() => { this.goUp() })
      }
      Scroll() {
        Row({ space: 2 }) {
          this.CrumbSeg(this.rootDir() === this.mcDir ? '.minecraft（共享）' : '实例目录（隔离）', '')
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
          color: row.isDir ? this.theme.actionText : this.theme.textSecondary,
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
          AppIcon({ name: AppIconName.Export, iconSize: 15, color: this.theme.actionText })
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
        .onClick(() => { this.openRename(row.name, row.isDir) })
      MenuItem({ startIcon: $r('sys.symbol.trash'), content: '删除' })
        .onClick(() => { this.openDelete_(row.name, row.isDir) })
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
        .backgroundColor(this.theme.actionPrimary).alignItems(VerticalAlign.Center)
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
      LoadingProgress().width(36).height(36).color(this.theme.actionText)
      Text('读取目录中…').fontSize(12).fontColor(this.theme.textHint)
    }
    .width('100%').layoutWeight(1)
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
  }

  @Builder
  BusyOverlay() {
    Column({ space: 12 }) {
      LoadingProgress().width(40).height(40).color(this.theme.actionText)
      Text(this.busyLabel).fontSize(13).fontColor(this.theme.textPrimary)
    }
    .width('100%').height('100%')
    .position({ x: 0, y: 0 })
    .backgroundColor(this.theme.overlayShade)
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
            .onClick(() => { this.dismissEntry_() })
          Button('删除')
            .type(ButtonType.Capsule).height(36).fontSize(14).layoutWeight(1)
            .fontColor(this.theme.textOnPrimary).backgroundColor(this.theme.error)
            .onClick(() => { this.executeDelete() })
        }
        .width('100%')
      }
      .width('90%').padding(20)
      .backgroundColor(this.theme.bgCard).borderRadius(16)
      .shadow({ radius: 16, color: this.theme.cardShadowColor, offsetX: 0, offsetY: 4 })
    }
    .width('100%').height('100%')
    .position({ x: 0, y: 0 })
    .backgroundColor(this.theme.overlayShade)
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    .onClick(() => { this.dismissEntry_() })
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
          Text(this.renameError).fontSize(11).fontColor(this.theme.errorText)
            .width('100%').margin({ top: 6 })
        }
        Row({ space: 12 }) {
          Button('取消')
            .type(ButtonType.Capsule).height(36).fontSize(14).layoutWeight(1)
            .fontColor(this.theme.textSecondary).backgroundColor(this.theme.bgInput)
            .onClick(() => { this.dismissEntry_() })
          Button('确定')
            .type(ButtonType.Capsule).height(36).fontSize(14).layoutWeight(1)
            .fontColor(this.theme.textOnPrimary).backgroundColor(this.theme.actionPrimary)
            .onClick(() => { this.executeRename() })
        }
        .width('100%').margin({ top: 16 })
      }
      .width('90%').padding(20)
      .backgroundColor(this.theme.bgCard).borderRadius(16)
      .shadow({ radius: 16, color: this.theme.cardShadowColor, offsetX: 0, offsetY: 4 })
    }
    .width('100%').height('100%')
    .position({ x: 0, y: 0 })
    .backgroundColor(this.theme.overlayShade)
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
          Text(this.newFolderError).fontSize(11).fontColor(this.theme.errorText)
            .width('100%').margin({ top: 6 })
        }
        Row({ space: 12 }) {
          Button('取消')
            .type(ButtonType.Capsule).height(36).fontSize(14).layoutWeight(1)
            .fontColor(this.theme.textSecondary).backgroundColor(this.theme.bgInput)
            .onClick(() => { this.showNewFolder = false })
          Button('创建')
            .type(ButtonType.Capsule).height(36).fontSize(14).layoutWeight(1)
            .fontColor(this.theme.textOnPrimary).backgroundColor(this.theme.actionPrimary)
            .onClick(() => { this.executeNewFolder() })
        }
        .width('100%').margin({ top: 16 })
      }
      .width('90%').padding(20)
      .backgroundColor(this.theme.bgCard).borderRadius(16)
      .shadow({ radius: 16, color: this.theme.cardShadowColor, offsetX: 0, offsetY: 4 })
    }
    .width('100%').height('100%')
    .position({ x: 0, y: 0 })
    .backgroundColor(this.theme.overlayShade)
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
  }

  // ============================================================
  //  路径
  // ============================================================

  /** 版本根目录：隔离 → versions/<id>；非隔离 → .minecraft 根。 */
  private rootDir(): string {
    if (this.mcDir.length === 0) return ''
    if (this.versionId.length === 0 && this.versionIsolation) return ''
    return resolveInstanceGameDir(this.mcDir, this.versionId, this.versionIsolation)
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
    this.skillScanError_ = false
    try {
      entries = fs.listFileSync(dir)
    } catch (e) {
      this.skillScanError_ = (e as BusinessError).code !== 13900002
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

  private async doImport(folderRef:string=''): Promise<Record<string,Object>> {
    if (this.busy) return result('needsUser','panelBusy')
    let ctx = this.getAbilityCtx()
    if (ctx === null) { this.safeToast('上下文不可用，无法导入', 1500); return result('failed','contextUnavailable') }
    let dir = this.curDir()
    if (dir.length === 0) { this.safeToast('请先选择一个已装版本', 1500); return result('failed','contextUnavailable') }
    const originalRoot=this.mcDir, originalVersion=this.versionId, isolated=this.versionIsolation;

    const current=():boolean=>this.navigationProjectionAlive_ && this.active && this.mcDir===originalRoot && this.versionId===originalVersion &&
      this.versionIsolation===isolated && this.curDir()===dir;
    const shared=resolveInstanceGameDir(this.mcDir,this.versionId,this.versionIsolation)===this.mcDir;
    const scope:ArchiveSelectionScope={root:originalRoot,current:current,consent:async():Promise<boolean>=>{
      if (!shared) return true;
      const choice=await this.getUIContext().getPromptAction().showDialog({title:'导入到共享 .minecraft 目录？',
        message:'使用同一游戏目录的实例都会看到本次导入。已有同名文件将保留。',buttons:[
        {text:'取消',color:this.theme.textSecondary as string},{text:'选择文件',color:this.theme.actionText as string}]}).catch(():undefined=>undefined);
      return choice?.index===1;
    }};
    if (folderRef && !this.skillScope_.belongs(originalRoot,dir,originalVersion,folderRef)) return result('failed','directoryChanged');
    this.busy = true
    this.busyLabel = '正在导入文件…'
    try {
      LauncherSkillBus.awaitingUser('importInstanceFiles');
      let r = await GameArchiveIO.importAnyFiles(ctx, dir,scope)
      this.busy = false
      if (r.cancelled) return result('cancelled')
      this.safeToast(r.message, r.failures.length > 0 ? 3500 : 1800)
      if (r.names.length > 0) {
        this.refresh()
        this.onChanged()
      }
      return {'state':r.failures.length>0?(r.names.length?'partial':'failed'):'ready','imported':r.names,'failedCount':r.failures.length,'reason':r.targetChanged?'directoryChanged':r.failures.length?'fileRejected':''}
    } catch (e) {
      this.busy = false
      AppLogger.warn(TAG, 'doImport failed', e, LOG_DOMAIN_UI)
      this.safeToast('导入失败：' + (e as Error).message, 2400)
      return result('failed','fileOperationFailed')
    }
  }

  private async doExport(row: FileEntry): Promise<Record<string,Object>> {
    if (this.busy) return result('needsUser','panelBusy')
    let ctx = this.getAbilityCtx()
    if (ctx === null) { this.safeToast('上下文不可用，无法导出', 1500); return result('failed','contextUnavailable') }
    let dir = this.curDir()
    if (dir.length === 0) return result('failed','directoryUnavailable')
    let src = dir + '/' + row.name
    const root=this.mcDir, version=this.versionId, isolation=this.versionIsolation;
    const scope:ArchiveSelectionScope={root:root,current:():boolean=>this.navigationProjectionAlive_ && this.active &&
      version===this.versionId && root===this.mcDir && isolation===this.versionIsolation && this.curDir()===dir};
    this.busy = true
    this.busyLabel = row.isDir ? '正在打包文件夹…' : '正在导出文件…'
    try {
      LauncherSkillBus.awaitingUser('exportInstanceFile');
      let r = row.isDir
        ? await GameArchiveIO.exportDirZip(ctx, src, row.name,scope)
        : await GameArchiveIO.exportFile(ctx, src, row.name,scope)
      this.busy = false
      if (r.cancelled) return result('cancelled')
      if (r.ok) {
        this.safeToast('已导出「' + r.name + (row.isDir ? '.zip' : '') + '」', 1800)
      } else {
        this.safeToast(r.message, 2400)
      }
      return r.ok ? {'state':'ready','exported':r.name} : result('failed','exportFailed')
    } catch (e) {
      this.busy = false
      AppLogger.warn(TAG, 'doExport failed', e, LOG_DOMAIN_UI)
      this.safeToast('导出失败：' + (e as Error).message, 2400)
      return result('failed','fileOperationFailed')
    }
  }

  /** 展示玩家的确认前固定原条目，取消、换页或关闭时归还全部句柄。 */
  private openDelete_(name: string, isDirectory: boolean): void {
    this.dismissEntry_();
    const target = ArchiveEntryConfirmation.capture(this.mcDir, this.curDir(), this.versionId, name, isDirectory);
    if (!target) { this.safeToast('项目已变化，请刷新后重试', 2000); return; }
    this.pendingEntry_ = target;
    this.pendingDelete = name;
    this.pendingDeleteIsDir = isDirectory;
  }

  private dismissEntry_(): void {
    this.pendingEntry_?.close();
    this.pendingEntry_ = undefined;
    this.pendingDelete = '';
    this.renameTarget = '';
  }

  private executeDelete(): void {
    const target = this.pendingEntry_;
    if (!target || this.pendingDelete !== target.name) { this.dismissEntry_(); return; }
    try { this.removeConfirmed_(target); } finally { this.dismissEntry_(); }
  }

  /** 玩家与具名调用共用原对象校验和删除后的实况回读，部分删除不会提示成功。 */
  private removeConfirmed_(target: ArchiveEntryConfirmation): boolean {
    const dir = this.curDir();
    if (!this.active || !this.navigationProjectionAlive_ || !target.matches(this.mcDir, dir, this.versionId)) {
      this.safeToast('原项目已变化，已停止删除', 2200);
      return false;
    }
    try {
      target.commit(this.mcDir, dir, this.versionId);
      this.safeToast('已删除原项目「' + target.name + '」', 1500);
      this.refresh();
      this.onChanged();
      return true;
    } catch (error) {
      this.safeToast('删除未完成：' + (error as Error).message, 2200);
      this.refresh();
      return false;
    }
  }

  private openRename(name: string, isDirectory: boolean): void {
    this.dismissEntry_();
    const target = ArchiveEntryConfirmation.capture(this.mcDir, this.curDir(), this.versionId, name, isDirectory);
    if (!target) { this.safeToast('项目已变化，请刷新后重试', 2000); return; }
    this.pendingEntry_ = target;
    this.renameTarget = name;
    this.renameInput = name;
    this.renameError = '';
  }

  private executeRename(): void {
    const target = this.pendingEntry_;
    if (!target || this.renameTarget !== target.name) { this.dismissEntry_(); return; }
    const newName = this.sanitizeName(this.renameInput);
    if (newName === target.name || this.renameConfirmed_(target, newName)) this.dismissEntry_();
  }

  /** 不接管确认期间出现的同名替代物；目标已存在或不可读时保留原名称。 */
  private renameConfirmed_(target: ArchiveEntryConfirmation, newName: string): boolean {
    if (!newName || newName === '.' || newName === '..') { this.renameError = '名称无效'; return false; }
    const dir = this.curDir();
    if (!this.active || !this.navigationProjectionAlive_ || !target.matches(this.mcDir, dir, this.versionId)) {
      this.renameError = '原项目已变化，请取消并刷新'; return false;
    }
    const dest = dir + '/' + newName;
    try {
      if (!missingEntry(dest)) { this.renameError = '已存在同名文件/文件夹'; return false; }
      target.commit(this.mcDir, dir, this.versionId, newName);
      this.safeToast('已重命名为「' + newName + '」', 1500);
      this.refresh();
      this.onChanged();
      return true;
    } catch (error) {
      this.renameError = '重命名失败：' + (error as Error).message;
      return false;
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

  /** 保留原正文的父组件状态与业务回调；具名content只转调此真正@Builder，避免this漂移。 */
  @Builder
  private ImmersiveTitleContent1_() {
        this.PanelBody_();
      }
}
