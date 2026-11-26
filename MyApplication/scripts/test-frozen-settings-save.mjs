/**
 * 两项冻结设置的实际生产源回归。只控制Preferences put/flush、Context及显示边缘，
 * 保存串行、旧值读屏障、回滚、运行路线冻结与UI续体均由原ETS实现执行。
 * 不运行ArkUI Builder或真实磁盘/设备；明确不替代ArkTS产品编译和真机显示验证。
 */
import assert from 'node:assert/strict';
import { verifySkillCases } from './lib/skill-business-check.mjs';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { loadActionComponent } from './lib/unified-actions-fixture.mjs';
import { environment } from './lib/ets-runtime-fixture.mjs';
import compiler from './lib/ets-compiler.mjs';
import { PROJECT_ROOT, assertExternalOutputPath, resolveWorkspacePath } from './lib/workspace-paths.mjs';

const P='feature_system/src/main/ets/PreferenceManager.ets';
const storageSource='feature_system/src/main/ets/GameStorage.ets';
const R='entry/src/main/ets/product/RuntimeProductProfile.ets';
const T='entry/src/main/ProductTouchSettings.ets';
const mobilePreference='entry/src/main/ets/runtime/MobileInputPreference.ets';
const mobileSkill='entry/src/main/ets/launcherskill/MobileInputSkill.ets';
const sources=[P,R,T,mobilePreference,mobileSkill,storageSource,'entry/src/main/ets/pages/Index.ets','gamecontrol/src/main/ets/ProductRuntimePolicy.ets',
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
function fixture(overrides={}, deviceType='2in1', sdkApiVersion=26, family='universal'){
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
      deleteSync:key=>{calls.push(['delete',key]);cache.delete(key);},
      put:async(key,value)=>{calls.push(['put',key,value]);cache.set(key,value);if(failPut){failPut=false;throw new Error('put rejected');}},
      flush:async()=>{calls.push(['flush']);const values=new Map(cache),step=steps.shift();
        try{if(step)await step.promise;}catch(error){if(step.partial)for(const[k,v]of values)disk.set(k,v);throw error;}
        disk.clear();for(const[k,v]of values)disk.set(k,v);}};
    const value={store,cache,disk,calls,steps,failPut:()=>{failPut=true;}};stores.set(ctx.preferencesDir,value);return value;
  }
  const commons={ProcessPreferences:{open:ctx=>storage(ctx).store,isGameProcess:()=>game},formatError:String,
    AppLogger:{info(){}},LOG_DOMAIN_LAUNCH:1,DeviceProfile:{isPC:()=>true},JDK_AUTO:'auto',DEFAULT_GAME_LANGUAGE:'zh_cn',
    ...makePureEtsLoader()('commons/src/main/ets/common/GameLanguages.ets'),
    isJdkSlotVersion:makePureEtsLoader()('commons/src/main/ets/common/Constants.ets').isJdkSlotVersion,
    ...makePureEtsLoader()('commons/src/main/ets/common/GameResolutionPolicy.ets')};
  const prefLoad=makePureEtsLoader({commons,'@kit.PerformanceAnalysisKit':{hilog:{warn(){}}}},overrides);
  const PreferenceManager=prefLoad(P).PreferenceManager;
  const pure=makePureEtsLoader(),policy=pure('gamecontrol/src/main/ets/ProductRuntimePolicy.ets');
  const imports={commons,'feature_system':{PreferenceManager},gamecontrol:policy,
    '@ohos.deviceInfo':{default:{deviceType,sdkApiVersion}},
    'libentry.so':{default:{hardwareRawMouseAvailable:()=>true,desktopGameProcessState:()=>1}},
    'entry/ProductBuildProfile':{ProductBuildProfile:{family,runtimeRawMouse:true,touchControls:family!=='desktop'}}};
  const runtimeLoad=makePureEtsLoader(imports,overrides),profile=runtimeLoad(R).RuntimeProductProfile;
  const notices=[], visibility=new Map([['amclSettingsTabVisible',true],['appInForeground',true]]);
  const ui=environment({globals:{AppStorage:{get:key=>visibility.get(key)}},imports:{...imports,'entry/ProductInputProfile':{ProductInputProfile:profile},
    './ets/components/AppIcon':{AppIcon:{}}},sourceOverrides:Object.fromEntries(Object.entries(overrides)
      .map(([key,value])=>[key,()=>value]))});
  const component=(name,ctx=main)=>{const Class=ui.load(name,true)['ProductTouchSettings'];
    const view=new Class();view.getUIContext=()=>({getHostContext:()=>ctx,getPromptAction:()=>({showToast:notice=>notices.push(notice)})});
    view.aboutToAppear();return view;};
  return {PreferenceManager,manager:ctx=>new PreferenceManager(ctx??main),profile,context,main,storage,component,notices,visibility,
    setGame:value=>{game=value;},coldProfile:()=>makePureEtsLoader(imports,overrides)(R).RuntimeProductProfile};
}

