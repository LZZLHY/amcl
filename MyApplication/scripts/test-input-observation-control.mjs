/**
 * P6执行真实Session来源、原组件方法/挂接闭包、反馈broker和受控Want编排。平台
 * Native/Ability/节点是显式边缘；不把宿主转译、路由成功或固定文件当作SDK/设备证明。
 * 提取现役GUI fixture只复用它的边界装配，不复制输入算法，产品正文均逐字转译执行。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {pathToFileURL} from 'node:url';
import compiler from './lib/ets-compiler.mjs';
import {makePureEtsLoader} from './lib/load-pure-ets.mjs';
import {environment} from './lib/ets-runtime-fixture.mjs';
import {PROJECT_ROOT,workspacePath} from './lib/workspace-paths.mjs';
const sessionFile='entry/src/main/ets/components/EntryTouchSession.ets';
const controlsFile='entry/src/main/ets/components/GameControls.ets';
const portFile='entry/src/main/ets/components/EntryInputObservationPort.ets';
const wantFile='entry/src/main/ets/components/InputObservationTestWant.ets';
const fixtureFile='scripts/test-game-gui-source-lease.mjs';
const raw=p=>fs.readFileSync(path.join(PROJECT_ROOT,p));
const source=p=>raw(p).toString('utf8').replaceAll('\r\n','\n');
const bound=[sessionFile,controlsFile,portFile,wantFile,fixtureFile,'scripts/test-input-observation-control.mjs',
  'entry/src/main/ets/gameability/GameAbility.ets','entry/src/main/ets/entryability/EntryAbility.ets',
  'entry/src/main/ets/components/EntryControlFeedbackBroker.ets','entry/src/main/ets/components/EntryTouchInputMaintenance.ets',
  'gamecontrol/src/main/ets/LayoutStore.ets','gamecontrol/src/main/ets/InputConfiguration.ets',
  'scripts/lib/ets-compiler.mjs','scripts/lib/load-pure-ets.mjs','scripts/lib/ets-runtime-fixture.mjs',
  'scripts/test-game-session-host.mjs','entry/src/main/ets/runtime/GameSessionHost.ets'];
const sha=p=>crypto.createHash('sha256').update(raw(p)).digest('hex');
const before=Object.fromEntries(bound.map(p=>[p,sha(p)])),startedAt=new Date().toISOString();
const compilationFacts=[];

/** 非UI完整叶先取明确转译诊断；错误不能混进后续行为断言，被测文本仍交原loader执行。 */
function checkedSource(file,text) {
  const compiled=compiler.transpileModule(text,{fileName:file,
    compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020},reportDiagnostics:true});
  const errors=(compiled.diagnostics??[]).filter(d=>d.category===compiler.DiagnosticCategory.Error);
  assert.equal(errors.length,0,'successful whole-module transpile '+file);
  compilationFacts.push({file,kind:'whole non-UI module',errors:errors.length});return text;
}

