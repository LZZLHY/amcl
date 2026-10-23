import { ThemeColors, AppLogger } from 'commons'
import { common } from '@kit.AbilityKit'
import { PreferenceManager } from 'feature_system'
import { GraphicsCandidate, GraphicsProfileInput, listGraphicsProfileAvailability } from 'launch'
import { prepareGraphicsProfileInput } from '../runtime/GraphicsCapabilityAdapter'

/** 设置页的平级后端行；偏好选择与探针可用性分别显示，等待期间不制造设备支持结论。 */
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
  private availabilityActive: boolean = false
  private pendingAvailabilityKey: string = ''
  private pendingAvailability: Promise<GraphicsProfileInput> | undefined = undefined
  private lastInputKey: string = ''
  private lastInput: GraphicsProfileInput | undefined = undefined

  /** appear与可见性回调可能相邻触发；同事实键共享在途查询，不向native重复争抢忙门。 */
  aboutToAppear(): void {
    this.availabilityActive = true
    this.refreshAvailability()
  }

  /** 退出后撤销所有等待者的发布资格；进行中的只读查询可完成，但不得再写组件状态。 */
  aboutToDisappear(): void {
    this.availabilityActive = false
    this.refreshGeneration++
  }

  /** Watch/可见性共用此入口；组件出现前或离开后的回调不再发起能力查询。 */
  private refreshAvailability(): void {
    this.loadAvailability()
  }

  /**
   * 按安装包、实例和偏好合并在途prepare，完成后不缓存能力。每位等待者仍有自己的
   * generation，只有活动组件的最后一次请求能够发布。切实例时立即清除旧行，防止
   * 新事实尚未返回时按旧实例能力选后端；重新进入组件可等待同键任务，但不能复活旧等待者。
   */
  private async loadAvailability(): Promise<void> {
    if (!this.availabilityActive) return
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined
    if (context === undefined) return
    const generation: number = ++this.refreshGeneration
    let pending: Promise<GraphicsProfileInput> | undefined = undefined
    try {
      const preferences: PreferenceManager = new PreferenceManager(context)
      const mcDir: string = this.mcDir
      const mcVersion: string = this.mcVersion
      const key: string = JSON.stringify([context.bundleCodeDir, mcDir, mcVersion,
        preferences.graphicsProfile, String(preferences.graphicsProfileExplicit)])
      if (key !== this.lastInputKey) {
        this.lastInput = undefined
        this.peerRows = []
        this.availabilityMessage = '正在读取设备与游戏能力…'
      }
      pending = this.pendingAvailabilityKey === key ? this.pendingAvailability : undefined
      if (pending === undefined) {
        pending = prepareGraphicsProfileInput(context, mcDir, mcVersion,
          preferences.graphicsProfile, true, preferences.graphicsProfileExplicit)
        this.pendingAvailabilityKey = key
        this.pendingAvailability = pending
      }
      const input: GraphicsProfileInput = await pending
      if (!this.availabilityActive || generation !== this.refreshGeneration) return
      this.lastInput = input
      this.lastInputKey = key
      this.availabilityMessage = input.realMcVersion.length > 0
        ? '当前版本：' + mcVersion + '；保存的偏好将在下次启动复核窗口与呈现能力。'
        : '请选择已安装的游戏版本，以核对窗口与图形 API 要求。'
      this.refreshPeerRows()
    } catch (error) {
      if (!this.availabilityActive || generation !== this.refreshGeneration) return
      this.lastInput = undefined
      this.peerRows = []
      this.availabilityMessage = '能力读取失败，请重新打开设置重试。'
      AppLogger.warn('RendererSettings', 'graphics availability failed', error)
    } finally {
      // 旧实例完成时不能清掉新实例已经登记的在途任务。
      if (pending !== undefined && this.pendingAvailability === pending) {
        this.pendingAvailability = undefined
        this.pendingAvailabilityKey = ''
      }
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
    // 有界重试仍遇到忙门时说明尚未完成检查，提示重新观察而非声称系统库缺失。
    if (candidate.id === 'nativegl' && this.lastInput !== undefined) {
      for (const result of this.lastInput.capabilityResults ?? []) {
        if (result.evidenceProfileId === 'nativegl' && result.reasonCode === 'native-gl-probe-busy') {
          return '系统 OpenGL 检查暂时忙碌，请稍后重新打开设置。'
        }
      }
    }
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
