/** 两轮审查的生产装配回归：平台边界替身、真实Store/Runtime/Manager/IME类及负向变异。 */
import assert from 'node:assert/strict';
import { environment } from './lib/ets-runtime-fixture.mjs';
const noop=()=>{};
const flush=async()=>{for(let i=0;i<12;i++)await Promise.resolve();};
let checks=0;
function passed(name){checks++;console.log('PASS '+name);}
function configuration(mutation=''){
  const overrides={};
  if(mutation==='retry')overrides['gamecontrol/src/main/ets/InputConfigurationRuntime.ets']=s=>s.replace('    store.reconcileInputConfiguration()','');
  const env=environment({sourceOverrides:overrides});
  const layout=env.load('gamecontrol/src/main/ets/ControlLayout.ets');
  const model=env.load('gamecontrol/src/main/ets/InputConfiguration.ets');
  const {LayoutStore}=env.load('gamecontrol/src/main/ets/LayoutStore.ets');
  const {setControlNativeSink}=env.load('gamecontrol/src/main/ets/InputConfigurationNativePort.ets');
  const {InputConfigurationRuntime}=env.load('gamecontrol/src/main/ets/InputConfigurationRuntime.ets');
  const profile=layout.getDefaultLayout();
  const store=new LayoutStore();store.profiles=[profile];store.activeName=profile.name;store._ready=true;
  let reject=false,effective;let attempts=0;
  setControlNativeSink({applyLookConfiguration:c=>{attempts++;if(reject)return false;effective={...c};return true;}});
  const configurationRuntime=new InputConfigurationRuntime();configurationRuntime.start(store);
  const before=model.touchBehaviorKey(profile);
  profile.controls[0].label+='new';profile.controls[0].style={bg:'#abcdef'};
  assert.equal(model.touchBehaviorKey(profile),before);store.publishInputConfiguration();
  const baseline={...effective};reject=true;profile.lookSensitivity=2;profile.invertY=true;
  store.publishInputConfiguration();assert.deepEqual(effective,baseline);
  assert.ok(store.inputConfigurationStatus().find(s=>s.name==='native-look').pending);
  reject=false;const attemptsBefore=attempts;configurationRuntime.reconcile();
  assert.equal(effective.sensitivity,2,'runtime must retry pending configuration');assert.equal(effective.invertY,true);
  assert.ok(attempts>attemptsBefore);assert.equal(store.inputConfigurationStatus().find(s=>s.name==='native-look').pending,false);
  const appliedAttempts=attempts;configurationRuntime.reconcile();assert.equal(attempts,appliedAttempts,'successful domain must not repeat');
  configurationRuntime.stop();
}
configuration();assert.throws(()=>configuration('retry'),/runtime must retry/);
passed('configuration semantic domains, desired/applied receipt and retry; retry mutation rejected');

async function preview(component,api,mutate=false){
  const listeners=new Map();let attached=false,previewSupported=false,nativeSession=0;
  const ordinary=new Set(['insertText','deleteLeft','deleteRight','sendFunctionKey','getLeftTextOfCursor','getRightTextOfCursor','getTextIndexAtCursor']);
  const attach=async()=>{previewSupported=listeners.has('setPreviewText')&&listeners.has('finishTextPreview');attached=true;};
  const controller={attach,attachWithUIContext:attach,detach:async()=>{attached=false;},hideTextInput:async()=>{},showTextInput:async()=>{},
    on:(name,fn)=>{if(ordinary.has(name)&&!attached)throw Error('requires attach');listeners.set(name,fn);},
    off:(name)=>{listeners.delete(name);if(attached&&(name==='setPreviewText'||name==='finishTextPreview'))previewSupported=false;}};
  const inputMethod={getController:()=>controller,TextInputType:{TEXT:0},EnterKeyType:{NEWLINE:0,DONE:1,SEND:2},RequestKeyboardReason:{NONE:0,TOUCH:1}};
  const napi={textInputSessionSupported:()=>true,getInputResetEpoch:()=>'1',beginTextInputSession:g=>{nativeSession=g;return true;},
    endTextInputSession:()=>true,abortTextInputSession:noop,commitTextInput:g=>g===nativeSession,updateTextInputEditing:()=>true,updateTextInputSelection:()=>true};
  const relative='entry/src/main/ets/components/'+component+'.ets';
  const runtimePath='entry/src/main/ets/runtime/EntryTextInputRuntime.ets';let runtime;
  // 只替换Host持有对象的装配边缘；实际组件和同一生产runtime/Coordinator都完整执行。
  const env=environment({imports:{'@ohos.deviceInfo':{default:{sdkApiVersion:api}},'@kit.IMEKit':{inputMethod},'libentry.so':{default:napi},
    '../runtime/GameSessionHost':{getGameSessionHost:()=>({textInputRuntime:runtime})}},
    sourceOverrides:mutate?{[runtimePath]:s=>s.replace("controller.on('setPreviewText', operation.preview);", '')}:{}});
  const {EntryTextInputRuntime}=env.load(runtimePath);runtime=new EntryTextInputRuntime();runtime.start();
  const Subject=env.load(relative,true)[component];const subject=new Subject();
  subject.active=true;subject.visible=true;subject.mode='field';subject.onClose=noop;subject.getUIContext=()=>({px2vp:v=>v});
  subject.aboutToAppear();await flush();assert.equal(runtime.snapshot().controllerPhase,'Attached');assert.equal(previewSupported,true,'preview capability must survive attach and ordinary registration');
  subject.aboutToDisappear();await flush();
}
for(const name of ['DesktopPhysicalTextInput','ChatInputBridge']){
  for(const api of [22,23,26])await preview(name,api);
  await assert.rejects(()=>preview(name,26,true),/preview capability/);
}
passed('both IME clients: preview before attach, ordinary callbacks after attach, capability not revoked; missing preview mutation rejected');
// source client与manager执行真实代码：边界只分配token及记录提交，不在替身内重新做输出聚合。
{
  const env=environment();const {InputSessionCoordinator}=env.load('gamecontrol/src/main/ets/InputSessionCoordinator.ets');
  const calls=[];let rejectGamepad=true;
  const coordinator=new InputSessionCoordinator({resetSource:source=>{calls.push(source);return source!==2||!rejectGamepad;},resetText:()=>{calls.push('text');return true;}});
  assert.equal(coordinator.reconcile('IRS1:1:1:1:1:1'),true);assert.deepEqual(calls,[]);
  coordinator.reconcile('IRS1:2:1:1:2:2');assert.deepEqual(calls,[3,'text'],'typed reset preserves touch/gamepad caches');calls.length=0;
  assert.equal(coordinator.reconcile('IRS1:4:2:2:2:2'),false);assert.deepEqual(calls,[1,2],'two missed domain resets are both observed');calls.length=0;
  rejectGamepad=false;assert.equal(coordinator.reconcile('IRS1:4:2:2:2:2'),true);assert.deepEqual(calls,[2],'only unacknowledged domain retries');calls.length=0;
  assert.equal(coordinator.reconcile('IRS2:4:2:2:2:2'),false);assert.deepEqual(calls,[]);
  passed('session coordinator: per-domain cumulative epochs, source isolation, failed-domain retry, unknown protocol rejected');
}
console.log('input architecture regressions: '+checks+' groups passed');
