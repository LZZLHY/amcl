import { common, ConfigurationConstant, Want } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { ThemeColors, ThemeMode, resolveTheme, resolveIsDark, AppIconName } from 'commons';
import { AppIcon } from '../components/AppIcon';
import { PreferenceManager } from 'feature_system';
import { LogShareRecord, loadShareHistory, revokeShare, isShareRecordCurrent, logShareSourceLabel, logShareInstanceForUrl } from '../components/LogShareClient';
import { getAiTaskSnapshot, cancelAiAnalysis } from '../components/AiAnalysisService';
import { clearSessionShare } from '../components/McSessionSnapshot';
import { flushPendingShareCredentials } from '../components/EvidenceShareService';

/** 分享凭据独立于本地账本；清理日志后仍能找到并撤回所有历史分享。 */
@Entry
@Component
struct LogShareHistoryPage {
  @State private records: LogShareRecord[] = [];
  @State private busy: boolean = false;
  @State private busyId: string = '';
  @State private statusText: string = '';
  @State private errorText: string = '';
  @State private warningText: string = '';
  @State private expandedRecord: string = '';
  @State private loaded: boolean = false;
  @State private loading: boolean = false;
  @State private theme: ThemeColors = resolveTheme(ThemeMode.SYSTEM, false);
  @StorageProp('topRectHeight') topSafeHeight: number = 0;
  @StorageProp('bottomRectHeight') bottomSafeHeight: number = 0;
  @StorageProp('currentColorMode') @Watch('onColorModeChange') currentColorMode: number = 0;
  private context: common.UIAbilityContext = AppStorage.get<common.UIAbilityContext>('uiAbilityContext')!;
  private prefManager: PreferenceManager = new PreferenceManager(this.context);

