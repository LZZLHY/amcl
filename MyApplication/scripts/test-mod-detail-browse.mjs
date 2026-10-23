/**
 * 模组详情浏览回归：执行真实页面/Sheet纯方法，证明完整版本目录与安装准入分别工作。
 * 仅替换网络、本地扫描、依赖服务和任务提交端口；选版、兼容判断、声明投影、分组、
 * 异步代次和确认入口均读取当前生产源码。夹具为控制流构造，不代表真实发布者内容。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import {loader,root,ts,productionPathPolicy} from './mod-install-test-runtime.mjs';

const load=loader({'./ModSourceRouter':{}});
const types=load('mods/src/main/ets/ModTypes.ets');
const resolver=load('mods/src/main/ets/ModDependencyResolver.ets');
const mc=load('commons/src/main/ets/utils/McVersionUtils.ets');
const pageSource=fs.readFileSync(path.join(root,'entry/src/main/ets/pages/ModBrowsePage.ets'),'utf8');
const sheetSource=fs.readFileSync(path.join(root,'entry/src/main/ets/components/ModDetailSheet.ets'),'utf8');

/** 从真实类成员边界提取纯方法，保留方法内部调用链，不复制页面的业务决策。 */
function method(source,name){
  const match=new RegExp('^  private (?:async )?'+name+'\\(','m').exec(source);
  assert.ok(match,'生产方法不存在：'+name);
  const parsed=ts.createSourceFile('detail.ts','class Subject {\n'+source.slice(match.index),ts.ScriptTarget.Latest,true,ts.ScriptKind.TS);
  const member=parsed.statements.find(ts.isClassDeclaration).members[0];
  assert.equal(member.name.getText(parsed),name);
  return member.getText(parsed);
}

/** 名称校验是openDetail的既有同步依赖，同样取生产函数和真实路径策略。 */
const installerSource=ts.createSourceFile('installer.ts',fs.readFileSync(path.join(root,'mods/src/main/ets/ModpackInstaller.ets'),'utf8'),ts.ScriptTarget.Latest,true,ts.ScriptKind.TS);
const naming=installerSource.statements.filter(node=>ts.isFunctionDeclaration(node)
  && ['sanitizeVersionName','validateModpackVersionName'].includes(node.name?.text)).map(node=>node.getText(installerSource)).join('\n');
const pageMethods=['openDetail','prefetchDetail','pickDetailVersion','buildDeclaredDepRows','buildDepRows',
  'onPickVersion','invalidateLocalScanCache','getOrScanInstalled','detailInstallIssue','loadChosenDetail',
  'toggleDetailDep','selectAllDetailDeps','closeDetail','switchDetailSource','confirmInstallFromSheet'];
const sheetMethods=['mcGroups','selectedGroupVersions','versionSupportsMc','canInstall','depRenderKey'];
const code=naming+'\nclass Page {\n'+pageMethods.map(name=>method(pageSource,name)).join('\n')
  +'\n}\nclass Sheet {\n'+sheetMethods.map(name=>method(sheetSource,name)).join('\n')+'\n}\nexports.Page=Page;exports.Sheet=Sheet;';
const transpiled=ts.transpileModule(code,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021},reportDiagnostics:true});
assert.equal((transpiled.diagnostics??[]).filter(item=>item.category===ts.DiagnosticCategory.Error).length,0);
const exported={};
const environments=new Map([['/mc::target',{loader:'fabric',game:'1.21.11'}],['/other::other',{loader:'fabric',game:'1.21.11'}]]);
const environment=(dir,id)=>environments.get(dir+'::'+id)??{loader:'',game:''};
vm.runInNewContext(transpiled.outputText,{exports:exported,...types,...resolver,...mc,...productionPathPolicy(),
  resolveInstalledLoader:(dir,id)=>environment(dir,id).loader,resolveInstalledMcVersion:(dir,id)=>environment(dir,id).game,
  GameStorage:{sandboxMcDir:()=>'/mc',externalMcDir:()=>'/other'},
  makeResolverFromRouter:router=>({resolve:(...args)=>router.resolve(...args)}),
  AppLogger:{warn(){}},TAG:'ModBrowsePage',LOG_DOMAIN_DOWNLOAD:1,
  InstalledModIndex:{baseNameOf:name=>name.replace(/\.disabled$/,'')},
});