/** 每次独立加载原方法；负控只修改内存产品正文且必须成功转译，再由同一行为断言发现。 */
function methods(file,names,dependencies={},rewrite=s=>s) {
  const original=source(file),changed=rewrite(original);
  const ast=compiler.createSourceFile(file,changed,compiler.ScriptTarget.Latest,true);
  const owner=ast.statements.find(n=>n.members?.some(m=>m.name?.getText(ast)===names[0]));assert.ok(owner,file);
  const bodies=names.map(name=>{const n=owner.members.find(m=>m.name?.getText(ast)===name);assert.ok(n,name);return n.getText(ast);});
  const compiled=compiler.transpileModule('class Subject{'+bodies.join('\n')+'}\nmodule.exports=Subject;',
    {compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020},reportDiagnostics:true});
  assert.equal((compiled.diagnostics??[]).filter(d=>d.category===compiler.DiagnosticCategory.Error).length,0,file);
  compilationFacts.push({file,kind:'original method subset',errors:0});
  const module={exports:{}};new Function('module',...Object.keys(dependencies),compiled.outputText)(module,...Object.values(dependencies));
  return new module.exports();
}
function replace(s,a,b){assert.ok(s.includes(a),'negative anchor '+a);return s.replaceAll(a,b);}
/** 读取现役fixture函数，不运行它的测试顶层；只把import.meta的文件定位参数显式传入。 */
function sessionFixture(rewrite=s=>s) {
  const ast=compiler.createSourceFile(fixtureFile,source(fixtureFile),compiler.ScriptTarget.Latest,true);
  const body=ast.statements.find(n=>n.name?.getText(ast)==='fixture').getText(ast).replaceAll('import.meta.dirname','testDirectory');
  return new Function('assert','fs','path','compiler','makePureEtsLoader','file','original','testDirectory','rewrite','checkedSource',
    body+'\nreturn fixture(s=>checkedSource(file,rewrite(s)));')(
    assert,fs,path,compiler,makePureEtsLoader,sessionFile,source(sessionFile),path.join(PROJECT_ROOT,'scripts'),rewrite,checkedSource);
}
function productionCallbacks(view,session) {
  const ast=compiler.createSourceFile(controlsFile,source(controlsFile),compiler.ScriptTarget.Latest,true);
  const owner=ast.statements.find(n=>n.name?.getText(ast)==='GameControls');let call;
  const visit=n=>{if(compiler.isCallExpression(n)&&n.expression.getText(ast)==='this.touchSession.start')call=n;compiler.forEachChild(n,visit);};
  visit(owner.members.find(n=>n.name?.getText(ast)==='aboutToAppear'));assert.equal(call.arguments.length,4);
  return [2,3].map(i=>{
    const compiled=compiler.transpileModule('module.exports='+call.arguments[i].getText(ast),
      {compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020},reportDiagnostics:true});
    assert.equal((compiled.diagnostics??[]).filter(d=>d.category===compiler.DiagnosticCategory.Error).length,0);
    const module={exports:{}};new Function('module','session','expectedAppearanceGeneration',compiled.outputText)
      .call(view,module,session,view.appearanceGeneration);return module.exports;
  });
}
/** 原挂接中局部登记闭包逐字执行，证明activity0等待只跟随原Host而不借全局current。 */
function productionRegistration(view,session,host,port) {
  const ast=compiler.createSourceFile(controlsFile,source(controlsFile),compiler.ScriptTarget.Latest,true);let initializer;
  const visit=n=>{if(compiler.isVariableDeclaration(n)&&n.name.getText(ast)==='registerObservation')initializer=n.initializer;compiler.forEachChild(n,visit);};
  visit(ast);assert.ok(initializer);
  const compiled=compiler.transpileModule('module.exports='+initializer.getText(ast),
    {compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020},reportDiagnostics:true});
  assert.equal((compiled.diagnostics??[]).filter(d=>d.category===compiler.DiagnosticCategory.Error).length,0);
  const module={exports:{}};new Function('module','session','observationHost','appearance','registerEntryInputObservation',compiled.outputText)
    .call(view,module,session,host,view.appearanceGeneration,port.registerEntryInputObservation);return module.exports;
}
const savedSet=globalThis.setInterval,savedClear=globalThis.clearInterval;let timers;
globalThis.setInterval=fn=>{const id=timers.size+1;timers.set(id,fn);return id;};globalThis.clearInterval=id=>timers.delete(id);
let now=1000;const savedNow=Date.now;Date.now=()=>now;
const cases=[],negatives=[];
function componentContract(rewrite=s=>s) {
  const f=sessionFixture();timers=f.timers;const session=new f.module.EntryTouchSession();
  const buttons=[],haptics=[],bounds=[],samples=[],retiredGyro=[],learningWrites=[];let slots=0,failClear=false,movement=0;
  f.native.touchGyroLeaseContext=()=> 'original-context';f.native.beginTouchGyroLease=()=> 'original-gyro';
  f.native.submitTouchGyroLease=(...args)=>{samples.push(args);return true;};
  f.native.retireTouchGyroLease=lease=>{retiredGyro.push(lease);return true;};
  const definition=f.models.getDefaultLayout();definition.profileId='original';definition.profileRevision=1;
  definition.touch={gyroscopeMode:'always',gyroscopeSensitivity:1};f.store.getActiveProfile=()=>f.models.cloneLayout(definition);
  const visual=(x,y)=>[x,y,...Array(10).fill(0),7,0,0,movement,0,-1,0,0,0,0,0,0,1];f.native.touchInteractionVisual=()=>visual(20,30);
  f.native.onButtonPressed=cb=>{slots++;buttons.push(cb);if(!cb&&failClear)throw Error('clear failed');return true;};
  f.native.onHaptic=cb=>{haptics.push(cb);return true;};
  f.native.touchPublicationState=()=>({version:1,fenced:false,modalCount:0,schemaGeneration:'7',session:'20',grabEpoch:'9'});
  const load=makePureEtsLoader({'libentry.so':{__esModule:true,default:f.native}});
  const feedback=load('entry/src/main/ets/components/EntryControlFeedbackBroker.ets');
  const port=load(portFile),mouse=load('gamecontrol/src/main/ets/VirtualMouseModel.ets');let vibrations=0,schemas=0;
  const names=['observationEnabled','touchFeedbackObservationEnabled_','operateTouchObservation_','touchObservationResult_','subscribeTouchObservation_','ensureTouchFeedback_',
    'receiveGameGui','maybeOpenLearning','observeLearning','syncGuideObservation','mouseFrame','setPressed','isPressed'];
  const view=methods(controlsFile,names,{...feedback,...f.models,...port,...mouse,EntryTouchVisual:f.module.EntryTouchVisual,
    hapticTap:()=>vibrations++,hilog:{warn(){}},GAME_CONTROLS_TAG:'test',hasEntryTouchModal:()=>false},rewrite);
  Object.assign(view,{mounted:true,pageActive:true,appearanceGeneration:7,observationGeneration:1,
    feedbackLease:undefined,feedbackClearComplete:true,nextFeedbackAttempt:0,feedbackRegistrationWarned:false,
    touchSession:session,touchVisual:new f.module.EntryTouchVisual(),guiState:new f.models.GameGuiState(),
    schemaActive:true,uiPublicationToken:'actual-publication',runtimeLayout:{find:()=>({})},btnVisMap:new Map(),btnPressedVer:0,
    getBtnVis:id=>{if(!view.btnVisMap.has(id))view.btnVisMap.set(id,{pressed:false});return view.btnVisMap.get(id);},
    compWidth:960,compHeight:540,density:1,menuGeometryX:0,menuGeometryY:0,isGrabbed:true,editing:false,imeOpen:false,fieldImeOpen:false,
    tutorialOpen:false,learningSeen:true,guideStep:0,guiHint:false,restorePending:0,guiGuard:{observe:()=>false},
    learningStore:{markSeen:()=>learningWrites.push('seen'),markClosed:()=>learningWrites.push('closed'),markLesson:()=>learningWrites.push('lesson')},
    touchGuide:new f.models.TouchGuide(),mouseOpen:true,guideScrollRequested:false,
    syncGuideBounds:()=>{},syncMouseBounds:()=>bounds.push(view.mouseFrame()),
    registerRegions:()=>{schemas++;},observationRegistration:undefined,observationResumeTeaching:false});
  const [gui,geometry]=productionCallbacks(view,session);
  session.setGuiViewport(1920,1080,'1.21.11');session.start(()=>{},true,gui,geometry);
  session.setGrabbed(true);session.setTouchAdmission(true);session.maintainSources();
  let activity=0;const host={sessionActivity:()=>activity,isRunning:()=>true,isEnded:()=>false};
  const registration=productionRegistration(view,session,host,port);registration();assert.equal(view.observationRegistration,undefined);
  activity=33;registration();assert.equal(view.observationRegistration.activity,33);const originalRegistration=view.observationRegistration;
  registration();assert.equal(view.observationRegistration,originalRegistration,'原心跳登记成功后不得重复换资格');
  assert.equal(session.gyroscopeStatus(),'active');const gyro=f.sensorCallbacks.at(-1);
  gyro({x:0,y:1,z:0,timestamp:1e9});gyro({x:0,y:1,z:0,timestamp:1e9+20000000});assert.ok(samples.length>0);
  view.subscribeTouchObservation_();view.ensureTouchFeedback_();session.refreshVisual();
  assert.equal(view.touchGuide.start(view.touchVisual.guide),true);view.tutorialOpen=true;
  const oldVisual=session.receive,oldButton=buttons.find(Boolean),oldHaptic=haptics.find(Boolean);
  oldButton('jump',true);assert.equal(view.isPressed('jump'),true);
  const origin=session.sourceLease,timer=session.timer,slotsBefore=slots,schemasBefore=schemas;
  const off=view.operateTouchObservation_('off');assert.equal(off.visualSubscribed,false);assert.equal(off.feedbackLease,0);
  assert.equal(view.tutorialOpen,false);assert.deepEqual(learningWrites,[],'诊断关闭不能持久标记用户已看/关闭教程');
  assert.equal(off.guiSubscribed,true);assert.equal(off.geometrySubscribed,true);assert.equal(off.sourceCurrent,true,'OBSERVATION_OFF_MUST_KEEP_ORIGINAL_SOURCE');
  now+=1500;view.ensureTouchFeedback_();assert.equal(slots,slotsBefore+1,'OBSERVATION_OFF_MUST_NOT_AUTOSUBSCRIBE_FEEDBACK');
  f.raw[1]=4;f.raw[2]=4;f.raw[5]=480;f.raw[6]=270;
  movement=100;
  f.native.touchInteractionVisual=()=>visual(200,220);for(const tick of f.timers.values())tick();
  const samplesBefore=samples.length;gyro({x:0,y:1,z:0,timestamp:1e9+40000000});assert.ok(samples.length>samplesBefore,
    '原Source/gyro真实积分提交不随显示订阅关闭');assert.equal(f.sensorOff.length,0);
  assert.equal(view.guiState.effective,4);assert.ok(schemas>schemasBefore,'必要GUI确实到原组件registerRegions边缘');
  const profile=f.models.getDefaultLayout();profile.controls=[f.models.makeHotbarSelector(.1,.2,100,20)];
  const hotbar=f.models.projectGameHotbar(profile,profile.controls,view.guiState,960,540)[0];assert.equal(hotbar.baseWidth,360);
  assert.equal(view.menuGeometryX,200);assert.deepEqual(bounds.at(-1),view.mouseFrame());
  const guiBeforeOn=session.observationSnapshot().guiReads,visualBeforeOn=session.observationSnapshot().visualDeliveries;
  const restored=view.operateTouchObservation_('on');assert.equal(restored.visualSubscribed,true);assert.ok(restored.feedbackLease>0);
  assert.equal(session.observationSnapshot().guiReads,guiBeforeOn,'Want on不能直接读取GUI/JNI');
  assert.equal(session.observationSnapshot().visualDeliveries,visualBeforeOn,'Want on不能补造额外投影tick');
  for(const tick of f.timers.values())tick();
  assert.equal(session.sourceLease,origin);assert.equal(session.timer,timer);assert.equal(restored.buttonBaseline,'UnknownUntilNextEdge');
  assert.equal(f.sensorCallbacks.length,1,'观察恢复不重建原gyro');assert.equal(f.sensorOff.length,0);
  assert.equal(view.tutorialOpen,true);assert.equal(view.touchGuide.step,0,'恢复基线不能追认关闭窗的旧教学进度');
  assert.deepEqual(learningWrites,[]);
  const deliveries=session.observationSnapshot().visualDeliveries;
  oldVisual(Object.assign(new f.module.EntryTouchVisual(),{menuX:999}));
  assert.equal(view.touchVisual.menuX,200,'OLD_VISUAL_CLOSURE_CANNOT_WRITE_AFTER_OFF_ON');
  oldButton('jump',true);oldHaptic(1,{version:1,registration:'old',grabEpoch:'9',generatedNs:'1',schemaGeneration:'7',session:'20',controlId:'jump'});
  assert.equal(view.isPressed('jump'),false);assert.equal(vibrations,0);
  view.operateTouchObservation_('read');assert.equal(session.observationSnapshot().visualDeliveries,deliveries,'read不能推进投影');
  const currentButton=buttons.filter(Boolean).at(-1);currentButton('jump',true);assert.equal(view.isPressed('jump'),true);
  failClear=true;const failed=view.operateTouchObservation_('off');assert.equal(failed.outcome,'ObserversRetiredNativeClearUnknown');
  currentButton('jump',true);assert.equal(view.isPressed('jump'),false,'注销异常仍失去原callback资格');
  view.mounted=false;gui(new f.models.GameGuiState());geometry(999,999);assert.equal(view.menuGeometryX,200,'旧appearance必要闭包也不得写入');
  view.mounted=true;view.appearanceGeneration++;geometry(999,999);assert.equal(view.menuGeometryX,200,'组件重新挂接也不得复用旧appearance必要闭包');
  view.appearanceGeneration--;view.operateTouchObservation_('on');for(const tick of f.timers.values())tick();const retiringVisual=session.receive;
  f.module.stopEntryTouchInputMaintenance(f.host);const retiredReadCount=session.observationSnapshot().guiReads;
  retiringVisual(Object.assign(new f.module.EntryTouchVisual(),{menuX:999}));geometry(999,999);session.refreshVisual();
  assert.equal(view.touchVisual.menuX,200,'RETIRED_SOURCE_CANNOT_PUBLISH_TO_STILL_MOUNTED_COMPONENT');
  assert.equal(view.menuGeometryX,200);assert.equal(session.observationSnapshot().guiReads,retiredReadCount);
  session.stop();assert.deepEqual(retiredGyro,['original-gyro']);
  return {hotbarWidth:hotbar.baseWidth,sourceAndTimerRetained:true,visualDeliveries:deliveries,realGyroSubmits:samples.length};
}

