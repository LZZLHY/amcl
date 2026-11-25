/** 执行当前页面的真实具名处理函数，磁盘/弹窗、既有业务 owner 用显式替身观察委托及结果。 */
import assert from 'node:assert/strict';
import {verifySkillCases} from '../../scripts/lib/skill-business-check.mjs';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import compiler from '../../scripts/lib/ets-compiler.mjs';
import { makePureEtsLoader } from '../../scripts/lib/load-pure-ets.mjs';

function receiver(file, component, names, globals, state) {
  const raw=readFileSync(new URL('../../entry/src/main/ets/'+file,import.meta.url),'utf8');
  const ast=compiler.createSourceFile(file,raw,compiler.ScriptTarget.Latest,true);
  const owner=ast.statements.find(n=>n.name?.getText(ast)===component && n.members);
  const members=names.map(name=>{const m=owner.members.find(v=>v.name?.getText(ast)===name);assert.ok(m,name);return m.getText(ast);});
  const compiled=compiler.transpileModule('class Subject {\n'+members.join('\n')+'\n}\nmodule.exports=Subject;', {
    compilerOptions:{target:compiler.ScriptTarget.ES2020,module:compiler.ModuleKind.CommonJS},reportDiagnostics:true });
  assert.equal(compiled.diagnostics?.length??0,0);
  const mod={exports:{}};new Function('module',...Object.keys(globals),compiled.outputText)(mod,...Object.values(globals));
  return Object.assign(new mod.exports(), state);
}
const {textArg,result}=makePureEtsLoader()('entry/src/main/ets/launcherskill/LibraryResult.ets');
let choice=1, deleted=0, imported=0, exported=0, accepted=0;
const dialog=()=>({getPromptAction:()=>({showDialog:async()=>({index:choice})})});
const theme={textSecondary:'#000',errorText:'#333',actionText:'#444'};
const globals={textArg,result,ArchiveEntryConfirmation:{capture:()=>({close(){}})},LauncherSkillBus:{awaitingUser(){}},fs:{accessSync:()=>false},resolveInstanceGameDir:(root,v,isolated)=>isolated?root+'/versions/'+v:root};
const scope={list:()=> 'folder',row:name=>'row:'+name,belongs:(_,__,___,token)=>token==='folder',resolve:(_,__,___,folder,ref)=>folder==='folder' && ref==='row:a'?'a':''};
for (const [file,kind] of [['SavesManagerSheet','worlds'],['VersionFileBrowser','files']]) {
  const filePanel=kind==='files';
  const state={active:true,navigationProjectionAlive_:true,versionId:'one',versionIsolation:false,mcDir:'/mc',skillScope_:scope,theme,
    navigationBlocked_:()=>false,refresh(){},savesDir:()=>'/mc/saves',curDir:()=>'/mc',crumbSegments:()=>[],skillScanError_:false,
    rows:[{name:'a',valid:true,isDir:true,mtimeMs:3,size:4}],getUIContext:dialog,removeConfirmed_(){deleted++;return true;},
    doImport:async()=>(imported++,{state:'partial',imported:['new'],failedCount:1}),doExport:async()=>(exported++,{state:'ready',exported:'a'}),
    enterDir(name){this.rel=name;},goUp(){this.rel='';},sanitizeName:n=>n.replaceAll('/','_'),pathExists:()=>false,openNewFolder(){},executeNewFolder(){this.showNewFolder=false;}};
  const page=receiver('components/'+file+'.ets',file,['fileSkill_'],globals,state);
  const run=(name,extra={})=>page.fileSkill_(name,{instance:'one',folder:'folder',ref:'row:a',...extra});
  assert.equal((await run(filePanel?'listInstanceFiles':'listWorlds')).shared,true);
  assert.equal((await run(filePanel?'importInstanceFiles':'importWorlds')).state,'partial');
  assert.equal((await run(filePanel?'exportInstanceFile':'exportWorld')).state,'ready');
  const remove=filePanel?'requestInstanceFileDeletion':'requestWorldDeletion';
  const before=deleted;choice=0;assert.equal((await run(remove)).state,'cancelled');assert.equal(deleted,before);
  choice=1;assert.equal((await run(remove)).removed,'a');assert.equal(deleted,before+1);
  assert.equal((await run(remove,{ref:'unrelated'})).state,'failed');
  if(filePanel){assert.equal((await run('enterInstanceFolder')).state,'ready');assert.equal(page.rel,'a');
    assert.equal((await run('createInstanceFolder',{name:'one/two'})).state,'failed');}
  page.active=false;assert.equal((await run(remove)).state,'failed');
}
assert.equal(imported,2);assert.equal(exported,2);
console.log('PASS worlds and files: current panel ownership, target/entry identity, shared path, real dialog decision, picker operation outcome');

