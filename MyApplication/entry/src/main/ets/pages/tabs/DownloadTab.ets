/**
 * 呈现颜色遵循父层主题快照：操作文字与焦点独立于按钮填充，状态小字独立于进度填充。
 * 本域不读取主题偏好，不改变原事件、任务或账户生命周期；资源类别与第三方品牌保持独立。
 */
/**
 * 下载Tab承载版本、模组、光影、资源包、整合包与JDK六分类的固定导航。
 * 四资源共用受控ModBrowsePage；版本筛选与JDK目录由DownloadAuxiliaryList管理退让，
 * 搜索与顶层导航留在滚动宿主外。
 * 本组件只展示并转发业务意图，不自动创建下载任务，也不拥有后台任务生命周期。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
// 2026-05-24：FloatingDock 占高预留
import { floatingDockReserveHeight } from 'commons';
import { router, promptAction } from '@kit.ArkUI';
import { ThemeColors } from 'commons';
import { McVersionService, McVersion } from 'feature_core';
import { JdkManager, JdkVersionInfo } from 'launch';
import { ModBrowsePage } from '../ModBrowsePage';
// v6.5：ModDlState 不再需要（ModBrowsePage 改为 registry.enqueue）
import { AppIconName } from 'commons';
import { AppIcon } from '../../components/AppIcon';
import { VersionBlockIcon } from '../../components/VersionBlockIcon';
import { classifyVersion, VersionCategory } from 'mods';
import { DownloadAuxiliaryList } from '../../components/DownloadAuxiliaryList';
import { DownloadSearchField } from '../../components/DownloadSearchField';

// 顶级 Tab 元数据（与设计稿对齐：6 个一字排开）
interface DlTabMeta {
  idx: number
  icon: AppIconName
  label: string
}
const DL_TABS: DlTabMeta[] = [
  { idx: 0, icon: AppIconName.Game,         label: '版本' },
  { idx: 1, icon: AppIconName.Mod,          label: '模组' },
  { idx: 2, icon: AppIconName.Shader,       label: '光影' },
  { idx: 3, icon: AppIconName.ResourcePack, label: '资源包' },
  { idx: 4, icon: AppIconName.ModPack,      label: '整合包' },
  { idx: 5, icon: AppIconName.Java,         label: 'JDK' },
]

@Component
export struct DownloadTab {
  @Prop theme: ThemeColors = {} as ThemeColors
  /** 原生主Tab保留组件时，由Index透传可见性，阻止后台动画续播。 */
  @Prop hostVisible: boolean = true
  @Prop topSafeHeight: number = 0
  @Prop bottomSafeHeight: number = 0
  /** 手机横屏：true 时分类页签走左侧竖向侧边栏，右侧给内容/模组列表更宽空间。 */
  @Prop isLandscape: boolean = false

  // JDK 状态
  @Prop jdkVersions: JdkVersionInfo[] = []
  @Prop jdkDownloadMsg: string = ''
  @Prop jdkDownloadPercent: number = 0
  /** 由首页统一管理目录状态，下载页直接显示并复用同一检查入口，不自行发网络请求。 */
  @Prop jdkChannel: string = 'stable'
  @Prop jdkChecking: boolean = false
  @Prop jdkCatalogStatus: string = ''
  onRefreshJdkCatalog: () => void = () => {}

  // P1-MODS Phase 1.7：模组浏览页依赖
  @Prop mcDir: string = ''
  /** JDK 行据此重新读取任务状态，切换按钮可用性。 */
  @Prop taskRevision: number = 0
  @Prop currentMcVersion: string = ''
  @Prop versionIsolation: boolean = true
  // P0 修复 #4：传给 ModBrowsePage 用于版本存在性校验
  @Prop availableVersions: string[] = []
  // P1-MODS 用户偏好透传（'auto'/'mcim'/'official'）
  @Prop modSource: string = 'auto'
  // 是否启用元数据缓存（false 时 ModBrowsePage 退化为无缓存请求）
  @Prop cacheRemoteMeta: boolean = true

  /**
   * 受控二级 Tab 导航命令（Index 透传）。编码 = 递增 nonce × 10 + 目标子页序号。
   *   目标子页序号：0=版本 / 1=模组 / 2=光影 / 3=资源包 / 4=整合包 / 5=JDK
   * 用 nonce × 10 是为了让"连续两次跳到同一子页"也能让 @Prop 值发生变化，从而触发 @Watch。
   * 父组件在切到下载 Tab 的同时 bump 此值，本组件把 `dlSubTab` 定位到目标子页。
   * -1 = 无命令（初始态，不动内部 tab，保留用户手动选择）。
   */
  @Prop @Watch('onNavCommand') navCommand: number = -1

  // 下载页内部状态
  @State dlSubTab: number = 0
  @State mcVersionList: McVersion[] = []
  @State mcVersionsLoading: boolean = false
  @State mcVersionsError: string = ''
  /**
   * 版本筛选 chips —— 4 个独立 boolean，全部可单独切换 / 任意组合，**约束至少选一个**。
   *
   * 默认：仅正式版。这条线对齐 PCL2 / HMCL 默认行为，避免新手第一次进来就被一堆
   * 23w12a / b1.7.3 / 24w14potato 淹没。
   *
   * 至少选一个：handleFilterToggle 里做 guard —— 当前 chip 取消后会让所有都为 false
   * 时直接 return，UI 不变化。
   */
  @State filterRelease: boolean = true
  @State filterSnapshot: boolean = false
  @State filterOld: boolean = false
  @State filterAprilFools: boolean = false
  @State versionSearch: string = ''
  /** 输入焦点期间保持全部筛选可见，不把键盘编辑当作列表浏览。 */
  @State private versionSearchFocused_: boolean = false
  /** 显式进入版本配置或JDK操作时复位旧展示方向，业务任务仍由原父回调管理。 */
  @State private versionActionEpoch_: number = 0
  @State private jdkActionEpoch_: number = 0
  private mcVersionService: McVersionService = new McVersionService()

  // 回调
  /**
   * 选中某版本。第 2 参数是 manifest type 推出的子类别
   * （'release' / 'snapshot' / 'aprilfools' / 'old'），由 mcVersionToCategory(v) 产出。
   *
   * 加这个参数是为了修 bug：'26.2-snapshot-8' 裸关键字名的快照被
   * VersionConfigPanel.classifyVersion 误判为 release，透传准确类别避免重复推断。
   */
  onSelectGameVersion: (ver: string, category: string) => void = () => {}
  onJdkDelete: (version: string) => void = () => {}
  onJdkDownload: (version: string) => void = () => {}
  /** 「更新」：与下载走同一条任务链，但强制重装（否则会被幂等门吞掉，见 JdkInstaller）。 */
  onJdkUpdate: (version: string) => void = () => {}
  /** 「从本地压缩包导入」：由 entry 层弹文件选择器 + 选目标槽位。 */
  onJdkImport: () => void = () => {}
  /** 导入进行中（导入不走 registry，故单独一个标志）。 */
  @Prop jdkImporting: boolean = false
  // B-1 修复（2026-05-26）：按版本查询，让 17 / 21 能并发；
  // 同版本重复点击仍会被 registry 用 id='jdk:'+version 拒绝
  isJdkDownloading: (version: string) => boolean = (_v: string) => false
  onModStatusMessage: (msg: string) => void = () => {}
  onOpenDownloadTask: (id: string) => void = () => {}
  // v6.5：onModDownloadProgress / onModInstallStart 已下台，走 registry 是唯一路径。

  /**
   * 普通下载样式保持固定标题。横竖屏只增减侧栏和顶部导航，正文始终位于同一Column，
   * 避免旋转销毁资源浏览器、查询和IME；资源胶囊也共用一个受控浏览器实例。
   */
  build() {
    Row() {
      if (this.isLandscape) this.DownloadSidebar_()
      Column() {
        if (!this.isLandscape) this.PortraitHeader_()
        this.DlTabContent()
      }.layoutWeight(1).height('100%').padding({ top: this.isLandscape ? this.topSafeHeight : 0 })
    }.width('100%').height('100%')
  }

  /** 竖屏（原布局）：大标题 + 横向滚动 chips + 内容。 */
  @Builder
  private PortraitHeader_() {
    Column() {
      // ============ 顶部 Page Header（"下载" 大标题） ============
      Row() {
        Text('下载')
          .id('download-page-title')
          .fontSize(28)
          .fontWeight(700)
          .fontColor(this.theme.textPrimary)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: this.topSafeHeight + 12, bottom: 8 })

      // ============ 横向滚动 6-tab Chips（设计稿 Screen A 核心新增） ============
      Scroll() {
        Row({ space: 8 }) {
          ForEach(DL_TABS, (tab: DlTabMeta) => {
            this.DlTopTabChip(tab)
          })
        }
        .padding({ left: 20, right: 20, top: 4, bottom: 8 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .id('download-category-strip')

    }
    .width('100%')
  }

  /** 横屏：左侧竖向侧边栏（标题 + 竖向页签 + 操作按钮），右侧内容占满剩余宽度。 */
  @Builder
  private DownloadSidebar_() {
      // ---- 左侧侧边栏 ----
      Column() {
        Text('下载')
          .fontSize(20)
          .fontWeight(700)
          .fontColor(this.theme.textPrimary)
          .width('100%')
          .padding({ left: 4, bottom: 10 })

        // 竖向页签列表（超出可滚，占满整列）
        Scroll() {
          Column({ space: 8 }) {
            ForEach(DL_TABS, (tab: DlTabMeta) => {
              this.DlSideTabChip(tab)
            })
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      .width(104)
      .height('100%')
      // 侧栏铺到窗口底部；右侧滚动内容自行在末尾为悬浮导航留位。
      .padding({ left: 12, right: 8, top: this.topSafeHeight + 12, bottom: 0 })
      .alignItems(HorizontalAlign.Start)

  }

  /** Tab 内容区（竖/横屏共用）。 */
  @Builder
  DlTabContent() {
    if (this.dlSubTab === 0) {
      this.DlVersionTab()
    } else if (this.dlSubTab >= 1 && this.dlSubTab <= 4) {
      // 同一个ArkUI分支承载四类资源，胶囊只改defaultKindIdx，不重建搜索和整个页面。
      this.DlModBrowseTab()
    } else {
      this.DlJdkTab()
    }
  }

  /** 横屏侧边栏竖向页签：图标在上、文字在下，选中态 primary 填充。 */
  @Builder
  DlSideTabChip(tab: DlTabMeta) {
    Column({ space: 4 }) {
      AppIcon({
        name: tab.icon,
        iconSize: 18,
        color: this.dlSubTab === tab.idx ? this.theme.textOnPrimary : this.theme.textSecondary,
      })
      Text(tab.label)
        .fontSize(12)
        .fontWeight(this.dlSubTab === tab.idx ? 600 : 500)
        .fontColor(this.dlSubTab === tab.idx ? this.theme.textOnPrimary : this.theme.textSecondary)
        .maxLines(1)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .borderRadius(14)
    .backgroundColor(this.dlSubTab === tab.idx ? this.theme.actionPrimary : this.theme.bgCard)
    .shadow(this.dlSubTab === tab.idx
      ? { radius: 0, color: Color.Transparent }
      : { radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      if (this.dlSubTab === tab.idx) return
      this.dlSubTab = tab.idx
      if (tab.idx === 0 && this.mcVersionList.length === 0) {
        this.loadVersionList()
      }
    })
  }

  /** 顶级横向 Tab chip（与设计稿 Screen A 一致：图标 + label + 选中态填充） */
  @Builder
  DlTopTabChip(tab: DlTabMeta) {
    Row({ space: 6 }) {
      AppIcon({
        name: tab.icon,
        iconSize: 14,
        color: this.dlSubTab === tab.idx ? this.theme.textOnPrimary : this.theme.textSecondary,
      })
      Text(tab.label)
        .fontSize(14)
        .fontWeight(this.dlSubTab === tab.idx ? 600 : 500)
        .fontColor(this.dlSubTab === tab.idx ? this.theme.textOnPrimary : this.theme.textSecondary)
    }
    .height(40)
    .padding({ left: 16, right: 16 })
    .borderRadius(20)
    .backgroundColor(this.dlSubTab === tab.idx ? this.theme.actionPrimary : this.theme.bgCard)
    .shadow(this.dlSubTab === tab.idx
      ? { radius: 0, color: Color.Transparent }
      : { radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (this.dlSubTab === tab.idx) return
      this.dlSubTab = tab.idx
      // 切到"版本" tab 时按需加载列表
      if (tab.idx === 0 && this.mcVersionList.length === 0) {
        this.loadVersionList()
      }
    })
  }

  /** 占位 Tab —— 未实现功能用统一空状态展示，对齐设计稿语义 */
  @Builder
  DlPlaceholderTab(title: string, icon: AppIconName, slogan: string, footerHint: string) {
    Column() {
      Column({ space: 14 }) {
        AppIcon({ name: icon, iconSize: 56, color: this.theme.textHint })
        Text(title)
          .fontSize(20)
          .fontWeight(600)
          .fontColor(this.theme.textPrimary)
        Text(slogan)
          .fontSize(13)
          .fontColor(this.theme.textSecondary)
          .textAlign(TextAlign.Center)
        Row({ space: 6 }) {
          AppIcon({ name: AppIconName.Construction, iconSize: 12, color: this.theme.warningText })
          Text(footerHint)
            .fontSize(11)
            .fontColor(this.theme.warningText)
            .fontWeight(500)
        }
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .borderRadius(12)
        .backgroundColor(this.theme.bgCard)
      }
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    // 2026-05-24：原纸值 80 是给以前 52+safe tab bar 留位；FloatingDock 后走预留辅助
    .padding({ left: 32, right: 32, bottom: this.dlContentBottomPad() })
  }

  /**
   * 四类资源共用同一正文位置。Prop直接读取父状态，由子组件Watch切换控制器；
   * 不通过Builder的按值参数传递快照，避免同实例下类别迟迟不同步。
   */
  @Builder
  DlModBrowseTab() {
    Column() {
      ModBrowsePage({
        theme: this.theme,
        hostVisible: this.hostVisible,
        mcDir: this.mcDir,
        currentMcVersion: this.currentMcVersion,
        versionIsolation: this.versionIsolation,
        availableVersions: this.availableVersions,
        modSource: this.modSource,
        cacheRemoteMeta: this.cacheRemoteMeta,
        defaultKindIdx: this.dlSubTab === 2 ? 2 : this.dlSubTab === 3 ? 1 : this.dlSubTab === 4 ? 3 : 0,
        topSafeHeight: this.topSafeHeight,
        bottomSafeHeight: this.bottomSafeHeight,
        onStatusMessage: this.onModStatusMessage,
        onOpenDownloadTask: this.onOpenDownloadTask,
      })
    }
    .width('100%')
    .layoutWeight(1)
  }

  /** 搜索固定，筛选可以随滚动退让，结果状态变化不重新挂载搜索输入。 */
  @Builder
  DlVersionTab() {
    Column() {
      // 与模组/光影等分类使用同一搜索组件；版本查询仍在本页即时筛选，不引入网络去抖。
      DownloadSearchField({
        theme: this.theme, text: this.versionSearch, placeholder: '搜索版本号...',
        controlId: 'version-browser-search',
        onTextChange: (value: string): void => { this.versionSearch = value },
        onInputFocus: (): void => { this.versionSearchFocused_ = true },
        onInputBlur: (): void => { this.versionSearchFocused_ = false },
        onClear: (): void => { this.versionSearch = '' },
      })

      DownloadAuxiliaryList({
        theme: this.theme, active: this.hostVisible && this.dlSubTab === 0,
        resetKey: this.versionRetreatKey_(), blocked: this.versionSearchFocused_ || this.mcVersionsLoading,
        firstEnabled: false, secondEnabled: true,
        itemCount: this.getFilteredVersions().length,
        hasResults: !this.mcVersionsLoading && !this.mcVersionsError && this.getFilteredVersions().length > 0,
        bottomInset: this.dlContentBottomPad(),
        // 箭头闭包固定父页this；直接传@Builder方法会在子组件中以子实例调用。
        firstLayer: () => { this.EmptyAuxiliary_() }, secondLayer: () => { this.VersionFilters_() },
        items: () => { this.VersionItems_() }, empty: () => { this.VersionEmpty_() },
      }).layoutWeight(1)
    }.width('100%').layoutWeight(1)
    .onAppear(() => { if (this.mcVersionList.length === 0) this.loadVersionList() })
  }

  /** 版本结果或辅助层身份变化时清除旧方向预算；不持久化自动退让状态。 */
  private versionRetreatKey_(): string {
    return this.versionSearch + ':' + this.filterRelease + ':' + this.filterSnapshot + ':' + this.filterOld
      + ':' + this.filterAprilFools + ':' + this.mcVersionList.length + ':' + this.mcVersionsLoading
      + ':' + this.mcVersionsError + ':' + this.versionActionEpoch_
  }

  /** 原筛选状态仍由DownloadTab持有，逐层退让不改任何类别选择。 */
  @Builder
  private VersionFilters_() {
      // 筛选 chips —— 4 个版本类别，全部可单独 / 组合切换，至少保留一个
      // 视觉上沿用原有的圆角胶囊 + 选中态 primary 蓝底；间距 8 vp 与原版一致
      //
      // 全部 inline —— 不抽 @Builder FilterChip(label, selected, ...)。原因：
      // ArkUI 对 @Builder 的 primitive 参数（boolean / number / string）脏标记会漏报，
      // filterRelease 等 @State 变化时，FilterChip 内部 `selected` 参数永远是首次构建那一刻的
      // 值快照，UI 永远停在初始状态（看起来像"锁死正式版"）。
      // 历史教训见 VersionManagerSheet.DetailResourcesCard 的同款修复。
      Row({ space: 8 }) {
        Text('正式版')
          .fontSize(12)
          .fontColor(this.filterRelease ? this.theme.textOnPrimary : this.theme.textSecondary)
          .backgroundColor(this.filterRelease ? this.theme.actionPrimary : this.theme.bgCard)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(14)
          .onClick(() => { this.toggleFilter('release') })
        Text('快照')
          .fontSize(12)
          .fontColor(this.filterSnapshot ? this.theme.textOnPrimary : this.theme.textSecondary)
          .backgroundColor(this.filterSnapshot ? this.theme.actionPrimary : this.theme.bgCard)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(14)
          .onClick(() => { this.toggleFilter('snapshot') })
        Text('远古版')
          .fontSize(12)
          .fontColor(this.filterOld ? this.theme.textOnPrimary : this.theme.textSecondary)
          .backgroundColor(this.filterOld ? this.theme.actionPrimary : this.theme.bgCard)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(14)
          .onClick(() => { this.toggleFilter('old') })
        Text('愚人节')
          .fontSize(12)
          .fontColor(this.filterAprilFools ? this.theme.textOnPrimary : this.theme.textSecondary)
          .backgroundColor(this.filterAprilFools ? this.theme.actionPrimary : this.theme.bgCard)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(14)
          .onClick(() => { this.toggleFilter('aprilfools') })
        Blank()
        Text('刷新')
          .fontSize(12)
          .fontColor(this.theme.actionText)
          .onClick(() => { this.loadVersionList(true) })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })

  }

  /** 真实列表项保留版本身份key，首占位由唯一滚动宿主统一生成。 */
  @Builder
  private VersionItems_() {
    ForEach(this.getFilteredVersions(), (ver: McVersion) => {
      ListItem() { this.VersionItem(ver) }
    }, (ver: McVersion): string => ver.id)
  }

  /** 网络、错误与空结果沿用原操作；没有真实内容时宿主禁止自动退让。 */
  @Builder
  private VersionEmpty_() {
    Column() {
      if (this.mcVersionsLoading) {
        Column() {
          LoadingProgress().width(40).height(40).color(this.theme.actionText)
          Text('正在获取版本列表...')
            .fontSize(13)
            .fontColor(this.theme.textHint)
            .margin({ top: 12 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.mcVersionsError) {
        Column() {
          Text(this.mcVersionsError)
            .fontSize(14)
            .fontColor(this.theme.errorText)
            .textAlign(TextAlign.Center)
          Button('重试')
            .type(ButtonType.Capsule)
            .height(36)
            .fontSize(14)
            .backgroundColor(this.theme.actionPrimary)
            .fontColor(this.theme.textOnPrimary)
            .margin({ top: 16 })
            .onClick(() => { this.loadVersionList(true) })
          Button('网络检测')
            .type(ButtonType.Capsule)
            .height(36)
            .fontSize(14)
            .backgroundColor(Color.Transparent)
            .fontColor(this.theme.textSecondary)
            .borderWidth(1).borderColor(this.theme.divider)
            .margin({ top: 8 })
            .onClick(() => { AppStorage.setOrCreate('amcl_open_netdiag_nonce', Date.now()) })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .padding(32)
      } else if (this.getFilteredVersions().length === 0) {
        Column({ space: 12 }) {
          Text('没有匹配的 Minecraft 版本').fontSize(15).fontColor(this.theme.textSecondary)
          Text('可以清除搜索词，或切换上方的版本类别').fontSize(12).fontColor(this.theme.textHint)
          Button('清除搜索').height(44).onClick(() => { this.versionSearch = '' })
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      }
    }.width('100%').height('100%')
  }

  @Builder
  VersionItem(ver: McVersion) {
    Row() {
      // 版本前的方块图标 —— release / snapshot / old / aprilfools 各有专属
      // PCL2 同款语义：草方块 / 命令方块 / 圆石 / 金块
      // 直接走 mcVersionToCategory，它内部用 classifyVersion(id) 优先识别愚人节版
      // （manifest 里 24w14potato 这种 type=snapshot，靠 id 白名单分出来）
      VersionBlockIcon({
        category: this.mcVersionToCategory(ver),
        versionId: ver.id,
        iconSize: 36,
        cornerRadius: 0,
      })
      Column() {
        Text(ver.id)
          .fontSize(15)
          .fontWeight(500)
          .fontColor(this.theme.textPrimary)
        Text(ver.displayDate + '  ·  ' + this.versionTypeLabelOf(ver))
          .fontSize(12)
          .fontWeight(400)
          .fontColor(this.theme.textHint)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })
      AppIcon({ name: AppIconName.ArrowRight, iconSize: 16, color: this.theme.textHint })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    .backgroundColor(this.theme.bgCard)
    .borderRadius(this.theme.cardRadius)
    .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
    .onClick(() => { this.versionActionEpoch_++; this.onSelectGameVersion(ver.id, this.mcVersionToCategory(ver)) })
  }

  /**
   * Tab 滚动内容的尾部预留（vp），供 List 的末尾偏移与 Scroll 内容内边距共用。
   * 横竖屏的 HdsTabs 都叠加在正文上，透明材质仍会覆盖内容，因此始终保留余量。
   * LauncherTabsStyle 的离底距离至少以 16vp 安全区计算；这里采用相同下限，
   * 再由公共辅助函数计入导航主体、离底间距和视觉缓冲，避免零安全区窗口预留不足。
   */
  private dlContentBottomPad(): number {
    return floatingDockReserveHeight(Math.max(this.bottomSafeHeight, 16))
  }

  /**
   * 切某一个 filter chip。约束：**至少保留一个**为 true，否则直接 return（UI 不动）。
   *
   * 用 string 而不是直接传 setter 闭包是因为：ArkTS 严格模式对 closure 捕获 @State
   * 字段 reference 不友好，最稳妥的写法就是用 if 链显式分发。代价是 O(branches=4)，
   * 反正 chip 数量是常量。
   */
  private toggleFilter(name: string): void {
    // 算 toggle 后命中的 4 个 boolean
    let r = this.filterRelease
    let s = this.filterSnapshot
    let o = this.filterOld
    let a = this.filterAprilFools
    if (name === 'release')         r = !r
    else if (name === 'snapshot')   s = !s
    else if (name === 'old')        o = !o
    else if (name === 'aprilfools') a = !a
    else return  // 未知 name，no-op
    // guard：至少留一个
    if (!r && !s && !o && !a) {
      // 真机上偶尔 chip 双击导致状态闪烁，加一行 toast 让用户明白为什么没动
      // 2026-05-23 API NEXT 迁移：promptAction.showToast 弃用，走 UIContext；
      // 同时 showToast 报 ArkTS 'Function may throw'，包 try-catch 兜底。
      try {
        this.getUIContext().getPromptAction().showToast({ message: '至少保留一个版本类别', duration: 1200 })
      } catch (e) { /* UI 实例已销毁，忽略 */ }
      return
    }
    this.filterRelease = r
    this.filterSnapshot = s
    this.filterOld = o
    this.filterAprilFools = a
  }

  /** JDK目录信息成为辅助层，版本实体、导入和进度保留在可滚动正文。 */
  @Builder
  DlJdkTab() {
    DownloadAuxiliaryList({
      theme: this.theme, active: this.hostVisible && this.dlSubTab === 5,
      resetKey: this.jdkRetreatKey_(),
      blocked: this.jdkChecking || this.jdkImporting, firstEnabled: true, secondEnabled: false,
      itemCount: this.jdkVersions.length + 1 + (this.jdkDownloadMsg ? 1 : 0), hasResults: true,
      rowSpacing: 12, bottomInset: this.dlContentBottomPad(),
      firstLayer: () => { this.JdkCatalog_() }, secondLayer: () => { this.EmptyAuxiliary_() },
      items: () => { this.JdkItems_() }, empty: () => { this.EmptyAuxiliary_() },
    }).layoutWeight(1)
  }

  /** 目录/版本身份和显式操作会重置展示；下载任务的普通进度帧不反复打断列表。 */
  private jdkRetreatKey_(): string {
    return this.jdkChannel + ':' + this.jdkCatalogStatus + ':' + this.jdkChecking + ':' + this.jdkActionEpoch_
      + ':' + this.jdkVersions.map((info: JdkVersionInfo): string => info.version + ':' + info.installed
        + ':' + info.stateText + ':' + info.available).join(',')
  }

  /** 目录异常依然完整展示通道、检查结果与重试动作；卡片的尾距属于该完整层。 */
  @Builder
  private JdkCatalog_() {
    Column() {
        // 目录异常不能只留下导入卡片：始终显示当前通道、检查结果与可重复执行的刷新动作。
        Column({ space: 6 }) {
          Row({ space: 8 }) {
            Text(this.jdkChannel === 'preview' ? 'JDK · 预览通道' : 'JDK · 稳定通道')
              .fontSize(15).fontWeight(500).fontColor(this.theme.textPrimary).layoutWeight(1)
            Button(this.jdkChecking ? '检查中' : '刷新列表')
              .type(ButtonType.Capsule).height(32).fontSize(13)
              .backgroundColor(this.jdkChecking ? this.theme.disabled : this.theme.actionPrimary)
              .fontColor(this.theme.textOnPrimary).enabled(!this.jdkChecking)
              .onClick((): void => { this.jdkActionEpoch_++; this.onRefreshJdkCatalog() })
          }.width('100%')
          Text(this.jdkCatalogStatus.length > 0 ? this.jdkCatalogStatus : '可刷新目录以检查当前通道的 JDK。')
            .fontSize(12).fontColor(this.theme.textHint).width('100%')
          if (this.jdkVersions.length === 0 && !this.jdkChecking) {
            Text('暂未取得可展示的 JDK。请刷新列表，或检查下载源与网络设置。')
              .fontSize(12).fontColor(this.theme.warningText).width('100%')
          }
        }
        .width('100%').padding(16).backgroundColor(this.theme.bgCard).borderRadius(this.theme.cardRadius)
    }.width('100%').padding({ left: 16, right: 16, top: 4, bottom: 12 })
  }

  /** 插槽占位不产生高度；JDK只有一个辅助层，不能虚构第二层端点。 */
  @Builder
  private EmptyAuxiliary_() { Column().height(0) }

  /**
   * Manager每次返回新的普通状态快照；ForEach若仅以主版本作键，会继续绑定旧对象，
   * 导致安装、删除和切通道后仍显示旧身份。用小型JdkVersionInfo快照及在途状态区分行。
   * taskRevision参数只建立任务变化的观察依赖，不进入键值；普通进度帧不会重建相同行，
   * 只有任务开始/终结改变按钮可用性时重建，也不影响辅助层的滚动重置规则。
   */
  private jdkRowKey_(info: JdkVersionInfo, _taskRevision: number): string {
    return JSON.stringify(info) + ':' + this.isJdkDownloading(info.version)
  }

  /** JDK行和本地导入各自成为真实ListItem，末尾避让随正文滚动。 */
  @Builder
  private JdkItems_() {
        ForEach(this.jdkVersions, (info: JdkVersionInfo) => {
          ListItem() {
          Row() {
            Column() {
              Row() {
                Text('JDK ' + info.version)
                  .fontSize(16).fontWeight(500).fontColor(this.theme.textPrimary)
                // 本地导入的包打个角标：它不参与更新检查，用户得能看出来这一份是自己塞的
                if (info.userImported) {
                  Text('本地导入')
                    .fontSize(10).fontColor(this.theme.textHint)
                    .backgroundColor(this.theme.bgInput)
                    .borderRadius(4).padding({ left: 5, right: 5, top: 1, bottom: 1 })
                    .margin({ left: 6 })
                }
              }
              Text(info.repairRequired ? '需修复（原安装已保留）' : info.installed
                ? '已安装'
                : (info.available ? '需下载 ~' + info.sizeMB + ' MB' : '暂不可下载'))
                .fontSize(13).fontWeight(400)
                .fontColor(info.repairRequired ? this.theme.warningText : info.installed ? this.theme.successText : this.theme.textHint)
                .margin({ top: 4 })
              // 状态说明行：把「装的是什么 → 期望什么」说出来。
              // 旧行为把"过期"显示成"未安装"，用户和我们都不知道真实原因（方案里的 J-b）。
              if (info.stateText.length > 0) {
                Text(info.stateText)
                  .fontSize(12).fontWeight(400)
                  .fontColor(info.updateAvailable ? this.theme.warningText : this.theme.textHint)
                  .margin({ top: 2 })
              }
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1)

            if (info.installed || info.repairRequired) {
              // 已装官方包也提供真实重新下载安装入口；不用先删仍可用的runtime才能修复
              // 下载/安装。复用onJdkUpdate的forceReinstall，唯一staging及完整校验成功后
              // 才发布，新任务失败/取消沿既有事务保留旧安装。没有可下载推荐时不展示。
              // 原有“先升级AMCL宿主”的更新入口仍由updateAvailable保留；新增重装只
              // 对当前有可下载推荐的槽生效，不能使旧宿主看不到原先可见的升级提示。
              if (info.updateAvailable || info.available) {
                // 用户导入永不自动替换；只有“改用官方”这个明确点击进入相同安全事务。
                Button(this.isJdkDownloading(info.version) ? '下载中' : (info.userImported ? '改用官方' : (info.repairRequired ? '修复' : (info.rollback ? '回退修复' : (info.updateAvailable ? '更新' : '重新安装')))))
                  .type(ButtonType.Capsule).height(32).fontSize(13)
                  .backgroundColor(this.isJdkDownloading(info.version) ? this.theme.disabled : this.theme.actionPrimary)
                  .fontColor(this.theme.textOnPrimary)
                  .enabled(!this.isJdkDownloading(info.version))
                  .margin({ right: 8 })
                  .onClick(() => { this.jdkActionEpoch_++; this.onJdkUpdate(info.version) })
              }
              Button('删除')
                .type(ButtonType.Capsule).height(32).fontSize(13)
                .backgroundColor(this.theme.error).fontColor(this.theme.textOnPrimary)
                .onClick(() => { this.jdkActionEpoch_++; this.onJdkDelete(info.version) })
            } else if (info.available) {
              // B-1 修复（2026-05-26）：每个版本独立判断，下载 17 时 21 按钮仍可点
              Button(this.isJdkDownloading(info.version) ? '下载中' : '下载')
                .type(ButtonType.Capsule).height(32).fontSize(13)
                .backgroundColor(this.isJdkDownloading(info.version) ? this.theme.disabled : this.theme.actionPrimary)
                .fontColor(this.theme.textOnPrimary)
                .enabled(!this.isJdkDownloading(info.version))
                .onClick(() => { this.jdkActionEpoch_++; this.onJdkDownload(info.version) })
            }
          }
          .width('100%').padding(16)
          .backgroundColor(this.theme.bgCard)
          .borderRadius(this.theme.cardRadius)
          .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
          }
        }, (info: JdkVersionInfo): string => this.jdkRowKey_(info, this.taskRevision))

        // 本地导入入口。放在列表下方而不是每行一个按钮：导入要先选"装到哪个槽位"，
        // 那是一次带选择的操作，不适合塞进行内。
        ListItem() {
        Column({ space: 6 }) {
          Row() {
            Column() {
              Text('从本地压缩包导入 JDK')
                .fontSize(15).fontWeight(500).fontColor(this.theme.textPrimary)
              Text('没有网络、或你自己准备/修好了 JDK 包时用。导入的包不参与更新检查。')
                .fontSize(12).fontColor(this.theme.textHint).margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1)
            Button(this.jdkImporting ? '导入中' : '选择文件')
              .type(ButtonType.Capsule).height(32).fontSize(13)
              .backgroundColor(this.jdkImporting ? this.theme.disabled : this.theme.bgInput)
              .fontColor(this.theme.textPrimary)
              .enabled(!this.jdkImporting)
              .onClick(() => { this.jdkActionEpoch_++; this.onJdkImport() })
          }
          .width('100%')
          // ⚠️ 这句必须留着：导入不校验 SHA-256（没有期望值可比），
          //    所以不能让它看起来和官方下载一样安全。
          Text('⚠️ 本地包不做校验和比对，来源与内容由你负责')
            .fontSize(11).fontColor(this.theme.textHint).width('100%')
        }
        .width('100%').padding(16)
        .backgroundColor(this.theme.bgCard)
        .borderRadius(this.theme.cardRadius)
        .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
        }

        if (this.jdkDownloadMsg) {
          ListItem() {
          Column() {
            if (this.jdkDownloadPercent > 0) {
              Stack({ alignContent: Alignment.Start }) {
                Row().width('100%').height(4).backgroundColor(this.theme.bgInput).borderRadius(2)
                Row().width(this.jdkDownloadPercent + '%').height(4)
                  .backgroundColor(this.jdkDownloadPercent >= 100 ? this.theme.success : this.theme.actionPrimary)
                  .borderRadius(2)
              }
              .width('100%').height(4).margin({ bottom: 8 })
            }
            Text(this.jdkDownloadMsg)
              .fontSize(13).fontColor(this.theme.warningText).maxLines(2)
          }
          .width('100%').padding(16)
          .backgroundColor(this.theme.bgCard).borderRadius(this.theme.cardRadius)
          }
        }
  }

  // 内部方法
  /**
   * 把 manifest entry 映射成中文显示标签，与 chip 文案对齐。
   * 愚人节版的 manifest type 仍然是 snapshot，靠 id 白名单分出来。
   */
  private versionTypeLabelOf(v: McVersion): string {
    let cat = this.mcVersionToCategory(v)
    if (cat === 'release')    return '正式版'
    if (cat === 'snapshot')   return '快照'
    if (cat === 'aprilfools') return '愚人节版'
    if (cat === 'old')        {
      // 远古版下面再细分 alpha / beta，方便用户识别
      if (v.type === 'old_alpha') return '远古 Alpha'
      if (v.type === 'old_beta')  return '远古 Beta'
      return '远古版'
    }
    return v.type
  }

  private versionTypeLabel(type: string): string {
    if (type === 'release') return '正式版'
    if (type === 'snapshot') return '快照'
    if (type === 'old_beta') return '远古 Beta'
    if (type === 'old_alpha') return '远古 Alpha'
    return type
  }

  private getFilteredVersions(): McVersion[] {
    // classify 优先看版本 id（愚人节白名单 / loader 后缀），manifest 的 type 仅作 fallback。
    // 把 chip 选中状态映射成允许的 VersionCategory 集合。
    let allow: Set<VersionCategory> = new Set<VersionCategory>()
    if (this.filterRelease)    allow.add('release')
    if (this.filterSnapshot)   allow.add('snapshot')
    if (this.filterOld)        allow.add('old')
    if (this.filterAprilFools) allow.add('aprilfools')

    let list: McVersion[] = this.mcVersionList.filter((v: McVersion): boolean => {
      let cat = this.mcVersionToCategory(v)
      return allow.has(cat)
    })
    if (this.versionSearch.length > 0) {
      let q = this.versionSearch.toLowerCase()
      list = list.filter((v: McVersion): boolean => v.id.toLowerCase().includes(q))
    }
    return list
  }

  /**
   * 把 manifest entry 映射到 VersionCategory，与 VersionBlockIcon 同一套语义。
   *
   * 决策顺序：
   *   1. classifyVersion(id) —— 愚人节白名单 / pre/rc / 远古版前缀都在这里命中
   *   2. 若 classify 仍然给出 release/snapshot 但 manifest type 说 old_*，按 manifest 走
   *      （历史 1.0~1.5 的版本 classify 已经识别为 old，但 manifest 自己也 old_alpha/old_beta）
   *   3. 兜底取 manifest type
   */
  private mcVersionToCategory(v: McVersion): VersionCategory {
    let byId = classifyVersion(v.id)
    // classify 已经能识别愚人节 / pre / rc / 远古版前缀；优先用它的结果
    if (byId === 'aprilfools') return 'aprilfools'
    if (byId === 'snapshot')   return 'snapshot'
    if (byId === 'old')        return 'old'
    // byId === 'release' 时再看 manifest type 兜底（manifest 的 old_alpha/old_beta
    // 标记的版本号可能 classify 没覆盖到，比如 "1.6.4" 就不在我的"远古版"规则里）
    if (v.type === 'old_alpha' || v.type === 'old_beta') return 'old'
    if (v.type === 'snapshot') return 'snapshot'
    return 'release'
  }

  /**
   * 响应父组件的受控二级 Tab 导航命令。解码 `navCommand % 10` 得到目标子页并切换。
   * 版本子页（0）按需触发一次版本列表加载。命令为 -1（初始）时不动内部 tab。
   */
  onNavCommand(): void {
    if (this.navCommand < 0) return
    let sub = this.navCommand % 10
    if (sub < 0 || sub > 5) return
    this.dlSubTab = sub
    if (sub === 0 && this.mcVersionList.length === 0) {
      this.loadVersionList()
    }
  }

  private loadVersionList(forceRefresh: boolean = false) {
    this.mcVersionsLoading = true
    this.mcVersionsError = ''
    this.mcVersionService.getVersionList(forceRefresh).then((result) => {
      this.mcVersionList = result.versions
      this.mcVersionsLoading = false
      hilog.info(0x0000, 'DownloadTab', 'Loaded %{public}d versions', this.mcVersionList.length)
    }).catch((e: Error) => {
      this.mcVersionsError = e.message || '获取版本列表失败'
      this.mcVersionsLoading = false
      // 失败路径原来只写 UI 不写日志，于是「列表拉不出来」在 hilog 里完全没有痕迹，
      // 只能靠 McVersionService 那一行 warn 反推。成功路径有日志、失败路径没有是反的。
      hilog.error(0x0000, 'DownloadTab', 'Load version list failed: %{public}s', this.mcVersionsError)
    })
  }
}
