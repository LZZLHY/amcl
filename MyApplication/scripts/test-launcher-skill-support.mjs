/** 真实页面操作与可持久化消息对象，系统弹窗、网页导航和文件 IO 由测试替身控制。 */
import assert from 'node:assert/strict';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { loadActionComponent } from './lib/unified-actions-fixture.mjs';

let storeChannel=false;
const links={DOCS_INSTALL_URL:'install',DOCS_INSTALL_FALLBACK_URL:'install-fallback',DOCS_NO_JIT_URL:'jit',DOCS_NO_JIT_FALLBACK_URL:'jit-fallback',
  DistributionPolicy:{isStore:()=>storeChannel}};
let disk='';
const log={warn(){},error(){},info(){}};
const load=makePureEtsLoader({'@kit.ArkData':{preferences:{getPreferences:async()=>({
  get:async()=>disk,put:async(k,value)=>{disk=value;},flush:async()=>{}
})}}, commons:{AppLogger:log,LOG_DOMAIN_UI:0,...links}});
const routes=load('entry/src/main/ets/launcherskill/SupportRoutes.ets');
assert.equal(routes.playerSupportRoute({topic:'install'}).params.src,'install');
assert.equal(routes.playerSupportRoute({topic:'https://other.example'}),undefined);
storeChannel=true;
assert.equal(routes.playerSupportRoute({topic:'feedback'}),undefined);
assert.equal(routes.supportRoute('policy',{policy:'../../credentials'}),undefined);
assert.equal(routes.supportRoute('activity',{activityId:-2}),undefined);
assert.equal(routes.supportRoute('activity',{activityId:7}).params.activityId,7);

const msg=load('entry/src/main/ets/components/AppMessageStore.ets');
let activeNotice=true, selectedNotice=0;
const notifier=makePureEtsLoader({'@kit.NotificationKit':{notificationManager:{
  cancel:async id=>{selectedNotice=id;throw Error('no acknowledgement');},
  getActiveNotifications:async()=>activeNotice?[{id:selectedNotice}]:[]}},
  '@kit.AbilityKit':{},commons:{AppLogger:log,LOG_DOMAIN_UI:0},'./AppMessageStore':msg})('entry/src/main/ets/components/AppNotifier.ets');
assert.equal(await notifier.cancelNotification('one'),false);
activeNotice=false;assert.equal(await notifier.cancelNotification('one'),true);
const store=msg.getAppMessageStore();
await store.init({});
const notices=[], targets=[];
const destination = load('entry/src/main/ets/runtime/MessageDestination.ets');
let dialog;
const Message=loadActionComponent('entry/src/main/ets/pages/MessageCenterPage.ets','MessageCenterPage',{
  methods:['skillAction_','refresh_','unreadCount_','onTapMessage_','markAllRead_','clearAll_','confirmClear_'],
  dependencies:{'../components/AppMessageStore':msg,'../runtime/MessageDestination':destination,
    '../launcherskill/LauncherSkillBus':load('entry/src/main/ets/launcherskill/LauncherSkillBus.ets'),
    '../components/AppNotifier':{refreshUnreadCount(){},cancelNotification:async id=>{notices.push(id);return true;}},
    '@kit.PerformanceAnalysisKit':{hilog:log}},globals:{TAG:'test',AppStorage:{setOrCreate(){}}}
});
const page=new Message();Object.assign(page,{context:{},messages:[],clearDecision_:'idle',theme:{},getUIContext:()=>({
  getRouter:()=>({pushUrl:async x=>{targets.push(x.url);},getState:()=>({name:'ActivityLogPage'}),back:()=>{throw Error('back rejected');}}),
  getPromptAction:()=>({showDialog:()=>new Promise(resolve=>{dialog=resolve;})})
})});
function message(id){return {id,kind:1,createdAt:Date.now(),read:false,title:'secret mail',body:'private text',action:{type:msg.AppMessageActionType.OPEN_PAGE,payload:'pages/ActivityLogPage'}};}
await store.post(message('one'));
let snapshot=await page.skillAction_('readMessages',{});
assert.equal(snapshot.unread,1); assert.equal(snapshot.messages[0].read,false);
assert.ok(!JSON.stringify(snapshot).includes('private text'));
assert.equal((await page.skillAction_('openMessage',{messageId:'one'})).read,true);
assert.deepEqual(notices,['one']);assert.deepEqual(targets,['pages/ActivityLogPage']);
assert.equal((await page.skillAction_('requestClearMessages',{})).state,'needsUser');
dialog({index:0}); await new Promise(r=>setImmediate(r));
assert.equal((await page.skillAction_('readMessages',{})).clearDecision,'cancelled');
assert.equal(store.size(),1);
await page.skillAction_('requestClearMessages',{});
await store.post(message('two'));
dialog({index:1}); await new Promise(r=>setImmediate(r));
assert.equal(store.size(),2,'new message must survive stale batch confirmation');
assert.equal((await page.skillAction_('readMessages',{})).clearDecision,'failed');
await page.skillAction_('requestClearMessages',{});dialog({index:1});await new Promise(r=>setImmediate(r));
assert.equal(store.size(),0);assert.equal((await page.skillAction_('readMessages',{})).clearDecision,'completed');
const stale=message('error-event');
stale.action={type:msg.AppMessageActionType.OPEN_ERROR_SHEET,payload:'42'};
await store.post(stale);await page.skillAction_('readMessages',{});
const backFailure=await page.skillAction_('openMessage',{messageId:stale.id});
assert.deepEqual(backFailure,{state:'unknown',read:true,destinationReached:false,notificationGone:true});
let firstWitness;
assert.equal(await destination.MessageDestination.open(42,()=>{
  firstWitness=destination.MessageDestination.witness(42);
  destination.MessageDestination.witness(99)(true);firstWitness(true);
}),true);
assert.equal(await destination.MessageDestination.open(42,()=>{firstWitness(true);throw Error('second route failed');}),false);
const Home=loadActionComponent('entry/src/main/ets/pages/Index.ets','Index',{
  methods:['onToastTap_'],dependencies:{'../components/AppMessageStore':msg,'../components/AppNotifier':{refreshUnreadCount(){}}}});
