/**
 * VersionManagerSheet.ets — 版本管理 Sheet（v2 重设计 2026-05-14）
 *
 * 设计稿：
 *   - docs/design/version_manager.pen
 *   - docs/design/download-page-redesign/07b_version_manager_v2.png（list step）
 *   - docs/design/download-page-redesign/07b_version_manager_v2_active.png（切换后反馈）
 *   - docs/design/download-page-redesign/09b_version_detail_sheet.png（detail step）
 *
 * v2 核心 UX 改动（仅 UI，不动业务/功能/路由）：
 *   1. 行体职责分离：左侧 BodySelect 区点击 = 切换当前版本（不关闭 sheet）；
 *      右侧 ⚙ 管理按钮点击 = 切换到 detail step（同 sheet 内）
 *   2. 当前版本指示：行 stroke 2px primary 边框；徽章统一只显示 loader 类型
 *   3. 09 详情改为同 sheet 内第二步（currentStep = 'detail'），不再 push 全屏路由
 *
 * 兼容性：
 *   - 保留全部既有 prop / callback（onSelectVersion / onDeleteVersion / onAddNew /
 *     onCleanupOrphans / onClose / onOpenVersionDetail）。
 *   - onOpenVersionDetail 不再用于内部触发（UI 自管 step），但保留为公开 API。
 *   - 新增可选只读 props：mcXmx / selectedJdkVersion（detail step 展示用）。
 *     未传时回退展示"—"，不影响主流程。
 */

// 2026-05-23 API NEXT 迁移：promptAction / router 全局函数已弃用，
// 本文件改走 this.getUIContext().getPromptAction() / .getRouter()。
// 该 import 仅保留类型依赖（如 router.pushUrl 参数型），运行时不调。
// 详见 docs/guides/api-migration-2026-05.md。
import { router, promptAction } from '@kit.ArkUI';
import { curves } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ThemeColors } from 'commons';
import { GAME_LANGUAGES, GameLanguageOption, gameLanguageLabel } from 'commons';
import { getModpackIconPath } from 'mods';
import { readModpackSnapshot, ModpackSnapshot, ModpackMissingItem } from 'mods';
import { resolveInstalledMcVersion } from 'mods';
import { pasteboard } from '@kit.BasicServicesKit';
import { AppIconName } from 'commons';
import { AppIcon } from './AppIcon';
import { VersionBlockIcon } from './VersionBlockIcon';
// 2026-05-23 图标系统重构：loader 名/颜色/图标全部走 LoaderCatalog 单一事实源。
// getInstalledBadgeInfo 进一步把 vanilla 子类（snapshot/aprilfools/old）的徽章
// 文案 + 配色也纳入统一接口（修 "26.2-snapshot-8" 显示为 "原版" 草绿的 bug）。
import {
  inferLoaderKey, inferLoaderInfo, getLoaderInfo, getInstalledBadgeInfo,
  resolveInstalledLoaderKey, resolveInstalledLoaderInfo, getInstalledBadgeInfoResolved,
} from '../components/LoaderCatalog';
import { countFilesWithExtensions, validateVersionName } from 'commons';
import { ResourceKind } from 'mods';
import { InstalledResourcesSheet } from './InstalledResourcesSheet';
import { SavesManagerSheet } from './SavesManagerSheet';
import { VersionFileBrowser } from './VersionFileBrowser';
import { GameArchiveIO } from './GameArchiveIO';

const TAG = 'VersionManagerSheet';

@Component
export struct VersionManagerSheet {
  @Prop theme: ThemeColors = {} as ThemeColors
  @Prop bottomSafeHeight: number = 0

  @Prop currentVersion: string = ''
  @Prop @Watch('onAvailableVersionsChange') availableVersions: string[] = []
  @Prop orphanVersionDirs: string[] = []
  @Prop versionIsolation: boolean = true
  /**
   * 当前 .minecraft 是否位于「沙箱外」（外部 Download/com.amcl.launcher）。
   * 由父级 Index 传入（= storageLocation === EXTERNAL）。
   * 当前未配置沙箱目录捐献，系统文件管理入口仅在外部存储时显示。
   */
  @Prop isExternalStorage: boolean = false
  /**
   * .minecraft 根目录（不带尾部 /）。由父级 Index 显式传入：
   *   `GameStorage.resolveMcDir(...)`
   *
   * 之所以不用 `getContext(this).filesDir`：在非 @Entry 的子组件里，
   * getContext(this) 返回的 Context 类型不稳定（部分场景拿到的是
   * ApplicationContext 而非 UIAbilityContext），filesDir 不一定指向
   * 正确的沙盒目录，会让 fs.listFileSync 静默命中空目录、计数全 0。
   */
  @Prop mcDir: string = ''
  /** detail step 展示用，未传时回退 "—" */
  @Prop mcXmx: number = 0
  @Prop selectedJdkVersion: string = ''
  /** 全局 Java 版本设置（'auto' 或具体版本）。仅用于单版本"跟随全局"选项的附注展示。 */
  @Prop globalJdkVersion: string = 'auto'
  /** 全局游戏语言 code（如 'zh_cn'）。仅用于单版本"跟随全局"选项的附注展示。 */
  @Prop globalGameLanguage: string = 'zh_cn'
  /**
   * 用户当前 MC 版本对应的"自动建议 JDK"（Index 通过 JdkManager.autoSelectVersion 计算）。
   * 仅用于在版本详情 sheet 的 JDK 选择器里给一个"推荐"标签，不参与决策；
   * 真正决策（是否覆盖用户选择）由父组件 onJdkVersionChange 收到回调后处理。
   */
  @Prop suggestedJdkVersion: string = ''

  /**
   * 父组件传入的"已上线 JDK 版本列表"。来自 JdkManager.SUPPORTED_JDK_VERSIONS。
   * 之所以传一份 prop 而不是直接 import：
   *   1. 避免 sheet 直接 import 服务层，保持纯展示；
   *   2. 父组件可以按需过滤掉未安装/未发布的版本。
   * 默认 ['17']，向后兼容 sheet 单独使用的场景。
   */
  @Prop supportedJdkVersions: string[] = ['17']

  /**
   * v3 深链：打开本 sheet 时直接落到哪一步（父组件设定）。
   *   - 'list'（默认）：版本列表
   *   - 'detail'：initialResourceVersion 的版本详情
   *   - 'resources'：initialResourceVersion + initialResourceKind 的资源管理
   *     （首页 Quick Stats "已装模组" 入口走这里，直达模组管理且不另开 sheet）
   */
  @Prop initialStep: string = 'list'
  /** 深链目标版本（'detail' / 'resources' 用；空时回退 currentVersion） */
  @Prop initialResourceVersion: string = ''
  /** 深链目标资源类型（'resources' 用） */
  @Prop initialResourceKind: ResourceKind = ResourceKind.MOD

  /** 排序 / 过滤的本地状态 */
  @State private filterLoader: string = ''

  /**
   * 列表实际渲染用的版本顺序（本地 @State）。
   *
   * 为什么不直接用 @Prop availableVersions：拖拽排序要"实时"重排（手指拖到哪，其余卡片
   * 立刻让位 + animateTo 平滑滑动），必须有一个可在 onItemDragMove 里原地 splice 的本地数据源。
   * 直接改 @Prop 不允许，且经父组件回传一圈会丢失逐帧动画。故本地维护，drop 时再回传父组件持久化。
   * 通过 @Watch(availableVersions) 在非拖拽态保持与父组件同步（下载/删除/重命名后刷新）。
   */
  @State private orderVersions: string[] = []
  /** 正在被拖拽的版本名（''=未拖拽）。用于把原始行"提起"（半透明）+ 抑制 @Watch 重置顺序。 */
  @State private draggingVer: string = ''
  /** 拖拽过程中被拖项在 orderVersions 里的当前下标（自管，避免依赖回调里会过期的 itemIndex）。 */
  private dragCurIndex_: number = -1

  /** v3: 同 sheet 三步切换 — list 版本列表 / detail 版本详情 / resources 已装资源管理 */
  @State private currentStep: string = 'list'
  @State private detailVersion: string = ''
  @State private openingFolder: boolean = false
  /** 当前详情版本的整合包快照（非整合包版本为 null）。进入详情时加载一次。 */
  @State private detailModpackSnap_: ModpackSnapshot | null = null
  /**
   * 详情资源数量 — 拆成 5 个独立的 primitive @State，**绝不**用单一对象/class 容器。
   *
   * 历史教训（实测真机 OpenHarmony 5.0 / API 14）：
   *   - 用 `interface` literal 字面量赋值给 @State：UI 不重渲染（赋值后日志数据正确，
   *     但 Builder 读到的还是旧值）
   *   - 用 `class` 实例赋值给 @State：同样的问题，仍然不刷新
   *   - 单独的 primitive @State number：稳定可靠
   *
   * 因此宁可写 5 行而不是 1 个聚合对象。这是 ArkTS @Component + animateTo +
   * Stack translate 切换 step 时的已知坑：嵌套对象读路径在 dirty-track 里漏报。
   */
  @State private modsCount: number = 0
  @State private modsEnabledCount: number = 0
  @State private shadersCount: number = 0
  @State private resPacksCount: number = 0
  @State private dataPacksCount: number = 0
  @State private savesCount: number = 0
  /** 切换反馈：sheet header 副标题瞬时绿色 "已切换到 ✓"，2.5 s 后清空 */
  @State private switchedHint: string = ''
  private switchedHintTimer: number = 0

  /**
   * 重命名浮层状态：
   *   - showRename:   是否展示重命名浮层
   *   - renameInput:  TextInput 当前文本（初始填入 detailVersion）
   *   - renameError:  即时校验错误（空串 = 无错；非空时在输入框下方红字提示并禁用确定）
   */
  @State private showRename: boolean = false
  @State private renameInput: string = ''
  @State private renameError: string = ''

  /**
   * 单版本「自定义 JVM 参数」内联编辑（版本详情步）：
   *   - jvmArgsExpanded: 是否展开编辑区（点击该行标题切换，animateTo 平滑伸缩）
   *   - versionJvmArgs:  当前 detailVersion 的单版本参数文本。进入详情时由
   *                      loadVersionJvmArgs(ver) 载入，编辑后经 onSaveVersionJvmArgs
   *                      回调交给父组件持久化（本组件保持纯展示，不直接碰 Preferences）。
   */
  @State private jvmArgsExpanded: boolean = false
  @State private versionJvmArgs: string = ''

  /** 当前 detailVersion 的【单版本 JDK 选择】：'' = 跟随全局 | 'auto' = 自动 | 具体版本 = 硬覆盖。
   *  进入详情时由 loadVersionJdk(ver) 载入；选择后经 onSaveVersionJdk 回调持久化。 */
  @State private versionJdk: string = ''

