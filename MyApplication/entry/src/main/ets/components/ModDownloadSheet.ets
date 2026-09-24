/**
 * ModDownloadSheet.ets — 模组下载详情面板（v2，2026-05-12 重构）
 *
 * 文档：docs/guides/mod-download-system-plan.md §八.5
 *
 * v2 增强（用户反馈）：
 *   - 取消按钮：调用方提供 onCancel → DownloadManager.cancel(taskId)
 *   - 重试按钮：失败终态可重试（调用方重新走 fetchAndInstallLatest）
 *   - 关闭按钮：终态时收起 Sheet
 *   - 多文件进度：展示文件名列表 + 已下载 / 总计
 *   - 任务名 + project 标题分行清晰显示
 *   - 失败错误详情不截断
 *
 * 与 DownloadSheet 的差异：
 *   - DownloadSheet 是 MC 整版下载用的，依赖 6 阶段 phase 模型 (PREPARE/CLIENT/LIBRARIES/...)
 *   - 本组件用于单 mod / 资源包 / 光影下载，扁平 1 阶段（多文件）模型
 *
 * 创建日期：2026-05-11；v2 重构：2026-05-12
 */

import { ThemeColors } from 'commons';
import { formatBytes, formatSpeed } from 'commons';
import { AppIconName } from 'commons';
import { AppIcon } from './AppIcon';

// ============================================================
//  ModDlState — Index ↔ ModBrowsePage 共享 state 类型
// ============================================================

/**
 * 模组下载实时状态。Index.ets 持有一个 @State 实例；ModBrowsePage
 * 通过 onModDownloadProgress 回调推送更新。
 *
 * 设计原则：扁平字段 + 默认值，方便 Index 直接 `this.modDl_ = nextState` 整体替换，
 * 避免 ArkUI @State 深层属性变更不刷新的坑。
 */
export interface ModDlState {
  /** 任务存在 + 未结束 */
  active: boolean;
  /** 任务终态（无论成功/失败/取消） */
  finished: boolean;
  /** 终态 + 成功 */
  success: boolean;
  /** 终态 + 失败/取消 */
  failed: boolean;
  /** 是否为用户取消（vs 真正失败） */
  cancelled: boolean;

  /** native task id；0 表示未启动（准备阶段）。用于 cancel(taskId) */
  taskId: number;

  /** 项目展示名（"sodium" / "Faithful 32x"），不含文件名 */
  projectTitle: string;
  /** 类型标签："模组" / "资源包" / "光影" */
  kindLabel: string;
  /** 底层任务名（"mod: sodium-0.5.8.jar + 2 deps"），调试用 */
  taskName: string;

  progress: number;       // 0-100
  currentFile: string;    // 当前在下的文件 basename
  /** v2: 当前活跃文件列表（多线程下载时有多个） */
  currentFiles: string[];
  filesDone: number;
  filesTotal: number;
  bytesDone: number;
  bytesTotal: number;
  speedBps: number;
  etaSeconds: number;     // -1 表示未知

  /** 失败信息（空字符串表示无错） */
  errorMessage: string;
  /** 失败的 native error kind（"Network" / "Sha1Mismatch" 等），UI 高亮用 */
  errorKind: string;
}

/** 工厂：构造空状态 */
export function makeEmptyModDlState(): ModDlState {
  return {
    active: false, finished: false, success: false, failed: false, cancelled: false,
    taskId: 0,
    projectTitle: '', kindLabel: '', taskName: '',
    progress: 0, currentFile: '', currentFiles: [],
    filesDone: 0, filesTotal: 0,
    bytesDone: 0, bytesTotal: 0, speedBps: 0, etaSeconds: -1,
    errorMessage: '', errorKind: '',
  };
}

// ============================================================
//  纯函数：ETA 格式化
// ============================================================

export function formatEta(seconds: number): string {
  if (seconds < 0 || !isFinite(seconds)) return '';
  if (seconds < 1) return '<1s';
  if (seconds < 60) return Math.round(seconds) + 's';
  let m = Math.floor(seconds / 60);
  let s = Math.round(seconds % 60);
  if (m < 60) return m + 'm ' + s + 's';
  let h = Math.floor(m / 60);
  let mm = m % 60;
  return h + 'h ' + mm + 'm';
}

// ============================================================
//  ModDownloadSheet 组件（v2）
// ============================================================

