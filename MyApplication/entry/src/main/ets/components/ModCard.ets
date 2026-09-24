/**
 * ModCard.ets — 单模组卡片（P1-MODS Phase 1.6）
 *
 * 样式参考 DownloadTab.VersionItem；鸿蒙风格：圆角 + 阴影 + 单行紧凑布局。
 *
 * 图标策略：
 *   - 卡片主图标 / 元信息图标（作者 / 下载量 / loader）走原生 SymbolGlyph
 *   - kindEmoji() 保留为纯函数 API（被测试与历史代码引用），返回 emoji
 *     供需要纯字符串展示的场景（如 toast 文案、日志）继续使用。
 *
 * 创建日期：2026-05-11
 */

import { ThemeColors } from 'commons';
import { RemoteProject, ModSource, ResourceKind, displayTitleOf } from 'mods';
import { AppIconName } from 'commons';
import { AppIcon } from './AppIcon';
import { RemoteImage } from './RemoteImage';
// 2026-05-22：kindIcon 已迁出到 components/ResourceIcons.ets 供多组件共用；
// 这里 re-export 保留旧 import 路径兼容性，外部代码可继续 `import { kindIcon } from './ModCard'`。
import { kindIcon } from '../components/ResourceIcons';
export { kindIcon };

/** 把 downloads 数字紧凑格式化：`12345 → 12.3k`，`1234567 → 1.2M`。 */
export function formatDownloadCount(n: number): string {
  if (n < 0) return '-';
  if (n < 1000) return n.toString();
  if (n < 1_000_000) return (n / 1000).toFixed(1) + 'k';
  if (n < 1_000_000_000) return (n / 1_000_000).toFixed(1) + 'M';
  return (n / 1_000_000_000).toFixed(1) + 'B';
}

/**
 * 类别 → emoji 字符串。仅用于无法渲染 SymbolGlyph 的纯文本场景（toast / 日志），
 * UI 卡片请用 kindIcon()。保留是为了不破坏 src/test/ModCard.test.ets。
 */
export function kindEmoji(kind: ResourceKind): string {
  switch (kind) {
    case ResourceKind.MOD:           return '🧩';
    case ResourceKind.RESOURCE_PACK: return '🎨';
    case ResourceKind.SHADER:        return '🌈';
    case ResourceKind.DATAPACK:      return '📦';
    case ResourceKind.MODPACK:       return '🧳';
    default:                         return '❓';
  }
}

/** 源标签：modrinth → "Modrinth"；curseforge → "CurseForge" */
export function sourceLabel(source: ModSource): string {
  switch (source) {
    case ModSource.MODRINTH:   return 'Modrinth';
    case ModSource.CURSEFORGE: return 'CurseForge';
    default:                   return '';
  }
}

/** 源的元信息文案：双源时显示 "Modrinth + CurseForge"，否则单源。 */
export function sourceMetaText(p: RemoteProject): string {
  let main = sourceLabel(p.source);
  if (p.altSource !== undefined && p.altSource !== p.source) {
    return main + ' + ' + sourceLabel(p.altSource);
  }
  return main;
}

@Component
export struct ModCard {
  @Prop theme: ThemeColors = {} as ThemeColors;
  @Prop project: RemoteProject = {} as RemoteProject;
  @Prop compact: boolean = false;

  /** 点击卡片回调（由 ModBrowsePage 传入，通常弹详情 sheet） */
  onTap: (project: RemoteProject) => void = () => {};
  /** "快速安装"回调（可选，列表 V1 阶段直接触发） */
  onQuickInstall: (project: RemoteProject) => void = () => {};

  build() {
    Row() {
      // 图标位（远程 iconUrl，失败回退到 kindIcon）
      RemoteImage({
        url: this.project.iconUrl,
        diameter: 44,
        fallbackIcon: kindIcon(this.project.kind),
        fallbackBg: this.theme.bgInput,
        fallbackColor: this.theme.textSecondary,
      })

      Column() {
        Row() {
          Text(displayTitleOf(this.project))
            .fontSize(15)
            .fontWeight(500)
            .fontColor(this.theme.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')

        Text(this.project.summary)
          .fontSize(12)
          .fontColor(this.theme.textSecondary)
          .maxLines(this.compact ? 1 : 2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 })
          .width('100%')

        Row({ space: 10 }) {
          // 源（Modrinth / CurseForge / 双源）
          Row({ space: 4 }) {
            Text('●').fontSize(8).fontColor(this.theme.textHint)
            Text(sourceMetaText(this.project))
              .fontSize(11)
              .fontColor(this.theme.textHint)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(VerticalAlign.Center)
          // 作者
          if (this.project.author.length > 0) {
            Row({ space: 4 }) {
              AppIcon({ name: AppIconName.Person, iconSize: 11, color: this.theme.textHint })
              Text(this.project.author)
                .fontSize(11)
                .fontColor(this.theme.textHint)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .alignItems(VerticalAlign.Center)
          }
          // 下载量
          Row({ space: 4 }) {
            AppIcon({ name: AppIconName.Download, iconSize: 11, color: this.theme.textHint })
            Text(formatDownloadCount(this.project.downloads))
              .fontSize(11)
              .fontColor(this.theme.textHint)
          }
          .alignItems(VerticalAlign.Center)
          // loader 标签（仅 mod 有）
          if (this.project.loaders.length > 0) {
            Row({ space: 4 }) {
              AppIcon({ name: AppIconName.Loader, iconSize: 11, color: this.theme.textHint })
              Text(this.project.loaders.join('/'))
                .fontSize(11)
                .fontColor(this.theme.textHint)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .alignItems(VerticalAlign.Center)
          }
        }
        .width('100%')
        .margin({ top: 6 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor(this.theme.bgCard)
    .borderRadius(this.theme.cardRadius)
    .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
    .onClick(() => { this.onTap(this.project); })
  }
}
