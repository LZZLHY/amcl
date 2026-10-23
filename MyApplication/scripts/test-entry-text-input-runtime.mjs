/** 真实Entry IME运行体/组件/Coordinator闭包；只替换IMF与Native、Host装配边界。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {fileURLToPath} from 'node:url';
import {environment} from './lib/ets-runtime-fixture.mjs';
import compiler from './lib/ets-compiler.mjs';
import {loadActionComponent} from './lib/unified-actions-fixture.mjs';

const RUNTIME='entry/src/main/ets/runtime/EntryTextInputRuntime.ets';
const CHAT='entry/src/main/ets/components/ChatInputBridge.ets';
const HARD='entry/src/main/ets/components/DesktopPhysicalTextInput.ets';
const flush=async()=>{for(let i=0;i<30;i++)await Promise.resolve();};
const noop=()=>{};

/** 只控制真正外部Promise的完成时刻，运行体的flags/lease/state不由夹具伪写。 */
function deferred(){let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return {promise,resolve,reject};}

/** 原组件全部非UI方法与真实runtime、Entry sink/epoch/Coordinator同环境执行。 */
function fixture(options={}){
  const state={epoch:'1',nativeGeneration:0,begins:0,beginOk:true,controllerGets:0,owners:0,maxOwners:0,
    attachError:false,detachError:false,registrationError:false,delayAttach:false,delayDetach:false,route:'typed',modalTokens:new Set(),
    commitOk:()=>true,keyOk:true};
  // 每个组件只给一份原UIContext，保身份比较；这里只记录外部IMF调用，不写Runtime内部资格。
  // 诊断边缘显式可开/关/抛错；观察数组不参加原controller/Native资格。
  const traces=[];
  const calls=[],warnings=[],callbacks=new Map(),contexts=new Map(),pendingAttach=[],pendingDetach=[];
  const controller={
    on(event,callback){calls.push('on:'+event);if(state.registrationError&&event==='insertText')throw new Error('on failed');callbacks.set(event,callback);},
    off(event,callback){calls.push('off:'+event);if(callbacks.get(event)===callback)callbacks.delete(event);},
    attach(show,config){return attach(show,config);},
    // 两种公开API分列；内部Promise完成仍共用原边缘，不能把context调用记录成legacy或固定false。
    attachWithUIContext(context,config,opts){calls.push({kind:'context',context,config,opts});return attach(opts.showKeyboard,config,'context');},
    showTextInput(){calls.push('show');return Promise.resolve();},hideTextInput(){calls.push('hide');return Promise.resolve();},
    detach(){calls.push('detach');if(state.detachError)return Promise.reject(new Error('detach rejected'));
      if(state.delayDetach){const d=deferred();pendingDetach.push(d);return d.promise.then(()=>{state.owners--;});}
      state.owners=Math.max(0,state.owners-1);return Promise.resolve();}
  };
  function attach(show,config,route='legacy'){calls.push({kind:'attach',show,config,route});if(state.attachError)return Promise.reject(new Error('attach rejected'));
    const finish=()=>{state.owners++;state.maxOwners=Math.max(state.maxOwners,state.owners);};
    if(state.delayAttach){const d=deferred();pendingAttach.push(d);return d.promise.then(finish);}
    finish();return Promise.resolve();}
  const napi={textInputSessionSupported:()=>true,getInputResetEpoch:()=>state.epoch,
    beginTextInputSession:g=>{calls.push('begin:'+g);state.begins++;if(!state.beginOk)return false;state.nativeGeneration=g;return true;},
    endTextInputSession:g=>{calls.push('end:'+g);if(g!==state.nativeGeneration)return false;state.nativeGeneration=0;return true;},
    abortTextInputSession:g=>{calls.push('abort:'+g);state.nativeGeneration=0;},
    commitTextInput:(g,text)=>{calls.push({kind:'commit',g,text});return g===state.nativeGeneration&&state.commitOk(text);},
    updateTextInputEditing:(g,text,start,length)=>{calls.push({kind:'preview',g,text,start,length});return g===state.nativeGeneration;},
    updateTextInputSelection:(g,start,length)=>{calls.push({kind:'selection',g,start,length});return g===state.nativeGeneration;},
    textInputKeyTap:(g,ohos,key)=>{calls.push({kind:'key',g,ohos,key});if(state.route==='throw')throw new TypeError('missing native key tap');
      return state.route==='boolean-false'?false:state.route==='legacy'?1:g===state.nativeGeneration&&state.keyOk?0:2;},
    acquireTouchModal:owner=>{const token=owner+':'+state.modalTokens.size;state.modalTokens.add(token);return token;},
    releaseTouchModal:token=>state.modalTokens.delete(token),
    sendSourceKeyEvent:(source,key,scan,action)=>{calls.push({kind:'legacy',source,key,action});return true;}};
  let runtime;
  const env=environment({commons:{DiagnosticPolicy:{inputTraceEnabled:()=>options.trace===true}},imports:{'@ohos.deviceInfo':{default:{sdkApiVersion:options.api??26}},
    '@kit.IMEKit':{inputMethod:{getController:()=>{state.controllerGets++;return controller;},TextInputType:{TEXT:0},
      EnterKeyType:{NEWLINE:0,DONE:1,SEND:2},RequestKeyboardReason:{NONE:0,TOUCH:1}}},
    '@kit.PerformanceAnalysisKit':{hilog:{info:(...values)=>{if(options.traceThrows&&String(values[2]).startsWith('AMCL_IME_PHASE'))throw new Error('controlled diagnostic failure');traces.push(values);},error:noop,warn:(_domain,_tag,format,...args)=>warnings.push(format+' '+args.join(','))}},
    'libentry.so':{default:napi},'../runtime/GameSessionHost':{getGameSessionHost:()=>({textInputRuntime:runtime})}},sourceOverrides:options.sourceOverrides});
  const module=env.load(RUNTIME);runtime=new module.EntryTextInputRuntime();
  const Chat=env.load(CHAT,true).ChatInputBridge,Hard=env.load(HARD,true).DesktopPhysicalTextInput;
  const create=(kind='physical',wanted=true)=>{
    const component=kind==='physical'?new Hard():new Chat();
    const context={identity:component,px2vp:x=>x};contexts.set(component,context);component.getUIContext=()=>context;
    if(kind==='physical')component.active=wanted;else{component.mode=kind;component.visible=wanted;component.closes=0;component.onClose=()=>component.closes++;}
    component.aboutToAppear();return component;};
  return {env,runtime,state,calls,warnings,traces,callbacks,contexts,create,pendingAttach,pendingDetach,napi,module};
}

/** API20/21/22保原legacy，23/26两route捕获原UIContext与原show意图；不把Host mock当系统origin证明。 */
for(const api of [20,21,22,23,26])for(const role of ['physical','field','chat']) {
  const f=fixture({api});f.runtime.start();const component=f.create(role);await flush();
  // environment已实际transpile/execute Runtime、两个组件及真实Coordinator；本marker先于承重断言。
  console.log('SOFT_CONTEXT_TRANSPILED API'+api+' '+role);
  const physical=role==='physical',attached=f.calls.filter(x=>x.kind==='attach');
  const contexts=f.calls.filter(x=>x.kind==='context');
  assert.equal(attached.length,1,'one actual attach attempt');
  assert.equal(attached[0].show,!physical,'keyboard visibility retains original role');
  assert.equal(attached[0].config.inputAttribute.enterKeyType,physical?0:role==='field'?1:2);
  assert.equal(attached[0].config.newEditBox,physical?true:undefined,'no additional edit-box identity invented');
  if(api>=23) {
    assert.equal(contexts.length,1,role+' API'+api+' must use original UIContext');
    assert.equal(contexts[0].context,f.contexts.get(component),'same original resource object');
    assert.equal(contexts[0].context.identity,component);
    assert.equal(contexts[0].config,attached[0].config,'same original config, not a second editor');
    assert.equal(contexts[0].opts.showKeyboard,!physical);
    assert.equal(contexts[0].opts.requestKeyboardReason,0);
    assert.equal(attached[0].route,'context','context helper is not legacy fallback');
  } else {
    assert.equal(contexts.length,0,'API20-22 never calls unavailable context interface');
    assert.equal(attached[0].route,'legacy');
  }
  assert.equal(f.state.controllerGets,1);assert.equal(f.state.owners,1);assert.equal(f.state.maxOwners,1);
  component.aboutToDisappear();await flush();
  assert.equal(f.state.owners,0);assert.equal(f.state.nativeGeneration,0);assert.equal(f.callbacks.size,0);
}
console.log('PASS exact original context/show/config API20-26 physical/field/chat and real lease release');

