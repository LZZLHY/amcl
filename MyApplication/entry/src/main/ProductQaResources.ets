import { fileIo as fs } from '@kit.CoreFileKit';
import { AtomicFileWriter, ledgerManifestAsync, LedgerState } from 'commons';
import { ProductQa } from 'entry/ProductQa';
import { qaTaskId } from './QaTaskIdentity';
import { resourceProjectKey, resourceSearchKey } from './ets/launcherskill/ResourceSearchIdentity';
import { ResourceBrowseAccess, ResourceDetailSelection, ResourceEnqueued } from './ets/runtime/ResourceBrowseAccess';
import { getDownloadTaskRegistry, UnifiedDownloadAdapter, TaskCategory, ActivityCategory, isTerminalState } from 'feature_core';
import { ModpackInstallTask, modpackFileKey, ModSearchState, RemoteProject, RemoteVersion, ResourceKind, SortBy } from 'mods';

type Args = Record<string, Object>;
interface Page { offset: number; limit: number; }
interface Confirmation { id: string; operation: string; choiceState: string; resumeState: string; }
interface ActivityBinding { activity: number; title: string; category: string; version: string; }
interface Owned { binding?: ActivityBinding; confirmation?: Confirmation; stop?: () => void; task: UnifiedDownloadAdapter; root: string; id: string; choice: string; fingerprint: string; saved: string; }
interface Trace { root?: string; complete?: boolean; missing?: number; instance?: string; confirmation?: Confirmation; schema: number; operationId: string; alias: string; activity: number; title: string; category: string; version: string; }
interface ImportState { request: string; state: string; archive: string; root: string; planId: string; name: string; }
interface Plan { id: string; binding: string; }

function reply(status: string, reason: string, data: Args = {}): string {
  return JSON.stringify({status:status,reason:reason,data:data});
}
function keys(args: Args, allowed: string[]): boolean { return Object.keys(args).every((key: string): boolean => allowed.includes(key)); }
function str(args: Args, name: string): string { return typeof args[name] === 'string' ? args[name] as string : ''; }
function pageOf(args: Args): Page | null {
  const offset = args['offset'] ?? 0;
  const limit = args['limit'] ?? 20;
  if (typeof offset !== 'number' || !Number.isSafeInteger(offset) || offset < 0 ||
    typeof limit !== 'number' || !Number.isInteger(limit) || limit < 1 || limit > 50) return null;
  return {offset:offset,limit:limit};
}

/** 指纹仅在本进程比较。真实文件、目标和依赖选择任一变化都需要再看一遍计划。 */
function detailKey(info: ResourceDetailSelection): string {
  return JSON.stringify([info.session,info.revision,info.project.source,info.project.id,info.project.kind,
    info.selected?.id,info.file,info.name,info.root,info.target,info.isolation,info.sourcePolicy,
    info.deps.map((row): string => JSON.stringify([row.key,row.versionNumber,row.selected,row.alreadyInstalled]))]);
}

/** retry 排队时卡片仍携带旧 startedAtMs，出队后才分配新活动。两个阶段均不能认领。 */
function superseded(entry: Owned): boolean {
  const bound=entry.binding;
  if (!bound) return false;
  const view=entry.task.view;
  return bound.activity!==view.startedAtMs ||
    (view.state==='waiting' && view.activityRelation==='retry' && view.parentActivityId===bound.activity);
}

function taskData(operation: string, entry: Owned): Args {
  const view = entry.task.view;
  const data: Args = {'operationId':operation,'taskId':entry.id,'state':view.state,'activityId':view.startedAtMs};
  if (entry.confirmation !== undefined) data['confirmation']=entry.confirmation;
  if (view.category===TaskCategory.MODPACK) {
    const pack=entry.task as ModpackInstallTask;
    const installed=pack.getResult();
    data['requiresConfirmation']=view.requiresConfirmation;
    data['instance']=installed?.versionName ?? pack.getInstallName();
    const committed=installed!==null && pack.getSession()?.complete===true;
    data['missingCount']=committed?installed!.missing.length:-1;
    data['complete']=committed && installed!.missing.length===0;
    data['completeness']=committed?(data['complete']===true?'complete':'partial'):'unknown';
  }
  return data;
}

