/** 真正自更新所有者的时序回归；平台边界见共享fixture，输出严格外置。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {fixture,record,deferred,settle,target,manifest,payload,sha} from './lib/sideload-coordinator-fixture.mjs';
/**
 * 平台调用的真实入口计数就是本组的到达证据；固定setImmediate次数不能证明异步下载、
 * 账本关闭与签名准备已经完成。保留原计数读写语义，只将首次到达目标值转换为Promise。
 */
function counterReached(counters,name,expected){
 const reached=deferred();let value=counters[name];
 Object.defineProperty(counters,name,{configurable:true,enumerable:true,get:()=>value,set(next){value=next;if(next>=expected)reached.resolve();}});
 if(value>=expected)reached.resolve();return reached.promise;
}
/** 限时只负责真实停滞时报错，不作为成功等待；错误保留实际公开快照与事务事实。 */
async function boundedBoundary(promise,f,label){
 let timeout;try{await Promise.race([promise,new Promise((_,reject)=>{timeout=setTimeout(()=>reject(new Error(
  label+'未到达；snapshot='+JSON.stringify(f.coordinator.snapshot())+' transaction='+JSON.stringify(f.coordinator.state()))),10000);})]);}
 finally{clearTimeout(timeout);}
}
/** 只订阅生产公开快照；Failed/working解除的实际发布才结束等待，不写owner私有字段。 */
function snapshotReached(coordinator,predicate){
 const reached=deferred();let remove,done=false;
 const listener=value=>{if(!done&&predicate(value)){done=true;reached.resolve();remove?.();}};
 remove=coordinator.subscribe(listener);if(done)remove();return reached.promise;
}
// 旧Verified+真实满队列：新轮投影Queued并可取消，UI关闭后不会继续下载。
{
 const f=await fixture({journal:record()});f.core.DownloadTaskRegistry.instance().maxConcurrent=1;
 const hold=deferred(),view=new f.core.UnifiedTaskView();view.id='peer';
 const peer=f.core.DownloadTaskRegistry.instance().enqueue({view,async start(){await hold.promise;view.state='done';},async cancel(){},async pause(){},async resume(){},async retry(){},dispose(){}});
 const ui=f.render();await settle();assert.equal(ui.phase,'queued');assert.equal(ui.working,true);
 ui.cancel();ui.dispose();await settle();hold.resolve();await peer;await settle();
 assert.equal(f.counters.download,0);assert.equal(f.coordinator.snapshot().phase,'cancelled');
 assert.equal([...f.rows.values()].filter(r=>r.category==='app_update').at(-1).state,3);
 console.log('coordinator: previous Verified + queued cancellation truly stops owner');
}
// 专属订阅与真实detach：A卸载只影响A，B继续收到下载状态，且detach不隐式取消。
{
 const f=await fixture({delayDownload:true}),a=f.render(),b=f.render(false);await settle();a.dispose();
 f.coordinator.setAbilityForeground(false);f.fetchGate.resolve();await settle();
 assert.equal(b.phase,'downloaded');assert.equal(f.counters.download,1);assert.equal(f.counters.dispatch,0);
 b.cancel();b.dispose();console.log('coordinator: owned subscriptions, detach and background separated');
}
// 后台签名真失败仍Failed，提供材料恢复动作，不会永久working。
{
 const f=await fixture({delaySign:true,signFailure:true}),entered=counterReached(f.counters,'sign',1),ui=f.render();
 await boundedBoundary(entered,f,'Native签名入口');assert.equal(f.counters.sign,1);
 const failed=snapshotReached(f.coordinator,value=>value.phase==='failed'&&!value.working&&value.needsImport);
 f.coordinator.setAbilityForeground(false);f.signGate.resolve();await boundedBoundary(failed,f,'后台签名失败收尾');
 assert.equal(ui.phase,'failed');assert.equal(ui.working,false);assert.equal(ui.needsImport,true);
 assert.match(ui.message,/签名/);assert.equal(f.counters.dispatch,0);ui.dispose();
 console.log('coordinator: background real signing failure remains recoverable Failed');
}
// 真实完整Writer成功短写循环写全；rename前失败不抢先改旧持久事务/内存。
{
 const f=await fixture({journal:record()}),before=f.coordinator.state();f.faults.rename=true;const ui=f.render();await settle();
 assert.equal(ui.phase,'storage-blocked');assert.equal(f.coordinator.state().phase,before.phase);
 assert.equal(JSON.parse(f.kitfs.readTextSync('/sandbox/sideload-update/transaction.json')).phase,before.phase);
 assert.equal(f.counters.prepare,0);ui.dispose();
 const g=await fixture();g.faults.shortWrite=true;const v=g.render();g.coordinator.setAbilityForeground(false);await settle();
 assert.equal(g.coordinator.state().phase,'downloaded');
 assert.equal(JSON.parse(g.kitfs.readTextSync('/sandbox/sideload-update/transaction.json')).asset.sha256,sha);
 v.cancel();v.dispose();console.log('repository: commit-before-memory and actual AtomicWriter short writes');
}
// 冷启动legacy Pending在Native租约处阻止新文件执行，无新manifest也有恢复入口。
{
 const f=await fixture({journal:record('installing')});assert.equal(f.coordinator.needsAttention(),true);
 let started=0;const view=new f.core.UnifiedTaskView();view.id='new-peer';
 await assert.rejects(f.core.DownloadTaskRegistry.instance().enqueue({view,async start(){started++;},async cancel(){},async pause(){},async resume(){},async retry(){},dispose(){}}));
 assert.equal(started,0);assert.equal(f.coordinator.state().phase,'confirmation-pending');
 console.log('coordinator: restored legacy Pending blocks file start before effects');
}
// APP_UPDATE取消只开放ExternalUpdateFlow，Registry不会运行不存在的内部retry。
{
 const f=await fixture(),registry=f.core.DownloadTaskRegistry.instance();registry.maxConcurrent=1;
 const hold=deferred(),view=new f.core.UnifiedTaskView();view.id='peer';
 const peer=registry.enqueue({view,async start(){await hold.promise;view.state='done';},async cancel(){},async pause(){},async resume(){},async retry(){},dispose(){}});
 const {SideloadDownloadTask}=f.load('entry/src/main/ets/sideload/SideloadDownloadTask.ets');
 const task=new SideloadDownloadTask('/sandbox',sha,'fixture',1,async()=>{},()=>{},()=>{});
 const queued=registry.enqueue(task).catch(()=>{});await registry.cancel(task.view.id);await queued;
 assert.equal(task.view.canRetry,false);assert.equal(task.view.canRecoverExternally,true);
 await assert.rejects(registry.retry(task.view.id),/完整/);hold.resolve();await peer;
 console.log('registry: stable external recovery capability after queued cancellation');
}
// 前置完成顺序/重复start与派发unknown：始终只一个sign和dispatch，未知不重派。
{
 const f=await fixture({delayConnect:true}),ui=f.render();await settle();
 assert.equal(ui.phase,'downloaded');assert.equal(f.counters.sign,0);ui.start();
 f.connectionGate.resolve('A'.repeat(64));await settle();
 assert.equal(f.counters.sign,1);assert.equal(f.counters.dispatch,1);
 await f.coordinator.reconcileInstallation();assert.equal(f.coordinator.state().phase,'confirmation-pending');
 ui.start();await settle();assert.equal(f.counters.dispatch,1);ui.dispose();
 console.log('coordinator: download first, duplicate starts, OutcomeUnknown never re-dispatch');
}
// 账号与连接先完成仍等原件；后台正常签名只等待前台，不重新签名。
{
 const f=await fixture({delayDownload:true,delaySign:true}),ui=f.render();await settle();
 assert.equal(ui.accountReady,true);assert.equal(f.counters.sign,0);
 f.fetchGate.resolve();await settle();assert.equal(f.counters.sign,1);
 f.coordinator.setAbilityForeground(false);f.signGate.resolve();await settle();
 assert.equal(f.coordinator.state().phase,'ready');assert.equal(f.counters.dispatch,0);
 f.coordinator.setAbilityForeground(true);await settle();
 assert.equal(f.counters.sign,1);assert.equal(f.counters.dispatch,1);ui.dispose();
 console.log('coordinator: prerequisites first and normal background Ready handoff');
}
// 未登录/已过期与网络不可用区分，关闭登录不取消原件，整轮取消挡晚成功。
for(const account of ['missing','expired','unavailable']){
 const f=await fixture({account,delayDownload:true}),ui=f.render();await settle();
 if(account==='unavailable'){assert.equal(ui.loginVisible,false);assert.equal(ui.accountRetry,true);}
 else {assert.equal(ui.loginVisible,true);assert.match(ui.loginReason,account==='expired'?/过期/:/尚未/);ui.closeLogin();}
 f.fetchGate.resolve();await settle();assert.equal(f.counters.download,1);assert.equal(f.counters.sign,0);
 ui.cancel();f.authorize();await settle();assert.equal(f.counters.dispatch,0);ui.dispose();
}
console.log('coordinator: missing/expired/unavailable, login close and late cancelled callback');
// 签名显式cancel与detach不等价；JVM晚返回也不能准备/安装，推进锁最终可释放。
{
 const f=await fixture({delaySign:true}),ui=f.render();await settle();assert.equal(f.counters.sign,1);
 ui.cancel();ui.dispose();f.signGate.resolve();await settle();
 assert.equal(f.counters.dispatch,0);assert.equal(f.coordinator.isBusy(),false);assert.equal(f.coordinator.state().phase,'cancelled');
 console.log('coordinator: explicit cancellation blocks late signing result');
}
// 热Ready换材重签：真实Vault新recordId改变revision，原件仍复用。
{
 const f=await fixture({delaySign:true}),ui=f.render();await settle();f.coordinator.setAbilityForeground(false);f.signGate.resolve();await settle();
 assert.equal(f.coordinator.state().phase,'ready');const old=f.coordinator.state().materialRevision;
 await f.vault.importBundle(JSON.stringify({schema:1,keyAlias:'fixture',keyPassword:'changed-test-only',storePassword:'test-only',signAlg:'SHA256withECDSA',
  p12Base64:Buffer.from('p12 fixture').toString('base64'),certificateBase64:Buffer.from('cert fixture').toString('base64'),profileBase64:Buffer.from('profile fixture').toString('base64')}));
 assert.notEqual(await f.vault.materialRevision(),old);f.coordinator.setAbilityForeground(true);await settle();
 assert.equal(f.counters.sign,2);assert.equal(f.counters.download,1);assert.equal(f.counters.dispatch,1);ui.dispose();
 console.log('coordinator: hot Ready changed private material re-signs without redownload');
}
// signing阶段事务提交失败亦finally解busy，可以进入真正核实，不永久占用。
{
 const f=await fixture({signCommitFailure:true}),ui=f.render();await settle();
 assert.equal(ui.phase,'storage-blocked');assert.equal(f.coordinator.isBusy(),false);assert.equal(f.counters.sign,0);ui.dispose();
 console.log('coordinator: signing checkpoint failure always releases busy');
}
// 用户选择导入正在加密时取消：beforeCommit阻止写入，不能覆写新轮材料。
{
 const f=await fixture({delayDownload:true}),ui=f.render();await settle();f.coordinator.setAbilityForeground(false);f.fetchGate.resolve();await settle();
 const original=f.kitfs.readTextSync('/sandbox/sideload-update/signing-vault.json'),gate=deferred();f.setEncryptionGate(gate);
 const material=JSON.stringify({schema:1,keyAlias:'fixture',keyPassword:'old-operation',storePassword:'test-only',signAlg:'SHA256withECDSA',
  p12Base64:Buffer.from('other p12').toString('base64'),certificateBase64:Buffer.from('cert fixture').toString('base64'),profileBase64:Buffer.from('profile fixture').toString('base64')});
 fs.writeFileSync(f.mapped('/sandbox/picked-material.json'),material);
 const importing=f.coordinator.importPickedMaterial('/sandbox/picked-material.json');await settle();assert.equal(f.coordinator.isBusy(),true);
 ui.cancel();gate.resolve();await importing;assert.equal(f.kitfs.readTextSync('/sandbox/sideload-update/signing-vault.json'),original);ui.dispose();
 console.log('coordinator: material encryption operation owns busy and late commit is rejected');
}
// Runtime新绑定保留同Attempt许可但只由新展示面继续，旧窗口事件不能放行安装。
{
 const f=await fixture({delayDownload:true}),old=f.render();await settle();const before=f.coordinator.runtime();
 const nextContext={...f.context};f.storage.set('uiAbilityContext',nextContext);f.coordinator.bindRuntime(nextContext);
 assert.equal(f.coordinator.runtime(),before+1);old.onForeground();f.coordinator.setAbilityForeground(true);
 f.fetchGate.resolve();await settle();assert.equal(f.counters.dispatch,0);
 const {SideloadUpdateViewModel}=f.load('entry/src/main/ets/sideload/SideloadUpdateViewModel.ets'),current=new SideloadUpdateViewModel();
 current.initialize(nextContext,{manifest,autoStart:false});current.onForeground();await settle();
 assert.equal(f.counters.download,1);assert.equal(f.counters.dispatch,1);old.dispose();current.dispose();
 console.log('coordinator: Runtime generation and reattached owner resume same verified original');
}
// 真正SigningService在RPC途中认证失效：材料不造假，重新登录后走原云端链继续原件。
{
 const f=await fixture({expireMaterialFirst:true}),ui=f.render();await settle();
 assert.equal(ui.loginVisible,true);assert.match(ui.loginReason,/过期/);assert.equal(ui.working,true);assert.equal(f.counters.dispatch,0);
 f.authorize();await settle();assert.equal(f.counters.download,1);assert.equal(f.counters.keygen,1);assert.equal(f.counters.dispatch,1);ui.dispose();
 console.log('coordinator: actual SigningService expired RPC resumes same attempt after login');
}
// 组件UUID席位：旧实例晚释放不能解除新owner或占第二个席位。
{
 const f=await fixture(),{UpdatePromptPresenter:P}=f.load('entry/src/main/ets/components/UpdatePromptPresenter.ets');
 assert.equal(P.claim('index-a'),true);P.release('index-a');assert.equal(P.claim('index-b'),true);
 P.release('index-a');assert.equal(P.owns('index-b'),true);assert.equal(P.claim('about-c'),false);P.forget('index-b');
 console.log('presenter: per-instance owner cannot release rebuilt surface');
}
// 同Attempt关闭/重新登录：旧begin的成功、拒绝和回调都不能盖写新登录展示或关闭新对象。
{
 for(const staleOutcome of ['https://cn.devecostudio.huawei.com/old-login',new Error('late begin fixture')]){
  const f=await fixture({account:'missing',delayDownload:true,delayLoginBegin:true}),ui=f.render();await settle();
  const first=f.authBegins[0];assert.equal(ui.loginBusy,true);ui.closeLogin();
  const reopening=f.coordinator.login();await settle();const second=f.authBegins[1];
  assert.notEqual(second.auth,first.auth);second.gate.resolve('https://cn.devecostudio.huawei.com/current-login');await reopening;
  const expected=f.coordinator.snapshot(),closes=second.auth.closeCount;
  first.gate.resolve(staleOutcome);await settle();f.authorize(0);first.callback(false,'迟到失败');await settle();
  assert.equal(ui.loginUrl,expected.loginUrl);assert.equal(ui.loginMessage,expected.loginMessage);
  assert.equal(ui.loginVisible,true);assert.equal(ui.loginBusy,true);assert.equal(ui.accountReady,false);
  assert.equal(second.auth.closeCount,closes);assert.equal(f.counters.dispatch,0);
  f.authorize(1);await settle();assert.equal(ui.accountReady,true);assert.equal(ui.loginVisible,false);
  // 已消费的登录终态不能再用旧URL返回或重复失败把成功改回待登录。
  second.callback(false,'重复失败');await settle();assert.equal(ui.accountReady,true);assert.equal(ui.loginVisible,false);
  ui.cancel();f.fetchGate.resolve();await settle();ui.dispose();
 }
 console.log('coordinator: late begin after close/reopen cannot mutate new login effect');
}
// Runtime换代：旧begin结算不能通过this.auth getter关闭新Context的会话，原Attempt仍等新登录。
{
 const f=await fixture({account:'missing',delayDownload:true,delayLoginBegin:true}),old=f.render();await settle();
 const first=f.authBegins[0],attempt=f.coordinator.snapshot().attemptId,nextContext={...f.context};
 f.storage.set('uiAbilityContext',nextContext);f.coordinator.bindRuntime(nextContext);f.coordinator.setAbilityForeground(true);
 const {SideloadUpdateViewModel}=f.load('entry/src/main/ets/sideload/SideloadUpdateViewModel.ets'),current=new SideloadUpdateViewModel();
 current.initialize(nextContext,{manifest,autoStart:false});current.onForeground();
 const reopened=f.coordinator.login();await settle();const second=f.authBegins[1];
 assert.equal(second.auth.context,nextContext);assert.notEqual(second.auth,first.auth);
 second.gate.resolve('https://cn.devecostudio.huawei.com/rebound-login');await reopened;
 const closes=second.auth.closeCount,expected=f.coordinator.snapshot();first.gate.resolve('https://cn.devecostudio.huawei.com/old-runtime');await settle();
 f.authorize(0);first.callback(false,'旧运行环境失败');await settle();
 assert.equal(current.loginUrl,expected.loginUrl);assert.equal(current.loginMessage,expected.loginMessage);
 assert.equal(current.accountReady,false);assert.equal(second.auth.closeCount,closes);
 assert.equal(f.coordinator.snapshot().attemptId,attempt);assert.equal(f.counters.dispatch,0);
 f.authorize(1);await settle();assert.equal(current.accountReady,true);assert.equal(current.loginVisible,false);
 current.cancel();f.fetchGate.resolve();await settle();old.dispose();current.dispose();
 console.log('coordinator: Runtime late login effect cannot close current AuthSession');
}
// 普通UI包装Context只消费canonical Entry：不换代/不清当前展示，不关闭授权；跨files调用拒绝。
{
 const f=await fixture({account:'missing'}),ui=f.render();await settle();
 const {SideloadUpdateCoordinator:C}=f.load('entry/src/main/ets/sideload/SideloadUpdateCoordinator.ets'),generation=f.coordinator.runtime(),login=f.authBegins.at(-1);
 assert.equal(C.get({...f.context}),f.coordinator);assert.equal(C.get({...f.context}),f.coordinator);
 assert.equal(f.coordinator.runtime(),generation);assert.equal(ui.runtimeRetired,false);assert.equal(login.auth.closeCount,1);
 assert.throws(()=>C.get({...f.context,filesDir:'/other'}),/存储身份/);assert.equal(f.coordinator.runtime(),generation);
 const {SideloadUpdateViewModel:VM}=f.load('entry/src/main/ets/sideload/SideloadUpdateViewModel.ets'),foreign=new VM();
 assert.throws(()=>foreign.initialize({...f.context,filesDir:'/other'},{manifest,autoStart:false}),/存储身份/);
 assert.equal(f.coordinator.runtime(),generation);foreign.dispose();
 f.authorize();await settle();assert.equal(f.counters.download,1);assert.equal(f.counters.sign,1);assert.equal(f.counters.dispatch,1);ui.dispose();
 console.log('runtime: same Entry wrappers retain presentation and authorization, foreign files rejected');
}
// 真正新Entry使旧投影立刻退役：所有写命令无效，也不再显示新Runtime账号成功或旧连接成功文案。
{
 const f=await fixture({account:'missing'}),old=f.render();await settle();const attempt=f.coordinator.snapshot().attemptId;
 const next={...f.context};f.storage.set('uiAbilityContext',next);f.coordinator.bindRuntime(next);await settle();
 assert.equal(old.runtimeRetired,true);assert.equal(old.accountReady,false);assert.doesNotMatch(f.coordinator.snapshot().connectionMessage,/已通过/);
 const before=f.coordinator.state(),material=f.kitfs.readTextSync('/sandbox/sideload-update/signing-vault.json'),calls={...f.counters},authCount=f.authSessions.length;
 old.onForeground();old.onBackground();old.start();old.checkAccount();old.checkConnection();old.retryConnection(true);old.openDebugSettings();
 old.login();old.closeLogin();old.loginFailed('旧网页错误');old.renewMaterial();old.reconcile();old.cancel();await old.importMaterial();await settle();
 assert.deepEqual(f.coordinator.state(),before);assert.deepEqual(f.counters,calls);assert.equal(f.authSessions.length,authCount);
 assert.equal(f.kitfs.readTextSync('/sandbox/sideload-update/signing-vault.json'),material);
 const {SideloadUpdateViewModel:VM}=f.load('entry/src/main/ets/sideload/SideloadUpdateViewModel.ets'),current=new VM();
 current.initialize(next,{manifest,autoStart:false});f.coordinator.setAbilityForeground(true);current.onForeground();await settle();f.authorize();await settle();
 assert.equal(current.accountReady,true);assert.equal(old.accountReady,false);assert.equal(f.coordinator.snapshot().attemptId,attempt);
 assert.equal(f.counters.sign,1);assert.equal(f.counters.dispatch,1);old.dispose();current.dispose();
 console.log('runtime: genuine rebound retires all old writes and resumes same attempt through current surface');
}
// 实际Content生命周期方法：PAUSED即使showing/focused都true也关门；RESUMED+真实焦点恢复只推进一次。
{
 const f=await fixture({account:'missing'}),host=f.mountContent();f.coordinator.setAbilityForeground(true);await settle();
 host.facts.focused=true;host.stage('PAUSED');host.focus('WINDOW_ACTIVE');f.authorize();host.retry();await settle();
 assert.equal(host.view.accountReady,true);assert.equal(f.counters.connections,0);assert.equal(f.counters.sign,0);assert.equal(f.counters.dispatch,0);
 host.stage('RESUMED');host.focus('WINDOW_ACTIVE');host.retry();await settle();
 assert.equal(f.counters.connections,1);assert.equal(f.counters.sign,1);assert.equal(f.counters.dispatch,1);host.dispose();
 const g=await fixture({account:'valid'}),hidden=g.mountContent({showing:false,focused:true});g.coordinator.setAbilityForeground(true);hidden.stage('RESUMED');hidden.retry();await settle();
 assert.equal(g.counters.connections,0);assert.equal(g.counters.dispatch,0);hidden.dispose();
 console.log('window: actual Content PAUSED/hidden guards and RESUMED focus recover exactly one dispatch');
}
// 新Runtime的检查等待旧check和异步close均收敛，不能复用旧检查成功或让迟到close撞新host。
{
 const f=await fixture({delayConnect:true,delayClose:true}),old=f.render();await settle();assert.equal(f.counters.connections,1);
 const next={...f.context};f.storage.set('uiAbilityContext',next);f.coordinator.bindRuntime(next);
 const {SideloadUpdateViewModel:VM}=f.load('entry/src/main/ets/sideload/SideloadUpdateViewModel.ets'),current=new VM();
 current.initialize(next,{manifest,autoStart:false});f.coordinator.setAbilityForeground(true);current.onForeground();await settle();
 assert.equal(f.counters.connections,1);assert.equal(f.counters.closeSettled,0);
 f.connectionGate.resolve('A'.repeat(64));await settle();assert.equal(f.counters.connections,1);assert.equal(current.connectionReady,false);assert.equal(f.counters.sign,0);
 f.closeGate.resolve();await settle();assert.equal(f.counters.closeSettled>=1,true);assert.equal(f.counters.connections,2);
 assert.equal(f.counters.sign,1);assert.equal(f.counters.dispatch,1);old.dispose();current.dispose();
 console.log('runtime: new connection starts only after old check and close settle');
}
/**
 * AA 回调采用独立 installId，不能与缓存事务 id 混用。使用真实 Repository 加载完整当前记录；
 * updatedAt 保持在五分钟以内，只有真实 recover 唤醒才能让以下观察计数立即增长。
 */
