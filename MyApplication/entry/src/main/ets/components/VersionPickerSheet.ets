/**
 * VersionPickerSheet.ets — 模组安装"目标版本"选择 Sheet
 *
 * 用途：模组 / 资源包 / 光影下载时，选择要把资源装进哪个**已安装**的 MC 版本。
 *   - 顶部左右两个页签：沙箱(应用内) / 外部(Download/com.amcl.launcher)
 *   - 每个页签下列出该存储根 `versions/` 里**真实存在**的版本号（由调用方扫描后传入）
 *   - 点击某版本 → onPick(location, versionId)，由调用方落位安装目录
 *
 * 与 ModDetailSheet 里的"版本选择"区别：那里选的是**远端模组文件的版本**；
 * 本 sheet 选的是**本地已装的 MC 实例**（决定 mods/ 落到哪个根、哪个版本目录）。
 *
 * ArkTS 注意：tab 段 / 版本行的"选中态"一律读 this.* (@State/@Prop)，
 * 不通过 @Builder 的 primitive 参数传入（参数脏标记会漏报，见 DownloadTab 注释）。
 *
 * 创建日期：2026-06-04
 */

import { ThemeColors } from 'commons';
import { AppIcon } from './AppIcon';
import { AppIconName } from 'commons';
import { VersionBlockIcon } from './VersionBlockIcon';
import { detectLoaderFromId, extractGameVersionFromId } from 'mods';
import { resolveInstalledLoader, resolveInstalledMcVersion } from 'mods';

@Component
export struct VersionPickerSheet {
  @Prop theme: ThemeColors = {} as ThemeColors;
  /** 沙箱根 versions/ 下真实存在的版本 id（调用方扫描，降序） */
  @Prop sandboxVersions: string[] = [];
  /** 外部根 versions/ 下真实存在的版本 id（外部不可用时为空） */
  @Prop externalVersions: string[] = [];
  /** 沙箱 .minecraft 根（解析整合包/重命名版本的真实 MC 版本 + loader 用） */
  @Prop sandboxMcDir: string = '';
  /** 外部 .minecraft 根（外部页签版本解析用，不可用时为空） */
  @Prop externalMcDir: string = '';
  /** 本设备外部存储是否可用（取得到 Download 路径）；false 时"外部"页签禁用 */
  @Prop externalAvailable: boolean = false;
  /** 当前已选中的位置（'sandbox' | 'external'），用于回显勾选 */
  @Prop selectedLocation: string = 'sandbox';
  /** 当前已选中的版本 id，用于回显勾选 */
  @Prop selectedVersionId: string = '';
  /** 打开时默认停在哪个页签：0=沙箱 / 1=外部 */
  @Prop initialTab: number = 0;

  /** 选定某版本回调（location: 'sandbox' | 'external'） */
  onPick: (location: string, versionId: string) => void = () => {};
  /** 关闭回调 */
  onClose: () => void = () => {};

  /** 内部页签下标：0=沙箱 / 1=外部 */
  @State private tabIdx_: number = 0;

  aboutToAppear() {
    // 外部不可用时强制停在沙箱页签
    this.tabIdx_ = (this.initialTab === 1 && this.externalAvailable) ? 1 : 0;
  }

  private activeList(): string[] {
    return this.tabIdx_ === 1 ? this.externalVersions : this.sandboxVersions;
  }

  private activeLocation(): string {
    return this.tabIdx_ === 1 ? 'external' : 'sandbox';
  }

  /** 版本副标题："MC 1.21.1 · Fabric" / "MC 1.20.4 · 原版" */
  private subtitleOf(id: string): string {
    // 整合包/重命名版本名无版本号/loader 关键字 → 走快照/内容解析（按当前页签的根）
    let root = this.tabIdx_ === 1 ? this.externalMcDir : this.sandboxMcDir;
    let gv = root.length > 0 ? resolveInstalledMcVersion(root, id) : extractGameVersionFromId(id);
    let loader = root.length > 0 ? resolveInstalledLoader(root, id) : detectLoaderFromId(id);
    let loaderLabel = loader.length > 0
      ? loader.charAt(0).toUpperCase() + loader.substring(1)
      : '原版';
    return (gv.length > 0 ? 'MC ' + gv : id) + ' · ' + loaderLabel;
  }

  private isSelected(id: string): boolean {
    return this.selectedVersionId === id && this.selectedLocation === this.activeLocation();
  }

