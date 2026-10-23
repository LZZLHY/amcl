/** 真实Entry/Model→真实Native回执的组合轨迹；不在假port里实现prefix或owner判定。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {makePureEtsLoader} from '../../lib/load-pure-ets.mjs';
const arg=name=>{const index=process.argv.indexOf(name);return index<0?'':process.argv[index+1];};
const binary=arg('--native'),out=arg('--out'),old=arg('--old-entry');
assert.ok(binary&&out,'explicit external Native binary and evidence path required');
const pure=makePureEtsLoader();
const {VirtualMouseModel}=pure('gamecontrol/src/main/ets/VirtualMouseModel.ets');
const {runtimeTouchContext}=pure('gamecontrol/src/main/ets/RuntimeTouchLayout.ets');
const surfaceModule=pure('gamecontrol/src/main/ets/InputSurfaceContext.ets');
const surface=new surfaceModule.InputSurfaceContext();
surface.generation=7;surface.windowId=1;surface.displayId=0;surface.widthPx=1000;surface.heightPx=1000;
surface.density=1;surface.transform=0;surface.provisional=false;
surface.validFields=surfaceModule.INPUT_SURFACE_FIELD_RECT|surfaceModule.INPUT_SURFACE_FIELD_DENSITY|
 surfaceModule.INPUT_SURFACE_FIELD_WINDOW|surfaceModule.INPUT_SURFACE_FIELD_DISPLAY|surfaceModule.INPUT_SURFACE_FIELD_TRANSFORM;
const context=runtimeTouchContext(surface,1000,1000,1),geometry=[10,20,152,208];assert.equal(context.valid,true);
let history=[],receipts=[];
function call(command,...args){
 const record=[command,...args.map(String)].join(' ');history.push(record);
 // 同一历史每次从同一初态完整重放，最后布尔值是本次真实Native函数返回，不是模型猜测。
 const run=spawnSync(binary,[],{input:history.join('\n')+'\n',encoding:'utf8'});
 assert.equal(run.status,0,run.stdout+run.stderr);
 const result=JSON.parse(run.stdout.trim().split(/\r?\n/).at(-1));receipts.push({call:record,result});return result;
}
const native={setTouchMenuMouseBounds:(...args)=>call('bounds',...args).ok,
 moveTouchMenuPointer:(...args)=>call('move',...args).ok,touchMenuScroll:(...args)=>call('wheel',...args).ok,
 touchMenuButton:(owner,code,down,token)=>call('button',owner,code,down?1:0,token).ok,
 cancelTouchMenuMouse:prefix=>call('cancel',prefix).ok};
const overrides=old?{'entry/src/main/ets/components/EntryVirtualMouse.ets':fs.readFileSync(old,'utf8')}:{};
const {EntryVirtualMouse}=makePureEtsLoader({commons:{AppLogger:{warn(){}}},gamecontrol:{VirtualMouseModel},'libentry.so':{__esModule:true,default:native}},overrides)
 ('entry/src/main/ets/components/EntryVirtualMouse.ets');
const cases=[];
function move(entry){entry.model.startPad(1,0,0);const accepted=entry.model.movePad(1,5,6);entry.model.endPad(1);return accepted;}
function setup(){history=[];receipts=[];const entry=new EntryVirtualMouse();entry.setRuntimeContext(context,'2');entry.configure(true,1);
 entry.bounds(...geometry);assert.equal(receipts.at(-1).result.ok,true);return entry;}
{
 const entry=setup();assert.equal(move(entry),true);assert.equal(entry.model.press('held',-1,true),true);
 const before=receipts.at(-1).result,reset=call('source-reset');assert.equal(reset.prefix,'');assert.equal(reset.token,2);assert.equal(reset.accepts,true);
 for(const field of ['surface','session','schema','policy','grabEpoch'])assert.equal(reset[field],before[field]);
 entry.model.acknowledgeReset();const beforeBounds=history.filter(value=>value.startsWith('bounds ')).length;
 entry.setRuntimeContext(context,'2');entry.configure(true,1);entry.bounds(...geometry);
 const afterBounds=history.filter(value=>value.startsWith('bounds ')).length;
 // 两个真实Native接受态都先取得再断言，旧代码反控不能在执行拒绝路径之前结束。
 const moveAccepted=move(entry),downAccepted=entry.model.press('after',-1,true);
 const probe={before,reset,beforeBounds,afterBounds,moveAccepted,downAccepted,trace:receipts};
 fs.writeFileSync(path.join(out,old?'negative-probe.json':'positive-probe.json'),JSON.stringify(probe,null,2)+'\n');
 assert.equal(afterBounds,beforeBounds+1,'REGISTRATION_RESET_REBIND: same geometry must confirm actual Native registration');
 assert.equal(moveAccepted,true,'REGISTRATION_RESET_REBIND: actual Native MOVE');
 assert.equal(downAccepted,true,'REGISTRATION_RESET_REBIND: actual Native DOWN');
 cases.push({name:'source reset with identical context/token/geometry re-registers',...probe});
}
{
 // Native按端复位已经撤销登记时，关闭仍须取得明确幂等回执，之后页面同步应保持安静。
 const entry=setup();const reset=call('source-reset');entry.model.acknowledgeReset();
 entry.configure(false,1);entry.bounds(0,0,0,0);
 assert.equal(receipts.at(-1).result.ok,true,'RESET_CLOSE_ACK: retired registration must acknowledge clear');
 assert.equal(receipts.at(-1).result.toolEpoch,reset.toolEpoch,'空登记不再次推进工具代次');
 const settled=history.length;
 for(let i=0;i<240;i++){entry.configure(false,1);entry.bounds(0,0,0,0);}
 assert.equal(history.length,settled,'已确认关闭不能继续调用Native取消/注销');
 entry.configure(true,1);entry.bounds(...geometry);assert.equal(move(entry),true);
 cases.push({name:'close after Native reset acknowledges once and reopens',trace:receipts});
}
{
 const entry=setup();assert.equal(entry.model.press('held',-1,true),true);const held=receipts.at(-1).result;
 for(let i=0;i<3;i++){entry.bounds(...geometry);const confirmed=receipts.at(-1).result;
  assert.equal(confirmed.ok,true);assert.equal(confirmed.prefix,held.prefix);assert.equal(confirmed.toolLive,1);
  assert.equal(confirmed.menuEpoch,held.menuEpoch);assert.equal(confirmed.toolEpoch,held.toolEpoch);assert.equal(move(entry),true);}
 entry.model.press('held',-1,false);assert.equal(receipts.at(-1).result.toolLive,0);
 cases.push({name:'same geometry confirmations preserve held source and tool epoch',trace:receipts});
}
{
 const entry=setup();assert.equal(entry.model.press('held',-1,true),true);entry.configure(false,1);
 const cancelled=receipts.at(-1).result;assert.notEqual(cancelled.prefix,'');assert.equal(cancelled.toolLive,0);
 entry.configure(true,1);entry.bounds(...geometry);assert.equal(receipts.at(-1).result.toolEpoch,cancelled.toolEpoch);
 assert.equal(move(entry),true);assert.equal(entry.model.press('new',-1,true),true);
 cases.push({name:'tool-only cancellation preserves registration and direct scope',cancelled,trace:receipts});
}
{
 const entry=setup();call('source-reset');entry.model.acknowledgeReset();const changed=call('new-context');
 assert.equal(changed.accepts,true);assert.notEqual(changed.token,2);
 // 实际UI几何key没有Native touch session；真实新UI token仍使重新注册取得正确域。
 entry.setRuntimeContext(context,String(changed.token));entry.bounds(...geometry);
 assert.equal(receipts.at(-1).result.ok,true);assert.equal(move(entry),true);assert.equal(entry.model.press('new-context',-1,true),true);
 entry.release();assert.equal(receipts.at(-1).result.prefix,'');
 cases.push({name:'new publication and explicit close preserve scoped identity',changed,trace:receipts});
}
fs.writeFileSync(path.join(out,'positive-cases.json'),JSON.stringify({recordedAt:new Date().toISOString(),runtimeContext:context,cases},null,2)+'\n');
console.log('PASS actual Entry/Model/Native: identical geometry rebinds after source reset; repeated confirmations preserve held/tool epoch; cancel/new publication/close remain scoped');