const disk=new Map(['/mc','/mc/mods','/mc/mods/a','/mc/versions','/mc/versions/one'].map((name,i)=>[name,i+1]));
const fileIo={accessSync:p=>disk.has(p),lstatSync(p){if(!disk.has(p))throw Error('missing');
  return {isDirectory:()=>p!=='/mc/mods/a',isFile:()=>p==='/mc/mods/a' || p.endsWith('.amcl-modpack.json'),isSymbolicLink:()=>false,ino:disk.get(p),mtime:1,ctime:1,size:1};}};
const loadFiles=makePureEtsLoader({'@kit.CoreFileKit':{fileIo},'@kit.ArkTS':{util:{generateRandomUUID:randomUUID}}});
const {captureFileEntry}=loadFiles('entry/src/main/ets/launcherskill/SkillFileScope.ets');
const {resolveInstanceGameDir}=loadFiles('commons/src/main/ets/utils/InstancePaths.ets');
// 人工确认使用真实页面准备/提交方法；用受控库存和目录身份模拟确认期间换代或开始使用游戏。
let inUse=false, leaseBusy=false, leases=0, removals=0, mcRoot='/mc';
const targetPath='/mc/versions/one';
const index=receiver('pages/Index.ets','Index',['confirmDeleteVersion','executeDeleteVersion'],{
  captureFileEntry,fs:fileIo,AppStorage:{get:()=>true},getTaskActivityOwner:()=>({recordSummary:async()=>{}}),
  ActivityCategory:{VERSION_MANAGE:'version'},ActivityStatus:{SUCCESS:'ok',FAILED:'failed'},
  newVersionInstallOwner:()=>randomUUID(),claimVersionInstall(){if(leaseBusy)throw Error('占用');leases++;return ()=>{leases--;};},
  removeDirRecursive(p){assert.equal(leases,1);assert.equal(p,targetPath);disk.delete(p);removals++;}},{
  availableVersions:['one'],orphanVersionDirs:[],deleteEpoch_:0,startupAlive_:true,startupRouteVisible_:true,
  mcRoot:()=>mcRoot,managementAccess_:()=>({gameBusy:()=>inUse}),versionAccess_:()=>({inventory:async()=>({installed:['one']})}),
  scanVersions:async()=>{},savePreferences(){}});
