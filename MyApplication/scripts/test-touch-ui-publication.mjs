/**
 * 执行现役Store→GameControls→Controller→Entry/Model及Panel事件的发布/触点组合。
 * 只替换Native布尔回执与SDK测量接缝，不复制发布协调器、坐标投影或工具接触算法。
 * 正例同时验证显示元数据更新、输入身份稳定与真正生命周期取消；撤回负控必须运行到行为断言。
 * 本门禁证明JS生产层时序；Native continuation准入另由生产State/NAPI/工具回归核实，不冒称设备通过。
 */
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import compiler from './lib/ets-compiler.mjs';
import {makePureEtsLoader} from './lib/load-pure-ets.mjs';
import {PROJECT_ROOT,assertExternalOutputPath,workspacePath} from './lib/workspace-paths.mjs';

const STORE='gamecontrol/src/main/ets/InputSurfaceContext.ets';
const CONTROLS='entry/src/main/ets/components/GameControls.ets';
const MODULES=['ControlLayout','TouchPreferences','TouchActionBindings','RuntimeTouchLayout','InputSurfaceContext',
  'GameGuiGeometry','TouchGuide','TouchGyroscope','VirtualMouseModel','LayoutCandidate','TouchControlGeometry','InputConfiguration'];
const sources=new Map();
function source(relative){if(!sources.has(relative))sources.set(relative,fs.readFileSync(path.join(PROJECT_ROOT,relative),'utf8'));return sources.get(relative);}
function replaceOnce(text,before,after){assert.equal(text.split(before).length-1,1,'变异必须命中唯一生产锚点');return text.replace(before,after);}
/** 原文提取生产方法，保留其调用与分支；只给无法在宿主创建的SDK依赖提供参数。 */
function methods(relative,ownerName,names,dependencies,overrides={}) {
  if(names.includes('sendControlSchema'))dependencies={...makePureEtsLoader({'gamecontrol':makePureEtsLoader()('gamecontrol/src/main/ets/ControlLayout.ets')})
    ('entry/src/main/ets/components/TouchGroupSchemaCompiler.ets'),...dependencies};
  const text=overrides[relative]??source(relative),ast=compiler.createSourceFile(relative,text,compiler.ScriptTarget.Latest,true);
  const owner=ast.statements.find(node=>node.name?.getText(ast)===ownerName);assert.ok(owner,ownerName);
  const body=names.map(name=>{const member=owner.members.find(node=>node.name?.getText(ast)===name);assert.ok(member,name);return member.getText(ast);}).join('\n');
  const compiled=compiler.transpileModule('class Subject{'+body+'}\nmodule.exports=Subject;',
    {compilerOptions:{target:compiler.ScriptTarget.ES2020,module:compiler.ModuleKind.CommonJS},reportDiagnostics:true});
  assert.equal((compiled.diagnostics??[]).filter(d=>d.category===compiler.DiagnosticCategory.Error).length,0,'生产方法必须先编译通过');
  const module={exports:{}};new Function('module',...Object.keys(dependencies),compiled.outputText)(module,...Object.values(dependencies));
  return new module.exports();
}
/** Panel传给父层的实际闭包也取生产AST，不能另造一个只调用sync的假onInteraction。 */
function interaction(subject,overrides={}) {
  const text=overrides[CONTROLS]??source(CONTROLS),ast=compiler.createSourceFile(CONTROLS,text,compiler.ScriptTarget.Latest,true),found=[];
  const owner=ast.statements.find(n=>n.name?.getText(ast)==='GameControls'),build=owner.members.find(n=>n.name?.getText(ast)==='build');
  function visit(n){if(compiler.isPropertyAssignment(n)&&n.name?.getText(ast)==='onInteraction'&&compiler.isArrowFunction(n.initializer))found.push(n.initializer.getText(ast));compiler.forEachChild(n,visit);}
  visit(build);assert.equal(found.length,1,'只能提取现役VirtualMousePanel的onInteraction');
  const js=compiler.transpileModule('module.exports='+found[0]+';',
    {compilerOptions:{target:compiler.ScriptTarget.ES2020,module:compiler.ModuleKind.CommonJS}}).outputText;
  const module={exports:{}};new Function('module',js).call(subject,module);return module.exports;
}
function pure(overrides={}){const load=makePureEtsLoader({commons:{AppLogger:{warn(){}}}},overrides);return Object.assign({},...MODULES.map(name=>load('gamecontrol/src/main/ets/'+name+'.ets')));}
function sample(game){const value=new game.InputSurfaceContextCandidate();Object.assign(value,{windowId:45,displayId:0,widthPx:2800,heightPx:1840,
  density:2.125,transform:0,refreshRateHz:60,provisional:false});return value;}

