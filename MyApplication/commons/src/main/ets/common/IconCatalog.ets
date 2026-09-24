/**
 * IconCatalog.ets — AMCL 图标语义表
 *
 * 定位：
 *   全应用唯一的 emoji → 鸿蒙 SymbolGlyph 资源映射点。新增 / 替换图标都
 *   在这里改，不要在业务页面写裸 Resource。配合 AppIcon.ets 一起使用。
 *
 * 资源来源：
 *   HarmonyOS NEXT API 20 内置 HMSymbol 矢量字体（hm_symbol_config_next.json
 *   ~3800 个 symbol），通过 $r('sys.symbol.<name>') 引用，name 全部为小写
 *   下划线，风格类似 Apple SF Symbols（gearshape / chevron_down /
 *   magnifyingglass / hammer_fill ...）。所有 name 已在 SDK resources.txt
 *   中实测可解析；如某个 name 在更老 / 更新设备上缺失，回退逻辑见
 *   AppIcon.ets（用 fallbackEmoji 兜底）。
 *
 * 设计准则：
 *   1. 每个语义图标对应**唯一** AppIconName，业务侧只通过枚举访问
 *   2. 字符串 'sys.symbol.xxx' **只**在本文件出现，便于一处替换
 *   3. fallback 字符串保留原有 emoji，使设备不支持 SymbolGlyph 时仍可见
 *   4. 不在此文件做主题色 / 尺寸决策 —— 那是 AppIcon 的职责
 *
 * 加新图标：
 *   ① 在 AppIconName 加一个新成员
 *   ② 在 lookupIcon() 的 switch 加一行 { resource, fallback }
 *   ③ 业务侧 AppIcon({ name: AppIconName.Foo, ... })
 *
 * 关于 ArkTS 严格模式：
 *   ArkTS 不推荐用 Record<K,V> + 字符串索引访问（"object-literal-no-untyped-index"），
 *   所以这里用纯 enum + switch lookup，类型 100% 静态，没有动态属性访问。
 */

/** 语义图标名 —— 业务方唯一入口 */
export enum AppIconName {
  // ---- 通用导航 / 操作 ----
  Settings,
  SettingsFilled,
  Notification,
  Search,
  Close,
  CloseFilled,
  Back,
  ChevronDown,
  ChevronRight,
  ChevronUp,
  ChevronLeft,
  Plus,
  Minus,
  More,
  Edit,
  Trash,
  Copy,
  Share,
  Refresh,
  CheckCircle,
  Check,
  Warning,
  Error,
  Info,
  Help,
  ArrowDown,
  ArrowRight,
  ArrowUpRight,
  History,
  Filter,
  Sort,
  DragHandle,
  Eye,
  EyeSlash,
  Upload,
  Import,
  Export,

  // ---- AMCL 业务 ----
  AppLogo,
  Game,
  GameController,
  Loader,
  LoaderFabric,
  LoaderForge,
  LoaderNeoForge,
  LoaderQuilt,
  Mod,
  Shader,
  ResourcePack,
  ModPack,
  DataPack,
  Java,
  Memory,
  Language,
  IsolateOn,
  IsolateOff,
  Folder,
  Save,
  Document,
  ReleaseVersion,
  SnapshotVersion,
  LegacyVersion,

  // ---- 启动 / 状态 ----
  Play,
  Pause,
  Hourglass,
  Time,

  // ---- 下载 / 网络 ----
  Download,
  DownloadFilled,
  CloudDownload,
  CancelHistory,

  // ---- 反馈 / 占位 ----
  Construction,
  Celebrate,
  EmptySad,

  // ---- 用户 ----
  Person,

  // ---- 底部 dock 导航（FloatingDock 用） ----
  // 与已有 SettingsFilled / DownloadFilled 一起组成"首页 / 下载 / 设置"三 tab 的
  // 选中 / 未选中态。HMSymbol house 系列在 NEXT 上正常可用。
  Home,
  HomeFilled,

  // ---- 按键布局编辑器（2026-07-11，替代 emoji chip 图标；symbol 名已在 SDK id 表核验存在） ----
  Keyboard,      // 键位（改键）
  Trigger,       // 触发模式（按住/切换/双击/长按）
  Scene,         // 显示场景（游戏中/菜单/始终）
  Aim,           // 拖动瞄准
  Tag,           // 标签
  Appearance,    // 外观
  Lock,          // 锁定
  Unlock,        // 解锁
  Hotbar,        // 物品栏直点
  LayoutList,    // 方案列表
  Undo,          // 撤销

