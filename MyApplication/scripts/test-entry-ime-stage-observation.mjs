/**
 * 真实Entry运行体与GameControls输入动作的有界诊断回归。
 * 本测试复用原fixture的外部IMF/Native边缘，并从生产AST提取现役动作方法；
 * 比较OFF/ON/日志抛错的实际业务轨迹，不以字符串出现或镜像状态机代替执行。
 * 宿主逻辑门不授ArkTS SDK、真实设备、最早OS来源或游戏采用资格。
 */
import fs from 'node:fs';
import assert from 'node:assert/strict';
import compiler from './lib/ets-compiler.mjs';
import {environment} from './lib/ets-runtime-fixture.mjs';

const RUNTIME='entry/src/main/ets/runtime/EntryTextInputRuntime.ets';
const CONTROLS='entry/src/main/ets/components/GameControls.ets';
const root=new URL('../',import.meta.url);
const read=relative=>fs.readFileSync(new URL(relative,root),'utf8').replaceAll('\r\n','\n');
const flush=async()=>{for(let i=0;i<30;i++)await Promise.resolve();};
const noop=()=>{};
/** 只控制原外部Promise时刻，不改Runtime内部状态或制造lease。 */
function deferred(){let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return {promise,resolve,reject};}
const fixtureText=read('scripts/test-entry-text-input-runtime.mjs');
const fixtureAst=compiler.createSourceFile('fixture.mjs',fixtureText,compiler.ScriptTarget.Latest,true,compiler.ScriptKind.JS);
const declaration=fixtureAst.statements.find(n=>compiler.isFunctionDeclaration(n)&&n.name?.getText(fixtureAst)==='fixture');
assert.ok(declaration,'existing real fixture must exist');
const fixture=new Function('environment','deferred','noop','RUNTIME','CHAT','HARD',
  'return ('+declaration.getText(fixtureAst)+');')(environment,deferred,noop,RUNTIME,
  'entry/src/main/ets/components/ChatInputBridge.ets','entry/src/main/ets/components/DesktopPhysicalTextInput.ets');

/** 三种诊断边缘必须保留相同attach/commit/key/cleanup调用及单controller上限。 */
async function runtimeBusiness(options){
  const f=fixture(options);f.runtime.start();const field=f.create('field');const originalBindingId=field.binding.id;await flush();
  f.callbacks.get('insertText')('中文😀');f.callbacks.get('deleteLeft')(1);
  field.aboutToDisappear();await flush();
  assert.equal(f.state.owners,0);assert.equal(f.state.maxOwners,1);
  return {calls:f.calls.map(x=>typeof x==='string'?x:{...x,context:x.context?'same-original-ui':undefined}),traces:f.traces,bindingId:originalBindingId};
}
const off=await runtimeBusiness({trace:false});
const on=await runtimeBusiness({trace:true});
const throws=await runtimeBusiness({trace:true,traceThrows:true});
assert.deepEqual(on.calls,off.calls,'diagnostics ON must preserve exact business calls');
assert.deepEqual(throws.calls,off.calls,'HiLog throw must preserve exact business calls');
assert.equal(off.traces.filter(x=>String(x[2]).startsWith('AMCL_IME_PHASE')).length,0);
const stages=on.traces.filter(x=>String(x[2]).startsWith('AMCL_IME_PHASE'));
assert.deepEqual(stages.map(x=>x[3]),['bind','request','lease','attach-call','attached']);
assert.ok(stages.every(x=>x[4]==='field'&&x[5]===on.bindingId.toString()),'existing binding identity, no new owner');
assert.ok(stages.every(x=>!x.some(v=>String(v).includes('中文'))),'phase diagnostics never contain text');
console.log('PASS runtime OFF/ON/HiLog throw preserves actual business and original binding');

