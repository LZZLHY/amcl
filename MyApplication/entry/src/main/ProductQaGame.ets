import { fileIo as fs } from '@kit.CoreFileKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { common, Want } from '@kit.AbilityKit'
import { AtomicFileWriter, LedgerManifest, LedgerState, ledgerLaunchManifestsAsync, ledgerManifestAsync } from 'commons'
import testNapi from 'libentry.so'
import { ProductQa } from 'entry/ProductQa'
import { LaunchAttemptObserver, StartObservedGame } from './ets/runtime/LaunchAttemptObserver'
import { existingGameSessionHost, GameSessionHost } from './ets/runtime/GameSessionHost'
import { PrivateGameWitness } from './ets/devtools/PrivateGameWitness'
import { GraphicsRuntimeState, parseGraphicsRuntimeState } from './ets/runtime/GraphicsRecoveryPolicy'

/** 私有会话内每个启动意图仅保存小型业务索引。账户、路径、令牌和原日志不经动作返回。 */
class LaunchRecord {
  schema: number = 1
  operationId: string = ''
  versionId: string = ''
  stage: string = 'prechecking'
  reasonCode: string = ''
  activityId: number = 0
  processRole: string = ''
  precheckKey: string = ''
  precheckStatus: string = ''
  choices: string[] = []
}

class GameObservation extends LaunchRecord {
  ledgerState: string = ''
  ownerPid: number = 0
  pidAlive: number = -1
  /** 共享进程查询原宿主；私有进程必须在当前轮次、当前活动中回复一次新挑战。 */
  ownerVerified: boolean = false
  windowId: number = 0
  witnessRequestId: string = ''
  presentCount: number = -1
  surfaceGeneration: number = 0
}

/** 现有会话只公布活动和窗口候选；不认领为本次启动，也不暴露账本内部标识。 */
class CurrentGame {
  state: string = 'unknown'
  activityId: number = 0
  versionId: string = ''
  processRole: string = ''
  ownerPid: number = 0
  windowId: number = 0
}

function currentReply(data: CurrentGame, reason: string = ''): string {
  return JSON.stringify({ status: data.state === 'unknown' ? 'unknown' : 'ok', data: data, reason: reason })
}

function isLiveGame(manifest: LedgerManifest): boolean {
  return manifest.category === 'launch' && manifest.state === LedgerState.RUNNING &&
    !!manifest.gameVersionId && !!manifest.runNonce && Number.isSafeInteger(manifest.activityId) &&
    manifest.activityId > 0 && (manifest.ownerPid ?? 0) > 0
}

/** 锁由独立游戏创建并保留。只观察已存在的锁，避免查询本身创建文件。 */
function privateGameState(filesDir: string): number {
  try {
    const stat = fs.lstatSync(filesDir + '/.desktop-game.lock')
    if (!stat.isFile() || stat.isSymbolicLink()) return -1
    return testNapi.desktopGameProcessState(filesDir, 0)
  } catch (error) {
    return (error as BusinessError).code === 13900002 ? 0 : -1
  }
}

