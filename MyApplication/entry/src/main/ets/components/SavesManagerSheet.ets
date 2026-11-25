/**
 * 呈现颜色遵循父层主题快照：操作文字与焦点独立于按钮填充，状态小字独立于进度填充。
 * 本域不读取主题偏好，不改变原事件、任务或账户生命周期；资源类别与第三方品牌保持独立。
 */
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

import { ImmersiveTitleScaffold } from './ImmersiveTitleScaffold';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ThemeColors } from 'commons';
import { resolveInstanceGameDir } from 'commons';
import { AppIconName } from 'commons';
import { AppIcon } from './AppIcon';
import { GameArchiveIO } from './GameArchiveIO';
import { ArchiveEntryConfirmation, ArchiveSelectionScope } from './ArchiveSelectionScope';
import { LauncherSkillBus } from '../launcherskill/LauncherSkillBus';
import { SkillFileScope } from '../launcherskill/SkillFileScope';
import { textArg, result } from '../launcherskill/LibraryResult';

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
  /** 同名版本也可能切换存储根或隔离目录；已挂载的存档页需要重新枚举。 */
  @Prop @Watch('onScopeChanged') mcDir: string = '';
  /** 目标版本 id；为空显示空态 */
  @Prop @Watch('onScopeChanged') versionId: string = '';
  @Prop @Watch('onScopeChanged') versionIsolation: boolean = true;
  /** 嵌入 VersionManagerSheet 第四步时为 true（用返回按钮取代拖拽指示条） */
  @Prop embedded: boolean = false;
  /** 仅当滑到本步时扫描磁盘 */
  @Prop @Watch('onScopeChanged') active: boolean = true;

  @State private rows: SaveRow[] = [];
  @State private loaded: boolean = false;
  /** 二次确认删除的世界名；空 = 无对话框 */
  @State @Watch('publishNavigationBlocked_') private pendingDelete: string = '';
  /** 导入 / 导出 / 压缩进行中：显示遮罩并禁用按钮 */
  @State @Watch('publishNavigationBlocked_') private busy: boolean = false;
  @State private busyLabel: string = '';

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
    if (this.active) this.refresh();
  }


  /** 卸载后不再向父标题发布迟到状态；文件任务和扫描的原所有权不变。 */
  private navigationProjectionAlive_: boolean = false;

  private skillScope_: SkillFileScope = new SkillFileScope();
  private skillScanError_: boolean = false;
  private pendingEntry_: ArchiveEntryConfirmation | undefined = undefined;

  private bindFileSkill_(): void {
    LauncherSkillBus.bind('worlds',this,(method:string,args:Record<string,Object>):Promise<Record<string,Object>>=>this.fileSkill_(method,args),
      ():boolean=>this.navigationProjectionAlive_ && this.active && AppStorage.get<boolean>('appInForeground')===true);
  }

  /** 目录和行引用均取自本次业务查询；异步选择器沿用面板的 busy / toast / 刷新逻辑。 */
  private async fileSkill_(method:string,args:Record<string,Object>):Promise<Record<string,Object>> {
    if (!this.active || !this.navigationProjectionAlive_ || textArg(args,'instance')!==this.versionId) return result('failed','instanceChanged');
    if (this.navigationBlocked_()) return result('needsUser','panelBusy');
    const dir=this.savesDir();
    if (method==='listWorlds') {
      this.refresh();
      if (this.skillScanError_) return result('failed','directoryUnreadable');
      const folder=this.skillScope_.list(this.mcDir,dir,this.versionId,true);
      if (!folder) return result('failed','directoryUnavailable');
      return {'state':'ready','instance':this.versionId,'folder':folder,'shared':resolveInstanceGameDir(this.mcDir,this.versionId,this.versionIsolation)===this.mcDir,
        'entries':this.rows.map((item):Record<string,Object>=>({'ref':this.skillScope_.row(item.name),'name':item.name,'valid':item.valid,'modified':item.mtimeMs}))};
    }
    const folder=textArg(args,'folder');
    if (!this.skillScope_.belongs(this.mcDir,dir,this.versionId,folder)) return result('failed','directoryChanged');

    if (method==='importWorlds') return await this.doImport(folder);
    const ref=textArg(args,'ref');
    const name=this.skillScope_.resolve(this.mcDir,dir,this.versionId,folder,ref);
    const item=this.rows.find(r=>r.name===name);
    if (!name || !item) return result('failed','entryChanged');

    if (method==='exportWorld') return await this.doExport(name);
    if (method==='requestWorldDeletion') {
      const shared=resolveInstanceGameDir(this.mcDir,this.versionId,this.versionIsolation)===this.mcDir;
      const target = ArchiveEntryConfirmation.capture(this.mcDir, dir, this.versionId, name, true);
      if (!target) return result('failed','entryChanged');
      try {
        LauncherSkillBus.awaitingUser(method);
        const accepted=await this.getUIContext().getPromptAction().showDialog({title:'删除「'+name+'」？',
          message:shared?'目标属于共享目录，将影响使用此目录的实例。':'目标属于所选实例。',buttons:[
          {text:'取消',color:this.theme.textSecondary as string},{text:'删除',color:this.theme.errorText as string}]}).catch(():undefined=>undefined);
        if (accepted?.index!==1) return result('cancelled');
        if (!this.active || !this.navigationProjectionAlive_ || this.navigationBlocked_() || this.skillScope_.resolve(this.mcDir,this.savesDir(),this.versionId,folder,ref)!==name) return result('failed','entryChanged');
        return this.removeConfirmed_(target) ? {'state':'ready','removed':name,'shared':shared} : result('failed','deleteFailed');
      } finally { target.close(); }
    }
    return result('failed','unsupportedOperation');
  }


  /** 导航只观察原遮罩事实，不取消任务或跳过原确认；未屏蔽正文时仍允许原返回。 */
  private navigationBlocked_(): boolean { return this.busy || this.pendingDelete.length > 0; }

  /** 业务状态变化后只发一个布尔投影，供已有父标题同步禁用状态。 */
  private publishNavigationBlocked_(): void {
    if (this.navigationProjectionAlive_) this.onNavigationBlocked(this.navigationBlocked_());
  }

  /** 仅注销标题状态投影，不新增任务取消或覆盖原文件事务。 */
  aboutToDisappear(): void {
    this.dismissEntry_();
    this.navigationProjectionAlive_ = false;
    LauncherSkillBus.unbind('worlds',this);
  }

  build() {
    if (this.embedded) {
      this.PanelBody_();
    } else {
      ImmersiveTitleScaffold({ title: '存档管理', contextLabel: this.versionId, contextTitle: '当前实例', theme: this.theme, modal: true,
        surfaceColor: this.theme.bgPrimary, closeLabel: '关闭管理面板',
        closeId: 'savesmanagersheet-close', closeEnabled: !this.navigationBlocked_(),
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
        // 实例身份由唯一页头负责，工具行只显示实际清单数量，不再重复长版本名。
        Text(this.loaded ? this.rows.length + ' 个存档' : '正在读取…')
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
        .backgroundColor(this.theme.actionPrimary).alignItems(VerticalAlign.Center)
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
          color: row.valid ? this.theme.actionText : this.theme.textHint,
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
              .fontSize(10).fontWeight(700).fontColor(this.theme.errorText)
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
          AppIcon({ name: AppIconName.Export, iconSize: 15, color: this.theme.actionText })
        }
        .width(36).height(36).borderRadius(10)
        .backgroundColor(this.theme.bgInput).justifyContent(FlexAlign.Center)
        .onClick(() => { this.doExport(row.name) })

        Row() {
          AppIcon({ name: AppIconName.Trash, iconSize: 15, color: this.theme.errorText })
        }
        .width(36).height(36).borderRadius(10)
        .backgroundColor(this.theme.errorBg).justifyContent(FlexAlign.Center)
        .onClick(() => { this.openDelete_(row.name, true) })
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
      Text('扫描 saves/ 中…').fontSize(12).fontColor(this.theme.textHint)
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

  // ============================================================
  //  数据 / 行为
  // ============================================================

  private savesDir(): string {
    if (this.mcDir.length === 0) return ''
    if (this.versionId.length === 0 && this.versionIsolation) return ''
    return resolveInstanceGameDir(this.mcDir, this.versionId, this.versionIsolation) + '/saves'
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
    this.skillScanError_ = false
    try {
      entries = fs.listFileSync(dir)
    } catch (e) {
      this.skillScanError_ = (e as BusinessError).code !== 13900002
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

  private async doImport(folderRef:string=''): Promise<Record<string,Object>> {
    if (this.busy) return result('needsUser','panelBusy')
    let ctx = this.getAbilityCtx()
    if (ctx === null) { this.safeToast('上下文不可用，无法导入', 1500); return result('failed','contextUnavailable') }
    let dir = this.savesDir()
    if (dir.length === 0) { this.safeToast('请先选择一个已装版本', 1500); return result('failed','contextUnavailable') }
    const originalRoot=this.mcDir, originalVersion=this.versionId, isolated=this.versionIsolation;

    const current=():boolean=>this.navigationProjectionAlive_ && this.active && this.mcDir===originalRoot && this.versionId===originalVersion &&
      this.versionIsolation===isolated && this.savesDir()===dir;
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
    this.busyLabel = '正在导入存档…'
    try {
      LauncherSkillBus.awaitingUser('importWorlds');
      let r = await GameArchiveIO.importSaveZips(ctx, dir,scope)
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
      hilog.warn(0x0000, TAG, 'doImport failed: %{public}s', (e as Error).message)
      this.safeToast('导入失败：' + (e as Error).message, 2400)
      return result('failed','fileOperationFailed')
    }
  }

  private async doExport(name: string): Promise<Record<string,Object>> {
    if (this.busy) return result('needsUser','panelBusy')
    let ctx = this.getAbilityCtx()
    if (ctx === null) { this.safeToast('上下文不可用，无法导出', 1500); return result('failed','contextUnavailable') }
    let dir = this.savesDir()
    if (dir.length === 0) return result('failed','directoryUnavailable')
    const root=this.mcDir, version=this.versionId, isolation=this.versionIsolation;
    const scope:ArchiveSelectionScope={root:root,current:():boolean=>this.navigationProjectionAlive_ && this.active &&
      version===this.versionId && root===this.mcDir && isolation===this.versionIsolation && this.savesDir()===dir};
    this.busy = true
    this.busyLabel = '正在打包存档…'
    try {
      LauncherSkillBus.awaitingUser('exportWorld');
      let r = await GameArchiveIO.exportSaveZip(ctx, dir, name,scope)
      this.busy = false
      if (r.cancelled) return result('cancelled')
      if (r.ok) {
        this.safeToast('已导出「' + r.name + '.zip」', 1800)
      } else {
        this.safeToast(r.message, 2400)
      }
      return r.ok ? {'state':'ready','exported':r.name} : result('failed','exportFailed')
    } catch (e) {
      this.busy = false
      hilog.warn(0x0000, TAG, 'doExport failed: %{public}s', (e as Error).message)
      this.safeToast('导出失败：' + (e as Error).message, 2400)
      return result('failed','fileOperationFailed')
    }
  }

  /** 展示玩家的确认前固定原条目，取消、换页或关闭时归还全部句柄。 */
  private openDelete_(name: string, isDirectory: boolean): void {
    this.dismissEntry_();
    const target = ArchiveEntryConfirmation.capture(this.mcDir, this.savesDir(), this.versionId, name, isDirectory);
    if (!target) { this.safeToast('项目已变化，请刷新后重试', 2000); return; }
    this.pendingEntry_ = target;
    this.pendingDelete = name;
  }

  private dismissEntry_(): void {
    this.pendingEntry_?.close();
    this.pendingEntry_ = undefined;
    this.pendingDelete = '';
  }

  private executeDelete(): void {
    const target = this.pendingEntry_;
    if (!target || this.pendingDelete !== target.name) { this.dismissEntry_(); return; }
    try { this.removeConfirmed_(target); } finally { this.dismissEntry_(); }
  }

  /** 玩家与具名调用共用原对象校验和删除后的实况回读，部分删除不会提示成功。 */
  private removeConfirmed_(target: ArchiveEntryConfirmation): boolean {
    const dir = this.savesDir();
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

  /** 把秒级 mtime 格式化成 "YYYY-MM-DD HH:mm"；0 显示占位。 */
  private formatMtime(ms: number): string {
    if (ms <= 0) return '—'
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
