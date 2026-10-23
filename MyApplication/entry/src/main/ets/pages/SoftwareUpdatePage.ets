/**
 * 软件更新的持久入口：选择 App 通道、检查推荐、下载与导入官方原始 HAP。
 * 本页仅持展示与文件选择生命周期；授权、签名、安装和恢复由既有 Coordinator 执行。
 */
import { common, ConfigurationConstant, Want } from '@kit.AbilityKit';
import { ImmersiveTitleScaffold } from '../components/ImmersiveTitleScaffold';
import { picker } from '@kit.CoreFileKit';
import { APP_VERSION, DistributionPolicy, ThemeColors, ThemeMode, resolveTheme, resolveIsDark, formatBytes } from 'commons';
import { PreferenceManager } from 'feature_system';
import { UpdateChecker, UpdateManifest } from 'update';
import { ProductBuildProfile } from 'entry/ProductBuildProfile';
import { SideloadUpdateService } from '../sideload/SideloadUpdateService';
import { SideloadUpdatePageParams } from '../sideload/SideloadUpdateViewModel';

@Entry
@Component
struct SoftwareUpdatePage {
  @State private theme: ThemeColors = resolveTheme(ThemeMode.SYSTEM,false);
  @StorageProp('topRectHeight') private topSafe: number = 0;
  @StorageProp('bottomRectHeight') private bottomSafe: number = 0;
  @StorageProp('currentColorMode') @Watch('applyTheme') private colorMode: number = 0;
  @State private channel: string = 'stable';
  @State private checking: boolean = false;
  @State private importing: boolean = false;
  @State private status: string = '检查当前通道的新版本，或选择自己下载的安装包。';
  @State private candidate: UpdateManifest | undefined = undefined;
  @State private pending: boolean = false;
  private context: common.UIAbilityContext = AppStorage.get<common.UIAbilityContext>('uiAbilityContext')!;
  private preferences: PreferenceManager = new PreferenceManager(this.context);
  private generation: number = 0;
  private visible: boolean = true;

