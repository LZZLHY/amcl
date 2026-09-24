import { DiagnosticPolicy } from 'commons';
/**
 * InstalledResourcesSheet.ets — 当前版本已装"模组 / 资源包 / 光影 / 数据包"管理 Sheet
 *  v2 · 2026-05-17（R-5 收敛：取代 InstalledModsSheet，统一处理四种资源类型）
 *
 * 入口：
 *   - HomeTab Quick Stats "已装模组"卡 → kind=MOD
 *   - VersionManagerSheet detail step 资源格 → kind=各自对应
 *
 * 资源类型差异（参考 ModInstaller / resourceKindToInstallDir 已有约定）：
 *
 *   | kind          | 安装目录              | 文件后缀                | 启用/禁用 | 备注          |
 *   |---------------|----------------------|-------------------------|----------|---------------|
 *   | MOD           | mods/                | .jar / .jar.disabled    | 支持      | 默认场景      |
 *   | RESOURCE_PACK | resourcepacks/       | .zip / .zip.disabled    | 支持      | 通过改名禁用  |
 *   | SHADER        | shaderpacks/         | .zip / .zip.disabled    | 支持      | Iris/OF 通用  |
 *   | DATAPACK      | datapacks/           | .zip                    | 不支持    | MC 不识别后缀 |
 *
 * Datapack 的特殊性：
 *   - MC 不通过文件后缀决定启用 / 禁用，而是通过 "datapacks_loaded" 写在
 *     world/level.dat 的 NBT 里。我们这里的 datapacks/ 目录是版本根目录的
 *     全局共享数据包（MC 1.21+ 加的"全局 datapack"功能，HMCL/PCL2 也支持），
 *     启用状态在 NBT 而不在文件名 → 这里不显示 Toggle，仅"删除 / 大小"。
 *
 * 所有四种资源都共享同一个 sheet 实现（仅 kind / dir 不同）。
 * 行视觉用 ModIcon（kind 决定图标样式 + 启用/禁用决定亮度）。
 *
 * 不做：
 *   - jar 内 manifest 解析（mod 名 / 作者）
 *   - 资源包 / 光影内 pack.mcmeta 解析（仅显示 .zip 文件名）
 *   - 检查更新（Modrinth /version_files/update）
 */

import { promptAction } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GameArchiveIO } from './GameArchiveIO';
import { ThemeColors } from 'commons';
import { AppIconName } from 'commons';
import { AppIcon } from './AppIcon';
import { RemoteImage } from './RemoteImage';
import {
  ModInstaller,
  isDisabledFilename,
  enableFilename,
} from 'mods';
import { DownloadManager } from 'feature_core';
import { formatBytes } from 'commons';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_DOWNLOAD, LOG_DOMAIN_UI } from 'commons';
import { ResourceKind } from 'mods';
import { kindIcon } from '../components/ResourceIcons';
import { LocalModScanner } from 'mods';
import { ModrinthRepository } from 'mods';
import { CurseForgeRepository } from 'mods';
import { ModIntegrity } from 'mods';
import { ModSource } from 'mods';
import { getMetadataCacheStore } from 'feature_core';
import { ModrinthSourceMode } from 'mods';
import { pickPrimaryFile, resolveInstalledMcVersion } from 'mods';
import { pickLatestModVersion } from 'mods';
import { RemoteVersion } from 'mods';
import { inferLoaderKey, resolveInstalledLoaderKey } from '../components/LoaderCatalog';
import { ModUpdateCoordinator } from './ModUpdateCoordinator';
import { ModSourceRouter, pickModUpdate } from 'mods';
import { PreferenceManager } from 'feature_system';

const TAG = 'InstalledResourcesSheet';

// ============================================================
//  纯函数：kind 元数据（标题、目录名、扩展名、是否支持启用/禁用）
//  与 resourceKindToInstallDir 的逻辑一致，但这里只关心 sheet UI 自身需要的字段。
// ============================================================

interface KindMeta {
  /** Sheet 标题与计数文案前缀（"已装模组" / "已装资源包" 等） */
  title: string;
  /** 单数名（toast / 空态文案用："模组" / "光影"） */
  unit: string;
  /** 子目录名（拼接到 mcDir/versions/<id>/<sub>） */
  subdir: string;
  /** 启用文件扩展（用于"是否启用"判断 + 列表过滤） */
  primaryExt: string;
  /** 禁用文件扩展（无则空串，表示该类型不支持启用/禁用，例如 datapack） */
  disabledExt: string;
  /** 数据包等不支持 toggle 的资源 */
  togglable: boolean;
}

function metaOf(kind: ResourceKind): KindMeta {
  switch (kind) {
    case ResourceKind.MOD:
      return {
        title: '已装模组',
        unit: '模组',
        subdir: 'mods',
        primaryExt: '.jar',
        disabledExt: '.jar.disabled',
        togglable: true,
      };
    case ResourceKind.RESOURCE_PACK:
      return {
        title: '已装资源包',
        unit: '资源包',
        subdir: 'resourcepacks',
        primaryExt: '.zip',
        disabledExt: '.zip.disabled',
        togglable: true,
      };
    case ResourceKind.SHADER:
      return {
        title: '已装光影',
        unit: '光影',
        subdir: 'shaderpacks',
        primaryExt: '.zip',
        disabledExt: '.zip.disabled',
        togglable: true,
      };
    case ResourceKind.DATAPACK:
      return {
        title: '已装数据包',
        unit: '数据包',
        subdir: 'datapacks',
        primaryExt: '.zip',
        disabledExt: '',
        togglable: false,
      };
    default:
      // MODPACK 不在 sheet 范围内（整合包不会装到当前版本目录里）；fallback 到 mod 行为
      return {
        title: '已装资源',
        unit: '资源',
        subdir: 'mods',
        primaryExt: '.jar',
        disabledExt: '.jar.disabled',
        togglable: true,
      };
  }
}

// ============================================================
//  Row 数据
// ============================================================

/**
 * 取版本列表里「最新」的一条。统一走 mods.pickLatestModVersion（版本号为主键、日期为次），
 * 与下载页 pickBestVersion 同一判定，杜绝"下载页/管理页谁是最新"分叉。空表 → null。
 */
function pickLatestVersion(versions: RemoteVersion[]): RemoteVersion | null {
  return pickLatestModVersion(versions);
}

/** 单个 mod 的源关联信息（更新检查 / 修复复用）。 */
interface ModUpdateMeta {
  /** ModSource 值（'modrinth' | 'curseforge'）：决定用哪个仓储查版本。 */
  source: string;
  projectId: string;
  installedVersionId: string;
}

interface ResourceRow {
  filePath: string;
  filename: string;
  /** 不带 .disabled / 扩展名后缀的展示名 */
  displayName: string;
  enabled: boolean;
  sizeBytes: number;
  /**
   * 远程项目图标 URL（来自 Modrinth 反查 sha1 → getProject）。
   * 空字符串 = 还没反查到 / 反查失败 → 由 RemoteImage 回退到 AppIcon 占位。
   * 异步填充：refresh() 完成后立刻挂出 rows（icon 全空），后台并发 sha1 lookup 命中后
   * 通过 setRowIcon() 局部更新单行，避免一次大重建闪屏。
   */
  iconUrl: string;
  /**
   * 更新检查状态（仅 MOD 类有意义；其它 kind 恒为 'none'）：
   *   - 'none'      还没查 / 没反查到 Modrinth 项目 / 非 mod
   *   - 'checking'  正在查最新版
   *   - 'latest'    已是最新（与当前 profile 的 loader+gameVersion 匹配的最新版）
   *   - 'outdated'  有新版可更新（latestVersionNumber 为目标版本号）
   *   - 'updating'  正在下载替换
   */
  updateState: string;
  /** outdated 时展示的目标版本号（如 "0.5.13"） */
  latestVersionNumber: string;
  /** updating 时的下载进度百分比（0~100） */
  updatingPct: number;
  /**
   * 完整性/来源状态（ModIntegrity 值；'none'=还没算/非 mod）：
   *   verified 完好 · linked 已链接 · corrupt 已损坏(可修复) · unknown 未知来源(不可查更新,非损坏) · recheck 待校验
   */
  integrity: string;
}