/** 任务面板会短暂遮蔽资源页，任务归属由原注册对象决定，不能凭名字或另一项相同下载认领。 */
export class ProductQaResources {
  private static scope: string = '';
  private static tasks: Map<string, Owned> = new Map<string, Owned>();
  private local: ImportState | null = null;
  private get: () => ResourceBrowseAccess;
  private dir: string = '';
  private search: string = '';
  private queryKey: string = '';
  private context: string = '';
  private projects: RemoteProject[] = [];
  private nextOffset: number = 0;
  private detail: number = 0;
  private plan: Plan | null = null;

  private constructor(get: () => ResourceBrowseAccess) { this.get = get; }
  static bind(owner: Object, get: () => ResourceBrowseAccess): void {
    const surface = new ProductQaResources(get);
    ProductQa.bindSurface('resources', owner, (action: string, json: string, request: string): Promise<string> =>
      surface.run(action,json,request));
  }
  static unbind(owner: Object): void { ProductQa.unbindSurface('resources', owner); }

  private same(port: ResourceBrowseAccess, dir: string): boolean {
    return ProductQa.sessionDirectory() === dir && dir.length > 0 && port.available();
  }
  private validSearch(port: ResourceBrowseAccess, args: Args): boolean {
    return port.available() && this.search !== '' && str(args,'searchId') === this.search && this.queryKey !== '' &&
      resourceSearchKey(port.view().lastRequest)===this.queryKey && port.contextKey()===this.context;
  }

  /** 筛选相同的后台刷新不夺走已回传项目的归属，续页仍必须经过原游标。 */
  private projectPage(view: ModSearchState, projects: RemoteProject[]): string {
    const rows = projects.map((p): Args => ({'source':p.source,'projectId':p.id,'kind':p.kind,'title':p.title.slice(0,160)}));
    const data: Args = {'searchId':this.search,'kind':view.kind,'query':view.query,'loader':view.lastRequest?.loaders?.[0] ?? '',
      'gameVersion':view.lastRequest?.gameVersion ?? '','sort':view.sortBy,'projects':rows,'total':view.totalHits,
      'hasMore':view.hasMore,'errorKind':view.errorKind ?? '','errorSource':view.errorSource ?? '','httpStatus':view.httpStatus};
    return reply(view.errorMessage === null ? 'ok' : 'unknown', view.errorMessage === null ? '' : 'RESOURCE_SEARCH_FAILED', data);
  }

  private async find(port: ResourceBrowseAccess, args: Args, request: string, next: boolean): Promise<string> {
    const dir = this.dir;
    if (port.detail() !== null) return reply('needsUser','RESOURCE_DETAIL_OPEN');
    let pending: Promise<void>;
    if (next) {
      if (!keys(args,['searchId']) || !this.validSearch(port,args)) return reply('rejected','SEARCH_CHANGED');
      const view = port.view();
      if (view.loading) return reply('unknown','SEARCH_PENDING');
      if (view.nextOffset!==this.nextOffset) return reply('unknown','SEARCH_PAGE_RESET');
      if (!view.hasMore || view.errorMessage!==null) return this.projectPage(view,[]);
      pending = port.next();
    } else {
      if (!keys(args,['query','kind','loader','gameVersion','sort']) || typeof args['query'] !== 'string' ||
        str(args,'kind') !== port.kind() || str(args,'query').length>180 ||
        (args['loader'] !== undefined && (typeof args['loader'] !== 'string' ||
          !['','fabric','forge','neoforge','quilt'].includes(str(args,'loader')))) ||
        (args['gameVersion'] !== undefined && typeof args['gameVersion'] !== 'string') ||
        (args['sort'] !== undefined && !['downloads','relevance','newest','updated'].includes(str(args,'sort')))) {
        return reply('rejected','INVALID_ARGUMENTS_OR_RESOURCE_KIND');
      }
      this.search = ''; this.queryKey = ''; this.projects = []; this.detail = 0; this.plan = null;
      pending = port.search(str(args,'query'),args['loader'] as string | undefined,
        args['gameVersion'] as string | undefined,args['sort'] as SortBy | undefined);
    }
    const queryKey = resourceSearchKey(port.view().lastRequest);
    const context = port.contextKey();
    await pending;
    const view = port.view();
    if (!this.same(port,dir) || !queryKey || resourceSearchKey(view.lastRequest)!==queryKey || context!==port.contextKey())
      return reply('unknown','SEARCH_CHANGED');
    if (view.loading) return reply('unknown','SEARCH_PENDING');
    if (next && view.lastRequest?.offset!==this.nextOffset) return reply('unknown','SEARCH_PAGE_RESET');
    if (!next) this.search=request;
    const seen=this.projects.map(resourceProjectKey);
    const rows=view.hits.filter((p): boolean=>!seen.includes(resourceProjectKey(p))).slice(0,50);
    this.projects=this.projects.concat(rows);
    this.nextOffset=view.nextOffset; this.context=context; this.queryKey=queryKey;
    return this.projectPage(view,rows);
  }