for(const change of [()=>disk.set(targetPath,42),()=>{inUse=true;},()=>{mcRoot='/other';},()=>{leaseBusy=true;},()=>{index.showDeleteConfirm=false;}]){
  assert.ok(index.confirmDeleteVersion('one')>0);
  change();
  assert.equal(await index.executeDeleteVersion(),false);
  assert.equal(removals,0);assert.ok(disk.has(targetPath));assert.equal(leases,0);
  inUse=leaseBusy=false;mcRoot='/mc';
}
assert.ok(index.confirmDeleteVersion('one')>0);assert.equal(await index.executeDeleteVersion(),true);
assert.equal(removals,1);assert.equal(leases,0);disk.set(targetPath,50);
console.log('PASS UI instance delete binds original directory and checks re-use, root, cancellation and lease at commit');
// 打开实际重命名浮层后，分别占用源/目标租约、替换目录或切换详情，均不能用旧确认提交。
const lease=loadFiles('feature_core/src/main/ets/version/VersionInstallLease.ets');
const {validateVersionName}=makePureEtsLoader({'@kit.CoreFileKit':{fileIo},'@kit.PerformanceAnalysisKit':{hilog:{}}})('commons/src/main/ets/utils/FileUtils.ets');
let renames=0;
const toast=()=>({getPromptAction:()=>({showToast(){}})});
const renameOwner=receiver('pages/Index.ets','Index',['prepareManagedRename_','renameManagedVersion_'],{
  ...lease,captureFileEntry,fs:fileIo,AppStorage:{get:()=>true},validateVersionName,getTaskActivityOwner:()=>({recordSummary(){}}),
  ActivityCategory:{VERSION_MANAGE:'version'},ActivityStatus:{SUCCESS:'ok',FAILED:'failed'},
  renameVersion(root,from,to){
    for (const name of [from,to]) assert.throws(()=>lease.claimVersionInstall(root,name,'competing-owner'));
    disk.delete(root+'/versions/'+from);disk.set(root+'/versions/'+to,91);renames++;return {ok:true};
  }},{mcRoot:()=>mcRoot,mcVersion:'one',getUIContext:toast,availableVersions:['one'],startupAlive_:true,startupRouteVisible_:true,
    managementAccess_:()=>({gameBusy:()=>inUse}),scanVersions(){},savePreferences(){},scanInstalledModsCount(){}});
const renameSheet=receiver('components/VersionManagerSheet.ets','VersionManagerSheet',['openRename','closeRename','confirmRename'],{
  validateVersionName},{detailVersion:'one',getUIContext:toast,onPrepareRename:from=>renameOwner.prepareManagedRename_(from),
  loadModpackSnapshot_(){},loadVersionJvmArgsState(){}});
const openRename=()=>{renameSheet.openRename();assert.ok(renameSheet.showRename);renameSheet.renameInput='renamed';};
for (const held of ['one','renamed']){
  openRename();const release=lease.claimVersionInstall('/mc',held,'installer');renameSheet.confirmRename();release();
  assert.equal(renames,0);renameSheet.closeRename();
}
for (const change of [()=>{inUse=true;},()=>{mcRoot='/other';},()=>disk.set(targetPath,63),()=>renameSheet.closeRename(),()=>{renameSheet.detailVersion='other';}]) {
  openRename();change();renameSheet.confirmRename();assert.equal(renames,0);
  mcRoot='/mc';inUse=false;renameSheet.detailVersion='one';renameSheet.closeRename();
}
openRename();const longName='valid'.repeat(20);renameSheet.renameInput=longName;renameSheet.confirmRename();
assert.equal(renames,1);assert.equal(renameSheet.detailVersion,longName);assert.equal(renameOwner.mcVersion,longName);
for(const name of ['one',longName]) lease.claimVersionInstall('/mc',name,'after-rename')();
disk.set(targetPath,64);
console.log('PASS real sheet rename binds original instance, locks both names, verifies use and selection at submit');
const env={...globals,captureFileEntry,resolveInstanceGameDir,fs:fileIo,updateFileIdentity:p=>String(disk.get(p)),LauncherSkillBus:{awaitingUser(){}},toggleEnabledFilename:n=>n,
  ModIntegrity:{CORRUPT:'corrupt'},metaOf:()=>({togglable:true}),AppStorage:{get:()=>true}};
