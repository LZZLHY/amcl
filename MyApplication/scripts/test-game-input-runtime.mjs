/**
 * 输入前端装配回归：转译真实HAR/Entry实现，仅替换系统API、时钟和Preferences。
 * 覆盖配置提交/失败、按设备轴积分、失焦/RESET、硬软IME交接及异步指针恢复。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import compiler from './lib/ets-compiler.mjs';
import { environment } from './lib/ets-runtime-fixture.mjs';
const root=path.resolve(import.meta.dirname,'..');
const noop=()=>{};
const flush=async()=>{for(let i=0;i<8;i++) await Promise.resolve();};
let count=0;
const pass=name=>{count++;console.log('PASS '+name);};

/**
 * 单个fixture拥有独立模块单例；所有平台调用必须显式提供，未知服务直接失败。
 * options.memberOverrides[相对路径][成员名] 只用于负向对照：组件成员原文替换成旧形状（字符串）
 * 或经函数改写（必须真的改到原文）；成员不存在即失败，防止对照随生产改名而静默失效。
 */

/** 按名字取出生产类中这些方法的原文（不含字段初始化，调用方在实例上补齐所需字段）；缺一个即失败。 */
function methodText(relative,names) {
  const source=fs.readFileSync(path.join(root,relative),'utf8');
  const ast=compiler.createSourceFile(relative,source,compiler.ScriptTarget.Latest,true);
  const owner=ast.statements.find(n=>n.members?.some(m=>m.name?.getText(ast)===names[0]));
  assert.ok(owner,relative);
  return names.map(name=>{
    const member=owner.members.find(m=>m.name?.getText(ast)===name);
    assert.ok(member,relative+': missing member '+name);return member.getText(ast);
  }).join('\n');
}
/** 把一段方法原文包成类并转译执行；NAPI、单例、定时器等全部自由标识符都由bindings注入。 */
function methodsFromText(body,bindings) {
  const js=compiler.transpileModule('class Subject {\n'+body+'\n}\nreturn Subject;',
    {compilerOptions:{target:compiler.ScriptTarget.ES2020}}).outputText;
  return new Function(...Object.keys(bindings),js)(...Object.values(bindings));
}
/**
 * 生命周期装配执行实际Ability/Page方法，依赖边界由调用方注入；不手写前后台转发逻辑。
 * mutate只用于负向对照：把生产原文改回旧形状，且必须真的改到原文，否则说明对照已失效。
 */
function productionMethods(relative,names,bindings,omitForeground=false,mutate=undefined) {
  let body=methodText(relative,names);
  if(omitForeground){const original=body;body=body.replace(/getInputSourceRegistry\(\)\.notifyAbilityForeground\(\);?/,'');assert.notEqual(body,original);}
  if(mutate){const original=body;body=mutate(body);assert.notEqual(body,original,'negative-control mutation no longer matches '+relative);}
  return methodsFromText(body,bindings);
}

{
  const env=environment();const m=env.load('gamecontrol/src/main/ets/GamepadManager.ets');
  const {GameInputRuntime}=env.load('gamecontrol/src/main/ets/GameInputRuntime.ets');
  const layout=env.load('gamecontrol/src/main/ets/ControlLayout.ets');
  const keys=env.load('gamecontrol/src/main/ets/OhosKeyCodes.ets');
  let now=0,resets=0;const output=[];
  const pad=new m.GamepadManager(undefined,{emitKey:(k,a)=>{output.push(['key',k,a]);return true;},emitMouse:()=>true,emitScroll:()=>true,emitLookDelta:(x,y)=>output.push(['look',x,y])});
  const runtime=new GameInputRuntime(pad,()=>now,()=>resets++);
  let listener;const store={reconcileInputConfiguration:noop,addInputConfigurationListener:fn=>{listener=fn;fn(layout.getDefaultLayout(),1);},removeInputConfigurationListener:fn=>{assert.equal(fn,listener);listener=undefined;}};
  runtime.start(store);runtime.setState(true,true);
  runtime.handleAxis(7,a=>a===m.AXIS_ABS_Z?1:0);
  assert.equal(output.filter(v=>v[0]==='look').length,0,'axis event itself must not move');
  for(let i=0;i<10;i++){now+=16;env.runTimers();}
  assert.ok(Math.abs(output.filter(v=>v[0]==='look').reduce((sum,v)=>sum+v[1],0)-172.8)<1e-6);
  runtime.handleAxis(7,()=>0);const before=output.length;now+=16;env.runTimers();assert.equal(output.length,before);
  runtime.handleAxis(8,a=>a===m.AXIS_ABS_Z?1:0);runtime.setState(false,true);now+=1000;env.runTimers();assert.equal(output.length,before);
  runtime.setState(true,true);now+=16;env.runTimers();assert.equal(output.length,before,'focus regain cannot replay old stick');
  runtime.handleAxis(8,a=>a===m.AXIS_ABS_Z?1:0);pad.releaseDevice(8);now+=16;env.runTimers();assert.equal(output.length,before);
  pad.handleButtonForDevice(7,keys.OHOS_BUTTON_A,true);
  const profile=layout.getDefaultLayout();profile.gamepad=layout.defaultGamepadConfig();profile.gamepad.buttonMap.A={kind:'key',code:66};
  listener(profile,2);pad.handleButtonForDevice(7,keys.OHOS_BUTTON_A,true);assert.ok(output.some(v=>v[0]==='key'&&v[1]===66&&v[2]===1));
  runtime.dropHeldStateAfterNativeReset('test');assert.equal(resets,1);runtime.stop();assert.equal(listener,undefined);assert.equal(env.timer.size,0);
  pass('production runtime: time integration, center/focus/remove/reset and live configuration');
}