/** 显式释放异步边界，避免靠真实时钟/延时碰巧形成选版竞态。 */
function deferred(){let resolve,reject;const promise=new Promise((ok,no)=>{resolve=ok;reject=no;});return {promise,resolve,reject};}
const primary=id=>({url:'https://example.invalid/'+id+'.jar',mirrors:[],filename:id+'.jar',size:23,isPrimary:true});
const version=(id,options={})=>({id,projectId:'project',source:'modrinth',name:id,versionNumber:'1.0',versionType:'release',
  datePublished:'2026-01-01T00:00:00Z',gameVersions:['1.21.11'],loaders:['fabric'],files:[primary(id)],dependencies:[],...options});
const project=(options={})=>({id:'project',source:'modrinth',kind:'mod',title:'测试项目',iconUrl:'',...options});
const plan=(dependencies=[])=>({dependencies,conflicts:[],depthExceeded:false,hasCompatWarning:false});
const ids=items=>Array.from(items,item=>item.id);

/** 每案独占端口与状态；wrapper只保留生产Promise供等待，不替换生产错误/代次逻辑。 */
function subject({versions=[],valid=true,kind='mod',scan=async()=>[],resolve=async()=>plan(),downloadInfo=async()=>({urls:[]})}={}){
  const calls={versions:[],scan:0,resolve:[],download:[],submitted:[],messages:[]};
  const repo={getVersions:async(...args)=>{calls.versions.push(args);return versions;},
    resolveFileDownloadInfo:async(...args)=>{calls.download.push(args);return downloadInfo(...args);}};
  const router={repoFor:()=>repo,resolve:async(...args)=>{calls.resolve.push(args);return resolve(...args);}};
  const page=Object.assign(new exported.Page(),{router_:router,detailProject_:project({kind}),detailFetchEpoch_:1,
    targetMcDir_:valid?'/mc':'',targetVersionId_:valid?'target':'',versionIsolation:true,targetValid_:valid,
    detailLoading_:false,detailError_:'',detailPreparingInstall_:false,detailInstallReady_:false,detailInstallError_:'',
    detailDependenciesResolved_:false,detailPreparedMcDir_:'',detailPreparedVersionId_:'',detailOptionalIds_:[],
    detailSelectedVersion_:null,detailPrimaryFile_:null,detailAllVersions_:[],detailDeps_:[],detailResolvedDeps_:[],
    detailInstalledVersionIds_:[],detailInstalledPrimary_:null,detailScanInfo_:'',showDetailSheet_:true,
    detailModpackName_:'测试项目',detailModpackNameError_:'',localScanCache_:new Map(),localScanCacheEpoch_:0,downloadingProjectIds_:new Set(),
    hasValidCurrentVersion(){return this.targetValid_;},toast(message){calls.messages.push(message);},
    async getOrScanInstalled(){calls.scan++;return scan();},
    async executeInstall(...args){calls.submitted.push(args);},installModpackFromSheet(...args){calls.submitted.push(args);},
  });
  page.prefetchDetail=(...args)=>(page.prefetchJob=exported.Page.prototype.prefetchDetail.apply(page,args));
  page.pickDetailVersion=(...args)=>(page.pickJob=exported.Page.prototype.pickDetailVersion.apply(page,args));
  return {page,calls,repo};
}

/** 开页本身为同步入口；等待其真实异步请求以及生产catch状态落定。 */
async function open(page,p=page.detailProject_){page.openDetail(p);await page.prefetchJob.catch(()=>{});await Promise.resolve();}
function assertBrowse(page,v){assert.equal(page.detailSelectedVersion_.id,v.id);assert.equal(page.detailPrimaryFile_?.filename,v.files[0]?.filename);assert.equal(page.detailLoading_,false);}
function assertBlocked(page,calls){const before=calls.submitted.length;page.confirmInstallFromSheet();assert.equal(calls.submitted.length,before,'无有效安装计划时不能提交');}
let count=0;
async function check(name,run){await run();count++;console.log('PASS: '+name);}

