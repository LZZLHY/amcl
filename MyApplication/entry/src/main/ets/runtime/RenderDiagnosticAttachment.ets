export interface RenderDiagnosticAttachment {
  id: string;
  /** 0 = 独立开发者探针；大于 0 = 绑定某次游戏活动。 */
  activityId: number;
  capturedAt: number;
  detailed: boolean;
  text: string;
}
