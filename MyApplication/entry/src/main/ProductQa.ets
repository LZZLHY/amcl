/**
 * 默认开发产品的设备会话。宿主的 Want 只唤醒已在私有沙箱中授权的会话。
 * 控制权在启动器进程，实际业务由当前首页接收。设备断线或回执丢失不能重复调用业务。
 */
import { BusinessError } from '@kit.BasicServicesKit';
import { common, Want } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { AtomicFileWriter, DiagnosticPolicy } from 'commons';
import { collectProductIdentity } from './ets/product/ProductIdentityCollector';
import { isQaLauncherSkill, runQaLauncherSkill } from './QaLauncherSkill';
import { UserDecisionObserver } from './ets/launcherskill/LauncherSkillBus';

type Handler = (action: string, argsJson: string, requestId: string, userDecision?: UserDecisionObserver) => Promise<string>;
interface Grant { schema: number; session: string; expiresAt: number; actions: string[]; sourceRevision: string; }
interface Request { schema: number; session: string; sequence: number; id: string; action: string; args: Record<string, Object>; }
interface Result { status: string; data: Object; reason?: string; }
interface Response extends Request { status: string; data: Object; reason: string; }
interface BuildMetadata { name: string; sourceRevision: string; build: BuildMode; }
interface BuildMode { mode: string; }
interface Closed { schema: number; session: string; closed: boolean; }
interface UnsealedReply { dir: string; grant: Grant; reply: Response; }
interface PendingHandoff { root: string; grant: Grant; pending: Array<() => boolean>; }
interface Hello extends Grant { product: string; bundle: string; versionCode: number; versionName: string; }

/** 同型状态回执使用显式 DTO，让 ArkTS 编译器也能核实 wire 格式。 */
function failureResult(status: string, reason: string): Result {
  const empty: Record<string, Object> = {};
  return { status: status, reason: reason, data: empty };
}

function saveClosed(directory: string, session: string): void {
  const closed: Closed = { schema: 1, session: session, closed: true };
  save(directory + '/closed.json', closed);
}


const ACTIONS: string[] = ['versions.list', 'versions.inspect', 'versions.remote', 'versions.select', 'versions.install',
  'tasks.list', 'tasks.get', 'game.launch', 'game.observe', 'game.current', 'loaders.list', 'loaders.games', 'loaders.versions',
  'launcher.home', 'resources.open', 'accounts.open', 'library.open',
  'versions.rename', 'versions.delete.prepare', 'versions.delete.confirm', 'versions.delete.cancel',
  'versions.orphans.prepare', 'versions.orphans.confirm', 'versions.orphans.cancel',
  'settings.version', 'settings.resolution', 'settings.jdk', 'tasks.control',
  'tasks.controlState', 'library.list', 'library.close', 'library.toggle',
  'library.delete.prepare', 'library.delete.confirm', 'library.delete.cancel', 'accounts.list',
  'accounts.select', 'accounts.addOffline', 'accounts.login', 'accounts.check',
  'accounts.prepareRemove', 'accounts.remove', 'accounts.cancelRemove', 'accounts.close',
  'resources.status', 'resources.search', 'resources.next', 'resources.versions', 'resources.plan',
  'resources.option', 'resources.install', 'resources.task', 'resources.dismiss',
  'modpacks.options', 'modpacks.choose', 'modpacks.confirm', 'modpacks.importLocal',
  'modpacks.importStatus', 'modpacks.localPlan', 'modpacks.installLocal'];
const HEX_ID: RegExp = /^[a-f0-9]{32}$/;
const MAX_STEPS = 1024;
// 容纳全部已列名的授权与官方方法的长文本；请求与再次 JSON 编码的 claim 均按文件字节限流。
const MAX_GRANT_BYTES = 32768;
const MAX_SKILL_REQUEST_BYTES = 2 * 1024 * 1024;