/**
 * 原GUI/必要几何闭包运行真实GC方法，边缘回入真正stopSources/stop scope。
 * same-lease场先unregister再scope stop，仅为明确受控资格边界；没有产品调用方证明。
 */
function projectionBoundaryContract(stage,rewrite=s=>s) {
  const f=sessionFixture(rewrite);timers=f.timers;const session=new f.module.EntryTouchSession();let getters=0;
  const view=methods(controlsFile,['receiveGameGui','maybeOpenLearning','observeLearning','syncGuideObservation','subscribeTouchObservation_'],
    {...f.models,hasEntryTouchModal:()=>false});
  const stop=control=>{
    if(control)f.maintenanceModule.unregisterEntryTouchInputMaintenanceSource(f.host,session);
    if(stage.includes('scope'))f.module.stopEntryTouchInputMaintenance(f.host);else session.stopSources();
  };
  Object.assign(view,{mounted:true,pageActive:true,appearanceGeneration:7,observationGeneration:1,observationEnabled:true,
    touchSession:session,touchVisual:new f.module.EntryTouchVisual(),touchGuide:new f.models.TouchGuide(),
    guiState:new f.models.GameGuiState(),restorePending:0,isGrabbed:true,editing:false,guiHint:false,learningSeen:true,tutorialOpen:false,
    guiGuard:{observe:()=>false},compWidth:960,menuGeometryX:0,menuGeometryY:0,
    registerRegions:()=>{if(stage.startsWith('gui-'))stop(false);},
    syncMouseBounds:()=>{if(stage.startsWith('geometry-'))stop(stage.includes('control'));},syncGuideBounds(){}});
  const [gui,geometry]=productionCallbacks(view,session);
  session.setGuiViewport(1920,1080,'1.21.11');session.start(()=>{},true,gui,geometry);view.subscribeTouchObservation_();
  f.native.touchInteractionVisual=()=>{getters++;if(stage.startsWith('getter-'))stop(stage.includes('control'));return [20,30,...Array(12).fill(0)];};
  try {
    session.refreshVisual();const snapshot=session.observationSnapshot();
    if(stage.startsWith('gui-'))assert.equal(getters,0,'GUI_REENTRY_RETIRE_MUST_NOT_READ_GLOBAL_VISUAL');
    else assert.equal(getters,1);
    if(stage==='current') {
      assert.equal(snapshot.geometryDeliveries,1);assert.equal(snapshot.visualDeliveries,1);
      assert.equal(view.menuGeometryX,20);assert.equal(view.touchVisual.menuX,20);
    } else if(stage.startsWith('getter-')) {
      assert.equal(snapshot.geometryDeliveries,0,'GETTER_RETURN_LOST_SOURCE_MUST_NOT_OFFER_GEOMETRY');
      assert.equal(snapshot.visualDeliveries,0);assert.equal(view.menuGeometryX,0);assert.equal(view.touchVisual.menuX,0);
    } else if(stage.startsWith('geometry-')) {
      assert.equal(snapshot.geometryDeliveries,1,'停止发生前必要几何已合法投递');
      assert.equal(view.menuGeometryX,20);assert.equal(view.touchVisual.menuX,0);
      assert.equal(snapshot.visualDeliveries,0,'GEOMETRY_REENTRY_RETIRE_MUST_NOT_OFFER_VISUAL');
    } else {assert.equal(snapshot.geometryDeliveries,0);assert.equal(snapshot.visualDeliveries,0);}
    return {stage,getters,geometryOffers:snapshot.geometryDeliveries,visualOffers:snapshot.visualDeliveries,
      gcGeometry:view.menuGeometryX,gcVisual:view.touchVisual.menuX,sourceCurrent:snapshot.sourceCurrent,
      premise:stage.includes('control')?'先unregister再真实scope stop的受控边界，无现役调用方证明':'真实原回调/停源边缘'};
  } finally {session.stop();}
}

