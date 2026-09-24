/**
 * PrivacyConsentDialog.ets — 开屏隐私政策同意弹窗（上架合规）
 *
 * 上架（华为应用市场 / AG）要求：用户首次启动须先阅读并同意隐私政策方可使用。
 * 由产品层 Index 在 aboutToAppear 判定（未同意 → 盖一层全屏遮罩弹窗）。
 *   - 「同意并继续」：落盘 privacyAgreed=true，关闭弹窗，正常进入。
 *   - 「不同意并退出」：终止应用（terminateSelf）。
 *   - 「隐私政策」「用户协议」内链：用系统浏览器打开 GitHub Pages 上的完整政策。
 *
 * 纯展示组件：状态（是否已同意）与持久化由 Index + PreferenceManager 管，
 * 本组件只发 onAgree / onDisagree 回调 + 自己负责打开浏览器。
 */

import { common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ThemeColors } from 'commons';
import { PRIVACY_POLICY_URL, BRAND_DISCLAIMER } from 'commons';

const TAG = 'PrivacyConsentDialog';

@Component
export struct PrivacyConsentDialog {
  @Prop theme: ThemeColors = {} as ThemeColors;
  onAgree: () => void = () => {};
  onDisagree: () => void = () => {};

  private openPolicy(): void {
    try {
      let ctx = AppStorage.get<common.UIAbilityContext>('uiAbilityContext');
      if (!ctx) return;
      let want: Want = {
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: PRIVACY_POLICY_URL,
      };
      ctx.startAbility(want);
    } catch (e) {
      hilog.error(0x0000, TAG, 'open policy failed: %{public}s', (e as BusinessError).message);
      try {
        this.getUIContext().getPromptAction().showToast({ message: '无法打开浏览器，请手动访问 ' + PRIVACY_POLICY_URL, duration: 2500 });
      } catch (_) { /* */ }
    }
  }

  build() {
    // 全屏遮罩，拦截一切点击（必须先决策）
    Column() {
      Column() {
        Text('隐私政策与用户协议')
          .fontSize(19).fontWeight(700).fontColor(this.theme.textPrimary)
          .margin({ bottom: 14 })

        Scroll() {
          Column({ space: 10 }) {
            Text('欢迎使用 AMCL。在使用前，请阅读并同意我们的隐私政策。')
              .fontSize(14).fontColor(this.theme.textPrimary).width('100%')

            Text('我们恪守"最小必要"原则：AMCL 没有自有数据服务器，不收集设备标识、位置、通讯录等个人信息，不做任何行为埋点或广告。仅在你主动使用时，与 Microsoft / Mojang / GitHub 等官方服务器直接通信以完成正版登录与游戏文件下载。账户凭据仅以 HUKS 加密存储在本机沙箱。')
              .fontSize(13).fontColor(this.theme.textSecondary).lineHeight(20).width('100%')

            Text('为运行内嵌的 OpenJDK，本应用在平板 / 2in1 设备上申请「可写可执行内存（JIT）」系统权限（ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY，静默授予、不弹窗），用于提升 Java 运行效率。')
              .fontSize(13).fontColor(this.theme.textSecondary).lineHeight(20).width('100%')

            // 品牌免责声明（知识产权合规，首屏显著展示）
            Text(BRAND_DISCLAIMER)
              .fontSize(13).fontWeight(600).fontColor(this.theme.textPrimary).lineHeight(20).width('100%')
              .padding(10)
              .borderRadius(10)
              .backgroundColor(this.theme.bgInput)

            Row({ space: 4 }) {
              Text('点击查看：').fontSize(13).fontColor(this.theme.textSecondary)
              Text('完整隐私政策')
                .fontSize(13).fontWeight(600).fontColor(this.theme.primary)
                .decoration({ type: TextDecorationType.Underline, color: this.theme.primary })
                .onClick(() => { this.openPolicy() })
            }
            .width('100%')
            .margin({ top: 2 })
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .width('100%')

        Row({ space: 12 }) {
          Button('不同意并退出')
            .type(ButtonType.Capsule).height(42).fontSize(15).layoutWeight(1)
            .fontColor(this.theme.textSecondary).backgroundColor(this.theme.bgInput)
            .onClick(() => { this.onDisagree() })
          Button('同意并继续')
            .type(ButtonType.Capsule).height(42).fontSize(15).fontWeight(600).layoutWeight(1)
            .fontColor(this.theme.textOnPrimary).backgroundColor(this.theme.primary)
            .onClick(() => { this.onAgree() })
        }
        .width('100%')
        .margin({ top: 16 })
      }
      .width('86%')
      .constraintSize({ maxHeight: '70%' })
      .padding(22)
      .backgroundColor(this.theme.bgCard)
      .borderRadius(20)
      .shadow({ radius: 24, color: '#40000000', offsetX: 0, offsetY: 6 })
    }
    .width('100%')
    .height('100%')
    .position({ x: 0, y: 0 })
    .backgroundColor('#99000000')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
