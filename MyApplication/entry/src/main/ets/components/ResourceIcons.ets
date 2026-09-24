/**
 * ResourceIcons.ets — 资源 / 任务类别 → AppIconName 集中映射（2026-05-22）
 *
 * 历史问题：相同语义的 switch 散落在多个 UI 文件里：
 *   - ModCard.kindIcon(ResourceKind)               ← 已 export
 *   - InstalledResourcesSheet.kindIcon()           ← 私有重复（同 ResourceKind）
 *   - TaskCard.categoryIcon()                      ← 私有，输入 TaskCategory
 *
 * 改动：抽到 common/ 里两个纯函数，所有 UI 组件统一引用本文件。
 *   - kindIcon(kind)             —— 模组 / 光影 / 资源包 / 数据包 / 整合包
 *   - taskCategoryIcon(cat)      —— 上面五类 + MC_VERSION（默认）+ JDK
 *
 * 为什么不把两个枚举合并：
 *   ResourceKind 只关心"可安装资源"，TaskCategory 还有 MC_VERSION / JDK
 *   语义不同，强行合并会污染调用方的类型检查。
 *
 * 注：MC_VERSION 任务的左侧大徽章在 TaskCard 里另走 VersionBlockIcon（PNG 方块），
 * 这里只给 AppIcon 兜底（按 sys.symbol.hammer_fill 显示 AppLogo）。
 */

import { AppIconName } from 'commons';
import { ResourceKind } from 'mods';
import { TaskCategory } from 'feature_core';

/**
 * 资源类别 → AppIconName。
 *
 * 卡片图标 / 列表 chip 等 UI 入口走这个。
 * 历史等价物：ModCard.kindIcon（保留 re-export 用于兼容旧 import 路径）。
 */
export function kindIcon(kind: ResourceKind): AppIconName {
  switch (kind) {
    case ResourceKind.MOD:           return AppIconName.Mod;
    case ResourceKind.RESOURCE_PACK: return AppIconName.ResourcePack;
    case ResourceKind.SHADER:        return AppIconName.Shader;
    case ResourceKind.DATAPACK:      return AppIconName.DataPack;
    case ResourceKind.MODPACK:       return AppIconName.ModPack;
    default:                         return AppIconName.Help;
  }
}

/**
 * 下载任务类别 → AppIconName（用于 TaskCard 左侧 44x44 徽章兜底）。
 *
 * MC_VERSION 在 TaskCard 里实际优先走 VersionBlockIcon（按 view.title 推断 PNG 方块），
 * 只有未传 title 等极少数情况才回退到 AppIcon → AppLogo。
 */
export function taskCategoryIcon(cat: TaskCategory): AppIconName {
  switch (cat) {
    case TaskCategory.MC_VERSION:    return AppIconName.AppLogo;
    case TaskCategory.MOD:           return AppIconName.Mod;
    case TaskCategory.SHADER:        return AppIconName.Shader;
    case TaskCategory.RESOURCE_PACK: return AppIconName.ResourcePack;
    case TaskCategory.DATAPACK:      return AppIconName.DataPack;
    case TaskCategory.MODPACK:       return AppIconName.ModPack;
    case TaskCategory.JDK:           return AppIconName.Java;
    default:                         return AppIconName.Download;
  }
}
