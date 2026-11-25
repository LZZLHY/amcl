import { ResourceOperation } from './ResourceOperation';
import { TaskControlOperations } from './TaskControlOperations';
import { isQueuedRetry, matchesTaskActivity, publicTaskId, result, textArg } from './LibraryResult';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AtomicFileWriter, ledgerManifest, validateVersionName } from 'commons';
import { ModLoaderType, safeBaseName, versionInstallNameError, listMcInstallRecovery, UnifiedTaskView } from 'feature_core';
import { SkillFileScope } from './SkillFileScope';
import { LauncherSkillBus } from './LauncherSkillBus';
import { classifyVersion, inspectInstalledVersion, inspectLegacyVanilla } from 'mods';
import { LauncherVersionAccess } from '../runtime/LauncherVersionAccess';
import { LauncherManagementAccess } from '../runtime/LauncherManagementAccess';
import { LaunchAttemptObserver, StartObservedGame } from '../runtime/LaunchAttemptObserver';

type Data = Record<string, Object>;

export function safeName(value: string): boolean {
  return value.length > 0 && value.length <= 180 && !value.startsWith('.') && value !== 'download-temp' && safeBaseName(value) === value;
}
export interface LibraryUi {
  homeSummary: () => Data;
  showCatalogVersion: (game:string,category:string)=>void;
  graphicsResult: (activity:number)=>Data;
  effectiveSettings: (version:string)=>Data;
  open: (page: string, version: string) => Promise<boolean>;
  loader: (version: string) => string;
  reorder: (ordered: string[]) => Promise<boolean>;
  currentOrder: () => string[];
  launch: StartObservedGame;
  focus: () => Promise<boolean>;
  window: (activity:number,ownerPid:number)=>Data;
  storeAction: () => string;
  performStoreAction: (awaitUser: () => void) => Promise<Data>;
  runningAllowed: () => boolean;
  confirm: (message:string) => Promise<boolean>;
  repair: (version:string) => Data;
  verify: (version:string) => Promise<Data>;
  cleanOrphans: (names:string[], all:boolean, method:string) => Promise<Data>;
  current: () => boolean;
}
interface Attempt {
  key: string;
  target: string;
  input: string;
  activity: number;
  task: string;
  companionRequired?: boolean;
  companionTask?: string;
  companionActivity?: number;
  companionFailed?: boolean;
  stage: string;
  reason: string;
  check: string;
  checkState: string;
  fix: string;
}
/** 首次受理前写入记录。丢失回包只允许用原业务号查询；无可证终态时保留未知。 */
class SkillAttempt {
  readonly file: string;
  readonly data: Attempt;
  constructor(file: string, data: Attempt) {
    this.file=file;
    this.data=data;
  }
  save(): void { AtomicFileWriter.write(this.file, JSON.stringify(this.data)); }
  static get(files: string, key: string): SkillAttempt | null {
    if (!/^[a-zA-Z0-9_-]{1,64}$/.test(key)) throw new Error('invalidOperationRef');
    const folder = files + '/launcher-skill-operations/' + key;
    if (!fs.accessSync(folder)) return null;
    const path = folder + '/operation.json';
    if (!fs.accessSync(path)) throw new Error('operationOutcomeUnknown');
    const st = fs.lstatSync(path);
    if (!st.isFile() || st.isSymbolicLink() || st.size > 8192) throw new Error('invalidOperationRecord');
    const data = JSON.parse(fs.readTextSync(path)) as Attempt;
    if (data.key !== key || !safeName(data.target) || !Number.isSafeInteger(data.activity) || data.activity < 0) throw new Error('invalidOperationRecord');
    return new SkillAttempt(path,data);
  }
  static create(files: string, key: string, target: string, input: string, task: string): SkillAttempt {
    const folder = files + '/launcher-skill-operations';
    if (!fs.accessSync(folder)) fs.mkdirSync(folder);
    // 创建专属目录就是原子认领；进程在后续写账前退出也不会重派。
    fs.mkdirSync(folder+'/'+key);
    const path = folder + '/' + key + '/operation.json';
    const record = new SkillAttempt(path, {key:key,target:target,input:input,activity:0,task:task,stage:'claimed',reason:'',check:'',checkState:'',fix:''});
    record.save();
    return record;
  }
}
class SkillLaunchObserver implements LaunchAttemptObserver {
  private readonly record: SkillAttempt;
  private readonly alive: () => boolean;
  constructor(record: SkillAttempt, alive: () => boolean) {
    this.record=record;
    this.alive=alive;
  }
  current(): boolean { return this.alive(); }
  beginChecks(): void { this.stop('checking',''); }
  check(key: string, state: string, fix: string): void {
    this.record.data.check=key; this.record.data.checkState=state; this.record.data.fix=fix; this.record.save();
  }
  stop(stage: string, reason: string): void { this.record.data.stage=stage; this.record.data.reason=reason; this.record.save(); }
  bind(activityId: number, isolated: boolean): void { this.record.data.activity=activityId; this.record.save(); }
  bindPrivateParams(_params: Record<string,string | number>): void { /* 原生观察属于开发诊断，普通启动沿用原路径。 */ }
  sent(reused: boolean = false): void { this.stop('dispatched',reused?'existingSessionFocused':''); }
}