const installed=receiver('components/InstalledResourcesSheet.ets','InstalledResourcesSheet',
  ['resourceSkill_','changeResource_','localResourceAccess_','ignoreUpdate','currentUpdate_','setRowUpdate','doUpdate','recheckUpdate'],env,{
  active:true,mounted_:true,loaded:true,kind:'mod',versionIsolation:false,
  skillScope_:scope,mcDir:'/mc',versionId:'one',targetDir:()=>'/mc/mods',isCurrent:e=>e===1,scanEpoch_:1,getUIContext:dialog,theme,resourceData_:{totalCount:()=>1,getData:()=>installed.row},
  row:{filename:'a',filePath:'/mc/mods/a',enabled:true,updateState:'outdated',latestVersionNumber:'v2',integrity:'corrupt',sizeBytes:25},applyQuery(){},
  modMeta_:new Map(),ignoredKeys_:new Set(),safeToast(){},pendingUpdates_:new Map([['/mc/mods/a',{version:{id:'v2',versionNumber:'v2'},identity:String(disk.get('/mc/mods/a'))}]]),
  doFullVerify:async()=>({state:'ready',corrupt:1}),doImport:async()=>({state:'cancelled'}),doRepair:async()=>({state:'ready'}),
  promptDelete_(){return 1},executeDelete(){accepted++;return true;}});
installed.rows=[installed.row];
installed.resourceData_.find=p=>installed.rows.find(row=>row.filePath===p);
const ir=(name,extra={})=>installed.resourceSkill_(name,{instance:'one',kind:'mod',folder:'folder',ref:'row:a',...extra});
assert.equal((await ir('listInstalledResources')).entries[0].integrity,'corrupt');
assert.equal((await ir('verifyInstalledMods')).corrupt,1);assert.equal((await ir('importInstalledResources')).state,'cancelled');
assert.equal((await ir('listInstalledResources')).shared,true);
disk.set('/mc/versions/one/.amcl-modpack.json',10);assert.equal((await ir('listInstalledResources')).shared,false);
disk.delete('/mc/versions/one/.amcl-modpack.json');
choice=0;assert.equal((await ir('updateInstalledMod')).state,'cancelled');choice=1;
assert.equal((await ir('ignoreInstalledModUpdate')).updateState,'ignored');
assert.equal((await ir('updateInstalledMod')).reason,'actionUnavailable');
installed.pendingUpdates_.set(installed.row.filePath,{version:{id:'v2'},identity:'another-file'});installed.row.updateState='outdated';
assert.equal((await ir('updateInstalledMod')).reason,'actionUnavailable');
assert.equal(await installed.recheckUpdate(installed.row),false); // 无可用来源的复查也撤回上轮候选。
assert.equal((await installed.changeResource_('updateInstalledMod',installed.row)).reason,'actionUnavailable');
assert.equal((await ir('repairInstalledMod')).state,'ready');
installed.getUIContext=()=>({getPromptAction:()=>({showDialog:async()=>{disk.set('/mc/mods/a',99);return {index:1};}})});
assert.equal((await ir('requestInstalledResourceDelete')).reason,'entryChanged');assert.equal(accepted,0);
installed.getUIContext=dialog;
assert.equal((await ir('requestInstalledResourceDelete')).state,'ready');assert.equal(accepted,1);
console.log('PASS installed assets: scoped scan, inherited update/verification/picker results and cancellation');

const pre=receiver('components/PreLaunchCheckSheet.ets','PreLaunchCheckSheet',['skillCheck_','checkActions_','switchAndRecheck_','fixFailedCheck_'],
  {textArg,result,util:{generateRandomUUID:randomUUID},DistributionPolicy:{isStore:()=>false}},
  {aborted:false,checks:[{id:'jvm',status:'warn',title:'JDK',fixActionKey:''}],phase:'jdkWarn',version:'one',currentJdk:'17',gameDir:'/mc',runAll(){this.calls=(this.calls??0)+1;},
  switchJdkToAuto:()=> '21',isJitFailed:()=>false,isJdkMissingFailed:()=>false,firstFailed:()=>null,onClose(){this.aborted=true;}});
