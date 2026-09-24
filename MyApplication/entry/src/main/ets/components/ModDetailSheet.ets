/**
 * ModDetailSheet.ets — 模组详情 Sheet（Phase R-3 重设计 2026-05-17）
 *
 * 设计稿：
 *   - 旧：docs/design/download-page-redesign/03_mod_detail_sheet.png
 *   - 新：docs/design/mod_detail_sheet.pen（落地版本）
 *
 * 改版要点（vs 旧实现）：
 *   - Hero 头：64 dp 深色圆角图标 + 标题 + "by xxx · 客户端优化" + 三联徽章
 *     （Modrinth · Fabric · MC 1.20.4），徽章用 SymbolGlyph 而非 emoji
 *   - Stats 三列网格：增加 1 px 垂直分隔线（更接近设计稿网格感）
 *     主数字用 textPrimary 加粗（旧实现按色彩区分，对比下显得花）
 *   - Version Select：版本号 + fabric / RELEASE 双 chip + 元信息子行
 *     标题区右侧加"查看全部 ›"次操作（与设计稿一致）
 *   - Deps 卡片：依赖数显示为蓝底圆角 chip 而非纯文字
 *     每行：复选框 + 32 dp 圆角图标 + 名称 + "by 作者 · NNN ↓" + 类型徽章
 *   - CTA Bar：紧凑型 "⇗ 网页" + 双行主按钮（"⇣ 一键安装" + "X + Y 依赖"）
 *
 * 图标系统：
 *   全部图标走 AppIcon + IconCatalog（详见 docs/guides/icon-system-guide.md）。
 *   所有"看起来像图标"的字符（▾ ‹ ↓ ⇗ ✓）都走 SymbolGlyph，仅排版用的 ·
 *   保留为文本字符。
 *
 * 当前 UI 占位策略：
 *   - selected version / dependencies 由调用方（ModBrowsePage 或 Index）传入
 *   - 若未提供则展示空占位（"尚未加载版本"）
 *   - 一键安装回调透传给现有的 quickInstall 逻辑
 */

import { ThemeColors } from 'commons';
import {
  ModSource, RemoteProject, RemoteVersion, RemoteFile, DependencyType, VersionChannel,
  pickPrimaryFile, displayTitleOf,
  mcmodClassUrl, modrinthWebUrl, curseforgeWebUrl,
} from 'mods';
import { formatBytes } from 'commons';
import { compareMcVersion } from 'commons';
import { compareModVersionFreshness } from 'mods';
import { AppIconName } from 'commons';
import { AppIcon } from './AppIcon';
import { RemoteImage } from './RemoteImage';
import { kindIcon, formatDownloadCount } from './ModCard';
// 2026-05-23 图标系统统一：loader name → icon/颜色全部走 LoaderCatalog。
import { inferLoaderInfo } from '../components/LoaderCatalog';
// 2026-05-23 语义色统一：source品牌 / channel 发布通道 / dep 依赖类型全走 SemanticColors。
import { SemanticTone, modSourceTone, channelTone, depTypeTone } from '../components/SemanticColors';

/** 简化的依赖展示行（UI 占位用，避免直接耦合 ResolvedDependency 内部结构） */
export interface ModDetailDepRow {
  /** mod 名（可读，未拉到时回退 projectId） */
  displayName: string;
  /** 作者；缺失时空串 */
  author: string;
  /** 远程图标 URL；缺失时回退到 SymbolGlyph 占位 */
  iconUrl: string;
  /** 下载量（用于"by 作者 · 22.5M ↓"副信息行）；< 0 表示未知 */
  downloads: number;
  dependencyType: DependencyType;
  estimatedSizeBytes: number;
  /**
   * 当前是否勾选（CTA 大小累计 + install 时是否真的下载都看这一位）。
   * 父组件维护 selection set，每次 toggle 重建数组传入；UI 只负责渲染。
   */
  selected: boolean;
  /**
   * 是否是本地已装项 —— LocalModScanner 命中时为 true。
   * UI 表现：行整体 opacity 0.55 + 复选框禁用 + 灰 "已装" chip 替代类型徽章。
   */
  alreadyInstalled: boolean;
  /** 跨源唯一 key（避免 ForEach 警告） */
  key: string;
  /**
   * 兼容性警告（人类可读）；undefined 表示无警告。
   * 来源：ModDependencyResolver 检测到主模组显式声明的精确依赖版本（versionId）
   * 不支持当前游戏版本时下发。UI 表现：依赖行下方一行橙色警告文字。
   */
  compatWarning?: string;
  versionNumber?: string;
}

/** Picker 分组：一个 MC 版本（或分组名）下的若干远端版本（PCL2 风格的版本分类）。 */
interface McVersionGroup {
  /** 分组键：MC 版本号（如 "1.21.1" / "26.1.2"）或 "其他" */
  mc: string;
  /** 该组下的版本（按父组件给的发布时间倒序保留） */
  versions: RemoteVersion[];
}

@Component
export struct ModDetailSheet {
  @Prop theme: ThemeColors = {} as ThemeColors
  @Prop bottomSafeHeight: number = 0

  /** 当前展示的项目；空对象表示"无选中状态"占位 */
  @Prop project: RemoteProject = {} as RemoteProject

  /** 当前选定的版本（已挑好的 best version）；null 时显示占位 */
  @Prop selectedVersion: RemoteVersion | null = null

  /** 选定版本的 primary file（决定下载大小、文件名） */
  @Prop primaryFile: RemoteFile | null = null

  /** 依赖项展示（已解析后的简化行） */
  @Prop dependencies: ModDetailDepRow[] = []

  /**
   * 该项目的全部远端版本列表（按 datePublished 排序，最新在前）。
   * 由父组件在 openDetail 时调 `repo.getVersions(projectId, ...)` 拉到 → 透传。
   * 用于 step 2 「版本 picker」的列表展示；空数组时 picker 显示空占位。
   */
  @Prop allVersions: RemoteVersion[] = []

  /**
   * 反查到本地已装的版本 id 集合（如 ["abc123", "def456"]）。
   * 由父组件用 LocalModScanner 命中后塞入。Picker 列表里这些版本显示
   * "已装" 灰 chip + 整行 opacity 0.55，不可点。
   * 与 dependencies[].alreadyInstalled 是不同维度（前者按版本 id，后者按 projectId）。
   */
  @Prop installedVersionIds: string[] = []

  /**
   * 本地扫描诊断信息（一行可读字串）。空串表示不展示。
   * 格式约定（由调用方决定）：
   *   - "正在扫描本地 mods/…"          —— 扫描中
   *   - "✓ 本地已装该版本"             —— 选中版命中
   *   - "↑ 已装旧版（v0.91.0），可升级" —— 装了别的版本
   *   - "本地未识别（共 12 个 mod）"   —— 扫到 mod 但无匹配
   *   - "扫描失败：…"                  —— 出错
   * 显示在版本选择卡内部底部，14 sp 灰字一行。
   */
  @Prop scanInfo: string = ''

  /** 是否正在加载版本/依赖 */
  @Prop loading: boolean = false
  @Prop blockingError: string = ''

