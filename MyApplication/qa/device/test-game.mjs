// 面板和游戏进程由平台装配。本套件直接执行设备适配器、首页准入和真实 Sheet 回调，沙箱与平台事实可控。
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import ts from '../../scripts/lib/ets-compiler.mjs';
import {makePureEtsLoader} from '../../scripts/lib/load-pure-ets.mjs';

const launchId='a'.repeat(32), observeId='b'.repeat(32), sid='1'.repeat(32);
const files=new Map();
let directory='/sandbox/amcl-qa-v1/'+sid, ledger=null, writesFail=false, activeSession;
let nonce=0, diskStats=0;
let graphicsReads=0, starts=0, observer;
const native={desktopProcessId:()=>14,desktopProcessAlive:pid=>(pid===14||pid===19)?1:0,
  mcGetGraphicsRuntimeFailure:()=>{graphicsReads++;return 'current-sample';}};
const disk={lstatSync(path){diskStats++;if(!files.has(path))throw Object.assign(Error('missing'),{code:13900002});
  return {isFile:()=>true,isSymbolicLink:()=>false,size:Buffer.byteLength(files.get(path))};},readTextSync:path=>files.get(path)};
const deps={
  '@kit.ArkTS':{util:{TextDecoder,generateRandomUUID:()=> (++nonce).toString(16).padStart(32,'0')}},
  '@kit.CoreFileKit':{fileIo:disk},'entry/ProductQa':{ProductQa:{sessionDirectory:()=>directory}},
  commons:{AtomicFileWriter:{write:(p,s)=>{if(writesFail)throw Error('disk');files.set(p,s);}},
    DiagnosticPolicy:{hasTestHooks:()=>true},ledgerCurrentRunNonce:()=> 'boot-14',
    LedgerState:{RUNNING:0},ledgerManifestAsync:async()=>ledger},
  'libentry.so':{__esModule:true,default:native},'./ets/runtime/GameSessionHost':{existingGameSessionHost:()=>activeSession},
  './ets/runtime/GraphicsRecoveryPolicy':{parseGraphicsRuntimeState:()=>({pid:14,presentCount:8,surfaceGeneration:5})},
};
function game(){return makePureEtsLoader(deps)('entry/src/main/ProductQaGame.ets').ProductQaGame;}
const api=game();
const launch=(id=launchId,start=(v,o)=>{assert.equal(v,'installed');starts++;observer=o;})=>
  api.handle('/sandbox','game.launch','{"versionId":"installed"}',id,start).then(JSON.parse);
const observe=(service=api,id=launchId)=>service.handle('/sandbox','game.observe',JSON.stringify({operationId:id}),observeId,
  ()=>assert.fail('只读观察不得派发游戏')).then(JSON.parse);
assert.equal((await observe()).status,'unknown');
assert.equal((await launch()).status,'accepted');assert.equal(starts,1);
assert.equal((await observe()).data.stage,'prechecking');
assert.equal((await observe(game())).status,'unknown','进程重启前未形成活动不得伪造回执');
await launch();assert.equal(starts,1,'同请求不得再派发');
observer.beginChecks();observer.check('files','fail','redownload');observer.check('contract','pass','');
assert.deepEqual([(await observe()).data.precheckKey,(await observe()).data.reasonCode],['files','redownload']);
observer.beginChecks();observer.check('runtime','fail','download_jdk');
assert.equal((await observe()).data.reasonCode,'download_jdk');
observer.beginChecks();observer.check('jdk','warn','jdk_mismatch');
assert.deepEqual((await observe()).data.choices,['automatic-jdk','keep-jdk','cancel']);
observer.beginChecks();observer.check('jdk','warn','');assert.equal((await observe()).data.stage,'prechecking');
observer.bind(500,false);observer.sent();
let sample=(await observe(game())).data;assert.equal(sample.activityId,500);assert.equal(sample.ownerPid,0);assert.equal(sample.presentCount,-1);
ledger={activityId:500,category:'launch',gameVersionId:'wrong',state:0,ownerPid:14};
assert.equal((await observe()).reason,'activity-mismatch');
ledger.gameVersionId='installed';assert.equal((await observe()).data.presentCount,-1);
assert.equal((await observe()).data.ownerVerified,false,'只有同一PID的旧账本不足以认领当前宿主');
activeSession={isRunning:()=>true,sessionActivity:()=>501};sample=(await observe()).data;
assert.equal(sample.presentCount,-1);assert.equal(sample.ownerVerified,false,'新一局不得认领上一局的账本');
activeSession={isRunning:()=>false,sessionActivity:()=>500,runningWindow:()=>5001};
assert.equal((await observe()).data.ownerVerified,false,'已停止宿主不可用作活动来源');
activeSession.isRunning=()=>true;
ledger.ownerPid=19;sample=(await observe()).data;assert.equal(sample.pidAlive,1);assert.equal(sample.ownerVerified,false,
  '活动号匹配也不得借另一存活进程的账本');