/** 原context attach拒绝不造OS owner，退休原preview、释放Native租约；下一原资源可恢复，不退回legacy重发。 */
for(const api of [23,26])for(const role of ['physical','field']) {
  const f=fixture({api});f.state.attachError=true;f.runtime.start();const old=f.create(role);
  const oldPreview=f.callbacks.get('setPreviewText');assert.equal(typeof oldPreview,'function');await flush();
  assert.equal(f.calls.filter(x=>x.kind==='context').length,1);
  assert.equal(f.calls.filter(x=>x.kind==='attach'&&x.route==='legacy').length,0);
  assert.equal(f.runtime.snapshot().controllerPhase,'Idle');assert.equal(f.state.owners,0);
  assert.equal(f.state.nativeGeneration,0);assert.equal(f.callbacks.size,0);
  const begins=f.state.begins;f.runtime.maintain();assert.equal(f.state.begins,begins,'rejected activation does not busy retry');
  old.aboutToDisappear();f.state.attachError=false;const current=f.create(role);await flush();
  const records=f.calls.filter(x=>x.kind==='context');assert.equal(records.length,2);
  assert.equal(records[0].context,f.contexts.get(old));assert.equal(records[1].context,f.contexts.get(current));
  assert.notEqual(records[0].context,records[1].context);const baseline=f.calls.length;
  oldPreview('迟到',{start:0,end:0});assert.equal(f.calls.length,baseline,'old rejected operation cannot borrow current lease');
  f.callbacks.get('insertText')('当前');assert.equal(f.calls.filter(x=>x.kind==='commit').at(-1).text,'当前');
  assert.equal(f.state.controllerGets,1);assert.equal(f.state.maxOwners,1);
  current.aboutToDisappear();await flush();assert.equal(f.state.owners,0);assert.equal(f.state.nativeGeneration,0);
}
console.log('PASS context attach rejection retires original callbacks/lease, then exact new resource recovers');

/** 原attach未完成时资源换代，分别完成成功/拒绝Promise；旧成功须等原detach完成，不能并开新editor。 */
for(const api of [23,26])for(const role of ['physical','field'])for(const outcome of ['resolve','reject']) {
  const f=fixture({api});f.state.delayAttach=true;f.runtime.start();const old=f.create(role);
  const oldOperation=f.runtime.operation,oldPreview=f.callbacks.get('setPreviewText');
  assert.equal(f.pendingAttach.length,1);old.aboutToDisappear();const current=f.create(role);await flush();
  assert.equal(f.calls.filter(x=>x.kind==='context').length,1,'later resource waits for original attach');
  assert.equal(oldOperation.retired,true);f.state.delayAttach=false;
  if(outcome==='resolve') {
    f.state.delayDetach=true;f.pendingAttach.shift().resolve();await flush();
    assert.equal(f.state.owners,1);assert.equal(f.pendingDetach.length,1);
    assert.equal(f.calls.filter(x=>x.kind==='context').length,1,'no second attach before actual old detach');
    const baseline=f.calls.length;oldPreview('旧预编辑',{start:0,end:0});assert.equal(f.calls.length,baseline);
    f.state.delayDetach=false;f.pendingDetach.shift().resolve();
  } else f.pendingAttach.shift().reject(new Error('old context attach rejected'));
  await flush();await f.env.drainZero();
  const records=f.calls.filter(x=>x.kind==='context');assert.equal(records.length,2);
  assert.equal(records[0].context,f.contexts.get(old));assert.equal(records[1].context,f.contexts.get(current));
  assert.notEqual(f.runtime.operation,oldOperation);assert.equal(f.runtime.snapshot().controllerPhase,'Attached');
  assert.equal(f.state.owners,1);assert.equal(f.state.maxOwners,1);assert.equal(f.state.controllerGets,1);
  const baseline=f.calls.length;oldPreview('旧延迟',{start:0,end:0});assert.equal(f.calls.length,baseline);
  f.callbacks.get('insertText')('新');assert.equal(f.calls.filter(x=>x.kind==='commit').at(-1).text,'新');
  current.aboutToDisappear();await flush();assert.equal(f.state.owners,0);assert.equal(f.state.nativeGeneration,0);
}
console.log('PASS pending original context operation resolve/reject cleans up before replacement resource attaches');

/** API23 soft重建的旧insert/delete/preview/query闭包，在原detach期间与新editor激活后均不能借新资格。 */
{
  const f=fixture({api:23});f.runtime.start();const old=f.create('field');await flush();const callbacks=new Map(f.callbacks);
  f.state.delayDetach=true;old.aboutToDisappear();const current=f.create('field');await flush();
  const invokeOld=()=>{for(const [event,args] of [['insertText',['旧']],['deleteLeft',[1]],['sendFunctionKey',[0]],
    ['setPreviewText',['旧',{start:0,end:0}]],['finishTextPreview',[]],['selectByRange',[{start:0,end:0}]]])callbacks.get(event)(...args);
    assert.equal(callbacks.get('getLeftTextOfCursor')(99),'');assert.equal(callbacks.get('getTextIndexAtCursor')(),0);};
  let baseline=f.calls.length;invokeOld();assert.equal(f.calls.length,baseline);
  assert.equal(f.calls.filter(x=>x.kind==='context').length,1);f.state.delayDetach=false;f.pendingDetach.shift().resolve();
  await flush();await f.env.drainZero();assert.equal(f.calls.filter(x=>x.kind==='context').length,2);
  assert.equal(f.calls.filter(x=>x.kind==='context').at(-1).context,f.contexts.get(current));
  f.callbacks.get('insertText')('当前');baseline=f.calls.length;invokeOld();assert.equal(f.calls.length,baseline);
  assert.equal(current.echo,'当前');assert.equal(f.state.maxOwners,1);current.aboutToDisappear();await flush();
  assert.equal(f.state.owners,0);assert.equal(f.state.nativeGeneration,0);
}
console.log('ENTRY_SOFT_CONTEXT_CASES_PASS real Runtime callbacks/resource/lease; earliest OS origin unproven');

/** 同一生产编辑路径保原I27换行/控制过滤/删除/失败停止；不由测试重写组件onInsert。 */
{
  const f=fixture();f.runtime.start();const hard=f.create();await flush();
  const effects=()=>f.calls.filter(x=>x.kind==='commit'||x.kind==='key'||x.kind==='legacy');
  f.calls.length=0;f.callbacks.get('insertText')('abc\ndef');
  assert.deepEqual(effects().map(x=>x.kind==='commit'?'commit:'+x.text:'key:'+x.key),['commit:abc','key:257','commit:def']);
  assert.equal(f.callbacks.get('getLeftTextOfCursor')(99),'def');
  for(const text of ['\r\n','\n']){f.calls.length=0;f.callbacks.get('insertText')(text);
    assert.deepEqual(effects().map(x=>x.kind+':'+x.key),['key:257']);assert.equal(f.callbacks.get('getLeftTextOfCursor')(99),'');}
  f.calls.length=0;f.callbacks.get('insertText')('a\tb');assert.deepEqual(effects().map(x=>x.text),['ab']);
  assert.ok(f.warnings.some(w=>w.includes('dropped non-printable')));
  f.calls.length=0;f.callbacks.get('insertText')('x\r\ry');
  assert.deepEqual(effects().map(x=>x.kind==='commit'?'commit:'+x.text:'key:'+x.key),['commit:x','key:257','key:257','commit:y']);
  f.calls.length=0;f.callbacks.get('deleteLeft')(2);f.callbacks.get('insertText')('z');f.callbacks.get('deleteRight')(1);f.callbacks.get('sendFunctionKey')(0);
  assert.deepEqual(effects().map(x=>x.kind==='commit'?'commit:'+x.text:'key:'+x.key),['key:259','key:259','commit:z','key:261','key:257']);
  f.state.commitOk=text=>text!=='abc';f.calls.length=0;f.callbacks.get('insertText')('abc\ndef');assert.equal(effects().length,1);
  f.state.commitOk=()=>true;f.state.keyOk=false;f.calls.length=0;f.callbacks.get('insertText')('a\nb');
  assert.deepEqual(effects().map(x=>x.kind),['commit','key']);assert.equal(effects().some(x=>x.kind==='legacy'),false);
  f.calls.length=0;f.callbacks.get('deleteLeft')(3);assert.equal(effects().length,1);
  assert.ok(f.warnings.some(w=>w.includes('edit key rejected')));
  hard.aboutToDisappear();await flush();console.log('PASS preserved ordered hard newline/delete/insert and first failure stop');
}

