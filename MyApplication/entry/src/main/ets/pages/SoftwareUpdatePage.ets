import { applyNativeTheme } from '../components/AppTheme';
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
  /** 同进程主题确认后重建本页快照；不触发业务重载、偏好写入或新的窗口订阅。 */
  @StorageProp('appThemeRevision') @Watch('applyTheme') private appThemeRevision: number = 0;
  @State private channel: string = 'stable';
  @State private checking: boolean = false;
  @State private importing: boolean = false;
  /** 初始操作已由下方按钮表达；仅检查、导入等真实操作产生反馈文字。 */
  @State private status: string = '';
  @State private candidate: UpdateManifest | undefined = undefined;
  @State private pending: boolean = false;
  /** 由系统实际版本名计算，安装开发者版不会把订阅偏好改成第三种通道。 */
  @State private developerInstalled: boolean = !UpdateChecker.automaticAllowed();
  private developerExitRequested: boolean = false;
  private requiredHostProtocol: number = 0;
  private requiredHostProtocols: number[] = [];
  private requirementValid: boolean = true;
  private runtimeIntentId: string | undefined = undefined;
  private context: common.UIAbilityContext = AppStorage.get<common.UIAbilityContext>('uiAbilityContext')!;
  private preferences: PreferenceManager = new PreferenceManager(this.context);
  private generation: number = 0;
  /** 用户选择次序独立于路由/网络代次；隐藏只取消网络投影，不撤销已提交的明确通道选择。 */
  private channelSelectionGeneration: number = 0;
  private visible: boolean = true;

  aboutToAppear(): void {
    this.channel=this.preferences.appUpdateChannel;this.applyTheme();
    const params=this.getUIContext().getRouter().getParams() as SideloadUpdatePageParams;
    this.runtimeIntentId=params?.runtimeIntentId;
    const required=params?.requiredHostProtocol;
    this.requiredHostProtocol=typeof required==='number' && Number.isInteger(required) && required>0 && required<=999 ? required : 0;
    const requirements=params?.requiredHostProtocols ?? (this.requiredHostProtocol>0 ? [this.requiredHostProtocol] : []);
    this.requirementValid=Array.isArray(requirements) && requirements.length<=8 && requirements.every((value: number,index: number): boolean =>
      Number.isInteger(value) && value>0 && value<=999 && requirements.indexOf(value)===index);
    if(this.requirementValid && this.requiredHostProtocol>0 && requirements.indexOf(this.requiredHostProtocol)<0)this.requirementValid=false;
    if(this.runtimeIntentId!==undefined && (typeof this.runtimeIntentId!=='string'||!new RegExp('^[0-9a-f]{32}$').test(this.runtimeIntentId)))this.requirementValid=false;
    this.requiredHostProtocols=this.requirementValid ? requirements.slice() : [];
    if(!this.requirementValid)this.status='JDK 更新要求无效，请返回运行时页重新选择。';
    if(this.requirementValid && this.requiredHostProtocols.length>0)this.status='所选 JDK 需要先更新 AMCL；将核对目标应用的兼容性。';
  }
  onPageShow(): void { this.applyTheme(); this.visible=true;this.developerInstalled=!UpdateChecker.automaticAllowed();this.syncConfirmedChannel();this.pending=!DistributionPolicy.isStore() && SideloadUpdateService.get(this.context).needsAttention();}
  onPageHide(): void {this.visible=false;this.generation++;this.checking=false;}
  aboutToDisappear(): void {this.visible=false;this.generation++;}
  private applyTheme(): void {
    const mode=this.preferences.themeMode;
    this.theme=resolveTheme(mode,resolveIsDark(mode,this.colorMode===ConfigurationConstant.ColorMode.COLOR_MODE_DARK),this.preferences.themeAccent);
    applyNativeTheme(this.theme);
  }
  /** 路由返回投影已确认偏好；开发版明确退出的临时目标仍由本页持有，直到原安装完成。 */
  private syncConfirmedChannel(): void {
    if(this.developerInstalled&&this.developerExitRequested)return;
    const confirmed=this.preferences.appUpdateChannel;
    if(this.channel!==confirmed){this.channel=confirmed;this.candidate=undefined;}
  }
  /** 点击切换只改变后续订阅，不撤销正在执行的事务，也不触发降级。 */
  private async chooseChannel(value: string): Promise<void> {
    // 重新点当前通道也是明确的后来选择，须推进代次，防旧完成步骤随后改回另一个订阅。
    if(DistributionPolicy.isStore() || this.importing) return;
    const generation=++this.generation,selection=++this.channelSelectionGeneration;this.candidate=undefined;this.checking=true;
    try {await this.preferences.selectAppUpdateChannel(value);if(selection!==this.channelSelectionGeneration)return;
      this.channel=this.preferences.appUpdateChannel;if(generation!==this.generation)return;}
    catch(error){if(generation===this.generation)this.status=(error as Error).message;return;}
    finally{if(generation===this.generation)this.checking=false;}
    this.preferences.resetAppUpdateCheck(ProductBuildProfile.product,value);
    if (!this.developerInstalled) this.check();
  }
  /** 明确离开开发者版才请求公开头；该动作同时明确选择成功退出后的 stable/preview 订阅。 */
  private exitDeveloper(channel: string): void {
    if (this.importing || this.checking || !this.developerInstalled) return;
    this.channelSelectionGeneration++;this.developerExitRequested=true; this.channel=channel;
    this.preferences.resetAppUpdateCheck(ProductBuildProfile.product,channel); this.check();
  }
  private async check(): Promise<void> {
    if(this.importing || DistributionPolicy.isStore() || !this.requirementValid) return;
    if(this.developerInstalled && !this.developerExitRequested) return;
    const generation=++this.generation, channel=this.channel;
    this.checking=true;this.candidate=undefined;this.status='检查中…';
    try {
      const result=await UpdateChecker.checkForUpdate(undefined,ProductBuildProfile.product,channel,this.developerExitRequested);
      if(!this.visible || generation!==this.generation || channel!==this.channel) return;
      if(!result.ok || result.manifest===null) {this.status=result.error || '暂时无法取得更新信息，请稍后重试。';return;}
      if(!UpdateChecker.supportsHosts(result.manifest,ProductBuildProfile.product,this.requiredHostProtocols)) {
        this.status='当前通道尚无支持所选 JDK 的 AMCL；可明确选择预览通道查看，或等待后续正式版。';return;
      }
      this.candidate=result.manifest;
      if (!this.developerInstalled) this.preferences.rememberAppUpdate(ProductBuildProfile.product,channel,result.manifest.versionCode,UpdateChecker.targetKey(result.manifest,ProductBuildProfile.product));
      // 候选卡已经完整列出目标版本；这里仅反馈结论，避免在品牌行重复长版本名。
      this.status=result.hasUpdate ? (UpdateChecker.isStableReturn(result.manifest)?'可返回正式版':'有新版本') : result.current>result.manifest.versionCode ?
        '当前版本高于通道推荐，后续将接收此通道的新版本。' : '已是最新';
    } catch(error) {if(this.visible && generation===this.generation)this.status='检查失败：'+(error as Error).message;}
    finally {if(generation===this.generation)this.checking=false;}
  }
  /** 当前候选在跳转前再次核对通道。路由只传公开清单，下载及安装仍复用既有流程。 */
  private startUpdate(): void {
    // store暂停应用自更新，旧页面或缓存候选不能绕过入口隐藏。
    if (DistributionPolicy.isStore() || !this.requirementValid) return;
    const manifest=this.candidate;
    if(manifest===undefined || !UpdateChecker.canInstall(manifest,this.channel) || this.checking || this.importing) return;
    const params: SideloadUpdatePageParams={manifest:manifest,autoStart:true,requiredHostProtocol:this.requiredHostProtocol,requiredHostProtocols:this.requiredHostProtocols.slice(),runtimeIntentId:this.runtimeIntentId};
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
    if(this.importing || this.checking || DistributionPolicy.isStore() || !this.requirementValid) return;
    const generation=++this.generation, channel=this.channel;
    this.importing=true;this.status='请选择从 GitHub 或官网开发者构建下载的原始未签名 HAP。';
    const owner=SideloadUpdateService.get(this.context);
    try {
      const document=new picker.DocumentViewPicker(this.context);
      const files=await document.select({maxSelectNumber:1,fileSuffixFilters:['HarmonyOS 安装包|.hap']});
      if(files.length===0) {if(generation===this.generation)this.status='已取消选择安装包。';return;}
      if(!this.visible || generation!==this.generation) return;
      this.status='正在核对安装包与官方发布记录…';
      const prepared=await owner.preparePickedPackage(files[0],channel,this.requiredHostProtocol,this.requiredHostProtocols);
      if(!this.visible || generation!==this.generation || channel!==this.channel) {owner.discardPreparedPackage(prepared.token);return;}
      const params: SideloadUpdatePageParams={manifest:prepared.manifest,importToken:prepared.token,autoStart:true,requiredHostProtocol:this.requiredHostProtocol,requiredHostProtocols:this.requiredHostProtocols.slice(),runtimeIntentId:this.runtimeIntentId};
      try {await this.getUIContext().getRouter().pushUrl({url:'pages/SideloadUpdatePage',params:params});}
      catch(error) {owner.discardPreparedPackage(prepared.token);throw error as Error;}
    } catch(error) {if(this.visible && generation===this.generation)this.status=(error as Error).message;}
    finally {this.importing=false;}
  }

  /** 窄窗口可能省略长预览版号；点击版本可核对完整包身份，不发起检查或更新。 */
  private showCurrentVersion_(): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '当前应用版本', message: 'AMCL v' + (UpdateChecker.currentVersionName() || APP_VERSION),
      buttons: [{ text: '关闭', color: this.theme.actionText as string }],
    }).catch((): void => { /* 点击框外或返回仅关闭版本信息。 */ });
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
            // 短状态与版本同排；较长的错误和操作结果仍完整显示，避免省略故障原因。
            Row({space:12}) {
              Button({type:ButtonType.Normal}) {
                Text('AMCL v'+(UpdateChecker.currentVersionName() || APP_VERSION)).fontSize(20).fontWeight(600)
                  .fontColor(this.theme.textPrimary).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis})
                  .ellipsisMode(EllipsisMode.CENTER)
              }.layoutWeight(1).height(44).padding(0).backgroundColor(Color.Transparent)
                .accessibilityText('查看当前应用的完整版本号').onClick((): void=>{this.showCurrentVersion_();})
              if(this.status.length>0 && this.status.length<=10) {
                Text(this.status).fontSize(13).fontColor(this.theme.textSecondary).constraintSize({maxWidth:144})
              }
            }.width('100%').alignItems(VerticalAlign.Center)
            if(this.status.length>10) {
              Text(this.status).fontSize(14).fontColor(this.theme.textSecondary).width('100%')
            }
          }.width('100%').padding(24).backgroundColor(this.theme.bgCard).borderRadius(20)
          if(DistributionPolicy.isStore()) {
            Text('此版本通过应用市场更新。').fontSize(14).fontColor(this.theme.textSecondary)
          } else {
            if(this.developerInstalled) {
              Column({space:12}) {
                Text('当前为开发者版，应用自动检查已暂停。原订阅保持不变，JDK 更新独立工作。')
                  .fontSize(14).fontColor(this.theme.textSecondary).width('100%')
                Button('返回正式版').height(44).width('100%').enabled(!this.importing && !this.checking)
                  .onClick((): void=>{this.exitDeveloper('stable');})
                Button('转入预览版').height(44).width('100%').enabled(!this.importing && !this.checking)
                  .onClick((): void=>{this.exitDeveloper('preview');})
              }.width('100%').padding(20).backgroundColor(this.theme.bgCard).borderRadius(20)
            }
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
              Button(this.checking?'正在检查…':'检查更新').height(44).width('100%').enabled(!this.checking && !this.importing && !this.developerInstalled)
                .backgroundColor(this.theme.bgInput).fontColor(this.theme.actionText).onClick((): void=>{this.check();})
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
              Text('自行下载 GitHub 正式/预览原件，或官网开发者原件后，在这里选择未签名 HAP。核对通过后继续授权、签名和安装。')
                .fontSize(14).fontColor(this.theme.textSecondary).width('100%')
              Button('前往 GitHub 下载').height(44).width('100%').backgroundColor(this.theme.bgInput).fontColor(this.theme.actionText)
                .enabled(!this.importing).onClick((): void=>{this.openGithub();})
              Button(this.importing?'正在核对安装包…':'选择本地安装包').height(44).width('100%')
                .backgroundColor(this.theme.bgInput).fontColor(this.theme.actionText).enabled(!this.importing && !this.checking)
                .onClick((): void=>{this.importPackage();})
            }.width('100%').padding(20).backgroundColor(this.theme.bgCard).borderRadius(20)
            if(this.pending) {
              Button('查看上次更新').height(44).width('100%').backgroundColor(this.theme.bgCard).fontColor(this.theme.actionText)
                .onClick((): void=>{this.getUIContext().getRouter().pushUrl({url:'pages/SideloadUpdatePage',params:{autoStart:false}});})
            }
          }
        }.width('100%').constraintSize({maxWidth:680}).padding({left:20,right:20,top:8,bottom:this.bottomSafe+24})
      }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
      }
}