/** 真实Source/scope退休但组件保持mounted；真实broker与匹配Native receipt不能代替Source资格。 */
function feedbackSourceContract(stage,rewrite=s=>s,fenced=false,hapticFirst=false) {
  const f=sessionFixture();timers=f.timers;const session=new f.module.EntryTouchSession(),buttons=[],haptics=[];
  let vibrations=0;const pressed={pressed:false};
  f.native.onButtonPressed=cb=>{buttons.push(cb);return true;};
  f.native.onHaptic=cb=>{
    haptics.push(cb);if(stage==='registration-return'&&cb)session.stopSources();
    // 本场只在Native注册中改变原观察字段，Source/appearance/观察代不变，专门验证返回后的重读。
    if(stage==='observation-return'&&cb)view.observationEnabled=false;
    return true;
  };
  f.native.touchPublicationState=()=>({version:1,fenced,modalCount:0,schemaGeneration:'7',session:'20',grabEpoch:'9'});
  const pure=makePureEtsLoader({'libentry.so':{__esModule:true,default:f.native}}),broker=pure('entry/src/main/ets/components/EntryControlFeedbackBroker.ets');
  const view=methods(controlsFile,['observationEnabled','touchFeedbackObservationEnabled_','ensureTouchFeedback_'],{...broker,hilog:{warn(){}},GAME_CONTROLS_TAG:'test',hapticTap:()=>vibrations++},rewrite);
  Object.assign(view,{mounted:true,pageActive:true,schemaActive:true,appearanceGeneration:7,observationGeneration:1,
    touchSession:session,feedbackLease:undefined,nextFeedbackAttempt:0,feedbackRegistrationWarned:false,btnPressedVer:0,
    getBtnVis:()=>pressed,runtimeLayout:{find:()=>({})},editing:false,imeOpen:false,fieldImeOpen:false});
  session.startSources(true);
  try {
    if(stage==='initial-stop') {
      // 字段初值来自同一个生产property，不用外部true假装观察就绪；未知值必须拒绝注册。
      const initialized=view.observationEnabled;assert.equal(initialized,true);
      view.observationEnabled=undefined;view.ensureTouchFeedback_();
      assert.equal(buttons.length,0,'UNINITIALIZED_OBSERVATION_MUST_NOT_REGISTER');
      view.observationEnabled=initialized;session.stopSources();
    }
    view.ensureTouchFeedback_();
    if(stage==='initial-stop') {assert.equal(buttons.length,0,'STOPPED_SOURCE_MUST_NOT_REGISTER_FEEDBACK');return {stage,registrations:0};}
    if(stage==='registration-return'||stage==='observation-return') {
      assert.equal(view.feedbackLease,undefined,stage==='observation-return'?
        'NATIVE_RETURN_MUST_RECHECK_OBSERVATION_FLAG':'RETURNED_LEASE_FOR_LOST_SOURCE_MUST_BE_RELEASED');
      assert.equal(buttons.at(-1),undefined);assert.equal(haptics.at(-1),undefined);
      if(stage==='observation-return') {assert.equal(session.hasCurrentSource(),true);assert.equal(view.observationEnabled,false);}
      return {stage,returnedLeaseReleased:true};
    }
    const button=buttons.find(Boolean),haptic=haptics.find(Boolean);
    const metadata={version:1,registration:'original',grabEpoch:'9',generatedNs:'1',schemaGeneration:'7',session:'20',controlId:'jump'};
    button('jump',true);button('jump',false);haptic(1,metadata);
    assert.equal(view.btnPressedVer,2);assert.equal(pressed.pressed,false);assert.equal(vibrations,fenced?0:1);
    if(stage==='scope-stop')f.module.stopEntryTouchInputMaintenance(f.host);else session.stopSources();
    button('jump',true);haptic(1,metadata);
    if(hapticFirst)assert.equal(vibrations,fenced?0:1,'LOST_SOURCE_MUST_REJECT_ORIGINAL_HAPTIC_CALLBACK');
    assert.equal(view.btnPressedVer,2,'LOST_SOURCE_MUST_REJECT_ORIGINAL_BUTTON_CALLBACK');
    assert.equal(pressed.pressed,false);assert.equal(vibrations,fenced?0:1,'LOST_SOURCE_MUST_REJECT_ORIGINAL_HAPTIC_CALLBACK');
    // Source关闭后原lease仍可供确切退休，但mounted、Native receipt或同活动值都不能再准入反馈。
    broker.releaseEntryControlFeedback(view.feedbackLease);view.feedbackLease=undefined;view.nextFeedbackAttempt=0;
    const registrations=buttons.length;view.ensureTouchFeedback_();assert.equal(buttons.length,registrations);
    return {stage,fenced,buttonVersion:view.btnPressedVer,pressed:pressed.pressed,haptics:vibrations};
  } finally {session.stop();}
}
try {
  cases.push({name:'actual-component-source-feedback',result:componentContract()});
  assert.throws(()=>componentContract(s=>replace(s,'!this.touchFeedbackObservationEnabled_() || !this.mounted || !this.pageActive || !this.schemaActive ||',
    '!this.mounted || !this.pageActive || !this.schemaActive ||')),/OBSERVATION_OFF_MUST_NOT_AUTOSUBSCRIBE_FEEDBACK/);
  negatives.push('removed feedback-off retry gate');
  assert.throws(()=>componentContract(s=>replace(s,'this.touchSession.unsubscribeVisual()',
    'this.touchSession.stopSources(); this.touchSession.unsubscribeVisual()')),/OBSERVATION_OFF_MUST_KEEP_ORIGINAL_SOURCE/);
  negatives.push('observer-off wrongly stops original source');
  assert.throws(()=>componentContract(s=>replace(s,'generation!==this.observationGeneration || session!==this.touchSession','session!==this.touchSession')),
    /OLD_VISUAL_CLOSURE_CANNOT_WRITE_AFTER_OFF_ON/);negatives.push('removed original visual generation fence');
  for(const stage of ['current','gui-stop','gui-scope-stop','getter-stop','getter-scope-control','geometry-stop','geometry-scope-control'])
    cases.push({name:'projection-boundary-'+stage,result:projectionBoundaryContract(stage)});
  assert.throws(()=>projectionBoundaryContract('gui-stop',s=>replace(s,
    "if (!this.isCurrentProjectionSource_(lease)) return\n      if (typeof testNapi.touchInteractionVisual",
    "if (false) return\n      if (typeof testNapi.touchInteractionVisual")),/GUI_REENTRY_RETIRE_MUST_NOT_READ_GLOBAL_VISUAL/);
  negatives.push('removed Source check after actual GUI callback');
  assert.throws(()=>projectionBoundaryContract('getter-scope-control',s=>replace(s,
    'if (!this.isCurrentProjectionSource_(lease)) return\n      if (values.length',
    'if (false) return\n      if (values.length')),/GETTER_RETURN_LOST_SOURCE_MUST_NOT_OFFER_GEOMETRY/);
  negatives.push('removed captured Source check after Native return (controlled same-lease scope loss)');
  assert.throws(()=>projectionBoundaryContract('geometry-scope-control',s=>replace(s,
    'if (!this.isCurrentProjectionSource_(lease) || receive===undefined',
    'if (receive===undefined')),/GEOMETRY_REENTRY_RETIRE_MUST_NOT_OFFER_VISUAL/);
  negatives.push('removed Source check after geometry callback (controlled same-lease scope loss)');
  for(const stage of ['initial-stop','registration-return','observation-return','source-stop','scope-stop'])
    cases.push({name:'feedback-source-'+stage,result:feedbackSourceContract(stage)});
  cases.push({name:'feedback-source-native-fenced',result:feedbackSourceContract('source-stop',s=>s,true)});
  assert.throws(()=>feedbackSourceContract('initial-stop',s=>replace(s,
    'Date.now()<this.nextFeedbackAttempt || !session.hasCurrentSource()', 'Date.now()<this.nextFeedbackAttempt')),
    /STOPPED_SOURCE_MUST_NOT_REGISTER_FEEDBACK/);negatives.push('removed original Source gate before registration');
  assert.throws(()=>feedbackSourceContract('source-stop',s=>replace(s,
    'this.feedbackLease===lease && session.hasCurrentSource()', 'this.feedbackLease===lease')),
    /LOST_SOURCE_MUST_REJECT_ORIGINAL_BUTTON_CALLBACK/);negatives.push('removed original Source callback acceptance');
  assert.throws(()=>feedbackSourceContract('scope-stop',s=>replace(s,
    'this.feedbackLease===lease && session.hasCurrentSource()', 'this.feedbackLease===lease'),false,true),
    /LOST_SOURCE_MUST_REJECT_ORIGINAL_HAPTIC_CALLBACK/);negatives.push('removed original Source haptic acceptance with matching Native receipt');
  assert.throws(()=>feedbackSourceContract('registration-return',s=>replace(s,
    'session!==this.touchSession || !session.hasCurrentSource()) {','session!==this.touchSession) {')),
    /RETURNED_LEASE_FOR_LOST_SOURCE_MUST_BE_RELEASED/);negatives.push('removed original Source gate after Native registration');
  assert.throws(()=>feedbackSourceContract('observation-return',s=>replace(s,
    'return this.observationEnabled===true','return true')),/NATIVE_RETURN_MUST_RECHECK_OBSERVATION_FLAG/);
  negatives.push('cached/constant observation true misses actual Native-return false reentry');
} finally {globalThis.setInterval=savedSet;globalThis.clearInterval=savedClear;Date.now=savedNow;}