/** 共享态用原宿主绑定；独立态只在原生占用锁和唯一存活账本一致时提供候选，宿主还会核对系统窗口。 */
async function observeCurrentGame(filesDir: string, directory: string): Promise<string> {
  const result = new CurrentGame()
  const host = existingGameSessionHost()
  const hostRunning = host?.isRunning() === true
  const activity = hostRunning && host !== undefined ? host.sessionActivity() : 0
  const pid = testNapi.desktopProcessId()
  const privateState = privateGameState(filesDir)
  if (activity > 0 && privateState === 0) {
    const manifest = await ledgerManifestAsync(filesDir, activity)
    if (manifest !== null && isLiveGame(manifest) && manifest.activityId === activity && manifest.ownerPid === pid &&
      host !== undefined && host === existingGameSessionHost() && host.isRunning() && host.sessionActivity() === activity &&
      privateGameState(filesDir) === 0 && ProductQa.sessionDirectory() === directory) {
      result.state = 'running'; result.activityId = activity; result.versionId = manifest.gameVersionId
      result.processRole = 'launcher'; result.ownerPid = pid; result.windowId = host.runningWindow(activity)
      return currentReply(result)
    }
    return currentReply(result, 'shared-game-identity-unavailable')
  }
  if (hostRunning || testNapi.mcIsRunning()) return currentReply(result, 'shared-game-transition')
  if (privateState === 0) {
    result.state = 'idle'
    return currentReply(result)
  }
  if (privateState !== 1) return currentReply(result, 'private-game-lock-unavailable')
  const candidates = (await ledgerLaunchManifestsAsync(filesDir)).filter((manifest: LedgerManifest): boolean =>
    isLiveGame(manifest) && manifest.ownerPid !== pid && testNapi.desktopProcessAlive(manifest.ownerPid ?? 0) === 1)
  if (candidates.length !== 1) return currentReply(result, 'private-game-identity-unavailable')
  const candidate = candidates[0]
  const manifest = await ledgerManifestAsync(filesDir, candidate.activityId)
  if (manifest === null || !isLiveGame(manifest) || manifest.ownerPid !== candidate.ownerPid ||
    manifest.runNonce !== candidate.runNonce || manifest.gameVersionId !== candidate.gameVersionId ||
    testNapi.desktopProcessAlive(manifest.ownerPid ?? 0) !== 1 || privateGameState(filesDir) !== 1 ||
    existingGameSessionHost()?.isRunning() === true || testNapi.mcIsRunning() || ProductQa.sessionDirectory() !== directory) {
    return currentReply(result, 'private-game-identity-changed')
  }
  result.state = 'running'; result.activityId = manifest.activityId; result.versionId = manifest.gameVersionId
  result.processRole = 'game'; result.ownerPid = manifest.ownerPid ?? 0
  return currentReply(result)
}

/** 测试构建内固定32位标识形成文件名。任何外部路径均不参与解析。 */
function validId(value: string): boolean { return /^[a-f0-9]{32}$/.test(value) }
function recordPath(directory: string, id: string): string { return directory + '/game-' + id + '.json' }

function reply(status: string, data: LaunchRecord, reason: string = ''): string {
  return JSON.stringify({ status: status, data: data, reason: reason })
}

function readRecord(path: string, id: string): LaunchRecord | undefined {
  let stat: fs.Stat
  try { stat=fs.lstatSync(path) }
  catch (error) {
    if ((error as BusinessError).code===13900002) return undefined
    throw error as Error
  }
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size < 2 || stat.size > 8192) throw new Error('record-invalid')
  const record = JSON.parse(fs.readTextSync(path)) as LaunchRecord
  if (record.schema !== 1 || record.operationId !== id || typeof record.versionId !== 'string' ||
    !Number.isSafeInteger(record.activityId) || record.activityId < 0 ||
    ['prechecking','needsUser','blocked','dispatching','dispatched','unknown'].indexOf(record.stage) < 0) {
    throw new Error('record-invalid')
  }
  return record
}

/** 可失联的观察者始终绑定原会话和请求。写失败先封住后续派发，不在回调中重演用户操作。 */
class DeviceLaunchAttempt implements LaunchAttemptObserver {
  readonly record: LaunchRecord
  private directory: string
  private healthy: boolean = true

  constructor(directory: string, record: LaunchRecord) { this.directory = directory; this.record = record }