/**
 * 缓存专项必须恢复真实 getOrScanInstalled，再只在 scanner IO 端控制完成顺序。
 * Picker 的存储根、搜索刷新属于外部端口；目标切换、失效代次、缓存读取/写回仍执行生产代码。
 */
function useRealScan(page,scan){
  delete page.getOrScanInstalled;
  page.scanner_={scan};
  page.uiCtx=()=>({});
  page.applyFiltersToController=()=>{};
  page.triggerSearch=()=>{};
}

await check('完整目录保留跨MC/loader文件，实际Sheet生成多个游戏版本组',async()=>{
  const current=version('current'),old=version('old',{loaders:['forge'],gameVersions:['1.20.4']}),
    modern=version('modern',{loaders:['neoforge'],gameVersions:['26.2'],versionNumber:'3.0'}),
    shared=version('shared',{gameVersions:['1.21.11','1.21.1'],versionNumber:'2.0'}),server=version('server',{isServerPack:true,versionNumber:'99.0'});
  const {page,calls}=subject({versions:[modern,old,current,shared,server]});await open(page);
  assert.deepEqual(calls.versions,[['project',undefined,undefined]]);
  assert.deepEqual(ids(page.detailAllVersions_),['modern','old','current','shared']);
  assert.equal(page.detailSelectedVersion_.id,'shared','推荐优先当前目标兼容文件');
  const sheet=Object.assign(new exported.Sheet(),{allVersions:page.detailAllVersions_,selectedMcGroup:'1.20.4'});
  const groups=sheet.mcGroups();assert.deepEqual(Array.from(groups,g=>g.mc),['26.2','1.21.11','1.21.1','1.20.4']);
  assert.equal(groups.find(g=>g.mc==='1.21.1').versions[0].id,'shared');assert.deepEqual(ids(sheet.selectedGroupVersions()),['old']);
  sheet.selectedMcGroup='1.21.11';assert.deepEqual(ids(sheet.selectedGroupVersions()),['shared','current']);
});

await check('没有目标匹配推荐时仍回退展示完整目录和声明前置',async()=>{
  const other=version('other',{loaders:['forge'],gameVersions:['1.20.4'],dependencies:[{dependencyType:'required',versionId:'exact-only'}]});
  const {page,calls}=subject({versions:[other]});await open(page);assertBrowse(page,other);
  assert.deepEqual(ids(page.detailAllVersions_),['other']);assert.equal(page.detailDeps_[0].displayName,'exact-only');
  assert.match(page.detailInstallError_,/不匹配/);assert.equal(page.detailError_,'');assert.equal(calls.scan,0);assert.equal(calls.resolve.length,0);assertBlocked(page,calls);
});

await check('声明浏览保留全部依赖类型，按业务身份去重且重排不改变key',async()=>{
  const declared=[{projectId:'same',dependencyType:'required'},{projectId:'same',dependencyType:'optional'},
    {versionId:'conflict-pin',dependencyType:'incompatible'},{fileName:'embedded.jar',dependencyType:'embedded'},
    {projectId:'same',dependencyType:'required'}];
  const v=version('declarations',{loaders:['forge'],dependencies:declared});
  const {page,calls}=subject();await page.pickDetailVersion(v);
  assert.deepEqual(Array.from(page.detailDeps_,d=>d.dependencyType),['required','optional','incompatible','embedded']);
  assert.equal(page.detailDependenciesResolved_,false);assert.equal(calls.resolve.length,0);assertBlocked(page,calls);
  const keys=Array.from(page.detailDeps_,d=>d.key).sort();assert.equal(new Set(keys).size,4);
  const reordered=page.buildDeclaredDepRows({...v,dependencies:[...declared].reverse()});
  assert.deepEqual(Array.from(reordered,d=>d.key).sort(),keys,'数组顺序不是声明业务身份');
  assert.ok(page.detailDeps_.every(d=>!d.selected&&!d.alreadyInstalled),'浏览声明不能伪造安装选择或已装结论');
});