  onInstall: () => void = () => {}
  onOpenWebsite: () => void = () => {}
  /** 打开指定 URL（由父组件经 Want 拉起浏览器）。网页菜单各项走这里。 */
  onOpenUrl: (url: string) => void = () => {}
  /** 切换下载源（双源资源：在 Modrinth / CurseForge 间切换，父组件重拉该源版本）。 */
  onSwitchSource: (source: ModSource) => void = () => {}
  /** 打开"另一源"页面（父组件按真实工程数据解析真实网址，避免按分类猜 URL 导致 404）。 */
  onOpenCrossSourceWeb: (source: ModSource) => void = () => {}
  onClose: () => void = () => {}
  /** 点击依赖一行（切换勾选） */
  onToggleDep: (key: string) => void = () => {}
  /** 点击"全选"（一键勾选所有未选） */
  onSelectAllDeps: () => void = () => {}
  /**
   * 点击 picker 列表中的某个版本 → 父组件重算 primaryFile + 依赖。
   * 选中后 sheet 滑入第三级"版本详情"页（不再自动回主页）。
   */
  onSelectVersion: (version: RemoteVersion) => void = () => {}

  // ==================== 内部 step 状态 ====================

  /**
   * 同 sheet 内 step 切换：'main' = Hero/Stats/Deps/CTA；'picker' = 版本列表（按 MC 版本分类）；
   * 'detail' = 单个版本的第三级详情页（文件/依赖/安装）。
   * 仿照 VersionManagerSheet 的单 sheet 多级模式（horizontally translated Stack）。
   * slidePct：0 = main，1 = picker，2 = detail（整数步进，animateTo 平滑过渡）。
   */
  @State private currentStep: string = 'main'
  @State private slidePct: number = 0
  @State private viewportW: number = 375
  /** 第三级当前展开的游戏版本分组（picker 点哪个游戏版本进来的）。 */
  @State private selectedMcGroup: string = ''
  private static readonly ANIM_DURATION_MS = 280

