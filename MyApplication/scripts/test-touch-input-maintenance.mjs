/**
 * 纯Native会话维护scope的生产回归。只注入Native和平台日志；若共同模块反向导入
 * 前端/gyro/layout，严格模块夹具立即失败。正例与撤回负例均执行真实生产实现。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {makePureEtsLoader} from './lib/load-pure-ets.mjs';

const relative='entry/src/main/ets/components/EntryTouchInputMaintenance.ets';
// 变异锚点针对源码逻辑，Windows正常CRLF检出不能使已有负控失去目标。
// 仅规范测试内文本副本；不改生产字节，不跳过成功转译后的行为断言。
const original=fs.readFileSync(path.resolve(import.meta.dirname,'..',relative),'utf8').replace(/\r\n/g,'\n');

/** 每例独立模块单例；未知依赖不提供兜底，Native只记录维护调用而不模拟scope判定。 */
function fixture(rewrite=source=>source,{loggerFailure=false}={}){
 const source=rewrite(original),logs=[];let nativeCalls=0;
 const load=makePureEtsLoader({
  'libentry.so':{__esModule:true,default:{maintainTouchInput:()=>{nativeCalls++;return true;}}},
  '@kit.PerformanceAnalysisKit':{hilog:{warn:(...args)=>{logs.push(args);if(loggerFailure)throw Error('受控日志失败');}}},
 },{[relative]:source});
 return {api:load(relative),logs,nativeCalls:()=>nativeCalls};
}

/** 退休后旧句柄、伪造同generation句柄都不能向后来scope登记或推进Native。 */
function identityContract(rewrite){
 const f=fixture(rewrite),a=f.api;
 assert.equal(a.captureEntryTouchInputMaintenanceScope(),undefined);
 assert.equal(a.isEntryTouchInputMaintenanceCurrent(undefined),false);
 assert.equal(a.reconcileEntryTouchInputMaintenance(undefined),false);assert.equal(f.nativeCalls(),0);
 const first=a.startEntryTouchInputMaintenance();assert.equal(a.captureEntryTouchInputMaintenanceScope(),first);
 assert.throws(()=>a.startEntryTouchInputMaintenance(),/活跃游戏会话/);
 assert.equal(a.isEntryTouchInputMaintenanceCurrent(new a.EntryTouchInputMaintenanceLease(first.generation)),false);
 assert.equal(a.reconcileEntryTouchInputMaintenance(first),true);assert.equal(f.nativeCalls(),1);
 a.stopEntryTouchInputMaintenance(first);a.stopEntryTouchInputMaintenance(first);
 const later=a.startEntryTouchInputMaintenance(),source={stopSources(){}};
 assert.equal(a.registerEntryTouchInputMaintenanceSource(first,source),false,'旧scope不得登记后来会话');
 assert.equal(a.reconcileEntryTouchInputMaintenance(first),false);assert.equal(f.nativeCalls(),1);
 assert.equal(a.registerEntryTouchInputMaintenanceSource(later,source),true);
 a.stopEntryTouchInputMaintenance(later);
}

/** 有界来源登记：重复登记不占新槽，撤本源归还容量，未登记来源不受宿主stop。 */
function capacityContract(rewrite){
 const f=fixture(rewrite),a=f.api,scope=a.startEntryTouchInputMaintenance(),stopped=Array(17).fill(0);
 const sources=stopped.map((_,index)=>({stopSources:()=>{stopped[index]++;}}));
 for(let index=0;index<16;index++)assert.equal(a.registerEntryTouchInputMaintenanceSource(scope,sources[index]),true);
 assert.equal(a.registerEntryTouchInputMaintenanceSource(scope,sources[0]),true);
 assert.equal(a.registerEntryTouchInputMaintenanceSource(scope,sources[16]),false,'第17个独立来源必须拒绝');
 a.unregisterEntryTouchInputMaintenanceSource(scope,sources[0]);
 assert.equal(a.registerEntryTouchInputMaintenanceSource(scope,sources[16]),true);
 a.stopEntryTouchInputMaintenance(scope);assert.equal(stopped[0],0);
 assert.deepEqual(stopped.slice(1),Array(16).fill(1));
}

