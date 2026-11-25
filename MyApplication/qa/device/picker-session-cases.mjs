// 从真实系统选择入口到原业务所有者，验证专用回执与设备会话各自的完成条件。
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {verifySkillCases} from '../../scripts/lib/skill-business-check.mjs';
import {loadActionComponent} from '../../scripts/lib/unified-actions-fixture.mjs';
import {makePureEtsLoader} from '../../scripts/lib/load-pure-ets.mjs';
import {load,model,send,reply,context,grant,signal,root,dir,session,disk,installGrant} from './session-fixture.mjs';

const folder='entry/src/main/ets/';
const busModule=load(folder+'launcherskill/LauncherSkillBus.ets'),bus=busModule.LauncherSkillBus;
const values=load(folder+'launcherskill/SettingsSkillValues.ets');
const tick=()=>new Promise(resolve=>setImmediate(resolve));
function gate() {
  let finish;
  const promise=new Promise(resolve=>{finish=resolve;});
  return {promise,finish};
}

function jdk(flow) {
  const Index=loadActionComponent(folder+'pages/Index.ets','Index',{methods:['importLocalJdk_','chooseAndImportLocalJdk_'],globals:{TAG:'fixture'},
    dependencies:{commons:{SUPPORTED_JDK_VERSIONS:['17'],AppLogger:{info(){},warn(){}},LOG_DOMAIN_LAUNCH:0},
      '../components/GameArchiveIO':{GameArchiveIO:{importResourceFile:()=>flow.pick.promise}},
      launch:{JdkImporter:{importFromZip:async (_ctx,major)=>{flow.writes.push(major);await flow.admit.promise;return {ok:true,message:'fixture',stamp:'memory'};}}},
      '@kit.CoreFileKit':{fileIo:{unlinkSync(){}}}}});
  const index=Object.assign(new Index(),{jdkImporting:false,theme:{},context:{filesDir:'/memory'},showToast_(){},updateJdkReadyState(){},
    getUIContext:()=>({getPromptAction:()=>({showActionMenu:async()=>({index:0})})})});
  const Tab=loadActionComponent(folder+'pages/tabs/DownloadTab.ets','DownloadTab',{methods:['runtimeSkill_','runtimeSkillActive_'],
    dependencies:{'../../launcherskill/SettingsSkillValues':values,'../../launcherskill/LauncherSkillBus':busModule}});
  const tab=Object.assign(new Tab(),{hostVisible:true,dlSubTab:5,skillInteractive:()=>true,slotDialogBusy_:false,jdkChecking:false,jdkImporting:false,
    jdkActionEpoch_:0,importRef_:'',importOutcome_:{state:'unavailable'},onJdkImport:()=>index.importLocalJdk_()});
  return {domain:'runtimeSlots',action:'pickJavaRuntimeArchive',query:'readJavaArchiveImport',args:{},key:'reference',
    selection:{ok:true,cancelled:false,name:'demo.zip'},writes:['17'],run:(n,a)=>tab.runtimeSkill_(n,a)};
}

