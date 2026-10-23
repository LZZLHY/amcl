import { ImmersiveTitleScaffold } from './ImmersiveTitleScaffold';
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
 *   来源识别与更新信息在完整本地列表发布后受限补全；包内语义仍交由实际加载器处理。
 */

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GameArchiveIO } from './GameArchiveIO';
import { ThemeColors } from 'commons';
import { resolveInstanceGameDir } from 'commons';
import { AppIconName } from 'commons';
import { AppIcon } from './AppIcon';
import { InstalledResourceRow as ResourceRow, InstalledResourceData } from './InstalledResourceData';
import { InstalledResourceItem } from './InstalledResourceItem';
import { installedResourceWork } from './InstalledResourceWork';
import {
  ModInstaller,
  isDisabledFilename,
  enableFilename,
} from 'mods';
import { DownloadManager } from 'feature_core';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_DOWNLOAD, LOG_DOMAIN_UI } from 'commons';
import { ResourceKind } from 'mods';
import { kindIcon } from '../components/ResourceIcons';
import { LocalModScanner, LocalMod, LocalModScanControl, enumerateLocalResourceFiles } from 'mods';
import { ModrinthRepository } from 'mods';
import { CurseForgeRepository } from 'mods';
import { ModIntegrity } from 'mods';
import { ModSource } from 'mods';
import { getMetadataCacheStore } from 'feature_core';
import { ModrinthSourceMode } from 'mods';
import { pickPrimaryFile, resolveInstalledMcVersion } from 'mods';
import { RemoteVersion } from 'mods';
import { resolveInstalledLoaderKey } from '../components/LoaderCatalog';
import { ModUpdateCoordinator } from './ModUpdateCoordinator';
import { ModSourceRouter, createModUpdateSession } from 'mods';
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

/** 单个 mod 的源关联信息（更新检查 / 修复复用）。 */
interface ModUpdateMeta {
  /** ModSource 值（'modrinth' | 'curseforge'）：决定用哪个仓储查版本。 */
  source: string;
  projectId: string;
  installedVersionId: string;
}


@Component
export struct InstalledResourcesSheet {
  @Prop theme: ThemeColors = {} as ThemeColors;
  @Prop bottomSafeHeight: number = 0;
  /** .minecraft 根（不带尾部 /） */
  @Prop @Watch('onScopeChanged') mcDir: string = '';
  /** 目标版本 id；为空时显示空态 + 引导提示 */
  @Prop @Watch('onScopeChanged') versionId: string = '';
  @Prop @Watch('onScopeChanged') versionIsolation: boolean = true;
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
  /** 全量轻量清单和可见投影分开；数据源实例不随输入重建。 */
  private resourceData_: InstalledResourceData = new InstalledResourceData();
  @State private query: string = '';
  @State private visibleCount: number = 0;
  private scopeKey_: string = '';
  private mounted_: boolean = false;
  private scanControl_: LocalModScanControl | null = null;
  private localMods_: LocalMod[] = [];

