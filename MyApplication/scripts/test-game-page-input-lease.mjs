/**
 * 实际前端入口的退休反例：新前端接管同局后，旧页面事件不得借稳定来源发出新输入。
 * 提取生产方法而不重写路由，故意不给其它页面/Native字段；越过资格门即直接失败。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { environment } from './lib/ets-runtime-fixture.mjs';
const relative='entry/src/main/ets/pages/McGamePage.ets';
const source=fs.readFileSync(new URL('../'+relative,import.meta.url),'utf8');
const ast=compiler.createSourceFile(relative,source,compiler.ScriptTarget.Latest,true);
const owner=ast.statements.find(n=>n.members?.some(m=>m.name?.getText(ast)==='handleKeyEvent'));
const names=['handleKeyEvent','handleMouseEvent','onBackPress','onWheelPanStart','onWheelPanUpdate',
  'handleAxisEvent','handleFocusAxisEvent','receiveDesktopDrop','publishInitialDeviceInventory'];
const methods=[...names,'readDeviceDescriptor','retireDesktopHeldKeys','rearmDesktopKeyRetirements','queueDesktopKeyRetirement',
  'desktopRetirementIndex','flushDesktopKeyRetirements','desktopUpConfirmed','tryRetireDesktopKey',
  'resolveDesktopRetirementsBeforeDown'].map(name=>{const member=owner.members.find(m=>m.name?.getText(ast)===name);
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

// 真实窗口轴入口与映射运行时一起执行。仅记录在原生路线本应完全避开的平台读取、
// reset 对账及输出端口，确认被拒绝的旧 RELEASE 仍允许当前映射接收轴。
{
  const env = environment();
  const load = name => env.load('gamecontrol/src/main/ets/' + name + '.ets');
  const { InputDeviceConnectionRegistry, InputDeviceIdentityEvidence } = load('InputDeviceConnectionLease');
  const { GamepadManager, AXIS_ABS_Y } = load('GamepadManager');
  const { GameInputRuntime } = load('GameInputRuntime');
  const connections = new InputDeviceConnectionRegistry();
  connections.observeAdd(7);
  let lookups = 0, axisReads = 0, resets = 0, cleanup = 0, allowRelease = false;
  const output = [];
  const gamepad = new GamepadManager(undefined, {
    lookExecutionMode: 'neutral-rate-v1',
    emitControlForConnection: (_connection, _control, code, action) => {
      if (action === 0 && !allowRelease) return false;
      output.push([code, action]); return true;
    },
    reconcileConnectionControls: () => { cleanup++; return true; }
  }, connections.reader);
  const runtime = new GameInputRuntime(gamepad, () => 0, () => {}, () => { resets++; });
  const monitor = { captureConnection: (id, known, compat) => {
    lookups++;
    return connections.capture(new InputDeviceIdentityEvidence(id, known, compat));
  } };
  const AxisPage = new Function('getInputDeviceMonitor', 'TAG', 'LOG_DOMAIN_LAUNCH', js)(() => monitor, 'axes', 1);
  const subject = new AxisPage();
  let frontend = oldLease;
  Object.assign(subject, { frontendLease: oldLease, mcStarted: true, gamepad, inputRuntime: runtime,
    sessionHost: { accepts: lease => lease === frontend }, probeAxisDeviceIdentity: () => {},
    launchLogger_: () => ({ warn: (_tag, _message, error) => { throw error; } }) });
  const event = { deviceId: 7, axisMap: { get: axis => { axisReads++; return axis === AXIS_ABS_Y ? -1 : 0; } } };
  const sample = () => subject.handleFocusAxisEvent(event);
  runtime.setState(true, true);
  sample();
  assert.deepEqual(output, [[87, 1]], '映射路线按下 W');
  gamepad.setMappedOutputEnabled(false);
  assert.equal(gamepad.isMappedOutputEnabled(), true, '旧 W 松开被拒，映射仍实际生效');
  const pendingLookups = lookups, pendingReads = axisReads, pendingResets = resets;
  sample();
  assert.deepEqual([lookups, axisReads, resets], [pendingLookups + 1, pendingReads + 8, pendingResets + 1]);
  allowRelease = true;
  gamepad.setMappedOutputEnabled(false);
  assert.equal(gamepad.isMappedOutputEnabled(), false);
  assert.deepEqual(output, [[87, 1], [87, 0]], '交还前松开原映射');
  // 旧 RELEASE 等待期间可已排入一次清理时钟。让它完成后再观察原生稳态。
  env.runTimers();
  assert.equal(env.timer.size, 0);
  const beforeNative = [lookups, axisReads, resets, cleanup];
  for (let i = 0; i < 1000; i++) sample();
  assert.deepEqual([lookups, axisReads, resets, cleanup], beforeNative,
    '已原生接管的窗口轴副本必须在设备查询、轴复制及映射维护之前退出');
  assert.equal(env.timer.size, 0);
  gamepad.setMappedOutputEnabled(true);
  runtime.setState(false, false);
  sample();
  assert.equal(axisReads, beforeNative[1], '失焦不能采集映射轴');
  runtime.setState(true, true);
  frontend = newLease;
  sample();
  assert.equal(axisReads, beforeNative[1], '已交接的旧前端不能给后来前端发轴');
  subject.frontendLease = newLease;
  sample();
  assert.deepEqual(output, [[87, 1], [87, 0], [87, 1]], '新前端可恢复映射操作');
  runtime.stop();
  console.log('PASS actual window axes: mapped, pending release, 1000 native copies with zero reads/work, blur and frontend handoff');
}

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
  const sessionNotices=ast.statements.find(n=>n.declarationList?.declarations.some(d=>d.name.getText(ast)==='notifiedGamepadRoutes'));
  assert.ok(sessionNotices,'同局通知归属于跨页面的宿主身份');
  const js=compiler.transpileModule(sessionNotices.getText(ast)+'\nclass RoutePage {\n'+body+'\n}\nreturn RoutePage;',
    {compilerOptions:{target:compiler.ScriptTarget.ES2020},reportDiagnostics:true});
  assert.equal((js.diagnostics??[]).filter(item=>item.category===compiler.DiagnosticCategory.Error).length,0);
  const Subject=new Function('nativeGamepadRouteNotice',js.outputText)(policy.nativeGamepadRouteNotice);
  const p=new Subject(), first={id:1}, next={id:2};let current=first, reads=0, onRead=()=>{};
  const toast=[],faults=[];
  const resolve=(requested,ready,applied,wire=currentWire)=>policy.resolveNativeGamepadRoute(requested,ready,wire,applied);
  let decision=resolve(false,false,'mapped');
  const host={accepts:lease=>lease===current,
    nativeGamepadRouteForFrontend:lease=>{reads++;onRead();return lease===current?decision:undefined;}};
  function bind(page,lease){
    Object.assign(page,{sessionHost:host,frontendLease:lease,inputLifecycleEpoch:7,mcStarted:true,pageVisible:true,
      pageInputActive:true,navigatedAway:false,notePageStepFault_:(_scope,step)=>faults.push(step),
      getUIContext:()=>({getPromptAction:()=>({showToast:options=>toast.push(options)})})});
  }
  const tick=(page=p)=>page.refreshNativeGamepadRouteStatus_(host,current,7);
  bind(p,first);tick();
  decision=resolve(true,false,'mapped','');tick(); // 等待输入计划。
  decision=resolve(true,true,'mapped');tick(); // 等待原映射释放。
  assert.deepEqual(toast,[],'默认映射和过渡过程保持安静');
  decision=resolve(true,true,'native');
  for(const field of ['mcStarted','pageVisible','pageInputActive']){
    p[field]=false;tick();assert.deepEqual(toast,[],'尚未可见/在后台时不能吞掉首次通知');p[field]=true;
  }
  onRead=()=>{p.pageInputActive=false;};tick();assert.deepEqual(toast,[],'读回期间失焦不弹');p.pageInputActive=true;
  onRead=()=>{};tick();tick();
  assert.deepEqual(toast,[{message:'本局已启用原生手柄。',duration:2000}],'心跳仅发一次短通知');
  p.pageVisible=false;tick();p.pageVisible=true;tick();assert.equal(toast.length,1);
  const rebuilt=new Subject();current=next;bind(rebuilt,next);tick(rebuilt);assert.equal(toast.length,1,'同一游戏重建页面不重播');
  const before=reads;p.refreshNativeGamepadRouteStatus_(host,first,7);
  assert.equal(reads,before,'ROUTE_PAGE_OLD_SCOPE 旧观察不得读取后来路线');
  rebuilt.refreshNativeGamepadRouteStatus_({},next,7);rebuilt.refreshNativeGamepadRouteStatus_(host,next,6);
  assert.equal(reads,before,'原host和页面代共同检查');
  decision=resolve(true,false,'mapped');
  onRead=()=>{rebuilt.sessionHost={accepts:()=>true};};tick(rebuilt);
  assert.equal(toast.length,1,'ROUTE_PAGE_REENTRY 读回不能影响后来会话');
  rebuilt.sessionHost=host;onRead=()=>{throw Error('status boundary unavailable');};tick(rebuilt);
  assert.deepEqual(faults,['route-read']);assert.equal(toast.length,1);
  onRead=()=>{};tick(rebuilt);tick(rebuilt);
  assert.equal(toast.length,2);assert.match(toast[1].message,/采集不可用.*启动器映射/);
  decision=resolve(true,true,'native');tick(rebuilt);
  decision=resolve(false,true,'native');tick(rebuilt);assert.equal(toast.length,3,'等待回退不能提前发已切换');
  decision=resolve(false,true,'mapped');tick(rebuilt);tick(rebuilt);
  assert.equal(toast.length,4);assert.match(toast[3].message,/已切换为启动器手柄映射/);
  decision=resolve(true,true,'native');rebuilt.getUIContext=()=>{throw Error('toast context unavailable');};
  tick(rebuilt);tick(rebuilt);assert.deepEqual(faults,['route-read','route-toast'],'Toast 抛错后正常心跳不会反复重试');
  const newHost={...host};bind(rebuilt,next);rebuilt.sessionHost=newHost;
  decision=resolve(true,false,'mapped','invalid-plan');
  rebuilt.refreshNativeGamepadRouteStatus_(newHost,next,7);rebuilt.refreshNativeGamepadRouteStatus_(newHost,next,7);
  assert.equal(toast.length,5);assert.match(toast[4].message,/无法确认.*启动器映射/,'新会话独立报告明确降级');
  return body;
}
const reportBody=pageRouteReader();
// 两个原资格检查共同保护旧读回；只撤一处仍受另一处保护，必须保真实反控强度。
const guard='if (this.sessionHost!==host || this.frontendLease!==frontend || this.inputLifecycleEpoch!==epoch || !host.accepts(frontend)) return';
assert.equal(reportBody.split(guard).length,3);
assert.throws(()=>pageRouteReader(reportBody.replaceAll(guard,'')),
  error=>error instanceof assert.AssertionError&&error.message.includes('ROUTE_PAGE_OLD_SCOPE'));
console.log('PASS actual route Toast: visible session transitions, one notification across heartbeats and reattach, fallback and stale-frontend guards');

// 真正的ArkUI桌面入口和实体按键方法共测，替身只提供SDK事件与原生接收结果。
const loadKeyboard=makePureEtsLoader();
const keyboardModule=name=>loadKeyboard('gamecontrol/src/main/ets/'+name+'.ets');
const codes=keyboardModule('OhosKeyCodes'), glfw=keyboardModule('GlfwKeys');
const keys={...glfw,...codes,...keyboardModule('PhysicalHeldKeyTracker'),...keyboardModule('KeyMap'),
  ...keyboardModule('PhysicalKeyEdge'),normalizeDeviceId:abi.normalizeDeviceId,
  KeyType:{Down:1,Up:2},KeySource:{Keyboard:1},routeKeyToGamepad:()=>false,
  getImeActivationGate:()=>({isActive:()=>false}),TAG:'navigation',LOG_DOMAIN_LAUNCH:1};
for (const statement of ast.statements.filter(compiler.isVariableStatement)) {
  for (const declaration of statement.declarationList.declarations) {
    const name=declaration.name.getText(ast);
    if (name.startsWith('PHYSICAL_KEY_') || name==='DESKTOP_KEY_RETIREMENT_ATTEMPTS') keys[name]=Number(declaration.initializer.getText(ast));
  }
}
let outcome=keys.PHYSICAL_KEY_TYPED_ROUTE_HANDLED, stops=0, throwKeyTransaction=false;
const sent=[];
keys.testNapi={physicalKeyTransaction:(...values)=>{
  sent.push(values);
  if(throwKeyTransaction) throw new Error('controlled native transaction exception');
  return outcome;
},sendCharEvent(){}};
const KeyboardPage=new Function(...Object.keys(keys),js)(...Object.values(keys));
const keyboard=new KeyboardPage();
Object.assign(keyboard,{sessionHost:{accepts:()=>true},mcStarted:true,pageInputActive:true,
  desktopKeyboardFocus_:true,reconcileNativeResetEpoch(){},heldKeys:new keys.PhysicalHeldKeyTracker(),
  physicalKeyRejectLogCount:0,desktopKeyRetirements_:[],desktopKeyRetirementAttempts_:0,
  launchLogger_:()=>({warn(){},info(){}})});
const handlers=[];
let surfaceBlur, surfaceFocus, inputPause;
function compileCallback(body) {
  const transpiled=compiler.transpileModule('return ('+body+');',{compilerOptions:{target:compiler.ScriptTarget.ES2020}});
  return new Function('getImeActivationGate', 'TAG', 'LOG_DOMAIN_LAUNCH', transpiled.outputText)
    .call(keyboard, keys.getImeActivationGate, keys.TAG, keys.LOG_DOMAIN_LAUNCH);
}
function visitKeyHandlers(node) {
  if (compiler.isCallExpression(node) && node.expression.name?.getText(ast)==='onKeyEvent') {
    const body=node.arguments[0].getText(ast);
    if(body.includes('this.handleKeyEvent')) {
      handlers.push(compileCallback(body));
    }
  }
  if (compiler.isCallExpression(node) && node.expression.name?.getText(ast)==='onFocus') {
    const body=node.arguments[0].getText(ast);
    if (body.includes('this.rearmDesktopKeyRetirements') && !body.includes('this.surfaceFocused')) surfaceFocus=compileCallback(body);
  }
  if (compiler.isCallExpression(node) && node.expression.name?.getText(ast)==='onBlur') {
    const body=node.arguments[0].getText(ast);
    if (body.includes('this.retireDesktopHeldKeys') && !body.includes('this.surfaceFocused')) surfaceBlur=compileCallback(body);
  }
  if (compiler.isPropertyAssignment(node) && node.name.getText(ast)==='onInputPause') {
    const body=node.initializer.getText(ast);
    if (body.includes('this.retireDesktopHeldKeys')) inputPause=compileCallback(body);
  }
  compiler.forEachChild(node,visitKeyHandlers);
}
visitKeyHandlers(owner);
assert.equal(handlers.length,2,'桌面渲染面和移动父节点保留各自的事件入口');
// 鏈式属性的AST遍历先访问根容器回调，再深入组件Builder的渲染面回调。
const desktop=handlers.find(fn=>fn.toString().includes('stopPropagation'));
const mobile=handlers.find(fn=>fn!==desktop);
const key=(code,type)=>({keyCode:code,type,deviceId:42,keySource:1,stopPropagation(){stops++;}});
assert.equal(desktop(key(codes.OHOS_TAB,1)),true);
assert.equal(desktop(key(codes.OHOS_TAB,2)),true);
mobile(key(codes.OHOS_TAB,1));
assert.equal(sent.length,2,'桌面Tab按放只投递一次，根容器不双发');
assert.equal(stops,2);
assert.equal(desktop(key(codes.OHOS_A,1)),false,'普通字母只转交游戏');
assert.equal(sent.at(-1)[7],glfw.GLFW_KEY_A);
outcome=10;
assert.equal(desktop(key(codes.OHOS_TAB,1)),false,'Native拒绝不能占用Tab');
const before=sent.length;
keyboard.pageInputActive=false;
assert.equal(desktop(key(codes.OHOS_TAB,1)),false,'页面没有焦点时不接管导航');
assert.equal(sent.length,before);
keyboard.pageInputActive=true; keyboard.desktopKeyboardFocus_=false;
assert.equal(desktop(key(codes.OHOS_TAB,1)),false);
assert.equal(sent.length,before);
mobile(key(codes.OHOS_TAB,1));
assert.equal(sent.length,before+1,'移动端原祖先入口仍处理按键');
assert.equal(stops,2);
// 真实工具、渲染区走焦两条路径，工具中的UP不送给游戏，返回后也不能补发第二次UP。
assert.ok(surfaceBlur && inputPause,'提取实际渲染区blur及工具pause入口');
for(const leave of ['overlay','surface']) {
  keyboard.heldKeys.clear(); sent.length=0; outcome=keys.PHYSICAL_KEY_TYPED_ROUTE_HANDLED;
  const liveLease={id:7};
  Object.assign(keyboard,{frontendLease:liveLease,sessionHost:{accepts:value=>value===liveLease},
    pageInputActive:true,inputOverlayPaused:false,desktopKeyboardFocus_:true,pageVisible:true,gameWindowReady:true,
    updatePageInputActive(){this.pageInputActive=!this.inputOverlayPaused;},
    getUIContext:()=>({getFocusController:()=>({requestFocus(){}})})});
  desktop(key(codes.OHOS_SHIFT_LEFT,1)); desktop(key(codes.OHOS_TAB,1));
  const shiftTab=sent.at(-1);
  assert.ok(shiftTab[4]&glfw.GLFW_MOD_SHIFT);
  if(leave==='overlay') { inputPause(true); inputPause(true); inputPause(false); }
  else { surfaceBlur(); surfaceBlur(); }
  assert.deepEqual(sent.slice(2).map(row=>[row[0],row[3],row[4],row[6],row[8],row[9]]),
    [[codes.OHOS_TAB,keys.SHADOW_KEY_UP,glfw.GLFW_MOD_SHIFT,42,glfw.GLFW_RELEASE,true],
      [codes.OHOS_SHIFT_LEFT,keys.SHADOW_KEY_UP,0,42,glfw.GLFW_RELEASE,true]]);
  assert.equal(keyboard.heldKeys.ownerCount(),0);
  desktop(key(codes.OHOS_SHIFT_LEFT,2)); desktop(key(codes.OHOS_TAB,2));
  assert.equal(sent.length,4,'迟到的两个实体UP都不重复投递');
  desktop(key(codes.OHOS_TAB,1));
  assert.equal(sent.at(-1)[4]&glfw.GLFW_MOD_SHIFT,0,'返回后Tab不遗留Shift修饰');
  desktop(key(codes.OHOS_TAB,2)); assert.equal(sent.length,6,'新按放照常交付');
  desktop(key(codes.OHOS_SHIFT_LEFT,1));
  keyboard.sessionHost={accepts:()=>false}; surfaceBlur();
  assert.equal(sent.length,7,'旧前端的blur不能退休后来游戏的键');
  keyboard.sessionHost={accepts:()=>true}; keyboard.desktopKeyboardFocus_=false; surfaceBlur();
  assert.equal(sent.length,7,'移动端原焦点策略保持不变');
}
// 拒收后保留真实owner。维护预算耗尽也不能吞掉迟到的真实UP或误松最新DOWN。
for(const recover of ['maintenance','real-up','fresh-down']) {
  keyboard.heldKeys.clear(); sent.length=0;
  const frontend={id:8};
  Object.assign(keyboard,{frontendLease:frontend,sessionHost:{accepts:lease=>lease===frontend},
    pageInputActive:true,desktopKeyboardFocus_:true,desktopKeyRetirements_:[],desktopKeyRetirementAttempts_:0});
  outcome=keys.PHYSICAL_KEY_TYPED_ROUTE_HANDLED;
  desktop(key(codes.OHOS_SHIFT_LEFT,1));
  outcome=3;
  surfaceBlur();
  assert.equal(sent.length,2,'先收首次受控 enqueue failure');
  assert.equal(keyboard.heldKeys.hasOwner(42,codes.OHOS_SHIFT_LEFT),true,'失败不能丢失原持有账');
  assert.equal(keyboard.heldKeys.wasSyntheticallyReleased(42,codes.OHOS_SHIFT_LEFT),false);
  if(recover==='maintenance') {
    outcome=keys.PHYSICAL_KEY_TYPED_ROUTE_HANDLED;
    keyboard.flushDesktopKeyRetirements();
    assert.equal(sent.length,3);
  } else {
    for(let i=0;i<8;i++) keyboard.flushDesktopKeyRetirements();
    assert.equal(sent.length,1+keys.DESKTOP_KEY_RETIREMENT_ATTEMPTS,'维护达到固定上限后停止');
    if(recover==='real-up') {
      outcome=keys.PHYSICAL_KEY_OWNERLESS_UP;
      desktop(key(codes.OHOS_SHIFT_LEFT,2));
      assert.equal(sent.length,2+keys.DESKTOP_KEY_RETIREMENT_ATTEMPTS,'真实UP提交旧松键直至终态');
    } else {
      outcome=3;
      desktop(key(codes.OHOS_SHIFT_LEFT,1));
      assert.equal(sent.at(-1)[9],true,'旧松键未确认，不发新Down');
      outcome=keys.PHYSICAL_KEY_TYPED_ROUTE_HANDLED;
      desktop(key(codes.OHOS_SHIFT_LEFT,1));
      assert.deepEqual(sent.slice(-2).map(row=>[row[8],row[9]]),[[glfw.GLFW_RELEASE,true],[glfw.GLFW_PRESS,undefined]]);
      const count=sent.length;
      keyboard.flushDesktopKeyRetirements();
      assert.equal(sent.length,count,'原维护请求不能松开新一轮持有');
      desktop(key(codes.OHOS_SHIFT_LEFT,2));
    }
  }
  assert.equal(keyboard.heldKeys.ownerCount(),0);
  const count=sent.length;
  keyboard.flushDesktopKeyRetirements();
  assert.equal(sent.length,count,'终态后没有额外松键');
}
// 保持游戏焦点，正常真UP第一次走实际gate入口。拒绝/异常不能让已拥有的Shift退账。
for(const failure of [3,10,'throw']) for(const recover of ['maintenance','fresh-down','real-up']) {
  keyboard.heldKeys.clear(); sent.length=0;
  const frontend={id:11};
  Object.assign(keyboard,{frontendLease:frontend,sessionHost:{accepts:lease=>lease===frontend},
    pageInputActive:true,inputOverlayPaused:false,desktopKeyboardFocus_:true,
    desktopKeyRetirements_:[],desktopKeyRetirementAttempts_:0});
  outcome=keys.PHYSICAL_KEY_TYPED_ROUTE_HANDLED;
  desktop(key(codes.OHOS_SHIFT_LEFT,1));
  outcome=typeof failure==='number'?failure:0;
  throwKeyTransaction=failure==='throw';
  desktop(key(codes.OHOS_SHIFT_LEFT,2));
  throwKeyTransaction=false;
  assert.deepEqual(sent.slice(-1).map(row=>[row[8],row[9],row[4]&glfw.GLFW_MOD_SHIFT]),
    [[glfw.GLFW_RELEASE,undefined,0]],'真实UP首次不穿越gate，但mods反映本次释放');
  assert.equal(keyboard.heldKeys.hasOwner(42,codes.OHOS_SHIFT_LEFT),true,'未获确认仍持有原Shift');
  assert.equal(keyboard.heldKeys.wasSyntheticallyReleased(42,codes.OHOS_SHIFT_LEFT),false);
  assert.equal(keyboard.desktopKeyRetirements_.length,1);
  outcome=keys.PHYSICAL_KEY_TYPED_ROUTE_HANDLED;
  if(recover==='maintenance') keyboard.flushDesktopKeyRetirements();
  else if(recover==='real-up') desktop(key(codes.OHOS_SHIFT_LEFT,2));
  else desktop(key(codes.OHOS_SHIFT_LEFT,1));
  assert.deepEqual(sent[2].slice(8),[glfw.GLFW_RELEASE,true],'维护或真边沿只补旧owner');
  if(recover==='fresh-down') {
    assert.deepEqual(sent[3].slice(8),[glfw.GLFW_PRESS],'松旧Shift之后才交付新DOWN');
    const count=sent.length;
    keyboard.flushDesktopKeyRetirements();
    assert.equal(sent.length,count,'旧维护不能松新Shift');
    desktop(key(codes.OHOS_SHIFT_LEFT,2));
  } else {
    const count=sent.length;
    desktop(key(codes.OHOS_SHIFT_LEFT,2));
    assert.equal(sent.length,count,'恢复后的迟到重复UP不双发');
  }
  assert.equal(keyboard.heldKeys.ownerCount(),0);
  assert.equal(keyboard.desktopKeyRetirements_.length,0);
  desktop(key(codes.OHOS_TAB,1));
  assert.equal(sent.at(-1)[4]&glfw.GLFW_MOD_SHIFT,0,'恢复后Tab没有陈旧Shift');
  desktop(key(codes.OHOS_TAB,2));
}

console.log('PASS actual focused UP failure: queue rejection, closed gate and exception recover via maintenance, UP or same-key DOWN');

// 自动Repeat与间隔后的同键Down拒收均不能清已接纳的owner，只有初次拒收应回滚。
const realNow=Date.now;
try {
  for(const desktopRoute of [true,false]) for(const elapsed of [10,1500]) {
    keyboard.heldKeys.clear(); sent.length=0;
    const frontend={id:12};
    Object.assign(keyboard,{frontendLease:frontend,sessionHost:{accepts:lease=>lease===frontend},
      pageInputActive:true,desktopKeyboardFocus_:desktopRoute,desktopKeyRetirements_:[]});
    const send=desktopRoute?desktop:mobile;
    Date.now=()=>1000;
    outcome=3;
    send(key(codes.OHOS_SHIFT_LEFT,1));
    assert.equal(keyboard.heldKeys.ownerCount(),0,'初次Down的明确拒绝需回滚新建owner');
    outcome=keys.PHYSICAL_KEY_TYPED_ROUTE_HANDLED;
    send(key(codes.OHOS_SHIFT_LEFT,1));
    Date.now=()=>1000+elapsed;
    outcome=10;
    send(key(codes.OHOS_SHIFT_LEFT,1));
    assert.equal(keyboard.heldKeys.ownerCount(),desktopRoute?1:0,
      '桌面原owner保留，移动既有重复判定保持');
    outcome=keys.PHYSICAL_KEY_TYPED_ROUTE_HANDLED;
    send(key(codes.OHOS_SHIFT_LEFT,2));
    assert.equal(keyboard.heldKeys.ownerCount(),0);
    assert.equal(sent.at(-1)[9],undefined,'普通实体松键继续走原gate');
    assert.equal(keyboard.desktopKeyRetirements_.length,0);
  }
} finally {
  Date.now=realNow;
}
console.log('PASS accepted desktop owner survives rejected repeat/stale down; initial rejection and mobile route preserved');

// 零owner仍上报同一Native诊断。保留另一键盘的同键Shift至最后owner释放。
keyboard.heldKeys.clear(); sent.length=0;
keyboard.desktopKeyboardFocus_=true;
outcome=keys.PHYSICAL_KEY_OWNERLESS_UP;
desktop(key(codes.OHOS_SHIFT_LEFT,2));
assert.equal(sent.length,1,'ownerless UP仍交Native诊断');
assert.equal(keyboard.desktopKeyRetirements_.length,0);
outcome=keys.PHYSICAL_KEY_TYPED_ROUTE_HANDLED;
desktop(key(codes.OHOS_SHIFT_LEFT,1));
desktop({...key(codes.OHOS_SHIFT_LEFT,1),deviceId:43});
desktop(key(codes.OHOS_SHIFT_LEFT,2));
assert.equal(sent.at(-1)[4]&glfw.GLFW_MOD_SHIFT,glfw.GLFW_MOD_SHIFT,'另一设备Shift继续持有');
desktop({...key(codes.OHOS_SHIFT_LEFT,2),deviceId:43});
assert.equal(sent.at(-1)[4]&glfw.GLFW_MOD_SHIFT,0,'最后一份Shift真正释放后修饰位清零');
// 实体Shift在工具里松开，四次真实生产补偿全部拒收。只有可恢复的原前端获准重新尝试。
assert.ok(surfaceFocus,'提取实际渲染区返焦入口');
for(const recover of ['close','focus','different-down','same-down','retired-frontend']) {
  keyboard.heldKeys.clear(); sent.length=0;
  const frontend={id:13};
  Object.assign(keyboard,{frontendLease:frontend,sessionHost:{accepts:lease=>lease===frontend},
    pageInputActive:true,inputOverlayPaused:false,desktopKeyboardFocus_:true,
    pageVisible:true,gameWindowReady:true,desktopKeyRetirements_:[],desktopKeyRetirementAttempts_:0,
    desktopKeyRetirementOnRefocus_:false});
  outcome=keys.PHYSICAL_KEY_TYPED_ROUTE_HANDLED;
  desktop(key(codes.OHOS_SHIFT_LEFT,1));
  outcome=3;
  if(recover==='focus') surfaceBlur(); else inputPause(true);
  for(let i=0;i<8;i++) keyboard.flushDesktopKeyRetirements();
  const exhausted=sent.length;
  assert.equal(exhausted,1+keys.DESKTOP_KEY_RETIREMENT_ATTEMPTS);
  if(recover!=='focus') {
    desktop(key(codes.OHOS_SHIFT_LEFT,2));
    assert.equal(sent.length,exhausted,'工具打开，原真实UP不交游戏');
  }
  if(recover==='close'||recover==='focus'||recover==='retired-frontend'){
    outcome=keys.PHYSICAL_KEY_TYPED_ROUTE_HANDLED;
    if(recover==='retired-frontend') keyboard.sessionHost={accepts:()=>false};
    if(recover==='focus') surfaceFocus(); else inputPause(false);
    surfaceFocus();
    for(let i=0;i<8;i++) keyboard.flushDesktopKeyRetirements();
    if(recover==='retired-frontend') {
      desktop(key(codes.OHOS_TAB,1));
      assert.equal(sent.length,exhausted,'工具恢复及Tab均不能借旧租约松键或发送');
      continue;
    }
    assert.equal(sent.length,exhausted+1,'Native恢复后返焦单次结清旧Shift，八轮维护无多余输出');
  } else {
    inputPause(false);
    for(let i=0;i<8;i++) keyboard.flushDesktopKeyRetirements();
    const exhaustedAgain=sent.length;
    assert.equal(exhaustedAgain,exhausted+keys.DESKTOP_KEY_RETIREMENT_ATTEMPTS);
    surfaceFocus();
    for(let i=0;i<8;i++) keyboard.flushDesktopKeyRetirements();
    assert.equal(sent.length,exhaustedAgain,'同一返回的重复focus不重开预算');
    const next= recover==='same-down'?codes.OHOS_SHIFT_LEFT:codes.OHOS_TAB;
    assert.equal(desktop(key(next,1)),false,'永久拒收旧Shift时不能发新Down');
    assert.deepEqual(sent.slice(exhaustedAgain).map(row=>[row[0],row[8],row[9]]),
      [[codes.OHOS_SHIFT_LEFT,glfw.GLFW_RELEASE,true]],'仅重试原Shift，没有错误导航');
    outcome=keys.PHYSICAL_KEY_TYPED_ROUTE_HANDLED;
    desktop(key(next,1));
    assert.deepEqual(sent.slice(-2).map(row=>[row[0],row[8],row[9]]),
      [[codes.OHOS_SHIFT_LEFT,glfw.GLFW_RELEASE,true],[next,glfw.GLFW_PRESS,undefined]],
      '预算用完之后Native恢复，新同键或不同键都先结清原Shift');
    assert.equal(sent.at(-1)[4]&glfw.GLFW_MOD_SHIFT,next===codes.OHOS_SHIFT_LEFT?glfw.GLFW_MOD_SHIFT:0);
    desktop(key(next,2));
  }
  assert.equal(keyboard.desktopKeyRetirements_.length,0);
  desktop(key(codes.OHOS_TAB,1));
  assert.equal(sent.at(-1)[4]&glfw.GLFW_MOD_SHIFT,0,'恢复后Tab不会携带陈旧Shift');
  desktop(key(codes.OHOS_TAB,2));
}

// 原修饰键失效不堵并行设备的真实UP；它仍按自己的已持有身份走正常gate。
keyboard.heldKeys.clear(); sent.length=0;
const separateFront={id:14};
Object.assign(keyboard,{frontendLease:separateFront,sessionHost:{accepts:lease=>lease===separateFront},
  pageInputActive:true,desktopKeyboardFocus_:true,desktopKeyRetirements_:[],desktopKeyRetirementAttempts_:0});
outcome=keys.PHYSICAL_KEY_TYPED_ROUTE_HANDLED;
desktop(key(codes.OHOS_SHIFT_LEFT,1));
desktop({...key(codes.OHOS_A,1),deviceId:43});
outcome=10;
desktop(key(codes.OHOS_SHIFT_LEFT,2));
outcome=keys.PHYSICAL_KEY_TYPED_ROUTE_HANDLED;
desktop({...key(codes.OHOS_A,2),deviceId:43});
assert.deepEqual(sent.slice(-1).map(row=>[row[0],row[6],row[8],row[9]]),
  [[codes.OHOS_A,43,glfw.GLFW_RELEASE,undefined]],'其它真实UP不借旧Shift重试或被拦住');
assert.ok(keyboard.heldKeys.hasOwner(42,codes.OHOS_SHIFT_LEFT));
assert.ok(!keyboard.heldKeys.hasOwner(43,codes.OHOS_A));
keyboard.flushDesktopKeyRetirements();
assert.equal(keyboard.heldKeys.ownerCount(),0);
console.log('PASS actual tool/focus recovery after exhausted release, blocked stale modifiers, real sibling UP, bounded duplicate focus and retired front');
console.log('PASS real desktop Tab scope and owned keys: tool/blur retirement, delayed UP, fresh keys, old frontend and mobile ingress');