function update(flow) {
  const saved=flow.saved??new Map();
  const deps={'@kit.ArkTS':{util:{generateRandomUUID:randomUUID}},'./LauncherSkillBus':busModule,
    'commons':{AtomicFileWriter:{write:(p,v)=>saved.set(p,v)}},
    '@kit.CoreFileKit':{fileIo:{accessSync:p=>saved.has(p),statSync:p=>({size:saved.get(p)?.length??0}),readTextSync:p=>saved.get(p)}}};
  function bindReader() {
    // 重新装载模拟更新后的新进程。通过真首页绑定读取，安装页也不需要启动旧软件更新页。
    const receipt=makePureEtsLoader(deps)(folder+'launcherskill/UpdatePackageSelection.ets');
    const Host=loadActionComponent(folder+'pages/Index.ets','Index',{methods:['bindShellSkills_'],
      globals:{AppStorage:{get:()=>true}},dependencies:{'../launcherskill/LauncherSkillBus':busModule,'../launcherskill/UpdatePackageSelection':receipt,
        '../launcherskill/SupportRoutes':{},'../launcherskill/EvidenceChoiceResult':{},
        '@kit.ArkTS':{util:{generateRandomUUID:randomUUID}},commons:{DistributionPolicy:{isStore:()=>false}}}});
    const host=Object.assign(new Host(),{context,startupAlive_:true,launcherInitializationComplete_:true,startupFinished_:true,
      bindLayoutSkill_() {}});
    host.bindShellSkills_();return {host,receipt};
  }
  const {host,receipt}=bindReader();
  const Page=loadActionComponent(folder+'pages/SoftwareUpdatePage.ets','SoftwareUpdatePage',{methods:['updateSkill_','skillActive_','importPackage','onPageHide'],
    globals:{AppStorage:{get:()=>true}},dependencies:{'../launcherskill/LauncherSkillBus':busModule,'../launcherskill/SettingsSkillValues':values,
      '../launcherskill/UpdatePackageSelection':receipt,
      '@kit.CoreFileKit':{picker:{DocumentViewPicker:class{select(){return flow.pick.promise;}}}},
      commons:{DistributionPolicy:{isStore:()=>false}},'entry/ProductBuildProfile':{ProductBuildProfile:{product:'default'}},
      update:{UpdateChecker:{targetKey:()=> 'target'}},'../sideload/SideloadUpdateService':{SideloadUpdateService:{
        get:()=>({preparePickedPackage:async()=>{flow.writes.push('prepare');await flow.admit.promise;if(flow.badPackage)throw Error('invalid package');return {manifest:{},token:'memory'};}})}}}});
  const page=Object.assign(new Page(),{visible:true,requirementValid:true,skillDialog_:false,checking:false,importing:false,generation:0,
    context,channel:'stable',requiredHostProtocols:[],getUIContext:()=>({getRouter:()=>({pushUrl:async route=>{
      assert.equal(route.params.autoStart,true);flow.writes.push('route');page.onPageHide();
    }})})});
  return {domain:'softwareUpdate',action:'openUpdateSource',query:'readUpdatePackageSelection',args:{source:'localPackage'},key:'reference',
    host,bindReader,available:()=>page.visible,
    selection:['/memory/owned.hap'],writes:['prepare','route'],run:(n,a)=>page.updateSkill_(n,a)};
}

function evidence(flow) {
  const choice=makePureEtsLoader({'@kit.ArkTS':{util:{generateRandomUUID:randomUUID}},'./LauncherSkillBus':busModule})
    (folder+'launcherskill/EvidenceChoiceResult.ets').EvidenceChoiceResult;
  return {domain:'activity',action:'requestActivityRemoval',query:'getActivityChoiceOutcome',args:{activityId:13},key:'operationRef',
    queryArgs:ref=>({activityId:13,operationRef:ref}),selection:true,writes:['removed'],run:async(n,args)=>{
      if (n==='getActivityChoiceOutcome') return choice.read(args);
      return choice.begin(13,n,async()=>{await flow.pick.promise;flow.writes.push('removed');await flow.admit.promise;
        return {state:'ready',removed:true};});
    }};
}
const realClock=Date.now;
try {
  for (const factory of [jdk,update,evidence]) for (const expire of [false,true]) {
    const flow={pick:gate(),admit:gate(),writes:[]},item=factory(flow),owner={};
    let now=realClock();Date.now=()=>now;
    const named='skill.'+item.action,query='skill.'+item.query;
    function start(actions) {
      disk.clear(); disk.set(root,null); installGrant({...grant,expiresAt:now+1000,actions});
      const q=model();q.bind(owner,()=>{},()=>{});
      assert.equal(q.activate(context,signal,false),true);return q;
    }
    let sequence=0;
    async function call(q,action,args) {
      sequence++;send(sequence,sequence.toString(16).padStart(32,'0'),action,args);
      await q.tick();return reply(sequence);
    }
    if(factory!==update) bus.attach(owner,()=>true,randomUUID);
    bus.bind(item.domain,owner,item.run,item.available);
    if(factory===evidence) bus.bind('evidenceReceipt',owner,item.run);
    const qa=start([named,query]);
    const first=await call(qa,named,item.args);await tick();
    assert.equal(first.status,'needsUser');
    const ref=first.data[item.key];assert.ok(ref);
    const args=item.queryArgs?.(ref) ?? {reference:ref};
    const wait=await call(qa,query,args);
    assert.ok(['waiting','needsUser'].includes(wait.data.state)); assert.deepEqual(flow.writes,[]);
    if(expire) now+=2000; else disk.set(root+'/close-'+session+'.txt',session);
    await qa.tick();assert.equal(disk.has(dir+'/closed.json'),false);
    flow.pick.finish(item.selection);await tick();await qa.tick();
    assert.equal(disk.has(dir+'/closed.json'),false,'owner is still committing the user choice');
    flow.admit.finish();await tick();await qa.tick();
    assert.deepEqual(flow.writes,item.writes);assert.equal(JSON.parse(disk.get(dir+'/closed.json')).closed,true);
    assert.deepEqual(reply(1),first);
    // 新会话即使持有专用读权限和同一真实引用，也不能读回未经该会话授权的原操作。
    sequence=0;
    const later=start([query]);
    assert.equal((await call(later,query,args)).status,'rejected');
    bus.detach(item.host??owner);
  }
} finally {Date.now=realClock;}
console.log('PASS original JDK/update pickers and activity choice retain their own receipts and hold QA through close and expiry');

