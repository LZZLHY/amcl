import { util } from '@kit.ArkTS';
import { Account, AccountType, getAccountManager } from 'account';
import { ProductQa } from 'entry/ProductQa';
import { AccountRemovalChoice, AccountSheetActions, AddAccountActions } from './ets/runtime/AccountSheetActions';

interface AccountItem { accountRef: string; type: string; selected: boolean; }
interface Removal { ref: string; token: string; choice: AccountRemovalChoice; until: number; }
interface PendingAdd {
  session: string;
  run: (actions: AddAccountActions) => Promise<string>;
  resolve: (response: string) => void;
  timer: number;
}

function token(): string { return util.generateRandomUUID().replace(/-/g, '').toLowerCase(); }
function reply(status: string, data: Record<string, Object>, reason: string = ''): string {
  return JSON.stringify({ status, data, reason });
}
function status(reason: string, code: string = 'rejected'): string {
  const empty: Record<string, Object> = {};
  return reply(code, empty, reason);
}
function keys(args: Record<string, Object>, expected: string[]): boolean {
  return Object.keys(args).length === expected.length && expected.every((k: string): boolean => typeof args[k] === 'string');
}

/** 每次进入页面及每一份沙箱授权都拥有独立的匿名引用和二次确认；不序列化账户本体或错误原文。 */
export class ProductQaAccounts {
  private static current: ProductQaAccounts | undefined;
  private refs: WeakMap<Account, string> = new WeakMap<Account, string>();
  private session: string = '';
  private pending: PendingAdd | undefined;
  private removal: Removal | undefined;
  private closedAck: (() => void) | undefined;
  private owner: Object;
  private port: AccountSheetActions;
  private constructor(owner: Object, port: AccountSheetActions) { this.owner = owner; this.port = port; }

  static bind(owner: Object, make: () => AccountSheetActions): void {
    if (ProductQaAccounts.current) ProductQaAccounts.current.retire();
    const surface = new ProductQaAccounts(owner, make());
    ProductQaAccounts.current = surface;
    ProductQa.bindSurface('accounts', owner, (action: string, args: string): Promise<string> => surface.handle(action, args));
  }
  static unbind(owner: Object): void {
    if (ProductQaAccounts.current?.owner === owner) {
      ProductQaAccounts.current.closedAck?.();
      ProductQaAccounts.current.retire();
      ProductQaAccounts.current = undefined;
    }
    ProductQa.unbindSurface('accounts', owner);
  }

  /** 子面板真正挂载后再调用原表单动作。手动打开的新增页没有请求，直接返回。 */
  static addShown(owner: Object, actions: AddAccountActions): void {
    const surface = ProductQaAccounts.current;
    const pending = surface?.pending;
    if (!surface || surface.owner !== owner || !pending) return;
    clearTimeout(pending.timer); surface.pending = undefined;
    if (!surface.live(pending.session)) { pending.resolve(status('ACCOUNT_PANEL_CHANGED')); return; }
    pending.run(actions).then(pending.resolve, (): void => pending.resolve(status('ACCOUNT_OUTCOME_UNKNOWN','unknown')));
  }
  private live(session: string): boolean {
    return ProductQaAccounts.current === this && session.length > 0 && ProductQa.sessionDirectory() === session;
  }
  private retire(): void {
    if (this.pending) { clearTimeout(this.pending.timer); this.pending.resolve(status('ACCOUNT_PANEL_CHANGED')); this.pending = undefined; }
    if (this.removal) this.port.cancelRemove(this.removal.choice);
    this.removal = undefined; this.refs = new WeakMap<Account, string>(); this.session = '';
  }
  private ref(account: Account): string {
    const old = this.refs.get(account);
    if (old) return old;
    const next = token(); this.refs.set(account, next); return next;
  }

  /** 只有原面板真实退场才确认 close，父组件的同步状态赋值不充当退场证据。 */
  private closePanel(): Promise<string> {
    return new Promise<string>((resolve): void => {
      const timer = setTimeout((): void => {
        this.closedAck = undefined;
        resolve(status('CLOSE_UNCONFIRMED', 'unknown'));
      }, 4000);
      this.closedAck = (): void => {
        clearTimeout(timer);
        this.closedAck = undefined;
        resolve(reply('ok', { 'closed': true }));
      };
      this.port.close();
    });
  }