/** 原I27三项反控改作用唯一生产正文：整段换行拒收、ring键越过有序入口、echo不随epoch退休。 */
{
  const whole=fixture({sourceOverrides:{[RUNTIME]:source=>{
    const needle='const source = operation.source, split: ImeInsertSplit = splitImeInsertText(text)';assert.ok(source.includes(needle));
    return source.replace(needle,"const source = operation.source; if (!commitEntryTextInput(operation.lease, text)) return\n    const split: ImeInsertSplit = splitImeInsertText('')");
  }}});whole.runtime.start();const hard=whole.create();await flush();whole.calls.length=0;
  whole.callbacks.get('insertText')('abc\ndef');assert.equal(whole.calls.filter(x=>x.kind==='commit'||x.kind==='key'||x.kind==='legacy').length,0);
  hard.aboutToDisappear();await flush();const chat=whole.create('chat');await flush();whole.calls.length=0;
  whole.callbacks.get('insertText')('abc\ndef');assert.equal(chat.closes,0);assert.equal(whole.calls.length,0);chat.aboutToDisappear();await flush();
  const ring=fixture({sourceOverrides:{[RUNTIME]:source=>{
    const needle='if (lease !== undefined) {\n      const result = tapEntryTextInputKey';assert.ok(source.includes(needle));
    return source.replace(needle,'if (false && lease !== undefined) {\n      const result = tapEntryTextInputKey');
  }}});ring.runtime.start();const ringHard=ring.create();await flush();ring.calls.length=0;
  ring.callbacks.get('deleteLeft')(1);ring.callbacks.get('insertText')('z');
  assert.deepEqual(ring.calls.filter(x=>x.kind==='legacy'||x.kind==='commit').map(x=>x.kind==='commit'?'commit:'+x.text:'ring:'+x.source+':'+x.key+':'+x.action),['ring:3:259:1','ring:3:259:0','commit:z']);
  assert.equal(ring.calls.some(x=>x.kind==='key'),false);ringHard.aboutToDisappear();await flush();
  const stale=fixture({sourceOverrides:{[RUNTIME]:source=>{
    const needle='if (generation === source.echoGeneration) return';assert.ok(source.includes(needle));
    return source.replace(needle,'if (generation === source.echoGeneration || source.echoGeneration !== 0) return');
  }}});stale.runtime.start();const staleHard=stale.create();await flush();stale.callbacks.get('insertText')('hello');
  stale.state.epoch='7';stale.state.nativeGeneration=0;assert.equal(stale.callbacks.get('getLeftTextOfCursor')(10),'hello');
  staleHard.aboutToDisappear();await flush();console.log('PASS compiled original negatives: whole newline rejected, ring-only ordering, stale epoch echo');
}

/** 三态保持原正确分支：端口实取缺席/NotTypedRoute才legacy，调用后异常结果未知必须拒绝补发。 */
{
  const f=fixture();f.runtime.start();const hard=f.create();await flush();
  f.state.route='legacy';f.calls.length=0;f.callbacks.get('deleteLeft')(1);
  assert.deepEqual(f.calls.filter(x=>x.kind==='legacy').map(x=>[x.source,x.key,x.action]),[[3,259,1],[3,259,0]]);
  const nativeTap=f.napi.textInputKeyTap;f.napi.textInputKeyTap=undefined;f.calls.length=0;f.callbacks.get('deleteLeft')(1);
  assert.deepEqual(f.calls.filter(x=>x.kind==='legacy').map(x=>[x.source,x.key,x.action]),[[3,259,1],[3,259,0]]);f.napi.textInputKeyTap=nativeTap;
  for(const route of ['boolean-false','typed','throw']){f.state.route=route;f.state.keyOk=false;f.calls.length=0;f.callbacks.get('deleteLeft')(1);
    assert.equal(f.calls.some(x=>x.kind==='legacy'),false);}
  assert.ok(f.warnings.some(w=>w.includes('outcome uncertain')));
  hard.aboutToDisappear();await flush();f.state.route='legacy';f.state.keyOk=true;const chat=f.create('chat');await flush();
  f.calls.length=0;chat.cancel();assert.deepEqual(f.calls.filter(x=>x.kind==='legacy').map(x=>[x.source,x.key,x.action]),[[1,256,1],[1,256,0]]);
  chat.aboutToDisappear();await flush();console.log('PASS three-state explicit/missing fallback, source pairing, false/rejected/uncertain no alternate output');
}

/** 原异常即fallback错误预期更正：实际Native先接受副作用后抛错，旧sink会再发送另一对按键。 */
{
  const sink='entry/src/main/ets/components/EntryTextInputSession.ets';
  const old=fixture({sourceOverrides:{[sink]:source=>{
    const needle=/(outcome uncertain[\s\S]*?return TextInputKeyTapResult\.)Rejected/;assert.ok(needle.test(source));
    return source.replace(needle,'$1NotTypedRoute');
  }}});old.runtime.start();const hard=old.create();await flush();old.state.route='throw';old.calls.length=0;
  old.callbacks.get('deleteLeft')(1);assert.deepEqual(old.calls.filter(x=>x.kind==='key'||x.kind==='legacy').map(x=>x.kind),['key','legacy','legacy']);
  hard.aboutToDisappear();await flush();console.log('PASS compiled uncertain-Native exception negative actually emits duplicate alternate tap');
}

/** 不确定结果同时遇reset也不重送同路线；明确Rejected+真实新epoch仍保原合法一次恢复。 */
{
  const f=fixture();f.runtime.start();const hard=f.create();await flush();const nativeTap=f.napi.textInputKeyTap;
  f.napi.textInputKeyTap=(...args)=>{nativeTap(...args);f.state.epoch='2';f.state.nativeGeneration=0;throw new Error('accepted then reset/throw');};
  f.calls.length=0;f.callbacks.get('deleteLeft')(1);assert.equal(f.calls.filter(x=>x.kind==='key').length,1);
  assert.equal(f.calls.some(x=>x.kind==='legacy'),false);hard.aboutToDisappear();await flush();
  const good=fixture();good.runtime.start();const goodHard=good.create();await flush();const tap=good.napi.textInputKeyTap;let count=0;
  good.napi.textInputKeyTap=(...args)=>{if(++count===1){good.state.keyOk=false;const r=tap(...args);good.state.keyOk=true;good.state.epoch='2';good.state.nativeGeneration=0;return r;}return tap(...args);};
  good.calls.length=0;good.callbacks.get('deleteLeft')(1);assert.equal(good.calls.filter(x=>x.kind==='key').length,2);
  assert.equal(good.calls.some(x=>x.kind==='legacy'),false);assert.ok(good.state.nativeGeneration>0);goodHard.aboutToDisappear();await flush();
  const repeated=fixture({sourceOverrides:{'entry/src/main/ets/components/EntryTextInputSession.ets':source=>{
    const needle=/(first !== TextInputKeyTapResult\.Rejected) \|\| keyTapUnavailableCount >= Number\.MAX_SAFE_INTEGER \|\|\s+uncertainBefore !== keyTapUnavailableCount/;
    assert.ok(needle.test(source));return source.replace(needle,'$1');
  }}});repeated.runtime.start();const repeatedHard=repeated.create();await flush();const repeatTap=repeated.napi.textInputKeyTap;let repeats=0;
  repeated.napi.textInputKeyTap=(...args)=>{const r=repeatTap(...args);if(++repeats===1){repeated.state.epoch='2';repeated.state.nativeGeneration=0;throw new Error('accepted then reset/throw');}return r;};
  repeated.calls.length=0;repeated.callbacks.get('deleteLeft')(1);assert.equal(repeated.calls.filter(x=>x.kind==='key').length,2);
  repeatedHard.aboutToDisappear();await flush();
  console.log('PASS uncertain tap with reset never retries; definite Rejected with new epoch retains original recovery');
}

/** Native命令同步退出只能完成已接受段，后续Enter/文本不再借旧回调入场的权限。 */
{
  const f=fixture();f.runtime.start();const hard=f.create();await flush();
  f.state.commitOk=()=>{f.runtime.stop('commit-reentry');return true;};f.calls.length=0;
  f.callbacks.get('insertText')('a\nb');await flush();assert.equal(f.calls.filter(x=>x.kind==='commit').length,1);
  assert.equal(f.calls.some(x=>x.kind==='key'),false);hard.aboutToDisappear();console.log('PASS real Native command boundary reentry stops later pieces');
}

/** 原owner scope撤回反控：旧闭包错误读取后来current，必须真实错投新Native generation。 */
{
  const f=fixture({sourceOverrides:{[RUNTIME]:source=>{
    const needle='if (accepted) this.insert(operation, text)';assert.ok(source.includes(needle));
    return source.replace(needle,'if (this.operation !== undefined) this.insert(this.operation, text)');
  }}});f.runtime.start();const old=f.create('field');await flush();const callback=f.callbacks.get('insertText');
  old.aboutToDisappear();await flush();const current=f.create('field');await flush();f.calls.length=0;
  callback('旧错投');assert.equal(f.calls.filter(x=>x.kind==='commit').at(-1).text,'旧错投');assert.equal(current.echo,'旧错投');
  current.aboutToDisappear();await flush();console.log('PASS compiled negative wrong-current callback actually writes new lease');
}

/** 上一次activation的attach拒绝不得把后来的明确开请求锁死，cleanup仍不借新resource。 */
{
  const f=fixture();f.state.delayAttach=true;f.runtime.start();const soft=f.create('field');await flush();
  soft.visible=false;soft.onVisibleChange();soft.visible=true;soft.onVisibleChange();
  f.state.delayAttach=false;f.pendingAttach.shift().reject(new Error('old activation failed'));
  await flush();await f.env.drainZero();assert.equal(f.state.owners,1);assert.equal(f.runtime.snapshot().controllerPhase,'Attached');
  soft.aboutToDisappear();await flush();console.log('PASS late previous activation attach failure does not quarantine new activation');
}

/** callback注册真实失败/attach拒绝先围栏，退出后新资源或用户show可以重新取得资格。 */
{
  const f=fixture();f.state.registrationError=true;f.runtime.start();const soft=f.create('field');await flush();
  assert.equal(f.state.owners,0);assert.equal(f.runtime.snapshot().controllerPhase,'Idle');
  const begins=f.state.begins;f.runtime.maintain();assert.equal(f.state.begins,begins,'permanent activation failure does not busy retry');
  f.state.registrationError=false;soft.reshowKeyboard();await flush();assert.equal(f.state.owners,1);
  soft.aboutToDisappear();await flush();console.log('PASS post-attach registration failure and explicit show recovery');
}

