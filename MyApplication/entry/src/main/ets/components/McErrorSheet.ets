/**
 * McErrorSheet.ets — MC 启动失败信息 Sheet（v6.5.1，2026-05-22 重设计）
 *
 * 核心改动：不再原样吐 Java 堆栈给用户看，而是通过 `McErrorClassifier`
 * 把异常翻译成"为什么会出错 + 怎么办"。结构对齐 docs/design/mc_error_sheet.pen：
 *
 *   ┌────────────────────────────────────────┐
 *   │  Header   ⌘ 启动失败 · 异常退出   ⋯    │   ← 红色小标签 + 大版本号 + 关闭
 *   │           Minecraft 26.1               │
 *   ├────────────────────────────────────────┤
 *   │     [Hero — 红底 ⚠ 大图标]             │
 *   │     游戏启动失败                        │
 *   │     [version chip] · 14:20             │
 *   ├────────────────────────────────────────┤
 *   │  ⓘ  为什么会出错？                      │   ← 人话原因 + 技术 chip
 *   ├────────────────────────────────────────┤
 *   │  🔍 日志分析与分享      [LogShare.CN]   │   ← M0 重绘：取代原「解决办法」卡
 *   │     隐私说明（脱敏 / 留存 / 可撤回）     │
 *   │   [分享日志]        [AI 智能分析]       │   ← 分享先进入活动账本选择与预览
 *   │   [      分享日志（全宽 46px）      ]   │
 *   │     链接行 ↗ 可跳转 · ⧉ 复制 · 🗑 撤回   │   ← 含剩余有效期
 *   │     AI 结果框（可展开收起 + 渐隐）       │
 *   ├────────────────────────────────────────┤
 *   │  ▸ 技术详情（点击展开）        [复制]   │   ← 折叠
 *   │     [errorKind chip]                   │
 *   │     ┌─ log box (mono) ──────┐          │
 *   ├────────────────────────────────────────┤
 *   │  [打开 1.21.x 版本 →]  [⧉]  [✕]        │   ← 主操作 + 复制 + 关闭
 *   └────────────────────────────────────────┘
 *
 * 主按钮的 label 和点击行为由 McDiagnosis.primaryActionKey 决定，通过 onAction
 * 回调透传给父组件 Index（'open_versions' → 关 sheet 切到 DownloadTab，等等）。
 *
 * 2026-07-30（M0，日志系统 v3）：
 *   - 删掉「建议的解决办法」卡。`suggestions` 是按错误类别硬编码的静态文案，S0 已证明
 *     规则会误判，而它给的建议恰恰是破坏性的（劝换版本 / 删版本重下）。字段与
 *     `primaryActionKey` 保留驱动底部主按钮，只是不再单独占一张卡。
 *   - LogShare 从「加塞的一小行 mini 按钮」升为正式卡，动作升为 46px 大按钮。
 *   - AI 结果框可展开收起，收起用渐隐遮罩而非裁切。
 *   - 分享走**鸿蒙系统分享面板**（`@kit.ShareKit` 的 `systemShare`，与
 *     `LayoutListPage.doShare` 同一条通道），分享后的链接行还可点击拉起浏览器。
 */

import { ThemeColors, DistributionPolicy } from 'commons';
import { AppIconName } from 'commons';
import {
  statGameLog, readGameLogTail, readGameLogFull, formatLogBytes,
  GameLogRead, GameLogStat, GAME_LOG_PREVIEW_BYTES,
} from 'commons';
// 活动账本（L4）：上传正文优先走账本，那里的日志按活动归属分流且已包含本局游戏日志
import { ledgerHas, ledgerRead, ledgerPartBytes, LedgerPart } from 'commons';
import { AppIcon } from './AppIcon';
import { MarkdownView } from './MarkdownView';
import { AiStructuredDiagnosis, parseAiStructuredDiagnosis } from './AiDiagnostic';
import { AiDiagnosticCard } from './AiDiagnosticCard';
// M5.7：AI 流的生命周期归 service，不归本组件
import {
  startAiAnalysis, attachAiObserver, detachAiObserver, cancelAiAnalysis,
  getAiTaskState, getAiTaskText, getAiTaskError, AiTaskState,
} from './AiAnalysisService';
import { ensureNotifyPermission } from './AppNotifier';
import { McSessionInfo } from 'launch';
import {
  revokeShare, isShareRecordCurrent, LogShareRecord, AiStreamHandle,
  logShareInstanceForUrl, logShareSupportsAi, logShareSourceLabel, loadShareRecords,
} from './LogShareClient';
import { common, Want } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { SessionMarker } from 'launch';
import { McDiagnosis, classifyMcError } from 'launch';

import { promptAction } from '@kit.ArkUI';

@Component
export struct McErrorSheet {
  /** 上次会话信息（version / startedAt / mcDir） */
  @Prop session: McSessionInfo = { startedAt: 0, version: '', mcDir: '' }
  /** 错误摘要（SessionMarker.extractErrorSummary 提取） */
  @Prop summary: string = ''
  /** mc_output.log 尾部内容（SessionMarker.readMcLogTail 读取） */
  @Prop logTail: string = ''
  /** 主题色（与父组件同步） */
  @Prop theme: ThemeColors = {} as ThemeColors
  /** 底部安全区高度，避免被 home indicator 遮挡 */
  @Prop bottomSafeHeight: number = 0

  // ---- 会话快照（M3）----
  /**
   * 本次展示的会话主键（= ActivityRecord.startedAt）。0 = 无快照（不回写持久化）。
   * 有了它，Sheet 关掉后用户还能从活动记录点回同一局。
   */
  @Prop sessionKey: number = 0
  /** 该局此前已分享过的结果（重入时带回，用户不必重新分享）。 */
  @Prop initialLsId: string = ''
  @Prop initialLsUrl: string = ''
  @Prop initialLsToken: string = ''
  @Prop initialLsSharedAt: number = 0
  /** 该局此前已保存的 AI 正文（重入时带回，不必再等半分钟）。 */
  @Prop initialAiText: string = ''

