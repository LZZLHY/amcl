/**
 * store新游戏准入。偏好负责用户的持久选择，私有原子记录负责跨进程即时撤销。
 * child从经验证的启动票据取得epoch/revision，并在JVM派发前重读磁盘；不把冻结偏好
 * 当实时授权。非store原样放行；已运行会话的返回/退出不属于新启动，不受此门控干扰。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AtomicFileWriter } from 'commons';
import { PreferenceManager } from 'feature_system';
import { ProductBuildProfile } from 'entry/ProductBuildProfile';
import { ProcessActivityCoordinator, SharedProcessGameLease } from 'feature_core';

/** epoch区分启动器进程，revision使关闭再打开也不能恢复旧准备请求；不含账号数据。 */
interface RunAdmissionRecord { schema: number; epoch: string; revision: number; allowed: boolean; }

export class GameRunAdmission {
  /**
   * 派发路线由 ProductInputProfile 冻结后调用。真实隔离游戏不预约父进程；共享路线
   * 在第一个准备 await 前同步预约。失败只释放未提交预约，不取消正在执行的文件任务。
   */
  static reserveProcessLaunch(isolatedGameProcess: boolean): SharedProcessGameLease | undefined {
    return isolatedGameProcess ? undefined : ProcessActivityCoordinator.instance().acquireSharedGame();
  }

  private static ownerRoot: string = '';
  private static epoch: string = '';
  private static revision: number = 0;
  private static allowed: boolean = false;
  private static installedTicket: string = '';
  private static intent: number = 0;
  private static tail: Promise<void> = Promise.resolve();