  @State private loaded: boolean = false;
  /** 二次确认中的删除目标 filename；空 = 无对话框 */
  @State @Watch('publishNavigationBlocked_') private pendingDelete: string = '';
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
  /** 只投影本面板原遮罩/事务是否阻止导航，父宿主不复制文件业务状态。 */
  onNavigationBlocked: (blocked: boolean) => void = () => {};
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
    this.navigationProjectionAlive_ = true;
    this.mounted_ = true;
    ModUpdateCoordinator.instance().addListener(this.coordListener)
    if (this.active) this.refresh();
  }

  aboutToDisappear() {
    this.navigationProjectionAlive_ = false;
    this.mounted_ = false;
    this.cancelScan();
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
    const scope = this.targetDir() + '|' + this.kind;
    if (scope !== this.scopeKey_) {
      this.scopeKey_ = scope;
      this.query = '';
      this.visibleCount = this.resourceData_.filter('');
      this.pendingDelete = '';
    }
    if (this.active && this.mounted_) this.refresh();
    else { this.cancelScan(); this.loaded = false; }
  }

  /** 失效后不再发布旧状态；控制器同时停止扫描器排队及后续联网工作。 */
  private cancelScan(): void {
    this.scanEpoch_++;
    this.scanControl_?.cancel();
    this.scanControl_ = null;
    this.verifying = false;
  }

  private isCurrent(epoch: number): boolean {
    return this.mounted_ && this.active && epoch === this.scanEpoch_;
  }


  /** 卸载后不再向父标题发布迟到状态；文件任务和扫描的原所有权不变。 */
  private navigationProjectionAlive_: boolean = false;

  /** 导航只观察原遮罩事实，不取消任务或跳过原确认；未屏蔽正文时仍允许原返回。 */
  private navigationBlocked_(): boolean { return this.pendingDelete.length > 0; }

  /** 业务状态变化后只发一个布尔投影，供已有父标题同步禁用状态。 */
  private publishNavigationBlocked_(): void {
    if (this.navigationProjectionAlive_) this.onNavigationBlocked(this.navigationBlocked_());
  }

  build() {
    if (this.embedded) {
      this.PanelBody_();
    } else {
      ImmersiveTitleScaffold({ title: metaOf(this.kind).title, theme: this.theme, modal: true,
        surfaceColor: this.theme.bgPrimary, closeLabel: '关闭管理面板',
        closeId: 'installedresourcessheet-close', closeEnabled: !this.navigationBlocked_(),
        onClose: (): void => { if (!this.navigationBlocked_()) this.onClose(); },
        content: (): void => { this.ImmersiveTitleContent1_(); }
      })
    }
  }

  /** 原面板正文与覆盖层保持原组件所有权，宿主只接管导航动作。 */
  @Builder
  private PanelBody_() {
    Column() {
      this.Header()
      this.SearchHeader()

      if (!this.loaded) {
        this.LoadingState()
      } else if (this.rows.length === 0) {
        this.EmptyState()
      } else if (this.visibleCount === 0) {
        this.NoSearchResults()
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
            .enabled(this.loaded && !this.verifying)
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

  /** 搜索框常驻，加载或无结果时不重挂输入框，保留软键盘和焦点。 */
  @Builder
  SearchHeader() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        AppIcon({ name: AppIconName.Search, iconSize: 16, color: this.theme.textHint })
        TextInput({ placeholder: '搜索当前版本' + metaOf(this.kind).unit + '文件名', text: this.query })
          .id('installed-resource-search')
          .height(40).fontSize(14).layoutWeight(1)
          .backgroundColor(Color.Transparent)
          .onChange((value: string) => { this.applyQuery(value) })
        if (this.query.length > 0) {
          Button('清除')
            .id('installed-resource-search-clear')
            .fontSize(12).height(32)
            .fontColor(this.theme.textSecondary).backgroundColor(Color.Transparent)
            .accessibilityText('清除模组搜索')
            .onClick(() => { this.applyQuery('') })
        }
      }
      .width('100%').padding({ left: 12, right: 4 })
      .backgroundColor(this.theme.bgInput).borderRadius(12)
      Text('找到 ' + this.visibleCount + ' / 共 ' + this.rows.length + ' 个' + metaOf(this.kind).unit)
        .id('installed-resource-search-count')
        .fontSize(11).fontColor(this.theme.textHint)
    }
    .width('100%').alignItems(HorizontalAlign.Start)
    .padding({ left: 20, right: 20, bottom: 10 })
  }

  /** 搜索只改轻量清单的内存投影，禁用项和未识别来源项不被额外排除。 */
  private applyQuery(value: string): void {
    this.query = value;
    this.visibleCount = this.resourceData_.filter(value);
    this.expandedPath = '';
  }

  @Builder
  NoSearchResults() {
    Column({ space: 12 }) {
      Text('没有匹配的' + metaOf(this.kind).unit)
        .fontSize(16).fontColor(this.theme.textPrimary)
      Text('试试文件名中的其他文字，或清除搜索查看全部资源。')
        .fontSize(12).fontColor(this.theme.textHint).textAlign(TextAlign.Center)
      Button('清除搜索').onClick(() => { this.applyQuery('') })
    }
    .width('100%').layoutWeight(1).padding(24)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  ListView() {
    List({ space: 10 }) {
      LazyForEach(this.resourceData_, (row: ResourceRow) => {
        ListItem() {
          InstalledResourceItem({
            row: row, theme: this.theme, kind: this.kind,
            togglable: metaOf(this.kind).togglable,
            expanded: this.expandedPath === row.filePath,
            onExpand: () => { this.toggleExpand(row.filePath) },
            onToggle: (enabled: boolean) => { this.handleToggle(row, enabled) },
            onDelete: () => { this.pendingDelete = row.filename },
            onRepair: () => { this.doRepair(row) },
            onUpdate: () => { this.doUpdate(row) },
            onRecheck: () => { this.recheckUpdate(row) },
            onIgnore: () => { this.ignoreUpdate(row) },
          })
        }
      }, (row: ResourceRow) => row.filePath)
    }
    .layoutWeight(1)
    .width('100%')
    .padding({ left: 20, right: 20 })
    .scrollBar(BarState.Off)
    .cachedCount(3)
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
    if (this.versionId.length === 0 && this.versionIsolation) return ''
    return resolveInstanceGameDir(this.mcDir, this.versionId, this.versionIsolation) + '/' + sub
  }

  /**
   * 创建本轮控制器并异步枚举完整目录；首屏只依赖本地轻量记录，来源反查不作为显示前提。
   * 每个 await 后校验代次与激活状态，避免快速返回、刷新或切实例时旧结果覆盖新清单。
   */
  private refresh(): void {
    this.cancelScan();
    if (!this.active || !this.mounted_) return;
    this.scopeKey_ = this.targetDir() + '|' + this.kind;
    this.loaded = false;
    this.pendingUpdates_.clear();
    this.modMeta_.clear();
    this.expandedPath = '';
    const epoch = this.scanEpoch_;
    const control = new LocalModScanControl();
    this.scanControl_ = control;
    this.loadLocalRows(epoch, control).catch((error: Error) => {
      if (!this.isCurrent(epoch)) return;
      this.rows = this.resourceData_.replace([]);
      this.visibleCount = 0;
      this.loaded = true;
      AppLogger.warn(TAG, '本地资源枚举失败', error, LOG_DOMAIN_UI);
    });
  }

  private async loadLocalRows(epoch: number, control: LocalModScanControl): Promise<void> {
    const dir = this.targetDir();
    const meta = metaOf(this.kind);
    const extensions = meta.disabledExt.length > 0 ? [meta.primaryExt, meta.disabledExt] : [meta.primaryExt];
    const files: LocalMod[] = dir.length === 0 ? [] : await enumerateLocalResourceFiles(dir, extensions, control);
    if (!this.isCurrent(epoch)) return;
    this.localMods_ = files;
    const result: ResourceRow[] = files.map((file: LocalMod) => new ResourceRow({
      filePath: file.filePath, filename: file.filename,
      displayName: this.displayNameOf(file.filename, meta), enabled: file.enabled,
      sizeBytes: file.sizeBytes, iconUrl: '', updateState: 'none',
      latestVersionNumber: '', updatingPct: 0, integrity: 'none',
    }));
    this.rows = this.resourceData_.replace(this.applyPersistedOrder(result));
    this.visibleCount = this.resourceData_.filter(this.query);
    this.loaded = true;
    this.reconnectUpdatingRows();
    if (this.kind === ResourceKind.MOD && files.length > 0) {
      this.fetchIconsAsync(epoch).catch((error: Error) => {
        if (this.isCurrent(epoch)) AppLogger.warn(TAG, '模组附加信息加载失败', error, LOG_DOMAIN_DOWNLOAD);
      });
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
    const control = this.scanControl_;
    if (control === null || !this.isCurrent(epoch)) return;
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
      control: control,
      localMods: this.localMods_,
    })
    if (!this.isCurrent(epoch)) return  // 用户已经切走，丢弃结果

    // 先把完整性状态写回所有行（含 corrupt / unknown / verified / linked / recheck）
    for (let m of scanResult.mods) {
      this.setRowIntegrity(m.filePath, m.integrity !== undefined ? m.integrity : ModIntegrity.UNKNOWN)
      if (m.remoteSource !== undefined && m.remoteProjectId !== undefined && m.remoteVersionId !== undefined) {
        this.modMeta_.set(m.filePath, { source: m.remoteSource, projectId: m.remoteProjectId,
          installedVersionId: m.remoteVersionId });
      }
    }
    // 显式完整性校验不再等待整合包的在线更新历史；来源映射已保留供损坏项修复。
    if (fullVerify) {
      for (const row of this.rows) { if (row.updateState === 'checking') row.updateState = 'none'; }
      return;
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
    // 本轮共享具体版本与反向依赖索引，避免每个候选重复读取全体已装版本。
    const updateSession = createModUpdateSession(scanResult.mods,
      new ModSourceRouter([modrinth, curseforge]), () => !this.isCurrent(epoch));
    const loadOne = async (m: LocalMod): Promise<void> => {
      if (!this.isCurrent(epoch)) return;
      let src = m.remoteSource as ModSource
      // 源关联(含损坏行)先记入 modMeta_，供修复 / 检查更新复用
      if (m.remoteVersionId !== undefined && m.remoteVersionId.length > 0) {
        this.modMeta_.set(m.filePath, { source: src, projectId: m.remoteProjectId!, installedVersionId: m.remoteVersionId })
      }
      // 图标（源感知）
      try {
        let iconUrl = await this.projectIconUrl_(src, m.remoteProjectId!, modrinth, curseforge)
        if (!this.isCurrent(epoch)) return
        if (iconUrl.length > 0) this.setRowIcon(m.filePath, iconUrl)
      } catch (e) {
        if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'getProject failed for %{public}s', m.filename)
      }
      if (!this.isCurrent(epoch)) return;
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
            if (!this.isCurrent(epoch)) return
            let latest = await updateSession.pick(src, m.remoteProjectId!, m.remoteVersionId!, versions)
            if (!this.isCurrent(epoch)) return;
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
            if (this.isCurrent(epoch)) this.setRowUpdate(m.filePath, 'none', '')
            if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'update check failed for %{public}s', m.filename)
          }
        }
      }
    };
    // 只创建三个消费器；跨页面实例的闸门确保刷新不会叠加无限在途查询。
    let cursor = 0;
    const consume = async (): Promise<void> => {
      while (this.isCurrent(epoch) && cursor < hits.length) {
        const mod = hits[cursor++];
        await installedResourceWork.run(() => loadOne(mod), () => !this.isCurrent(epoch));
      }
    };
    await Promise.all([consume(), consume(), consume()]);
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

  /** 以下单项回写按物理路径定位稳定行，由 ObjectLink 只刷新可见消费者。 */
  private setRowIcon(filePath: string, iconUrl: string): void {
    const row = this.resourceData_.find(filePath);
    if (row !== undefined) row.iconUrl = iconUrl;
  }

  private setRowIntegrity(filePath: string, integrity: string): void {
    const row = this.resourceData_.find(filePath);
    if (row !== undefined) row.integrity = integrity;
  }

  private setRowUpdate(filePath: string, state: string, latestVersionNumber: string): void {
    const row = this.resourceData_.find(filePath);
    if (row === undefined) return;
    row.updateState = state;
    row.latestVersionNumber = latestVersionNumber;
    if (state !== 'updating') row.updatingPct = 0;
  }

  private setRowUpdatingPct(filePath: string, pct: number): void {
    const row = this.resourceData_.find(filePath);
    if (row === undefined) return;
    row.updateState = 'updating';
    row.updatingPct = Math.max(0, Math.min(100, Math.floor(pct)));
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
    // 初始枚举是唯一发布基础清单的任务，不能被空快照校验打断。
    if (!this.loaded || !this.active || !this.mounted_) return;
    if (this.verifying) return
    if (this.kind !== ResourceKind.MOD) return
    let dm = DownloadManager.instance()
    if (!dm.isCaBundleInitialized()) { this.safeToast('网络组件未就绪，请稍后再试', 1800); return }
    this.cancelScan();
    const epoch = this.scanEpoch_;
    this.scanControl_ = new LocalModScanControl();
    this.verifying = true
    this.safeToast('正在校验完整性…', 1500)
    try {
      await this.fetchIconsAsync(epoch, true)
      if (!this.isCurrent(epoch)) return;
      let corrupt = 0
      for (let r of this.rows) { if (r.integrity === ModIntegrity.CORRUPT) corrupt++ }
      this.safeToast(corrupt > 0 ? ('校验完成：发现 ' + corrupt + ' 个损坏模组') : '校验完成：未发现已确认的损坏', 2400)
    } catch (e) {
      if (this.isCurrent(epoch)) this.safeToast('校验失败：' + (e as Error).message, 2200)
    } finally {
      if (this.isCurrent(epoch)) this.verifying = false
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

  /** 展开 / 折叠某行（手风琴：同一时刻只展开一行）。带高度/淡入动画。 */
  private toggleExpand(filePath: string): void {
    this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
      this.expandedPath = this.expandedPath === filePath ? '' : filePath
    })
  }

  /** 单条「检查更新」：清掉该行的忽略记录后，重新查一次最新版。 */
  private async recheckUpdate(row: ResourceRow): Promise<void> {
    const epoch = this.scanEpoch_;
    const control = this.scanControl_;
    if (!this.isCurrent(epoch) || control === null || row.updateState === 'checking') return;
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
      if (!this.isCurrent(epoch)) return;
      const scan = await new LocalModScanner(modrinth, curseforge).scan({ mcDir: this.mcDir,
        versionId: this.versionId, versionIsolation: this.versionIsolation, kind: ResourceKind.MOD,
        control: control, localMods: this.localMods_ })
      if (!this.isCurrent(epoch)) return;
      const session = createModUpdateSession(scan.mods, new ModSourceRouter([modrinth, curseforge]),
        () => !this.isCurrent(epoch));
      let latest = await session.pick(src, meta.projectId, meta.installedVersionId, versions)
      if (!this.isCurrent(epoch)) return;
      if (latest !== null && latest.id !== meta.installedVersionId && pickPrimaryFile(latest.files) !== null) {
        this.pendingUpdates_.set(row.filePath, latest)
        this.setRowUpdate(row.filePath, 'outdated', latest.versionNumber)
      } else {
        this.setRowUpdate(row.filePath, 'latest', '')
        this.safeToast('当前没有满足依赖要求的更新', 1800)
      }
    } catch (e) {
      if (!this.isCurrent(epoch)) return;
      this.setRowUpdate(row.filePath, 'none', '')
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
   * 资源类型从组件当前作用域读取；排序只处理当前完整清单。
   */
  private applyPersistedOrder(scanned: ResourceRow[]): ResourceRow[] {
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

  /** 保留原正文的父组件状态与业务回调；具名content只转调此真正@Builder，避免this漂移。 */
  @Builder
  private ImmersiveTitleContent1_() {
        this.PanelBody_();
      }
}