  onClose: () => void = () => {}
  /** 分享状态变化：id 为空串表示已撤回。父组件据此持久化回活动记录。 */
  onShareChanged: (id: string, url: string, token: string, sharedAt: number) => void = () => {}
  /** AI 分析完成，父组件据此把正文落盘。 */
  onAiDone: (text: string) => void = () => {}
  /**
   * 主按钮点击 / 步骤点击触发的应用操作。McErrorClassifier.actionKey 透传上来：
   *   - 'open_versions'        → 父组件应关 sheet + 切到 DownloadTab 版本列表
   *   - 'open_jdk_manager'     → 关 sheet + 切到设置 / JDK 管理
   *   - 'open_mod_list'        → 关 sheet + 切到模组管理
   *   - 'open_mod_browse'      → 关 sheet + 切到模组浏览
   *   - 'open_memory_settings' → 关 sheet + 切到设置 / 启动配置
   *   - 'redownload'           → 关 sheet + 触发该 MC 版本的重新下载
   *   - 'copy_log'             → 子组件已自行复制日志，父组件可不响应
   */
  onAction: (actionKey: string) => void = () => {}

  /** 技术详情卡片是否展开 */
  @State private techExpanded: boolean = false

  // ---- 完整日志（M2）----
  /**
   * 技术详情实际展示的日志正文。
   *
   * 不再直接用 `logTail` @Prop —— 那是父组件为了做**分类判定**读的 32 KB 尾部，
   * 拿它当「技术详情」给用户看是口径错位：用户以为看到的是日志，实际只是判定用的
   * 一小段尾巴。首次展开时按 64 KB 重新读，用户点「加载全部」再读全量。
   */
  @State private logText: string = ''
  /** 日志文件总字节数（算「上方还有多少」）。 */
  @State private logTotalBytes: number = 0
  /** 当前 logText 是否已是全量。 */
  @State private logComplete: boolean = false
  /** 已读取的字节数。 */
  @State private logReadBytes: number = 0
  /** 是否正在读全量。 */
  @State private logLoadingFull: boolean = false

  // ---- LogShare 接入（日志系统 v3 · S7）----
  /** 分析状态：idle / running / done / error */


  /** 分享状态：idle / sharing / done / error */
  @State private lsShareState: string = 'idle'
  @State private lsShareUrl: string = ''
  @State private lsShareId: string = ''
  @State private lsShareToken: string = ''
  /** 分享成功的时刻（毫秒）。用于算「还有几天过期」，0 表示未分享。 */
  @State private lsSharedAt: number = 0
  @State private lsRetentionSec: number = 0
  @State private lsError: string = ''
  /** AI 分析：默认关闭，用户主动展开才请求 */
  @State private lsAiExpanded: boolean = false
  @State private lsAiState: string = 'idle'
  @State private lsAiText: string = ''
  @State private lsAiDiagnosis: AiStructuredDiagnosis | undefined = undefined
  @State private revoking: boolean = false
  @State private checkingShare: boolean = false
  private lsAiHandle: AiStreamHandle | null = null

  // ============================================================
  //  生命周期
  // ============================================================

  /**
   * 吃掉父组件带来的会话快照（M3）。
   *
   * 之所以用「@Prop initialXxx → @State lsXxx」这种一次性拷贝而不是直接双向绑定：
   * Sheet 里这些状态在用户操作过程中会频繁变（分享中 / 流式追加），双向绑定会把
   * 中间态一路写回持久化。只在打开时拷一次，结束时通过回调回写一次，干净得多。
   */
  aboutToAppear(): void {
    if (this.initialLsId.length > 0 && logShareInstanceForUrl(this.initialLsUrl).length > 0) {
      this.lsShareId = this.initialLsId
      this.lsShareUrl = this.initialLsUrl
      this.lsShareToken = this.initialLsToken
      this.lsSharedAt = this.initialLsSharedAt
      this.lsShareState = 'done'
      const context = this.uiCtx_()
      if (context !== undefined) loadShareRecords(context).then((records: LogShareRecord[]) => {
        const record = records.find((item: LogShareRecord): boolean => item.id === this.lsShareId && item.url === this.lsShareUrl)
        this.lsRetentionSec = record?.storageTimeSec ?? 0
      }).catch((e: Error): void => { this.lsError = '读取分享记录失败：' + e.message })
    }
    if (this.initialAiText.length > 0) {
      this.lsAiText = this.initialAiText
      this.lsAiDiagnosis = parseAiStructuredDiagnosis(this.initialAiText)
      this.lsAiState = 'done'
      // 带回的结果默认收起：用户是来看错误的，不该被一大段历史 AI 结论顶掉版面
      this.lsAiExpanded = false
    }
    // M5.7：如果 service 里这一局的分析**还在跑**（用户上次关了 Sheet 但流没停），
    // 接上去继续显示进度 —— attach 会把已累积的文本回放一遍。
    if (this.sessionKey > 0) {
      let st = getAiTaskState(this.sessionKey)
      if (st === AiTaskState.RUNNING) {
        this.lsAiState = 'running'
        this.lsAiText = ''
        this.lsAiDiagnosis = undefined
        this.attachAi_()
      } else if (st === AiTaskState.DONE && this.lsAiText.length === 0) {
        this.lsAiText = getAiTaskText(this.sessionKey)
        this.lsAiDiagnosis = parseAiStructuredDiagnosis(this.lsAiText)
        this.lsAiState = 'done'
      } else if (st === AiTaskState.ERROR) {
        this.lsAiState = 'error'
        this.lsError = getAiTaskError(this.sessionKey)
      }
    }
  }

  aboutToDisappear(): void {
    // 只解绑，**不取消流**（M5.7）。用户可能只是想先看别的，关掉就杀流会让他
    // 白等半分钟。流由 AiAnalysisService 持有，跑完会自己落盘 + 发消息告知。
    if (this.sessionKey > 0) detachAiObserver(this.sessionKey)
    if (this.lsAiHandle !== null) { this.lsAiHandle = null }
  }

  // ============================================================
  //  派生数据：诊断结果（每次 build 都重新分类，成本极低）
  // ============================================================

  private getDiagnosis(): McDiagnosis {
    return classifyMcError(this.summary, this.logTail, this.session.version)
  }

  // ============================================================
  //  辅助
  // ============================================================

  private formatTime(ts: number): string {
    if (!ts || ts <= 0) return '未知时间'
    let d = new Date(ts)
    let pad = (n: number): string => (n < 10 ? '0' + n : '' + n)
    let now = new Date()
    let sameDay = d.getFullYear() === now.getFullYear()
      && d.getMonth() === now.getMonth()
      && d.getDate() === now.getDate()
    let prefix = sameDay ? '今天 ' : pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' '
    return prefix + pad(d.getHours()) + ':' + pad(d.getMinutes())
  }

  /** 把 'fabric-loader-0.19.2-26.1' 缩短到 '26.1' */
  private shortVersion(v: string): string {
    if (!v) return '<unknown>'
    let m = v.match(/fabric-loader-[\d.]+-(.+)$/)
    if (m) return 'Minecraft ' + m[1]
    let f = v.match(/^forge-([\d.]+)-/)
    if (f) return 'Minecraft ' + f[1]
    if (v.match(/^[\d.]+$/)) return 'Minecraft ' + v
    return v
  }