ledger.ownerPid=14;
activeSession.sessionActivity=()=>500;sample=(await observe()).data;
assert.equal(sample.ownerVerified,true);
assert.equal(sample.presentCount,8);assert.equal(sample.surfaceGeneration,5);assert.equal(sample.pidAlive,1);
assert.equal(sample.mainMenu,undefined,'帧数不提供主菜单证明');
assert.equal(graphicsReads,1);
ledger.state=4;sample=(await observe()).data;assert.equal(sample.stage,'ended');assert.equal(sample.ownerVerified,false);
assert.equal(graphicsReads,1,'退出活动不采新进程的图形计数');
const privateId='c'.repeat(32);await launch(privateId);observer.bind(500,true);observer.sent();ledger.state=0;
sample=(await observe(api,privateId)).data;
assert.equal(sample.presentCount,-1);assert.equal(sample.pidAlive,1);assert.equal(sample.ownerVerified,false,
  '独立进程的 PID 存活不能证明本轮活动归属');
assert.equal(graphicsReads,1,'独立游戏不能借启动器的图形样本');
// 两份导出分别代表两个进程的独立静态状态；真正的父端出题、私有子端应答及租约撤销均执行产品实现。
{
  const revision='2'.repeat(40),grant={schema:1,session:sid,sourceRevision:revision,expiresAt:Date.now()+60000,
    actions:['game.launch','game.observe']};
  files.set('/sandbox/amcl-qa-v1/session.json',JSON.stringify(grant,null,2));
  files.set(directory+'/grant.json',JSON.stringify(grant));
  const context={filesDir:'/sandbox',resourceManager:{getRawFileContentSync:()=>Buffer.from(JSON.stringify(
    {name:'default',sourceRevision:revision,build:{mode:'debug'}}))}};
  let running=true,window=77,srcActivity=500,boot='boot-19',alive=1;
  const child=makePureEtsLoader({...deps,'@kit.ArkTS':{util:{TextDecoder:class {decodeWithStream(raw){return String(raw);}}}},
    commons:{...deps.commons,ledgerCurrentRunNonce:()=>boot},'libentry.so':{__esModule:true,default:{
      desktopProcessId:()=>19,mcIsRunning:()=>running}}})('entry/src/main/ProductQaGame.ets').ProductQaGame;
  const params={activityId:500};observer.bindPrivateParams(params);
  const release=child.armPrivate(context,{parameters:params},500,'installed');
  assert.equal(typeof release,'function');
  const realAlive=native.desktopProcessAlive;
  native.desktopProcessAlive=pid=>pid===19?alive:realAlive(pid);
  ledger={activityId:500,category:'launch',gameVersionId:'installed',state:0,ownerPid:19,runNonce:boot};
  const host={sessionActivity:()=>srcActivity,runningWindow:act=>act===500?window:0};
  const clock=globalThis.setTimeout,now=Date.now;
  let simulate=()=>child.pulsePrivate(host);
  globalThis.setTimeout=(cb,delay,...args)=>clock(()=>{simulate();cb(...args);},delay===200?3:delay);
  const one=async q=>JSON.parse(await api.handle('/sandbox','game.observe',JSON.stringify({operationId:privateId}),q,
    ()=>assert.fail('只读观察不能启动游戏')));
  try {
    let q='3'.repeat(32),v=(await one(q)).data;
    assert.deepEqual([v.ownerVerified,v.windowId,v.witnessRequestId],[true,77,q]);
    const answer=JSON.parse(files.get(directory+'/witness-'+privateId+'.json'));
    const firstNonce=answer.nonce;
    q='4'.repeat(32);v=(await one(q)).data;
    assert.equal(v.ownerVerified,true);assert.equal(v.witnessRequestId,q);
    assert.notEqual(JSON.parse(files.get(directory+'/witness-'+privateId+'.json')).nonce,firstNonce);
    running=false;assert.equal((await one('5'.repeat(32))).data.ownerVerified,false,'先前的正回执不得重放');
    running=true;window=0;assert.equal((await one('6'.repeat(32))).data.ownerVerified,false,'无有效窗口');
    window=77;boot='another-birth';assert.equal((await one('7'.repeat(32))).data.ownerVerified,false,'PID复用');
    boot='boot-19';srcActivity=501;assert.equal((await one('8'.repeat(32))).data.ownerVerified,false,'活动切换');
    srcActivity=500;simulate=()=>{child.pulsePrivate(host);alive=0;};
    assert.equal((await one('9'.repeat(32))).data.ownerVerified,false,'响应之后进程已退出');
    alive=1;simulate=()=>{child.pulsePrivate(host);ledger={...ledger,runNonce:'superseded'};};
    assert.equal((await one('a'.repeat(32))).data.ownerVerified,false,'响应后账本归属改变');
    ledger={...ledger,runNonce:boot};simulate=()=>{child.pulsePrivate(host);files.set(directory+'/closed.json','{}');};
    assert.equal((await one('b'.repeat(32))).data.ownerVerified,false,'结束会话与应答竞争');
    files.delete(directory+'/closed.json');
    simulate=()=>{child.pulsePrivate(host);Date.now=()=>now()+4000;};
    assert.equal((await one('c'.repeat(32))).data.ownerVerified,false,'刚回答时有效的挑战不能在过期后作证');
    Date.now=now;release();simulate=()=>child.pulsePrivate(host);
    assert.equal((await one('f'.repeat(32))).data.ownerVerified,false,'已销毁的 GameAbility 不继续回复');
    const initial=diskStats;
    assert.equal(child.armPrivate(context,{parameters:{}},500,'installed'),undefined);
    child.pulsePrivate(host);
    assert.equal(initial,diskStats,'正常游戏局不访问测试文件');
    const expired={...grant,expiresAt:now()-10};
    files.set(directory+'/grant.json',JSON.stringify(expired));files.set('/sandbox/amcl-qa-v1/session.json',JSON.stringify(expired));
    assert.equal(child.armPrivate(context,{parameters:params},500,'installed'),undefined,'过期授权不得建立子进程观察');
  } finally {globalThis.setTimeout=clock;Date.now=now;native.desktopProcessAlive=realAlive;ledger={...ledger,ownerPid:14};release();}
}
writesFail=true;assert.equal((await launch('d'.repeat(32))).status,'unknown');assert.equal(starts,2);
writesFail=false;directory='/sandbox/other';assert.equal(observer.current(),false);
assert.equal((await observe()).reason,'operation-not-found','跨会话请求不得读取旧活动');