/** Builder仍不执行；只抽真实事件闭包，验证GUI保存入口确实调用了被测生产方法。 */
function event(view,relative,method,eventName,values={}){
  const source=fs.readFileSync(path.join(PROJECT_ROOT,relative),'utf8');
  const ast=compiler.createSourceFile(relative,source,compiler.ScriptTarget.Latest,true);
  const owner=ast.statements.find(node=>node.members?.some(member=>member.name?.getText(ast)===method));
  assert.ok(owner,relative+': actual UI owner');
  const member=owner.members.find(node=>node.name?.getText(ast)===method);let callback;
  const visit=node=>{
    if(compiler.isPropertyAssignment(node) && node.name.getText(ast)===eventName && compiler.isArrowFunction(node.initializer))
      callback??=node.initializer;
    if(node.kind===compiler.SyntaxKind.CallExpression && node.expression?.name?.getText(ast)===eventName)
      callback??=node.arguments?.find(arg=>arg.kind===compiler.SyntaxKind.ArrowFunction);
    compiler.forEachChild(node,visit);
  };
  visit(member);assert.ok(callback,relative+': actual '+eventName);
  const compiled=compiler.transpileModule('return (function(){ return ('+callback.getText(ast)+'); }).call(this);',
    {compilerOptions:{target:compiler.ScriptTarget.ES2020},reportDiagnostics:true});
  assert.equal((compiled.diagnostics??[]).filter(d=>d.category===compiler.DiagnosticCategory.Error).length,0);
  return new Function(...Object.keys(values),compiled.outputText).call(view,...Object.values(values));
}

{
  // 直接执行设置页传入的生产回调；失败、在途、成功三种刷盘结果应驱动不同的页面和 Native 结果。
  const source='entry/src/main/ets/pages/Index.ets', f=fixture(), backing=f.storage(), manager=f.manager();
  const Host=loadActionComponent(source,'Index',{methods:['saveLauncherChange_'],
    dependencies:{commons:{AppLogger:{warn(){}},LOG_DOMAIN_LAUNCH:1}},globals:{TAG:'test'}});
  const page=new Host(), native=[];
  Object.assign(page,{ohosFrameRateCap:0,ohosFixedRefreshRate:0,getPrefManager_:()=>manager,safeToast_(){}});
  const cap=event(page,source,'LauncherContent_','onOhosFrameRateCapChange',{testNapi:{setOhosFrameRateCap(value){
    native.push({value,stored:backing.disk.get('ohosFrameRateCap'),displayed:page.ohosFrameRateCap});return true;
  }}});
  for(const reject of [true,false]){
    const wait=deferred();backing.steps.push(wait);
    const pending=cap(120);await settle();
    assert.equal(page.ohosFrameRateCap,0);assert.deepEqual(native,[]);
    if(reject)wait.reject(Error('frame cap flush failed'));else wait.resolve();
    assert.equal(await pending,!reject);
    if(reject){assert.equal(page.ohosFrameRateCap,0);assert.deepEqual(native,[]);}
  }
  assert.deepEqual(native,[{value:120,stored:120,displayed:120}]);
  const fixed=event(page,source,'LauncherContent_','onOhosFixedRefreshRateChange');
  assert.equal(await fixed(90),true);assert.equal(backing.disk.get('ohosFixedRefreshRate'),90);
  assert.equal(page.ohosFixedRefreshRate,90);assert.equal(page.ohosFrameRateCap,120);assert.equal(native.length,1);
  passed('scheduler cap reaches Native with confirmed state; fixed display preference stays independently stored');
}
{
  const f=fixture(),s=f.storage(),wait=deferred();
  const Page=loadActionComponent('entry/src/main/ets/pages/Index.ets','Index',{methods:['onPrivacyAgree']});
  let resumed=0;
  const page=new Page();
  Object.assign(page,{savingPrivacy_:false,startupAlive_:true,showPrivacy:true,getPrefManager_:()=>f.manager(),
    safeToast_(){},resumeRecoveryPresentation_(){resumed++;},onOpenErrorSheetReq(){},initRuntimeUpdateCheck_(){}});
  s.steps.push(wait);
  const pending=page.onPrivacyAgree();await settle();
  assert.equal(page.showPrivacy,true);assert.equal(f.manager().readPrivacyConsent(),undefined);
  await page.onPrivacyAgree();
  wait.reject(Error('refused privacy flush'));await pending;
  assert.equal(page.showPrivacy,true);assert.equal(f.manager().privacyAgreed,false);assert.equal(resumed,0);
  await page.onPrivacyAgree();assert.equal(page.showPrivacy,false);assert.equal(s.disk.get('privacyAgreed'),true);assert.equal(resumed,1);
  passed('store consent stays gated during flush and on failure, only confirmed human choice opens the launcher');
}