/** Want平台边缘明确模拟内部Ability派发和固定IO；真实原Port处理Host/活动/登记身份。 */
async function wantContract(rewrite=s=>s) {
  let running=false,activity=33,product='default',hooks=true,process=1;const writes=[],starts=[];
  const host={isRunning:()=>running,isEnded:()=>false,sessionActivity:()=>activity};
  const pure=makePureEtsLoader({});const port=pure(portFile);
  let operated=0;const registration=port.registerEntryInputObservation(host,7,action=>{
    operated++;const result=new port.EntryInputObservationResult();result.activity=33;result.enabled=action!=='off';result.outcome='actual-component';return result;});
  assert.ok(registration,'原组件可早于正常runLaunch登记，但登记不能冒运行资格');
  assert.equal(port.operateEntryInputObservation(33,'read').qualified,false);assert.equal(operated,0);running=true;
  const policy={hasTestHooks:()=>hooks},profile={get product(){return product;}};
  let hostFactoryCalls=0;
  const load=makePureEtsLoader({'@kit.AbilityKit':{},commons:{DiagnosticPolicy:policy,writeEvidenceTextAtomic:(p,t)=>writes.push([p,JSON.parse(t)])},
    'entry/ProductBuildProfile':{ProductBuildProfile:profile},'libentry.so':{__esModule:true,default:{desktopGameProcessState:()=>process}},
    '../runtime/GameSessionHost':{getGameSessionHost:()=>{hostFactoryCalls++;return host;}},'./EntryInputObservationPort':port}, {[wantFile]:checkedSource(wantFile,rewrite(source(wantFile)))});
  const wants=load(wantFile),context={filesDir:'/sandbox',applicationInfo:{name:'com.amcl.launcher'},startAbility:async want=>starts.push(want)};
  const request={parameters:{amclInputObservationTest:'off',requestId:'p6_off_1',activityId:33,uri:'ignored',path:'/arbitrary'}};
  await wants.forwardInputObservationTestWant(context,request);assert.equal(starts.length,1);
  assert.deepEqual(Object.keys(starts[0].parameters).sort(),['activityId','amclInputObservationTest','requestId']);
  assert.equal(writes.at(-1)[1].result.outcome,'Forwarding','转发成功不能伪造组件完成');
  wants.runInputObservationTestWant(context,starts[0],true);assert.equal(operated,1);assert.equal(writes.at(-1)[1].result.outcome,'actual-component');
  assert.equal(writes.at(-1)[1].result.qualified,true);
  assert.equal(hostFactoryCalls,0,'WANT_MUST_NOT_CALL_HOST_FACTORY');
  assert.ok(writes.every(([p])=>p==='/sandbox/input-observation-test-result.json'));
  const startsBeforeString=starts.length;
  await wants.forwardInputObservationTestWant(context,{parameters:{...request.parameters,activityId:'9007199254740991'}});
  assert.equal(starts.at(-1).parameters.activityId,9007199254740991,'外部严格字符串保留安全整数活动ID');
  await wants.forwardInputObservationTestWant(context,{parameters:{...request.parameters,activityId:'9007199254740992'}});
  assert.equal(starts.length,startsBeforeString+1,'超出安全整数必须拒绝，不舍入为另一活动');
  starts.pop();
  product='desktop';await wants.forwardInputObservationTestWant(context,request);
  assert.equal(starts.length,1,'NON_DEFAULT_MUST_NOT_FORWARD_OBSERVATION_CONTROL');product='default';
  hooks=false;await wants.forwardInputObservationTestWant(context,request);assert.equal(starts.length,1);hooks=true;
  wants.runInputObservationTestWant(context,{parameters:{...request.parameters,activityId:34}},true);assert.equal(operated,1);
  wants.runInputObservationTestWant(context,request,false);assert.equal(operated,1);
  running=false;wants.runInputObservationTestWant(context,request,true);assert.equal(operated,1);running=true;
  // 操作API只取原登记Host，不接收另一同活动值Host来替换资格；原Host停止即不可用。
  // 执行现役两个热生命周期正文，原Entry内部派发到真实GameAbility处理；仅Ability平台是边缘。
  const entry=methods('entry/src/main/ets/entryability/EntryAbility.ets',['onNewWant'],wants);
  entry.context=context;entry.onNewWant(request,{});await Promise.resolve();assert.equal(starts.length,2);
  const game=methods('entry/src/main/ets/gameability/GameAbility.ets',['onNewWant'],
    {...wants,AppLogger:{info(){}},TAG:'test',LOG_DOMAIN_LAUNCH:1});
  game.context=context;game.startupReady=true;game.onNewWant(starts.at(-1),{});assert.equal(operated,2);
  const newer=port.registerEntryInputObservation(host,8,()=>new port.EntryInputObservationResult());
  port.unregisterEntryInputObservation(registration);assert.equal(port.operateEntryInputObservation(33,'read').outcome,'FrontendUnavailable');
  // 新登记默认结果也为FrontendUnavailable，使用明确标记证明旧退休没有清它。
  port.unregisterEntryInputObservation(newer);
  const surviving=port.registerEntryInputObservation(host,9,()=>{const r=new port.EntryInputObservationResult();r.outcome='survives';return r;});
  port.unregisterEntryInputObservation(registration);assert.equal(port.operateEntryInputObservation(33,'read').outcome,'survives');
  port.unregisterEntryInputObservation(surviving);activity=34;
  wants.runInputObservationTestWant(context,request,true);assert.equal(writes.at(-1)[1].result.qualified,false);
  assert.equal(writes.at(-1)[1].result.outcome,'FrontendUnavailable');
  assert.equal(hostFactoryCalls,0,'无页面登记也不能创建Created Host');
  process=0;await wants.forwardInputObservationTestWant(context,request);assert.equal(starts.length,2);
  return {fixedPath:true,doubleGate:true,originalActivity:true};
}
cases.push({name:'want-route-and-fixed-receipt',result:await wantContract()});
await assert.rejects(()=>wantContract(s=>replace(s,"ProductBuildProfile.product!=='default' || ",'')),/NON_DEFAULT_MUST_NOT_FORWARD_OBSERVATION_CONTROL/);
negatives.push('removed default product gate');