let pc=await pre.skillCheck_('getLaunchChecks',{instance:'one'});assert.ok(pc.actions.includes('automaticJdk'));
pre.currentJdk='25';assert.equal((await pre.skillCheck_('chooseLaunchCheckAction',{instance:'one',choice:'automaticJdk',choiceRef:pc.choiceRef})).state,'failed');
pc=await pre.skillCheck_('getLaunchChecks',{instance:'one'});assert.equal((await pre.skillCheck_('chooseLaunchCheckAction',{instance:'one',choice:'automaticJdk',choiceRef:pc.choiceRef})).state,'accepted');
assert.equal(pre.currentJdk,'21');assert.equal(pre.calls,1);assert.equal((await pre.skillCheck_('chooseLaunchCheckAction',{instance:'one',choice:'automaticJdk',choiceRef:pc.choiceRef})).state,'failed');
console.log('PASS prelaunch captures original generation/JDK/choices, rejects stale or replayed decisions');

const versions=receiver('components/VersionManagerSheet.ets','VersionManagerSheet',['runVersionSkill_'],
  {textArg,result,GAME_LANGUAGES:[{code:'zh_cn'}],getDownloadTaskRegistry:()=>({get:()=>({id:'modpack:xyz',startedAtMs:33})})},
  {detailVersion:'one',availableVersions:['one'],currentStep:'detail',canRunGame:true,isExternalStorage:true,loadModpackSnapshot_(){},
    detailModpackSnap_:{installId:'xyz',source:'local',gameVersion:'1.20',missing:[{name:'a',reason:'offline'}]},copyModpackMissing_:async()=>true,
    repairModpack_(){this.repaired=true;return {state:'accepted',taskId:'modpack:xyz',activityId:33};},async onSaveVersionGameLang(_,v){this.language=v;return true;},loadVersionGameLang(){return this.language;},
    openFolder:async function(dir){this.folder=dir;return true;}});
assert.equal((await versions.runVersionSkill_('getInstancePack',{instance:'one'})).missing[0].name,'a');
assert.equal((await versions.runVersionSkill_('repairInstancePack',{instance:'one'})).activityId,33);assert.equal(versions.repaired,true);
assert.equal((await versions.runVersionSkill_('setInstanceLanguage',{instance:'one',language:'zh_cn'})).state,'ready');
assert.equal((await versions.runVersionSkill_('openInstanceSystemFolder',{instance:'one',folder:'saves'})).state,'needsUser');
assert.equal((await versions.runVersionSkill_('openInstanceSystemFolder',{instance:'one',folder:'../unlisted'})).state,'failed');assert.equal(versions.folder,'saves');
console.log('PASS per-instance settings, pack repair and external file manager allowlist');

const {MessageDestination}=makePureEtsLoader()('entry/src/main/ets/runtime/MessageDestination.ets');
let submittedRoute, routeResult='ok', restored=true, restoreFails=false, exportSnapshot;
const exportRecord={startedAt:8,title:'export',category:'export',status:'success',versionName:'1.20.2',mcDir:'/original',exportTaskId:'8-package'};
const navigation={
  pushUrl:async q=>{ if(routeResult==='reject')throw Error('rejected navigation');submittedRoute=q; },
  getState:()=>({name:routeResult==='wrongPage'?'AboutPage':submittedRoute.url}),
  getParams:()=>routeResult==='wrongParams'?{activityId:123456}:submittedRoute.params,
  back:()=>{if(routeResult==='reject')throw Error('back refused');}
};
const history=receiver('pages/DownloadHistoryPage.ets','DownloadHistoryPage',['historySkill_','openOverview_','openActivityLog_','openGameExport_','openErrorSheet_','pushHistoryRoute_','doUploadActivity_'],{result,textArg,
  LauncherSkillBus:globals.LauncherSkillBus,ActivityCategory:{GAME_EXPORT:'export'},MessageDestination,
  AppStorage:{setOrCreate:(_key,activity)=>{MessageDestination.witness(activity)(true);}},
  getGameExportCoordinator:()=>({restoreTask:async()=>{if(restoreFails)throw Error('removed receipt');return restored;},getTask:()=>exportSnapshot}),
  matchesActivity:(r,q)=>r.title.includes(q),activityDisplayTitle:r=>r.title,activityCategory:r=>r.category,ACTIVITY_FILTERS:['all','game','export'],isAbnormalActivity:r=>r.status==='failed'},
  {hostVisible:true,loaded:true,stats:{total:3,completed:2,failed:1,interrupted:0},records:[{startedAt:7,title:'test',category:'game',status:'failed'}],hasEvidence_:()=>true,
    viewportWidth:400,selectedRecords:[],cat_:r=>r.category,cardTitle_:r=>r.title,
    safeToast_(){},getUIContext:()=>({getRouter:()=>navigation}),
    canClear_:()=>true,confirmClearAll_:async function(){this.records=[];}});
