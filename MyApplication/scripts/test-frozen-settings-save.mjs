/**
 * 两项冻结设置的实际生产源回归。只控制Preferences put/flush、Context及显示边缘，
 * 保存串行、旧值读屏障、回滚、运行路线冻结与UI续体均由原ETS实现执行。
 * 不运行ArkUI Builder或真实磁盘/设备；明确不替代ArkTS产品编译和真机显示验证。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { environment } from './lib/ets-runtime-fixture.mjs';
import compiler from './lib/ets-compiler.mjs';
import { PROJECT_ROOT, assertExternalOutputPath, resolveWorkspacePath } from './lib/workspace-paths.mjs';

const P='feature_system/src/main/ets/PreferenceManager.ets';
const R='entry/src/main/ets/product/RuntimeProductProfile.ets';
const G='entry/src/main/ets/components/DesktopGamepadSettings.ets';
const T='entry/src/main/ProductTouchSettings.ets';
const sources=[P,R,G,T,'gamecontrol/src/main/ets/ProductRuntimePolicy.ets',
  'gamecontrol/src/main/ets/ProductInputPolicy.ets','scripts/test-frozen-settings-save.mjs',
  'scripts/lib/load-pure-ets.mjs','scripts/lib/ets-runtime-fixture.mjs','scripts/lib/ets-compiler.mjs'];
const hashes=()=>Object.fromEntries(sources.map(name=>[name,createHash('sha256')
  .update(fs.readFileSync(path.join(PROJECT_ROOT,name))).digest('hex')]));
const outputIndex=process.argv.indexOf('--output');
const output=assertExternalOutputPath(outputIndex<0?resolveWorkspacePath('run','frozen-settings-save'):process.argv[outputIndex+1]);
fs.mkdirSync(output,{recursive:true});
const startedAt=new Date().toISOString(),before=hashes(),groups=[];
const passed=name=>{groups.push(name);console.log('PASS '+name);};
const settle=async()=>{for(let i=0;i<32;i++)await Promise.resolve();};
function deferred(){let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return {promise,resolve,reject};}

/** 每个fixture表示一个真实新进程；同preferencesDir的不同manager共用同一平台store。 */
function fixture(overrides={}){
  // 撤回副本先通过宿主语法编译，不能以语法错误/装载失败代替下面实际行为断言。
  for(const[name,source]of Object.entries(overrides)){
    const result=compiler.transpileModule(source,{fileName:name,reportDiagnostics:true,
      compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020}});
    assert.equal((result.diagnostics??[]).filter(d=>d.category===compiler.DiagnosticCategory.Error).length,0,name);
  }
  const stores=new Map();let game=false;
  const context=owner=>({filesDir:'/sandbox/'+owner,preferencesDir:'/preferences/'+owner});
  const main=context('main');
  function storage(ctx=main){
    if(stores.has(ctx.preferencesDir))return stores.get(ctx.preferencesDir);
    const cache=new Map([['desktopNativeGamepad',false],['desktopInteraction','auto']]);
    const disk=new Map(cache),steps=[],calls=[];
    let failPut=false;
    const store={getSync:(key,fallback)=>cache.has(key)?cache.get(key):fallback,
      get:async(key,fallback)=>cache.has(key)?cache.get(key):fallback,
      putSync:(key,value)=>{calls.push(['rollback',key,value]);cache.set(key,value);},
      put:async(key,value)=>{calls.push(['put',key,value]);cache.set(key,value);if(failPut){failPut=false;throw new Error('put rejected');}},
      flush:async()=>{calls.push(['flush']);const values=new Map(cache),step=steps.shift();
        try{if(step)await step.promise;}catch(error){if(step.partial)for(const[k,v]of values)disk.set(k,v);throw error;}
        for(const[k,v]of values)disk.set(k,v);}};
    const value={store,cache,disk,calls,steps,failPut:()=>{failPut=true;}};stores.set(ctx.preferencesDir,value);return value;
  }
  const commons={ProcessPreferences:{open:ctx=>storage(ctx).store,isGameProcess:()=>game},formatError:String,
    AppLogger:{info(){}},LOG_DOMAIN_LAUNCH:1,DeviceProfile:{isPC:()=>true}};
  const prefLoad=makePureEtsLoader({commons,'@kit.PerformanceAnalysisKit':{hilog:{warn(){}}}},overrides);
  const PreferenceManager=prefLoad(P).PreferenceManager;
  const pure=makePureEtsLoader(),policy=pure('gamecontrol/src/main/ets/ProductRuntimePolicy.ets');
  const imports={commons,'feature_system':{PreferenceManager},gamecontrol:policy,
    '@ohos.deviceInfo':{default:{deviceType:'2in1',sdkApiVersion:26}},
    'libentry.so':{default:{hardwareRawMouseAvailable:()=>true,desktopGameProcessState:()=>1}},
    'entry/ProductBuildProfile':{ProductBuildProfile:{family:'universal',runtimeRawMouse:true,touchControls:true}}};
  const runtimeLoad=makePureEtsLoader(imports,overrides),profile=runtimeLoad(R).RuntimeProductProfile;
  const ui=environment({imports:{...imports,'entry/ProductInputProfile':{ProductInputProfile:profile},
    './ets/components/AppIcon':{AppIcon:{}}},sourceOverrides:Object.fromEntries(Object.entries(overrides)
      .map(([key,value])=>[key,()=>value]))});
  const component=(name,ctx=main)=>{const Class=ui.load(name,true)[name===G?'DesktopGamepadSettings':'ProductTouchSettings'];
    const view=new Class();view.getUIContext=()=>({getHostContext:()=>ctx});view.aboutToAppear();return view;};
  return {PreferenceManager,manager:ctx=>new PreferenceManager(ctx??main),profile,context,main,storage,component,
    setGame:value=>{game=value;},coldProfile:()=>makePureEtsLoader(imports,overrides)(R).RuntimeProductProfile};
}