await check('无已装实例的整合包仍独立准备并通过自己的名称和文件门控',async()=>{
  const v=version('pack',{loaders:[],gameVersions:['26.2']});
  const {page,calls}=subject({valid:false,kind:'modpack',versions:[v]});await open(page);
  assertBrowse(page,v);assert.equal(page.detailInstallReady_,true);assert.equal(calls.scan,0);assert.equal(calls.resolve.length,0);
  page.detailModpackName_='';page.detailModpackNameError_='';assertBlocked(page,calls);
  assert.ok(page.detailModpackNameError_.length>0,'整合包名称校验不得被浏览修复绕过');
  page.detailModpackName_='测试整合包';page.detailModpackNameError_='';page.confirmInstallFromSheet();
  assert.equal(calls.submitted.length,1,'整合包创建新实例，不要求已有实例');
});

await check('无安装目标可开详情和浏览，不读无效目录或解析安装依赖',async()=>{
  const v=version('no-target');const {page,calls}=subject({valid:false,versions:[v]});await open(page);
  assert.equal(page.showDetailSheet_,true);assertBrowse(page,v);assert.equal(calls.versions.length,1);
  assert.equal(calls.scan,0);assert.equal(calls.resolve.length,0);assert.match(page.detailInstallError_,/选择已安装/);assertBlocked(page,calls);
});

await check('手选不匹配文件可读，换回兼容文件后重新取得安装资格',async()=>{
  const wrong=version('wrong',{loaders:['forge'],gameVersions:['1.20.4']}),right=version('right');
  const {page,calls}=subject();await page.pickDetailVersion(wrong);assertBrowse(page,wrong);assert.equal(calls.scan,0);assertBlocked(page,calls);
  await page.pickDetailVersion(right);assertBrowse(page,right);assert.equal(page.detailInstallReady_,true);assert.equal(page.detailDependenciesResolved_,true);
  assert.equal(calls.resolve[0][1].loader,'fabric');assert.equal(calls.resolve[0][1].gameVersion,'1.21.11');
  page.confirmInstallFromSheet();assert.equal(calls.submitted.length,1,'生产确认入口允许完整兼容计划提交');
});

await check('选中文件立即可读，扫描与依赖准备期间安装仍阻断',async()=>{
  const scan=deferred(),dependency=deferred(),entered=deferred(),v=version('pending');
  const {page,calls}=subject({scan:()=>scan.promise,resolve:()=>{entered.resolve();return dependency.promise;}});
  const pending=page.pickDetailVersion(v);assertBrowse(page,v);assert.equal(page.detailPreparingInstall_,true);assertBlocked(page,calls);
  scan.resolve([]);await entered.promise;assert.equal(page.detailInstallReady_,false);assertBlocked(page,calls);
  dependency.resolve(plan());await pending;assert.equal(page.detailPreparingInstall_,false);assert.equal(page.detailInstallReady_,true);
});

for(const [name,downloadInfo] of [['异常',async()=>{throw Error('CF地址fixture失败');}],['空URL',async()=>({urls:[],filename:'cf.jar',size:23})]]){
  await check('CF补地址'+name+'只阻断安装，保留原文件与后续换选能力',async()=>{
    const cf=version('cf',{source:'curseforge',files:[{...primary('cf'),url:''}]}),good=version('good');
    const {page,calls}=subject({downloadInfo});page.detailProject_=project({source:'curseforge'});
    await page.pickDetailVersion(cf);assertBrowse(page,cf);assert.equal(page.detailPreparingInstall_,false);assert.equal(page.detailInstallReady_,false);
    assert.ok(page.detailInstallError_.length>0);assert.equal(page.detailError_,'');assertBlocked(page,calls);
    await page.pickDetailVersion(good);assert.equal(page.detailInstallReady_,true);assert.equal(page.detailInstallError_,'');
  });
}

await check('旧CF补地址成功不能覆盖新选版',async()=>{
  const address=deferred(),cf=version('cf-old',{source:'curseforge',files:[{...primary('cf-old'),url:''}]}),next=version('next');
  const {page}=subject({downloadInfo:()=>address.promise});const stale=page.pickDetailVersion(cf);await page.pickDetailVersion(next);
  address.resolve({urls:['https://example.invalid/stale.jar'],filename:'stale.jar',size:99});await stale;
  assertBrowse(page,next);assert.equal(page.detailPrimaryFile_.url,next.files[0].url);assert.equal(page.detailInstallReady_,true);
});