/** scope必须先退休；清理异常不阻断兄弟，清理重入的新scope不会被旧循环末尾覆盖。 */
function cleanupContract(rewrite){
 const f=fixture(rewrite),a=f.api,first=a.startEntryTouchInputMaintenance();let stopped=0,later,retiredBeforeCleanup=false,rebindAccepted;
 const shared={stopSources:()=>{stopped++;return true;},reconcileStoppedSources:()=>true};
 const laterSource={stopSources:()=>{stopped++;return true;},reconcileStoppedSources:()=>true};
 a.registerEntryTouchInputMaintenanceSource(first,{stopSources(){
  retiredBeforeCleanup=!a.isEntryTouchInputMaintenanceCurrent(first);
  if(!retiredBeforeCleanup)return;
  later=a.startEntryTouchInputMaintenance();
  rebindAccepted=a.registerEntryTouchInputMaintenanceSource(later,shared);
  assert.equal(a.registerEntryTouchInputMaintenanceSource(later,laterSource),true);
 }});
 a.registerEntryTouchInputMaintenanceSource(first,{stopSources(){throw Error('受控单源清理失败');}});
 a.registerEntryTouchInputMaintenanceSource(first,shared);
 a.stopEntryTouchInputMaintenance(first);
 assert.equal(retiredBeforeCleanup,true,'回调执行前原scope必须退休');
 assert.equal(rebindAccepted,false,'原对象不能改绑到后来scope');
 assert.equal(stopped,1);assert.ok(later);
 assert.equal(a.captureEntryTouchInputMaintenanceScope(),later);
 assert.equal(f.logs.length,1);assert.equal(f.logs[0][1],'InputSession');
 a.unregisterEntryTouchInputMaintenanceSource(first,laterSource);
 a.stopEntryTouchInputMaintenance(later);assert.equal(stopped,2,'旧源解绑不能删除后来scope的新登记');
}

/** 第一来源和日志端口同时失败时，第二来源仍必须取得停止机会；日志不拥有清理控制权。 */
function loggerIsolationContract(rewrite){
 const f=fixture(rewrite,{loggerFailure:true}),a=f.api,scope=a.startEntryTouchInputMaintenance();let stopped=0;
 a.registerEntryTouchInputMaintenanceSource(scope,{stopSources(){throw Error('受控第一来源清理失败');}});
 a.registerEntryTouchInputMaintenanceSource(scope,{stopSources(){stopped++;}});
 a.stopEntryTouchInputMaintenance(scope);
 assert.equal(stopped,1,'日志异常不能跳过后续来源清理');
 assert.equal(f.logs.length,1);assert.equal(a.isEntryTouchInputMaintenanceCurrent(scope),false);
}

identityContract();capacityContract();cleanupContract();loggerIsolationContract();
console.log('PASS production Native-only scope: identity, 16-source budget, retirement, failures and reentry');
console.log('PASS first-source and logger failure still stops the next production source');

/** false是原资源尚未结束：真实receipt只重试原source，不重复stop，不借后来scope代完成。 */
function pendingReceiptContract(){
 const f=fixture(),a=f.api,first=a.startEntryTouchInputMaintenance();let stops=0,retries=0,siblingStops=0;
 const source={stopSources(){stops++;return false;},reconcileStoppedSources(){retries++;return retries>=2;}};
 const sibling={stopSources(){siblingStops++;return true;},reconcileStoppedSources(){throw Error('已完成兄弟不应重试');}};
 assert.equal(a.registerEntryTouchInputMaintenanceSource(first,source),true);
 assert.equal(a.registerEntryTouchInputMaintenanceSource(first,sibling),true);
 const receipt=a.stopEntryTouchInputMaintenance(first);
 assert.ok(receipt);assert.equal(receipt.complete(),false);assert.equal(receipt.waiting(),true);
 assert.equal(stops,1);assert.equal(siblingStops,1);assert.equal(a.isEntryTouchInputMaintenanceCurrent(first),false);
 assert.equal(a.stopEntryTouchInputMaintenance(first),undefined,'旧scope重复stop没有新receipt或新副作用');
 const later=a.startEntryTouchInputMaintenance();let laterStops=0;
 a.registerEntryTouchInputMaintenanceSource(later,{stopSources(){laterStops++;return true;},reconcileStoppedSources(){return true;}});
 assert.equal(receipt.reconcile(),false);assert.equal(retries,1);assert.equal(receipt.waiting(),true);
 assert.equal(receipt.reconcile(),true);assert.equal(retries,2);assert.equal(receipt.complete(),true);
 assert.equal(receipt.waiting(),false);assert.equal(receipt.reconcile(),true);assert.equal(retries,2);
 assert.equal(stops,1,'receipt retry不重复原stop或开启来源');assert.equal(laterStops,0);
 assert.equal(a.captureEntryTouchInputMaintenanceScope(),later);assert.equal(f.nativeCalls(),0,'cleanup不推进输入维护');
 a.stopEntryTouchInputMaintenance(later);assert.equal(laterStops,1);
}