/** Builder仍不执行；只抽真实事件闭包，验证GUI保存入口确实调用了被测生产方法。 */
function event(view,relative,method,eventName,values={}){
  const source=fs.readFileSync(path.join(PROJECT_ROOT,relative),'utf8');
  const ast=compiler.createSourceFile(relative,source,compiler.ScriptTarget.Latest,true);
  const owner=ast.statements.find(node=>node.members?.some(member=>member.name?.getText(ast)===method));
  assert.ok(owner,relative+': actual UI owner');
  const member=owner.members.find(node=>node.name?.getText(ast)===method);let callback;
  const visit=node=>{if(node.kind===compiler.SyntaxKind.CallExpression&&node.expression?.name?.getText(ast)===eventName)
    callback??=node.arguments?.find(arg=>arg.kind===compiler.SyntaxKind.ArrowFunction);compiler.forEachChild(node,visit);};
  visit(member);assert.ok(callback,relative+': actual '+eventName);
  const compiled=compiler.transpileModule('return (function(){ return ('+callback.getText(ast)+'); }).call(this);',
    {compilerOptions:{target:compiler.ScriptTarget.ES2020},reportDiagnostics:true});
  assert.equal((compiled.diagnostics??[]).filter(d=>d.category===compiler.DiagnosticCategory.Error).length,0);
  return new Function(...Object.keys(values),compiled.outputText).call(view,...Object.values(values));
}

