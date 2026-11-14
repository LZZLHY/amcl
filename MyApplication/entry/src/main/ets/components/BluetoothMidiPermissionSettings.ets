/**
 * 蓝牙MIDI的显式系统授权入口，沿用麦克风设置的状态机和离页失效规则。
 * 组件出现只查询当前权限，只有用户点击才申请；不扫描、配对、连接或自动授予设备权限。
 */
import { abilityAccessCtrl, common, PermissionRequestResult } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppLogger, ThemeColors } from 'commons';

@Component
export struct BluetoothMidiPermissionSettings {
  @Prop theme: ThemeColors = new ThemeColors();
  @State private status: abilityAccessCtrl.PermissionStatus = abilityAccessCtrl.PermissionStatus.INVALID;
  @State private busy: boolean = false;
  @State private message: ResourceStr = '';
  private generation: number = 0;

  /** 页面生命周期仅同步读取系统状态，不在启动或枚举MIDI时请求授权。 */
  aboutToAppear(): void {
    this.generation++;
    this.busy = false;
    this.refresh();
  }

  /** 旧页面请求完成后不得回写新视图，也不得继续打开第二个系统授权弹窗。 */
  aboutToDisappear(): void { this.generation++; }

  /** getSelfPermissionStatus自API20可用，恰为产品最低版本；未知状态不等于已拒绝。 */
  private refresh(): void {
    try {
      this.status = abilityAccessCtrl.createAtManager().getSelfPermissionStatus('ohos.permission.ACCESS_BLUETOOTH');
      this.message = this.status === abilityAccessCtrl.PermissionStatus.GRANTED
        ? $r('app.string.bluetooth_midi_permission_granted')
        : this.status === abilityAccessCtrl.PermissionStatus.DENIED
          ? $r('app.string.bluetooth_midi_permission_denied')
          : this.status === abilityAccessCtrl.PermissionStatus.NOT_DETERMINED
            ? $r('app.string.bluetooth_midi_permission_needed')
            : $r('app.string.bluetooth_midi_permission_invalid');
    } catch (error) {
      this.status = abilityAccessCtrl.PermissionStatus.INVALID;
      this.message = $r('app.string.bluetooth_midi_permission_query_failed');
      AppLogger.warn('BluetoothMidiPermission', '查询蓝牙MIDI权限失败', error);
    }
  }

  /**
   * 一次显式点击只执行一个授权流程。首次拒绝后停止；只有点击前就已经DENIED，
   * 才在标准申请确认拒绝状态后调用API12二次设置接口，不依赖API22新入口。
   * 完成结果重新查系统，不把Promise返回或本地布尔变量当作真实授权。
   */
  private async request(): Promise<void> {
    if (this.busy) return;
    this.refresh();
    const previous: abilityAccessCtrl.PermissionStatus = this.status;
    if (previous !== abilityAccessCtrl.PermissionStatus.NOT_DETERMINED &&
        previous !== abilityAccessCtrl.PermissionStatus.DENIED) return;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context === undefined) {
      this.message = $r('app.string.bluetooth_midi_permission_no_context');
      return;
    }
    this.busy = true;
    const epoch: number = this.generation;
    try {
      const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const result: PermissionRequestResult = await manager.requestPermissionsFromUser(context,
        ['ohos.permission.ACCESS_BLUETOOTH']);
      if (epoch !== this.generation) return;
      if (previous === abilityAccessCtrl.PermissionStatus.DENIED &&
          result.authResults.length === 1 && result.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_DENIED) {
        await manager.requestPermissionOnSetting(context, ['ohos.permission.ACCESS_BLUETOOTH']);
      }
      if (epoch === this.generation) this.refresh();
    } catch (error) {
      if (epoch !== this.generation) return;
      this.refresh();
      this.message = $r('app.string.bluetooth_midi_permission_request_failed');
      AppLogger.warn('BluetoothMidiPermission', '请求蓝牙MIDI权限失败', error as BusinessError);
    } finally {
      if (epoch === this.generation) this.busy = false;
    }
  }

  /** 按钮仅控制授权，不表示当前JDK/系统或外设已经通过MIDI传输资格。 */
  build() {
    Column({ space: 10 }) {
      Text($r('app.string.bluetooth_midi_permission_title'))
        .fontSize(16).fontWeight(500).fontColor(this.theme.textPrimary)
      Text(this.message).fontSize(14).fontColor(this.theme.textSecondary).width('100%')
      Button(this.busy ? $r('app.string.bluetooth_midi_permission_waiting')
        : this.status === abilityAccessCtrl.PermissionStatus.GRANTED
          ? $r('app.string.bluetooth_midi_permission_check')
          : this.status === abilityAccessCtrl.PermissionStatus.DENIED
            ? $r('app.string.bluetooth_midi_permission_settings')
            : this.status === abilityAccessCtrl.PermissionStatus.NOT_DETERMINED
              ? $r('app.string.bluetooth_midi_permission_allow') : $r('app.string.bluetooth_midi_permission_retry'))
        .width('100%').constraintSize({ minHeight: 44 }).enabled(!this.busy)
        .id('settings-bluetooth-midi-permission')
        .onClick((): void => { this.request(); })
    }.width('100%').alignItems(HorizontalAlign.Start).padding(16)
      .backgroundColor(this.theme.bgCard).borderRadius(24)
  }
}
