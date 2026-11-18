/** 签名准备的可恢复原因。账号授权与安装身份分开，网络/服务错误不能被误报成缺原材料。 */
export enum SigningPreparationIssue {
  None = '',
  Identity = 'identity',
  Material = 'material',
  Service = 'service',
  Permission = 'permission',
  Response = 'response',
  Preparation = 'preparation'
}

/** 仅携带安全的用户提示和恢复分类；不保留云端响应、账号标识、证书正文或认证头。 */
export class SigningPreparationError extends Error {
  readonly issue: SigningPreparationIssue;

  constructor(issue: SigningPreparationIssue, message: string) {
    super(message);
    this.name = 'SigningPreparationError';
    this.issue = issue;
  }
}