for(const failure of [false,true]){
  await check('旧依赖准备'+(failure?'失败':'成功')+'不能改写正在准备的新选版',async()=>{
    const a=deferred(),b=deferred(),enteredA=deferred(),enteredB=deferred(),first=version('first'),second=version('second');
    const {page}=subject({resolve:v=>{if(v.id==='first'){enteredA.resolve();return a.promise;}enteredB.resolve();return b.promise;}});
    // 必须证明两个生产resolve都已进入；仅等待一个微任务会让旧请求在扫描后即退休，
    // 既覆盖不到真正的依赖竞态，也会把无消费者的fixture reject变成unhandled rejection。
    const old=page.pickDetailVersion(first);await enteredA.promise;const fresh=page.pickDetailVersion(second);await enteredB.promise;
    if(failure)a.reject(Error('旧代次异常'));else a.resolve(plan());await old;
    assertBrowse(page,second);assert.equal(page.detailPreparingInstall_,true);assert.equal(page.detailInstallError_,'');assert.equal(page.detailInstallReady_,false);
    b.resolve(plan());await fresh;assert.equal(page.detailInstallReady_,true);assert.equal(page.detailPreparingInstall_,false);
  });
}

await check('旧目录网络失败不覆盖新项目详情',async()=>{
  const listing=deferred(),oldProject=project({id:'old-project'}),next=version('new-project-version');
  const {page,repo}=subject({versions:[next]});let first=true;
  repo.getVersions=async()=>{if(first){first=false;return listing.promise;}return [next];};
  page.openDetail(oldProject);const old=page.prefetchJob;await open(page,project());listing.reject(Error('旧目录失败'));await old.catch(()=>{});await Promise.resolve();
  assertBrowse(page,next);assert.equal(page.detailError_,'');assert.equal(page.detailInstallReady_,true);
});

await check('空客户端目录为可读空态，服务端包不能成为回退推荐',async()=>{
  for(const versions of [[],[version('server',{isServerPack:true})]]){
    const {page,calls}=subject({versions});await open(page);assert.deepEqual(ids(page.detailAllVersions_),[]);
    assert.equal(page.detailSelectedVersion_,null);assert.equal(page.detailLoading_,false);assert.equal(page.detailError_,'');assert.equal(calls.scan,0);assertBlocked(page,calls);
  }
});

await check('目录请求和安装准备均在关闭后失效，旧错误不能重新填充状态',async()=>{
  const listing=deferred(),{page,repo}=subject();repo.getVersions=()=>listing.promise;page.openDetail(project());const fetch=page.prefetchJob;
  page.closeDetail();listing.resolve([version('late-directory')]);await fetch;
  assert.equal(page.showDetailSheet_,false);assert.equal(page.detailSelectedVersion_,null);assert.equal(page.detailAllVersions_.length,0);
  const scan=deferred(),second=subject({scan:()=>scan.promise}),pending=second.page.pickDetailVersion(version('closing'));
  second.page.closeDetail();scan.reject(Error('关闭后的扫描失败'));await pending;
  assert.equal(second.page.detailSelectedVersion_,null);assert.equal(second.page.detailInstallError_,'');assert.equal(second.page.detailPreparingInstall_,false);
});

await check('异步期间换目标撤销旧计划，准备完成后换目标也无法提交',async()=>{
  const dependency=deferred(),entered=deferred(),v=version('target-change');
  const {page,calls}=subject({resolve:()=>{entered.resolve();return dependency.promise;}});const pending=page.pickDetailVersion(v);await entered.promise;
  page.targetMcDir_='/other';page.targetVersionId_='other';dependency.resolve(plan());await pending;
  assertBrowse(page,v);assert.equal(page.detailInstallReady_,false);assert.match(page.detailInstallError_,/目标已变化/);assertBlocked(page,calls);
  await page.pickDetailVersion(v);assert.equal(page.detailInstallReady_,true);page.targetMcDir_='/mc';page.targetVersionId_='target';
  assertBlocked(page,calls);assert.match(calls.messages.at(-1),/目标已变化/);
});

