import { DistributionPolicy } from 'commons';
/**
 * ChangelogPage.ets — 更新日志页
 *
 * 入口：关于页「更新日志」行、更新弹窗的「查看完整更新日志」。
 *
 * 数据：`ChangelogService`（update HAR）——内存 → 磁盘缓存 → 随包 rawfile 快照，
 * 后台带 ETag 拉一次远程，有新内容经 `onChangelogUpdated` 通知本页重刷。
 * 事实源与网页 /changelog、GitHub Release Note 同一份，见 AMCL-web/CHANGELOG-SPEC.md。
 *
 * 上架轨（DeviceProfile.isStoreTrack）：ChangelogService 不发任何请求，本页只读随包快照，
 * 并隐藏「在浏览器打开」与「前往下载」（更新由应用市场负责）。
 *
 * 主题 / 安全区 / 返回导航沿用其它 push 页（AboutPage / DownloadHistoryPage）的约定。
 *
 * 设计稿：Pencil `pencil-new.pen` 的「更新日志页 · 浅色 / 深色 / 有新版本」三屏。
 *
 * 创建日期：2026-08-08
 */

import { common, ConfigurationConstant, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ThemeColors, ThemeMode, resolveTheme, resolveIsDark } from 'commons';
import { APP_VERSION, APP_REPO_URL, CHANGELOG_PAGE_URL } from 'commons';
import { DeviceProfile } from 'commons';
import { AppIconName } from 'commons';
import { AppIcon } from '../components/AppIcon';
import { changelogTone } from '../components/SemanticColors';
import { PreferenceManager } from 'feature_system';
import {
  ChangelogService, ChangelogSnapshot, ChangelogRelease, ChangelogEntry,
  UpdateChecker, noteTypeLabel, noteTypeRank,
  onChangelogUpdated, offChangelogUpdated,
} from 'update';

const TAG = 'ChangelogPage'

/** 筛选项：'' 表示全部。 */
interface FilterChip {
  type: string;
  label: string;
}

@Entry
@Component
struct ChangelogPage {
  @State theme: ThemeColors = resolveTheme(ThemeMode.SYSTEM, false)
  @StorageProp('topRectHeight') topSafeHeight: number = 0
  @StorageProp('bottomRectHeight') bottomSafeHeight: number = 0
  @StorageProp('currentColorMode') @Watch('onColorModeChange') currentColorMode: number = 0

  @State private loading: boolean = true
  @State private releases: ChangelogRelease[] = []
  @State private source: string = ''
  @State private filter: string = ''
  @State private chips: FilterChip[] = []
  /** 已装 versionCode，用于「已是最新 / 有新版本」判定。 */
  @State private currentCode: number = 0

  private context: common.UIAbilityContext = AppStorage.get<common.UIAbilityContext>('uiAbilityContext')!
  private prefManager: PreferenceManager = new PreferenceManager(this.context)
  private storeTrack: boolean = DistributionPolicy.isStore()
  private onUpdated_: () => void = () => { this.reloadFromCache_() }

  aboutToAppear() {
    this.applyTheme_()
    this.currentCode = UpdateChecker.currentVersionCode()
    onChangelogUpdated(this.onUpdated_)
    this.load_()
  }

  aboutToDisappear() {
    offChangelogUpdated(this.onUpdated_)
  }

  private applyTheme_(): void {
    let systemIsDark = (this.currentColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK)
    let mode = this.prefManager.themeMode
    this.theme = resolveTheme(mode, resolveIsDark(mode, systemIsDark))
  }

  onColorModeChange(): void {
    this.applyTheme_()
  }

  private async load_(): Promise<void> {
    let snapshot: ChangelogSnapshot = await ChangelogService.load()
    this.apply_(snapshot)
    this.loading = false
  }

  /** 后台远程刷新拿到新内容后重刷（ChangelogService 已把新快照放进进程内缓存）。 */
  private reloadFromCache_(): void {
    let snapshot = ChangelogService.peek()
    if (snapshot !== null) this.apply_(snapshot)
  }

  private apply_(snapshot: ChangelogSnapshot): void {
    this.releases = snapshot.releases
    this.source = snapshot.source
    this.chips = this.buildChips_(snapshot.releases)
    // 当前筛选在新数据里不存在了 → 回到全部，避免空白页
    if (this.filter.length > 0 && !this.chips.some((c: FilterChip) => c.type === this.filter)) {
      this.filter = ''
    }
  }

  /** 只为**实际出现过**的分类生成筛选 chip（避免出现点了永远空的分类）。 */
  private buildChips_(releases: ChangelogRelease[]): FilterChip[] {
    let present: string[] = []
    for (let r of releases) {
      for (let e of r.entries) {
        if (present.indexOf(e.type) < 0) present.push(e.type)
      }
    }
    present.sort((a: string, b: string) => noteTypeRank(a) - noteTypeRank(b))
    let out: FilterChip[] = [{ type: '', label: '全部' }]
    for (let t of present) out.push({ type: t, label: noteTypeLabel(t) })
    return out
  }

