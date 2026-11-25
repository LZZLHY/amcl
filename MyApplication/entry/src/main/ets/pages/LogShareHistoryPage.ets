/**
 * 日志分享记录页：以时间、真实接收状态、活动身份和文件快照组织公开分享凭据。
 * 页面只重绘展示层，撤回后移除记录、产品网页门控及本地凭据恢复继续由既有流程处理。
 */
import { applyNativeTheme } from '../components/AppTheme';
import { LauncherSkillBus, SkillFields } from '../launcherskill/LauncherSkillBus';
import { common, ConfigurationConstant, Want } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { ThemeColors, ThemeMode, resolveTheme, resolveIsDark, AppIconName, DistributionPolicy } from 'commons';
import { AppIcon } from '../components/AppIcon';
import { ImmersiveTitleScaffold } from '../components/ImmersiveTitleScaffold';
import { PreferenceManager } from 'feature_system';
import { LogShareRecord, loadShareHistory, revokeShare, isShareRecordCurrent, logShareSourceLabel, logShareInstanceForUrl } from '../components/LogShareClient';
import { getAiTaskSnapshot, cancelAiAnalysis } from '../components/AiAnalysisService';
import { clearSessionShare } from '../components/McSessionSnapshot';
import { flushPendingShareCredentials } from '../components/EvidenceShareService';

