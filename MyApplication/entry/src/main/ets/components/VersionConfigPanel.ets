/**
 * VersionConfigPanel.ets — 版本下载详情面板（Phase R-3 重设计 2026-05-13）
 *
 * 设计稿：docs/design/download-page-redesign/06_version_download_sheet.png（Screen F）
 *
 * 重设计改动：
 *   - Hero Card：🎮 大图标 + "Minecraft <ver>" 标题 + 正式版 badge + 体积估算
 *   - 加载器选择 Card：5 个 loader chips（含 NeoForge / Quilt UI 占位）+ 选中详情卡
 *   - 加载器版本 chip 列表（含 β 标记差异化）
 *   - 版本名称输入 + 路径预览
 *   - 底部 Sticky CTA：开始下载（带体积估算）
 *
 * 兼容性：保留原 props / 回调签名（onStartDownload / onClose），Index.ets 无需改 builder。
 *
 * 未实现功能（UI 占位）：
 *   - NeoForge / Quilt 选项当前 ModLoaderType 枚举未包含 → 点击显示"暂未支持"占位
 *   - "了解区别 ›" 链接（Screen G 加载器选择详细页）— 当前 P3 待实现
 */

import { ThemeColors } from 'commons';
import { ModLoaderType, ModLoaderVersion } from 'feature_core';
import { ModLoaderManager } from 'feature_core';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { promptAction } from '@kit.ArkUI';
import { isVersionInstalled } from 'commons';
import { requiredJdkMajorForMc, pickInstalledJdkMajor } from 'commons';
import { DOCS_NO_JIT_URL, DOCS_NO_JIT_FALLBACK_URL } from 'commons';
import { AppIconName } from 'commons';
import { AppIcon } from './AppIcon';
import { VersionBlockIcon } from './VersionBlockIcon';
import { LoaderBadge } from './LoaderBadge';
import { classifyVersion, VersionCategory } from 'mods';
// 2026-05-23 图标系统重构：loader 显示数据（icon/PNG/desc/color/supported）
// 全部走 LoaderCatalog 单一事实源，不再在本文件定义 LOADERS 表的细节。
import {
  LoaderKey, LoaderInfo, getLoaderInfo, getVanillaCategoryInfo,
} from '../components/LoaderCatalog';
import { fetchVersionMeta, VersionMetaResult } from 'feature_core';
// MC 26.2+ 官方 Vulkan 渲染后端的设备能力门控（静默探针 + 提示）。
import { getVulkanStatusForVersion, VulkanStatusHint, VulkanFeasibilityState } from 'feature_system';
// 2026-05-23：Fabric API 伴随下载——选 Fabric loader 后可勾选同时装 Fabric API mod。
// 元数据走 Modrinth（slug=fabric-api），不走 CurseForge 兑底（与计划一致）。
import { ModrinthRepository } from 'mods';
import { ModrinthSourceMode } from 'mods';
import { getMetadataCacheStore } from 'feature_core';
import { DownloadManager } from 'feature_core';
import { RemoteVersion, RemoteFile, RemoteProject, pickPrimaryFile } from 'mods';
import { pickBestVersion } from 'mods';
import { formatBytes } from 'commons';

const TAG = 'VersionConfigPanel';

const INVALID_NAME_CHARS = '/\\:*?"<>|';
const MAX_NAME_LENGTH = 64;


// loaderChoice 数字含义：0=Vanilla / 1=Fabric / 2=Forge / 3=NeoForge(占位) / 4=Quilt(占位)
// 表本身只存最小信息（idx 即数组下标，所以只剩 LoaderKey）。displayName / description /
// iconName / accentColor / blockMedia / supported 全部走 LoaderCatalog.getLoaderInfo()，
// 单一事实源避免与 VersionManagerSheet / FabricApiCard 的颜色矩阵分歧。
const LOADER_KEYS: LoaderKey[] = ['vanilla', 'fabric', 'forge', 'neoforge', 'quilt']

/** loaderChoice 数字 → LoaderInfo 的方便包装（带越界保护） */
function loaderInfoForChoice(idx: number): LoaderInfo {
  if (idx < 0 || idx >= LOADER_KEYS.length) return getLoaderInfo('vanilla')
  return getLoaderInfo(LOADER_KEYS[idx])
}

@Component
export struct VersionConfigPanel {
  @Prop @Watch('refreshVulkanStatus') gameVersion: string = ''
  /**
   * 版本子类别（由父组件从 manifest type 判出后透传，限 vanilla 状态生效）。
   *
   * 可选值：'release' / 'snapshot' / 'aprilfools' / 'old' / ''。空字符串 = 未传，
   * fallback 到按 versionId 推断（classifyVersion）。
   *
   * 为什么要这个 prop：classifyVersion 仅识别‘24w14a’/‘pre’/‘rc’ 等格式，遇到
   * ‘26.2-snapshot-8’ 这种 “snapshot” 裸关键字名会误判为 release。而调用方
   * （DownloadTab）已从 manifest 拿到准确类别，透传过来避免重复推断与漏识。
   */
  @Prop gameCategory: string = ''
  @Prop theme: ThemeColors = {} as ThemeColors
  // 设备已安装的 JDK 大版本集合（如 [17, 25]）。Forge / NeoForge 需在设备上跑安装器，
  // 安装期的 JDK 由 MC 版本纪元（commons.requiredJdkMajorForMc）+ 本集合自动匹配
  // （pickInstalledJdkMajor：取 ≥required 的最低版本）。空集 = 没有任何可用 JDK。
  @Prop installedJdkMajors: number[] = []
  @Prop mcDir: string = ''
  @Prop downloading: boolean = false

  @State loaderChoice: number = 0
  @State loaderVersions: ModLoaderVersion[] = []
  @State loaderVersionsLoading: boolean = false
  /** 非空 = 上一次加载失败（区别于"该 MC 版本确实没有该加载器"）。 */
  @State loaderVersionsError: string = ''
  @State selectedLoaderVersion: string = ''
  @State versionName: string = ''
  @State isNameEdited: boolean = false
  @State nameError: string = ''
  private _lastAutoName: string = ''

  /**
   * 版本说明（来自 minecraft.wiki / CC BY-NC-SA 3.0）。
   *   - ''        = 还在加载 / 还没发起请求 → UI 显示骨架屏
   *   - non-empty = 拿到 intro 段落，UI 显示文本 + 署名
   *   - desc='' && descLoaded=true = 抓取失败 / 文章不存在 → UI 隐藏整张卡
   */
  @State versionDesc: string = ''
  @State versionDescLoaded: boolean = false
  /** 末次发起请求的版本 id，避免快速切版本时旧请求的回调把新版本的 desc 覆盖掉 */
  private versionDescEpoch_: number = 0
  /**
   * 版本说明折叠/展开：
   *   - descExpanded:    false=折叠（最多 3 行+省略号）/ true=展开全文
   *   - descShowToggle:  正文是否超过 3 行（超过才显示「展开/收起」按钮）
   *   - descTextWidthVp: 正文可用宽度（vp，= 卡片宽度 - 左右内边距），onAreaChange 捕获后据此测量行数
   */
  @State descExpanded: boolean = false
  @State descShowToggle: boolean = false
  private descTextWidthVp: number = 0