  aboutToAppear(): void {this.channel=this.preferences.appUpdateChannel;this.applyTheme();}
  onPageShow(): void {this.visible=true;this.pending=!DistributionPolicy.isStore() && SideloadUpdateService.get(this.context).needsAttention();}
  onPageHide(): void {this.visible=false;this.generation++;this.checking=false;}
  aboutToDisappear(): void {this.visible=false;this.generation++;}
  private applyTheme(): void {
    const mode=this.preferences.themeMode;
    this.theme=resolveTheme(mode,resolveIsDark(mode,this.colorMode===ConfigurationConstant.ColorMode.COLOR_MODE_DARK));
  }
  /** 点击切换只改变后续订阅，不撤销正在执行的事务，也不触发降级。 */
  private chooseChannel(value: string): void {
    if(DistributionPolicy.isStore() || this.importing || this.channel===value) return;
    this.generation++;this.channel=value;this.preferences.appUpdateChannel=value;this.candidate=undefined;
    this.preferences.resetAppUpdateCheck(ProductBuildProfile.product,value);
    this.check();
  }
  private async check(): Promise<void> {
    if(this.importing || DistributionPolicy.isStore()) return;
    const generation=++this.generation, channel=this.channel;
    this.checking=true;this.candidate=undefined;this.status='正在检查'+(channel==='preview'?'测试':'稳定')+'通道…';
    try {
      const result=await UpdateChecker.checkForUpdate(undefined,ProductBuildProfile.product,channel);
      if(!this.visible || generation!==this.generation || channel!==this.channel) return;
      if(!result.ok || result.manifest===null) {this.status=result.error || '暂时无法取得更新信息，请稍后重试。';return;}
      this.candidate=result.manifest;
      this.preferences.rememberAppUpdate(ProductBuildProfile.product,channel,result.manifest.versionCode,UpdateChecker.targetKey(result.manifest,ProductBuildProfile.product));
      this.status=result.hasUpdate ? (UpdateChecker.isStableReturn(result.manifest)?'可返回正式版 v':'发现新版本 v')+result.manifest.versionName : result.current>result.manifest.versionCode ?
        '当前版本高于通道推荐，后续将接收此通道的新版本。' : '当前已是此通道的最新版本。';
    } catch(error) {if(this.visible && generation===this.generation)this.status='检查失败：'+(error as Error).message;}
    finally {if(generation===this.generation)this.checking=false;}
  }
  /** 当前候选在跳转前再次核对通道。路由只传公开清单，下载及安装仍复用既有流程。 */
  private startUpdate(): void {
    // store暂停应用自更新，旧页面或缓存候选不能绕过入口隐藏。
    if (DistributionPolicy.isStore()) return;
    const manifest=this.candidate;
    if(manifest===undefined || !UpdateChecker.canInstall(manifest,this.channel) || this.checking || this.importing) return;
    const params: SideloadUpdatePageParams={manifest:manifest,autoStart:true};
    this.getUIContext().getRouter().pushUrl({url:'pages/SideloadUpdatePage',params:params});
  }
  private openGithub(): void {
    // 网页兜底也受渠道约束，不能因旧路由重入而恢复浏览器下载。
    if (DistributionPolicy.isStore()) return;
    const url=this.candidate?.url || ('https://github.com/LZZLHY/amcl/releases'+(this.channel==='stable'?'/latest':''));
    const want: Want={action:'ohos.want.action.viewData',entities:['entity.system.browsable'],uri:url};
    this.context.startAbility(want).catch((): void=>{this.status='暂时无法打开浏览器，请稍后重试。';});
  }
  /** 系统选择器权限只用于读取；页面离开后即使预检完成也不自动签名或安装。 */
  private async importPackage(): Promise<void> {
    if(this.importing || this.checking || DistributionPolicy.isStore()) return;
    const generation=++this.generation, channel=this.channel;
    this.importing=true;this.status='请选择从 GitHub 下载的原始未签名 HAP。';
    const owner=SideloadUpdateService.get(this.context);
    try {
      const document=new picker.DocumentViewPicker(this.context);
      const files=await document.select({maxSelectNumber:1,fileSuffixFilters:['HarmonyOS 安装包|.hap']});
      if(files.length===0) {if(generation===this.generation)this.status='已取消选择安装包。';return;}
      if(!this.visible || generation!==this.generation) return;
      this.status='正在核对安装包与官方发布记录…';
      const prepared=await owner.preparePickedPackage(files[0],channel);
      if(!this.visible || generation!==this.generation || channel!==this.channel) {owner.discardPreparedPackage(prepared.token);return;}
      const params: SideloadUpdatePageParams={manifest:prepared.manifest,importToken:prepared.token,autoStart:true};
      try {await this.getUIContext().getRouter().pushUrl({url:'pages/SideloadUpdatePage',params:params});}
      catch(error) {owner.discardPreparedPackage(prepared.token);throw error as Error;}
    } catch(error) {if(this.visible && generation===this.generation)this.status=(error as Error).message;}
    finally {this.importing=false;}
  }

  build() {
    Column() {
      // 返回只退出本路由；检查、选择安装包和进行中的更新仍由原业务持有。
      ImmersiveTitleScaffold({ title: '软件更新', theme: this.theme, topSafeHeight: this.topSafe,
        surfaceColor: this.theme.bgPrimary, backLabel: '返回设置',
        onBack: (): void => { this.getUIContext().getRouter().back(); },
        content: (): void => { this.ImmersiveTitleContent1_(); }
      })
    }.width('100%').height('100%').backgroundColor(this.theme.bgPrimary)
  }