@Component
export struct ModDownloadSheet {
  @Prop theme: ThemeColors = {} as ThemeColors;
  @Prop modDl: ModDlState = makeEmptyModDlState();
  @Prop bottomSafeHeight: number = 0;

  /** 用户点击取消（仅 active 时可用）。调用方拿到后 cancel(taskId) */
  onCancel: () => void = () => {};
  /** 用户点击重试（仅 failed 非 cancelled 时可用）。调用方重新发起整个下载 */
  onRetry: () => void = () => {};
  /** 用户点击关闭 / 完成（收起 Sheet） */
  onClose: () => void = () => {};

  private getStatusLabel(): string {
    if (this.modDl.success) return '安装完成';
    if (this.modDl.cancelled) return '已取消';
    if (this.modDl.failed) return '安装失败';
    if (this.modDl.active) {
      if (this.modDl.taskId === 0) return '准备中...';
      return '下载中';
    }
    return '准备中';
  }

  private getStatusColor(): ResourceColor {
    if (this.modDl.success) return this.theme.success;
    if (this.modDl.failed && !this.modDl.cancelled) return this.theme.error;
    if (this.modDl.cancelled) return this.theme.warning;
    return this.theme.primary;
  }

  private getStatusIcon(): AppIconName {
    if (this.modDl.success) return AppIconName.CheckCircle;
    if (this.modDl.cancelled) return AppIconName.Pause;
    if (this.modDl.failed) return AppIconName.Error;
    return AppIconName.Download;
  }

  private canCancel(): boolean {
    return this.modDl.active && !this.modDl.finished && this.modDl.taskId > 0;
  }

  private canRetry(): boolean {
    return this.modDl.failed && !this.modDl.cancelled;
  }