@Component
export struct InstalledResourcesSheet {
  @Prop theme: ThemeColors = {} as ThemeColors;
  @Prop bottomSafeHeight: number = 0;
  /** .minecraft 根（不带尾部 /） */
  @Prop mcDir: string = '';
  /** 目标版本 id；为空时显示空态 + 引导提示 */
  @Prop @Watch('onScopeChanged') versionId: string = '';
  @Prop versionIsolation: boolean = true;
  /** 资源类型；改 kind 会触发重扫（standalone 走 aboutToAppear，embedded 走 @Watch） */
  @Prop @Watch('onScopeChanged') kind: ResourceKind = ResourceKind.MOD;
  /**
   * 嵌入模式：true 时本组件被 VersionManagerSheet 作为"第三步"内嵌（同 sheet 横滑）。
   *   - 顶部用"← 版本详情"返回按钮取代独立 sheet 的拖拽指示条；
   *   - 不再自管 bindSheet 高度/背景（由宿主 sheet 决定）。
   * 默认 false：保持作为独立 bottom sheet 使用的原有行为。
   */
  @Prop embedded: boolean = false;
  /**
   * 当前是否"可见/激活"。嵌入模式下本组件始终挂载（为了横滑动画不被卸载），
   * 但只有真正滑到资源步（active=true）才扫描磁盘 + 拉图标，避免每次进版本详情
   * 都白扫一遍并触发一轮 Modrinth 图标网络请求。standalone 模式恒为 true。
   */
  @Prop @Watch('onScopeChanged') active: boolean = true;

  @State private rows: ResourceRow[] = [];

  @State private loaded: boolean = false;
  /** 二次确认中的删除目标 filename；空 = 无对话框 */
  @State private pendingDelete: string = '';
  /**
   * 每次 refresh() 自增的"扫描代号"。后台 sha1 lookup 完成时如果 epoch 与启动时不同，
   * 说明用户已经切版本/切 kind/再次刷新过，旧任务结果应当丢弃，避免：
   *   - 给已经被替换的 rows[] 写脏数据（filePath 已经不在了）
   *   - 重复 setRowIcon 触发不必要的列表重建
   */
  private scanEpoch_: number = 0;
  /**
   * PreferenceManager 实例，sheet 内部自己持有：用同一份 `amcl_settings` namespace
   * 读写"已装资源排序"，避免给所有调用方加 prop 透传。
   * aboutToAppear 里 lazy 创建（getContext(this) 在子组件构造期不一定可用）。
   */
  private prefs_: PreferenceManager | null = null;

  /**
   * 更新检查命中后，把"最新可用版本"按 filePath 暂存，供「一键更新」直接取用，
   * 避免点更新时再发一次网络请求。仅 MOD 类写入。
   */
  private pendingUpdates_: Map<string, RemoteVersion> = new Map<string, RemoteVersion>();
  /** 每个 mod 的 Modrinth 关联（projectId + 已装版本 id），供单条「检查更新」复用。 */
  private modMeta_: Map<string, ModUpdateMeta> = new Map<string, ModUpdateMeta>();
  /**
   * 会话级「忽略此更新」集合，key = `filePath|latestVersionId`。
   * 命中则把该行显示为 'ignored'（不提示可更新）；出现更"新"的版本（id 变了）会重新提示。
   */
  private ignoredKeys_: Set<string> = new Set<string>();
  /** 当前展开的行（filePath）；'' = 全部折叠。手风琴式单行展开。 */
  @State private expandedPath: string = '';
  /** 「校验完整性」进行中（全量哈希），禁用重复点击 + 顶部提示。 */
  @State private verifying: boolean = false;
  @State private importing: boolean = false;

  onClose: () => void = () => {};
  /** 嵌入模式：返回上一步（版本详情）。standalone 模式下无意义。 */
  onBack: () => void = () => {};
  /**
   * 引导用户跳转到下载 Tab 安装新资源（资源包 / 光影 / 模组都走 ModBrowsePage）。
   * 携带当前资源类别 `kind`，让父组件把下载页二级 Tab 定位到对应分类（模组/资源包/光影）。
   */
  onJumpToBrowse: (kind: ResourceKind) => void = () => {};
  /** 任意启用/禁用/删除后回调外层刷新 quick stats 等 */
  onChanged: () => void = () => {};

  /** 协调器监听：进度变化 / 任务完成时驱动行内同步刷新。 */
  private coordListener: () => void = () => { this.onCoordChange() };

  aboutToAppear() {
    ModUpdateCoordinator.instance().addListener(this.coordListener)
    if (this.active) this.refresh();
  }

  aboutToDisappear() {
    ModUpdateCoordinator.instance().removeListener(this.coordListener)
  }

  /**
   * 协调器状态变化回调：
   *   - 仍在更新的行 → 同步进度百分比；
   *   - 之前是 'updating' 但协调器里已无该任务（完成/失败）→ 重扫，让新文件出现/旧文件消失。
   */
  private onCoordChange(): void {
    let coord = ModUpdateCoordinator.instance()
    let needRefresh = false
    for (let r of this.rows) {
      if (coord.isUpdating(r.filePath)) {
        this.setRowUpdatingPct(r.filePath, coord.pctOf(r.filePath))
      } else if (r.updateState === 'updating') {
        needRefresh = true
      }
    }
    if (needRefresh) this.refresh()
  }

  /**
   * kind / versionId / active 任一变化时：仅在 active 时重扫。
   * 嵌入模式下父组件改 @Prop 不会重建本组件、也不会再触发 aboutToAppear，
   * 因此靠 @Watch 驱动重扫；active 门控避免在非资源步做无谓的磁盘/网络开销。
   */
  onScopeChanged(): void {
    if (this.active) this.refresh();
  }

  build() {
    Column() {
      if (this.embedded) {
        // 嵌入模式：← 版本详情 返回按钮（与版本详情步的"← 版本管理"同款）
        Row() {
          Row({ space: 4 }) {
            AppIcon({ name: AppIconName.ChevronLeft, iconSize: 14, color: this.theme.textPrimary })
            Text('版本详情').fontSize(12).fontWeight(600).fontColor(this.theme.textSecondary)
          }
          .height(32)
          .padding({ left: 10, right: 12 })
          .borderRadius(16)
          .backgroundColor(this.theme.bgInput)
          .alignItems(VerticalAlign.Center)
          .onClick(() => { this.onBack() })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 4 })
        .justifyContent(FlexAlign.Start)
      } else {
        // Drag pill（独立 sheet 模式）
        Row() {
          Column().width(36).height(4).backgroundColor(this.theme.divider).borderRadius(2)
        }
        .width('100%').justifyContent(FlexAlign.Center).padding({ top: 10, bottom: 6 })
      }

      this.Header()

      if (!this.loaded) {
        this.LoadingState()
      } else if (this.rows.length === 0) {
        this.EmptyState()
      } else {
        this.ListView()
      }

      if (this.pendingDelete.length > 0) {
        this.DeleteConfirmOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.bgPrimary)
  }

  // ============================================================
  //  Builders
  // ============================================================

