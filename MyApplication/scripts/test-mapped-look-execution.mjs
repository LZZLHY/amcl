/** 真实Manager/Runtime的原连接速率合同；Native出口是明确边界，实际消费另由P5组合验证。 */
import assert from 'node:assert/strict';
import {environment} from './lib/ets-runtime-fixture.mjs';

/** 构造真实领域对象，记录全部出口以拒绝Native速率与旧JS积分并行发射。 */
function fixture() {
  const env=environment();
  const module=env.load('gamecontrol/src/main/ets/GamepadManager.ets');
  const {GameInputRuntime}=env.load('gamecontrol/src/main/ets/GameInputRuntime.ets');
  const layout=env.load('gamecontrol/src/main/ets/ControlLayout.ets');
  const outputs=[];let refuseRate=false,refuseRetire=false,now=0;
  const emitter={lookExecutionMode:'neutral-rate-v1',emitControl:(device,control,code,action)=>{
    outputs.push(['control',device,control,code,action]);return true;},emitKey:()=>true,emitMouse:()=>true,emitScroll:()=>true,
    emitLookDelta:(...values)=>{outputs.push(['legacy-delta',...values]);return true;},
    emitLookVelocity:(...values)=>{outputs.push(['rate',...values]);return !refuseRate;},
    advanceLookExecution:()=>{outputs.push(['advance-native']);return true;},
    retireLookConnection:(...values)=>{outputs.push(['retire',...values]);return !refuseRetire;}};
  const pad=new module.GamepadManager(undefined,emitter);
  const runtime=new GameInputRuntime(pad,()=>now,()=>{});
  const profile=layout.getDefaultLayout();
  runtime.start({addInputConfigurationListener:listener=>listener(profile,1),removeInputConfigurationListener(){},reconcileInputConfiguration(){}});
  runtime.setState(true,true);
  return {env,module,pad,runtime,outputs,setRateFailure:value=>{refuseRate=value;},setRetireFailure:value=>{refuseRetire=value;},
    setClock:value=>{now=value;}};
}

/** 实际轴归一入口；用满右摇杆与可选扳机，不复制Manager的死区或输出数学。 */
function axis(f,device,x,trigger=0) {
  f.runtime.handleAxis(device,code=>code===f.module.AXIS_ABS_Z?x:code===f.module.AXIS_ABS_GAS?trigger:0);
}

{
  const f=fixture();axis(f,7,1,1);
  const rate=f.outputs.find(row=>row[0]==='rate');assert.deepEqual(rate,['rate',7,1,1080,0]);
  assert.ok(f.outputs.findIndex(row=>row[0]==='rate')<f.outputs.findIndex(row=>row[0]==='control'),
    '同轴快照的速度边界先于扳机action提交');
  f.outputs.length=0;f.setClock(1000);f.env.runTimers();
  assert.ok(f.outputs.some(row=>row[0]==='advance-native'));
  assert.equal(f.outputs.some(row=>row[0]==='legacy-delta'),false,'新路线不以JS dt再积分');
  axis(f,7,0);assert.deepEqual(f.outputs.filter(row=>row[0]==='rate').at(-1),['rate',7,1,0,0]);
  assert.equal(f.outputs.some(row=>row[0]==='retire'),false,'归中不取消正常Native平滑尾量');
  f.runtime.stop();
  console.log('PASS actual Manager/Runtime velocity units, axis-action boundary, Native clock tick, centered tail and no duplicate delta');
}
{
  const f=fixture();axis(f,7,1);axis(f,8,1);
  assert.deepEqual(f.outputs.filter(row=>row[0]==='rate').map(row=>row.slice(1)),[[7,1,1080,0],[8,2,1080,0]]);
  f.outputs.length=0;f.pad.releaseDevice(7);
  assert.deepEqual(f.outputs,[['retire',7,1]]);
  assert.equal(f.pad.hasDeviceState(7),false);assert.equal(f.pad.hasDeviceState(8),true);
  axis(f,7,1);assert.deepEqual(f.outputs.filter(row=>row[0]==='rate').at(-1),['rate',7,3,1080,0]);
  f.runtime.stop();
  console.log('PASS original connection retirement is device-scoped; reinserted same ID obtains a new connection');
}
{
  const f=fixture();f.setRateFailure(true);axis(f,7,1);
  assert.equal(f.pad.hasLookMotion(),true);f.outputs.length=0;
  f.pad.advanceMappedLook(10,9007199254740992);
  assert.ok(f.outputs.some(row=>row[0]==='rate'&&row[2]===1));
  assert.equal(f.outputs.some(row=>row[0]==='legacy-delta'),false,'NotReady不能变旧delta副作用');
  f.setRateFailure(false);f.pad.reconcileLookExecution();f.outputs.length=0;
  f.setRetireFailure(true);f.pad.releaseDevice(7);assert.equal(f.pad.hasDeviceState(7),true);
  axis(f,7,1);assert.equal(f.outputs.some(row=>row[0]==='rate'),false,'退休失败的原连接不得接受后来轴');
  f.setRetireFailure(false);f.pad.reconcileLookExecution();assert.equal(f.pad.hasDeviceState(7),false);
  axis(f,7,1);assert.deepEqual(f.outputs.filter(row=>row[0]==='rate').at(-1),['rate',7,2,1080,0]);
  f.runtime.stop();
  console.log('PASS failed rate/retirement retains original identity and retries without fallback or stale axis replay');
}
{
  const f=fixture();axis(f,7,1);f.runtime.setState(false,true);const before=f.outputs.length;
  f.setClock(100000);f.env.runTimers();assert.equal(f.outputs.length,before);
  f.runtime.setState(true,true);f.env.runTimers();assert.equal(f.outputs.length,before,'恢复不重放后台轴');
  axis(f,7,1);assert.deepEqual(f.outputs.filter(row=>row[0]==='rate').at(-1),['rate',7,2,1080,0]);
  f.runtime.dropHeldStateAfterNativeReset('test-reset');axis(f,7,1);
  assert.deepEqual(f.outputs.filter(row=>row[0]==='rate').at(-1),['rate',7,3,1080,0]);
  f.runtime.stop();
  console.log('PASS foreground/reset uses new facts and connection, with no background time catchup');
}
{
  const f=fixture();
  // 边界值直接作为夹具初始counter，不能真实循环2^32次；被测试的分配/拒绝仍是生产方法。
  f.pad.nextLookConnection=4294967295;axis(f,7,1);axis(f,8,1);
  assert.deepEqual(f.outputs.filter(row=>row[0]==='rate'),[['rate',7,4294967295,1080,0]]);
  assert.equal(f.pad.devices.get(8)?.lookConnection??0,0);
  f.runtime.stop();
  console.log('PASS connection counter final valid value once; exhaustion rejects without wrap/reuse');
}
