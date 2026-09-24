/**
 * LoaderCatalog.ets — Mod Loader 元数据单一事实源（2026-05-23）
 *
 * ============================================================================
 *  为什么有这个文件
 * ============================================================================
 * 历史上 fabric / forge / neoforge / quilt 的视觉与文案在 5 个地方重复定义：
 *   - VersionConfigPanel.LOADERS[].icon          → AppIconName 映射
 *   - VersionConfigPanel.loaderIconColor         → 颜色矩阵
 *   - VersionManagerSheet.iconName / iconFg /    → 同样的 AppIconName + 颜色
 *     detailHeroIcon                              ↑ 但 Fabric 一处灰一处绿，已分歧
 *   - VersionBlockIcon.selectMedia()             → loader → PNG 资源（没 export）
 *   - AppIcon.loaderIconForVersion(mcVersion)    → 字符串 indexOf 推断
 *   - FabricApiCard 内硬编码 '#16A34A' / '#DCFCE7'
 *
 * 改动：所有 loader 的 icon / 颜色 / PNG / 描述 / supported 标志收敛到本文件
 * 一张 LOADER_INFO 表里。UI 调用方只对外暴露 3 个函数：
 *
 *   getLoaderInfo(key)              —— 直接按 key 取
 *   inferLoaderKey(versionId)       —— 由版本 id 推断 key（复用 detectLoaderFromId）
 *   inferLoaderInfo(versionId)      —— 推断 + 取信息一步到位
 *
 * 顺带把 vanilla 子类别（snapshot/aprilfools/old/release）的 PNG + 颜色矩阵
 * 也归到本文件 VANILLA_CATEGORY_INFO 表里，VersionBlockIcon / VersionConfigPanel
 * 不再各自维护一套。
 *
 * ============================================================================
 *  加新 loader 流程（5 步）
 * ============================================================================
 *   1. LoaderKey 加新字面量
 *   2. LOADER_INFO 表加新 entry（icon/PNG/color/desc/supported）
 *   3. resources/base/media/loader_xxx.png 放 PCL2 风方块图
 *   4. features/mods/VersionIdUtils.detectLoaderFromId / classifyVersion 加识别规则
 *   5. UI 全部自动接通（不需要再改任何组件代码）
 *
 * ============================================================================
 *  ArkTS 限制
 * ============================================================================
 * `$r('app.media.xxx')` 不能放在顶层 const，所以 LOADER_INFO 由 buildLoaderInfo()
 * 函数延迟构造（首次调用时才解析 Resource），用模块级 lazy cache 避免重复构造。
 */

import { AppIconName } from 'commons';
import { detectLoaderFromId, classifyVersion, VersionCategory } from 'mods';
import { resolveInstalledLoader } from 'mods';

/** 已识别的 mod loader 键（含 vanilla 表示无 loader） */
export type LoaderKey = 'vanilla' | 'fabric' | 'forge' | 'neoforge' | 'quilt';

/** 单个 loader 的全部展示元数据 */
export interface LoaderInfo {
  /** loader 键 */
  key: LoaderKey;
  /** UI 显示名（Fabric / Forge / 原版 …） */
  displayName: string;
  /** SymbolGlyph 矢量兜底（chip / list 小图标 / fallback 用） */
  iconName: AppIconName;
  /** PCL2 风 64×64 PNG 方块（vanilla=草方块；loader=loom / anvil / flame 等 logo） */
  blockMedia: Resource;
  /** 主色（600 系列）：chip 选中态、hero 卡、accent badge */
  accentColor: ResourceColor;
  /** 浅背景色（100 系列）：chip bg / FabricApiCard 图标背景 */
  accentBg: ResourceColor;
  /** chip 副标题描述（VersionConfigPanel.LOADERS desc 字段同义） */
  description: string;
  /** 是否完整支持安装链（false=显示但不让选） */
  supported: boolean;
}

// ============================================================================
//  vanilla 子类别（snapshot / aprilfools / old / release）—— 同一张表
// ============================================================================

/** vanilla 版本的子分类视觉数据 */
export interface VanillaCategoryInfo {
  category: VersionCategory;
  displayName: string;
  blockMedia: Resource;
  accentColor: ResourceColor;
  accentBg: ResourceColor;
}

