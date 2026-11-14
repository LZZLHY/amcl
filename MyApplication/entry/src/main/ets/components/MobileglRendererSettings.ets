import { ThemeColors, AppLogger } from 'commons'
import { common } from '@kit.AbilityKit'
import { PreferenceManager } from 'feature_system'
import { GraphicsCandidate, GraphicsProfileInput, listGraphicsProfileAvailability } from 'launch'
import { prepareGraphicsProfileInput } from '../runtime/GraphicsCapabilityAdapter'
import { SettingsHint, SettingsValueRow } from './SettingsPrimitives'

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
  /** 紧凑模式只展示确认偏好与能力摘要；完整候选编辑由父页面打开独立设置界面。 */
  @Prop compact: boolean = false
  onOpen: () => void = () => {}
  /** 仅在用户明确确定并交给原偏好选择入口后通知父层关闭，不表示实际游戏启动成功。 */
  onConfirmed: () => void = () => {}
  @State private peerRows: PeerBackendRow[] = []
  @State private availabilityMessage: string = '正在读取设备与游戏能力…'
  /** 草稿只属于本次完整界面；选中单选项时不写偏好，也不清除开发者覆盖。 */
  @State private draftBackendId: string = ''
  @State private availabilityLoading: boolean = false
  @State private confirmError: string = ''
  /** 防止同一页面连续确定重复提交；重新挂接才开始下一次明确选择。 */
  @State private confirmationCommitted: boolean = false
  private refreshGeneration: number = 0
  private availabilityActive: boolean = false
  private pendingAvailabilityKey: string = ''
  private pendingAvailability: Promise<GraphicsProfileInput> | undefined = undefined
  private lastInputKey: string = ''
  private lastInput: GraphicsProfileInput | undefined = undefined

  /** appear与可见性回调可能相邻触发；同事实键共享在途查询，不向native重复争抢忙门。 */
  aboutToAppear(): void {
    this.availabilityActive = true
    this.draftBackendId = ''
    this.confirmationCommitted = false
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
    const generation: number = ++this.refreshGeneration
    if (context === undefined) {
      // 当前环境已经失效，本次 generation 同时使旧等待者失去发布权，不能确认旧候选。
      this.lastInput = undefined
      this.peerRows = []
      this.draftBackendId = ''
      this.availabilityLoading = false
      this.availabilityMessage = '无法读取当前页面环境，请重新打开设置。'
      return
    }
    this.availabilityLoading = true
    this.confirmError = ''
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
        this.draftBackendId = ''
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
      this.draftBackendId = ''
      this.availabilityMessage = '能力读取失败，请重新打开设置重试。'
      AppLogger.warn('RendererSettings', 'graphics availability failed', error)
    } finally {
      // 只有当前活动查询结束才能解除“读取中”；旧查询不得提前放开新一轮的确认操作。
      if (this.availabilityActive && generation === this.refreshGeneration) this.availabilityLoading = false
      // 旧实例完成时不能清掉新实例已经登记的在途任务。
      if (pending !== undefined && this.pendingAvailability === pending) {
        this.pendingAvailability = undefined
        this.pendingAvailabilityKey = ''
      }
    }
  }

  /** 仍由原 canonical 库生成唯一候选表；确认偏好与未提交草稿分别投影，不读取第二库存。 */
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
    // 同事实键的可见性复查不覆盖用户正在选择的有效草稿；换实例时已在读取前清空。
    if (this.draftBackendId.length === 0 || !rows.some((row: PeerBackendRow): boolean => row.id === this.draftBackendId)) {
      const selected: PeerBackendRow | undefined = rows.find((row: PeerBackendRow): boolean => row.selected)
      this.draftBackendId = selected?.id ?? ''
    }
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

  /** 原选择出口只在确定时调用；保存启动偏好不代表当前窗口已经采用或验证了该后端。 */
  private selectPeerBackend(row: PeerBackendRow): void {
    if (!row.enabled) return
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined
    if (context === undefined) return
    const preferences: PreferenceManager = new PreferenceManager(context)
    preferences.graphicsProfile = row.id
    // 所有候选共用原偏好键；用户明确选择时退役旧 DevTools 覆盖，避免两份偏好竞争。
    preferences.devRendererOverride = ''
    this.refreshPeerRows()
    AppLogger.info('RendererSettings', 'graphics profile selected=' + row.id)
  }

  /** 摘要只消费 peerRows 的确认标记；加载与失败时不借用旧偏好名称制造能力结论。 */
  private confirmedBackendName_(): string {
    if (this.availabilityLoading) return '正在读取…'
    if (this.lastInput === undefined) return '暂不可用'
    return this.peerRows.find((row: PeerBackendRow): boolean => row.selected)?.name ?? '未选择'
  }

  /** 未选择实例、加载失败和真实候选原因分别呈现，预检通过不表述为实际运行通过。 */
  private backendSummary_(): string {
    if (this.availabilityLoading) return '正在核对设备与游戏能力…'
    if (this.lastInput === undefined || this.lastInput.realMcVersion.length === 0) return this.availabilityMessage
    return this.peerRows.find((row: PeerBackendRow): boolean => row.selected)?.reason ?? this.availabilityMessage
  }

  /** 只变更草稿；行对象可能来自较早一帧，必须再从当前候选表按稳定 id 取得可选事实。 */
  private stagePeerBackend_(row: PeerBackendRow): void {
    if (this.compact || !this.availabilityActive || this.availabilityLoading || this.confirmationCommitted) return
    const current: PeerBackendRow | undefined = this.peerRows.find((item: PeerBackendRow): boolean => item.id === row.id)
    if (current === undefined || !current.enabled || this.lastInput === undefined) return
    this.draftBackendId = current.id
    this.confirmError = ''
  }

  /** 加载或失败、退出页面及不可手选的候选均不能通过底部确定按钮提交旧项。 */
  private canConfirm_(): boolean {
    return !this.compact && this.availabilityActive && !this.availabilityLoading && !this.confirmationCommitted &&
      this.lastInput !== undefined && this.peerRows.some((row: PeerBackendRow): boolean =>
      row.id === this.draftBackendId && row.enabled)
  }

  /** 确定时重核当前表与页面环境，只交给原选择出口一次；返回通知只代表偏好提交。 */
  private confirmBackend_(): void {
    if (!this.canConfirm_()) return
    const row: PeerBackendRow | undefined = this.peerRows.find((item: PeerBackendRow): boolean =>
      item.id === this.draftBackendId && item.enabled)
    if (row === undefined) return
    if (this.getUIContext().getHostContext() === undefined) {
      this.confirmError = '当前页面环境已失效，请重新打开设置。'
      return
    }
    this.confirmationCommitted = true
    try {
      this.selectPeerBackend(row)
    } catch (error) {
      this.confirmationCommitted = false
      this.confirmError = '无法提交图形偏好，请重试。'
      AppLogger.warn('RendererSettings', 'graphics preference submission failed', error)
      return
    }
    this.onConfirmed()
  }

  /** 候选正文只绘制确认草稿。只读候选不用Button禁用态压暗必要原因，选择仍由canonical校验。 */
  @Builder
  private BackendRow_(row: PeerBackendRow) {
    Row({ space: 16 }) {
      Column({ space: 4 }) {
        Text(row.name).fontSize(16).fontColor(row.enabled ? this.theme.textPrimary : this.theme.textSecondary).width('100%')
        Text(row.reason).fontSize(14).fontColor(this.theme.textSecondary).lineHeight(20).width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Stack() {
        Row().width(24).height(24).borderRadius(12).backgroundColor(Color.Transparent)
          .border({ color: this.draftBackendId === row.id ? this.theme.actionText : this.theme.textSecondary,
            width: this.draftBackendId === row.id ? 2 : 1.5 })
        if (this.draftBackendId === row.id) {
          Row().width(12).height(12).borderRadius(6).backgroundColor(this.theme.actionText)
        }
      }.width(24).height(24)
    }.width('100%').constraintSize({ minHeight: 76 }).padding(16).alignItems(VerticalAlign.Center)
  }

  build() {
    Column({ space: this.compact ? 0 : 20 }) {
      if (this.compact) {
        SettingsValueRow({ title: '图形后端', value: this.confirmedBackendName_(), description: this.backendSummary_(),
          theme: this.theme, controlId: 'settings-item-graphics', onAction: (): void => { this.onOpen(); } })
      } else {
        SettingsHint({ text: this.availabilityMessage, theme: this.theme })
        Column({ space: 0 }) {
          ForEach(this.peerRows, (row: PeerBackendRow) => {
            if (row.enabled) {
              Button({ type: ButtonType.Normal }) { this.BackendRow_(row); }
                .width('100%').constraintSize({ minHeight: 76 }).padding(0).borderRadius(0).backgroundColor(Color.Transparent)
                .id('graphics-profile-' + row.id).enabled(!this.availabilityLoading && !this.confirmationCommitted)
                .accessibilityText(row.name + '，' + row.reason + (this.draftBackendId === row.id ? '，已选中，待确认' : ''))
                .onClick((): void => { this.stagePeerBackend_(row); })
            } else {
              Column() { this.BackendRow_(row); }.width('100%').id('graphics-profile-' + row.id)
                .accessibilityGroup(true).accessibilityText(row.name + '，不可用，' + row.reason)
            }
          }, (row: PeerBackendRow): string => row.id + ':' + (row.enabled ? 'enabled' : 'disabled') + ':' + row.reason)
        }.width('100%').backgroundColor(this.theme.bgCard).borderRadius(20).clip(true)
        if (this.confirmError.length > 0) {
          SettingsHint({ text: this.confirmError, theme: this.theme, isError: true })
        }
        SettingsHint({ text: '此处选择下次启动的偏好；实际窗口与呈现能力会在启动时复核。', theme: this.theme })
        Button('确定').width('100%').height(48).borderRadius(24).fontSize(16)
          .fontColor(this.theme.textOnPrimary).backgroundColor(this.theme.actionPrimary)
          .enabled(this.canConfirm_()).id('settings-graphics-confirm')
          .onClick((): void => { this.confirmBackend_(); })
      }
    }.width('100%').backgroundColor(this.compact ? this.theme.bgCard : Color.Transparent).borderRadius(this.compact ? 20 : 0)
      .onVisibleAreaChange([0, 1], (visible: boolean, _ratio: number) => {
        if (visible) this.refreshAvailability()
      })
  }
}
