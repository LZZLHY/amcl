/**
 * 自更新活动关联回归：执行真实Activity/Core/VM/Repository，平台边界使用既有共享fixture。
 * 新请求、原失败重试与下载子活动分别核实；所有模拟I/O仍外置，不改任何历史设备账本。
 */
import assert from 'node:assert/strict';
import {fixture,settle,deferred,manifest,payload,target} from './lib/sideload-coordinator-fixture.mjs';
const states={SUCCESS:1,FAILED:2,ABORTED:3,INTERRUPTED:5};
const row=f=>f.rows.get(f.coordinator.activityId());
const independent=m=>{assert.equal(m.parentActivityId||0,0);assert.equal(m.relation||'','');};
/** 生成明确不同asset，versionName刻意不改，证明关系不靠显示名称猜测。 */
function nextManifest(changes={}){
 const tag='v3.0.0',name='amcl-'+tag+'-sideload-unsigned.hap';
 const asset={...target,tag,name,versionCode:3,url:'https://github.com/LZZLHY/amcl/releases/download/'+tag+'/'+name,
  websiteUrl:'https://amcl.lovedhy.cn/api/packages/files/'+target.sha256+'/'+name,
  mirrors:[{provider:'miawa',projectId:'amcl',ready:true,filePath:'amcl/'+tag+'/'+name}],...changes};
 return{...manifest,...asset,versionName:manifest.versionName,delivery:{schema:1,ready:true,assets:[asset]}};
}
/** 新投影采用真实VM和onShown，不能直接调用私有开账逻辑冒充首页首次请求。 */
function mount(f,params){const {SideloadUpdateViewModel:VM}=f.load('entry/src/main/ets/sideload/SideloadUpdateViewModel.ets');
 const ui=new VM();ui.initialize(f.context,params);f.coordinator.setAbilityForeground(true);ui.onForeground();return ui;}