const list=await history.historySkill_('listActivityHistory',{query:'test',filter:'all'});assert.equal(list.records[0].activityId,7);
assert.equal((await history.historySkill_('openHistoryRecord',{action:'log',activityId:7})).state,'needsUser');
assert.equal(submittedRoute.params.activityId,7);assert.equal((await history.historySkill_('openHistoryRecord',{action:'log',activityId:8})).state,'failed');
const openHistory=(action,activityId=7)=>history.historySkill_('openHistoryRecord',{action,activityId});
for(const wrong of ['reject','wrongPage','wrongParams']){
  routeResult=wrong;
  assert.equal((await openHistory('overview')).destinationReached,false);
  assert.equal((await openHistory('log')).state,'unknown');
}
routeResult='reject';assert.equal((await openHistory('error')).destinationReached,false);
routeResult='ok';assert.equal((await openHistory('error')).destinationReached,true);
history.viewportWidth=910;assert.equal((await openHistory('overview')).destinationReached,true);assert.equal(history.selectedRecords[0].startedAt,7);
history.records.push(exportRecord);exportSnapshot={id:'8-package',request:{mcRoot:'/original',versionId:'My Pack'}};
restored=false;assert.equal((await openHistory('exportResult',8)).state,'unknown');
restored=true;restoreFails=true;assert.equal((await openHistory('overview',8)).state,'unknown');
restoreFails=false;exportSnapshot.id='different';assert.equal((await openHistory('exportResult',8)).state,'unknown');
exportSnapshot.id='8-package';routeResult='reject';assert.equal((await openHistory('exportResult',8)).state,'unknown');
routeResult='ok';assert.equal((await openHistory('exportResult',8)).destinationReached,true);assert.equal(submittedRoute.params.versionId,'My Pack');
assert.equal((await history.historySkill_('manageActivityHistory',{action:'clear'})).state,'ready');
console.log('PASS history accountably distinguishes search, original activity, share/log handoff and actual cleared state');

const uuid=randomUUID(),other=randomUUID();const gr=receiver('pages/Index.ets','Index',['graphicsAttempts_'],{
  fs:{accessSync:()=>true,listFileSync:()=>[uuid+'.request.json',other+'.request.json','not-a-ticket.json']},
  GraphicsRecoveryStore:{ticket:(_,id)=>({rootActivityId:id===uuid?500:502,activityId:501,mcDir:'/mc',version:'one',attempt:1,retryProfile:'fallback'}),failure:()=>undefined},
  GraphicsHistoryStore:{outcome:()=>({status:'failed',code:'firstFrameUnavailable',stage:'before-frame',profile:'fallback'})}
},{mcRoot:()=>'/mc',context:{filesDir:'/app'}});
assert.equal(gr.graphicsAttempts_(500).attempts.length,1);assert.equal(gr.graphicsAttempts_(500).attempts[0].stage,'before-frame');
assert.equal(gr.graphicsAttempts_(123).state,'unavailable');
const requirements=receiver('components/VersionConfigPanel.ets','VersionConfigPanel',['versionSkill_'],{
  requiredJdkMajorForMc:()=>17,LOADER_KEYS:['vanilla','fabric','forge','neoforge','quilt'],loaderInfoForChoice:i=>({key:['vanilla','fabric','forge','neoforge','quilt'][i]})
},{gameVersion:'1.20.1',resolveVanillaCategory_:()=>'release',versionDescLoaded:true,versionDesc:'from wiki',installedJdkMajors:[17],
  vulkanHint:null,checkJitAvailable:()=>false,isLoaderSupported:i=>i!==4,requiredJdkForLoader:i=>i===2?17:0,runtimeJdkForLoader:()=>17});