/** 按引用传递记录快照，保留 Builder 对父级刷新状态的依赖。 */
interface LogShareRecordView { record: LogShareRecord; }

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
  /** 同进程主题确认后重建本页快照；不触发业务重载、偏好写入或新的窗口订阅。 */
  @StorageProp('appThemeRevision') @Watch('onColorModeChange') private appThemeRevision: number = 0;
  private context: common.UIAbilityContext = AppStorage.get<common.UIAbilityContext>('uiAbilityContext')!;
  private prefManager: PreferenceManager = new PreferenceManager(this.context);

  /** 已发布链接的撤回只打开真实二次确认，令牌、URL 和本机路径不作为通用返回。 */
  private async skillAction_(method: string, args: SkillFields): Promise<SkillFields> {
    if (!this.loaded || this.loading || this.busy) return { 'state': 'busy' };
    if (method === 'readSharedLogs') {
      await this.refresh_();
      if (this.errorText) return { 'state': 'failed', 'reason': 'readFailed' };
      const offset = Number(args['offset'] ?? 0);
      if (!Number.isSafeInteger(offset) || offset < 0) return { 'state': 'failed', 'reason': 'invalidOffset' };
      return { 'state': 'ready', 'total': this.records.length,
        'records': this.records.slice(offset,offset+30).map((r: LogShareRecord): SkillFields => ({
          'id': r.id, 'activityId': r.activityId ?? 0, 'createdAt': r.sharedAt, 'revocable': r.token.length > 0,
          'status': this.recordStateLabel_(r), 'retention': this.recordRetentionLabel_(r) })) };
    }
    const matches = this.records.filter((r: LogShareRecord): boolean => r.id === args['shareId'] && r.sharedAt === args['createdAt']);
    if (matches.length !== 1) return { 'state': 'failed', 'reason': 'shareChanged' };
    const record = matches[0];
    if (method === 'requestRevokeSharedLog' && record.token.length > 0) {
      LauncherSkillBus.followUserDecision(method,this.confirmRevoke_(record));
      return { 'state': 'needsUser', 'surface': 'revokeShare' };
    }
    if (method === 'viewSharedLog') {
      LauncherSkillBus.followUserDecision(method,this.recordMenu_(record));
      return { 'state': 'needsUser', 'surface': 'shareOptions' };
    }
    return { 'state': 'unavailable', 'reason': 'unsupportedAction' };
  }

  private bindSkill_(): void {
    LauncherSkillBus.bind('shares', this, (method: string, args: SkillFields): Promise<SkillFields> => this.skillAction_(method,args), (): boolean => {
      const page = this.getUIContext().getRouter().getState().name;
      return page === 'LogShareHistoryPage' || page === 'pages/LogShareHistoryPage';
    });
  }

  aboutToDisappear(): void { LauncherSkillBus.unbind('shares',this); }

  aboutToAppear(): void {
    this.applyTheme_();
    this.refresh_();
  }
  onColorModeChange(): void { this.applyTheme_(); }
  private applyTheme_(): void {
    const systemIsDark: boolean = this.currentColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.theme = resolveTheme(this.prefManager.themeMode, resolveIsDark(this.prefManager.themeMode, systemIsDark), this.prefManager.themeAccent);
    applyNativeTheme(this.theme);
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
  private async confirmRevoke_(record: LogShareRecord): Promise<void> {
    if (this.busy || this.loading || !this.loaded || !this.records.includes(record)) return;
    // 去重只得到已有链接；没有首次上传的凭据时，不打开会承诺可撤回的确认框。
    if (record.token.length === 0) {
      this.errorText = '该链接复用了已有日志，本机没有撤回凭据；需要首次上传者撤回或等待到期。'; return;
    }
    try {
      await this.getUIContext().getPromptAction().showDialog({
        title: '撤回这条在线分享？',
        message: '撤回后链接将无法访问。本地活动日志不会受影响。已过期的链接也可以清理。',
        buttons: [
          { text: '取消', color: this.theme.actionText as string },
          { text: '撤回并清理记录', color: this.theme.errorText as string },
        ],
      }).then(async (res: promptAction.ShowDialogSuccessResponse): Promise<void> => {
        if (res.index === 1) await this.revoke_(record);
      }).catch(() => { /* 点框外 = 取消 */ });
    } catch (e) { this.errorText = '无法打开确认框：' + (e as Error).message; }
  }
  /** 全页单请求防重入；成功后仅清理匹配链接的诊断引用，失败保留凭据及重试入口。 */
  private async revoke_(record: LogShareRecord): Promise<void> {
    if (this.busy || this.loading || !this.loaded || !this.records.includes(record)) return;
    this.busy = true; this.busyId = record.url; this.errorText = ''; this.statusText = '';
    try {
      const result = await revokeShare(this.context, record);
      if (!result.ok) throw new Error(result.error);
      // 服务已确认撤回。立即从当前可操作集合移除，后续凭据或页面刷新失败也不能复用旧链接。
      this.records = this.records.filter((r: LogShareRecord): boolean =>
        !(r.id === record.id && r.url === record.url && r.sharedAt === record.sharedAt));
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
    if (this.busy || this.loading || !this.loaded || !this.records.includes(record)) return;
    if (record.accepted === false) { this.errorText = '接收结果尚待核对，无法复制链接'; return; }
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, record.url));
      this.errorText = ''; this.statusText = '链接已复制';
    } catch (e) { this.errorText = '复制失败：' + (e as Error).message; }
  }
  /** 历史内容不被当作任意外链执行，只打开已知分享服务，异步打开失败在页面提示。 */
  private async open_(record: LogShareRecord): Promise<void> {
    // 商店历史记录仍可复制和撤回；网页动作在函数边界拒绝，旧事件不能触发浏览器。
    if (DistributionPolicy.isStore() || record.accepted === false) return;
    if (logShareInstanceForUrl(record.url).length === 0) { this.errorText = '分享链接无效'; return; }
    const want: Want = { action: 'ohos.want.action.viewData', entities: ['entity.system.browsable'], uri: record.url };
    try { await this.context.startAbility(want); }
    catch (e) { this.errorText = '无法打开浏览器：' + (e as Error).message; }
  }

  /** 具名入口与玩家“更多”共用同一菜单；返回索引只解释为实际展示过的按钮。 */
  private async recordMenu_(record: LogShareRecord): Promise<void> {
    if (this.busy) return;
    const files: promptAction.Button = {
      text:this.expandedRecord === record.url ? '收起发送文件' : '查看发送文件', color:this.theme.actionText as string };
    const revoke: promptAction.Button = {
      text:record.token.length > 0 ? '撤回这条分享' : '为何不能撤回', color:this.theme.errorText as string };
    const buttons: [promptAction.Button,promptAction.Button?,promptAction.Button?,promptAction.Button?] = [files,revoke];
    let browser = -1;
    let copy = -1;
    if (record.accepted !== false) {
      if (!DistributionPolicy.isStore()) {
        browser = buttons.length;
        const openButton: promptAction.Button = { text:'在网页中查看', color:this.theme.actionText as string };
        buttons.push(openButton);
      }
      copy = buttons.length;
      const copyButton: promptAction.Button = { text:'复制链接', color:this.theme.actionText as string };
      buttons.push(copyButton);
    }
    const result = await this.getUIContext().getPromptAction().showActionMenu({title:'分享选项',buttons:buttons})
      .catch((): undefined => undefined);
    if (!result || result.index < 0 || result.index >= buttons.length || this.busy || this.loading || !this.loaded) return;
    const current = this.records.find((r: LogShareRecord): boolean =>
      r.id === record.id && r.url === record.url && r.sharedAt === record.sharedAt);
    if (!current) { this.errorText = '分享记录已变化'; return; }
    if (result.index === 0) this.expandedRecord = this.expandedRecord === record.url ? '' : record.url;
    else if (result.index === 1) await this.confirmRevoke_(current);
    else if (result.index === copy) await this.copy_(current);
    else if (result.index === browser) await this.open_(current);
  }
  /** 缓存路由再次显示时补取确认主题，只更新显示快照。 */
  onPageShow(): void { this.bindSkill_(); this.applyTheme_(); }

  build() {
    Column() {
      // 返回仅离开记录页，撤回、复制与异步凭据保存仍走原入口。
      ImmersiveTitleScaffold({ title: '日志分享记录', theme: this.theme, topSafeHeight: this.topSafeHeight,
        surfaceColor: this.theme.bgPrimary, onBack: (): void => { this.getUIContext().getRouter().back(); },
        content: (): void => { this.ImmersiveTitleContent1_(); }
      })
    }
      .width('100%').height('100%').backgroundColor(this.theme.bgPrimary)
  }

  /**
   * 分享状态只从已持久化的接收事实和现有有效期判据推导。撤回成功仍由原流程移除记录，
   * 这里不增加“已撤回”伪记录，也不把接收校验失败显示为普通成功链接。
   */
  private recordStateLabel_(record: LogShareRecord): string {
    if (record.accepted === false) return '接收待核对';
    if (record.token.length === 0) return '已有链接 · 无撤回凭据';
    return isShareRecordCurrent(record) ? '有效期内' : '已到期或未知';
  }

  /** 预计保留结束时间来自该记录的服务端保留期；旧记录缺少该值时明确显示未知。 */
  private recordRetentionLabel_(record: LogShareRecord): string {
    if (record.storageTimeSec === undefined || record.storageTimeSec <= 0) return '预计保留期未知';
    return '预计保留至 ' + new Date(record.sharedAt + record.storageTimeSec * 1000).toLocaleString();
  }

  /**
   * 每张分享卡以时间和状态起头，活动名、真实服务来源、文件数与快照链接各自成行。
   * 高频复制保持原 enabled 判据，网页/文件/撤回继续进入现有菜单和确认流程；已撤回记录
   * 不在此列表中保留，因此本地日志与在线撤回的不同作用仍由原成功反馈说明。
   */
  @Builder
  private ShareRecord_(params: LogShareRecordView) {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text(new Date(params.record.sharedAt).toLocaleString()).fontSize(12).fontColor(this.theme.textSecondary).layoutWeight(1)
        Text(this.recordStateLabel_(params.record)).fontSize(12).fontWeight(600)
          .fontColor(params.record.accepted === false ? this.theme.errorText : isShareRecordCurrent(params.record) ? this.theme.successText : this.theme.warningText)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 }).borderRadius(8)
          .backgroundColor(params.record.accepted === false ? this.theme.errorBg : isShareRecordCurrent(params.record) ? this.theme.successBg : this.theme.warningBg)
      }.width('100%')
      Text(params.record.versionId || '活动日志').fontSize(16).fontWeight(600).fontColor(this.theme.textPrimary)
        .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(logShareSourceLabel(params.record.url) + ' · ' + (params.record.selectedPaths?.length ?? 0) + ' 个发送文件')
        .fontSize(12).fontColor(this.theme.textSecondary).width('100%')
      if (DistributionPolicy.isStore()) {
        Text(params.record.url).fontSize(14).fontWeight(600).fontColor(this.theme.textSecondary)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      } else {
        Button() {
          Text(params.record.url).fontSize(14).fontWeight(600).fontColor(this.theme.actionText)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').textAlign(TextAlign.Start)
        }.width('100%').constraintSize({ minHeight: 44 }).padding(0).borderRadius(8).backgroundColor(Color.Transparent)
          .accessibilityText('在网页中查看分享链接').onClick(() => { this.open_(params.record); })
      }
      Text(this.recordRetentionLabel_(params.record)).fontSize(12).fontColor(this.theme.textHint).width('100%')
      if (this.expandedRecord === params.record.url) {
        Text((params.record.selectedPaths ?? []).join('\n')).fontSize(12).fontColor(this.theme.textSecondary).width('100%')
          .padding(12).backgroundColor(this.theme.bgPrimary).borderRadius(12)
      }
      if (params.record.verificationError) {
        Text(params.record.verificationError).fontSize(12).fontColor(this.theme.warningText).width('100%')
      }
      Row({ space: 12 }) {
        Button() {
          Row({ space: 8 }) {
            AppIcon({ name: AppIconName.Copy, iconSize: 18, color: this.theme.textOnPrimary })
            Text(this.busyId === params.record.url ? '撤回中…' : '复制链接').fontSize(14).fontWeight(600).fontColor(this.theme.textOnPrimary)
          }
        }.height(48).layoutWeight(1).borderRadius(24).enabled(!this.busy && params.record.accepted !== false)
          .backgroundColor(this.theme.actionPrimary).onClick(() => { this.copy_(params.record); })
        Button() { AppIcon({ name: AppIconName.More, iconSize: 20, color: this.theme.textSecondary }) }
          .width(44).height(44).padding(0).borderRadius(22).enabled(!this.busy).backgroundColor(Color.Transparent)
          .accessibilityText(DistributionPolicy.isStore() ? '查看文件或撤回' : '查看文件、打开链接或撤回')
          .onClick(() => { this.recordMenu_(params.record); })
      }.width('100%')
    }.alignItems(HorizontalAlign.Start).width('100%').padding(16).backgroundColor(this.theme.bgCard).borderRadius(18)
  }

  /**
   * 页面保持单一列表滚动轴与原读取、空态、失败判据。顶部结果条只在真实反馈存在时出现，
   * 不能用空列表掩盖读取或待保存凭据错误；成功撤回仍显示“本地日志仍保留”的现有结果。
   */
  @Builder
  private ImmersiveTitleContent1_() {
    Column({ space: 16 }) {
      if (this.errorText.length > 0) {
        Text(this.errorText).fontSize(12).fontColor(this.theme.errorText).width('100%')
          .padding(12).backgroundColor(this.theme.errorBg).borderRadius(12)
      }
      if (this.warningText.length > 0) {
        Text(this.warningText).fontSize(12).fontColor(this.theme.warningText).width('100%')
          .padding(12).backgroundColor(this.theme.warningBg).borderRadius(12)
      }
      if (this.statusText.length > 0) {
        Text(this.statusText).fontSize(12).fontColor(this.theme.successText).width('100%')
          .padding(12).backgroundColor(this.theme.successBg).borderRadius(12)
      }
      if (!this.loaded || this.loading) {
        Column({ space: 12 }) {
          LoadingProgress().width(28).height(28).color(this.theme.actionText)
          Text('正在读取分享记录…').fontSize(14).fontColor(this.theme.textSecondary)
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else if ((this.errorText.length > 0 || this.warningText.length > 0) && this.records.length === 0) {
        Column({ space: 12 }) {
          AppIcon({ name: AppIconName.Warning, iconSize: 32, color: this.theme.warningText })
          Text('暂时无法读取分享记录').fontSize(16).fontWeight(600).fontColor(this.theme.textPrimary)
          Button('重试').height(44).padding({ left: 24, right: 24 }).borderRadius(22)
            .backgroundColor(this.theme.primaryLight).fontColor(this.theme.actionText).onClick(() => { this.refresh_(); })
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else if (this.records.length === 0) {
        Column({ space: 12 }) {
          AppIcon({ name: AppIconName.Share, iconSize: 32, color: this.theme.actionText })
          Text('暂无日志分享记录').fontSize(16).fontWeight(600).fontColor(this.theme.textPrimary)
          Text('生成公开分享后，链接和撤回入口会保存在这里。')
            .fontSize(12).fontColor(this.theme.textSecondary).textAlign(TextAlign.Center)
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else {
        List({ space: 16 }) {
          ListItem() {
            Text('查看分享时的文件快照，或撤回在线链接。').fontSize(14).fontColor(this.theme.textSecondary).width('100%')
          }
          ForEach(this.records, (record: LogShareRecord) => {
            ListItem() { this.ShareRecord_({ record: record }) }
          }, (record: LogShareRecord): string => (record.apiBaseUrl ?? '') + record.id)
          ListItem() {
            Row({ space: 12 }) {
              AppIcon({ name: AppIconName.Info, iconSize: 18, color: this.theme.actionText })
              Text('复制与撤回针对在线分享；删除本地活动日志不会自动撤回链接。')
                .fontSize(12).fontColor(this.theme.textSecondary).layoutWeight(1)
            }.width('100%').padding(16).backgroundColor(this.theme.primaryLight).borderRadius(14)
          }
        }.layoutWeight(1).width('100%').scrollBar(BarState.Auto)
      }
    }.padding({ left: 20, right: 20, top: 12, bottom: this.bottomSafeHeight + 16 }).width('100%').height('100%')
  }
}