/** 原登记中的Host资格读或真实操作回入换登记，不能把原结果涂成后来页面的qualified状态。 */
function portReentryContract(stage,rewrite=s=>s) {
  const port=makePureEtsLoader({}, {[portFile]:checkedSource(portFile,rewrite(source(portFile)))})(portFile);let reads=0,operations=0,armed=false;
  const newerHost={isRunning:()=>true,isEnded:()=>false,sessionActivity:()=>33};
  const replaceRegistration=()=>port.registerEntryInputObservation(newerHost,8,()=>new port.EntryInputObservationResult());
  const host={isEnded:()=>false,sessionActivity:()=>33,isRunning:()=>{
    reads++;if(armed&&((stage==='before'&&reads===1)||(stage==='after'&&reads===2)))replaceRegistration();return true;
  }};
  port.registerEntryInputObservation(host,7,()=>{operations++;if(stage==='callback')replaceRegistration();return new port.EntryInputObservationResult();});
  armed=true;const result=port.operateEntryInputObservation(33,'read');
  assert.equal(result.qualified,false,'PORT_CHANGED_DURING_HOST_READ_MUST_NOT_QUALIFY');
  assert.equal(operations,stage==='before'?0:1,'PORT_REPLACED_BEFORE_OPERATION_MUST_NOT_CALL_OLD_DELEGATE');
  assert.equal(result.outcome,stage==='before'?'FrontendUnavailable':'FrontendRetired');
  return {stage,reads,operations,outcome:result.outcome,qualified:result.qualified};
}
for(const stage of ['before','after','callback'])cases.push({name:'original-port-reentry-'+stage,result:portReentryContract(stage)});
assert.throws(()=>portReentryContract('before',s=>replace(s,
  "if (!host.isRunning() || host.sessionActivity()!==activity || current!==registration) return unavailable",
  "if (!host.isRunning() || host.sessionActivity()!==activity) return unavailable")),/PORT_REPLACED_BEFORE_OPERATION_MUST_NOT_CALL_OLD_DELEGATE/);
