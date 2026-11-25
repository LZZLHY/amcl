/**
 * 系统 Skill 只向当前前台业务对象投递。注册的是业务回调，脚本不持有页面、不模拟点击；
 * 跳转后的 owner、超时和页面换代均在执行副作用前重新核对。
 */
export type SkillFields = Record<string, Object>;
export type SkillHandler = (method: string, args: SkillFields) => Promise<SkillFields>;
export type UserDecisionObserver = (pending: () => boolean) => void;

/** 退出草稿的确认可能跨过组件退场。只跟踪这次选择和由它接手的保存/恢复，不占用其它草稿。 */
export class DraftLeaveDecision {
  private offered: boolean = true;
  private writes: number = 0;
  private visible: () => boolean;

  constructor(visible: () => boolean) { this.visible = visible; }
  pending(): boolean { return (this.offered && this.visible()) || this.writes > 0; }
  waiting(): boolean { return this.offered && this.visible(); }
  dismiss(): void { this.offered = false; }

  hold<T>(work: Promise<T>): void {
    if (!this.offered && this.writes === 0) return;
    this.writes++;
    const settled = (): void => { this.writes--; };
    work.then(settled,settled);
  }
}
type SkillOpener = (method: string, args: SkillFields) => boolean;

interface SkillSurface {
  owner: Object;
  handle: SkillHandler;
  available: () => boolean;
}

interface OpenerBinding {
  owner: Object;
  open: SkillOpener;
}

interface UserHandoff {
  method: string;
  ref: string;
  outcome?: SkillFields;
}

interface ActiveSkill {
  method: string;
  host: Object | undefined;
  respond: (value: SkillFields) => void;
  handoff?: UserHandoff;
  userDecision?: UserDecisionObserver;
}

export class LauncherSkillBus {
  private static surfaces: Map<string, SkillSurface> = new Map();
  private static openers: Map<string, OpenerBinding> = new Map();
  private static waiters: Map<string, () => void> = new Map();
  private static active: ActiveSkill | undefined = undefined;
  private static newRef: (() => string) | undefined = undefined;
  private static handoffs: UserHandoff[] = [];
  private static activeOwner: Object | undefined = undefined;
  private static chain: string[] = [];
  private static host: Object | undefined = undefined;
  private static allowed: ((domain: string, method: string) => boolean) | undefined = undefined;

  /** 私有 QA、历史 Want 和脚本自身均不能授予使用启动器的资格。 */
  static attach(owner: Object, allowed: (domain: string, method: string) => boolean, newRef: () => string): void {
    const previous = LauncherSkillBus.host;
    if (previous !== undefined && previous !== owner) LauncherSkillBus.detach(previous);
    LauncherSkillBus.host = owner;
    LauncherSkillBus.allowed = allowed;
    LauncherSkillBus.newRef = newRef;
    LauncherSkillBus.bind('handoffReceipt',owner,async (_method: string,args: SkillFields): Promise<SkillFields> =>
      LauncherSkillBus.readHandoff(args));
  }

  static detach(owner: Object): void {
    if (LauncherSkillBus.host !== owner) return;
    LauncherSkillBus.host = undefined;
    LauncherSkillBus.allowed = undefined;
    LauncherSkillBus.newRef = undefined;
    LauncherSkillBus.handoffs = [];
    LauncherSkillBus.surfaces.clear();
    LauncherSkillBus.openers.clear();
    LauncherSkillBus.waiters.forEach((wake: () => void): void => wake());
  }

  static bind(domain: string, owner: Object, handle: SkillHandler,
    available: () => boolean = (): boolean => true): void {
    if (!LauncherSkillBus.host) return;
    LauncherSkillBus.surfaces.set(domain, { owner: owner, handle: handle, available: available });
    const wake = LauncherSkillBus.waiters.get(domain);
    if (wake !== undefined) wake();
  }

  static unbind(domain: string, owner: Object): void {
    if (LauncherSkillBus.surfaces.get(domain)?.owner === owner) LauncherSkillBus.surfaces.delete(domain);
  }

