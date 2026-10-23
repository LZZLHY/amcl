/** 运行真实entry发布/反馈协调器和纯几何，仅替换Native/SDK边界；覆盖丢回执与迟到租约组合。 */
import assert from 'node:assert/strict';
import { environment } from './lib/ets-runtime-fixture.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import fs from 'node:fs';
import path from 'node:path';
import compiler from './lib/ets-compiler.mjs';

const load = makePureEtsLoader();
const layouts = load('gamecontrol/src/main/ets/ControlLayout.ets');
const surfaces = load('gamecontrol/src/main/ets/InputSurfaceContext.ets');
const geometry = load('gamecontrol/src/main/ets/RuntimeTouchLayout.ets');
const gui = load('gamecontrol/src/main/ets/GameGuiGeometry.ets');
let groups = 0;
function passed(name) { groups++; console.log('PASS ' + name); }

{
  const profile = layouts.getDefaultLayout();
  profile.globalScale=4; profile.controls[0].xPct=.95; profile.controls[0].yPct=.98;
  const original=JSON.stringify(profile);
  const surface=new surfaces.InputSurfaceContext();
  Object.assign(surface,{widthPx:640,heightPx:360,density:2,transform:1,generation:7,provisional:false,
    validFields:surfaces.INPUT_SURFACE_FIELD_DENSITY|surfaces.INPUT_SURFACE_FIELD_RECT});
  const context=geometry.runtimeTouchContext(surface,100,100,3);
  const result=geometry.projectRuntimeTouchLayout(profile,context,new gui.GameGuiState(),true,0,new Map());
  assert.ok(result.entries.length);
  for(const entry of result.entries) {
    assert.ok(entry.rectPx.x>=0 && entry.rectPx.x+entry.rectPx.width<=640);
    assert.ok(entry.rectPx.y>=0 && entry.rectPx.y+entry.rectPx.height<=360);
    assert.equal(entry.rectVp.x*2,entry.rectPx.x);assert.equal(entry.rectVp.width*2,entry.rectPx.width);
    assert.ok(Math.abs(entry.item.baseWidth*entry.item.itemScale*profile.globalScale*2-entry.rectPx.width)<1e-8);
  }
  assert.equal(JSON.stringify(profile),original,'运行时夹取不能修改用户存档');
  const before=context.key;surface.density=1;const after=geometry.runtimeTouchContext(surface,100,100,3);
  assert.notEqual(after.key,before,'相同px视口的density变化仍改变policy身份');
  surface.validFields=surfaces.INPUT_SURFACE_FIELD_RECT;
  assert.equal(geometry.runtimeTouchContext(surface,100,100,3).valid,false,'权威density缺失不能默认display复活');
  passed('single geometry: px/vp/clamp agreement, stored layout intact, density identity and authoritative absence');
}

function fixture(mutate=false,borrowSchema=false,onPresent=()=>{}) {
  let contacts=0, failBegin=false, loseCommit=false, reject=false, serial=0,previousToken='';
  let state={version:1,status:'idle',surface:'1',session:'10',policy:'20',schemaGeneration:'30',token:'',
    operationId:'',candidateId:'',fenced:false,nativeTouches:0,modalCount:0,density:2,transform:0,grabEpoch:'40',grabbed:false};
  const calls=[], presentations=[], warnings=[];
  const napi={
    touchPublicationState:()=>({...state}),
    beginTouchPublication:(operation,candidate,surface,session,policy,schema,grabEpoch)=>{
      calls.push(['begin',operation]); if(failBegin)throw Error('temporary');
      previousToken=state.token;
      assert.deepEqual([surface,session,policy,schema,grabEpoch],[state.surface,state.session,state.policy,state.schemaGeneration,state.grabEpoch]);
      state={...state,status:'fenced',operationId:operation,candidateId:candidate,token:String(++serial),fenced:true};return {...state};
    },
    publishTouchSchema:(schema,operation)=>{
      calls.push(['attempt-publish',operation]);
      assert.equal(state.fenced,true,'安装必须先关新DOWN');assert.equal(operation,state.operationId);
      assert.equal(state.nativeTouches,0);assert.equal(contacts,0,'Native零触点不能漏ArkTS面板角色');
      calls.push(['publish',operation,structuredClone(schema)]);
      if(reject)return {...state,status:'invalid'};
      state={...state,status:'committed',schemaGeneration:String(Number(state.schemaGeneration)+1)};
      if(loseCommit){loseCommit=false;throw Error('receipt lost after install');}return {...state};
    },
    confirmTouchPublication:(operation,token)=>{
      calls.push(['confirm',operation,token]);if(operation!==state.operationId || token!==state.token || state.status==='stale')return false;
      state.fenced=false;return true;
    },
    abortTouchPublication:operation=>{
      if(operation===state.operationId && reject)state={...state,status:previousToken?'idle':'invalid',operationId:'',candidateId:'',token:previousToken||'0',fenced:!previousToken};
      return {...state};
    }
  };
  const relative='entry/src/main/ets/components/TouchSurfaceController.ets';
  const env=environment({imports:{'libentry.so':{default:napi}},sourceOverrides:mutate||borrowSchema?{
    [relative]:source=>borrowSchema
      ?source.replace('this.schemaValue = JSON.parse(JSON.stringify(schema)) as ControlSchemaMsg','this.schemaValue = schema')
        .replace('get schema(): ControlSchemaMsg { return JSON.parse(JSON.stringify(this.schemaValue)) as ControlSchemaMsg }',
          'get schema(): ControlSchemaMsg { return this.schemaValue }')
      :source.replace('this.contacts() !== 0','false')}: {}});
  const {TouchSurfaceController,TouchSurfaceCandidate}=env.load('entry/src/main/ets/components/TouchSurfaceController.ets');
  const controller=new TouchSurfaceController((candidate,token)=>{
    presentations.push({candidate,token});onPresent(candidate,token);
  },()=>contacts,m=>warnings.push(m));
  const candidate=(name,projected)=>{
    const runtime=projected??new geometry.RuntimeTouchLayout();
    Object.assign(runtime.context,{key:'window',valid:true,density:2,transform:0,widthPx:640,heightPx:360});
    const profile=layouts.getDefaultLayout();profile.controls=profile.controls.slice(0,1);profile.controls[0].id=name;
    return new TouchSurfaceCandidate(profile,runtime,{grabbed:false,controls:[{id:name}]});
  };
  return {env,controller,candidate,calls,presentations,warnings,state:()=>state,
    createCandidate:(profile,runtime,schema)=>new TouchSurfaceCandidate(profile,runtime,schema),
    contacts:n=>{contacts=n;},nativeContacts:n=>{state.nativeTouches=n;},lose:()=>{loseCommit=true;},
    reject:v=>{reject=v;},fail:v=>{failBegin=v;},stale:()=>{state={...state,status:'stale',surface:'2',fenced:true};}};
}
function frozenCandidate(borrowSchema=false) {
  const f=fixture(false,borrowSchema),profile=layouts.getDefaultLayout(),runtime=new geometry.RuntimeTouchLayout();
  Object.assign(runtime.context,{key:'freeze',valid:true,density:2,transform:0,widthPx:640,heightPx:360});
  const entry=new geometry.RuntimeTouchEntry(profile.controls[0]);entry.rectPx.x=10;entry.rectVp.x=5;
  runtime.entries=[entry];runtime.controls=[entry.item];
  const schema={grabbed:false,controls:[{id:'original',x:10,keys:[32]}]},original=structuredClone(schema);
  const candidate=f.createCandidate(profile,runtime,schema);f.contacts(1);f.controller.request(candidate);
  profile.controls[0].label='changed';runtime.context.density=7;entry.rectPx.x=900;schema.controls[0].x=800;schema.controls[0].keys[0]=65;
  candidate.profile.controls[0].label='also changed';candidate.layout.context.density=8;candidate.schema.controls[0].keys[0]=66;
  f.contacts(0);f.controller.reconcile();
  assert.deepEqual(f.calls.find(c=>c[0]==='publish')[2],original,'waiting候选不能借外部草稿/消息数组');
  const presented=f.presentations[0];assert.equal(presented.candidate.layout.context.density,2);
  assert.equal(presented.candidate.layout.entries[0].rectPx.x,10);
  assert.notEqual(presented.candidate.profile.controls[0].label,'changed');
  assert.equal(f.controller.confirm(presented.candidate.id,presented.token),true);
}
frozenCandidate();assert.throws(()=>frozenCandidate(true),/waiting候选/);
passed('waiting candidate freezes profile/context/nested message and defensive reads; borrowed-schema negative control fails');
{
  const f=fixture();f.reject(true);const broken=f.candidate('first-invalid');f.controller.request(broken);
  assert.equal(f.state().fenced,true);assert.equal(f.state().token,'0');assert.equal(f.controller.admits('0'),false);
  const attempts=f.calls.length;f.controller.reconcile();assert.equal(f.calls.length,attempts,'无applied坏候选不高频重试');
  f.reject(false);f.controller.request(f.candidate('corrected'));const current=f.presentations.at(-1);
  assert.ok(current);assert.equal(f.state().fenced,true);assert.equal(f.controller.confirm(current.candidate.id,current.token),true);
  assert.equal(f.controller.admits(current.token),true);
  passed('first invalid has no recoverable applied: Native fence stays closed, corrected candidate obtains a new verified publication');
}