const home=new Home();
Object.assign(home,{toastMsgId:stale.id,toastMessage_:stale,toastSessionKey:42,startupAlive_:true,startupRouteVisible_:true,
  openErrorSheetBySession_:async()=>false,toastVisible:true});
assert.equal((await home.onToastTap_()).destinationReached,false);
await store.post({...stale,title:'replacement'});
assert.equal((await home.onToastTap_()).reason,'messageNotCommitted','旧提示不能替换同号新消息的确定结果');
const About=loadActionComponent('entry/src/main/ets/pages/AboutPage.ets','AboutPage',{
  methods:['skillAction_'],dependencies:{update:{UpdateChecker:{currentVersionCode:()=>1000911,currentVersionName:()=>'1.0.8-pre2'}},
    '../runtime/GameRunAdmission':{GameRunAdmission:{isAllowed:()=>true}},commons:{DistributionPolicy:{isStore:()=>true},
      AUTHOR_EMAIL:'mail',QQ_GROUP_ID:'group',APP_REPO_URL:'repo'}}});
const about=new About();about.installedVersionCode=0;
const build=await about.skillAction_('readLauncherAbout',{});
assert.equal(build.versionCode,1000911);assert.equal(build.repository,'');

const Policy=loadActionComponent('entry/src/main/ets/pages/LocalPolicyPage.ets','LocalPolicyPage',{
  methods:['load_','skillAction_'],dependencies:{'@kit.ArkTS':{util:{TextDecoder:{create:()=>({decodeToString:bytes=>new TextDecoder().decode(bytes)})}}}}});
const policy=new Policy();Object.assign(policy,{generation:0,displayedPolicy_:'',getUIContext:()=>({getRouter:()=>({getParams:()=>({policy:'privacy'})})}),
  context:{resourceManager:{getRawFileContent:async name=>new TextEncoder().encode(name)}}});
const result=await policy.skillAction_('readLocalPolicy',{policy:'license',offset:0});
assert.equal(result.state,'ready');assert.equal(result.text,'store-policies/licenses.txt');
assert.equal((await policy.skillAction_('readLocalPolicy',{policy:'../invalid'})).state,'failed');
// 与上次产生的分享结果隔离；仅本次前台确认的回执可供对应操作号读取。
const Activity=loadActionComponent('entry/src/main/ets/pages/ActivityLogPage.ets','ActivityLogWorkspace',{
  methods:['skillActivity_','shareVisibilityChanged_','shareOutcome_'],dependencies:{
    '../launcherskill/LauncherSkillBus':load('entry/src/main/ets/launcherskill/LauncherSkillBus.ets'),
    '@kit.ArkTS':{util:{generateRandomUUID:()=> 'new-operation'}},
    '../launcherskill/EvidenceChoiceResult':makePureEtsLoader({'@kit.ArkTS':{util:{generateRandomUUID:()=>'choice-1'}}})('entry/src/main/ets/launcherskill/EvidenceChoiceResult.ets'),
    commons:{DistributionPolicy:{allowPublisherServices:()=>false}},
    '../components/AiReportStore':{loadAiReport:()=>undefined}}});
