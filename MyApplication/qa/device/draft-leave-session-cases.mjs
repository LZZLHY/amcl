// 使用三个真实编辑器的业务方法。把原生按钮、文件写入和事务恢复停在可观察的边界。
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {loadActionComponent} from '../../scripts/lib/unified-actions-fixture.mjs';
import {makePureEtsLoader} from '../../scripts/lib/load-pure-ets.mjs';
import {load,model,send,reply,context,grant,signal,root,dir,session,disk,installGrant} from './session-fixture.mjs';

const base='entry/src/main/ets/';
const busModule=load(base+'launcherskill/LauncherSkillBus.ets'),bus=busModule.LauncherSkillBus;
const kit={util:{generateRandomUUID:randomUUID}};
const draftModule=makePureEtsLoader({'@kit.ArkTS':kit})(base+'launcherskill/LayoutDraftAccess.ets');
const flush=()=>new Promise(resolve=>setImmediate(resolve));
const realClock=Date.now;
function deferred() {let finish;const work=new Promise(done=>{finish=done;});return {work,finish};}
function editor(name,methods,deps) {
  return loadActionComponent(base+'components/'+name+'.ets',name,{methods,dependencies:{
    '../launcherskill/LauncherSkillBus':busModule,'../launcherskill/LayoutDraftAccess':draftModule,
    '@kit.ArkTS':kit,'@kit.PerformanceAnalysisKit':{hilog:{error(){}}},...deps}});
}
function exportCase(write) {
  const E=editor('GameExportSheet',['skillExport_','requestClose_','requestLeave_','currentView_','activeTask_','editable_',
    'requestBack_','saveAndLeave_','saveDraft_','finishLeave_'],{
    '../export/GameExportCoordinator':{getGameExportCoordinator:()=>({saveDraft:async req=>{await write(req.versionId);}})}});
  const page=Object.assign(new E(),{versionId_:'test',loaded_:true,scanState_:'ready',source_:{},contentTree_:{},dirty_:true,
    busy_:false,savingLeave_:false,draftSaving_:false,showLeaveConfirm_:false,pageMotion_:{moving:false},taskState_:'',alive_:true,
    editRevision_:1,viewGeneration_:1,request_:()=>({versionId:'test'}),onClose(){this.closed=true;}});
  return {page,method:'discardExportEdits',domain:'gameExport',action:'skillExport_',args:{instance:'test'},
    save:()=>page.saveAndLeave_(),cancel:()=>page.requestBack_(),check(saved){assert.equal(!!page.closed,saved);assert.equal(page.dirty_,!saved);}};
}
function layoutCase(write,operation) {
  const store={getCurrentDeviceType:()=>'tablet',saveEditedProfile:async p=>{await write(p.name);return p;},
    commitEditorTransaction(){},endEditorSession(){}};
  const E=editor('LayoutEditor',['skillWorkbench_','requestSettings_','requestCancel_','saveEditor_','runPersistence_',
    'performPersistence_','completeEditor_','releaseEditorLease_','reportPersistenceError_','backEditor_'],{gamecontrol:{getLayoutStore:()=>store}});
  const draft=new draftModule.LayoutDraftAccess();draft.open();const stamp=draft.snapshot('changed');
  let modal;
  const page=Object.assign(new E(),{launcherWorkbench:true,editorMounted:true,editorReady:true,editorClosed:false,persistenceBusy:false,
    dragIdx:-1,playerDraft_:draft,editorGeneration:1,editorLeaseHeld:true,editorTransactionOwned:true,baselineSig:'original',
    nextSettingsSection:'',selectedItem:()=>null,contentSignature:()=>'changed',currentDeviceModel:()=>'tablet',
    buildProfile:()=>({name:'test',profileId:'layout',profileRevision:1}),getUIContext:()=>({showAlertDialog:d=>{modal=d;}}),
    onDone(){},onOpenSettings(){this.settingsOpened=true;}});
  return {page,method:'finishControlWorkbench',domain:'layoutWorkbench',action:'skillWorkbench_',args:{...stamp,decision:operation},
    save(){if(modal)modal.secondaryButton.action();else{page.showLeaveConfirm=false;page.saveEditor_();}
      return page.persistenceTask;},
    cancel(){if(modal){modal.primaryButton.action();modal.secondaryButton.action();}else page.backEditor_();},
    check(saved){assert.equal(page.editorClosed,saved);assert.equal(!!page.settingsOpened,operation==='input' && saved);}};
}
function inputCase(write) {
  const store={restoreEditorTransaction:async()=>{await write('restore');return true;},commitEditorTransaction(){},endEditorSession(){}};
  const E=editor('InputSettingsEditor',['playerInputAction_','dirty_','cancel_','run_','persist_','release_','keepEditing_',
    'aboutToDisappear','cleanup_'],{gamecontrol:{getLayoutStore:()=>store}});
  const draft=new draftModule.LayoutDraftAccess();draft.open();const profile={name:'changed'};const stamp=draft.snapshot(JSON.stringify(profile));
  const page=Object.assign(new E(),{launcherWorkbench:true,mounted:true,leaseHeld:true,busy:false,playerInput_:draft,original:{name:'prior'},
    baselineSig:JSON.stringify({name:'prior'}),touchBindingEditIndex:-1,gamepadBtnPicker:'',generation:1,buildProfile:()=>profile,onDone(){}});
  return {page,method:'finishInputWorkbench',domain:'inputWorkbench',action:'playerInputAction_',args:{...stamp,decision:'discard'},
    save(){page.run_(false);return page.pending;},cancel(){page.keepEditing_();},
    check(saved){assert.equal(!!page.completed,saved);}};
}

