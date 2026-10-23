/**
 * 实际前端入口的退休反例：新前端接管同局后，旧页面事件不得借稳定来源发出新输入。
 * 提取生产方法而不重写路由，故意不给其它页面/Native字段；越过资格门即直接失败。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
const relative='entry/src/main/ets/pages/McGamePage.ets';
const source=fs.readFileSync(new URL('../'+relative,import.meta.url),'utf8');
const ast=compiler.createSourceFile(relative,source,compiler.ScriptTarget.Latest,true);
const owner=ast.statements.find(n=>n.members?.some(m=>m.name?.getText(ast)==='handleKeyEvent'));
const names=['handleKeyEvent','handleMouseEvent','onBackPress','onWheelPanStart','onWheelPanUpdate',
  'handleAxisEvent','handleFocusAxisEvent','receiveDesktopDrop','publishInitialDeviceInventory'];
const methods=[...names,'readDeviceDescriptor'].map(name=>{const member=owner.members.find(m=>m.name?.getText(ast)===name);
  assert.ok(member,name);return member.getText(ast);}).join('\n');
const compiled=compiler.transpileModule('class Page {\n'+methods+'\n}\nreturn Page;',
  {compilerOptions:{target:compiler.ScriptTarget.ES2020},reportDiagnostics:true});
assert.equal((compiled.diagnostics??[]).filter(item=>item.category===compiler.DiagnosticCategory.Error).length,0,
  '实际页面方法必须成功转译，不能把语法失败算退休反例');
const js=compiled.outputText;
// 原页面方法与真实纯ABI/库存guard；仅SDK与Host准入、Native发布是显式平台边缘。
const abi=makePureEtsLoader()('gamecontrol/src/main/ets/InputDeviceAbi.ets');
const inventory=makePureEtsLoader()('gamecontrol/src/main/ets/InputDeviceLifecycleCoordinator.ets');
let finishDrop,finishInventory;
let detailHook=()=>{};
const effects=[];
const Page=new Function('DesktopFileDrop','ProductInputProfile','testNapi','inputDevice','normalizeDeviceId','InputDeviceDescriptor','deviceCapabilityBitsFromSources','pointerDeviceClassFromSources','TAG','LOG_DOMAIN_LAUNCH',js)(
  {stage:()=>new Promise(resolve=>{finishDrop=resolve;}),discard:(_context,paths)=>effects.push(['discard',paths])},
  {selection:()=>({desktopWindow:true})},
  {desktopPublishDrop:paths=>{effects.push(['publish-drop',paths]);return true;},publishInputDeviceChange:(...values)=>effects.push(['device',...values])},
  {getDeviceList:()=>new Promise(resolve=>{finishInventory=resolve;}),
    getDeviceInfoSync:()=>{detailHook();return {sources:['mouse']};}},
  abi.normalizeDeviceId,abi.InputDeviceDescriptor,abi.deviceCapabilityBitsFromSources,abi.pointerDeviceClassFromSources,'page-lease',1);
console.log('PASS actual Page methods transpile and Function construction, including real readDeviceDescriptor');
const page=new Page(),oldLease={id:1},newLease={id:2};
page.frontendLease=oldLease;
page.sessionHost={accepts:lease=>lease===newLease};
for(const name of names.filter(name=>name!=='publishInitialDeviceInventory')) {
  await assert.doesNotReject(async()=>page[name]({}),name+' must reject retired origin');
}
console.log('PASS actual page event ingress: eight retired frontend routes cannot borrow current session/window');

// 同一页面在await期间也可能重新attach；不能用更新后的this.frontendLease补合法化旧结果。
let current=oldLease;
page.frontendLease=oldLease;page.sessionHost={accepts:lease=>lease===current};page.inputLifecycleEpoch=1;
page.context={};page.navigatedAway=false;page.launchLogger_=()=>({warn(){}});
page.getUIContext=()=>{throw Error('retired notice cannot access UI');};
const drop=page.receiveDesktopDrop({getData:()=>({})});
current=newLease;page.frontendLease=newLease;finishDrop(['/staged/old']);await drop;
assert.deepEqual(effects,[['discard',['/staged/old']]],'旧拖放只撤回自身staging，不向新窗口发布');
effects.length=0;current=oldLease;page.frontendLease=oldLease;page.mcStarted=true;
page.deviceInventoryGuard={beginInventory:()=>1,mayPublishAdded:()=>true};
page.readDeviceDescriptor=()=>{effects.push(['descriptor']);return {capabilities:1,deviceClass:1};};
page.publishInitialDeviceInventory();current=newLease;page.frontendLease=newLease;
finishInventory([42]);for(let i=0;i<5;i++)await Promise.resolve();
assert.deepEqual(effects,[],'旧异步inventory不能借重绑定后的前端发布ADDED');
console.log('PASS actual async page ingress: drop/inventory capture origin across same-page reattach');

/**
 * 条件性Source防御门：在SDK详情边缘同步退休一个资格，再返回普通sources。
 * 真实readDeviceDescriptor、两项ABI映射与库存guard全部执行；不把这种受控边缘
 * 冒称商业OHOS已发生回入，也不替Native实现owner/传输算法。断言在生产catch之外。
 */
