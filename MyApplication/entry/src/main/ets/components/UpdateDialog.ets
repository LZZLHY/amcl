/**
 * UpdateDialog.ets — 发现新版本弹窗（替代原来的系统 promptAction.showDialog）
 *
 * 为什么自绘：系统弹窗只能显示一段纯文本 message，无法分类、无法滚动、无法放入
 * 「查看完整更新日志」入口。数据侧已经把更新说明结构化了（update.json 的
 * `notesEntries`，见 AMCL-web/CHANGELOG-SPEC.md），UI 必须跟上才用得到。
 *
 * 数据来源：`UpdateChecker.displayEntries(manifest)` —— 优先结构化条目，
 * 拿不到时自动回退解析 `notes` 纯文本，所以本组件对新旧 update.json 都能渲染。
 *
 * 强制更新（`mandatory`）：隐藏「稍后再说」，只留一个全宽「立即更新」，并加一条红色横幅。
 *
 * 设计稿：Pencil `pencil-new.pen` 的「更新弹窗 · 浅色 / 深色 / 强制更新」三屏。
 *
 * 创建日期：2026-08-08
 */

import display from '@ohos.display';
import { ThemeColors } from 'commons';
import { AppIconName } from 'commons';
import { UpdateNoteEntry, noteTypeLabel } from 'update';
import { AppIcon } from './AppIcon';
import { changelogTone } from './SemanticColors';

/**
 * 条目列表的高度限位。
 *
 * 条目数量由发版者写的 notes / notesEntries 决定（1.0.2 就有 20 条），是弹窗里**唯一**
 * 会无界增长的部分，所以只限它、不限整个弹窗 —— 给弹窗根节点加 maxHeight 反而会把
 * 底部按钮裁掉。
 *
 * 上限按屏幕高度算而不是写死：弹窗其余部分（头部 51 + 对比条 35 + 说明头 18 + 分割线 1 +
 * 日志入口 27 + 按钮 46 + 五处 gap 66 + 上下 padding 36 ≈ 280，强制更新态再多一条横幅）
 * 约占 290vp，再给系统安全区留 15%，剩下的才给列表；最后夹到 [140, 360]，避免小屏塞不下、
 * 大屏又把弹窗拉成一长条。360vp 大约能一屏显示 12 条，20 条（1.0.2 的量）滚动两三下看完。
 */
const LIST_CHROME_VP: number = 290;
const LIST_MIN_HEIGHT: number = 140;
const LIST_MAX_HEIGHT: number = 360;
const LIST_FALLBACK_HEIGHT: number = 232;

function listMaxHeight(): number {
  try {
    // 不用 px2vp（已 deprecated，且 UIContext 版拿不到——这里是模块级函数）：
    // 直接用 display 的 densityPixels 把物理像素换算成 vp。
    let d = display.getDefaultDisplaySync();
    let density = d.densityPixels > 0 ? d.densityPixels : 1;
    let screenVp = d.height / density;
    if (!(screenVp > 0)) return LIST_FALLBACK_HEIGHT;
    let avail = screenVp * 0.85 - LIST_CHROME_VP;
    return Math.max(LIST_MIN_HEIGHT, Math.min(LIST_MAX_HEIGHT, avail));
  } catch (e) {
    // 取不到 display（极少见）时退回固定值，不能因为量不到屏幕就让弹窗无界增长
    return LIST_FALLBACK_HEIGHT;
  }
}

@CustomDialog
export struct UpdateDialog {
  // @CustomDialog 的编译期必需字段。部分设备运行时不会注入它，业务关闭不得依赖此值。
  controller?: CustomDialogController
  theme: ThemeColors = {} as ThemeColors