// 真实选择动作从进入选择器到跳转隐藏原页；专用读绑定可跨路由与新进程回读且不复派。
{
  const saved=new Map(),cases=[];
  for (const expected of ['accepted','cancelled','failed']) {
    const flow={saved,pick:gate(),admit:gate(),writes:[],badPackage:expected==='failed'},item=update(flow);
    bus.bind(item.domain,item.host,item.run,item.available);
    const start=await bus.call(item.domain,item.action,item.args);
    const args={reference:start.reference};
    const read=()=>bus.call('updatePackageReceipt',item.query,args);
    assert.equal((await read()).state,'waiting');
    flow.pick.finish(expected==='cancelled'?[]:item.selection);flow.admit.finish();await tick();
    const outcome=await read();assert.equal(outcome.state,expected);
    if(expected==='accepted'){assert.equal(item.available(),false);assert.equal(outcome.target,'target');}
    cases.push({args,outcome});
    bus.detach(item.host);
    const later=item.bindReader();
    for (const old of cases) assert.deepEqual(await bus.call('updatePackageReceipt',item.query,old.args),old.outcome);
    assert.deepEqual(flow.writes,expected==='accepted'?['prepare','route']:expected==='failed'?['prepare']:[]);
    bus.detach(later.host);
  }
  verifySkillCases('readUpdatePackageSelection',cases[0].outcome,cases[2].outcome,'L079');
}


// 保存选择器仍归 QA 发起的原意图；协调器受理并返回任务号后，后台任务归产品所有者，可独立继续。
{
  const owner={},pick=gate(),background=gate(),preview={};
  let queued=0,finished=false;
  const coordinator={pickAndStart:async()=>{
    await pick.promise;queued++;
    background.promise.then(()=>{finished=true;});return 'owned-export';
  }};
  const Sheet=loadActionComponent(folder+'components/GameExportSheet.ets','GameExportSheet',{
    methods:['skillExport_','start_'],dependencies:{'../launcherskill/LauncherSkillBus':busModule,'@kit.ArkTS':{util:{generateRandomUUID:randomUUID}},
      '../export/GameExportCoordinator':{getGameExportCoordinator:()=>coordinator}}
  });
  const sheet=Object.assign(new Sheet(),{versionId_:'fixture',loaded_:true,source_:{},scanState_:'ready',contentTree_:{},
    step_:1,previewReady_:true,skillPlan_:preview,preview_:preview,skillPlanRef_:'plan',viewGeneration_:1,
    busy_:false,editable_:()=>true,activeTask_:()=>false,context_:{},currentView_:()=>true,refreshTask_(){},syncNavigation_(){}});
  bus.attach(owner,()=>true,randomUUID);bus.bind('gameExport',sheet,(n,a)=>sheet.skillExport_(n,a));
  disk.clear();disk.set(root,null); installGrant({...grant,actions:['skill.startExport']});
  const q=model();q.bind(owner,()=>{},()=>{});assert.equal(q.activate(context,signal,false),true);
  send(1,'7'.repeat(32),'skill.startExport',{instance:'fixture',plan:'plan'});await q.tick();
  assert.equal(reply(1).data.surface,'savePicker',JSON.stringify(reply(1)));disk.set(root+'/close-'+session+'.txt',session);
  await q.tick();assert.equal(disk.has(dir+'/closed.json'),false);assert.equal(queued,0);
  pick.finish();await tick();await q.tick();
  assert.equal(sheet.skillPicker_,'accepted');assert.equal(queued,1);
  assert.equal(disk.has(dir+'/closed.json'),true);assert.equal(finished,false);
  background.finish();await tick();assert.equal(finished,true);bus.detach(owner);
}
console.log('PASS game export holds the original picker until queue admission, not background execution');
