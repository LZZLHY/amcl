/**
 * 配置所有权迁移回归：执行生产Store/Runtime，只替换Preferences和Native平台端口。
 * 检验仓库保存与本局激活的独立回执、端口更换、失败重试及停止时的迟到/重入边界。
 */
import assert from 'node:assert/strict';
import { environment } from './lib/ets-runtime-fixture.mjs';

/** 每例独立模块单例和保存缓存；fixture不模拟配置应用算法。 */
function fixture() {
  const env=environment();
  const {LayoutStore}=env.load('gamecontrol/src/main/ets/LayoutStore.ets');
  const layout=env.load('gamecontrol/src/main/ets/ControlLayout.ets');
  const {InputConfigurationRuntime}=env.load('gamecontrol/src/main/ets/InputConfigurationRuntime.ets');
  const nativePort=env.load('gamecontrol/src/main/ets/InputConfigurationNativePort.ets');
  const profile=layout.getDefaultLayout();
  profile.name='session-source';profile.isPreset=false;profile.profileId='profile-session';profile.profileRevision=1;
  const store=new LayoutStore();store.profiles=[profile];store.activeName=profile.name;store._ready=true;
  const data=new Map();let failure=false;
  store.pref={get:async(k,f)=>data.get(k)??f,put:async(k,v)=>data.set(k,v),putSync:(k,v)=>data.set(k,v),
    flush:async()=>{if(failure){failure=false;throw Error('disk failure');}}};
  const configuration=env.load('gamecontrol/src/main/ets/InputConfiguration.ets');
  return {store,InputConfigurationRuntime,nativePort,touchBehaviorKey:configuration.touchBehaviorKey,failSave:()=>{failure=true;}};
}

{
  const f=fixture(),observed=[],look=[];
  f.nativePort.setControlNativeSink({applyLookConfiguration:c=>{look.push({...c});return true;}});
  const runtime=new f.InputConfigurationRuntime();runtime.start(f.store);
  f.store.addInputConfigurationListener(profile=>{observed.push(profile);return true;},'confirmed-feedback');
  const before=f.store.getActiveProfile(),key=f.touchBehaviorKey(before);
  const changed=f.store.getActiveProfile();changed.haptic=false;changed.controls[0].label+='反馈';changed.controls[0].style={bg:'#abcdef'};
  assert.equal(f.touchBehaviorKey(changed),key,'反馈变化不进入动作/命中生存键');
  assert.equal(await f.store.saveProfile(changed),true);
  assert.equal(observed.at(-1).haptic,false,'行为等价不能短路完整已确认定义的发布');
  assert.equal(observed.at(-1).profileId,before.profileId);assert.equal(observed.at(-1).profileRevision,before.profileRevision+1);
  assert.equal(look.length,1,'纯反馈不重配原全来源look手感');
  const confirmed=observed.length;f.failSave();const rejected=f.store.getActiveProfile();rejected.haptic=true;
  await assert.rejects(f.store.saveProfile(rejected),/disk failure/);
  assert.equal(observed.length,confirmed);assert.equal(f.store.getActiveProfile().haptic,false);
  runtime.stop();console.log('PASS feedback-only preserves stable identity and input behavior while real Store saves/publishes new feedback');
}

{
  const f=fixture();const applied=[];
  f.nativePort.setControlNativeSink({applyLookConfiguration:c=>{applied.push({...c});return true;}});
  const draft=f.store.getActiveProfile();draft.lookSensitivity=2;
  assert.equal(await f.store.saveProfile(draft),true);
  f.store.reconcileInputConfiguration();
  assert.deepEqual(applied,[],'仓库保存/定义重试不能在会话外触发Native应用');
  const runtime=new f.InputConfigurationRuntime();runtime.start(f.store);
  assert.equal(applied.length,1);assert.equal(applied[0].sensitivity,2);
  runtime.start(f.store);runtime.reconcile();assert.equal(applied.length,1,'同会话start/已成功域重试幂等');
  const nativeState=runtime.status()[0];assert.equal(nativeState.pending,false);
  runtime.stop();assert.deepEqual(runtime.status(),[]);
  const later=f.store.getActiveProfile();later.lookSensitivity=3;assert.equal(await f.store.saveProfile(later),true);
  runtime.reconcile();assert.equal(applied.length,1,'停局后保存与维护不能继续写旧会话');
  runtime.start(f.store);assert.equal(applied.length,2);assert.equal(applied[1].sensitivity,3);runtime.stop();
  console.log('PASS confirmed definitions remain inert outside a live session; start/stop/rebind ownership');
}

