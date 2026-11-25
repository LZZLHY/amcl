/** 启动器与已通过私有启动快照核验的 :game 进程之间的只读观测。只在受理本局的开发会话内传输。 */
import { common, Want } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { util } from '@kit.ArkTS'
import { AtomicFileWriter, DiagnosticPolicy, ledgerCurrentRunNonce } from 'commons'
import testNapi from 'libentry.so'

interface Grant { schema: number; session: string; expiresAt: number; actions: string[]; sourceRevision: string }
interface BuildMode { mode: string }
interface Build { name: string; sourceRevision: string; build: BuildMode }
interface Binding { root: string; dir: string; grantText: string; session: string; operationId: string; activityId: number; versionId: string; expiresAt: number }
export interface PrivateWindowSample { schema: number; session: string; operationId: string; queryId: string; activityId: number; versionId: string;
  nonce: string; runNonce: string; ownerPid: number; expiresAt: number; windowId: number }
interface BoundLaunch { schema: number; operationId: string; activityId: number; versionId: string; processRole: string; stage: string }

const ID: RegExp=/^[0-9a-f]{32}$/
const TTL: number=3200

/** 固定对象只读小文件，过期、非普通文件以及未归属的旧会话都没有回复资格。 */
function read(path: string): string | undefined {
  let st: fs.Stat
  try { st=fs.lstatSync(path) }
  catch (e) { if ((e as BusinessError).code===13900002) return undefined; throw e as Error }
  if (!st.isFile() || st.isSymbolicLink() || st.size<=0 || st.size>8192) throw new Error('invalid-private-game-evidence')
  return fs.readTextSync(path)
}
function pathFor(b: Binding, request: boolean): string {return b.dir+(request?'/probe-':'/witness-')+b.operationId+'.json'}
function open(b: Binding): boolean {
  const descriptor=read(b.root+'/session.json')
  return b.expiresAt>Date.now() && descriptor!==undefined && JSON.stringify(JSON.parse(descriptor))===b.grantText &&
    read(b.dir+'/grant.json')===b.grantText && read(b.dir+'/closed.json')===undefined &&
    read(b.root+'/close-'+b.session+'.txt')===undefined
}
function same(a: PrivateWindowSample,b: PrivateWindowSample): boolean {
  return a.schema===1 && a.session===b.session && a.operationId===b.operationId && a.activityId===b.activityId &&
    a.versionId===b.versionId && a.nonce===b.nonce && a.queryId===b.queryId && a.runNonce===b.runNonce && a.ownerPid===b.ownerPid && a.expiresAt===b.expiresAt
}

/** 子进程只响应原启动传入的会话/操作二元组，不接收路径、窗口操作、游戏输入或其他命令。 */
export class PrivateGameWitness {
  private static child: Binding | undefined = undefined
  private static answered: string = ''

  static arm(context: common.UIAbilityContext, want: Want, activityId: number, versionId: string): (() => void) | undefined {
    PrivateGameWitness.retire()
    const session=want.parameters?.['qaGameSession']
    const operation=want.parameters?.['qaGameOperation']
    if (typeof session!=='string' || !ID.test(session) || typeof operation!=='string' || !ID.test(operation) ||
      !Number.isSafeInteger(activityId) || activityId<=0 || !DiagnosticPolicy.hasTestHooks()) return undefined
    try {
      const root=context.filesDir+'/amcl-qa-v1'
      const grantText=read(root+'/session.json')
      if (grantText===undefined) return undefined
      const grant=JSON.parse(grantText) as Grant
      if (grant.schema!==1 || grant.session!==session || !Number.isSafeInteger(grant.expiresAt) ||
        grant.expiresAt-Date.now()>1800000 || !Array.isArray(grant.actions) ||
        !grant.actions.includes('game.launch') || !grant.actions.includes('game.observe')) return undefined
      const bytes=context.resourceManager.getRawFileContentSync('product-profile.json')
      const build=JSON.parse(new util.TextDecoder().decodeWithStream(bytes)) as Build
      if (build.name!=='default' || build.build.mode!=='debug' || build.sourceRevision!==grant.sourceRevision) return undefined
      const b: Binding={root:root,dir:root+'/'+session,grantText:JSON.stringify(grant),session:session,operationId:operation,
        activityId:activityId,versionId:versionId,expiresAt:grant.expiresAt}
      if (!open(b)) return undefined
      const source=read(b.dir+'/game-'+operation+'.json')
      if (source===undefined) return undefined
      const launch=JSON.parse(source) as BoundLaunch
      if (launch.schema===1 && launch.operationId===operation && launch.activityId===activityId &&
        launch.versionId===versionId && launch.processRole==='game' && ['dispatching','dispatched'].includes(launch.stage)) {
        PrivateGameWitness.child=b
        return (): void => { if (PrivateGameWitness.child===b) PrivateGameWitness.retire() }
      }
    } catch (_) { /* 观测材料缺失只失去证明，不改变真实游戏启动结果。 */ }
    return undefined
  }