  private async versions(port: ResourceBrowseAccess,args: Args): Promise<string> {
    const page=pageOf(args);
    if (!page || !keys(args,['searchId','source','projectId','offset','limit']) || !this.validSearch(port,args)) return reply('rejected','INVALID_SEARCH');
    const project=this.projects.find((p): boolean => p.source===args['source'] && p.id===args['projectId'] && p.kind===port.kind());
    if (!project) return reply('rejected','PROJECT_NOT_IN_PRODUCT_RESULTS');
    const dir=this.dir;
    let info=port.detail();
    if (info===null) {
      const opening=port.open(project);
      this.detail=port.detail()?.session ?? 0;
      await opening;
      info=port.detail();
    }
    if (!this.same(port,dir) || !this.validSearch(port,args) || !info || !this.detail || info.session!==this.detail ||
      info.project.id!==project.id || info.project.source!==project.source) return reply('needsUser','DETAIL_CHANGED');
    if (info.loading) return reply('unknown','RESOURCE_DETAIL_PENDING');
    if (info.error && info.versions.length===0) return reply('unknown','RESOURCE_VERSIONS_UNAVAILABLE');
    const versions=info.versions.slice(page.offset,page.offset+page.limit).map((v: RemoteVersion): Args =>
      ({'versionId':v.id,'name':v.versionNumber.slice(0,160),'loaders':v.loaders.slice(0,12),'gameVersions':v.gameVersions.slice(0,64)}));
    return reply('ok','',{'source':project.source,'projectId':project.id,'versions':versions,'total':info.versions.length,'offset':page.offset});
  }

  private showPlan(port: ResourceBrowseAccess, info: ResourceDetailSelection, token: string): string {
    if (info.loading || !info.ready || info.error || !info.file || !info.selected) { this.plan=null; return reply('needsUser','INSTALL_PLAN_UNAVAILABLE'); }
    if (info.saveOnly) { this.plan=null; return reply('needsUser','SYSTEM_SAVE_PICKER_REQUIRED'); }
    this.plan={id:token,binding:detailKey(info)};
    const deps=info.deps.map((dep): Args => ({'key':dep.key,'name':dep.displayName.slice(0,160),'kind':dep.dependencyType,
      'selected':dep.selected,'installed':dep.alreadyInstalled}));
    return reply('ok','',{'planId':token,'source':info.project.source,'projectId':info.project.id,'versionId':info.selected.id,
      'kind':port.kind(),'target':info.target,'filename':info.file.filename,'dependencies':deps});
  }

  private async prepare(port: ResourceBrowseAccess,args: Args,request: string,option: boolean): Promise<string> {
    const dir=this.dir;
    let info=port.detail();
    if (!info || info.session!==this.detail || !this.detail) return reply('rejected','DETAIL_CHANGED');
    if (option) {
      if (!keys(args,['planId','key','selected']) || !this.plan || str(args,'planId')!==this.plan.id ||
        this.plan.binding!==detailKey(info) || typeof args['selected']!=='boolean') return reply('rejected','PLAN_CHANGED');
      const row=info.deps.find((r): boolean => r.key===args['key']);
      if (!row || row.dependencyType!=='optional' || row.alreadyInstalled) return reply('rejected','UNAVAILABLE_OPTION');
      this.plan=null;
      if (row.selected!==args['selected']) await port.toggle(row.key);
    } else {
      if (!keys(args,['searchId','source','projectId','versionId','versionName']) || !this.validSearch(port,args) ||
        info.project.source!==args['source'] || info.project.id!==args['projectId']) return reply('rejected','PROJECT_CHANGED');
      const project=info.project;
      const version=info.versions.find((v: RemoteVersion): boolean => v.id===args['versionId'] && v.projectId===project.id && v.source===project.source);
      if (!version) return reply('rejected','VERSION_NOT_IN_PRODUCT_RESULTS');
      if (args['versionName']!==undefined) {
        if (info.project.kind!==ResourceKind.MODPACK || typeof args['versionName']!=='string' || !str(args,'versionName').length) return reply('rejected','INVALID_VERSION_NAME');
        port.rename(str(args,'versionName'));
      }
      this.plan=null;
      await port.pick(version);
    }
    info=port.detail();
    if (!info || !this.same(port,dir) || info.session!==this.detail || port.contextKey()!==this.context ||
      (!option && info.selected?.id!==args['versionId'])) return reply('rejected','PLAN_CHANGED');
    return this.showPlan(port,info,request);
  }

