/**
 * 游戏录音的系统授权入口。只在用户点击时申请麦克风，不创建音频输入流；
 * 显示值每次从系统重新读取，不持久化一个会掩盖撤权的“已允许”开关。
 */
import { abilityAccessCtrl, common, PermissionRequestResult } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppLogger, ThemeColors } from 'commons';

@Component
export struct MicrophonePermissionSettings {
  @Prop theme: ThemeColors = new ThemeColors();
  @State private status: abilityAccessCtrl.PermissionStatus = abilityAccessCtrl.PermissionStatus.INVALID;
  @State private busy: boolean = false;
  @State private message: string = '';
  private generation: number = 0;

  /** 组件出现只查询权限；不借生命周期触发敏感权限弹窗。 */
  aboutToAppear(): void {
    this.generation++;
    this.busy = false;
    this.refresh();
  }

  /** 使已离开页面的异步结果失效，避免回写已销毁视图或继续拉起设置弹窗。 */
  aboutToDisappear(): void { this.generation++; }

  /** API20正是产品最低版本；未知/查询失败保留为不可确认，不当作拒绝或允许。 */
  private refresh(): void {
    try {
      this.status = abilityAccessCtrl.createAtManager().getSelfPermissionStatus('ohos.permission.MICROPHONE');
      this.message = this.status === abilityAccessCtrl.PermissionStatus.GRANTED
        ? '已授权。仅在你启动语音或录音功能时使用麦克风。'
        : this.status === abilityAccessCtrl.PermissionStatus.DENIED
          ? '尚未授权。你可以前往系统授权设置开启麦克风。'
          : this.status === abilityAccessCtrl.PermissionStatus.NOT_DETERMINED
            ? '使用语音或录音功能前，需要你允许麦克风权限。'
            : '当前无法申请麦克风权限，请检查系统中的应用权限设置。';
    } catch (error) {
      this.status = abilityAccessCtrl.PermissionStatus.INVALID;
      this.message = '无法读取麦克风授权状态，请稍后重试。';
      AppLogger.warn('MicrophonePermission', '查询麦克风权限失败', error);
    }
  }

  /**
   * 一次点击只启动一个授权动作。首次申请被拒绝后立即返回，不追着用户再弹设置框；
   * 仅点击前已处于DENIED时才进入官方二次设置授权流程。所有完成结果以系统复查为准。
   */
  private async request(): Promise<void> {
    if (this.busy) return;
    this.refresh();
    const previous: abilityAccessCtrl.PermissionStatus = this.status;
    if (previous !== abilityAccessCtrl.PermissionStatus.NOT_DETERMINED &&
        previous !== abilityAccessCtrl.PermissionStatus.DENIED) return;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context === undefined) {
      this.message = '当前页面无法发起授权，请重新进入设置。';
      return;
    }
    this.busy = true;
    const epoch: number = this.generation;
    try {
      const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      // 二次设置接口要求先调用标准申请接口；已拒绝状态下它不会重新弹首次授权框。
      const result: PermissionRequestResult = await manager.requestPermissionsFromUser(context,
        ['ohos.permission.MICROPHONE']);
      if (epoch !== this.generation) return;
      if (previous === abilityAccessCtrl.PermissionStatus.DENIED &&
          result.authResults.length === 1 && result.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_DENIED) {
        await manager.requestPermissionOnSetting(context, ['ohos.permission.MICROPHONE']);
      }
      if (epoch === this.generation) this.refresh();
    } catch (error) {
      if (epoch !== this.generation) return;
      this.refresh();
      this.message = '麦克风授权未完成，请重试或在系统应用权限中查看。';
      AppLogger.warn('MicrophonePermission', '请求麦克风权限失败', error as BusinessError);
    } finally {
      if (epoch === this.generation) this.busy = false;
    }
  }

  /** 独立纵向卡片沿用设置页主题；按钮不是录音开关，也不承诺当前JDK具备输入后端。 */
  build() {
    Column({ space: 10 }) {
      Text('麦克风授权').fontSize(16).fontWeight(500).fontColor(this.theme.textPrimary)
      Text(this.message).fontSize(14).fontColor(this.theme.textSecondary).width('100%')
      Button(this.busy ? '正在等待授权…' : this.status === abilityAccessCtrl.PermissionStatus.GRANTED
        ? '检查授权状态' : this.status === abilityAccessCtrl.PermissionStatus.DENIED
          ? '前往授权设置' : this.status === abilityAccessCtrl.PermissionStatus.NOT_DETERMINED
            ? '允许使用麦克风' : '重新检查')
        .width('100%').constraintSize({ minHeight: 44 }).enabled(!this.busy)
        .id('settings-microphone-permission')
        .onClick((): void => { this.request(); })
    }.width('100%').alignItems(HorizontalAlign.Start).padding(16)
      .backgroundColor(this.theme.bgCard).borderRadius(24)
  }
}
