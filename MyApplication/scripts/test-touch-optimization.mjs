/** 触控策略和游戏改键的生产模块回归；非法配置、迁移、未知绑定和共键均走实际 ArkTS 纯模块。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
// 配置投递执行真实纯模块；日志是外部观察边缘，不能用空配置类补齐构造签名。
const load = makePureEtsLoader({commons:{AppLogger:{warn(){}}}});
const { normalizeTouchPreferences } = load('gamecontrol/src/main/ets/TouchPreferences.ets');
const { parseMinecraftTouchKey, parseTouchActionBindings } = load('gamecontrol/src/main/ets/TouchActionBindings.ets');
const layout = load('gamecontrol/src/main/ets/ControlLayout.ets');
const gyroModule = load('gamecontrol/src/main/ets/TouchGyroscope.ets');
const legacy = normalizeTouchPreferences();
assert.equal(legacy.menuMode,'direct');
assert.equal(legacy.gyroscopeMode,'off');
assert.equal(legacy.hotbarDropHold,false);
// 缺省直接模式保持落指按住；相对触摸板缺省保留滚动，显式偏好和原文均不得改写。
assert.equal(legacy.menuTwoFingerScroll,false);
assert.equal(normalizeTouchPreferences({menuMode:'direct'}).menuTwoFingerScroll,false);
assert.equal(normalizeTouchPreferences({menuMode:'touchpad'}).menuTwoFingerScroll,true);
assert.equal(normalizeTouchPreferences({menuMode:'direct',menuTwoFingerScroll:true}).menuTwoFingerScroll,true);
assert.equal(normalizeTouchPreferences({menuMode:'touchpad',menuTwoFingerScroll:false}).menuTwoFingerScroll,false);
assert.equal(normalizeTouchPreferences({menuTwoFingerScroll:false}).menuTwoFingerScroll,false);
const oldWithoutTouch=layout.getDefaultLayout();delete oldWithoutTouch.touch;
assert.equal(layout.cloneLayout(oldWithoutTouch).touch,undefined);
for (const input of [{version:2},{menuMode:'virtual'},{menuSensitivity:NaN},{menuTwoFingerScroll:'false'},
    {joystickSprintThreshold:0},{gyroscopeSensitivity:Infinity},[],null]) {
  assert.equal(normalizeTouchPreferences(input),undefined);
}
const configured = normalizeTouchPreferences({menuMode:'touchpad',joystickCenter:'floating',hotbarSwapDoubleTap:true});
assert.equal(configured.menuMode,'touchpad');
const profile = layout.getDefaultLayout();
profile.touch = configured;
const copy = layout.cloneLayout(profile);
copy.touch.menuMode = 'direct';
assert.equal(profile.touch.menuMode,'touchpad');
assert.ok(layout.validateAndNormalizeLayout(profile));
profile.touch.menuHoldMs = 0;
assert.equal(layout.validateAndNormalizeLayout(profile),null);
const mapping = [ ['17',87],['42',340],['59',290],['-100',-1],['-99',-2],['key.mouse.4',-4],
    ['key.keyboard.w',87],['key.keyboard.left.control',341],['key.keyboard.keypad.7',327],
    ['key.keyboard.f25',314],['0',0],['key.keyboard.unknown',0] ];
for(const [text,expected] of mapping) assert.equal(parseMinecraftTouchKey(text),expected,text);
for(const text of ['-101','9999999','1.5','key.keyboard.no-such-key','key.mouse.17'])
  assert.equal(parseMinecraftTouchKey(text),undefined,text);
const snapshot = parseTouchActionBindings('key_key.forward:key.keyboard.i\nkey_key.left:key.keyboard.i\n'+
  'key_key.hotbar.1:key.mouse.4\nkey_key.drop:key.keyboard.unknown\nkey_key.use:not-a-key\n'+
  'key_key.sprint:key.keyboard.r\nkey_key.sprint:key.keyboard.left.alt\n');
assert.equal(snapshot.keys[0],73); assert.equal(snapshot.keys[1],73);
assert.equal(snapshot.keys[7],-4); assert.equal(snapshot.keys[6],0);
assert.equal(snapshot.keys[4],342); assert.deepEqual(Array.from(snapshot.unsupported),['use']);
assert.equal(parseTouchActionBindings('key_forward:200').keys[0],265);
assert.equal(parseTouchActionBindings('key_key.forward:key.keyboard.i',false).keys[0],87);
console.log('PASS touch preferences: migration, isolation, invalid rejection; Minecraft modern/legacy/unbound mappings');

// 相同角速度/时长在不同采样频率下积分一致；旋转、暂停和逆序样本不能产生跨会话跳变。
for (const stepMs of [5,10,20,50]) {
  const integrator = new gyroModule.TouchGyroscopeIntegrator();
  let total=0;
  for(let ms=0;ms<=1000;ms+=stepMs) {
    const delta=integrator.sample(0,1,1e9+ms*1e6,0,1,false,false);
    if(delta) total+=delta.dx;
  }
  assert.ok(Math.abs(total+360)<1e-8,`${stepMs}ms integration`);
  assert.equal(integrator.sample(0,1,3.2e9,1,1,false,false),undefined);
  assert.equal(integrator.sample(NaN,1,3.21e9,1,1,false,false),undefined);
  assert.equal(integrator.sample(0,1,3.1e9,1,1,false,false),undefined);
  integrator.reset();
  assert.equal(integrator.sample(0,1,4e9,1,1,false,false),undefined);
}

// 真正执行entry平台适配器，只替换传感器、native、文件和时钟边界。
const samples=[], subscriptions=[], retired=[], warnings=[], timers=new Map();
let frame=Array(14).fill(0), readCount=0, timerId=0;
frame[0]=500;frame[1]=400;frame[2]=1;frame[3]=200;frame[4]=300;frame[12]=9;
let maintenanceCalls=0;
const native={maintainTouchInput:()=>{maintenanceCalls++;return true;},touchInteractionVisual:()=>frame.slice(),sendTouchGyroSample:(...args)=>{samples.push(args);return true;}};
const model={...layout,...gyroModule,...load('gamecontrol/src/main/ets/TouchPreferences.ets'),
  ...load('gamecontrol/src/main/ets/TouchActionBindings.ets'),...load('gamecontrol/src/main/ets/TouchGuide.ets'),
  ...load('gamecontrol/src/main/ets/InputConfiguration.ets')};
// 新Session沿仓库确认定义取得gyro政策。提取原LayoutStore完整薄方法并使用真实
// InputConfigurationDelivery；仅活动方案读取与持久IO留在此fixture边缘，不让schemaOptions
// 重新承担应用副作用，也不以直接写Session私有字段代替配置投递。
const fixtureRepo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const storeSource=fs.readFileSync(path.join(fixtureRepo,'gamecontrol/src/main/ets/LayoutStore.ets'),'utf8');
const storeAst=compiler.createSourceFile('LayoutStore.ets',storeSource,compiler.ScriptTarget.Latest,true);
const storeOwner=storeAst.statements.find(node=>node.name?.getText(storeAst)==='LayoutStore'&&node.members);
assert.ok(storeOwner,'真实LayoutStore生产类');
const storeNames=['addInputConfigurationListener','removeInputConfigurationListener','addInputConfigurationDefinitionListener',
  'removeInputConfigurationDefinitionListener','publishInputConfiguration','reconcileInputConfiguration','invalidateInputConfiguration'];
const storeBodies=storeNames.map(name=>{const member=storeOwner.members.find(node=>node.name?.getText(storeAst)===name);
  assert.ok(member,'真实LayoutStore方法 '+name);return member.getText(storeAst);});
const storeJs=compiler.transpileModule('class StoreSubject{'+storeBodies.join('\n')+'}\nmodule.exports=StoreSubject;',
  {compilerOptions:{target:compiler.ScriptTarget.ES2020,module:compiler.ModuleKind.CommonJS}}).outputText;
const storeBox={exports:{}};new Function('module',storeJs)(storeBox);
const store=new storeBox.exports();store._ready=true;store.inputConfigurationDelivery=new model.InputConfigurationDelivery();
let activeProfile=layout.getDefaultLayout();store.getActiveProfile=()=>layout.cloneLayout(activeProfile);
model.getLayoutStore=()=>store;
const platform=makePureEtsLoader({gamecontrol:model,'libentry.so':{__esModule:true,default:native},
  '@ohos.file.fs':{__esModule:true,default:{readTextSync(){readCount++;return 'key_key.forward:key.keyboard.k';}}},
  '@kit.PerformanceAnalysisKit':{hilog:{warn:(...args)=>warnings.push(args),info(){}}},
  '@kit.ArkUI':{display:{getDefaultDisplaySync:()=>({rotation:0})}},
  '@kit.SensorServiceKit':{sensor:{SensorId:{GYROSCOPE:2},on:(id,callback,options)=>subscriptions.push({id,callback,options}),
    off:(id,callback)=>retired.push({id,callback})}}});
const originalSet=globalThis.setInterval,originalClear=globalThis.clearInterval;
globalThis.setInterval=(fn)=>{const id=++timerId;timers.set(id,fn);return id;};
globalThis.clearInterval=(id)=>timers.delete(id);
try {
  const {EntryTouchSession,startEntryTouchInputMaintenance,stopEntryTouchInputMaintenance,
    reconcileEntryTouchInputMaintenance}=platform('entry/src/main/ets/components/EntryTouchSession.ets');
  const hostLease=startEntryTouchInputMaintenance();
  const session=new EntryTouchSession(), views=[];
  const active=layout.getDefaultLayout();
  active.touch=normalizeTouchPreferences({menuMode:'touchpad',gyroscopeMode:'always',actionOverrides:{left:75}});
  activeProfile=active;
  session.setDirectory('/instance');
  const options=session.schemaOptions(active);
  assert.equal(options.actions[0],75);assert.equal(options.actions[1],75);
  session.setGrabbed(true);session.start(view=>views.push(view),true);
  session.setRuntimeContext({widthPx:1200,heightPx:800,density:2,transform:0,valid:true,key:'test'});
  session.setTouchAdmission(true);
  try {
    session.refreshVisual();session.refreshVisual();
    assert.equal(views.length,1,JSON.stringify(warnings));assert.equal(views[0].schemaGeneration,9);
    assert.equal(views[0].guide.available,false,'旧视觉前缀仍正常工作，但不能伪造教学反馈');
    assert.equal(subscriptions.length,0,'只读视觉不启动或维护传感器');
    session.maintainSources();
    assert.equal(subscriptions.length,1);assert.equal(readCount,1);
    const callback=subscriptions[0].callback;
    callback({x:0,y:1,z:0,timestamp:1e9});callback({x:0,y:1,z:0,timestamp:1.02e9});
    assert.equal(samples.length,1);assert.equal(samples[0][3],9);
    assert.ok(Math.abs(samples[0][0]+7.2)<1e-8);
    session.setActive(false);callback({x:0,y:1,z:0,timestamp:1.04e9});
    assert.equal(samples.length,1);assert.equal(timers.size,0);assert.equal(retired.length,1);
    session.setActive(true);frame[12]=10;session.maintainSources();session.refreshVisual();
    assert.equal(subscriptions.length,2);
    callback({x:0,y:1,z:0,timestamp:1.06e9});assert.equal(samples.length,1);
    const next=subscriptions[1].callback;
    next({x:0,y:1,z:0,timestamp:2e9});next({x:0,y:1,z:0,timestamp:2.02e9});
    assert.equal(samples.length,2);assert.equal(samples[1][3],10);
    session.setTouchAdmission(false);next({x:0,y:1,z:0,timestamp:2.04e9});assert.equal(samples.length,2,'modal/fence立即退休旧gyro回调');
    session.setTouchAdmission(true);session.unsubscribeVisual();
    const viewCount=views.length, maintenanceBefore=maintenanceCalls;
    for(const tick of timers.values())tick();
    assert.ok(maintenanceCalls>maintenanceBefore);assert.equal(views.length,viewCount);
    assert.equal(subscriptions.length,3,'关闭视觉仍以来源16ms时钟恢复合法gyro');
    const independent=subscriptions[2].callback;
    independent({x:0,y:1,z:0,timestamp:3e9});independent({x:0,y:1,z:0,timestamp:3.02e9});assert.equal(samples.length,3);
    session.setGrabbed(false);independent({x:0,y:1,z:0,timestamp:3.04e9});assert.equal(samples.length,3);
  } finally { session.stop();stopEntryTouchInputMaintenance(hostLease); }
  assert.equal(timers.size,0);
  const noFrontendLease=startEntryTouchInputMaintenance();
  assert.equal(reconcileEntryTouchInputMaintenance(hostLease),false,'旧宿主不能维护后来会话');
  assert.equal(reconcileEntryTouchInputMaintenance(noFrontendLease),true,'没有视觉前端时宿主仍执行必要Native维护');
  session.setActive(true);assert.equal(timers.size,0,'旧来源不能通过setActive偷取后来会话scope');
  const sourceOnly=new EntryTouchSession();sourceOnly.schemaOptions(active);sourceOnly.setGrabbed(true);
  sourceOnly.setTouchAdmission(true);sourceOnly.startSources(true);sourceOnly.maintainSources();
  assert.equal(timers.size,1,'来源可在没有视觉订阅时独立运行');
  const sourceOnlyCallback=subscriptions.at(-1).callback;
  stopEntryTouchInputMaintenance(noFrontendLease);
  assert.equal(timers.size,0,'宿主停局独立撤销尚未detach的来源时钟');
  const afterHostStop=samples.length;
  sourceOnlyCallback({x:0,y:1,z:0,timestamp:4e9});sourceOnlyCallback({x:0,y:1,z:0,timestamp:4.02e9});
  assert.equal(samples.length,afterHostStop,'宿主停止后迟到传感器回调作废');
  const laterHost=startEntryTouchInputMaintenance();sourceOnly.setActive(true);
  assert.equal(timers.size,0,'旧来源不能重开后来会话');
  sourceOnly.startSources(true);assert.equal(timers.size,0,'旧前端的迟到start也不能改绑后来会话');
  stopEntryTouchInputMaintenance(laterHost);
} finally {globalThis.setInterval=originalSet;globalThis.clearInterval=originalClear;}
console.log('PASS gyro sampling-rate invariance, rotation/reset; real entry session binding, subscription and stale-callback fence');

// 转换器执行真实格式语义：Pojav负数不是通用鼠标编码；动态表达式不执行脚本。
const {evaluateLayoutExpression}=load('gamecontrol/src/main/ets/LayoutExpression.ets');
assert.equal(evaluateLayoutExpression('(${screen_width} - ${width}) / 2 + 3',{'screen_width':720,'width':50}),338);
for(const expr of ['1/0','Math.random()','${unknown}+1','1; process.exit()','('.repeat(50)+'1'+')'.repeat(50)])
  assert.equal(evaluateLayoutExpression(expr,{}),undefined);
const {analyzeExternalLayout}=load('gamecontrol/src/main/ets/ExternalLayoutImporter.ets');
const pojav={version:6,mControlDataList:[
  {name:'键盘',keycodes:[-1],dynamicX:'20',dynamicY:'20',width:50,height:50},
  {name:'攻击',keycodes:[-3],dynamicX:'${right}',dynamicY:'${bottom}',width:60,height:60},
  {name:'使用',keycodes:[-4],dynamicX:'100',dynamicY:'100',width:60,height:60}]};
const pr=analyzeExternalLayout(JSON.stringify(pojav),'pojav');
assert.ok(pr.profile,pr.reason);assert.equal(pr.profile.controls[0].systemAction,'input');
assert.equal(pr.profile.controls[1].keyOrMouse,-1);assert.equal(pr.profile.controls[2].keyOrMouse,-2);
assert.ok(pr.warnings.length>0);
const fcl={controllerVersion:21,viewGroups:[{visibility:'VISIBLE',viewData:{buttonList:[
  {text:'跳',baseInfo:{sizeType:'ABSOLUTE',absoluteWidth:50,absoluteHeight:50,xPosition:1000,yPosition:0},
    event:{pressEvent:{outputKeycodes:[57]}}},
  {text:'连点宏',baseInfo:{},event:{pressEvent:{outputKeycodes:[1000],autoClick:true}}} ]}}]};
const fr=analyzeExternalLayout(JSON.stringify(fcl),'fcl');
assert.equal(fr.profile,null);assert.match(fr.reason,/连点/,'未支持宏必须在保存前拒绝整份执行');
fcl.viewGroups[0].viewData.buttonList.pop();
const supportedFcl=analyzeExternalLayout(JSON.stringify(fcl),'fcl');
assert.ok(supportedFcl.profile,supportedFcl.reason);assert.equal(supportedFcl.profile.controls.length,1);
assert.equal(supportedFcl.profile.version,5);assert.deepEqual(supportedFcl.profile.controls[0].phaseBindings[0].keys,[32]);
const zl={editorVersion:12,layers:[{name:'game',hide:false,visibilityType:'in_game',normalButtons:[
  {text:{default:'Esc'},position:{x:10000,y:0},buttonSize:{type:'dp',widthDp:50,heightDp:50},
    clickEvents:[{type:'key',key:'GLFW_KEY_ESCAPE'}]}]}]};
const zr=analyzeExternalLayout(JSON.stringify(zl),'zl');
assert.ok(zr.profile,zr.reason);assert.equal(zr.profile.controls[0].keyOrMouse,256);
assert.equal(zr.profile.controls[0].grabbedOnly,true);
assert.equal(analyzeExternalLayout('{"layers":[],"editorVersion":12}','empty').profile,null);
assert.equal(analyzeExternalLayout(JSON.stringify({mControlDataList:[{keycodes:[-3],width:'bad'}]}),'bad').profile,null);

const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const optionSource=fs.readFileSync(path.join(repo,'entry/src/main/ets/components/TouchOptionsEditor.ets'),'utf8');
const optionAst=compiler.createSourceFile('TouchOptionsEditor.ets',optionSource,compiler.ScriptTarget.Latest,true);
const optionOwner=optionAst.statements.find(node=>node.name?.getText(optionAst)==='TouchOptionsEditor'&&node.members);
assert.ok(optionOwner);
const names=['flag','number','cycle'];
if(optionOwner.members.some(node=>node.name?.getText(optionAst)==='commit'))names.push('commit');
const bodies=names.map(name=>optionOwner.members.find(node=>node.name?.getText(optionAst)===name).getText(optionAst));
const compiled=compiler.transpileModule('class TouchEditorSubject{'+bodies.join('\n')+'}\nmodule.exports=TouchEditorSubject;',
  {compilerOptions:{target:compiler.ScriptTarget.ES2020,module:compiler.ModuleKind.CommonJS}}).outputText;
const box={exports:{}};
new Function('module','normalizeTouchPreferences','TouchConfiguration',compiled)(box,normalizeTouchPreferences,model.TouchConfiguration);
const subject=new box.exports(),changes=[];
subject.value=normalizeTouchPreferences({menuMode:'touchpad',menuTwoFingerScroll:true,joystickCenter:'floating'});
subject.onChange=(value,key)=>changes.push({value,key});
subject.flag('scroll',true);subject.number('menuSpeed',100);subject.number('menuHold',350);
assert.equal(changes.length,0,'程序更新控件当前值不能制造撤销项');
subject.flag('scroll',false);assert.equal(changes.length,1);assert.equal(changes[0].value.menuTwoFingerScroll,false);
console.log('PASS real options callbacks ignore same-value Toggle/Slider notifications');
