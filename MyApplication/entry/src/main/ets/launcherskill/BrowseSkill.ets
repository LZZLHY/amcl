import { LauncherSkillBus } from './LauncherSkillBus';
import { util } from '@kit.ArkTS';
import { getDownloadTaskRegistry, UnifiedDownloadAdapter } from 'feature_core';
import { ResourceOperation } from './ResourceOperation';
import { ModSearchState, RemoteProject, ResourceKind, SortBy, validateModpackVersionName } from 'mods';
import { ResourceBrowseAccess, ResourceDetailSelection } from '../runtime/ResourceBrowseAccess';
import { result, textArg } from './LibraryResult';
import { resourceProjectKey, resourceSearchKey } from './ResourceSearchIdentity';

type Data = Record<string,Object>;

function fingerprint(info:ResourceDetailSelection):string {
  return JSON.stringify([info.session,info.revision,info.root,info.target,info.isolation,info.sourcePolicy,info.project.source,info.project.id,
    info.selected?.id,info.file,info.name,info.saveOnly,info.deps.map(d=>[d.key,d.versionNumber,d.selected,d.alreadyInstalled])]);
}

/** 面板与脚本共享 ResourceBrowseAccess。每次读当前的结果、目标和选择，过期选版或确认只会失效。 */
export class BrowseSkill {
  private search='';
  private queryKey='';
  private context='';
  private projects: RemoteProject[]=[];
  private nextOffset=0;
  private detail=0;
  private plan='';
  private chosen='';
  private localRef='';
  private archive='';
  private localName='';
  private localRoot='';