  /** 当前 detailVersion 的【单版本游戏语言】：'' = 跟随全局 | 具体 code（'zh_cn'…）= 硬覆盖。
   *  进入详情时由 loadVersionGameLang(ver) 载入；选择后经 onSaveVersionGameLang 回调持久化。 */
  @State private versionGameLang: string = ''

  /**
   * v3 横向滑动动画（三步：list / detail / resources）：
   *   - slidePos = 0 → list 可见；detail 待命 +100%，resources 待命 +200%
   *   - slidePos = 1 → detail 可见；list 在 -100%，resources 待命 +100%
   *   - slidePos = 2 → resources 可见；list 在 -200%，detail 在 -100%
   *   动画通过 animateTo 驱动 slidePos 在 0 / 1 / 2 间平滑过渡。
   *   每个面板平移量 = (面板序号 - slidePos) * viewportW。
   */
  @State private slidePos: number = 0
  /** 资源步（第三步）当前展示的资源类型；由详情步资源格点击决定 */
  @State private resourceKind: ResourceKind = ResourceKind.MOD
  /** 容器宽度（onAreaChange 测量；fallback 为 375 dp） */
  @State private viewportW: number = 375
  private static readonly ANIM_DURATION_MS = 280

  onSelectVersion: (ver: string) => void = () => {}
  onDeleteVersion: (ver: string) => void = () => {}
  onAddNew: () => void = () => {}
  onCleanupOrphans: () => void = () => {}
  /** 修复某个残留/损坏的版本（父组件走 repairVersionFiles：Forge 深度修复 / 普通增量补全）。 */
  onRepairVersion: (ver: string) => void = () => {}
  onClose: () => void = () => {}
  /**
   * 重命名版本目录。父组件应执行实际的文件系统操作（见 FileUtils.renameVersion），
   * 并在成功后重扫版本列表 / 同步当前选中版本 / 持久化偏好。
   *
   * @returns true = 重命名成功（sheet 据此把详情切到新名 + 关闭浮层）；
   *          false = 失败（父组件已 toast 具体原因，sheet 保持浮层让用户改）。
   * 默认实现 no-op 返回 false，方便老调用方平滑迁移。
   */
  onRenameVersion: (oldVer: string, newVer: string) => boolean = () => false
  /** v2 之后内部不再触发；保留为公开 API */
  onOpenVersionDetail: (ver: string) => void = () => {}
  /**
   * v3：资源步"安装" / 空态按钮 → 关闭本 sheet 并跳到下载 Tab 让用户找新资源。
   * （资源管理改为同 sheet 第三步后，不再用 onManage* 各开一个独立 sheet。）
   */
  onJumpToBrowse: (kind: ResourceKind) => void = () => {}
  /**
   * v3：嵌入的资源步发生启用 / 禁用 / 删除后回调 —— 让父组件刷新首页"已装模组"统计等。
   */
  onResourcesChanged: () => void = () => {}
  /**
   * 读取某版本的【单版本 JDK 选择】：'' = 跟随全局 | 'auto' = 自动路由 | 具体版本（'8'/'17'/'21'/'25'）= 硬覆盖。
   * 父组件接 PreferenceManager.getVersionOverride(ver).jdkVersion。默认 ''（跟随全局）。
   */
  loadVersionJdk: (ver: string) => string = () => ''
  /**
   * 持久化某版本的【单版本 JDK 选择】。父组件接 PreferenceManager.setVersionOverride
   * （只改 jdkVersion 字段，其余保持）+ 刷新 jdkReady。choice ∈ '' | 'auto' | 具体版本。默认 no-op。
   */
  onSaveVersionJdk: (ver: string, choice: string) => void = () => {}

  /**
   * 读取某版本的【单版本游戏语言】：'' = 跟随全局 | 具体 code（'zh_cn'/'en_us'…）= 硬覆盖。
   * 父组件接 PreferenceManager.getVersionOverride(ver).gameLanguage。默认 ''（跟随全局）。
   */
  loadVersionGameLang: (ver: string) => string = () => ''
  /**
   * 持久化某版本的【单版本游戏语言】。父组件接 PreferenceManager.setVersionOverride
   * （只改 gameLanguage 字段，其余保持）。code ∈ '' | 具体 code。默认 no-op。
   */
  onSaveVersionGameLang: (ver: string, code: string) => void = () => {}

  /**
   * 读取某版本的"单版本自定义 JVM 参数"。父组件接 PreferenceManager.getVersionOverride。
   * 同步返回（Preferences 读取是同步的）。默认空实现返回 ''。
   */
  loadVersionJvmArgs: (ver: string) => string = () => ''
  /**
   * 持久化某版本的"单版本自定义 JVM 参数"。父组件接 PreferenceManager.setVersionOverride
   * （只改 customJvmArgs 字段，其余字段保持）。默认 no-op。
   */
  onSaveVersionJvmArgs: (ver: string, args: string) => void = () => {}
  /** 用户点"校验文件完整性 (SHA1)"：父组件跑 VersionFileVerifier.verifyAll 并展示结果。 */
  onVerifyVersionFiles: (ver: string) => void = () => {}

  /**
   * 版本详情页"启动"：父组件把当前版本切到 ver 并走通用启动路径
   * （launchMC → 启动前硬校验 Sheet → 真正创建 JVM），与首页「启动游戏」同一条链路。
   */
  onLaunchVersion: (ver: string) => void = () => {}

  /**
   * 用户在版本列表长按拖拽排序后，回传新的版本顺序（自上而下）。
   * 父组件持久化（PreferenceManager.versionOrder）并即时应用到 availableVersions。
   * 仅在未启用 loader 过滤时可拖拽（过滤子集拖拽语义不清晰）。
   */
  onReorderVersions: (newOrder: string[]) => void = () => {}

  /**
   * v3 深链：按 initialStep 决定打开本 sheet 时落在哪一步。
   * bindSheet 每次展开都会重建本组件 → aboutToAppear 必跑，能据此初始化 step / slidePos。
   */
  aboutToAppear() {
    this.orderVersions = this.availableVersions.slice()
    if (this.initialStep === 'resources') {
      let ver = this.initialResourceVersion.length > 0 ? this.initialResourceVersion : this.currentVersion
      this.detailVersion = ver
      this.resourceKind = this.initialResourceKind
      this.resetDetailCounts()
      this.refreshDetailResStat(ver)
      this.loadVersionJvmArgsState(ver)
      this.loadModpackSnapshot_(ver)
      this.currentStep = 'resources'
      this.slidePos = 2
    } else if (this.initialStep === 'detail') {
      let ver = this.initialResourceVersion.length > 0 ? this.initialResourceVersion : this.currentVersion
      this.detailVersion = ver
      this.resetDetailCounts()
      this.refreshDetailResStat(ver)
      this.loadModpackSnapshot_(ver)
      this.loadVersionJvmArgsState(ver)
      this.currentStep = 'detail'
      this.slidePos = 1
    } else {
      this.currentStep = 'list'
      this.slidePos = 0
    }
  }