/** 生产模态broker保原owned-text命令，NotTypedRoute也不得用普通legacy按键落到底层。 */
{
  const f=fixture();f.runtime.start();const soft=f.create('chat');await flush();
  const modal=f.env.load('entry/src/main/ets/components/EntryTouchModalBroker.ets');const lease=modal.acquireEntryTouchModal('ime-chat');
  assert.ok(lease);f.state.route='legacy';soft.cancel();await flush();
  assert.equal(f.calls.some(x=>x.kind==='legacy'),false);assert.equal(soft.closes,1);assert.equal(modal.releaseEntryTouchModal(lease),true);
  soft.aboutToDisappear();console.log('PASS actual modal broker prevents ordinary fallback while UI closes');
}

/** 非prepared的真实UI资源请求只能Pending；显式start才真实取得controller与Native lease。 */
{
  const f=fixture();const hard=f.create();assert.equal(f.state.controllerGets,0);assert.equal(f.calls.length,0);
  f.runtime.start();await flush();assert.equal(f.state.controllerGets,1);assert.equal(f.state.owners,1);
  assert.equal(f.runtime.snapshot().controllerPhase,'Attached');
  f.callbacks.get('insertText')('汉😀');assert.equal(f.calls.filter(x=>x.kind==='commit').at(-1).text,'汉😀');
  assert.equal(f.callbacks.get('getLeftTextOfCursor')(4096),'汉😀');
  assert.equal(f.callbacks.get('getTextIndexAtCursor')(),3,'official IMF caret offsets use UTF16; echo query is not the real game document');
  f.calls.length=0;f.callbacks.get('selectByRange')({start:3,end:3});
  assert.equal(f.calls.some(x=>x.kind==='selection'),false,'OS document selection cannot derive scalar position from echo');
  const currentSource=f.runtime.sources.get(hard.binding.id);
  assert.equal(currentSource.documentRequest.kind,'Selection');assert.equal(currentSource.documentRequest.startUtf16,3);
  assert.equal(currentSource.documentRequest.outcome,'DocumentSelectionUnsupported');
  f.calls.length=0;f.callbacks.get('selectByRange')({start:2,end:2});assert.equal(f.calls.some(x=>x.kind==='selection'),false);
  assert.equal(currentSource.documentRequest.startUtf16,2,'original range retained; no real document means no surrogate-boundary claim from echo');
  assert.equal(f.callbacks.get('getLeftTextOfCursor')(1),'');assert.equal(f.callbacks.get('getLeftTextOfCursor')(2),'😀');
  const wrong=fixture({sourceOverrides:{[RUNTIME]:source=>{
    const needle='this.utf16Length(operation)';assert.ok(source.includes(needle));return source.replace(needle,'this.scalars(operation.source.echo).length');
  }}});wrong.runtime.start();const wrongHard=wrong.create();await flush();wrong.callbacks.get('insertText')('😀');
  const index=wrong.callbacks.get('getTextIndexAtCursor')();assert.equal(index,1);wrong.calls.length=0;
  assert.throws(()=>assert.equal(index,2),'compiled wrong unit must fail the original UTF16 caret query assertion');
  wrong.callbacks.get('selectByRange')({start:index,end:index});assert.equal(wrong.calls.some(x=>x.kind==='selection'),false);
  wrongHard.aboutToDisappear();await flush();
  hard.aboutToDisappear();await flush();await f.env.drainZero();assert.equal(f.state.owners,0);
  console.log('PASS actual component Pending/start/Native lease/scalar echo/unbind');
}

/** 精确原callback在Native同步回入退休后，每个后续副作用都必须重新核原op。 */
{
  const f=fixture();f.runtime.start();const hard=f.create();await flush();const original=f.napi.textInputKeyTap;let taps=0;
  f.napi.textInputKeyTap=(...args)=>{const result=original(...args);if(++taps===1)hard.aboutToDisappear();return result;};
  f.calls.length=0;f.callbacks.get('deleteLeft')(3);assert.equal(f.calls.filter(x=>x.kind==='key').length,1);await flush();
  const p=fixture();p.runtime.start();const field=p.create('field');await flush();const editing=p.napi.updateTextInputEditing;
  p.napi.updateTextInputEditing=(...args)=>{const result=editing(...args);field.aboutToDisappear();return result;};
  p.calls.length=0;p.callbacks.get('setPreviewText')('新',{start:0,end:0});assert.deepEqual(p.calls.filter(x=>x.kind==='preview'||x.kind==='selection').map(x=>x.kind),['preview']);
  await flush();console.log('PASS actual delete/preview Native reentry retires before every later effect');
}

/** 从实际build逐字取factory表达式，排队原点击在hide、重开、换role、重建之后一律无副作用。 */
{
  const source=fs.readFileSync(fileURLToPath(new URL('../'+CHAT,import.meta.url)),'utf8');
  // 逐字提取真实build中的三个factory：原生Button.onClick和共享Round.onAction都是同一个生产意图。
  // AST只接受这两个已知事件绑定位置，不能从注释或其它makeAction调用凑满三个动作。
  const ast=compiler.createSourceFile(CHAT,source,compiler.ScriptTarget.Latest,true);
  const owner=ast.statements.find(node=>node.name?.getText(ast)==='ChatInputBridge');
  const build=owner?.members.find(node=>node.name?.getText(ast)==='build');assert.ok(build);
  const expressions=[];
  function collectFactory(node){
    if(node.kind===compiler.SyntaxKind.CallExpression&&node.expression.getText(ast)==='this.makeAction'){
      const parent=node.parent,kind=node.arguments[0]?.text;
      const native=parent?.kind===compiler.SyntaxKind.CallExpression&&parent.expression?.name?.text==='onClick'&&parent.arguments[0]===node;
      const shared=parent?.kind===compiler.SyntaxKind.PropertyAssignment&&parent.name?.getText(ast)==='onAction'&&
        parent.parent?.parent?.kind===compiler.SyntaxKind.CallExpression&&parent.parent.parent.expression.getText(ast)==='AppRoundIconButton';
      if(native||shared)expressions.push({expression:node.getText(ast),kind,binding:native?'Button.onClick':'AppRoundIconButton.onAction'});
    }
    compiler.forEachChild(node,collectFactory);
  }
  collectFactory(build);
  assert.equal(expressions.length,3);assert.deepEqual(expressions.map(item=>item.kind).sort(),['cancel','show','submit']);
  assert.ok(expressions.some(item=>item.kind==='cancel'&&item.binding==='AppRoundIconButton.onAction'),'取消必须来自真实共享按钮');
  const f=fixture();f.runtime.start();const hard=f.create(),chat=f.create('chat');await flush();
  const queued=expressions.map(item=>new Function('return '+item.expression).call(chat));
  chat.visible=false;chat.onVisibleChange();await flush();await f.env.drainZero();f.calls.length=0;
  queued.forEach(fn=>fn());assert.equal(f.calls.length,0,'old hidden activation cannot send Touch keys during hard role');
  chat.visible=true;chat.onVisibleChange();await flush();f.calls.length=0;queued.forEach(fn=>fn());
  assert.equal(f.calls.length,0,'old activation cannot borrow reopened same binding');assert.equal(chat.closes,0);
  chat.mode='field';chat.onModeChange();await flush();f.calls.length=0;queued.forEach(fn=>fn());assert.equal(f.calls.length,0);
  chat.aboutToDisappear();await flush();const current=f.create('chat');await flush();f.calls.length=0;queued.forEach(fn=>fn());assert.equal(f.calls.length,0);
  current.cancel();assert.equal(current.closes,1,'current explicit action remains functional');hard.aboutToDisappear();current.aboutToDisappear();await flush();
  const wrong=fixture({sourceOverrides:{[CHAT]:source=>{
    const needle='const intent = binding !== undefined ? runtime?.captureIntent(binding) : undefined';assert.ok(source.includes(needle));
    source=source.replace(needle,'');return source.replace('return (): void => {',"return (): void => {\n      const intent = this.binding !== undefined ? this.runtime?.captureIntent(this.binding) : undefined");
  }}});wrong.runtime.start();const old=wrong.create('chat');await flush();const click=old.makeAction('submit');
  old.visible=false;old.onVisibleChange();await flush();old.visible=true;old.onVisibleChange();await flush();wrong.calls.length=0;click();
  assert.equal(old.closes,1);assert.ok(wrong.calls.some(x=>x.kind==='key'&&x.key===257),'compiled current-intent mutation really sends into reopened activation');
  old.aboutToDisappear();await flush();
  console.log('PASS actual rendered actions capture original request capability through hide/reopen/role/page reconstruction');
}