  private install(port: ResourceBrowseAccess,args: Args,request: string): string {
    const info=port.detail();
    if (!keys(args,['planId']) || !this.plan || str(args,'planId')!==this.plan.id || !info || !info.ready || info.error || info.loading ||
      info.saveOnly || info.session!==this.detail || this.plan.binding!==detailKey(info) || port.contextKey()!==this.context) return reply('rejected','PLAN_CHANGED');
    this.plan=null;
    return this.enqueue(port.submit,request);
  }

  /** 业务进程重启后保留可核对的活动号，以及原确认与异步恢复各自已知的结局。 */
  private static remember(directory: string, request: string, entry: Owned, force: boolean): void {
    const view=entry.task.view;
    if (ProductQa.sessionDirectory()!==directory || getDownloadTaskRegistry().getAdapter(view.id)!==entry.task || view.startedAtMs<=0) return;
    // 同一 adapter 可以被产品 retry 重用。只绑定第一次真正出队的活动，后来重试永远不能替代本次终态。
    if (!entry.binding) {
      // 账本按首次出队快照建档。整合包完成后卡片标题会变为实际实例名，不能覆盖原活动标题。
      entry.binding={activity:view.startedAtMs,title:view.title,version:view.activityGameVersion,
        category:view.activityCategory || (view.category===TaskCategory.MODPACK?ActivityCategory.MODPACK:ActivityCategory.MOD_INSTALL)};
    }
    const original=entry.binding;
    if (superseded(entry) || (!force && entry.saved.length>0 && !isTerminalState(view.state))) return;
    const trace: Trace={schema:1,operationId:request,root:entry.root,alias:entry.id,activity:original.activity,title:original.title,
      category:original.category,version:original.version,confirmation:entry.confirmation};
    // 所有确认号都只引用原操作。最终实例、缺件等证据只保存在原活动，后续人工操作也更新这一份。
    if (request===entry.root && view.category===TaskCategory.MODPACK && view.state==='done') {
      const pack=entry.task as ModpackInstallTask;
      const installed=pack.getResult();
      if (installed!==null && pack.getSession()?.complete===true) {
        trace.instance=installed.versionName; trace.missing=installed.missing.length; trace.complete=installed.missing.length===0;
      }
    }
    try {
      const json=JSON.stringify(trace);
      if (json!==entry.saved) { AtomicFileWriter.write(directory+'/resource-'+request+'.json',json); entry.saved=json; }
    } catch (_) { /* 活对象仍可查询；缺少耐久证据时重启后按未知处理。 */ }
  }