{
  const f=fixture(),c=f.candidate('jump');f.contacts(1);f.nativeContacts(1);
  assert.equal(f.controller.request(c),false);assert.equal(f.calls.filter(c=>c[0]==='publish').length,0);
  f.nativeContacts(0);f.controller.reconcile();assert.equal(f.presentations.length,0);
  assert.equal(f.calls.filter(c=>c[0]==='attempt-publish').length,0,'ArkTS触点仍在时不得尝试Native安装');
  f.contacts(0);f.lose();f.controller.reconcile();assert.equal(f.presentations.length,0);
  assert.equal(f.controller.admits(f.state().token),false,'丢回执必须保持fence');
  f.controller.reconcile();assert.equal(f.presentations.length,1);
  assert.equal(f.calls.filter(c=>c[0]==='publish').length,1,'查询已commit不能再退休一次owner');
  const {candidate,token}=f.presentations[0];assert.equal(f.controller.confirm(candidate.id,token),true);
  assert.equal(f.controller.admits(token),true);
  passed('fence before zero contacts, ArkTS/native contacts combined, lost commit queried exactly once before UI confirmation');
}
{
  const f=fixture(true);f.contacts(1);f.nativeContacts(0);f.controller.request(f.candidate('held-panel'));
  assert.equal(f.calls.filter(c=>c[0]==='attempt-publish').length,1,'负向变异确实绕过ArkTS零触点门并调用安装');
  passed('negative control executes the removed ArkTS-contact gate and exposes the forbidden install attempt');
}
{
  const f=fixture(),first=f.candidate('first');f.controller.request(first);
  const a=f.presentations[0];f.controller.confirm(a.candidate.id,a.token);
  f.reject(true);const invalid=f.candidate('invalid');assert.equal(f.controller.request(invalid),false);
  assert.equal(f.controller.admits(a.token),true,'明确未commit拒绝保留旧UI资格');
  const count=f.calls.length;f.controller.reconcile();assert.equal(f.calls.length,count,'invalid内容不得高频重试');
  f.reject(false);const newer=f.candidate('newer');f.controller.request(newer);const b=f.presentations.at(-1);
  assert.equal(f.controller.confirm(a.candidate.id,a.token),false,'旧didLayout不能确认新候选');
  f.controller.confirm(b.candidate.id,b.token);assert.equal(f.controller.admits(b.token),true);
  f.stale();f.controller.reconcile();f.controller.reconcile();const restored=f.presentations.at(-1);
  assert.notEqual(restored.token,b.token);assert.equal(f.controller.confirm(b.candidate.id,b.token),false);
  assert.equal(f.controller.confirm(restored.candidate.id,restored.token),true);
  passed('invalid retains applied, bad candidate stops retry, stale lifecycle rebinds and late UI confirmation cannot unlock');
}

