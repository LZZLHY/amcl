import { common } from '@kit.AbilityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { util } from '@kit.ArkTS'
import { DesktopFileDrop } from './DesktopFileDrop'
import { GameLayoutJournal } from './GameLayoutJournal'
import { GameLayoutTransportV2 } from './GameLayoutTransportV2'
import { AccountType, getAccountManager } from 'account'
import { getLayoutStore, LayoutLaunchSource } from 'gamecontrol'
import { PreferenceManager } from 'feature_system'
import { INPUT_PLAN_SCHEMA } from 'launch'
import { GameRunAdmission } from './GameRunAdmission'
import { ProcessPreferences, LaunchPreferenceSnapshot, LaunchPreferenceValue,
  AppLogger, LOG_DOMAIN_LAUNCH } from 'commons'

interface DesktopPreferenceTicket {
  schema: number
  id: string
  parentPid: number
  activityId: number
  createdAt: number
  stores: LaunchPreferenceSnapshot[]
  /** schema2只传冻结布局根记录的身份/摘要，完整catalog与payload留在私有V2会话目录。 */
  layoutSession?: string
  layoutDigest?: string
  /** schema3绑定父侧启动版本与输入契约版本；具体ABI仍由child同次运行库解析生成。 */
  version?: string
  inputPlanSchema?: string
  /** 与父侧实时门控绑定；child不能用旧设置快照恢复已经撤销的运行准备。 */
  runAdmission?: string
}
export interface DesktopLaunchSnapshotRef {
  id: string
  account: string
}

/** Account data travels only in the private Want; disk tickets contain settings/layouts. */
export class DesktopLaunchSnapshot {
  static async prepare(context: common.UIAbilityContext, parentPid: number, version: string,
    activityId: number): Promise<DesktopLaunchSnapshotRef> {
    if (ProcessPreferences.isGameProcess()) throw new Error('Only the launcher may prepare a desktop launch')
    if (!Number.isSafeInteger(activityId) || activityId <= 0) throw new Error('启动活动身份无效')
    const runAdmission: string = GameRunAdmission.capture(context)
    // 下一次启动是前台回调可能遗漏时的完整兜底；未导入布局不能被下一局旧快照遮蔽。
    const layoutImport = await GameLayoutJournal.importPending(context)
    if (layoutImport.deferred || layoutImport.pending > 0) {
      throw new Error('上次游戏布局尚未同步，请关闭布局编辑器并重试启动')
    }
    await DesktopFileDrop.clearPrevious(context)
    const manager = getAccountManager()
    await manager.init(context)
    const account = manager.getSelected()
    const storedAccount: boolean = manager.findById(account.id) === account
    let refreshed: boolean = false
    try { await account.refresh(); refreshed = true }
    catch (error) { AppLogger.warn('DesktopGame', 'Account refresh failed; using cached launch credentials', error, LOG_DOMAIN_LAUNCH) }
    if (storedAccount && manager.findById(account.id) !== account) throw new Error('启动账户已被移除或替换，请重新启动')
    if (refreshed && account.type !== AccountType.OFFLINE) await manager.persistOne(account)
    const settings = new PreferenceManager(context)
    settings.resolveLaunch(version)
    await getLayoutStore().init(context)
    const allAccounts: LaunchPreferenceSnapshot = await ProcessPreferences.captureOwner(context, 'amcl_accounts')
    const accountValues: Record<string, LaunchPreferenceValue> = {}
    const key: string = 'account_' + account.id
    if (Object.keys(allAccounts.values).includes(key)) {
      accountValues['accounts_list'] = JSON.stringify([account.id])
      accountValues['selected_account_id'] = account.id
      accountValues[key] = allAccounts.values[key]
    } else {
      accountValues['accounts_list'] = '[]'
      accountValues['selected_account_id'] = ''
    }
    const selected: LaunchPreferenceSnapshot = { name: 'amcl_accounts', values: accountValues }
    const accountJson: string = JSON.stringify(selected)
    if (accountJson.length > 32768) throw new Error('Selected account launch snapshot is too large')
    const layoutSource: LayoutLaunchSource | null = await getLayoutStore().captureLaunchLayoutSource()
    const snapshots: LaunchPreferenceSnapshot[] = [
      await ProcessPreferences.captureOwner(context, 'amcl_settings'),
      layoutSource === null ? await getLayoutStore().captureLaunchPreferences() : { name: 'control_layout', values: {} }
    ]
    if (storedAccount && manager.findById(account.id) !== account) throw new Error('启动账户已变化，请重新启动')
    const id: string = util.generateRandomUUID().toLowerCase()
    const layoutDigest: string = GameLayoutTransportV2.prepare(context, id, activityId, parentPid, snapshots[1], layoutSource)
    const ticket: DesktopPreferenceTicket = { schema: 3, id: id, parentPid: parentPid, activityId: activityId,
      createdAt: Date.now(), stores: [snapshots[0]], layoutSession: id, layoutDigest: layoutDigest,
      version: version, inputPlanSchema: INPUT_PLAN_SCHEMA, runAdmission: runAdmission }
    GameRunAdmission.assertToken(context, runAdmission)
    const directory: string = context.filesDir + '/desktop-launch'
    try { fs.mkdirSync(directory, true) } catch (_) {}
    const destination: string = directory + '/' + id + '.json'
    const temporary: string = destination + '.tmp'
    const file: fs.File = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
    try { fs.writeSync(file.fd, JSON.stringify(ticket)); fs.fsyncSync(file.fd) } finally { fs.closeSync(file) }
    if (fs.statSync(temporary).size > 4 * 1024 * 1024) {
      fs.unlinkSync(temporary)
      throw new Error('Desktop settings/layout snapshot is too large')
    }
    fs.renameSync(temporary, destination)
    return { id: id, account: accountJson }
  }

