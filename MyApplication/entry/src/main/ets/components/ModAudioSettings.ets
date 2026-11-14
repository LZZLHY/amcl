/** 模组录音设置视图；保存和授权由进程协调器完成，组件销毁不取消已经授权的持久提交。 */
import { ThemeColors } from 'commons';
import { ModAudioRuntime } from '../runtime/ModAudioRuntime';
import { SettingsHint, SettingsToggleRow } from './SettingsPrimitives';

@Component
export struct ModAudioSettings {
  @Prop theme: ThemeColors = {} as ThemeColors;
  @StorageProp('modAudioUserEnabled') private microphoneEnabled_: boolean = false;
  @StorageProp('modAudioPermissionGranted') private granted: boolean = false;
  @State private saving: boolean = false;
  @State private errorText: string = '';
  private active: boolean = false;
  onLayout: () => void = () => {};

  /** 初次呈现仅刷新真实状态，不弹系统权限、不打开麦克风。 */
  aboutToAppear(): void { this.active = true; ModAudioRuntime.refresh(); }
  aboutToDisappear(): void { this.active = false; }

  /** 同一视图的操作串行；异步完成只更新仍挂载的组件，业务提交不依赖视图寿命。 */
  private async change_(enabled: boolean): Promise<void> {
    if (this.saving) return;
    this.saving = true;
    this.errorText = '';
    try { await ModAudioRuntime.setEnabled(enabled); }
    catch (error) { if (this.active) this.errorText = (error as Error).message; }
    finally { if (this.active) this.saving = false; }
  }

  build() {
    Column() {
      SettingsToggleRow({ title: '允许模组使用麦克风',
        description: '用于游戏内语音聊天和 AI 交互，仅在游戏前台采集',
        value: this.microphoneEnabled_, saving: this.saving, theme: this.theme,
        controlId: 'modMicrophoneEnabledSwitch',
        onChange: (enabled: boolean): void => { this.change_(enabled); } });
      Column({ space: 6 }) {
        SettingsHint({ text: this.microphoneEnabled_ && !this.granted ? '系统麦克风权限尚未授予。' :
          '开启后重新启动游戏，以便模组重新扫描麦克风。录音仅在模组请求时开始。', theme: this.theme });
        if (this.errorText.length > 0) SettingsHint({ text: this.errorText, theme: this.theme, isError: true });
      }.width('100%').padding({ left: 16, right: 16, bottom: 16 });
    }.width('100%').id('settings-item-mod-audio').onAreaChange((): void => { this.onLayout(); });
  }
}