  /** 保留原正文的父组件状态与业务回调；具名content只转调此真正@Builder，避免this漂移。 */
  @Builder
  private ImmersiveTitleContent1_() {
      Scroll() {
        Column({space:20}) {
          Column({space:12}) {
            Image($r('app.media.amcl_axe')).width(64).height(64).borderRadius(16).draggable(false)
            Text('AMCL v'+(UpdateChecker.currentVersionName() || APP_VERSION)).fontSize(24).fontWeight(600).fontColor(this.theme.textPrimary)
            Text(this.status).fontSize(14).fontColor(this.theme.textSecondary).textAlign(TextAlign.Center).width('100%')
          }.width('100%').padding(24).backgroundColor(this.theme.bgCard).borderRadius(20)
          if(DistributionPolicy.isStore()) {
            Text('此版本通过应用市场更新。').fontSize(14).fontColor(this.theme.textSecondary)
          } else {
            Column({space:12}) {
              Text('更新通道').fontSize(18).fontWeight(600).fontColor(this.theme.textPrimary).width('100%')
              Row({space:8}) {
                Button(this.channel==='stable'?'稳定版 ✓':'稳定版').layoutWeight(1).height(44)
                  .backgroundColor(this.channel==='stable'?this.theme.primary:this.theme.bgInput)
                  .fontColor(this.channel==='stable'?this.theme.textOnPrimary:this.theme.textPrimary)
                  .enabled(!this.importing).onClick((): void=>{this.chooseChannel('stable');})
                Button(this.channel==='preview'?'预览版 ✓':'预览版').layoutWeight(1).height(44)
                  .backgroundColor(this.channel==='preview'?this.theme.primary:this.theme.bgInput)
                  .fontColor(this.channel==='preview'?this.theme.textOnPrimary:this.theme.textPrimary)
                  .enabled(!this.importing).onClick((): void=>{this.chooseChannel('preview');})
              }.width('100%')
              Text(this.channel==='preview'?'接收预览版和后续正式版。预览版可能存在尚未解决的问题，可切回稳定通道查看可返回的正式版。':'接收正式版本。预览版沿用相同安装编号时，可在此选择返回正式版；切换通道不会立即安装。')
                .fontSize(12).fontColor(this.theme.textHint).width('100%')
              Button(this.checking?'正在检查…':'检查更新').height(44).width('100%').enabled(!this.checking && !this.importing)
                .backgroundColor(this.theme.bgInput).fontColor(this.theme.primary).onClick((): void=>{this.check();})
            }.width('100%').padding(20).backgroundColor(this.theme.bgCard).borderRadius(20)
            if(this.candidate!==undefined && UpdateChecker.canInstall(this.candidate,this.channel)) {
              Column({space:12}) {
                Text((UpdateChecker.isStableReturn(this.candidate)?'返回正式版 v':'新版本 v')+this.candidate.versionName).fontSize(18).fontWeight(600).fontColor(this.theme.textPrimary).width('100%')
                Text(this.candidate.notes).fontSize(14).fontColor(this.theme.textSecondary).width('100%')
                if(this.candidate.sizeBytes>0) {Text(formatBytes(this.candidate.sizeBytes)).fontSize(12).fontColor(this.theme.textHint).width('100%')}
                Button(UpdateChecker.isStableReturn(this.candidate)?'返回此正式版':'立即更新').height(48).width('100%').backgroundColor(this.theme.primary).fontColor(this.theme.textOnPrimary)
                  .enabled(!this.importing && !this.checking).onClick((): void=>{this.startUpdate();})
              }.width('100%').padding(20).backgroundColor(this.theme.bgCard).borderRadius(20)
            }
            Column({space:12}) {
              Text('手动更新').fontSize(18).fontWeight(600).fontColor(this.theme.textPrimary).width('100%')
              Text('自行下载官方未签名 HAP 后，在这里选择文件。核对通过后继续授权、签名和安装。')
                .fontSize(14).fontColor(this.theme.textSecondary).width('100%')
              Button('前往 GitHub 下载').height(44).width('100%').backgroundColor(this.theme.bgInput).fontColor(this.theme.primary)
                .enabled(!this.importing).onClick((): void=>{this.openGithub();})
              Button(this.importing?'正在核对安装包…':'选择本地安装包').height(44).width('100%')
                .backgroundColor(this.theme.bgInput).fontColor(this.theme.primary).enabled(!this.importing && !this.checking)
                .onClick((): void=>{this.importPackage();})
            }.width('100%').padding(20).backgroundColor(this.theme.bgCard).borderRadius(20)
            if(this.pending) {
              Button('查看上次更新').height(44).width('100%').backgroundColor(this.theme.bgCard).fontColor(this.theme.primary)
                .onClick((): void=>{this.getUIContext().getRouter().pushUrl({url:'pages/SideloadUpdatePage',params:{autoStart:false}});})
            }
          }
        }.width('100%').constraintSize({maxWidth:680}).padding({left:20,right:20,top:8,bottom:this.bottomSafe+24})
      }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
      }
}