  aboutToAppear(): void {
    this.applyTheme_();
    this.refresh_();
  }
  onColorModeChange(): void { this.applyTheme_(); }
  private applyTheme_(): void {
    const systemIsDark: boolean = this.currentColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.theme = resolveTheme(this.prefManager.themeMode, resolveIsDark(this.prefManager.themeMode, systemIsDark));
  }
  /** 先补存撤回凭据再加载列表，错误态独立于空态；保留上一份列表以便重试。 */
  private async refresh_(): Promise<void> {
    if (this.loading) return;
    this.loading = true;
    this.errorText = '';
    let pendingWarning: string = '';
    try { await flushPendingShareCredentials(this.context); }
    catch (e) { pendingWarning = '有接收凭据尚未保存，请返回原分享操作重试保存。'; }
    try {
      const result = await loadShareHistory(this.context); this.records = result.records;
      this.warningText = pendingWarning + result.warnings.join('；');
    }
    catch (e) { this.errorText = '读取分享记录失败：' + (e as Error).message; }
    finally { this.loaded = true; this.loading = false; }
  }
  private confirmRevoke_(record: LogShareRecord): void {
    if (this.busy) return;
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '撤回这条在线分享？',
        message: '撤回后链接将无法访问。本地活动日志不会受影响。已过期的链接也可以清理。',
        buttons: [
          { text: '取消', color: this.theme.primary as string },
          { text: '撤回并清理记录', color: this.theme.error as string },
        ],
      }).then((res: promptAction.ShowDialogSuccessResponse) => {
        if (res.index === 1) this.revoke_(record);
      }).catch(() => { /* 点框外 = 取消 */ });
    } catch (e) { this.errorText = '无法打开确认框：' + (e as Error).message; }
  }
  /** 全页单请求防重入；成功后仅清理匹配链接的诊断引用，失败保留凭据及重试入口。 */
  private async revoke_(record: LogShareRecord): Promise<void> {
    if (this.busy) return;
    this.busy = true; this.busyId = record.url; this.errorText = ''; this.statusText = '';
    try {
      const result = await revokeShare(this.context, record);
      if (!result.ok) throw new Error(result.error);
      if (record.activityId !== undefined) {
        // 只取消绑定这条分享的任务，撤回旧链接不能影响同会话的新分析。
        if (getAiTaskSnapshot(record.activityId).shareId === record.id) cancelAiAnalysis(record.activityId);
        await clearSessionShare(record.activityId, record.id);
      }
      await this.refresh_();
      this.statusText = '分享已撤回，本地日志仍保留';
    } catch (e) { this.errorText = (e as Error).message; }
    finally { this.busy = false; this.busyId = ''; }
  }
  private async copy_(record: LogShareRecord): Promise<void> {
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, record.url));
      this.errorText = ''; this.statusText = '链接已复制';
    } catch (e) { this.errorText = '复制失败：' + (e as Error).message; }
  }
  /** 历史内容不被当作任意外链执行，只打开已知分享服务，异步打开失败在页面提示。 */
  private async open_(record: LogShareRecord): Promise<void> {
    if (logShareInstanceForUrl(record.url).length === 0) { this.errorText = '分享链接无效'; return; }
    const want: Want = { action: 'ohos.want.action.viewData', entities: ['entity.system.browsable'], uri: record.url };
    try { await this.context.startAbility(want); }
    catch (e) { this.errorText = '无法打开浏览器：' + (e as Error).message; }
  }

  /** 每条记录只保留复制主动作，文件明细/网页核对/撤回在同一低频菜单。 */
  private recordMenu_(record: LogShareRecord): void {
    if (this.busy) return;
    this.getUIContext().getPromptAction().showActionMenu({ title: '分享选项', buttons: [
      { text: '在网页中查看', color: this.theme.primary as string },
      { text: this.expandedRecord === record.url ? '收起发送文件' : '查看发送文件', color: this.theme.primary as string },
      { text: '撤回这条分享', color: this.theme.errorText as string },
    ] }).then((result: promptAction.ActionMenuSuccessResponse): void => {
      if (result.index === 0) this.open_(record);
      else if (result.index === 1) this.expandedRecord = this.expandedRecord === record.url ? '' : record.url;
      else if (result.index === 2) this.confirmRevoke_(record);
    }).catch((): void => {});
  }
  build() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Button('返回').onClick(() => { this.getUIContext().getRouter().back(); })
        Text('日志分享记录').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.theme.textPrimary)
      }.width('100%')
      Text('这里保留全部 LogShare 分享。清理本地活动日志后，仍可查看链接和撤回分享。')
        .fontSize(13).fontColor(this.theme.textSecondary).width('100%')
      if (this.errorText.length > 0) Text(this.errorText).fontColor(this.theme.error).width('100%')
      if (this.warningText.length > 0) Text(this.warningText).fontSize(12).fontColor(this.theme.warningText).width('100%')
      if (this.statusText.length > 0) Text(this.statusText).fontColor(this.theme.success).width('100%')
      if (!this.loaded || this.loading) {
        Column({ space: 8 }) {
          LoadingProgress().width(24).height(24).color(this.theme.primary)
          Text('正在读取分享记录…').fontColor(this.theme.textSecondary)
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else if ((this.errorText.length > 0 || this.warningText.length > 0) && this.records.length === 0) {
        Column({ space: 10 }) {
          Text('暂时无法读取分享记录').fontSize(16).fontColor(this.theme.textPrimary)
          Button('重试').onClick(() => { this.refresh_() })
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else if (this.records.length === 0) {
        Column({ space: 8 }) {
          Text('暂无日志分享记录').fontSize(16).fontColor(this.theme.textSecondary)
          Text('生成公开分享后，链接和撤回入口会保存在这里。')
            .fontSize(12).fontColor(this.theme.textHint).textAlign(TextAlign.Center)
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else { List({ space: 12 }) {
        ForEach(this.records, (record: LogShareRecord) => {
          ListItem() {
            Column({ space: 8 }) {
              Text((record.versionId || '活动日志') + ' · ' + logShareSourceLabel(record.url))
                .fontWeight(FontWeight.Bold).fontColor(this.theme.textPrimary)
              Text(new Date(record.sharedAt).toLocaleString() + (isShareRecordCurrent(record) ? ' · 有效期内' : ' · 已到期或有效期未知'))
                .fontSize(12).fontColor(this.theme.textSecondary)
              Text(record.url).fontSize(12).fontColor(this.theme.primary)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .onClick(() => { this.open_(record) })
              Text((record.selectedPaths?.length ?? 0) + ' 个发送文件' + (record.accepted === false ? ' · 接收信息待核对' : ''))
                .fontSize(12).fontColor(this.theme.textSecondary)
              if (this.expandedRecord === record.url) {
                Text((record.selectedPaths ?? []).join('\n')).fontSize(12).fontColor(this.theme.textSecondary)
              }
              if (record.verificationError) Text(record.verificationError).fontSize(12).fontColor(this.theme.textHint)
              Row({ space: 12 }) {
                Button(this.busyId === record.url ? '撤回中…' : '复制链接').height(44).layoutWeight(1)
                  .enabled(!this.busy && record.accepted !== false).backgroundColor(this.theme.primaryLight).fontColor(this.theme.primary)
                  .onClick(() => { this.copy_(record); })
                Button() { AppIcon({ name: AppIconName.More, iconSize: 20, color: this.theme.textSecondary }) }
                  .width(44).height(44).enabled(!this.busy).backgroundColor(Color.Transparent)
                  .accessibilityText('查看文件、打开链接或撤回').onClick(() => { this.recordMenu_(record); })
              }
            }.alignItems(HorizontalAlign.Start).width('100%').padding(14).backgroundColor(this.theme.bgInput).borderRadius(12)
          }
        }, (record: LogShareRecord): string => (record.apiBaseUrl ?? '') + record.id)
      }.layoutWeight(1).width('100%') }
    }.padding({ left: 16, right: 16, top: this.topSafeHeight + 12, bottom: this.bottomSafeHeight + 16 })
      .width('100%').height('100%').backgroundColor(this.theme.bgPrimary)
  }
}