  /** 新版本号（如 1.0.2）；空串时退化显示 tag。 */
  newVersion: string = ''
  /** 设备当前版本号（APP_VERSION）。 */
  currentVersion: string = ''
  /** 发布日期 YYYY-MM-DD，可空。 */
  releaseDate: string = ''
  /** 预格式化的体积文案（如 "42.0 MB"），可空 —— 格式化由调用方做，弹窗不依赖 PathUtils。 */
  sizeLabel: string = ''
  /** 强制更新：去掉「稍后」，加红色横幅。 */
  mandatory: boolean = false
  /** 结构化更新说明。 */
  entries: UpdateNoteEntry[] = []
  /** 是否显示「查看完整更新日志」入口（上架轨等场景可关掉）。 */
  showChangelogEntry: boolean = true

  /** 条目列表高度上限（按屏幕算一次，build 内多处引用不重复取 display）。 */
  private listMaxHeight: number = listMaxHeight()

  onDownload: () => void = () => {}
  onLater: () => void = () => {}
  onViewChangelog: () => void = () => {}

  private headline_(): string {
    return this.mandatory ? '必须更新后继续使用' : '发现新版本'
  }

  private metaLine_(): string {
    let parts: string[] = []
    if (this.sizeLabel.length > 0) parts.push('约 ' + this.sizeLabel)
    if (this.releaseDate.length > 0) parts.push(this.releaseDate)
    return parts.join(' · ')
  }

  build() {
    Column({ space: 14 }) {
      // ===== 头部：图标 + 标题 + 版本药丸 =====
      Row({ space: 12 }) {
        Stack() {
          AppIcon({
            name: this.mandatory ? AppIconName.Warning : AppIconName.CloudDownload,
            iconSize: 23,
            color: this.mandatory ? this.theme.error : this.theme.primary,
          })
        }
        .width(44).height(44).borderRadius(22)
        .backgroundColor(this.mandatory ? this.theme.errorBg : this.theme.primaryLight)

        Column({ space: 3 }) {
          Text(this.headline_())
            .fontSize(19).fontWeight(700).fontColor(this.theme.textPrimary)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 6 }) {
            Text('v' + this.newVersion)
              .fontSize(11).fontWeight(600).fontColor(this.theme.textOnPrimary)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(5)
              .backgroundColor(this.mandatory ? this.theme.error : this.theme.primary)
            if (this.metaLine_().length > 0) {
              Text(this.metaLine_())
                .fontSize(11).fontColor(this.theme.textHint)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
          }
          .width('100%').alignItems(VerticalAlign.Center)
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1)
      }
      .width('100%').alignItems(VerticalAlign.Center)

      // ===== 版本对比条 =====
      Row() {
        Row({ space: 7 }) {
          Text('当前 v' + this.currentVersion)
            .fontSize(12).fontColor(this.theme.textSecondary)
          AppIcon({ name: AppIconName.ArrowRight, iconSize: 13, color: this.theme.textHint })
          Text('v' + this.newVersion)
            .fontSize(12).fontWeight(600)
            .fontColor(this.mandatory ? this.theme.error : this.theme.primary)
        }
        .alignItems(VerticalAlign.Center).layoutWeight(1)
        Text('GitHub 发布')
          .fontSize(11).fontColor(this.theme.textHint)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 9, bottom: 9 })
      .borderRadius(10)
      .backgroundColor(this.theme.bgInput)
      .alignItems(VerticalAlign.Center)