/** 用现役Store证明Hz/有效位更新不丢失；几何、单位、可用性和publisher边界仍换身份。 */
function storeContract(overrides={}) {
  const game=pure(overrides),store=new game.InputSurfaceContextStore(),lease=store.beginPublisher('current'),value=sample(game);
  const initial=store.publish(lease,value);value.refreshRateHz=120;const faster=store.publish(lease,value);
  assert.equal(faster.generation,initial.generation,'REFRESH_INPUT_IDENTITY');assert.equal(faster.refreshRateHz,120,'REFRESH_METADATA_UPDATED');
  value.refreshRateHz=NaN;const absent=store.publish(lease,value);
  assert.equal(absent.generation,initial.generation,'REFRESH_AVAILABILITY_IDENTITY');assert.equal(absent.refreshRateHz,0);
  assert.equal(absent.has(game.INPUT_SURFACE_FIELD_REFRESH_RATE),false);
  value.refreshRateHz=60;assert.equal(store.publish(lease,value).generation,initial.generation);assert.equal(store.snapshot().refreshRateHz,60);
  assert.equal(initial.refreshRateHz,60,'之前借出的防御快照不能被后续采样改写');
  for(const [field,next] of [['windowId',46],['displayId',1],['leftPx',1],['topPx',1],['widthPx',2801],['heightPx',1841],
    ['density',2.25],['transform',1],['provisional',true],['widthPx',0],['density',0],['transform',-1],['displayId',-1],['windowId',0]]) {
    const before=store.snapshot();value[field]=next;const changed=store.publish(lease,value);
    assert.ok(changed.generation>before.generation,'真实输入字段或availability变化必须换代: '+field);
  }
  const prior=store.snapshot(),replacement=store.beginPublisher('replacement');
  assert.ok(store.snapshot().generation>prior.generation);assert.equal(store.publish(lease,sample(game)),undefined,'旧publisher不能恢复新页面');
  const current=store.publish(replacement,sample(game));assert.ok(current.generation>initial.generation);
  const ended=store.endPublisher(replacement);assert.ok(ended.generation>current.generation);assert.equal(ended.validFields,0);
  assert.equal(ended.provisional,false);assert.equal(store.publish(replacement,sample(game)),undefined);
  const restart=store.beginPublisher('restart'),newPage=store.publish(restart,sample(game));assert.ok(newPage.generation>ended.generation);
  return {initial:initial.generation,refresh:faster.generation,latest:newPage.generation};
}