  // ============================================================
  //  Vulkan 能力门控（MC 26.2+ 官方 Vulkan 渲染后端）
  // ============================================================
  /** null = 该版本不走 Vulkan（< 26.2）或未探测；non-null = 已静默探测出的提示 */
  @State vulkanHint: VulkanStatusHint | null = null

  // ============================================================
  //  Fabric API 伴随下载（2026-05-23）
  // ============================================================
  /** 用户是否勾选了同时装 Fabric API（仅在 loaderChoice=1 时生效） */
  @State withFabricApi: boolean = true
  /** 取回的 RemoteVersion 元数据，含 primaryFile；null = 未提取 / 失败 */
  @State fabricApiVersion: RemoteVersion | null = null
  @State fabricApiPrimary: RemoteFile | null = null
  @State fabricApiLoading: boolean = false
  /** Fabric API 项目图标 URL（伴随下载卡片显示真实图标用；拉不到则为空，不影响下载） */
  @State fabricApiIconUrl: string = ''
  /** '' = 正常；non-empty = 拉取失败 / 该 MC 版本无可用 Fabric API */
  @State fabricApiError: string = ''
  /** 防用户快速切 loader 后旧请求覆盖新请求的 epoch */
  private fabricApiEpoch_: number = 0
  /** 防 loader 版本列表的旧请求（慢的 Forge metadata）覆盖新请求（NeoForge）的 epoch */
  private loaderVersionsEpoch_: number = 0

  private modLoaderManager: ModLoaderManager = new ModLoaderManager()

  /**
   * 开始下载回调。
   *
   * 第 5 个参数 fabricApi 是 2026-05-23 新增：RemoteVersion 代表要伴随下载的
   * Fabric API 版本；null = 不装 / 未勾选 / 元数据未就绪。上层 Index.beginDownload
   * 负责在 MC 任务完成后串行 enqueue 一个 ResourceInstallTask。
   */
  onStartDownload: (gameVersion: string, loaderType: ModLoaderType | null,
    loaderVersion: string, versionName: string,
    fabricApi: RemoteVersion | null, fabricApiIconUrl: string) => void =
    (_g: string, _t: ModLoaderType | null, _v: string, _n: string,
     _api: RemoteVersion | null, _icon: string) => {}
  onClose: () => void = () => {}
  // 加载器（Forge/NeoForge）需安装器 JDK 但设备无可用版本时，用户在提示框点「去安装」触发。
  // 入参为所需的最低 JDK 大版本（17/21/25）——上层负责关 sheet + 下载对应 JDK。
  onInstallJdk: (requiredMajor: number) => void = (_m: number) => {}
  // JIT（可执行内存）探测。Forge 安装器要跑 JVM（fork_run_java），需 JIT；不可用则拦截。
  // 由上层（持 libentry.so 的产品层）注入 testNapi.checkJitAvailable 包装。默认 true 不拦。
  checkJitAvailable: () => boolean = () => true

  aboutToAppear(): void {
    this._lastAutoName = this.gameVersion
    this.versionName = this.gameVersion
    this.loaderChoice = 0
    this.isNameEdited = false
    this.nameError = ''
    this.loaderVersions = []
    this.selectedLoaderVersion = ''
    // 异步抓版本说明 —— 失败 / 文章 missing 都返回 description=null，UI 自动隐藏卡片
    this.versionDesc = ''
    this.versionDescLoaded = false
    this.descExpanded = false
    this.descShowToggle = false
    this.kickOffVersionDesc()
    this.refreshVulkanStatus()
  }

  /** 首次打开及目标版本变化均刷新报告；同步只读设备查询不创建窗口，不影响下载操作。 */
  private refreshVulkanStatus(): void {
    this.vulkanHint = getVulkanStatusForVersion(this.gameVersion)
  }

  /**
   * 异步拉取版本说明。epoch 自增防止用户快速切版本时旧请求回调把新版本数据冲掉。
   */
  private kickOffVersionDesc(): void {
    if (this.gameVersion.length === 0) {
      this.versionDescLoaded = true
      return
    }
    this.versionDescEpoch_++
    let myEpoch = this.versionDescEpoch_
    let target = this.gameVersion
    fetchVersionMeta(target).then((res: VersionMetaResult) => {
      // 异步回来时若用户已经切版本，丢弃旧数据
      if (myEpoch !== this.versionDescEpoch_) return
      this.versionDesc = res.description !== null ? res.description : ''
      this.versionDescLoaded = true
      this.descExpanded = false
      this.recomputeDescOverflow()
    }).catch((e: Error) => {
      if (myEpoch !== this.versionDescEpoch_) return
      hilog.warn(0x0000, TAG, 'fetchVersionMeta uncaught: %{public}s', e.message)
      this.versionDesc = ''
      this.versionDescLoaded = true
    })
  }

  /**
   * 测量版本说明正文在当前可用宽度下是否超过 3 行，决定是否显示「展开/收起」。
   * 用 MeasureUtils.measureTextSize（全程 vp 输入、px 输出再转回 vp），与 Text 的
   * fontSize(13)/lineHeight(20) 对齐。宽度或正文未就绪时按"不超过"处理（不显示按钮）。
   */
  private recomputeDescOverflow(): void {
    if (this.versionDesc.length === 0 || this.descTextWidthVp <= 0) {
      this.descShowToggle = false
      return
    }
    try {
      let size = this.getUIContext().getMeasureUtils().measureTextSize({
        textContent: this.versionDesc,
        fontSize: 13,
        lineHeight: 20,
        constraintWidth: this.descTextWidthVp,
      })
      let hVp = this.getUIContext().px2vp(size.height as number)
      let lines = Math.round(hVp / 20)
      this.descShowToggle = lines > 3
    } catch (e) {
      this.descShowToggle = false
    }
  }