  current(): boolean { return this.healthy && ProductQa.sessionDirectory() === this.directory }
  persist(): void {
    if (!this.current()) { this.healthy = false; return }
    try { AtomicFileWriter.write(recordPath(this.directory, this.record.operationId), JSON.stringify(this.record)) }
    catch (_) { this.healthy = false }
  }
  beginChecks(): void {
    this.record.stage='prechecking'; this.record.reasonCode=''; this.record.choices=[]
    this.record.precheckKey=''; this.record.precheckStatus=''
    this.persist()
  }
  check(key: string, state: string, fix: string): void {
    if (!this.current() || this.record.stage !== 'prechecking') return
    this.record.precheckKey=key; this.record.precheckStatus=state
    if (state==='fail') {
      this.record.stage='blocked'; this.record.reasonCode=fix.length>0 ? fix : 'precheck-failed'
      this.record.choices=fix.length>0 ? [fix,'cancel'] : ['cancel']
    } else if (key==='jdk' && state==='warn' && fix==='jdk_mismatch') {
      this.record.stage='needsUser'; this.record.reasonCode=fix
      this.record.choices=['automatic-jdk','keep-jdk','cancel']
    } else return
    this.persist()
  }
  stop(stage: string, reason: string): void {
    this.record.stage=stage; this.record.reasonCode=reason; this.record.choices=[]
    this.persist()
  }
  bind(activityId: number, isolated: boolean): void {
    this.record.activityId=activityId; this.record.processRole=isolated ? 'game' : 'launcher'
    this.stop('dispatching','')
  }
  bindPrivateParams(params: Record<string,string | number>): void {
    if (this.current() && this.record.activityId===params['activityId'] && this.record.processRole==='game') {
      params['qaGameSession']=this.directory.slice(this.directory.lastIndexOf('/')+1)
      params['qaGameOperation']=this.record.operationId
    }
  }
  sent(reused: boolean = false): void { this.stop('dispatched',reused ? 'existing-session-focused' : '') }
}

/** 仅凭本局记录找到生产账本。主菜单、世界和窗口焦点由独立观测核实。 */
async function observe(filesDir: string, record: LaunchRecord, active: boolean, queryId: string): Promise<string> {
  // 仅投影协议声明字段，磁盘未知字段不进入返回正文。
  const result=new GameObservation()
  result.operationId=record.operationId; result.versionId=record.versionId; result.stage=record.stage
  result.reasonCode=record.reasonCode; result.activityId=record.activityId; result.processRole=record.processRole
  result.precheckKey=record.precheckKey; result.precheckStatus=record.precheckStatus; result.choices=record.choices
  if (record.activityId > 0) {
    const ledger: LedgerManifest | null = await ledgerManifestAsync(filesDir,record.activityId)
    if (ledger !== null) {
      if (ledger.activityId!==record.activityId || ledger.category!=='launch' || ledger.gameVersionId!==record.versionId) {
        return reply('unknown',result,'activity-mismatch')
      }
      const labels: string[]=['running','success','failed','aborted','crashed','interrupted']
      result.ledgerState=labels[ledger.state] ?? ''
      result.ownerPid=ledger.ownerPid ?? 0
      if (result.ownerPid>0) result.pidAlive=testNapi.desktopProcessAlive(result.ownerPid)
      if (ledger.state!==LedgerState.RUNNING) result.stage='ended'
      // 本进程的图形计数只归当前共享活动；私有进程须单独取得同局窗口回复。
      if (result.processRole==='launcher' && ledger.state===LedgerState.RUNNING &&
        result.pidAlive===1 && result.ownerPid===testNapi.desktopProcessId()) {
        const session=existingGameSessionHost()
        if (session!==undefined && session.isRunning() && session.sessionActivity()===record.activityId) {
          result.ownerVerified=true
          result.witnessRequestId=queryId
          result.windowId=session.runningWindow(record.activityId)
          const state: GraphicsRuntimeState | undefined=parseGraphicsRuntimeState(testNapi.mcGetGraphicsRuntimeFailure())
          if (state!==undefined && state.pid===result.ownerPid) {
            result.presentCount=state.presentCount; result.surfaceGeneration=state.surfaceGeneration
          }
        }
      }
      if (result.processRole==='game' && result.ledgerState==='running' && result.pidAlive===1 &&
        result.ownerPid!==testNapi.desktopProcessId() && ledger.runNonce && queryId.length>0) {
        const dir=ProductQa.sessionDirectory()
        const witness=await PrivateGameWitness.query(dir,record.operationId,record.activityId,record.versionId,
          result.ownerPid,ledger.runNonce,queryId,(): boolean => dir.length>0 && dir===ProductQa.sessionDirectory())
        if (witness!==undefined) {
          const current=await ledgerManifestAsync(filesDir,record.activityId)
          result.pidAlive=testNapi.desktopProcessAlive(result.ownerPid)
          if (current!==null && current.activityId===record.activityId && current.category==='launch' &&
            current.gameVersionId===record.versionId && current.ownerPid===result.ownerPid && current.state===LedgerState.RUNNING &&
            current.runNonce===ledger.runNonce && result.pidAlive===1 && dir===ProductQa.sessionDirectory() && PrivateGameWitness.stillOpen(dir,witness)) {
            result.ownerVerified=true; result.windowId=witness.windowId; result.witnessRequestId=queryId
          }
        }
      }
    }
  }
  if (!active && result.activityId===0 && (result.stage==='prechecking' || result.stage==='dispatching')) {
    result.stage='unknown'; return reply('unknown',result,'precheck-owner-lost')
  }
  if (result.stage==='unknown') return reply('unknown',result,result.reasonCode)
  if (result.stage==='needsUser') return reply('needsUser',result,result.reasonCode)
  return reply('ok',result,result.reasonCode)
}