  /** 只由EntryAbility调用；新epoch撤销旧进程留下的未开始票据，失败不开放运行。 */
  static initialize(context: common.UIAbilityContext): void {
    if (!ProductBuildProfile.storeChannel) return;
    if (GameRunAdmission.ownerRoot === context.filesDir && GameRunAdmission.epoch.length > 0) return;
    // 偏好与准入组成一次开启结果：偏好已flush但发布/回滚失败时，不能下次启动仅凭true
    // 重新授予。只有原记录也确认开放才恢复；缺失或损坏需用户再次明确保存。
    let restore: boolean = false;
    if (new PreferenceManager(context).storeAllowDebug) {
      try {
        const path = context.filesDir + '/game-run-admission/state.json';
        const stat = fs.lstatSync(path);
        if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 2048) throw new Error('原运行准入记录无效');
        const previous = JSON.parse(fs.readTextSync(path)) as RunAdmissionRecord;
        restore = previous.schema === 1 &&
          typeof previous.epoch === 'string' && previous.epoch.length > 0 && Number.isSafeInteger(previous.revision) &&
          previous.revision > 0 && previous.allowed === true;
      } catch (_) { restore = false; }
    }
    GameRunAdmission.ownerRoot = context.filesDir;
    GameRunAdmission.epoch = util.generateRandomUUID();
    GameRunAdmission.revision = 0;
    GameRunAdmission.allowed = false;
    GameRunAdmission.publish(context, restore);
  }

  /** 页面读取已发布结果，不能因偏好缓存提前变化而显示已开启。 */
  static isAllowed(): boolean { return !ProductBuildProfile.storeChannel || GameRunAdmission.allowed; }

  /**
   * 关闭先撤销门控，开启先确认偏好；队列及intent阻止迟到开启覆盖后来的关闭。
   * 失败保持本进程拒绝，向调用者传播；不将保存或撤销失败冒充已持久化。
   */
  static saveChoice(context: common.UIAbilityContext, enabled: boolean): Promise<void> {
    if (!ProductBuildProfile.storeChannel || typeof enabled !== 'boolean') return Promise.reject(new Error('当前产品没有此运行开关'));
    const intent = ++GameRunAdmission.intent;
    if (!enabled) {
      GameRunAdmission.allowed = false;
      try { GameRunAdmission.publish(context, false); } catch (error) { return Promise.reject(error as Error); }
    }
    const task = GameRunAdmission.tail.then(async (): Promise<void> => {
      const preferences = new PreferenceManager(context);
      const previous = preferences.storeAllowDebug;
      try {
        await preferences.saveStoreAllowDebug(enabled);
        if (intent === GameRunAdmission.intent) GameRunAdmission.publish(context, enabled);
      } catch (error) {
        GameRunAdmission.allowed = false;
        try { GameRunAdmission.publish(context, false); } catch (_) { /* 保留原异常，不能声称磁盘撤销已确认。 */ }
        if (enabled) { try { await preferences.saveStoreAllowDebug(previous); } catch (_) { /* 原事务报告未知态。 */ } }
        throw error as Error;
      }
    });
    GameRunAdmission.tail = task.then((): void => {}, (): void => {});
    return task;
  }

  /** 为一轮准备捕获token；后继await必须验证此token，不能重新捕获替旧任务续命。 */
  static capture(context: common.UIAbilityContext): string {
    if (!ProductBuildProfile.storeChannel) return '';
    const record = GameRunAdmission.read(context);
    return record.epoch + ':' + record.revision;
  }

  /** 同进程异步续体及child票据消费都用同一比较规则，关闭/重开/owner重建均失效。 */
  static assertToken(context: common.UIAbilityContext, token: string): void {
    if (!ProductBuildProfile.storeChannel) return;
    const record = GameRunAdmission.read(context);
    if (token.length === 0 || token !== record.epoch + ':' + record.revision) throw new Error('运行授权已变化，请重新开启运行调试并发起启动');
  }

  /** 私有GameAbility验证snapshot后安装，不从child的旧Preferences重新授予权限。 */
  static installTicket(context: common.UIAbilityContext, token: string): void {
    if (!ProductBuildProfile.storeChannel) return;
    GameRunAdmission.assertToken(context, token);
    GameRunAdmission.installedTicket = token;
  }

  /** 游戏页必须持有父派发绑定的原token，不能由直接打开旧路由重新取得授权。 */
  static captureDispatch(context: common.UIAbilityContext): string {
    if (!ProductBuildProfile.storeChannel) return '';
    GameRunAdmission.assertToken(context, GameRunAdmission.installedTicket);
    return GameRunAdmission.installedTicket;
  }

  /** 紧邻实际新JVM派发前调用；已运行Host的复用分支在调用此方法前返回。 */
  static assertNewLaunch(context: common.UIAbilityContext): void {
    if (!ProductBuildProfile.storeChannel) return;
    if (GameRunAdmission.installedTicket.length > 0) GameRunAdmission.assertToken(context, GameRunAdmission.installedTicket);
    else GameRunAdmission.read(context);
  }

  /** 固定应用私有位置，不接受Want路径；原子写失败时缓存保持关闭。 */
  private static publish(context: common.UIAbilityContext, allowed: boolean): void {
    GameRunAdmission.allowed = false;
    if (GameRunAdmission.ownerRoot !== context.filesDir || GameRunAdmission.epoch.length === 0) throw new Error('运行授权owner尚未初始化');
    const directory = context.filesDir + '/game-run-admission';
    try { fs.mkdirSync(directory, true); } catch (_) { if (!fs.statSync(directory).isDirectory()) throw new Error('运行授权目录不可用'); }
    const next: RunAdmissionRecord = { schema: 1, epoch: GameRunAdmission.epoch, revision: ++GameRunAdmission.revision, allowed };
    try {
      AtomicFileWriter.write(directory + '/state.json', JSON.stringify(next));
    } catch (error) {
      // 写满等rename前失败可能留下旧allowed=true。尽力移除旧准入，让child读缺失即拒绝；
      // 若连撤销也失败则明确报告未知，不能把关闭成功返回给UI。已运行会话不读此文件退出。
      try { fs.unlinkSync(directory + '/state.json'); }
      catch (_) { throw new Error('运行授权保存失败，旧授权撤销尚未确认；请检查存储后重试'); }
      throw error as Error;
    }
    GameRunAdmission.allowed = allowed;
  }

  /** 每次直接读取磁盘；缺失、非法类型、关闭或不可读都拒绝，不用偏好快照兜底。 */
  private static read(context: common.UIAbilityContext): RunAdmissionRecord {
    // 原owner发布失败后allowed=false，旧磁盘不得反向授予它或其迟到异步续体运行权。
    const owner: boolean = GameRunAdmission.ownerRoot === context.filesDir && GameRunAdmission.epoch.length > 0;
    if (owner && !GameRunAdmission.allowed) throw new Error('运行授权未确认，请在关于页面重新保存允许调试');
    let record: RunAdmissionRecord;
    try {
      const path = context.filesDir + '/game-run-admission/state.json';
      const stat = fs.lstatSync(path);
      if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 2048) throw new Error('门控记录非法');
      record = JSON.parse(fs.readTextSync(path)) as RunAdmissionRecord;
      if (record.schema !== 1 || typeof record.epoch !== 'string' || record.epoch.length === 0 ||
        !Number.isSafeInteger(record.revision) || record.revision <= 0 || record.allowed !== true) throw new Error('未开启运行调试');
      if (owner && (record.epoch !== GameRunAdmission.epoch || record.revision !== GameRunAdmission.revision)) throw new Error('门控owner已变化');
    } catch (_) { throw new Error('请先在关于页面开启“允许调试”，再运行游戏'); }
    return record;
  }
}