const activity=new Activity();
Object.assign(activity,{activityId:42,loading:false,manifest:{state:1},pageActive:true,context:{filesDir:'/private'},
  shareNonce:4,skillShareRef_:'',sharedLog:{id:'previous'},authorSubmissionId:'old'});
assert.equal((await activity.skillActivity_('reviewActivityShare',{activityId:41,destination:'logshare'})).state,'unavailable');
assert.equal((await activity.skillActivity_('reviewActivityShare',{activityId:42,destination:'author'})).state,'unavailable');
const handoff=await activity.skillActivity_('reviewActivityShare',{activityId:42,destination:'logshare'});
assert.equal(handoff.state,'needsUser'); assert.equal(handoff.operationRef,'new-operation');
activity.shareVisibilityChanged_();
assert.equal((await activity.skillActivity_('getActivityShareOutcome',{activityId:42,operationRef:'old'})).state,'unknown');
const waiting=await activity.skillActivity_('getActivityShareOutcome',{activityId:42,operationRef:handoff.operationRef});
assert.equal(waiting.shareState,'waiting'); assert.equal(waiting.receipt,'');
activity.showShareOptions=false;activity.shareVisibilityChanged_();
assert.equal((await activity.skillActivity_('getActivityShareOutcome',{activityId:42,operationRef:handoff.operationRef})).shareState,'cancelled');
// 原面板上报的阶段经相同的活动号和引用查询；旧面板关闭或失败不能覆盖新面板的结果。
const readShare=async()=>activity.skillActivity_('getActivityShareOutcome',{activityId:42,operationRef:activity.skillShareRef_});
const errors=makePureEtsLoader()('entry/src/main/ets/components/LogShareErrors.ets');
const Errors=loadActionComponent('entry/src/main/ets/components/ActivityShareSheet.ets','ActivityShareSheet',{
  methods:['fail_'],dependencies:{'./LogShareErrors':errors}});
const shareSheet=new Errors();
Object.assign(shareSheet,{alive:true,phase:'sending',setPhase_(phase){this.phase=phase;},
  onShareOutcome:(state,reason,receipt)=>activity.shareOutcome_(activity.shareNonce,state,reason,receipt)});
for (const [stage,expected] of [['http','failed'],['unknown-outcome','unknown'],['persist','unknown']]) {
  shareSheet.fail_(new errors.LogShareRequestError('sensitive internal transport detail',stage));
  activity.showShareOptions=false;activity.shareVisibilityChanged_();
  const outcome=await readShare();assert.equal(outcome.shareState,expected);assert.equal(outcome.reason,stage);
  assert.ok(!JSON.stringify(outcome).includes('sensitive'));
}
activity.shareOutcome_(activity.shareNonce-1,'shared','','wrong');
assert.equal((await readShare()).receipt,'');
activity.shareOutcome_(activity.shareNonce,'shared','','actual');
shareSheet.fail_(new Error('clipboard error'));
assert.equal((await readShare()).receipt,'actual');
assert.equal((await activity.skillActivity_('readHistoricalAnalysis',{activityId:42})).available,false);
let settle;
activity.canDelete_=()=>true;activity.requestRemoveLedger_=()=>new Promise(resolve=>{settle=resolve;});
const ask=await activity.skillActivity_('requestActivityRemoval',{activityId:42});
assert.equal(ask.state,'needsUser');
assert.equal((await activity.skillActivity_('requestActivityRemoval',{activityId:42})).state,'busy');
settle('cancelled');await new Promise(resolve=>setImmediate(resolve));
// 缺失配置有明确的默认值。特别是在保存关闭提醒后，读取被拒或配置消失都不足以证明写成了 0。
let alertText, alertError;
const alertStore=makePureEtsLoader({
  '@kit.CoreFileKit':{fileIo:{readTextSync(){if(alertError)throw alertError;return alertText;}}},
  './ActivityLedger':{},'./EvidenceIo':{}
})('commons/src/main/ets/utils/ActivityStorage.ets');
alertText='{"bytes":268435456}';
assert.equal(alertStore.readConfirmedActivityAlert('/owned'),268435456);
for(const invalid of ['{}','null','{"bytes":"0"}','{']) {
  alertText=invalid;
  assert.equal(alertStore.readConfirmedActivityAlert('/owned'),undefined);
  assert.equal(alertStore.activityStorageAlert('/owned'),0,'页面保留原来的容错显示');
}
alertError={code:13900002};
assert.equal(alertStore.readConfirmedActivityAlert('/owned'),0);
assert.equal(alertStore.readConfirmedActivityAlert('/owned',false),undefined);
alertError={code:13900013};
assert.equal(alertStore.readConfirmedActivityAlert('/owned'),undefined);
const Shell=loadActionComponent('entry/src/main/ets/pages/Index.ets','Index',{
  methods:['shellOperation_'],dependencies:{commons:{readConfirmedActivityAlert:alertStore.readConfirmedActivityAlert,
    readActivityStorage:async()=>({bytes:1024,issues:[],groups:[]}),setActivityStorageAlert(){}},
    'entry/ProductBuildProfile':{},'../launcherskill/SupportRoutes':{},'../runtime/SystemBackupState':{}}
});
const shell=new Shell();Object.assign(shell,{context:{filesDir:'/owned'},startupAlive_:true,startupRouteVisible_:true,versionActionBlock_:()=>''});
const uncertain=await shell.shellOperation_('readActivityStorage',{});
assert.equal(uncertain.state,'partial');assert.equal(uncertain.alertKnown,false);assert.equal('alertBytes' in uncertain,false);
assert.equal((await shell.shellOperation_('setActivityAlert',{thresholdMiB:0})).state,'unknown','读取被拒不能把 0 当作禁用已保存');