  static bindOpener(domain: string, owner: Object, open: SkillOpener): void {
    if (!LauncherSkillBus.host) return;
    LauncherSkillBus.openers.set(domain, { owner: owner, open: open });
  }

  static unbindOpener(domain: string, owner: Object): void {
    if (LauncherSkillBus.openers.get(domain)?.owner === owner) {
      LauncherSkillBus.openers.delete(domain);
      const wake = LauncherSkillBus.waiters.get(domain);
      if (wake !== undefined) wake();
    }
  }

  private static current(domain: string): SkillSurface | undefined {
    const bound = LauncherSkillBus.surfaces.get(domain);
    return bound !== undefined && bound.available() ? bound : undefined;
  }

  private static async waitVisible(domain: string, binding: OpenerBinding): Promise<void> {
    // 转页本身不执行业务；超时后不留下任何可被迟到页面继续消费的指令。
    if (LauncherSkillBus.current(domain) !== undefined || LauncherSkillBus.openers.get(domain) !== binding) return;
    await new Promise<void>((resolve: () => void): void => {
      let timer: number = -1;
      const finish = (): void => {
        clearTimeout(timer);
        LauncherSkillBus.waiters.delete(domain);
        resolve();
      };
      LauncherSkillBus.waiters.set(domain, finish);
      timer = setTimeout(finish, 2500);
    });
  }

  /** 仅真实启动对话框/选择器的已认领方法可先回复；原业务仍独占写入，等待同一次用户决定。 */
  static awaitingUser(method: string): void {
    const active = LauncherSkillBus.active;
    const create = LauncherSkillBus.newRef;
    if (!active || active.method !== method || active.handoff || active.host !== LauncherSkillBus.host || !create) return;
    const entry: UserHandoff = { method: method, ref: create() };
    if (LauncherSkillBus.handoffs.length >= 32) LauncherSkillBus.handoffs.shift();
    LauncherSkillBus.handoffs.push(entry);
    active.handoff = entry;
    if (active.userDecision) active.userDecision((): boolean => active.handoff?.outcome === undefined);
    active.respond({ 'state':'needsUser', 'reason':'awaitingUser', 'method':method, 'operationRef':entry.ref });
  }

  /** 仍由原对话框接手的决定不能被普通页面导航关闭。 */
  static hasPendingDecision(): boolean {
    return LauncherSkillBus.active?.handoff !== undefined && LauncherSkillBus.active?.handoff?.outcome === undefined;
  }

  private static readHandoff(args: SkillFields): SkillFields {
    const row = LauncherSkillBus.handoffs.find((entry: UserHandoff): boolean =>
      entry.method === args['method'] && entry.ref === args['operationRef']);
    if (!row) return { 'state':'unknown', 'reason':'handoffNotRetained' };
    if (!row.outcome) return { 'state':'needsUser', 'method':row.method, 'operationRef':row.ref, 'reason':'awaitingUser' };
    return { 'state':'ready', 'method':row.method, 'operationRef':row.ref, 'outcome':row.outcome };
  }

  /** 独立结果引用仍由业务持有。调用所有者可观察从这次选择开始、到原续体不再派发写入的区间。 */
  static followUserDecision<T>(method: string, work: Promise<T>): void {
    const observer = LauncherSkillBus.active?.userDecision;
    if (LauncherSkillBus.active?.method !== method || !observer) return;
    let pending = true;
    observer((): boolean => pending);
    work.then((): void => { pending = false; }, (): void => { pending = false; });
  }

  /** 原生按钮型确认框无可等待的 Promise，按实际会话及业务阶段检查能否继续派发。 */
  static followUserCondition(method: string, pending: () => boolean): void {
    const active = LauncherSkillBus.active;
    if (active && active.method === method && active.userDecision) active.userDecision(pending);
  }

  static draftLeave(method: string, visible: () => boolean): DraftLeaveDecision {
    const decision = new DraftLeaveDecision(visible);
    LauncherSkillBus.followUserCondition(method, (): boolean => decision.pending());
    return decision;
  }

