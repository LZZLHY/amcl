/**
 * 已装资源惰性列表的单行视图。通过 ObjectLink 观察共享行属性，更新图标或进度时只刷新该行。
 * 实际磁盘操作与来源查询仍由 Sheet 编排；回调捕获资源身份，过滤后不使用数组下标执行操作。
 */
import { ThemeColors, AppIconName, formatBytes } from 'commons';
import { ModIntegrity, ResourceKind } from 'mods';
import { AppIcon } from './AppIcon';
import { RemoteImage } from './RemoteImage';
import { kindIcon } from './ResourceIcons';
import { InstalledResourceRow } from './InstalledResourceData';

@Component
export struct InstalledResourceItem {
  @ObjectLink row: InstalledResourceRow;
  @Prop theme: ThemeColors = {} as ThemeColors;
  @Prop kind: ResourceKind = ResourceKind.MOD;
  @Prop togglable: boolean = true;
  @Prop expanded: boolean = false;
  onExpand: () => void = () => {};
  onToggle: (enabled: boolean) => void = () => {};
  onDelete: () => void = () => {};
  onRepair: () => void = () => {};
  onUpdate: () => void = () => {};
  onRecheck: () => void = () => {};
  onIgnore: () => void = () => {};

  /** 展开能力直接读取 ObjectLink 状态，异步更新后无需父列表重新执行 builder。 */
  private isExpandable(): boolean {
    return this.row.updateState === 'outdated' || this.row.updateState === 'latest'
      || this.row.updateState === 'updating' || this.row.updateState === 'ignored'
      || this.row.integrity === ModIntegrity.CORRUPT;
  }