let completeCopy, writes=0;
const network=loadActionComponent('entry/src/main/ets/components/NetworkDiagnosticsSheet.ets','NetworkDiagnosticsSheet',{
  methods:['skillAction_','copyReport_'],
  dependencies:{'../launcherskill/SettingsSkillValues':load('entry/src/main/ets/launcherskill/SettingsSkillValues.ets'),
    feature_core:{ProbeStatus:{OK:0,FAIL:1}},'@kit.BasicServicesKit':{pasteboard:{
      createData:(type,txt)=>txt, getSystemPasteboard:()=>({setData:()=>{writes++;return new Promise((resolve,reject)=>{completeCopy={resolve,reject};});}})
    }}}
});
const panel=new network();Object.assign(panel,{running:true,toast_(){},report:{title:'ok',summary:'checked',probes:[]}});
const Settings=loadActionComponent('entry/src/main/ets/pages/tabs/SettingsTab.ets','SettingsTab',{
  methods:['openSkillSetting_'],dependencies:{commons:{DistributionPolicy:{isStore:()=>false}},'../../launcherskill/LauncherSkillBus':{
    LauncherSkillBus:{forward:(_owner,_domain,operation,args)=>panel.skillAction_(operation,args)}},
    '../../launcherskill/SettingsSkillValues':load('entry/src/main/ets/launcherskill/SettingsSkillValues.ets')}});
const settings=new Settings();Object.assign(settings,{hasItem_:()=>true,openSearchItem_:async()=>true});
assert.deepEqual(await settings.openSkillSetting_('network'),{state:'needsUser',item:'network'});
assert.equal((await panel.skillAction_('inspectNetwork',{operation:'read'})).state,'busy');
assert.equal((await panel.skillAction_('inspectNetwork',{operation:'copy'})).state,'busy'); assert.equal(writes,0);
panel.running=false;
const denied=panel.skillAction_('inspectNetwork',{operation:'copy'});
assert.equal(writes,1);assert.equal((await panel.skillAction_('inspectNetwork',{operation:'copy'})).state,'busy');
completeCopy.reject(Error('clipboard denied'));assert.deepEqual(await denied,{state:'failed',copied:false});
const ok=panel.skillAction_('inspectNetwork',{operation:'copy'});completeCopy.resolve();assert.deepEqual(await ok,{state:'ready',copied:true});
console.log('PASS launcher support, durable confirmation, strict alert readback and acknowledged network-report clipboard delivery');

const Changelog=loadActionComponent('entry/src/main/ets/pages/ChangelogPage.ets','ChangelogPage',{
  methods:['skillAction_','latestRelease_','hasUpdate_','openReleaseListOrUpdate_'],dependencies:{commons:{APP_REPO_URL:'repo'}}});
const changelog=new Changelog();
const destinations=[];
Object.assign(changelog,{releases:[],loading:false,storeTrack:false,currentCode:2,openUrl_:async url=>{destinations.push(url);return true;}});
assert.equal((await changelog.skillAction_('openLatestRelease',{})).state,'needsUser');
assert.deepEqual(destinations,['repo/releases']);
changelog.storeTrack=true;
assert.equal((await changelog.skillAction_('openLatestRelease',{})).state,'unavailable');
changelog.storeTrack=false;changelog.releases=[{versionCode:2,url:'disabled'}];
assert.equal((await changelog.skillAction_('openLatestRelease',{})).state,'unavailable');
changelog.releases=[{versionCode:3,url:'new-file'}];
assert.equal((await changelog.skillAction_('openLatestRelease',{})).state,'needsUser');
assert.deepEqual(destinations,['repo/releases','new-file']);
