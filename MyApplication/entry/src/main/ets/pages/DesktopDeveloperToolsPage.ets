import { pasteboard, deviceInfo } from '@kit.BasicServicesKit'
import { ThemeColors, ThemeMode, resolveTheme, ledgerBegin, ledgerEnd, LedgerState,
  ledgerDirOf, ensureDirSync, writeEvidenceTextAtomic, listSessionEvidence, setEvidenceSelection } from 'commons'
import testNapi, { NativeGlCapability } from 'libentry.so'
import { common } from '@kit.AbilityKit'
import { ProductRenderDiagnostics } from 'entry/ProductRenderDiagnostics'
import { graphicsProfileById, GraphicsProfileSpec } from 'launch'
import { loadShareRecords, revokeShare,
  LogShareRecord } from '../components/LogShareClient'

@Entry
@Component
struct DesktopDeveloperToolsPage {
  @State theme: ThemeColors = resolveTheme(ThemeMode.SYSTEM, false)
  @State busy: boolean = false
  @State result: string = '无需安装 Minecraft。点击下方按钮，验证系统桌面 OpenGL，并复制完整结果反馈。'
  @State verdict: string = '尚未验证'
  @State savedLabel: string = ''
  @State saveError: string = ''
  @State sharing: boolean = false
  @State shareStatus: string = ''
  @State diagnosticShares: LogShareRecord[] = []
  private pendingShare: LogShareRecord | undefined = undefined

  aboutToAppear(): void {
    if (!ProductRenderDiagnostics.enabled) {
      this.verdict = '此诊断仅供电脑包使用'
      return
    }
    this.restoreSaved(true)
    if (this.savedLabel.length === 0) this.result += '\n\n' + this.desktopProfileSummary()
    this.refreshShares()
  }

  private context(): common.UIAbilityContext | undefined {
    return AppStorage.get<common.UIAbilityContext>('uiAbilityContext')
  }

  private desktopProfileSummary(): string {
    const profile: GraphicsProfileSpec | undefined = graphicsProfileById('nativegl')
    if (profile === undefined) return 'profile=nativegl (registry metadata unavailable)'
    return 'profile=' + profile.id + ' api=' + profile.api + ' provider=' + profile.windowProviders.join('/')
      + ' transport=' + profile.transport + ' capability=' + profile.capabilityKind
      + ' lifecycle=' + profile.lifecycle + ' admission=' + profile.admission
      + ' fallback=platform-default requirement=' + profile.requirementId
  }

  private restoreSaved(restoreText: boolean = false): void {
    const context = this.context()
    if (context === undefined) return
    const diagnostic = ProductRenderDiagnostics.read(context.filesDir)
    if (diagnostic !== undefined) {
      this.savedLabel = (diagnostic.detailed ? '完整渲染诊断' : '基础能力验证')
        + ' · ' + new Date(diagnostic.capturedAt).toLocaleString()
      if (restoreText) {
        this.result = diagnostic.text
        this.verdict = '已载入保存的诊断结果'
      }
    }
  }

  private async refreshShares(): Promise<void> {
    if (!ProductRenderDiagnostics.enabled) return
    const context = this.context()
    if (context === undefined) return
    const records = await loadShareRecords(context)
    this.diagnosticShares = records.filter((record: LogShareRecord): boolean =>
      record.versionId === ProductRenderDiagnostics.shareCategory)
  }

  private async verify(detailed: boolean = false): Promise<void> {
    if (!ProductRenderDiagnostics.enabled || this.busy || this.sharing) return
    this.busy = true
    this.saveError = ''
    this.verdict = '正在验证系统 OpenGL…'
    try {
      const capability: NativeGlCapability = await testNapi.getNativeGlCapability(detailed)
      this.verdict = capability.ready
        ? (detailed ? '渲染诊断已完成，请复制完整结果反馈' : 'PASS · 系统桌面 OpenGL 验证通过')
        : 'FAIL · ' + capability.stage
      this.result = 'AMCL_DESKTOP_OPENGL_PROBE_V1\n'
        + this.desktopProfileSummary() + '\n'
        + 'time=' + new Date().toISOString() + '\n'
        + 'deviceType=' + deviceInfo.deviceType + '\n'
        + 'sdkApi=' + deviceInfo.sdkApiVersion + '\n'
        + JSON.stringify(capability, null, 2)
      if (detailed && capability.renderDiagnostics.length > 0) {
        this.result += '\n\n' + capability.renderDiagnostics
      }
    } catch (error) {
      this.verdict = 'ERROR · 探针未完成'
      this.result = 'AMCL_DESKTOP_OPENGL_PROBE_V1\n' + ((error as Error).stack ?? (error as Error).message)
    }
    try {
      const context = this.context()
      if (context === undefined) throw new Error('诊断日志上下文不可用')
      ProductRenderDiagnostics.save(context.filesDir, this.result, detailed)
      this.restoreSaved()
    } catch (error) {
      this.saveError = '保存失败，请复制完整结果：' + (error as Error).message
    } finally { this.busy = false }
  }