/**
 * V1保留子组件时普通函数只初始化一次：运行Chat真实key数据、ForEach itemBuilder、原factory与Round生命周期方法。
 * 夹具只模拟已由真实SDK产物证明的V1初始化/更新边界，不把该模型称为系统UI排版或新SDK编译证明。
 */
{
  const source=fs.readFileSync(fileURLToPath(new URL('../'+CHAT,import.meta.url)),'utf8');
  const ast=compiler.createSourceFile(CHAT,source,compiler.ScriptTarget.Latest,true);
  const owner=ast.statements.find(node=>node.name?.getText(ast)==='ChatInputBridge');
  const build=owner?.members.find(node=>node.name?.getText(ast)==='build');assert.ok(build);
  const loops=[];
  function collectCancelLoop(node){
    if(node.kind===compiler.SyntaxKind.CallExpression&&node.expression.getText(ast)==='ForEach'&&
      node.getText(ast).includes("this.makeAction('cancel')"))loops.push(node);
    compiler.forEachChild(node,collectCancelLoop);
  }
  collectCancelLoop(build);assert.equal(loops.length,1,'原取消factory必须由唯一单项ForEach承载');
  const loop=loops[0];assert.equal(loop.arguments.length,3);
  const Round=loadActionComponent('entry/src/main/ets/components/AppRoundIconButton.ets','AppRoundIconButton',{
    methods:['aboutToAppear','aboutToDisappear','requestAction_'],dependencies:{}});
  /** 只转译生产表达式；不重写key计算、factory、runtime状态或原业务回调。 */
  function expression(text,component,values={}){
    const compiled=compiler.transpileModule('const value = '+text+';',{
      fileName:'CapturedChatBuilder.ts',reportDiagnostics:true,
      compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020}});
    assert.equal((compiled.diagnostics??[]).filter(d=>d.category===compiler.DiagnosticCategory.Error).length,0);
    return new Function(...Object.keys(values),compiled.outputText+'\nreturn value;').call(component,...Object.values(values));
  }
  async function retainedCancel(scenario,sourceOverrides){
    const f=fixture({sourceOverrides});f.runtime.start();const chat=f.create(scenario==='echo-only'?'field':'chat');await flush();
    let current,mounts=0,retires=0;const all=[];
    const intentIdentity=()=>{const intent=chat.runtime.captureIntent(chat.binding);
      return intent===undefined?'':String(intent.binding.id)+':'+intent.activation;};
    /** 模拟V1对子实例的保留：普通onAction仅初始传入，父重新build不会替换该函数。 */
    function render(){
      const entries=expression(loop.arguments[0].getText(ast),chat);assert.equal(entries.length,1);
      const keyOf=expression(loop.arguments[2].getText(ast),chat),key=keyOf(entries[0]);
      let props;
      const item=expression(loop.arguments[1].getText(ast),chat,{
        AppRoundIconButton:value=>{props=value;},AppIconName:{Close:'close'},$r:value=>value});
      item(entries[0]);assert.equal(typeof props?.onAction,'function','真实itemBuilder必须调用原cancel工厂');
      if(current?.key!==key){
        if(current){current.node.aboutToDisappear();retires++;}
        const node=new Round();node.actionEnabled=props.actionEnabled??true;node.onAction=props.onAction;node.aboutToAppear();
        current={key,node};all.push(node);mounts++;
      }else{
        // SDK updateStateVars刷新@Prop，但不会给普通函数onAction重新赋值。
        current.node.actionEnabled=props.actionEnabled??true;
      }
      return current;
    }
    const first=render(),beforeKey=first.key,beforeIntent=intentIdentity(),oldClick=()=>first.node.requestAction_();
    if(scenario==='visible-mode-change'){chat.mode='field';chat.onModeChange();}
    else if(scenario==='same-frame-hide-show'){
      // 两次真实wanted切换，中间不提交UI渲染；即使子节点保留，最终identity也必须不同。
      chat.visible=false;chat.onVisibleChange();chat.visible=true;chat.onVisibleChange();
    }else{
      f.callbacks.get('insertText')('只更新');render();f.callbacks.get('insertText')('回声');
    }
    await flush();await f.env.drainZero();const afterIntent=intentIdentity(),last=render();
    if(scenario!=='echo-only'){oldClick();assert.equal(chat.closes,0,'旧请求或退休Round不能关闭新输入');}
    last.node.requestAction_();const closes=chat.closes;last.node.requestAction_();assert.equal(chat.closes,closes,'同一取消不得重复派发');
    const result={scenario,beforeKey,afterKey:last.key,beforeIntent,afterIntent,mounts,retires,closes};
    for(const node of all)node.aboutToDisappear();chat.aboutToDisappear();await flush();return result;
  }
  for(const scenario of ['visible-mode-change','same-frame-hide-show','echo-only']){
    const result=await retainedCancel(scenario);
    assert.equal(result.beforeKey,result.beforeIntent,'展示key必须来自原intent');
    assert.equal(result.afterKey,result.afterIntent,'展示key不自行签发能力或沿用旧activation');
    assert.equal(result.closes,1,'保留V1函数规则时当前取消仍应成功');
    if(scenario==='echo-only'){
      assert.equal(result.beforeKey,result.afterKey);assert.deepEqual([result.mounts,result.retires],[1,0],'echo-only不能每个字重建');
    }else{
      assert.notEqual(result.beforeKey,result.afterKey);assert.deepEqual([result.mounts,result.retires],[2,1],'只在原请求身份变化时替换Round');
    }
  }
  // 撤回实际生产key同步：真实新intent仍存在，但保留子实例再次持有旧factory，回归必须检出关闭失效。
  const withdrawn=await retainedCancel('visible-mode-change',{[CHAT]:text=>{
    const needle='this.cancelIdentity_ = this.mounted &&';assert.ok(text.includes(needle));
    return text.replace(needle,'this.cancelIdentity_ = false && this.mounted &&');
  }});
  assert.notEqual(withdrawn.beforeIntent,withdrawn.afterIntent);assert.equal(withdrawn.closes,0);
  assert.deepEqual([withdrawn.mounts,withdrawn.retires],[1,0]);
  assert.throws(()=>assert.equal(withdrawn.closes,1),'撤回identity的真实行为负控必须暴露旧factory');
  console.log('PASS actual keyed cancel ForEach preserves V1 callback ownership through mode/coalesced hide-show; echo-only reuses one Round; withdrawn key negative fails');
}

/** 当前角色交接共用一个controller；soft请求立即围栏hard，detach完成前不attach第二份。 */
for(const api of [22,23,26]){
  const f=fixture({api});f.runtime.start();const hard=f.create();await flush();
  f.callbacks.get('insertText')('before');f.state.epoch='2';f.state.nativeGeneration=0;
  assert.equal(f.callbacks.get('getLeftTextOfCursor')(10),'');assert.equal(f.callbacks.get('getTextIndexAtCursor')(),0);
  f.callbacks.get('insertText')('after');assert.equal(f.calls.filter(x=>x.kind==='commit').at(-1).text,'after');
  const original=new Map(f.callbacks);f.state.delayDetach=true;
  const soft=f.create('field');await flush();assert.equal(f.state.owners,1);assert.equal(f.pendingDetach.length,1);
  const before=f.calls.filter(x=>x.kind==='commit').length;original.get('insertText')('旧硬件');
  assert.equal(f.calls.filter(x=>x.kind==='commit').length,before);
  f.state.delayDetach=false;f.pendingDetach.shift().resolve();await flush();await f.env.drainZero();
  assert.equal(f.state.owners,1);assert.equal(f.state.maxOwners,1);f.callbacks.get('insertText')('软');assert.equal(soft.echo,'软');
  f.state.epoch='3';f.state.nativeGeneration=0;assert.equal(f.callbacks.get('getLeftTextOfCursor')(10),'');assert.equal(soft.echo,'');
  f.callbacks.get('insertText')('soft');assert.equal(f.calls.filter(x=>x.kind==='commit').at(-1).text,'soft');
  soft.visible=false;soft.onVisibleChange();await flush();await f.env.drainZero();assert.equal(f.state.owners,1);
  if(api===22)assert.equal(f.calls.some(x=>x.kind==='context'),false);else assert.ok(f.calls.some(x=>x.kind==='context'));
  hard.aboutToDisappear();soft.aboutToDisappear();await flush();assert.equal(f.state.owners,0);
  console.log('PASS actual hard/soft serialized handoff and original UIContext API'+api);
}

/** 原OS闭包排队后页面重建，真实ImeCallbackLease保原lease、role、resource而不借后来current。 */
{
  const f=fixture();f.runtime.start();const old=f.create('field');await flush();const callbacks=new Map(f.callbacks);
  old.aboutToDisappear();await flush();const current=f.create('field');await flush();
  f.callbacks.get('insertText')('当前');f.callbacks.get('setPreviewText')('新预编辑',{start:0,end:0});
  const baseline=f.calls.length;
  for(const [event,args] of [['insertText',['迟到']],['deleteLeft',[1]],['sendFunctionKey',[0]],['setPreviewText',['旧',{start:0,end:0}]],['finishTextPreview',[]],['selectByRange',[{start:0,end:0}]]])callbacks.get(event)(...args);
  assert.equal(f.calls.length,baseline);assert.equal(current.echo,'当前');assert.equal(callbacks.get('getLeftTextOfCursor')(99),'');assert.equal(callbacks.get('getTextIndexAtCursor')(),0);
  current.aboutToDisappear();await flush();console.log('PASS queued old callbacks cannot borrow reconstructed page lease or echo');
}

