import { LauncherSkillBus } from './LauncherSkillBus';
import { util } from '@kit.ArkTS';
import { DownloadTaskRegistry, isTerminalState, McVersionTask, TaskCategory, UnifiedDownloadAdapter, UnifiedTaskView } from 'feature_core';
import { ModpackInstallTask, modpackFileKey, ResourceFileProvider } from 'mods';
import { makeDownloadTaskSnapshot } from '../components/DownloadTaskSnapshot';
import { isQueuedRetry, publicTaskId, result, textArg } from './LibraryResult';
import { TaskControlOperations } from './TaskControlOperations';

type Data = Record<string,Object>;
interface ObservedTask { adapter:UnifiedDownloadAdapter; activity:number; queuedRetry:boolean; }
interface Choice { adapter:ModpackInstallTask; signature:string; }
export interface TaskPanelUi {
  detail:(id:string)=>void;
  recover:(view:UnifiedTaskView)=>Promise<Data>;
  confirm:(label:string)=>Promise<boolean>;
  active:()=>boolean;
}
export class TaskPanelSkill {
  private refs:Map<string,ObservedTask>=new Map<string,ObservedTask>();
  private choices:Map<string,Choice>=new Map<string,Choice>();
  private readonly registry:DownloadTaskRegistry;
  private readonly ui:TaskPanelUi;
  constructor(registry:DownloadTaskRegistry, ui:TaskPanelUi) {
    this.registry=registry;
    this.ui=ui;
  }
  private choiceSignature(pack:ModpackInstallTask):string {
    return JSON.stringify([pack.getSession()?.id,pack.view.startedAtMs,pack.view.requiresConfirmation,pack.requiresPackageSelection(),
      pack.packageCandidates().map(v=>[v.id,pack.packageSelected(v.id)]),
      pack.optionalFiles().map(v=>[modpackFileKey(v),pack.optionalSelected(v)])]);
  }
  private choicesOf(pack:ModpackInstallTask):Data {
    const token=util.generateRandomUUID();this.choices.clear();this.choices.set(token,{adapter:pack,signature:this.choiceSignature(pack)});
    return {'state':'ready','choiceRef':token,'requiresChoice':pack.view.requiresConfirmation,'canChooseOtherPackage':pack.canChooseOtherPackage(),
      'packages':pack.packageCandidates().map((v,i):Data=>({'index':i,'name':v.title,'selected':pack.packageSelected(v.id)})),
      'files':pack.optionalFiles().map((v,i):Data=>({'index':i,'name':(v.fileNameHint || v.path.split('/').pop() || '').slice(0,180),'selected':pack.optionalSelected(v)}))};
  }
  /** 快照区分父尝试、借用父活动号的排队重试和已经独立开账的新尝试。 */
  private observe(adapter:UnifiedDownloadAdapter):ObservedTask {
    return {adapter:adapter,activity:adapter.view.startedAtMs,queuedRetry:isQueuedRetry(adapter.view)};
  }
  private same(item:ObservedTask):boolean {
    const view = item.adapter.view;
    return this.ui.active() && this.registry.getAdapter(view.id) === item.adapter &&
      view.startedAtMs === item.activity && isQueuedRetry(view) === item.queuedRetry;
  }
  private describe(v:UnifiedTaskView, ref:string):Data {
    return {'id':publicTaskId(v.id,ref),'activityId':isQueuedRetry(v)?0:v.startedAtMs,'title':v.title,'phase':v.state,'category':v.category,'queuePosition':v.queuePosition,
      'bytesDone':v.bytesDone,'bytesTotal':v.bytesTotal,'filesDone':v.filesDone,'filesTotal':v.filesTotal,'errorKind':v.errorKind,
      'canPause':v.canPause,'canResume':v.canResume,'canRetry':v.canRetry,'canCancel':v.canCancel,'requiresConfirmation':v.requiresConfirmation};
  }
  async run(method:string,args:Data):Promise<Data> {
    if (!this.ui.active()) return result('needsUser','queueUnavailable');
    if (method==='listDownloadQueue') {
      const all=makeDownloadTaskSnapshot(this.registry.listAll());
      const filter=textArg(args,'filter') || 'all';
      const selected=filter==='done'?all.done:filter==='active'?all.inProgress:filter==='failed'?all.failed:all.all;
      const data:Data[]=[];this.refs.clear();this.choices.clear();
      for (const v of selected) {
        const adapter=this.registry.getAdapter(v.id);if (!adapter) continue;
        const ref=util.generateRandomUUID();this.refs.set(ref,this.observe(adapter));
        const row=this.describe(v,ref);row['ref']=ref;data.push(row);
      }
      return {'state':'ready','tasks':data,'activeCount':all.activeCount,'waitingCount':all.waitingCount,'progress':all.progress};
    }
    if (method==='clearFinishedTasks') {
      const terminal:ObservedTask[]=[];
      for (const view of this.registry.listAll().filter(v=>isTerminalState(v.state))) {
        const adapter=this.registry.getAdapter(view.id);
        if (!adapter) return result('failed','queueChanged');
        terminal.push(this.observe(adapter));
      }
      if (!terminal.length) return {'state':'ready','removed':0};
      LauncherSkillBus.awaitingUser(method);
      if (!await this.ui.confirm('移除 '+terminal.length+' 条已结束任务记录（保留下载文件）？')) return result('cancelled');
      const count=this.registry.listAll().filter(v=>isTerminalState(v.state)).length;
      if (terminal.length!==count || !terminal.every(item=>this.same(item) && isTerminalState(item.adapter.view.state))) {
        return result('failed','queueChanged');
      }
      return {'state':'ready','removed':this.registry.purgeFinished()};
    }
    const ref=textArg(args,'ref'),observed=this.refs.get(ref);
    if (method==='controlDownloadTask' || method==='confirmModpackChoices') {
      const command=method==='confirmModpackChoices'?'confirm':textArg(args,'action');
      const existing=TaskControlOperations.prior(method==='confirmModpackChoices'?textArg(args,'choiceRef'):ref,command,this.registry,ref);
      if (existing) return existing;
    }
    if (!observed || !this.same(observed)) return result('failed','taskChanged');
    const a=observed.adapter, v=a.view;
    if (method==='getDownloadTaskDetail') {
      const data=this.describe(v,ref);data['state']='ready';
      if (v.category===TaskCategory.MC_VERSION && a instanceof McVersionTask) {
        data['stages']=a.dlState.phaseDetails.map((p):Data=>({'phase':p.phase,'state':p.status,'done':p.current,'total':p.total}));
      }
      if ([TaskCategory.MOD,TaskCategory.SHADER,TaskCategory.RESOURCE_PACK,TaskCategory.DATAPACK].includes(v.category)) {
        const provider=a as Object as ResourceFileProvider;
        data['files']=provider.getFileEntries().map((entry):Data=>({'name':entry.filename,'bytes':entry.sizeBytes}));
        data['currentFiles']=(provider.getCurrentDmView()?.currentFiles ?? []).map((path:string):string=>path.split('/').pop() || '');
      }
      if (v.canViewDetail && args['show']===true) this.ui.detail(v.id);
      return data;
    }
    if (method==='getModpackChoices' || method==='changeModpackChoice' || method==='confirmModpackChoices') {
      if (!(a instanceof ModpackInstallTask)) return result('failed','notModpack');
      if (method==='getModpackChoices') return this.choicesOf(a);
      const key=textArg(args,'choiceRef'), ticket=this.choices.get(key);
      if (!ticket || ticket.adapter!==a || ticket.signature!==this.choiceSignature(a)) return result('failed','choiceChanged');
      if (method==='confirmModpackChoices') {
        if (!v.requiresConfirmation) return result('failed','noConfirmation');
        this.choices.delete(key);
        return TaskControlOperations.submit(key,'confirm',a,this.registry,ref,(started,committed):Promise<void>=>a.confirmAndResume(this.registry,committed,started));
      }
      const kind=textArg(args,'kind'),i=args['index'] as number;
      if (kind==='other' && a.canChooseOtherPackage()) a.chooseOtherPackage();
      else if (!v.requiresConfirmation || !Number.isSafeInteger(i) || i<0) return result('failed','choiceUnavailable');
      else if (kind==='package' && a.requiresPackageSelection() && i<a.packageCandidates().length) a.selectPackage(a.packageCandidates()[i].id);
      else if (kind==='optional' && !a.requiresPackageSelection() && i<a.optionalFiles().length && typeof args['selected']==='boolean') a.setOptionalSelected(a.optionalFiles()[i],args['selected']===true);
      else return result('failed','choiceUnavailable');
      // 只有实际选择成功才签发新引用；参数错误时原引用仍可用于纠正本轮选择。
      return this.choicesOf(a);
    }
    if (method!=='controlDownloadTask') return result('failed','unsupportedOperation');
    const action=textArg(args,'action');
    if (action==='externalRecovery' && v.canRecoverExternally) return this.ui.recover(v);
    if (action==='remove' && isTerminalState(v.state)) {
      LauncherSkillBus.awaitingUser(method);
      if (!await this.ui.confirm('移除「'+v.title+'」的任务记录？')) return result('cancelled');
      if (!this.same(observed) || !isTerminalState(v.state)) return result('failed','taskChanged');
      this.registry.remove(v.id); return this.registry.getAdapter(v.id)===a?result('failed','removeRefused'):result('ready');
    }
    if (!['pause','resume','retry','cancel'].includes(action)) return result('failed','controlUnavailable');
    if (action==='cancel') {
      if (!v.canCancel) return result('failed','controlUnavailable');
      LauncherSkillBus.awaitingUser(method);
      if (!await this.ui.confirm('取消「'+v.title+'」并保留已下载文件？')) return result('cancelled');
      if (!this.same(observed) || !v.canCancel) return result('failed','taskChanged');
    }
    if ((action==='pause' && (!v.canPause || v.state==='waiting')) ||
      (action==='resume' && (v.state==='waiting' || !v.canResume || v.requiresConfirmation)) ||
      (action==='retry' && (v.state==='waiting' || !v.canRetry || v.canRecoverExternally))) return result('failed','controlUnavailable');
    this.refs.delete(ref);
    return TaskControlOperations.submit(ref,action,a,this.registry,ref,(started,_committed):Promise<void>=>{
      if (action==='resume') return this.registry.resume(v.id,started);
      if (action==='retry') return this.registry.retry(v.id,started);
      if (action==='pause') return this.registry.pause(v.id);
      return this.registry.cancel(v.id,false,started);
    });
  }
}