export class LauncherLibrary {
  private readonly versions: () => LauncherVersionAccess;
  private readonly manager: () => LauncherManagementAccess;
  private readonly ui: LibraryUi;
  constructor(versions: () => LauncherVersionAccess, manager: () => LauncherManagementAccess, ui: LibraryUi) {
    this.versions=versions;
    this.manager=manager;
    this.ui=ui;
  }
  private observe(port: LauncherVersionAccess, record: SkillAttempt): Data {
    const item=record.data;
    const ledger=item.activity > 0 ? ledgerManifest(port.filesDir,item.activity) : null;
    const view=item.task ? port.registry.get(item.task) : null;
    const current=view !== null && item.activity>0 && matchesTaskActivity(view,item.activity);
    const answer: Data={'state':'ready','operationRef':item.key,'instance':item.target,'stage':item.stage,
      'reason':item.reason,'activityId':item.activity,'taskId':item.task,'precheck':item.check,'precheckState':item.checkState,'fix':item.fix};
    if (current && view!==null) { answer['taskState']=view.state; answer['bytesDone']=view.bytesDone; answer['bytesTotal']=view.bytesTotal; }
    if (ledger!==null && ledger.activityId===item.activity) {
      answer['activityState']=ledger.state; answer['outcomeSource']=ledger.outcomeSource;
      if (ledger.category==='launch' && ledger.gameVersionId===item.target) answer['window']=this.ui.window(item.activity,ledger.ownerPid ?? 0);
    }
    if (item.companionRequired) {
      answer['companionTaskId']=publicTaskId(item.companionTask ?? '', item.key + '-companion');
      answer['companionActivityId']=item.companionActivity ?? 0;
      const evidence=item.companionActivity ? ledgerManifest(port.filesDir,item.companionActivity) : null;
      answer['companionState']=item.companionFailed?'failed':evidence!==null?String(evidence.state):'pending';
    }
    if (item.stage==='claimed' && !current && ledger===null) answer['state']='unknown';
    return answer;
  }
  private async install(args: Data, port: LauncherVersionAccess, root: string): Promise<Data> {
    const game=textArg(args,'gameVersion'), target=textArg(args,'instance'), key=textArg(args,'operationRef');
    const raw=textArg(args,'loader') || 'vanilla', version=textArg(args,'loaderVersion');
    const withApi=raw==='fabric' ? args['withFabricApi']!==false : args['withFabricApi']===true;
    const loader=raw==='vanilla'?null:raw as ModLoaderType;
    const input=JSON.stringify(['install',root,game,target,raw,version,withApi]);
    if (!safeName(game) || !safeName(target) || !key || (loader===null && (version || withApi)) ||
      (loader!==null && (!port.supportedLoaders().includes(loader) || !safeName(version))) || (withApi && loader!==ModLoaderType.FABRIC)) return result('failed','invalidArguments');
    let old=SkillAttempt.get(port.filesDir,key);
    if (old) return old.data.input===input?this.observe(port,old):result('failed','operationRefConflict');
    const catalog=await port.catalog.getVersionList();
    if (!catalog.versions.some(item=>item.id===game)) return result('failed','versionNotInCatalog');
    if (loader!==null) {
      const choices=await port.loaders.getLoaderVersions(loader,game);
      if (!choices.some(v=>v.gameVersion===game && v.loader===loader && v.loaderVersion===version)) return result('failed','loaderNotInCatalog');
    }
    const api = withApi ? await port.companion(game) : null;
    if (withApi && !api) return result('needsUser','fabricApiUnavailable');
    if (!this.ui.current() || port.root()!==root || !port.ready()) return result('needsUser','launcherChanged');
    const denied=port.loaderAdmission(game,loader);
    if (denied) return result('needsUser',denied);
    old=SkillAttempt.get(port.filesDir,key);
    if (old) return old.data.input===input?this.observe(port,old):result('failed','operationRefConflict');
    const task='mc:'+target;
    if (port.registry.get(task)!==null || versionInstallNameError(root,target) || listMcInstallRecovery(port.filesDir,root).some(v=>v.versionName===target)) return result('failed','instanceExists');
    try { fs.lstatSync(root+'/versions/'+target); return result('failed','instanceExists'); }
    catch (e) { if ((e as BusinessError).code!==13900002) throw e as Error; }
    const record=SkillAttempt.create(port.filesDir,key,target,input,task);
    if (api!==null) { record.data.companionRequired=true; record.save(); }
    const submitted=port.install(game,target,loader,version,api?.version ?? null,api?.iconUrl ?? '');
    if (submitted.companion) {
      submitted.companion.then(child=>{
        record.data.companionTask=child.view.id; record.save();
        const link=():void=>{
          if (record.data.companionActivity || port.registry.get(child.view.id)!==child.view || child.view.startedAtMs<=0) return;
          record.data.companionActivity=child.view.startedAtMs;record.save();
          Promise.resolve().then(():void=>port.registry.removeListener(link));
        };
        port.registry.addListener(link);link();
        child.completion.then(()=>{link();port.registry.removeListener(link);},()=>{link();port.registry.removeListener(link);record.data.companionFailed=true;record.save();});
      }).catch(()=>{record.data.companionFailed=true;record.save();});
    }
    const adapter=submitted.adapter;
    // 真正开始时 Registry 才分配活动号；后续 retry 不得冒充第一次安装。
    const pin=():void=>{
      if (port.registry.getAdapter(task)!==adapter || adapter.view.startedAtMs<=0 || record.data.activity) return;
      record.data.activity=adapter.view.startedAtMs; record.data.stage='admitted'; record.save();
      Promise.resolve().then(():void=>port.registry.removeListener(pin));
    };
    port.registry.addListener(pin); pin();
    submitted.completion?.then(()=>{ pin(); port.registry.removeListener(pin); },()=>{ pin(); port.registry.removeListener(pin); });
    const admitted=port.registry.getAdapter(task)===adapter;
    return {'state':admitted?'accepted':'unknown','operationRef':key,'taskId':task,'activityId':record.data.activity};
  }
  async run(method: string, args: Data): Promise<Data> {
    const port=this.versions(), owner=this.manager(), root=port.root();
    if (!this.ui.current() || !port.initialized()) return result('initializing');
    if (method==='getResourceInstall') return ResourceOperation.read(port.filesDir,textArg(args,'operationRef'));
    if (method==='getTaskControlOperation') return TaskControlOperations.read(textArg(args,'operationRef'),port.registry);
    if (method==='getLauncherOperation') {
      const record=SkillAttempt.get(port.filesDir,textArg(args,'operationRef'));
      return record ? this.observe(port,record) : result('failed','operationNotFound');
    }
    if (method==='getLauncherTasks') {
      if (port.taskBlock()) return result('needsUser','launcherUnavailable');
      const rows: Data[]=port.registry.listAll().map((v:UnifiedTaskView,index:number):Data=>({'id':publicTaskId(v.id,v.startedAtMs>0 && !isQueuedRetry(v)?v.startedAtMs.toString():('waiting-'+index)),
        'activityId':isQueuedRetry(v)?0:v.startedAtMs,'category':v.category,'title':v.title,
        'phase':v.state,'bytesDone':v.bytesDone,'bytesTotal':v.bytesTotal,'canPause':v.canPause,'canResume':v.canResume,'canCancel':v.canCancel,
        'canRetry':v.canRetry,'requiresConfirmation':v.requiresConfirmation}));
      return {'state':'ready','tasks':rows};
    }
    // 普通任务面板不遮蔽只读库存。其余业务保持实际窗口确认边界。
    const readsInventory = method==='getLauncherHome' || method==='listInstances' || method==='inspectGameInstance';
    const blocked = (): string => readsInventory ? port.taskBlock() : port.ready() ? '' : port.blockReason();
    const reason = blocked();
    if (reason && !(method==='openLauncherSection' && textArg(args,'section')==='home' && reason==='DOWNLOAD_TASKS_OPEN')) {
      return result('needsUser',reason);
    }
    if (method==='getLauncherHome') return this.ui.homeSummary();
    if (method==='focusRunningGame') {
      if (!this.ui.runningAllowed()) return result('needsUser','gameAdmissionRequired');
      return await this.ui.focus()?result('accepted','existingWindowFocusRequested'):result('failed','existingSessionUnavailable');
    }
    if (method==='getGraphicsRecovery') {
      const activity=args['activityId'] as number;
      return Number.isSafeInteger(activity) && activity>0 ? this.ui.graphicsResult(activity) : result('failed','invalidActivity');
    }
    if (method==='showCatalogVersion') {
      const game=textArg(args,'gameVersion');
      const catalog=await port.catalog.getVersionList();
      const item=catalog.versions.find(v=>v.id===game);
      if (!item || !this.ui.current() || !port.ready() || root!==port.root()) return result('failed','catalogChanged');
      const byName=classifyVersion(item.id);
      const kind=byName!=='release'?byName:item.type.startsWith('old_')?'old':item.type;
      this.ui.showCatalogVersion(item.id,kind);
      return {'state':'needsUser','gameVersion':game,'reason':'versionDetailOpened'};
    }
    if (method==='openLauncherSection') {
      const page=textArg(args,'section');
      return await this.ui.open(page,'') ? {'state':'ready','section':page} : result('failed','sectionUnavailable');
    }
    if (method==='performStoreManagerAction') {
      const action=textArg(args,'action');
      if (!action || action!==this.ui.storeAction()) return result('failed','actionChanged');
      // 首页处理器确认派发后才报告受理，检查中和已撤销的活动无法执行。
      return await this.ui.performStoreAction(():void => LauncherSkillBus.awaitingUser(method));
    }
    if (method==='installGameInstance') return this.install(args,port,root);
    if (method==='listGameCatalog') {
      const catalog=await port.catalog.getVersionList(args['refresh']===true);
      if (!this.ui.current() || !port.ready() || port.root()!==root) return result('needsUser','launcherChanged');
      const query=textArg(args,'query').toLowerCase(), kind=textArg(args,'category') || 'all';
      const offset=args['offset']===undefined ? 0 : args['offset'] as number;
      if (!Number.isSafeInteger(offset) || offset<0 || !['all','release','old','snapshot','aprilfools'].includes(kind)) return result('failed','invalidArguments');
      const matches=catalog.versions.filter(v=> {
        const byId=classifyVersion(v.id);
        const type=byId!=='release'?byId:v.type.startsWith('old_')?'old':v.type;
        return (kind==='all' || type===kind) && v.id.toLowerCase().includes(query);
      });
      return {'state':'ready','total':matches.length,'offset':offset,'versions':matches.slice(offset,offset+50).map((v):Data=>({'id':v.id,'type':v.type,'date':v.displayDate}))};
    }
    if (method==='listGameLoaders') {
      const game=textArg(args,'gameVersion'), loader=textArg(args,'loader') as ModLoaderType;
      if (!game || !safeName(game)) return result('failed','invalidArguments');
      const catalog=await port.catalog.getVersionList();
      if (!catalog.versions.some(v=>v.id===game)) return result('failed','versionNotInCatalog');
      if (!this.ui.current() || !port.ready() || port.root()!==root) return result('needsUser','launcherChanged');
      const supported=port.supportedLoaders();
      if (!loader) return {'state':'ready','supported':supported,'gameVersion':game};
      if (!supported.includes(loader)) return result('failed','loaderUnavailable');
      const items=await port.loaders.getLoaderVersions(loader,game);
      if (!this.ui.current() || !port.ready() || port.root()!==root) return result('needsUser','launcherChanged');
      return {'state':'ready','gameVersion':game,'versions':items.map((v):Data=>({'version':v.loaderVersion,'stable':v.stable}))};
    }
    const inventory=await port.inventory();
    if (!this.ui.current() || blocked() || root!==port.root()) return result('needsUser','launcherChanged');
    if (inventory.error) return result('failed','inventoryUnavailable');
    const name=textArg(args,'instance');
    if (method==='listInstances') {
      const filter=textArg(args,'loader') || 'all';
      const selected=port.selected();
      return {'state':'ready','instances':inventory.installed.filter(v=>filter==='all' || this.ui.loader(v)===filter),
        'orphans':inventory.orphans,'selected':inventory.installed.includes(selected)?selected:''};
    }
    if (method==='moveInstanceBefore') {
      const before=textArg(args,'before');
      if (!inventory.installed.includes(name) || name===before || (before && !inventory.installed.includes(before))) return result('failed','invalidOrder');
      const order=inventory.installed.filter(v=>v!==name);
      if (before) order.splice(order.indexOf(before),0,name); else order.push(name);
      if (!await this.ui.reorder(order)) return result('failed','orderNotSaved');
      return JSON.stringify(this.ui.currentOrder())===JSON.stringify(order)?{'state':'ready','order':order}:result('failed','orderNotSaved');
    }
    if (method==='clearIncompleteInstances') return this.ui.cleanOrphans(inventory.orphans,true,method);
    if (method==='requestInstanceDeletion' && inventory.orphans.includes(name)) return this.ui.cleanOrphans([name],false,method);
    if (method==='requestInstanceDeletion' || method==='renameGameInstance' || method==='repairGameInstance' || method==='verifyGameInstance') {
      const stamps=new SkillFileScope(), dir=root+'/versions';
      const folder=stamps.list(root,dir,'versions');
      const targets=[name];
      if (!targets.length || targets.some(v=>!safeName(v) || (!inventory.installed.includes(v) && !inventory.orphans.includes(v)))) return result('failed','unknownInstance');
      if (owner.gameBusy()) return result('needsUser','gameActive');
      const refs=targets.map(v=>stamps.row(v));
      if (!folder || refs.some(r=>!r)) return result('failed','instanceChanged');
      if (method==='verifyGameInstance') return this.ui.verify(name);
      if (method==='repairGameInstance') return this.ui.repair(name);
      const renamed=textArg(args,'newName');
      if (method==='renameGameInstance' && (!inventory.installed.includes(name) || !safeName(renamed) || validateVersionName(renamed) || fs.accessSync(dir+'/'+renamed))) return result('failed','invalidName');
      const rename=method==='renameGameInstance' ? owner.prepareRename(name) : undefined;
      if (method==='renameGameInstance' && !rename) return result('failed','instanceChanged');
      const title=method==='renameGameInstance'?'将「'+name+'」改名为「'+renamed+'」？':'删除游戏实例「'+name+'」及其文件？';
      LauncherSkillBus.awaitingUser(method);
      if (!await this.ui.confirm(title)) return result('cancelled');
      const current=await port.inventory();
      if (!this.ui.current() || !port.ready() || port.root()!==root || owner.gameBusy() || current.error ||
          ((!current.installed.includes(name) && inventory.installed.includes(name)) || (!current.orphans.includes(name) && inventory.orphans.includes(name))) || targets.some((v,i)=>stamps.resolve(root,dir,'versions',folder,refs[i])!==v)) return result('failed','instanceChanged');
      if (rename) return rename(name,renamed)?{'state':'ready','instance':renamed}:result('failed','renameFailed');
      const epoch=owner.prompt(name);
      if (!owner.pending(name,epoch)) return result('failed','instanceChanged');
      return await owner.remove()?{'state':'ready','removed':name}:result('failed','deleteFailed');
    }
    if (!safeName(name) || !inventory.installed.includes(name)) return result('failed','instanceNotInstalled');
    if (method==='inspectGameInstance') {
      const identity=inspectInstalledVersion(root,name) ?? await inspectLegacyVanilla(root,name,textArg(args,'gameVersion'));
      if (!this.ui.current() || !port.ready() || port.root()!==root) return result('unknown','instanceChanged');
      return identity===null?result('unknown','identityUnproven'):{'state':'ready','instance':name,'gameVersion':identity.gameVersion,'loader':identity.loader,'loaderVersion':identity.loaderVersion};
    }
    if (method==='selectGameInstance') {
      if (!await port.select(name)) return result('failed','selectionNotSaved');
      return this.ui.current() && port.root()===root && port.selected()===name ?
        {'state':'ready','selected':name}:result('unknown','selectionChanged');
    }
    if (method==='openInstancePanel') return await this.ui.open(textArg(args,'panel'),name)?{'state':'needsUser','instance':name,'panel':args['panel']}:result('failed','panelUnavailable');
    if (method==='getInstanceSettings') {
      const overrides=owner.settings(name);
      const answer=this.ui.effectiveSettings(name);
      answer['state']='ready';answer['instance']=name;answer['jdk']=overrides.jdkVersion;answer['resolution']=overrides.renderScalePercent ?? 0;
      answer['language']=overrides.gameLanguage;answer['jdkChoices']=owner.jdkChoices();
      return answer;
    }
    if (method==='setInstanceJdk') {
      const jdk=textArg(args,'jdk');
      if (!this.ui.runningAllowed() || owner.gameBusy() || (jdk!=='inherit' && jdk!=='auto' && !owner.jdkChoices().includes(jdk))) return result('failed','jdkUnavailable');
      return await owner.saveJdk(name,jdk==='inherit'?'':jdk) ? {'state':'ready','instance':name,'jdk':jdk} : result('failed','settingNotSaved');
    }
    if (method==='setInstanceResolution') {
      const percent=args['percent'] as number;
      if (!Number.isSafeInteger(percent) || !this.ui.runningAllowed() || owner.gameBusy()) return result('failed','settingUnavailable');
      await owner.saveResolution(name,percent);
      return root===port.root() && (owner.settings(name).renderScalePercent ?? 0)===percent ? {'state':'ready','percent':percent} : result('failed','settingNotSaved');
    }

    if (method==='launchGameInstance') {
      const key=textArg(args,'operationRef'), input=JSON.stringify(['launch',root,name]);
      const previous=SkillAttempt.get(port.filesDir,key);
      if (previous) return previous.data.input===input?this.observe(port,previous):result('failed','operationRefConflict');
      if (port.selected()!==name || !this.ui.runningAllowed()) return result('needsUser','selectInstanceOrEnableGameInLauncher');
      const record=SkillAttempt.create(port.filesDir,key,name,input,'');
      await this.ui.launch(name,new SkillLaunchObserver(record,this.ui.current));
      return this.observe(port,record);
    }
    return result('failed','unsupportedOperation');
  }
}