  private async shareResult(): Promise<void> {
    if (!ProductRenderDiagnostics.enabled || this.sharing || this.busy) return
    try {
      const context = this.context()
      if (context === undefined) throw new Error('分享上下文不可用')
      const diagnostic = ProductRenderDiagnostics.read(context.filesDir)
      if (diagnostic === undefined) throw new Error('请先运行并保存电脑渲染诊断')
      const activityId: number = diagnostic.capturedAt
      ledgerBegin(context.filesDir, activityId, { category: 'render-diagnostic', title: '电脑渲染诊断' })
      const directory: string = ledgerDirOf(context.filesDir, activityId) + '/render/probes'
      ensureDirSync(directory)
      writeEvidenceTextAtomic(directory + '/desktop.json', diagnostic.text)
      ledgerEnd(context.filesDir, activityId, { state: LedgerState.SUCCESS, source: 'desktop.diagnostic', summary: '电脑渲染诊断已保存' })
      const files = listSessionEvidence(context.filesDir, activityId)
      // 用户此处主动选择分享渲染诊断；仍在统一页面预览并最终确认。
      setEvidenceSelection(context.filesDir, activityId, files.map((file): string => file.fileId))
      const params: Record<string, Object> = { 'activityId': activityId, 'showShare': true }
      await this.getUIContext().getRouter().pushUrl({ url: 'pages/ActivityLogPage', params: params })
    } catch (error) { this.shareStatus = '分享未完成：' + (error as Error).message }
  }

  private async copyShareUrl(url: string): Promise<void> {
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url))
      this.shareStatus = '诊断分享链接已复制'
    } catch (error) {
      this.shareStatus = '链接已保留，复制失败：' + (error as Error).message
    }
  }

  private async revokeDiagnostic(record: LogShareRecord): Promise<void> {
    if (this.sharing) return
    const context = this.context()
    if (context === undefined) return
    this.sharing = true
    try {
      const result = await revokeShare(context, record)
      if (!result.ok) throw new Error(result.error)
      await this.refreshShares()
      this.shareStatus = '诊断分享已撤回'
    } catch (error) {
      this.shareStatus = '撤回失败：' + (error as Error).message
    } finally { this.sharing = false }
  }

  private shareLabel(record: LogShareRecord): string {
    const seconds: number = record.storageTimeSec ?? 0
    return new Date(record.sharedAt).toLocaleString()
      + (seconds > 0 ? ' · 保留约 ' + Math.ceil(seconds / 86400) + ' 天' : ' · 保留期以分享页为准')
  }
  private async copyResult(): Promise<void> {
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.result))
      this.getUIContext().getPromptAction().showToast({ message: '完整结果已复制' })
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: '复制失败：' + (error as Error).message })
    }
  }
  build() {
    Column({ space: 12 }) {
      Row({ space: 18 }) {
        Button('返回').onClick(() => { this.getUIContext().getRouter().back() })
        Text('开发者工具 · 电脑').fontSize(24).fontWeight(FontWeight.Bold)
      }.width('100%')
      Text('系统桌面 OpenGL').fontSize(20).fontWeight(FontWeight.Medium).width('100%')
      Text('检查系统能力、OpenGL 4.2 Core 上下文和实际像素读回，记录电脑原生渲染环境。')
        .fontSize(15).width('100%')
      Row({ space: 12 }) {
        Button(this.busy ? '验证中…' : '验证桌面 OpenGL').enabled(ProductRenderDiagnostics.enabled && !this.busy && !this.sharing)
          .onClick(() => { this.verify() })
        Button('复制完整结果').enabled(!this.busy).onClick(() => { this.copyResult() })
      }.width('100%')
      Row({ space: 12 }) {
        Button('运行渲染诊断').enabled(ProductRenderDiagnostics.enabled && !this.busy && !this.sharing)
          .onClick(() => { this.verify(true) })
        if (ProductRenderDiagnostics.enabled) {
          Button('分享已保存诊断').enabled(!this.busy && !this.sharing && this.savedLabel.length > 0)
            .onClick(() => { this.shareResult() })
        }
      }.width('100%')
      Text('画面出现黑面、缺块时运行。检查着色器、纹理、顶点与缓冲区更新；结果不等同于游戏画面验收。')
        .fontSize(14).width('100%')
      Text(this.verdict).fontSize(18).fontWeight(FontWeight.Medium).width('100%')
      if (ProductRenderDiagnostics.enabled) {
        Text(this.savedLabel).fontSize(12).width('100%')
        Text('诊断会保存并随电脑游戏日志分享；单独分享会上传脱敏后的完整输出，保留期以分享页为准，可撤回。')
          .fontSize(12).width('100%')
        if (this.saveError.length > 0) { Text(this.saveError).fontSize(12).width('100%') }
        if (this.shareStatus.length > 0) { Text(this.shareStatus).fontSize(12).width('100%') }
        if (this.diagnosticShares.length > 0) {
          Scroll() {
            Column({ space: 6 }) {
              ForEach(this.diagnosticShares, (record: LogShareRecord) => {
                Row({ space: 8 }) {
                  Text(this.shareLabel(record)).fontSize(12).maxLines(2).layoutWeight(1)
                  Button('复制链接').enabled(!this.sharing).onClick(() => { this.copyShareUrl(record.url) })
                  Button('撤回').enabled(!this.sharing).onClick(() => { this.revokeDiagnostic(record) })
                }.width('100%')
              }, (record: LogShareRecord): string => record.url)
            }.width('100%')
          }.height(Math.min(this.diagnosticShares.length * 48, 144)).width('100%')
        }
      }
      Scroll() {
        Text(this.result).fontFamily('monospace').fontSize(14).width('100%').copyOption(CopyOptions.LocalDevice)
      }.layoutWeight(1).width('100%').align(Alignment.TopStart)
    }.width('100%').height('100%').padding(24).backgroundColor(this.theme.bgPrimary)
  }
}