  @Builder
  Header() {
    Column({ space: 6 }) {
      Row() {
        Column({ space: 2 }) {
          Text(metaOf(this.kind).title)
            .fontSize(22)
            .fontWeight(700)
            .fontColor(this.theme.textPrimary)
          Text(this.headerSubtitle())
            .fontSize(11)
            .fontColor(this.theme.textHint)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Row({ space: 8 }) {
          Row({ space: 5 }) {
            AppIcon({ name: AppIconName.Refresh, iconSize: 13, color: this.theme.textSecondary })
            Text('刷新')
              .fontSize(12).fontWeight(600).fontColor(this.theme.textSecondary)
          }
          .height(32)
          .padding({ left: 12, right: 12 })
          .borderRadius(16)
          .backgroundColor(this.theme.bgInput)
          .alignItems(VerticalAlign.Center)
          .onClick(() => { this.refresh() })

          if (this.kind === ResourceKind.MOD) {
            Row({ space: 5 }) {
              if (this.verifying) {
                LoadingProgress().width(13).height(13).color(this.theme.textSecondary)
              } else {
                AppIcon({ name: AppIconName.Check, iconSize: 13, color: this.theme.textSecondary })
              }
              Text(this.verifying ? '校验中' : '校验')
                .fontSize(12).fontWeight(600).fontColor(this.theme.textSecondary)
            }
            .height(32)
            .padding({ left: 12, right: 12 })
            .borderRadius(16)
            .backgroundColor(this.theme.bgInput)
            .alignItems(VerticalAlign.Center)
            .opacity(this.verifying ? 0.5 : 1)
            .onClick(() => { this.doFullVerify() })
          }

          Row({ space: 5 }) {
            AppIcon({ name: AppIconName.Import, iconSize: 13, color: this.theme.textSecondary })
            Text('导入')
              .fontSize(12).fontWeight(600).fontColor(this.theme.textSecondary)
          }
          .height(32)
          .padding({ left: 12, right: 12 })
          .borderRadius(16)
          .backgroundColor(this.theme.bgInput)
          .alignItems(VerticalAlign.Center)
          .onClick(() => { this.doImport() })
          .enabled(!this.importing)

          Row({ space: 5 }) {
            AppIcon({ name: AppIconName.Plus, iconSize: 13, color: this.theme.textOnPrimary, weight: FontWeight.Bold })
            Text('安装')
              .fontSize(12).fontWeight(600).fontColor(this.theme.textOnPrimary)
          }
          .height(32)
          .padding({ left: 12, right: 12 })
          .borderRadius(16)
          .backgroundColor(this.theme.primary)
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.onClose()
            this.onJumpToBrowse(this.kind)
          })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 6, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  ListView() {
    List({ space: 10 }) {
      // key 故意 = filePath + iconUrl：iconUrl 异步从空变成真 URL 时，key 跟着变，
      // ArkUI ForEach 把这一行的 ListItem 强制 rebuild，新的 row.iconUrl 才会被
      // RemoteImage 的 @Prop 拿到。如果只用 filePath 当 key，ArkUI 认为是"同一项"
      // 不重建 → row.iconUrl 永远停在初始空字符串，图标永远是占位。
      // 启用态切换不会改 filePath（只改 enabled），但因为 setRowIcon / handleToggle
      // 都走 `this.rows = next` 整体替换，ArkUI 至少会重跑 ForEach 主体；带 iconUrl
      // 进 key 同时也兜住了"先反查到图标后用户再禁用 / 启用"的边界场景。
      ForEach(this.rows, (row: ResourceRow) => {
        ListItem() {
          this.RowItem(row)
        }
      }, (row: ResourceRow) => row.filePath + '|' + row.iconUrl + '|' + (row.enabled ? '1' : '0') + '|' + row.updateState + '|' + row.latestVersionNumber + '|' + row.updatingPct)

      ListItem() {
        Text(this.footerHint())
          .fontSize(11)
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
  }

  @Builder
  RowItem(row: ResourceRow) {
    Column({ space: 0 }) {
      // ===== 主行（折叠态：保持原始紧凑样式）=====
      Row({ space: 10 }) {
        // 左：资源图标
        RemoteImage({
          url: row.iconUrl,
          diameter: 40,
          cornerRadius: 10,
          fallbackIcon: kindIcon(this.kind),
          fallbackBg: row.enabled ? this.theme.primaryLight : this.theme.bgInput,
          fallbackColor: row.enabled ? this.theme.primary : this.theme.textHint,
          fallbackIconSize: 20,
        })

        // 中：名字 + 状态/大小
        Column({ space: 4 }) {
          Text(row.displayName)
            .fontSize(14)
            .fontWeight(600)
            .fontColor(row.enabled ? this.theme.textPrimary : this.theme.textHint)
            .maxLines(2)
            // 默认 wordBreak 会在第一个连字符处就断行，导致第一行只剩 "fabric-" 一大截空白。
            // BREAK_ALL：按字符填满每一行再换行，长文件名两行都填满后才省略。
            .wordBreak(WordBreak.BREAK_ALL)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 6 }) {
            if (metaOf(this.kind).togglable) {
              Text(row.enabled ? '启用' : '禁用')
                .fontSize(10).fontWeight(700)
                .fontColor(row.enabled ? this.theme.success : this.theme.textHint)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(5)
                .backgroundColor(row.enabled ? this.theme.successBg : this.theme.bgInput)
            }
            Text(formatBytes(row.sizeBytes))
              .fontSize(11).fontWeight(500).fontColor(this.theme.textHint)
            // 完整性徽章（优先于更新状态显示）
            if (row.integrity === ModIntegrity.CORRUPT) {
              Text('已损坏')
                .fontSize(10).fontWeight(700)
                .fontColor(this.theme.error)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(5)
                .backgroundColor(this.theme.errorBg)
            } else if (row.integrity === ModIntegrity.UNKNOWN) {
              Text('未知来源')
                .fontSize(10).fontWeight(500).fontColor(this.theme.textHint)
            }
            // 折叠态更新状态：只显示极简标记（详细动作在展开区）
            if (row.updateState === 'outdated') {
              Text('可更新')
                .fontSize(10).fontWeight(700)
                .fontColor(this.theme.primary)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(5)
                .backgroundColor(this.theme.primaryLight)
            } else if (row.updateState === 'latest') {
              Text('已最新')
                .fontSize(10).fontWeight(600).fontColor(this.theme.textHint)
            } else if (row.updateState === 'updating') {
              Text('更新中 ' + row.updatingPct + '%')
                .fontSize(10).fontWeight(700)
                .fontColor(this.theme.primary)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(5)
                .backgroundColor(this.theme.primaryLight)
            } else if (row.updateState === 'checking') {
              Text('检查更新…')
                .fontSize(10).fontWeight(500).fontColor(this.theme.textHint)
            }
          }
          .alignItems(VerticalAlign.Center)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        // 右：展开箭头（仅有 Modrinth 关联时）+ toggle + 删除
        Row({ space: 8 }) {
          if (this.isExpandable(row)) {
            Row() {
              AppIcon({
                name: this.expandedPath === row.filePath ? AppIconName.ChevronUp : AppIconName.ChevronDown,
                iconSize: 14,
                color: row.updateState === 'outdated' ? this.theme.primary : this.theme.textSecondary,
              })
            }
            .width(32).height(32).borderRadius(10)
            .backgroundColor(row.updateState === 'outdated' ? this.theme.primaryLight : this.theme.bgInput)
            .justifyContent(FlexAlign.Center)
            .onClick(() => { this.toggleExpand(row.filePath) })
          }

          if (metaOf(this.kind).togglable) {
            Toggle({ type: ToggleType.Switch, isOn: row.enabled })
              .selectedColor(this.theme.primary)
              .onChange((isOn: boolean) => { this.handleToggle(row, isOn) })
          }

          Row() {
            AppIcon({ name: AppIconName.Trash, iconSize: 15, color: this.theme.error })
          }
          .width(36).height(36)
          .borderRadius(10)
          .backgroundColor(this.theme.errorBg)
          .justifyContent(FlexAlign.Center)
          .onClick(() => { this.pendingDelete = row.filename })
        }
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // ===== 展开态：更新动作区（拓宽卡片）=====
      if (this.expandedPath === row.filePath && this.isExpandable(row)) {
        Column({ space: 0 }) {
          Row().width('100%').height(1).backgroundColor(this.theme.divider)
            .margin({ top: 10, bottom: 10 })

          if (row.updateState === 'updating') {
            Column({ space: 6 }) {
              Row({ space: 8 }) {
                LoadingProgress().width(16).height(16).color(this.theme.primary)
                Text('正在更新到 ' + row.latestVersionNumber + '  ' + row.updatingPct + '%')
                  .fontSize(12).fontWeight(500).fontColor(this.theme.textSecondary)
                  .layoutWeight(1)
              }
              .width('100%').alignItems(VerticalAlign.Center)
              Progress({ value: row.updatingPct, total: 100, type: ProgressType.Linear })
                .color(this.theme.primary)
                .width('100%')
            }
            .width('100%')
          } else if (row.integrity === ModIntegrity.CORRUPT) {
            Text('文件已损坏（与模组源校验不一致）')
              .fontSize(12).fontWeight(600).fontColor(this.theme.error)
              .width('100%').margin({ bottom: 4 })
            Text('可从原始来源重新下载同一版本进行修复。')
              .fontSize(11).fontColor(this.theme.textHint)
              .width('100%').margin({ bottom: 8 })
            Row({ space: 8 }) {
              Row({ space: 4 }) {
                AppIcon({ name: AppIconName.Download, iconSize: 13, color: this.theme.textOnPrimary })
                Text('重新下载修复').fontSize(12).fontWeight(600).fontColor(this.theme.textOnPrimary)
              }
              .height(32).padding({ left: 12, right: 12 }).borderRadius(16)
              .backgroundColor(this.theme.error).alignItems(VerticalAlign.Center)
              .onClick(() => { this.doRepair(row) })
            }
            .width('100%').alignItems(VerticalAlign.Center)
          } else if (row.updateState === 'outdated') {
            Text('可更新到 ' + row.latestVersionNumber)
              .fontSize(12).fontWeight(600).fontColor(this.theme.textPrimary)
              .width('100%').margin({ bottom: 8 })
            Row({ space: 8 }) {
              // 更新（主操作）
              Row({ space: 4 }) {
                AppIcon({ name: AppIconName.Download, iconSize: 13, color: this.theme.textOnPrimary })
                Text('更新').fontSize(12).fontWeight(600).fontColor(this.theme.textOnPrimary)
              }
              .height(32).padding({ left: 12, right: 12 }).borderRadius(16)
              .backgroundColor(this.theme.primary).alignItems(VerticalAlign.Center)
              .onClick(() => { this.doUpdate(row) })
              // 检查更新
              Row({ space: 4 }) {
                AppIcon({ name: AppIconName.Refresh, iconSize: 13, color: this.theme.textSecondary })
                Text('检查更新').fontSize(12).fontWeight(600).fontColor(this.theme.textSecondary)
              }
              .height(32).padding({ left: 12, right: 12 }).borderRadius(16)
              .backgroundColor(this.theme.bgInput).alignItems(VerticalAlign.Center)
              .onClick(() => { this.recheckUpdate(row) })
              // 忽略
              Row({ space: 4 }) {
                AppIcon({ name: AppIconName.Close, iconSize: 13, color: this.theme.textSecondary })
                Text('忽略').fontSize(12).fontWeight(600).fontColor(this.theme.textSecondary)
              }
              .height(32).padding({ left: 12, right: 12 }).borderRadius(16)
              .backgroundColor(this.theme.bgInput).alignItems(VerticalAlign.Center)
              .onClick(() => { this.ignoreUpdate(row) })
            }
            .width('100%').alignItems(VerticalAlign.Center)
          } else {
            // latest / ignored：已是最新或已忽略 → 仅提供「检查更新」
            Row({ space: 8 }) {
              Text(row.updateState === 'ignored' ? '已忽略此更新' : '已是最新版')
                .fontSize(12).fontWeight(500).fontColor(this.theme.textSecondary)
                .layoutWeight(1)
              Row({ space: 4 }) {
                AppIcon({ name: AppIconName.Refresh, iconSize: 13, color: this.theme.textSecondary })
                Text('检查更新').fontSize(12).fontWeight(600).fontColor(this.theme.textSecondary)
              }
              .height(32).padding({ left: 12, right: 12 }).borderRadius(16)
              .backgroundColor(this.theme.bgInput).alignItems(VerticalAlign.Center)
              .onClick(() => { this.recheckUpdate(row) })
            }
            .width('100%').alignItems(VerticalAlign.Center)
          }
        }
        .width('100%')
        .transition(TransitionEffect.OPACITY.animation({ duration: 220, curve: Curve.FastOutSlowIn }))
      }
    }
    .width('100%')
    .padding({ left: 12, right: 10, top: 10, bottom: 10 })
    .backgroundColor(this.theme.bgCard)
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
    .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
  }

  @Builder
  EmptyState() {
    Column({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width(72).height(72)
          .backgroundColor(this.theme.bgInput)
          .borderRadius(18)
        AppIcon({
          name: kindIcon(this.kind),
          iconSize: 36,
          color: this.theme.textSecondary,
        })
      }
      .width(72).height(72)
      Text(this.emptyTitle())
        .fontSize(16).fontWeight(500).fontColor(this.theme.textPrimary)
      Text(this.emptyHint())
        .fontSize(12).fontColor(this.theme.textHint)
        .textAlign(TextAlign.Center)
      if (this.versionId.length > 0) {
        Row({ space: 5 }) {
          AppIcon({ name: AppIconName.Plus, iconSize: 12, color: this.theme.textOnPrimary, weight: FontWeight.Bold })
          Text('立即安装').fontSize(13).fontWeight(600).fontColor(this.theme.textOnPrimary)
        }
        .height(36)
        .padding({ left: 18, right: 18 })
        .borderRadius(18)
        .backgroundColor(this.theme.primary)
        .alignItems(VerticalAlign.Center)
        .margin({ top: 8 })
        .onClick(() => {
          this.onClose()
          this.onJumpToBrowse(this.kind)
        })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 32, right: 32, bottom: 60 })
  }

  @Builder
  LoadingState() {
    Column({ space: 10 }) {
      LoadingProgress()
        .width(36).height(36)
        .color(this.theme.primary)
      Text('扫描' + metaOf(this.kind).subdir + '/ 中…')
        .fontSize(12).fontColor(this.theme.textHint)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  DeleteConfirmOverlay() {
    Column() {
      Column() {
        Text('删除' + metaOf(this.kind).unit)
          .fontSize(18).fontWeight(600).fontColor(this.theme.textPrimary)
          .margin({ bottom: 12 })
        Text('确定要删除 ' + this.pendingDelete + ' 吗？')
          .fontSize(14).fontColor(this.theme.textSecondary)
          .margin({ bottom: 4 })
        Text('文件将从' + metaOf(this.kind).subdir + '/ 目录中移除，无法恢复。'
          + (metaOf(this.kind).togglable ? '如果只是想暂时停用，请使用启用开关。' : ''))
          .fontSize(12).fontColor(this.theme.textHint)
          .margin({ bottom: 16 })
        Row({ space: 12 }) {
          Button('取消')
            .type(ButtonType.Capsule).height(36).fontSize(14).layoutWeight(1)
            .fontColor(this.theme.textSecondary).backgroundColor(this.theme.bgInput)
            .onClick(() => { this.pendingDelete = '' })
          Button('删除')
            .type(ButtonType.Capsule).height(36).fontSize(14).layoutWeight(1)
            .fontColor(this.theme.textOnPrimary).backgroundColor(this.theme.error)
            .onClick(() => { this.executeDelete() })
        }
        .width('100%')
      }
      .width('90%').padding(20)
      .backgroundColor(this.theme.bgCard).borderRadius(16)
      .shadow({ radius: 16, color: '#40000000', offsetX: 0, offsetY: 4 })
    }
    .width('100%').height('100%')
    .position({ x: 0, y: 0 })
    .backgroundColor('#80000000')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => { this.pendingDelete = '' })
  }

  // ============================================================
  //  数据 / 行为
  // ============================================================

  // ResourceKind → AppIconName 映射已迁出到 components/ResourceIcons.kindIcon（跨组件复用），
  // 这里直接 import 使用。

  private headerSubtitle(): string {
    let m = metaOf(this.kind)
    if (this.versionId.length === 0) return '未选择版本'
    let total = this.rows.length
    if (total === 0) return this.versionId + ' · 暂无' + m.unit
    if (!m.togglable) return this.versionId + ' · ' + total + ' 个'
    let enabled = 0
    for (let r of this.rows) { if (r.enabled) enabled++ }
    return this.versionId + ' · ' + total + ' 个 · ' + enabled + ' 启用'
  }

  private footerHint(): string {
    let m = metaOf(this.kind)
    let total = this.rows.length
    if (!m.togglable) return '共 ' + total + ' 个' + m.unit
    let enabled = 0
    for (let r of this.rows) { if (r.enabled) enabled++ }
    let disabled = Math.max(0, total - enabled)
    if (disabled === 0) return '共 ' + total + ' 个' + m.unit + ' · 全部启用'
    return '共 ' + total + ' 个' + m.unit + ' · ' + enabled + ' 启用 · ' + disabled + ' 禁用'
  }

  private emptyTitle(): string {
    if (this.versionId.length === 0) return '请先选择一个已装版本'
    return '尚未安装任何' + metaOf(this.kind).unit
  }

  private emptyHint(): string {
    if (this.versionId.length === 0) return '从首页或版本管理切换到目标版本后再来管理'
    return '前往「下载」页搜索 Modrinth / CurseForge 获取' + metaOf(this.kind).unit
  }

  private targetDir(): string {
    if (this.mcDir.length === 0) return ''
    let sub = metaOf(this.kind).subdir
    if (!this.versionIsolation) return this.mcDir + '/' + sub
    if (this.versionId.length === 0) return ''
    return this.mcDir + '/versions/' + this.versionId + '/' + sub
  }

  private refresh(): void {
    this.loaded = false
    // 自增 epoch；任何后台 lookup 完成时会校对 epoch，过期则丢弃
    this.scanEpoch_++
    this.pendingUpdates_.clear()
    this.modMeta_.clear()
    this.expandedPath = ''
    let myEpoch = this.scanEpoch_
    let dir = this.targetDir()
    if (dir.length === 0) {
      this.rows = []
      this.loaded = true
      return
    }
    let entries: string[] = []
    try {
      entries = fs.listFileSync(dir)
    } catch (e) {
      this.rows = []
      this.loaded = true
      return
    }
    let m = metaOf(this.kind)
    let result: ResourceRow[] = []
    for (let name of entries) {
      let lower = name.toLowerCase()
      let isPrimary = lower.endsWith(m.primaryExt)
      let isDisabled = m.disabledExt.length > 0 && lower.endsWith(m.disabledExt)
      if (!isPrimary && !isDisabled) continue
      let path = dir + '/' + name
      let size = 0
      try { size = fs.statSync(path).size } catch (e) { /* skip stat fail */ }
      result.push({
        filePath: path,
        filename: name,
        displayName: this.displayNameOf(name, m),
        // 注意：判断"启用"必须先看 disabledExt 后看 primaryExt（disabledExt 更长，
        // 否则 .zip.disabled 会被 .zip 误命中为"启用"）
        enabled: !isDisabled,
        sizeBytes: size,
        // iconUrl 异步填充：先空着，sha1 lookup 命中后通过 setRowIcon() 局部更新
        iconUrl: '',
        updateState: 'none',
        latestVersionNumber: '',
        updatingPct: 0,
        integrity: 'none',
      })
    }
    // ===== 持久化排序：按 PreferenceManager 里存的逻辑名顺序排，启用切换不影响顺序 =====
    this.rows = this.applyPersistedOrder(result, m)
    this.loaded = true
    // 重连协调器：若某行正被全局协调器更新（如退出 sheet 再进来），立刻恢复 'updating' + 进度，
    // 而不是把正在被替换的旧文件当普通行展示。新文件在暂存目录下载，不会出现在 mods/ 列表里。
    this.reconnectUpdatingRows()
    if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG,
      'refresh kind=%{public}s dir=%{public}s found=%{public}d',
      this.kind as string, dir, result.length)

    // ======= 异步 sha1 反查 → 拿真实 iconUrl（仅 MOD 类有意义）=======
    // - MOD 才反查（资源包 / 光影 在 Modrinth 也有 sha1 反查接口，但 UI 不展示作者卡，
    //   省一次 HTTP；以后真有需要再开）
    // - DATAPACK / MODPACK 跳过
    // - 失败 / 反查不命中 → iconUrl 维持空 → RemoteImage 自动回退占位
    if (this.kind === ResourceKind.MOD && result.length > 0) {
      this.fetchIconsAsync(myEpoch).catch((e: Error) => {
        AppLogger.warn(TAG, 'fetchIconsAsync uncaught', e, LOG_DOMAIN_DOWNLOAD)
      })
    }
  }

  /**
   * 异步：sha1 → Modrinth lookup_version_by_sha1 → projectId → getProject → iconUrl
   *
   * 复用 LocalModScanner（它已经做了步 1-2 的并发批处理 + sha1 缓存语义），
   * 这里在它返回后追加一次 getProject 拿 iconUrl，按 row.filePath 局部回写。
   *
   * 失败语义：单个 mod 的 lookup / getProject 失败 → 该行 iconUrl 维持空，不影响其他行。
   * 取消语义：进函数前记下的 epoch 与当前 scanEpoch_ 不等 → 立即返回，丢弃所有结果。
   */
  private async fetchIconsAsync(epoch: number, fullVerify: boolean = false): Promise<void> {
    let dm = DownloadManager.instance()
    if (!dm.isCaBundleInitialized()) {
      // CA bundle 未就绪（极早冷启动）→ 跳过反查；rows 维持占位图标，不报错
      if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'fetchIconsAsync skipped: CA bundle not ready')
      return
    }
    let modrinth = this.makeModrinth(dm)
    let curseforge = this.makeCurseForge(dm)
    // 传入 CF 仓储 → 未收编模组 Modrinth sha1 反查落空时用 CF Murmur2 指纹再查一次。
    let scanner = new LocalModScanner(modrinth, curseforge)
    if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'fetchIconsAsync start: ver=%{public}s full=%{public}s', this.versionId, fullVerify ? 'yes' : 'no')
    let scanResult = await scanner.scan({
      mcDir: this.mcDir,
      versionId: this.versionId,
      versionIsolation: this.versionIsolation,
      kind: ResourceKind.MOD,
      fullVerify: fullVerify,
    })
    if (epoch !== this.scanEpoch_) return  // 用户已经切走，丢弃结果

    // 先把完整性状态写回所有行（含 corrupt / unknown / verified / linked / recheck）
    for (let m of scanResult.mods) {
      this.setRowIntegrity(m.filePath, m.integrity !== undefined ? m.integrity : ModIntegrity.UNKNOWN)
    }

    // 有源链接（managed / linked）的行：拉图标 + 检查更新
    let hits = scanResult.mods.filter(m => m.remoteProjectId !== undefined && m.remoteProjectId.length > 0
      && m.remoteSource !== undefined)
    if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG,
      'fetchIconsAsync scan done: total=%{public}d hits=%{public}d',
      scanResult.mods.length, hits.length)
    let loaderKey = resolveInstalledLoaderKey(this.mcDir, this.versionId)
    let gameVer = resolveInstalledMcVersion(this.mcDir, this.versionId)
    let canCheckUpdate = loaderKey !== 'vanilla' && gameVer.length > 0
    let iconLookups = hits.map(async (m): Promise<void> => {
      let src = m.remoteSource as ModSource
      // 源关联(含损坏行)先记入 modMeta_，供修复 / 检查更新复用
      if (m.remoteVersionId !== undefined && m.remoteVersionId.length > 0) {
        this.modMeta_.set(m.filePath, { source: src, projectId: m.remoteProjectId!, installedVersionId: m.remoteVersionId })
      }
      // 图标（源感知）
      try {
        let iconUrl = await this.projectIconUrl_(src, m.remoteProjectId!, modrinth, curseforge)
        if (epoch !== this.scanEpoch_) return
        if (iconUrl.length > 0) this.setRowIcon(m.filePath, iconUrl)
      } catch (e) {
        if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'getProject failed for %{public}s', m.filename)
      }
      // 损坏的行不做更新检查（先修复）；未知来源的行本就不在 hits 里。
      if (m.integrity === ModIntegrity.CORRUPT) return
      // 更新检查（源感知）
      if (canCheckUpdate && m.remoteVersionId !== undefined && m.remoteVersionId.length > 0) {
        if (ModUpdateCoordinator.instance().isUpdating(m.filePath)) {
          this.setRowUpdate(m.filePath, 'updating', ModUpdateCoordinator.instance().latestOf(m.filePath))
        } else {
          this.modMeta_.set(m.filePath, { source: src, projectId: m.remoteProjectId!, installedVersionId: m.remoteVersionId })
          this.setRowUpdate(m.filePath, 'checking', '')
          try {
            let versions = await this.getVersionsForSource_(src, m.remoteProjectId!, loaderKey, gameVer, modrinth, curseforge)
            if (epoch !== this.scanEpoch_) return
            let latest = await pickModUpdate(src, m.remoteProjectId!, m.remoteVersionId!, versions, scanResult.mods,
              new ModSourceRouter([modrinth, curseforge]))
            if (latest !== null && latest.id !== m.remoteVersionId && pickPrimaryFile(latest.files) !== null) {
              this.pendingUpdates_.set(m.filePath, latest)
              if (this.ignoredKeys_.has(m.filePath + '|' + latest.id)) {
                this.setRowUpdate(m.filePath, 'ignored', latest.versionNumber)
              } else {
                this.setRowUpdate(m.filePath, 'outdated', latest.versionNumber)
              }
            } else {
              this.setRowUpdate(m.filePath, 'latest', '')
            }
          } catch (e) {
            if (epoch === this.scanEpoch_) this.setRowUpdate(m.filePath, 'none', '')
            if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'update check failed for %{public}s', m.filename)
          }
        }
      }
    })
    await Promise.all(iconLookups)
  }

