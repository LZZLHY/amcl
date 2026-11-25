/**
 * 执行真实触控会话、原组件挂接闭包和反馈broker，检查投影、回入及来源退休。平台
 * Native与节点使用宿主替身，剩余代码按生产逻辑执行。
 * 提取现役GUI fixture只复用它的边界装配，不复制输入算法，产品正文均逐字转译执行。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import compiler from './lib/ets-compiler.mjs';
import {makePureEtsLoader} from './lib/load-pure-ets.mjs';
import {PROJECT_ROOT,workspacePath} from './lib/workspace-paths.mjs';
const sessionFile='entry/src/main/ets/components/EntryTouchSession.ets';
const controlsFile='entry/src/main/ets/components/GameControls.ets';
const fixtureFile='scripts/test-game-gui-source-lease.mjs';
const raw=p=>fs.readFileSync(path.join(PROJECT_ROOT,p));
const source=p=>raw(p).toString('utf8').replaceAll('\r\n','\n');
const bound=[sessionFile,controlsFile,fixtureFile,'scripts/test-input-observation-control.mjs',
  'entry/src/main/ets/components/EntryControlFeedbackBroker.ets','entry/src/main/ets/components/EntryTouchInputMaintenance.ets',
  'gamecontrol/src/main/ets/LayoutStore.ets','gamecontrol/src/main/ets/InputConfiguration.ets',
  'scripts/lib/ets-compiler.mjs','scripts/lib/load-pure-ets.mjs'];
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
const savedSet=globalThis.setInterval,savedClear=globalThis.clearInterval;let timers;
globalThis.setInterval=fn=>{const id=timers.size+1;timers.set(id,fn);return id;};globalThis.clearInterval=id=>timers.delete(id);
let now=1000;const savedNow=Date.now;Date.now=()=>now;
const cases=[],negatives=[];
function componentContract(rewrite=s=>s) {
  const f=sessionFixture();timers=f.timers;const session=new f.module.EntryTouchSession();
  const buttons=[],haptics=[],bounds=[],samples=[],retiredGyro=[],learningWrites=[];let movement=0;
  f.native.touchGyroLeaseContext=()=> 'original-context';f.native.beginTouchGyroLease=()=> 'original-gyro';
  f.native.submitTouchGyroLease=(...args)=>{samples.push(args);return true;};
  f.native.retireTouchGyroLease=lease=>{retiredGyro.push(lease);return true;};
  const definition=f.models.getDefaultLayout();definition.profileId='original';definition.profileRevision=1;
  definition.touch={gyroscopeMode:'always',gyroscopeSensitivity:1};f.store.getActiveProfile=()=>f.models.cloneLayout(definition);
  const visual=(x,y)=>[x,y,...Array(10).fill(0),7,0,0,movement,0,-1,0,0,0,0,0,0,1];f.native.touchInteractionVisual=()=>visual(20,30);
  f.native.onButtonPressed=cb=>{buttons.push(cb);return true;};
  f.native.onHaptic=cb=>{haptics.push(cb);return true;};
  f.native.touchPublicationState=()=>({version:1,fenced:false,modalCount:0,schemaGeneration:'7',session:'20',grabEpoch:'9'});
  const load=makePureEtsLoader({'libentry.so':{__esModule:true,default:f.native}});
  const feedback=load('entry/src/main/ets/components/EntryControlFeedbackBroker.ets');
  const mouse=load('gamecontrol/src/main/ets/VirtualMouseModel.ets');let vibrations=0,schemas=0;
  const names=['observationEnabled','touchFeedbackObservationEnabled_','subscribeTouchObservation_','ensureTouchFeedback_',
    'receiveGameGui','maybeOpenLearning','observeLearning','syncGuideObservation','mouseFrame','setPressed','isPressed'];
  const view=methods(controlsFile,names,{...feedback,...f.models,...mouse,EntryTouchVisual:f.module.EntryTouchVisual,
    hapticTap:()=>vibrations++,hilog:{warn(){}},GAME_CONTROLS_TAG:'test',hasEntryTouchModal:()=>false},rewrite);
  Object.assign(view,{mounted:true,pageActive:true,appearanceGeneration:7,observationGeneration:1,
    feedbackLease:undefined,nextFeedbackAttempt:0,feedbackRegistrationWarned:false,
    touchSession:session,touchVisual:new f.module.EntryTouchVisual(),guiState:new f.models.GameGuiState(),
    schemaActive:true,uiPublicationToken:'actual-publication',runtimeLayout:{find:()=>({})},btnVisMap:new Map(),btnPressedVer:0,
    getBtnVis:id=>{if(!view.btnVisMap.has(id))view.btnVisMap.set(id,{pressed:false});return view.btnVisMap.get(id);},
    compWidth:960,compHeight:540,density:1,menuGeometryX:0,menuGeometryY:0,isGrabbed:true,editing:false,imeOpen:false,fieldImeOpen:false,
    tutorialOpen:false,learningSeen:true,guideStep:0,guiHint:false,restorePending:0,guiGuard:{observe:()=>false},
    learningStore:{markSeen:()=>learningWrites.push('seen'),markClosed:()=>learningWrites.push('closed'),markLesson:()=>learningWrites.push('lesson')},
    touchGuide:new f.models.TouchGuide(),mouseOpen:true,guideScrollRequested:false,
    syncGuideBounds:()=>{},syncMouseBounds:()=>bounds.push(view.mouseFrame()),
    registerRegions:()=>{schemas++;}});
  const [gui,geometry]=productionCallbacks(view,session);
  session.setGuiViewport(1920,1080,'1.21.11');session.start(()=>{},true,gui,geometry);
  session.setGrabbed(true);session.setTouchAdmission(true);session.maintainSources();
  assert.equal(session.gyroscopeStatus(),'active');const gyro=f.sensorCallbacks.at(-1);
  gyro({x:0,y:1,z:0,timestamp:1e9});gyro({x:0,y:1,z:0,timestamp:1e9+20000000});assert.ok(samples.length>0);
  view.subscribeTouchObservation_();view.ensureTouchFeedback_();session.refreshVisual();
  assert.equal(view.touchGuide.start(view.touchVisual.guide),true);view.tutorialOpen=true;
  const oldButton=buttons.find(Boolean);
  oldButton('jump',true);assert.equal(view.isPressed('jump'),true);
  const origin=session.sourceLease,timer=session.timer,schemasBefore=schemas;
  session.unsubscribeVisual();
  // 跨过正常 GUI 采样窗口，再在原来源时钟观察缩放、几何及陀螺仪变化。
  now+=1500;
  f.raw[1]=4;f.raw[2]=4;f.raw[5]=480;f.raw[6]=270;
  movement=100;
  f.native.touchInteractionVisual=()=>visual(200,220);for(const tick of f.timers.values())tick();
  const samplesBefore=samples.length;gyro({x:0,y:1,z:0,timestamp:1e9+40000000});assert.ok(samples.length>samplesBefore,
    '原Source/gyro真实积分提交不随显示订阅关闭');assert.equal(f.sensorOff.length,0);
  assert.equal(view.guiState.effective,4);assert.ok(schemas>schemasBefore,'必要GUI确实到原组件registerRegions边缘');
  const profile=f.models.getDefaultLayout();profile.controls=[f.models.makeHotbarSelector(.1,.2,100,20)];
  const hotbar=f.models.projectGameHotbar(profile,profile.controls,view.guiState,960,540)[0];assert.equal(hotbar.baseWidth,360);
  assert.equal(view.menuGeometryX,200);assert.deepEqual(bounds.at(-1),view.mouseFrame());
  assert.equal(session.sourceLease,origin);assert.equal(session.timer,timer);assert.equal(f.sensorCallbacks.length,1);
  view.mounted=false;gui(new f.models.GameGuiState());geometry(999,999);assert.equal(view.menuGeometryX,200,'旧appearance必要闭包也不得写入');
  view.mounted=true;view.appearanceGeneration++;geometry(999,999);assert.equal(view.menuGeometryX,200,'组件重新挂接也不得复用旧appearance必要闭包');
  view.appearanceGeneration--;view.subscribeTouchObservation_();for(const tick of f.timers.values())tick();const retiringVisual=session.receive;
  f.module.stopEntryTouchInputMaintenance(f.host);const retiredReadCount=session.guiReads;
  retiringVisual(Object.assign(new f.module.EntryTouchVisual(),{menuX:999}));geometry(999,999);session.refreshVisual();
  assert.equal(view.touchVisual.menuX,200,'RETIRED_SOURCE_CANNOT_PUBLISH_TO_STILL_MOUNTED_COMPONENT');
  assert.equal(view.menuGeometryX,200);assert.equal(session.guiReads,retiredReadCount);
  session.stop();assert.deepEqual(retiredGyro,['original-gyro']);
  return {hotbarWidth:hotbar.baseWidth,sourceAndTimerRetained:true,realGyroSubmits:samples.length};
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
  // 在实际组件接收器边缘计数，避免在每个产品帧上维护测试专用计数器。
  let geometryOffers=0,visualOffers=0;
  session.setGuiViewport(1920,1080,'1.21.11');
  session.start(()=>{},true,gui,(x,y)=>{geometryOffers++;geometry(x,y);});
  view.subscribeTouchObservation_();
  const receive=session.receive;
  session.subscribeVisual(state=>{visualOffers++;receive(state);});
  f.native.touchInteractionVisual=()=>{getters++;if(stage.startsWith('getter-'))stop(stage.includes('control'));return [20,30,...Array(12).fill(0)];};
  try {
    session.refreshVisual();
    if(stage.startsWith('gui-'))assert.equal(getters,0,'GUI_REENTRY_RETIRE_MUST_NOT_READ_GLOBAL_VISUAL');
    else assert.equal(getters,1);
    if(stage==='current') {
      assert.equal(geometryOffers,1);assert.equal(visualOffers,1);
      assert.equal(view.menuGeometryX,20);assert.equal(view.touchVisual.menuX,20);
    } else if(stage.startsWith('getter-')) {
      assert.equal(geometryOffers,0,'GETTER_RETURN_LOST_SOURCE_MUST_NOT_OFFER_GEOMETRY');
      assert.equal(visualOffers,0);assert.equal(view.menuGeometryX,0);assert.equal(view.touchVisual.menuX,0);
    } else if(stage.startsWith('geometry-')) {
      assert.equal(geometryOffers,1,'停止发生前必要几何已合法投递');
      assert.equal(view.menuGeometryX,20);assert.equal(view.touchVisual.menuX,0);
      assert.equal(visualOffers,0,'GEOMETRY_REENTRY_RETIRE_MUST_NOT_OFFER_VISUAL');
    } else {assert.equal(geometryOffers,0);assert.equal(visualOffers,0);}
    return {stage,getters,geometryOffers,visualOffers,
      gcGeometry:view.menuGeometryX,gcVisual:view.touchVisual.menuX,sourceCurrent:session.hasCurrentSource(),
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
  for(const stage of ['current','gui-stop','gui-scope-stop','getter-stop','getter-scope-control','geometry-stop','geometry-scope-control'])
    cases.push({name:'projection-boundary-'+stage,result:projectionBoundaryContract(stage)});
  assert.throws(()=>projectionBoundaryContract('gui-stop',s=>replace(s,
    "if (epoch !== this.gyroConfigurationEpoch || !this.isCurrentProjectionSource_(lease)) return\n      if (typeof testNapi.touchInteractionVisual",
    "if (false) return\n      if (typeof testNapi.touchInteractionVisual")),/GUI_REENTRY_RETIRE_MUST_NOT_READ_GLOBAL_VISUAL/);
  negatives.push('removed Source check after actual GUI callback');
  assert.throws(()=>projectionBoundaryContract('getter-scope-control',s=>replace(s,
    'if (epoch !== this.gyroConfigurationEpoch || !this.isCurrentProjectionSource_(lease)) return\n      const geometryOnly',
    'if (false) return\n      const geometryOnly')),/GETTER_RETURN_LOST_SOURCE_MUST_NOT_OFFER_GEOMETRY/);
  negatives.push('removed captured Source check after Native return (controlled same-lease scope loss)');
  assert.throws(()=>projectionBoundaryContract('geometry-scope-control',s=>replace(s,
    'if (epoch !== this.gyroConfigurationEpoch || !this.isCurrentProjectionSource_(lease) || receive===undefined',
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

const drift=bound.filter(p=>sha(p)!==before[p]);assert.deepEqual(drift,[]);
const out=workspacePath('run','input-observation-control-'+process.pid);fs.mkdirSync(out,{recursive:true});
fs.writeFileSync(path.join(out,'receipt.json'),JSON.stringify({startedAt,endedAt:new Date().toISOString(),before,cases,negatives,compilationFacts,drift,
  limits:'Native和节点边缘受控；执行真实触控会话、组件方法/闭包及反馈broker。'},null,2));
console.log('INPUT_OBSERVATION_PASS cases='+cases.length+' compiled_behavior_negatives='+negatives.length+' evidence='+out);