  private entriesOf_(release: ChangelogRelease): ChangelogEntry[] {
    if (this.filter.length === 0) return release.entries
    return release.entries.filter((e: ChangelogEntry) => e.type === this.filter)
  }

  private visibleReleases_(): ChangelogRelease[] {
    if (this.filter.length === 0) return this.releases
    return this.releases.filter((r: ChangelogRelease) => this.entriesOf_(r).length > 0)
  }

  private latestRelease_(): ChangelogRelease | null {
    return this.releases.length > 0 ? this.releases[0] : null
  }

  private latestVersionName_(): string {
    let latest = this.latestRelease_()
    return latest !== null ? latest.versionName : ''
  }

  private hasUpdate_(): boolean {
    let latest = this.latestRelease_()
    if (latest === null || this.currentCode <= 0) return false
    return latest.versionCode > this.currentCode
  }

  private safeToast_(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 })
    } catch (e) { /* UI 实例已销毁，忽略 */ }
  }

  private openUrl_(url: string): void {
    try {
      let want: Want = {
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: url,
      }
      this.context.startAbility(want)
    } catch (e) {
      hilog.error(0x0000, TAG, 'openUrl failed: %{public}s', (e as Error).message)
      this.safeToast_('无法打开浏览器，请手动访问 ' + url)
    }
  }

  /** 数据来源说明：让「为什么没有最新版本」可自证，而不是让用户猜。 */
  private sourceLabel_(): string {
    if (this.storeTrack) return '随包数据'
    if (this.source === 'remote') return '已同步最新'
    if (this.source === 'cache') return '本地缓存'
    if (this.source === 'bundled') return '随包数据'
    return ''
  }

  build() {
    Column() {
      // ===== 顶栏 =====
      Row() {
        Stack() {
          AppIcon({ name: AppIconName.Back, iconSize: 20, color: this.theme.textPrimary })
        }
        .width(40).height(40).borderRadius(20)
        .backgroundColor(this.theme.bgCard)
        .onClick(() => { this.getUIContext().getRouter().back() })

        Text('更新日志')
          .fontSize(20).fontWeight(700).fontColor(this.theme.textPrimary)
          .margin({ left: 12 }).layoutWeight(1)

        if (!this.storeTrack) {
          Stack() {
            AppIcon({ name: AppIconName.ArrowUpRight, iconSize: 18, color: this.theme.primary })
          }
          .width(40).height(40).borderRadius(20)
          .backgroundColor(this.theme.bgCard)
          .onClick(() => { this.openUrl_(CHANGELOG_PAGE_URL) })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topSafeHeight + 12, bottom: 10 })
      .alignItems(VerticalAlign.Center)

      if (this.loading) {
        Column({ space: 12 }) {
          LoadingProgress().width(40).height(40).color(this.theme.primary)
          Text('正在读取更新日志…').fontSize(13).fontColor(this.theme.textHint)
        }
        .width('100%').layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.releases.length === 0) {
        this.EmptyState()
      } else {
        Scroll() {
          Column({ space: 14 }) {
            this.CurrentVersionCard()
            this.FilterChips()
            ForEach(this.visibleReleases_(), (r: ChangelogRelease) => {
              this.ReleaseCard(r)
            }, (r: ChangelogRelease) => r.tag + ':' + this.filter)
            Text('仅展示面向用户的变更 · 完整开发日志见 GitHub 仓库'
              + (this.sourceLabel_().length > 0 ? ' · ' + this.sourceLabel_() : ''))
              .fontSize(11).fontColor(this.theme.textHint)
              .textAlign(TextAlign.Center).width('100%')
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: Math.max(24, this.bottomSafeHeight + 16) })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.bgPrimary)
  }

  @Builder
  EmptyState() {
    Column({ space: 14 }) {
      AppIcon({ name: AppIconName.EmptySad, iconSize: 48, color: this.theme.textHint })
      Text('暂无更新日志')
        .fontSize(16).fontWeight(600).fontColor(this.theme.textPrimary)
      Text(this.storeTrack
        ? '本版本未随包提供更新日志数据。'
        : '还没有取到更新日志数据，可能是网络暂时不可用。')
        .fontSize(13).fontColor(this.theme.textSecondary)
        .textAlign(TextAlign.Center)
      if (!this.storeTrack) {
        Button('去 GitHub 查看')
          .type(ButtonType.Capsule).height(42)
          .fontSize(14).fontWeight(600)
          .backgroundColor(this.theme.primary).fontColor(this.theme.textOnPrimary)
          .onClick(() => { this.openUrl_(APP_REPO_URL + '/releases') })
      }
    }
    .width('100%').layoutWeight(1)
    .padding({ left: 32, right: 32 })
    .justifyContent(FlexAlign.Center)
  }

  /** 当前版本卡：已是最新 / 有新版本两态。 */
  @Builder
  CurrentVersionCard() {
    Row({ space: 12 }) {
      Stack() {
        Image($r('app.media.amcl_axe'))
          .width(30).height(30).draggable(false)
      }
      .width(46).height(46).borderRadius(12)
      .backgroundColor(this.theme.primaryLight)

      Column({ space: 3 }) {
        Text('AMCL')
          .fontSize(16).fontWeight(700).fontColor(this.theme.textPrimary)
        Text(this.hasUpdate_()
          ? `当前 v${APP_VERSION} → 最新 v${this.latestVersionName_()}`
          : `当前 v${APP_VERSION} · 构建 ${this.currentCode}`)
          .fontSize(12).fontColor(this.theme.textHint)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)

      if (this.hasUpdate_() && !this.storeTrack) {
        Button() {
          Row({ space: 5 }) {
            AppIcon({ name: AppIconName.Download, iconSize: 13, color: this.theme.textOnPrimary })
            Text('更新').fontSize(12).fontWeight(600).fontColor(this.theme.textOnPrimary)
          }
          .alignItems(VerticalAlign.Center)
        }
        .type(ButtonType.Normal).borderRadius(9)
        .height(32).padding({ left: 12, right: 12 })
        .backgroundColor(this.theme.primary)
        .onClick(() => {
          let latest = this.latestRelease_()
          this.openUrl_(latest !== null && latest.url.length > 0 ? latest.url : APP_REPO_URL + '/releases/latest')
        })
      } else {
        Row({ space: 4 }) {
          AppIcon({ name: AppIconName.Check, iconSize: 12, color: this.theme.success })
          Text(this.hasUpdate_() ? '有新版本' : '已是最新')
            .fontSize(11).fontWeight(600).fontColor(this.theme.success)
        }
        .padding({ left: 9, right: 9, top: 4, bottom: 4 })
        .borderRadius(7)
        .backgroundColor(this.theme.successBg)
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.theme.bgCard)
    .borderRadius(this.theme.cardRadius)
    .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  FilterChips() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.chips, (c: FilterChip) => {
          Text(c.label)
            .fontSize(12)
            .fontWeight(this.filter === c.type ? 600 : 400)
            .fontColor(this.filter === c.type ? this.theme.textOnPrimary : this.theme.textSecondary)
            .padding({ left: 13, right: 13, top: 6, bottom: 6 })
            .borderRadius(9)
            .backgroundColor(this.filter === c.type ? this.theme.primary : this.theme.bgCard)
            .onClick(() => { this.filter = c.type })
        }, (c: FilterChip) => c.type)
      }
      .padding({ right: 4 })
    }
    .width('100%')
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .align(Alignment.Start)
  }

  @Builder
  ReleaseCard(r: ChangelogRelease) {
    Column() {
      // 卡头：版本号 + 徽章 + 日期
      Row() {
        Row({ space: 8 }) {
          Text(r.versionName)
            .fontSize(17).fontWeight(700).fontColor(this.theme.textPrimary)
          if (this.isLatest_(r)) {
            Text(this.hasUpdate_() ? '可更新' : '最新')
              .fontSize(10).fontWeight(600).fontColor(this.theme.textOnPrimary)
              .padding({ left: 7, right: 7, top: 2, bottom: 2 })
              .borderRadius(6)
              .backgroundColor(this.theme.primary)
          } else if (r.versionCode === this.currentCode) {
            Text('当前')
              .fontSize(10).fontWeight(600).fontColor(this.theme.textSecondary)
              .padding({ left: 7, right: 7, top: 2, bottom: 2 })
              .borderRadius(6)
              .backgroundColor(this.theme.bgInput)
          } else if (r.prerelease) {
            Text('预览')
              .fontSize(10).fontWeight(600).fontColor(this.theme.textHint)
              .padding({ left: 7, right: 7, top: 2, bottom: 2 })
              .borderRadius(6)
              .backgroundColor(this.theme.bgInput)
          }
        }
        .alignItems(VerticalAlign.Center).layoutWeight(1)
        Text(r.date)
          .fontSize(11).fontColor(this.theme.textHint)
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 13, bottom: 13 })
      .backgroundColor(this.isLatest_(r) ? this.theme.primaryLight : Color.Transparent)
      .alignItems(VerticalAlign.Center)

      Divider().color(this.theme.divider).strokeWidth(0.5)

      Column({ space: 10 }) {
        if (r.title.length > 0 && this.filter.length === 0) {
          Text(r.title)
            .fontSize(13).fontWeight(600).fontColor(this.theme.textPrimary)
            .width('100%')
        }
        ForEach(this.entriesOf_(r), (e: ChangelogEntry) => {
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
        }, (e: ChangelogEntry, i: number) => r.tag + ':' + i + ':' + e.text)
      }
      .width('100%')
      .padding(14)
    }
    .width('100%')
    .clip(true)
    .backgroundColor(this.theme.bgCard)
    .borderRadius(this.theme.cardRadius)
    .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
  }

  private isLatest_(r: ChangelogRelease): boolean {
    let latest = this.latestRelease_()
    return latest !== null && latest.tag === r.tag
  }
}