  /** 作者提交与公开分享的入口文案始终跟随实际渠道能力。 */
  private uploadBtnLabel(): string {
    return DistributionPolicy.allowPublisherServices() ? '提交给作者' : '公开分享日志'
  }

  // ============================================================
  //  完整日志（M2）
  // ============================================================

  /** 首次展开技术详情时读尾部 64 KB（打开即可见，不卡 UI）。 */
  private loadLogPreview_(): void {
    if (this.logText.length > 0) return
    if (this.loadLedgerGame_(GAME_LOG_PREVIEW_BYTES)) return
    let st: GameLogStat = statGameLog(this.session.mcDir, this.session.version)
    this.logTotalBytes = st.bytes
    let r: GameLogRead = readGameLogTail(this.session.mcDir, this.session.version, GAME_LOG_PREVIEW_BYTES)
    if (r.text.length === 0) {
      // 读不到文件时退回父组件传来的判定尾部，至少让用户有东西可看
      this.logText = this.logTail
      this.logComplete = true
      this.logReadBytes = 0
      return
    }
    this.logText = r.text
    this.logReadBytes = r.readBytes
    this.logComplete = r.complete
    if (this.logTotalBytes <= 0) this.logTotalBytes = r.totalBytes
  }

  /** 「加载全部」——读全量替换。带 16 MB 防御上限，见 readGameLogFull。 */
  private loadLogFull_(): void {
    if (this.logLoadingFull || this.logComplete) return
    this.logLoadingFull = true
    // 读文件是同步 IO，放到微任务里让「加载中…」这一帧能先画出来
    setTimeout(() => {
      if (this.loadLedgerGame_(0)) { this.logLoadingFull = false; return }
      let r: GameLogRead = readGameLogFull(this.session.mcDir, this.session.version)
      if (r.text.length > 0) {
        this.logText = r.text
        this.logReadBytes = r.readBytes
        this.logComplete = r.complete
        this.logTotalBytes = r.totalBytes
      }
      this.logLoadingFull = false
      if (!r.complete) {
        this.toast_('日志超过 16 MB，只显示了尾部')
      }
    }, 16)
  }

  private loadLedgerGame_(maxBytes: number): boolean {
    const context = AppStorage.get<common.UIAbilityContext>('uiAbilityContext')
    const id = this.sessionKey > 0 ? this.sessionKey : this.session.startedAt
    if (context === undefined || !ledgerHas(context.filesDir, id)) return false
    this.logTotalBytes = ledgerPartBytes(context.filesDir, id, LedgerPart.GAME)
    this.logText = ledgerRead(context.filesDir, id, LedgerPart.GAME, maxBytes)
    this.logReadBytes = maxBytes > 0 ? Math.min(maxBytes, this.logTotalBytes) : this.logTotalBytes
    this.logComplete = this.logReadBytes >= this.logTotalBytes
    // 已有账本却没有本局 GAME 时展示缺失，禁止回退到另一次游玩的最新日志。
    if (this.logText.length === 0) this.logText = '该会话的游戏输出尚未生成或已不可用'
    return true
  }

  /** 「上方还有 N，点击加载全部」的提示文案。 */
  private logMoreLabel_(): string {
    if (this.logLoadingFull) return '正在读取完整日志…'
    let rest = this.logTotalBytes - this.logReadBytes
    if (rest <= 0) return ''
    return '上方还有 ' + formatLogBytes(rest) + '，点击加载全部'
  }

  /** 日志体积说明（卡头右侧）。 */
  private logSizeLabel_(): string {
    if (this.logTotalBytes <= 0) return ''
    if (this.logComplete) return '完整 ' + formatLogBytes(this.logTotalBytes)
    return formatLogBytes(this.logReadBytes) + ' / ' + formatLogBytes(this.logTotalBytes)
  }