/** Native接缝只记录出口与不可分辨的成功回执；所有JS状态推进由实际生产方法完成。 */
function fixture(overrides={}) {
  const game=pure(overrides),trace=[];let serial=1,installedSchema,modal=false;
  let state={version:1,status:'idle',surface:'7',session:'3',policy:'1',schemaGeneration:'1',grabEpoch:'1',grabbed:false,
    token:'',operationId:'',candidateId:'',fenced:false,nativeTouches:0,modalCount:0,density:2.125,transform:0};
  const native={touchPublicationState:()=>({...state}),beginTouchPublication:(op,candidate)=>{
    state={...state,status:'fenced',fenced:true,operationId:op,candidateId:candidate,token:String(++serial)};
    trace.push({phase:'begin',token:state.token});return {...state};},
    publishTouchSchema:schema=>{const next=JSON.stringify(schema),same=next===installedSchema;installedSchema=next;
      state={...state,status:same?'unchanged':'committed'};trace.push({phase:'install',status:state.status});return {...state};},
    confirmTouchPublication:()=>{state={...state,status:'idle',fenced:false};trace.push({phase:'confirm'});return true;},
    isTouchPublicationCurrent:token=>!state.fenced&&token===state.token,
    setTouchMenuMouseBounds:(...args)=>{trace.push({phase:'bounds',args});return true;},
    moveTouchMenuPointer:(dx,dy,token,prefix)=>{trace.push({phase:'move',dx,dy,token,prefix});return true;},
    touchMenuScroll:(steps,token,prefix)=>{trace.push({phase:'wheel',steps,token,prefix});return true;},
    touchMenuButton:(owner,code,down,token)=>{trace.push({phase:'button',owner,code,down,token});return true;},
    cancelTouchMenuMouse:prefix=>{trace.push({phase:'cancel',prefix});return true;}};
  const load=makePureEtsLoader({commons:{AppLogger:{warn(){}}},'gamecontrol':game,'libentry.so':{__esModule:true,default:native},
    '@kit.PerformanceAnalysisKit':{hilog:{info(){},warn(){}}}},overrides);
  const {EntryVirtualMouse}=load('entry/src/main/ets/components/EntryVirtualMouse.ets');
  const {TouchSurfaceController,TouchSurfaceCandidate}=load('entry/src/main/ets/components/TouchSurfaceController.ets');
  const store=new game.InputSurfaceContextStore(),lease=store.beginPublisher('page'),value=sample(game);store.publish(lease,value);
  const deps={...game,TouchSurfaceCandidate,testNapi:native,getInputSurfaceContextStore:()=>store,hasEntryTouchModal:()=>modal,
    releaseEntryTouchModal:()=>true,DEFAULT_JOYSTICK_DEAD_ZONE:.18,getLayoutStore:()=>({isReady:()=>false})};
  const view=methods(CONTROLS,'GameControls',['openMouse','syncMouseBounds','mouseFrame','registerRegions','sendControlSchema','triggerCode',
    'presentTouchCandidate_','confirmTouchLayout_','touchNodeId_','touchMarkerId_','arktsTouchContactCount_','onSurfaceContextChanged',
    'mouseEntryVisible_','mouseEntryPresented_','canOpenMouse_','mousePanelVisible_','retireHiddenMouse_','closeMouse','admitTouchAction_'],deps,overrides);
  Object.assign(view,{mounted:true,pageActive:true,editing:false,imeOpen:false,fieldImeOpen:false,isGrabbed:false,
    layoutObserverRegistered:true,appearanceGeneration:1,profileVer:0,presentedCandidateId:'',uiPublicationToken:'',touchStatusMessage:'',
    mouseOpen:false,compWidth:2800/2.125,compHeight:1840/2.125,density:2.125,desiredProfile:game.getDefaultLayout(),profile:game.getDefaultLayout(),
    runtimeLayout:new game.RuntimeTouchLayout(),guiHint:false,guiState:new game.GameGuiState(),globalVisMode:0,drawerOpen:new Map(),
    touchVisual:{menuX:1200,menuY:900},mouseController:new EntryVirtualMouse(),mouseGeometry:new game.FloatingMouseFrame(),
    syncGuideBounds(){},realGameVersion:'1.21.11',
    unresolvedSurfaceModal:undefined,buttonFingerIds:new Map(),scrollFingerIds:new Map(),hotbarFingerId:new Map(),dragLookFinger:new Map(),
    blockedUiFingers:new Set(),joystickFingerId:-1});
  const maintenance=load('entry/src/main/ets/components/EntryTouchInputMaintenance.ets');
  const maintenanceLease=maintenance.startEntryTouchInputMaintenance();
  view.touchSession=methods('entry/src/main/ets/components/EntryTouchSession.ets','EntryTouchSession',
    ['schemaOptions','adoptConfirmedTouchBindings'],{...game,isEntryTouchInputMaintenanceCurrent:maintenance.isEntryTouchInputMaintenanceCurrent},overrides);
  Object.assign(view.touchSession,{bindings:new game.TouchBindingSnapshot(),follow:true,bindingOptionsText:'',originLease:maintenanceLease,setRuntimeContext(){},setGuiViewport(){},
    setTouchAdmission(){},refreshBindings(){},refreshVisual(){}});
  view.getUIContext=()=>({vp2px:()=>2.125,getComponentUtils:()=>({getRectangleById:id=>{
    if(id===view.touchMarkerId_())return {size:{width:2.125,height:2.125}};
    const entry=view.runtimeLayout.entries.find(e=>view.touchNodeId_(e.item.id)===id);assert.ok(entry,'实际SDK节点: '+id);
    return {size:{width:entry.rectPx.width,height:entry.rectPx.height},localOffset:{x:entry.rectPx.x,y:entry.rectPx.y}};}})});
  view.touchSurface=new TouchSurfaceController((candidate,token)=>view.presentTouchCandidate_(candidate,token),()=>view.arktsTouchContactCount_(),()=>{});
  view.registerRegions();view.confirmTouchLayout_();assert.equal(view.touchSurface.admits(view.uiPublicationToken),true,
    JSON.stringify({message:view.touchStatusMessage,state,trace,progress:view.touchSurface.status()}));view.openMouse();
  const model=view.mouseController.model,panel=methods('entry/src/main/ets/components/VirtualMousePanel.ets','VirtualMousePanel',
    ['touchArea','refreshHeld'],{TouchType:{Down:0,Move:1,Up:2,Cancel:3}},overrides);
  Object.assign(panel,{model,alive:true,onInteraction:interaction(view,overrides)});
  const touch=(type,x,id=1,part='left')=>{const point={id,windowX:part==='wheel'?100:x,windowY:part==='wheel'?x:100,pressedTime:id};
    panel.touchArea({type,stopPropagation(){},changedTouches:type===1?[]:[point],touches:type===2?[]:[point]},part);};
  return {game,view,store,lease,value,model,panel,touch,trace,modal:value=>{modal=value;},state:()=>({...state}),
    installedSchema:()=>JSON.parse(installedSchema)};
}
function refreshContract(overrides={}) {
  const f=fixture(overrides);f.touch(0,100);f.touch(1,107);const token=f.view.uiPublicationToken,identity=f.store.snapshot().generation;
  const cancels=f.trace.filter(e=>e.phase==='cancel').length,begins=f.trace.filter(e=>e.phase==='begin').length;
  f.view.touchVisual.menuX+=50;f.view.syncMouseBounds();f.view.registerRegions();assert.equal(f.model.activeContacts(),true);
  f.value.refreshRateHz=120;f.store.publish(f.lease,f.value);f.view.onSurfaceContextChanged();
  assert.equal(f.store.snapshot().refreshRateHz,120);assert.equal(f.store.snapshot().generation,identity,'REFRESH_INPUT_IDENTITY');
  assert.equal(f.view.uiPublicationToken,token);assert.equal(f.trace.filter(e=>e.phase==='begin').length,begins);
  assert.equal(f.trace.filter(e=>e.phase==='cancel').length,cancels);assert.equal(f.model.down(-1),true);
  f.touch(1,140);f.touch(2,180);assert.equal(f.model.activeContacts(),false);assert.equal(f.model.down(-1),false);
  assert.deepEqual(f.trace.filter(e=>e.phase==='move').map(e=>e.dx),[14.875,70.125,85]);
  assert.deepEqual(f.trace.filter(e=>e.phase==='button').map(e=>e.down),[true,false]);return f.trace;
}
function pendingContract(overrides={},feedbackOnly=false) {
  const f=fixture(overrides);f.touch(0,100);const token=f.view.uiPublicationToken,installs=f.trace.filter(e=>e.phase==='install').length;
  assert.equal(f.view.arktsTouchContactCount_(),1,'TOOL_CONTACT_ZERO_GATE');
  f.view.desiredProfile.globalOpacity=.4;
  if(feedbackOnly){
    // 真实producer仍发布完整新反馈，不以touch行为等价性假装新Native开关已经安装。
    f.view.desiredProfile.haptic=false;f.view.desiredProfile.controls[0].label+='反馈';
    f.view.desiredProfile.controls[0].style={bg:'#abcdef'};
  }
  f.view.registerRegions();f.view.syncMouseBounds();
  assert.equal(f.trace.filter(e=>e.phase==='install').length,installs,'TOOL_CONTACT_ZERO_GATE');
  assert.equal(f.view.touchSurface.pending(),true);assert.equal(f.view.touchSurface.admits(token),false);
  assert.equal(f.model.activeContacts(),true,'NEW_DOWN_GATE_KEEP_CONTACT');assert.equal(f.model.down(-1),true,'NEW_DOWN_GATE_KEEP_CONTACT');
  f.touch(0,200,2);assert.equal(f.model.hasContact(2,2),false,'waiting不得认领新LEFT触点');
  assert.equal(f.model.press('new-lock',340,true),false,'waiting不得创建新锁存owner');
  assert.equal(f.model.stepWheel(1),false,'waiting的无既有触点滚轮点击也属于新意图');
  f.touch(1,140);f.touch(2,180);assert.equal(f.model.activeContacts(),false);assert.equal(f.model.down(-1),false);
  const release=f.trace.findIndex(e=>e.phase==='button'&&!e.down);assert.ok(release>=0);
  assert.equal(f.trace[release-1].phase,'move','真实UP先携末段移动，再按冻结owner释放');
  assert.equal(f.trace[release-1].token,token);assert.equal(f.trace[release].token,token);
  f.view.touchSurface.reconcile();const nextInstall=f.trace.findLastIndex(e=>e.phase==='install');assert.ok(nextInstall>release);
  f.view.confirmTouchLayout_();assert.equal(f.view.touchSurface.admits(f.view.uiPublicationToken),true);
  if(feedbackOnly){
    assert.equal(f.view.profile.haptic,false);
    assert.ok(f.installedSchema().controls.length>0);
    assert.equal(f.installedSchema().controls.every(entry=>entry.haptic===false),true);
  }
  f.touch(0,220,3);assert.equal(f.model.hasContact(3,3),true);f.touch(2,240,3);return f.trace;
}
/** 已按下的滚轮与纯移动触点也计入zero门；等待时仅新意图关闭，不截断其真实MOVE/UP。 */
function pointerOnlyContract() {
  const results=[];
  for(const part of ['move','wheel']) {
    const f=fixture();f.touch(0,100,1,part);assert.equal(f.view.arktsTouchContactCount_(),1);
    const token=f.view.uiPublicationToken,installs=f.trace.filter(e=>e.phase==='install').length;
    f.view.desiredProfile.globalOpacity=.4;f.view.registerRegions();f.view.syncMouseBounds();
    assert.equal(f.trace.filter(e=>e.phase==='install').length,installs);assert.equal(f.model.activeContacts(),true);
    f.touch(1,140,1,part);f.touch(2,160,1,part);assert.equal(f.model.activeContacts(),false);
    assert.deepEqual(f.trace.filter(e=>e.phase==='button'),[],'纯移动/滚轮不得补造LEFT');
    const outputs=f.trace.filter(e=>e.phase===(part==='wheel'?'wheel':'move'));
    assert.equal(outputs.length,2);assert.equal(outputs.every(e=>e.token===token),true);
    if(part==='wheel')assert.deepEqual(outputs.map(e=>e.steps),[3,2]);else assert.deepEqual(outputs.map(e=>e.dx),[85,42.5]);
    f.view.touchSurface.reconcile();f.view.confirmTouchLayout_();assert.equal(f.view.touchSurface.admits(f.view.uiPublicationToken),true);
    results.push({part,outputs});
  }
  return results;
}
function lifecycleContract() {
  const results=[];
  for(const gate of ['pageActive','mouseOpen','isGrabbed','editing','imeOpen','fieldImeOpen','modal','context']) {
    const f=fixture();f.touch(0,100);const before=f.trace.filter(e=>e.phase==='cancel').length;
    if(gate==='modal')f.modal(true);else if(gate==='context')f.view.runtimeLayout.context.valid=false;
    else f.view[gate]=gate==='pageActive'||gate==='mouseOpen'?false:true;
    f.view.syncMouseBounds();assert.equal(f.model.activeContacts(),false,gate+'必须取消');assert.equal(f.model.down(-1),false);
    assert.ok(f.trace.filter(e=>e.phase==='cancel').length>before);f.touch(0,200,2);assert.equal(f.model.hasContact(2,2),false);
    results.push(gate);
  }
  return results;
}