try {
  for(const make of [exportCase,w=>layoutCase(w,'discard'),w=>layoutCase(w,'input'),inputCase]) {
    for(const mode of ['save','cancel','expiry']) {
      const gate=deferred(),writes=[],owner={};
      const s=make(async value=>{writes.push(value);await gate.work;});
      let now=realClock();Date.now=()=>now;
      disk.clear();disk.set(root,null);
      installGrant({...grant,expiresAt:now+5000,actions:['skill.'+s.method]});
      bus.attach(owner,()=>true,randomUUID);bus.bind(s.domain,s.page,(n,a)=>s.page[s.action](n,a));
      const qa=model();qa.bind(owner,()=>{},()=>{});assert.equal(qa.activate(context,signal,false),true);
      send(1,'1'.repeat(32),'skill.'+s.method,s.args);await qa.tick();
      const received=reply(1);assert.equal(received.data.state,'needsUser',JSON.stringify(received));
      assert.equal(received.status,'needsUser');assert.deepEqual(writes,[]);
      if(mode==='expiry')now+=5500;else disk.set(root+'/close-'+session+'.txt',session);
      await qa.tick();assert.equal(disk.has(dir+'/closed.json'),false);
      const other={...grant,session:'9'.repeat(32),expiresAt:now+90000,actions:['skill.getLauncherState']};
      const wake={parameters:{amclQaSession:other.session}}; installGrant(other);assert.equal(qa.activate(context,wake,false),false);
      if(mode==='cancel') {s.cancel();assert.deepEqual(writes,[]);}
      else {
        const saving=s.save(); await flush();assert.equal(writes.length,1);
        await qa.tick();assert.equal(disk.has(dir+'/closed.json'),false);assert.equal(qa.activate(context,wake,false),false);
        gate.finish();await saving;
      }
      await flush();await qa.tick();assert.equal(disk.has(dir+'/closed.json'),true);
      assert.equal(qa.activate(context,wake,false),true);
      s.check(mode!=='cancel');assert.deepEqual(reply(1),received);
      bus.detach(owner);
    }
  }
} finally {Date.now=realClock;}
// 保存期间组件退场，原 store 写入结束后，组件还要恢复基线并归还租约。两次真实 Promise 分别阻止提前封账。
{
  const writes=[],first=deferred(),restore=deferred(),owner={};
  const s=inputCase(async v=>{writes.push(v);await (writes.length===1?first.work:restore.work);});
  bus.attach(owner,()=>true,randomUUID);bus.bind(s.domain,s.page,(n,a)=>s.page[s.action](n,a));
  disk.clear();disk.set(root,null);installGrant({...grant,actions:['skill.'+s.method]});
  const qa=model();qa.bind(owner,()=>{},()=>{});assert.equal(qa.activate(context,signal,false),true);
  send(1,'a'.repeat(32),'skill.'+s.method,s.args);await qa.tick();assert.equal(reply(1).data.surface,'unsavedDraft');
  const pending=s.save();s.page.aboutToDisappear();disk.set(root+'/close-'+session+'.txt',session);
  await qa.tick();assert.equal(disk.has(dir+'/closed.json'),false);assert.equal(writes.length,1);
  first.finish();await pending;await flush();
  assert.equal(writes.length,2);assert.equal(s.page.leaseHeld,true);
  await qa.tick();assert.equal(disk.has(dir+'/closed.json'),false);
  restore.finish();await s.page.cleanupTask;await qa.tick();
  assert.equal(s.page.leaseHeld,false);assert.equal(disk.has(dir+'/closed.json'),true);bus.detach(owner);
}
console.log('PASS export, layout and input draft choices: original consent, continued editing, pending write, closure and expiry');

