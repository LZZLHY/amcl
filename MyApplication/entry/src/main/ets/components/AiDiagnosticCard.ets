/**
 * 活动详情与旧错误页共用的第三方 AI 摘要。只接收经过形状校验的派生结果，
 * 不发起网络请求、不保存第二份事实源、不执行模型建议；完整回答由父组件保留。
 */
import { ThemeColors } from 'commons';
import { AiStructuredDiagnosis } from './AiDiagnostic';

@Component
export struct AiDiagnosticCard {
  @Prop theme: ThemeColors = new ThemeColors();
  @Prop diagnosis: AiStructuredDiagnosis | undefined = undefined;

  /** 单独换行展示模型自报的分数，避免窄屏下挤压标题；它不是应用核实的概率。 */
  private confidenceCaption_(): string {
    const value: string = this.diagnosis?.confidence ?? '';
    return value.length > 0 ? 'AI 自述置信度：' + value : '';
  }

  build() {
    Column({ space: 8 }) {
      Text('AI 排查摘要 · 仅供参考').fontSize(14).fontWeight(600)
        .fontColor(this.theme.textPrimary).width('100%')
      Text(this.diagnosis?.rootCause ?? '').fontSize(14).lineHeight(21)
        .fontColor(this.theme.textPrimary).width('100%')
      if (this.confidenceCaption_().length > 0) {
        Text(this.confidenceCaption_()).fontSize(12).fontColor(this.theme.textSecondary).width('100%')
      }
      if ((this.diagnosis?.troubleshooting.length ?? 0) > 0) {
        Text('排查建议').fontSize(12).fontWeight(600).fontColor(this.theme.textSecondary).width('100%')
        ForEach(this.diagnosis?.troubleshooting ?? [], (step: string, index: number) => {
          Text((index + 1).toString() + '. ' + step).fontSize(14).lineHeight(21)
            .fontColor(this.theme.textPrimary).width('100%')
        }, (step: string, index: number): string => index.toString() + ':' + step)
      }
      if ((this.diagnosis?.evidence.length ?? 0) > 0) {
        Text('AI 引用的线索 · 请核对原文').fontSize(12).fontWeight(600)
          .fontColor(this.theme.textSecondary).width('100%')
        ForEach(this.diagnosis?.evidence ?? [], (evidence: string, index: number) => {
          Text('· ' + evidence).fontSize(12).lineHeight(18).fontColor(this.theme.textSecondary).width('100%')
        }, (evidence: string, index: number): string => index.toString() + ':' + evidence)
      }
      if ((this.diagnosis?.caveats.length ?? 0) > 0) {
        Text(this.diagnosis?.caveats.join(' · ') ?? '').fontSize(12).lineHeight(18)
          .fontColor(this.theme.textSecondary).width('100%')
      }
    }.width('100%').padding(12).borderRadius(12).backgroundColor(this.theme.bgCard)
      .alignItems(HorizontalAlign.Start)
  }
}