  /** 取项目图标 URL（源感知）。失败 / 无图标返回空串。 */
  private async projectIconUrl_(source: ModSource, projectId: string,
    modrinth: ModrinthRepository, curseforge: CurseForgeRepository): Promise<string> {
    let proj = (source === ModSource.CURSEFORGE)
      ? await curseforge.getProject(projectId)
      : await modrinth.getProject(projectId)
    return (proj.iconUrl !== undefined && proj.iconUrl.length > 0) ? proj.iconUrl : ''
  }

  /** 取某源下项目的版本列表（源感知），供 pickLatest 比对更新。 */
  private async getVersionsForSource_(source: ModSource, projectId: string,
    loaderKey: string, gameVer: string,
    modrinth: ModrinthRepository, curseforge: CurseForgeRepository): Promise<RemoteVersion[]> {
    if (source === ModSource.CURSEFORGE) {
      return curseforge.getVersions(projectId, [loaderKey], [gameVer])
    }
    return modrinth.getVersions(projectId, [loaderKey], [gameVer])
  }

  /**
   * 局部更新单行的 iconUrl，并通过整体重赋值 rows 触发 ArkUI 重渲。
   *
   * 之所以整体重建 rows 而非直接 mutate row.iconUrl：
   *   - ArkUI @State<Array> 的 dirty-track 仅监听数组引用变化，对 row.iconUrl
   *     这种字段级 mutate 不触发；必须用 `this.rows = newArray` 整体替换才稳。
   */
  private setRowIcon(filePath: string, iconUrl: string): void {
    let next: ResourceRow[] = this.rows.map((r): ResourceRow => {
      if (r.filePath !== filePath) return r
      return {
        filePath: r.filePath,
        filename: r.filename,
        displayName: r.displayName,
        enabled: r.enabled,
        sizeBytes: r.sizeBytes,
        iconUrl: iconUrl,
        updateState: r.updateState,
        latestVersionNumber: r.latestVersionNumber,
        updatingPct: r.updatingPct,
        integrity: r.integrity,
      }
    })
    this.rows = next
    if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'setRowIcon: %{public}s', filePath)
  }

  /** 局部更新单行的完整性状态（整体重赋值触发重渲）。 */
  private setRowIntegrity(filePath: string, integrity: string): void {
    let next: ResourceRow[] = this.rows.map((r): ResourceRow => {
      if (r.filePath !== filePath) return r
      return {
        filePath: r.filePath,
        filename: r.filename,
        displayName: r.displayName,
        enabled: r.enabled,
        sizeBytes: r.sizeBytes,
        iconUrl: r.iconUrl,
        updateState: r.updateState,
        latestVersionNumber: r.latestVersionNumber,
        updatingPct: r.updatingPct,
        integrity: integrity,
      }
    })
    this.rows = next
  }

  /** 局部更新单行的更新检查状态（与 setRowIcon 同样整体重赋值触发重渲）。 */
  private setRowUpdate(filePath: string, state: string, latestVersionNumber: string): void {
    let next: ResourceRow[] = this.rows.map((r): ResourceRow => {
      if (r.filePath !== filePath) return r
      return {
        filePath: r.filePath,
        filename: r.filename,
        displayName: r.displayName,
        enabled: r.enabled,
        sizeBytes: r.sizeBytes,
        iconUrl: r.iconUrl,
        updateState: state,
        latestVersionNumber: latestVersionNumber,
        updatingPct: state === 'updating' ? r.updatingPct : 0,
        integrity: r.integrity,
      }
    })
    this.rows = next
  }

  /** 仅更新某行的下载进度百分比（updating 期间高频调用）。 */
  private setRowUpdatingPct(filePath: string, pct: number): void {
    let next: ResourceRow[] = this.rows.map((r): ResourceRow => {
      if (r.filePath !== filePath) return r
      return {
        filePath: r.filePath,
        filename: r.filename,
        displayName: r.displayName,
        enabled: r.enabled,
        sizeBytes: r.sizeBytes,
        iconUrl: r.iconUrl,
        updateState: 'updating',
        latestVersionNumber: r.latestVersionNumber,
        updatingPct: pct,
        integrity: r.integrity,
      }
    })
    this.rows = next
  }

  /** 重连：把正被全局协调器更新的行恢复为 'updating' + 当前进度。 */
  private reconnectUpdatingRows(): void {
    let coord = ModUpdateCoordinator.instance()
    for (let r of this.rows) {
      if (coord.isUpdating(r.filePath)) {
        this.setRowUpdate(r.filePath, 'updating', coord.latestOf(r.filePath))
        this.setRowUpdatingPct(r.filePath, coord.pctOf(r.filePath))
      }
    }
  }

  /** 去掉 .disabled + 主扩展名后缀，给行卡片当主标题 */
  private displayNameOf(filename: string, m: KindMeta): string {
    // 先去掉可能的 .disabled 后缀
    let n = (m.disabledExt.length > 0 && isDisabledFilename(filename))
      ? enableFilename(filename)  // 这里 enableFilename 是按 ".disabled" 后缀切的，对 .zip.disabled 同样生效
      : filename
    let lower = n.toLowerCase()
    if (lower.endsWith(m.primaryExt)) {
      return n.substring(0, n.length - m.primaryExt.length)
    }
    return n
  }

  // 2026-05-23 API NEXT 迁移：promptAction.showToast 全局函数弃用，
  // 改走 this.getUIContext().getPromptAction().showToast(...)。同时该调用
  // 报 ArkTS 'Function may throw'，所以抽一个 safeToast 助手设凡位。
  // 详见 docs/guides/api-migration-2026-05.md。
  private safeToast(message: string, duration: number): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message, duration })
    } catch (e) {
      if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'showToast failed: %{public}s', (e as Error).message)
    }
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

  /**
   * 本地批量导入：多选资源文件，逐项校验与导入；部分成功也刷新列表。
   * 模组要 .jar，资源包 / 光影 / 数据包要 .zip（取 metaOf(kind).primaryExt）。
   */
  private async doImport(): Promise<void> {
    if (this.importing) return
    let ctx = this.getAbilityCtx()
    if (ctx === null) { this.safeToast('上下文不可用，无法导入', 1500); return }
    let dir = this.targetDir()
    if (dir.length === 0) { this.safeToast('请先选择一个已装版本', 1500); return }
    let m = metaOf(this.kind)
    this.importing = true
    try {
      let r = await GameArchiveIO.importResourceFiles(ctx, dir, [m.primaryExt])
      if (r.cancelled) return
      this.safeToast(r.message, r.failures.length > 0 ? 3500 : 1800)
      if (r.names.length > 0) {
        this.refresh()
        this.onChanged()
      }
    } catch (e) {
      AppLogger.warn(TAG, 'doImport failed', e, LOG_DOMAIN_DOWNLOAD)
      this.safeToast('导入失败：' + (e as Error).message, 2200)
    } finally {
      this.importing = false
    }
  }

  /**
   * 校验完整性（全量）：对已收编模组重算 sha1 与基准比对检出损坏；不符再反查消歧。
   * 复用 fetchIconsAsync(fullVerify=true)。完成后 toast 汇总损坏数。
   */
  private async doFullVerify(): Promise<void> {
    if (this.verifying) return
    if (this.kind !== ResourceKind.MOD) return
    let dm = DownloadManager.instance()
    if (!dm.isCaBundleInitialized()) { this.safeToast('网络组件未就绪，请稍后再试', 1800); return }
    this.verifying = true
    this.safeToast('正在校验完整性…', 1500)
    try {
      await this.fetchIconsAsync(this.scanEpoch_, true)
      let corrupt = 0
      for (let r of this.rows) { if (r.integrity === ModIntegrity.CORRUPT) corrupt++ }
      this.safeToast(corrupt > 0 ? ('校验完成：发现 ' + corrupt + ' 个损坏模组') : '校验完成：全部完好', 2400)
    } catch (e) {
      this.safeToast('校验失败：' + (e as Error).message, 2200)
    } finally {
      this.verifying = false
    }
  }

  /**
   * 一键修复损坏模组：按清单记录的源 + 版本重新下载【同一版本】，走 ModUpdateCoordinator
   * 暂存下载 + sha1 校验 + 原子替换（不污染 mods/）。完成后重扫即恢复 verified。
   */
  private async doRepair(row: ResourceRow): Promise<void> {
    const repairMcDir = this.mcDir
    const repairVersionId = this.versionId
    const repairIsolation = this.versionIsolation
    let meta = this.modMeta_.get(row.filePath)
    if (meta === undefined) { this.safeToast('无法修复（未关联来源）', 2000); return }
    let dm = DownloadManager.instance()
    if (!dm.isCaBundleInitialized()) { this.safeToast('网络组件未就绪，请稍后再试', 1800); return }
    this.safeToast('正在获取修复版本…', 1500)
    try {
      let src = (meta.source === ModSource.CURSEFORGE) ? ModSource.CURSEFORGE : ModSource.MODRINTH
      let ver: RemoteVersion
      if (src === ModSource.CURSEFORGE) {
        let cf = this.makeCurseForge(dm)
        ver = await cf.getVersion(meta.projectId + '/' + meta.installedVersionId)
      } else {
        let mr = this.makeModrinth(dm)
        ver = await mr.getVersion(meta.installedVersionId)
      }
      if (pickPrimaryFile(ver.files) === null) { this.safeToast('该版本无可下载文件', 2000); return }
      this.expandedPath = ''
      this.setRowUpdate(row.filePath, 'updating', ver.versionNumber)
      await ModUpdateCoordinator.instance().start({
        oldPath: row.filePath,
        wasEnabled: row.enabled,
        mcDir: repairMcDir,
        versionId: repairVersionId,
        versionIsolation: repairIsolation,
        displayName: row.displayName,
        latest: ver,
        router: new ModSourceRouter([this.makeModrinth(dm), this.makeCurseForge(dm)]),
      })
      this.safeToast('修复完成', 1600)
      this.refresh()
      this.onChanged()
    } catch (e) {
      this.setRowIntegrity(row.filePath, ModIntegrity.CORRUPT)
      this.safeToast('修复失败：' + (e as Error).message, 2400)
    }
  }

  /** 构造一个 Modrinth 仓储实例（图标反查 / 更新检查共用配置）。 */
  private makeModrinth(dm: DownloadManager): ModrinthRepository {
    return new ModrinthRepository(
      dm,
      getMetadataCacheStore(),
      () => ModrinthSourceMode.MCIM_FIRST,
      'AMCL/1.0.0 (https://github.com/axecraft/amcl)',
      () => true,
    )
  }

  /** 构造一个 CurseForge 仓储实例（CF 指纹反查 / CF 更新检查 / CF 图标共用）。 */
  private makeCurseForge(dm: DownloadManager): CurseForgeRepository {
    return new CurseForgeRepository(
      dm,
      getMetadataCacheStore(),
      'AMCL/1.0.0 (https://github.com/axecraft/amcl)',
      () => true,
      () => true,
    )
  }

  /** 该行是否可展开（有 Modrinth 关联，能展示更新动作；或已损坏可修复）。 */
  private isExpandable(row: ResourceRow): boolean {
    return row.updateState === 'outdated' || row.updateState === 'latest'
      || row.updateState === 'updating' || row.updateState === 'ignored'
      || row.integrity === ModIntegrity.CORRUPT
  }

  /** 展开 / 折叠某行（手风琴：同一时刻只展开一行）。带高度/淡入动画。 */
  private toggleExpand(filePath: string): void {
    this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
      this.expandedPath = this.expandedPath === filePath ? '' : filePath
    })
  }

  /** 单条「检查更新」：清掉该行的忽略记录后，重新查一次最新版。 */
  private async recheckUpdate(row: ResourceRow): Promise<void> {
    let meta = this.modMeta_.get(row.filePath)
    if (meta === undefined) { this.safeToast('无法检查（未关联 Modrinth）', 1800); return }
    // 清掉该文件的所有忽略记录（用户主动检查 = 想看到结果）
    let drop: string[] = []
    this.ignoredKeys_.forEach((k: string) => { if (k.startsWith(row.filePath + '|')) drop.push(k) })
    for (let k of drop) this.ignoredKeys_.delete(k)

    let dm = DownloadManager.instance()
    if (!dm.isCaBundleInitialized()) { this.safeToast('网络组件未就绪，请稍后再试', 1800); return }
    let loaderKey = resolveInstalledLoaderKey(this.mcDir, this.versionId)
    let gameVer = resolveInstalledMcVersion(this.mcDir, this.versionId)
    this.setRowUpdate(row.filePath, 'checking', '')
    try {
      let modrinth = this.makeModrinth(dm)
      let curseforge = this.makeCurseForge(dm)
      let src = (meta.source === ModSource.CURSEFORGE) ? ModSource.CURSEFORGE : ModSource.MODRINTH
      let versions = await this.getVersionsForSource_(src, meta.projectId, loaderKey, gameVer, modrinth, curseforge)
      const scan = await new LocalModScanner(modrinth, curseforge).scan({ mcDir: this.mcDir,
        versionId: this.versionId, versionIsolation: this.versionIsolation, kind: ResourceKind.MOD })
      let latest = await pickModUpdate(src, meta.projectId, meta.installedVersionId, versions, scan.mods,
        new ModSourceRouter([modrinth, curseforge]))
      if (latest !== null && latest.id !== meta.installedVersionId && pickPrimaryFile(latest.files) !== null) {
        this.pendingUpdates_.set(row.filePath, latest)
        this.setRowUpdate(row.filePath, 'outdated', latest.versionNumber)
      } else {
        this.setRowUpdate(row.filePath, 'latest', '')
        this.safeToast('当前没有满足依赖要求的更新', 1800)
      }
    } catch (e) {
      this.setRowUpdate(row.filePath, 'latest', '')
      this.safeToast('检查失败：' + (e as Error).message, 2200)
    }
  }

  /** 忽略本次更新（会话级，记到该目标版本；出现更新版本会重新提示）。 */
  private ignoreUpdate(row: ResourceRow): void {
    let latest = this.pendingUpdates_.get(row.filePath)
    if (latest !== undefined) this.ignoredKeys_.add(row.filePath + '|' + latest.id)
    this.expandedPath = ''
    this.setRowUpdate(row.filePath, 'ignored', row.latestVersionNumber)
    this.safeToast('已忽略该更新', 1400)
  }

  /**
   * 一键更新：交给全局协调器 ModUpdateCoordinator（暂存下载 → 校验 → 落地替换）。
   * 本组件只置一次 'updating' 做即时反馈，进度与完成由协调器监听驱动。
   * 走协调器的好处：跨 sheet 关闭/重开进度不丢、mods/ 不出现半成品、完成后才替换旧文件。
   */
  private async doUpdate(row: ResourceRow): Promise<void> {
    let latest = this.pendingUpdates_.get(row.filePath)
    if (latest === undefined) { this.safeToast('更新信息已过期，请刷新后重试', 1800); return }
    this.setRowUpdate(row.filePath, 'updating', row.latestVersionNumber)
    try {
      await ModUpdateCoordinator.instance().start({
        oldPath: row.filePath,
        wasEnabled: row.enabled,
        mcDir: this.mcDir,
        versionId: this.versionId,
        versionIsolation: this.versionIsolation,
        displayName: row.displayName,
        latest: latest,
        router: new ModSourceRouter([this.makeModrinth(DownloadManager.instance()), this.makeCurseForge(DownloadManager.instance())]),
      })
      this.safeToast('已更新到 ' + latest.versionNumber, 1800)
      this.onChanged()
      // 完成后协调器会 notify → onCoordChange 触发 refresh；这里再兜一次确保刷新
      this.refresh()
    } catch (e) {
      let msg = (e as Error).message
      let isCancelled = msg.indexOf('已取消') >= 0 || msg.indexOf('cancel') >= 0
      AppLogger.warn(TAG, `doUpdate failed: ${msg}`, null, LOG_DOMAIN_DOWNLOAD)
      this.setRowUpdate(row.filePath, 'outdated', row.latestVersionNumber)
      this.safeToast(isCancelled ? '已取消更新' : ('更新失败：' + msg), 2400)
    }
  }

  private handleToggle(row: ResourceRow, isOn: boolean): void {
    if (row.enabled === isOn) return
    if (!metaOf(this.kind).togglable) {
      this.safeToast(metaOf(this.kind).unit + '不支持启用 / 禁用切换', 1500)
      return
    }
    let installer = new ModInstaller(DownloadManager.instance())
    try {
      let newPath = installer.setEnabled(row.filePath, isOn)
      if (newPath === null) {
        this.safeToast('文件已不存在，正在刷新', 1500)
        this.refresh()
        return
      }
      this.safeToast(isOn ? '已启用' : '已禁用', 1200)
      this.refresh()
      this.onChanged()
    } catch (e) {
      let msg = (e as Error).message
      AppLogger.warn(TAG, `toggle failed: ${msg}`, null, LOG_DOMAIN_UI)
      this.safeToast('切换失败：' + msg, 2000)
      this.refresh()
    }
  }

  private executeDelete(): void {
    let target = this.pendingDelete
    this.pendingDelete = ''
    if (target.length === 0) return
    let dir = this.targetDir()
    let path = dir + '/' + target
    let installer = new ModInstaller(DownloadManager.instance())
    try {
      let ok = installer.delete(path)
      if (!ok) {
        this.safeToast('文件已不存在', 1500)
      } else {
        this.safeToast('已删除 ' + target, 1500)
      }
      this.refresh()
      this.onChanged()
    } catch (e) {
      let msg = (e as Error).message
      AppLogger.warn(TAG, `delete failed: ${msg}`, null, LOG_DOMAIN_UI)
      this.safeToast('删除失败：' + msg, 2000)
    }
  }

  // ============================================================
  //  排序持久化（sheet 范围内）
  //
  //  目标：
  //    - toggle 启用/禁用不让行跳到顶/底
  //    - 用户手动顺序（未来 TODO：长按拖拽）应当跨 app 重启保留
  //    - 新装的 mod 默认追加到末尾
  //
  //  实现：
  //    - "逻辑名" = enableFilename(filename)，即剥掉 .disabled 后的稳定名字。
  //      即使切了 toggle，filename 从 sodium-fabric-0.5.8+mc1.20.4.jar 变成
  //      sodium-fabric-0.5.8+mc1.20.4.jar.disabled，logicalName 仍是同一个串。
  //    - PreferenceManager.getResOrder/setResOrder 存这一份 logicalName 数组，
  //      key 是 resOrder.<versionId>.<kind>。
  //    - applyPersistedOrder 是纯排序合并器：磁盘扫描结果按存储顺序排，遗漏项追加，
  //      存储里多余项清掉，最后回写一次（便于下次省一次合并）。
  // ============================================================

  /** 拿（懒加载）PreferenceManager 实例。失败返回 null —— 不让排序持久化吃异常
   *
   * 2026-05-23 API NEXT 迁移：getContext(this) 已弃用，改读 EntryAbility
   * 缓存的 'uiAbilityContext'。详见 docs/guides/api-migration-2026-05.md。
   */
  private getPrefs(): PreferenceManager | null {
    if (this.prefs_ !== null) return this.prefs_
    try {
      let ctx = AppStorage.get<Context>('uiAbilityContext')
      if (!ctx) {
        if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'uiAbilityContext not yet cached in AppStorage')
        return null
      }
      this.prefs_ = new PreferenceManager(ctx)
    } catch (e) {
      AppLogger.warn(TAG, 'PreferenceManager init failed', e, LOG_DOMAIN_UI)
      return null
    }
    return this.prefs_
  }

  /**
   * row 的"逻辑名"：剥掉 .disabled 后缀。
   * 用于持久化排序的稳定 key —— 切换 toggle 不会改变。
   */
  private logicalNameOf(filename: string): string {
    return enableFilename(filename)
  }

  /**
   * 把磁盘扫描结果 `scanned` 按存储顺序重排，并把"目录有 / 存储无"的新项追加到末尾。
   * 同时把"存储有 / 目录无"的项从持久化里清掉，避免无限膨胀。
   *
   * 排序规则（合并后）：
   *   1. 持久化数组里出现过的项 → 按数组里的相对顺序
   *   2. 没出现过的新项 → 按 displayName 字母序追加到末尾
   *
   * 调用方需要传入 `meta`（来自 metaOf(kind)），仅用来判断"是否需要持久化"的 kind 名。
   */
  private applyPersistedOrder(scanned: ResourceRow[], meta: KindMeta): ResourceRow[] {
    if (scanned.length === 0) return scanned
    let kindKey = this.kind as string
    if (this.versionId.length === 0 || kindKey.length === 0) return scanned
    let prefs = this.getPrefs()
    if (prefs === null) return scanned

    let savedOrder = prefs.getResOrder(this.versionId, kindKey)

    // index lookup：savedOrder 里每个 logicalName → 数组下标
    let savedIdx: Map<string, number> = new Map<string, number>()
    for (let i = 0; i < savedOrder.length; i++) {
      savedIdx.set(savedOrder[i], i)
    }

    // 拆成两组：
    //   - known   = 命中存储的，按 savedIdx 排序
    //   - unknown = 没命中的（新装），按 displayName 字母序排
    let known: ResourceRow[] = []
    let unknown: ResourceRow[] = []
    for (let r of scanned) {
      let logical = this.logicalNameOf(r.filename)
      if (savedIdx.has(logical)) {
        known.push(r)
      } else {
        unknown.push(r)
      }
    }
    known.sort((a: ResourceRow, b: ResourceRow): number => {
      let ai = savedIdx.get(this.logicalNameOf(a.filename))!
      let bi = savedIdx.get(this.logicalNameOf(b.filename))!
      return ai - bi
    })
    unknown.sort((a: ResourceRow, b: ResourceRow): number => {
      if (a.displayName < b.displayName) return -1
      if (a.displayName > b.displayName) return 1
      return 0
    })

    let merged: ResourceRow[] = known.concat(unknown)

    // 回写存储 —— 清理失效项 + 落盘新项的顺序，下次省一次合并。
    // 仅当合并后顺序与磁盘真实情况"应当持久化"的顺序不同时才写：
    //   - 多了 / 少了 / 相对顺序变了 → 都触发回写
    let nextOrder: string[] = []
    for (let r of merged) nextOrder.push(this.logicalNameOf(r.filename))
    if (!this.arrayEqual(nextOrder, savedOrder)) {
      prefs.setResOrder(this.versionId, kindKey, nextOrder)
    }

    return merged
  }

  private arrayEqual(a: string[], b: string[]): boolean {
    if (a.length !== b.length) return false
    for (let i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) return false
    }
    return true
  }
}