// 成功checkpoint跨Activity重建仍不成为重试来源，即便调用方错误提供旧SUCCESS身份。
{
 const f=await fixture(),{SideloadUpdateActivity:A}=f.load('entry/src/main/ets/sideload/SideloadUpdateActivity.ets');
 const checkpoint='/sandbox/sideload-update/activity-relation-test.json',first=new A('/sandbox',checkpoint);
 const previous=first.begin('相同显示标题');await first.finishAsync(states.SUCCESS,'真实测试成功');
 const history=JSON.stringify(f.rows.get(previous)),rebuilt=new A('/sandbox',checkpoint);
 assert.equal(rebuilt.activityId(),previous);const current=rebuilt.begin('相同显示标题',0,0,previous);
 assert.notEqual(current,previous);independent(f.rows.get(current));assert.equal(JSON.stringify(f.rows.get(previous)),history);
 const running=JSON.stringify(f.rows.get(current));assert.equal(rebuilt.begin('重复入口',0,0,previous),current);
 rebuilt.resume();assert.equal(f.rows.get(current).parentActivityId||0,0);assert.equal(f.rows.get(current).relation||'','');
 assert.equal(JSON.parse(running).title,f.rows.get(current).title);
 console.log('activity: persisted SUCCESS never becomes retry; RUNNING begin/resume retains current independent identity');
}
// 失败/取消/中断必须同时有明确原身份；普通下一次请求不隐式关联，显式下载parent保持download。
{
 for(const state of [states.FAILED,states.ABORTED,states.INTERRUPTED]){
  const f=await fixture(),{SideloadUpdateActivity:A}=f.load('entry/src/main/ets/sideload/SideloadUpdateActivity.ets');
  const checkpoint='/sandbox/sideload-update/activity-relation-test.json',first=new A('/sandbox',checkpoint);
  const previous=first.begin('原失败');await first.finishAsync(state,'原终态');const history=JSON.stringify(f.rows.get(previous));
  const ordinary=new A('/sandbox',checkpoint),id=ordinary.begin('新的独立请求');independent(f.rows.get(id));
  await ordinary.finishAsync(state,'又一明确终态');const retry=new A('/sandbox',checkpoint),retryId=retry.begin('显式重试',0,0,id);
  assert.equal(f.rows.get(retryId).parentActivityId,id);assert.equal(f.rows.get(retryId).relation,'retry');
  const download=new A('/sandbox','','app_update_download'),child=download.begin('原件下载',retryId);
  assert.equal(f.rows.get(child).parentActivityId,retryId);assert.equal(f.rows.get(child).relation,'download');
  assert.equal(JSON.stringify(f.rows.get(previous)),history);
 }
 console.log('activity: only explicit failed/aborted/interrupted origins produce retry; download parent remains explicit');
}
// 原活动被删、错类或不属于当前checkpoint时，提示不能伪造来源关系。
{
 for(const fault of ['missing','category','foreign']){
  const f=await fixture(),{SideloadUpdateActivity:A}=f.load('entry/src/main/ets/sideload/SideloadUpdateActivity.ets');
  const a=new A('/sandbox'),old=a.begin('原尝试');await a.finishAsync(states.FAILED,'失败');
  if(fault==='missing')f.rows.delete(old);if(fault==='category')f.rows.get(old).category='download';
  const next=a.begin('新尝试',0,0,fault==='foreign'?old+100:old);independent(f.rows.get(next));
 }
 console.log('activity: missing, foreign and category-mismatched origin hints never forge a retry relation');
}
// 真正Core由目标进程确认成功后，新VM首次onShown请求不同版本必须开独立主活动。
{
 const f=await fixture(),oldUi=f.render();await settle();const task=f.coordinator.state();
 Object.assign(f.environment,{version:2,payload});f.setObservation({kind:'bms-success',safeToRelease:true,bmSubmitted:true,
  code:0,message:'明确平台测试终态',installId:task.installId,nonce:task.restartNonce});
 f.coordinator.recover(task.installId,task.restartNonce);await settle();assert.equal(f.coordinator.state().phase,'verified');
 const oldId=task.activityId,history=JSON.stringify(f.rows.get(oldId));oldUi.dispose();
 const next=mount(f,{manifest:nextManifest(),autoStart:true});next.onShown();await settle();
 assert.notEqual(f.coordinator.activityId(),oldId);independent(row(f));assert.equal(JSON.stringify(f.rows.get(oldId)),history);
 const download=f.coordinator.downloadView();assert.equal(f.rows.get(download.startedAtMs).parentActivityId,f.coordinator.activityId());
 assert.equal(f.rows.get(download.startedAtMs).relation,'download');next.dispose();
 console.log('core: actual Verified followed by first VM request is independent; download child still belongs to its current parent');
}
// 相同asset的显式按钮重试关联原FAILED；首次弹窗自动请求、不同asset和过时原活动提示均独立。
{
 for(const mode of ['explicit','first-auto','different-version','different-sha','foreign-id','legacy-no-digest']){
  const f=await fixture({signFailure:true}),oldUi=f.render();await settle();
  assert.equal(f.coordinator.state().phase,'failed');const origin=f.coordinator.activityId(),history=JSON.stringify(f.rows.get(origin));
  if(mode==='explicit')oldUi.start();
  else if(mode==='first-auto'){const ui=mount(f,{manifest,autoStart:true});ui.onShown();}
  else if(mode==='different-version')mount(f,{manifest:nextManifest(),autoStart:false}).start();
  else if(mode==='different-sha'){
   const changed={...target,sha256:'a'.repeat(64),websiteUrl:'https://amcl.lovedhy.cn/api/packages/files/'+'a'.repeat(64)+'/'+target.name};
   mount(f,{manifest:{...manifest,delivery:{schema:1,ready:true,assets:[changed]}},autoStart:false}).start();
  }else if(mode==='foreign-id')f.coordinator.requestUpdate({manifest},origin+100);
  else{const legacy={...manifest};delete legacy.delivery;mount(f,{manifest:legacy,autoStart:false}).start();}
  await settle();assert.notEqual(f.coordinator.activityId(),origin);
  if(mode==='explicit'){assert.equal(row(f).parentActivityId,origin);assert.equal(row(f).relation,'retry');}
  else independent(row(f));
  assert.equal(JSON.stringify(f.rows.get(origin)),history);oldUi.dispose();
 }
 console.log('core: retry requires explicit current origin and full matching asset; first-auto, different version/SHA, stale id and unbound legacy remain independent');
}
// 公开beginAttempt同样统一核实，不能通过直接提供retryOf绕过当前完整目标与原活动绑定。
{
 for(const mode of ['same-target','different-version-name','stale-origin','no-intent']){
  const f=await fixture({signFailure:true}),ui=f.render();await settle();
  assert.equal(f.coordinator.state().phase,'failed');const origin=f.coordinator.activityId(),history=JSON.stringify(f.rows.get(origin));
  const version=mode==='different-version-name'?'3.0.0':manifest.versionName;
  const requested=mode==='stale-origin'?origin+100:mode==='no-intent'?0:origin;
  f.coordinator.beginAttempt(version,true,requested);const next=f.coordinator.activityId();assert.notEqual(next,origin);
  if(mode==='same-target'){assert.equal(row(f).parentActivityId,origin);assert.equal(row(f).relation,'retry');}
  else independent(row(f));
  assert.equal(JSON.stringify(f.rows.get(origin)),history);ui.dispose();
 }
 console.log('core: public beginAttempt cannot bypass target/origin binding; same-target explicit retry remains available');
}
// 同ID忙态由真实Activity等待异步端口；失败原件能跨对象恢复，旧结果不得污染新attempt。
{
 const f=await fixture(),{SideloadUpdateActivity:A}=f.load('entry/src/main/ets/sideload/SideloadUpdateActivity.ets');
 const checkpoint='/sandbox/sideload-update/activity-pending-test.json',activity=new A('/sandbox',checkpoint);
 const id=activity.begin('原更新'),gate=deferred();f.faults.ledgerGate=gate;
 const pending=activity.finishAsync(states.SUCCESS,'已核实成功');
 assert.equal(activity.finishAsync(states.SUCCESS,'其他显示文案'),pending,'同终态合并同一收尾Promise');
 assert.equal(activity.isRunning(),true);assert.throws(()=>activity.begin('新更新'),/保存结果/);
 const raw=f.kitfs.readTextSync('/sandbox/logs/ledger/'+id+'/update-terminal.json');
 f.faults.ledgerEnd=true;gate.resolve();await assert.rejects(pending,/IO/);
 assert.equal(activity.isRunning(),true);assert.equal(f.rows.get(id).state,0);
 const restored=new A('/sandbox',checkpoint);assert(restored.hasPendingTerminal());
 f.faults.ledgerEnd=false;f.faults.ledgerGate=undefined;await restored.waitForFinishAsync();
 assert.equal(f.rows.get(id).state,1);assert.equal(restored.isRunning(),false);
 assert.equal(f.kitfs.readTextSync('/sandbox/logs/ledger/'+id+'/update-terminal.json'),raw,'重试不改原结局时间');
 const next=restored.begin('新更新');assert.notEqual(next,id);assert.equal(f.rows.get(next).state,0);
 console.log('activity: async close merge, durable failure retry and restored fixed outcome');
}
// 权威BMS事实先持久，日志失败保留Verified/fence；重试日志后才complete同一安装执行权。
{
 const f=await fixture(),ui=f.render();await settle();const task=f.coordinator.state(),gate=deferred();
 f.faults.ledgerGate=gate;f.environment.version=2;f.environment.payload=payload;
 f.setObservation({kind:'bms-success',safeToRelease:true,bmSubmitted:true,code:0,message:'明确平台终态',installId:task.installId,nonce:task.restartNonce});
 f.coordinator.recover(task.installId,task.restartNonce);await settle();
 assert.equal(f.coordinator.state().phase,'verified');assert.equal(f.counters.complete,0);
 assert(f.kitfs.accessSync('/sandbox/sideload-update/install-fence.json'));
 f.faults.ledgerEnd=true;gate.resolve();await settle();
 assert.equal(f.coordinator.state().phase,'verified','日志IO不改写权威安装结果');assert.equal(f.counters.complete,0);
 assert.deepEqual(Array.from(f.coordinator.recoverActivity()),[task.activityId],'待保存终态获stale豁免');
 await settle();f.faults.ledgerEnd=false;f.faults.ledgerGate=undefined;await f.coordinator.reconcileInstallation();
 assert.equal(f.rows.get(task.activityId).state,1);assert.equal(f.counters.complete,1);
 assert.equal(f.kitfs.accessSync('/sandbox/sideload-update/install-fence.json'),false);assert.equal(f.counters.dispatch,1);ui.dispose();
 console.log('core: authoritative Verified survives ledger IO, fence releases only after async terminal retry');
}
// 下载Promise等待日志关闭，但已验证原件的SUCCESS不因该关闭故障变成下载ERROR。
{
 const f=await fixture(),{SideloadDownloadTask:T}=f.load('entry/src/main/ets/sideload/SideloadDownloadTask.ets'),gate=deferred();
 f.faults.ledgerGate=gate;f.faults.ledgerEnd=true;
 const task=new T('/sandbox','fixed-source','下载终态',1,async()=>{},()=>{},()=>{});let settled=false;
 const pending=task.start().then(()=>{settled=true;});await settle();
 assert.equal(settled,false);assert.equal(task.view.state,'done');gate.resolve();await pending;
 assert.equal(task.view.state,'done');assert.equal(f.rows.get(task.view.startedAtMs).state,0);
 const raw=JSON.parse(f.kitfs.readTextSync('/sandbox/logs/ledger/'+task.view.startedAtMs+'/update-terminal.json'));
 assert.equal(raw.category,'app_update_download');assert.equal(raw.state,1);
 assert.equal(raw.runNonce,f.rows.get(task.view.startedAtMs).runNonce);
 console.log('download: actual async close awaited, IO failure preserves verified SUCCESS and bound recovery receipt');
}
console.log('sideload-activity-relations: real Activity/Core/VM source regressions passed');