function methods(path, struct, names, bindings){
  const text=readFileSync(new URL('../../'+path,import.meta.url),'utf8');
  const ast=ts.createSourceFile(path,text,ts.ScriptTarget.Latest,true);
  const owner=ast.statements.find(n=>n.name?.getText(ast)===struct);
  const source=names.map(name=>owner.members.find(n=>n.name?.getText(ast)===name).getText(ast)).join('\n');
  const js=ts.transpileModule('class Subject {'+source+'}\nmodule.exports=Subject;',{
    compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020},reportDiagnostics:true});
  assert.equal(js.diagnostics?.length??0,0);
  const module={exports:{}};new Function('module',...Object.keys(bindings),js.outputText)(module,...Object.values(bindings));
  return new module.exports();
}
let ready=true, currentAccount='account-A', called=0;
const page=methods('entry/src/main/ets/pages/Index.ets','Index',['gameAction_','startObservedGame_','launchScopeKey_','launchStillCurrent_'],{
  ProductQaGame:api,existingGameSessionHost:()=>undefined,getAccountManager:()=>({isReady:()=>ready,getSelectedId:()=>currentAccount})});
Object.assign(page,{context:{filesDir:'/sandbox'},launcherWorkVisible_:true,launcherWorkForeground_:true,
  versionAccess_:()=>({ready:()=>true}),
  currentTab:0,canRunGame_:true,mcRoot:()=>'/mc',mcVersion:'installed',availableVersions:['installed'],isMcDownloading_:()=>false,
  graphicsPreferenceStamp_:()=> 'effective-plan',versionIsolation:true,selectedJdkVersion:'auto',
  launchMC(o){called++;this.launchObservation_=o;this.launchScope_=this.launchScopeKey_();}});
