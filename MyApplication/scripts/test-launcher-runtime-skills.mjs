/** 直接运行系统 Skill 注册的产品方法，夹具只提供相应页面已持有的服务和对话框。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';
import {loadActionComponent} from './lib/unified-actions-fixture.mjs';
import {makePureEtsLoader} from './lib/load-pure-ets.mjs';
import {verifySkillCases} from './lib/skill-business-check.mjs';

const load=makePureEtsLoader();
const values=load('entry/src/main/ets/launcherskill/SettingsSkillValues.ets');
const bus=load('entry/src/main/ets/launcherskill/LauncherSkillBus.ets');
function component(file,name,methods,other={}) {
  const deps={'../launcherskill/SettingsSkillValues':values,'../../launcherskill/SettingsSkillValues':values,
    '../launcherskill/LauncherSkillBus':bus,'../../launcherskill/LauncherSkillBus':bus,...other};
  return new (loadActionComponent('entry/src/main/ets/'+file+'.ets',name,{methods,dependencies:deps,
    globals:{AppStorage:{get:()=>true}}}))();
}
const tab=component('pages/tabs/DownloadTab','DownloadTab',['runtimeSkill_','manageRuntimeSlot_','runtimeSkillActive_','slotView_','catalogSkillResult_']);
Object.assign(tab,{hostVisible:true,dlSubTab:5,skillInteractive:()=>true,slotDialogBusy_:false,jdkCatalogStatus:'',
  jdkChecking:false,jdkImporting:false,jdkChannel:'stable',jdkActionEpoch_:0,importRef_:'',importOutcome_:{state:'unavailable'}});
const row={version:'17',installed:true,available:true,userImported:false,repairRequired:false,rollback:false,updateAvailable:true,
  installedTag:'A',expectedTag:'B',path:'/private/path',stateText:'ok'};
const uninstalled={...row,version:'21',installed:false};
tab.jdkVersions=[row,uninstalled];
tab.readRuntimeCatalog=()=>({catalog:{requestedChannel:'stable',catalogChannel:'stable',phase:'updated',origin:'network',
  selection:'stable-github',serial:1,generation:1,revision:7,usable:true},slots:tab.jdkVersions});
const calls=[];const active=new Set();
tab.isJdkDownloading=v=>active.has(v);
let slotIdentity='original-slot';
tab.readSlotIdentity=()=>slotIdentity;
const registry=new Map();
const index=component('pages/Index','Index',['enqueueManagedJdk_'],{launch:{JdkInstallTask:class {
  constructor(major,_manager,activity,replace){this.major=major;this.replace=replace;this.view={id:'jdk:'+major,startedAtMs:activity};}
}},commons:{AppLogger:{warn(){}},LOG_DOMAIN_DOWNLOAD:1}});
Object.assign(index,{showRuntimeHostRequirement_:()=>false,getJdkManager_:()=>({}),updateJdkReadyState(){},
  registry:{enqueue:task=>{registry.set(task.view.id,task);calls.push((task.replace?'replace:':'install:')+task.major);
    active.add(task.major);return Promise.resolve();}, getAdapter:id=>registry.get(id)}});
tab.onJdkDownload=v=>index.enqueueManagedJdk_(v,false);
tab.onJdkUpdate=v=>index.enqueueManagedJdk_(v,true);
tab.onJdkDelete=v=>calls.push('remove:'+v);
let pickerDone;
tab.onJdkImport=()=>{calls.push('picker');return new Promise(resolve=>{pickerDone=resolve;});};
let decide=async()=>({index:0});
tab.theme={};
tab.getUIContext=()=>({getPromptAction:()=>({showDialog:()=>decide()})});
const act=(n,a={})=>tab.runtimeSkill_(n,a);
// 玩家入口与机器入口共享同一份进行中确认；切换槽或放弃均不能执行删除。
const tabSource=fs.readFileSync(new URL('../entry/src/main/ets/pages/tabs/DownloadTab.ets',import.meta.url),'utf8');
const ast=compiler.createSourceFile('DownloadTab.ets',tabSource,compiler.ScriptTarget.Latest,true);
const jdkRows=ast.statements.find(n=>n.name?.getText(ast)==='DownloadTab').members.find(n=>n.name?.getText(ast)==='JdkItems_');
let deleteClick;
function findDeleteButton(node) {
  if (node.expression?.name?.getText(ast)==='onClick' && /^Button\(['"]删除['"]\)/.test(node.expression.getText(ast))) {
    assert.equal(deleteClick,undefined);deleteClick=node.arguments[0].getText(ast);
  }
  compiler.forEachChild(node,findDeleteButton);
}
findDeleteButton(jdkRows);assert.ok(deleteClick,'真实 JDK 删除按钮缺少点击事件');
const button=compiler.transpileModule('class ButtonHost { bind(info) { return ('+deleteClick+'); } }',{
  compilerOptions:{target:compiler.ScriptTarget.ES2020}}).outputText;
const bind=new Function(button+';return ButtonHost.prototype.bind;')();
let dismiss;
decide=()=>new Promise(resolve=>{dismiss=resolve;});
let manual;
const clickOwner=Object.create(tab);
clickOwner.manageRuntimeSlot_=(major,op)=>(manual=tab.manageRuntimeSlot_(major,op));
bind.call(clickOwner,row)();
assert.ok(manual,'玩家的确认路径须进入同一真实操作');
assert.equal((await act('manageJavaRuntime',{major:'17',operation:'replace'})).reason,'busy');
slotIdentity='reimported-same-tag';dismiss({index:1});
assert.equal((await manual).reason,'slotChanged'); assert.deepEqual(calls,[]);
row.installedTag='A';decide=async()=>({index:0});
assert.equal((await tab.manageRuntimeSlot_('17','remove')).state,'cancelled');
const inventory=await act('listJavaRuntimes');
assert.equal(inventory.state,'ready');assert.ok(!JSON.stringify(inventory).includes('/private'));
assert.equal((await act('manageJavaRuntime',{major:'../17',operation:'install'})).state,'failed');
assert.equal((await act('manageJavaRuntime',{major:'17',operation:'install'})).state,'failed');
assert.equal((await act('manageJavaRuntime',{major:'17',operation:'remove'})).state,'cancelled');
decide=async()=>{row.installedTag='next';return {index:1};};
assert.equal((await act('manageJavaRuntime',{major:'17',operation:'replace'})).reason,'slotChanged');
decide=async()=>({index:1});
const admission=await act('manageJavaRuntime',{major:'21',operation:'install'});
assert.deepEqual([admission.state,admission.taskId],['accepted','jdk:21']);
assert.equal((await act('manageJavaRuntime',{major:'21',operation:'install'})).state,'failed');
assert.equal((await act('manageJavaRuntime',{major:'17',operation:'replace'})).taskId,'jdk:17');
tab.hostVisible=false;
assert.equal((await act('pickJavaRuntimeArchive')).state,'failed');
assert.deepEqual(calls,['install:21','replace:17']);
index.registry.getAdapter=id=>({view:{id}});
assert.equal(index.enqueueManagedJdk_('25',false).state,'unknown');
index.showRuntimeHostRequirement_=()=>true;
assert.equal(index.enqueueManagedJdk_('11',false).state,'needsUser');
tab.hostVisible=true;
const pick=await act('pickJavaRuntimeArchive');
assert.equal(pick.state,'needsUser');assert.equal((await act('pickJavaRuntimeArchive')).reason,'busy');
pickerDone({state:'cancelled',major:'17'});await Promise.resolve();
assert.deepEqual(await act('readJavaArchiveImport',{reference:pick.reference}),{state:'cancelled',major:'17'});
assert.equal((await act('readJavaArchiveImport',{reference:'old'})).state,'failed');
console.log('PASS real runtime slots: recognized choice, replacement consent, slot replacement race, same task, duplicate, no path egress');

const current={versionName:'1.0.8',releaseKey:'target1'};
let bmsFact={versionName:'1.0.7',versionCode:31};
let rejectBms=false;
const bms=loadActionComponent('update/src/main/ets/UpdateChecker.ets','UpdateChecker',{methods:['installedIdentity'],
  dependencies:{'@kit.AbilityKit':{bundleManager:{BundleFlag:{GET_BUNDLE_INFO_DEFAULT:0},getBundleInfoForSelfSync(){
    if(rejectBms)throw Error('BMS rejected self query');return bmsFact;
  }}}}});
const updates=component('pages/SoftwareUpdatePage','SoftwareUpdatePage',['updateSkill_','skillActive_','skillUpdateState_','startUpdate','openGithub'],{
  '../launcherskill/UpdatePackageSelection':{UpdatePackageSelection:{begin(){throw Error('此用例不打开系统选择器');}}},
  'commons':{DistributionPolicy:{isStore:()=>channelStore},APP_VERSION:'1.0.7'},
  'entry/ProductBuildProfile':{ProductBuildProfile:{product:'sideload'}},
  'update':{UpdateChecker:{targetKey:m=>m.releaseKey,installedIdentity:()=>bms.installedIdentity(),canInstall:()=>true}}
});
let channelStore=false;
Object.assign(updates,{visible:true,requirementValid:true,skillDialog_:false,checking:false,importing:false,developerInstalled:false,
  channel:'stable',pending:true,candidate:current,theme:{},requiredHostProtocols:[],preferences:{strictLauncherField:()=> 'stable'}});
updates.getUIContext=tab.getUIContext;
let routeFailure=false;
updates.getUIContext=()=>({getPromptAction:()=>({showDialog:()=>decide()}),getRouter:()=>({pushUrl:async()=>{
  if(routeFailure)throw Error('page not found');calls.push('start');
}})});
updates.context={startAbility:async()=>{if(routeFailure)throw Error('browser denied');}};
const control=(n,a={})=>updates.updateSkill_(n,a);
const facts=await control('getLauncherUpdate');assert.equal(facts.target,current.releaseKey);
assert.equal(facts.currentCode,31);
rejectBms=true;assert.equal((await control('getLauncherUpdate')).state,'unknown');
assert.equal((await control('installRecommendedUpdate',{target:current.releaseKey})).state,'unknown');
rejectBms=false;bmsFact={versionName:'',versionCode:31};
assert.equal((await control('getLauncherUpdate')).reason,'installedVersionUnavailable');
bmsFact={versionName:'1.0.7',versionCode:31};
updates.preferences.strictLauncherField=()=>{throw Error('update channel read rejected');};
assert.equal((await control('getLauncherUpdate')).reason,'channelUnreadable');
updates.preferences.strictLauncherField=()=> 'stable';
assert.equal((await control('installRecommendedUpdate',{target:'wrong'})).reason,'targetChanged');
decide=async()=>{updates.candidate={...current};return {index:1};};
assert.equal((await control('installRecommendedUpdate',{target:current.releaseKey})).reason,'targetChanged');
decide=async()=>({index:1});
assert.equal((await control('installRecommendedUpdate',{target:current.releaseKey})).state,'needsUser');
routeFailure=true;
assert.equal((await control('installRecommendedUpdate',{target:current.releaseKey})).reason,'updatePageUnavailable');
assert.equal((await control('openUpdateSource',{source:'officialReleasePage'})).reason,'browserUnavailable');
routeFailure=false;
channelStore=true;assert.equal((await control('getLauncherUpdate')).state,'failed');
assert.equal(calls.filter(s=>s==='start').length,1);
console.log('PASS same candidate checkout, changed recommendation on confirmation, store blocked');

const notice=component('components/UpdateDialog','UpdateDialog',['noticeSkill_','selectNoticeItem_']);
Object.assign(notice,{skillNoticeRef_:'prompt-3',newVersion:'1',items:[{id:'17',title:'JDK 17',current:'A',target:'B'}],selectedItems:[],isRequired_:()=>false});
notice.onLater=()=>calls.push('later');
assert.equal((await notice.noticeSkill_('chooseRuntimeUpdateItem',{reference:'wrong',id:'17',selected:true})).state,'failed');
assert.equal((await notice.noticeSkill_('chooseRuntimeUpdateItem',{reference:'prompt-3',id:'17',selected:true})).state,'ready');
await notice.noticeSkill_('chooseRuntimeUpdateItem',{reference:'prompt-3',id:'17',selected:true});
assert.deepEqual(notice.selectedItems,['17']);
assert.equal((await notice.noticeSkill_('answerUpdateNotice',{reference:'prompt-3',answer:'review'})).state,'needsUser');
assert.equal((await notice.noticeSkill_('answerUpdateNotice',{reference:'prompt-3',answer:'later'})).outcome,'postponed');
console.log('PASS distinct update notice reference, live selectable runtime items, postponed separated from install');

const prompt=component('components/SideloadUpdateContent','SideloadUpdateContent',['skillUpdate_'],{commons:{DistributionPolicy:{isStore:()=>false}}});
const vm={version:'1.0.8',activityId:77,phase:'running',working:true,connectionReady:false,connectionRetry:true,
  checking:false,runtimeRetired:false,finishing:false,loginUrl:'SECRET',port:'5555'};
Object.assign(prompt,{theme:{},viewModel:vm,windowInteractive:()=>true,primaryLabel:()=>'继续',primaryEnabled:()=>true,installationPending:()=>false,
  retryConnection:()=>calls.push('retryConn'),runPrimary:()=>calls.push('advance'),getUIContext:tab.getUIContext});
const ctl=(op,more={})=>prompt.skillUpdate_('controlActiveLauncherUpdate',{activityId:77,phase:'running',operation:op,...more});
assert.ok(!JSON.stringify(await prompt.skillUpdate_('getActiveLauncherUpdate',{})).includes('SECRET'));
assert.equal((await ctl('retryConnection',{activityId:78})).state,'failed');
assert.equal((await ctl('retryConnection',{port:'5555'})).state,'failed');
assert.equal((await ctl('manualPort')).reason,'enterPortInApp');
assert.equal((await ctl('retryConnection')).state,'accepted');
decide=async()=>{vm.phase='installing';return {index:1};};
assert.equal((await ctl('continue')).reason,'updateChanged');
assert.equal(calls.includes('advance'),false);
console.log('PASS original update phase/owner, wireless handoff, stale acknowledgement, no unverified port or credentials');

// 真实具名选择、UI 确定与 QA 关闭观察器共享单次草稿；偏好替身只控制耐久写入何时完成。
{
  const registry=bus.LauncherSkillBus,owner={},settings={};let finishWrite, writes=0,closed=0;
  const stored={glRenderer:'mobileglues',graphicsProfileExplicit:true,devRendererOverride:''};
  class Preferences {
    strictLauncherField(key){return stored[key];}
    async saveLauncherFields(fields,current){
      writes++;assert.ok(current());await new Promise(resolve=>{finishWrite=resolve;});Object.assign(stored,fields);
    }
  }
  const g=component('components/MobileglRendererSettings','MobileglRendererSettings',
    ['skillAction_','stagePeerBackend_','canConfirm_','confirmBackend_','aboutToDisappear'],
    {feature_system:{PreferenceManager:Preferences},commons:{AppLogger:{info(){},warn(){}}}});
  Object.assign(g,{mcVersion:'game',availabilityActive:true,availabilityLoading:false,lastInput:{},choiceEpoch_:0,writingChoice_:-1,
    peerRows:[{id:'mobileglues',selected:true,enabled:true},{id:'nativegl',selected:false,enabled:true}],compact:false,confirmationCommitted:false,
    draftBackendId:'mobileglues',getUIContext:()=>({getHostContext:()=>({})}),onConfirmed(){closed++;},
    refreshPeerRows(){for(const row of this.peerRows)row.selected=stored.glRenderer===row.id;}});
  registry.attach(owner,()=>true,()=> 'fixture');
  registry.bind('settings',settings,(name,args)=>registry.forward(settings,'settingsGraphics',name,args));
  registry.bind('settingsGraphics',g,(name,args)=>g.skillAction_(name,args));
  let pending;
  const ask=()=>registry.call('settings','selectGraphicsBackend',{id:'nativegl',version:'game'},observe=>{pending=observe;});
  const declined=await registry.call('settings','selectGraphicsBackend',{id:'removed',version:'game'});
  const staged=await ask();assert.equal(staged.state,'needsUser');assert.equal(pending(),true);assert.equal(writes,0);
  verifySkillCases('selectGraphicsBackend',staged,declined,'L065');
  g.stagePeerBackend_(g.peerRows[0]);assert.equal(pending(),false);
  assert.equal((await ask()).state,'needsUser');assert.equal(pending(),true);
  const apply=g.confirmBackend_();assert.equal(pending(),true);assert.equal(writes,1);assert.equal(closed,0);
  g.aboutToDisappear();assert.equal(pending(),true,'已派发写入的原组件即使退场也需等提交');
  finishWrite();await apply;assert.equal(pending(),false);assert.equal(stored.glRenderer,'nativegl');
  assert.equal(stored.graphicsProfileExplicit,true);assert.equal(stored.devRendererOverride,'');assert.equal(closed,0);
  registry.detach(owner);
}