const evidence={scope:'actual JS source composition; controlled Native/SDK boundaries, not SDK/device acceptance',
  store:storeContract(),refreshTrace:refreshContract(),pendingTrace:pendingContract(),feedbackTrace:pendingContract({},true),
  pointerOnly:pointerOnlyContract(),lifecycle:lifecycleContract(),negatives:[]};
/** 每项撤回必须保持可执行，并在明确的行为断言失败；语法、导入或其它异常不能算负控成功。 */
const negativeCases=[
  ['old-refresh-input-identity',STORE,s=>replaceOnce(s,'left.transform === right.transform &&',
    'left.transform === right.transform &&\n      left.refreshRateHz === right.refreshRateHz &&'),o=>storeContract(o),'REFRESH_INPUT_IDENTITY'],
  ['old-refresh-metadata-frozen',STORE,s=>replaceOnce(s,'normalized.generation = InputSurfaceContextStore.sameSemantics',
    'if (InputSurfaceContextStore.sameSemantics(this.currentValue, normalized)) return this.currentValue.copy()\n    normalized.generation = InputSurfaceContextStore.sameSemantics'),o=>storeContract(o),'REFRESH_METADATA_UPDATED'],
  ['omitted-tool-contact-zero',CONTROLS,s=>replaceOnce(s,'return fingers.size + (this.mouseController.model.activeContacts() ? 1 : 0)',
    'return fingers.size'),o=>pendingContract(o),'TOOL_CONTACT_ZERO_GATE'],
  ['new-down-gate-cancels-contact',CONTROLS,s=>replaceOnce(s,
    'this.mouseController.configure(active,this.density,this.touchSurface.admits(this.uiPublicationToken))',
    'this.mouseController.configure(active && this.touchSurface.admits(this.uiPublicationToken),this.density,true)'),o=>pendingContract(o),'NEW_DOWN_GATE_KEEP_CONTACT'],
];
const mutatedSources=[];
for(const [name,relative,mutate,run,expected] of negativeCases) {
  const changed=mutate(source(relative));let failure;
  try{run({[relative]:changed});}catch(error){failure=error;}
  assert.ok(failure instanceof assert.AssertionError&&failure.message.includes(expected),name+'必须运行到预期行为断言: '+failure);
  evidence.negatives.push({name,mutatedSourceSHA256:crypto.createHash('sha256').update(changed).digest('hex'),
    assertion:expected,actualFailure:failure.message});
  mutatedSources.push({name,changed,stack:failure.stack});
}
const bound=[...MODULES.map(n=>'gamecontrol/src/main/ets/'+n+'.ets'),CONTROLS,'entry/src/main/ets/components/EntryVirtualMouse.ets',
  'entry/src/main/ets/components/TouchSurfaceController.ets','entry/src/main/ets/components/EntryTouchSession.ets',
  'entry/src/main/ets/components/VirtualMousePanel.ets','scripts/test-touch-ui-publication.mjs'];
evidence.sources=Object.fromEntries(bound.map(p=>[p,crypto.createHash('sha256').update(fs.readFileSync(path.join(PROJECT_ROOT,p))).digest('hex')]));
const at=process.argv.indexOf('--output'),base=at>=0?assertExternalOutputPath(process.argv[at+1]):workspacePath('run','touch-ui-publication');
const output=path.join(base,'run-'+process.pid+'-'+crypto.randomUUID().slice(0,8));fs.mkdirSync(output,{recursive:true});
// 完整撤回源码与实际AssertionError留在独占外置证据目录，复核者可重放同一生产来源。
for(const mutant of mutatedSources){fs.writeFileSync(path.join(output,mutant.name+'.ets'),mutant.changed);
  fs.writeFileSync(path.join(output,mutant.name+'.log'),mutant.stack+'\n');}
fs.writeFileSync(path.join(output,'evidence.json'),JSON.stringify(evidence,null,2)+'\n');
console.log('[touch-ui-publication] PASS actual Store/GC/Controller/Entry/Panel/Model: metadata, zero-contact, continuation, 8 lifecycle gates, 4 behavioral negatives; evidence='+output);