/** 区分文件不存在和读取失败。路径只由常量及经过校验的编号构成。 */
function readFile(path: string, limit: number): string | undefined {
  let stat: fs.Stat;
  try { stat = fs.lstatSync(path); }
  catch (error) {
    if ((error as BusinessError).code === 13900002) return undefined;
    throw error as Error;
  }
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > limit) throw new Error('QA 文件无效');
  return fs.readTextSync(path);
}

function ensureDirectory(path: string): void {
  if (!fs.accessSync(path)) fs.mkdirSync(path);
  const stat = fs.lstatSync(path);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('QA 会话目录无效');
}

function save(path: string, value: Object): void {
  AtomicFileWriter.write(path, JSON.stringify(value));
}

/** 原子替换已经可见但父目录未确认同步时，只核对原字节并同步目录。即使宿主已读走结果也不覆写。 */
function sealReply(directory: string, reply: Response): void {
  const path = directory + '/reply-' + reply.sequence + '.json';
  const bytes = JSON.stringify(reply);
  const existing = readFile(path, bytes.length * 4);
  if (existing === undefined) {
    AtomicFileWriter.write(path, bytes);
    return;
  }
  if (existing !== bytes) throw new Error('QA 原序号已有不同结果');
  syncDirectory(directory);
}

function syncDirectory(directory: string): void {
  const parent = fs.openSync(directory, fs.OpenMode.READ_ONLY);
  try { fs.fsyncSync(parent.fd); }
  finally { fs.closeSync(parent); }
}

/** 只在恢复已登记会话时定位最后一份回执。已有文件在崩溃前可能刚刚 rename，先同步再承认下一序号。 */
function nextSequence(directory: string, grant: Grant): number {
  let seq = 1;
  while (seq <= MAX_STEPS && fs.accessSync(directory + '/reply-' + seq + '.json')) seq++;
  if (seq > 1) {
    const number = seq - 1;
    const contents = readFile(directory + '/reply-' + number + '.json', Number.MAX_SAFE_INTEGER);
    if (contents === undefined) throw new Error('QA 已发布回执消失');
    const reply = JSON.parse(contents) as Response;
    if (reply.schema !== 1 || reply.session !== grant.session || reply.sequence !== number || !HEX_ID.test(reply.id) ||
      !['ok','accepted','needsUser','rejected','unknown'].includes(reply.status) || !reply.data ||
      typeof reply.data !== 'object' || typeof reply.action !== 'string') throw new Error('QA 已发布回执身份不符');
    let normalized = '';
    try { normalized = argumentsKey(reply.args,isQaLauncherSkill(reply.action)); } catch (_) { /* 非法参数的拒绝回执保留原值。 */ }
    const key = JSON.stringify([reply.id,reply.action,normalized || JSON.stringify(reply.args)]);
    if (readFile(directory + '/claim-' + number + '.json', MAX_SKILL_REQUEST_BYTES * 2 + 256) !== key) {
      throw new Error('QA 已发布回执与原认领不同');
    }
    syncDirectory(directory);
  }
  return seq;
}

/** 冷恢复只封存已实际认领的请求；授权结束不能重新调用业务，也不为尚未认领的输入制造结果。 */
function closeRegistered(directory: string, grant: Grant): boolean {
  if (!fs.accessSync(directory)) return false;
  ensureDirectory(directory);
  if (readFile(directory + '/grant.json', MAX_GRANT_BYTES) !== JSON.stringify(grant)) return false;
  const closed = readFile(directory + '/closed.json', 256);
  if (closed !== undefined) {
    const record = JSON.parse(closed) as Closed;
    if (record.schema !== 1 || record.session !== grant.session || record.closed !== true) throw new Error('QA 关闭记录身份不符');
    syncDirectory(directory);
    return true;
  }
  const seq = nextSequence(directory,grant);
  const key = readFile(directory + '/claim-' + seq + '.json', MAX_SKILL_REQUEST_BYTES * 2 + 256);
  if (key !== undefined) {
    const claim = JSON.parse(key) as string[];
    if (!Array.isArray(claim) || claim.length !== 3 || typeof claim[0] !== 'string' || !HEX_ID.test(claim[0]) ||
      typeof claim[1] !== 'string' || typeof claim[2] !== 'string') throw new Error('无法核实原请求');
    const args = JSON.parse(claim[2]) as Record<string, Object>;
    const empty: Record<string, Object> = {};
    const reply: Response = { schema: 1, session: grant.session, sequence: seq, id: claim[0],
      action: claim[1], args: args, status: 'unknown', data: empty, reason: '原请求结局未知，请回读产品状态' };
    sealReply(directory, reply);
  }
  saveClosed(directory, grant.session);
  return true;
}