  private async openAdd(run: (actions: AddAccountActions) => Promise<string>): Promise<string> {
    return new Promise<string>((resolve): void => {
      const timer = setTimeout((): void => {
        if (this.pending?.timer === timer) { this.pending = undefined; resolve(status('ADD_PANEL_UNAVAILABLE','unknown')); }
      }, 5000);
      this.pending = { session: this.session, run: run, resolve: resolve, timer: timer };
      this.port.openAdd();
    });
  }
  private async handle(action: string, body: string): Promise<string> {
    const session = ProductQa.sessionDirectory();
    if (!this.live(session)) return status('ACCOUNT_PANEL_CHANGED');
    if (session !== this.session) { this.retire(); this.session = session; }
    if (this.removal && Date.now() >= this.removal.until) {
      this.port.cancelRemove(this.removal.choice); this.removal = undefined;
    }
    const manager = getAccountManager();
    if (!manager.isReady() || !this.port.ready()) return status('ACCOUNT_PANEL_BUSY','needsUser');
    try {
      const args = JSON.parse(body) as Record<string, Object>;
      const accounts = manager.list();
      const selected = manager.getSelectedId();
      if (action === 'accounts.list' && keys(args, [])) {
        const rows = accounts.map((acc: Account): AccountItem => ({accountRef:this.ref(acc), type:acc.type, selected:acc.id===selected}));
        return reply('ok', { 'accounts':rows, 'total':rows.length });
      }
      const confirmationAction = action === 'accounts.remove' || action === 'accounts.cancelRemove';
      if (this.port.hasConfirmation() && !confirmationAction) return status('ACCOUNT_CONFIRMATION_PENDING','needsUser');
      if (action === 'accounts.close' && keys(args, [])) return await this.closePanel();
      if (action === 'accounts.login' && keys(args, ['provider'])) {
        const provider = args['provider'] as string;
        if (provider !== 'microsoft' && provider !== 'authlib') return status('INVALID_PROVIDER');
        return await this.openAdd(async (form: AddAccountActions): Promise<string> => {
          const opened = await form.login(provider);
          if (!this.live(session) || !opened) return status('LOGIN_FORM_UNAVAILABLE','unknown');
          return reply('needsUser', {'provider':provider}, 'USER_AUTHORIZATION_REQUIRED');
        });
      }
      if (action === 'accounts.addOffline' && keys(args, ['name'])) {
        const name = args['name'] as string;
        if (!/^[a-zA-Z0-9_]{1,16}$/.test(name)) return status('INVALID_OFFLINE_NAME');
        return await this.openAdd(async (form: AddAccountActions): Promise<string> => {
          const id = await form.offline(name);
          const account = manager.findById(id);
          if (!this.live(session) || !account || account.type !== AccountType.OFFLINE || manager.getSelectedId() !== id) return status('ADD_OUTCOME_UNCONFIRMED','unknown');
          return reply('ok', {'accountRef':this.ref(account), 'selected':true});
        });
      }
      if (!keys(args, confirmationAction ? ['accountRef','confirmation'] : ['accountRef'])) return status('INVALID_ARGUMENTS');
      const ref = args['accountRef'] as string;
      const target = accounts.find((account: Account): boolean => this.refs.get(account) === ref);
      if (!target) return status('STALE_ACCOUNT_REFERENCE');
      if (action === 'accounts.check') {
        const state = target.type === AccountType.OFFLINE ? 'offline' : (await target.isUsable() ? 'locally-usable' : 'needs-login');
        if (!this.live(session) || manager.findById(target.id) !== target) return status('STALE_ACCOUNT_REFERENCE');
        return reply('ok', {'accountRef':ref,'state':state});
      }
      if (action === 'accounts.select') {
        const ok = await this.port.select(target);
        if (!this.live(session) || !ok || manager.findById(target.id) !== target || manager.getSelectedId() !== target.id) return status('SELECTION_UNCONFIRMED','unknown');
        return reply('ok', {'accountRef':ref,'selected':true});
      }
      if (action === 'accounts.prepareRemove') {
        const choice = this.port.prepareRemove(target.id);
        if (!choice || choice.target !== target) return status('STALE_ACCOUNT_REFERENCE');
        const confirmation = token(); this.removal = {ref:ref,token:confirmation,choice:choice,until:Date.now()+60000};
        return reply('ok', {'accountRef':ref, 'confirmation':confirmation});
      }
      if (!confirmationAction) return status('UNKNOWN_ACTION');
      const plan = this.removal;
      if (!plan || plan.ref !== ref || plan.token !== args['confirmation'] || plan.choice.target !== target) return status('STALE_CONFIRMATION');
      this.removal = undefined;
      if (action === 'accounts.cancelRemove') return this.port.cancelRemove(plan.choice) ? reply('ok',{'cancelled':true}) : status('STALE_CONFIRMATION');
      const ok = await this.port.confirmRemove(plan.choice);
      if (!ok || manager.findById(target.id) !== undefined) {
        this.port.cancelRemove(plan.choice);
        return status('REMOVAL_UNCONFIRMED', 'unknown');
      }
      this.refs.delete(target);
      return reply('ok', {'removed':true});
    } catch (_) { return status('ACCOUNT_OUTCOME_UNKNOWN','unknown'); }
  }
}
