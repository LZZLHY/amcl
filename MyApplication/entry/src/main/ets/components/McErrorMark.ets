/** 结果页使用原生矢量描边显示分类。轮廓与强调线共用 64 像素设计坐标，随显示尺寸等比缩放。 */
import { ThemeColors } from 'commons';
import { McErrorCategory } from 'launch';

interface MarkPaths {
  outline: string;
  detail: string;
  muted?: string;
  tint?: string;
}

const RING = 'M32 8.5a23.5 23.5 0 1 1 0 47a23.5 23.5 0 1 1 0-47Z';

/** 断链和环叉采用 A 样稿的原始路径。其余类别各有独立轮廓，单色下也可以辨别。 */
const MARKS: Record<string, MarkPaths> = {
  'split-link': {
    outline: 'M28.4 37.5l-6.8 6.8a7.4 7.4 0 0 1-10.5-10.4l9.4-9.4a7.4 7.4 0 0 1 8.3-1.5 '
      + 'M35.6 26.5l6.8-6.8a7.4 7.4 0 0 1 10.5 10.4l-9.4 9.4a7.4 7.4 0 0 1-8.3 1.5',
    detail: 'm29 10 2 7m10 31 2 6',
    muted: 'm25.2 30.2 3.6-3.6m6.4 10.8 3.6-3.6',
  },
  'classic-cross': {
    outline: RING, detail: 'M24.9 24.9l14.2 14.2m0-14.2-14.2 14.2', tint: RING,
  },
  'jvm-runtime': {
    outline: 'M13 12h38a4 4 0 0 1 4 4v31a4 4 0 0 1-4 4H13a4 4 0 0 1-4-4V16a4 4 0 0 1 4-4ZM10 22h44',
    detail: 'm19 30 7 6-7 6m14-1h10',
  },
  'memory': {
    outline: 'M9 17h46v28H9ZM15 46v5m8-5v5m8-5v5m8-5v5m8-5v5',
    detail: 'M16 25h11v11H16ZM36 25h11v11H36Z',
  },
  'document-cross': {
    outline: 'M18 7h21l12 12v34a4 4 0 0 1-4 4H18a4 4 0 0 1-4-4V11a4 4 0 0 1 4-4ZM38.5 8v9.5a3 3 0 0 0 3 3H50',
    detail: 'M25.1 28.1l12.8 12.8m0-12.8L25.1 40.9', muted: 'M20 50h10',
  },
  'native-crash': {
    outline: 'M23 9h18l14 14v18L41 55H23L9 41V23Z',
    detail: 'M16 34h8l5-12 6 22 5-13h8',
  },
  'graphics': {
    outline: 'm32 10 23 13-23 13L9 23Zm-22 23 22 12 22-12',
    detail: 'm10 42 22 12 22-12',
  },
  'launch-args': {
    outline: 'M10 20h11m13 0h20M10 43h24m13 0h7',
    detail: 'M27.5 14a6 6 0 1 1 0 12a6 6 0 1 1 0-12ZM40.5 37a6 6 0 1 1 0 12a6 6 0 1 1 0-12Z',
  },
  'network': {
    outline: 'M53 34a22 22 0 1 0-19 19m-4-42c-9 10-11 28 0 42m2-42c6 7 9 14 9 21M11 31h43',
    detail: 'm41 40 12 12m0-12L41 52',
  },
  'session-ended': {
    outline: RING, detail: 'M24 32h16',
  },
};

@Component
export struct McErrorMark {
  @Prop category: McErrorCategory = 'unknown';
  @Prop theme: ThemeColors = {} as ThemeColors;
  @Prop iconSize: number = 36;

  /** 依据分类器的稳定类别选形；中性结束与已知崩溃但未查明原因使用不同图形。 */
  private markKey_(): string {
    switch (this.category) {
      case 'mod_conflict':
      case 'mixin_apply': return 'split-link';
      case 'jdk_version':
      case 'jdk_runtime': return 'jvm-runtime';
      case 'oom': return 'memory';
      case 'missing_file':
      case 'fabric_game_missing':
      case 'forge_boot_classpath': return 'document-cross';
      case 'native_crash': return 'native-crash';
      case 'lwjgl_module_missing':
      case 'lwjgl_version': return 'graphics';
      case 'launch_arg': return 'launch-args';
      case 'ipv6_unsupported': return 'network';
      case 'not_diagnosable': return 'session-ended';
      default: return 'classic-cross';
    }
  }

  /** Path 命令和线宽都使用 64px 设计坐标。变换整个原生画布，让两层线条随图形一起缩放。 */
  @Builder
  private Drawing_(key: string, mark: MarkPaths, scale: number) {
    Shape() {
      if (mark.tint !== undefined) {
        Path().width('64px').height('64px').commands(mark.tint).fill(this.theme.textHint).fillOpacity(0.12)
      }
      Path().width('64px').height('64px').commands(mark.outline)
        .stroke(this.category === 'not_diagnosable' ? this.theme.textSecondary : this.theme.textPrimary)
        .strokeWidth(key === 'split-link' ? '4.5px' : '3.7px').fill(Color.Transparent)
      Path().width('64px').height('64px').commands(mark.detail)
        .stroke(this.category === 'not_diagnosable' ? this.theme.textSecondary : this.theme.actionText)
        .strokeWidth(key === 'classic-cross' ? '4.7px' : '3.7px').fill(Color.Transparent)
      if (mark.muted !== undefined) {
        Path().width('64px').height('64px').commands(mark.muted).stroke(this.theme.textHint)
          .strokeWidth('2.7px').fill(Color.Transparent)
      }
    }.width('64px').height('64px').strokeLineCap(LineCapStyle.Round).strokeLineJoin(LineJoinStyle.Round)
      .scale({ x: scale, y: scale, centerX: '50%', centerY: '50%' })
  }

  build() {
    // 布局按 vp 占位，先把画布中心对齐，再围绕同一中心放大到目标物理像素。
    Stack({ alignContent: Alignment.Center }) {
      this.Drawing_(this.markKey_(), MARKS[this.markKey_()], this.getUIContext().vp2px(this.iconSize) / 64)
    }.id('mc-error-mark-' + this.markKey_()).width(this.iconSize).height(this.iconSize)
      .accessibilityLevel('yes').accessibilityText(this.category === 'not_diagnosable' ? '会话已结束' : '故障标记')
  }
}