  /** 等待原用户决定时，只允许不会跳页、转发或修改草稿的已挂载观察；其余请求保持忙碌。 */
  private static async observe(domain: string, method: string, args: SkillFields): Promise<SkillFields> {
    const pure = (domain === 'handoffReceipt' && method === 'getLauncherHandoff') ||
      (domain === 'shell' && method === 'getLauncherState') ||
      (domain === 'library' && (method === 'getLauncherTasks' || method === 'listInstances'));
    if (!pure || !LauncherSkillBus.active?.handoff) return { 'state':'busy', 'reason':'anotherRequest' };
    const host = LauncherSkillBus.host;
    const permit = LauncherSkillBus.allowed;
    const surface = LauncherSkillBus.current(domain);
    if (!host || !surface || !permit || !permit(domain,method)) return { 'state':'unavailable', 'reason':'surfaceUnavailable' };
    try {
      const outcome = await surface.handle(method,args);
      return LauncherSkillBus.host === host && LauncherSkillBus.current(domain) === surface ? outcome :
        { 'state':'unknown', 'reason':'ownerChanged' };
    } catch (_) {
      return { 'state':'unknown', 'reason':'observationUnconfirmed' };
    }
  }

  static async call(domain: string, method: string, args: SkillFields, userDecision?: UserDecisionObserver): Promise<SkillFields> {
    if (LauncherSkillBus.active) return LauncherSkillBus.observe(domain,method,args);
    return new Promise<SkillFields>((resolve: (value: SkillFields) => void): void => {
      const call: ActiveSkill = { method:method, host:LauncherSkillBus.host, respond:resolve, userDecision:userDecision };
      LauncherSkillBus.active = call;
      LauncherSkillBus.dispatch(domain,method,args).then((outcome: SkillFields): void => {
        if (call.handoff) call.handoff.outcome = outcome;
        LauncherSkillBus.active = undefined;
        resolve(outcome);
      });
    });
  }

  /** 已认领的业务可转入实际持有子设置、弹窗或文件列表的对象；外部并发请求不能搭乘该调用。 */
  static async forward(owner: Object, domain: string, method: string, args: SkillFields): Promise<SkillFields> {
    if (owner !== LauncherSkillBus.activeOwner || !LauncherSkillBus.active ||
      LauncherSkillBus.chain.includes(domain)) return { 'state': 'unavailable', 'reason': 'invalidForward' };
    return LauncherSkillBus.dispatch(domain,method,args);
  }

  private static async dispatch(domain: string, method: string, args: SkillFields): Promise<SkillFields> {
    const previous = LauncherSkillBus.activeOwner;
    LauncherSkillBus.activeOwner = undefined;
    LauncherSkillBus.chain.push(domain);
    try {
      const host = LauncherSkillBus.host;
      const permit = LauncherSkillBus.allowed;
      if (!host || !permit || !permit(domain, method)) return { 'state': 'unavailable', 'reason': 'launcherNotReady' };
      let bound = LauncherSkillBus.current(domain);
      if (bound === undefined) {
        const opener = LauncherSkillBus.openers.get(domain);
        if (opener === undefined || !opener.open(method, args)) {
          return { 'state': 'unavailable', 'reason': 'surfaceUnavailable' };
        }
        await LauncherSkillBus.waitVisible(domain, opener);
        if (LauncherSkillBus.openers.get(domain) !== opener) return { 'state': 'unavailable', 'reason': 'ownerChanged' };
        bound = LauncherSkillBus.current(domain);
      }
      if (bound === undefined || LauncherSkillBus.host !== host || !permit(domain, method)) {
        return { 'state': 'unavailable', 'reason': 'surfaceUnavailable' };
      }
      LauncherSkillBus.activeOwner = bound.owner;
      const outcome = await bound.handle(method, args);
      return LauncherSkillBus.host === host ? outcome : { 'state': 'unknown', 'reason': 'hostReplaced' };
    } catch (_) {
      // 方法可能在提交后失败，调用者只能通过产品回读，不自动重放。
      return { 'state': 'unknown', 'reason': 'operationUnconfirmed' };
    } finally {
      LauncherSkillBus.activeOwner = previous;
      LauncherSkillBus.chain.pop();
    }
  }
}