export class ProductQaGame {
  private static active: DeviceLaunchAttempt | undefined = undefined
  static armPrivate(context: common.UIAbilityContext, want: Want, activity: number, version: string): (() => void) | undefined {
    return PrivateGameWitness.arm(context,want,activity,version)
  }
  static pulsePrivate(host: GameSessionHost): void {
    if (PrivateGameWitness.armed()) PrivateGameWitness.pulse(host.sessionActivity(),host.runningWindow(host.sessionActivity()))
  }

  /** 接受动作先落原意图；同号重试仅读回授权会话中的原记录。 */
  static async handle(filesDir: string, action: string, args: string, requestId: string,
    start: StartObservedGame): Promise<string> {
    const blank=new LaunchRecord()
    const directory=ProductQa.sessionDirectory()
    if (directory.length===0 || !validId(requestId)) return reply('rejected',blank,'session-unavailable')
    try {
      const payload=JSON.parse(args) as Record<string,string>
      if (payload===null || typeof payload!=='object' || Array.isArray(payload) ||
        Object.keys(payload).length!==(action==='game.current' ? 0 : 1)) {
        return reply('rejected',blank,'invalid-arguments')
      }
      if (action==='game.current') return await observeCurrentGame(filesDir,directory)
      if (action==='game.observe') {
        const id=payload['operationId']
        if (typeof id!=='string' || !validId(id)) return reply('rejected',blank,'invalid-operation')
        const prior=readRecord(recordPath(directory,id),id)
        if (!prior) return reply('unknown',blank,'operation-not-found')
        const live=ProductQaGame.active
        return await observe(filesDir,prior,live!==undefined && live.current() && live.record.operationId===id,requestId)
      }
      if (action!=='game.launch') return reply('rejected',blank,'unknown-action')
      const versionId=payload['versionId']
      if (typeof versionId!=='string' || versionId.length===0 || versionId.length>255) return reply('rejected',blank,'invalid-version')
      const prior=readRecord(recordPath(directory,requestId),requestId)
      if (prior) return prior.versionId===versionId ? await observe(filesDir,prior,false,'') : reply('rejected',blank,'request-conflict')
      blank.versionId=versionId; blank.operationId=requestId
      const attempt=new DeviceLaunchAttempt(directory,blank)
      attempt.persist()
      if (!attempt.current()) return reply('unknown',blank,'intent-unavailable')
      await start(versionId,attempt)
      if (!attempt.current()) return reply('unknown',blank,'observation-unavailable')
      if (blank.stage==='blocked') return reply('rejected',blank,blank.reasonCode)
      if (blank.stage==='unknown') return reply('unknown',blank,blank.reasonCode)
      if (blank.stage==='prechecking') ProductQaGame.active=attempt
      return reply(blank.stage==='needsUser' ? 'needsUser' : 'accepted',blank,blank.reasonCode)
    } catch (_) {return reply('unknown',blank,'game-operation-unavailable')}
  }
}
