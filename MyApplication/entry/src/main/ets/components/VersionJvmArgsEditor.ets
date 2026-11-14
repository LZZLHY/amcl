/**
 * 版本专属 JVM 参数的独立编辑正文（V06）。标题、共享 Sheet 与真正的存储 owner 均由父层持有。
 * 本组件只通过同步读取/异步保存回调工作，不打开 Preferences、不解释参数，也不启动游戏。
 * versionId、ownerKey、visible 与本地代次共同决定显示资格；退场不会取消已派发的耐久写入，
 * 但其迟到结果不得更新新版本草稿、通知新 owner 或驱动新的导航。
 */
import { promptAction } from '@kit.ArkUI';
import { ThemeColors, formatError } from 'commons';

@Component
export struct VersionJvmArgsEditor {
  @Prop theme: ThemeColors = new ThemeColors();
  @Prop @Watch('onSessionChanged_') versionId: string = '';
  @Prop @Watch('onSessionChanged_') ownerKey: string = '';
  @Prop @Watch('onSessionChanged_') visible: boolean = false;
  @Prop bottomSafeHeight: number = 0;

  /** 缺少接线须显式失败，不能把未读取的空值伪装成已有确认值。 */
  loadValue: (versionId: string) => string = (_: string): string => {
    throw new Error('尚未配置版本 JVM 参数读取回调');
  };
  /** 父 owner 必须在自己的耐久写入确认后 resolve；默认拒绝避免误报保存成功。 */
  saveValue: (versionId: string, value: string) => Promise<void> = async (_: string, _value: string): Promise<void> => {
    throw new Error('尚未配置版本 JVM 参数保存回调');
  };
  onSaved: (versionId: string, value: string) => void = (_: string, _value: string): void => {};
  onBack: () => void = (): void => {};
  onClose: () => void = (): void => {};
  /** handler(true) 返回上一步；handler(false/undefined) 关闭整个父 Sheet。 */
  onRegisterDismiss: (handler: ((back?: boolean) => void) | undefined) => void =
    (_: ((back?: boolean) => void) | undefined): void => {};
  onNavigationBlocked: (blocked: boolean) => void = (_: boolean): void => {};

  @State private draft_: string = '';
  @State private confirmed_: string = '';
  @State private loaded_: boolean = false;
  @State private saving_: boolean = false;
  @State private confirming_: boolean = false;
  @State private loadError_: string = '';
  @State private saveError_: string = '';
  private mounted_: boolean = false;
  private closing_: boolean = false;
  private generation_: number = 0;
  private sessionVersion_: string = '';
  private sessionOwner_: string = '';
  private registered_: boolean = false;
  private publishedBlocked_: boolean = false;
  /** 独立于父 Prop 刷新的本地在途标记，阻止同一帧重复提交。 */
  private saveSerial_: number = 0;
  private pendingSave_: number = 0;
  private dialogSerial_: number = 0;
  private pendingDialog_: number = 0;

  /** 只在正文可见且已挂载时读取父层轻量确认值。 */
  aboutToAppear(): void {
    this.mounted_ = true;
    this.onSessionChanged_();
  }

  /** 卸载只撤销处理器与显示资格；不补写草稿，也不撤销父 owner 已执行的保存。 */
  aboutToDisappear(): void {
    this.retireSession_();
    this.mounted_ = false;
  }

  /** 真实版本/owner/可见性变化均退休旧代次；visible=false 不触发加载、保存或结果通知。 */
  private onSessionChanged_(): void {
    if (!this.mounted_) return;
    this.retireSession_();
    if (!this.visible) return;
    this.closing_ = false;
    this.sessionVersion_ = this.versionId;
    this.sessionOwner_ = this.ownerKey;
    this.draft_ = '';
    this.confirmed_ = '';
    this.loaded_ = false;
    this.loadError_ = '';
    this.saveError_ = '';
    this.saving_ = this.pendingSave_ !== 0;
    const generation: number = this.generation_;
    const version: string = this.sessionVersion_;
    const owner: string = this.sessionOwner_;
    this.registered_ = true;
    this.onRegisterDismiss((back?: boolean): void => {
      if (this.isCurrent_(generation, version, owner)) this.requestDismiss_(back === true);
    });
    if (this.pendingSave_ !== 0) {
      // 外部强制换 owner 后旧保存仍在执行；显式重读可避免展示在途缓存或补写旧结果。
      this.loadError_ = '上一笔保存尚未结束，完成后请重新读取。';
    } else {
      this.load_();
    }
    this.reportBlocked_();
  }