  /**
   * 父组件 availableVersions 变化（下载/删除/重命名/重排回传后）时同步本地 orderVersions。
   * 拖拽进行中（draggingVer 非空）不重置，避免把用户正在拖的实时顺序冲掉。
   */
  private onAvailableVersionsChange() {
    if (this.draggingVer.length > 0) return
    this.orderVersions = this.availableVersions.slice()
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
    Column() {
      // Drag pill（三个 step 共用）
      Row() {
        Column().width(36).height(4).backgroundColor(this.theme.divider).borderRadius(2)
      }
      .width('100%').justifyContent(FlexAlign.Center).padding({ top: 10, bottom: 6 })

      // ============== 三步内容容器（横向滑动）==============
      // 用 Stack 同时挂载 list / detail / resources，靠 translate 决定可见性；
      // clip 锁视口避免溢出。每个面板平移量 = (面板序号 - slidePos) * viewportW。
      Stack() {
        // List step（序号 0）
        Column() {
          this.ListStep()
        }
        .width('100%').height('100%')
        .translate({ x: (0 - this.slidePos) * this.viewportW })

        // Detail step（序号 1）
        Column() {
          this.DetailStep()
        }
        .width('100%').height('100%')
        .translate({ x: (1 - this.slidePos) * this.viewportW })

        // Resources step（序号 2）—— 内嵌 InstalledResourcesSheet（embedded 模式）
        Column() {
          this.ResourcesStep()
        }
        .width('100%').height('100%')
        .translate({ x: (2 - this.slidePos) * this.viewportW })

        // Saves step（序号 3）—— 内嵌 SavesManagerSheet（embedded 模式）
        Column() {
          this.SavesStep()
        }
        .width('100%').height('100%')
        .translate({ x: (3 - this.slidePos) * this.viewportW })

        // Files step（序号 4）—— 内嵌 VersionFileBrowser（虚拟文件管理器）
        Column() {
          this.FilesStep()
        }
        .width('100%').height('100%')
        .translate({ x: (4 - this.slidePos) * this.viewportW })
      }
      .width('100%')
      .layoutWeight(1)
      .clip(true)
      .onAreaChange((_, area) => {
        // 用容器实际宽度做平移基准，适配横屏 / 折叠屏
        let w = area.width as number
        if (w > 0 && Math.abs(w - this.viewportW) > 0.5) {
          this.viewportW = w
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.bgPrimary)

      // 重命名浮层：覆盖整个版本管理 sheet，半透明遮罩点击空白处关闭
      if (this.showRename) {
        this.RenameOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }

  // ============================================================
  //  Step 3：已装资源管理（同 sheet 内嵌 InstalledResourcesSheet）
  // ============================================================

  @Builder
  ResourcesStep() {
    InstalledResourcesSheet({
      theme: this.theme,
      bottomSafeHeight: this.bottomSafeHeight,
      mcDir: this.mcDir,
      versionId: this.detailVersion,
      versionIsolation: this.versionIsolation,
      kind: this.resourceKind,
      // 嵌入宿主 sheet：用"← 版本详情"返回按钮取代拖拽指示条
      embedded: true,
      // 仅当真正滑到资源步时才扫描磁盘 / 拉图标（避免每次进详情都白扫一遍）
      active: this.currentStep === 'resources',
      onBack: () => { this.backToDetail() },
      // 资源步"安装" / 空态会先 onClose 再 onJumpToBrowse；这里 onClose = 关闭整个版本管理 sheet
      onClose: () => { this.onClose() },
      onJumpToBrowse: (kind: ResourceKind) => { this.onJumpToBrowse(kind) },
      onChanged: () => {
        // 启用/禁用/删除后：刷新详情步资源计数 + 冒泡给父组件刷新首页统计
        this.refreshDetailResStat(this.detailVersion)
        this.onResourcesChanged()
      },
    })
  }

  // ============================================================
  //  Step 4：存档管理（同 sheet 内嵌 SavesManagerSheet）
  // ============================================================

  @Builder
  SavesStep() {
    SavesManagerSheet({
      theme: this.theme,
      bottomSafeHeight: this.bottomSafeHeight,
      mcDir: this.mcDir,
      versionId: this.detailVersion,
      versionIsolation: this.versionIsolation,
      embedded: true,
      active: this.currentStep === 'saves',
      onBack: () => { this.backToDetail() },
      onClose: () => { this.onClose() },
      onChanged: () => {
        this.refreshDetailResStat(this.detailVersion)
        this.onResourcesChanged()
      },
    })
  }

  // ============================================================
  //  Step 5：版本文件夹（虚拟文件管理器，同 sheet 内嵌 VersionFileBrowser）
  // ============================================================

  @Builder
  FilesStep() {
    VersionFileBrowser({
      theme: this.theme,
      bottomSafeHeight: this.bottomSafeHeight,
      mcDir: this.mcDir,
      versionId: this.detailVersion,
      versionIsolation: this.versionIsolation,
      embedded: true,
      active: this.currentStep === 'files',
      onBack: () => { this.backToDetail() },
      onClose: () => { this.onClose() },
      onChanged: () => {
        this.refreshDetailResStat(this.detailVersion)
        this.onResourcesChanged()
      },
    })
  }

  // ============================================================
  //  Step 1：版本列表
  // ============================================================

  @Builder
  ListStep() {
    // ============== Sheet Header ==============
    Row() {
      Column({ space: 2 }) {
        Text('版本管理')
          .fontSize(22).fontWeight(700).fontColor(this.theme.textPrimary)
        if (this.switchedHint.length > 0) {
          Text(this.switchedHint)
            .fontSize(11).fontWeight(600).fontColor(this.theme.success)
        } else {
          Text(this.headerSubtitle())
            .fontSize(11).fontColor(this.theme.textHint)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Row({ space: 5 }) {
        AppIcon({ name: AppIconName.Plus, iconSize: 14, color: this.theme.textOnPrimary, weight: FontWeight.Bold })
        Text('新增').fontSize(12).fontWeight(600).fontColor(this.theme.textOnPrimary)
      }
      .height(32)
      .padding({ left: 12, right: 12 })
      .borderRadius(16)
      .backgroundColor(this.theme.primary)
      .alignItems(VerticalAlign.Center)
      .onClick(() => { this.onAddNew() })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 6, bottom: 12 })
    .alignItems(VerticalAlign.Center)

    // ============== 过滤 Chips ==============
    Scroll() {
      Row({ space: 6 }) {
        this.FilterChip('', '全部')
        this.FilterChip('vanilla', '原版')
        this.FilterChip('fabric', 'Fabric')
        this.FilterChip('forge', 'Forge')
        Row({ space: 4 }) {
          Text('时间').fontSize(11).fontWeight(500).fontColor(this.theme.textSecondary)
          AppIcon({ name: AppIconName.ChevronDown, iconSize: 11, color: this.theme.textSecondary })
        }
        .height(28)
        .padding({ left: 10, right: 10 })
        .borderRadius(14)
        .backgroundColor(this.theme.bgCard)
        .alignItems(VerticalAlign.Center)
      }
      .padding({ left: 20, right: 20 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .padding({ bottom: 8 })

    // ============== 版本列表 ==============
    if (this.availableVersions.length === 0 && this.orphanVersionDirs.length === 0) {
      this.EmptyState()
    } else {
      List({ space: 10 }) {
        ForEach(this.filteredVersions(), (ver: string) => {
          ListItem() {
            this.VersionRow(ver)
          }
        }, (ver: string) => ver)

        if (this.orphanVersionDirs.length > 0) {
          ListItem() {
            this.OrphansHintCard()
          }
          ForEach(this.orphanVersionDirs, (name: string) => {
            ListItem() {
              this.OrphanRow(name)
            }
          }, (name: string) => 'orphan:' + name)
        }

        ListItem() {
          Text('已安装 ' + this.availableVersions.length + ' 个版本'
            + (this.versionIsolation ? '  ·  版本隔离已开启' : '  ·  存档共享'))
            .fontSize(11)
            .fontWeight(400)
            .fontColor(this.theme.textHint)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 12, bottom: 30 })
        }
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 20, right: 20 })
      .scrollBar(BarState.Off)
      // ====== 长按拖拽排序（鸿蒙 List 原生拖拽 API + 实时重排动画）======
      // 仅未过滤时启用（过滤子集拖拽语义不清晰，onItemDragStart 返回 void 即禁用）。
      // 手感优化：onItemDragStart 提起原行（半透明）；onItemDragMove 实时让位 + animateTo
      // 平滑滑动；onItemDrop 落定后回传父组件持久化。
      .onItemDragStart((event: ItemDragInfo, itemIndex: number) => {
        if (this.filterLoader.length > 0) return
        let list = this.orderVersions
        if (itemIndex < 0 || itemIndex >= list.length) return
        this.draggingVer = list[itemIndex]
        this.dragCurIndex_ = itemIndex
        return this.DragPreview(list[itemIndex])
      })
      .onItemDragMove((event: ItemDragInfo, itemIndex: number, insertIndex: number) => {
        // 实时重排：用自管的 dragCurIndex_（回调里的 itemIndex 会过期）。
        if (this.draggingVer.length === 0 || this.dragCurIndex_ < 0) return
        let n = this.orderVersions.length
        // 只在版本区间内让位（孤儿行 / 页脚不参与）
        if (insertIndex < 0 || insertIndex >= n) return
        if (insertIndex === this.dragCurIndex_) return
        let from = this.dragCurIndex_
        this.getUIContext().animateTo({ duration: 180, curve: Curve.Friction }, () => {
          let moved = this.orderVersions.splice(from, 1)[0]
          this.orderVersions.splice(insertIndex, 0, moved)
        })
        this.dragCurIndex_ = insertIndex
      })
      .onItemDrop((event: ItemDragInfo, itemIndex: number, insertIndex: number, isSuccess: boolean) => {
        if (this.filterLoader.length > 0) { this.endDrag_(); return }
        // 落点若在版本区间外，保持 onItemDragMove 已实时排好的顺序即可。
        this.persistOrder_()
        // 归位动画：被提起的行（opacity 0.28）带弹性回落到不透明，配合实时重排已就位的
        // 槽位，读起来就是"卡片落回原位"。springMotion 给自然的回弹收尾。
        this.dragCurIndex_ = -1
        this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.85) }, () => {
          this.draggingVer = ''
        })
      })
    }
  }

  // ============================================================
  //  VersionRow（核心 v2 改动）— 行体职责分离 + 当前版本边框高亮
  // ============================================================

  @Builder
  VersionRow(ver: string) {
    // 2026-05-22 压缩布局给标题让位：原 48 图标 + 56 管理按钮 + 1px 分隔线 +
    // 卡片 padding 占 ~140px，加 LoaderBadge 后留给 versionId 仅 ~190px，长 fabric/forge id
    // 被截到仅剩 7~9 字符。现在图标 40 + 按钮 44 + 去掉分隔线 + padding 收紧，
    // 同时标题 maxLines:2 使长 id 能完整读出。
    Row({ space: 8 }) {
      // ----- 左侧 BodySelect 区（点击 = 切换当前版本）-----
      Row({ space: 10 }) {
        // 拖拽手柄（仅未过滤时显示；此时长按整行可拖拽排序）。点按无副作用，长按触发拖拽。
        if (this.filterLoader.length === 0 && this.availableVersions.length > 1) {
          AppIcon({ name: AppIconName.DragHandle, iconSize: 14, color: this.theme.textHint })
        }
        // 图标 —— PCL2 同款方块图标：草方块/命令方块/金块/圆石/铁砧/Fabric/Quilt/NeoForge
        // 不再用旧的 AppIcon SymbolGlyph + 主题色背景：方块贴图自带颜色识别度，
        // 包一层背景反而冲突。版本类别由 classifyVersion(versionId) 推断。
        // cornerRadius=0：3D 方块边角是图本身的视觉特征（草方块的草边、铁砧的金属角），
        // 切圆角会把这些细节剪掉，反而失去立体感
        VersionBlockIcon({
          versionId: ver,
          iconSize: 40,
          cornerRadius: 0,
          overrideImagePath: getModpackIconPath(this.mcDir, ver),
        })
        .width(40).height(40)

        Column({ space: 3 }) {
          Row({ space: 6 }) {
            Text(ver)
              .fontSize(14)
              .fontWeight(600)
              .fontColor(this.theme.textPrimary)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .lineHeight(18)
              .layoutWeight(1)
            this.LoaderBadge(ver)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)

          Text(this.metaLine(ver))
            .fontSize(11)
            .fontWeight(500)
            .fontColor(this.theme.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .layoutWeight(1)
      .alignItems(VerticalAlign.Center)
      .onClick(() => { this.handleSelectVersion(ver) })

      // ----- 右侧管理按钮（点击 = 切到 detail step）-----
      // 2026-05-22：去掉中间分隔线、缩小按钮 width 56→44，iconSize 18→16，
      // 多留 ~14px 横向空间给标题。
      Column({ space: 1 }) {
        AppIcon({ name: AppIconName.SettingsFilled, iconSize: 16, color: this.theme.primary })
        Text('管理').fontSize(10).fontWeight(600).fontColor(this.theme.primary)
      }
      .width(44)
      .height(54)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .borderRadius(10)
      .backgroundColor(this.theme.bgInput)
      .onClick(() => { this.gotoDetail(ver) })
    }
    .width('100%')
    .padding({ left: 10, right: 8, top: 10, bottom: 10 })
    .backgroundColor(this.theme.bgCard)
    .borderRadius(14)
    .border(this.currentVersionBorder(ver))
    .alignItems(VerticalAlign.Center)
    .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
    // 被拖拽的原行"提起"：半透明留出占位，浮层（DragPreview）跟随手指。
    .opacity(this.draggingVer === ver ? 0.28 : 1)
  }

  /** 当前版本：2 px primary 蓝边框；其他：无边框（透明 0 厚度） */
  private currentVersionBorder(ver: string): BorderOptions {
    if (ver === this.currentVersion) {
      return {
        width: 2,
        color: this.theme.primary,
        style: BorderStyle.Solid,
      }
    }
    return { width: 0, color: '#00000000' }
  }

  @Builder
  LoaderBadge(ver: string) {
    Text(this.versionTypeLabel(ver))
      .fontSize(10)
      .fontWeight(700)
      .fontColor(this.versionTypeFg(ver))
      .padding({ left: 7, right: 7, top: 2, bottom: 2 })
      .borderRadius(5)
      .backgroundColor(this.versionTypeBg(ver))
  }

  @Builder
  FilterChip(loader: string, label: string) {
    Text(label)
      .fontSize(11)
      .fontWeight(this.filterLoader === loader ? 600 : 500)
      .fontColor(this.filterLoader === loader ? this.theme.textOnPrimary : this.theme.textSecondary)
      .height(28)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(14)
      .backgroundColor(this.filterLoader === loader ? this.theme.primary : this.theme.bgCard)
      .onClick(() => { this.filterLoader = loader })
  }

  @Builder
  OrphansHintCard() {
    Row({ space: 8 }) {
      AppIcon({ name: AppIconName.Warning, iconSize: 14, color: '#D97706' })
      Text(this.orphanVersionDirs.length + ' 个版本不完整 / 损坏（安装中断或文件缺失）。可逐个修复或清理：')
        .fontSize(11)
        .fontWeight(500)
        .fontColor('#92400E')
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Row() {
        Text('全部清理')
          .fontSize(11)
          .fontWeight(600)
          .fontColor('#D97706')
      }
      .height(26)
      .padding({ left: 10, right: 10 })
      .borderRadius(13)
      .backgroundColor(this.theme.bgCard)
      .justifyContent(FlexAlign.Center)
      .onClick(() => { this.onCleanupOrphans() })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor('#FEF3C7')
    .borderRadius(12)
    .alignItems(VerticalAlign.Center)
  }

  /** 单个残留/损坏版本行：红色标识 + 修复 / 删除。让用户能直接处理坏版本，不被挡在列表外。 */
  @Builder
  OrphanRow(name: string) {
    Row({ space: 8 }) {
      AppIcon({ name: AppIconName.Warning, iconSize: 18, color: this.theme.error })
      Column({ space: 3 }) {
        Row({ space: 6 }) {
          Text(name)
            .fontSize(14)
            .fontWeight(600)
            .fontColor(this.theme.error)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(18)
            .layoutWeight(1)
          Text('损坏')
            .fontSize(10).fontWeight(700).fontColor(this.theme.textOnPrimary)
            .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            .borderRadius(5).backgroundColor(this.theme.error)
        }
        .width('100%').alignItems(VerticalAlign.Top)
        Text('文件不完整，无法启动。可尝试修复或删除。')
          .fontSize(11).fontWeight(500).fontColor(this.theme.textSecondary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Column({ space: 1 }) {
        AppIcon({ name: AppIconName.Refresh, iconSize: 16, color: this.theme.primary })
        Text('修复').fontSize(10).fontWeight(600).fontColor(this.theme.primary)
      }
      .width(44).height(54)
      .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      .borderRadius(10).backgroundColor(this.theme.primaryLight)
      .onClick(() => { this.onRepairVersion(name) })

      Column({ space: 1 }) {
        AppIcon({ name: AppIconName.Trash, iconSize: 16, color: this.theme.error })
        Text('删除').fontSize(10).fontWeight(600).fontColor(this.theme.error)
      }
      .width(44).height(54)
      .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      .borderRadius(10).backgroundColor(this.theme.bgInput)
      .onClick(() => { this.onDeleteVersion(name) })
    }
    .width('100%')
    .padding({ left: 10, right: 8, top: 10, bottom: 10 })
    .backgroundColor(this.theme.bgCard)
    .borderRadius(14)
    .border({ width: 1, color: this.theme.error, style: BorderStyle.Solid })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  EmptyState() {
    Column({ space: 12 }) {
      AppIcon({ name: AppIconName.GameController, iconSize: 56, color: this.theme.textHint })
      Text('暂无已安装的版本')
        .fontSize(16)
        .fontWeight(500)
        .fontColor(this.theme.textPrimary)
      Text('点击右上角"+ 新增"或前往「下载」页')
        .fontSize(12)
        .fontColor(this.theme.textHint)
      Row({ space: 5 }) {
        AppIcon({ name: AppIconName.Plus, iconSize: 12, color: this.theme.textOnPrimary, weight: FontWeight.Bold })
        Text('立即新建').fontSize(13).fontWeight(600).fontColor(this.theme.textOnPrimary)
      }
      .height(36)
      .padding({ left: 18, right: 18 })
      .borderRadius(18)
      .backgroundColor(this.theme.primary)
      .alignItems(VerticalAlign.Center)
      .margin({ top: 8 })
      .onClick(() => { this.onAddNew() })
    }
    .width('100%')
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 32, right: 32, bottom: 60 })
  }

  // ============================================================
  //  Step 2：版本详情视图（同 sheet 内切换）
  // ============================================================

  @Builder
  DetailStep() {
    // ----- header：← 版本管理 / 版本详情 / 重命名 -----
    Row({ space: 10 }) {
      Row({ space: 4 }) {
        AppIcon({ name: AppIconName.ChevronLeft, iconSize: 14, color: this.theme.textPrimary })
        Text('版本管理').fontSize(12).fontWeight(600).fontColor(this.theme.textSecondary)
      }
      .height(32)
      .padding({ left: 10, right: 12 })
      .borderRadius(16)
      .backgroundColor(this.theme.bgInput)
      .alignItems(VerticalAlign.Center)
      .onClick(() => { this.backToList() })

      Column({ space: 1 }) {
        Text('版本详情')
          .fontSize(13)
          .fontWeight(600)
          .fontColor(this.theme.textPrimary)
        Text(this.detailVersion || '—')
          .fontSize(11)
          .fontWeight(500)
          .fontColor(this.theme.textHint)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Row() {
        AppIcon({ name: AppIconName.Edit, iconSize: 14, color: this.theme.textSecondary })
      }
      .width(32).height(32)
      .borderRadius(16)
      .backgroundColor(this.theme.bgInput)
      .justifyContent(FlexAlign.Center)
      .onClick(() => { this.openRename() })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 4, bottom: 12 })
    .alignItems(VerticalAlign.Center)

    // ----- 滚动内容区 -----
    Scroll() {
      Column({ space: 12 }) {
        this.DetailHeroCard()
        this.DetailActionRow()
        if (this.detailModpackSnap_ !== null) {
          this.DetailModpackCard()
        }
        this.DetailResourcesCard()
        this.DetailConfigCard()
        this.DetailFilesCard()
        if (this.isExternalStorage) {
          this.DetailFoldersCard()
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: this.bottomSafeHeight + 24 })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
  }

  @Builder
  DetailHeroCard() {
    Row({ space: 12 }) {
      // Hero 图标：56dp 方块图标（PCL2 同款），在 primary 蓝底上视觉对比足够
      // 不再用旧的 SymbolGlyph + 深蓝色块叠加，避免与卡片底色冲突
      Stack() {
        // 浅色底框，让方块贴图在深色 primary 背景上有"卡片感"
        Column().width(56).height(56).backgroundColor('#FFFFFF20').borderRadius(14)
        VersionBlockIcon({
          versionId: this.detailVersion,
          iconSize: 44,
          cornerRadius: 0,
          overrideImagePath: getModpackIconPath(this.mcDir, this.detailVersion),
        })
      }
      .width(56).height(56)

      Column({ space: 4 }) {
        Text('Minecraft ' + this.detailMcVersion())
          .fontSize(16)
          .fontWeight(700)
          .fontColor(this.theme.textOnPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 6 }) {
          AppIcon({ name: this.detailHeroIcon(), iconSize: 12, color: '#BFDBFE' })
          Text(this.detailLoaderText())
            .fontSize(12)
            .fontWeight(500)
            .fontColor('#BFDBFE')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(VerticalAlign.Center)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.detailVersion === this.currentVersion) {
        Text('当前')
          .fontSize(11)
          .fontWeight(700)
          .fontColor(this.theme.textOnPrimary)
          .height(24)
          .padding({ left: 10, right: 10 })
          .borderRadius(12)
          .backgroundColor('#FFFFFF40')
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.theme.primary)
    .borderRadius(16)
    .alignItems(VerticalAlign.Center)
  }

  /** 整合包信息卡：来源 / 包版本 / loader + 缺失项复查（仅整合包版本显示）。 */
  @Builder
  DetailModpackCard() {
    if (this.detailModpackSnap_ !== null) {
      Column({ space: 8 }) {
        Text('·  整合包')
          .fontSize(11).fontWeight(600).fontColor(this.theme.textHint).width('100%')

        Row({ space: 8 }) {
          AppIcon({ name: AppIconName.ModPack, iconSize: 18, color: this.theme.primary })
          Column({ space: 2 }) {
            Text(this.modpackSourceLabel_(this.detailModpackSnap_.source)
              + (this.detailModpackSnap_.packVersion.length > 0 ? ' · v' + this.detailModpackSnap_.packVersion : ''))
              .fontSize(13).fontWeight(600).fontColor(this.theme.textPrimary)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('MC ' + this.detailModpackSnap_.gameVersion
              + (this.detailModpackSnap_.loaderType.length > 0 && this.detailModpackSnap_.loaderType !== 'none'
                ? ' · ' + this.detailModpackSnap_.loaderType : ''))
              .fontSize(11).fontWeight(500).fontColor(this.theme.textSecondary)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)
        }
        .width('100%').padding(12)
        .backgroundColor(this.theme.bgInput).borderRadius(12)
        .alignItems(VerticalAlign.Center)

        if (this.detailModpackSnap_.missing.length > 0) {
          Row({ space: 8 }) {
            AppIcon({ name: AppIconName.Warning, iconSize: 16, color: this.theme.error })
            Text(this.detailModpackSnap_.missing.length + ' 项内容安装时缺失')
              .fontSize(12).fontWeight(500).fontColor(this.theme.error).layoutWeight(1)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('复制清单')
              .fontSize(12).fontWeight(600).fontColor(this.theme.primary)
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .onClick(() => {
                if (this.detailModpackSnap_ !== null) this.copyModpackMissing_(this.detailModpackSnap_)
              })
          }
          .width('100%').padding({ left: 12, right: 8, top: 8, bottom: 8 })
          .backgroundColor(this.theme.errorBg).borderRadius(12)
          .alignItems(VerticalAlign.Center)
        }
      }
      .width('100%')
    }
  }

  /** 整合包来源 → 展示标签。 */
  private modpackSourceLabel_(source: string): string {
    if (source === 'modrinth') return 'Modrinth 整合包'
    if (source === 'curseforge') return 'CurseForge 整合包'
    return '整合包'
  }

  @Builder
  DetailActionRow() {
    Row({ space: 8 }) {
      this.DetailActionBtn(AppIconName.Play, '启动', this.theme.success, '#FFFFFF', () => {
        // 正式接入通用启动路径：切到详情版本，父组件走 launchMC（启动前校验 → 真正启动）。
        if (this.detailVersion.length > 0) this.onLaunchVersion(this.detailVersion)
      })
      this.DetailActionBtn(AppIconName.Copy, '复制', this.theme.bgCard, this.theme.textSecondary, () => {
        this.getUIContext().getPromptAction().showToast({ message: '复制版本功能 R-5 接入', duration: 1500 })
      })
      this.DetailActionBtn(AppIconName.Trash, '删除', this.theme.errorBg, this.theme.error, () => {
        this.handleDetailDelete()
      })
    }
    .width('100%')
    .height(48)
  }

  @Builder
  DetailActionBtn(icon: AppIconName, label: string, bg: ResourceColor, fg: ResourceColor, action: () => void) {
    Row({ space: 6 }) {
      AppIcon({ name: icon, iconSize: 14, color: fg, weight: FontWeight.Bold })
      Text(label).fontSize(13).fontWeight(600).fontColor(fg)
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .borderRadius(14)
    .backgroundColor(bg)
    .onClick(() => action())
  }

  /**
   * v3 修复（2026-05-18）：4 个资源格全部 inline 渲染，不再走 `DetailResCell(...)`
   * 这种 @Builder 函数参数式调用。
   *
   * 历史 bug：`this.DetailResCell(icon, this.modsCount, ...)` 把 primitive @State
   * 当**值参数**传进 @Builder。ArkUI 在 Stack/translate 横滑 + animateTo 同步的
   * 双重场景下，对透过 @Builder 参数路径的 primitive @State **脏标记会漏报** —
   * 子 cell 拿到的 count 永远停在 step 切换那一刻的 0，即使父组件 @State 已刷成 4。
   *
   * 唯一稳定的做法：在容器节点内**直接读 this.modsCount**，不经任何参数传递。
   * 因此这里把所有 cell 体复制 4 份内联（多了 ~30 行代码，换换正确性）。
   */
  @Builder
  DetailResourcesCard() {
    Column({ space: 10 }) {
      Text('·  资源管理')
        .fontSize(11)
        .fontWeight(600)
        .fontColor(this.theme.textHint)
        .width('100%')

      Row({ space: 8 }) {
        // ===== 模组 cell =====
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            AppIcon({
              name: AppIconName.Mod,
              iconSize: 16,
              color: this.modsCount > 0 ? this.theme.textPrimary : this.theme.textHint,
            })
            Text(this.modsCount.toString())
              .fontSize(16)
              .fontWeight(700)
              .fontColor(this.modsCount > 0 ? this.theme.textPrimary : this.theme.textHint)
          }
          .alignItems(VerticalAlign.Center)
          Text('模组 · ' + this.modsHint())
            .fontSize(11)
            .fontWeight(500)
            .fontColor(this.theme.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1).height('100%').padding(12)
        .backgroundColor(this.theme.bgInput).borderRadius(12)
        .alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Center)
        .onClick(() => { this.handleManageMods() })

        // ===== 光影 cell =====
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            AppIcon({
              name: AppIconName.Shader,
              iconSize: 16,
              color: this.shadersCount > 0 ? this.theme.textPrimary : this.theme.textHint,
            })
            Text(this.shadersCount.toString())
              .fontSize(16)
              .fontWeight(700)
              .fontColor(this.shadersCount > 0 ? this.theme.textPrimary : this.theme.textHint)
          }
          .alignItems(VerticalAlign.Center)
          Text('光影 · ' + this.shadersHint())
            .fontSize(11)
            .fontWeight(500)
            .fontColor(this.theme.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1).height('100%').padding(12)
        .backgroundColor(this.theme.bgInput).borderRadius(12)
        .alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Center)
        .onClick(() => { this.handleManageShaders() })
      }
      .width('100%').height(80)

      Row({ space: 8 }) {
        // ===== 资源包 cell =====
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            AppIcon({
              name: AppIconName.ResourcePack,
              iconSize: 16,
              color: this.resPacksCount > 0 ? this.theme.textPrimary : this.theme.textHint,
            })
            Text(this.resPacksCount.toString())
              .fontSize(16)
              .fontWeight(700)
              .fontColor(this.resPacksCount > 0 ? this.theme.textPrimary : this.theme.textHint)
          }
          .alignItems(VerticalAlign.Center)
          Text('资源包 · ' + this.resPacksHint())
            .fontSize(11)
            .fontWeight(500)
            .fontColor(this.theme.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1).height('100%').padding(12)
        .backgroundColor(this.theme.bgInput).borderRadius(12)
        .alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Center)
        .onClick(() => { this.handleManageResPacks() })

        // ===== 数据包 cell =====
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            AppIcon({
              name: AppIconName.DataPack,
              iconSize: 16,
              color: this.dataPacksCount > 0 ? this.theme.textPrimary : this.theme.textHint,
            })
            Text(this.dataPacksCount.toString())
              .fontSize(16)
              .fontWeight(700)
              .fontColor(this.dataPacksCount > 0 ? this.theme.textPrimary : this.theme.textHint)
          }
          .alignItems(VerticalAlign.Center)
          Text('数据包 · ' + this.dataPacksHint())
            .fontSize(11)
            .fontWeight(500)
            .fontColor(this.theme.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1).height('100%').padding(12)
        .backgroundColor(this.theme.bgInput).borderRadius(12)
        .alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Center)
        .onClick(() => { this.handleManageDataPacks() })
      }
      .width('100%').height(80)

      // ===== 存档 cell（整行，含导入/导出）=====
      Row({ space: 8 }) {
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            AppIcon({
              name: AppIconName.Save,
              iconSize: 16,
              color: this.savesCount > 0 ? this.theme.textPrimary : this.theme.textHint,
            })
            Text(this.savesCount.toString())
              .fontSize(16)
              .fontWeight(700)
              .fontColor(this.savesCount > 0 ? this.theme.textPrimary : this.theme.textHint)
          }
          .alignItems(VerticalAlign.Center)
          Text('存档 · ' + this.savesHint())
            .fontSize(11)
            .fontWeight(500)
            .fontColor(this.theme.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Center)
        .layoutWeight(1)

        Row({ space: 5 }) {
          AppIcon({ name: AppIconName.Import, iconSize: 14, color: this.theme.textOnPrimary })
          Text('导入 / 导出')
            .fontSize(12).fontWeight(600).fontColor(this.theme.textOnPrimary)
        }
        .height(34).padding({ left: 14, right: 14 }).borderRadius(17)
        .backgroundColor(this.theme.primary).alignItems(VerticalAlign.Center)
      }
      .width('100%').height(64)
      .padding({ left: 12, right: 12 })
      .backgroundColor(this.theme.bgInput).borderRadius(12)
      .alignItems(VerticalAlign.Center)
      .onClick(() => { this.handleManageSaves() })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.theme.bgCard)
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
  }

  // 版本文件夹入口卡片：进入虚拟文件管理器（沙箱内/外通用，浏览+导入导出+删除+重命名+新建）。
  @Builder
  DetailFilesCard() {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.Center }) {
        Column().width(36).height(36).borderRadius(9).backgroundColor(this.theme.primaryLight)
        AppIcon({ name: AppIconName.Folder, iconSize: 18, color: this.theme.primary })
      }
      .width(36).height(36)