  /** 接受提交后只观察这一真实 adapter。保存原活动身份，冷启动后的计数和结局仍取生产账本。 */
  private enqueue(submit: (capture: ResourceEnqueued) => void, request: string): string {
    const directory=this.dir;
    submit((task: UnifiedDownloadAdapter, completion: Promise<void>): void => {
      const entry: Owned={task:task,root:request,id:qaTaskId(directory,task.view),choice:'',fingerprint:'',saved:''};
      ProductQaResources.tasks.set(request,entry);
      const registry=getDownloadTaskRegistry();
      let admitted=false;
      let settled=false;
      const update=(): void => {
        if (!entry.stop) return;
        const view=task.view;
        const current=registry.getAdapter(view.id)===task;
        if (ProductQa.sessionDirectory()!==directory || (!current && (admitted || settled)) || superseded(entry)) { entry.stop(); return; }
        if (!current) return;
        admitted=true;
        ProductQaResources.remember(directory,request,entry,false);
        // enqueue 的 Promise 在等待选择时也会兑现。保留对原活动的监听，直至人工或自动续跑完成。
        if (view.category!==TaskCategory.MODPACK && settled) { entry.stop(); return; }
        if (isTerminalState(view.state) && !view.canResume && !view.requiresConfirmation &&
          !(view.category===TaskCategory.MODPACK && view.state==='error' && (task as ModpackInstallTask).canChooseOtherPackage())) entry.stop();
      };
      entry.stop=(): void => {
        entry.stop=undefined;
        // Registry 正在遍历监听数组，移除推迟到微任务以免跳过下一个业务监听。
        Promise.resolve().then((): void => registry.removeListener(update));
      };
      registry.addListener(update);
      update();
      const finish=(): void => { settled=true; update(); };
      completion.then(finish,finish);
    });
    const entry=ProductQaResources.tasks.get(request);
    if (!entry) return reply('rejected','PRODUCT_INSTALL_NOT_SUBMITTED');
    const registered=getDownloadTaskRegistry().getAdapter(entry.task.view.id)===entry.task;
    return reply(registered?'accepted':'unknown',registered?'':'AWAIT_TASK_ADMISSION',taskData(request,entry));
  }