  build() {
    Column() {
      // ============== Drag pill（两个 step 共用） ==============
      Row() {
        Column().width(36).height(4).backgroundColor(this.theme.divider).borderRadius(2)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 10, bottom: 4 })

      // ============== 双 step 容器（horizontal slide） ==============
      Stack() {
        // Main step
        Column() {
          this.MainStep()
        }
        .width('100%').height('100%')
        .translate({ x: -this.slidePct * this.viewportW })

        // Picker step
        Column() {
          this.PickerStep()
        }
        .width('100%').height('100%')
        .translate({ x: (1 - this.slidePct) * this.viewportW })

        // Files step（第三级：某游戏版本下的全部模组版本）
        Column() {
          this.GroupFilesStep()
        }
        .width('100%').height('100%')
        .translate({ x: (2 - this.slidePct) * this.viewportW })
      }
      .width('100%')
      .layoutWeight(1)
      .clip(true)
      .onAreaChange((_, area) => {
        let w = area.width as number
        if (w > 0 && Math.abs(w - this.viewportW) > 0.5) {
          this.viewportW = w
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.bgPrimary)
  }

  // ============================================================
  //  Step 1：主视图（Hero / Stats / Desc / Version / Deps + CTA）
  // ============================================================

  @Builder
  MainStep() {
    Column() {
      Scroll() {
        Column({ space: 10 }) {
          this.HeroCard()
          this.StatsCard()
          if (this.project.summary && this.project.summary.length > 0) {
            this.DescCard()
          }
          this.VersionSelectCard()
          // 依赖卡片：始终展示（哪怕 0 个）— 让用户明确知道"这 mod 没依赖"，
          // 而不是看到没卡片就以为流程出错。仅当当前选中版本本身不存在时才隐藏。
          if (this.selectedVersion !== null) {
            this.DepsCard()
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 6, bottom: 8 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      this.CtaBar()
    }
    .width('100%').height('100%')
  }

  // ============================================================
  //  Hero Card —— 大图标 + 标题 + 作者 + 三联徽章
  // ============================================================

  @Builder
  HeroCard() {
    Row({ space: 12 }) {
      // 64 dp 圆角图标位（远程 iconUrl，失败 fallback 到深色 + kindIcon）
      RemoteImage({
        url: this.project.iconUrl,
        diameter: 64,
        cornerRadius: 16,
        fallbackIcon: this.project.kind !== undefined ? kindIcon(this.project.kind) : AppIconName.Mod,
        fallbackBg: '#0F172A',
        fallbackColor: '#FFFFFF',
        fallbackIconSize: 32,
      })

      Column({ space: 6 }) {
        // 主标题
        Text(displayTitleOf(this.project).length > 0
            ? displayTitleOf(this.project) : '—')
          .fontSize(22)
          .fontWeight(700)
          .fontColor(this.theme.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        // by xxx · 类别副标题
        Row({ space: 6 }) {
          Text('by')
            .fontSize(12).fontWeight(500).fontColor(this.theme.textSecondary)
          if (this.project.author && this.project.author.length > 0) {
            Text(this.project.author)
              .fontSize(12).fontWeight(600).fontColor(this.theme.textPrimary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          } else {
            Text('—').fontSize(12).fontColor(this.theme.textHint)
          }
          if (this.project.summary && this.project.summary.length > 0) {
            Text('·').fontSize(12).fontColor(this.theme.textHint)
            Text('客户端优化') // TODO: 接 categories 后替换
              .fontSize(12).fontWeight(500).fontColor(this.theme.textSecondary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(VerticalAlign.Center)

        // 三联徽章：源 · loader · MC 版本（位置不够自动换行，不挤出屏幕）
        Flex({ wrap: FlexWrap.Wrap }) {
          this.SourceBadge()
          if (this.project.loaders && this.project.loaders.length > 0) {
            this.LoaderChip(this.project.loaders[0])
          }
          if (this.supportedVersionLabel().length > 0) {
            this.McVersionBadge(this.supportedVersionLabel())
          }
        }
        .width('100%')
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
   * 徽章：资源源（Modrinth / CurseForge）
   *
   * 2026-05-23：品牌色走 SemanticColors.modSourceTone，品牌颜色不随 theme 漂（Modrinth
   * 绿在深色主题仍保持 #16A34A 以保识别）。
   */
  @Builder
  SourceBadge() {
    if (this.project.source === ModSource.MODRINTH) {
      this.SourceBadgeBox(modSourceTone(ModSource.MODRINTH), 'Modrinth')
    } else if (this.project.source === ModSource.CURSEFORGE) {
      this.SourceBadgeBox(modSourceTone(ModSource.CURSEFORGE), 'CurseForge')
    }
    // 双源：同一资源在 Modrinth + CurseForge 都有时，再补一个另一源的标签
    if (this.project.altSource === ModSource.MODRINTH) {
      this.SourceBadgeBox(modSourceTone(ModSource.MODRINTH), 'Modrinth')
    } else if (this.project.altSource === ModSource.CURSEFORGE) {
      this.SourceBadgeBox(modSourceTone(ModSource.CURSEFORGE), 'CurseForge')
    }
  }

  @Builder
  SourceBadgeBox(tone: SemanticTone, label: string) {
    Row({ space: 4 }) {
      Text('●').fontSize(10).fontColor(tone.color)
      Text(label)
        .fontSize(10).fontWeight(700).fontColor(tone.color)
    }
    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
    .borderRadius(6)
    .backgroundColor(tone.bg)
    .alignItems(VerticalAlign.Center)
    .margin({ right: 6, bottom: 4 })
  }

  /**
   * 徽章：loader chip（fabric / forge / quilt / neoforge）。
   *
   * 2026-05-23 重命名为 LoaderChip：与新的顶层 LoaderBadge struct（画 PNG 方块 / 大徽章）
   * 区分。本函数画的是 inline chip（图标 + 名字 + padding），同面板内不互换。
   */
  @Builder
  LoaderChip(loader: string) {
    Row({ space: 4 }) {
      AppIcon({
        name: this.loaderIconName(loader),
        iconSize: 10,
        color: this.loaderTextColor(loader),
      })
      Text(this.capitalize(loader))
        .fontSize(10).fontWeight(700).fontColor(this.loaderTextColor(loader))
    }
    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
    .borderRadius(6)
    .backgroundColor(this.loaderBg(loader))
    .alignItems(VerticalAlign.Center)
    .margin({ right: 6, bottom: 4 })
  }

  /** 徽章：MC 版本（蓝色主题色） */
  @Builder
  McVersionBadge(gv: string) {
    Text('MC ' + gv)
      .fontSize(10).fontWeight(700).fontColor(this.theme.primary)
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .borderRadius(6)
      .backgroundColor(this.theme.primaryLight)
      .margin({ right: 6, bottom: 4 })
  }

  // ============================================================
  //  Stats Card —— 三列网格（下载量 · 关注 · 更新）
  // ============================================================

  @Builder
  StatsCard() {
    Row() {
      this.StatCell(this.formatCount(this.project.downloads), '↓ 下载量')
      Column().width(1).height(36).backgroundColor(this.theme.divider)
      this.StatCell(this.formatCount(this.project.follows), '★ 关注')
      Column().width(1).height(36).backgroundColor(this.theme.divider)
      this.StatCell(this.formatUpdated(this.project.dateModified), '⏱ 更新')
    }
    .width('100%')
    .padding(12)
    .backgroundColor(this.theme.bgCard)
    .borderRadius(14)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  StatCell(value: string, label: string) {
    Column({ space: 4 }) {
      Text(value)
        .fontSize(18).fontWeight(700).fontColor(this.theme.textPrimary)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(label)
        .fontSize(11).fontWeight(500).fontColor(this.theme.textSecondary)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  // ============================================================
  //  Description Card
  // ============================================================

  @Builder
  DescCard() {
    Column({ space: 6 }) {
      this.SectionHeader('简介')
      Text(this.project.summary)
        .fontSize(13)
        .fontColor(this.theme.textSecondary)
        .lineHeight(20)
        .width('100%')
        .maxLines(4)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding(12)
    .backgroundColor(this.theme.bgCard)
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
  }

  // ============================================================
  //  Version Select Card
  // ============================================================

  @Builder
  VersionSelectCard() {
    Column({ space: 8 }) {
      Row() {
        Text('·')
          .fontSize(14).fontWeight(700).fontColor(this.theme.primary)
          .margin({ right: 6 })
        Text('选择版本')
          .fontSize(14).fontWeight(700).fontColor(this.theme.textPrimary)
          .layoutWeight(1)
        Row({ space: 2 }) {
          Text('查看全部')
            .fontSize(11).fontWeight(600).fontColor(this.theme.primary)
          AppIcon({ name: AppIconName.ChevronRight, iconSize: 11, color: this.theme.primary })
        }
        .alignItems(VerticalAlign.Center)
        .onClick(() => { this.gotoPicker() })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.loading) {
        Row({ space: 8 }) {
          LoadingProgress().width(16).height(16).color(this.theme.primary)
          Text('正在拉取版本列表...')
            .fontSize(12).fontColor(this.theme.textHint)
        }
        .padding({ left: 12, right: 12, top: 12, bottom: 12 })
        .backgroundColor(this.theme.bgInput)
        .borderRadius(10)
        .alignItems(VerticalAlign.Center)
      } else if (this.selectedVersion === null) {
        Text('尚未加载版本')
          .fontSize(12).fontColor(this.theme.textHint)
          .padding({ left: 12, right: 12, top: 12, bottom: 12 })
          .backgroundColor(this.theme.bgInput)
          .borderRadius(10)
      } else {
        Row({ space: 8 }) {
          Column({ space: 4 }) {
            // 版本号（完整显示，过长换行，不靠省略号截断）
            Text(this.selectedVersion!.versionNumber)
              .fontSize(14).fontWeight(700).fontColor(this.theme.textPrimary)
              .width('100%')
              .wordBreak(WordBreak.BREAK_ALL)
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })

            // 标签行：loader + channel（位置不够自动换行）
            Flex({ wrap: FlexWrap.Wrap }) {
              if (this.selectedVersion!.loaders.length > 0) {
                Text(this.selectedVersion!.loaders[0])
                  .fontSize(9).fontWeight(700).fontColor(this.loaderTextColor(this.selectedVersion!.loaders[0]))
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .borderRadius(5)
                  .backgroundColor(this.loaderBg(this.selectedVersion!.loaders[0]))
                  .margin({ right: 6, bottom: 4 })
              }
              Text(this.channelLabel_(this.selectedVersion!.versionType))
                .fontSize(9).fontWeight(700)
                .fontColor(channelTone(this.selectedVersion!.versionType, this.theme).color)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(5)
                .backgroundColor(channelTone(this.selectedVersion!.versionType, this.theme).bg)
                .margin({ right: 6, bottom: 4 })
            }
            .width('100%')

            // MC 版本 · 日期 · 大小
            Text(this.versionSubInfo())
              .fontSize(11).fontWeight(500).fontColor(this.theme.textSecondary)
              .width('100%')
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          AppIcon({
            name: AppIconName.ChevronDown,
            iconSize: 14,
            color: this.theme.textSecondary,
            weight: FontWeight.Bold,
          })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .backgroundColor(this.theme.bgInput)
        .borderRadius(10)
        .alignItems(VerticalAlign.Center)
        .onClick(() => { this.gotoPicker() })
      }

      if (this.blockingError.length > 0) {
        Text(this.blockingError).fontSize(12).fontColor(this.theme.warning).width('100%')
      }
      // 本地扫描诊断：让用户能看到 sheet 是否真的找到本地已装
      if (this.scanInfo.length > 0) {
        Row({ space: 4 }) {
          AppIcon({
            name: this.scanInfoIcon(),
            iconSize: 11,
            color: this.scanInfoColor(),
          })
          Text(this.scanInfo)
            .fontSize(11).fontWeight(500).fontColor(this.scanInfoColor())
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(this.theme.bgCard)
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * Channel 徽章：RELEASE / BETA / ALPHA
   *
   * 2026-05-23：颜色走 SemanticColors.channelTone，BETA 走 theme.warning、ALPHA 走 theme.error，
   * RELEASE 走 theme.primary——深浅主题都自适应。
   *
   * 注：ArkTS @Builder 内不允许普通 let 语句，tone/label 预计算抽到 private 方法。
   */
  @Builder
  ChannelBadge(channel: VersionChannel) {
    Text(this.channelLabel_(channel))
      .fontSize(9).fontWeight(700)
      .fontColor(channelTone(channel, this.theme).color)
      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      .borderRadius(5)
      .backgroundColor(channelTone(channel, this.theme).bg)
  }

  private channelLabel_(channel: VersionChannel): string {
    if (channel === VersionChannel.BETA)  return 'BETA'
    if (channel === VersionChannel.ALPHA) return 'ALPHA'
    return 'RELEASE'
  }

  // ============================================================
  //  Dependencies Card
  // ============================================================

  @Builder
  DepsCard() {
    Column({ space: 6 }) {
      Row() {
        Text('·')
          .fontSize(14).fontWeight(700).fontColor(this.theme.primary)
          .margin({ right: 6 })
        Text('依赖项')
          .fontSize(14).fontWeight(700).fontColor(this.theme.textPrimary)
          .margin({ right: 8 })
        Text(this.dependencies.length.toString())
          .fontSize(11).fontWeight(700).fontColor(this.theme.primary)
          .padding({ left: 8, right: 8, top: 1, bottom: 1 })
          .borderRadius(8)
          .backgroundColor(this.theme.primaryLight)
        Column().layoutWeight(1)
        if (this.dependencies.length > 0 && this.hasAnyTogglableDep()) {
          Text('全选')
            .fontSize(11).fontWeight(600).fontColor(this.theme.primary)
            .onClick(() => { this.onSelectAllDeps() })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.dependencies.length === 0) {
        // 无依赖：明确告诉用户 — 让"啥都没有"这种状态可被理解（例如 Sodium 不依赖 Fabric API）
        Row({ space: 6 }) {
          AppIcon({
            name: AppIconName.CheckCircle,
            iconSize: 12,
            color: this.theme.success,
          })
          Text('该模组无外部依赖，可独立安装')
            .fontSize(12).fontWeight(500).fontColor(this.theme.textSecondary)
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 10, bottom: 10 })
        .backgroundColor(this.theme.bgInput)
        .borderRadius(10)
        .alignItems(VerticalAlign.Center)
      } else {
        // 聚合兼容性横幅：任一必需依赖的精确版本（versionId）不支持当前游戏版本时提示。
        if (this.hasAnyCompatWarning()) {
          Row({ space: 6 }) {
            AppIcon({
              name: AppIconName.Warning,
              iconSize: 14,
              color: this.theme.warning,
            })
            Text('部分依赖尚未解决，请查看下方原因并选择兼容版本')
              .fontSize(12).fontWeight(600).fontColor(this.theme.warning)
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 10, right: 10, top: 9, bottom: 9 })
          .backgroundColor(this.theme.warningBg)
          .borderRadius(10)
          .alignItems(VerticalAlign.Center)
          .margin({ bottom: 4 })
        }
        ForEach(this.dependencies, (d: ModDetailDepRow) => {
          this.DepRow(d)
        }, (d: ModDetailDepRow) => d.key + '|' + (d.selected ? '1' : '0') + '|' + (d.alreadyInstalled ? '1' : '0') + '|' + (d.compatWarning !== undefined ? '1' : '0'))
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 12, bottom: 10 })
    .backgroundColor(this.theme.bgCard)
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
  }

  /** 是否有任一依赖带兼容性警告（决定聚合横幅是否显示）。 */
  private hasAnyCompatWarning(): boolean {
    for (let d of this.dependencies) {
      if (d.compatWarning !== undefined && d.compatWarning.length > 0) return true
    }
    return false
  }

  @Builder
  DepRow(d: ModDetailDepRow) {
    Column({ space: 6 }) {
      Row({ space: 10 }) {
      // 复选框（勾选 = 蓝实心 + ✓；未勾 = 白底灰边；已装 = 灰禁用 + ✓）
      Stack() {
        Column()
          .width(18).height(18)
          .borderRadius(5)
          .backgroundColor(this.depCheckboxBg(d))
          .border(d.alreadyInstalled || d.selected
            ? { width: 0 }
            : { width: 1.5, color: this.theme.divider })
        if (d.selected || d.alreadyInstalled) {
          AppIcon({
            name: AppIconName.Check,
            iconSize: 12,
            color: this.theme.textOnPrimary,
            weight: FontWeight.Bold,
          })
        }
      }
      .width(18).height(18)

      // 32 dp 圆角图标位（远程 icon URL，失败 fallback 到深色 + 拼图图标）
      RemoteImage({
        url: d.iconUrl,
        diameter: 32,
        cornerRadius: 8,
        fallbackIcon: AppIconName.Mod,
        fallbackBg: '#0F172A',
        fallbackColor: '#FFFFFF',
        fallbackIconSize: 16,
      })

      // 名称 + 副信息行
      Column({ space: 3 }) {
        Text(d.displayName)
          .fontSize(13).fontWeight(700).fontColor(this.theme.textPrimary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        if ((d.versionNumber ?? '').length > 0) {
          Text(d.versionNumber ?? '').fontSize(11).fontColor(this.theme.textSecondary)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Text(this.depSubLine(d))
          .fontSize(11).fontWeight(500).fontColor(this.theme.textSecondary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 类型徽章；已装项替换为灰色"已装"徽章
      if (d.alreadyInstalled) {
        Text('已装')
          .fontSize(9).fontWeight(700).fontColor(this.theme.textSecondary)
          .padding({ left: 6, right: 6, top: 3, bottom: 3 })
          .borderRadius(6).backgroundColor(this.theme.bgInput)
      } else {
        this.DepTypeBadge(d.dependencyType)
      }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 逐行兼容性警告：该依赖的精确版本（versionId）不支持当前游戏版本时展示。
      if (d.compatWarning !== undefined && d.compatWarning.length > 0) {
        Row({ space: 6 }) {
          AppIcon({
            name: AppIconName.Warning,
            iconSize: 12,
            color: this.theme.warning,
          })
          Text(d.compatWarning)
            .fontSize(11).fontWeight(500).fontColor(this.theme.warning)
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .backgroundColor(this.theme.bgInput)
    .borderRadius(10)
    .opacity(d.alreadyInstalled ? 0.55 : 1)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      // 已装项不可切换（CTA 也不会下载它），点击吞掉
      if (d.alreadyInstalled) return
      this.onToggleDep(d.key)
    })
  }

  /**
   * 依赖类型徽章：REQUIRED / OPTIONAL / INCOMPATIBLE / EMBEDDED。
   *
   * 2026-05-23：颜色走 SemanticColors.depTypeTone。REQUIRED=theme.error，
   * OPTIONAL=theme.warning，INCOMPATIBLE 保留独立紫避免与 REQUIRED 撞色，
   * EMBEDDED 中性。
   *
   * 注：ArkTS @Builder 内不允许普通 let 语句，tone/label 预计算抽到 private 方法。
   */
  @Builder
  DepTypeBadge(t: DependencyType) {
    Text(this.depTypeLabel_(t))
      .fontSize(9).fontWeight(700)
      .fontColor(depTypeTone(t, this.theme).color)
      .padding({ left: 6, right: 6, top: 3, bottom: 3 })
      .borderRadius(6)
      .backgroundColor(depTypeTone(t, this.theme).bg)
  }

  private depTypeLabel_(t: DependencyType): string {
    if (t === DependencyType.REQUIRED)     return 'REQUIRED'
    if (t === DependencyType.OPTIONAL)     return 'OPTIONAL'
    if (t === DependencyType.INCOMPATIBLE) return 'INCOMPAT'
    return 'EMBEDDED'
  }

  // ============================================================
  //  Sticky CTA Bar
  // ============================================================

  @Builder
  CtaBar() {
    Column({ space: 8 }) {
      // 双源资源：下载源选择（"一键安装"= 当前选中源；可切到另一源；默认 = 自动选源）
      if (this.project.altSource !== undefined) {
        this.SourceSelectorRow()
      }
      Row({ space: 10 }) {
      // 紧凑型"网页"次按钮
      Row({ space: 6 }) {
        AppIcon({
          name: AppIconName.ArrowUpRight,
          iconSize: 14,
          color: this.theme.textPrimary,
          weight: FontWeight.Bold,
        })
        Text('网页')
          .fontSize(13).fontWeight(600).fontColor(this.theme.textPrimary)
      }
      .padding({ left: 14, right: 14, top: 12, bottom: 12 })
      .backgroundColor(this.theme.bgInput)
      .borderRadius(14)
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.Center)
      .bindMenu(this.buildWebMenu())

      // 主按钮：4 状态（已装当前版 / 升级 / 安装 / 不可装）
      Column({ space: 1 }) {
        Row({ space: 6 }) {
          AppIcon({
            name: this.ctaIcon(),
            iconSize: 14,
            color: this.theme.textOnPrimary,
            weight: FontWeight.Bold,
          })
          Text(this.ctaTitle())
            .fontSize(14).fontWeight(700).fontColor(this.theme.textOnPrimary)
        }
        .alignItems(VerticalAlign.Center)
        if (this.ctaSubText().length > 0) {
          Text(this.ctaSubText())
            .fontSize(10).fontWeight(500).fontColor('#BFDBFE')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .padding({
        left: 16, right: 16,
        top: this.ctaSubText().length > 0 ? 8 : 14,
        bottom: this.ctaSubText().length > 0 ? 8 : 14,
      })
      .borderRadius(14)
      .backgroundColor(this.ctaButtonColor())
      .alignItems(HorizontalAlign.Center)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        if (this.canInstall()) this.onInstall()
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({
      left: 16, right: 16, top: 10,
      bottom: 16 + this.bottomSafeHeight,
    })
    .backgroundColor(this.theme.bgCard)
  }

  /** 双源下载源选择行（仅 project.altSource 存在时显示）。 */
  @Builder
  SourceSelectorRow() {
    Row({ space: 8 }) {
      Text('下载源')
        .fontSize(11).fontColor(this.theme.textHint)
      this.SourcePick(ModSource.MODRINTH, 'Modrinth')
      this.SourcePick(ModSource.CURSEFORGE, 'CurseForge')
      Blank()
      Text('一键安装将从所选源下载')
        .fontSize(10).fontColor(this.theme.textHint)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  SourcePick(src: ModSource, label: string) {
    Text(label)
      .fontSize(11)
      .fontWeight(this.project.source === src ? 700 : 500)
      .fontColor(this.project.source === src ? this.theme.textOnPrimary : this.theme.textSecondary)
      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      .borderRadius(10)
      .backgroundColor(this.project.source === src ? this.theme.primary : this.theme.bgInput)
      .onClick(() => {
        if (this.project.source === src) return
        this.onSwitchSource(src)
      })
  }

  // ============================================================
  //  小工具
  // ============================================================

  /** 通用 section header："· <title>" */
  @Builder
  SectionHeader(title: string) {
    Row() {
      Text('·')
        .fontSize(14).fontWeight(700).fontColor(this.theme.primary)
        .margin({ right: 6 })
      Text(title)
        .fontSize(14).fontWeight(700).fontColor(this.theme.textPrimary)
    }
    .alignItems(VerticalAlign.Center)
  }

  // ============================================================
  //  helpers
  // ============================================================

  /**
   * 模组标题区"支持版本"标签：真实数据源（allVersions 的 gameVersions 并集，回退
   * project.gameVersions）里的正式版算最低/最高——≥4 个显示区间"最低 - 最高"（最高即实时最新
   * 支持版本，如 "1.16.5 - 26.2"）；≤3 个/较零散只显示最低。比较走统一 commons.compareMcVersion。
   */
  private supportedVersionLabel(): string {
    let seen: Set<string> = new Set<string>()
    let list: string[] = []
    if (this.allVersions.length > 0) {
      for (let v of this.allVersions) {
        for (let gv of v.gameVersions) {
          if (gv.length > 0 && !seen.has(gv)) { seen.add(gv); list.push(gv) }
        }
      }
    }
    if (list.length === 0 && this.project.gameVersions) {
      for (let gv of this.project.gameVersions) {
        if (gv.length > 0 && !seen.has(gv)) { seen.add(gv); list.push(gv) }
      }
    }
    if (list.length === 0) return ''
    // 过滤掉快照（含 'w'）等非正式版，避免污染 min/max；全被滤掉则退回原始列表
    let rel: string[] = []
    for (let g of list) {
      if (/^[0-9]/.test(g) && g.indexOf('w') < 0) rel.push(g)
    }
    let use = rel.length > 0 ? rel : list
    let sorted = use.slice().sort((a: string, b: string): number => compareMcVersion(a, b))
    let min = sorted[0]
    let max = sorted[sorted.length - 1]
    if (use.length <= 3 || min === max) return min
    return min + ' - ' + max
  }

  private formatCount(n: number): string {
    if (n < 0) return '—'
    if (n < 1000) return n.toString()
    if (n < 1_000_000) return (n / 1000).toFixed(1) + 'K'
    if (n < 1_000_000_000) return (n / 1_000_000).toFixed(1) + 'M'
    return (n / 1_000_000_000).toFixed(1) + 'B'
  }

  /** ISO-8601 → "2d 前" 等友好格式 */
  private formatUpdated(iso: string): string {
    if (!iso || iso.length === 0) return '—'
    try {
      let then = new Date(iso).getTime()
      let now = Date.now()
      let diffSec = Math.max(0, Math.floor((now - then) / 1000))
      if (diffSec < 60) return '刚刚'
      if (diffSec < 3600) return Math.floor(diffSec / 60) + 'm 前'
      if (diffSec < 86400) return Math.floor(diffSec / 3600) + 'h 前'
      if (diffSec < 86400 * 30) return Math.floor(diffSec / 86400) + 'd 前'
      if (diffSec < 86400 * 365) return Math.floor(diffSec / (86400 * 30)) + 'mo 前'
      return Math.floor(diffSec / (86400 * 365)) + 'y 前'
    } catch (e) {
      return iso.substring(0, 10)
    }
  }

  /** 选中版本的副信息行："MC 1.20.4 · 2024-11-15 · 368 KB" */
  private versionSubInfo(): string {
    if (!this.selectedVersion) return ''
    let bits: string[] = []
    if (this.selectedVersion.gameVersions && this.selectedVersion.gameVersions.length > 0) {
      bits.push('MC ' + this.selectedVersion.gameVersions[0])
    }
    if (this.selectedVersion.datePublished && this.selectedVersion.datePublished.length > 0) {
      bits.push(this.selectedVersion.datePublished.substring(0, 10))
    }
    if (this.primaryFile && this.primaryFile.size > 0) {
      bits.push(formatBytes(this.primaryFile.size))
    }
    return bits.join(' · ')
  }

  /** 依赖行副信息："by 作者 · NNN ↓"；缺失时降级 */
  private depSubLine(d: ModDetailDepRow): string {
    let bits: string[] = []
    if (d.author && d.author.length > 0) bits.push('by ' + d.author)
    if (d.downloads >= 0) bits.push(formatDownloadCount(d.downloads) + ' ↓')
    else if (d.estimatedSizeBytes > 0) bits.push('~ ' + formatBytes(d.estimatedSizeBytes))
    return bits.length > 0 ? bits.join(' · ') : '依赖项'
  }

  /**
   * 当前选中版本是否在 installedVersionIds 中（按 sha1 反查命中即认为已装）。
   * 注意：versions 同一 id 跨源不冲突 —— Modrinth 用 base62 短 id，CurseForge
   * 用纯数字，正常情况下没有 collision。如需更稳妥可以拼 source:id 比较。
   */
  private isCurrentVersionInstalled(): boolean {
    if (this.selectedVersion === null) return false
    let id = this.selectedVersion.id
    for (let installed of this.installedVersionIds) {
      if (installed === id) return true
    }
    return false
  }

  /**
   * 当前 project 在本地有任意版本已装（即便不是当前选中版本）。
   * 用来区分「当前版已装 → 已装态」与「装的是旧版 → 升级态」。
   */
  private hasAnyVersionInstalled(): boolean {
    return this.installedVersionIds.length > 0
  }

  /**
   * CTA 主按钮文案：
   *   - 加载中：仍显示"一键安装"（按钮整体灰禁用）
   *   - 选中版本已装：「已装该版本」
   *   - 装了别的版本：「升级到该版本」
   *   - 都没装：「一键安装」
   *   - 不可装（无版本 / 无文件 url）：「不可下载」
   */
  private ctaTitle(): string {
    if (this.loading) return '正在解析依赖'
    if (this.blockingError.length > 0) return '依赖尚未解决'
    if (this.selectedVersion === null || this.primaryFile === null
        || this.primaryFile!.url.length === 0) {
      return '不可下载'
    }
    if (this.isCurrentVersionInstalled()) return '检查并重新安装'
    if (this.hasAnyVersionInstalled()) return '升级到该版本'
    return '一键安装'
  }

  /** CTA icon：已装时换成 ✓，否则保持下载箭头 */
  private ctaIcon(): AppIconName {
    if (!this.loading && this.isCurrentVersionInstalled()) {
      return AppIconName.Check
    }
    return AppIconName.ArrowDown
  }

  /** CTA 按钮底色：已装当前版 = success；不可装 = disabled；其它 = primary */
  private ctaButtonColor(): ResourceColor {
    if (!this.canInstall()) return this.theme.disabled
    if (this.isCurrentVersionInstalled()) return this.theme.success
    return this.theme.primary
  }

  /**
   * CTA 主按钮副提示：
   *   - 已装当前版：「无需重新下载」
   *   - 升级：「368 KB + 5.2 MB 依赖（替换旧版）」
   *   - 安装：「368 KB + 5.2 MB 依赖」
   *   - 不可装 / 加载中：空串
   */
  private ctaSubText(): string {
    if (!this.primaryFile || this.loading) return ''
    if (this.primaryFile!.url.length === 0) return ''
    if (this.blockingError.length > 0) return this.blockingError

    let depBytes = 0
    let depCount = 0
    for (let d of this.dependencies) {
      // 已装项不再下载，不计入 CTA 大小
      if (d.alreadyInstalled) continue
      if (d.selected && d.estimatedSizeBytes > 0) {
        depBytes += d.estimatedSizeBytes
        depCount++
      }
    }
    let main = formatBytes(this.primaryFile.size)
    let suffix = this.hasAnyVersionInstalled() ? '（替换旧版）' : ''
    if (depCount === 0) return main + suffix
    return main + ' + ' + formatBytes(depBytes) + ' 依赖' + suffix
  }

  /**
   * 是否允许触发安装（被 CTA 按钮 onClick 守卫）。
   *
   * 注意：当前版已装时仍允许"重装"——不阻塞用户主动重新下载（场景：损坏 jar 修复）。
   * 仅在选中版本不存在 / 没有 primary file / 文件 URL 为空时禁掉。
   */
  private canInstall(): boolean {
    if (this.loading || this.blockingError.length > 0) return false
    return this.selectedVersion !== null
      && this.primaryFile !== null
      && this.primaryFile!.url.length > 0
  }

  // ---- loader 视觉映射 ----
  //
  // 2026-05-23 重构：3 个 switch 全部委托给 LoaderCatalog 单一事实源。
  // inferLoaderInfo 内部调 detectLoaderFromId（字符串 indexOf），传 'fabric' /
  // 'Forge' / 'neoforge' 等 loader 名字都能正确识别；识不出时 fallback 到 vanilla。
  //
  // 未识别时不走 vanilla 的 accentColor/accentBg（那会给不明 loader 染上草方块绿），
  // 仍保留原有的 theme.bgInput / theme.textSecondary 作为中性 fallback。

  private loaderIconName(loader: string): AppIconName {
    let key = inferLoaderInfo(loader).key
    return key === 'vanilla' ? AppIconName.Loader : inferLoaderInfo(loader).iconName
  }

  private loaderBg(loader: string): ResourceColor {
    let info = inferLoaderInfo(loader)
    return info.key === 'vanilla' ? this.theme.bgInput : info.accentBg
  }

  private loaderTextColor(loader: string): ResourceColor {
    let info = inferLoaderInfo(loader)
    return info.key === 'vanilla' ? this.theme.textSecondary : info.accentColor
  }

  private capitalize(s: string): string {
    if (!s || s.length === 0) return s
    return s.charAt(0).toUpperCase() + s.substring(1).toLowerCase()
  }

  /** scanInfo 行的图标（按文案前缀启发式选） */
  private scanInfoIcon(): AppIconName {
    let s = this.scanInfo
    if (s.indexOf('正在') >= 0) return AppIconName.Hourglass
    if (s.indexOf('✓') >= 0 || s.indexOf('已装') >= 0) return AppIconName.CheckCircle
    if (s.indexOf('升级') >= 0 || s.indexOf('↑') >= 0) return AppIconName.ArrowUpRight
    if (s.indexOf('失败') >= 0 || s.indexOf('错') >= 0) return AppIconName.Warning
    return AppIconName.Info
  }

  /** scanInfo 行的颜色 */
  private scanInfoColor(): ResourceColor {
    let s = this.scanInfo
    if (s.indexOf('✓') >= 0 || s.indexOf('已装') >= 0) return this.theme.success
    if (s.indexOf('升级') >= 0 || s.indexOf('↑') >= 0) return this.theme.primary
    if (s.indexOf('失败') >= 0 || s.indexOf('错') >= 0) return this.theme.error
    return this.theme.textSecondary
  }

  /** 是否还有可被"全选"切换的依赖（已装项不算，免得"全选"按钮误导） */
  private hasAnyTogglableDep(): boolean {
    for (let d of this.dependencies) {
      if (!d.alreadyInstalled) return true
    }
    return false
  }

  // ============================================================
  //  Step 2：版本 picker
  // ============================================================

  /** 切到 picker step（同 sheet 横向 push 转场） */
  // 2026-05-23 API NEXT 迁移：全局 animateTo 弃用，改走
  // this.getUIContext().animateTo(...)。详见
  // docs/guides/api-migration-2026-05.md。
  private gotoPicker(): void {
    if (this.allVersions.length === 0) return  // 没数据时不切
    this.currentStep = 'picker'
    this.getUIContext().animateTo({
      duration: ModDetailSheet.ANIM_DURATION_MS,
      curve: Curve.FastOutSlowIn,
    }, () => {
      this.slidePct = 1
    })
  }

  /** 切回 main step */
  private backToMain(): void {
    this.currentStep = 'main'
    this.getUIContext().animateTo({
      duration: ModDetailSheet.ANIM_DURATION_MS,
      curve: Curve.FastOutSlowIn,
    }, () => {
      this.slidePct = 0
    })
  }

  /** picker（游戏版本列表）→ 第三级：该游戏版本对应的所有模组版本（文件）。 */
  private gotoFiles(mc: string): void {
    this.selectedMcGroup = mc
    this.currentStep = 'files'
    this.getUIContext().animateTo({
      duration: ModDetailSheet.ANIM_DURATION_MS,
      curve: Curve.FastOutSlowIn,
    }, () => {
      this.slidePct = 2
    })
  }

  /** 第三级 → picker */
  private backToPicker(): void {
    this.currentStep = 'picker'
    this.getUIContext().animateTo({
      duration: ModDetailSheet.ANIM_DURATION_MS,
      curve: Curve.FastOutSlowIn,
    }, () => {
      this.slidePct = 1
    })
  }

  @Builder
  PickerStep() {
    Column() {
      // ----- 头部：← 返回 + 标题 + 版本计数 -----
      Row({ space: 8 }) {
        Row({ space: 4 }) {
          AppIcon({
            name: AppIconName.ChevronLeft,
            iconSize: 16,
            color: this.theme.primary,
            weight: FontWeight.Bold,
          })
          Text('返回')
            .fontSize(13).fontWeight(600).fontColor(this.theme.primary)
        }
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor(this.theme.bgCard)
        .borderRadius(12)
        .alignItems(VerticalAlign.Center)
        .onClick(() => { this.backToMain() })

        Column({ space: 2 }) {
          Text('选择版本')
            .fontSize(18).fontWeight(700).fontColor(this.theme.textPrimary)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.pickerHeaderSub())
            .fontSize(11).fontWeight(500).fontColor(this.theme.textSecondary)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 6, bottom: 8 })
      .alignItems(VerticalAlign.Center)

      // ----- 游戏版本列表（点击进入第三级：该游戏版本的全部模组版本）-----
      if (this.allVersions.length === 0) {
        Column() {
          Text('该项目暂无可选版本')
            .fontSize(13).fontColor(this.theme.textHint)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: 8 }) {
            ForEach(this.mcGroups(), (g: McVersionGroup) => {
              this.GroupRow(g.mc, g.versions.length)
            }, (g: McVersionGroup) => g.mc)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 16 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%').height('100%')
  }

  /** 游戏版本行：点击进入该版本对应的全部模组版本（第三级）。含当前选中版本的组高亮。 */
  @Builder
  GroupRow(mc: string, count: number) {
    Row({ space: 10 }) {
      Column({ space: 3 }) {
        Text(mc.length === 0 ? '其他版本' : ('Minecraft ' + mc))
          .fontSize(15).fontWeight(600).fontColor(this.theme.textPrimary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 6 }) {
          Text(count + ' 个版本')
            .fontSize(11).fontWeight(500).fontColor(this.theme.textSecondary)
          if (this.groupContainsCurrent(mc)) {
            Text('当前选择')
              .fontSize(9).fontWeight(700).fontColor(this.theme.primary)
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .borderRadius(5).backgroundColor(this.theme.primaryLight)
          }
        }
        .alignItems(VerticalAlign.Center)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      AppIcon({ name: AppIconName.ChevronRight, iconSize: 16, color: this.theme.textSecondary })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.theme.bgCard)
    .borderRadius(12)
    .alignItems(VerticalAlign.Center)
    .border(this.groupContainsCurrent(mc)
      ? { width: 2, color: this.theme.primary, style: BorderStyle.Solid }
      : { width: 0 })
    .onClick(() => { this.gotoFiles(mc) })
  }

  /**
   * 模组版本（文件）行（PCL2 风格）。修复：长文件名/版本号整行换行**不省略**（wordBreak BREAK_ALL），
   * loader / 发布通道 / 已装等标签放到**独立的可换行行**，绝不会被长标题挤出屏幕外。
   * 点击整行 → 选中该版本（父组件重算依赖）并回到主页，由底部 CTA 安装。
   */
  @Builder
  PickerRow(v: RemoteVersion) {
    Column({ space: 6 }) {
      // 标题：版本号/文件名（完整显示，过长则换行，不靠省略号截断信息）
      Text(this.versionDisplayName(v))
        .fontSize(14)
        .fontWeight(this.isCurrentVersion(v) ? 700 : 600)
        .fontColor(this.theme.textPrimary)
        .width('100%')
        .wordBreak(WordBreak.BREAK_ALL)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      // 标签行：loader(s) + channel + 已装/当前（Flex 自动换行）
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(v.loaders, (l: string) => {
          Text(l)
            .fontSize(9).fontWeight(700).fontColor(this.loaderTextColor(l))
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(5)
            .backgroundColor(this.loaderBg(l))
            .margin({ right: 6, bottom: 4 })
        }, (l: string) => l)

        Text(this.channelLabel_(v.versionType))
          .fontSize(9).fontWeight(700)
          .fontColor(channelTone(v.versionType, this.theme).color)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(5)
          .backgroundColor(channelTone(v.versionType, this.theme).bg)
          .margin({ right: 6, bottom: 4 })

        if (this.isVersionInstalled(v)) {
          Text('已装')
            .fontSize(9).fontWeight(700).fontColor(this.theme.textSecondary)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(5).backgroundColor(this.theme.bgInput)
            .margin({ right: 6, bottom: 4 })
        }
        if (this.isCurrentVersion(v)) {
          Text('当前选择')
            .fontSize(9).fontWeight(700).fontColor(this.theme.primary)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(5).backgroundColor(this.theme.primaryLight)
            .margin({ right: 6, bottom: 4 })
        }
      }
      .width('100%')

      // 副信息：MC 版本 · 日期 · 大小（完整，可换行）
      Text(this.pickerRowSubInfo(v))
        .fontSize(11).fontWeight(500).fontColor(this.theme.textSecondary)
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding(12)
    .backgroundColor(this.theme.bgCard)
    .borderRadius(12)
    .alignItems(HorizontalAlign.Start)
    .border(this.isCurrentVersion(v)
      ? { width: 2, color: this.theme.primary, style: BorderStyle.Solid }
      : { width: 0 })
    .onClick(() => {
      // 选中该版本（父组件重算 primaryFile + 依赖）后回主页，由底部 CTA 安装
      if (!this.isCurrentVersion(v)) {
        this.onSelectVersion(v)
      }
      this.backToMain()
    })
  }

  // ============================================================
  //  Step 3：某游戏版本下的全部模组版本（文件）列表
  // ============================================================

  @Builder
  GroupFilesStep() {
    Column() {
      // ----- 头部：← 返回(picker) + 游戏版本 + 计数 -----
      Row({ space: 8 }) {
        Row({ space: 4 }) {
          AppIcon({
            name: AppIconName.ChevronLeft,
            iconSize: 16,
            color: this.theme.primary,
            weight: FontWeight.Bold,
          })
          Text('返回')
            .fontSize(13).fontWeight(600).fontColor(this.theme.primary)
        }
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor(this.theme.bgCard)
        .borderRadius(12)
        .alignItems(VerticalAlign.Center)
        .onClick(() => { this.backToPicker() })

        Column({ space: 2 }) {
          Text(this.selectedMcGroup.length === 0 ? '其他版本' : ('Minecraft ' + this.selectedMcGroup))
            .fontSize(18).fontWeight(700).fontColor(this.theme.textPrimary)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.selectedGroupVersions().length + ' 个模组版本')
            .fontSize(11).fontWeight(500).fontColor(this.theme.textSecondary)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 6, bottom: 8 })
      .alignItems(VerticalAlign.Center)

      // ----- 该游戏版本对应的模组版本（文件）列表 -----
      Scroll() {
        Column({ space: 8 }) {
          ForEach(this.selectedGroupVersions(), (v: RemoteVersion) => {
            this.PickerRow(v)
          }, (v: RemoteVersion) => v.source + ':' + v.id)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 16 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%').height('100%')
  }

  // ============================================================
  //  picker / detail helpers
  // ============================================================

  private pickerHeaderSub(): string {
    let bits: string[] = []
    if (this.project.title.length > 0) bits.push(this.project.title)
    bits.push('共 ' + this.allVersions.length + ' 个版本')
    return bits.join(' · ')
  }

  private pickerRowSubInfo(v: RemoteVersion): string {
    let bits: string[] = []
    if (v.gameVersions.length > 0) bits.push('MC ' + v.gameVersions[0])
    if (v.datePublished.length > 0) bits.push(v.datePublished.substring(0, 10))
    let f = pickPrimaryFile(v.files)
    if (f !== null && f.size > 0) bits.push(formatBytes(f.size))
    return bits.join(' · ')
  }

  /** 行标题：优先版本号；为空时退回主文件名。 */
  private versionDisplayName(v: RemoteVersion): string {
    if (v.versionNumber.length > 0) return v.versionNumber
    return this.versionFileName(v)
  }

  /** 主文件名；取不到时退回版本号。 */
  private versionFileName(v: RemoteVersion): string {
    let f = pickPrimaryFile(v.files)
    if (f !== null && f.filename.length > 0) return f.filename
    return v.versionNumber
  }

  /** 第三级：当前展开的游戏版本对应的全部模组版本（文件），按新旧统一判定降序（最新在前）。 */
  private selectedGroupVersions(): RemoteVersion[] {
    let out: RemoteVersion[] = []
    for (let v of this.allVersions) {
      if (this.selectedMcGroup.length === 0) {
        if (v.gameVersions.length === 0) out.push(v)
      } else if (this.versionSupportsMc(v, this.selectedMcGroup)) {
        out.push(v)
      }
    }
    out.sort((a: RemoteVersion, b: RemoteVersion): number => -compareModVersionFreshness(a, b))
    return out
  }

  /** 某游戏版本分组是否包含当前选中的模组版本（用于第二级高亮"当前选择所在的游戏版本"）。 */
  private groupContainsCurrent(mc: string): boolean {
    if (this.selectedVersion === null) return false
    if (mc.length === 0) return this.selectedVersion.gameVersions.length === 0
    return this.versionSupportsMc(this.selectedVersion, mc)
  }

  private versionSupportsMc(v: RemoteVersion, mc: string): boolean {
    for (let gv of v.gameVersions) {
      if (gv === mc) return true
    }
    return false
  }

  /**
   * 第二级"游戏版本列表"：把所有模组版本按其支持的每个 MC 版本归类（PCL2 风格——
   * 一个同时支持 1.21 / 1.21.1 的文件会同时计入两个游戏版本组）。按首次出现顺序排列。
   */
  private mcGroups(): McVersionGroup[] {
    let groups: McVersionGroup[] = []
    let index: Map<string, McVersionGroup> = new Map<string, McVersionGroup>()
    for (let v of this.allVersions) {
      let gvs: string[] = v.gameVersions.length > 0 ? v.gameVersions : ['']
      for (let gv of gvs) {
        let g = index.get(gv)
        if (g === undefined) {
          let ng: McVersionGroup = { mc: gv, versions: [] }
          index.set(gv, ng)
          groups.push(ng)
          g = ng
        }
        g.versions.push(v)
      }
    }
    // 按游戏版本降序排列（PCL2 同款语义：复用 commons.compareMcVersion，跨纪元 26.x > 1.x、
    // 同纪元逐段数字比较）。无法识别的版本（快照/空）compareMcVersion 返回 0，保持相对顺序；
    // 空键（"其他"）固定排到最后。
    groups.sort((a: McVersionGroup, b: McVersionGroup): number => {
      if (a.mc.length === 0 && b.mc.length === 0) return 0
      if (a.mc.length === 0) return 1
      if (b.mc.length === 0) return -1
      return -compareMcVersion(a.mc, b.mc)
    })
    return groups
  }

  private isCurrentVersion(v: RemoteVersion): boolean {
    if (this.selectedVersion === null) return false
    return this.selectedVersion.id === v.id && this.selectedVersion.source === v.source
  }

  private isVersionInstalled(v: RemoteVersion): boolean {
    for (let id of this.installedVersionIds) {
      if (id === v.id) return true
    }
    return false
  }

  /** 构造"网页"按钮的下拉菜单：项目自身源页面 + 另一源页面 + MC 百科（按可用性增减）。 */
  private buildWebMenu(): MenuElement[] {
    let items: MenuElement[] = []
    let p = this.project
    if (p === undefined) {
      items.push({ value: '无可用网址', enabled: false, action: () => {} })
      return items
    }
    let ownUrl = (p.websiteUrl !== undefined && p.websiteUrl.length > 0) ? p.websiteUrl : ''

    if (p.source === ModSource.CURSEFORGE) {
      if (ownUrl.length === 0) ownUrl = curseforgeWebUrl(p.kind, p.slug)
      if (ownUrl.length > 0) {
        let u = ownUrl
        items.push({ value: '打开 CurseForge 页面', action: () => { this.onOpenUrl(u) } })
      }
      // 另一源（Modrinth）：真实网址由父组件按工程数据解析（不按分类猜，避免 404）
      if (p.altSource === ModSource.MODRINTH) {
        items.push({ value: '打开 Modrinth 页面', action: () => { this.onOpenCrossSourceWeb(ModSource.MODRINTH) } })
      }
    } else {
      if (ownUrl.length === 0) ownUrl = modrinthWebUrl(p.kind, p.slug)
      if (ownUrl.length > 0) {
        let u = ownUrl
        items.push({ value: '打开 Modrinth 页面', action: () => { this.onOpenUrl(u) } })
      }
      // 另一源（CurseForge）：真实网址由父组件按工程数据解析（CF 分类常与 MR 不同，猜会 404）
      if (p.altSource === ModSource.CURSEFORGE) {
        items.push({ value: '打开 CurseForge 页面', action: () => { this.onOpenCrossSourceWeb(ModSource.CURSEFORGE) } })
      }
    }

    if (p.wikiId !== undefined && p.wikiId > 0) {
      let u = mcmodClassUrl(p.wikiId)
      if (u.length > 0) items.push({ value: '打开 MC 百科 (mcmod)', action: () => { this.onOpenUrl(u) } })
    }

    if (items.length === 0) {
      items.push({ value: '无可用网址', enabled: false, action: () => {} })
    }
    return items
  }

  private depCheckboxBg(d: ModDetailDepRow): ResourceColor {
    if (d.alreadyInstalled) return this.theme.disabled
    return d.selected ? this.theme.primary : this.theme.bgCard
  }
}