  build() {
    Column() {
      // ============ 头部：标题 + 关闭 ============
      Row() {
        Text('选择安装版本')
          .fontSize(17)
          .fontWeight(700)
          .fontColor(this.theme.textPrimary)
          .layoutWeight(1)
        Row() {
          AppIcon({ name: AppIconName.Close, iconSize: 16, color: this.theme.textSecondary })
        }
        .width(32)
        .height(32)
        .borderRadius(16)
        .backgroundColor(this.theme.bgInput)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .onClick(() => { this.onClose() })
      }
      .width('100%')
      .padding({ left: 4, right: 4, top: 2, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      // ============ 左右页签：沙箱 / 外部 ============
      Row({ space: 8 }) {
        // —— 沙箱 ——
        Row({ space: 6 }) {
          AppIcon({
            name: AppIconName.Folder,
            iconSize: 14,
            color: this.tabIdx_ === 0 ? this.theme.textOnPrimary : this.theme.textSecondary,
          })
          Text('沙箱')
            .fontSize(14)
            .fontWeight(this.tabIdx_ === 0 ? 600 : 500)
            .fontColor(this.tabIdx_ === 0 ? this.theme.textOnPrimary : this.theme.textSecondary)
          Text('(' + this.sandboxVersions.length + ')')
            .fontSize(12)
            .fontColor(this.tabIdx_ === 0 ? this.theme.textOnPrimary : this.theme.textHint)
        }
        .layoutWeight(1)
        .height(40)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .borderRadius(12)
        .backgroundColor(this.tabIdx_ === 0 ? this.theme.primary : this.theme.bgInput)
        .onClick(() => { if (this.tabIdx_ !== 0) this.tabIdx_ = 0 })

        // —— 外部 ——
        Row({ space: 6 }) {
          AppIcon({
            name: AppIconName.CloudDownload,
            iconSize: 14,
            color: !this.externalAvailable
              ? this.theme.textHint
              : (this.tabIdx_ === 1 ? this.theme.textOnPrimary : this.theme.textSecondary),
          })
          Text('外部')
            .fontSize(14)
            .fontWeight(this.tabIdx_ === 1 ? 600 : 500)
            .fontColor(!this.externalAvailable
              ? this.theme.textHint
              : (this.tabIdx_ === 1 ? this.theme.textOnPrimary : this.theme.textSecondary))
          Text(this.externalAvailable ? '(' + this.externalVersions.length + ')' : '不可用')
            .fontSize(12)
            .fontColor(!this.externalAvailable
              ? this.theme.textHint
              : (this.tabIdx_ === 1 ? this.theme.textOnPrimary : this.theme.textHint))
        }
        .layoutWeight(1)
        .height(40)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .borderRadius(12)
        .opacity(this.externalAvailable ? 1 : 0.5)
        .backgroundColor(this.tabIdx_ === 1 ? this.theme.primary : this.theme.bgInput)
        .onClick(() => {
          if (!this.externalAvailable) return;
          if (this.tabIdx_ !== 1) this.tabIdx_ = 1;
        })
      }
      .width('100%')

      // ============ 当前页签说明 ============
      Text(this.tabIdx_ === 1
        ? '外部：保存在下载目录，卸载 AMCL 不会丢失'
        : '沙箱：应用内私有目录，卸载 AMCL 会一并删除')
        .fontSize(11)
        .fontColor(this.theme.textHint)
        .width('100%')
        .padding({ left: 4, top: 10, bottom: 6 })

      // ============ 版本列表 / 空态 ============
      if (this.activeList().length === 0) {
        Column({ space: 8 }) {
          AppIcon({ name: AppIconName.Game, iconSize: 30, color: this.theme.textHint })
          Text('该位置暂无已安装版本')
            .fontSize(14)
            .fontColor(this.theme.textSecondary)
          Text('请先在「下载」页安装一个游戏版本')
            .fontSize(12)
            .fontColor(this.theme.textHint)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.activeList(), (id: string) => {
            ListItem() {
              this.VersionRow(id)
            }
          }, (id: string) => this.activeLocation() + ':' + id)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ top: 4, bottom: 8 })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .backgroundColor(this.theme.bgPrimary)
  }

  @Builder
  VersionRow(id: string) {
    Row() {
      VersionBlockIcon({ versionId: id, iconSize: 34, cornerRadius: 6 })
      Column() {
        Text(id)
          .fontSize(15)
          .fontWeight(500)
          .fontColor(this.isSelected(id) ? this.theme.primary : this.theme.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.subtitleOf(id))
          .fontSize(12)
          .fontColor(this.theme.textHint)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })

      if (this.isSelected(id)) {
        AppIcon({ name: AppIconName.CheckCircle, iconSize: 20, color: this.theme.primary })
      } else {
        AppIcon({ name: AppIconName.ArrowRight, iconSize: 16, color: this.theme.textHint })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 14, top: 12, bottom: 12 })
    .backgroundColor(this.theme.bgCard)
    .borderRadius(this.theme.cardRadius)
    .border(this.isSelected(id)
      ? { width: 1.5, color: this.theme.primary }
      : { width: 0, color: Color.Transparent })
    .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
    .onClick(() => { this.onPick(this.activeLocation(), id) })
  }
}