// 两个独立模块域模拟平板前后台进程，只替换平台文件与通知边缘；实际读写、订阅和具名业务共用生产函数。
{
  const context={filesDir:'/sandbox/mobile-input'}, file=context.filesDir+'/mobile-input-mode';
  const files=new Map(), watchers=new Set();
  let failWrite=false, failRead=false, reads=0;
  const fileIo={
    readTextSync(name) {
      reads++;
      if(failRead)throw Object.assign(Error('read denied'),{code:13900012});
      if(!files.has(name))throw Object.assign(Error('missing'),{code:13900002});
      return files.get(name);
    },
    createWatcher(path,mask,listener) {
      assert.equal(path,context.filesDir);assert.equal(mask,0x80);
      return {start:()=>watchers.add(listener),stop:()=>watchers.delete(listener)};
    }
  };
  function processView(form,api,family='universal') {
    const product=fixture({},form,api,family).profile;
    const imports={
      '@kit.CoreFileKit':{fileIo}, 'entry/ProductInputProfile':{ProductInputProfile:product},
      commons:{AtomicFileWriter:{write(name,mode){if(failWrite)throw Error('write denied');files.set(name,mode);}},
        AppLogger:{warn(){}},LOG_DOMAIN_LAUNCH:1}
    };
    const pref=makePureEtsLoader(imports)(mobilePreference).MobileInputPreference;
    const method=makePureEtsLoader({'../runtime/MobileInputPreference':{MobileInputPreference:pref}})(mobileSkill).mobileInputSkill;
    return {pref,call:(name,args)=>method(context,name,args)};
  }
  const launcher=processView('tablet',20),game=processView('tablet',20);
  const get='getMobileInputMode',set='setMobileInputMode';
  for(const [form,api,family,enabled] of [['phone',20,'universal',true],['tablet',21,'universal',true],
    ['2in1',26,'universal',false],['2in1',26,'desktop',false],['phone',26,'desktop',false],['watch',26,'universal',false]]) {
    const owner=processView(form,api,family);
    assert.equal(owner.pref.available(),enabled);
    if(!enabled)assert.equal(owner.call(set,{mode:'kbm'}).state,'unavailable');
  }
  const initial=launcher.call(get,{});
  assert.deepEqual(initial,{state:'ready',mode:'auto'});
  verifySkillCases(get,initial,launcher.call(get,{extra:true}),'L106');
  const main=[],child=[],other=[];
  const stopMain=launcher.pref.subscribe(context,v=>main.push(v));
  const stopChild=game.pref.subscribe(context,v=>child.push(v));
  const stopOther=game.pref.subscribe(context,v=>other.push(v));
  assert.equal(watchers.size,2,'一个进程内复用一个目录监听');
  assert.deepEqual(main,['auto']);assert.deepEqual(other,['auto']);
  const saved=launcher.call(set,{mode:'gamepad'});
  assert.deepEqual(saved,{state:'ready',mode:'gamepad'});
  verifySkillCases(set,saved,launcher.call(set,{mode:'desktop'}),'L106');
  assert.deepEqual(main,['auto','gamepad']);assert.deepEqual(child,['auto']);
  const notify=(name=file)=>{for(const callback of watchers)callback({fileName:name,event:0x80});};
  notify(file+'.other');assert.deepEqual(child,['auto']);
  notify();notify();
  assert.deepEqual(child,['auto','gamepad']);assert.deepEqual(other,child);
  stopOther();
  game.pref.save(context,'kbm');
  assert.equal(launcher.pref.read(context),'kbm','启动器回读游戏进程的设置');
  notify();assert.deepEqual(main,['auto','gamepad','kbm']);assert.deepEqual(child,main);
  assert.deepEqual(other,['auto','gamepad']);
  failWrite=true;assert.equal(game.call(set,{mode:'auto'}).state,'unknown');failWrite=false;
  assert.equal(game.pref.read(context),'kbm');notify();assert.equal(child.length,3);
  failRead=true;assert.equal(launcher.call(get,{}).state,'unknown');failRead=false;
  files.set(file,'broken');assert.equal(game.call(get,{}).state,'unknown');
  assert.equal(launcher.call(set,{mode:'auto'}).state,'ready');
  const oldCallbacks=[...watchers];stopChild();stopMain();assert.equal(watchers.size,0);
  const next=game.pref.subscribe(context,v=>other.push(v));
  files.set(file,'kbm');oldCallbacks.forEach(cb=>cb({fileName:file,event:0x80}));
  assert.equal(other.at(-1),'auto');notify();assert.equal(other.at(-1),'kbm');
  next();assert.equal(watchers.size,0);
  passed('mobile input mode uses one live preference in two process domains with atomic save, hot notifications, product admission and QA readback');

  // 控制的仅是系统时钟。测试瞬时读错、第二次仍失败、显式回前台、停止后已排队的旧定时回调。
  const realSet=globalThis.setTimeout,realClear=globalThis.clearTimeout;
  const timers=new Map();
  let sequence=0;
  globalThis.setTimeout=(fn,delay)=>{
    assert.ok(delay>0 && delay<=1000,'补读须有界延时');timers.set(++sequence,fn);return sequence;
  };
  globalThis.clearTimeout=id=>timers.delete(id);
  function fireRetry(){
    assert.equal(timers.size,1);
    const [id,fn]=timers.entries().next().value;timers.delete(id);fn();
  }
  try {
    const received=[], replacement=[];
    const leaveMain=launcher.pref.subscribe(context,()=>{});
    const leaveGame=game.pref.subscribe(context,v=>received.push(v));
    const [,gameEvent]=watchers;
    const signal=()=>gameEvent({fileName:file,event:0x80});
    launcher.pref.save(context,'gamepad');
    failRead=true;signal();signal();assert.deepEqual(received,['kbm']);
    failRead=false;fireRetry();
    assert.deepEqual(received,['kbm','gamepad'],'无后续文件事件也采纳另一进程的保存');
    assert.equal(timers.size,0);

    launcher.pref.save(context,'auto');
    failRead=true;signal();fireRetry();
    assert.equal(timers.size,0,'持续失败不会重新排程');
    failRead=false;game.pref.reconcile(context);
    assert.equal(received.at(-1),'auto','可见边界刷新已有观察者');
    launcher.pref.save(context,'gamepad');
    failRead=true;signal();
    const obsolete=timers.values().next().value;
    leaveGame();assert.equal(timers.size,0);
    failRead=false;
    const leaveReplacement=game.pref.subscribe(context,v=>replacement.push(v));
    launcher.pref.save(context,'kbm');const beforeLate=reads;
    obsolete();signal();
    assert.equal(reads,beforeLate);
    assert.deepEqual(received,['kbm','gamepad','auto']);
    assert.deepEqual(replacement,['gamepad'],'旧观察者不得发布到新一轮界面');
    leaveReplacement();leaveMain();
    const afterUnmount=reads;game.pref.reconcile(context);assert.equal(reads,afterUnmount);
    assert.equal(watchers.size,0);
  } finally {
    globalThis.setTimeout=realSet;globalThis.clearTimeout=realClear;
  }
  passed('mobile preference retries a transient cross-process read once, reconciles on visibility and fences retired observers');
}