/** 首版业务参数是有界的标量，排序后同一请求可在重连时比较参数身份。 */
function argumentsKey(args: Record<string, Object>, namedSkill: boolean): string {
  if (!args || typeof args !== 'object' || Array.isArray(args)) throw new Error('无效参数');
  const keys = Object.keys(args).sort();
  const normalized: Record<string, Object> = {};
  if (keys.length > 12) throw new Error('参数过多');
  for (const key of keys) {
    const value = args[key];
    if (!/^[a-zA-Z][a-zA-Z0-9]{0,39}$/.test(key) || key === 'constructor' || key === 'prototype' ||
      (typeof value !== 'string' && typeof value !== 'boolean' && typeof value !== 'number') ||
      (typeof value === 'string' && value.length > (namedSkill ? 16384 : 512))) throw new Error('无效参数');
    normalized[key] = value;
  }
  return JSON.stringify(normalized);
}

interface Surface { owner: Object; handle: Handler; }

export class ProductQa {
  private static surfaces: Map<string, Surface> = new Map<string, Surface>();

  /** 页面注册自己的产品上下文。旧组件异步销毁时不能撤销已经接管的组件。 */
  static bindSurface(name: string, owner: Object, handle: Handler): void {
    ProductQa.surfaces.set(name, { owner: owner, handle: handle });
  }

  static unbindSurface(name: string, owner: Object): void {
    if (ProductQa.surfaces.get(name)?.owner === owner) ProductQa.surfaces.delete(name);
  }

  /** 打开页面的动作由首页派发，其余操作只会到达当前挂载的对应组件。 */
  private static handler(action: string): Handler | undefined {
    if (isQaLauncherSkill(action)) return runQaLauncherSkill;
    if (action.startsWith('game.')) return ProductQa.game;
    if (action === 'resources.open' || action === 'accounts.open' || action === 'library.open' ||
      action.startsWith('launcher.') || action.startsWith('settings.') || action.startsWith('versions.delete') ||
      action.startsWith('versions.orphans.') || action === 'versions.rename') return ProductQa.surfaces.get('management')?.handle;
    if (action.startsWith('resources.') || action.startsWith('modpacks.')) return ProductQa.surfaces.get('resources')?.handle;
    if (action.startsWith('accounts.')) return ProductQa.surfaces.get('accounts')?.handle;
    if (action.startsWith('library.')) return ProductQa.surfaces.get('library')?.handle;
    return ProductQa.versions;
  }

  private static owner: Object | undefined;
  private static versions: Handler | undefined;
  private static game: Handler | undefined;
  private static ability: common.UIAbilityContext | undefined;
  private static grant: Grant | undefined;
  private static root: string = '';
  private static expected: number = 1;
  private static timer: number = -1;
  private static working: boolean = false;
  private static unsealed: UnsealedReply | undefined;
  private static handoff: PendingHandoff | undefined;

  /** 第一份 needsUser 只完成传输，原授权仍持有这次交互。直到原回调终结才释放关闭/切换资格。 */
  private static handoffSession(): string {
    const held = ProductQa.handoff;
    if (held === undefined) return '';
    held.pending = held.pending.filter((check: () => boolean): boolean => check());
    if (held.pending.length > 0) return held.grant.session;
    const session = held.grant.session;
    if ((held.grant.expiresAt <= Date.now() || readFile(held.root + '/close-' + session + '.txt',128) === session) &&
      !closeRegistered(held.root + '/' + session,held.grant)) throw new Error('原交接会话暂不能关闭');
    ProductQa.handoff = undefined;
    return '';
  }