await check('即使旧ready与错误提示被篡改，确认仍拒绝错误MC/loader和无效目标',async()=>{
  const {page,calls}=subject();await page.pickDetailVersion(version('valid'));
  page.detailSelectedVersion_=version('wrong',{loaders:['forge'],gameVersions:['1.20.4']});
  page.detailInstallError_='';page.detailInstallReady_=true;assertBlocked(page,calls);assert.match(calls.messages.at(-1),/不匹配/);
  page.detailSelectedVersion_=version('valid');page.targetValid_=false;assertBlocked(page,calls);assert.match(calls.messages.at(-1),/选择已安装/);
});

await check('无法识别loader/MC不得借兼容函数空字符串通配授予安装资格',async()=>{
  for(const env of [{loader:'',game:'1.21.11'},{loader:'fabric',game:''}]){
    environments.set('/unknown::unknown',env);const {page,calls}=subject();page.targetMcDir_='/unknown';page.targetVersionId_='unknown';
    await page.pickDetailVersion(version('unknown'));assert.equal(calls.scan,0);assert.equal(calls.resolve.length,0);assert.equal(page.detailInstallReady_,false);assertBlocked(page,calls);
  }
});

await check('可选前置失败保留可撤选行，撤选后生产解析错误清除并恢复安装',async()=>{
  const optional={dependencyType:'optional',projectId:'optional'},rootVersion=version('optional-root',{dependencies:[optional]});
  const {page,calls}=subject({resolve:async(_v,opt)=>plan([{dependencyType:'optional',parentProjectId:'project',projectId:'optional',
    project:{title:'可选前置'},version:null,alreadyInstalled:false,selected:opt.selectedOptionalIds.includes('optional'),
    errorMessage:opt.selectedOptionalIds.includes('optional')?'前置查询fixture失败':null,compatWarning:null}])});
  await page.pickDetailVersion(rootVersion);assert.equal(page.detailInstallReady_,true);
  page.toggleDetailDep('optional');await page.pickJob;assert.equal(page.detailDependenciesResolved_,true);assert.equal(page.detailInstallReady_,false);
  assert.match(page.detailInstallError_,/前置查询/);assertBlocked(page,calls);
  page.toggleDetailDep('optional');await page.pickJob;assert.equal(page.detailInstallReady_,true);assert.equal(page.detailInstallError_,'');
  assert.deepEqual(Array.from(page.detailOptionalIds_),[]);assert.equal(calls.resolve.length,3);
});

await check('切换发布文件清空可选选择，同文件重解保留选择',async()=>{
  const {page,calls}=subject(),first=version('first'),second=version('second');await page.pickDetailVersion(first);
  page.detailOptionalIds_=['selected'];await page.pickDetailVersion(first);assert.deepEqual(Array.from(calls.resolve.at(-1)[1].selectedOptionalIds),['selected']);
  await page.pickDetailVersion(second);assert.deepEqual(Array.from(calls.resolve.at(-1)[1].selectedOptionalIds),[]);
  page.detailOptionalIds_=['another'];await page.pickDetailVersion({...second,source:'curseforge'});
  assert.deepEqual(Array.from(calls.resolve.at(-1)[1].selectedOptionalIds),[],'跨源同ID也不是同一发布文件');
});

await check('切源请求关闭后不能重开详情，反序响应只采纳先完成的新代次',async()=>{
  const counterpart=project({id:'counterpart',source:'curseforge'}),original=project({altSource:'curseforge'});
  const closed=subject(),pendingClose=deferred();closed.page.detailProject_=original;closed.page.resolveCounterpart=()=>pendingClose.promise;
  const switching=closed.page.switchDetailSource('curseforge');closed.page.closeDetail();pendingClose.resolve(counterpart);await switching;
  assert.equal(closed.page.showDetailSheet_,false);assert.equal(closed.calls.versions.length,0);
  const first=deferred(),second=deferred(),fresh=subject();fresh.page.detailProject_=original;let index=0;
  fresh.page.resolveCounterpart=()=>index++===0?first.promise:second.promise;
  const old=fresh.page.switchDetailSource('curseforge'),newer=fresh.page.switchDetailSource('curseforge');
  second.resolve({...counterpart,id:'new-source'});await newer;await fresh.page.prefetchJob;
  first.resolve({...counterpart,id:'stale-source'});await old;
  assert.equal(fresh.page.detailProject_.id,'new-source');assert.equal(fresh.calls.versions.length,1,'旧切源响应不得重新拉取目录');
});