// ============================================================================
//  延迟构造：$r() 不能放顶层 const，所以包在函数里 + module-scope cache
// ============================================================================

let LOADER_INFO_CACHE_: Map<LoaderKey, LoaderInfo> | null = null;
let VANILLA_CAT_CACHE_: Map<VersionCategory, VanillaCategoryInfo> | null = null;

/**
 * 首次调用时构造表；之后直接返回缓存。
 *
 * 不能 module init 时跑——$r 在某些 ArkTS 严格模式版本下要求在组件 build()
 * 上下文之外延迟解析。
 */
function ensureLoaderInfoTable_(): Map<LoaderKey, LoaderInfo> {
  if (LOADER_INFO_CACHE_ !== null) return LOADER_INFO_CACHE_;
  let m = new Map<LoaderKey, LoaderInfo>();
  m.set('vanilla', {
    key: 'vanilla',
    displayName: '原版',
    iconName: AppIconName.Game,
    blockMedia: $r('app.media.block_grass'),
    accentColor: '#16A34A',                         // 草方块绿
    accentBg: '#DCFCE7',
    description: '纯净 Minecraft，无 mod',
    supported: true,
  });
  m.set('fabric', {
    key: 'fabric',
    displayName: 'Fabric',
    iconName: AppIconName.LoaderFabric,
    blockMedia: $r('app.media.loader_fabric'),      // PCL2 风 loom 织布机 logo
    accentColor: '#16A34A',                         // 绿（与 PNG 主色一致）
    accentBg: '#DCFCE7',
    description: '轻量级 · 启动快 · Sodium/Iris 必选',
    supported: true,
  });
  m.set('forge', {
    key: 'forge',
    displayName: 'Forge',
    iconName: AppIconName.LoaderForge,
    blockMedia: $r('app.media.block_anvil'),        // 铁砧 = Forge 锻造主题
    accentColor: '#D97706',                         // 橙（铁砧火花色）
    accentBg: '#FEF3C7',
    description: '经典 · mod 最多 · Create / JEI 生态',
    supported: true,
  });
  m.set('neoforge', {
    key: 'neoforge',
    displayName: 'NeoForge',
    iconName: AppIconName.LoaderNeoForge,
    blockMedia: $r('app.media.loader_neoforge'),
    accentColor: '#DC2626',                         // 红（NeoForge 火焰主题）
    accentBg: '#FEE2E2',
    description: '前沿 · Forge 社区分支 · 性能优',
    supported: true,
  });
  m.set('quilt', {
    key: 'quilt',
    displayName: 'Quilt',
    iconName: AppIconName.LoaderQuilt,
    blockMedia: $r('app.media.loader_quilt'),
    accentColor: '#9333EA',                         // 紫（Quilt 拼布主题）
    accentBg: '#F3E8FF',
    description: '实验 · Fabric 兼容分支',
    supported: false,
  });
  LOADER_INFO_CACHE_ = m;
  return m;
}

function ensureVanillaCatTable_(): Map<VersionCategory, VanillaCategoryInfo> {
  if (VANILLA_CAT_CACHE_ !== null) return VANILLA_CAT_CACHE_;
  let m = new Map<VersionCategory, VanillaCategoryInfo>();
  m.set('release', {
    category: 'release',
    displayName: '正式版',
    blockMedia: $r('app.media.block_grass'),
    accentColor: '#16A34A',
    accentBg: '#DCFCE7',
  });
  m.set('snapshot', {
    category: 'snapshot',
    displayName: '快照',
    blockMedia: $r('app.media.block_command'),
    accentColor: '#D97706',                         // 命令方块橙
    accentBg: '#FEF3C7',
  });
  m.set('aprilfools', {
    category: 'aprilfools',
    displayName: '愚人节版',
    blockMedia: $r('app.media.block_gold'),
    accentColor: '#CA8A04',                         // 金黄
    accentBg: '#FEF9C3',
  });
  m.set('old', {
    category: 'old',
    displayName: '远古版',
    blockMedia: $r('app.media.block_cobblestone'),
    accentColor: '#6B7280',                         // 圆石灰
    accentBg: '#F3F4F6',
  });
  // 'forge' / 'fabric' / ... 这些 VersionCategory 也合法，但不属于 vanilla
  // 子类。VersionBlockIcon 走 loader 分支前会先判断，这里不需要 entry。
  VANILLA_CAT_CACHE_ = m;
  return m;
}

