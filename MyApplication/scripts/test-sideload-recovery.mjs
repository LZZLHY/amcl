/**
 * 真正Coordinator/Repository持久恢复回归，安装边界只提供结构化观测。
 * 原旧CLI返回+版本匹配的“成功”断言已由强身份与一次性执行权同时确认取代。
 */
import assert from 'node:assert/strict';
import {fixture,record,settle,payload} from './lib/sideload-coordinator-fixture.mjs';

// 两次同大小坏包都运行真实SHA并失效，重试不会由size永久复用。
{
 const f=await fixture({delayDownload:true}),ui=f.render();await settle();
 const original=f.kitfs.readSync;
 f.kitfs.readSync=(fd,buffer,options)=>{const n=original(fd,buffer,options);if(n>0)new Uint8Array(buffer)[0]^=1;return n;};
 f.coordinator.setAbilityForeground(false);f.fetchGate.resolve();await settle();assert.equal(ui.phase,'failed');
 ui.start();await settle();assert.equal(f.counters.download,2);assert.equal(f.kitfs.accessSync(f.coordinator.state().unsignedPath),false);
 ui.dispose();console.log('recovery: repeated bad digest invalidates actual file');
}
// schema1原字节保留，返回对象不可改内部；CAS与专用EX必须真实拒绝旧修订/重入。
{
 const source=record(),f=await fixture({journal:source}),state=f.coordinator.state();assert.equal(state.schema,2);assert.equal(state.revision,1);
 assert.equal(f.kitfs.readTextSync('/sandbox/sideload-update/transaction-schema1-'+source.id+'.json'),JSON.stringify(source));
 state.phase='failed';assert.equal(f.coordinator.state().phase,'verified');
 const {SideloadTransactionRepository:Repo}=f.load('entry/src/main/ets/sideload/SideloadTransactionRepository.ets'),repo=new Repo('/sandbox/sideload-update',false);
 assert.throws(()=>repo.commit(f.coordinator.state(),0),/修订改变/);
 const lock=f.kitfs.openSync('/sandbox/sideload-update/.sideload-transaction.lock',10);lock.tryLock(true);
 assert.throws(()=>repo.load(),/正在提交/);f.kitfs.closeSync(lock);
 console.log('recovery: original schema1 retained, immutable state and locked revision commit');
}
// legacy没有新CAS证明，只有已装身份也不能清fence；错载荷不确认。
{
 const f=await fixture({journal:record('installing')});f.environment.version=2;f.environment.payload=payload;
 f.coordinator.setAbilityForeground(true);f.coordinator.recover();await settle();
 assert.equal(f.coordinator.state().installedIdentityVerified,true);assert.equal(f.coordinator.state().phase,'confirmation-pending');
 assert.equal(f.kitfs.accessSync('/sandbox/sideload-update/install-fence.json'),true);assert.equal(f.coordinator.needsAttention(),true);
 const bad=await fixture({journal:record('installing')});bad.environment.version=2;bad.environment.payload='f'.repeat(40);bad.coordinator.recover();
 assert.notEqual(bad.coordinator.state().installedIdentityVerified,true);
 console.log('recovery: legacy identity cannot substitute system execution proof');
}
// v2真正终态proof+新进程目标身份才封主成功；普通异常/cancel不抢先封账。
{
 const f=await fixture(),ui=f.render();await settle();assert.equal(f.counters.dispatch,1);const task=f.coordinator.state();
 f.coordinator.finishAttempt('ambiguous disconnect');assert.equal(f.rows.get(task.activityId).state,0);
 f.environment.version=2;f.environment.payload=payload;
 f.setObservation({kind:'bms-success',safeToRelease:true,bmSubmitted:true,code:0,message:'trusted fixture terminal',installId:task.installId,nonce:task.restartNonce});
 f.coordinator.recover(task.installId,task.restartNonce);await settle();
 assert.equal(f.coordinator.state().phase,'verified');assert.equal(f.kitfs.accessSync('/sandbox/sideload-update/install-fence.json'),false);
 assert.equal(f.rows.get(task.activityId).state,1);assert.equal(f.counters.dispatch,1);
 ui.cancel();assert.equal(f.coordinator.state().phase,'verified');ui.dispose();
 console.log('recovery: typed terminal plus actual target closes current owner once');
}
// 主活动与下载子活动独立，取消不改已经核验成功的下载结果。
{
 const f=await fixture({delayDownload:true}),ui=f.render();await settle();f.coordinator.setAbilityForeground(false);f.fetchGate.resolve();await settle();
 const download=f.coordinator.downloadView(),parent=f.coordinator.activityId();
 assert.notEqual(parent,download.startedAtMs);assert.equal(f.rows.get(parent).state,0);assert.equal(f.rows.get(download.startedAtMs).state,1);
 assert.equal(f.rows.get(download.startedAtMs).parentActivityId,parent);assert.equal(f.core.DownloadTaskRegistry.instance().get(download.id),download);
 ui.cancel();await settle();assert.equal(f.rows.get(parent).state,3);assert.equal(f.rows.get(download.startedAtMs).state,1);ui.dispose();
 console.log('recovery: parent/child outcomes and stable unified progress identities');
}
console.log('sideload-recovery: real persistent owner regression groups passed');