  /** 注册只撤销一次，防止退场动画结束后的第二次卸载回调清除后继正文的处理器。 */
  private retireSession_(): void {
    this.generation_++;
    this.dialogSerial_++;
    this.pendingDialog_ = 0;
    this.confirming_ = false;
    if (this.registered_) {
      this.registered_ = false;
      this.onRegisterDismiss(undefined);
    }
    if (this.publishedBlocked_) {
      this.publishedBlocked_ = false;
      this.onNavigationBlocked(false);
    }
  }

  /** 每个事件及异步结果都核对真实 Prop、建立会话时的身份与代次，不能只比较版本名称。 */
  private isCurrent_(generation: number, version: string, owner: string): boolean {
    return this.mounted_ && this.visible && !this.closing_ && generation === this.generation_
      && version === this.versionId && owner === this.ownerKey
      && version === this.sessionVersion_ && owner === this.sessionOwner_;
  }

  private isActive_(): boolean {
    return this.isCurrent_(this.generation_, this.sessionVersion_, this.sessionOwner_);
  }

  /** 原始草稿比较不吞掉用户输入的首尾空白；只在明确保存时统一 trim。 */
  private isDirty_(): boolean {
    return this.loaded_ && this.draft_ !== this.confirmed_;
  }

  /** 父层用同一阻塞事实保护顶部/系统返回、拖拽与遮罩；正文也保有自己的同步事件围栏。 */
  private reportBlocked_(): void {
    const blocked: boolean = this.isActive_() && (this.pendingSave_ !== 0 || this.confirming_);
    if (blocked === this.publishedBlocked_) return;
    this.publishedBlocked_ = blocked;
    this.onNavigationBlocked(blocked);
  }

  /** 同步 load 回调允许抛错；失败保留明确错误和重试入口，保存按钮不接受未读确认态。 */
  private load_(): void {
    if (!this.isActive_() || this.pendingSave_ !== 0 || this.confirming_) return;
    const generation: number = this.generation_;
    const version: string = this.sessionVersion_;
    const owner: string = this.sessionOwner_;
    this.loaded_ = false;
    this.loadError_ = '';
    this.saveError_ = '';
    try {
      if (version.length === 0 || owner.length === 0) throw new Error('版本编辑上下文无效，请返回后重试');
      const value: string = this.loadValue(version);
      if (typeof value !== 'string') throw new Error('读取回调没有返回有效的参数文本');
      if (!this.isCurrent_(generation, version, owner)) return;
      this.confirmed_ = value;
      this.draft_ = value;
      this.loaded_ = true;
    } catch (error) {
      if (this.isCurrent_(generation, version, owner)) this.loadError_ = '读取失败：' + formatError(error);
    }
  }

  /** TextArea 的直接事件也核对资格；迟到输入不能改隐藏页或保存中的请求快照。 */
  private changeDraft_(value: string): void {
    if (!this.isActive_() || !this.loaded_ || this.pendingSave_ !== 0 || this.confirming_) return;
    this.draft_ = value;
    this.saveError_ = '';
  }

  /** 退出确认固定绑定当前 UIContext；不用全局 AlertDialog/promptAction 推测所属窗口。 */
  private showDiscard_(): Promise<promptAction.ShowDialogSuccessResponse> {
    return this.getUIContext().getPromptAction().showDialog({
      title: '放弃尚未保存的修改？',
      message: '当前版本的 JVM 参数尚未保存。放弃后将恢复此前的参数。',
      buttons: [
        { text: '继续编辑', color: this.theme.actionText as string },
        { text: '放弃修改', color: this.theme.errorText as string }
      ]
    });
  }

  /** 取消、标题返回/关闭及父层系统退出统一走此入口；确认取消或失败均不写存储。 */
  private async requestDismiss_(back: boolean): Promise<void> {
    if (!this.isActive_() || this.pendingSave_ !== 0 || this.confirming_) return;
    if (!this.isDirty_()) { this.finishDismiss_(back); return; }
    const generation: number = this.generation_;
    const version: string = this.sessionVersion_;
    const owner: string = this.sessionOwner_;
    const dialog: number = ++this.dialogSerial_;
    this.pendingDialog_ = dialog;
    this.confirming_ = true;
    this.reportBlocked_();
    try {
      const result: promptAction.ShowDialogSuccessResponse = await this.showDiscard_();
      if (!this.isCurrent_(generation, version, owner) || this.pendingDialog_ !== dialog) return;
      if (result.index === 1) {
        this.draft_ = this.confirmed_;
        this.saveError_ = '';
        this.finishDismiss_(back);
      }
    } catch (_) {
      // 原生返回/遮罩取消确认也可能拒绝 Promise，保留草稿即可，不伪装成保存失败。
    } finally {
      if (this.pendingDialog_ === dialog) {
        this.pendingDialog_ = 0;
        if (this.isCurrent_(generation, version, owner)) {
          this.confirming_ = false;
          this.reportBlocked_();
        }
      }
    }
  }

