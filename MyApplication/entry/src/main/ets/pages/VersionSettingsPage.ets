/**
 * VersionSettingsPage.ets — 版本设置页面
 *
 * 显示已安装的 MC 版本列表，提供版本管理功能：
 * - 选择当前版本
 * - 删除已安装版本
 * - 查看版本信息（大小、安装日期）
 * - 跳转到下载页下载新版本
 */

import { router } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ThemeColors, ThemeMode, resolveTheme } from 'commons';
import { PreferenceManager } from 'feature_system';
import { GameStorage, parseStorageLocation } from 'feature_system';
import { common } from '@kit.AbilityKit';
import { removeDirRecursive } from 'commons';
import { ImmersiveTitleScaffold } from '../components/ImmersiveTitleScaffold';

const TAG = 'VersionSettings'

interface InstalledVersion {
  id: string
  jarSizeMB: number
  hasNatives: boolean
}

@Entry
@Component
struct VersionSettingsPage {
  /** 共享标题独占系统栏避让，版本正文不重复添加顶部补偿。 */
  @StorageProp('topRectHeight') private topSafeHeight: number = 0
  @State versions: InstalledVersion[] = []
  @State currentVersion: string = '1.20.4'
  @State theme: ThemeColors = resolveTheme(ThemeMode.SYSTEM, false)
  @State versionIsolation: boolean = true
  // 2026-05-23 API NEXT 迁移：getContext(this) 已弃用，改读 EntryAbility 缓存。
  // 详见 docs/guides/api-migration-2026-05.md。
  private context: common.UIAbilityContext = AppStorage.get<common.UIAbilityContext>('uiAbilityContext')!
  private prefManager: PreferenceManager = new PreferenceManager(this.context)

  aboutToAppear() {
    this.loadSettings()
    this.scanVersions()
  }

  private loadSettings() {
    this.currentVersion = this.prefManager.mcVersion
    this.versionIsolation = this.prefManager.versionIsolation
    this.theme = resolveTheme(this.prefManager.themeMode, false)
  }

  private saveCurrentVersion() {
    this.prefManager.mcVersion = this.currentVersion
  }

  /** 当前激活的 .minecraft 根（沙箱或外部，按存储位置偏好解析） */
  private mcRoot(): string {
    return GameStorage.resolveMcDir(this.context, parseStorageLocation(this.prefManager.mcStorageLocation))
  }

  private scanVersions() {
    let versionsDir = this.mcRoot() + '/versions'
    let result: InstalledVersion[] = []
    try {
      let entries = fs.listFileSync(versionsDir)
      for (let name of entries) {
        let jarPath = versionsDir + '/' + name + '/' + name + '.jar'
        try {
          let stat = fs.statSync(jarPath)
          if (stat.size > 1024 * 1024) {
            let nativesDir = versionsDir + '/' + name + '/natives'
            let hasNatives = false
            try { fs.statSync(nativesDir); hasNatives = true } catch (e) { /* no natives */ }
            let ver: InstalledVersion = {
              id: name,
              jarSizeMB: Math.round(stat.size / 1024 / 1024 * 10) / 10,
              hasNatives: hasNatives
            }
            result.push(ver)
          }
        } catch (e) { /* jar doesn't exist */ }
      }
    } catch (e) { /* versions dir doesn't exist */ }
    result.sort((a: InstalledVersion, b: InstalledVersion) => {
      if (a.id > b.id) return -1
      if (a.id < b.id) return 1
      return 0
    })
    this.versions = result
  }

  private deleteVersion(id: string) {
    let versionDir = this.mcRoot() + '/versions/' + id
    removeDirRecursive(versionDir)
    if (this.currentVersion === id && this.versions.length > 1) {
      let remaining = this.versions.filter(v => v.id !== id)
      if (remaining.length > 0) {
        this.currentVersion = remaining[0].id
        this.saveCurrentVersion()
      }
    }
    this.scanVersions()
  }

  /**
   * 旧版本管理路由与首页版本详情使用同一导出向导。立即固定点击行的身份，
   * 不借用 currentVersion 以免“导出非当前行”错误变成导出当前游戏。
   * 导航失败只提示错误；完整性检查与系统另存由向导负责。
   */
  private async exportVersion_(versionId: string): Promise<void> {
    try {
      await this.getUIContext().getRouter().pushUrl({
        url: 'pages/GameExportPage',
        params: { 'mcRoot': this.mcRoot(), 'versionId': versionId, 'versionIsolation': this.versionIsolation },
      })
    } catch (e) {
      try { this.getUIContext().getPromptAction().showToast({ message: '无法打开导出页面：' + (e as Error).message }) }
      catch (toastError) { hilog.warn(0, TAG, '导出导航及提示失败：%{public}s', (toastError as Error).message) }
    }
  }

