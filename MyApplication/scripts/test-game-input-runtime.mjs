/**
 * 输入前端装配回归：转译真实HAR/Entry实现，仅替换系统API、时钟和Preferences。
 * 覆盖配置提交/失败、按设备轴积分、失焦/RESET、硬软IME交接及异步指针恢复。
 */
import assert from 'node:assert/strict';
import { environment } from './lib/ets-runtime-fixture.mjs';
const noop=()=>{};
const flush=async()=>{for(let i=0;i<8;i++) await Promise.resolve();};
let count=0;
const pass=name=>{count++;console.log('PASS '+name);};

// Ability到会话的前后台装配由完整GameSessionHost测试覆盖，来源墓碑纯规则保留于上方。
{
  const env=environment();const {LayoutStore}=env.load('gamecontrol/src/main/ets/LayoutStore.ets');
  const {setControlNativeSink}=env.load('gamecontrol/src/main/ets/InputConfigurationNativePort.ets');
  const {InputConfigurationRuntime}=env.load('gamecontrol/src/main/ets/InputConfigurationRuntime.ets');
  const layout=env.load('gamecontrol/src/main/ets/ControlLayout.ets');
  const store=new LayoutStore();let failing=false;const data=new Map(),observed=[],native=[];
  store.pref={get:async(k,f)=>data.get(k)??f,put:async(k,v)=>{data.set(k,v);},putSync:(k,v)=>data.set(k,v),flush:async()=>{if(failing){failing=false;throw Error('disk failure');}}};
  store._ready=true;const initial=layout.getDefaultLayout();initial.name='initial';initial.isPreset=false;initial.profileId='profile_initial';initial.profileRevision=1;store.profiles=[initial];store.activeName=initial.name;
  setControlNativeSink({applyLookConfiguration:config=>{native.push(config.sensitivity);return true;}});
  const configurationRuntime=new InputConfigurationRuntime();configurationRuntime.start(store);
  store.addInputConfigurationListener((p,r)=>observed.push([p.name,p.lookSensitivity,r]));
  await store.cloneAsUser('initial');await store.renameProfile(store.getActiveProfile().name,'updated');
  const updated=store.getActiveProfile();updated.lookSensitivity=2;
  assert.equal(await store.saveProfile(updated),true);assert.equal(observed.at(-1)[0],'updated');assert.equal(native.at(-1),2);
  const confirmed=observed.length;failing=true;const next=store.getActiveProfile();next.lookSensitivity=3;await assert.rejects(store.saveProfile(next));assert.equal(observed.length,confirmed);assert.equal(store.getActiveProfile().lookSensitivity,2);
  await store.setActiveProfile('initial');assert.equal(observed.at(-1)[0],'initial');
  configurationRuntime.stop();
  pass('production LayoutStore: only confirmed active revisions broadcast; failed flush rolls back');
}

{
  const env=environment();const map=env.load('gamecontrol/src/main/ets/KeyMap.ets'), k=env.load('gamecontrol/src/main/ets/GlfwKeys.ets');
  for(const mods of [k.GLFW_MOD_CONTROL,k.GLFW_MOD_SUPER,k.GLFW_MOD_ALT])assert.equal(map.resolvePhysicalKeyCodepoint(97,2017,mods),0);
  assert.equal(map.resolvePhysicalKeyCodepoint(65,2017,k.GLFW_MOD_SHIFT),65);
  assert.equal(map.resolvePhysicalKeyCodepoint(64,2017,k.GLFW_MOD_CONTROL|k.GLFW_MOD_ALT,true),64);
  assert.equal(map.resolvePhysicalKeyCodepoint(undefined,2017,k.GLFW_MOD_CONTROL|k.GLFW_MOD_ALT,true),0);
  pass('physical text: shortcuts suppressed, Shift and evidenced AltGr retained');
}

// IME全部非UI组件、共享运行体、真实Coordinator/Entry sink与可失败IMF Promise，
// 原编辑/换行/三态fallback/epoch/预算/交接契约迁到同一个生产实现，不再调用已退出的UI状态机。
await import('./test-entry-text-input-runtime.mjs');
pass('production shared IME runtime and complete UI source bindings');

{
  const pending=[],calls=[];let visible=true;
  const pointer={setPointerVisible:v=>{calls.push(v);return new Promise(resolve=>pending.push(()=>{visible=v;resolve();}));}};
  const env=environment({imports:{'@ohos.multimodalInput.pointer':{default:pointer}}});
  const p=env.load('gamecontrol/src/main/ets/PointerVisibilityCoordinator.ets').getPointerVisibility();
  p.sync(true,true);await flush();p.restore();pending.shift()();await flush();assert.deepEqual(calls,[false,true]);pending.shift()();await flush();assert.equal(visible,true);
  pass('pointer restore follows an already in-flight hide without heartbeat');
}

{
  // 继续执行仓库已有纯ArkTS断言，避免新时钟模型只通过新测试却破坏旧持有/去重契约。
  let cases=0;
  const hypium={describe:(_name,body)=>body(),it:(_name,_level,body)=>{body();cases++;},expect:value=>({
    assertEqual:expected=>assert.equal(value,expected),assertTrue:()=>assert.equal(value,true),assertFalse:()=>assert.equal(value,false)
  })};
  const env=environment({imports:{'@ohos/hypium':hypium}});
  for(const name of ['PhysicalKeyEdge','PhysicalHeldKeyTracker','TextInputSessionCoordinator']) {
    env.load('entry/src/test/'+name+'.test.ets').default();
  }
  pass('existing ArkTS pure contracts: '+cases+' assertions scenarios');
}

// 页面心跳/退出/装配的生产实现已迁到稳定宿主，相关故障反例由完整宿主测试继续覆盖。
await import('./test-game-session-host.mjs');
await import('./test-game-page-input-lease.mjs');
await import('./test-game-page-session-facts.mjs');
console.log('test-game-input-runtime: '+count+' production assembly checks passed');