{
  const f=fixture();let rejects=false;const applied=[];
  f.nativePort.setControlNativeSink({applyLookConfiguration:c=>{if(rejects)return false;applied.push({...c});return true;}});
  const runtime=new f.InputConfigurationRuntime();runtime.start(f.store);
  const baseline=f.store.getActiveProfile();const baselineRevision=runtime.status()[0].appliedRevision;
  f.failSave();const broken=f.store.getActiveProfile();broken.lookSensitivity=2.5;
  await assert.rejects(f.store.saveProfile(broken),/disk failure/);
  assert.equal(f.store.getActiveProfile().lookSensitivity,baseline.lookSensitivity);
  assert.equal(applied.length,1);assert.equal(runtime.status()[0].appliedRevision,baselineRevision);
  rejects=true;const saved=f.store.getActiveProfile();saved.lookSensitivity=2;saved.invertY=true;
  assert.equal(await f.store.saveProfile(saved),true,'Native拒绝不改写持久保存成功事实');
  assert.equal(f.store.getActiveProfile().lookSensitivity,2);assert.equal(runtime.status()[0].pending,true);
  assert.equal(runtime.status()[0].appliedRevision,baselineRevision);assert.equal(applied.length,1);
  rejects=false;runtime.reconcile();assert.equal(runtime.status()[0].pending,false);
  assert.equal(applied.length,2);assert.deepEqual([applied[1].sensitivity,applied[1].invertY],[2,true]);
  runtime.stop();console.log('PASS save failure leaves old definition; native rejection preserves saved/pending distinction');
}

{
  const f=fixture();const first=[],second=[];
  f.nativePort.setControlNativeSink({applyLookConfiguration:c=>{first.push(c.sensitivity);return true;}});
  const runtime=new f.InputConfigurationRuntime();runtime.start(f.store);
  const confirmed=f.store.inputConfigurationStatus()[0].desiredRevision;
  f.nativePort.setControlNativeSink(null);runtime.reconcile();assert.equal(runtime.status()[0].pending,true);
  assert.equal(runtime.status()[0].desiredRevision,confirmed,'端口替换不虚增定义修订');
  f.nativePort.setControlNativeSink({applyLookConfiguration:c=>{second.push(c.sensitivity);return true;}});
  runtime.reconcile();assert.equal(second.length,1);assert.equal(first.length,1);assert.equal(runtime.status()[0].pending,false);
  const draft=f.store.getActiveProfile();draft.controls[0].label+='视觉';draft.controls[0].style={bg:'#abcdef'};
  assert.equal(await f.store.saveProfile(draft),true);assert.equal(second.length,1,'纯视觉修改不重新应用相同look');
  runtime.stop();console.log('PASS platform binding replacement retires only native-look receipt; unchanged look is not reapplied');
}

{
  const f=fixture();let attempts=0;const runtime=new f.InputConfigurationRuntime();
  f.nativePort.setControlNativeSink({applyLookConfiguration:()=>{attempts++;runtime.stop();return true;}});
  runtime.start(f.store);assert.equal(attempts,1);assert.deepEqual(runtime.status(),[]);
  // 抽出真正由运行对象注册的旧订阅，模拟调用者在注销前已取得快照后的迟到投递。
  const next=new f.InputConfigurationRuntime();
  f.nativePort.setControlNativeSink({applyLookConfiguration:()=>{attempts++;return true;}});
  next.start(f.store);const oldListener=next.listener;next.stop();
  assert.equal(oldListener(f.store.getActiveProfile(),99),false);assert.equal(attempts,2);
  console.log('PASS synchronous stop and late captured subscriber cannot stamp/replay a retired session');
}

{
  const f=fixture();let first=0,second=0;
  f.nativePort.setControlNativeSink({applyLookConfiguration:()=>{
    first++;f.nativePort.setControlNativeSink({applyLookConfiguration:()=>{second++;return true;}});return true;
  }});
  const runtime=new f.InputConfigurationRuntime();runtime.start(f.store);
  assert.equal(first,1);assert.equal(runtime.status()[0].pending,true,'旧端口回调更换注册不能盖章为新端口已应用');
  runtime.reconcile();assert.equal(second,1);assert.equal(runtime.status()[0].pending,false);runtime.stop();
  console.log('PASS synchronous native replacement cannot let an old completion acknowledge the new binding');
}