  /** 只有原具名方法实际启动的用户决定才占用本次会话；独立读回和入队后的长任务不会登记。 */
  private static holdDecision(root: string, grant: Grant, pending: () => boolean): void {
    const held = ProductQa.handoff;
    if (held === undefined) ProductQa.handoff = { root: root, grant: grant, pending: [pending] };
    else if (held.grant.session === grant.session) held.pending.push(pending);
    else throw new Error('无法将原用户决定归入另一会话');
  }

  /** 保持原执行结果到持久化成功。故障重试早于读入下一个请求，避免下一序号把未封存回执挤掉。 */
  private static finishReply(): void {
    const pending = ProductQa.unsealed;
    if (!pending) return;
    sealReply(pending.dir, pending.reply);
    if (ProductQa.grant === pending.grant) ProductQa.expected = pending.reply.sequence + 1;
    ProductQa.unsealed = undefined;
  }

  /** 持有当前页面原操作。旧页面离开时不能清掉新页面注册。 */
  static bind(owner: Object, versions: Handler, game: Handler): void {
    ProductQa.owner = owner; ProductQa.versions = versions; ProductQa.game = game;
  }

  static unbind(owner: Object): void {
    if (ProductQa.owner !== owner) return;
    ProductQa.owner = undefined; ProductQa.versions = undefined; ProductQa.game = undefined;
  }

  static sessionDirectory(): string {
    const grant = ProductQa.grant;
    return grant && grant.expiresAt > Date.now() ? ProductQa.root + '/' + grant.session : '';
  }

  /** 销毁或到期只停止本会话轮询，正在执行的真实任务仍由其产品所有者管理。 */
  static detach(context: common.UIAbilityContext): void {
    if (ProductQa.ability !== context) return;
    if (ProductQa.timer !== -1) clearInterval(ProductQa.timer);
    ProductQa.timer = -1; ProductQa.grant = undefined; ProductQa.ability = undefined;
  }