/** 原stop或retry异常必须保失败事实；后继清完可结束等待，不能把异常历史洗成Clean。 */
function failedReceiptContract(){
 const f=fixture(undefined,{loggerFailure:true}),a=f.api,scope=a.startEntryTouchInputMaintenance();let retries=0,siblings=0;
 a.registerEntryTouchInputMaintenanceSource(scope,{
  stopSources(){throw Error('原source停止失败');},
  reconcileStoppedSources(){retries++;if(retries===1)throw Error('原source retry仍失败');return true;},
 });
 a.registerEntryTouchInputMaintenanceSource(scope,{stopSources(){siblings++;return true;},reconcileStoppedSources(){return true;}});
 const receipt=a.stopEntryTouchInputMaintenance(scope);
 assert.ok(receipt);assert.equal(siblings,1,'stop异常和日志异常仍停止兄弟');
 assert.equal(receipt.complete(),false);assert.equal(receipt.waiting(),true);
 assert.equal(receipt.reconcile(),false);assert.equal(receipt.waiting(),true);
 assert.equal(receipt.reconcile(),false);assert.equal(receipt.waiting(),false);
 assert.equal(receipt.complete(),false,'已收回pending也不能伪Clean原失败事务');
 assert.equal(retries,2);assert.equal(f.nativeCalls(),0);
}

/** receipt同步回入自己的reconcile必须暂缓，不能递归双退同一callback/token。 */
function receiptReentryContract(){
 const f=fixture(),a=f.api,scope=a.startEntryTouchInputMaintenance();let receipt,retries=0;
 a.registerEntryTouchInputMaintenanceSource(scope,{
  stopSources(){return false;},
  reconcileStoppedSources(){retries++;assert.equal(receipt.complete(),false);assert.equal(receipt.waiting(),true);
   assert.equal(receipt.reconcile(),false,'原receipt正在清理，嵌套调用不得重复退资源');return true;},
 });
 receipt=a.stopEntryTouchInputMaintenance(scope);
 assert.equal(receipt.reconcile(),true);assert.equal(receipt.complete(),true);assert.equal(retries,1);
}
pendingReceiptContract();failedReceiptContract();receiptReentryContract();
console.log('PASS original stop receipt pending/retry, sticky failure, sibling isolation and reentry');

/** 对照须确实改到生产原文；未匹配或编译/模块装配失败不能冒充状态合同抓到错误。 */
function mutation(before,after){
 assert.ok(original.includes(before),'负控目标已失效');
 return source=>source.replace(before,after);
}
assert.throws(()=>identityContract(mutation(
 'return lease !== undefined && maintenanceLease === lease',
 'return lease !== undefined')),/strictly equal|false/);
assert.throws(()=>capacityContract(mutation(
 '  if (maintenanceSources.size >= MAX_MAINTENANCE_SOURCES) return false',
 '')),/第17个独立来源/);
assert.throws(()=>cleanupContract(mutation(
 '  maintenanceLease = undefined\n',
 '')),/回调执行前原scope必须退休/);
// 原对象首次登记域不得被清理回入改贴；撤掉WeakMap围栏须命中真实跨scope注册断言。
assert.throws(()=>cleanupContract(mutation(
 '  if (original!==undefined && original!==lease) return false',
 '')),/原对象不能改绑到后来scope/);
console.log('PASS compiled negative controls reject stale scope, unbounded registry and late retirement');

// 撤回日志异常隔离必须真正执行旧生产调用，然后以同一个logger失败证明后续清理被阻断。
const loggerGuard = `      try { hilog.warn(0x0000,'InputSession','输入来源维护清理失败：%{public}s',String(error)) }
      catch (_) {
        // 清理日志只是观察。日志端口失效不能夺走后续来源的停止机会；scope和登记集合
        // 已经退休，直接继续清理下一来源，不再调用可能重复失败的日志兜底或恢复旧scope。
        continue
      }`;
assert.throws(()=>loggerIsolationContract(mutation(loggerGuard,
 "      hilog.warn(0x0000,'InputSession','输入来源维护清理失败：%{public}s',String(error))")),/受控日志失败/);
console.log('PASS compiled old-logger negative control exposes interrupted sibling cleanup');

// 真实反向依赖对照：让生产共同模块真正使用前端class，严格夹具应在UI/文件依赖处拒绝。
assert.throws(()=>fixture(source=>"import { EntryTouchSession } from './EntryTouchSession'\n"+
 source+'\nexport const accidentalFrontend = EntryTouchSession\n'),/Unexpected pure-module dependency/);
console.log('PASS dependency negative control rejects importing the touch frontend into common maintenance');