{
  const f=fixture(),s=f.storage(),wait=deferred();s.steps.push(wait);let done=false;
  const save=f.manager().saveDesktopNativeGamepad(true).then(()=>{done=true;});await settle();
  assert.equal(done,false);assert.equal(s.cache.get('desktopNativeGamepad'),true);assert.equal(s.disk.get('desktopNativeGamepad'),false);
  assert.equal(f.manager().desktopNativeGamepad,false,'新manager读原确认值，不能mount清屏障');
  wait.resolve();await save;assert.equal(f.manager().desktopNativeGamepad,true);assert.equal(s.disk.get('desktopNativeGamepad'),true);
  passed('native gamepad awaits actual flush; same-owner new manager reads old confirmation, success is durable');
}
{
  const f=fixture(),s=f.storage(),wait=deferred();s.steps.push(wait);f.profile.initialize(f.main);
  const saving=f.profile.setInteraction('touch',f.main);await settle();
  assert.equal(f.profile.interaction(),'auto');assert.equal(f.manager().desktopInteraction,'auto');
  f.profile.initialize(f.main);assert.equal(f.profile.selection().input.productKind,1,'等待中initialize仍用原交互');
  f.profile.freeze();const selected=f.profile.selection();wait.resolve();assert.equal(await saving,false);
  assert.equal(f.profile.selection(),selected);assert.equal(f.profile.interaction(),'touch');assert.equal(f.profile.interactionPending(),true);
  assert.equal(s.disk.get('desktopInteraction'),'touch');const cold=f.coldProfile();cold.initialize(f.main);
  assert.equal(cold.selection().input.productKind,2,'实际下次初始化采纳已持久选择');
  passed('interaction wait/reinitialize/freeze keeps exact current selection; next process adopts durable value');
}
for(const [key,value]of [['desktopNativeGamepad',true],['desktopInteraction','touch']]){
  const f=fixture(),s=f.storage(),wait=deferred();s.steps.push(wait);const method=key==='desktopInteraction'?'saveDesktopInteraction':'saveDesktopNativeGamepad';
  const request=f.manager()[method](value),failure=assert.rejects(request,/disk rejected/);await settle();
  wait.reject(new Error('disk rejected'));await failure;
  assert.equal(f.manager()[key],key==='desktopInteraction'?'auto':false);assert.equal(s.disk.get(key),key==='desktopInteraction'?'auto':false);
  await f.manager()[method](value);assert.equal(s.disk.get(key),value);
  passed(key+' rejection restores old confirmed/cache/disk; explicit retry succeeds');
}
{
  const f=fixture(),s=f.storage();s.failPut();await assert.rejects(f.manager().saveDesktopNativeGamepad(true),/put rejected/);
  assert.equal(f.manager().desktopNativeGamepad,false);assert.equal(s.disk.get('desktopNativeGamepad'),false);
  f.setGame(true);const size=s.calls.length;await assert.rejects(f.manager().saveDesktopNativeGamepad(true),/启动器/);
  await assert.rejects(f.manager().saveDesktopInteraction('touch'),/启动器/);assert.equal(s.calls.length,size);
  await assert.rejects(f.manager({}).saveDesktopNativeGamepad(true),/启动器/);
  passed('put rejection rolls back; game snapshot role rejects both writes before platform IO');
}
{
  const f=fixture(),s=f.storage(),first=deferred(),rollback=deferred();first.partial=true;s.steps.push(first,rollback);
  const pending=f.manager().saveDesktopNativeGamepad(true),failure=assert.rejects(pending,/磁盘回滚尚未确认/);await settle();
  first.reject(new Error('partial disk failure'));await settle();rollback.reject(new Error('rollback disk failure'));await failure;
  assert.equal(s.disk.get('desktopNativeGamepad'),true,'平台边缘实际模拟了部分写盘，不能声称旧磁盘');
  assert.equal(f.manager().desktopNativeGamepad,false,'新manager只保原确认基线');
  await f.manager().saveDesktopNativeGamepad(false);assert.equal(s.disk.get('desktopNativeGamepad'),false);
  passed('rollback flush failure stays disk unknown/old confirmation; same-value explicit retry really writes disk');
}
{
  const f=fixture(),s=f.storage(),wait=deferred();s.steps.push(wait);
  const a=f.manager().saveDesktopNativeGamepad(true),b=f.manager().saveDesktopNativeGamepad(true),c=f.manager().saveDesktopInteraction('touch');
  await settle();assert.deepEqual(s.calls.filter(x=>x[0]==='put'),[['put','desktopNativeGamepad',true]]);
  wait.resolve();await Promise.all([a,b,c]);assert.deepEqual(s.calls.filter(x=>x[0]==='put'),
    [['put','desktopNativeGamepad',true],['put','desktopInteraction','touch']]);
  passed('same-owner duplicate/same-key and cross-key requests serialize; confirmed duplicate is one actual write');
}
{
  const f=fixture(),s=f.storage(),first=deferred(),rollback=deferred();s.steps.push(first,rollback);
  const a=f.manager().saveDesktopNativeGamepad(true),failure=assert.rejects(a,/first disk rejected/);
  const b=f.manager().saveDesktopInteraction('touch');await settle();first.reject(new Error('first disk rejected'));await settle();
  assert.deepEqual(s.calls.filter(x=>x[0]==='put'),[['put','desktopNativeGamepad',true]],'另一键等待原rollback flush完成');
  rollback.resolve();await failure;await b;assert.equal(s.disk.get('desktopNativeGamepad'),false);
  assert.equal(s.disk.get('desktopInteraction'),'touch');
  passed('cross-key queued save waits original failed transaction rollback, then recovers on same owner');
}
{
  const f=fixture(),a=f.storage(),other=f.context('other'),b=f.storage(other),wa=deferred(),wb=deferred();a.steps.push(wa);b.steps.push(wb);
  const ra=f.manager().saveDesktopNativeGamepad(true),rb=f.manager(other).saveDesktopNativeGamepad(true);await settle();
  assert.equal(a.calls.filter(x=>x[0]==='put').length,1);assert.equal(b.calls.filter(x=>x[0]==='put').length,1);
  wa.resolve();await ra;assert.equal(f.manager(other).desktopNativeGamepad,false,'旧owner完成不能清后来owner屏障');
  wb.resolve();await rb;assert.equal(b.disk.get('desktopNativeGamepad'),true);
  passed('genuinely different Preferences owner isolates original queue/read barrier and late completion');
}
for(const relative of [G,T]){
  const f=fixture(),s=f.storage(),wait=deferred();s.steps.push(wait);f.profile.initialize(f.main);f.profile.freeze();
  const selected=f.profile.selection(),view=f.component(relative);let pending;
  if(relative===G){event(view,G,'build','onChange')(true);await settle();pending=view.changeNativeMode_(true);}
  else{event(view,T,'Choice','onClick',{value:'touch'})();await settle();pending=view.changeInteraction_('desktop');}
  await pending;assert.equal(view.saving,true);assert.match(view.saveMessage,/正在保存/);
  assert.equal(relative===G?view.nativeMode:view.interaction,relative===G?false:'auto');
  assert.equal(s.calls.filter(x=>x[0]==='put').length,1,'实际事件闭包重复调用不并发写');
  wait.reject(new Error('UI disk rejected'));await settle();assert.equal(view.saving,false);assert.match(view.saveMessage,/保存失败/);
  assert.equal(relative===G?view.nativeMode:view.interaction,relative===G?false:'auto');assert.equal(f.profile.selection(),selected);
  if(relative===G)await view.changeNativeMode_(true);else await view.changeInteraction_('touch');
  assert.match(view.saveMessage,/已保存/);assert.equal(relative===G?view.nativeMode:view.interaction,relative===G?true:'touch');
  assert.equal(f.profile.selection(),selected);passed(relative+' actual event/UI wait, duplicate rejection, failure, retry and frozen route');
}
for(const relative of [G,T]){
  const f=fixture(),s=f.storage(),wait=deferred();s.steps.push(wait);f.profile.initialize(f.main);f.profile.freeze();
  const view=f.component(relative),operation=relative===G?view.changeNativeMode_(true):view.changeInteraction_('touch');await settle();
  view.aboutToDisappear();view.aboutToAppear();view.saveMessage='new appearance owns this message';
  const value=relative===G?view.nativeMode:view.interaction;wait.resolve();await operation;
  assert.equal(view.saveMessage,'new appearance owns this message');assert.equal(relative===G?view.nativeMode:view.interaction,value);
  passed(relative+' old await cannot overwrite remounted appearance; durable operation remains owned by Preferences');
}
{
  const f=fixture(),s=f.storage(),first=deferred(),rollback=deferred();first.partial=true;s.steps.push(first,rollback);
  const view=f.component(G),saving=view.changeNativeMode_(true);await settle();first.reject(new Error('partial UI disk rejected'));await settle();
  rollback.reject(new Error('UI rollback rejected'));await saving;
  assert.equal(view.nativeMode,false);assert.match(view.saveMessage,/磁盘回滚尚未确认/);assert.equal(view.saving,false);
  await view.changeNativeMode_(true);assert.equal(view.nativeMode,true);assert.match(view.saveMessage,/已保存/);
  passed('actual UI displays rollback disk unknown, retains old value and permits explicit durable retry');
}
{
  const f=fixture(),s=f.storage(),wait=deferred();s.steps.push(wait);const view=f.component(G);
  const first=view.changeNativeMode_(true);await settle();view.aboutToDisappear();view.aboutToAppear();
  const repeat=view.changeNativeMode_(true);await settle();assert.equal(s.calls.filter(x=>x[0]==='put').length,1);
  wait.resolve();await Promise.all([first,repeat]);assert.equal(s.calls.filter(x=>x[0]==='put').length,1);
  assert.equal(view.nativeMode,true);assert.match(view.saveMessage,/已保存/);
  passed('same component remount/repeated desired request cannot cross original owner transaction or duplicate actual write');
}