function pendingAaRecord(){
 const now=Date.now();return{...record('installing'),schema:2,revision:1,ownerAttemptId:'e'.repeat(32),
  installId:'a'.repeat(32),installProtocol:2,beforeVersionCode:1,createdAt:now-2000,updatedAt:now-1000};
}
/** 平台终态属于本次执行者；真实 Core 决定是否可完成，测试不直接写 installedIdentityVerified。 */
function aaProof(task,kind,safeToRelease){return{kind,safeToRelease,bmSubmitted:true,
 code:kind==='bms-failure'?1:0,message:'受控安装终态',installId:task.installId,nonce:task.restartNonce};}

// 仍运行原版本时，匹配 AA 立即走既有 revoke/observe 裁决；真实 BMS 失败安全结束，无第二次安装。
{
 const task=pendingAaRecord(),f=await fixture({journal:task});f.setObservation(aaProof(task,'bms-failure',true));
 f.coordinator.setAbilityForeground(true);f.coordinator.recover(task.installId,task.restartNonce);
 assert.equal(f.counters.revoke,1,'匹配 AA 必须在 recover 返回前启动既有核实，不等待五分钟');
 await settle();assert.equal(f.counters.observe,1);assert.equal(f.coordinator.state().phase,'failed');
 assert.notEqual(f.coordinator.state().installedIdentityVerified,true);assert.equal(f.counters.complete,1);
 assert.equal(f.counters.dispatch,0);assert.equal(f.counters.prepare,0);assert.equal(f.counters.download,0);
 assert.equal(f.counters.sign,0);assert.equal(f.coordinator.snapshot().working,false);
 console.log('recover: matching AA on original version immediately observes BMS failure without new update permission or dispatch');
}
// post 尚待重采只变 Pending；下一次严格匹配的 AA 可再次观察，不造成功、不重新执行 bm。
{
 const task=pendingAaRecord(),f=await fixture({journal:task});f.setObservation(aaProof(task,'unknown',false));
 f.coordinator.setAbilityForeground(true);f.coordinator.recover(task.installId,task.restartNonce);await settle();
 assert.equal(f.counters.observe,1);assert.equal(f.coordinator.state().phase,'confirmation-pending');
 assert.notEqual(f.coordinator.state().installedIdentityVerified,true);assert.equal(f.counters.complete,0);
 f.setObservation(aaProof(task,'bms-failure',true));f.coordinator.recover(task.installId,task.restartNonce);await settle();
 assert.equal(f.counters.observe,2);assert.equal(f.coordinator.state().phase,'failed');
 assert.equal(f.counters.dispatch,0);assert.equal(f.counters.prepare,0);
 console.log('recover: matching AA recollects pending post evidence and never promotes unknown to success or re-dispatch');
}
// 错误 nonce、别轮 installId、缓存目录 id 和普通旧版重开均不能触发核实、提交确认或改变许可。
{
 for(const input of ['wrong-nonce','foreign-install','cache-id','empty']){
  const task=pendingAaRecord(),f=await fixture({journal:task}),before=f.coordinator.state();
  f.setObservation(aaProof(task,'bms-failure',true));f.coordinator.setAbilityForeground(true);
  const id=input==='foreign-install'?'f'.repeat(32):input==='cache-id'?task.id:input==='empty'?'':task.installId;
  const nonce=input==='wrong-nonce'?'f'.repeat(32):input==='empty'?'':task.restartNonce;
  f.coordinator.recover(id,nonce);await settle();
  assert.equal(f.counters.revoke,0);assert.equal(f.counters.observe,0);assert.equal(f.counters.dispatch,0);
  assert.deepEqual(f.coordinator.state(),before);assert.equal(f.coordinator.snapshot().working,false);
 }
 console.log('recover: wrong nonce, foreign execution, cache transaction id and empty old-version launch never wake reconciliation');
}
// 后台 AA 只保留核实意图。真实 VM/Ability 前台入口仍按既有 Guard 唤醒同一观察，不授予安装许可。
{
 const task=pendingAaRecord(),f=await fixture({journal:task});f.setObservation(aaProof(task,'bms-failure',true));
 f.coordinator.recover(task.installId,task.restartNonce);await settle();assert.equal(f.counters.revoke,0);
 const {SideloadUpdateViewModel:VM}=f.load('entry/src/main/ets/sideload/SideloadUpdateViewModel.ets'),ui=new VM();
 ui.initialize(f.context,{autoStart:false});ui.onForeground();await settle();assert.equal(f.counters.observe,0);
 f.coordinator.setAbilityForeground(true);ui.onForeground();await settle();
 assert.equal(f.counters.observe,1);assert.equal(ui.phase,'failed');assert.equal(ui.working,false);
 assert.equal(f.counters.dispatch,0);assert.equal(f.counters.prepare,0);ui.dispose();
 console.log('recover: background callback waits for real Ability/VM foreground guard then reconciles without install permission');
}
// BMS 成功也不能代替目标身份；逐项改变真实 bundle/resource 边界，唯一成功标志仍由 confirms 设置。
{
 for(const facts of [{version:1,uid:42,payload},{version:2,uid:43,payload},{version:2,uid:42,payload:'wrong'}]){
  const task=pendingAaRecord(),f=await fixture({journal:task});Object.assign(f.environment,facts);
  f.setObservation(aaProof(task,'bms-success',true));f.coordinator.setAbilityForeground(true);
  f.coordinator.recover(task.installId,task.restartNonce);await settle();
  assert.equal(f.counters.observe,1);assert.equal(f.coordinator.state().phase,'confirmation-pending');
  assert.notEqual(f.coordinator.state().installedIdentityVerified,true);assert.equal(f.counters.complete,0);
  // 真实目标版本、UID、载荷全部成立时，原有无 Want 的跨版本冷启动确认路径仍可完成。
  Object.assign(f.environment,{version:2,uid:42,payload});f.coordinator.recover();await settle();
  assert.equal(f.coordinator.state().installedIdentityVerified,true);assert.equal(f.coordinator.state().phase,'verified');
  assert.equal(f.counters.complete,1);assert.equal(f.counters.dispatch,0);assert.equal(f.counters.prepare,0);
 }
 console.log('recover: BMS success requires real version UID and payload; matching AA alone never marks old or mismatched identity successful');
}
/**
 * 已装身份与安装执行权可以分时成立：目标进程 1000686 先通过真实 recover/Repository
 * 保存版本、UID、编译载荷确认，但平台 BMS 观察仍 unknown；随后维修版 1000687 冷启动
 * 只核实原执行权。这里从原进程实际写盘结果创建独立 fixture/模块单例，模拟跨进程恢复，
 * 不直接赋值 installedIdentityVerified，也不把 1000687 的新载荷当成 1000686。
 * BMS 是平台替身；该用例验证真实 Core/Policy/Repository 只消费原事务与原 AA 凭据，
 * 完结时不重新下载、签名或安装。真实 Executor 的日志证明仍由其独立测试和真机验证。
 */
{
 const task=pendingAaRecord();task.beforeVersionCode=1000685;task.asset.versionCode=1000686;
 const original=await fixture({journal:task});
 Object.assign(original.environment,{version:1000686,uid:task.beforeUid,payload:task.expectedPayloadIdentity});
 original.setObservation(aaProof(task,'unknown',false));original.coordinator.setAbilityForeground(true);
 original.coordinator.recover(task.installId,task.restartNonce);await settle();
 assert.equal(original.coordinator.state().phase,'confirmation-pending');
 assert.equal(original.coordinator.state().installedIdentityVerified,true);
 assert.equal(original.counters.observe,1);assert.equal(original.counters.complete,0);
 const persisted=JSON.parse(original.kitfs.readTextSync('/sandbox/sideload-update/transaction.json'));
 assert.equal(persisted.installedIdentityVerified,true,'历史目标确认必须来自实际 Repository 提交');
 const repaired=await fixture({journal:persisted}),newPayload='f'.repeat(40);
 Object.assign(repaired.environment,{version:1000687,uid:task.beforeUid,payload:newPayload});
 const {SideloadTransactionPolicy:Policy}=repaired.load('update/src/main/ets/SideloadTransactionPolicy.ets');
 assert.equal(Policy.confirms(repaired.coordinator.state(),1000687,task.beforeUid,newPayload,task.installId,task.restartNonce),false,
  '维修版版本和载荷不能重新确认旧目标');
 assert.equal(repaired.coordinator.state().installedIdentityVerified,true);
 repaired.setObservation(aaProof(task,'bms-success',true));repaired.coordinator.setAbilityForeground(true);
 repaired.coordinator.recover(task.installId,task.restartNonce);await settle();
 const verified=JSON.parse(repaired.kitfs.readTextSync('/sandbox/sideload-update/transaction.json'));
 assert.equal(verified.phase,'verified');assert.equal(verified.installedIdentityVerified,true);
 for(const key of ['id','ownerAttemptId','installId','installProtocol','asset','beforeVersionCode','beforeUid',
  'expectedPayloadIdentity','restartNonce','signedPath','signedSha256'])assert.deepEqual(verified[key],persisted[key],key+' 必须保持原事务身份');
 assert.equal(repaired.counters.observe,1);assert.equal(repaired.counters.complete,1);
 assert.equal(repaired.counters.download,0);assert.equal(repaired.counters.sign,0);
 assert.equal(repaired.counters.prepare,0);assert.equal(repaired.counters.dispatch,0);
 // 同样的维修版和原 AA/BMS 成功，若没有历史目标确认，仍必须保持 Pending。
 const unconfirmed=await fixture({journal:task});
 Object.assign(unconfirmed.environment,{version:1000687,uid:task.beforeUid,payload:newPayload});
 unconfirmed.setObservation(aaProof(task,'bms-success',true));unconfirmed.coordinator.setAbilityForeground(true);
 unconfirmed.coordinator.recover(task.installId,task.restartNonce);await settle();
 assert.equal(unconfirmed.coordinator.state().phase,'confirmation-pending');
 assert.notEqual(unconfirmed.coordinator.state().installedIdentityVerified,true);
 assert.equal(unconfirmed.counters.complete,0);assert.equal(unconfirmed.counters.dispatch,0);
 console.log('recover: repair 1000687 closes original 1000686 only with persisted genuine identity and original BMS proof; no identity rewrite or second dispatch');
}
console.log('sideload-coordinator: complete real implementation timing regressions passed');