function pageLaunch(n){return page.gameAction_('game.launch','{"versionId":"installed"}',n.toString(16).padStart(32,'0')).then(JSON.parse);}
page.currentTab=2;assert.equal((await pageLaunch(1)).reason,'launcher-not-foreground');page.currentTab=0;
ready=false;assert.equal((await pageLaunch(2)).reason,'launch-admission');ready=true;
page.versionAccess_=()=>({ready:()=>false});assert.equal((await pageLaunch(6)).reason,'launcher-unavailable');
page.versionAccess_=()=>({ready:()=>true});
page.mcVersion='different';assert.equal((await pageLaunch(3)).reason,'target-not-ready');page.mcVersion='installed';
page.showPreLaunchSheet=true;assert.equal((await pageLaunch(4)).reason,'launch-busy');page.showPreLaunchSheet=false;
assert.equal((await pageLaunch(5)).status,'accepted');assert.equal(called,1);
assert.equal(page.launchStillCurrent_(page.launchObservation_),true);
currentAccount='account-B';assert.equal(page.launchStillCurrent_(page.launchObservation_),false);
currentAccount='account-A';page.graphicsPreferenceStamp_=()=> 'changed-plan';assert.equal(page.launchStillCurrent_(page.launchObservation_),false);

let focused=0;
const original={isRunning:()=>true, sessionActivity:()=>500};
let privateOnly=false;
const resume=methods('entry/src/main/ets/pages/Index.ets','Index',['returnExistingGame_'],{
  existingGameSessionHost:()=>privateOnly?undefined:original,ledgerManifest:()=>ledger,
  LedgerState:{RUNNING:0},testNapi:{desktopProcessId:()=>14,desktopGameProcessState:()=>1}});
Object.assign(resume,{context:{filesDir:'/sandbox', startAbility:()=>assert.fail('未经身份核对的子进程')},
  mcVersion:'installed',mcRoot:()=>'/mc',getUIContext:()=>({getRouter:()=>({pushUrl:async()=>{focused++;}})})});
ledger.mcDir='/mc';
const existingId='e'.repeat(32);
const reuse=await launch(existingId,(_version,op)=>resume.returnExistingGame_(op));
assert.equal(reuse.data.activityId,500);assert.equal(reuse.reason,'existing-session-focused');assert.equal(focused,1);
privateOnly=true;
assert.equal((await launch('f'.repeat(32),(_version,op)=>resume.returnExistingGame_(op))).reason,'existing-session-identity-unverified');
assert.equal(focused,1);

const seen=[];
const sheet=methods('entry/src/main/ets/components/PreLaunchCheckSheet.ets','PreLaunchCheckSheet',
  ['aboutToAppear','setCheck','aboutToDisappear'],{LauncherSkillBus:makePureEtsLoader()('entry/src/main/ets/launcherskill/LauncherSkillBus.ets').LauncherSkillBus,AppLogger:{error(){},flush(){}},LOG_DOMAIN_LAUNCH:0});
const watched={check:(...v)=>seen.push(v)};let dismissed;
Object.assign(sheet,{observer:watched,checks:[],runAll(){},onDismissed:v=>{dismissed=v;}});
sheet.aboutToAppear();sheet.observer={check:()=>assert.fail('迟到结果认领了后来请求')};
sheet.setCheck(0,{id:'runtime',status:'fail',detail:'missing',fixActionKey:'download_jdk'});
sheet.aboutToDisappear();assert.equal(dismissed,watched);assert.deepEqual(seen,[['runtime','fail','download_jdk']]);
console.log('PASS game actions: real adapter, home admission, precheck observer, durable re-observe, renderer/session identity');