const inventoryCases=['normal','epoch','frontend','not-running','removed','detail-throw'];
const selectedInventoryCase=process.env.AMCL_PAGE_INVENTORY_CASE;
assert.ok(selectedInventoryCase===undefined || inventoryCases.includes(selectedInventoryCase),'合法库存用例选择');
for(const kind of inventoryCases.filter(value=>selectedInventoryCase===undefined || value===selectedInventoryCase)) {
  effects.length=0;
  const subject=new Page(),original={id:11},replacement={id:12};let accepted=original,details=0;
  Object.assign(subject,{frontendLease:original,sessionHost:{accepts:lease=>lease===accepted},
    inputLifecycleEpoch:7,mcStarted:true,
    inputProduct:{supportsRelativeMouse:true,supportsCursorLock:true},
    deviceInventoryGuard:new inventory.DeviceInventoryPublicationGuard(),launchLogger_:()=>({warn(){}})});
  detailHook=()=>{
    details++;
    // 三个资格各自单独变化，另两项保持原合法状态，防反控被兄弟guard遮住。
    if(kind==='epoch') subject.inputLifecycleEpoch++;
    else if(kind==='frontend') {accepted=replacement;subject.frontendLease=replacement;}
    else if(kind==='not-running') subject.mcStarted=false;
    else if(kind==='removed') subject.deviceInventoryGuard.noteRealtimeChange(42,false);
    else if(kind==='detail-throw') throw Error('controlled detail unavailable');
  };
  subject.publishInitialDeviceInventory();finishInventory([42]);
  for(let tick=0;tick<5;tick++) await Promise.resolve();
  assert.equal(details,1,'真实readDeviceDescriptor应抵达唯一SDK详情边缘');
  if(kind==='normal') assert.deepEqual(effects,[['device',42,true,
    abi.deviceCapabilityBitsFromSources(['mouse'],true,true),abi.InputDeviceClass.Mouse]],'真实正常库存继续发布ADDED');
  else assert.deepEqual(effects,[],'INVENTORY_DETAIL_'+kind+' 详情返回后不得借后来资格发布');
  console.log('PASS actual inventory detail edge '+kind+'; native publications='+effects.length);
}
detailHook=()=>{};


/** 执行真实页面报告方法与真实中文政策函数；只替换原Host的只读依赖边缘。 */
const plan=makePureEtsLoader()('launch/src/main/ets/ResolvedInputPlan.ets');
const policy=makePureEtsLoader({launch:plan})('entry/src/main/ets/runtime/NativeGamepadRoutePolicy.ets');
const routeMethod=owner.members.find(member=>member.name?.getText(ast)==='refreshNativeGamepadRouteStatus_');
assert.ok(routeMethod);
const currentWire='v=v1;abi=GLFW;slot=LWJGL3;window=GLFW;binding=libglfw.so;policy=glfw-present-2';
function pageRouteReader(overrides=undefined){
  const body=overrides??routeMethod.getText(ast);
  const js=compiler.transpileModule('class RoutePage {\n'+body+'\n}\nreturn RoutePage;',
    {compilerOptions:{target:compiler.ScriptTarget.ES2020},reportDiagnostics:true});
  assert.equal((js.diagnostics??[]).filter(item=>item.category===compiler.DiagnosticCategory.Error).length,0);
  const Subject=new Function('nativeGamepadRouteStatusMessage',js.outputText)(policy.nativeGamepadRouteStatusMessage);
  const p=new Subject(), first={id:1}, next={id:2};let current=first, reads=0, onRead=()=>{};
  const host={accepts:lease=>lease===current,
    nativeGamepadRouteForFrontend:lease=>{if(lease!==current)return undefined;reads++;onRead();
      return policy.resolveNativeGamepadRoute(true,true,currentWire,policy.GamepadOutputRoute.Native);}};
  Object.assign(p,{sessionHost:host,frontendLease:first,inputLifecycleEpoch:7,nativeGamepadRouteMessage:''});
  p.refreshNativeGamepadRouteStatus_(host,first,7);
  assert.match(p.nativeGamepadRouteMessage,/本局已启用原生手柄路线/);
  current=next;p.frontendLease=next;p.nativeGamepadRouteMessage='后来前端的报告';
  const before=reads;p.refreshNativeGamepadRouteStatus_(host,first,7);
  assert.equal(reads,before);assert.equal(p.nativeGamepadRouteMessage,'后来前端的报告','ROUTE_PAGE_OLD_SCOPE 旧观察不可清新提示');
  p.refreshNativeGamepadRouteStatus_({},next,7);p.refreshNativeGamepadRouteStatus_(host,next,6);
  assert.equal(reads,before,'原host和页面代共同检查');
  onRead=()=>{p.sessionHost={accepts:()=>true};p.nativeGamepadRouteMessage='新会话的报告';};
  p.refreshNativeGamepadRouteStatus_(host,next,7);
  assert.equal(p.nativeGamepadRouteMessage,'新会话的报告','ROUTE_PAGE_REENTRY 读回不能覆盖后来会话');
  p.sessionHost=host;onRead=()=>{throw Error('status boundary unavailable');};
  p.refreshNativeGamepadRouteStatus_(host,next,7);assert.match(p.nativeGamepadRouteMessage,/状态暂不可用.*等待确认/);
  return body;
}
const reportBody=pageRouteReader();
// 两个原资格检查共同保护旧读回；只撤一处仍受另一处保护，必须保真实反控强度。
const guard='if (this.sessionHost!==host || this.frontendLease!==frontend || this.inputLifecycleEpoch!==epoch || !host.accepts(frontend)) return';
assert.equal(reportBody.split(guard).length,3);
assert.throws(()=>pageRouteReader(reportBody.replaceAll(guard,'')),
  error=>error instanceof assert.AssertionError&&error.message.includes('ROUTE_PAGE_OLD_SCOPE'));
console.log('PASS real Page route reader: original host/lease/epoch, stale scope, synchronous new session, unknown read and compiled withdrawal');