  build() {
    Column() {
      // ==================== 顶部摘要 ====================
      Column() {
        Row() {
          Row() {
            AppIcon({
              name: this.getStatusIcon(),
              iconSize: 28,
              color: this.getStatusColor(),
              weight: FontWeight.Bold,
            })
          }
          .width(40).justifyContent(FlexAlign.Center)

          Column() {
            Text(this.modDl.projectTitle.length > 0
                ? this.modDl.projectTitle
                : (this.modDl.taskName.length > 0 ? this.modDl.taskName : '模组下载'))
              .fontSize(17).fontWeight(600).fontColor(this.theme.textPrimary)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })

            Row() {
              Text(this.getStatusLabel())
                .fontSize(12).fontColor(this.getStatusColor())
              if (this.modDl.kindLabel.length > 0) {
                Text(' · ' + this.modDl.kindLabel)
                  .fontSize(12).fontColor(this.theme.textHint)
              }
              if (this.modDl.taskId > 0) {
                Text(' · #' + this.modDl.taskId)
                  .fontSize(11).fontColor(this.theme.textHint)
              }
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .margin({ left: 8 })
        }
        .width('100%')

        // 进度条
        Progress({
          value: Math.max(0, Math.min(this.modDl.progress, 100)),
          total: 100,
          type: ProgressType.Linear,
        })
          .width('100%')
          .height(8)
          .color(this.getStatusColor())
          .backgroundColor(this.theme.divider)
          .borderRadius(4)
          .margin({ top: 12 })

        // 进度数据行：% / 文件计数
        Row() {
          Text(Math.round(this.modDl.progress) + '%')
            .fontSize(14).fontWeight(500).fontColor(this.theme.textPrimary)
          Blank()
          if (this.modDl.filesTotal > 0) {
            Text(this.modDl.filesDone + ' / ' + this.modDl.filesTotal + ' 文件')
              .fontSize(12).fontColor(this.theme.textSecondary)
          }
        }
        .width('100%')
        .margin({ top: 8 })

        // 字节 / 速度 / ETA
        Row() {
          if (this.modDl.bytesTotal > 0) {
            Text(formatBytes(this.modDl.bytesDone) + ' / ' + formatBytes(this.modDl.bytesTotal))
              .fontSize(12).fontColor(this.theme.textHint)
          }
          Blank()
          if (this.modDl.active && this.modDl.speedBps > 0) {
            Text(formatSpeed(this.modDl.speedBps))
              .fontSize(12).fontColor(this.theme.primary).fontWeight(500)
          }
          if (this.modDl.active && this.modDl.etaSeconds >= 0) {
            Text(' · 剩 ' + formatEta(this.modDl.etaSeconds))
              .fontSize(12).fontColor(this.theme.textHint)
          }
        }
        .width('100%')
        .margin({ top: 4 })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 12, bottom: 12 })

      // ==================== 文件详情区 ====================
      Scroll() {
        Column() {
          // 当前活跃文件列表
          if (this.modDl.active && this.modDl.currentFiles.length > 0) {
            Column() {
              Text('正在下载')
                .fontSize(12).fontWeight(500).fontColor(this.theme.textSecondary)
                .width('100%')
                .margin({ bottom: 6 })
              ForEach(this.modDl.currentFiles, (filename: string) => {
                Row() {
                  Text('↓ ')
                    .fontSize(12).fontColor(this.theme.primary)
                  Text(filename)
                    .fontSize(12).fontColor(this.theme.textPrimary)
                    .textOverflow({ overflow: TextOverflow.Ellipsis }).maxLines(1)
                    .layoutWeight(1)
                }
                .width('100%')
                .padding({ top: 2, bottom: 2 })
              }, (filename: string) => filename)
            }
            .width('100%')
            .padding(12)
            .backgroundColor(this.theme.bgCard)
            .borderRadius(8)
            .margin({ bottom: 8 })
          } else if (this.modDl.active && this.modDl.currentFile.length > 0) {
            // fallback: 单文件
            Row() {
              Text('↓ ')
                .fontSize(12).fontColor(this.theme.primary)
              Text(this.modDl.currentFile)
                .fontSize(12).fontColor(this.theme.textPrimary)
                .textOverflow({ overflow: TextOverflow.Ellipsis }).maxLines(1)
                .layoutWeight(1)
            }
            .width('100%')
            .padding(12)
            .backgroundColor(this.theme.bgCard)
            .borderRadius(8)
            .margin({ bottom: 8 })
          }

          // 失败详情
          if (this.modDl.failed && this.modDl.errorMessage.length > 0) {
            Column() {
              Row() {
                Text('错误详情')
                  .fontSize(12).fontWeight(500).fontColor(this.theme.error)
                if (this.modDl.errorKind.length > 0) {
                  Text(' · ' + this.modDl.errorKind)
                    .fontSize(11).fontColor(this.theme.error)
                }
              }
              .width('100%')
              .margin({ bottom: 4 })
              Text(this.modDl.errorMessage)
                .fontSize(12).fontColor(this.theme.textSecondary)
                .maxLines(8)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding(12)
            .backgroundColor(this.theme.errorBg)
            .borderRadius(8)
            .alignItems(HorizontalAlign.Start)
          }

          // 成功状态：填空白让 Scroll 不抖
          if (this.modDl.success) {
            Column({ space: 8 }) {
              AppIcon({ name: AppIconName.Celebrate, iconSize: 36, color: this.theme.success })
              Text('所有文件已安装到目标版本目录')
                .fontSize(13).fontColor(this.theme.textSecondary)
                .textAlign(TextAlign.Center)
            }
            .width('100%')
            .padding(24)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)

      // ==================== 底部操作栏 ====================
      Row() {
        if (this.canCancel()) {
          Button('取消下载')
            .fontSize(14)
            .fontColor(this.theme.error)
            .backgroundColor(this.theme.errorBg)
            .borderRadius(20)
            .height(36)
            .layoutWeight(1)
            .onClick(() => { this.onCancel(); })
        } else if (this.canRetry()) {
          Button('重试')
            .fontSize(14)
            .fontColor(this.theme.textOnPrimary)
            .backgroundColor(this.theme.primary)
            .borderRadius(20)
            .height(36)
            .layoutWeight(1)
            .margin({ right: 8 })
            .onClick(() => { this.onRetry(); })

          Button('关闭')
            .fontSize(14)
            .fontColor(this.theme.textSecondary)
            .backgroundColor(this.theme.bgInput)
            .borderRadius(20)
            .height(36)
            .layoutWeight(1)
            .margin({ left: 8 })
            .onClick(() => { this.onClose(); })
        } else {
          // success / cancelled / 准备阶段：只显示关闭
          Button(this.modDl.success ? '完成' : '关闭')
            .fontSize(14)
            .fontColor(this.theme.textOnPrimary)
            .backgroundColor(this.modDl.success ? this.theme.success : this.theme.primary)
            .borderRadius(20)
            .height(36)
            .layoutWeight(1)
            .onClick(() => { this.onClose(); })
        }
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 12, bottom: Math.max(16, this.bottomSafeHeight) })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.bgPrimary)
  }
}