  static retire(): void { PrivateGameWitness.child=undefined; PrivateGameWitness.answered='' }
  static armed(): boolean { return PrivateGameWitness.child!==undefined }

  /** 仅开发包中已获授权的本局才读沙箱。使用现有运行时心跳，每个随机询问只能答一次。 */
  static pulse(activityId: number, windowId: number): void {
    const b=PrivateGameWitness.child
    if (b===undefined) return
    try {
      if (!open(b)) { PrivateGameWitness.retire(); return }
      if (activityId!==b.activityId || windowId<=0) return
      const text=read(pathFor(b,true))
      if (text===undefined) return
      const query=JSON.parse(text) as PrivateWindowSample
      const now=Date.now(), pid=testNapi.desktopProcessId(), run=ledgerCurrentRunNonce()
      if (query.schema!==1 || query.windowId!==0 || query.session!==b.session || query.operationId!==b.operationId ||
        query.activityId!==activityId || query.versionId!==b.versionId || query.ownerPid!==pid ||
        !run || query.runNonce!==run || !ID.test(query.nonce) || !ID.test(query.queryId) || query.nonce===PrivateGameWitness.answered ||
        !Number.isSafeInteger(query.expiresAt) || query.expiresAt<=now || query.expiresAt>now+TTL || query.expiresAt>b.expiresAt ||
        !testNapi.mcIsRunning()) return
      query.windowId=windowId
      AtomicFileWriter.write(pathFor(b,false),JSON.stringify(query))
      PrivateGameWitness.answered=query.nonce
    } catch (_) { /* 独立观测缺失不可影响游戏。宿主按超时返回不确定。 */ }
  }

  /** 每次观测重新出题。过期回复、另一活动/进程/窗口及上一轮问题均不能授予本次资格。 */
  static async query(directory: string, operation: string, activity: number, version: string, pid: number,
    run: string, queryId: string, current: () => boolean): Promise<PrivateWindowSample | undefined> {
    if (!run || pid<=0 || !ID.test(operation) || !ID.test(queryId) || !current()) return undefined
    try {
      const session=directory.slice(directory.lastIndexOf('/')+1)
      if (!ID.test(session)) return undefined
      const grantText=read(directory+'/grant.json')
      if (!grantText) return undefined
      const grant=JSON.parse(grantText) as Grant
      const b: Binding={root:directory.slice(0,directory.lastIndexOf('/')),dir:directory,grantText:grantText,session:session,
        operationId:operation,activityId:activity,versionId:version,expiresAt:grant.expiresAt}
      if (!open(b)) return undefined
      const sample: PrivateWindowSample={schema:1,session:session,operationId:operation,queryId:queryId,activityId:activity,versionId:version,
        ownerPid:pid,runNonce:run,nonce:util.generateRandomUUID().replace(/-/g,'').toLowerCase(),windowId:0,
        expiresAt:Math.min(Date.now()+TTL,grant.expiresAt)}
      AtomicFileWriter.write(pathFor(b,true),JSON.stringify(sample))
      for (let attempt=0;attempt<16;attempt++) {
        await new Promise<void>((done: () => void): void => { setTimeout(done,200) })
        if (!current() || Date.now()>=sample.expiresAt || !open(b)) return undefined
        const text=read(pathFor(b,false))
        if (!text) continue
        const witness=JSON.parse(text) as PrivateWindowSample
        if (same(witness,sample) && Number.isSafeInteger(witness.windowId) && witness.windowId>0) return witness
      }
    } catch (_) { /* 平台缺观测时返回未知，不补造子进程回执。 */ }
    return undefined
  }

  /** 账本异步读取完成后再核验时效、关闭标记和原租约；不让慢 I/O 复用过期回应。 */
  static stillOpen(directory: string, sample: PrivateWindowSample): boolean {
    try {
      if (sample.expiresAt<=Date.now() || sample.expiresAt>Date.now()+TTL) return false
      const root=directory.slice(0,directory.lastIndexOf('/'))
      const grantText=read(directory+'/grant.json')
      if (!grantText) return false
      const grant=JSON.parse(grantText) as Grant
      const binding: Binding={root:root,dir:directory,grantText:grantText,session:sample.session,operationId:sample.operationId,
        activityId:sample.activityId,versionId:sample.versionId,expiresAt:grant.expiresAt}
      return grant.session===sample.session && open(binding)
    } catch (_) { return false }
  }
}