  build() {
    Column({ space: 0 }) {
      // ===== 主行（折叠态：保持原始紧凑样式）=====
      Row({ space: 10 }) {
        // 左：资源图标
        RemoteImage({
          url: this.row.iconUrl,
          diameter: 40,
          cornerRadius: 10,
          fallbackIcon: kindIcon(this.kind),
          fallbackBg: this.row.enabled ? this.theme.primaryLight : this.theme.bgInput,
          fallbackColor: this.row.enabled ? this.theme.primary : this.theme.textHint,
          fallbackIconSize: 20,
        })

        // 中：名字 + 状态/大小
        Column({ space: 4 }) {
          Text(this.row.displayName)
            .fontSize(14)
            .fontWeight(600)
            .fontColor(this.row.enabled ? this.theme.textPrimary : this.theme.textHint)
            .maxLines(2)
            // 默认 wordBreak 会在第一个连字符处就断行，导致第一行只剩 "fabric-" 一大截空白。
            // BREAK_ALL：按字符填满每一行再换行，长文件名两行都填满后才省略。
            .wordBreak(WordBreak.BREAK_ALL)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 6 }) {
            if (this.togglable) {
              Text(this.row.enabled ? '启用' : '禁用')
                .fontSize(10).fontWeight(700)
                .fontColor(this.row.enabled ? this.theme.success : this.theme.textHint)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(5)
                .backgroundColor(this.row.enabled ? this.theme.successBg : this.theme.bgInput)
            }
            Text(formatBytes(this.row.sizeBytes))
              .fontSize(11).fontWeight(500).fontColor(this.theme.textHint)
            // 完整性徽章（优先于更新状态显示）
            if (this.row.integrity === ModIntegrity.CORRUPT) {
              Text('已损坏')
                .fontSize(10).fontWeight(700)
                .fontColor(this.theme.error)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(5)
                .backgroundColor(this.theme.errorBg)
            } else if (this.row.integrity === ModIntegrity.UNKNOWN) {
              Text('未知来源')
                .fontSize(10).fontWeight(500).fontColor(this.theme.textHint)
            }
            // 折叠态更新状态：只显示极简标记（详细动作在展开区）
            if (this.row.updateState === 'outdated') {
              Text('可更新')
                .fontSize(10).fontWeight(700)
                .fontColor(this.theme.primary)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(5)
                .backgroundColor(this.theme.primaryLight)
            } else if (this.row.updateState === 'latest') {
              Text('已最新')
                .fontSize(10).fontWeight(600).fontColor(this.theme.textHint)
            } else if (this.row.updateState === 'updating') {
              Text('更新中 ' + this.row.updatingPct + '%')
                .fontSize(10).fontWeight(700)
                .fontColor(this.theme.primary)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(5)
                .backgroundColor(this.theme.primaryLight)
            } else if (this.row.updateState === 'checking') {
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
          if (this.isExpandable()) {
            Row() {
              AppIcon({
                name: this.expanded ? AppIconName.ChevronUp : AppIconName.ChevronDown,
                iconSize: 14,
                color: this.row.updateState === 'outdated' ? this.theme.primary : this.theme.textSecondary,
              })
            }
            .width(32).height(32).borderRadius(10)
            .backgroundColor(this.row.updateState === 'outdated' ? this.theme.primaryLight : this.theme.bgInput)
            .justifyContent(FlexAlign.Center)
            .onClick(() => { this.onExpand() })
          }

          if (this.togglable) {
            Toggle({ type: ToggleType.Switch, isOn: this.row.enabled })
              .selectedColor(this.theme.primary)
              .onChange((isOn: boolean) => { this.onToggle(isOn) })
          }

          Row() {
            AppIcon({ name: AppIconName.Trash, iconSize: 15, color: this.theme.error })
          }
          .width(36).height(36)
          .borderRadius(10)
          .backgroundColor(this.theme.errorBg)
          .justifyContent(FlexAlign.Center)
          .onClick(() => { this.onDelete() })
        }
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // ===== 展开态：更新动作区（拓宽卡片）=====
      if (this.expanded && this.isExpandable()) {
        Column({ space: 0 }) {
          Row().width('100%').height(1).backgroundColor(this.theme.divider)
            .margin({ top: 10, bottom: 10 })

          if (this.row.updateState === 'updating') {
            Column({ space: 6 }) {
              Row({ space: 8 }) {
                LoadingProgress().width(16).height(16).color(this.theme.primary)
                Text('正在更新到 ' + this.row.latestVersionNumber + '  ' + this.row.updatingPct + '%')
                  .fontSize(12).fontWeight(500).fontColor(this.theme.textSecondary)
                  .layoutWeight(1)
              }
              .width('100%').alignItems(VerticalAlign.Center)
              Progress({ value: this.row.updatingPct, total: 100, type: ProgressType.Linear })
                .color(this.theme.primary)
                .width('100%')
            }
            .width('100%')
          } else if (this.row.integrity === ModIntegrity.CORRUPT) {
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
              .onClick(() => { this.onRepair() })
            }
            .width('100%').alignItems(VerticalAlign.Center)
          } else if (this.row.updateState === 'outdated') {
            Text('可更新到 ' + this.row.latestVersionNumber)
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
              .onClick(() => { this.onUpdate() })
              // 检查更新
              Row({ space: 4 }) {
                AppIcon({ name: AppIconName.Refresh, iconSize: 13, color: this.theme.textSecondary })
                Text('检查更新').fontSize(12).fontWeight(600).fontColor(this.theme.textSecondary)
              }
              .height(32).padding({ left: 12, right: 12 }).borderRadius(16)
              .backgroundColor(this.theme.bgInput).alignItems(VerticalAlign.Center)
              .onClick(() => { this.onRecheck() })
              // 忽略
              Row({ space: 4 }) {
                AppIcon({ name: AppIconName.Close, iconSize: 13, color: this.theme.textSecondary })
                Text('忽略').fontSize(12).fontWeight(600).fontColor(this.theme.textSecondary)
              }
              .height(32).padding({ left: 12, right: 12 }).borderRadius(16)
              .backgroundColor(this.theme.bgInput).alignItems(VerticalAlign.Center)
              .onClick(() => { this.onIgnore() })
            }
            .width('100%').alignItems(VerticalAlign.Center)
          } else {
            // latest / ignored：已是最新或已忽略 → 仅提供「检查更新」
            Row({ space: 8 }) {
              Text(this.row.updateState === 'ignored' ? '已忽略此更新' : '已是最新版')
                .fontSize(12).fontWeight(500).fontColor(this.theme.textSecondary)
                .layoutWeight(1)
              Row({ space: 4 }) {
                AppIcon({ name: AppIconName.Refresh, iconSize: 13, color: this.theme.textSecondary })
                Text('检查更新').fontSize(12).fontWeight(600).fontColor(this.theme.textSecondary)
              }
              .height(32).padding({ left: 12, right: 12 }).borderRadius(16)
              .backgroundColor(this.theme.bgInput).alignItems(VerticalAlign.Center)
              .onClick(() => { this.onRecheck() })
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
}