  private readonly access:()=>ResourceBrowseAccess;
  constructor(access:()=>ResourceBrowseAccess) {
    this.access=access;
  }
  private valid(port:ResourceBrowseAccess,args:Data):boolean {
    return port.available() && !!this.search && textArg(args,'searchRef')===this.search &&
      port.contextKey()===this.context && this.queryKey!=='' && resourceSearchKey(port.view().lastRequest)===this.queryKey;
  }
  /** 详情只使用本搜索真正返回过的项目。后台同筛选刷新暂时清空列表时也可继续打开原项目。 */
  private snapshot(view:ModSearchState, rows:RemoteProject[]):Data {
    return {'state':view.errorMessage===null?'ready':'failed','searchRef':this.search,'kind':view.kind,'query':view.query,
      'loader':view.loader,'gameVersion':view.gameVersion,'sort':view.sortBy,'sourceError':view.errorSource ?? '',
      'errorKind':view.errorKind ?? '','httpStatus':view.httpStatus,'total':view.totalHits,'hasMore':view.hasMore,
      'projects':rows.map((p):Data=>({'project':p.id,'source':p.source,'title':p.title.slice(0,160)}))};
  }
  private describe(info:ResourceDetailSelection):Data {
    if (info.error || !info.ready || info.loading || info.file===null || info.selected===null) return result('needsUser','planUnavailable');
    this.plan=util.generateRandomUUID(); this.chosen=fingerprint(info);
    return {'state':'ready','planRef':this.plan,'project':info.project.id,'source':info.project.source,'version':info.selected.id,
      'target':info.target,'saveOnly':info.saveOnly,'filename':info.file.filename,
      'dependencies':info.deps.map((d):Data=>({'key':d.key,'kind':d.dependencyType,'name':d.displayName,'installed':d.alreadyInstalled,'selected':d.selected}))};
  }
  private submitOwned(port:ResourceBrowseAccess,key:string,local:boolean):Data {
    const files=port.filesDir();
    ResourceOperation.claim(files,key);
    let captured=false;
    const capture=(task:UnifiedDownloadAdapter,completion:Promise<void>):void=>{
      captured=true;
      ResourceOperation.watch(files,key,task,completion);
    };
    if (local) port.submitLocal(capture); else port.submit(capture);
    return {'state':captured?'accepted':'unknown','operationRef':key};
  }
  async run(method:string,args:Data):Promise<Data> {
    const port=this.access();
    if (!port.available()) return result('needsUser','resourcePageUnavailable');
    if (method==='getResourceInstall') return ResourceOperation.read(port.filesDir(),textArg(args,'operationRef'));
    if (method==='searchResources') {
      if (textArg(args,'kind')!==port.kind() || port.detail()) return result('needsUser','resourcePageChanged');
      const query=textArg(args,'query'), loader=textArg(args,'loader'),game=textArg(args,'gameVersion'),sort=textArg(args,'sort');
      if (query.length>180 || !['','fabric','forge','neoforge','quilt'].includes(loader) || !['','downloads','newest','updated','relevance'].includes(sort)) return result('failed','invalidArguments');
      this.search='';this.plan='';this.detail=0;this.projects=[];
      const run=port.search(query,args['loader']===undefined?undefined:loader,args['gameVersion']===undefined?undefined:game,sort?sort as SortBy:undefined);
      const queryKey=resourceSearchKey(port.view().lastRequest),context=port.contextKey();
      await run;
      const view=port.view();
      if (!port.available() || !queryKey || resourceSearchKey(view.lastRequest)!==queryKey || port.contextKey()!==context)
        return result('unknown','searchChanged');
      if (view.loading) return result('unknown','searchPending');
      this.queryKey=queryKey;this.context=context;this.search=util.generateRandomUUID();this.nextOffset=view.nextOffset;
      this.projects=view.hits.slice(0,50);
      return this.snapshot(view,this.projects);
    }
    if (method==='chooseLocalModpack') {
      if (port.kind()!==ResourceKind.MODPACK || port.detail() || port.local()) return result('needsUser','chooseModpackPage');
      const context=port.contextKey();
      LauncherSkillBus.awaitingUser(method);
      const status=await port.importLocal(():boolean=>port.available() && port.contextKey()===context);
      const draft=port.local();
      if (!draft || status!=='selected') return result(status==='cancelled'?'cancelled':'failed','fileNotSelected');
      this.localRef=util.generateRandomUUID();this.archive=draft.archive;this.localRoot=draft.root;this.localName=draft.name;
      return {'state':'ready','selectionRef':this.localRef,'instance':draft.name};
    }
    if (method==='prepareLocalModpack' || method==='installLocalModpack') {
      const draft=port.local();
      if (!draft || !this.localRef || this.localRef!==textArg(args,'selectionRef') || draft.root!==this.localRoot || draft.archive!==this.archive || draft.name!==this.localName) return result('failed','fileSelectionChanged');
      if (method==='prepareLocalModpack') {
        const name=textArg(args,'instance');
        // 无效名称只返回校验结果，页面和当前选择保持原状，调用方可以在同一文件上纠正。
        if (name && validateModpackVersionName(name)) return result('failed','invalidInstance');
        if (name) port.renameLocal(name);
        const now=port.local(); if (!now || !now.valid) return result('failed','invalidInstance');
        this.localName=now.name;this.plan=util.generateRandomUUID();return {'state':'ready','planRef':this.plan,'instance':now.name};
      }
      if (!draft.valid || !this.plan || this.plan!==textArg(args,'planRef')) return result('failed','localPlanChanged');
      const submitted=this.plan; this.plan=''; this.localRef='';
      return this.submitOwned(port,submitted,true);
    }
    if (method==='closeResourceDetails') {
      // 即使搜索或目标已换代，也只允许关闭原引用打开的详情；玩家另开的详情不会被关闭。
      if (!this.search || textArg(args,'searchRef')!==this.search || !this.detail || port.detail()?.session!==this.detail)
        return result('failed','searchChanged');
      port.dismiss();this.plan='';this.detail=0;
      return result('ready');
    }
    if (!this.valid(port,args)) return result('failed','searchChanged');
    if (method==='nextResourcePage') {
      if (port.detail()) return result('needsUser','resourceDetailOpen');
      let view=port.view();
      if (view.loading) return result('unknown','searchPending');
      // 后台刷新可能回到首页，不能在丢失游标时把旧页冒充下一页。
      if (view.nextOffset!==this.nextOffset) return result('unknown','searchPageReset');
      if (!view.hasMore || view.errorMessage!==null) return this.snapshot(view,[]);
      await port.next();
      view=port.view();
      if (!this.valid(port,args)) return result('unknown','searchChanged');
      if (view.loading) return result('unknown','searchPending');
      if (view.lastRequest?.offset!==this.nextOffset) return result('unknown','searchPageReset');
      const seen=this.projects.map(resourceProjectKey);
      const rows=view.hits.filter(p=>!seen.includes(resourceProjectKey(p))).slice(0,50);
      this.projects=this.projects.concat(rows);this.nextOffset=view.nextOffset;
      return this.snapshot(view,rows);
    }
    if (method==='getResourceVersions') {
      const offset=args['offset']===undefined?0:args['offset'] as number;
      if (!Number.isSafeInteger(offset) || offset<0) return result('failed','invalidOffset');
      const project=this.projects.find(p=>p.id===textArg(args,'project') && p.source===textArg(args,'source'));
      if (!project) return result('failed','projectNotInResults');
      if (!port.detail()) {
        const opening=port.open(project);
        this.detail=port.detail()?.session ?? 0;
        await opening;
      }
      const info=port.detail();
      if (!this.valid(port,args) || !info || !this.detail || info.session!==this.detail ||
        info.project.id!==project.id || info.project.source!==project.source) return result('failed','detailChanged');
      // 默认推荐文件若暂不可安装，已加载的完整版本目录仍可供玩家重新选择。
      if (info.loading || (info.error && info.versions.length===0)) return result('needsUser','versionsUnavailable');
      return {'state':'ready','description':info.project.summary,'source':project.source,'project':project.id,'offset':offset,'total':info.versions.length,
        'versions':info.versions.slice(offset,offset+50).map((v):Data=>({'id':v.id,'name':v.versionNumber,'loaders':v.loaders,'games':v.gameVersions,
          'files':v.files.map((f):Data=>({'name':f.filename,'bytes':f.size,'primary':f.isPrimary}))}))};
    }
    const info=port.detail();
    if (!info || !this.detail || info.session!==this.detail) return result('failed','noDetail');
    if (method==='prepareResourceInstall') {
      const v=info.versions.find(item=>item.id===textArg(args,'version') && item.source===textArg(args,'source') && item.projectId===textArg(args,'project'));
      if (!v || info.project.id!==v.projectId || info.project.source!==v.source) return result('failed','versionNotInProduct');
      const target=textArg(args,'instance'); if (target && info.project.kind===ResourceKind.MODPACK) port.rename(target);
      this.plan=''; await port.pick(v);
      const current=port.detail();
      return this.valid(port,args) && current && current.selected?.id===v.id && current.session===info.session?this.describe(current):result('failed','detailChanged');
    }
    if (!this.plan || this.plan!==textArg(args,'planRef') || fingerprint(info)!==this.chosen) return result('failed','planChanged');
    if (method==='selectResourceDependency') {
      const d=info.deps.find(row=>row.key===textArg(args,'key'));
      if (!d || d.alreadyInstalled || d.dependencyType!=='optional' || typeof args['selected']!=='boolean') return result('failed','dependencyUnavailable');
      this.plan='';
      if (d.selected!==args['selected']) await port.toggle(d.key);
      const current=port.detail();return current && current.session===info.session && this.valid(port,args)?this.describe(current):result('failed','detailChanged');
    }
    if (method==='installResourcePlan') {
      const submitted=this.plan; this.plan='';
      if (info.saveOnly) {
        if (!port.saveSelectedFile) return result('failed','saveUnavailable');
        const files=port.filesDir();ResourceOperation.claim(files,submitted);
        LauncherSkillBus.awaitingUser(method);
        const id=await port.saveSelectedFile();
        if (!id) return result('cancelled');
        if (id==='#failed') return result('failed','saveFailed');
        const adapter=getDownloadTaskRegistry().getAdapter(id);
        if (adapter) ResourceOperation.watch(files,submitted,adapter,Promise.resolve());
        return {'state':adapter?'accepted':'unknown','operationRef':submitted,'taskId':id,'destination':'userSelectedFile'};
      }
      const additions=info.deps.filter(d=>d.selected && !d.alreadyInstalled).map(d=>d.displayName);
      if (additions.length) {
        if (!port.confirmDependencies) return result('failed','confirmationUnavailable');
        LauncherSkillBus.awaitingUser(method);
        if (!await port.confirmDependencies(info.project.title,additions,info.target)) return result('cancelled');
        const current=port.detail();
        if (!current || !this.valid(port,args) || !port.available() || this.chosen!==fingerprint(current)) return result('failed','planChanged');
      }
      return this.submitOwned(port,submitted,false);
    }
    return result('failed','unsupportedOperation');
  }
}