  private toast_(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 })
    } catch (e) { /* UI 已销毁，忽略 */ }
  }

  /** 仅打开对应目的地的选择/预览页，本按钮不直接发送日志。 */
  private uploadLog(): void {
    this.openShareComposer_(DistributionPolicy.allowPublisherServices() ? 'author' : 'logshare')
  }

  /** 所有入口进入同一个文件选择与脱敏预览页。 */
  private openShareComposer_(destination: string = 'logshare', requestAi: boolean = false): void {
    const params: Record<string, Object> = { 'activityId': this.sessionKey > 0 ? this.sessionKey : this.session.startedAt,
      'destination': destination, 'showShare': true, 'requestAi': requestAi, 'diagnosisTitle': this.shortVersion(this.session.version) }
    this.onClose()
    this.getUIContext().getRouter().pushUrl({ url: 'pages/ActivityLogPage', params: params })
      .catch((error: Error) => { this.toast_('无法打开日志分享：' + error.message) })
  }

  /**
   * 本次诊断是否代表"确实出了故障"。
   *
   * 2026-07-30（日志系统 v3 · S0）：新增 `not_diagnosable` 类别 —— 会话被结束但
   * 日志里找不到可归因错误（用户从后台划掉 / 系统回收进程 / 关闭标记被挤出尾部）。
   * 这不是故障，整个 Sheet 不应该用红色错误样式去吓用户。
   */
  private isFault(): boolean {
    return this.getDiagnosis().category !== 'not_diagnosable'
  }

  // ============================================================
  //  LogShare 接入（日志系统 v3 · S7）
  // ============================================================

  private uiCtx_(): common.UIAbilityContext | undefined {
    return AppStorage.get<common.UIAbilityContext>('uiAbilityContext')
  }

  /** 分享在活动账本中选择文件和预览，错误页不再另组正文。 */
  private async lsShare(): Promise<void> {
    if (this.checkingShare || this.revoking) return
    const context = this.uiCtx_()
    if (context === undefined || this.lsShareId.length === 0) { this.openShareComposer_(); return }
    this.checkingShare = true
    try {
      const records = await loadShareRecords(context)
      const record = records.find((item: LogShareRecord): boolean => item.id === this.lsShareId
        && item.url === this.lsShareUrl && item.accepted !== false && isShareRecordCurrent(item))
      if (record !== undefined) this.lsSystemShare_(record.url)
      else this.openShareComposer_()
    } catch (e) { this.lsError = '读取分享记录失败：' + (e as Error).message }
    finally { this.checkingShare = false }
  }

  /** AI 只使用已有且未过期的 LogShare ID，不能隐式产生一次新上传。 */
  private async lsSubmit_(): Promise<boolean> {
    const context = this.uiCtx_()
    if (context === undefined) return false
    const activityId: number = this.sessionKey > 0 ? this.sessionKey : this.session.startedAt
    const records = await loadShareRecords(context)
    const record = records.find((item: LogShareRecord): boolean => item.activityId === activityId
      && item.accepted !== false && isShareRecordCurrent(item))
    if (record === undefined) {
      this.getUIContext().getPromptAction().showDialog({
        title: '先选择并预览日志',
        message: 'AI 分析需要公开分享链接。下一步先选择文件并检查脱敏预览，确认“公开上传并分析”后才会上传和分析。',
        buttons: [{ text: '取消', color: this.theme.textSecondary as string }, { text: '选择与预览', color: this.theme.primary as string }],
      }).then((result: promptAction.ShowDialogSuccessResponse): void => {
        if (result.index === 1) this.openShareComposer_('logshare', true)
      }).catch((): void => {})
      return false
    }
    this.lsUseShare_(record)
    return true
  }

  private lsUseShare_(record: LogShareRecord): void {
    if (this.lsShareId.length > 0 && this.lsShareId !== record.id) {
      cancelAiAnalysis(this.sessionKey)
      detachAiObserver(this.sessionKey)
      this.lsAiState = 'idle'
      this.lsAiText = ''
      this.lsAiDiagnosis = undefined
      this.lsAiHandle = null
    }
    this.lsShareId = record.id
    this.lsShareUrl = record.url
    this.lsShareToken = record.token
    this.lsSharedAt = record.sharedAt
    this.lsRetentionSec = record.storageTimeSec ?? 0
    this.lsShareState = 'done'
    this.onShareChanged(record.id, record.url, record.token, record.sharedAt)
  }

  /** 「撤回」——删除已分享的日志并清本地记录。 */
  private confirmRevoke_(): void {
    if (this.revoking) return
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '撤回这条在线分享？',
        message: '撤回后链接将无法访问。本地日志不会受影响。',
        buttons: [
          { text: '取消', color: this.theme.primary as string },
          { text: '撤回分享', color: this.theme.error as string },
        ],
      }).then((res: promptAction.ShowDialogSuccessResponse) => {
        if (res.index === 1) this.lsRevoke()
      }).catch(() => { /* 点框外 = 取消 */ })
    } catch (e) { this.lsError = '无法打开确认框：' + (e as Error).message }
  }

  private lsRevoke(): void {
    let ctx = this.uiCtx_()
    if (ctx === undefined || this.lsShareId.length === 0 || this.revoking) return
    this.revoking = true
    let rec: LogShareRecord = {
      id: this.lsShareId, url: this.lsShareUrl, token: this.lsShareToken,
      sharedAt: Date.now(), versionId: this.session.version,
    }
    revokeShare(ctx, rec).then((r) => {
      if (r.ok) {
        this.lsShareState = 'idle'
        this.lsShareUrl = ''
        this.lsShareId = ''
        this.lsShareToken = ''
        this.lsSharedAt = 0
        // 分享撤回后 AI 结果失去来源（服务端按 id 取日志），一并收起复位，
        // 否则用户会看到一段「来自已删除日志」的分析结论。
        // 这里是**真取消**（用户明确删了日志，流继续跑没有意义）。
        cancelAiAnalysis(this.sessionKey)
        this.lsAiHandle = null
        this.lsAiExpanded = false
        this.lsAiState = 'idle'
        this.lsAiText = ''
        this.lsAiDiagnosis = undefined
        // M3：清掉活动记录里的分享信息（空 id 即「已撤回」）
        this.onShareChanged('', '', '', 0)
        this.toast_('已撤回分享')
      } else {
        this.lsError = r.error
        this.toast_('撤回失败：' + r.error)
      }
      this.revoking = false
    }).catch((e: Error) => {
      this.revoking = false
      this.lsError = '撤回失败：' + e.message
      this.toast_(this.lsError)
    })
  }

  /**
   * 「AI 分析」——**默认关闭**，用户主动展开才发起。
   *
   * 实测该 AI 会对健康会话给出错误且危险的建议（详见 LogShareClient.streamAiAnalysis
   * 注释），因此 UI 必须折叠 + 明确标注是第三方推测。需要先分享拿到 id。
   */
  private async lsRunAi(): Promise<void> {
    if (this.checkingShare || this.revoking) return
    // 正在跑：只把结果框拉开让用户看进度，不重复发请求
    if (this.lsAiState === 'running') { this.lsAiExpanded = true; return }
    // 已完成：这个按钮退化成展开/收起
    if (this.lsAiState === 'done') { this.lsAiExpanded = !this.lsAiExpanded; return }

    this.checkingShare = true
    try {
      if (!await this.lsSubmit_()) return
      if (!logShareSupportsAi(this.lsShareUrl)) { this.lsError = '备用分享暂不支持 AI，可重新选择公开分享服务'; return }
      this.lsAiExpanded = true
      const context = this.uiCtx_()
      if (context !== undefined) ensureNotifyPermission(context).catch((): void => {})
      this.lsStartAiStream_()
    } catch (e) { this.lsError = '无法开始分析：' + (e as Error).message }
    finally { this.checkingShare = false }
  }

  /**
   * 发起 AI 分析（前提：lsShareId 已就绪）。
   *
   * 2026-07-30（M5.7）：流的生命周期**不再由本组件持有**。以前是直接
   * `streamAiAnalysis(...)` 把回调写进本组件的 @State —— Sheet 一关就没人接收，
   * 用户白等半分钟。现在交给 `AiAnalysisService`：它幂等地起流、自己落盘、自己
   * 发消息；本组件只是一个可随时 attach / detach 的观察者。
   */
  private lsStartAiStream_(): void {
    if (!logShareSupportsAi(this.lsShareUrl)) {
      this.lsAiState = 'error'
      this.lsError = '日志已通过备用服务分享，但备用服务不支持 AI 分析'
      return
    }
    let ctx = this.uiCtx_()
    if (ctx === undefined) { this.lsAiState = 'error'; this.lsError = '上下文不可用'; return }
    this.lsAiState = 'running'
    this.lsAiText = ''
    this.lsAiDiagnosis = undefined
    this.lsError = ''
    startAiAnalysis(ctx, this.sessionKey, this.lsShareId, this.shortVersion(this.session.version), logShareInstanceForUrl(this.lsShareUrl))
    this.attachAi_()
  }

  /** 订阅 service 的实时增量（attach 时会把已累积文本回放一次）。 */
  private attachAi_(): void {
    if (this.sessionKey <= 0) return
    attachAiObserver(this.sessionKey, {
      onDelta: (t: string) => { this.lsAiText += t },
      onDone: (full: string) => {
        this.lsAiText = full.length > 0 ? full : '(AI 未返回内容)'
        this.lsAiDiagnosis = parseAiStructuredDiagnosis(this.lsAiText)
        this.lsAiState = 'done'
      },
      onError: (msg: string) => {
        this.lsAiState = 'error'
        this.lsError = msg
      },
    })
  }

  /**
   * AI 结果框展开 / 收起 —— **纯视觉**，不碰正在跑的流。
   *
   * 旧实现把「收起」当成「取消分析」，用户想少占点版面就把等了半分钟的
   * 结果弄没了。现在收起只是折叠显示。
   */
  private lsToggleAiBox(): void {
    this.lsAiExpanded = !this.lsAiExpanded
  }

  /**
   * 收起态的预览文案：露出开头一段，配合底部渐隐暗示还有内容。
   *
   * 预览是纯 Text（渐隐遮罩要压在文字上，用 MarkdownView 会让遮罩盖不准），
   * 所以这里先把 Markdown 标记抹掉 —— 否则用户在收起态看到的是一堆
   * `###`、`**`、反引号。
   */
  private lsAiPreview(): string {
    let t = this.lsAiText
    if (t.length === 0) return ''
    let head = t.length > 400 ? t.slice(0, 400) : t
    let plain = head
      .replace(/```[\s\S]*?(```|$)/g, ' ')     // 代码块整段去掉
      .replace(/^\s{0,3}#{1,6}\s+/gm, '')       // 标题标记
      .replace(/^\s{0,3}([-*+]|\d{1,3}\.)\s+/gm, '')  // 列表标记
      .replace(/^\s{0,3}(-{3,}|\*{3,}|_{3,})\s*$/gm, '')  // 分隔线
      .replace(/\*\*/g, '')                     // 加粗标记
      .replace(/`/g, '')                        // 行内码反引号
      .replace(/\n{2,}/g, '\n')
      .trim()
    return plain.length > 180 ? plain.slice(0, 180) : plain
  }

  private async copyText_(text: string, tip: string): Promise<void> {
    if (text.length === 0) return
    try {
      let data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text)
      await pasteboard.getSystemPasteboard().setData(data)
      this.toast_(tip)
    } catch (e) { this.toast_('复制失败：' + (e as Error).message) }
  }

  /**
   * 调起**鸿蒙系统分享面板**分享日志链接。
   *
   * 用 `general.hyperlink` + `content` 直接分享 URL 文本，不需要像
   * `LayoutListPage.doShare` 那样先往 cacheDir 落一个文件再按 uri 分享 ——
   * 我们分享的是一个公开链接而不是本地文件。
   *
   * 失败时降级到「复制链接」，不把用户卡住。
   */
  private lsSystemShare_(url: string): void {
    if (url.length === 0) return
    let ctx = this.uiCtx_()
    if (ctx === undefined) { this.copyText_(url, '链接已复制'); return }
    let d = this.getDiagnosis()
    let record: systemShare.SharedRecord = {
      utd: utd.UniformDataType.HYPERLINK,
      content: url,
      title: 'AMCL 崩溃日志 · ' + this.shortVersion(this.session.version),
      description: d.title,
      label: 'AMCL 崩溃日志',
    }
    try {
      let controller = new systemShare.ShareController(new systemShare.SharedData(record))
      controller.show(ctx, {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DETAIL,
      }).catch((e: Error) => {
        hilog.error(0x0000, 'McErrorSheet', 'systemShare show failed: %{public}s', e.message)
        this.copyText_(url, '分享面板打不开，已复制链接')
      })
    } catch (e) {
      hilog.error(0x0000, 'McErrorSheet', 'systemShare init failed: %{public}s', (e as Error).message)
      this.copyText_(url, '分享面板不可用，已复制链接')
    }
  }

  /** 用系统浏览器打开链接（链接行点击用）。 */
  private async openInBrowser_(url: string): Promise<void> {
    if (url.length === 0) return
    let ctx = this.uiCtx_()
    if (ctx === undefined) { this.toast_('无法打开浏览器，已复制链接'); this.copyText_(url, '链接已复制'); return }
    let want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: url,
    }
    // startAbility 在 ArkTS 严格模式下报 'Function may throw'，必须包 try-catch。
    try {
      await ctx.startAbility(want)
    } catch (e) {
      hilog.error(0x0000, 'McErrorSheet', 'openInBrowser failed: %{public}s', (e as Error).message)
      this.toast_('没有可用的浏览器，已复制链接')
      this.copyText_(url, '链接已复制')
    }
  }

  /** 分享按钮主文案。 */
  private lsShareBtnLabel(): string {
    if (this.lsShareState === 'sharing') return '生成链接中…'
    if (this.lsShareState === 'done') return '再次分享'
    if (this.lsShareState === 'error') return '重试分享'
    return '分享日志'
  }

  /** 分享按钮副文案（说明这一下点下去会发生什么）。 */
  private lsShareBtnHint(): string {
    if (this.lsShareState === 'sharing') return '正在上传并生成公开链接'
    if (this.lsShareState === 'done') return '调起系统分享面板'
    if (this.lsShareState === 'error') return this.lsError.length > 0 ? this.lsError : '上次生成失败'
    return '官方优先，连接失败时使用备用服务'
  }

  /** 剩余有效期文案（由 sharedAt 与本次分享记录的 storageTimeSec 算出）。 */
  private lsExpiryLabel(): string {
    if (this.lsSharedAt <= 0) return ''
    if (this.lsRetentionSec <= 0) return logShareSourceLabel(this.lsShareUrl) + ' · 有效期以分享页为准'
    let dayMs = 24 * 60 * 60 * 1000
    let left = Math.ceil((this.lsSharedAt + this.lsRetentionSec * 1000 - Date.now()) / dayMs)
    if (left <= 0) return '已过期'
    if (left === 1) return '1 天后过期'
    return left + ' 天后过期'
  }


  /** AI 按钮文案。 */
  private lsAiBtnLabel(): string {
    if (this.lsAiState === 'running') return 'AI 分析中…'
    if (this.lsAiState === 'done') return 'AI 已完成'
    if (this.lsAiState === 'error') return 'AI 重试'
    return 'AI 智能分析'
  }

  /** 判定颜色：根据 category 选用 hero 区的色调 */
  private heroIconColor(): ResourceColor {
    return this.isFault() ? this.theme.error : this.theme.textSecondary
  }
  private heroIconBg(): ResourceColor {
    // 故障用比 errorBg 更深一些的浅红突出图标；非故障用中性底色
    return this.isFault() ? '#F9D9DA' : this.theme.bgInput
  }
  private heroIconName(d: McDiagnosis): AppIconName {
    if (d.category === 'not_diagnosable') return AppIconName.Info
    if (d.category === 'jdk_version' || d.category === 'jdk_runtime') return AppIconName.Java
    if (d.category === 'oom') return AppIconName.Memory
    if (d.category === 'mod_conflict') return AppIconName.Mod
    if (d.category === 'mixin_apply') return AppIconName.Mod
    if (d.category === 'missing_file') return AppIconName.Folder
    if (d.category === 'native_crash') return AppIconName.Error
    if (d.category === 'lwjgl_version' || d.category === 'lwjgl_module_missing') return AppIconName.Error
    if (d.category === 'launch_arg') return AppIconName.Settings
    return AppIconName.Warning
  }

  // ============================================================
  //  主 build —— 直接拉一个外层 Scroll 把所有 section 套住
  // ============================================================

  build() {
    Column() {
      // Header
      this.HeaderRow_()

      // Scroll body
      Scroll() {
        Column({ space: 14 }) {
          this.HeroCard_()
          this.ReasonCard_()
          this.LogShareCard_()
          this.TechDetailsCard_()
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 16 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)

      // Action bar
      this.ActionBar_()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.bgPrimary)
  }

  // ============================================================
  //  Section: Header
  // ============================================================

  @Builder
  HeaderRow_() {
    Row({ space: 10 }) {
      // 左侧标识图标（不可点）
      Stack() {
        AppIcon({ name: AppIconName.Error, iconSize: 18, color: this.theme.error })
      }
      .width(40).height(40)
      .borderRadius(20)
      .backgroundColor(this.theme.errorBg)

      // 中间双行标题
      Column({ space: 1 }) {
        Text(this.isFault() ? '上次游戏异常退出' : '上次游戏已结束')
          .fontSize(11)
          .fontWeight(500)
          .fontColor(this.theme.error)
          .maxLines(1)
        Text(this.shortVersion(this.session.version))
          .fontSize(18)
          .fontWeight(700)
          .fontColor(this.theme.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 右侧关闭按钮
      Stack() {
        AppIcon({ name: AppIconName.Close, iconSize: 18, color: this.theme.textSecondary })
      }
      .width(40).height(40)
      .borderRadius(20)
      .backgroundColor(this.theme.bgCard)
      .onClick(() => { this.onClose() })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 10 })
    .alignItems(VerticalAlign.Center)
  }

  // ============================================================
  //  Section: Hero Card（红底 ⚠ + 标题 + 元信息）
  // ============================================================

  @Builder
  HeroCard_() {
    Column({ space: 12 }) {
      // 大圆图标
      Stack() {
        AppIcon({
          name: this.heroIconName(this.getDiagnosis()),
          iconSize: 44,
          color: this.heroIconColor(),
        })
      }
      .width(88).height(88)
      .borderRadius(44)
      .backgroundColor(this.heroIconBg())

      // 主标题
      Text(this.getDiagnosis().title)
        .fontSize(18)
        .fontWeight(700)
        .fontColor(this.heroIconColor())
        .textAlign(TextAlign.Center)

      // 元信息
      Row({ space: 8 }) {
        Row() {
          Text(this.session.version || '<unknown>')
            .fontSize(11)
            .fontFamily('HarmonyHeiTi-Mono, monospace')
            .fontWeight(600)
            .fontColor(this.theme.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        .borderRadius(10)
        .backgroundColor(this.theme.bgInput)
        .constraintSize({ maxWidth: 230 })

        Text('·')
          .fontSize(13)
          .fontWeight(600)
          .fontColor(this.theme.textHint)

        Text(this.formatTime(this.session.startedAt))
          .fontSize(11)
          .fontWeight(500)
          .fontColor(this.theme.textHint)
      }
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 24, bottom: 22 })
    .backgroundColor(this.isFault() ? this.theme.errorBg : this.theme.bgCard)
    .borderRadius(20)
    .alignItems(HorizontalAlign.Center)
  }

  // ============================================================
  //  Section: 为什么会出错？
  // ============================================================

  @Builder
  ReasonCard_() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        AppIcon({ name: AppIconName.Info, iconSize: 18, color: this.theme.warning })
        Text('为什么会出错？')
          .fontSize(14)
          .fontWeight(700)
          .fontColor(this.theme.textPrimary)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(this.getDiagnosis().description)
        .fontSize(13)
        .fontColor(this.theme.textSecondary)
        .lineHeight(20)
        .width('100%')
        .textAlign(TextAlign.Start)

      // 技术原因 chip（蓝底）
      Row({ space: 8 }) {
        Text('技术原因：')
          .fontSize(11)
          .fontWeight(600)
          .fontColor(this.theme.primary)
        Text(this.getDiagnosis().techDetail)
          .fontSize(10)
          .fontFamily('HarmonyHeiTi-Mono, monospace')
          .fontWeight(500)
          .fontColor(this.theme.textSecondary)
          .layoutWeight(1)
          .maxLines(2)
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
      .borderRadius(8)
      .backgroundColor(this.theme.primaryLight)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.theme.bgCard)
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
  }

  // ============================================================
  //  Section: 日志分析与分享（LogShare）
  // ============================================================

  /**
   * 「日志分析与分享」卡（M0 重绘，2026-07-30）。
   *
   * 这张卡取代了原来的「建议的解决办法」占位 —— 静态硬编码建议的天花板太低（详见
   * docs/guides/message-center-and-diagnosis-ux.md §2.5.1），版面让给基于完整日志
   * 的真实分析。
   *
   * 分享统一进入活动账本预览；AI 只读取已有分享 ID。
   */
  @Builder
  LogShareCard_() {
    Column({ space: 12 }) {
      // ---- 卡头 ----
      Row({ space: 8 }) {
        AppIcon({ name: AppIconName.Search, iconSize: 18, color: this.theme.primary })
        Text('日志分享与分析')
          .fontSize(14).fontWeight(700).fontColor(this.theme.textPrimary).layoutWeight(1)
        Row() {
          Text(this.lsShareUrl.length > 0 ? logShareSourceLabel(this.lsShareUrl) : 'LogShare 官方优先')
            .fontSize(10).fontWeight(600).fontColor(this.theme.textHint)
        }
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .borderRadius(6).backgroundColor(this.theme.bgInput)
      }
      .width('100%').alignItems(VerticalAlign.Center)

      // 分享目标和 AI 的触发条件。
      Text('下一步会先选择文件并生成脱敏预览，再由你确认外发。当前规则会尝试移除玩家名、UUID、令牌、服务器地址与聊天内容；请以预览为准。'
        + '公开分享优先使用 LogShare 官方，故障时使用 AMCL 备用服务。AI 分析仅在你主动点击时调用官方服务，备用分享不支持 AI。')
        .fontSize(11).lineHeight(17).fontColor(this.theme.textSecondary).width('100%')

      if (this.lsShareUrl.length === 0 || logShareSupportsAi(this.lsShareUrl)) {
        Button(this.checkingShare ? '正在核对分享…' : this.lsAiBtnLabel()).height(44).width('100%')
          .enabled(!this.checkingShare && !this.revoking)
          .onClick(() => { this.lsRunAi() })
      } else {
        Text('当前为备用分享，可正常查看和撤回；暂不支持 AI 分析。')
          .fontSize(11).fontColor(this.theme.textHint)
      }

      // ---- 分享按钮（全宽 46px，双行：主文案 + 副文案）----
      Column({ space: 1 }) {
        Row({ space: 6 }) {
          AppIcon({
            name: AppIconName.Share,
            iconSize: 15,
            color: this.lsShareState === 'error' ? this.theme.error : this.theme.textPrimary,
          })
          Text(this.lsShareBtnLabel())
            .fontSize(14).fontWeight(600)
            .fontColor(this.lsShareState === 'error' ? this.theme.error : this.theme.textPrimary)
            .maxLines(1)
        }
        .alignItems(VerticalAlign.Center)

        Text(this.lsShareBtnHint())
          .fontSize(10).fontColor(this.theme.textHint).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%').height(46).borderRadius(12)
      .backgroundColor(this.lsShareState === 'done' ? this.theme.primaryLight : this.theme.bgInput)
      .enabled(!this.checkingShare && !this.revoking)
      .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      .onClick(() => { this.lsShare() })

      // ---- 分享后的链接行：可跳转 / 可复制 / 可撤回 / 显示剩余有效期 ----
      if (this.lsShareState === 'done' && this.lsShareUrl.length > 0) {
        Column({ space: 6 }) {
          Row({ space: 8 }) {
            // 链接本体：点击拉起浏览器
            Column({ space: 2 }) {
              Text(this.lsShareUrl)
                .fontSize(11).fontWeight(600).fontColor(this.theme.primary)
                .fontFamily('HarmonyHeiTi-Mono, monospace')
                .decoration({ type: TextDecorationType.Underline, color: this.theme.primary })
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(this.lsExpiryLabel())
                .fontSize(10).fontColor(this.theme.textHint)
            }
            .layoutWeight(1).alignItems(HorizontalAlign.Start)
            .onClick(() => { this.openInBrowser_(this.lsShareUrl) })

            // 复制
            Stack() {
              AppIcon({ name: AppIconName.Copy, iconSize: 15, color: this.theme.textSecondary })
            }
            .width(44).height(44).borderRadius(8).backgroundColor(this.theme.bgCard)
            .accessibilityText('复制分享链接')
            .onClick(() => { this.copyText_(this.lsShareUrl, '链接已复制') })

            // 撤回（常驻，红色）
            Stack() {
              if (this.revoking) LoadingProgress().width(20).height(20).color(this.theme.primary)
              else AppIcon({ name: AppIconName.Trash, iconSize: 15, color: this.theme.error })
            }
            .width(44).height(44).borderRadius(8).backgroundColor(this.theme.bgCard)
            .enabled(!this.revoking)
            .accessibilityText(this.revoking ? '正在撤回分享' : '撤回在线分享')
            .onClick(() => { this.confirmRevoke_() })
          }
          .width('100%').alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .padding(10).borderRadius(10).backgroundColor(this.theme.bgInput)
        .alignItems(HorizontalAlign.Start)
      }

      if (this.lsAiState !== 'idle' && logShareSupportsAi(this.lsShareUrl)) {
        this.AiResultBox_()
      }
      // 分享和分析错误均保留可见提示。
      if (this.lsError.length > 0) {
        Row({ space: 6 }) {
          AppIcon({ name: AppIconName.Warning, iconSize: 13, color: this.theme.error })
          Text(this.lsError)
            .fontSize(11).fontColor(this.theme.error).layoutWeight(1)
        }
        .width('100%').alignItems(VerticalAlign.Top)
      }
    }
    .width('100%')
    .padding(16)
    .borderRadius(14)
    .backgroundColor(this.theme.bgCard)
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * AI 结果框。
   *
   * 收起态露出开头一段 + 底部渐隐遮罩暗示还有内容；**不用裁切**（裁切会把最后一行
   * 切成半截字）。「仅供参考」chip 常驻在头部，收起状态下也能看到免责提示。
   */
  @Builder
  AiResultBox_() {
    Column({ space: 8 }) {
      // 头部：标题 + 仅供参考 chip + 展开/收起
      Row({ space: 6 }) {
        AppIcon({ name: AppIconName.Ai, iconSize: 14, color: this.theme.primary })
        Text('AI 分析结果')
          .fontSize(12).fontWeight(600).fontColor(this.theme.textPrimary)
        Row() {
          Text('仅供参考')
            .fontSize(10).fontWeight(600).fontColor(this.theme.warning)
        }
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .borderRadius(5).backgroundColor(this.theme.warningBg)

        Blank()

        if (this.lsAiText.length > 0) {
          Row({ space: 3 }) {
            Text(this.lsAiExpanded ? '收起' : '展开')
              .fontSize(11).fontWeight(500).fontColor(this.theme.primary)
            AppIcon({
              name: this.lsAiExpanded ? AppIconName.ChevronUp : AppIconName.ChevronDown,
              iconSize: 12, color: this.theme.primary,
            })
          }
          .alignItems(VerticalAlign.Center)
          .onClick(() => { this.lsToggleAiBox() })
        }
      }
      .width('100%').alignItems(VerticalAlign.Center)

      // 正文
      if (this.lsAiState === 'error') {
        Text(this.lsError.length > 0 ? this.lsError : 'AI 分析失败')
          .fontSize(11).fontColor(this.theme.error).width('100%')
      } else if (this.lsAiText.length === 0) {
        // running 且还没有首个 delta
        Text('正在分析，通常需要半分钟。可以先关掉这个页面，稍后回来看。')
          .fontSize(11).lineHeight(17).fontColor(this.theme.textSecondary).width('100%')
      } else if (this.lsAiExpanded) {
        if (this.lsAiDiagnosis !== undefined) {
          AiDiagnosticCard({ diagnosis: this.lsAiDiagnosis, theme: this.theme })
        }
        // 展开态：Markdown 渲染（AI 输出实测含标题/列表/代码块/加粗/行内码）
        MarkdownView({
          content: this.lsAiText,
          theme: this.theme,
          baseFontSize: 12,
          maxCodeLines: 12,
        })
      } else {
        // 收起态：预览 + 底部渐隐遮罩
        Stack({ alignContent: Alignment.Bottom }) {
          Text(this.lsAiPreview())
            .fontSize(12).lineHeight(19).fontColor(this.theme.textSecondary)
            .width('100%').textAlign(TextAlign.Start)
          Column()
            .width('100%').height(26)
            .linearGradient({
              angle: 180,
              colors: [[Color.Transparent, 0.0], [this.theme.bgInput, 1.0]],
            })
        }
        .width('100%')
      }

      // 免责说明（常驻，收起也看得到）
      Text('由第三方 AI 生成，未针对 HarmonyOS 校准。它可能把正常会话误判为故障，'
        + '也可能给出删文件、跑包管理器命令等在本平台无意义的建议 —— 请只当参考。')
        .fontSize(10).lineHeight(15).fontColor(this.theme.textHint).width('100%')
    }
    .width('100%')
    .padding(12).borderRadius(10).backgroundColor(this.theme.bgInput)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  TechDetailsCard_() {
    Column({ space: 12 }) {
      // Header（可点开）
      Row({ space: 8 }) {
        AppIcon({
          name: this.techExpanded ? AppIconName.ChevronUp : AppIconName.ChevronDown,
          iconSize: 16,
          color: this.theme.textSecondary,
        })
        Column({ space: 1 }) {
          Text(this.techExpanded ? '技术详情（开发者）' : '技术详情（点击展开）')
            .fontSize(13)
            .fontWeight(600)
            .fontColor(this.theme.textPrimary)
          if (this.techExpanded && this.logSizeLabel_().length > 0) {
            Text(this.logSizeLabel_())
              .fontSize(10)
              .fontColor(this.theme.textHint)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 上传日志 mini 按钮（状态化）
        Row({ space: 5 }) {
          AppIcon({ name: AppIconName.Upload, iconSize: 11, color: this.theme.primary })
          Text(this.uploadBtnLabel())
            .fontSize(11)
            .fontWeight(500)
            .fontColor(this.theme.primary)
        }
        .padding({ left: 9, right: 9, top: 5, bottom: 5 })
        .borderRadius(8)
        .backgroundColor(this.theme.primaryLight)
        .alignItems(VerticalAlign.Center)
        .onClick(() => { this.uploadLog() })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.techExpanded = !this.techExpanded
        // 首次展开才真正读文件，关掉再开不重复读
        if (this.techExpanded) this.loadLogPreview_()
      })

      if (this.techExpanded) {
        // 错误类型 chip
        Row({ space: 8 }) {
          Text('错误类型')
            .fontSize(11)
            .fontWeight(500)
            .fontColor(this.theme.textHint)
          Row() {
            Text(this.getDiagnosis().errorKind)
              .fontSize(10)
              .fontFamily('HarmonyHeiTi-Mono, monospace')
              .fontWeight(600)
              .fontColor(this.theme.error)
          }
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(6)
          .backgroundColor(this.theme.errorBg)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // 「上方还有 N，点击加载全部」（M2：展示不设人为上限，读取按需分页）
        if (!this.logComplete && this.logMoreLabel_().length > 0) {
          Row({ space: 6 }) {
            AppIcon({
              name: this.logLoadingFull ? AppIconName.Hourglass : AppIconName.ArrowDown,
              iconSize: 12,
              color: this.theme.primary,
            })
            Text(this.logMoreLabel_())
              .fontSize(11).fontWeight(500).fontColor(this.theme.primary).layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 10, right: 10, top: 7, bottom: 7 })
          .borderRadius(8)
          .backgroundColor(this.theme.primaryLight)
          .alignItems(VerticalAlign.Center)
          .onClick(() => { this.loadLogFull_() })
        }

        // log box（暗底等宽）
        Column() {
          Scroll() {
            Text(this.logText.length > 0
              ? this.logText
              : '(无日志内容 — 可能是 mc_output.log 已被清理)')
              .fontSize(10)
              .fontFamily('HarmonyHeiTi-Mono, monospace')
              .lineHeight(15)
              .fontColor('#A0AEC0')
              .width('100%')
              .textAlign(TextAlign.Start)
              .padding(12)
              .copyOption(CopyOptions.None)
          }
          .scrollBar(BarState.Auto)
          .width('100%')
          .constraintSize({ maxHeight: 320 })
        }
        .width('100%')
        .borderRadius(8)
        .backgroundColor('#0F1115')
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: this.techExpanded ? 16 : 14 })
    .backgroundColor(this.theme.bgCard)
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
  }

  // ============================================================
  //  Section: Action Bar（粘底）
  // ============================================================

  @Builder
  ActionBar_() {
    Row({ space: 10 }) {
      // 主按钮（大宽）
      Row({ space: 8 }) {
        Text(this.getDiagnosis().primaryActionKey === 'copy_log' ? this.uploadBtnLabel() : this.getDiagnosis().primaryActionLabel)
          .fontSize(15)
          .fontWeight(600)
          .fontColor(this.theme.textOnPrimary)
        Text('→')
          .fontSize(16)
          .fontWeight(700)
          .fontColor(this.theme.textOnPrimary)
      }
      .layoutWeight(1)
      .height(48)
      .borderRadius(24)
      .backgroundColor(this.theme.primary)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        let key = this.getDiagnosis().primaryActionKey
        if (key === 'copy_log') {
          this.uploadLog()
        } else if (key) {
          this.onAction(key)
        } else {
          this.onClose()
        }
      })

      // 上传日志（圆形）
      Stack() {
        AppIcon({
          name: AppIconName.Upload,
          iconSize: 18,
          color: this.theme.textSecondary,
        })
      }
      .width(48).height(48)
      .borderRadius(24)
      .backgroundColor(this.theme.bgCard)
      .accessibilityText(this.uploadBtnLabel())
      .onClick(() => { this.uploadLog() })

      // 关闭（圆形）
      Stack() {
        AppIcon({ name: AppIconName.Close, iconSize: 18, color: this.theme.textSecondary })
      }
      .width(48).height(48)
      .borderRadius(24)
      .backgroundColor(this.theme.bgCard)
      .onClick(() => { this.onClose() })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: Math.max(16, this.bottomSafeHeight) })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.theme.bgPrimary)
  }
}