  static consume(context: common.UIAbilityContext, id: string, account: string, parentPid: number,
    activityId: number, gamePid: number, expectedVersion: string = ''): void {
    if (!new RegExp('^[0-9a-f-]{36}$').test(id) || account.length === 0 || account.length > 32768) {
      throw new Error('Desktop launch snapshot is missing or invalid')
    }
    const path: string = context.filesDir + '/desktop-launch/' + id + '.json'
    if (fs.statSync(path).size > 4 * 1024 * 1024) throw new Error('Desktop snapshot exceeds the size limit')
    const ticket = JSON.parse(fs.readTextSync(path)) as DesktopPreferenceTicket
    const validStores: boolean = Array.isArray(ticket.stores) && (ticket.schema === 1
      ? ticket.stores.length === 2 && ticket.stores[0].name === 'amcl_settings' && ticket.stores[1].name === 'control_layout'
      : (ticket.schema === 2 || ticket.schema === 3) && ticket.stores.length === 1 && ticket.stores[0].name === 'amcl_settings'
        && ticket.layoutSession === id && typeof ticket.layoutDigest === 'string')
    // 私有票据只有五分钟寿命，不属于用户长期布局格式；schema3必须与已验证Want的
    // 游戏版本及当前输入契约一致，不能让新参数绕过父侧冻结的设置/布局基线。
    const validInputContract: boolean = ticket.schema !== 3 || (expectedVersion.length > 0
      && ticket.version === expectedVersion && ticket.inputPlanSchema === INPUT_PLAN_SCHEMA)
    if ((ticket.schema !== 1 && ticket.schema !== 2 && ticket.schema !== 3) || ticket.id !== id || ticket.parentPid !== parentPid || ticket.activityId !== activityId ||
        !Number.isFinite(ticket.createdAt) || Math.abs(Date.now() - ticket.createdAt) > 300000 ||
        !validStores || !validInputContract) {
      throw new Error('Expired or mismatched desktop launch snapshot')
    }
    const accounts = JSON.parse(account) as LaunchPreferenceSnapshot
    GameRunAdmission.installTicket(context, ticket.runAdmission ?? '')
    if (accounts.name !== 'amcl_accounts') throw new Error('Account snapshot identity mismatch')
    const layout: LaunchPreferenceSnapshot = ticket.schema === 1 ? ticket.stores[1] : { name: 'control_layout', values: {} }
    const stores: LaunchPreferenceSnapshot[] = [ticket.stores[0], layout, accounts]
    ProcessPreferences.installGameSnapshots(stores)
    // 先绑定经 GameAbility 验证的独立进程身份，再允许 LayoutStore 打开本局提交 overlay。
    // 账号/设置仍只读，布局只向私有 journal 提交，绝不在 child 打开 XML。
    if (ticket.schema === 1) GameLayoutJournal.installGame(context, id, activityId, parentPid, gamePid, ticket.stores[1])
    else GameLayoutTransportV2.installGame(context, id, activityId, parentPid, gamePid, ticket.layoutDigest!)
    fs.unlinkSync(path)
  }

  static discard(context: common.UIAbilityContext, id: string): void {
    if (!new RegExp('^[0-9a-f-]{36}$').test(id)) return
    try { fs.unlinkSync(context.filesDir + '/desktop-launch/' + id + '.json') } catch (_) {}
  }
  static pending(context: common.UIAbilityContext, id: string): boolean {
    if (!new RegExp('^[0-9a-f-]{36}$').test(id)) return false
    try {
      const path: string = context.filesDir + '/desktop-launch/' + id + '.json'
      if (fs.statSync(path).size > 4 * 1024 * 1024) return false
      const ticket = JSON.parse(fs.readTextSync(path)) as DesktopPreferenceTicket
      if (Number.isFinite(ticket.createdAt) && Date.now() - ticket.createdAt < 300000) return true
      DesktopLaunchSnapshot.discard(context, id)
    } catch (_) {}
    return false
  }
}