  /** 冷启动可重新读取原授权，热启动只认宿主提供的相同会话编号。失败不干扰应用初始化。 */
  static activate(context: common.UIAbilityContext, want: Want, cold: boolean): boolean {
    const signal = want.parameters?.['amclQaSession'];
    if ((!cold && signal === undefined) || !DiagnosticPolicy.hasTestHooks()) return false;
    if (signal !== undefined && (typeof signal !== 'string' || !HEX_ID.test(signal))) return false;
    try {
      const root = context.filesDir + '/amcl-qa-v1';
      if (!fs.accessSync(root)) return false;
      ensureDirectory(root);
      // 新描述符可能已经取代了过期会话。针对原编号的关闭唤醒只读其登记原件，绝不恢复执行资格。
      const closeSignal = typeof signal === 'string' && readFile(root + '/close-' + signal + '.txt',128) === signal;
      const original = closeSignal ? root + '/' + String(signal) : root;
      if (closeSignal && !fs.accessSync(original)) return false;
      ensureDirectory(original);
      const text = readFile(original + (closeSignal ? '/grant.json' : '/session.json'), MAX_GRANT_BYTES);
      if (!text) return false;
      const grant = JSON.parse(text) as Grant;
      const now = Date.now();
      if (grant.schema !== 1 || typeof grant.session !== 'string' || !HEX_ID.test(grant.session) ||
        (signal !== undefined && signal !== grant.session) || !Number.isSafeInteger(grant.expiresAt) ||
        grant.expiresAt - now > 1800000 || !Array.isArray(grant.actions) ||
        !grant.actions.length || new Set<string>(grant.actions).size !== grant.actions.length ||
        !grant.actions.every((a: string): boolean => typeof a === 'string' && (ACTIONS.includes(a) || isQaLauncherSkill(a))) ||
        !/^[0-9a-f]{40}$/.test(grant.sourceRevision)) return false;
      const raw = context.resourceManager.getRawFileContentSync('product-profile.json');
      const meta = JSON.parse(new util.TextDecoder().decodeWithStream(raw)) as BuildMetadata;
      if (meta.name !== 'default' || meta.build.mode !== 'debug' || meta.sourceRevision !== grant.sourceRevision) return false;
      const dir = root + '/' + grant.session;
      const closing = closeSignal || grant.expiresAt <= now || readFile(root + '/close-' + grant.session + '.txt', 128) === grant.session;
      if (ProductQa.working) return !closing && signal !== undefined && ProductQa.grant !== undefined &&
        JSON.stringify(ProductQa.grant) === JSON.stringify(grant);
      ProductQa.finishReply();
      const heldSession = ProductQa.handoffSession();
      if (heldSession && (closing || heldSession !== grant.session)) return false;
      if (closing) {
        if (closeRegistered(dir, grant) && ProductQa.grant?.session === grant.session && ProductQa.ability) {
          ProductQa.detach(ProductQa.ability);
        }
        return false;
      }
      // 运行中的会话为独占写者，另一次开场不能夺走正在处理的请求。
      if (ProductQa.grant) {
        const previous = ProductQa.grant;
        if (previous.session === grant.session) return JSON.stringify(previous) === JSON.stringify(grant) && signal !== undefined;
        if (previous.expiresAt > now && readFile(ProductQa.root + '/close-' + previous.session + '.txt', 128) !== previous.session) return false;
        if (!closeRegistered(ProductQa.root + '/' + previous.session, previous)) return false;
      }
      // 普通冷启动仅认回先前显式开场的授权；未唤醒的描述符不能自行取得执行资格。
      if (signal === undefined && !fs.accessSync(dir)) return false;
      ensureDirectory(dir);
      if (readFile(dir + '/closed.json', 256) !== undefined) return false;
      const saved = readFile(dir + '/grant.json', MAX_GRANT_BYTES);
      if (saved === undefined && signal === undefined) return false;
      if (saved === undefined) save(dir + '/grant.json', grant);
      else if (saved !== JSON.stringify(grant)) return false;
      const sequence = nextSequence(dir,grant);
      const identity = collectProductIdentity();
      if (identity.product !== 'default' || identity.versionCode < 1 || identity.versionName === 'unknown') return false;
      const hello: Hello = { schema: 1, session: grant.session, product: identity.product,
        versionName: identity.versionName, versionCode: identity.versionCode, sourceRevision: meta.sourceRevision,
        bundle: context.abilityInfo.bundleName, actions: grant.actions, expiresAt: grant.expiresAt };
      save(root + '/hello-' + grant.session + '.json', hello);
      if (ProductQa.ability) ProductQa.detach(ProductQa.ability);
      ProductQa.ability = context; ProductQa.root = root; ProductQa.grant = grant; ProductQa.expected = sequence;
      ProductQa.timer = setInterval((): void => {
        ProductQa.tick().catch((): void => { /* 未取得完整耐久证据时，保持原请求供重连。 */ });
      }, 350);
      return signal !== undefined;
    } catch (_) { return false; }
  }