// 直接保存预设会产生一个真实的活动副本。组件退场又通过同一 LayoutStore 恢复事务，
// 用两个独立的 Preferences.flush 暂停点核对：中间副本仍落盘时，不能交还设备会话。
for (const kind of ['input','layout']) for (const failRestore of [false,true]) {
  const cache=new Map(), durable=new Map(), gates=[], entered=[];
  const prefs={getSync:(key,fallback)=>cache.get(key)??fallback,get:async(key,fallback)=>prefs.getSync(key,fallback),
    putSync:(key,value)=>cache.set(key,value),put:async(key,value)=>cache.set(key,value),flush:async()=>{
      const snapshot=new Map(cache), barrier=gates.shift();
      if(barrier) {entered.push(barrier.phase);await barrier.work;if(barrier.fail)throw Error('fixture restore flush');}
      durable.clear();for(const [key,value] of snapshot)durable.set(key,value);
    }};
  const deps={'@kit.AbilityKit':{},'@kit.CoreFileKit':{fileIo:{}},'@kit.ArkTS':kit,
    '@kit.PerformanceAnalysisKit':{hilog:{info(){},error(){},warn(){}}},
    '@kit.ArkUI':{display:{getDefaultDisplaySync:()=>({width:2400,height:1600,densityPixels:2})}},
    '@kit.BasicServicesKit':{deviceInfo:{marketName:'fixture'}},commons:{AppLogger:{info(){},warn(){},error(){}},
      ProcessPreferences:{open:()=>prefs,isGameProcess:()=>false,discardGameLayoutChanges(){}},
      OwnerLayoutSourceRepository:{open:()=>null,openOrMigrate:()=>{throw Error('unexpected repository');}},utf8ByteLength:v=>Buffer.byteLength(v)}};
  const storeLoad=makePureEtsLoader(deps);Object.assign(deps.commons,storeLoad('commons/src/main/ets/utils/PreferenceSnapshot.ets'));
  const store=new (storeLoad('gamecontrol/src/main/ets/LayoutStore.ets').LayoutStore)();
  await store.init({});assert.equal(store.beginEditorSession(),true);store.beginEditorTransaction();
  const draft=new draftModule.LayoutDraftAccess();draft.open();
  const profile=store.getActiveProfile(),original=profile.name,originalBytes=durable.get('profiles'),baseline=JSON.stringify(profile);
  profile.invertY=!profile.invertY;
  const signature=JSON.stringify(profile),stamp=draft.snapshot(signature),input=kind==='input';
  const method=input?'finishInputWorkbench':'finishControlWorkbench',domain=input?'inputWorkbench':'layoutWorkbench';
  const methods=input?['playerInputAction_','run_','persist_','aboutToDisappear','cleanup_','release_']:
    ['skillWorkbench_','saveEditor_','runPersistence_','performPersistence_','aboutToDisappear','cleanupDestroyedEditor_',
     'restoreUnfinishedEditor_','restoreUnfinishedEditorOnce_','releaseEditorLease_','reportPersistenceError_'];
  const E=editor(input?'InputSettingsEditor':'LayoutEditor',methods,{gamecontrol:{getLayoutStore:()=>store}});
  const page=Object.assign(new E(),{launcherWorkbench:true,buildProfile:()=>profile,onDone(){assert.fail('retired UI');}},
    input?{mounted:true,leaseHeld:true,busy:false,playerInput_:draft,baselineSig:baseline,original:profile,
      touchBindingEditIndex:-1,gamepadBtnPicker:'',generation:1}:{editorMounted:true,editorReady:true,editorClosed:false,persistenceBusy:false,
      dragIdx:-1,playerDraft_:draft,editorGeneration:1,editorLeaseHeld:true,editorTransactionOwned:true,baselineSig:baseline,
      nextSettingsSection:'',selectedItem:()=>null,contentSignature:()=>signature,currentDeviceModel:()=>'tablet'});
  const owner={},save={phase:'save',...deferred()},restore={phase:'restore',fail:failRestore,...deferred()};
  gates.push(save,restore);disk.clear();disk.set(root,null);installGrant({...grant,actions:['skill.'+method]});
  bus.attach(owner,()=>true,randomUUID);bus.bind(domain,page,(name,args)=>page[methods[0]](name,args));
  const qa=model();qa.bind(owner,()=>{},()=>{});assert.equal(qa.activate(context,signal,false),true);
  send(1,'1'.repeat(32),'skill.'+method,{...stamp,decision:'save'});const issued=qa.tick();await flush();
  assert.deepEqual(entered,['save']);page.aboutToDisappear();
  disk.set(root+'/close-'+session+'.txt',session);await qa.tick();assert.equal(disk.has(dir+'/closed.json'),false);
  save.finish();await issued;await flush();assert.deepEqual(entered,['save','restore']);
  const interim=durable.get('active_profile');assert.notEqual(interim,original);assert.notEqual(durable.get('profiles'),originalBytes);
  assert.equal(reply(1).data.state,'unknown');assert.equal(store.isEditorActive(),true);
  const other={...grant,session:'d'.repeat(32),actions:['skill.getLauncherState']};installGrant(other);
  const wake={parameters:{amclQaSession:other.session}};
  await qa.tick();assert.equal(disk.has(dir+'/closed.json'),false);assert.equal(qa.activate(context,wake,false),false);
  restore.finish();await (page.cleanupTask??page.editorCleanupTask);await qa.tick();
  assert.equal(input?page.leaseHeld:page.editorLeaseHeld,false);
  assert.equal(store.isEditorActive(),failRestore);assert.equal(disk.has(dir+'/closed.json'),true);
  assert.equal(qa.activate(context,wake,false),true);
  // 回滚失败留下受保护的原快照，旧组件已无在途写。只有明确再次请求恢复才能修改落盘副本。
  if (failRestore) {
    const retained=durable.get('profiles');await flush();assert.equal(durable.get('profiles'),retained);
    assert.equal(durable.get('active_profile'),interim);assert.equal(await store.restoreEditorTransaction(),true);
  }
  assert.equal(durable.get('active_profile'),original);assert.equal(durable.get('profiles'),originalBytes);
  assert.equal(store.isEditorActive(),false);
  assert.equal(reply(1).data.state,'unknown');bus.detach(owner);
}
console.log('PASS direct layout/input saves: real durable clone, rollback flush, failure and lease release before QA replacement');