  // ---- AI（2026-07-30；symbol id 已在 SDK id_defined.json 核验存在） ----
  Ai,            // AI 智能分析（wand_and_stars_fill）
}

/** Catalog 行：sys.symbol Resource + fallback emoji */
export interface IconEntry {
  resource: Resource;
  fallback: string;
}

/**
 * 给定语义名取 catalog 行。switch 全静态，ArkTS 严格模式友好。
 *
 * 选名思路：
 *   - 优先选**填充态 (xxx_fill)** 用于按钮 / chip / 头部装饰，
 *     线条态 (xxx) 用于次要 / 列表项。
 *   - MC 专属概念（Forge / Fabric / Quilt）走 SF 同义图：
 *     hammer_fill / puzzle_fill / flame_fill / diamond 等。
 *
 * @returns 永远不会返回 undefined（所有 enum 成员都有分支）。
 */
export function lookupIcon(name: AppIconName): IconEntry {
  switch (name) {
    // ---- 通用 ----
    case AppIconName.Settings:        return { resource: $r('sys.symbol.gearshape'),                  fallback: '⚙' };
    case AppIconName.SettingsFilled:  return { resource: $r('sys.symbol.gearshape_fill'),             fallback: '⚙' };
    case AppIconName.Notification:    return { resource: $r('sys.symbol.bell'),                       fallback: '🔔' };
    case AppIconName.Search:          return { resource: $r('sys.symbol.magnifyingglass'),            fallback: '🔍' };
    case AppIconName.Close:           return { resource: $r('sys.symbol.xmark'),                      fallback: '✕' };
    case AppIconName.CloseFilled:     return { resource: $r('sys.symbol.xmark_circle_fill'),          fallback: '✕' };
    case AppIconName.Back:            return { resource: $r('sys.symbol.chevron_left'),               fallback: '‹' };
    case AppIconName.ChevronDown:     return { resource: $r('sys.symbol.chevron_down'),               fallback: '▾' };
    case AppIconName.ChevronUp:       return { resource: $r('sys.symbol.chevron_up'),                 fallback: '▴' };
    case AppIconName.ChevronLeft:     return { resource: $r('sys.symbol.chevron_left'),               fallback: '‹' };
    case AppIconName.ChevronRight:    return { resource: $r('sys.symbol.chevron_right'),              fallback: '›' };
    case AppIconName.Plus:            return { resource: $r('sys.symbol.plus'),                       fallback: '+' };
    case AppIconName.Minus:           return { resource: $r('sys.symbol.minus'),                      fallback: '−' };
    case AppIconName.More:            return { resource: $r('sys.symbol.more'),                       fallback: '⋯' };
    case AppIconName.Edit:            return { resource: $r('sys.symbol.square_and_pencil'),          fallback: '✎' };
    case AppIconName.Trash:           return { resource: $r('sys.symbol.trash'),                      fallback: '🗑' };
    case AppIconName.Copy:            return { resource: $r('sys.symbol.checkmark_square_on_square'), fallback: '⌘' };
    case AppIconName.Share:           return { resource: $r('sys.symbol.share'),                      fallback: '↗' };
    case AppIconName.Refresh:         return { resource: $r('sys.symbol.arrow_clockwise'),            fallback: '↻' };
    case AppIconName.CheckCircle:     return { resource: $r('sys.symbol.checkmark_circle_fill'),      fallback: '✅' };
    case AppIconName.Check:           return { resource: $r('sys.symbol.checkmark'),                  fallback: '✓' };
    case AppIconName.Warning:         return { resource: $r('sys.symbol.exclamationmark_triangle_fill'), fallback: '⚠' };
    case AppIconName.Error:           return { resource: $r('sys.symbol.exclamationmark_circle_fill'),   fallback: '✗' };
    case AppIconName.Info:            return { resource: $r('sys.symbol.info_circle'),                fallback: 'ℹ' };
    case AppIconName.Help:            return { resource: $r('sys.symbol.questionmark_circle'),        fallback: '?' };
    case AppIconName.ArrowDown:       return { resource: $r('sys.symbol.arrow_down'),                 fallback: '↓' };
    case AppIconName.ArrowRight:      return { resource: $r('sys.symbol.arrow_right'),                fallback: '→' };
    case AppIconName.ArrowUpRight:    return { resource: $r('sys.symbol.arrow_up_right'),             fallback: '↗' };
    case AppIconName.History:         return { resource: $r('sys.symbol.clock_arrow_2_circlepath'),   fallback: '⊗' };
    case AppIconName.Filter:          return { resource: $r('sys.symbol.line_3_horizontal'),          fallback: '⇅' };
    case AppIconName.Sort:            return { resource: $r('sys.symbol.sort'),                       fallback: '⇅' };
    case AppIconName.DragHandle:      return { resource: $r('sys.symbol.line_3_horizontal'),          fallback: '≡' };
    case AppIconName.Eye:             return { resource: $r('sys.symbol.eye'),                        fallback: '👁' };
    case AppIconName.EyeSlash:        return { resource: $r('sys.symbol.eye_slash'),                  fallback: '⃠' };
    case AppIconName.Upload:          return { resource: $r('sys.symbol.arrow_up_circle'),            fallback: '↥' };
    case AppIconName.Import:          return { resource: $r('sys.symbol.arrow_down_circle'),          fallback: '⤓' };
    case AppIconName.Export:          return { resource: $r('sys.symbol.arrow_up_circle'),            fallback: '⤒' };

    // ---- AMCL 业务 ----
    // AppLogo —— ⛏ 矿镐：HMSymbol 有 hammer_fill，SDK 没有 pickaxe；
    // 用 hammer_fill 占位，UI 上叠一个圆角蓝底框，整体仍是 AMCL logo。
    case AppIconName.AppLogo:         return { resource: $r('sys.symbol.hammer_fill'),                fallback: '⛏' };
    case AppIconName.Game:            return { resource: $r('sys.symbol.gamecontroller_fill'),        fallback: '🎮' };
    case AppIconName.GameController:  return { resource: $r('sys.symbol.gamecontroller'),             fallback: '🎮' };
    case AppIconName.Loader:          return { resource: $r('sys.symbol.puzzle_fill'),                fallback: '🧩' };
    case AppIconName.LoaderFabric:    return { resource: $r('sys.symbol.puzzle_fill'),                fallback: '🧩' };
    case AppIconName.LoaderForge:     return { resource: $r('sys.symbol.hammer_fill'),                fallback: '⚒' };
    case AppIconName.LoaderNeoForge:  return { resource: $r('sys.symbol.flame_fill'),                 fallback: '🔥' };
    case AppIconName.LoaderQuilt:     return { resource: $r('sys.symbol.diamond'),                    fallback: '🧶' };
    case AppIconName.Mod:             return { resource: $r('sys.symbol.puzzle_fill'),                fallback: '🧩' };
    case AppIconName.Shader:          return { resource: $r('sys.symbol.wand_and_stars'),             fallback: '✨' };
    case AppIconName.ResourcePack:    return { resource: $r('sys.symbol.paintpalette_fill'),          fallback: '🎨' };
    case AppIconName.ModPack:         return { resource: $r('sys.symbol.briefcase_fill'),             fallback: '🧳' };
    case AppIconName.DataPack:        return { resource: $r('sys.symbol.archivebox_fill'),            fallback: '📦' };
    case AppIconName.Java:            return { resource: $r('sys.symbol.cup_fill'),                   fallback: '☕' };
    case AppIconName.Memory:          return { resource: $r('sys.symbol.memory_module'),              fallback: '🧠' };
    case AppIconName.Language:        return { resource: $r('sys.symbol.textformat'),                fallback: '🌐' };
    case AppIconName.IsolateOn:       return { resource: $r('sys.symbol.checkmark_square_fill'),      fallback: '▣' };
    case AppIconName.IsolateOff:      return { resource: $r('sys.symbol.square'),                     fallback: '▢' };
    case AppIconName.Folder:          return { resource: $r('sys.symbol.folder_fill'),                fallback: '📁' };
    case AppIconName.Document:        return { resource: $r('sys.symbol.doc_text'),                   fallback: '📄' };
    case AppIconName.Save:            return { resource: $r('sys.symbol.externaldrive_fill'),         fallback: '💾' };
    case AppIconName.ReleaseVersion:  return { resource: $r('sys.symbol.archivebox_fill'),            fallback: '📦' };
    case AppIconName.SnapshotVersion: return { resource: $r('sys.symbol.code_lab'),                   fallback: '🧪' };
    case AppIconName.LegacyVersion:   return { resource: $r('sys.symbol.book_pages_fill'),            fallback: '📜' };

    // ---- 启动 / 状态 ----
    case AppIconName.Play:            return { resource: $r('sys.symbol.play_fill'),                  fallback: '▶' };
    case AppIconName.Pause:           return { resource: $r('sys.symbol.pause_fill'),                 fallback: '⏸' };
    case AppIconName.Hourglass:       return { resource: $r('sys.symbol.hourglass'),                  fallback: '⏳' };
    case AppIconName.Time:            return { resource: $r('sys.symbol.clock'),                      fallback: '⏱' };

    // ---- 下载 / 网络 ----
    case AppIconName.Download:        return { resource: $r('sys.symbol.download'),                   fallback: '📥' };
    case AppIconName.DownloadFilled:  return { resource: $r('sys.symbol.download_fill'),              fallback: '📥' };
    case AppIconName.CloudDownload:   return { resource: $r('sys.symbol.cloud_and_arrow_down'),       fallback: '⤓' };
    case AppIconName.CancelHistory:   return { resource: $r('sys.symbol.clock_arrow_2_circlepath'),   fallback: '⊗' };

    // ---- 反馈 / 占位 ----
    case AppIconName.Construction:    return { resource: $r('sys.symbol.exclamationmark_triangle'),   fallback: '🚧' };
    case AppIconName.Celebrate:       return { resource: $r('sys.symbol.firework'),                   fallback: '🎉' };
    case AppIconName.EmptySad:        return { resource: $r('sys.symbol.face_smiling'),               fallback: '😢' };

    // ---- 用户 ----
    case AppIconName.Person:          return { resource: $r('sys.symbol.person'),                     fallback: '👤' };

    // ---- 底部 dock 导航 ----
    case AppIconName.Home:            return { resource: $r('sys.symbol.house'),                      fallback: '🏠' };
    case AppIconName.HomeFilled:      return { resource: $r('sys.symbol.house_fill'),                 fallback: '🏠' };

    // ---- 按键布局编辑器 ----
    case AppIconName.Keyboard:        return { resource: $r('sys.symbol.keyboard'),                   fallback: '⌨' };
    case AppIconName.Trigger:         return { resource: $r('sys.symbol.hand_tap'),                   fallback: '👆' };
    case AppIconName.Scene:           return { resource: $r('sys.symbol.rectangle_stack'),            fallback: '🎬' };
    case AppIconName.Aim:             return { resource: $r('sys.symbol.scope'),                      fallback: '🎯' };
    case AppIconName.Tag:             return { resource: $r('sys.symbol.textformat'),                 fallback: '🏷' };
    case AppIconName.Appearance:      return { resource: $r('sys.symbol.paintpalette_fill'),          fallback: '🎨' };
    case AppIconName.Lock:            return { resource: $r('sys.symbol.lock'),                       fallback: '🔒' };
    case AppIconName.Unlock:          return { resource: $r('sys.symbol.lock_open'),                  fallback: '🔓' };
    case AppIconName.Hotbar:          return { resource: $r('sys.symbol.bag_fill'),                   fallback: '🎒' };
    case AppIconName.LayoutList:      return { resource: $r('sys.symbol.list_bullet'),                fallback: '📋' };
    case AppIconName.Undo:            return { resource: $r('sys.symbol.arrowshape_turn_up_left'),     fallback: '↶' };

    // ---- AI ----
    case AppIconName.Ai:              return { resource: $r('sys.symbol.wand_and_stars_fill'),        fallback: '✨' };

    // 防御性 default：理论上 enum 全枚举完不会到这里。
    // 部分 ArkTS 严格模式分析器要求所有 switch-return 函数都有 default 分支。
    default:                          return { resource: $r('sys.symbol.questionmark_circle'),        fallback: '⛔' };
  }
}