/** 关闭显示观察不停止真实epoch维护/原OS回调；原资源仍在，维护恢复Native号并清旧echo。 */
{
  const f=fixture();f.runtime.start();const soft=f.create('field');await flush();f.callbacks.get('insertText')('旧上下文');
  f.runtime.unobserve(soft.binding);f.state.epoch='2';f.state.nativeGeneration=0;f.runtime.maintain();
  assert.equal(f.callbacks.get('getLeftTextOfCursor')(99),'');f.callbacks.get('insertText')('恢复');
  assert.equal(f.callbacks.get('getLeftTextOfCursor')(99),'恢复');assert.equal(soft.echo,'旧上下文','unobserved UI is only an old projection');
  soft.aboutToDisappear();await flush();console.log('PASS unobserve leaves runtime maintenance and original source alive');
}

/** HostRejected退避只有五次；无观察/页面心跳依赖，Host maintain条件变化可重武装一次。 */
{
  const f=fixture();f.state.beginOk=false;f.runtime.start();const soft=f.create('field');await flush();
  for(let i=0;i<5;i++){assert.equal(f.env.timer.size,1);f.env.runTimers();await flush();}
  assert.equal(f.state.begins,6);assert.equal(f.env.timer.size,0);f.runtime.unobserve(soft.binding);
  f.runtime.maintain();await flush();assert.equal(f.state.begins,6,'unchanged epoch cannot rearm exhausted budget');
  f.state.beginOk=true;f.state.epoch='2';f.runtime.maintain();await flush();assert.equal(f.state.owners,1);
  soft.aboutToDisappear();await flush();console.log('PASS bounded retry and stable Host rearm without observers');
}

/** 原硬软件两端预算前提都经过公共runtime；旧“耗尽即永久失败”变异实际阻止新epoch恢复。 */
for(const role of ['physical','chat']){
  const f=fixture();f.state.beginOk=false;f.runtime.start();const component=f.create(role);await flush();
  for(let i=0;i<5;i++){assert.equal(f.env.timer.size,1);f.env.runTimers();await flush();}
  f.runtime.maintain();assert.equal(f.state.begins,6);assert.equal(f.env.timer.size,0);
  f.state.epoch='2';f.runtime.maintain();await flush();assert.equal(f.state.begins,7);assert.equal(f.env.timer.size,1);
  f.state.beginOk=true;f.env.runTimers();await flush();assert.equal(f.state.owners,1);assert.equal(f.state.begins,8);
  component.aboutToDisappear();await flush();
  const dead=fixture({sourceOverrides:{[RUNTIME]:source=>{
    const needle="source.retryExhausted = true; source.failure = 'HostRejectedBudgetExhausted'";assert.ok(source.includes(needle));
    return source.replace(needle,"source.failedActivation = true; source.failure = 'HostRejectedBudgetExhausted'");
  }}});dead.state.beginOk=false;dead.runtime.start();const old=dead.create(role);await flush();
  for(let i=0;i<5;i++){dead.env.runTimers();await flush();}dead.state.epoch='2';dead.runtime.maintain();await flush();
  assert.equal(dead.state.begins,6);assert.equal(dead.env.timer.size,0);assert.equal(dead.state.owners,0);old.aboutToDisappear();await flush();
  console.log('PASS original '+role+' retry premise and compiled permanent-exhaustion negative');
}

/** stop不会等待非完成OS Promise；旧attach完成后只原资源cleanup，detach拒绝如实Failed。 */
{
  const f=fixture();f.state.delayAttach=true;f.runtime.start();const soft=f.create('field');await flush();
  const outcomes=[];const observed=value=>outcomes.push(value);f.runtime.addStopOutcomeListener(observed);
  assert.equal(f.runtime.stop('game-stop').stopOutcome,'Pending');assert.equal(outcomes.length,0);f.pendingAttach.shift().resolve();await flush();
  assert.equal(f.runtime.snapshot().stopOutcome,'Completed');assert.equal(f.state.owners,0);
  assert.equal(outcomes.at(-1).stopOutcome,'Completed');f.runtime.removeStopOutcomeListener(observed);
  assert.equal(f.create('field').binding,undefined);soft.aboutToDisappear();
  const rejected=fixture();rejected.runtime.start();rejected.create('field');await flush();rejected.state.detachError=true;
  assert.equal(rejected.runtime.stop('game-stop').stopOutcome,'Pending');await flush();const actual=rejected.runtime.snapshot();
  assert.equal(actual.stopOutcome,'Failed');assert.equal(actual.callbackFenced,true);assert.equal(actual.platformDetachResolved,false);
  assert.equal(rejected.state.owners,1,'OS rejection is not a pretend detach');console.log('PASS actual pending stop, late attach cleanup and truthful detach Failed');
}

/** 停止预算只有一个deadline，不轮询；晚到实际成功只更新事实，不能抹掉原TimedOut。 */
{
  const f=fixture();f.runtime.start();f.create('field');await flush();f.state.delayDetach=true;
  const outcomes=[];f.runtime.addStopOutcomeListener(value=>outcomes.push(value));
  const result=f.runtime.stop('deadline');assert.equal(result.callbackFenced,true);assert.equal(result.localLeaseClosed,true);
  await flush();f.env.runTimers();await flush();assert.equal(outcomes.at(-1).stopOutcome,'TimedOut');
  assert.equal(outcomes.at(-1).platformDetachResolved,false);assert.equal(f.state.owners,1);
  f.pendingDetach.shift().resolve();await flush();assert.equal(outcomes.at(-1).stopOutcome,'TimedOut');
  assert.equal(outcomes.at(-1).platformDetachResolved,true);assert.equal(f.state.owners,0);assert.equal(f.env.timer.size,0);
  console.log('PASS original stop outcome exact callbacks/deadline/late actual facts; no UI polling');
}

/** 两soft请求聚合：关闭旧角色不清兄弟优先声明，自己的submit/cancel保持原chat/field语义。 */
{
  const f=fixture();f.runtime.start();const chat=f.create('chat'),field=f.create('field');await flush();
  f.callbacks.get('insertText')('首行\n尾行');assert.equal(chat.closes,1);await flush();await f.env.drainZero();
  assert.ok(f.warnings.some(w=>w.includes('truncated after first line break')));
  assert.equal(f.state.owners,1);assert.equal(f.runtime.snapshot().controllerPhase,'Attached');
  f.callbacks.get('insertText')('字段');field.cancel();await flush();assert.equal(field.closes,1);
  assert.equal(f.calls.filter(x=>x.kind==='key').length,1,'field cancel must not synthesize Escape');
  chat.aboutToDisappear();field.aboutToDisappear();console.log('PASS shared source policy preserves chat/field and sibling soft request');
}

/** 原单行的各独立前提在明确新activation上重跑，不把已退休OS闭包当再输入的权限。 */
for(const role of ['chat','field']){
  const f=fixture();f.runtime.start();const soft=f.create(role);await flush();
  const effects=()=>f.calls.filter(x=>x.kind==='commit'||x.kind==='key'||x.kind==='legacy');
  const reopen=async()=>{soft.visible=true;soft.onVisibleChange();await flush();await f.env.drainZero();};
  for(const text of ['\n','\r\n']){f.calls.length=0;f.callbacks.get('insertText')(text);await flush();
    assert.deepEqual(effects().map(x=>x.kind+':'+x.key),role==='chat'?['key:257']:[]);await reopen();}
  f.calls.length=0;f.callbacks.get('insertText')('a\tb');assert.deepEqual(effects().map(x=>x.text),['ab']);
  f.calls.length=0;f.callbacks.get('deleteLeft')(1);f.callbacks.get('insertText')('c');
  assert.deepEqual(effects().map(x=>x.kind==='commit'?'commit:'+x.text:'key:'+x.key),['key:259','commit:c']);assert.equal(soft.echo,'ac');
  f.calls.length=0;soft.cancel();await flush();assert.deepEqual(effects().map(x=>x.kind+':'+x.key),role==='chat'?['key:256']:[]);
  await reopen();f.calls.length=0;f.callbacks.get('insertText')('x\ny');await flush();
  assert.deepEqual(effects().map(x=>x.kind==='commit'?'commit:'+x.text:'key:'+x.key),role==='chat'?['commit:x','key:257']:['commit:x']);
  soft.aboutToDisappear();await flush();console.log('PASS original '+role+' CRLF/filter/delete/submit/cancel semantics on explicit activation');
}