// 旧包中的手柄开关不参与设置接口，桌面交互模式仍按当前产品策略读写。
{
  const f=fixture();f.profile.initialize(f.main);const panel=f.component(T);
  const read=await panel.skillInteraction_('getDesktopInteraction',{});
  assert.equal(read.mode,'auto');
  verifySkillCases('getDesktopInteraction',read,await panel.skillInteraction_('getDesktopInteraction',{unexpected:true}),'L063');
  const saved=await panel.skillInteraction_('setDesktopInteraction',{mode:'touch'});assert.equal(saved.mode,'touch');
  verifySkillCases('setDesktopInteraction',saved,await panel.skillInteraction_('setDesktopInteraction',{mode:'invalid'}),'L063');
  assert.throws(()=>f.manager().strictLauncherField('desktopNativeGamepad'),/未知设置项/);
  assert.equal(f.storage().disk.get('desktopNativeGamepad'),false);
  panel.aboutToDisappear();
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
{
  const f=fixture(),s=f.storage();s.failPut();await assert.rejects(f.manager().saveDesktopInteraction('touch'),/put rejected/);
  assert.equal(f.manager().desktopInteraction,'auto');assert.equal(s.disk.get('desktopInteraction'),'auto');
  f.setGame(true);const size=s.calls.length;await assert.rejects(f.manager().saveDesktopInteraction('touch'),/启动器/);
  assert.equal(s.calls.length,size);
  await assert.rejects(f.manager({}).saveDesktopInteraction('touch'),/启动器/);
  passed('put rejection rolls back; game snapshot role rejects both writes before platform IO');
}
{
  const f=fixture(),s=f.storage(),first=deferred(),rollback=deferred();first.partial=true;s.steps.push(first,rollback);
  const pending=f.manager().saveDesktopInteraction('touch'),failure=assert.rejects(pending,/磁盘回滚尚未确认/);await settle();
  first.reject(new Error('partial disk failure'));await settle();rollback.reject(new Error('rollback disk failure'));await failure;
  assert.equal(s.disk.get('desktopInteraction'),'touch','平台边缘实际模拟了部分写盘，不能声称旧磁盘');
  assert.equal(f.manager().desktopInteraction,'auto','新manager只保原确认基线');
  await f.manager().saveDesktopInteraction('auto');assert.equal(s.disk.get('desktopInteraction'),'auto');
  passed('rollback flush failure stays disk unknown/old confirmation; same-value explicit retry really writes disk');
}
{
  const f=fixture(),s=f.storage(),wait=deferred();s.steps.push(wait);
  const a=f.manager().saveDesktopInteraction('touch'),b=f.manager().saveDesktopInteraction('touch'),c=f.manager().recordPrivacyConsent();
  await settle();assert.deepEqual(s.calls.filter(x=>x[0]==='put'),[['put','desktopInteraction','touch']]);
  wait.resolve();await Promise.all([a,b,c]);assert.deepEqual(s.calls.filter(x=>x[0]==='put'),
    [['put','desktopInteraction','touch'],['put','privacyAgreed',true]]);
  passed('same-owner duplicate/same-key and cross-key requests serialize; confirmed duplicate is one actual write');
}
{
  const f=fixture(),s=f.storage(),first=deferred(),rollback=deferred();s.steps.push(first,rollback);
  const a=f.manager().saveDesktopInteraction('touch'),failure=assert.rejects(a,/first disk rejected/);
  const b=f.manager().recordPrivacyConsent();await settle();first.reject(new Error('first disk rejected'));await settle();
  assert.deepEqual(s.calls.filter(x=>x[0]==='put'),[['put','desktopInteraction','touch']],'另一键等待原rollback flush完成');
  rollback.resolve();await failure;await b;assert.equal(s.disk.get('desktopInteraction'),'auto');
  assert.equal(s.disk.get('privacyAgreed'),true);
  passed('cross-key queued save waits original failed transaction rollback, then recovers on same owner');
}
{
  const f=fixture(),a=f.storage(),other=f.context('other'),b=f.storage(other),wa=deferred(),wb=deferred();a.steps.push(wa);b.steps.push(wb);
  const ra=f.manager().saveDesktopInteraction('touch'),rb=f.manager(other).saveDesktopInteraction('touch');await settle();
  assert.equal(a.calls.filter(x=>x[0]==='put').length,1);assert.equal(b.calls.filter(x=>x[0]==='put').length,1);
  wa.resolve();await ra;assert.equal(f.manager(other).desktopInteraction,'auto','旧owner完成不能清后来owner屏障');
  wb.resolve();await rb;assert.equal(b.disk.get('desktopInteraction'),'touch');
  passed('genuinely different Preferences owner isolates original queue/read barrier and late completion');
}
{
  const relative=T;
  const f=fixture(),s=f.storage(),wait=deferred();s.steps.push(wait);f.profile.initialize(f.main);f.profile.freeze();
  const selected=f.profile.selection(),view=f.component(relative);let pending;
  event(view,T,'Choice','onClick',{value:'touch'})();await settle();pending=view.changeInteraction_('desktop');
  await pending;assert.equal(view.saving,true);assert.match(view.saveMessage,/正在保存/);
  assert.equal(view.interaction,'auto');
  assert.equal(s.calls.filter(x=>x[0]==='put').length,1,'实际事件闭包重复调用不并发写');
  wait.reject(new Error('UI disk rejected'));await settle();assert.equal(view.saving,false);assert.match(view.saveMessage,/保存失败/);
  assert.equal(view.interaction,'auto');assert.equal(f.profile.selection(),selected);
  await view.changeInteraction_('touch');assert.match(view.saveMessage,/已保存/);
  assert.equal(view.interaction,'touch');
  assert.equal(f.profile.selection(),selected);passed(relative+' actual event/UI wait, duplicate rejection, failure, retry and frozen route');
}
{
  const relative=T;
  const f=fixture(),s=f.storage(),wait=deferred();s.steps.push(wait);f.profile.initialize(f.main);f.profile.freeze();
  const view=f.component(relative),operation=view.changeInteraction_('touch');await settle();
  view.aboutToDisappear();view.aboutToAppear();view.saveMessage='new appearance owns this message';
  const value=view.interaction;wait.resolve();await operation;
  assert.equal(view.saveMessage,'new appearance owns this message');assert.equal(view.interaction,value);
  assert.deepEqual(f.notices,[],'退出旧页面的保存续体不弹消息');
  passed(relative+' old await cannot overwrite remounted appearance; durable operation remains owned by Preferences');
}
// 两个内存撤回都必须执行到原行为断言。坏语法/装载失败不得算捕获成功。
{
  const original=fs.readFileSync(path.join(PROJECT_ROOT,P),'utf8');
  const anchor=/await this\.pref\.flush\(\);\r?\n        state\.originals\.delete\(key\);/g;
  // 负对照只撤回被测冻结设置方法，其他功能也可以合法使用相同的持久化屏障。
  const methodStart=original.indexOf('  private saveFrozenSetting_(');
  const methodEnd=original.indexOf('  /** 交互模式保存',methodStart);
  assert.ok(methodStart>=0&&methodEnd>methodStart);
  const method=original.slice(methodStart,methodEnd);
  assert.equal([...method.matchAll(anchor)].length,1);
  const changed=original.slice(0,methodStart)+method.replace(anchor,match=>match.replace('await this.pref.flush()','void this.pref.flush()'))+original.slice(methodEnd);
  const f=fixture({[P]:changed}),s=f.storage(),wait=deferred();s.steps.push(wait);let finished=false;
  const saving=f.manager().saveDesktopInteraction('touch').then(()=>{finished=true;});await settle();
  assert.throws(()=>assert.equal(finished,false),assert.AssertionError);wait.resolve();await saving;
  passed('compiled negative removing flush await fails actual completion assertion');
}
{
  const original=fs.readFileSync(path.join(PROJECT_ROOT,P),'utf8');
  const changed=original.replace('if (state !== undefined && state.originals.has(key)) return state.originals.get(key) as LaunchPreferenceValue;',
    '/* negative: expose tentative platform cache */');assert.notEqual(changed,original);
  const f=fixture({[P]:changed}),s=f.storage(),wait=deferred();s.steps.push(wait);
  const saving=f.manager().saveDesktopInteraction('touch');await settle();
  assert.throws(()=>assert.equal(f.manager().desktopInteraction,'auto'),assert.AssertionError);wait.resolve();await saving;
  passed('compiled negative removing read barrier fails actual new-manager wait assertion');
}
{
  const f=fixture(), owner=f.manager(), reader=f.manager(), disk=f.storage();
  const wait=deferred();disk.steps.push(wait);
  const first=owner.saveLauncherFields({mcXmx:4096});await settle();
  assert.equal(reader.mcXmx,0,'flush未确认时读取的是旧基线');
  const source=reader.saveLauncherFields({mcSource:'mirror'});await settle();
  assert.equal(reader.mcSource,'auto');
  wait.resolve();await first;await source;
  assert.equal(disk.disk.get('mcXmx'),4096);assert.equal(reader.mcSource,'mirror');
  for(const [key,value] of [['mcXmx',512],['virtualMemoryMode',true],['mcVersion','new-instance'],['versionOrder','["new-instance"]'],
    ['mcSource','official'],['modSource','mcim'],['jdkSource','gitee'],['cacheRemoteMeta',false],['accelDownload',true]]) {
    const rejected=deferred();rejected.partial=true;disk.steps.push(rejected);
    const before=disk.disk.get(key), pending=owner.saveLauncherFields({[key]:value});
    await settle();rejected.reject(Error('injected disk failure'));await assert.rejects(pending,/injected/);
    assert.equal(disk.disk.get(key),before,key+'须恢复原磁盘值或不存在状态');
  }
  await owner.saveLauncherFields({jdkWebEnabled:true});
  await reader.saveLauncherFields({jdkSource:'web'});
  const rejected=deferred();rejected.partial=true;disk.steps.push(rejected);
  const disabling=owner.saveLauncherFields({jdkWebEnabled:false});await settle();
  assert.equal(reader.jdkWebEnabled,true);assert.equal(reader.jdkSource,'web');
  rejected.reject(Error('batch'));await assert.rejects(disabling,/batch/);
  assert.equal(disk.disk.get('jdkSource'),'web');assert.equal(disk.disk.get('jdkWebEnabled'),true);
  await owner.saveLauncherFields({jdkWebEnabled:false});assert.equal(reader.jdkSource,'auto');
  await assert.rejects(owner.saveLauncherFields({jdkSource:'web'}));
  passed('launcher scalar writes and dependent JDK source changes cross actual flush; failures restore prior keys');
}
{
  const f=fixture(), manager=f.manager(), disk=f.storage();
  const name='vanilla',key='verLaunch.'+name;
  await manager.saveVersionChoice(name,'jdk','17');
  await manager.saveVersionChoice(name,'language','en_us');
  const rejected=deferred();rejected.partial=true;disk.steps.push(rejected);
  const pending=manager.saveVersionChoice(name,'language','zh_cn');await settle();
  assert.equal(f.manager().getVersionOverride(name).gameLanguage,'en_us');
  rejected.reject(Error('language flush'));await assert.rejects(pending,/language flush/);
  const chosen=JSON.parse(disk.disk.get(key));
  assert.equal(chosen.gameLanguage,'en_us');assert.equal(chosen.jdkVersion,'17');
  await Promise.all([manager.saveVersionChoice(name,'jdk','21'),f.manager().saveVersionChoice(name,'language','fr_fr')]);
  const confirmed=JSON.parse(disk.disk.get(key));assert.equal(confirmed.jdkVersion,'21');assert.equal(confirmed.gameLanguage,'fr_fr');
  passed('per-instance Java and language share the version owner, retaining sibling fields across rollback and concurrent writes');
}
{
  const f=fixture(), store=f.storage(), manager=f.manager();
  const Host=loadActionComponent('entry/src/main/ets/pages/Index.ets','Index',{
    methods:['selectManagedVersion_','onReorderVersions','saveLauncherChange_','setManagedJdk_'],
    dependencies:{commons:{AppLogger:{warn(){}},LOG_DOMAIN_LAUNCH:1}},
    globals:{TAG:'test'}
  });
  const page=new Host();
  Object.assign(page,{getPrefManager_:()=>manager,mcRoot:()=>'/app/root',safeToast_(){},scanInstalledModsCount(){},
    updateJdkReadyState(){},forceStoreSourceRecheck_(){},availableVersions:['A','B'],mcVersion:'A'});
  await manager.saveLauncherFields({mcVersion:'A',versionOrder:'["A","B"]'});
  for (const request of [()=>page.selectManagedVersion_('B'),()=>page.onReorderVersions(['B','A']),()=>page.setManagedJdk_('B','17')]) {
    const rejected=deferred();rejected.partial=true;store.steps.push(rejected);
    const pending=request();await settle();assert.equal(page.mcVersion,'A');assert.deepEqual(page.availableVersions,['A','B']);
    rejected.reject(Error('real owner flush failure'));assert.equal(await pending,false);
    assert.equal(store.disk.get('mcVersion'),'A');assert.equal(store.disk.get('versionOrder'),'["A","B"]');
    assert.equal(manager.getVersionOverride('B').jdkVersion,'');
  }
  const gate=deferred();store.steps.push(gate);const selected=page.selectManagedVersion_('B');
  await settle();assert.equal(manager.launcherPreferencesConfirmed(),false);assert.equal(page.mcVersion,'A');
  gate.resolve();assert.equal(await selected,true);assert.equal(manager.launcherPreferencesConfirmed(),true);assert.equal(page.mcVersion,'B');
  passed('actual launcher owner waits for real preference confirmation; rejected version, order and JDK never publish');
}
{
  const f=fixture(), p=f.manager(), backing=f.storage(), originalRead=backing.store.getSync;
  const project=makePureEtsLoader({commons:{},update:{UpdateChecker:{installedIdentity:()=>undefined}},feature_system:{}})
    ('entry/src/main/ets/launcherskill/ConfirmedSettings.ets').readConfirmedSetting;
  const Page=loadActionComponent('entry/src/main/ets/pages/tabs/SettingsTab.ets','SettingsTab',{
    methods:['readSkillSetting_','skillChoiceKind_'],dependencies:{commons:{},'entry/ProductInputProfile':{},
      '../../components/TouchLearningStore':{},'../../launcherskill/SettingsSkillValues':{}}
  });
  const page=new Page();page.readCommittedSettings=id=>project(p,id);page.choiceOptions_=()=>[];
  const list=['memory','java','isolation','process','frame-rate','language','mc-source','mod-source','jdk-source','remote-cache','storage','jdk-update'];
  assert.equal(page.readSkillSetting_('remote-cache').enabled,true,'confirmed absent key has documented default');
  backing.cache.set('cacheRemoteMeta',false);
  backing.cache.set('verLaunch.A',JSON.stringify({gameLanguage:'en_us',jdkVersion:'17'}));
  assert.equal(page.readSkillSetting_('remote-cache').enabled,false);
  assert.equal(p.strictVersionOverride('A').gameLanguage,'en_us');
  assert.equal(p.strictVersionOverride('absent').jdkVersion,'');
  backing.store.getSync=()=>{throw Error('read denied');};
  for(const id of list) assert.equal(page.readSkillSetting_(id).state,'unknown',id);
  assert.throws(()=>p.strictVersionOverride('A'),/read denied/);
  assert.throws(()=>p.strictVersionOrder(),/read denied/);
  assert.throws(()=>p.resolveLaunch('A',true),/read denied/);
  assert.equal(p.cacheRemoteMeta,true,'ordinary UI retains existing fallback');
  backing.store.getSync=originalRead;
  for(const [field,invalid] of [['mcXmx',-3],['jdkSource','unregistered'],['jdkChannel','unknown'],['cacheRemoteMeta','yes']]) {
    backing.cache.set(field,invalid);assert.throws(()=>p.strictLauncherField(field));backing.cache.delete(field);
  }
  backing.cache.set('verLaunch.A','{');assert.throws(()=>p.strictVersionOverride('A'));
  backing.cache.set('verLaunch.A','{"xmx":"broken","jdkVersion":"17"}');assert.throws(()=>p.strictVersionOverride('A'));
  backing.cache.set('versionOrder','["A",42]');assert.throws(()=>p.strictVersionOrder());
  const op=deferred();backing.steps.push(op);const saving=p.saveLauncherFields({mcXmx:4096});await settle();
  assert.equal(page.readSkillSetting_('memory').state,'unknown');
  assert.equal(page.readSkillSetting_('remote-cache').state,'ready','unrelated confirmed key is readable');
  op.resolve();await saving;
  assert.equal(page.readSkillSetting_('memory').megabytes,4096);
  passed('official settings and version reads distinguish absent, denied, corrupted and in-flight stores; no manufactured success');
}
{
  // 系统可用性在这里受控；实际目录读写及新旧安装识别由文件访问套件执行。
  function install(fresh, available) {
    const f=fixture(), manager=f.manager(), disk=f.storage(), attempts=[];
    const api=environment().load(storageSource).GameStorage;
    api.isFreshInstall=()=>fresh;
    api.prepareExternal=async (_ctx,_pref,requestPermission)=>{
      attempts.push(requestPermission);
      return available ? 'ready' : 'unavailable';
    };
    return {manager,disk,api,attempts,start:()=>api.prepareStartupLocation(f.main,manager,()=>true)};
  }
  for(const [fresh,available,expected] of [[true,true,'external'],[true,false,'sandbox'],[false,true,'sandbox']]) {
    const app=install(fresh,available), gate=deferred();
    assert.equal(app.manager.storedMcStorageLocation(),undefined);
    app.disk.steps.push(gate);
    let delivered=false;
    const pending=app.start().then(location=>{delivered=true;return location;});
    await settle();assert.equal(delivered,false);
    gate.resolve();assert.equal(await pending,expected);
    assert.equal(app.disk.disk.get('mcStorageLocation'),expected);
    assert.deepEqual(app.attempts,fresh?[true]:[]);
    assert.equal(await app.start(),expected);
    assert.deepEqual(app.attempts,expected==='external'?[true,false]:fresh?[true]:[]);
  }
  const explicit=install(true,true);
  await explicit.manager.saveLauncherFields({mcStorageLocation:'sandbox'});
  assert.equal(await explicit.start(),'sandbox');assert.deepEqual(explicit.attempts,[]);
  const withdrawn=install(false,false);
  await withdrawn.manager.saveLauncherFields({mcStorageLocation:'external'});
  assert.equal(await withdrawn.start(),'sandbox');assert.deepEqual(withdrawn.attempts,[false]);
  assert.equal(withdrawn.disk.disk.get('mcStorageLocation'),'external');
  withdrawn.api.prepareExternal=async()=>'ready';
  assert.equal(await withdrawn.start(),'external');
  // 在会话回退期间，玩家也能把内部设为今后的首选。执行实际页面入口，仅保存，无需复制。
  const storageModule=environment().load(storageSource);
  const Home=loadActionComponent('entry/src/main/ets/pages/Index.ets','Index',{
    methods:['handleStorageLocationChange','saveLauncherChange_'],
    dependencies:{feature_system:storageModule,commons:{AppLogger:{warn(){}},LOG_DOMAIN_LAUNCH:0}},globals:{TAG:'test'}
  });
  const home=new Home();
  Object.assign(home,{startupAlive_:true,storageLocation:'sandbox',getPrefManager_:()=>withdrawn.manager,
    safeToast_(){},promptSwitchStorage(){assert.fail('same directory must not be copied');}});
  assert.equal(await new Promise(done=>home.handleStorageLocationChange('sandbox',true,done)),'saved');
  assert.equal(withdrawn.disk.disk.get('mcStorageLocation'),'sandbox');
  const racing=install(true,true), picker=deferred();
  racing.api.prepareExternal=()=>picker.promise;
  const pending=racing.start();
  await racing.manager.saveLauncherFields({mcStorageLocation:'sandbox'});
  picker.resolve('ready');assert.equal(await pending,'sandbox');
  assert.equal(racing.disk.disk.get('mcStorageLocation'),'sandbox');
  // 已选外部的旧页面在等目录时，另一个窗口也可先完成手动切换。
  const duringProbe=install(false,true), probing=deferred(), entered=deferred();
  await duringProbe.manager.saveLauncherFields({mcStorageLocation:'external'});
  duringProbe.api.prepareExternal=()=>{entered.resolve();return probing.promise;};
  const oldWindow=duringProbe.start();await entered.promise;
  await duringProbe.manager.saveLauncherFields({mcStorageLocation:'sandbox'});
  probing.resolve('ready');assert.equal(await oldWindow,'sandbox');
  const duringWrite=install(true,true), saving=deferred();duringWrite.disk.steps.push(saving);
  const manual=duringWrite.manager.saveLauncherFields({mcStorageLocation:'sandbox'});await settle();
  const opening=duringWrite.start();saving.resolve();await manual;
  assert.equal(await opening,'sandbox');assert.deepEqual(duringWrite.attempts,[]);
  const failed=install(true,true);
  const flush=deferred();failed.disk.steps.push(flush);
  const first=failed.start();await settle();flush.reject(Error('storage preference flush failed'));
  await assert.rejects(first);
  assert.equal(failed.manager.storedMcStorageLocation(),undefined);
  assert.equal(await failed.start(),'external');
  passed('first storage choice waits for flush, retains legacy and explicit locations, honors concurrent choice and retries failed persistence');
}
const after=hashes();assert.deepEqual(after,before,'被测源/loader在执行期间必须保持原身份');
fs.writeFileSync(path.join(output,'receipt.json'),JSON.stringify({startedAt,finishedAt:new Date().toISOString(),
  status:'PASS',groups,sourceBefore:before,sourceAfter:after,sourceDrift:[],scope:'actual production ETS; controlled Preferences/Context/display edges',
  notAttested:['real disk failure','ArkUI rendering','final ArkTS compilation','device/native gamepad current route','SDK/HAP/APP']},null,2));
console.log('PASS frozen settings '+groups.length+' source-bound groups; receipt '+path.join(output,'receipt.json'));