const selected=await requirements.versionSkill_('getGameVersionRequirements',{gameVersion:'1.20.1'});assert.equal(selected.description,'from wiki');
assert.equal(selected.loaders[2].installerJdk,17);assert.equal(selected.loaders[4].supported,false);
console.log('PASS graphics recovery observations bound to root activity, actual version details read loader/JDK/Vulkan/report status');

let admitted=null, accept=true, ctx={filesDir:'/private'}, observed=null, store=false, alternate=null, attempts=0, browser='ok';
const project={id:'source-id',source:'modrinth',websiteUrl:'https://example.org/project'};
const registry={getAdapter:()=>admitted,enqueue:task=>{
  if(!accept)return Promise.reject(Error('admission blocked'));
  admitted=task;return new Promise(()=>{});
}};
const search=receiver('pages/ModBrowsePage.ets','ModBrowsePage',['handleBrowseSkill_','resumeModpack_','runModpackInstall_',
  'openWebsiteFromSheet','openCrossSourceWeb','openExternalUrl_','switchDetailSource'],{
  LauncherSkillBus:globals.LauncherSkillBus,ResourceKind:{MODPACK:'modpack'},ModSource:{MODRINTH:'modrinth',CURSEFORGE:'curseforge'},GameStorage:{externalMcDir:()=>'/external',sandboxMcDir:()=>'/internal'},supportsCustomResourceSave:()=>true,
  getDownloadTaskRegistry:()=>registry,ResourceOperation:{claim(){},watch:(files,ref,task)=>{observed={files,ref,task};}},
  util:{generateRandomUUID:randomUUID},createModpackFileResolver:()=>()=>undefined,CurseForgeFileSourceMode:{OFFICIAL_FIRST:'official'},
  ModpackInstallTask:class {constructor(arg){this.view={id:'modpack:'+arg.sessionId,startedAtMs:33};}},
  DiagnosticPolicy:{isDeveloperBuild:()=>false},DistributionPolicy:{isStore:()=>store},UnifiedTaskState:{ABORTED:'abort'},AppLogger:{error(){},warn(){}},TAG:'test',LOG_DOMAIN_DOWNLOAD:0},
  {currentBrowseKind_:()=>'modpack',uiCtx:()=>ctx,showModpackRecovery_:false,showVersionPicker_:false,showLocalModpackDetail_:false,
    openVersionPicker(){this.showVersionPicker_=true;},sandboxVersions_:['one'],externalVersions_:['other'],scanRootVersions:()=>['other'],
    onPickVersion(loc,version){this.targetLocation_=loc;this.targetVersionId_=version;this.showVersionPicker_=false;},
    modpackRecovery_:[{id:'original',title:'pack',missingCount:1}],modpackRecoveryVisible_(){return this.showModpackRecovery_;},
    openModpackRecovery_(){this.showModpackRecovery_=true;},closeModpackRecovery_(){this.showModpackRecovery_=false;},
    onOpenDownloadTask(){},onlyOfficialModpackFiles_:()=>false,resolveCurseForgeFileMode:()=>'official',
    detailProject_:project,detailFetchEpoch_:1,detailInteractionActive_:()=>true,
    resourceAccess_:()=>({detail:()=>({project}),available:()=>true}),resolveCounterpart:async()=>alternate,
    toast(){},onStatusMessage(){},refreshModpackRecovery_(){},
    async confirmDismissModpack_(item){this.modpackRecovery_=this.modpackRecovery_.filter(v=>v.id!==item.id);return "ready";}});
