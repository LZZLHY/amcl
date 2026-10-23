/** 真实传感器适配/积分器的原Native租约；只替换OS sensor与Native端口，非硬件采样证明。 */
import assert from 'node:assert/strict';
import {makePureEtsLoader} from './lib/load-pure-ets.mjs';

/** 每夹具单独装载真实适配器与积分，OS只保存注册的原闭包，Native明示context/lease。 */
function fixture() {
  const plain=makePureEtsLoader();
  const gamecontrol={...plain('gamecontrol/src/main/ets/TouchGyroscope.ets'),...plain('gamecontrol/src/main/ets/TouchPreferences.ets')};
  const subscriptions=[],offs=[],begins=[],submits=[],retires=[],legacy=[];
  let context='resource-policy-A',serial=0,accept=true;
  const native={sharedLookExecutionSupported:()=>true,touchGyroLeaseContext:()=>context,
    beginTouchGyroLease:schema=>{const token='gyro:'+ ++serial;begins.push({schema,token});return token;},
    submitTouchGyroLease:(...values)=>{submits.push(values);return accept;},retireTouchGyroLease:lease=>{retires.push(lease);return true;},
    sendTouchGyroSample:(...values)=>{legacy.push(values);return true;}};
  const load=makePureEtsLoader({gamecontrol,'libentry.so':{__esModule:true,default:native},
    '@kit.SensorServiceKit':{sensor:{SensorId:{GYROSCOPE:2},on:(id,callback)=>subscriptions.push(callback),off:(id,callback)=>offs.push(callback)}},
    '@kit.PerformanceAnalysisKit':{hilog:{info(){},warn(){}}}});
  const {EntryTouchGyroscope}=load('entry/src/main/ets/components/EntryTouchGyroscope.ets');
  const options=gamecontrol.normalizeTouchPreferences({gyroscopeMode:'always'});
  return {gyro:new EntryTouchGyroscope(),options,subscriptions,offs,begins,submits,retires,legacy,native,
    context:value=>{context=value;},accept:value=>{accept=value;}};
}

/** 使用真实trapezoid积分；首样本只建基线，第二样本形成已完成delta，不外推未来方向。 */
function sample(callback,base) {
  callback({x:0,y:1,z:0,timestamp:base});
  callback({x:0,y:1,z:0,timestamp:base+20000000});
}
{
  const f=fixture();f.gyro.configure(true,f.options,0,9);
  assert.equal(f.gyro.currentStatus(),'active');assert.equal(f.begins.length,1);
  const old=f.subscriptions[0];sample(old,1e9);
  assert.equal(f.submits.length,1);assert.equal(f.submits[0][0],'gyro:1');
  assert.ok(Math.abs(f.submits[0][1]+7.2)<1e-8);assert.equal(f.legacy.length,0);
  f.gyro.configure(true,f.options,0,9);assert.equal(f.begins.length,1);
  // policy/resource变，schema/设置值未变：原context而非两个ns钟的比较决定新租约。
  f.context('resource-policy-B');f.gyro.configure(true,f.options,0,9);
  assert.deepEqual(f.retires,['gyro:1']);assert.equal(f.begins.length,2);
  sample(old,2e9);assert.equal(f.submits.length,1,'off后排队旧sensor仍绑定原回调代');
  sample(f.subscriptions[1],3e9);assert.equal(f.submits.at(-1)[0],'gyro:2');
  f.gyro.stop();f.gyro.stop();assert.deepEqual(f.retires,['gyro:1','gyro:2']);
  console.log('PASS actual gyro completed delta, original opaque lease/context and retired callback; no old timestamp fallback');
}
{
  const f=fixture();f.context('');f.gyro.configure(true,f.options,0,9);
  assert.equal(f.gyro.currentStatus(),'pending');assert.equal(f.begins.length,0);assert.equal(f.subscriptions.length,0);
  f.context('ready-resource');f.gyro.configure(true,f.options,0,9);assert.equal(f.subscriptions.length,1);
  f.accept(false);sample(f.subscriptions[0],1e9);assert.equal(f.gyro.currentStatus(),'retired');
  assert.deepEqual(f.retires,['gyro:1']);assert.equal(f.legacy.length,0);
  f.gyro.configure(true,f.options,0,9);assert.equal(f.subscriptions.length,1,'同原context拒绝不每帧盲重建流');
  f.context('new-resource');f.gyro.configure(true,f.options,0,9);assert.equal(f.subscriptions.length,2);
  f.gyro.stop();console.log('PASS unready context waits, reject retires original source, resource change explicitly reacquires');
}
{
  const f=fixture();delete f.native.beginTouchGyroLease;
  f.gyro.configure(true,f.options,0,9);assert.equal(f.gyro.currentStatus(),'unavailable');
  assert.equal(f.subscriptions.length,0);assert.equal(f.legacy.length,0);
  console.log('PASS new capability without complete gyro lease cannot silently run old cross-clock path');
}
{
  const f=fixture();f.native.touchGyroLeaseContext=()=>{throw Error('native unavailable');};
  f.gyro.configure(true,f.options,0,9);assert.equal(f.gyro.currentStatus(),'unavailable');
  assert.equal(f.subscriptions.length,0);assert.equal(f.legacy.length,0);
  f.native.touchGyroLeaseContext=()=> 'same-resource-restored';f.gyro.configure(true,f.options,0,9);
  assert.equal(f.gyro.currentStatus(),'active');f.gyro.stop();
  console.log('PASS context query exception is observable and original resource recovery establishes a new qualified lease');
}
{
  const f=fixture();f.gyro.configure(true,f.options,0,9);const old=f.subscriptions[0];
  let accept=false;f.native.retireTouchGyroLease=token=>{f.retires.push(token);return accept;};
  f.gyro.stop();assert.equal(f.gyro.currentStatus(),'retirement-pending');assert.equal(f.gyro.pendingRetirement,'gyro:1');
  sample(old,1e9);assert.equal(f.submits.length,0);
  f.context('new-resource');f.gyro.configure(true,f.options,0,9);assert.equal(f.begins.length,1);
  assert.ok(f.retires.every(token=>token==='gyro:1'),'重试只能用原token');
  accept=true;f.gyro.configure(true,f.options,0,9);assert.equal(f.begins.length,2);
  assert.equal(f.gyro.currentStatus(),'active');f.gyro.stop();
  console.log('PASS failed Native retirement retains original tombstone, fences old callbacks and blocks replacement until confirmed');
}
