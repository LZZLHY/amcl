/**
 * 整合包浏览卡片：以包名、简介与兼容版本为主，来源和下载量作为辅助信息。
 * 手机单列与平板网格共用相同的内容结构和高度，避免宽屏只拉长文字行。
 * 本组件只展示远程项目并打开详情，不在列表中猜选版本或直接提交安装任务。
 */
import { ThemeColors, AppIconName, compareMcVersion } from 'commons';
import { RemoteProject, displayTitleOf } from 'mods';
import { AppIcon } from './AppIcon';
import { RemoteImage } from './RemoteImage';
import { formatDownloadCount, sourceMetaText } from './ModCard';
import { inferLoaderInfo } from './LoaderCatalog';

@Component
export struct ModpackCard {
  @Prop theme: ThemeColors = new ThemeColors();
  @Prop project: RemoteProject = {} as RemoteProject;
  /** 卡片点击只交给浏览页；详情解析与安装确认仍使用已有服务链路。 */
  onTap: (project: RemoteProject) => void = () => {};

  /**
   * 优先展示可比较的较新游戏版本，并注明项目还支持其他版本。
   * 版本来自项目元数据，不能当作即将安装的具体文件版本；最终兼容信息由详情选版决定。
   * 生产比较器对不可比较的快照返回 0，因此此处保留来源顺序，不臆造快照新旧关系。
   */
  private gameVersionLabel_(): string {
    const versions = this.project.gameVersions;
    if (versions.length === 0) return '版本信息见详情';
    let newest = versions[0];
    for (let version of versions) {
      if (compareMcVersion(version, newest) > 0) newest = version;
    }
    return 'MC ' + newest + (versions.length > 1 ? ' 等 ' + versions.length + ' 个版本' : '');
  }

  /** 加载器复用全应用名称目录；双加载器项目保留两者，不把项目级信息当作单个安装文件。 */
  private loaderLabel_(): string {
    if (this.project.loaders.length === 0) return '';
    return this.project.loaders.map((loader: string): string => inferLoaderInfo(loader).displayName).join(' / ');
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        RemoteImage({
          url: this.project.iconUrl, diameter: 56, cornerRadius: 16,
          fallbackIcon: AppIconName.ModPack,
          fallbackBg: this.theme.bgInput, fallbackColor: this.theme.textSecondary,
        })
        Column({ space: 4 }) {
          Text(displayTitleOf(this.project))
            .fontSize(16).fontWeight(600).fontColor(this.theme.textPrimary)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.project.author.length > 0 ? this.project.author : sourceMetaText(this.project))
            .fontSize(12).fontColor(this.theme.textSecondary)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }
        .layoutWeight(1).alignItems(HorizontalAlign.Start)
      }
      .width('100%').height(64).alignItems(VerticalAlign.Center)

      Text(this.project.summary.length > 0 ? this.project.summary : '打开详情查看内容与可安装版本')
        .fontSize(13).lineHeight(20).fontColor(this.theme.textSecondary)
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%').height(40)

      Row({ space: 8 }) {
        Text(this.gameVersionLabel_())
          .fontSize(12).fontColor(this.theme.textPrimary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.project.loaders.length > 0) {
          Text(this.loaderLabel_())
            .fontSize(12).fontColor(this.theme.textSecondary)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '45%' })
        }
      }
      .width('100%').height(28)
      .padding({ left: 8, right: 8 }).backgroundColor(this.theme.bgInput).borderRadius(8)

      Row({ space: 4 }) {
        Text(sourceMetaText(this.project))
          .fontSize(12).fontColor(this.theme.textSecondary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        AppIcon({ name: AppIconName.Download, iconSize: 12, color: this.theme.textSecondary })
        Text(formatDownloadCount(this.project.downloads))
          .fontSize(12).fontColor(this.theme.textSecondary)
      }
      .width('100%').height(20).alignItems(VerticalAlign.Center)
    }
    .width('100%').padding(16).alignItems(HorizontalAlign.Start)
    .backgroundColor(this.theme.bgCard).borderRadius(this.theme.cardRadius)
    .onClick(() => { this.onTap(this.project); })
  }
}