negatives.push('removed registration recheck after original Host qualification read');
assert.throws(()=>portReentryContract('after',s=>replace(s,
  "host.sessionActivity()!==activity || current!==registration) {", "host.sessionActivity()!==activity) {")),
  /PORT_CHANGED_DURING_HOST_READ_MUST_NOT_QUALIFY/);negatives.push('removed registration recheck after return Host qualification read');

/**
 * 无页面的Want使用真实Host工厂模块作反事实边缘，生产Host不改写；装配停在getter前。
 * 正例不触工厂/Native/timer；成功转译撤回必须实际造出Created/activity0 Host后命中行为断言。
 */
const noPageFacts=[];
function noPageWantContract(rewrite=s=>s) {
  const file='scripts/test-game-session-host.mjs',ast=compiler.createSourceFile(file,source(file),compiler.ScriptTarget.Latest,true);
  let body=ast.statements.find(n=>n.name?.getText(ast)==='fixture').getText(ast);
  const anchor='  const host = module.getGameSessionHost();';assert.ok(body.includes(anchor));
  body=body.slice(0,body.indexOf(anchor))+'return {module,env,calls};\n}';
  body=body.replaceAll("new URL('../' + hostPath, import.meta.url)","new URL('../' + hostPath, fixtureUrl)");
  const plan=makePureEtsLoader()('launch/src/main/ets/ResolvedInputPlan.ets');
  const original=new Function('assert','fs','environment','plan','wire','noop','fixtureUrl',body+'\nreturn fixture({realSources:true});')(
    assert,fs,environment,plan,'v=v1;abi=LWJGL2;slot=LWJGL2;window=GLFW;binding=liblwjgl_v2.so;policy=l2-pull',()=>{},pathToFileURL(path.join(PROJECT_ROOT,file)));
  const port=makePureEtsLoader({})(portFile),writes=[];let factories=0,created;
  const wants=makePureEtsLoader({'@kit.AbilityKit':{},commons:{DiagnosticPolicy:{hasTestHooks:()=>true},
    writeEvidenceTextAtomic:(_p,t)=>writes.push(JSON.parse(t))},'entry/ProductBuildProfile':{ProductBuildProfile:{product:'default'}},
    'libentry.so':{__esModule:true,default:{}},'./EntryInputObservationPort':port,
    '../runtime/GameSessionHost':{getGameSessionHost:()=>{factories++;const host=original.module.getGameSessionHost();
      created={lifecycle:host.lifecycle(),activity:host.sessionActivity()};return host;}}}, {[wantFile]:checkedSource(wantFile,rewrite(source(wantFile)))})(wantFile);
  wants.runInputObservationTestWant({filesDir:'/sandbox'},
    {parameters:{amclInputObservationTest:'read',requestId:'no_page',activityId:33}},true);
  const fact={factories,created,nativeCalls:original.calls.slice(),timers:original.env.timer.size,
    outcome:writes.at(-1)?.result.outcome,qualified:writes.at(-1)?.result.qualified};noPageFacts.push(fact);
  assert.equal(factories,0,'NO_PAGE_WANT_MUST_NOT_CREATE_HOST');assert.equal(original.env.timer.size,0);assert.deepEqual(original.calls,[]);
  assert.equal(fact.outcome,'FrontendUnavailable');assert.equal(fact.qualified,false);return fact;
}
cases.push({name:'actual-no-page-want-no-host-construction',result:noPageWantContract()});
const eagerFactory=s=>replace(s,
  "import { EntryInputObservationResult, operateEntryInputObservation } from './EntryInputObservationPort'",
  "import { getGameSessionHost } from '../runtime/GameSessionHost'\nimport { EntryInputObservationResult, operateEntryInputObservation } from './EntryInputObservationPort'")
  .replace('result=operateEntryInputObservation(request.activity,request.action)',
    'getGameSessionHost(); result=operateEntryInputObservation(request.activity,request.action)');