  private readTrace(directory: string, request: string): Trace | null {
    if (!/^[a-f0-9]{32}$/.test(request)) return null;
    const path=directory+'/resource-'+request+'.json';
    if (!fs.accessSync(path)) return null;
    const stat=fs.lstatSync(path);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size>8192) return null;
    const trace=JSON.parse(fs.readTextSync(path)) as Trace;
    if (trace.schema!==1 || trace.operationId!==request || !Number.isSafeInteger(trace.activity) || trace.activity<=0 ||
      typeof trace.alias!=='string' || !/^observation-[0-9]+$/.test(trace.alias)) return null;
    return trace;
  }

  private async coldTask(port: ResourceBrowseAccess, request: string): Promise<string> {
    if (!/^[a-f0-9]{32}$/.test(request)) return reply('rejected','INVALID_OPERATION');
    const directory=this.dir;
    const record=this.readTrace(directory,request);
    if (!record) return reply('unknown','ORIGINAL_TASK_UNAVAILABLE');
    const trace=record.root && record.root!==request ? this.readTrace(directory,record.root) : record;
    if (!trace || (record.root!==undefined && trace.root!==trace.operationId) || trace.activity!==record.activity ||
      trace.alias!==record.alias || trace.category!==record.category || trace.title!==record.title || trace.version!==record.version) {
      return reply('unknown','INVALID_TASK_RECORD');
    }
    const filesDir=port.filesDir();
    if (!filesDir) return reply('unknown','LAUNCHER_CONTEXT_UNAVAILABLE');
    const ledger=await ledgerManifestAsync(filesDir,trace.activity);
    if (!this.same(port,directory) || !ledger || ledger.activityId!==trace.activity || ledger.category!==trace.category ||
      ledger.title!==trace.title || (ledger.gameVersionId ?? '')!==(trace.version ?? '')) return reply('unknown','ORIGINAL_TASK_UNAVAILABLE');
    const terminal=ledger.outcomeSource==='task.owner';
    const state=!terminal?'':ledger.state===LedgerState.SUCCESS?'done':ledger.state===LedgerState.FAILED?'error':ledger.state===LedgerState.ABORTED?'aborted':'';
    // 调度拒绝可独立于活动终态获证。冷恢复无法从 RUNNING 推测队列已开跑。
    const data: Args={'operationId':request,'taskId':trace.alias,'state':state || 'unknown','activityId':trace.activity};
    const c=record.confirmation;
    let resumeFailed=false;
    if (c && /^[a-f0-9]{32}$/.test(c.id) && /^[a-f0-9]{32}$/.test(c.operation) && (c.id===request || c.operation===request) &&
      ['pending','committed','unknown'].includes(c.choiceState) && ['pending','returned','failed'].includes(c.resumeState)) {
      data['confirmation']=c;
      resumeFailed=c.resumeState==='failed';
    }
    if (trace.category===ActivityCategory.MODPACK) {
      const qualified=typeof trace.complete==='boolean' && typeof trace.instance==='string' &&
        typeof trace.missing==='number' && Number.isSafeInteger(trace.missing) && trace.missing>=0 && trace.complete===(trace.missing===0);
      data['instance']=qualified?trace.instance!:'';
      data['complete']=qualified && trace.complete===true; data['missingCount']=qualified?trace.missing!:-1;
      data['completeness']=qualified?(trace.complete?'complete':'partial'):'unknown';
      if (state==='done' && !qualified) return reply('unknown','PACK_COMPLETENESS_UNPROVEN',data);
    }
    if (resumeFailed) return reply('ok','RESUME_FAILED',data);
    return state?reply('ok','',data):reply('unknown','ORIGINAL_TASK_UNAVAILABLE',data);
  }

  /** 文件路径只由系统 picker 和产品复制流程产生，宿主传递原操作编号和待确认名称。 */
  private localImport(port: ResourceBrowseAccess,action: string,args: Args,request: string): string {
    if (port.kind()!==ResourceKind.MODPACK) return reply('rejected','OPEN_MODPACK_PAGE_FIRST');
    const draft=port.local();
    if (action==='modpacks.importLocal') {
      if (!keys(args,[])) return reply('rejected','INVALID_ARGUMENTS');
      if (port.detail()!==null || draft!==null || this.local?.state==='waitingForPicker') return reply('needsUser','PICKER_OR_DETAIL_BUSY');
      const directory=this.dir;
      const originalContext=port.contextKey();
      const pending: ImportState={request:request,state:'waitingForPicker',archive:'',root:'',name:'',planId:''};
      this.local=pending;
      port.importLocal((): boolean => ProductQa.sessionDirectory()===directory && this.local===pending &&
        port.kind()===ResourceKind.MODPACK && port.contextKey()===originalContext)
        .then((state: string): void => {
          const current=port.local();
          if (this.local!==pending || ProductQa.sessionDirectory()!==directory) return;
          pending.state=state==='selected' && !current?'expired':state;
          if (state==='selected' && current) {pending.archive=current.archive; pending.root=current.root; pending.name=current.name;}
        }).catch((): void => { pending.state='failed'; });
      return reply('needsUser','SYSTEM_FILE_PICKER',{'operationId':request,'state':pending.state,'name':''});
    }
    const pending=this.local;
    if (!pending || pending.request!==args['operationId']) return reply('unknown','IMPORT_NOT_FOUND');
    if (pending.state==='selected' && (!draft || draft.archive!==pending.archive || draft.root!==pending.root)) pending.state='expired';
    if (action==='modpacks.importStatus' && keys(args,['operationId'])) {
      return reply('ok','',{'operationId':pending.request,'state':pending.state,'name':draft?.name ?? ''});
    }
    if (!draft || pending.state!=='selected') return reply('needsUser','FILE_NOT_SELECTED');
    if (action==='modpacks.localPlan' && keys(args,['operationId','versionName'])) {
      if (args['versionName']!==undefined) {
        if (!str(args,'versionName')) return reply('rejected','INVALID_VERSION_NAME');
        port.renameLocal(str(args,'versionName'));
      }
      const current=port.local();
      if (!current || !current.valid || current.archive!==pending.archive || current.root!==pending.root) return reply('rejected','INVALID_LOCAL_PLAN');
      pending.name=current.name;pending.planId=request;
      return reply('ok','',{'operationId':pending.request,'planId':request,'name':current.name});
    }
    if (action==='modpacks.installLocal' && keys(args,['operationId','planId'])) {
      if (!pending.planId || args['planId']!==pending.planId || !draft.valid || draft.name!==pending.name) return reply('rejected','LOCAL_PLAN_CHANGED');
      pending.planId='';
      const result=this.enqueue(port.submitLocal,request);
      pending.state=ProductQaResources.tasks.has(request)?'submitted':'notSubmitted';
      return result;
    }
    return reply('rejected','INVALID_IMPORT_ACTION');
  }

  /** 标记选择已提交后再向 Registry 申请继续。延迟的拒绝可用原安装号或本次确认号回读。 */
  private async confirmPack(task: ModpackInstallTask,entry: Owned,operation: string,request: string): Promise<string> {
    const dir=this.dir;
    const original=ProductQaResources.tasks.get(entry.root);
    if (!original || original.task!==task) return reply('unknown','ORIGINAL_TASK_UNAVAILABLE');
    const state: Confirmation={id:request,operation:entry.root,choiceState:'pending',resumeState:'pending'};
    const attempt: Owned={task:task,root:entry.root,id:entry.id,choice:'',fingerprint:'',binding:original.binding,saved:'',confirmation:state};
    original.confirmation=state;
    ProductQaResources.tasks.set(request,attempt);
    const save=(): void => {
      ProductQaResources.remember(dir,request,attempt,true);
      if (original.confirmation===state) ProductQaResources.remember(dir,entry.root,original,true);
    };
    save();
    try {
      const work=task.confirmAndResume(getDownloadTaskRegistry(),(): void => { state.choiceState='committed'; save(); });
      work.then((): void => { state.resumeState='returned'; save(); },(): void => { state.resumeState='failed'; save(); });
      // 立即拒绝可直接在回复里暴露，长任务只报告受理后继续回读。
      await Promise.resolve();
    } catch (_) {
      if (state.choiceState==='pending') state.choiceState='unknown';
      state.resumeState='failed'; save();
    }
    const failure=state.resumeState==='failed';
    return reply(failure?'rejected':'accepted',failure?'CONFIRM_OR_RESUME_FAILED':'',taskData(operation,attempt));
  }

  private async pack(port: ResourceBrowseAccess,entry: Owned,operation: string,action: string,args: Args,request: string): Promise<string> {
    const task=entry.task as ModpackInstallTask;
    if (task.view.category!==TaskCategory.MODPACK || !task.view.requiresConfirmation || !task.getSession()) return reply('rejected','NO_PENDING_PACKAGE_CHOICE');
    const candidates=task.packageCandidates();
    const optional=task.optionalFiles();
    const names=candidates.map((item): string => item.id);
    const options=optional.map((item): string => modpackFileKey(item));
    const fingerprint=JSON.stringify([task.getSession()?.id,task.view.startedAtMs,task.getInstallName(),task.requiresPackageSelection(),names,
      names.map((id: string): boolean => task.packageSelected(id)),options,optional.map((item): boolean => task.optionalSelected(item))]);
    if (action!=='modpacks.options') {
      if (!entry.choice || args['choiceId']!==entry.choice || fingerprint!==entry.fingerprint) return reply('rejected','PACKAGE_CHOICE_CHANGED');
      if (action==='modpacks.confirm') {
        if (!keys(args,['operationId','choiceId'])) return reply('rejected','INVALID_ARGUMENTS');
        entry.choice=''; entry.fingerprint='';
        return this.confirmPack(task,entry,operation,request);
      }
      if (!keys(args,['operationId','choiceId','key','selected'])) return reply('rejected','INVALID_ARGUMENTS');
      const key=str(args,'key');
      if (!/^(package|optional)-([0-9]{1,6})$/.test(key)) return reply('rejected','INVALID_OPTION');
      const i=Number(key.split('-')[1]);
      if (key==='package-'+i && task.requiresPackageSelection() && candidates[i]!==undefined && args['selected']===undefined) task.selectPackage(candidates[i].id);
      else if (key==='optional-'+i && !task.requiresPackageSelection() && optional[i]!==undefined && typeof args['selected']==='boolean') task.setOptionalSelected(optional[i],args['selected'] as boolean);
      else return reply('rejected','INVALID_OPTION');
      const after: Args={'operationId':operation,'offset':Math.floor(i/20)*20};
      return this.pack(port,entry,operation,'modpacks.options',after,request);
    }
    const page=pageOf(args);
    if (!page || !keys(args,['operationId','offset','limit'])) return reply('rejected','INVALID_ARGUMENTS');
    entry.choice=request; entry.fingerprint=fingerprint;
    return reply('ok','',{'operationId':operation,'choiceId':request,'name':task.getInstallName(),
      'packages':candidates.slice(page.offset,page.offset+page.limit).map((item,j: number): Args =>
        ({'key':'package-'+(page.offset+j),'title':item.title.slice(0,160),'kind':item.kind,'selected':task.packageSelected(item.id)})),
      'optional':optional.slice(page.offset,page.offset+page.limit).map((item,j: number): Args =>
        ({'key':'optional-'+(page.offset+j),'name':(item.fileNameHint || item.path.split('/').pop() || '').slice(0,160),'selected':task.optionalSelected(item)})),
      'total':task.requiresPackageSelection()?candidates.length:optional.length,'offset':page.offset});
  }

  private async run(action: string,json: string,request: string): Promise<string> {
    const dir=ProductQa.sessionDirectory();
    if (!dir || !/^[a-f0-9]{32}$/.test(request)) return reply('rejected','SESSION_UNAVAILABLE');
    if (this.dir!==dir) {
      this.dir=dir; this.search=''; this.queryKey=''; this.projects=[]; this.detail=0; this.plan=null; this.local=null;
    }
    if (ProductQaResources.scope!==dir) {
      ProductQaResources.tasks.forEach((item: Owned): void => { item.stop?.(); });
      ProductQaResources.tasks.clear(); ProductQaResources.scope=dir;
    }
    const port=this.get();
    try {
      const args=JSON.parse(json) as Args;
      if (!args || Array.isArray(args) || typeof args!=='object') return reply('rejected','INVALID_ARGUMENTS');
      // 导航受理只说明已发令；此查询核对实际挂载的资源页、类别及已打开详情。
      if (action==='resources.status') {
        const kind=port.kind();
        if (!keys(args,['kind']) || ![ResourceKind.MOD,ResourceKind.SHADER,ResourceKind.RESOURCE_PACK,ResourceKind.MODPACK].some((value): boolean=>value===args['kind']))
          return reply('rejected','INVALID_RESOURCE_KIND');
        const detail=port.detail();
        const ready=this.same(port,dir) && kind===args['kind'];
        return reply(ready?'ok':'unknown',ready?'':'RESOURCE_PAGE_PENDING',{'kind':kind,'ready':ready,
          'detailOpen':detail!==null,'detailOwned':detail!==null && this.detail>0 && detail.session===this.detail,
          'localDetailOpen':port.local()!==null});
      }
      // 文件选择器前台占位时仍允许读取同一挂起请求，不能用它提交新业务。
      if (action!=='modpacks.importStatus' && !this.same(port,dir)) return reply('needsUser','RESOURCE_PAGE_UNAVAILABLE');
      if (action==='modpacks.importLocal' || action==='modpacks.importStatus' || action==='modpacks.localPlan' || action==='modpacks.installLocal')
        return this.localImport(port,action,args,request);
      if (port.local()!==null) return reply('needsUser','LOCAL_DETAIL_OPEN');
      if (action==='resources.search' || action==='resources.next') return await this.find(port,args,request,action==='resources.next');
      if (action==='resources.versions') return await this.versions(port,args);
      if (action==='resources.plan' || action==='resources.option') return await this.prepare(port,args,request,action==='resources.option');
      if (action==='resources.install') return this.install(port,args,request);
      if (action==='resources.dismiss') {
        // 原详情的收口不依赖后台搜索；跨会话、用户另开的详情或错误引用仍拒绝。
        if (!keys(args,['searchId']) || !this.search || str(args,'searchId')!==this.search || !this.detail ||
          port.detail()?.session!==this.detail) return reply('rejected','DETAIL_CHANGED');
        port.dismiss(); this.plan=null; this.detail=0; return reply('ok','',{'dismissed':true});
      }
      const operation=str(args,'operationId');
      const entry=ProductQaResources.tasks.get(operation);
      if (!entry || getDownloadTaskRegistry().getAdapter(entry.task.view.id)!==entry.task || superseded(entry)) return action==='resources.task' && keys(args,['operationId'])
        ? await this.coldTask(port,operation) : reply('unknown','ORIGINAL_TASK_UNAVAILABLE');
      if (action==='resources.task' && keys(args,['operationId'])) {
        ProductQaResources.remember(dir,operation,entry,false);
        const data=taskData(operation,entry);
        return data['state']==='done' && data['completeness']==='unknown'?reply('unknown','PACK_COMPLETENESS_UNPROVEN',data):
          reply('ok',entry.confirmation?.resumeState==='failed'?'RESUME_FAILED':'',data);
      }
      if (action==='modpacks.options' || action==='modpacks.choose' || action==='modpacks.confirm') return await this.pack(port,entry,operation,action,args,request);
      return reply('rejected','UNKNOWN_RESOURCE_ACTION');
    } catch (_) {
      return reply('unknown','RESOURCE_OPERATION_UNAVAILABLE');
    }
  }
}
