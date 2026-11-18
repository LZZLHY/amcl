/**
 * 设置中的开发者账号投影。复用自更新的AuthSession/HUKS仓库，只处理登录，不创建更新或签名任务。
 * 页面隐藏和关闭登录会撤销本实例的异步代次；已可靠保存的授权继续供后续自更新读取。
 */
import { common } from '@kit.AbilityKit';
import { DeveloperAuthSession, DeveloperAuthState } from './DeveloperAuthSession';

@Observed
export class DeveloperAccountViewModel {
  state: DeveloperAuthState = DeveloperAuthState.Unavailable;
  checking: boolean = false;
  loginVisible: boolean = false;
  loginBusy: boolean = false;
  loginUrl: string = '';
  loginMessage: string = '';
  private auth: DeveloperAuthSession = new DeveloperAuthSession();
  private generation: number = 0;
  private active: boolean = false;

  /** 绑定当前Ability的私有目录；不复制JWT、账号标识或访问令牌到UI状态。 */
  initialize(context: common.UIAbilityContext): void { this.auth.initialize(context); }

  /** 路由返回时重新向官方验证；仅有本地记录不显示为已登录，网络故障也不显示为未登录。 */
  activate(): void {
    if (this.active) return;
    this.active = true;
    this.check();
  }
  deactivate(): void {
    this.active = false; this.generation++;
    this.auth.close(); this.checking = false;
    this.loginVisible = false; this.loginBusy = false; this.loginUrl = '';
  }

  statusText(): string {
    if (this.checking) return '验证中';
    if (this.state === DeveloperAuthState.Valid) return '已登录';
    if (this.state === DeveloperAuthState.Expired) return '重新登录';
    if (this.state === DeveloperAuthState.Missing) return '登录';
    return '重试';
  }
  description(): string {
    if (this.checking) return '正在核实已保存的登录状态';
    if (this.state === DeveloperAuthState.Valid) return '更新时自动使用已保存的登录';
    if (this.state === DeveloperAuthState.Expired) return '授权已失效，重新登录后自动保存';
    if (this.state === DeveloperAuthState.Missing) return '提前登录，下次更新自动继续';
    return '暂时无法验证，已保存的登录仍保留';
  }
  needsLogin(): boolean {
    return this.state === DeveloperAuthState.Missing || this.state === DeveloperAuthState.Expired;
  }
  act(): void { if (this.needsLogin()) this.login(); else this.check(); }

  /** 一次可见期只保留本次检查的结果；迟到结果不能覆盖新登录或重新打开的页面。 */
  async check(): Promise<void> {
    if (!this.active || this.checking || this.loginVisible) return;
    const generation = ++this.generation;
    this.checking = true;
    try {
      const state = await this.auth.restore();
      if (this.active && generation === this.generation && state !== DeveloperAuthState.Cancelled) this.state = state;
    } catch (_) {
      if (this.active && generation === this.generation) this.state = DeveloperAuthState.Unavailable;
    } finally {
      if (generation === this.generation) this.checking = false;
    }
  }

  /** 官方页面自行收集密码；成功通知已由AuthSession的可靠保存门禁保护，不启动更新。 */
  async login(): Promise<void> {
    if (!this.active || this.checking || this.loginBusy) return;
    const generation = ++this.generation;
    this.loginVisible = true; this.loginBusy = true; this.loginUrl = '';
    this.loginMessage = '正在建立安全登录会话…';
    try {
      const target = await this.auth.begin((success: boolean, message: string): void => {
        if (!this.active || generation !== this.generation) return;
        this.generation++; // 成功/失败回调可先于begin返回，阻止迟到URL重新打开已结束的页面。
        this.loginBusy = false; this.loginUrl = ''; this.loginVisible = !success;
        this.loginMessage = success ? '华为登录已保存' : message;
        if (success) this.state = DeveloperAuthState.Valid;
      });
      if (!this.active || generation !== this.generation) return;
      this.loginUrl = target;
      this.loginMessage = '登录成功后自动返回';
    } catch (_) {
      if (!this.active || generation !== this.generation) return;
      this.loginBusy = false; this.loginUrl = '';
      this.loginMessage = '暂时无法打开华为登录，请检查网络后重试';
    }
  }

  /** 用户取消只结束当前授权接收器，不清除此前保存的账号或签名材料。 */
  closeLogin(): void {
    this.generation++; this.auth.close();
    this.loginVisible = false; this.loginBusy = false; this.loginUrl = '';
  }
  loginFailed(message: string): void {
    if (!this.loginVisible) return;
    this.generation++; this.auth.close(); this.loginBusy = false; this.loginUrl = '';
    this.loginMessage = message;
  }
}