await check('切源期间换文件或页面卸载使旧切源响应失效',async()=>{
  for(const retired of ['selection','unmount']){
    const {page,calls}=subject(),pending=deferred();page.detailProject_=project({altSource:'curseforge'});page.resolveCounterpart=()=>pending.promise;
    const switching=page.switchDetailSource('curseforge');
    if(retired==='selection')await page.pickDetailVersion(version('new-selection'));else page.router_=null;
    pending.resolve(project({id:'stale-source',source:'curseforge'}));await switching;
    assert.equal(page.detailProject_.id,'project');assert.equal(calls.versions.length,0);
    if(retired==='selection')assert.equal(page.detailSelectedVersion_.id,'new-selection');
  }
});

await check('声明依赖跨文件有独立key，依赖版本/警告变化更新真实渲染key',async()=>{
  const {page}=subject(),a=version('a',{dependencies:[{projectId:'dep',versionId:'v1',dependencyType:'required'}]}),
    b=version('b',{dependencies:[{projectId:'dep',versionId:'v2',dependencyType:'required'}]});
  const first=page.buildDeclaredDepRows(a)[0],second=page.buildDeclaredDepRows(b)[0];assert.notEqual(first.key,second.key);
  const sheet=new exported.Sheet(),key=sheet.depRenderKey(first);
  assert.notEqual(key,sheet.depRenderKey({...first,versionNumber:'v2'}));
  assert.notEqual(key,sheet.depRenderKey({...first,compatWarning:'另一个阻塞原因'}));
  assert.equal(key,sheet.depRenderKey({...first}),'内容相同的行保留稳定身份');
});

await check('非MOD资源无目标同样可浏览，有目标不执行模组扫描与依赖解析',async()=>{
  for(const kind of ['resourcepack','shader']){
    const v=version(kind),{page,calls}=subject({kind,valid:false,versions:[v]});await open(page);assertBrowse(page,v);assertBlocked(page,calls);
    page.targetValid_=true;page.targetMcDir_='/mc';page.targetVersionId_='target';await page.pickDetailVersion(v);
    assert.equal(page.detailInstallReady_,true);assert.equal(calls.scan,0);assert.equal(calls.resolve.length,0);
  }
});

await check('Sheet按钮必须同时得到ready、有效文件和无错误/准备态',async()=>{
  const v=version('button'),sheet=Object.assign(new exported.Sheet(),{project:project(),selectedVersion:v,primaryFile:v.files[0],
    loading:false,preparingInstall:false,installReady:true,blockingError:'',installBlockReason:'',modpackNameError:''});
  assert.equal(sheet.canInstall(),true);
  for(const patch of [{loading:true},{preparingInstall:true},{installReady:false},{blockingError:'目录失败'},
    {installBlockReason:'目标不符'},{selectedVersion:{...v,isServerPack:true}},{primaryFile:{...v.files[0],url:''}}]){
    const old={};for(const key of Object.keys(patch))old[key]=sheet[key];Object.assign(sheet,patch);assert.equal(sheet.canInstall(),false);Object.assign(sheet,old);
  }
});