/** 原Native确切接受/拒绝和已调用未知分开；预编辑和底层文档selection运输没有重试helper。 */
{
  for(const outcome of ['accepted-reset','false-reset','uncertain-reset']){
    const f=fixture();f.runtime.start();const hard=f.create();await flush();const commit=f.napi.commitTextInput;let count=0;
    f.napi.commitTextInput=(...args)=>{
      if(++count!==1)return commit(...args);
      f.state.commitOk=()=>outcome!=='false-reset';const result=commit(...args);
      f.state.commitOk=()=>true;f.state.epoch='2';f.state.nativeGeneration=0;
      if(outcome==='uncertain-reset')throw Error('accepted Native result unknown');return result;
    };
    f.calls.length=0;f.callbacks.get('insertText')('一次提交');
    assert.equal(f.calls.filter(x=>x.kind==='commit').length,outcome==='false-reset'?2:1,outcome);
    assert.equal(f.calls.some(x=>x.kind==='key'||x.kind==='legacy'),false);hard.aboutToDisappear();await flush();
  }
  const sink='entry/src/main/ets/components/EntryTextInputSession.ets';
  const old=fixture({sourceOverrides:{[sink]:source=>{
    const needle='  if (commitOutcomeUncertainCount >= Number.MAX_SAFE_INTEGER || uncertainBefore !== commitOutcomeUncertainCount) return false';assert.ok(source.includes(needle));
    return source.replace(needle,'');
  }}});old.runtime.start();const oldHard=old.create();await flush();const originalCommit=old.napi.commitTextInput;let first=true;
  old.napi.commitTextInput=(...args)=>{const result=originalCommit(...args);if(first){first=false;old.state.epoch='2';old.state.nativeGeneration=0;throw Error('accepted Native result unknown');}return result;};
  old.calls.length=0;old.callbacks.get('insertText')('一次提交');const commits=old.calls.filter(x=>x.kind==='commit');
  assert.equal(commits.length,2);assert.notEqual(commits[0].g,commits[1].g);assert.equal(commits[0].text,commits[1].text);oldHard.aboutToDisappear();await flush();
  for(const kind of ['preview','selection']){
    const f=fixture();f.runtime.start();const hard=f.create();await flush();const method=kind==='preview'?'updateTextInputEditing':'updateTextInputSelection';const native=f.napi[method];
    f.napi[method]=(...args)=>{native(...args);f.state.epoch='2';f.state.nativeGeneration=0;throw Error('editing result unknown');};
    f.calls.length=0;if(kind==='preview')f.callbacks.get('setPreviewText')('候选',{start:0,end:0});else {
      // 底层Coordinator/Entry sink的原unknown合同仍需真实执行；OS回调现在按文档能力拒绝，
      // 不得用“不调用Native”的新路径使本条调用后异常回归变成空断言。
      f.env.load('entry/src/main/ets/components/EntryTextInputSession.ets').getEntryTextInputSession()
        .selection(f.runtime.operation.lease,0,0);
    }
    assert.equal(f.calls.filter(x=>x.kind===kind).length,1);if(kind==='preview')assert.equal(f.calls.some(x=>x.kind==='selection'),false);
    hard.aboutToDisappear();await flush();
  }
  console.log('PASS all called-unknown text paths do not repeat; accepted no replay, definite false/reset recover; compiled commit replay negative');
}

/** 两计数边界仍运行原Sink/helper：MAX-1→MAX后未知不重发，饱和后明确拒绝也不授权reset重试。 */
{
  const sink='entry/src/main/ets/components/EntryTextInputSession.ets';
  for(const kind of ['key','commit']){
    const counter=kind==='key'?'keyTapUnavailableCount':'commitOutcomeUncertainCount';
    const f=fixture({sourceOverrides:{[sink]:source=>{
      const needle=`let ${counter}: number = 0`;assert.ok(source.includes(needle));
      return source.replace(needle,`let ${counter}: number = Number.MAX_SAFE_INTEGER - 1`);
    }}});f.runtime.start();const hard=f.create();await flush();
    const method=kind==='key'?'textInputKeyTap':'commitTextInput',native=f.napi[method];
    const trigger=()=>kind==='key'?f.callbacks.get('deleteLeft')(1):f.callbacks.get('insertText')('边界');
    for(const outcome of ['unknown','unknown','definite-false','accepted']){
      f.state.keyOk=outcome!=='definite-false';f.state.commitOk=()=>outcome!=='definite-false';
      f.napi[method]=(...args)=>{const result=native(...args);f.state.epoch=String(Number(f.state.epoch)+1);f.state.nativeGeneration=0;
        if(outcome==='unknown')throw Error('accepted boundary result unknown');return result;};
      f.calls.length=0;trigger();assert.equal(f.calls.filter(x=>x.kind===kind).length,1,kind+':'+outcome);
      assert.equal(f.calls.some(x=>x.kind==='legacy'),false);
    }
    hard.aboutToDisappear();await flush();
  }
  console.log('PASS both uncertainty counters saturate safely and permanently refuse reset retry authority; successful call remains single');
}

/** 文档替换/选择保原UTF16与operation，只报告能力不足；同包预编辑caret仍交付一次。 */
{
  const f=fixture();f.runtime.start();const field=f.create('field');await flush();
  const source=f.runtime.sources.get(field.binding.id),observed=[],originalObserver=source.observer;
  f.runtime.observe(field.binding,value=>{observed.push(value);originalObserver(value);});
  f.callbacks.get('insertText')('ab');f.calls.length=0;
  const replacementRange={start:0,end:1};f.callbacks.get('setPreviewText')('XYZ',replacementRange);
  assert.deepEqual(f.calls.filter(x=>x.kind==='preview'||x.kind==='selection').map(x=>[x.kind,x.start,x.length]),[['preview',3,0]]);
  let value=observed.at(-1),request=source.documentRequest;
  assert.equal(request.operation,f.runtime.operation);assert.equal(request.operation.lease,f.runtime.operation.lease);
  assert.equal(request.replacementText,'XYZ');assert.equal(value.documentOperation,'Replacement');
  assert.deepEqual([value.documentStartUtf16,value.documentEndUtf16],[0,1]);
  assert.equal(value.documentOutcome,'DocumentReplacementUnsupported');assert.match(field.documentMessage,/暂不支持替换/);
  replacementRange.start=1;replacementRange.end=2;assert.deepEqual([request.startUtf16,request.endUtf16],[0,1]);
  value.documentOutcome='Supported';f.runtime.maintain();assert.equal(observed.at(-1).documentOutcome,'DocumentReplacementUnsupported');
  for(const range of [{start:0,end:1},{start:200,end:300}]) {
    f.calls.length=0;f.callbacks.get('selectByRange')(range);value=observed.at(-1);
    assert.equal(f.calls.some(x=>x.kind==='selection'||x.kind==='preview'),false);
    assert.equal(source.preview,'XYZ');assert.equal(value.documentOperation,'Selection');
    assert.deepEqual([value.documentStartUtf16,value.documentEndUtf16],[range.start,range.end]);
    assert.equal(value.documentOutcome,'DocumentSelectionUnsupported');assert.match(field.documentMessage,/暂不支持选择/);
  }
  f.callbacks.get('finishTextPreview')();f.calls.length=0;f.callbacks.get('selectByRange')({start:0,end:1});
  assert.equal(f.calls.some(x=>x.kind==='selection'||x.kind==='preview'),false);assert.equal(source.preview,'');
  f.callbacks.get('setPreviewText')('汉😀Z',{start:-1,end:-1});value=observed.at(-1);
  assert.equal(f.calls.filter(x=>x.kind==='preview').at(-1).start,3);
  assert.deepEqual([value.documentStartUtf16,value.documentEndUtf16],[-1,-1]);
  assert.equal(value.documentOutcome,'DocumentReplacementUnsupported','default Range is retained without inventing a caret');
  for(const range of [{start:-1,end:0},{start:3,end:2},{start:0.5,end:1},{start:NaN,end:0}]) {
    f.calls.length=0;f.callbacks.get('setPreviewText')('不应写入',range);
    assert.equal(f.calls.some(x=>x.kind==='preview'||x.kind==='selection'||x.kind==='commit'||x.kind==='legacy'),false);
    assert.equal(observed.at(-1).documentOutcome,'InvalidDocumentRange');
  }
  for(let i=0;i<20;i++)f.callbacks.get('selectByRange')({start:i,end:i});
  assert.equal(f.runtime.sources.size,1);assert.equal(source.documentRequest.kind,'Selection');
  assert.equal(source.documentRequest.startUtf16,19,'one bounded latest request, no document queue/history');
  const oldPreview=f.callbacks.get('setPreviewText'),oldSelection=f.callbacks.get('selectByRange');
  field.aboutToDisappear();await flush();assert.equal(source.documentRequest,undefined);
  const current=f.create('field');await flush();f.calls.length=0;
  oldPreview('旧',{start:0,end:1});oldSelection({start:0,end:1});
  assert.equal(f.calls.length,0);assert.equal(current.documentMessage,'');
  current.aboutToDisappear();await flush();
  console.log('PASS document replacement/selection preserve original Range and scope; explicit bounded unsupported projection, no echo document');
}