{
  const callbacks=[], events=[];let failHaptic=false;
  const current={version:1,fenced:false,modalCount:0,schemaGeneration:'9007199254740995',session:'9007199254740997',grabEpoch:'9007199254740999'};
  const napi={onButtonPressed:callback=>{callbacks.push(['button',callback]);return true;},
    onHaptic:callback=>{callbacks.push(['haptic',callback]);if(failHaptic){failHaptic=false;return false;}return true;},
    touchPublicationState:()=>current};
  const env=environment({imports:{'libentry.so':{default:napi}}});
  const broker=env.load('entry/src/main/ets/components/EntryControlFeedbackBroker.ets');
  const a=broker.acquireEntryControlFeedback((id,down)=>events.push(['A',id,down]),strength=>events.push(['A',strength]));
  const old=callbacks.slice();const b=broker.acquireEntryControlFeedback((id,down)=>events.push(['B',id,down]),strength=>events.push(['B',strength]));
  const metadata={version:1,registration:'1',controlId:'jump',schemaGeneration:current.schemaGeneration,session:current.session,
    grabEpoch:current.grabEpoch,generatedNs:'100'};
  old[0][1]('jump',true);old[1][1](8,metadata);assert.deepEqual(events,[],'旧TSFN闭包不能读latest global client');
  const active=callbacks.slice(-2);active[0][1]('jump',false);active[1][1](8,metadata);
  assert.deepEqual(events,[['B','jump',false],['B',8]]);assert.equal(broker.releaseEntryControlFeedback(a),false);
  current.session='next';active[1][1](8,metadata);assert.equal(events.length,2,'过期session反馈丢弃且身份不丢精度');
  current.session=metadata.session;current.grabEpoch='9007199254741001';active[1][1](8,metadata);
  assert.equal(events.length,2,'game→menu→game即使schema/session不变也不能补旧场景触觉');
  failHaptic=true;assert.equal(broker.acquireEntryControlFeedback(()=>{},()=>{}),undefined);
  const restored=callbacks.slice(-2);restored[0][1]('jump',true);assert.equal(events.at(-1)[0],'B');
  assert.equal(broker.releaseEntryControlFeedback(b),true);restored[0][1]('jump',false);assert.equal(events.length,3);
  passed('feedback closures bind registration lease; old drains, precise identities, failed replacement and late release isolated');
}

{
  let serial=0,reject=false,loseReply=false;const active=new Set(),issued=new Set();
  const napi={acquireTouchModal:()=>{const t=String(++serial);active.add(t);return t;},
    releaseTouchModal:token=>{
      if(reject)return false;
      if(!issued.has(token)&&!active.has(token))return false;
      issued.add(token);active.delete(token);
      if(loseReply){loseReply=false;throw Error('release reply lost after Native commit');}
      return true;
    }};
  const env=environment({imports:{'libentry.so':{default:napi}}});
  const broker=env.load('entry/src/main/ets/components/EntryTouchModalBroker.ets');
  const editor=broker.acquireEntryTouchModal('editor'),ime=broker.acquireEntryTouchModal('ime');
  broker.releaseEntryTouchModal(editor);assert.equal(active.has(ime.token),true);
  reject=true;assert.equal(broker.releaseEntryTouchModal(ime),false);assert.equal(broker.hasEntryTouchModal(),true);
  reject=false;broker.reconcileEntryTouchModals();assert.equal(active.size,0);assert.equal(broker.hasEntryTouchModal(),false);
  const current=broker.acquireEntryTouchModal('new-page');broker.releaseEntryTouchModal(editor);assert.equal(active.has(current.token),true);
  loseReply=true;assert.equal(broker.releaseEntryTouchModal(current),false);assert.equal(active.size,0);
  assert.equal(broker.hasEntryTouchModal(),true,'丢释放回执的UI租约先保pending');
  broker.reconcileEntryTouchModals();assert.equal(broker.hasEntryTouchModal(),false,'Native已退休token幂等回执收口pending');
  passed('modal leases nest independently; rejected close retries and late old page cannot release current modal');
}

/** 提取真正的UI确认/几何失效方法，只桩SDK节点查询和Native租约边界。 */
function productionMethods(relative,ownerName,names,dependencies={}) {
  const file=path.resolve(import.meta.dirname,'../'+relative);
  const source=fs.readFileSync(file,'utf8'),ast=compiler.createSourceFile(file,source,compiler.ScriptTarget.Latest,true);
  const owner=ast.statements.find(node=>node.name?.getText(ast)===ownerName);assert.ok(owner,ownerName);
  const members=names.map(name=>{const member=owner.members.find(m=>m.name?.getText(ast)===name);assert.ok(member,name);
    // Builder装饰声明属于SDK边缘；函数体逐字执行，不在Node内伪造ArkUI节点/响应链。
    return member.getText(ast).replace(/@Builder\s*/g,'');});
  const compiled=compiler.transpileModule('class Subject{'+members.join('\n')+'}\nmodule.exports=Subject;',
    {compilerOptions:{target:compiler.ScriptTarget.ES2020,module:compiler.ModuleKind.CommonJS},reportDiagnostics:true});
  assert.equal((compiled.diagnostics??[]).filter(d=>d.category===compiler.DiagnosticCategory.Error).length,0);
  const module={exports:{}};new Function('module',...Object.keys(dependencies),compiled.outputText)(module,...Object.values(dependencies));
  return new module.exports();
}
/** 原组件提取入口保持不变；Session与GameControls使用同一可编译的逐字方法装载器。 */
function controlsMethods(names,dependencies={}) {
  const helpers=['touchControlGroupIndex_','touchControlGroupEpoch_','touchGroupVisible_',
    'confirmTouchGroupLayout_','displayedGroupControls_'];
  if(names.includes('ControlView'))helpers.push('ControlContent');
  const groupCompiler=makePureEtsLoader({'gamecontrol':layouts})('entry/src/main/ets/components/TouchGroupSchemaCompiler.ets');
  return productionMethods('entry/src/main/ets/components/GameControls.ets','GameControls',[...new Set([...names,...helpers])],
    {Visibility:{Visible:0,Hidden:1},...groupCompiler,...dependencies});
}
/** 本组只创建真实绑定完成scope，不启用来源时钟或gyro；options原文作为受控文件读取结果。 */
function bindingSession(f) {
  const pure=makePureEtsLoader({commons:{AppLogger:{warn(){}}}});
  const game=Object.assign({},layouts,...['TouchPreferences','TouchActionBindings','InputConfiguration']
    .map(name=>pure('gamecontrol/src/main/ets/'+name+'.ets')));
  const maintenance=f.env.load('entry/src/main/ets/components/EntryTouchInputMaintenance.ets');
  const originLease=maintenance.startEntryTouchInputMaintenance();
  const session=productionMethods('entry/src/main/ets/components/EntryTouchSession.ets','EntryTouchSession',
    ['schemaOptions','adoptConfirmedTouchBindings','actionKeys','setRuntimeContext','setGuiViewport','setTouchAdmission','hasCurrentSource'],
    {...game,isEntryTouchInputMaintenanceCurrent:maintenance.isEntryTouchInputMaintenanceCurrent});
  Object.assign(session,{bindings:new game.TouchBindingSnapshot(),follow:true,bindingOptionsText:'key_key.forward:key.keyboard.r',
    bindingActivation:'',originLease,sourceLease:originLease,touchAdmitted:true});
  return {session,stop:()=>maintenance.stopEntryTouchInputMaintenance(originLease)};
}

/** 运行实际Schema生成和实际顶层ForEach/ControlView/Drawer Builder，系统节点只记录调用与回调。
 * 同一投影必须同时成为Native前缀、UI后层和摇杆视觉下标；不能只检查新纯排序helper的输出。
 */
