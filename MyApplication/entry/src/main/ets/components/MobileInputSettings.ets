import { ConnectedInputDevice, getInputDeviceMonitor } from 'gamecontrol'
import { MobileInputPreference } from '../runtime/MobileInputPreference'
import { EditorPalette } from './TouchEditorTheme'

/** 启动器与游戏使用同一份即时偏好。设备列表只在局内面板可见时订阅，不参与输入路由。 */
@Component
export struct MobileInputSettings {
  @Prop palette: EditorPalette = new EditorPalette()
  @Prop showDevices: boolean = false
  @State private mode: string = ''
  @State private devices: ConnectedInputDevice[] = []
  @State private error: string = ''
  private unsubscribe?: () => void
  private mounted: boolean = false
  private deviceListener: () => void = (): void => {
    if (this.mounted) this.devices = getInputDeviceMonitor().connectedDevices()
  }

  aboutToAppear(): void {
    this.mounted = true
    this.observePreference_()
    if (this.showDevices) {
      getInputDeviceMonitor().addDeviceListListener(this.deviceListener)
      this.deviceListener()
    }
  }

  aboutToDisappear(): void {
    this.mounted = false
    this.unsubscribe?.()
    this.unsubscribe = undefined
    if (this.showDevices) getInputDeviceMonitor().removeDeviceListListener(this.deviceListener)
  }

  /** 订阅成功会同步发布首值。监听不可用时仍独立回读磁盘，玩家可显式修复坏值或重试监听。 */
  private observePreference_(): void {
    if (!this.mounted) return
    const context = this.getUIContext().getHostContext() as Context
    if (!this.unsubscribe) {
      try {
        this.unsubscribe = MobileInputPreference.subscribe(context,
          (mode: string): void => { if (this.mounted) { this.mode = mode; this.error = '' } })
        return
      } catch (_) { /* 订阅失败可能来自监听或初读，以下回读区分当前值是否可用。 */ }
    }
    try {
      this.mode = MobileInputPreference.read(context)
      this.error = this.unsubscribe ? '' : '暂时无法自动刷新输入方式，可重新读取。'
    } catch (_) {
      this.mode = ''
      this.error = '无法读取当前输入方式。可重新读取，或选择一种方式重新保存。'
    }
  }

  /** 显式选择允许覆盖不可读的旧值；只以已提交文件的回读或订阅首值确认实际档位。 */
  private choose_(mode: string): void {
    if (!this.mounted || (mode === this.mode && this.error.length === 0)) return
    try {
      MobileInputPreference.save(this.getUIContext().getHostContext() as Context, mode)
    } catch (_) {
      this.error = '保存失败，请重试'
      return
    }
    this.observePreference_()
    if (this.error.length === 0 && this.mode !== mode) this.error = '输入方式已变更，当前选项已刷新。'
  }

  /** 复合外设展示全部来源类别；系统返回新类别时仍保留原描述。 */
  private categories_(device: ConnectedInputDevice): string {
    const labels: string[] = []
    for (const source of device.sources) {
      let label: string = source
      switch (source) {
        case 'keyboard': label = '键盘'; break
        case 'mouse': label = '鼠标'; break
        case 'touchpad': label = '触控板'; break
        case 'gamepad':
        case 'joystick': label = '手柄'; break
        case 'touchscreen': label = '触摸屏'; break
        case 'trackball': label = '轨迹球'; break
        case 'pen':
        case 'stylus': label = '手写笔'; break
      }
      if (label.length > 0 && !labels.includes(label)) labels.push(label)
    }
    return labels.length > 0 ? labels.join('、') : '类别未知'
  }

  @Builder
  Choice_(value: string, label: string) {
    Button(label).type(ButtonType.Normal).borderRadius(this.palette.radiusSmall)
      .constraintSize({ minHeight: 44 }).padding({ left: 12, right: 12 }).fontSize(14)
      .fontColor(this.mode === value ? this.palette.onAccent : this.palette.text)
      .backgroundColor(this.mode === value ? this.palette.accentFill : this.palette.surface)
      .margin({ right: 6, bottom: 4 })
      .id('mobile-input-'+value)
      .accessibilityText(label + (this.mode === value ? '，已选择' : ''))
      .onClick((): void => { this.choose_(value) })
  }

  build() {
    Column({ space: 8 }) {
      Text('移动端输入方式').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.palette.text)
      Flex({ wrap: FlexWrap.Wrap }) {
        this.Choice_('auto', '自动')
        this.Choice_('gamepad', '手柄优先')
        this.Choice_('kbm', '键鼠优先')
      }.width('100%')
      if (this.mode.length > 0) {
        Text(this.mode === 'auto' ? '连接外设时保留当前触控布局，可点“显影”手动切换。' :
          (this.mode === 'gamepad' ? '连接手柄后' : '键盘和鼠标或触控板均连接后') +
          '只留“显影、设置、聊”。触屏仍可操作，点“显影”恢复布局。')
          .fontSize(13).fontColor(this.palette.muted).width('100%')
      }
      if (this.error.length > 0) {
        Text(this.error).fontSize(13).fontColor(this.palette.warning)
        Button('重新读取').onClick((): void => { this.observePreference_() })
      }
      if (this.showDevices) {
        Text('已连接的输入设备').fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor(this.palette.text).margin({ top: 12 })
        if (this.devices.length === 0) {
          Text('暂未检测到输入设备').fontSize(14).fontColor(this.palette.muted)
        }
        ForEach(this.devices, (device: ConnectedInputDevice) => {
          Column({ space: 3 }) {
            Text(device.name || '设备 ' + device.id).fontSize(15).fontColor(this.palette.text)
            Text(this.categories_(device)).fontSize(13).fontColor(this.palette.muted)
          }.alignItems(HorizontalAlign.Start).width('100%').padding(10)
            .borderRadius(this.palette.radiusSmall).backgroundColor(this.palette.surface)
        }, (device: ConnectedInputDevice): string => JSON.stringify([device.id.toString(), device.name, ...device.sources]))
      }
    }.alignItems(HorizontalAlign.Start).width('100%')
  }
}