      Column({ space: 2 }) {
        Text('版本文件夹')
          .fontSize(14).fontWeight(600).fontColor(this.theme.textPrimary)
        Text('浏览 / 导入 / 导出此版本的文件')
          .fontSize(11).fontWeight(500).fontColor(this.theme.textHint)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      AppIcon({ name: AppIconName.ChevronRight, iconSize: 16, color: this.theme.textHint })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    .backgroundColor(this.theme.bgCard).borderRadius(14)
    .alignItems(VerticalAlign.Center)
    .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
    .onClick(() => { this.gotoFiles() })
  }

  @Builder
  DetailConfigCard() {
    Column() {
      Text('·  启动配置')
        .fontSize(11)
        .fontWeight(600)
        .fontColor(this.theme.textHint)
        .width('100%')

      Row() {
        Row({ space: 6 }) {
          AppIcon({ name: AppIconName.Memory, iconSize: 13, color: this.theme.textSecondary })
          Text('JVM 最大内存').fontSize(13).fontWeight(500).fontColor(this.theme.textPrimary)
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)

        Text(this.mcXmx > 0 ? this.mcXmx + ' MB' : '—')
          .fontSize(13)
          .fontWeight(700)
          .fontColor(this.theme.primary)
      }
      .width('100%')
      .padding({ top: 12, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      Row().width('100%').height(1).backgroundColor(this.theme.divider)

      Row() {
        Row({ space: 6 }) {
          AppIcon({ name: AppIconName.Java, iconSize: 13, color: this.theme.textSecondary })
          Text('Java 运行时').fontSize(13).fontWeight(500).fontColor(this.theme.textPrimary)
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)

        Row({ space: 4 }) {
          Text(this.versionJdkLabel())
            .fontSize(12).fontWeight(600).fontColor(this.theme.primary)
          AppIcon({ name: AppIconName.ChevronDown, iconSize: 11, color: this.theme.primary })
        }
        .height(28)
        .padding({ left: 10, right: 10 })
        .borderRadius(14)
        .backgroundColor(this.theme.primaryLight)
        .alignItems(VerticalAlign.Center)
        // 点开 menu 让用户选【该版本】的 JDK：跟随全局 / 自动 / 具体版本（硬覆盖，可选错调试）
        .bindMenu(this.buildJdkVersionMenu())
      }
      .width('100%')
      .padding({ top: 12, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      Row().width('100%').height(1).backgroundColor(this.theme.divider)

      // 游戏语言（该版本 options.txt lang）：跟随全局 / 单版本覆盖
      Row() {
        Row({ space: 6 }) {
          AppIcon({ name: AppIconName.Language, iconSize: 13, color: this.theme.textSecondary })
          Text('游戏语言').fontSize(13).fontWeight(500).fontColor(this.theme.textPrimary)
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)

        Row({ space: 4 }) {
          Text(this.versionGameLangLabel())
            .fontSize(12).fontWeight(600).fontColor(this.theme.primary)
            .constraintSize({ maxWidth: 140 })
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          AppIcon({ name: AppIconName.ChevronDown, iconSize: 11, color: this.theme.primary })
        }
        .height(28)
        .padding({ left: 10, right: 10 })
        .borderRadius(14)
        .backgroundColor(this.theme.primaryLight)
        .alignItems(VerticalAlign.Center)
        // 点开 menu 让用户选【该版本】的游戏语言：跟随全局 / 具体语言
        .bindMenu(this.buildGameLangMenu())
      }
      .width('100%')
      .padding({ top: 12, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      Row().width('100%').height(1).backgroundColor(this.theme.divider)

      Row() {
        Row({ space: 6 }) {
          AppIcon({
            name: this.versionIsolation ? AppIconName.IsolateOn : AppIconName.IsolateOff,
            iconSize: 13,
            color: this.theme.textSecondary,
          })
          Text('版本隔离').fontSize(13).fontWeight(500).fontColor(this.theme.textPrimary)
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)

        Text(this.versionIsolation ? '已开启' : '关闭')
          .fontSize(12)
          .fontWeight(600)
          .fontColor(this.versionIsolation ? this.theme.success : this.theme.textHint)
      }
      .width('100%')
      .padding({ top: 12, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      Row().width('100%').height(1).backgroundColor(this.theme.divider)

      // 自定义 JVM 参数（单版本）—— 点击标题行就地展开编辑区，伸长本卡片
      Column() {
        Row() {
          Row({ space: 6 }) {
            AppIcon({ name: AppIconName.Settings, iconSize: 13, color: this.theme.textSecondary })
            Text('自定义 JVM 参数').fontSize(13).fontWeight(500).fontColor(this.theme.textPrimary)
          }
          .layoutWeight(1)
          .alignItems(VerticalAlign.Center)

          Row({ space: 6 }) {
            // 折叠态且有内容时给个"已设置"标签，让用户一眼看出此版本有单独参数
            if (!this.jvmArgsExpanded && this.versionJvmArgs.trim().length > 0) {
              Text('已设置')
                .fontSize(11).fontWeight(600).fontColor(this.theme.primary)
                .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                .borderRadius(8).backgroundColor(this.theme.primaryLight)
            }
            AppIcon({
              name: this.jvmArgsExpanded ? AppIconName.ChevronUp : AppIconName.ChevronDown,
              iconSize: 14,
              color: this.theme.textHint,
            })
          }
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .padding({ top: 12, bottom: this.jvmArgsExpanded ? 10 : 4 })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          let willExpand = !this.jvmArgsExpanded
          // 收起前先落盘，避免编辑后直接点标题收起丢失输入
          if (!willExpand) this.saveVersionJvmArgs()
          this.getUIContext().animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
            this.jvmArgsExpanded = willExpand
          })
        })

        if (this.jvmArgsExpanded) {
          Column({ space: 8 }) {
            TextArea({
              text: this.versionJvmArgs,
              placeholder: '仅作用于此版本 · 空格分隔 · 与全局参数叠加（本版本优先）',
            })
              .width('100%')
              .height(96)
              .fontSize(13)
              .fontColor(this.theme.textPrimary)
              .backgroundColor(this.theme.bgInput)
              .borderRadius(10)
              .onChange((v: string) => { this.versionJvmArgs = v })
              .onBlur(() => { this.saveVersionJvmArgs() })

            Text('留空 = 仅用全局参数。全局参数在「设置」页中编辑。修改后需重新启动游戏生效。')
              .fontSize(11)
              .fontColor(this.theme.textHint)
              .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ bottom: 4 })
        }
      }
      .width('100%')

      Row().width('100%').height(1).backgroundColor(this.theme.divider)

      // 校验文件完整性（SHA1）—— 用户手动触发的全量哈希校验，开销大不进启动热路径
      Row() {
        Row({ space: 6 }) {
          AppIcon({ name: AppIconName.CheckCircle, iconSize: 13, color: this.theme.textSecondary })
          Text('校验文件完整性').fontSize(13).fontWeight(500).fontColor(this.theme.textPrimary)
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)

        Row({ space: 4 }) {
          Text('SHA1')
            .fontSize(11).fontWeight(600).fontColor(this.theme.textHint)
          AppIcon({ name: AppIconName.ChevronRight, iconSize: 14, color: this.theme.textHint })
        }
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({ top: 12, bottom: 4 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => { this.onVerifyVersionFiles(this.detailVersion) })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .backgroundColor(this.theme.bgCard)
    .borderRadius(16)
  }

  @Builder
  DetailFoldersCard() {
    Column() {
      Text('·  在系统文件管理中打开')
        .fontSize(11)
        .fontWeight(600)
        .fontColor(this.theme.textHint)
        .width('100%')

      this.DetailFolderRow(AppIconName.Folder,       '版本根目录', '')
      Row().width('100%').height(1).backgroundColor(this.theme.divider)
      this.DetailFolderRow(AppIconName.Mod,          'mods/', 'mods')
      Row().width('100%').height(1).backgroundColor(this.theme.divider)
      this.DetailFolderRow(AppIconName.Shader,       'shaderpacks/', 'shaderpacks')
      Row().width('100%').height(1).backgroundColor(this.theme.divider)
      this.DetailFolderRow(AppIconName.ResourcePack, 'resourcepacks/', 'resourcepacks')
      Row().width('100%').height(1).backgroundColor(this.theme.divider)
      this.DetailFolderRow(AppIconName.Save,         'saves/', 'saves')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 8 })
    .backgroundColor(this.theme.bgCard)
    .borderRadius(16)
  }

  /**
   * @param sub 子目录名（'' = 版本根目录）。实际路径 = verDir()[ + '/' + sub]。
   */
  @Builder
  DetailFolderRow(icon: AppIconName, name: string, sub: string) {
    Row() {
      Row({ space: 10 }) {
        AppIcon({ name: icon, iconSize: 15, color: this.theme.textSecondary })
        Text(name).fontSize(13).fontWeight(500).fontColor(this.theme.textPrimary)
      }
      .alignItems(VerticalAlign.Center)
      .layoutWeight(1)

      AppIcon({ name: AppIconName.ArrowUpRight, iconSize: 15, color: this.theme.primary })
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => { this.openFolder(sub) })
    .enabled(!this.openingFolder)
  }

  /** 详情版本目录根（含版本隔离判断）。 */
  private verDir(): string {
    if (this.mcDir.length === 0) return ''
    if (!this.versionIsolation) return this.mcDir
    if (this.detailVersion.length === 0) return ''
    return this.mcDir + '/versions/' + this.detailVersion
  }

  /** 取 UIAbilityContext（picker 需要）。 */
  private getAbilityCtx(): common.UIAbilityContext | null {
    try {
      let ctx = AppStorage.get<common.UIAbilityContext>('uiAbilityContext')
      return ctx ? ctx : null
    } catch (e) {
      return null
    }
  }

  /** showToast 会抛异常，统一包一层 try/catch（与 InstalledResourcesSheet 一致）。 */
  private safeToast(message: string, duration: number): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message, duration })
    } catch (e) {
      hilog.warn(0x0000, TAG, 'showToast failed: %{public}s', (e as Error).message)
    }
  }

  /** 在文件管理中打开版本目录下的子目录（sub='' 为版本根）。 */
  private async openFolder(sub: string): Promise<void> {
    if (this.openingFolder || !this.isExternalStorage) return
    let base = this.verDir()
    if (base.length === 0) {
      this.safeToast('目录无效', 1500)
      return
    }
    let dir = sub.length > 0 ? (base + '/' + sub) : base
    let ctx = this.getAbilityCtx()
    if (ctx === null) {
      this.safeToast('上下文不可用', 1500)
      return
    }
    this.openingFolder = true
    try {
      let r = await GameArchiveIO.openFolder(ctx, dir)
      if (!r.launched && r.message.length > 0) {
        this.safeToast(r.message, 3000)
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, 'openFolder failed: %{public}s', (e as Error).message)
      this.safeToast('打开失败：' + (e as Error).message, 2000)
    } finally {
      this.openingFolder = false
    }
  }

  // ============================================================
  //  Step transitions / 行为 helpers
  // ============================================================

  private handleSelectVersion(ver: string): void {
    if (ver === this.currentVersion) {
      // 已是当前版本：仅做轻提示，不重复触发上层 onSelectVersion
      this.flashSwitched(ver, '已是当前版本')
      return
    }
    this.onSelectVersion(ver)
    this.flashSwitched(ver, '已切换到 ' + ver + ' ✓')
  }

  private flashSwitched(ver: string, hint: string): void {
    this.switchedHint = hint
    if (this.switchedHintTimer !== 0) {
      clearTimeout(this.switchedHintTimer)
    }
    this.switchedHintTimer = setTimeout(() => {
      this.switchedHint = ''
      this.switchedHintTimer = 0
    }, 2500)
  }

  /** 重置 5 个 primitive @State 资源计数（每个独立赋值确保 ArkUI dirty-track 都触发） */
  private resetDetailCounts(): void {
    this.modsCount = 0
    this.modsEnabledCount = 0
    this.shadersCount = 0
    this.resPacksCount = 0
    this.dataPacksCount = 0
    this.savesCount = 0
  }

  /** 进入某版本详情时载入其单版本自定义 JVM 参数，并收起编辑区（默认折叠）。 */
  private loadVersionJvmArgsState(ver: string): void {
    this.versionJvmArgs = this.loadVersionJvmArgs(ver)
    this.versionJdk = this.loadVersionJdk(ver)
    this.versionGameLang = this.loadVersionGameLang(ver)
    this.jvmArgsExpanded = false
  }

  /** 持久化当前详情版本的单版本自定义 JVM 参数（trim 首尾空白）。 */
  private saveVersionJvmArgs(): void {
    if (this.detailVersion.length === 0) return
    this.onSaveVersionJvmArgs(this.detailVersion, this.versionJvmArgs.trim())
  }

  /** 进入版本详情时加载整合包快照（非整合包版本置 null）。读文件失败静默忽略。 */
  private loadModpackSnapshot_(ver: string): void {
    if (ver.length === 0) { this.detailModpackSnap_ = null; return }
    this.detailModpackSnap_ = readModpackSnapshot(this.mcDir + '/versions/' + ver)
  }

  /** 把整合包缺失清单（名称 — 原因 — 下载地址）复制到剪贴板。 */
  private copyModpackMissing_(snap: ModpackSnapshot): void {
    let parts: string[] = ['整合包「' + snap.name + '」缺失清单（共 ' + snap.missing.length + ' 项）:']
    for (let m of snap.missing) {
      let line = '- ' + m.name + ' — ' + m.reason
      if (m.url !== undefined && m.url.length > 0) line += '\n  ' + m.url
      parts.push(line)
    }
    try {
      let data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, parts.join('\n'))
      pasteboard.getSystemPasteboard().setData(data)
      this.getUIContext().getPromptAction().showToast({ message: '缺失清单已复制', duration: 1500 })
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: '复制失败', duration: 1500 })
    }
  }

  private gotoDetail(ver: string): void {
    this.detailVersion = ver
    this.loadModpackSnapshot_(ver)
    this.resetDetailCounts()
    this.refreshDetailResStat(ver)
    this.loadVersionJvmArgsState(ver)
    this.currentStep = 'detail'
    // 横向滑动：list → 左滑出，detail → 右滑入
    this.getUIContext().animateTo({
      duration: VersionManagerSheet.ANIM_DURATION_MS,
      curve: Curve.FastOutSlowIn,
    }, () => {
      this.slidePos = 1
    })
  }

  private backToList(): void {
    this.currentStep = 'list'
    this.getUIContext().animateTo({
      duration: VersionManagerSheet.ANIM_DURATION_MS,
      curve: Curve.FastOutSlowIn,
    }, () => {
      this.slidePos = 0
    })
  }

  /** 详情 → 资源管理（同 sheet 第三步）。kind 决定展示哪种资源。 */
  private gotoResources(kind: ResourceKind): void {
    if (!this.detailVersion) return
    this.resourceKind = kind
    // 先置 currentStep（→ 内嵌 sheet active 翻 true → @Watch 触发扫描），再驱动滑动
    this.currentStep = 'resources'
    this.getUIContext().animateTo({
      duration: VersionManagerSheet.ANIM_DURATION_MS,
      curve: Curve.FastOutSlowIn,
    }, () => {
      this.slidePos = 2
    })
  }

  /** 资源管理 → 详情。回到详情时重扫资源数量（用户可能启用/禁用/删除过）。 */
  private backToDetail(): void {
    this.currentStep = 'detail'
    this.refreshDetailResStat(this.detailVersion)
    this.getUIContext().animateTo({
      duration: VersionManagerSheet.ANIM_DURATION_MS,
      curve: Curve.FastOutSlowIn,
    }, () => {
      this.slidePos = 1
    })
  }

  /** 详情 → 存档管理（同 sheet 第四步，序号 3）。 */
  private gotoSaves(): void {
    if (!this.detailVersion) return
    this.currentStep = 'saves'
    this.getUIContext().animateTo({
      duration: VersionManagerSheet.ANIM_DURATION_MS,
      curve: Curve.FastOutSlowIn,
    }, () => {
      this.slidePos = 3
    })
  }

  /** 详情 → 版本文件夹（虚拟文件管理器，同 sheet 第五步，序号 4）。 */
  private gotoFiles(): void {
    if (!this.detailVersion) return
    this.currentStep = 'files'
    this.getUIContext().animateTo({
      duration: VersionManagerSheet.ANIM_DURATION_MS,
      curve: Curve.FastOutSlowIn,
    }, () => {
      this.slidePos = 4
    })
  }

  private handleDetailDelete(): void {
    let ver = this.detailVersion
    if (!ver) return
    // 2026-05-22 修：以前这里再用 promptAction.showDialog 自己弹一次确认 →
    // 然后调 onDeleteVersion(ver) → Index.confirmDeleteVersion 又弹自定义 dialog 一次，
    // 用户被连击两次确认框。
    //
    // 现在统一只用 Index 的自定义 dialog（视觉/交互更一致），这里直接退回列表 +
    // 把 ver 透传上去由上层确认。listStep 的删除路径也是这样工作的。
    this.backToList()
    this.onDeleteVersion(ver)
  }

  // ============================================================
  //  重命名版本
  //
  //  本组件只负责浮层 UI 与即时校验；真正的文件系统操作（目录 + 内部
  //  <id>.jar / <id>.json + json 的 id 字段，原子带回滚）由父组件
  //  onRenameVersion → FileUtils.renameVersion 执行，父组件成功后重扫列表 +
  //  同步当前选中版本 + 持久化。这样保持本组件纯展示、不直接碰文件系统。
  // ============================================================

  /** 打开重命名浮层：预填当前详情版本名，清空错误（与原名相同时"确定"本就禁用）。 */
  private openRename(): void {
    if (this.detailVersion.length === 0) return
    this.renameInput = this.detailVersion
    this.renameError = ''
    this.showRename = true
  }

  /** 关闭重命名浮层并清空即时错误。 */
  private closeRename(): void {
    this.showRename = false
    this.renameError = ''
  }

  /**
   * "确定"是否可点：名称合法（validateVersionName 通过）且确实改了名。
   * 与 onChange 的即时校验同源，避免"无错误提示但按钮可点却必然失败"的割裂感。
   */
  private canConfirmRename(): boolean {
    let n = this.renameInput.trim()
    if (n.length === 0) return false
    if (n === this.detailVersion) return false
    return validateVersionName(n).length === 0
  }

  /**
   * 提交重命名：委托父组件执行真正的文件系统操作。
   * 成功 → 详情切到新名 + 关闭浮层；失败 → 父组件已 toast 原因，浮层保留让用户改。
   */
  private confirmRename(): void {
    let oldVer = this.detailVersion
    let newVer = this.renameInput.trim()
    // 兜底再校验一次（正常路径下 canConfirmRename 已挡住非法/未改名的输入）
    let err = validateVersionName(newVer)
    if (err.length > 0) { this.renameError = err; return }
    if (newVer === oldVer) { this.renameError = '新名称与原名称相同'; return }

    if (this.onRenameVersion(oldVer, newVer)) {
      this.detailVersion = newVer
      this.loadModpackSnapshot_(newVer)
      this.loadVersionJvmArgsState(newVer)
      this.closeRename()
    }
  }

  @Builder
  RenameOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      // 半透明遮罩：点击空白处关闭
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#99000000')
        .onClick(() => { this.closeRename() })

      // 居中卡片
      Column({ space: 14 }) {
        Text('重命名版本')
          .fontSize(17)
          .fontWeight(700)
          .fontColor(this.theme.textPrimary)
          .width('100%')

        Text('修改版本文件夹名称（会同步内部 .jar / .json 与版本 id，保持可启动）')
          .fontSize(12)
          .fontWeight(400)
          .fontColor(this.theme.textHint)
          .width('100%')

        TextInput({ text: this.renameInput, placeholder: '输入新的版本名称' })
          .width('100%')
          .height(46)
          .fontSize(15)
          .fontColor(this.theme.textPrimary)
          .backgroundColor(this.theme.bgInput)
          .borderRadius(10)
          .padding({ left: 12, right: 12 })
          .maxLength(120)
          .onChange((value: string) => {
            this.renameInput = value
            // 即时校验：空串表示合法；非空时下方红字提示（"确定"另判是否真改了名）
            this.renameError = validateVersionName(value)
          })

        // 即时错误提示（仅在有错时渲染，避免空行抖动）
        if (this.renameError.length > 0) {
          Row({ space: 4 }) {
            AppIcon({ name: AppIconName.Warning, iconSize: 12, color: this.theme.error })
            Text(this.renameError)
              .fontSize(12)
              .fontWeight(500)
              .fontColor(this.theme.error)
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }

        // 取消 / 确定
        Row({ space: 10 }) {
          Text('取消')
            .layoutWeight(1)
            .height(44)
            .fontSize(15)
            .fontWeight(600)
            .fontColor(this.theme.textSecondary)
            .backgroundColor(this.theme.bgInput)
            .borderRadius(12)
            .textAlign(TextAlign.Center)
            .onClick(() => { this.closeRename() })

          Text('确定')
            .layoutWeight(1)
            .height(44)
            .fontSize(15)
            .fontWeight(700)
            .fontColor(this.theme.textOnPrimary)
            // 不可提交时弱化（primaryLight + 降透明度），可提交时 primary 实色
            .backgroundColor(this.canConfirmRename() ? this.theme.primary : this.theme.primaryLight)
            .opacity(this.canConfirmRename() ? 1 : 0.6)
            .borderRadius(12)
            .textAlign(TextAlign.Center)
            .enabled(this.canConfirmRename())
            .onClick(() => { this.confirmRename() })
        }
        .width('100%')
        .margin({ top: 2 })
      }
      .width('86%')
      .padding(20)
      .backgroundColor(this.theme.bgCard)
      .borderRadius(18)
      .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
    }
    .width('100%')
    .height('100%')
  }

  // ============================================================
  //  helpers — 列表 + 徽章
  // ============================================================

  private headerSubtitle(): string {
    let n = this.availableVersions.length
    if (n === 0) return '尚未安装任何版本'
    return n + ' 个已安装  ·  点击行体切换  ·  点击「管理」进入详情'
  }

  private filteredVersions(): string[] {
    if (this.filterLoader.length === 0) return this.orderVersions
    let out: string[] = []
    for (let v of this.orderVersions) {
      // 走 LoaderCatalog → detectLoaderFromId 单一事实源识别 loader，不再自写 indexOf。
      // 'vanilla' = 无 loader；其余精确匹配 chip。注意：与旧 indexOf('forge') 不同，
      // neoforge 不再被 'forge' 子串误命中（旧实现 Forge 过滤会顺带带出 neoforge），
      // 这是更正确的行为（neoforge 当前 supported=false，实际几乎不会安装）。
      let key = resolveInstalledLoaderKey(this.mcDir, v)
      if (this.filterLoader === 'vanilla') {
        if (key === 'vanilla') out.push(v)
      } else if (key === this.filterLoader) {
        out.push(v)
      }
    }
    return out
  }

  /**
   * 拖拽落定：把本地实时重排好的 orderVersions 回传父组件持久化。
   * onItemDragMove 已逐帧把顺序排到位，这里只需提交最终结果。
   */
  private persistOrder_(): void {
    this.onReorderVersions(this.orderVersions.slice())
  }

  /** 清理拖拽态（无论成功/取消都调用），把被提起的原行恢复不透明。 */
  private endDrag_(): void {
    this.draggingVer = ''
    this.dragCurIndex_ = -1
  }

  /** 拖拽时跟随手指的浮层：略放大 + 强阴影 + 主题描边，强化"被拎起"的层次感。 */
  @Builder
  DragPreview(ver: string) {
    Row() {
      AppIcon({ name: AppIconName.DragHandle, iconSize: 16, color: this.theme.primary })
      VersionBlockIcon({ versionId: ver, iconSize: 32, cornerRadius: 0, overrideImagePath: getModpackIconPath(this.mcDir, ver) })
        .width(32).height(32).margin({ left: 10 })
      Text(ver)
        .fontSize(15).fontWeight(600).fontColor(this.theme.textPrimary)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1).margin({ left: 10 })
    }
    .width('72%')
    .padding({ left: 14, right: 16, top: 12, bottom: 12 })
    .backgroundColor(this.theme.bgCard)
    .borderRadius(14)
    .border({ width: 1.5, color: this.theme.primary, style: BorderStyle.Solid })
    .shadow({ radius: this.theme.cardShadowRadius * 2.2, color: this.theme.cardShadowColor })
    .scale({ x: 1.04, y: 1.04 })
  }

  // ============================================================
  //  版本类型 helper
  //
  //  这八个函数过去各自都是一场重复 switch，现全部委托给 LoaderCatalog
  //  单一事实源。保留函数签名是为了调用点（build 内量大）不必改动。
  // ============================================================

  private versionTypeKind(ver: string): string {
    return resolveInstalledLoaderKey(this.mcDir, ver)
  }

  /**
   * 行尾徽章文字 / 颜色 — 走 LoaderCatalog.getInstalledBadgeInfo 单一事实源。
   *
   * 与旧实现 (`getLoaderInfo(inferLoaderKey(ver))`) 的差别：vanilla 版本
   * 现在按 classifyVersion 进一步细分 release/snapshot/aprilfools/old，
   * 让 "26.2-snapshot-8" 显示 "快照" + 命令橙，而不是 "原版" + 草绿。
   * release vanilla 仍显示 "原版" + 草绿，沿用原 UX。
   */
  private versionTypeLabel(ver: string): string {
    return getInstalledBadgeInfoResolved(this.mcDir, ver).displayName
  }

  private versionTypeFg(ver: string): ResourceColor {
    return getInstalledBadgeInfoResolved(this.mcDir, ver).accentColor
  }

  private versionTypeBg(ver: string): ResourceColor {
    return getInstalledBadgeInfoResolved(this.mcDir, ver).accentBg
  }

  /** 以前 fabric 这里走 theme.primaryLight、现在统一走 catalog accentBg=#DCFCE7，
   *  与 versionTypeBg / FabricApiCard 背景保持一致。 */
  private iconBg(ver: string): ResourceColor {
    return getLoaderInfo(resolveInstalledLoaderKey(this.mcDir, ver)).accentBg
  }

  private iconName(ver: string): AppIconName {
    return getLoaderInfo(resolveInstalledLoaderKey(this.mcDir, ver)).iconName
  }

  private iconFg(ver: string): ResourceColor {
    return getLoaderInfo(resolveInstalledLoaderKey(this.mcDir, ver)).accentColor
  }

  private metaLine(ver: string): string {
    return resolveInstalledLoaderKey(this.mcDir, ver) === 'vanilla' ? '原版' : '已装加载器'
  }

  // ============================================================
  //  helpers — Detail step
  // ============================================================

  private detailMcVersion(): string {
    // 整合包/重命名版本名拿不到版本号，走快照/内容解析；最后才回退名字
    let mc = resolveInstalledMcVersion(this.mcDir, this.detailVersion)
    return mc || this.detailVersion || '—'
  }

  private detailLoaderText(): string {
    let key = resolveInstalledLoaderKey(this.mcDir, this.detailVersion)
    if (key === 'vanilla') return '原版 Vanilla'
    return getLoaderInfo(key).displayName + ' Loader'
  }

  private detailHeroIcon(): AppIconName {
    return resolveInstalledLoaderInfo(this.mcDir, this.detailVersion).iconName
  }

  /**
   * 构造 JDK 版本选择 menu。
   *
   * 表项："JDK 17"、"JDK 21" 等。当前选中加 "✓" 前缀；与
   * suggestedJdkVersion（按 mcVersion 推算的 autoSelectVersion 结果）一致时
   * 加" · 推荐"后缀。
   *
   * 返回值遵循 ArkUI bindMenu(MenuElement[]) 接口；图标省略保持视觉简洁。
   *
   * suggestedJdkVersion === selectedJdkVersion 时不挂"推荐"，避免冗余。
   */
  private buildJdkVersionMenu(): MenuElement[] {
    let items: MenuElement[] = []
    // 跟随全局（附注全局当前值）
    let globalLabel = this.globalJdkVersion === 'auto' ? '自动'
      : (this.globalJdkVersion.length > 0 ? 'JDK ' + this.globalJdkVersion : '自动')
    items.push({
      value: (this.versionJdk === '' ? '✓  ' : '    ') + '跟随全局（' + globalLabel + '）',
      action: () => { this.selectVersionJdk('') },
    } as MenuElement)
    // 自动（按版本纪元路由）
    items.push({
      value: (this.versionJdk === 'auto' ? '✓  ' : '    ') + '自动（按版本纪元）',
      action: () => { this.selectVersionJdk('auto') },
    } as MenuElement)
    // 各具体版本（硬覆盖，可用于"选错也能启动"的调试）
    let supported = this.supportedJdkVersions.length > 0 ? this.supportedJdkVersions : ['17']
    for (let v of supported) {
      let prefix = (v === this.versionJdk) ? '✓  ' : '    '
      let suffix = (v === this.suggestedJdkVersion) ? '  · 推荐' : ''
      items.push({
        value: prefix + 'JDK ' + v + suffix,
        action: () => { this.selectVersionJdk(v) },
      } as MenuElement)
    }
    return items
  }

  /** 选择单版本 JDK：更新本地 state + 回调父组件持久化（'' 跟随全局 / 'auto' / 具体版本）。 */
  private selectVersionJdk(choice: string): void {
    this.versionJdk = choice
    if (this.detailVersion.length > 0) {
      this.onSaveVersionJdk(this.detailVersion, choice)
    }
  }

  /** 单版本 JDK 行的显示文案。 */
  private versionJdkLabel(): string {
    if (this.versionJdk === 'auto') return '自动'
    if (this.versionJdk.length > 0) return 'JDK ' + this.versionJdk
    return '跟随全局'
  }

  /**
   * 构造单版本【游戏语言】选择 menu。首项"跟随全局（<全局语言>）"，其后各具体语言。
   * 当前选中加 "✓" 前缀。
   */
  private buildGameLangMenu(): MenuElement[] {
    let items: MenuElement[] = []
    // 跟随全局（附注全局当前语言）
    items.push({
      value: (this.versionGameLang === '' ? '✓  ' : '    ')
        + '跟随全局（' + gameLanguageLabel(this.globalGameLanguage) + '）',
      action: () => { this.selectVersionGameLang('') },
    } as MenuElement)
    // 各具体语言（单版本硬覆盖）
    for (let opt of GAME_LANGUAGES) {
      let prefix = (opt.code === this.versionGameLang) ? '✓  ' : '    '
      items.push({
        value: prefix + opt.label,
        action: () => { this.selectVersionGameLang(opt.code) },
      } as MenuElement)
    }
    return items
  }

  /** 选择单版本游戏语言：更新本地 state + 回调父组件持久化（'' 跟随全局 / 具体 code）。 */
  private selectVersionGameLang(code: string): void {
    this.versionGameLang = code
    if (this.detailVersion.length > 0) {
      this.onSaveVersionGameLang(this.detailVersion, code)
    }
  }

  /** 单版本游戏语言行的显示文案。 */
  private versionGameLangLabel(): string {
    if (this.versionGameLang.length > 0) return gameLanguageLabel(this.versionGameLang)
    return '跟随全局'
  }

  private refreshDetailResStat(ver: string): void {
    if (this.mcDir.length === 0 || ver.length === 0) {
      // 没拿到根目录或目标版本时，全部置 0；UI 显示 "—" hint
      this.modsCount = 0
      this.modsEnabledCount = 0
      this.shadersCount = 0
      this.resPacksCount = 0
      this.dataPacksCount = 0
      this.savesCount = 0
      hilog.warn(0x0000, TAG,
        'refreshDetailResStat skipped: mcDir=%{public}s ver=%{public}s',
        this.mcDir, ver)
      return
    }
    try {
      let verDir = this.versionIsolation ? (this.mcDir + '/versions/' + ver) : this.mcDir
      let modsTotal = countFilesWithExtensions(verDir + '/mods', ['.jar', '.jar.disabled'])
      let modsEnabled = countFilesWithExtensions(verDir + '/mods', ['.jar'])
      let shaders = countFilesWithExtensions(verDir + '/shaderpacks', ['.zip', '.zip.disabled'])
      let resPacks = countFilesWithExtensions(verDir + '/resourcepacks', ['.zip', '.zip.disabled'])
      let dataPacks = countFilesWithExtensions(verDir + '/datapacks', ['.zip'])
      // 存档是文件夹（saves/<世界>/），countFilesWithExtensions 只数文件，这里单独数子目录
      let savesTotal = 0
      try {
        let saveNames = fs.listFileSync(verDir + '/saves')
        for (let sn of saveNames) {
          try { if (fs.statSync(verDir + '/saves/' + sn).isDirectory()) savesTotal++ } catch (e) { /* */ }
        }
      } catch (e) { /* saves 目录不存在 → 0 */ }
      // 关键：每个 @State 独立赋值，绝不打包成对象。ArkUI 在 step 切换 + animateTo
      // 同时发生时，对单一对象 @State 的 dirty-track 偶发漏报，但 5 个独立 primitive
      // @State 写法完全可靠。
      this.modsCount = modsTotal
      this.modsEnabledCount = modsEnabled
      this.shadersCount = shaders
      this.resPacksCount = resPacks
      this.dataPacksCount = dataPacks
      this.savesCount = savesTotal
      hilog.info(0x0000, TAG,
        'res-stat ver=%{public}s dir=%{public}s mods=%{public}d/%{public}d shaders=%{public}d resPacks=%{public}d dataPacks=%{public}d',
        ver, verDir, modsEnabled, modsTotal, shaders, resPacks, dataPacks)
    } catch (e) {
      hilog.warn(0x0000, TAG, 'refreshDetailResStat: %{public}s', (e as Error).message)
    }
  }

  /**
   * 仅 .jar 文件存在的 disabled 后缀做特殊处理：
   *   - extensions=['.jar', '.jar.disabled'] 时分别匹配两种后缀；
   *   - extensions=['.jar'] 单独传时不会把 `.jar.disabled` 当作 `.jar` 命中。
   * 因此调用方区分启用/总数时只需传不同的扩展数组。
   *
   * @deprecated 2026-05-17：迁到 utils/FileUtils.countFilesWithExtensions 统一实现，
   *             保留私有方法仅为兜底（未来无引用后可删除）
   */
  private countFilesIn(dir: string, extensions: string[]): number {
    return countFilesWithExtensions(dir, extensions)
  }

  // ============================================================
  //  helpers — 资源格 hint 文案 + 点击行为
  // ============================================================

  private modsHint(): string {
    let total = this.modsCount
    if (total <= 0) return '点击安装模组'
    let enabled = this.modsEnabledCount
    let disabled = Math.max(0, total - enabled)
    if (disabled <= 0) return enabled + ' 个启用'
    return enabled + ' 启用 · ' + disabled + ' 禁用'
  }

  private shadersHint(): string {
    return this.shadersCount > 0 ? '已装光影' : '点击添加'
  }

  private resPacksHint(): string {
    return this.resPacksCount > 0 ? '已装资源' : '点击添加'
  }

  private dataPacksHint(): string {
    return this.dataPacksCount > 0 ? '已装数据包' : '点击添加'
  }

  private handleManageMods(): void {
    this.gotoResources(ResourceKind.MOD)
  }

  private handleManageShaders(): void {
    this.gotoResources(ResourceKind.SHADER)
  }

  private handleManageResPacks(): void {
    this.gotoResources(ResourceKind.RESOURCE_PACK)
  }

  private handleManageDataPacks(): void {
    this.gotoResources(ResourceKind.DATAPACK)
  }

  private handleManageSaves(): void {
    this.gotoSaves()
  }

  private savesHint(): string {
    return this.savesCount > 0 ? this.savesCount + ' 个存档' : '点击导入'
  }
}