function controlDomainLayers(removePolicy=false,childTrigger=0) {
  const relative='gamecontrol/src/main/ets/RuntimeTouchLayout.ets';
  const original=fs.readFileSync(path.resolve(import.meta.dirname,'../'+relative),'utf8').replace(/\r\n/g,'\n');
  const anchor='layout.entries = layout.entries.filter((entry: RuntimeTouchEntry): boolean => entry.handledBy === 0)\n    .concat(layout.entries.filter((entry: RuntimeTouchEntry): boolean => entry.handledBy === 1))';
  assert.equal(original.split(anchor).length-1,1,'共同分层生产锚点唯一');
  const model=makePureEtsLoader({},removePolicy?{[relative]:original.replace(anchor,'/* withdrawn display-domain sorting */')}:{ })(relative);
  const profile=layouts.getDefaultLayout();profile.globalScale=1;
  const base=profile.controls.find(item=>item.type===layouts.ControlType.BUTTON&&!item.systemAction);
  const item=(id,type=layouts.ControlType.BUTTON)=>({...layouts.cloneItem(base),id,label:id,type,keys:[65],keyOrMouse:65,
    xPct:.3,yPct:.3,baseWidth:50,baseHeight:50,itemScale:1,alignGroup:layouts.AlignGroup.NONE,alignIndex:0,grabbedOnly:false});
  const drawer=item('drawer',layouts.ControlType.DRAWER);drawer.children=[item('child')];drawer.children[0].trigger=['press','toggle','doubleTap','longPress'][childTrigger];
  const native=item('native'),joystick=item('joystick',layouts.ControlType.JOYSTICK),ui=item('ui');ui.systemAction='edit';
  profile.controls=[drawer,native,ui,joystick];profile.profileId='domain-layers';profile.profileRevision=1;
  // 用实际投影求出展开孩子的位置，再让系统入口覆盖同一矩形，重现旧内联绘制的无响应区。
  const overlapContext=new model.RuntimeTouchContext();Object.assign(overlapContext,{valid:true,widthPx:600,heightPx:400,density:1,key:'overlap'});
  const childRect=model.projectRuntimeTouchLayout(profile,overlapContext,new gui.GameGuiState(),true,0,new Map([['drawer',true]])).find('child').rectVp;
  ui.xPct=childRect.x/600;ui.yPct=childRect.y/400;
  const saved=JSON.stringify(profile);
  const surface=new surfaces.InputSurfaceContext();Object.assign(surface,{widthPx:600,heightPx:400,density:1,transform:0,
    generation:1,provisional:false,validFields:surfaces.INPUT_SURFACE_FIELD_DENSITY|surfaces.INPUT_SURFACE_FIELD_RECT});
  const trace=[],clicks=[];let submitted,chain,view;
  // 安装后用原GameControls呈现接点更新UI候选；request不假Applied，后续仍须原didLayout确认。
  const f=fixture(false,false,(candidate,token)=>view.presentTouchCandidate_(candidate,token));
  const binding=bindingSession(f);
  // 本组Native资源边缘与实际surface样本使用同一density；不能撤Controller的ResourceChanged核验。
  f.state().density=surface.density;f.state().grabbed=true;
  chain=new Proxy({}, {get:(_target,name)=>(...args)=>{if(name==='id')trace.push(args[0]);if(name==='onClick')clicks.push(args[0]);return chain;}});
  view=controlsMethods(['sendControlSchema','triggerCode','displayedControls','currentTouchItem_','drawerTouchIds_','isControlVisible',
    'ControlView','DrawerView','DrawerChild','ButtonView','drawerChildX','drawerChildY','itemX','itemY','itemW','itemH',
    'touchNodeId_','touchMarkerId_','usesNativeJoystick','admitTouchAction_','presentTouchCandidate_','confirmTouchLayout_'],{...layouts,...model,
    runtimeTouchContext:geometry.runtimeTouchContext,layoutCapabilityIssue:load('gamecontrol/src/main/ets/LayoutCandidate.ets').layoutCapabilityIssue,
    getInputSurfaceContextStore:()=>({snapshot:()=>surface}),DEFAULT_JOYSTICK_DEAD_ZONE:.18,
    TouchSurfaceCandidate:function(p,l,s){return f.createCandidate(p,l,s);},
    Text:()=>chain,ButtonItemView:args=>trace.push(args.nodeId),ForEach:(items,callback)=>items.forEach(callback),
    FontWeight:{Medium:1},TextAlign:{Center:1},HitTestMode:{Block:1},AccessibilityRoleType:{BUTTON:1},$r:value=>value,
    hasEntryTouchModal:()=>false,releaseEntryTouchModal:()=>true,
    testNapi:{isTouchPublicationCurrent:token=>!f.state().fenced&&token===f.state().token}});
  Object.assign(view,{desiredProfile:profile,profile,compWidth:600,compHeight:400,isGrabbed:true,globalVisMode:0,
    drawerOpen:new Map([['drawer',true]]),guiState:new gui.GameGuiState(),guiHint:false,appearanceGeneration:1,
    mounted:true,pageActive:true,editing:false,imeOpen:false,fieldImeOpen:false,layoutObserverRegistered:true,
    profileVer:0,uiPublicationToken:'',presentedCandidateId:'',realGameVersion:'1.21.11',unresolvedSurfaceModal:undefined,
    syncMouseBounds(){},syncGuideBounds(){},touchSession:binding.session,touchSurface:f.controller,
    getBtnVis:()=>({}),btnFontSize:()=>12,btnBorderRadius:()=>0,systemButtonLabel:control=>control.label,
    JoystickView:args=>trace.push(view.touchNodeId_(args.item.id)),cOwnsJoystick:()=>true,btnPressedVer:0});
  view.getUIContext=()=>({vp2px:value=>value,getComponentUtils:()=>({getRectangleById:id=>{
    if(id===view.touchMarkerId_())return {size:{width:1,height:1}};
    const entry=view.runtimeLayout.entries.find(item=>view.touchNodeId_(item.item.id)===id);assert.ok(entry,id);
    return {size:{width:entry.rectPx.width,height:entry.rectPx.height},localOffset:{x:entry.rectPx.x,y:entry.rectPx.y}};
  }})});
  assert.equal(view.sendControlSchema(),false,'Native安装完成仍等待原UI确认');
  submitted=f.presentations.at(-1).candidate;assert.ok(submitted);
  assert.equal(binding.session.bindingActivation,'','分层候选构值不能提前采用动作绑定');
  // 顶层迭代仍取实际build里的调用，不自写“先Native再UI”的测试循环。
  const file=path.resolve(import.meta.dirname,'../entry/src/main/ets/components/GameControls.ets');
  const source=fs.readFileSync(file,'utf8'),ast=compiler.createSourceFile(file,source,compiler.ScriptTarget.Latest,true);
  const owner=ast.statements.find(node=>node.name?.getText(ast)==='GameControls');let loop;
  function visit(node){if(compiler.isCallExpression(node)&&node.expression.getText(ast)==='ForEach'&&
    node.arguments[0]?.getText(ast)==='this.displayedGroupControls_()')loop=node.getText(ast);compiler.forEachChild(node,visit);}
  visit(owner.members.find(member=>member.name?.getText(ast)==='build'));assert.ok(loop);
  const compiled=compiler.transpileModule('module.exports=function(){'+loop+';};',
    {compilerOptions:{target:compiler.ScriptTarget.ES2020,module:compiler.ModuleKind.CommonJS}}).outputText;
  const module={exports:{}};new Function('module','ForEach',compiled)(module,(items,callback)=>items.forEach(callback));module.exports.call(view);
  const rendered=trace.map(id=>id.split(':').at(-1));
  assert.deepEqual(rendered,['native','joystick','child','drawer','ui'],'实际Builder的UI根及全部孩子必须在Native后层');
  assert.deepEqual(submitted.schema.controls.map(control=>control.id),['native','joystick','child','drawer','ui']);
  assert.deepEqual(submitted.schema.controls.map(control=>control.handledBy),[0,0,0,1,1]);
  assert.equal(submitted.schema.controls.find(control=>control.id==='child').trigger,childTrigger);
  assert.deepEqual(submitted.layout.find('child').rectPx,submitted.layout.find('ui').rectPx,'孩子与系统按钮使用真实重叠热区');
  assert.equal(JSON.stringify(profile),saved,'运行时分层不能修改存档顺序/几何/绑定');
  view.touchVisual={joystickIndex:submitted.schema.controls.findIndex(control=>control.id==='joystick')};
  assert.equal(view.usesNativeJoystick(view.currentTouchItem_('joystick')),true,'Schema/顶层显示共同Native前缀下标');
  // 真实Drawer click捕获原Builder参数；新publication不能让旧回调改为当前意图。
  const first=f.presentations.at(-1),completedPublication=f.controller.status();
  let toggles=0;Object.assign(view,{isPointerDeviceSourced:()=>false,toggleDrawer:()=>toggles++});
  const oldClick=clicks[0];oldClick({});assert.equal(toggles,0,'真实UI候选未确认时Drawer仍受fence');
  view.confirmTouchLayout_();assert.equal(f.controller.admits(first.token),true);
  assert.equal(binding.session.actionKeys()[0],82,'DOMAIN_UI_CONFIRM_ADOPTS_ORIGINAL_BINDING');
  assert.deepEqual(JSON.parse(binding.session.bindingActivation),
    ['domain-layers',1,completedPublication.operationId,completedPublication.desiredCandidateId,first.token]);
  oldClick({});assert.equal(toggles,1,'原候选真实确认后才允许其Drawer意图');
  const laterProfile=submitted.profile;laterProfile.controls[0].label='later presentation';
  f.controller.request(f.createCandidate(laterProfile,submitted.layout,submitted.schema));
  const next=f.presentations.at(-1);oldClick({});assert.equal(toggles,1,'后来候选fence不复活旧Drawer回调');
  view.confirmTouchLayout_();assert.equal(f.controller.admits(next.token),true);
  oldClick({});assert.equal(toggles,1,'原捕获Drawer callback拒绝后来表');
  trace.length=0;clicks.length=0;module.exports.call(view);clicks[0]({});assert.equal(toggles,2);
  binding.stop();
}
for(let trigger=0;trigger<4;trigger++)controlDomainLayers(false,trigger);assert.throws(()=>controlDomainLayers(true),/实际Builder的UI根/);
passed('actual Schema/ControlView/Drawer hierarchy: UI domain after Native, shared joystick prefix, unchanged storage and stale Drawer intent; removed layering rejected');
/** UI语法保留在生产文件，宿主只取真正onClick箭头函数，不能用复制的意图实现冒充回归。 */
function guiIntentCallbacks(subject,args,relative='GameControls.ets',ownerName='GameControls',builderName='GuiSizeHint') {
  const file=path.resolve(import.meta.dirname,'../entry/src/main/ets/components/'+relative);
  const source=fs.readFileSync(file,'utf8'),ast=compiler.createSourceFile(file,source,compiler.ScriptTarget.Latest,true);
  const owner=ast.statements.find(node=>node.name?.getText(ast)===ownerName);
  const builder=owner.members.find(node=>node.name?.getText(ast)===builderName),callbacks=[];
  function visit(node){
    if(compiler.isCallExpression(node)&&compiler.isPropertyAccessExpression(node.expression)&&node.expression.name.text==='onClick'
      &&compiler.isArrowFunction(node.arguments[0]))callbacks.push(node.arguments[0].getText(ast));
    compiler.forEachChild(node,visit);
  }
  visit(builder);assert.equal(callbacks.length,3);
  return callbacks.map(source=>{
    const output=compiler.transpileModule('module.exports='+source+';',{compilerOptions:{target:compiler.ScriptTarget.ES2020,module:compiler.ModuleKind.CommonJS}}).outputText;
    const module={exports:{}};new Function('module','$$',output).call(subject,module,args);return module.exports;
  });
}
{
  const f=fixture();f.controller.request(f.candidate('teacher'));const current=f.presentations[0];f.controller.confirm(current.candidate.id,current.token);
  const effects=[];
  const parent=controlsMethods(['admitTouchAction_'],{hasEntryTouchModal:()=>false,
    testNapi:{isTouchPublicationCurrent:t=>!f.state().fenced&&t===f.state().token}});
  Object.assign(parent,{mounted:true,pageActive:true,editing:false,imeOpen:false,fieldImeOpen:false,touchSurface:f.controller});
  const callbacksFor=action=>token=>{if(parent.admitTouchAction_(token))effects.push(action);};
  const child={publicationToken:'stale',onSkip:callbacksFor('skip'),onBeginScroll:callbacksFor('scroll'),onClose:callbacksFor('close')};
  const clicks=guiIntentCallbacks(child,{},'TouchLearningView.ets','TouchLearningView','build');
  for(const click of clicks)click();assert.deepEqual(effects,[]);
  child.publicationToken=current.token;for(const click of clicks)click();assert.deepEqual(effects,['skip','scroll','close']);
  f.controller.request(f.candidate('new-geometry'));effects.length=0;for(const click of clicks)click();assert.deepEqual(effects,[]);
  passed('real teaching toolbar sends its displayed token; old token and publication fence cannot advance or close a different presentation');
}
{
  const f=fixture();f.controller.request(f.candidate('first'));const first=f.presentations[0];f.controller.confirm(first.candidate.id,first.token);
  const effects=[];
  const view=controlsMethods(['admitTouchAction_','canOpenMouse_','mouseEntryVisible_','mouseEntryPresented_'],
    {...geometry,ControlType:layouts.ControlType,hasEntryTouchModal:()=>false,
    testNapi:{isTouchPublicationCurrent:t=>!f.state().fenced&&t===f.state().token}});
  Object.assign(view,{mounted:true,pageActive:true,editing:false,imeOpen:false,fieldImeOpen:false,touchSurface:f.controller,
    guiHint:true,guiState:{},isGrabbed:false,globalVisMode:0,desiredProfile:layouts.getDefaultLayout(),
    runtimeLayout:{controls:layouts.getDefaultLayout().controls,entries:layouts.getDefaultLayout().controls.map(item=>({item}))},
    drawerOpen:new Map(),uiPublicationToken:first.token,
    guiGuard:{keep:()=>effects.push('keep')},registerRegions:()=>effects.push('regions'),
    restoreGui:()=>effects.push('restore'),openMouse:()=>effects.push('mouse')});
  const args={token:first.token},callbacks=guiIntentCallbacks(view,args);
  f.controller.request(f.candidate('next'));
  for(const callback of callbacks)callback();assert.deepEqual(effects,[]);assert.equal(view.guiHint,true);
  const next=f.presentations.at(-1);f.controller.confirm(next.candidate.id,next.token);
  for(const callback of callbacks)callback();assert.deepEqual(effects,[],'旧提示token在新表确认后仍不能调用游戏设置/鼠标');
  args.token=next.token;view.uiPublicationToken=next.token;
  callbacks[0]();assert.deepEqual(effects,['keep','regions']);assert.equal(view.guiHint,false);
  callbacks[1]();callbacks[2]();assert.deepEqual(effects,['keep','regions','restore','mouse']);
  passed('real GUI keep/restore/mouse callbacks reject fenced and stale displayed tokens and allow current publication intents');
}
{
  const f=fixture(),runtime=new geometry.RuntimeTouchLayout();
  const entry=new geometry.RuntimeTouchEntry(layouts.getDefaultLayout().controls[0]);entry.item.id='jump';
  Object.assign(entry.rectPx,{x:10,y:20,width:40,height:50});runtime.entries.push(entry);
  const candidate=f.candidate('actual',runtime);
  f.controller.request(candidate);const {token}=f.presentations[0],rectangles=new Map();
  const view=controlsMethods(['confirmTouchLayout_','touchNodeId_','touchMarkerId_'],
    {releaseEntryTouchModal:()=>true,hasEntryTouchModal:()=>false,
      layoutCapabilityIssue:load('gamecontrol/src/main/ets/LayoutCandidate.ets').layoutCapabilityIssue});
  Object.assign(view,{mounted:true,pageActive:true,layoutObserverRegistered:true,appearanceGeneration:1,
    touchSurface:f.controller,runtimeLayout:candidate.layout,uiPublicationToken:token,profile:candidate.profile,presentedCandidateId:f.presentations[0].candidate.id,
    getUIContext:()=>({getComponentUtils:()=>({getRectangleById:id=>{const value=rectangles.get(id);if(!value)throw Error('node absent');return value;}})}),
    syncMouseBounds(){},syncGuideBounds(){},touchSession:{setTouchAdmission(){}},unresolvedSurfaceModal:undefined});
  view.confirmTouchLayout_();assert.equal(f.controller.admits(token),false,'任意didLayout不含候选marker不能解封');
  rectangles.set(view.touchMarkerId_(),{size:{width:2,height:2}});
  rectangles.set(view.touchNodeId_('jump'),{size:{width:40,height:50},localOffset:{x:100,y:20}});
  view.confirmTouchLayout_();assert.equal(f.controller.admits(token),false,'实际节点不匹配px投影时保持fence');
  rectangles.get(view.touchNodeId_('jump')).localOffset.x=10;
  view.confirmTouchLayout_();assert.equal(f.controller.admits(token),true);
  passed('real didLayout confirmation requires candidate marker and measured control rectangles, arbitrary frame cannot unlock');
}
{
  const retired=[],acquired=[];
  const lease={token:'unresolved-1'};
  const view=controlsMethods(['publishUnresolvedSurfaceSchema'],{acquireEntryTouchModal:owner=>{acquired.push(owner);return lease;}});
  Object.assign(view,{appearanceGeneration:4,touchSession:{setTouchAdmission:value=>retired.push(value)},
    releaseInputForSurfaceRebuild:()=>retired.push('release'),unresolvedSurfaceModal:undefined});
  view.publishUnresolvedSurfaceSchema();view.publishUnresolvedSurfaceSchema();
  assert.equal(view.unresolvedSurfaceModal,lease);assert.deepEqual(acquired,['surface-unresolved:4']);
  assert.equal(retired.filter(v=>v==='release').length,1,'同一缺失上下文不重复退休触控owner');
  passed('zero/invalid geometry obtains its own Native touch modal and preserves it until verified recovery');
}
{
  let now=1000,attempts=0,fail=true;const callbacks=[];
  const view=controlsMethods(['ensureTouchLayoutObserver_'],{Date:{now:()=>now}});
  Object.assign(view,{mounted:true,pageActive:true,layoutObserverRegistered:false,nextLayoutObserverAttempt:0,profileVer:0,
    didTouchLayout:()=>{},getUIContext:()=>({getUIObserver:()=>({off(){},on:(_,callback)=>{attempts++;if(fail)throw Error('temporary context');callbacks.push(callback);}})})});
  view.ensureTouchLayoutObserver_();assert.equal(attempts,1);assert.equal(view.layoutObserverRegistered,false);
  view.ensureTouchLayoutObserver_();assert.equal(attempts,1,'观察注册失败不逐帧刷SDK');
  now=2000;fail=false;view.ensureTouchLayoutObserver_();assert.equal(view.layoutObserverRegistered,true);assert.equal(view.profileVer,1);
  assert.equal(callbacks[0],view.didTouchLayout);view.ensureTouchLayoutObserver_();assert.equal(attempts,2);
  passed('real observer registration failure retries on the existing active heartbeat, bounded rate and own callback preserved');
}
{
  let now=1000,attempts=0,warnings=0;const callbacks=[];
  // 本组仅隔离Native注册边缘；原Source资格来自真实maintenance scope与生产查询，不能用fake ready。
  const f=fixture(),source=bindingSession(f);
  const view=controlsMethods(['observationEnabled','touchFeedbackObservationEnabled_','ensureTouchFeedback_'],{Date:{now:()=>now},GAME_CONTROLS_TAG:'test',hapticTap(){},
    hilog:{warn:()=>warnings++},acquireEntryControlFeedback:(...handlers)=>{attempts++;callbacks.push(handlers);return attempts===1?undefined:{id:attempts};}});
  Object.assign(view,{mounted:true,pageActive:true,schemaActive:true,feedbackLease:undefined,nextFeedbackAttempt:0,
    feedbackRegistrationWarned:false,appearanceGeneration:7,editing:false,imeOpen:false,fieldImeOpen:false,
    runtimeLayout:{find:()=>({})},touchSession:source.session,
    getBtnVis:()=>assert.fail('late appearance callback must be rejected'),btnPressedVer:0});
  const initialized=view.observationEnabled;assert.equal(initialized,true,'观察字段初值必须来自生产property');
  view.observationEnabled=undefined;view.ensureTouchFeedback_();assert.equal(attempts,0,'未初始化观察状态不得注册');
  view.observationEnabled=initialized;
  view.ensureTouchFeedback_();view.ensureTouchFeedback_();assert.equal(attempts,1);assert.equal(warnings,1);
  now=2000;view.ensureTouchFeedback_();assert.ok(view.feedbackLease);assert.equal(attempts,2);
  view.appearanceGeneration++;callbacks[1][0]('jump',true);assert.equal(view.btnPressedVer,0);
  source.stop();view.feedbackLease=undefined;now=3000;view.ensureTouchFeedback_();
  assert.equal(attempts,2,'原维护scope退休后mounted组件也不能重新登记反馈');
  passed('real feedback registration failure retries without log flooding; recovered callback keeps appearance lease');
}
/** 只替代 Native 回执/SDK测量边界，执行真实必要通知、镜像更新、节点确认与恢复方法。 */
{
  let listener,reads=0,confirms=0,failConfirm=true,markerReady=false,wrongRect=false;
  let state={token:'g-token',revision:'2',enabled:true,pending:true,mask:[true,false],epochs:['1','2']};
  const napi={readTouchGroups:token=>{assert.equal(token,state.token);reads++;return structuredClone(state);},
    onTouchGroupsChanged:callback=>{listener=callback;return '9';},
    confirmTouchGroups:(token,revision)=>{confirms++;assert.equal(token,state.token);assert.equal(revision,state.revision);
      if(failConfirm)return false;state.pending=false;return true;},
    isTouchPublicationCurrent:token=>token===state.token,
    isTouchGroupControlCurrent:(token,id,epoch)=>token===state.token&&id==='base'&&epoch==='1'};
  const view=controlsMethods(['syncTouchGroups_','ensureTouchGroupListener_','touchGroupMarkerId_',
    'touchMarkerId_','touchNodeId_','admitTouchAction_','admitTouchUi_'],{testNapi:napi,hasEntryTouchModal:()=>false,
    TouchType:{Down:0,Move:1,Up:2,Cancel:3}});
  const entry=new geometry.RuntimeTouchEntry({...layouts.getDefaultLayout().controls[0],id:'base'});
  Object.assign(entry.rectPx,{x:10,y:20,width:30,height:40});
  const runtime=new geometry.RuntimeTouchLayout();runtime.entries=[entry];
  Object.assign(view,{mounted:true,pageActive:true,appearanceGeneration:1,uiPublicationToken:state.token,
    groupSchema:{groups:[{id:'base'},{id:'tools'}]},groupIndices:new Map([['base',0]]),
    groupRegistration:'',nextGroupListenerAttempt:0,touchSession:{hasCurrentSource:()=>true},groupMask:[],groupEpochs:[],groupToken:'',groupRevision:'',groupPending:false,
    groupPresentedRevision:'',runtimeLayout:runtime,observationEnabled:false,editing:false,imeOpen:false,fieldImeOpen:false,
    blockedUiFingers:new Set(),groupBlockedUiFingers:new Set(),touchSurface:{admits:token=>token===state.token},releaseControlInputs(){},retireHiddenMouse_(){},
    isPointerSourcedTouch:()=>false,
    getUIContext:()=>({getComponentUtils:()=>({getRectangleById:id=>{
      if(id===view.touchGroupMarkerId_()){if(!markerReady)throw Error('not laid out');return{size:{width:1,height:1}};}
      return{size:{width:wrongRect?31.5:30,height:40},localOffset:{x:10,y:20}};
    }})})});
  view.syncTouchGroups_();assert.equal(reads,1);assert.ok(listener,'必要组通道不能随可选视觉观察关闭');
  assert.deepEqual(view.groupMask,[true,false]);assert.equal(confirms,0);
  view.confirmTouchGroupLayout_();assert.equal(confirms,0,'没有当前修订marker不能确认');
  markerReady=true;wrongRect=true;view.confirmTouchGroupLayout_();assert.equal(confirms,0,'真实矩形不符不能确认');
  wrongRect=false;view.confirmTouchGroupLayout_();assert.equal(confirms,1);assert.equal(view.groupPresentedRevision,'2');
  failConfirm=false;view.syncTouchGroups_('2');assert.equal(confirms,2);assert.equal(view.groupPending,false,'原维护重试已实际呈现的原ACK');
  const up={type:2,changedTouches:[{id:7}]};
  assert.equal(view.admitTouchUi_({type:0,changedTouches:[{id:7}]},state.token,'base','old'),false);
  assert.equal(view.admitTouchUi_({type:1,changedTouches:[{id:7}]},state.token,'base','1'),false);
  assert.equal(view.admitTouchUi_({type:0,changedTouches:[{id:7}]},state.token,'base','1'),true,'真实新DOWN结束隐藏节点遗留的旧隔离墓碑');
  assert.equal(view.admitTouchUi_({type:0,changedTouches:[{id:7}]},state.token,'base','old'),false);
  assert.equal(view.admitTouchUi_(up,state.token,'base','1'),false);assert.equal(view.blockedUiFingers.size,0);
  const before=reads;view.appearanceGeneration++;listener();assert.equal(reads,before,'旧appearance的必要通知也不能借后来前端');
  passed('actual group mirror/presentation: optional observations off, real marker/rect, failed ACK recovery, stale group eligibility and old callback isolation');
}
{
  const calls=[],issues=[];
  const napi={invokeTouchGroupControl:(...args)=>{calls.push(args);if(calls.length===1)throw Error('reply lost after commit');
    return {status:'committed',revision:'12'};}};
  const view=controlsMethods(['dispatchGroupIntent_','reconcileGroupIntents_'],{testNapi:napi});
  const intent={token:'original-schema',control:'switch',eligibility:'3',producer:'7',sequence:'10',phase:0};
  Object.assign(view,{pendingGroupCommands:new Map([['10',intent]]),uiPublicationToken:'original-schema',groupRegistration:'7',
    reportGroupIssue_:message=>issues.push(message)});
  view.dispatchGroupIntent_(intent);assert.equal(view.pendingGroupCommands.size,1);
  view.reconcileGroupIntents_();assert.equal(view.pendingGroupCommands.size,0);assert.deepEqual(calls[0],calls[1]);
  view.pendingGroupCommands.set('11',{...intent,sequence:'11'});view.uiPublicationToken='new-schema';
  view.reconcileGroupIntents_();assert.equal(calls.length,2);assert.equal(view.pendingGroupCommands.size,0);
  passed('actual UI group command recovery retains original payload/id; replaced schema never receives the old retry');
}
{
  const calls=[],issues=[];let answer,mirrors=0;
  const view=controlsMethods(['reconcileGroupRestore_'],{testNapi:{restoreTouchGroups:(...args)=>{calls.push(args);return answer;}}});
  Object.assign(view,{groupRestoreRequested:true,editing:false,groupRegistration:'7',uiPublicationToken:'schema-a',
    groupRestoreSequence:'',groupRestoreToken:'',groupCommandSequence:10,touchSurface:{admits:token=>token==='schema-a'},
    reportGroupIssue_:message=>issues.push(message),syncTouchGroups_:()=>mirrors++});
  view.reconcileGroupRestore_();assert.equal(view.groupRestoreRequested,true);assert.equal(view.groupRestoreSequence,'11');
  answer={status:'committed',revision:'5'};view.reconcileGroupRestore_();
  assert.deepEqual(calls[0],calls[1]);assert.equal(view.groupRestoreRequested,false);assert.equal(mirrors,1);
  view.groupRestoreRequested=true;answer={status:'expired',revision:'6'};view.reconcileGroupRestore_();
  assert.equal(view.groupRestoreRequested,false);assert.equal(issues.length,1);
  view.reconcileGroupRestore_();assert.equal(calls.length,3,'过期恢复终结后不能沿维护永久重试');
  view.groupRestoreRequested=true;view.groupRestoreSequence='13';view.groupRestoreToken='old-schema';
  view.reconcileGroupRestore_();assert.equal(calls.length,3);assert.equal(view.groupRestoreRequested,false);
  passed('real restore-to-initial intent preserves unknown identity and terminates expired/stale requests without heartbeat replay');
}
/** 取真实EditorOverlay给LayoutEditor的恢复回调，避免手写requested=true漏掉新意图身份重置。 */
function realRestoreCallback(withdrawReset=false) {
  const source=fs.readFileSync(path.resolve(import.meta.dirname,'../entry/src/main/ets/components/GameControls.ets'),'utf8');
  const tree=compiler.createSourceFile('GameControls.ets',source,compiler.ScriptTarget.Latest,true),calls=[];
  function visit(node) {
    if(compiler.isCallExpression(node)&&node.expression.getText(tree)==='LayoutEditor')calls.push(node);
    compiler.forEachChild(node,visit);
  }
  visit(tree);assert.equal(calls.length,1,'真实布局编辑器调用必须唯一');
  const property=calls[0].arguments[0].properties.find(item=>item.name?.getText(tree)==='onRestoreGroups');
  assert.ok(property&&compiler.isPropertyAssignment(property));
  let callback=property.initializer.getText(tree);
  if(withdrawReset) {
    const before=callback;callback=callback.replace(/this\.groupRestoreSequence\s*=\s*''\s*;?/,'');
    assert.notEqual(callback,before,'负控必须真实删除新请求序号重置');
  }
  const compiled=compiler.transpileModule('module.exports=function(){const callback='+callback+';callback();};',
    {compilerOptions:{target:compiler.ScriptTarget.ES2020},reportDiagnostics:true});
  assert.equal((compiled.diagnostics??[]).filter(item=>item.category===compiler.DiagnosticCategory.Error).length,0);
  const module={exports:{}};new Function('module',compiled.outputText)(module);return module.exports;
}

