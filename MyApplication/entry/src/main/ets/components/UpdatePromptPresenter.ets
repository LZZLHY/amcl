/**
 * 更新弹窗的UI席位。仅管理展示面归属和待显示回调，不持业务许可、事务、Context或执行器。
 * 首页与关于页共享一席，旧宿主释放只能释放自己的席位；迟到请求仍由宿主可见性/代次检查。
 */
export class UpdatePromptPresenter {
  private static owner: string = '';
  private static pending: Map<string, () => void> = new Map();

  /** 当前席位空闲或本宿主重用才成功，不能同时创建两个自更新controller。 */
  static claim(owner: string): boolean {
    if (UpdatePromptPresenter.owner.length > 0 && UpdatePromptPresenter.owner !== owner) return false;
    UpdatePromptPresenter.owner = owner; return true;
  }
  /** 只允许当前实例判断自己的展示席位，旧宿主不能对新面板发退出命令。 */
  static owns(owner: string): boolean { return UpdatePromptPresenter.owner === owner; }
  /** 每个宿主最多保留最新待显示请求，回调只在席位释放后尝试合格宿主。 */
  static defer(owner: string, present: () => void): void { UpdatePromptPresenter.pending.set(owner, present); }
  /** 幂等且有归属的释放，调用方随后可销毁自己的controller。 */
  static release(owner: string): void {
    if (UpdatePromptPresenter.owner !== owner) return;
    UpdatePromptPresenter.owner = '';
    const pending: (() => void)[] = [];
    UpdatePromptPresenter.pending.forEach((present: () => void): void => { pending.push(present); });
    UpdatePromptPresenter.pending.clear();
    pending.forEach((present: () => void): void => { present(); });
  }
  /** 宿主真正销毁时撤销迟到展示请求；不触碰其他宿主和业务Coordinator。 */
  static forget(owner: string): void { UpdatePromptPresenter.pending.delete(owner); UpdatePromptPresenter.release(owner); }
}