/** attach拒绝有独立阶段，仍执行原cleanup；不把Phase失败记录当某个SDK错误码。 */
{
  const f=fixture({trace:true});f.state.attachError=true;f.runtime.start();f.create('field');await flush();
  assert.ok(f.traces.some(x=>x[3]==='attach-failed'));
  assert.equal(f.state.owners,0);assert.ok(f.calls.includes('detach'));
}
/** 旧attach完成只记录旧activation；现请求退休/清理后才能原新activation接上。 */
{
  const f=fixture({trace:true});f.state.delayAttach=true;f.runtime.start();const field=f.create('field');
  field.visible=false;field.onVisibleChange();field.visible=true;field.onVisibleChange();
  f.pendingAttach.shift().resolve();await flush();
  const retired=f.traces.find(x=>x[3]==='attach-resolved'&&x[7]==='OriginalRequestRetired');
  assert.ok(retired);assert.equal(retired[6],'1','old Promise cannot read currentactivation3');
  f.state.delayAttach=false;f.pendingAttach.shift().resolve();await flush();
  const attached=f.traces.find(x=>x[3]==='attached');assert.ok(attached);assert.equal(attached[6],'3');
  assert.equal(f.state.maxOwners,1);field.aboutToDisappear();await flush();assert.equal(f.state.owners,0);
}
/** 有界原请求翻转耗尽观察预算后，实际输入仍可正常attach并提交。 */
{
  const f=fixture({trace:true});f.runtime.start();const field=f.create('field');await flush();
  for(let i=0;i<40;i++){field.visible=false;field.onVisibleChange();await flush();field.visible=true;field.onVisibleChange();await flush();}
  assert.equal(f.traces.filter(x=>String(x[2]).startsWith('AMCL_IME_PHASE')).length,64);
  const before=f.calls.filter(x=>x.kind==='commit').length;f.callbacks.get('insertText')('after-budget');
  assert.equal(f.calls.filter(x=>x.kind==='commit').length,before+1);
  field.aboutToDisappear();await flush();assert.equal(f.state.owners,0);assert.equal(f.state.maxOwners,1);
}
console.log('PASS runtime rejected/late original activation/bounded64 retains actual maintenance');

/** 格式控制仅调用现役观察方法，不授任意binding输入资格；数字必须完整十进制保真。 */
{
  const f=fixture({trace:true}),binding=new f.module.EntryTextInputBinding(2**40,'field');
  f.runtime.noteImePhase('format-control',binding,2**41,'ReadOnly');
  assert.equal(f.traces[0][5],'1099511627776');assert.equal(f.traces[0][6],'2199023255552');
  assert.equal(f.calls.length,0,'format observation never acquirescontroller/Nativelease');
  const c=controls({trace:true});c.subject.noteImeRoute('format-control','field',2**40,true);
  assert.equal(c.traces[0][5],'1099511627776');assert.equal(c.calls.length,0);
}


/** GameControls只替换Native control/modal/haptic边缘；路由、dispatch和记录释放均提取生产正文。 */
function controls(options={}){
  const text=read(CONTROLS),ast=compiler.createSourceFile(CONTROLS,text,compiler.ScriptTarget.Latest,true);
  const owner=ast.statements.find(n=>n.name?.getText(ast)==='GameControls');assert.ok(owner);
  const names=['noteImeRoute','handleSystemAction','dispatchButton','releaseArktsButtonOutput','emitCheckedKeySequence','cOwnsButton'];
  const body=names.map(name=>{const n=owner.members.find(m=>m.name?.getText(ast)===name);assert.ok(n,name);return n.getText(ast);}).join('\n');
  const record=ast.statements.find(n=>n.name?.getText(ast)==='ArktsButtonOutputRecord');assert.ok(record);
  const source=record.getText(ast)+'\nclass Subject{'+body+'}\nmodule.exports=Subject;';
  const compiled=compiler.transpileModule(source,{compilerOptions:{target:compiler.ScriptTarget.ES2020,module:compiler.ModuleKind.CommonJS},reportDiagnostics:true});
  assert.equal((compiled.diagnostics??[]).filter(x=>x.category===compiler.DiagnosticCategory.Error).length,0);
  const calls=[],traces=[],module={exports:{}};
  const deps={DiagnosticPolicy:{inputTraceEnabled:()=>options.trace===true},GAME_CONTROLS_TAG:'GameControls',
    hilog:{info:(...values)=>{if(options.traceThrows)throw new Error('controlled diagnostic failure');traces.push(values);}},
    acquireEntryTouchModal:owner=>{calls.push(['modal',owner]);return options.modal===false?undefined:{owner};},
    GLFW_PRESS:1,GLFW_RELEASE:0,effectiveKeys:item=>item.keys,hapticTap:noop};
  new Function('module',...Object.keys(deps),compiled.outputText)(module,...Object.values(deps));
  const subject=new module.exports();
  Object.assign(subject,{imeRouteTraceCount:0,isGrabbed:options.grabbed===true,appearanceGeneration:17,
    arktsButtonOutputs:new Map(),profile:{haptic:false},fieldImeOpen:false,imeOpen:false,
    closeMouse:()=>calls.push(['closeMouse']),controlClient:{
      acquire:(control,keys)=>{calls.push(['acquire',control,keys.slice()]);return options.acquire===false?'':'original-token';},
      currentToken:()=> 'original-token',releaseToken:token=>{calls.push(['release',token]);return options.release!==false;}}});
  return {subject,calls,traces};
}
for(const spec of [{},{modal:false},{grabbed:true,acquire:false},{grabbed:true,modal:false},{grabbed:true},{grabbed:true,release:false}]){
  const outcomes=[];
  for(const diag of [{trace:false},{trace:true},{trace:true,traceThrows:true}]){
    const f=controls({...spec,...diag});f.subject.handleSystemAction({id:'test-ime',systemAction:'input',keys:[84]});await flush();
    outcomes.push({calls:f.calls,chat:f.subject.imeOpen,field:f.subject.fieldImeOpen,outputs:f.subject.arktsButtonOutputs.size});
    if(!diag.trace)assert.equal(f.traces.length,0);
    if(spec.grabbed&&spec.acquire===false&&diag.trace&&!diag.traceThrows){
      assert.deepEqual(f.traces.map(x=>x[3]),['request','key-acquire']);assert.equal(f.traces.at(-1)[6],0);
    }
  }
  assert.deepEqual(outcomes[1],outcomes[0]);assert.deepEqual(outcomes[2],outcomes[0]);
}
{
  const f=controls({trace:true,grabbed:true});f.subject.handleSystemAction({id:'test-ime',systemAction:'input',keys:[84]});
  f.subject.appearanceGeneration=19;f.subject.isGrabbed=false;await flush();
  const release=f.traces.find(x=>x[3]==='key-release');assert.ok(release);assert.equal(release[4],'chat');assert.equal(release[5],'17');
  const bounded=controls({trace:true});for(let i=0;i<30;i++)bounded.subject.handleSystemAction({id:'test-ime',systemAction:'input',keys:[84]});
  assert.equal(bounded.traces.length,64);assert.equal(bounded.calls.filter(x=>x[0]==='modal').length,30);
}
console.log('PASS actual controls field/chat/key rejection/modal rejection/HiLogthrow/originalrelease/bounded64');