// 两个内存撤回都必须执行到原行为断言。坏语法/装载失败不得算捕获成功。
{
  const original=fs.readFileSync(path.join(PROJECT_ROOT,P),'utf8');
  const anchor=/await this\.pref\.flush\(\);\r?\n        state\.originals\.delete\(key\);/g;
  assert.equal([...original.matchAll(anchor)].length,1);
  const changed=original.replace(anchor,match=>match.replace('await this.pref.flush()','void this.pref.flush()'));
  const f=fixture({[P]:changed}),s=f.storage(),wait=deferred();s.steps.push(wait);let finished=false;
  const saving=f.manager().saveDesktopNativeGamepad(true).then(()=>{finished=true;});await settle();
  assert.throws(()=>assert.equal(finished,false),assert.AssertionError);wait.resolve();await saving;
  passed('compiled negative removing flush await fails actual completion assertion');
}
{
  const original=fs.readFileSync(path.join(PROJECT_ROOT,P),'utf8');
  const changed=original.replace('if (state !== undefined && state.originals.has(key)) return state.originals.get(key) as LaunchPreferenceValue;',
    '/* negative: expose tentative platform cache */');assert.notEqual(changed,original);
  const f=fixture({[P]:changed}),s=f.storage(),wait=deferred();s.steps.push(wait);
  const saving=f.manager().saveDesktopNativeGamepad(true);await settle();
  assert.throws(()=>assert.equal(f.manager().desktopNativeGamepad,false),assert.AssertionError);wait.resolve();await saving;
  passed('compiled negative removing read barrier fails actual new-manager wait assertion');
}
const after=hashes();assert.deepEqual(after,before,'被测源/loader在执行期间必须保持原身份');
fs.writeFileSync(path.join(output,'receipt.json'),JSON.stringify({startedAt,finishedAt:new Date().toISOString(),
  status:'PASS',groups,sourceBefore:before,sourceAfter:after,sourceDrift:[],scope:'actual production ETS; controlled Preferences/Context/display edges',
  notAttested:['real disk failure','ArkUI rendering','final ArkTS compilation','device/native gamepad current route','SDK/HAP/APP']},null,2));
console.log('PASS frozen settings '+groups.length+' source-bound groups; receipt '+path.join(output,'receipt.json'));
