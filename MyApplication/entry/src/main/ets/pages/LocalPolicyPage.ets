/**
 * 随包政策与许可阅读页：只展示已核对的 UTF-8 本地文本，不创建 Web、外链或远程更新请求。
 * 首启隐私弹窗和日志分享说明复用此路由；返回后仍由原页面决定是否取得同意。
 * policy 仅选择固定资源白名单，不将路由参数拼成文件名，避免历史路由读取任意资源。
 */
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { ThemeColors, ThemeMode, resolveTheme, resolveIsDark } from 'commons';
import { PreferenceManager } from 'feature_system';
import { ImmersiveTitleScaffold } from '../components/ImmersiveTitleScaffold';

@Entry
@Component
struct LocalPolicyPage {
  @StorageProp('topRectHeight') private topSafeHeight: number = 0;
  @StorageProp('bottomRectHeight') private bottomSafeHeight: number = 0;
  @StorageProp('currentColorMode') @Watch('applyTheme_') private colorMode: number = 0;
  @State private theme: ThemeColors = resolveTheme(ThemeMode.SYSTEM, false);
  @State private title: string = '隐私政策';
  @State private body: string = '';
  @State private loading: boolean = true;
  @State private errorText: string = '';
  private generation: number = 0;
  private context: common.UIAbilityContext = AppStorage.get<common.UIAbilityContext>('uiAbilityContext')!;
  private preferences: PreferenceManager = new PreferenceManager(this.context);

  /** 使用项目原有主题与系统安全区；不建立另一套窗口监听或修改首启同意状态。 */
  aboutToAppear(): void { this.applyTheme_(); }
  onPageShow(): void { this.load_(); }
  aboutToDisappear(): void { this.generation++; }
  private applyTheme_(): void {
    const dark = this.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.theme = resolveTheme(this.preferences.themeMode, resolveIsDark(this.preferences.themeMode, dark));
  }

  /** 异步读取固定随包文本；晚到结果不更新已销毁页面，失败只允许本地重试，不提供网页兜底。 */
  private async load_(): Promise<void> {
    const current = ++this.generation;
    // 路由键使用字面字符串访问，避免 store release 混淆接口属性后与序列化参数名不一致。
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object> | undefined;
    let policy = 'privacy';
    if (params !== undefined && params !== null && typeof params['policy'] === 'string') policy = params['policy'] as string;
    let filename = 'privacy.txt';
    if (policy === 'logshare') { filename = 'logshare-privacy.txt'; this.title = '日志分享隐私说明'; }
    else if (policy === 'license') { filename = 'licenses.txt'; this.title = '许可与致谢'; }
    else this.title = '隐私政策';
    this.loading = true;
    this.errorText = '';
    try {
      const bytes = await this.context.resourceManager.getRawFileContent('store-policies/' + filename);
      const text = util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(bytes);
      if (text.trim().length === 0) throw new Error('本地正文为空');
      if (current === this.generation) this.body = text;
    } catch (_) {
      if (current === this.generation) this.errorText = '本地说明读取失败，请重试。';
    } finally { if (current === this.generation) this.loading = false; }
  }

  build() {
    Column() {
      // 政策仍只本地读取；共享返回不写入任何同意状态，也不引入外链。
      ImmersiveTitleScaffold({ title: this.title, theme: this.theme, topSafeHeight: this.topSafeHeight,
        surfaceColor: this.theme.bgPrimary, onBack: (): void => { this.getUIContext().getRouter().back(); },
        content: (): void => { this.ImmersiveTitleContent1_(); }
      })
    }
      .width('100%').height('100%').backgroundColor(this.theme.bgPrimary)
  }

  /** 保留原正文的父组件状态与业务回调；具名content只转调此真正@Builder，避免this漂移。 */
  @Builder
  private ImmersiveTitleContent1_() {
      Column({ space: 12 }) {
      if (this.loading) {
        Text('正在读取本地说明…').fontColor(this.theme.textSecondary).layoutWeight(1)
      } else if (this.errorText.length > 0) {
        Column({ space: 12 }) {
          Text(this.errorText).fontColor(this.theme.error)
          Button('重试').height(44).onClick(() => { this.load_(); })
        }.layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          // Text 不解析 HTML/Markdown，正文中的网址仅作来源标识，不变成一般网页动作。
          Text(this.body).fontSize(14).lineHeight(23).fontColor(this.theme.textPrimary)
            .width('100%').copyOption(CopyOptions.LocalDevice)
        }.layoutWeight(1).width('100%').scrollBar(BarState.Auto)
      }
      }.padding({ left: 16, right: 16, top: 12, bottom: this.bottomSafeHeight + 12 })
        .width('100%').height('100%')
      }
}