/** 自动恢复继续使用旧身份；重新进入编辑后显式恢复必须建立新身份，不能被旧publication过期吞掉。 */
function explicitRestoreAfterUnknown(failure,withdrawReset=false) {
  const calls=[],issues=[];let committed=false,mirrors=0;
  const callback=realRestoreCallback(withdrawReset);
  const view=controlsMethods(['reconcileGroupRestore_'],{testNapi:{restoreTouchGroups:(...args)=>{
    calls.push(args);if(committed)return {status:'committed',revision:'8'};
    if(failure==='throw')throw Error('reply lost');return undefined;
  }}});
  Object.assign(view,{groupRestoreRequested:false,editing:false,groupRegistration:'7',uiPublicationToken:'schema-a',
    groupRestoreSequence:'',groupRestoreToken:'',groupCommandSequence:10,touchSurface:{admits:()=>true},
    reportGroupIssue_:message=>issues.push(message),syncTouchGroups_:()=>mirrors++});
  callback.call(view);view.reconcileGroupRestore_();view.reconcileGroupRestore_();
  assert.deepEqual(calls,[['schema-a','7','11'],['schema-a','7','11']],'未知回执的维护重试必须沿用原身份');
  view.editing=true;view.uiPublicationToken='schema-b';callback.call(view);
  view.reconcileGroupRestore_();assert.equal(calls.length,2,'编辑期间的新请求只排队，不立即派发');
  view.editing=false;committed=true;view.reconcileGroupRestore_();
  assert.deepEqual(calls.at(-1),['schema-b','7','12'],'新显式恢复必须使用新publication和新序号');
  assert.equal(view.groupRestoreRequested,false);assert.equal(mirrors,1);assert.deepEqual(issues,[]);
}
for(const failure of ['undefined','throw']) {
  explicitRestoreAfterUnknown(failure);
  passed('real editor restore callback after '+failure+': maintenance identity preserved, new intent gets fresh identity');
}
assert.throws(()=>explicitRestoreAfterUnknown('undefined',true),error=>error.code==='ERR_ASSERTION'&&error.message.includes('新显式恢复'));
passed('restore callback withdrawal: stale pending identity must not swallow a later explicit user request');
console.log(`touch surface regressions: ${groups} groups passed`);