/** 两个旧错域动作撤回后都真实转译并触达Native边缘，不能以无调用的新分支冒充负控。 */
{
  const wrongReplacement=fixture({sourceOverrides:{[RUNTIME]:source=>{
    const needle='if (accepted) operation.source.preview = value';assert.ok(source.includes(needle));
    return source.replace(needle,needle+`\n    if (accepted) { const start = this.scalarIndex(operation.source.echo, range.start), end = this.scalarIndex(operation.source.echo, range.end)
      if (start >= 0 && end >= start) getEntryTextInputSession().selection(operation.lease, start, end - start) }`);
  }}});wrongReplacement.runtime.start();const field=wrongReplacement.create('field');await flush();
  wrongReplacement.callbacks.get('insertText')('ab');wrongReplacement.calls.length=0;
  wrongReplacement.callbacks.get('setPreviewText')('XYZ',{start:0,end:1});
  assert.deepEqual(wrongReplacement.calls.filter(x=>x.kind==='preview'||x.kind==='selection').map(x=>x.kind),['preview','selection']);
  assert.throws(()=>assert.equal(wrongReplacement.calls.some(x=>x.kind==='selection'),false));
  field.aboutToDisappear();await flush();
  const wrongSelection=fixture({sourceOverrides:{[RUNTIME]:source=>{
    const needle="const request = this.documentRequest(operation, 'Selection', range, '')\n    if (request === undefined || !this.accepts(operation)) return\n    operation.source.documentRequest = request";assert.ok(source.includes(needle));
    return source.replace(needle,needle+`\n    const start = this.scalarIndex(operation.source.echo, range.start), end = this.scalarIndex(operation.source.echo, range.end)
    if (start >= 0 && end >= start) getEntryTextInputSession().selection(operation.lease, start, end - start)`);
  }}});wrongSelection.runtime.start();const selected=wrongSelection.create('field');await flush();
  wrongSelection.callbacks.get('insertText')('ab');wrongSelection.calls.length=0;
  wrongSelection.callbacks.get('selectByRange')({start:0,end:1});assert.equal(wrongSelection.calls.filter(x=>x.kind==='selection').length,1);
  assert.throws(()=>assert.equal(wrongSelection.calls.some(x=>x.kind==='selection'),false));
  selected.aboutToDisappear();await flush();
  console.log('PASS compiled original domain negatives actually reintroduce Native selection for replacement and document selection');
}

/** Unknown/回入退休仍只有原预编辑副作用；范围提示不可借新Native文字代次或新activation。 */
{
  for(const outcome of ['false','throw','retire']) {
    const f=fixture();f.runtime.start();const field=f.create('field');await flush();
    const method=f.napi.updateTextInputEditing;
    f.napi.updateTextInputEditing=(...args)=>{method(...args);if(outcome==='retire'){field.aboutToDisappear();return true;}
      if(outcome==='throw'){f.state.epoch='2';f.state.nativeGeneration=0;throw new Error('unknown accepted preview');}return false;};
    f.calls.length=0;f.callbacks.get('setPreviewText')('新',{start:0,end:0});
    assert.equal(f.calls.filter(x=>x.kind==='preview').length,1);
    assert.equal(f.calls.some(x=>x.kind==='selection'||x.kind==='commit'||x.kind==='legacy'),false);
    if(outcome!=='retire')field.aboutToDisappear();await flush();
  }
  const f=fixture();f.runtime.start();const field=f.create('field');await flush();
  f.callbacks.get('setPreviewText')('原',{start:0,end:0});assert.match(field.documentMessage,/暂不支持替换/);
  f.state.epoch='2';f.state.nativeGeneration=0;f.runtime.maintain();assert.equal(field.documentMessage,'');
  const source=f.runtime.sources.get(field.binding.id);assert.equal(source.documentRequest,undefined);
  field.visible=false;field.onVisibleChange();await flush();field.visible=true;field.onVisibleChange();await flush();
  assert.equal(field.documentMessage,'');field.aboutToDisappear();await flush();
  console.log('PASS document result remains scoped through unknown preview, synchronous retirement, Native reset and activation replacement');
}

/** 原Range每字段只读取一次；同一捕获值用于数值检查与只读意图，不被后来getter值替换。 */
{
  for(const kind of ['Replacement','Selection']) {
    const f=fixture();f.runtime.start();const field=f.create('field');await flush();let starts=0,ends=0;
    const range={get start(){starts++;return starts===1?0:99;},get end(){ends++;return ends===1?1:100;}};
    if(kind==='Replacement')f.callbacks.get('setPreviewText')('XYZ',range);else f.callbacks.get('selectByRange')(range);
    const request=f.runtime.sources.get(field.binding.id).documentRequest;
    assert.deepEqual([starts,ends],[1,1]);assert.deepEqual([request.startUtf16,request.endUtf16],[0,1]);
    assert.equal(request.kind,kind);assert.equal(request.outcome,'Document'+kind+'Unsupported');
    field.aboutToDisappear();await flush();
  }
  const repeated=fixture({sourceOverrides:{[RUNTIME]:source=>{
    const needle='startUtf16, endUtf16, replacementText, outcome)';assert.ok(source.includes(needle));
    return source.replace(needle,'range.start, range.end, replacementText, outcome)');
  }}});repeated.runtime.start();const field=repeated.create('field');await flush();let starts=0,ends=0;
  const range={get start(){return ++starts===1?0:99;},get end(){return ++ends===1?1:100;}};
  repeated.callbacks.get('setPreviewText')('XYZ',range);
  const request=repeated.runtime.sources.get(field.binding.id).documentRequest;
  assert.deepEqual([starts,ends],[2,2]);assert.deepEqual([request.startUtf16,request.endUtf16],[99,100]);
  assert.throws(()=>assert.deepEqual([request.startUtf16,request.endUtf16],[0,1]),'compiled repeated-getter negative corrupts original Range');
  field.aboutToDisappear();await flush();
  console.log('PASS original Range values captured once; compiled re-read negative changes actual request coordinates');
}

/** getter取值时原资源退出/重开，仍执行真实unbind/detach串行机；旧回调不续读或写Native。 */
{
  for(const kind of ['Replacement','Selection'])for(const edge of ['start','end']) {
    const f=fixture();f.runtime.start();const field=f.create('field');await flush();f.state.delayDetach=true;
    const oldSource=f.runtime.sources.get(field.binding.id),originalOperation=f.runtime.operation;let current,starts=0,ends=0;
    const retire=()=>{field.aboutToDisappear();current=f.create('field');};
    const range={get start(){starts++;if(edge==='start')retire();return 0;},get end(){ends++;if(edge==='end')retire();return 1;}};
    f.calls.length=0;if(kind==='Replacement')f.callbacks.get('setPreviewText')('旧',range);else f.callbacks.get('selectByRange')(range);
    assert.equal(originalOperation.retired,true);assert.equal(oldSource.documentRequest,undefined);
    assert.equal(f.calls.some(x=>['preview','selection','commit','key','legacy'].includes(x.kind)),false);
    assert.equal(starts,1);assert.equal(ends,edge==='start'?0:1,'retired first getter cannot authorize second getter');
    assert.equal(current.documentMessage,'');await flush();for(const pending of f.pendingDetach)pending.resolve();await flush();
    const newSource=f.runtime.sources.get(current.binding.id);assert.equal(newSource.documentRequest,undefined);
    current.aboutToDisappear();await flush();for(const pending of f.pendingDetach)pending.resolve();await flush();
  }
  console.log('PASS Range getter retirement/reopen fences the original operation before every later read/write/Native effect');
}

/** 构造返回边缘同步退休须由caller再核；撤回这层后真实旧source被写回且预编辑跨退休发出。 */
{
  function afterRequest(kind,withdraw) {
    const sourceOverrides=withdraw?{[RUNTIME]:source=>{
      const needle='if (request === undefined || !this.accepts(operation)) return';assert.equal(source.split(needle).length-1,2);
      return source.replaceAll(needle,'if (request === undefined) return');
    }}:undefined;
    const f=fixture({sourceOverrides});f.runtime.start();return flush().then(()=>{
      const field=f.create('field');return flush().then(()=>{
        f.state.delayDetach=true;const oldSource=f.runtime.sources.get(field.binding.id),make=f.runtime.documentRequest.bind(f.runtime);let current;
        f.runtime.documentRequest=(...args)=>{const request=make(...args);field.aboutToDisappear();current=f.create('field');return request;};
        f.calls.length=0;if(kind==='Replacement')f.callbacks.get('setPreviewText')('旧',{start:0,end:1});else f.callbacks.get('selectByRange')({start:0,end:1});
        return {f,oldSource,current};
      });
    });
  }
  for(const kind of ['Replacement','Selection'])for(const withdraw of [false,true]) {
    const {f,oldSource,current}=await afterRequest(kind,withdraw);
    if(!withdraw){assert.equal(oldSource.documentRequest,undefined);assert.equal(f.calls.some(x=>x.kind==='preview'||x.kind==='selection'),false);}
    else{
      assert.notEqual(oldSource.documentRequest,undefined);assert.throws(()=>assert.equal(oldSource.documentRequest,undefined));
      assert.equal(f.calls.filter(x=>x.kind==='preview').length,kind==='Replacement'?1:0,'compiled withdrawal reaches real Native preview after retirement');
    }
    assert.equal(current.documentMessage,'');await flush();for(const pending of f.pendingDetach)pending.resolve();await flush();
    current.aboutToDisappear();await flush();for(const pending of f.pendingDetach)pending.resolve();await flush();
  }
  console.log('PASS request construction return edge checks original operation; compiled withdrawal writes retired source/Native preview');
}

console.log('ENTRY_TEXT_INPUT_RUNTIME_PASS complete production non-UI components/runtime/Coordinator; platform and Host assembly only injected');