  build() {
    Column() {
      // 仅替换标题宿主；选择版本、删除与导出的原回调保持独立。
      ImmersiveTitleScaffold({ title: '版本管理', theme: this.theme, topSafeHeight: this.topSafeHeight,
        surfaceColor: this.theme.bgPrimary, onBack: (): void => { this.getUIContext().getRouter().back(); },
        content: (): void => { this.ImmersiveTitleContent1_(); }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.bgPrimary)
  }

  /** 保留原正文的父组件状态与业务回调；具名content只转调此真正@Builder，避免this漂移。 */
  @Builder
  private ImmersiveTitleContent1_() {
      // 内容区
      Scroll() {
        Column({ space: 12 }) {

          // 版本隔离状态卡片
          Row() {
            Column() {
              Text('版本隔离')
                .fontSize(16)
                .fontWeight(500)
                .fontColor(this.theme.textPrimary)
              Text(this.versionIsolation
                ? '已开启 — 每个版本独立存档和模组'
                : '已关闭 — 所有版本共享数据')
                .fontSize(13)
                .fontWeight(400)
                .fontColor(this.theme.textSecondary)
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')
          .padding(16)
          .backgroundColor(this.theme.bgCard)
          .borderRadius(16)

          // 将导出主操作独立成行，窄窗口不会因原有选择/删除按钮而横向溢出。
          Button('导出当前版本游戏包')
            .width('100%').height(48).fontSize(14)
            .fontColor(this.theme.textOnPrimary).backgroundColor(this.theme.primary)
            .enabled(this.versions.some((version: InstalledVersion): boolean => version.id === this.currentVersion))
            .onClick(() => { this.exportVersion_(this.currentVersion) })

          // 已安装版本标题
          Row() {
            Text('已安装版本')
              .fontSize(13)
              .fontColor(this.theme.textHint)
              .fontWeight(500)
            Blank()
            Text(this.versions.length + ' 个')
              .fontSize(13)
              .fontColor(this.theme.textHint)
          }
          .width('100%')
          .padding({ left: 4, right: 4 })

          // 版本列表
          if (this.versions.length === 0) {
            Column() {
              Text('暂无已安装的版本')
                .fontSize(16)
                .fontWeight(400)
                .fontColor(this.theme.textSecondary)
                .margin({ top: 40, bottom: 8 })
              Text('请在「下载」页面下载游戏版本')
                .fontSize(13)
                .fontWeight(400)
                .fontColor(this.theme.textHint)
                .margin({ bottom: 40 })
            }
            .width('100%')
            .backgroundColor(this.theme.bgCard)
            .borderRadius(16)
            .justifyContent(FlexAlign.Center)
          } else {
            Column() {
              ForEach(this.versions, (ver: InstalledVersion, index: number) => {
                // 版本项
                Row() {
                  // 左侧选中指示器
                  Column()
                    .width(3)
                    .height(32)
                    .borderRadius(2)
                    .backgroundColor(this.currentVersion === ver.id ? this.theme.primary : Color.Transparent)
                    .margin({ right: 16 })

                  // 版本信息
                  Column() {
                    Row({ space: 8 }) {
                      Text('Minecraft ' + ver.id)
                        .fontSize(16)
                        .fontWeight(500)
                        .fontColor(this.currentVersion === ver.id ? this.theme.primary : this.theme.textPrimary)
                      if (this.currentVersion === ver.id) {
                        Text('当前')
                          .fontSize(11)
                          .fontColor(this.theme.textOnPrimary)
                          .backgroundColor(this.theme.primary)
                          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                          .borderRadius(8)
                      }
                    }
                    Text(ver.jarSizeMB + ' MB')
                      .fontSize(12)
                      .fontWeight(400)
                      .fontColor(this.theme.textHint)
                      .margin({ top: 2 })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  // 操作按钮
                  Row({ space: 8 }) {
                    if (this.currentVersion !== ver.id) {
                      Button('选择')
                        .type(ButtonType.Capsule)
                        .height(32)
                        .fontSize(13)
                        .fontColor(this.theme.primary)
                        .backgroundColor(this.theme.bgInput)
                        .onClick(() => {
                          this.currentVersion = ver.id
                          this.saveCurrentVersion()
                        })
                    }
                    Button('删除')
                      .type(ButtonType.Capsule)
                      .height(32)
                      .fontSize(13)
                      .fontColor(this.theme.error)
                      .backgroundColor(this.theme.bgInput)
                      .onClick(() => { this.deleteVersion(ver.id) })
                  }
                }
                .width('100%')
                .padding({ top: 14, bottom: 14, left: 12, right: 16 })
                .onClick(() => {
                  this.currentVersion = ver.id
                  this.saveCurrentVersion()
                })

                // 分割线（最后一项不显示）
                if (index < this.versions.length - 1) {
                  Row()
                    .width('100%')
                    .height(0.5)
                    .backgroundColor(this.theme.divider)
                    .margin({ left: 32 })
                }
              })
            }
            .width('100%')
            .backgroundColor(this.theme.bgCard)
            .borderRadius(16)
          }

          // 提示信息
          Text('在「下载」页面可以下载更多游戏版本')
            .fontSize(12)
            .fontWeight(400)
            .fontColor(this.theme.textHint)
            .textAlign(TextAlign.Center)
            .width('100%')
            .margin({ top: 4 })
        }
        .width('100%')
        .padding(16)
      }
      .layoutWeight(1)
      }
}