// ============================================================================
//  公共 API
// ============================================================================

/**
 * 按 key 取 loader 信息。
 * 不存在的 key（理论上 LoaderKey 已穷举不会落空）兜底返回 vanilla。
 */
export function getLoaderInfo(key: LoaderKey): LoaderInfo {
  let table = ensureLoaderInfoTable_();
  let info = table.get(key);
  if (info !== undefined) return info;
  // 永远不会到这里（LoaderKey 是 union）；但 ArkTS 严格 null check 要 fallback
  return table.get('vanilla')!;
}

/**
 * 由 mc 版本 id 推断 loader key。
 *
 * 优先复用 detectLoaderFromId（已有 indexOf 'fabric' / 'forge' / 'neoforge' /
 * 'quilt' 的逻辑）；空字符串视为 vanilla。
 */
export function inferLoaderKey(versionId: string): LoaderKey {
  let raw = detectLoaderFromId(versionId);
  if (raw === 'fabric')   return 'fabric';
  if (raw === 'forge')    return 'forge';
  if (raw === 'neoforge') return 'neoforge';
  if (raw === 'quilt')    return 'quilt';
  return 'vanilla';
}

/** 推断 + 取信息一步到位（最常用入口） */
export function inferLoaderInfo(versionId: string): LoaderInfo {
  return getLoaderInfo(inferLoaderKey(versionId));
}

/** 把 detectLoaderFromId / resolveInstalledLoader 的原始 loader 字符串映射成 LoaderKey。 */
export function loaderKeyFromRaw(raw: string): LoaderKey {
  if (raw === 'fabric')   return 'fabric';
  if (raw === 'forge')    return 'forge';
  if (raw === 'neoforge') return 'neoforge';
  if (raw === 'quilt')    return 'quilt';
  return 'vanilla';
}

/**
 * 由【本地已装版本】推断 loader key —— 名字判不出(整合包/重命名版本)时回退读 version.json 内容。
 * 用于所有"本地选中版本"的 loader 显示/判定场景，取代纯名字的 inferLoaderKey。
 */
export function resolveInstalledLoaderKey(mcDir: string, versionId: string): LoaderKey {
  return loaderKeyFromRaw(resolveInstalledLoader(mcDir, versionId));
}

/** 由本地已装版本推断 + 取 LoaderInfo 一步到位（名字判不出时读 json 内容）。 */
export function resolveInstalledLoaderInfo(mcDir: string, versionId: string): LoaderInfo {
  return getLoaderInfo(resolveInstalledLoaderKey(mcDir, versionId));
}

/**
 * 取 vanilla 子类别信息。
 *
 * 当传入的 category 不是 vanilla 子类（比如 'fabric'）时返回 release 的兜底
 * 数据——调用方应当先用 classifyVersion 判断是否是 vanilla 再用这个 API。
 */
export function getVanillaCategoryInfo(cat: VersionCategory): VanillaCategoryInfo {
  let table = ensureVanillaCatTable_();
  let info = table.get(cat);
  if (info !== undefined) return info;
  return table.get('release')!;
}

/**
 * 已装版本徽章信息（VersionManagerSheet 行尾 chip / 类似 UI 用）。
 *
 * 与 manifest-style "正式版/快照/愚人节版/远古版" 的区别：
 *   - vanilla **release** 显示为 "原版"（沿用 LoaderInfo 文案，
 *     强调"无 loader"语义，避免与 Fabric/Forge 等 loader 一起列表时
 *     混入"正式版"这种与 release/snapshot 二分的 manifest 语义）。
 *   - vanilla **snapshot/aprilfools/old** 用 VanillaCategoryInfo 的
 *     "快照"/"愚人节版"/"远古版" 文案 + 配色（命令橙 / 金黄 / 圆石灰）。
 *   - 有 loader 直接走 LoaderInfo（"Fabric"/"Forge"/...）。
 */