  /** 单在途。先持久化序号和唯一请求身份才派发，进程死亡留下的 claim 一律进入结果未知。 */
  private static async tick(): Promise<void> {
    const grant = ProductQa.grant;
    const context = ProductQa.ability;
    if (!grant || !context) return;
    const root = ProductQa.root;
    // 慢请求也受授权期限限制；仍有在途副作用时不写已安全关闭的收据。
    if (ProductQa.working) return;
    ProductQa.finishReply();
    const heldSession = ProductQa.handoffSession();
    if (Date.now() >= grant.expiresAt || readFile(root + '/close-' + grant.session + '.txt', 128) === grant.session) {
      if (heldSession === grant.session) return;
      if (closeRegistered(root + '/' + grant.session, grant)) ProductQa.detach(context);
      return;
    }
    const dir = root + '/' + grant.session;
    const seq = ProductQa.expected;
    const id = readFile(root + '/commit-' + grant.session + '.txt', 64);
    if (!id || !HEX_ID.test(id) || seq > MAX_STEPS) return;
    const namedGrant = grant.actions.some((action: string): boolean => isQaLauncherSkill(action));
    const body = readFile(root + '/next-' + grant.session + '.json', namedGrant ? MAX_SKILL_REQUEST_BYTES : 8192);
    if (!body) return;
    const req = JSON.parse(body) as Request;
    if (req.schema !== 1 || req.id !== id || req.session !== grant.session || req.sequence !== seq ||
      typeof req.action !== 'string' || req.action.length > 48) return;
    // 页面首次绑定前不认领操作，也不因 UI 预热向调用方谎报拒绝。
    if (!ProductQa.owner) return;
    let argsJson: string = '';
    try { argsJson = argumentsKey(req.args, isQaLauncherSkill(req.action)); } catch (_) { /* 下文落盘明确拒绝。 */ }
    const claimPath = dir + '/claim-' + seq + '.json';
    const identityPath = dir + '/id-' + id + '.json';
    const existing = readFile(claimPath, namedGrant ? 2 * MAX_SKILL_REQUEST_BYTES + 256 : 8192);
    const key = JSON.stringify([id, req.action, argsJson || JSON.stringify(req.args)]);
    if (existing !== undefined && existing !== key) return;
    ProductQa.working = true;
    try {
      let result: Result = failureResult('unknown', '原请求结局未知，请回读产品状态');
      // 双身份先落盘。即使进程恰好死在两次写之间，恢复也会占用原编号而不重派。
      const indexed = readFile(identityPath, 64);
      if (existing === undefined) AtomicFileWriter.write(claimPath, key);
      if (indexed === undefined) AtomicFileWriter.write(identityPath, String(seq));
      if (indexed !== undefined && indexed !== String(seq)) {
        result = failureResult('rejected', '请求编号已在本会话使用');
      } else if (existing === undefined && indexed === undefined) {
        if (!argsJson) {
          result = failureResult('rejected', '无效的动作参数');
        } else if (!grant.actions.includes(req.action) ||
          (req.action === 'skill.readJavaArchiveImport' && !grant.actions.includes('skill.pickJavaRuntimeArchive')) ||
          (req.action === 'skill.readUpdatePackageSelection' && !grant.actions.includes('skill.openUpdateSource')) ||
          (req.action === 'skill.getLauncherHandoff' &&
          (typeof req.args['method'] !== 'string' || !grant.actions.includes('skill.' + String(req.args['method']))))) {
          result = failureResult('rejected', '动作未在本次会话授权');
        } else {
          const handler = ProductQa.handler(req.action);
          if (!handler) result = failureResult('needsUser', 'SURFACE_NOT_OPEN');
          else {
            try {
              result = JSON.parse(await handler(req.action, argsJson, id,
                (pending: () => boolean): void => ProductQa.holdDecision(root,grant,pending))) as Result;
            }
            catch (_) { result = failureResult('unknown', '产品调用未返回可验证结果'); }
          }
        }
      }
      if (!result || !['ok','accepted','needsUser','rejected','unknown'].includes(result.status) ||
        !result.data || typeof result.data !== 'object') {
        result = failureResult('unknown', '产品返回不符合动作契约');
      }
      if (req.action === 'skill.getActivityChoiceOutcome') {
        const facts = result.data as Record<string, Object>;
        if (typeof facts['operation'] === 'string' && !grant.actions.includes('skill.' + String(facts['operation']))) {
          result = failureResult('rejected','原活动操作未获本次会话授权');
        }
      }
      const reply: Response = { schema: 1, session: grant.session, sequence: seq, id: id,
        action: req.action, args: req.args, status: result.status, data: result.data, reason: result.reason ?? '' };
      ProductQa.unsealed = { dir: dir, grant: grant, reply: reply };
      ProductQa.finishReply();
    } finally { ProductQa.working = false; }
  }
}