/** Builder真实闭包也由生产AST提取；只替换未改动的准入算法边缘，核新包装只调用它一次。 */
{
  const text=read(CONTROLS),ast=compiler.createSourceFile(CONTROLS,text,compiler.ScriptTarget.Latest,true);
  const owner=ast.statements.find(n=>n.name?.getText(ast)==='GameControls');
  const builder=owner.members.find(n=>n.name?.getText(ast)==='ButtonView');assert.ok(builder);
  const arrows=new Map();
  function visit(node){
    if(compiler.isPropertyAssignment(node)&&['onTouchEvent','onAccessibilityActivate'].includes(node.name?.getText(ast))){
      assert.ok(compiler.isArrowFunction(node.initializer));arrows.set(node.name.getText(ast),node.initializer.getText(ast));
    }
    compiler.forEachChild(node,visit);
  }
  visit(builder);assert.equal(arrows.size,2);
  for(const [name,code]of arrows){
    for(const admitted of [false,true])for(const traceThrows of [false,true]){
      const f=controls({trace:true,traceThrows}),item={id:'test-ime',systemAction:'input'};
      let checks=0,delivered=0;
      f.subject.admitTouchUi_=()=>{checks++;return admitted;};
      f.subject.admitTouchAction_=()=>{checks++;return admitted;};
      f.subject.handleButtonTouch=(originalItem,event)=>{assert.equal(originalItem,item);assert.equal(event.type,0);delivered++;};
      f.subject.activateButtonFromAccessibility=originalItem=>{assert.equal(originalItem,item);delivered++;};
      const compiled=compiler.transpileModule('module.exports='+code+';',
        {compilerOptions:{target:compiler.ScriptTarget.ES2020,module:compiler.ModuleKind.CommonJS},reportDiagnostics:true});
      assert.equal((compiled.diagnostics??[]).filter(x=>x.category===compiler.DiagnosticCategory.Error).length,0);
      const module={exports:{}};new Function('module','$$','TouchType',compiled.outputText)
        .call(f.subject,module,{item,token:'original-publication'},{Move:2});
      module.exports({type:0});assert.equal(checks,1);assert.equal(delivered,admitted?1:0);
      if(!traceThrows){assert.equal(f.traces.length,1);assert.equal(f.traces[0][6],admitted?1:0);}
    }
  }
}
console.log('PASS actual Builder admission callbacks once; reject/HiLogthrow preserves original dispatch');
console.log('ENTRY_IME_STAGE_OBSERVATION_PASS actualproduction methods; SDK/HAP/device not qualified');