  /** 只在放弃已确认或保存成功后派发一次导航；先退休闭包避免连续返回关闭后继正文。 */
  private finishDismiss_(back: boolean): void {
    if (!this.isActive_() || this.pendingSave_ !== 0) return;
    this.closing_ = true;
    this.retireSession_();
    if (back) this.onBack(); else this.onClose();
  }

  /** 请求只携发起时的版本及 trim 后文本；真实成功以前不更新确认值或通知父层。 */
  private async save_(): Promise<void> {
    if (!this.isActive_() || !this.loaded_ || !this.isDirty_() || this.pendingSave_ !== 0 || this.confirming_) return;
    const generation: number = this.generation_;
    const version: string = this.sessionVersion_;
    const owner: string = this.sessionOwner_;
    const value: string = this.draft_.trim();
    const request: number = ++this.saveSerial_;
    this.pendingSave_ = request;
    this.saving_ = true;
    this.saveError_ = '';
    this.reportBlocked_();
    let completed: boolean = false;
    try {
      await this.saveValue(version, value);
      completed = true;
    } catch (error) {
      if (this.isCurrent_(generation, version, owner)) this.saveError_ = '保存失败，草稿已保留，可重试：' + formatError(error);
    } finally {
      if (this.pendingSave_ === request) {
        // 这是实际在途请求的资源标记，不是迟到 owner 的显示结果；不清除任何后继请求。
        this.pendingSave_ = 0;
        if (this.mounted_) { this.saving_ = false; this.reportBlocked_(); }
      }
    }
    if (!completed || !this.isCurrent_(generation, version, owner)) return;
    this.confirmed_ = value;
    this.draft_ = value;
    this.saveError_ = '';
    this.onSaved(version, value);
    if (this.isCurrent_(generation, version, owner)) this.finishDismiss_(true);
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 16 }) {
          Text('全局参数在前，版本参数在后；留空时只使用全局参数。')
            .fontSize(14).fontColor(this.theme.textSecondary).width('100%');
          if (this.loadError_.length > 0) {
            Column({ space: 12 }) {
              Text(this.loadError_).fontSize(14).fontColor(this.theme.errorText).width('100%')
                .id('version-jvm-load-error');
              Button('重新读取').height(48).fontSize(16).fontColor(this.theme.actionText)
                .backgroundColor(this.theme.primaryLight).enabled(!this.saving_ && !this.confirming_)
                .id('version-jvm-retry').onClick((): void => { this.load_(); });
            }.width('100%').padding(16).backgroundColor(this.theme.bgInput).borderRadius(16);
          } else {
            TextArea({ text: this.draft_, placeholder: '输入版本专属 JVM 参数' })
              .width('100%').height(208).fontSize(16).fontColor(this.theme.textPrimary)
              .placeholderColor(this.theme.textSecondary).caretColor(this.theme.actionText)
              .padding(16).backgroundColor(this.theme.bgInput).borderRadius(16)
              .enabled(this.loaded_ && !this.saving_ && !this.confirming_)
              .id('version-jvm-input').onChange((value: string): void => { this.changeDraft_(value); });
            Text('保留参数内部的空格与引号；保存时仅移除首尾空白。留空可清除此版本的专属参数。')
              .fontSize(14).fontColor(this.theme.textSecondary).width('100%');
            if (this.saving_) {
              Text('正在保存，请稍候…').fontSize(14).fontColor(this.theme.textSecondary).width('100%');
            } else if (this.isDirty_()) {
              Text('有尚未保存的更改').fontSize(14).fontColor(this.theme.actionText).width('100%')
                .id('version-jvm-dirty');
            }
          }
          if (this.saveError_.length > 0) {
            Text(this.saveError_).fontSize(14).fontColor(this.theme.errorText).width('100%')
              .id('version-jvm-save-error');
          }
        }.width('100%').padding(16);
      }.width('100%').layoutWeight(1).scrollBar(BarState.Auto);
      Row({ space: 12 }) {
        Button('取消').layoutWeight(1).height(48).fontSize(16).fontColor(this.theme.actionText)
          .backgroundColor(this.theme.primaryLight).enabled(!this.saving_ && !this.confirming_)
          .id('version-jvm-cancel').onClick((): void => { this.requestDismiss_(true); });
        Button(this.saving_ ? '保存中…' : '保存').layoutWeight(1).height(48).fontSize(16)
          .fontColor(this.theme.textOnPrimary).backgroundColor(this.theme.actionPrimary)
          .enabled(this.loaded_ && this.isDirty_() && !this.saving_ && !this.confirming_)
          .id('version-jvm-save').onClick((): void => { this.save_(); });
      }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: Math.max(16, this.bottomSafeHeight) });
    }.width('100%').height('100%');
  }
}
