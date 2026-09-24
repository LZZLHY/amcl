import { ThemeColors, AppLogger } from 'commons'
import { common } from '@kit.AbilityKit'
import { PreferenceManager } from 'feature_system'
import { GraphicsCandidate, GraphicsProfileInput, listGraphicsProfileAvailability } from 'launch'
import { prepareGraphicsProfileInput } from '../runtime/GraphicsCapabilityAdapter'

/** A peer renderer row. Kept UI-local so settings can render while a probe is pending. */
export interface PeerBackendRow {
  id: string
  name: string
  enabled: boolean
  selected: boolean
  reason: string
  reasonCode: string
  provider: string
  api: string
}

@Component
export struct MobileglRendererSettings {
  @Prop theme: ThemeColors = {} as ThemeColors
  @Prop @Watch('refreshAvailability') mcDir: string = ''
  @Prop @Watch('refreshAvailability') mcVersion: string = ''
  @State private peerRows: PeerBackendRow[] = []
  @State private availabilityMessage: string = '正在读取设备与游戏能力…'
  private refreshGeneration: number = 0
  private lastInput: GraphicsProfileInput | undefined = undefined

  aboutToAppear(): void {
    this.refreshAvailability()
  }

  aboutToDisappear(): void {
    this.refreshGeneration++
  }

  private refreshAvailability(): void {
    this.loadAvailability()
  }

  private async loadAvailability(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined
    if (context === undefined) return
    const generation: number = ++this.refreshGeneration
    try {
      const preferences: PreferenceManager = new PreferenceManager(context)
      const input: GraphicsProfileInput = await prepareGraphicsProfileInput(context,
        this.mcDir, this.mcVersion, preferences.graphicsProfile, true, preferences.graphicsProfileExplicit)
      if (generation !== this.refreshGeneration) return
      this.lastInput = input
      this.availabilityMessage = input.realMcVersion.length > 0
        ? '当前版本：' + this.mcVersion + '；保存的偏好将在下次启动复核窗口与呈现能力。'
        : '请选择已安装的游戏版本，以核对窗口与图形 API 要求。'
      this.refreshPeerRows()
    } catch (error) {
      if (generation !== this.refreshGeneration) return
      this.lastInput = undefined
      this.peerRows = []
      this.availabilityMessage = '能力读取失败，请重新打开设置重试。'
      AppLogger.warn('RendererSettings', 'graphics availability failed', error)
    }
  }

  private refreshPeerRows(): void {
    if (this.lastInput === undefined) return
    const preferences: PreferenceManager = new PreferenceManager(this.getUIContext().getHostContext() as common.UIAbilityContext)
    const override: string = preferences.devRendererOverride
    const selected: string = override.length > 0 ? override
      : (!preferences.graphicsProfileExplicit && preferences.graphicsProfile === 'mobileglues' ? 'auto' : preferences.graphicsProfile)
    const rows: PeerBackendRow[] = []
    rows.push({ id: 'auto', name: '自动选择', enabled: true, selected: selected === 'auto',
      reason: '按游戏版本、设备能力和包内运行库选择。', reasonCode: 'auto', provider: '', api: '' })
    for (const candidate of listGraphicsProfileAvailability(this.lastInput)) {
      const profile = candidate.profile
      if (profile === undefined) continue
      rows.push({ id: candidate.id, name: profile.displayName,
        enabled: candidate.admitted && profile.userSelectable, selected: selected === candidate.id,
        reason: this.availabilityReason(candidate), reasonCode: candidate.reasonCode,
        provider: candidate.provider, api: profile.api })
    }
    this.peerRows = rows
  }

  private availabilityReason(candidate: GraphicsCandidate): string {
    if (candidate.id === 'gl4es') return '兼容旧版游戏，由版本与 LWJGL 槽位自动选择。'
    if (candidate.admitted) return candidate.id === 'nativegl'
      ? '系统 OpenGL 入口可用；启动时复核 context 和窗口，底层实现待观测。'
      : '运行库与设备预检通过；启动时复核当前窗口和呈现。'
    if (candidate.reasonCode === 'artifact-missing') return '当前安装包未包含此后端所需的运行库。'
    if (candidate.reasonCode === 'window-provider-unsupported') return '当前游戏的窗口接口尚未支持此后端。'
    if (candidate.reasonCode === 'game-api-unverified') return '当前游戏清单未声明所需的图形 API。'
    if (candidate.reasonCode === 'fixed-function-required') return '此旧版游戏需要 GL4ES 固定管线兼容。'
    if (candidate.reasonCode === 'game-version-unsupported') return '当前游戏版本不满足此后端要求。'
    return '能力尚未通过：' + candidate.reason
  }

  private selectPeerBackend(row: PeerBackendRow): void {
    if (!row.enabled) return
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined
    if (context === undefined) return
    const preferences: PreferenceManager = new PreferenceManager(context)
    preferences.graphicsProfile = row.id
    // Every peer uses the same preference. Retire an old DevTools override
    // when the user selects a profile explicitly from Settings.
    preferences.devRendererOverride = ''
    this.refreshPeerRows()
    AppLogger.info('RendererSettings', 'graphics profile selected=' + row.id)
  }

  build() {
    Column() {
      Column({ space: 8 }) {
        Text('图形后端').fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.theme.textPrimary)
        Text(this.availabilityMessage)
          .fontSize(12).fontColor(this.theme.textSecondary).width('100%')
        ForEach(this.peerRows, (row: PeerBackendRow) => {
          Row({ space: 10 }) {
            Column({ space: 3 }) {
              Text(row.name).fontSize(14).fontColor(row.enabled ? this.theme.textPrimary : this.theme.textHint)
              Text(row.reason).fontSize(11).fontColor(row.enabled ? this.theme.textSecondary : this.theme.textHint)
                .width('100%')
              if (row.api.length > 0) {
                Text(row.api + ' · ' + row.provider + ' · ' + row.reasonCode).fontSize(10).fontColor(this.theme.textHint)
              }
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Text(row.enabled ? (row.selected ? '已选择' : '可选') : '不可用')
              .fontSize(11).fontColor(row.enabled ? this.theme.primary : this.theme.textHint)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 }).backgroundColor(this.theme.bgInput).borderRadius(8)
          }.width('100%').padding({ top: 7, bottom: 7 }).opacity(row.enabled ? 1 : 0.62)
            .id('graphics-profile-' + row.id)
            .enabled(row.enabled)
            .accessibilityText(row.name + '，' + row.reason)
            .onClick(() => { this.selectPeerBackend(row) })
        }, (row: PeerBackendRow) => row.id + ':'
          + (row.enabled ? 'enabled' : 'disabled') + ':'
          + (row.selected ? 'selected' : 'available') + ':' + row.reason)
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12, bottom: 8 })
      Row().width('100%').height(0.5).backgroundColor(this.theme.divider)
    }.width('100%')
      .onVisibleAreaChange([0, 1], (visible: boolean, _ratio: number) => {
        if (visible) this.refreshAvailability()
      })
  }
}