      // ===== 强制更新横幅 =====
      if (this.mandatory) {
        Row({ space: 7 }) {
          AppIcon({ name: AppIconName.Warning, iconSize: 14, color: this.theme.error })
          Text('当前版本已停止服务，请更新后再启动游戏')
            .fontSize(11).lineHeight(16).fontColor(this.theme.error)
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 9, bottom: 9 })
        .borderRadius(10)
        .backgroundColor(this.theme.errorBg)
        .alignItems(VerticalAlign.Center)
      }

      // ===== 更新内容 =====
      Column({ space: 10 }) {
        Row() {
          Text('更新内容')
            .fontSize(13).fontWeight(600).fontColor(this.theme.textPrimary)
            .layoutWeight(1)
          Text(`共 ${this.entries.length} 项`)
            .fontSize(11).fontColor(this.theme.textHint)
        }
        .width('100%').alignItems(VerticalAlign.Center)

        if (this.entries.length > 0) {
          Scroll() {
            Column({ space: 9 }) {
              ForEach(this.entries, (e: UpdateNoteEntry) => {
                Row({ space: 8 }) {
                  Text(noteTypeLabel(e.type))
                    .fontSize(11).fontWeight(600)
                    .fontColor(changelogTone(e.type, this.theme).color)
                    .padding({ left: 7, right: 7, top: 3, bottom: 3 })
                    .borderRadius(6)
                    .backgroundColor(changelogTone(e.type, this.theme).bg)
                  Text(e.text)
                    .fontSize(13).lineHeight(19.5).fontColor(this.theme.textSecondary)
                    .layoutWeight(1)
                }
                .width('100%').alignItems(VerticalAlign.Top)
              }, (e: UpdateNoteEntry, i: number) => i + ':' + e.text)
            }
            .width('100%')
          }
          .width('100%')
          // 限位：内容超过 maxHeight 时列表内部滚动，弹窗整体高度不再增长
          .constraintSize({ maxHeight: this.listMaxHeight })
          .scrollBar(BarState.Auto)
          .scrollBarWidth(3)
          .scrollBarColor(this.theme.divider)
          // Spring 回弹让"这里可以滑"这件事被用户感知到（None 会让人以为列表被截断了）
          .edgeEffect(EdgeEffect.Spring)
        } else {
          Text('有新版本可用，建议更新。')
            .fontSize(13).fontColor(this.theme.textSecondary).width('100%')
        }
      }
      .width('100%')

      // ===== 完整更新日志入口 =====
      if (this.showChangelogEntry) {
        Divider().color(this.theme.divider).strokeWidth(0.5)
        Row() {
          Row({ space: 7 }) {
            AppIcon({ name: AppIconName.History, iconSize: 15, color: this.theme.primary })
            Text('查看完整更新日志')
              .fontSize(13).fontWeight(500).fontColor(this.theme.primary)
          }
          .alignItems(VerticalAlign.Center).layoutWeight(1)
          AppIcon({ name: AppIconName.ChevronRight, iconSize: 15, color: this.theme.primary })
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          let callback: () => void = this.onViewChangelog
          callback()
        })
      }

      // ===== 按钮 =====
      Row({ space: 10 }) {
        if (!this.mandatory) {
          Button('稍后再说')
            .type(ButtonType.Normal).borderRadius(12)
            .layoutWeight(1).height(46)
            .fontSize(15).fontWeight(500)
            .backgroundColor(this.theme.bgInput)
            .fontColor(this.theme.textSecondary)
            .onClick(() => {
              let callback: () => void = this.onLater
              callback()
            })
        }
        Button() {
          Row({ space: 6 }) {
            AppIcon({ name: AppIconName.Download, iconSize: 16, color: this.theme.textOnPrimary })
            Text(this.mandatory ? '立即更新' : '前往下载')
              .fontSize(15).fontWeight(600).fontColor(this.theme.textOnPrimary)
          }
          .alignItems(VerticalAlign.Center)
        }
        .type(ButtonType.Normal).borderRadius(12)
        .layoutWeight(1).height(46)
        .backgroundColor(this.mandatory ? this.theme.error : this.theme.primary)
        .onClick(() => {
          let callback: () => void = this.onDownload
          callback()
        })
      }
      .width('100%')
    }
    // customStyle: true 时弹窗容器不做任何默认样式，宽度由本组件决定：
    // 手机 88% ≈ 316vp（对齐设计稿的 312），平板/2in1 用 maxWidth 收住不拉伸。
    .width('88%')
    .constraintSize({ maxWidth: 460 })
    .padding({ left: 20, right: 20, top: 20, bottom: 16 })
    .backgroundColor(this.theme.bgCard)
    .borderRadius(20)
  }
}