  build() {
    Column() {
      // ============== 顶部 drag pill + 标题行 ==============
      Row() {
        Column()
          .width(36).height(4)
          .backgroundColor(this.theme.divider)
          .borderRadius(2)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 10, bottom: 6 })

      // ============== Scroll 内容区 ==============
      Scroll() {
        Column({ space: 14 }) {
          // ---- Hero Card：🎮 + MC <ver> + 类型 badge + 体积 ----
          this.HeroCard()

          // ---- 版本说明 Card（首次进入异步抓 minecraft.wiki，CC BY-NC-SA 3.0 署名）----
          this.VersionDescCard()

          // ---- Vulkan 渲染能力 Card（仅 MC 26.2+ 且探测有结果时显示）----
          if (this.vulkanHint !== null) {
            this.VulkanStatusCard()
          }

          // ---- 加载器选择 Card ----
          this.LoaderSelectCard()

          // ---- 加载器版本 Card（仅选了 loader 时显示）----
          if (this.loaderChoice > 0 && this.isLoaderSupported(this.loaderChoice)) {
            this.LoaderVersionCard()
          }

          // ---- Fabric API 伴随下载 Card（仅选了 Fabric 时显示）----
          // 2026-05-23：让用户一次性把 Fabric API 跟 MC + loader 一起装好，
          // 减少新手用户装完 Fabric 启动报错 "missing fabric-api" 的迷茫场景。
          if (this.loaderChoice === 1) {
            this.FabricApiCard()
          }

          // ---- 版本名称 Card ----
          this.VersionNameCard()
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 12 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      // ============== Sticky CTA Bar ==============
      this.CtaBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.bgPrimary)
  }

  // ============================================================
  //  @Builder
  // ============================================================

  @Builder
  HeroCard() {
    Row({ space: 12 }) {
      // Hero 方块图标 —— 用户没选 loader 时按 game version 推断
      // （正式版草方块 / 快照命令方块 / 愚人节金块 / 远古版圆石）；
      // 选了 loader 后切到对应 loader 图标（Fabric 织布 / Forge 铁砧 / Quilt / NeoForge）
      Stack() {
        // 深色底框，让方块贴图在卡片白底上有"卡片感"
        Column().width(56).height(56).backgroundColor('#0F172A').borderRadius(14)
        VersionBlockIcon({
          versionId: this.gameVersion,
          category: this.heroIconCategory(),
          iconSize: 44,
          cornerRadius: 0,
        })
      }
      .width(56).height(56)

      Column({ space: 4 }) {
        // 2026-05-23：字号 20→18 + maxLines 1→2，避免 ‘26.2-snapshot-8’ 这种
        // 长版本名被截断成 “Minecraft 26.2-...”。
        Text('Minecraft ' + this.gameVersion)
          .fontSize(18)
          .fontWeight(700)
          .fontColor(this.theme.textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 6 }) {
          Text('客户端 ·')
            .fontSize(12).fontWeight(500).fontColor(this.theme.textSecondary)
          Text('~ 280 MB')
            .fontSize(12).fontWeight(500).fontColor(this.theme.textSecondary)
        }
        .alignItems(VerticalAlign.Center)
        Row({ space: 6 }) {
          Row({ space: 4 }) {
            Text('●').fontSize(10).fontColor(this.heroBadgeColor())
            Text(this.heroBadgeLabel())
              .fontSize(10).fontWeight(700).fontColor(this.heroBadgeColor())
          }
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(6)
          .backgroundColor(this.heroBadgeBg())
          .alignItems(VerticalAlign.Center)

          Text('Mojang 官方')
            .fontSize(10).fontWeight(700).fontColor(this.theme.primary)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(6)
            .backgroundColor(this.theme.primaryLight)
        }
        .alignItems(VerticalAlign.Center)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(12)
    .backgroundColor(this.theme.bgCard)
    .borderRadius(14)
    .alignItems(VerticalAlign.Center)
  }

  /**
   * vanilla 子类别推断：优先用父组件传入的 gameCategory（manifest type），空字符串时
   * fallback 到按 versionId 推断。
   *
   * 修 bug: “26.2-snapshot-8” 裸关键字名 classifyVersion 误判 release，导致
   * hero 图标/badge 显示为草方块 + “正式版”。现在 DownloadTab 从 manifest type
   * 拿到准确类别（'snapshot'）透传下来，优先生效。
   */
  private resolveVanillaCategory_(): VersionCategory {
    if (this.gameCategory === 'release' || this.gameCategory === 'snapshot'
        || this.gameCategory === 'aprilfools' || this.gameCategory === 'old') {
      return this.gameCategory as VersionCategory
    }
    return classifyVersion(this.gameVersion)
  }

  /**
   * Hero VersionBlockIcon 的 category override。
   *
   * 选了 loader 返回 loader key （切到对应 loader 图标）；vanilla 状态返回子类别串
   * 让 VersionBlockIcon 按 manifest type 选准确的 PNG。
   */
  private heroIconCategory(): string {
    let key = LOADER_KEYS[this.loaderChoice]
    if (key !== 'vanilla') return key
    return this.resolveVanillaCategory_()
  }

  /** Hero badge 文案：vanilla 状态显示 game 类别；选了 loader 显示 loader 名 */
  private heroBadgeLabel(): string {
    let key = LOADER_KEYS[this.loaderChoice]
    if (key !== 'vanilla') return getLoaderInfo(key).displayName
    return getVanillaCategoryInfo(this.resolveVanillaCategory_()).displayName
  }

  /** Hero badge 文字色：与 LoaderChip 颜色矩阵保持一致（统一从 LoaderCatalog 读） */
  private heroBadgeColor(): ResourceColor {
    let key = LOADER_KEYS[this.loaderChoice]
    if (key !== 'vanilla') return getLoaderInfo(key).accentColor
    return getVanillaCategoryInfo(this.resolveVanillaCategory_()).accentColor
  }

  /** Hero badge 背景：与文字色配对 */
  private heroBadgeBg(): ResourceColor {
    let key = LOADER_KEYS[this.loaderChoice]
    if (key !== 'vanilla') return getLoaderInfo(key).accentBg
    return getVanillaCategoryInfo(this.resolveVanillaCategory_()).accentBg
  }

  /**
   * 版本说明卡片。
   *
   * 三态：
   *   - 还在加载（versionDescLoaded=false）→ 骨架占位（3 行灰色长条）
   *   - 加载完成 + 拿到 desc（versionDesc 非空）→ 文本 + 署名行
   *   - 加载完成但失败 / 文章不存在（versionDesc=''）→ 整张卡不渲染
   *
   * 协议合规：底部"内容来自 minecraft.wiki · CC BY-NC-SA 3.0"署名行**不可移除**，
   * 删了就违反 CC-BY 的署名要求。点击署名跳到原 wiki 页面。
   */
  @Builder
  VersionDescCard() {
    if (!this.versionDescLoaded) {
      // 骨架屏：3 行灰条占位
      Column({ space: 10 }) {
        Row().width('60%').height(12).backgroundColor(this.theme.bgInput).borderRadius(6)
        Row().width('100%').height(10).backgroundColor(this.theme.bgInput).borderRadius(5)
        Row().width('80%').height(10).backgroundColor(this.theme.bgInput).borderRadius(5)
      }
      .width('100%')
      .padding(14)
      .backgroundColor(this.theme.bgCard)
      .borderRadius(14)
      .alignItems(HorizontalAlign.Start)
    } else if (this.versionDesc.length > 0) {
      Column({ space: 8 }) {
        Row({ space: 6 }) {
          Text('·')
            .fontSize(14).fontWeight(700).fontColor(this.theme.primary)
          Text('版本说明')
            .fontSize(14).fontWeight(700).fontColor(this.theme.textPrimary)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(this.versionDesc)
          .fontSize(13)
          .fontWeight(400)
          .fontColor(this.theme.textSecondary)
          .lineHeight(20)
          .width('100%')
          .maxLines(this.descExpanded ? 1000 : 3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .onAreaChange((_o: Area, n: Area) => {
            // 正文实际可用宽度（vp）；变化时按新宽度重新测量是否超过 3 行
            let w = n.width as number
            if (w > 0 && Math.abs(w - this.descTextWidthVp) > 0.5) {
              this.descTextWidthVp = w
              this.recomputeDescOverflow()
            }
          })

        // 展开 / 收起（仅当正文超过 3 行时显示）
        if (this.descShowToggle) {
          Row({ space: 4 }) {
            Text(this.descExpanded ? '收起' : '展开')
              .fontSize(12).fontWeight(600).fontColor(this.theme.primary)
            AppIcon({
              name: this.descExpanded ? AppIconName.ChevronUp : AppIconName.ChevronDown,
              iconSize: 12,
              color: this.theme.primary,
            })
          }
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.getUIContext().animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
              this.descExpanded = !this.descExpanded
            })
          })
        }

        // CC BY-NC-SA 3.0 署名行（不可删 —— 删了违反协议）
        Row({ space: 4 }) {
          AppIcon({ name: AppIconName.Info, iconSize: 11, color: this.theme.textHint })
          Text('内容来自 minecraft.wiki · CC BY-NC-SA 3.0')
            .fontSize(10)
            .fontWeight(400)
            .fontColor(this.theme.textHint)
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 4 })
      }
      .width('100%')
      .padding(14)
      .backgroundColor(this.theme.bgCard)
      .borderRadius(14)
      .alignItems(HorizontalAlign.Start)
    }
    // versionDescLoaded=true 且 versionDesc='' 时：不渲染（else 分支故意省略）
  }

  /**
   * Vulkan 渲染能力 Card（仅 MC 26.2+ 且 this.vulkanHint 非空时由 build() 渲染）。
   *
   * 26.4+ 展示现有版本化探针的设备证据和默认 Vulkan 操作提示；后续未审计版本注明
   * 参考要求。未查询/查询失败用中性“尚未确认”，不能伪装为通过或确定不支持。
   * 下载前报告不替代安装后的客户端/窗口准入，刷新不改用户渲染器偏好。
   */
  @Builder
  VulkanStatusCard() {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        AppIcon({
          name: this.vulkanHint!.available ? AppIconName.CheckCircle : AppIconName.Warning,
          iconSize: 14,
          color: this.vulkanHint?.status === VulkanFeasibilityState.UNKNOWN ? this.theme.textHint
            : (this.vulkanHint!.available ? this.theme.success : this.theme.warning),
        })
        Text('Vulkan 设备检查')
          .fontSize(14).fontWeight(700).fontColor(this.theme.textPrimary)
        Column().layoutWeight(1)
        Text(this.vulkanHint?.statusLabel ?? '')
          .fontSize(11).fontWeight(600)
          .fontColor(this.vulkanHint?.status === VulkanFeasibilityState.UNKNOWN ? this.theme.textHint
            : (this.vulkanHint!.available ? this.theme.success : this.theme.warning))
          .backgroundColor(this.vulkanHint?.status === VulkanFeasibilityState.UNKNOWN ? this.theme.bgCard
            : (this.vulkanHint!.available ? this.theme.successBg : this.theme.warningBg))
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(6)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(this.vulkanHint!.message)
        .fontSize(12)
        .fontWeight(400)
        .fontColor(this.theme.textSecondary)
        .lineHeight(18)
        .width('100%')
      if ((this.vulkanHint?.defaultNotice ?? '').length > 0) {
        Text(this.vulkanHint?.defaultNotice ?? '')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.textPrimary)
          .lineHeight(18)
          .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.theme.bgCard)
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  LoaderSelectCard() {
    Column({ space: 10 }) {
      Row({ space: 6 }) {
        Text('·')
          .fontSize(14).fontWeight(700).fontColor(this.theme.primary)
        Text('选择加载器')
          .fontSize(14).fontWeight(700).fontColor(this.theme.textPrimary)
        Column().layoutWeight(1)
        Text('了解区别 ›')
          .fontSize(11)
          .fontWeight(600)
          .fontColor(this.theme.primary)
          .onClick(() => {
            // 2026-05-23 API NEXT 迁移：promptAction.showToast 弃用，改走 UIContext。
            // 详见 docs/guides/api-migration-2026-05.md。
            this.getUIContext().getPromptAction().showToast({ message: '详细对比页待 R-4 后续接入', duration: 1800 })
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 5 个 loader chips。LOADER_KEYS 表是顶层 const，forEach 取 idx 下标传给 chip。
      Row({ space: 6 }) {
        ForEach([0, 1, 2, 3, 4], (idx: number) => {
          this.LoaderChipCard(idx)
        })
      }
      .width('100%')

      // 选中 loader 详细介绍卡
      if (this.loaderChoice >= 0 && this.loaderChoice < LOADER_KEYS.length
          && this.isLoaderSupported(this.loaderChoice)) {
        Column({ space: 3 }) {
          Text(loaderInfoForChoice(this.loaderChoice).displayName + ' · '
            + this.loaderChoiceSlogan(this.loaderChoice))
            .fontSize(13)
            .fontWeight(700)
            .fontColor(this.theme.primary)
          Text(loaderInfoForChoice(this.loaderChoice).description)
            .fontSize(11)
            .fontWeight(500)
            .fontColor(this.theme.textSecondary)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .maxLines(2)
            .lineHeight(16)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ left: 10, right: 10, top: 8, bottom: 8 })
        .borderRadius(10)
        .backgroundColor(this.theme.primaryLight)
      }

      // 未支持提示（NeoForge / Quilt 选中时）
      if (this.loaderChoice > 0 && !this.isLoaderSupported(this.loaderChoice)) {
        Row({ space: 8 }) {
          AppIcon({ name: AppIconName.Construction, iconSize: 13, color: this.theme.warning })
          Text('该加载器暂未接入，请选择 Fabric 或 Forge')
            .fontSize(11)
            .fontWeight(500)
            .fontColor(this.theme.warning)
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 8, bottom: 8 })
        .borderRadius(10)
        .backgroundColor('#FEF3C7')
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 12, bottom: 10 })
    .backgroundColor(this.theme.bgCard)
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  LoaderChipCard(idx: number) {
    Column({ space: 3 }) {
      // 加载器 chip 图标 —— 用 PCL2 同款 3D 方块（Fabric 织布 / Forge 铁砧 /
      // NeoForge / Quilt）。原版（idx=0）走 game version 推断。
      // 24×24 是 chip 高度 54 - padding - label 后的合理大小，再大会撑出 chip
      VersionBlockIcon({
        category: this.loaderChipCategory(idx),
        versionId: this.gameVersion,
        iconSize: 24,
        cornerRadius: 0,
      })
      Text(loaderInfoForChoice(idx).displayName)
        .fontSize(11)
        .fontWeight(this.loaderChoice === idx ? 700 : 600)
        .fontColor(this.loaderChoice === idx ? this.theme.textOnPrimary : this.theme.textSecondary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .height(54)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(10)
    .backgroundColor(this.loaderChoice === idx ? this.theme.primary : this.theme.bgInput)
    .opacity((loaderInfoForChoice(idx).supported && this.isLoaderJdkReady(idx)) ? 1.0 : 0.55)
    .onClick(() => {
      if (this.loaderChoice === idx) return
      // Forge / NeoForge 需在设备上跑安装器：无可用 JDK 时置灰 + 点击提示去安装，不进入选中态
      let reqJdk = this.requiredJdkForLoader(idx)
      if (reqJdk > 0 && this.resolvedInstallerJdk(reqJdk) === 0) {
        this.promptInstallJdkForLoader(reqJdk)
        return
      }
      this.loaderChoice = idx
      this.loaderVersions = []
      this.selectedLoaderVersion = ''
      this.loaderVersionsEpoch_ += 1  // 作废上一个 loader 仍在飞的版本列表请求
      this.updateAutoName()
      if (idx > 0 && this.isLoaderSupported(idx)) {
        this.loadLoaderVersions()
      }
      // 2026-05-23：Fabric 时起 fetch；非 Fabric 时清空 fabric api 状态。
      if (idx === 1) {
        this.kickOffFabricApi()
      } else {
        this.fabricApiEpoch_ += 1
        this.fabricApiVersion = null
        this.fabricApiPrimary = null
        this.fabricApiLoading = false
        this.fabricApiError = ''
      }
    })
  }

  /**
   * Chip 图标的 category：vanilla（idx=0）按 gameVersion 推断（草方块/快照/愚人节/远古版），
   * 其它走对应 loader 类。空字符串 → 让 VersionBlockIcon 走 versionId 推断。
   *
   * 这里不接选中态：选中态用 chip 自己的 backgroundColor 来高亮，方块本身保持原样
   * 反而比 SymbolGlyph 染白色更好认（金块还是金块、铁砧还是铁砧）。
   */
  private loaderChipCategory(idx: number): string {
    let key = LOADER_KEYS[idx]
    return key === 'vanilla' ? '' : key
  }

  @Builder
  LoaderVersionCard() {
    Column({ space: 10 }) {
      Row({ space: 6 }) {
        Text('·')
          .fontSize(14).fontWeight(700).fontColor(this.theme.primary)
        Text(loaderInfoForChoice(this.loaderChoice).displayName + ' Loader 版本')
          .fontSize(14).fontWeight(700).fontColor(this.theme.textPrimary)
        Column().layoutWeight(1)
        if (this.loaderVersionsLoading) {
          LoadingProgress().width(14).height(14).color(this.theme.primary)
        } else if (this.loaderVersions.length > 0) {
          Text('查看全部')
            .fontSize(11).fontWeight(600).fontColor(this.theme.primary)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 安装器 JDK 需求 / 可用性（仅 Forge/NeoForge 这类需在设备跑安装器的加载器显示）
      if (this.requiredJdkForLoader(this.loaderChoice) > 0) {
        this.JdkRequirementBanner()
      }

      if (this.loaderVersionsLoading) {
        Text('正在获取版本列表...')
          .fontSize(12)
          .fontColor(this.theme.textHint)
      } else if (this.loaderVersionsError.length > 0) {
        Text('加载器版本获取失败：' + this.loaderVersionsError)
          .fontSize(12)
          .fontColor(this.theme.error)
      } else if (this.loaderVersions.length === 0) {
        Text('该 MC 版本暂无可用的 ' + loaderInfoForChoice(this.loaderChoice).displayName + ' 加载器版本')
          .fontSize(12)
          .fontColor(this.theme.textHint)
      } else {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.loaderVersions.slice(0, 8), (ver: ModLoaderVersion) => {
            this.LoaderVersionChip(ver)
          })
        }
        .width('100%')

        // 选中版本提示
        if (this.selectedLoaderVersion.length > 0) {
          Row({ space: 4 }) {
            AppIcon({ name: AppIconName.Check, iconSize: 11, color: this.theme.success, weight: FontWeight.Bold })
            Text('推荐使用最新稳定版本')
              .fontSize(11)
              .fontWeight(500)
              .fontColor(this.theme.success)
          }
          .alignItems(VerticalAlign.Center)
        }
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 8 })
    .backgroundColor(this.theme.bgCard)
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  LoaderVersionChip(ver: ModLoaderVersion) {
    Row({ space: 3 }) {
      if (this.selectedLoaderVersion === ver.loaderVersion) {
        AppIcon({ name: AppIconName.Check, iconSize: 10, color: this.theme.textOnPrimary, weight: FontWeight.Bold })
      }
      Text(ver.loaderVersion)
        .fontSize(11)
        .fontWeight(this.selectedLoaderVersion === ver.loaderVersion ? 700 : 600)
        .fontColor(this.chipTextColor(ver))
      if (!ver.stable) {
        Text('β')
          .fontSize(9)
          .fontWeight(700)
          .fontColor(this.chipBetaTextColor(ver))
      }
    }
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .borderRadius(10)
    .backgroundColor(this.chipBgColor(ver))
    .margin({ right: 6, bottom: 6 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.selectedLoaderVersion = ver.loaderVersion
      this.updateAutoName()
    })
  }

  // ============================================================
  //  Fabric API 伴随下载 Card（2026-05-23）
  //  仅在 loaderChoice=1 时由 build() 渲染。
  //  设计：左侧拼图图标 + 中间标题/版本/大小 + 右侧 Toggle。
  //  状态：loading / error / ready 三态切换右侧控件。
  // ============================================================

  @Builder
  FabricApiCard() {
    Column({ space: 10 }) {
      // ----- header（与其他 Card 同款 ·  小标题）-----
      Row({ space: 6 }) {
        Text('·')
          .fontSize(11).fontWeight(600).fontColor(this.theme.textHint)
        Text('推荐 Mod')
          .fontSize(11).fontWeight(600).fontColor(this.theme.textHint)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // ----- 主体行 -----
      Row({ space: 12 }) {
        // 左：LoaderBadge（PNG 风格）与 LoaderChip / VersionBlockIcon 使用同一 loom logo，
        // 不再用 puzzle_fill 矢量 —— 同一面板内 Fabric 视觉保持一致。
        LoaderBadge({
          loader: 'fabric',
          iconSize: 44,
          style: 'block',
          cornerRadius: 12,
        })

        // 中：标题 + 描述 + 版本大小
        Column({ space: 3 }) {
          Row({ space: 6 }) {
            Text('Fabric API')
              .fontSize(14).fontWeight(700).fontColor(this.theme.textPrimary)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            // "推荐" 小 badge、颜色与 LoaderBadge 同走 LoaderCatalog。
            Text('推荐')
              .fontSize(10).fontWeight(700).fontColor(getLoaderInfo('fabric').accentColor)
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .borderRadius(5)
              .backgroundColor(getLoaderInfo('fabric').accentBg)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text('绝大多数 Fabric 模组的依赖')
            .fontSize(11).fontWeight(500).fontColor(this.theme.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          // 第三行：版本号 + 大小（仅 ready 态显示），loading 时显示 hint，error 时显示 error
          this.FabricApiMetaRow()
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 右：Toggle / loading / 不可用 chip
        if (this.fabricApiLoading) {
          LoadingProgress().width(22).height(22).color(this.theme.primary)
        } else if (this.fabricApiError.length > 0) {
          // 拉取失败：固定 disabled 视觉，不暴露 toggle 让用户切（因为没数据）
          Text('不可用')
            .fontSize(11).fontWeight(600).fontColor(this.theme.textHint)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .borderRadius(6)
            .backgroundColor(this.theme.bgInput)
        } else {
          Toggle({ type: ToggleType.Switch, isOn: this.withFabricApi })
            .selectedColor(this.theme.primary)
            .switchPointColor('#FFFFFF')
            .onChange((on: boolean) => { this.withFabricApi = on })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 14 })
    .backgroundColor(this.theme.bgCard)
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
  }

  /** Fabric API 元数据第三行：根据 state 切换文本 */
  @Builder
  FabricApiMetaRow() {
    if (this.fabricApiLoading) {
      Text('正在获取最新版本...')
        .fontSize(11).fontWeight(500).fontColor(this.theme.textHint)
    } else if (this.fabricApiError.length > 0) {
      Text(this.fabricApiError)
        .fontSize(11).fontWeight(500).fontColor(this.theme.error)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    } else if (this.fabricApiVersion !== null && this.fabricApiPrimary !== null) {
      Row({ space: 6 }) {
        Text(this.fabricApiVersion!.versionNumber)
          .fontSize(11).fontWeight(600).fontColor(this.theme.primary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('·')
          .fontSize(11).fontWeight(500).fontColor(this.theme.textHint)
        Text(formatBytes(this.fabricApiPrimary!.size))
          .fontSize(11).fontWeight(500).fontColor(this.theme.textSecondary)
      }
      .alignItems(VerticalAlign.Center)
    }
  }

  @Builder
  VersionNameCard() {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Text('·')
          .fontSize(14).fontWeight(700).fontColor(this.theme.primary)
        Text('版本名称')
          .fontSize(14).fontWeight(700).fontColor(this.theme.textPrimary)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        TextInput({ text: this.versionName, placeholder: '输入版本名称...' })
          .height(40)
          .fontSize(14)
          .layoutWeight(1)
          .backgroundColor(Color.Transparent)
          .borderRadius(0)
          .onChange((val: string) => {
            this.versionName = val
            if (val !== this._lastAutoName) this.isNameEdited = true
            this.validateName()
          })
        Row() {
          AppIcon({ name: AppIconName.Edit, iconSize: 14, color: this.theme.textHint })
        }
        .padding({ left: 8, right: 12 })
      }
      .width('100%')
      .padding({ left: 12, right: 0 })
      .backgroundColor(this.theme.bgInput)
      .borderRadius(10)
      .alignItems(VerticalAlign.Center)

      Text('安装到 versions/<名称>/')
        .fontSize(11)
        .fontWeight(500)
        .fontColor(this.theme.textHint)
        .width('100%')

      if (this.nameError.length > 0) {
        Row({ space: 6 }) {
          AppIcon({ name: AppIconName.Warning, iconSize: 12, color: this.theme.error })
          Text(this.nameError)
            .fontSize(11)
            .fontWeight(500)
            .fontColor(this.theme.error)
        }
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor(this.theme.bgCard)
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  CtaBar() {
    Row({ space: 10 }) {
      Column({ space: 1 }) {
        Row({ space: 6 }) {
          AppIcon({
            name: AppIconName.ArrowDown,
            iconSize: 14,
            color: this.theme.textOnPrimary,
            weight: FontWeight.Bold,
          })
          Text(this.canStart() ? '开始下载' : this.disabledReason())
            .fontSize(14)
            .fontWeight(700)
            .fontColor(this.theme.textOnPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(VerticalAlign.Center)
        if (this.canStart()) {
          Text('预计 ~ 285 MB')
            .fontSize(10).fontWeight(500).fontColor('#BFDBFE')
        }
      }
      .layoutWeight(1)
      .padding({ left: 16, right: 16, top: this.canStart() ? 8 : 14, bottom: this.canStart() ? 8 : 14 })
      .borderRadius(14)
      .backgroundColor(this.canStart() ? this.theme.primary : this.theme.disabled)
      .alignItems(HorizontalAlign.Center)
      .justifyContent(FlexAlign.Center)
      .onClick(() => { this.startDownload() })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 16 })
    .backgroundColor(this.theme.bgCard)
    .alignItems(VerticalAlign.Center)
  }

  // ============================================================
  //  业务逻辑
  // ============================================================

  /**
   * 加载器（Forge/NeoForge）需安装器 JDK 但设备无可用版本：弹框提示，用户确认后回调上层去下载。
   * @param requiredMajor 所需最低 JDK 大版本（17/21/25）
   */
  private promptInstallJdkForLoader(requiredMajor: number): void {
    let loaderName = loaderInfoForChoice(this.loaderChoice).displayName
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '安装 ' + loaderName + ' 需要 JDK ' + requiredMajor,
        message: '安装 ' + loaderName + ' 需在设备上运行安装器，依赖 ' + this.jdkRequirementText(requiredMajor)
          + '。当前没有可用 JDK，是否前往下载安装 JDK ' + requiredMajor + '？',
        buttons: [
          { text: '取消', color: this.theme.textSecondary as string },
          { text: '去安装', color: this.theme.primary as string },
        ],
      }).then((r: promptAction.ShowDialogSuccessResponse) => {
        if (r.index === 1) this.onInstallJdk(requiredMajor)
      }).catch(() => { /* 用户取消 */ })
    } catch (e) {
      // 兜底：弹框失败直接触发安装回调
      this.onInstallJdk(requiredMajor)
    }
  }

  /**
   * 该 loader 选择**安装时**所需的最低 JDK 大版本；不需要在设备跑安装器的（Vanilla/Fabric）返回 0。
   *
   * Forge(2)/NeoForge(3) 的安装器（installertools/ART/binarypatcher 等 processors）在 fork 子进程
   * 跑。自 2026-06 方案 B 起，fork 子进程改用 jvmInit（含 pre-JVM sigchain），21/25 不再 init 期
   * SIGSEGV，故安装器 JDK 与游戏运行时**同套纪元判定**（commons.requiredJdkMajorForMc：
   * ≤1.20.4→17 / 1.20.5+→21 / 26.1+→25），不再固定 17。引擎再从设备已装集挑 ≥required 的最低。
   */
  private requiredJdkForLoader(idx: number): number {
    if (idx === 2 || idx === 3) return requiredJdkMajorForMc(this.gameVersion)
    return 0
  }

  /** 该 loader 选择对应版本的**游戏运行时**所需最低 JDK（仅用于横幅信息展示，不 gate 安装）。 */
  private runtimeJdkForLoader(idx: number): number {
    if (idx === 2 || idx === 3) return requiredJdkMajorForMc(this.gameVersion)
    return 0
  }

  /** 从设备已装 JDK 集里挑能满足 requiredMajor 的（≥required 最低）；0 = 无可用。 */
  private resolvedInstallerJdk(requiredMajor: number): number {
    if (requiredMajor <= 0) return 0
    return pickInstalledJdkMajor(requiredMajor, this.installedJdkMajors)
  }

  /** chip 是否就绪：不需 JDK 的 loader 恒 true；需 JDK 的看是否有可用安装器 JDK。 */
  private isLoaderJdkReady(idx: number): boolean {
    let req = this.requiredJdkForLoader(idx)
    if (req <= 0) return true
    return this.resolvedInstallerJdk(req) > 0
  }

  /** 需求文案："需安装 JDK 21（或更高，如 25）"；required 已是最高（25）时不带"或更高"。 */
  private jdkRequirementText(requiredMajor: number): string {
    if (requiredMajor >= 25) return 'JDK ' + requiredMajor
    return 'JDK ' + requiredMajor + '（或更高，如 25）'
  }

  @Builder
  JdkRequirementBanner() {
    Row({ space: 8 }) {
      if (this.resolvedInstallerJdk(this.requiredJdkForLoader(this.loaderChoice)) > 0) {
        // 已有可用安装器 JDK：绿色提示 + 运行时 JDK 信息
        AppIcon({ name: AppIconName.Check, iconSize: 13, color: this.theme.success, weight: FontWeight.Bold })
        Text('将用已安装的 JDK ' + this.resolvedInstallerJdk(this.requiredJdkForLoader(this.loaderChoice))
          + ' 安装；该版本运行需 JDK ' + this.runtimeJdkForLoader(this.loaderChoice) + '+（启动时自动匹配）')
          .fontSize(11)
          .fontWeight(500)
          .fontColor(this.theme.success)
          .layoutWeight(1)
      } else {
        // 无可用安装器 JDK：提示需安装所需纪元 JDK + 「去安装」
        AppIcon({ name: AppIconName.Construction, iconSize: 13, color: this.theme.warning })
        Text('安装需 JDK ' + this.requiredJdkForLoader(this.loaderChoice) + '，当前未安装')
          .fontSize(11)
          .fontWeight(500)
          .fontColor(this.theme.warning)
          .layoutWeight(1)
        Text('去安装')
          .fontSize(11)
          .fontWeight(700)
          .fontColor(this.theme.primary)
          .onClick(() => {
            this.onInstallJdk(this.requiredJdkForLoader(this.loaderChoice))
          })
      }
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(10)
    .backgroundColor(this.theme.bgInput)
    .alignItems(VerticalAlign.Center)
  }

  private isLoaderSupported(idx: number): boolean {
    return loaderInfoForChoice(idx).supported
  }

  private loaderChoiceSlogan(idx: number): string {
    switch (idx) {
      case 0: return '纯净版'
      case 1: return '轻量级 mod 加载器'
      case 2: return '经典 mod 加载器'
      case 3: return '前沿（占位）'
      case 4: return '实验（占位）'
      default: return ''
    }
  }

  private chipBgColor(ver: ModLoaderVersion): ResourceColor {
    if (this.selectedLoaderVersion === ver.loaderVersion) return this.theme.primary
    if (!ver.stable) return '#FEF3C7'
    return this.theme.bgInput
  }

  private chipTextColor(ver: ModLoaderVersion): ResourceColor {
    if (this.selectedLoaderVersion === ver.loaderVersion) return this.theme.textOnPrimary
    if (!ver.stable) return '#D97706'
    return this.theme.textSecondary
  }

  private chipBetaTextColor(ver: ModLoaderVersion): ResourceColor {
    if (this.selectedLoaderVersion === ver.loaderVersion) return this.theme.textOnPrimary
    return '#D97706'
  }

  private getLoaderType(): ModLoaderType | null {
    if (this.loaderChoice === 1) return ModLoaderType.FABRIC
    if (this.loaderChoice === 2) return ModLoaderType.FORGE
    if (this.loaderChoice === 3) return ModLoaderType.NEOFORGE
    return null
  }

  private loadLoaderVersions(): void {
    let loaderType = this.getLoaderType()
    if (!loaderType) return

    // 防竞态（与 Fabric API 同款 epoch 守卫）：快速切换 loader 时，慢的旧请求（如 Forge
    // maven-metadata）可能在新请求（NeoForge）之后才 resolve，若不守卫会用旧 loader 的版本
    // 覆盖 selectedLoaderVersion —— 实测表现为「选 NeoForge 却装成 Forge 的 56.0.9」。
    this.loaderVersionsEpoch_ += 1
    let myEpoch = this.loaderVersionsEpoch_
    this.loaderVersionsLoading = true
    this.loaderVersionsError = ''
    this.modLoaderManager.getLoaderVersions(loaderType, this.gameVersion)
      .then((versions: ModLoaderVersion[]) => {
        if (myEpoch !== this.loaderVersionsEpoch_) return  // 已切换到别的 loader，丢弃陈旧结果
        this.loaderVersions = versions
        this.loaderVersionsLoading = false
        for (let v of versions) {
          if (v.stable) {
            this.selectedLoaderVersion = v.loaderVersion
            this.updateAutoName()
            return
          }
        }
        if (versions.length > 0) {
          this.selectedLoaderVersion = versions[0].loaderVersion
          this.updateAutoName()
        }
      })
      .catch((e: Error) => {
        if (myEpoch !== this.loaderVersionsEpoch_) return
        this.loaderVersionsLoading = false
        // 必须把「加载失败」和「这个 MC 版本确实没有该加载器」分开：两者都表现为
        // loaderVersions 为空，而 UI 原来一律显示"暂无可用版本" —— 把网络/解析故障
        // 说成了产品事实，用户会去换 MC 版本而不是去查网络。
        this.loaderVersionsError = e.message || '加载器版本列表获取失败'
        hilog.error(0x0000, TAG, 'Failed to load loader versions: %{public}s', e.message)
      })
  }

  private updateAutoName(): void {
    if (this.isNameEdited) return
    let name = this.gameVersion
    if (this.loaderChoice === 1 && this.selectedLoaderVersion) {
      name = 'fabric-loader-' + this.selectedLoaderVersion + '-' + this.gameVersion
    } else if (this.loaderChoice === 2 && this.selectedLoaderVersion) {
      name = this.gameVersion + '-forge-' + this.selectedLoaderVersion
    } else if (this.loaderChoice === 3 && this.selectedLoaderVersion) {
      name = this.gameVersion + '-neoforge-' + this.selectedLoaderVersion
    }
    this._lastAutoName = name
    this.versionName = name
    this.validateName()
  }

  private validateName(): void {
    this.nameError = ''
    if (this.versionName.length === 0) {
      this.nameError = '版本名称不能为空'
      return
    }
    if (this.versionName.length > MAX_NAME_LENGTH) {
      this.nameError = '版本名称不能超过 ' + MAX_NAME_LENGTH + ' 个字符'
      return
    }
    for (let i = 0; i < this.versionName.length; i++) {
      if (INVALID_NAME_CHARS.indexOf(this.versionName[i]) >= 0) {
        this.nameError = '不能包含字符: ' + this.versionName[i]
        return
      }
    }
    if (isVersionInstalled(this.mcDir, this.versionName)) {
      this.nameError = '版本 ' + this.versionName + ' 已存在'
    }
  }

  private disabledReason(): string {
    if (this.downloading) return '已有下载任务进行中'
    if (this.nameError.length > 0) return this.nameError
    if (this.versionName.length === 0) return '请输入版本名称'
    if (this.loaderChoice > 0 && !this.isLoaderSupported(this.loaderChoice)) {
      return '该加载器暂未支持'
    }
    if (this.loaderChoice > 0 && this.loaderVersionsLoading) return '加载器版本加载中...'
    if (this.loaderChoice > 0 && !this.selectedLoaderVersion) return '请选择加载器版本'
    return '请完成必填项'
  }

  private canStart(): boolean {
    if (this.downloading) return false
    if (this.nameError.length > 0) return false
    if (this.versionName.length === 0) return false
    if (this.loaderChoice > 0 && !this.isLoaderSupported(this.loaderChoice)) return false
    if (this.loaderChoice > 0 && !this.selectedLoaderVersion) return false
    if (this.loaderChoice > 0 && this.loaderVersionsLoading) return false
    return true
  }

  private startDownload(): void {
    if (!this.canStart()) return
    // Forge/NeoForge 安装前 JIT 拦截：二者的安装器都要 fork 一个 JVM 跑 processors，
    // 设备/环境 JIT 不可用时安装必失败，提前拦截避免白下一遍。Forge(=2) / NeoForge(=3) 都查。
    if ((this.loaderChoice === 2 || this.loaderChoice === 3) && !this.checkJitAvailable()) {
      this.promptJitUnavailableForForge()
      return
    }
    // 仅在 Fabric loader + 用户勾选 + 元数据拉到 三个条件全部满足时才伴随下载。
    // 拉取失败 / loading 中 / 未勾选：传 null，让 Index 跳过。
    let api: RemoteVersion | null = null
    if (this.loaderChoice === 1 && this.withFabricApi
        && this.fabricApiVersion !== null && this.fabricApiPrimary !== null) {
      api = this.fabricApiVersion
    }
    this.onStartDownload(
      this.gameVersion,
      this.getLoaderType(),
      this.selectedLoaderVersion,
      this.versionName,
      api,
      api !== null ? this.fabricApiIconUrl : '',
    )
  }

  /** Forge 安装所需 JIT 不可用：弹框说明并拦截（不进入下载）。 */
  private promptJitUnavailableForForge(): void {
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '无法安装 Forge：JIT 不可用',
        message: 'Forge 安装器需要在本机运行一个 Java 进程（依赖 JIT 可执行内存），'
          + '但当前设备/环境探测到 JIT 不可用，安装会失败。\n\n'
          + '请确认已授予应用「可写可执行内存(JIT)」权限后重试；'
          + '或改用 Fabric 加载器。',
        buttons: [
          { text: '如何解决', color: this.theme.textSecondary as string },
          { text: '我知道了', color: this.theme.primary as string },
        ],
      }).then((res: promptAction.ShowDialogSuccessResponse) => {
        // 点「如何解决」（index 0）→ 打开无 JIT 解决办法文档
        if (res.index === 0) this.openNoJitDoc()
      }).catch(() => { /* ignore */ })
    } catch (e) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: 'JIT 不可用，无法安装 Forge', duration: 2200 })
      } catch (e2) { /* ignore */ }
    }
  }

  /** 打开「无 JIT 权限的解决办法」文档（内嵌 WebView）。 */
  private openNoJitDoc(): void {
    try {
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/DocWebPage',
        params: { src: DOCS_NO_JIT_URL, title: 'JIT 的解决办法', fallback: DOCS_NO_JIT_FALLBACK_URL },
      })
    } catch (e) { /* ignore */ }
  }

  // ============================================================
  //  Fabric API 元数据拉取（2026-05-23）
  // ============================================================

  /**
   * 当用户切到 Fabric loader 时调。默认 withFabricApi=true，立刻发起拉取；
   * 拉不到只记录 error，UI 显示 disabled 态，不阻断主下载。
   *
   * 限制 loaders=['fabric'] + game_versions=[gameVersion] 让 Modrinth 过滤；
   * getVersions 不保证排序，故用 pickBestVersion 显式选最新兼容 release（见下方实现）。
   */
  private kickOffFabricApi(): void {
    this.fabricApiEpoch_ += 1
    let myEpoch = this.fabricApiEpoch_
    this.fabricApiVersion = null
    this.fabricApiPrimary = null
    this.fabricApiIconUrl = ''
    this.fabricApiError = ''
    this.fabricApiLoading = true

    let dm = DownloadManager.instance()
    if (!dm.isCaBundleInitialized()) {
      // CA bundle 未就绪——与其走网请求必败，不如直接出错。用户重启 / 等一下再开面板可正常。
      this.fabricApiLoading = false
      this.fabricApiError = '网络未就绪，上拉页面重试'
      return
    }
    let modrinth = new ModrinthRepository(
      dm,
      getMetadataCacheStore(),
      () => ModrinthSourceMode.MCIM_FIRST,
      'AMCL/1.0.0 (https://github.com/axecraft/amcl)',
      () => true,
    )
    modrinth.getVersions('fabric-api', ['fabric'], [this.gameVersion])
      .then((versions: RemoteVersion[]) => {
        if (myEpoch !== this.fabricApiEpoch_) return  // 被后来请求赶上
        if (versions.length === 0) {
          this.fabricApiLoading = false
          this.fabricApiError = '该 MC 版本无可用的 Fabric API'
          return
        }
        // ⚠️ 2026-06-06 修复：Modrinth getVersions 不保证按发布日期降序返回（原样返回 API
        //   顺序），旧代码直接取 versions[0] 会拿到非最新版（实测装 26.1.1 时拿到 0.144.4
        //   而非最新 0.145.x → Sodium 0.8.9 要求 fabric-api ≥0.145.1 → loader 拒绝启动）。
        //   改用 pickBestVersion（release 优先 + datePublished 降序 + 严格匹配 loader/gameVersion），
        //   稳定选到最新兼容的 release。
        let v = pickBestVersion(versions, 'fabric', this.gameVersion)
        if (v === null) {
          this.fabricApiLoading = false
          this.fabricApiError = '该 MC 版本无可用的 Fabric API'
          return
        }
        let f = pickPrimaryFile(v.files)
        if (f === null || f.url.length === 0) {
          this.fabricApiLoading = false
          this.fabricApiError = 'Fabric API 主文件不可下载'
          return
        }
        this.fabricApiVersion = v
        this.fabricApiPrimary = f
        this.fabricApiLoading = false
        // 取项目图标供伴随下载卡片显示（best-effort，失败不影响下载）。
        modrinth.getProjectsByIds(['fabric-api'])
          .then((ps: RemoteProject[]) => {
            if (myEpoch !== this.fabricApiEpoch_) return
            if (ps.length > 0 && ps[0].iconUrl.length > 0) {
              this.fabricApiIconUrl = ps[0].iconUrl
            }
          })
          .catch((e: Error) => {
            hilog.warn(0x0000, TAG, 'fabric-api icon fetch failed: %{public}s', e.message)
          })
      })
      .catch((e: Error) => {
        if (myEpoch !== this.fabricApiEpoch_) return
        this.fabricApiLoading = false
        this.fabricApiError = '拉取失败：' + e.message
        hilog.warn(0x0000, TAG, 'fabric-api fetch failed: %{public}s', e.message)
      })
  }
}