await check('真实扫描缓存同代次复用，切实例先失效再准备且旧扫描不能回填',async()=>{
  const oldB=deferred(),freshA=deferred(),{page,calls}=subject(),scans=[];
  const removed={filename:'removed.jar',filePath:'/other/removed.jar',remoteProjectId:'project',
    remoteVersionId:'removed',remoteSource:'modrinth',enabled:true};
  useRealScan(page,opt=>{
    scans.push({...opt});
    if(scans.length===1)return oldB.promise;
    if(scans.length===2)return freshA.promise;
    return Promise.resolve({mods:[]});
  });
  page.targetMcDir_='/other';page.targetVersionId_='other';
  const initialEpoch=page.localScanCacheEpoch_,old=page.pickDetailVersion(version('root'));
  assert.equal(scans.length,1,'必须先进入真实B扫描，再开始目标切换');
  page.onPickVersion('sandbox','target');const targetA=page.pickJob;
  assert.equal(page.localScanCacheEpoch_,initialEpoch+1);assert.equal(scans.length,2);
  // B 的扫描先抓到随后被移除的文件，迟到完成时不得把该快照塞回新代次缓存。
  oldB.resolve({mods:[removed]});await old;
  assert.equal(page.localScanCache_.has('/other::other::1'),false,'切实例后旧B扫描不能回填缓存');
  freshA.resolve({mods:[]});await targetA;
  assert.equal(page.detailPreparedMcDir_,'/mc');assert.equal(page.detailInstallReady_,true);
  const cachedA=await page.getOrScanInstalled();assert.equal(cachedA.length,0);assert.equal(scans.length,2,'同代次同目标应复用新扫描');
  // 额外放入一份当前缓存，证明 onPickVersion 在同步触发新准备前就已清除旧项。
  page.localScanCache_.set('/other::other::1',[removed]);
  page.onPickVersion('external','other');await page.pickJob;
  assert.deepEqual(scans.map(item=>item.mcDir+'::'+item.versionId),['/other::other','/mc::target','/other::other']);
  assert.equal(page.detailPreparedMcDir_,'/other');assert.equal(page.detailInstalledPrimary_,null);
  assert.deepEqual(Array.from(page.detailInstalledVersionIds_),[],'已移除文件不可再次被识别为已装');
  assert.equal(calls.versions.length,0,'改选实例只重算安装计划，不重新筛选远端目录');
});

await check('关闭重开退休在途真实扫描，旧结果不回填也不覆盖新目录或安装状态',async()=>{
  const oldScan=deferred(),newScan=deferred(),enteredOld=deferred(),enteredNew=deferred(),
    v=version('reopened'),{page}=subject({versions:[v]}),scans=[];
  const removed={filename:'old.jar',filePath:'/mc/old.jar',remoteProjectId:'project',
    remoteVersionId:'old',remoteSource:'modrinth',enabled:true};
  useRealScan(page,opt=>{
    scans.push({...opt});
    if(scans.length===1){enteredOld.resolve();return oldScan.promise;}
    enteredNew.resolve();return newScan.promise;
  });
  // 等待真实扫描端口已进入，不能用固定微任务次数猜测目录 Promise 的调度深度。
  page.openDetail(project());const old=page.prefetchJob;await enteredOld.promise;
  assert.equal(scans.length,1);const firstEpoch=page.localScanCacheEpoch_;
  page.closeDetail();assert.equal(page.localScanCacheEpoch_,firstEpoch+1);
  page.openDetail(project());const fresh=page.prefetchJob;await enteredNew.promise;
  assert.equal(scans.length,2,'重开详情必须开始新的真实扫描');
  assert.equal(page.localScanCacheEpoch_,firstEpoch+2,'重开也必须退休先前的扫描代次');
  oldScan.resolve({mods:[removed]});await old;
  assert.equal(page.localScanCache_.size,0,'关闭并重开后旧扫描结果仍不能回填');
  assertBrowse(page,v);assert.equal(page.detailPreparingInstall_,true);assert.equal(page.detailInstallReady_,false);
  newScan.resolve({mods:[]});await fresh;
  assert.equal(page.detailInstallReady_,true);assert.equal(page.detailPreparingInstall_,false);
  assert.equal(page.detailInstalledPrimary_,null);assert.deepEqual(Array.from(page.detailInstalledVersionIds_),[]);
  await page.getOrScanInstalled();assert.equal(scans.length,2,'当前代次新扫描完成后仍可正常命中缓存');
});

console.log('Mod detail browse regression passed: '+count+' independent scenarios');