const wrongKind=await search.handleBrowseSkill_({},'listResourceTargets',{kind:'mod'});
assert.equal(wrongKind.reason,'resourcePageChanged');assert.equal(search.showVersionPicker_,false);
let targets=await search.handleBrowseSkill_({},'listResourceTargets',{kind:'modpack'});assert.deepEqual(targets.external,['other']);
const missingInstance=await search.handleBrowseSkill_({},'selectResourceTarget',{kind:'modpack',location:'external'});
assert.equal(missingInstance.reason,'invalidArguments');
assert.equal((await search.handleBrowseSkill_({},'selectResourceTarget',{kind:'modpack',instance:'one',location:'external'})).state,'failed');
const chosenTarget=await search.handleBrowseSkill_({},'selectResourceTarget',{kind:'modpack',instance:'other',location:'external'});
assert.equal(chosenTarget.instance,'other');assert.equal(search.targetVersionId_,'other');
verifySkillCases('selectResourceTarget',chosenTarget,missingInstance);
assert.equal((await search.handleBrowseSkill_({},'listModpackRecovery',{})).records[0].missing,1);
const resume=()=>{search.showModpackRecovery_=true;return search.handleBrowseSkill_({},'continueModpackRecovery',{id:'original'});};
ctx=undefined;assert.equal((await resume()).state,'unavailable');
ctx={filesDir:'/private'};admitted={view:{id:'modpack:original',startedAtMs:999,state:'done'}};
const oldCard=await resume();assert.equal(oldCard.state,'needsUser');assert.equal(oldCard.activityId,undefined);assert.equal(observed,null);
admitted=null;accept=false;assert.equal((await resume()).state,'unknown');assert.equal(admitted,null);
accept=true;const recovered=await resume();assert.equal(recovered.state,'accepted');assert.equal(recovered.activityId,33);
assert.equal(recovered.operationRef,observed.ref);assert.equal(admitted,observed.task);
search.showModpackRecovery_=true;
assert.equal((await search.handleBrowseSkill_({},'dismissModpackRecovery',{id:'original'})).state,'ready');assert.equal(search.modpackRecovery_.length,0);
console.log('PASS resource target identifies the correct storage, recovery uses the original persistent record');
const go=(choice)=>search.handleBrowseSkill_({},'resourceProjectSource',{project:project.id,source:project.source,choice,target:'curseforge'});
ctx={startAbility:async want=>{attempts++;if(browser==='reject')throw Error('browser denied');assert.match(want.uri,/^https:/);}};
assert.equal((await go('website')).state,'needsUser');
browser='reject';assert.equal((await go('website')).reason,'browserUnavailable');
const url=project.websiteUrl;project.websiteUrl='';assert.equal((await go('website')).reason,'websiteUnavailable');project.websiteUrl=url;
assert.equal((await go('crossSourceWeb')).reason,'counterpartWebsiteUnavailable');
alternate={websiteUrl:'https://example.org/alternate'};assert.equal((await go('crossSourceWeb')).reason,'browserUnavailable');
browser='ok';assert.equal((await go('crossSourceWeb')).state,'needsUser');
search.resolveCounterpart=async()=>{search.detailFetchEpoch_++;return alternate;};
assert.equal((await go('crossSourceWeb')).reason,'detailChanged');
store=true;const count=attempts;assert.equal((await go('website')).reason,'unavailableForProduct');assert.equal(attempts,count);
store=false;ctx=undefined;assert.equal((await go('website')).reason,'contextUnavailable');
project.altSource='curseforge';search.showDetailSheet_=true;search.router_={};
alternate={id:'paired-project',source:'curseforge'};search.resolveCounterpart=async()=>alternate;
search.openDetail=async resolved=>{search.detailProject_=resolved;};
const switched=await go('switch');assert.equal(switched.project,'paired-project');
search.detailProject_=project;search.openDetail=async()=>{search.detailProject_={id:'unrelated',source:'curseforge'};};
const wrongProject=await go('switch');
assert.notEqual(wrongProject.state,'ready','同一个来源的其他项目不能充当已切到本次匹配');
verifySkillCases('resourceProjectSource',switched,wrongProject);
console.log('PASS system browser acknowledged only after the matching project resolves and the system accepts its Want');