{
  const env=environment();const {GameInputRuntime}=env.load('gamecontrol/src/main/ets/GameInputRuntime.ets');
  let releases=0,suspended=0,updates=0;
  // 故意让配置等待旧RELEASE确认，制造background后最容易误重启timer的pending状态。
  // 此边界替身仍明确使用旧兼容模型；新生产管理器的维护查询不能让夹具漏方法冒充业务失败。
  const pad={releaseAllInputs:()=>releases++,updateConfig:()=>{updates++;return false;},reconcileLookExecution:noop,
    reconcileConnectionCleanup:()=>true, // 此无token边缘没有连接墓碑；真实清理另执行新生产模块。
    usesSharedLookExecution:()=>false,hasLookMotion:()=>true,advanceMappedLook:()=>{throw Error('background motion');}};
  const runtime=new GameInputRuntime(pad,()=>100,noop,noop,()=>suspended++);
  runtime.start({reconcileInputConfiguration:noop,addInputConfigurationListener:fn=>fn({gamepad:{}},1),removeInputConfigurationListener:noop});
  runtime.setState(true,true);runtime.reconcile();assert.ok(env.timer.size>0);
  runtime.releaseAllInputs('game-ability-background');assert.equal(suspended,1);assert.equal(env.timer.size,0);
  runtime.setState(true,true);runtime.reconcile();assert.equal(env.timer.size,0,'stale active UI/grab/heartbeat must not reopen background');
  runtime.resumeAfterLifecycle();runtime.setState(true,true);runtime.reconcile();assert.equal(env.timer.size,0,'focus cannot forge Ability foreground');
  runtime.onAbilityForeground();runtime.setState(true,true);runtime.reconcile();assert.ok(env.timer.size>0);
  runtime.stop();assert.equal(env.timer.size,0);assert.ok(releases>0&&updates>0);
  pass('runtime lifecycle tombstone blocks stale UI and pending configuration timers until explicit focus/show');
}

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
  // 真正把LayoutStore装配到runtime，不能仅测试各自的镜像接口。
  const {GamepadManager}=env.load('gamecontrol/src/main/ets/GamepadManager.ets');
  const {GameInputRuntime}=env.load('gamecontrol/src/main/ets/GameInputRuntime.ets');
  const emitted=[];const pad=new GamepadManager(undefined,{emitKey:(k,a)=>{emitted.push([k,a]);return true;},emitMouse:()=>true,emitScroll:()=>true,emitLookDelta:noop});
  const runtime=new GameInputRuntime(pad,()=>0,noop);runtime.start(store);runtime.setState(true,true);
  await store.cloneAsUser('initial');await store.renameProfile(store.getActiveProfile().name,'updated');
  const updated=store.getActiveProfile();updated.lookSensitivity=2;
  updated.gamepad=layout.defaultGamepadConfig();updated.gamepad.buttonMap.A={kind:'key',code:67};
  assert.equal(await store.saveProfile(updated),true);assert.equal(observed.at(-1)[0],'updated');assert.equal(native.at(-1),2);
  pad.handleButton(2301,true);assert.ok(emitted.some(e=>e[0]===67&&e[1]===1));
  const confirmed=observed.length;failing=true;const next=store.getActiveProfile();next.lookSensitivity=3;await assert.rejects(store.saveProfile(next));assert.equal(observed.length,confirmed);assert.equal(store.getActiveProfile().lookSensitivity,2);
  await store.setActiveProfile('initial');assert.equal(observed.at(-1)[0],'initial');
  assert.ok(emitted.some(e=>e[0]===67&&e[1]===0));runtime.stop();configurationRuntime.stop();
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
  for(const name of ['GamepadManager','PhysicalKeyEdge','TextInputSessionCoordinator']) {
    env.load('entry/src/test/'+name+'.test.ets').default();
  }
  pass('existing ArkTS pure contracts: '+cases+' assertions scenarios');
}

// 页面心跳/退出/装配的生产实现已迁到稳定宿主，相关故障反例由完整宿主测试继续覆盖。
await import('./test-game-session-host.mjs');
await import('./test-game-page-input-lease.mjs');
await import('./test-game-page-session-facts.mjs');
console.log('test-game-input-runtime: '+count+' production assembly checks passed');