assert.throws(()=>noPageWantContract(eagerFactory),/NO_PAGE_WANT_MUST_NOT_CREATE_HOST/);
assert.deepEqual(noPageFacts.at(-1).created,{lifecycle:'Created',activity:0});
negatives.push('restored no-page Want factory actually creates original Created Host');
await assert.rejects(()=>wantContract(s=>replace(s,
  "import { EntryInputObservationResult, operateEntryInputObservation } from './EntryInputObservationPort'",
  "import { getGameSessionHost } from '../runtime/GameSessionHost'\nimport { EntryInputObservationResult, operateEntryInputObservation } from './EntryInputObservationPort'")
  .replace('result=operateEntryInputObservation(request.activity,request.action)',
    'getGameSessionHost(); result=operateEntryInputObservation(request.activity,request.action)')),
  /WANT_MUST_NOT_CALL_HOST_FACTORY/);negatives.push('restored eager Host factory in Want operation');

/** 真正冷GameAbility.onCreate必须在任何Native/Host初始化前退出，不以转发检查排除竞态。 */
function coldContract(rewrite=s=>s) {
  let terminations=0,initializations=0;
  const subject=methods('entry/src/main/ets/gameability/GameAbility.ets',['onCreate'],{
    isInputObservationTestWant:want=>want.parameters?.amclInputObservationTest!==undefined,
    DiagnosticPolicy:{configure(){}},ProductBuildProfile:{developerDiagnostics:true},runInputObservationTestWant:(_c,_w,ready)=>assert.equal(ready,false),
    testNapi:{getDiagnosticCapabilities:()=>3,configureSideloadInstallRoot:()=>{initializations++;throw Error('unexpected initialization');}},
  },rewrite);
  subject.context={filesDir:'/sandbox',terminateSelf:async()=>terminations++};subject.failStartup_=()=>{};
  subject.onCreate({parameters:{amclInputObservationTest:'off'}},{});
  assert.equal(initializations,0,'COLD_DIAGNOSTIC_MUST_NOT_INITIALIZE_SOURCE_OR_HOST');assert.equal(terminations,1);return {terminations,initializations};
}
cases.push({name:'actual-cold-ability-guard',result:coldContract()});
assert.throws(()=>coldContract(s=>replace(s,'if (isInputObservationTestWant(want)) {','if (false) {')),
  /COLD_DIAGNOSTIC_MUST_NOT_INITIALIZE_SOURCE_OR_HOST/);negatives.push('removed cold GameAbility guard');
const drift=bound.filter(p=>sha(p)!==before[p]);assert.deepEqual(drift,[]);
const out=workspacePath('run','input-observation-control-'+process.pid);fs.mkdirSync(out,{recursive:true});
fs.writeFileSync(path.join(out,'receipt.json'),JSON.stringify({startedAt,endedAt:new Date().toISOString(),before,cases,negatives,noPageFacts,compilationFacts,drift,
  limits:'Host资格边缘/Native和Ability平台边缘受控；真实Session、组件方法/闭包、broker、Port和Want执行。无SDK或设备证明。'},null,2));
console.log('INPUT_OBSERVATION_PASS cases='+cases.length+' compiled_behavior_negatives='+negatives.length+' evidence='+out);