export interface InstalledBadgeInfo {
  /** 文字标签 */
  displayName: string;
  /** chip 文字 / 主色 */
  accentColor: ResourceColor;
  /** chip 背景 */
  accentBg: ResourceColor;
}

/**
 * 由 versionId 推断已装版本徽章的统一显示数据。
 *
 * 决策路径：
 *   1. inferLoaderKey(versionId) ≠ vanilla → 取 LoaderInfo
 *   2. 否则按 classifyVersion 细化到 vanilla 子类：
 *      - release      → LoaderInfo('vanilla')（"原版" + 草绿）
 *      - snapshot     → VanillaCategoryInfo('snapshot')（"快照" + 命令橙）
 *      - aprilfools   → VanillaCategoryInfo('aprilfools')（"愚人节版" + 金黄）
 *      - old          → VanillaCategoryInfo('old')（"远古版" + 圆石灰）
 *
 * 这样 VersionManagerSheet 的右侧徽章对 "26.2-snapshot-8" 自动显示
 * "快照" + 命令橙，不再误显示成 "原版" + 草绿。
 */
export function getInstalledBadgeInfo(versionId: string): InstalledBadgeInfo {
  return badgeInfoForKey_(inferLoaderKey(versionId), versionId);
}

/** 同 getInstalledBadgeInfo，但 loader 走【已装版本内容判定】(整合包/重命名版本正确)。 */
export function getInstalledBadgeInfoResolved(mcDir: string, versionId: string): InstalledBadgeInfo {
  return badgeInfoForKey_(resolveInstalledLoaderKey(mcDir, versionId), versionId);
}

function badgeInfoForKey_(key: LoaderKey, versionId: string): InstalledBadgeInfo {
  if (key !== 'vanilla') {
    let info = getLoaderInfo(key);
    return {
      displayName: info.displayName,
      accentColor: info.accentColor,
      accentBg: info.accentBg,
    };
  }
  let cat = classifyVersion(versionId);
  if (cat === 'release') {
    let info = getLoaderInfo('vanilla');
    return {
      displayName: info.displayName,    // "原版"
      accentColor: info.accentColor,    // 草绿
      accentBg: info.accentBg,
    };
  }
  // snapshot / aprilfools / old
  let vinfo = getVanillaCategoryInfo(cat);
  return {
    displayName: vinfo.displayName,     // "快照" / "愚人节版" / "远古版"
    accentColor: vinfo.accentColor,
    accentBg: vinfo.accentBg,
  };
}

/**
 * 给 VersionBlockIcon 用的统一类别选择器：先判 vanilla 子类，再判 loader 类。
 *
 * 这个函数让 VersionBlockIcon 的 selectMedia 可以一行搞定，不需要再写 switch。
 */
export function getMediaForVersion(versionId: string, override: string): Resource {
  // 1) 显式 override 优先（对应 VersionBlockIcon 的 category prop）
  if (override.length > 0) {
    let asCat = override as VersionCategory;
    // 1a) loader 类
    if (asCat === 'fabric')   return getLoaderInfo('fabric').blockMedia;
    if (asCat === 'forge')    return getLoaderInfo('forge').blockMedia;
    if (asCat === 'neoforge') return getLoaderInfo('neoforge').blockMedia;
    if (asCat === 'quilt')    return getLoaderInfo('quilt').blockMedia;
    // 1b) vanilla 类
    if (asCat === 'release' || asCat === 'snapshot'
        || asCat === 'aprilfools' || asCat === 'old') {
      return getVanillaCategoryInfo(asCat).blockMedia;
    }
    // 非法 override 走 versionId 推断
  }

  // 2) versionId 推断
  let cat = classifyVersion(versionId);
  if (cat === 'fabric')   return getLoaderInfo('fabric').blockMedia;
  if (cat === 'forge')    return getLoaderInfo('forge').blockMedia;
  if (cat === 'neoforge') return getLoaderInfo('neoforge').blockMedia;
  if (cat === 'quilt')    return getLoaderInfo('quilt').blockMedia;
  return getVanillaCategoryInfo(cat).blockMedia;
}
