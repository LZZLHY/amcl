/** 基础触控的生产模型/组件方法回归：真实几何、接受态、教学隔离与解除绑定，不重写产品逻辑。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import compiler from './lib/ets-compiler.mjs';
import {makePureEtsLoader} from './lib/load-pure-ets.mjs';
import {environment} from './lib/ets-runtime-fixture.mjs';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const load=makePureEtsLoader();
const layout=load('gamecontrol/src/main/ets/ControlLayout.ets');
const gui=load('gamecontrol/src/main/ets/GameGuiGeometry.ets');
const {VirtualMouseModel,FloatingMouseFrame,floatingMouseFrame}=load('gamecontrol/src/main/ets/VirtualMouseModel.ets');
const {TouchGuide,TouchGuideStep,TouchGuideFeedback,parseTouchGuideFeedback}=load('gamecontrol/src/main/ets/TouchGuide.ets');
const presentation=load('gamecontrol/src/main/ets/TouchControlPresentation.ets');
const controlGeometry=load('gamecontrol/src/main/ets/TouchControlGeometry.ets');
const guideGeometry=load('gamecontrol/src/main/ets/TouchGuideLayout.ets');
const runtimeGeometry=load('gamecontrol/src/main/ets/RuntimeTouchLayout.ets');
const surfaceModel=load('gamecontrol/src/main/ets/InputSurfaceContext.ets');
let cases=0;
function check(name,body){body();cases++;console.log('PASS '+name);}
function snapshot(requested=3,effective=3,revision=1){return gui.parseGameGuiState([2,requested,effective,1280,720,Math.ceil(1280/effective),Math.ceil(720/effective),1,revision,1,0,0,0]);}
/** 只提取被测试的真实方法；平台属性由夹具提供，不包含ArkUI绘制语言或复制的业务实现。 */
function component(file,type,names,dependencies={},sourceOverrides={}) {
  // 撤回负控仅替换本次内存源码；生产文件不落盘改写，且后续仍提取、编译真实方法。
  const text=sourceOverrides[file]??fs.readFileSync(path.join(root,file),'utf8');
  const ast=compiler.createSourceFile(file,text,compiler.ScriptTarget.Latest,true);
  const node=ast.statements.find(item=>item.name?.getText(ast)===type);
  assert.ok(node,type);
  const methods=node.members.filter(member=>names.includes(member.name?.getText(ast))).map(member=>member.getText(ast));
  assert.equal(methods.length,names.length);
  const compiled=compiler.transpileModule('class Subject{'+methods.join('\n')+'}\nmodule.exports=Subject;',
    {compilerOptions:{target:compiler.ScriptTarget.ES2020,module:compiler.ModuleKind.CommonJS},reportDiagnostics:true});
  assert.equal((compiled.diagnostics??[]).filter(d=>d.category===compiler.DiagnosticCategory.Error).length,0,
    '生产方法及撤回负控必须先编译成功，语法错误不能冒充行为断言命中');
  const js=compiled.outputText;
  const module={exports:{}};
  new Function('module',...Object.keys(dependencies),js)(module,...Object.values(dependencies));
  return new module.exports();
}

/**
 * 回放桌面组件真实字段、生命周期、Watch 与 builder 的事件登记/IME 入参。
 * SDK AST 打印仅把 ArkUI 的组件块变为宿主可执行的顺序构造语法；不重写任何回调正文。
 * Stack 只记录事件与属性，不计算 ArkUI 布局；文本组件只录原 active 参数，不替 P6 运行体确认资源。
 * 全部 schema 副作用由 NAPI 边缘录值，不能用“恒拒绝 Native”使旧 writer 假装安全。
 */
function desktopSchemaExitContract(sourceOverrides={}) {
  const file='entry/src/main/ets/components/DesktopGameControlSurface.ets';
  const source=sourceOverrides[file]??fs.readFileSync(path.join(root,file),'utf8');
  const ast=compiler.createSourceFile(file,source,compiler.ScriptTarget.Latest,true);
  const owner=ast.statements.find(item=>item.name?.getText(ast)==='DesktopGameControlSurface');
  assert.ok(owner,'真实 desktop 组件必须仍存在，不能以删产品入口避开反例');
  const printer=compiler.createPrinter();
  // SDK AST 会补一个零长度源区间的组件构造签名；它不是源码生命周期，打印匿名参数会造成假语法失败。
  // 仅排除没有原文件正文的合成节点；实际字段、方法与全部 callback 正文仍原样打印。
  const members=owner.members.filter(member=>member.end>member.pos).map(member=>printer.printNode(compiler.EmitHint.Unspecified,member,ast)
    .replace(/@(Prop|State|Watch)(\([^\n]*?\))?\s*/g,''));
  const compiled=compiler.transpileModule('class DesktopSubject {\n'+members.join('\n')+'\n}\nmodule.exports=DesktopSubject;',
    {compilerOptions:{target:compiler.ScriptTarget.ES2020,module:compiler.ModuleKind.CommonJS},reportDiagnostics:true});
  assert.equal((compiled.diagnostics??[]).filter(d=>d.category===compiler.DiagnosticCategory.Error).length,0,
    '桌面原实现及完整撤回对照必须先转译成功，不能把语法/装配失败写成行为反控');
  const effects=[],ime=[];let registering=[];
  const chain=new Proxy({}, {get:(_target,name)=>(...args)=>{
    if(typeof name==='string'&&/^on[A-Z]/.test(name)) registering.push({name,callback:args[0]});
    return chain;
  }});
  const store=surfaceModel.getInputSurfaceContextStore();
  const publish=(ownerName,windowId,width,height,density)=>{
    const lease=store.beginPublisher(ownerName),candidate=new surfaceModel.InputSurfaceContextCandidate();
    Object.assign(candidate,{windowId,displayId:1,widthPx:width,heightPx:height,density,transform:0,provisional:false});
    const context=store.publish(lease,candidate);assert.ok(context);return {lease,context};
  };
  const dependencies={Stack:()=>chain,width:()=>chain,HitTestMode:{Transparent:1},
    DesktopPhysicalTextInput:value=>ime.push({...value}),
    testNapi:{setControlSchema:schema=>{effects.push(structuredClone(schema));return 1;}},
    getInputSurfaceContextStore:()=>store,INPUT_SURFACE_FIELD_DENSITY:surfaceModel.INPUT_SURFACE_FIELD_DENSITY,
    DEFAULT_JOYSTICK_DEAD_ZONE:.18,display:{getDefaultDisplaySync:()=>({densityPixels:1})},
    hilog:{error(){}},TAG:'DesktopControls'};
  const module={exports:{}};
  new Function('module',...Object.keys(dependencies),compiled.outputText)(module,...Object.values(dependencies));
  const make=props=>Object.assign(new module.exports(),props);
  const render=subject=>{registering=[];subject.build();return [...registering];};
  const lifecycle=(subject,name)=>{if(typeof subject[name]==='function')subject[name]();};
  // Watch 名来自真实装饰器；退出后的类不登记它们，恢复整份旧组件才会取得原回调。
  const watches=owner.members.flatMap(member=>[...member.getText(ast).matchAll(/@Watch\(['"]([^'"]+)['"]\)/g)]
    .map(match=>match[1]));
  const first=publish('desktop-old',11,1000,600,2);
  const old=make({pageActive:false,isGrabbed:false,surfaceContextGeneration:first.context.generation});
  lifecycle(old,'aboutToAppear');
  const oldEvents=render(old);
  for(const event of oldEvents)if(event.name==='onAreaChange')event.callback({}, {width:500,height:300});
  const oldWatches=watches.map(name=>()=>old[name]());
  // 真实 Store 换 publisher 后拒绝原身份；旧 UI 回调若仍存在，也不能借后来 snapshot 写入。
  const next=publish('desktop-new',22,2000,1200,3);
  assert.equal(store.publish(first.lease,new surfaceModel.InputSurfaceContextCandidate()),undefined);
  const current=make({pageActive:true,isGrabbed:false,surfaceContextGeneration:next.context.generation});
  lifecycle(current,'aboutToAppear');
  for(const event of render(current))if(event.name==='onAreaChange')event.callback({}, {width:2000/3,height:400});
  current.isGrabbed=true;for(const name of watches)current[name]();render(current);
  current.isGrabbed=false;for(const name of watches)current[name]();render(current);
  lifecycle(old,'aboutToDisappear');
  old.isGrabbed=true;
  for(const callback of oldWatches)callback();
  for(const event of oldEvents)if(event.name==='onAreaChange')event.callback({}, {width:400,height:200});
  render(old);
  assert.deepEqual(ime.map(value=>value.active),[false,true,false,true,false],
    '桌面 IME 原 pageActive && !isGrabbed 意图必须继续传给原文本组件');
  store.endPublisher(next.lease);
  for(const callback of oldWatches)callback();
  // 这是正例和完整旧组件撤回对照共用的行为断言；恢复旧 writer 会产生实际 NAPI 候选。
  assert.equal(effects.length,0,'DESKTOP_SCHEMA_NO_WRITES 生命周期/旧实例事件不得安装 Native 控件表');
}

check('桌面原生命周期和旧实例事件没有schema写入，保留原IME意图及窗口事实围栏',()=>desktopSchemaExitContract());
check('完整恢复旧桌面组件必须先转译成功，再命中真实schema副作用断言',()=>{
  // 固定样本来自 f18742 的完整原组件；不依赖测试宿主具有 Git 历史，不只恢复一个伪造 writer。
  const file='entry/src/main/ets/components/DesktopGameControlSurface.ets';
  const legacy=fs.readFileSync(path.join(root,'scripts/fixtures/desktop-control-schema/DesktopGameControlSurface.legacy.ets'));
  assert.equal(createHash('sha256').update(legacy).digest('hex'),
    'dc312761560dfaf8b8a0faf733cc1033cf1c75c405e3e1c5d140e6395443dcfe','完整原组件样本不得漂移');
  let withdrawnWrites=0;
  assert.throws(()=>desktopSchemaExitContract({[file]:legacy.toString('utf8')}),error=>{
    const detected=error instanceof assert.AssertionError&&error.message.includes('DESKTOP_SCHEMA_NO_WRITES')&&
      Number.isInteger(error.actual)&&error.actual>0&&error.expected===0;
    if(detected)withdrawnWrites=error.actual;
    return detected;
  },'反控必须识别已转译旧组件实际发送的空表');
  console.log('PASS desktop compiled withdrawal: actual NAPI schema writes='+withdrawnWrites);
});

check('原版GUI自动/手动/Unicode及最小尺寸的已知结果',()=>{
  for(const [w,h,requested,unicode,expected] of [[854,480,0,false,2],[1280,720,0,false,3],
    [1920,1080,0,false,4],[2800,1840,0,false,7],[2800,1840,0,true,8],[1920,1080,3,true,4],
    [640,480,12,false,2],[319,239,0,false,1],[640,480,1,true,2]])
    assert.equal(gui.calculateMinecraftGuiScale(w,h,requested,unicode),expected);
});
check('GUI数值ABI拒绝不完整/非法几何与版本代次',()=>{
  assert.equal(gui.parseGameGuiState([]).valid,false);
  for(const [index,value] of [[1,65],[2,NaN],[3,0],[3,65536],[5,3.5],[7,2],[8,0],[9,3],[10,-1],[11,7]]) {
    const raw=[2,3,3,1280,720,427,240,1,1,1,0,0,0];raw[index]=value;
    assert.equal(gui.parseGameGuiState(raw).valid,false,`${index}=${value}`);
  }
});
check('导航尾表保持旧GUI前缀，真实位置投影，坏尾表不污染恢复能力',()=>{
  const prefix=[2,4,4,1920,1080,480,270,1,1,1,0,0,0];
  const state=gui.parseGameGuiState([...prefix,2,34,70,150,20,0]);
  assert.equal(state.valid,true);assert.equal(state.navigationKind,2);
  const rect=gui.projectGameNavigation(state,960,540);
  assert.deepEqual([rect.x,rect.y,rect.width,rect.height],[68,140,300,40]);
  const bad=gui.parseGameGuiState([...prefix,2,NaN,70,150,20,0]);
  assert.equal(bad.valid,true);assert.equal(bad.canRestore,true);assert.equal(bad.navigationKind,0);
  const unknown=gui.parseGameGuiState([...prefix,3,0,0,0,0,-1]);
  assert.equal(unknown.navigationKind,3);assert.equal(unknown.navigationScrollKnown,false);
  assert.equal(gui.parseGameGuiState([...prefix,2]).valid,false);
});
check('手机教学使用短菜单提示且与工具栏热区共享视口几何',()=>{
  for(const [w,h] of [[827,374],[374,827],[240,180],[1317,865]]) {
    const target=new controlGeometry.TouchControlRect();target.x=w*.6;target.y=h*.4;target.width=44;target.height=44;
    for(const step of Object.values(TouchGuideStep).filter(Number.isInteger)) {
      const frame=guideGeometry.touchGuideLayout(w,h,step,false,target);
      for(const rect of [frame.toolbar,frame.card]) assert.ok(rect.x>=0 && rect.y>=0 && rect.x+rect.width<=w && rect.y+rect.height<=h);
      if(Math.min(w,h)<480) { assert.equal(frame.menuRail,true);assert.ok(frame.card.height<=60); }
    }
  }
});
check('旧版Unicode缩放向下偶数且保留1，版本识别不把现代快照当旧版',()=>{
  assert.equal(gui.calculateMinecraftGuiScale(1920,1080,3,true,true),2);
  assert.equal(gui.calculateMinecraftGuiScale(640,480,1,true,true),1);
  assert.equal(gui.calculateMinecraftGuiScale(2800,1840,0,true,true),6);
  for(const v of ['1.7.10','1.8.9','1.12.2']) assert.equal(gui.usesLegacyGuiScale(v),true);
  for(const v of ['1.13.2','1.21.11','26.4-snapshot-1']) assert.equal(gui.usesLegacyGuiScale(v),false);
  const legacy=gui.estimateGameGuiFromOptions('guiScale:3\nforceUnicodeFont:true',1920,1080,true,1,true);
  assert.equal(legacy.effective,2);assert.equal(legacy.legacy,true);assert.equal(legacy.canRestore,false);
});
check('快捷栏按真实framebuffer/GUI宽投影，保持手工校准且不改存档',()=>{
  const p=layout.getDefaultLayout(); const item=layout.makeHotbarSelector(.1,.2,100,20);p.controls=[item];
  const out=gui.projectGameHotbar(p,p.controls,snapshot(),1280,720)[0];
  assert.equal(out.xPct,369/1280);assert.equal(out.yPct,654/720);
  assert.equal(out.baseWidth*p.globalScale,540);assert.equal(out.baseHeight*p.globalScale,66);
  assert.equal(item.xPct,.1);
  const scaled=gui.projectGameHotbar(p,p.controls,snapshot(),640,360)[0];
  assert.equal(scaled.baseWidth*p.globalScale,270);assert.equal(scaled.xPct,out.xPct);
  item.hotbarUserPlaced=true;assert.equal(gui.projectGameHotbar(p,p.controls,snapshot(),1280,720)[0],item);
});
check('设置文件降级明确估算、无即时恢复权限',()=>{
  const s=gui.estimateGameGuiFromOptions('guiScale:1\nforceUnicodeFont:true',1280,720,true,9);
  assert.equal(s.valid,true);assert.equal(s.estimated,true);assert.equal(s.effective,2);assert.equal(s.canRestore,false);
  for(const text of ['guiScale:NaN','guiScale:-1','guiScale:100','other:3']) assert.equal(gui.estimateGameGuiFromOptions(text,1280,720,true,1).valid,false);
});
check('真实GUI投影在旧13项与新19项桥不可用时仍按当前实例options降级',()=>{
  // 新Native即使无法绑定游戏也输出19项；回归必须经过会话生产方法，防止估算模型正确但调用点被长度条件截断。
  for(const length of [13,19]) {
    const raw=Array(length).fill(0);raw[3]=1280;raw[4]=720;const states=[];
    // 选中当前生产GUI投影叶；Source/visual资格由独立完整Session门验证，本组只证明旧ABI的options降级。
    const session=component('entry/src/main/ets/components/EntryTouchSession.ets','EntryTouchSession',['refreshGuiProjection_','warnProjection_'],
      {parseGameGuiState:gui.parseGameGuiState,usesLegacyGuiScale:gui.usesLegacyGuiScale,
        estimateGameGuiFromOptions:gui.estimateGameGuiFromOptions,
        testNapi:{gameGuiState:()=>raw,touchInteractionVisual:()=>[]},
        fs:{statSync:()=>({mtime:1,size:10}),readTextSync:()=> 'guiScale:3\nforceUnicodeFont:true'}});
    Object.assign(session,{receive(){},guiReceive:state=>states.push(state),nextGuiRead:0,guiWidth:1280,guiHeight:720,
      guiVersion:'1.12.2',directory:'/instance',grabbed:false,fallbackOptionsStamp:'',fallbackGuiRevision:1,
      gyro:{stop(){}}});session.refreshGuiProjection_(session.guiReceive,undefined);
    assert.equal(states.length,1);assert.equal(states[0].valid,true);assert.equal(states[0].estimated,true);
    assert.equal(states[0].effective,2);assert.equal(states[0].canRestore,false);assert.equal(states[0].navigationKind,0);
  }
});
check('小GUI恢复目标、用户保留与再次改小分别处理',()=>{
  const guard=new gui.SmallGuiGuard();
  assert.equal(guard.observe(snapshot(3,3,1),960),false);
  const tiny=snapshot(1,1,2);assert.equal(guard.observe(tiny,960),true);assert.equal(guard.target,3);assert.equal(guard.canRestore,true);
  assert.equal(guard.observe(tiny,960),false);guard.keep(tiny);
  assert.equal(guard.observe(snapshot(1,1,3),960),false);
  guard.observe(snapshot(3,3,4),960);assert.equal(guard.observe(snapshot(1,1,5),960),true);
  const world=snapshot(1,1,6);world.menu=false;assert.equal(guard.observe(world,960),false);
  const autoSmall=snapshot(0,1,7);autoSmall.framebufferWidth=320;autoSmall.framebufferHeight=240;
  const small=new gui.SmallGuiGuard();assert.equal(small.observe(autoSmall,240),true);assert.equal(small.canRestore,false);
});
check('鼠标系统按钮实际保存，游戏/菜单身份位置相同且默认不再含旧滚轮',()=>{
  const p=layout.getDefaultLayout();const saved=JSON.stringify(p);
  const result=presentation.runtimeTouchControls(p,true,720,360);
  assert.equal(result.filter(c=>c.type===layout.ControlType.SCROLL_WHEEL).length,0);
  assert.equal(result.filter(c=>c.systemAction==='mouse').length,1);
  const game=result.find(c=>c.systemAction==='mouse');
  const menu=presentation.runtimeTouchControls(p,false,1280,720).find(c=>c.systemAction==='mouse');
  assert.equal(game,menu);assert.equal(game,p.controls.find(c=>c.systemAction==='mouse'));
  assert.equal(game.style.bg,undefined);assert.equal(game.baseWidth,layout.DEFAULT_BUTTON_SIZE);
  assert.equal(JSON.stringify(p),saved);
});
check('旧默认scroll不决定新鼠标位置，保留自建滚轮及已有鼠标设置，补齐身份避免嵌套碰撞',()=>{
  const p=layout.getDefaultLayout();p.controls=p.controls.filter(c=>c.systemAction!=='mouse');
  const wheel={...layout.makeSystemButton('visibility',.27,.61,0),id:'scroll',systemAction:undefined,type:layout.ControlType.SCROLL_WHEEL};
  const custom={...wheel,id:'custom-wheel',xPct:.8};
  p.controls.push(wheel,custom);
  p.controls[0].children=[{...layout.makeSystemButton('mouse',.1,.2,0),systemAction:undefined}];
  presentation.ensureSystemMouseControl(p);
  const mouse=p.controls.find(c=>c.systemAction==='mouse');
  const defaultMouse=layout.makeDefaultSystemMouseControl();
  assert.notEqual(mouse.id,'sys_mouse');assert.equal(mouse.xPct,defaultMouse.xPct);assert.equal(mouse.yPct,defaultMouse.yPct);
  assert.equal(p.controls.includes(custom),true);assert.equal(p.controls.some(c=>c.id==='scroll'),false);
  mouse.xPct=.45;mouse.yPct=.25;mouse.style.bg='#123456';mouse.hidden=true;mouse.menuOnly=true;mouse.visibilityOverride='force_hide';
  const userDefined=JSON.stringify(mouse);
  presentation.ensureSystemMouseControl(p);
  assert.equal(JSON.stringify(mouse),userDefined,'补齐不能无条件恢复已有入口的位置、外观或显示/场景设置');
  assert.equal(p.controls.filter(c=>c.systemAction==='mouse').length,1);
});
check('鼠标系统入口不能单删/批删或隐藏成单场景，拖动仍走普通编辑器并保留其它按钮',()=>{
  // 执行真实编辑器方法，覆盖普通删除与多选删除两条入口；移动必须写回同一个存档控件。
  const mouse=layout.makeSystemButton('mouse',.45,.25,0),other=layout.makeSystemButton('input',.1,.1,0);
  const editor=component('entry/src/main/ets/components/LayoutEditor.ets','LayoutEditor',
    ['selectedItem','selectedIsSystemMouse','deleteSelected','batchDelete','cycleVisibility','cycleScene','commitDrag'],{ControlType:layout.ControlType});
  Object.assign(editor,{controls:[mouse,other],selectedIdx:0,selectedIds:[mouse.id],screenWidth:1000,screenHeight:500,
    dragIdx:0,dragDx:100,dragDy:50,pushUndo(){},refreshControls(){},clearSnapGuides(){},
    itemPxX:item=>item.xPct*1000,itemPxY:item=>item.yPct*500,itemW:()=>48,itemH:()=>48});
  assert.equal(editor.selectedIsSystemMouse(),true);
  editor.deleteSelected();assert.equal(editor.controls[0],mouse);assert.match(editor.statusMsg,/不可删除/);
  editor.batchDelete();assert.equal(editor.controls.length,2);assert.equal(editor.controls[0],mouse);
  editor.cycleVisibility();editor.cycleScene();assert.equal(mouse.grabbedOnly,false);assert.notEqual(mouse.hidden,true);
  editor.commitDrag();assert.equal(mouse.xPct,.55);assert.equal(mouse.yPct,.35);assert.equal(editor.controls[1],other);
});
check('鼠标系统入口遵循全局显隐和已保存策略；UI与Native共用已确认可见集合',()=>{
  const view=component('entry/src/main/ets/components/GameControls.ets','GameControls',['isControlVisible']);
  const mouse=layout.makeSystemButton('mouse',.2,.3,0);
  for(const grabbed of [true,false]) for(const mode of [0,1,2]) {
    assert.equal(runtimeGeometry.runtimeTouchControlVisible(mouse,grabbed,mode),mode!==2);
    const profile=layout.getDefaultLayout();profile.controls=[mouse];
    const context={valid:true,density:2,widthPx:1200,heightPx:800,widthVp:()=>600,heightVp:()=>400};
    const projection=runtimeGeometry.projectRuntimeTouchLayout(profile,context,new gui.GameGuiState(),grabbed,mode,new Map());
    Object.assign(view,{runtimeLayout:projection});assert.equal(view.isControlVisible(mouse),mode!==2);
  }
  // 已有用户策略仍沿通用优先级：强显可越全局隐藏，显式hidden/强隐仍优先于强显。
  mouse.visibilityOverride='force_show';assert.equal(runtimeGeometry.runtimeTouchControlVisible(mouse,true,2),true);
  mouse.hidden=true;assert.equal(runtimeGeometry.runtimeTouchControlVisible(mouse,true,2),false);
  mouse.hidden=false;mouse.visibilityOverride='force_hide';assert.equal(runtimeGeometry.runtimeTouchControlVisible(mouse,false,0),false);
  mouse.visibilityOverride=undefined;mouse.menuOnly=true;
  assert.equal(runtimeGeometry.runtimeTouchControlVisible(mouse,true,0),false);
  assert.equal(runtimeGeometry.runtimeTouchControlVisible(mouse,false,0),true);
});

const edges=[],moves=[],wheels=[],held=new Map();let accept=true;
const port={move:(x,y)=>{moves.push([x,y]);return accept;},wheel:n=>{wheels.push(n);return accept;},
  button:(id,code,down)=>{if(down&&!accept)return false;edges.push([id,code,down]);if(down)held.set(id,code);else held.delete(id);return true;},
  cancel:()=>{held.clear();return true;}};
check('悬浮鼠标同一手指保持左/右键移动，取消不遗留持有且迟到MOVE无效',()=>{
  for(const [part,code] of [['left',-1],['right',-2]]) {
    const m=new VirtualMouseModel(port);edges.length=0;moves.length=0;
    assert.equal(m.beginContact(3,part,100,100),true);m.moveContact(3,125,140);
    assert.equal(m.down(code),true);assert.deepEqual(moves,[[25,40]]);
    m.endContact(3);assert.equal(m.down(code),false);assert.equal(m.moveContact(3,500,500),false);
    assert.deepEqual(edges.map(e=>[e[1],e[2]]),[[code,true],[code,false]]);
    m.beginContact(4,part,0,0);m.releaseAll();assert.equal(held.size,0);
  }
});
check('面板reset后复用finger编号仍分配新Native持有，已知旧按下时间不能移动或释放新接触',()=>{
  const emitted=[];
  const m=new VirtualMouseModel({move:()=>true,wheel:()=>true,
    button:(owner,code,down)=>{emitted.push([owner,code,down]);return true;},cancel:()=>true});
  assert.equal(m.beginContact(0,'left',10,20,100),true);
  const first=emitted[0][0];
  m.acknowledgeReset();
  assert.equal(m.beginContact(0,'left',30,40,200),true);
  const second=emitted[1][0];assert.notEqual(first,second);
  assert.equal(m.moveContact(0,500,600,100),false);m.endContact(0,100);
  assert.equal(m.down(-1),true);assert.equal(emitted.length,2);
  m.endContact(0,200);assert.equal(m.down(-1),false);
  assert.deepEqual(emitted[2],[second,-1,false]);
  assert.equal(m.press('frozen',-1,true),true);
  assert.equal(m.press('frozen',-2,true),false);
  m.press('frozen',0,false);assert.equal(emitted.at(-1)[1],-1);
  // 可选pressedTime缺失时仍须结束真实接触，不能因诊断身份缺失把左键留住。
  assert.equal(m.beginContact(1,'right',0,0,300),true);m.endContact(1);
  assert.equal(m.down(-2),false);
});
check('系统取消走独立工具退休，失败冻结并保留重试；普通UP仍只释放原owner',()=>{
  // 平台替身只记录真实端口边界；是否清缓存、是否允许新操作由生产模型决定。
  const sent=[];let cancelled=0,allowCancel=false;
  const m=new VirtualMouseModel({move:()=>true,wheel:()=>true,
    button:(owner,code,down)=>{sent.push([owner,code,down]);return true;},
    cancel:()=>{cancelled++;return allowCancel;}});
  m.beginContact(8,'left',0,0,100);const oldOwner=sent[0][0];
  assert.equal(m.cancelAll(),false);assert.equal(m.down(-1),true);
  assert.equal(m.beginContact(9,'right',0,0),false);assert.equal(m.moveContact(8,10,10,100),false);
  m.endContact(8,100);assert.equal(sent.length,1,'取消失败不能补发普通UP伪装成功');
  allowCancel=true;assert.equal(m.cancelAll(),true);assert.equal(cancelled,2);
  assert.equal(m.down(-1),false);assert.equal(m.activeContacts(),false);assert.equal(sent.length,1);
  m.beginContact(8,'left',0,0,200);assert.notEqual(sent[1][0],oldOwner);
  assert.equal(m.hasContact(8,100),false);assert.equal(m.hasContact(8,200),true);
  m.endContact(8,200);assert.equal(sent.length,3);assert.equal(sent[2][2],false);
});
check('鼠标本体四角可达且不回写指针；教学使用实际布局和GUI投影',()=>{
  for(const [w,h] of [[360,720],[1280,720],[720,360],[240,180]]) {
    for(const [x,y] of [[0,0],[w-1,0],[0,h-1],[w-1,h-1]]) {
      const frame=floatingMouseFrame(x,y,w,h);
      assert.ok(frame.x>=0 && frame.y>=0 && frame.x+frame.width<=w && frame.y+frame.height<=h);
    }
  }
  const p=layout.getDefaultLayout();const joystick=p.controls.find(c=>c.type===layout.ControlType.JOYSTICK);
  joystick.xPct=.61;joystick.yPct=.31;
  const projection=controlGeometry.touchControlRect(joystick,p,1280,720);
  assert.equal(projection.x,.61*1280);assert.equal(projection.y,.31*720);
  const actual=gui.projectGameHotbar(p,p.controls,snapshot(),1280,720).find(c=>c.type===layout.ControlType.HOTBAR_SELECTOR);
  const bar=controlGeometry.touchControlRect(actual,p,1280,720);
  assert.equal(bar.x,actual.xPct*1280);assert.equal(bar.width,actual.baseWidth*actual.itemScale*p.globalScale);
  assert.equal(controlGeometry.touchHotbarSlot(bar.width,0,bar.width,bar.height),-1);
});
check('手机使用紧凑鼠标，平板保持完整本体，非法视口不发布虚假排除区',()=>{
  const phone=floatingMouseFrame(300,160,827,374);
  const tablet=floatingMouseFrame(500,400,1317,865);
  assert.equal(phone.compact,true);assert.deepEqual([phone.width,phone.height],[136,152]);
  assert.equal(tablet.compact,false);assert.deepEqual([tablet.width,tablet.height],[152,208]);
  assert.deepEqual([floatingMouseFrame(0,0,NaN,200).width,floatingMouseFrame(0,0,10,0).height],[0,0]);
});
check('鼠标面板的触指与锁定owner独立，关闭后零持有',()=>{
  const m=new VirtualMouseModel(port);
  assert.equal(m.press('finger',-1,true),true);m.toggle(-1);m.press('finger',-1,false);
  assert.equal(m.down(-1),true);assert.equal(held.size,1);
  m.press('right',-2,true);m.toggle(340);m.releaseAll();assert.equal(held.size,0);
  assert.equal(m.down(-1),false);assert.equal(m.locked(340),false);
  accept=false;assert.equal(m.press('rejected',-1,true),false);assert.equal(m.down(-1),false);accept=true;
});
check('pointer和wheel手指身份、余量与取消不会相互继承',()=>{
  const m=new VirtualMouseModel(port);moves.length=0;wheels.length=0;
  m.startPad(4,10,20);m.movePad(5,50,80);m.movePad(4,15,17);m.endPad(4);m.movePad(4,40,50);
  assert.deepEqual(moves,[[5,-3]]);
  m.startWheel(2,100);m.moveWheel(2,93);m.moveWheel(2,87);m.endWheel(2);
  assert.deepEqual(wheels,[-1]);m.startWheel(3,100);m.moveWheel(3,89);assert.deepEqual(wheels,[-1]);m.releaseAll();
});
check('entry真实sink停用后拒绝新动作且关闭补放',()=>{
  const emitted=[];
  const native={moveTouchMenuPointer:(...v)=>{emitted.push(['move',...v]);return true;},
    touchMenuScroll:(...v)=>{emitted.push(['wheel',...v]);return true;},touchMenuButton:(...v)=>{emitted.push(['button',...v]);return true;},
    cancelTouchMenuMouse:prefix=>{emitted.push(['cancel',prefix]);return true;},
    setTouchMenuMouseBounds:(...v)=>{emitted.push(['bounds',...v]);return true;}};
  const platform=makePureEtsLoader({commons:{AppLogger:{warn(){}}},gamecontrol:{VirtualMouseModel},'libentry.so':{__esModule:true,default:native}});
  const {EntryVirtualMouse}=platform('entry/src/main/ets/components/EntryVirtualMouse.ets');
  const entry=new EntryVirtualMouse();assert.equal(entry.model.press('off',-1,true),false);
  entry.configure(true,2);entry.bounds(1,2,136,152);entry.model.startPad(1,0,0);entry.model.movePad(1,3,4);
  entry.model.toggle(-2);entry.model.stepWheel(1);entry.release();
  const moved=emitted.find(v=>v[0]==='move'),cancelled=emitted.find(v=>v[0]==='cancel');
  assert.deepEqual(moved.slice(0,4),['move',6,8,'']);
  assert.equal(moved[4],cancelled[1],'移动冻结同一面板实例前缀');
  assert.ok(emitted.find(v=>v[0]==='button')[1].startsWith(cancelled[1]),'取消冻结同一面板实例前缀');
  assert.equal(emitted.find(v=>v[0]==='wheel')[3],cancelled[1],'滚轮冻结同一面板实例前缀');
  assert.deepEqual(emitted[0].slice(0,6),['bounds',2,4,272,304,'']);
  assert.equal(emitted[0][6],cancelled[1],'实际显示注册冻结同一实例前缀');
  assert.equal(emitted.at(-1)[0],'bounds');assert.deepEqual(emitted.at(-1).slice(3,5),[0,0]);
  const count=emitted.length;entry.model.stepWheel(1);assert.equal(emitted.length,count);
});
/** 回放实际GameControls同步与Entry/模型，只在NAPI出口记录调用和注入明确失败。 */
function idleMouseFixture() {
  const calls=[];let cancelFailures=0,boundsFailures=0;
  const native={moveTouchMenuPointer:()=>true,touchMenuScroll:()=>true,touchMenuButton:()=>true,
    cancelTouchMenuMouse:prefix=>{calls.push(['cancel',prefix]);return cancelFailures-->0 ? false : true;},
    setTouchMenuMouseBounds:(...args)=>{calls.push(['bounds',...args]);return boundsFailures-->0 ? false : true;}};
  const loader=makePureEtsLoader({commons:{AppLogger:{warn(){}}},gamecontrol:{VirtualMouseModel},'libentry.so':{__esModule:true,default:native}});
  const {EntryVirtualMouse}=loader('entry/src/main/ets/components/EntryVirtualMouse.ets');
  const entry=new EntryVirtualMouse();
  const view=component('entry/src/main/ets/components/GameControls.ets','GameControls',
    ['syncMouseBounds','mouseFrame','mousePanelVisible_','mouseEntryVisible_','mouseEntryPresented_'],
    {hasEntryTouchModal:()=>false,...runtimeGeometry,ControlType:layout.ControlType});
  const profile=layout.getDefaultLayout();
  Object.assign(view,{mouseController:entry,runtimeLayout:{context:{valid:true,density:2},controls:profile.controls,entries:profile.controls.map(item=>({item}))},
    desiredProfile:profile,drawerOpen:new Map(),globalVisMode:0,uiPublicationToken:'1',
    mouseOpen:false,isGrabbed:false,pageActive:true,imeOpen:false,fieldImeOpen:false,editing:false,density:2,
    touchSurface:{admits:()=>true},menuGeometryX:600,menuGeometryY:300,compWidth:800,compHeight:500,
    mouseGeometry:new FloatingMouseFrame()});
  return {calls,entry,view,tick:()=>view.syncMouseBounds(),
    failCancel:count=>{cancelFailures=count;},failBounds:count=>{boundsFailures=count;}};
}
check('本体真实原始移动在指针反馈不变时仍投影State，绘制与Native范围始终一致',()=>{
  const f=idleMouseFixture();f.view.mouseOpen=true;f.tick();
  const before=f.view.mouseFrame();
  assert.equal(f.entry.model.beginContact(7,'left',340,210,100),true);
  assert.equal(f.entry.model.moveContact(7,350,220,100),true);f.tick();
  const moving=f.view.mouseFrame();
  assert.equal(f.view.menuGeometryX,600,'不伪造Native指针反馈驱动绘制');
  assert.equal(moving.x-before.x,10);assert.equal(moving.y-before.y,10);
  assert.notEqual(moving,before,'真实几何变化必须整体替换State对象');
  assert.deepEqual(f.calls.at(-1).slice(1,5),[moving.x*2,moving.y*2,moving.width*2,moving.height*2]);
  f.tick();assert.equal(f.view.mouseFrame(),moving,'同几何同步不能反复替换State或形成重绘环');
  assert.equal(f.entry.model.beginContact(8,'move',360,310,200),true);
  f.entry.model.moveContact(8,380,330,200);f.tick();
  assert.equal(f.view.mouseFrame(),moving,'两指本轮锁定几何，移动指仍只移动游戏指针');
});
check('关闭鼠标的240次真实页面同步只取消一次且不反复注销不存在的面板',()=>{
  const f=idleMouseFixture();for(let i=0;i<240;i++)f.tick();
  assert.equal(f.calls.filter(c=>c[0]==='cancel').length,1,'已确认取消不能每16ms重入Native锁');
  assert.equal(f.calls.filter(c=>c[0]==='bounds').length,0,'从未登记的本实例没有待清范围');
  f.view.mouseOpen=true;f.tick();f.tick();
  assert.equal(f.calls.filter(c=>c[0]==='bounds').length,2,'活动面板仍重复确认，Native reset后必须可恢复');
  // 已UP的点击可能仍在原生队列；不能按当前held为空跳过真正关闭时的取消。
  assert.equal(f.entry.model.press('click',-1,true),true);assert.equal(f.entry.model.press('click',-1,false),true);
  f.view.mouseOpen=false;f.tick();const after=f.calls.length;
  for(let i=0;i<240;i++)f.tick();
  assert.equal(f.calls.length,after);assert.equal(f.calls.filter(c=>c[0]==='cancel').length,2);
  assert.deepEqual(f.calls.at(-1).slice(3,5),[0,0]);
});
check('取消失败后立即重新打开仍重试确认，不永久冻结原触点或吞掉新点击',()=>{
  const f=idleMouseFixture();f.view.mouseOpen=true;f.tick();
  assert.equal(f.entry.model.press('held',-1,true),true);f.failCancel(1);
  f.view.mouseOpen=false;f.tick();assert.equal(f.entry.model.down(-1),true,'失败不能伪造已松开');
  f.view.mouseOpen=true;f.tick();
  assert.equal(f.entry.model.down(-1),false,'重开后原取消仍须重试并取得真实确认');
  assert.equal(f.entry.model.press('new',-2,true),true);
  // 系统CANCEL由面板直接调用模型，父层也须在下一轮同步补偿失败，不依赖另一次关闭。
  f.failCancel(1);assert.equal(f.entry.model.cancelAll(),false);f.tick();
  assert.equal(f.entry.model.down(-2),false);assert.equal(f.entry.model.press('after-cancel',-1,true),true);
});
check('范围撤销失败仍重试，得到确认后静止；重开不会继承上次已撤销状态',()=>{
  const f=idleMouseFixture();f.view.mouseOpen=true;f.tick();f.failBounds(1);
  f.view.mouseOpen=false;f.tick();const rejected=f.calls.length;f.tick();
  assert.equal(f.calls.length,rejected+1,'失败撤销必须重试而非缓存期望值');
  const accepted=f.calls.length;f.tick();assert.equal(f.calls.length,accepted);
  f.view.mouseOpen=true;f.tick();f.entry.release();
  assert.deepEqual(f.calls.at(-1).slice(3,5),[0,0]);const released=f.calls.length;
  f.view.mouseOpen=false;for(let i=0;i<240;i++)f.tick();assert.equal(f.calls.length,released);
});
check('实际面板组件销毁后迟到的手势不再移动指针',()=>{
  const m=new VirtualMouseModel(port);moves.length=0;
  const view=component('entry/src/main/ets/components/VirtualMousePanel.ets','VirtualMousePanel',
    ['aboutToDisappear','touchArea','refreshHeld'],{TouchType:{Down:0,Move:1,Up:2,Cancel:3}});
  view.model=m;view.alive=true;view.onInteraction=()=>{};
  const event=(type,x,y)=>({type,stopPropagation(){},changedTouches:[{id:7,windowX:x,windowY:y}],touches:[{id:7,windowX:x,windowY:y}]});
  view.touchArea(event(0,100,100),'left');view.touchArea(event(1,105,107),'left');view.aboutToDisappear();
  view.touchArea(event(1,130,140),'left');assert.deepEqual(moves,[[5,7]]);assert.equal(held.size,0);
});
check('鼠标左右键Builder颜色直接读取组件状态，不按值捕获pressed反馈',()=>{
  // 这里只守现役ArkUI源码的依赖表达式，不用Node绘制替身冒充框架响应。
  // 真正SDK生成的observeComponentCreation2依赖点及旧compiled反例另由本轮产物对照核实。
  const file='entry/src/main/ets/components/VirtualMousePanel.ets';
  const text=fs.readFileSync(path.join(root,file),'utf8');
  const ast=compiler.createSourceFile(file,text,compiler.ScriptTarget.Latest,true);
  const panel=ast.statements.find(node=>node.name?.getText(ast)==='VirtualMousePanel');
  const builder=panel.members.find(node=>node.name?.getText(ast)==='MouseKey');
  assert.deepEqual(builder.parameters.map(p=>p.name.getText(ast)),['label','part'],
    '动态持有不能作为primitive参数传入Builder');
  const colors=[];
  function visit(node){
    if(compiler.isCallExpression(node)&&compiler.isPropertyAccessExpression(node.expression)&&
      ['fontColor','backgroundColor'].includes(node.expression.name.text))colors.push(node.arguments[0]);
    compiler.forEachChild(node,visit);
  }
  visit(builder);assert.equal(colors.length,2);
  for(const color of colors){
    const reads=new Set();
    function stateRead(node){
      if(compiler.isPropertyAccessExpression(node)&&node.expression.kind===compiler.SyntaxKind.ThisKeyword&&
        ['leftDown','rightDown'].includes(node.name.text))reads.add(node.name.text);
      compiler.forEachChild(node,stateRead);
    }
    stateRead(color);assert.deepEqual([...reads].sort(),['leftDown','rightDown'],
      '颜色观察表达式必须直接访问所属组件@State，不能由外层值拷贝替代');
  }
});
check('实际面板迟到旧CANCEL不撤新接触，当前CANCEL不生成普通UP',()=>{
  const sent=[];let cancelled=0;
  const m=new VirtualMouseModel({move:()=>true,wheel:()=>true,
    button:(owner,code,down)=>{sent.push([owner,code,down]);return true;},cancel:()=>{cancelled++;return true;}});
  const view=component('entry/src/main/ets/components/VirtualMousePanel.ets','VirtualMousePanel',
    ['touchArea','refreshHeld'],{TouchType:{Down:0,Move:1,Up:2,Cancel:3}});
  Object.assign(view,{model:m,alive:true,onInteraction(){}});
  const event=(type,pressedTime)=>({type,stopPropagation(){},changedTouches:[{id:7,windowX:10,windowY:20,pressedTime}],touches:[]});
  view.touchArea(event(0,100),'left');m.acknowledgeReset();view.touchArea(event(0,200),'left');
  view.touchArea(event(3,100),'left');assert.equal(cancelled,0);assert.equal(m.down(-1),true);
  view.touchArea(event(3,200),'left');assert.equal(cancelled,1);assert.equal(m.down(-1),false);
  assert.equal(sent.length,2,'系统CANCEL不得另生成一次普通RELEASE点击');
});
/**
 * 提取生产Panel真实触摸归约，加载原模型；夹具只提供SDK事件与NAPI出口录值。
 * 不以复制移动权逻辑代替生产实现，也不把Node回放描述成ArkUI布局或真人手感验证。
 */
function mousePanelBatchFixture() {
  const deltas=[],edges=[];
  const model=new VirtualMouseModel({move:(x,y)=>{deltas.push([x,y]);return true;},wheel:()=>true,
    button:(owner,code,down)=>{edges.push([owner,code,down]);return true;},cancel:()=>true});
  const panel=component('entry/src/main/ets/components/VirtualMousePanel.ets','VirtualMousePanel',
    ['touchArea','refreshHeld'],{TouchType:{Down:0,Move:1,Up:2,Cancel:3}});
  Object.assign(panel,{model,alive:true,onInteraction(){}});
  const finger=(id,x,y,pressedTime=id*100)=>({id,windowX:x,windowY:y,pressedTime});
  const send=(type,changed,touches,part='move')=>panel.touchArea({type,changedTouches:changed,touches,stopPropagation(){}},part);
  return {model,deltas,edges,finger,send};
}
check('面板UP先采仍在等待指的最新基线，移动指抬起后仅发送接续新位移',()=>{
  const f=mousePanelBatchFixture(),p=f.finger;
  f.send(0,[p(1,100,100)],[p(1,100,100)],'left');
  f.send(0,[p(2,200,200)],[p(1,100,100),p(2,200,200)]);
  f.send(1,[p(2,210,210)],[p(1,100,100),p(2,210,210)]);
  // 指1的最新坐标只在指2这次UP的touches中到达；交接必须锚到140/145，而非旧100/100。
  f.send(2,[p(2,210,210)],[p(1,140,145),p(2,210,210)]);
  assert.equal(f.model.down(-1),true);
  f.send(1,[p(1,143,149)],[p(1,143,149)],'left');
  assert.deepEqual(f.deltas.filter(([x,y])=>x!==0||y!==0),[[10,10],[3,4]]);
  f.send(2,[p(1,143,149)],[p(1,143,149)],'left');
  assert.equal(f.model.activeContacts(),false);assert.equal(f.model.down(-1),false);
});
check('面板同批多UP先归约全部末点，等待指不临时取得移动权并补发尾段',()=>{
  for(const reversed of [false,true]) {
    const f=mousePanelBatchFixture(),p=f.finger;
    f.send(0,[p(1,10,10)],[p(1,10,10)]);
    f.send(0,[p(2,100,100)],[p(1,10,10),p(2,100,100)],'left');
    const ended=[p(1,12,13),p(2,150,170)];
    f.send(2,reversed ? [...ended].reverse() : ended,ended);
    assert.deepEqual(f.deltas,[[2,3]],'changed顺序不应让等待指的50/70vp变成owner末段');
    assert.equal(f.model.activeContacts(),false);assert.equal(f.model.down(-1),false);
    assert.deepEqual(f.edges.map(edge=>edge.slice(1)),[[-1,true],[-1,false]]);
  }
});
check('其它指UP包含仍在owner的新样本时保真移动，重复结束触点只取changed末点',()=>{
  const f=mousePanelBatchFixture(),p=f.finger;
  f.send(0,[p(1,100,100)],[p(1,100,100)]);
  f.send(0,[p(2,200,200)],[p(1,100,100),p(2,200,200)],'right');
  // touches与changed可能来自不同采样；指2在touches中的225/235不能先被解释成另一份UP尾样本。
  f.send(2,[p(2,220,230)],[p(1,107,111),p(2,225,235)],'right');
  assert.deepEqual(f.deltas,[[7,11]],'仍在的owner真实增量不能被无输出observe吞掉');
  f.send(1,[p(1,108,113)],[p(1,108,113)]);
  assert.deepEqual(f.deltas,[[7,11],[1,2]]);assert.equal(f.model.down(-2),false);
  // 当前owner自己的UP仍只消费changed末点，不消费touches中的另一个样本，且正常末段未被取消语义替代。
  f.send(2,[p(1,110,116)],[p(1,150,170)]);
  assert.deepEqual(f.deltas,[[7,11],[1,2],[2,3]]);assert.equal(f.model.activeContacts(),false);
});
check('面板UP批次仍拒绝复用id的旧身份，CANCEL不采用任何占位末段',()=>{
  const f=mousePanelBatchFixture(),p=f.finger;
  f.send(0,[p(1,100,100,100)],[p(1,100,100,100)],'left');
  f.model.acknowledgeReset();
  f.send(0,[p(1,200,200,200)],[p(1,200,200,200)],'left');
  f.send(2,[p(1,900,900,100)],[p(1,900,900,100)],'left');
  assert.equal(f.model.hasContact(1,200),true);assert.deepEqual(f.deltas,[]);
  f.send(3,[p(1,999,999,200)],[p(1,999,999,200)],'left');
  assert.deepEqual(f.deltas,[]);assert.equal(f.model.activeContacts(),false);assert.equal(f.model.down(-1),false);
});
check('真实游戏引导：标题菜单不启动、旧事件不计入、抬手后自动推进',()=>{
  const g=new TouchGuide(),f=new TouchGuideFeedback();f.available=true;f.movement=3;
  assert.equal(g.start(f),false);f.grabbed=true;f.fingers=1;assert.equal(g.start(f),false);
  f.fingers=0;assert.equal(g.start(f),true);assert.equal(g.observe(f),false);
  f.movement++;f.fingers=1;assert.equal(g.observe(f),false);f.fingers=0;assert.equal(g.observe(f),true);
  assert.equal(g.step,TouchGuideStep.Hotbar);f.hotbar++;f.slot=3;assert.equal(g.observe(f),false);
  f.hotbar++;f.slot=4;assert.equal(g.observe(f),true);assert.equal(g.step,TouchGuideStep.Menu);
  assert.equal(g.beginScroll(f,true),false);f.grabbed=false;assert.equal(g.beginScroll(f,false),false);
  assert.equal(g.beginScroll(f,true),true);f.scroll++;f.scrollAmount=-1;assert.equal(g.observe(f),false);
  f.scroll++;f.scrollAmount=-3;assert.equal(g.observe(f),true);assert.equal(g.step,TouchGuideStep.Mouse);
  f.mouseMove++;f.mouseButton++;f.mouseCode=-1;assert.equal(g.observe(f),false);
  f.mouseButton++;f.mouseCode=-2;assert.equal(g.observe(f),true);assert.equal(g.step,TouchGuideStep.Done);

  assert.equal(g.step,TouchGuideStep.Done);g.stop();assert.equal(g.observe(f),false);
});
check('帮助仅由明确请求启动，后台返回恢复请求且最后一步显示5/5',()=>{
  let requested=false,opened=0;
  const controls=component('entry/src/main/ets/components/GameControls.ets','GameControls',
    ['onPageActiveChanged','maybeOpenLearning'],{});
  Object.assign(controls,{pageActive:true,isGrabbed:true,editing:false,learningRequested:false,learningSeen:false,
    touchSurface:{setActive(){}},touchSession:{setActive(){}},touchGuide:{stop(){},baseline(){}},
    touchVisual:{guide:{grabbed:true}},learningStore:{requested:()=>requested},hasContinuousControlInteraction:()=>false,
    syncGuideBounds(){},resetTransientInputState(){},openLearning(){opened++;this.learningRequested=false;}});
  controls.onPageActiveChanged();assert.equal(opened,0,'首次显示不能自动开启');
  requested=true;controls.onPageActiveChanged();assert.equal(opened,1);
  const view=component('entry/src/main/ets/components/TouchLearningView.ets','TouchLearningView',['progressLabel'],{});
  view.step=TouchGuideStep.Mouse;assert.equal(view.progressLabel(),'5 / 5');
});
check('输入快照兼容前缀与换代：缺反馈不假完成，schema更换清旧观察基线',()=>{
  assert.equal(parseTouchGuideFeedback(Array(15).fill(0)).available,false);
  const raw=Array(25).fill(0);raw[24]=1;raw[17]=-1;
  const f=parseTouchGuideFeedback(raw);assert.equal(f.available,true);assert.equal(f.grabbed,true);
  const g=new TouchGuide();assert.equal(g.start(f),true);
  f.generation++;f.movement++;assert.equal(g.observe(f),false);assert.equal(g.observe(f),false);
  f.movement++;assert.equal(g.observe(f),true);
  raw[23]=11;assert.equal(parseTouchGuideFeedback(raw).available,false);
});
check('真实引导开关不暂停、不重置游戏，也不松开用户按住的控件',()=>{
  const calls=[],f=new TouchGuideFeedback();f.available=true;f.grabbed=true;
  const view=component('entry/src/main/ets/components/GameControls.ets','GameControls',
    ['openLearning','closeLearning','syncGuideBounds','guideToolbarX','guideLayout','syncGuideObservation'],
    {testNapi:{setTouchGuideBounds:()=>{calls.push('bounds');return true;}},
      touchGuideLayout:guideGeometry.touchGuideLayout,TouchGuideStep,hasEntryTouchModal:()=>false});
  Object.assign(view,{tutorialOpen:false,editing:false,mounted:true,touchGuide:new TouchGuide(),touchVisual:{guide:f},
    learningSeen:false,isGrabbed:true,guideTarget:()=>new controlGeometry.TouchControlRect(),
    registerRegions:()=>calls.push('regions'),touchSession:{refreshVisual:()=>calls.push('visual'),setGuideActive(){}},
    pageActive:true,compWidth:1280,compHeight:720,density:2,guideBoundsKey:'',
    runtimeLayout:{context:{key:'surface'}},uiPublicationToken:'token',imeOpen:false,fieldImeOpen:false,
    learningStore:{markSeen:()=>calls.push('seen'),markClosed:()=>calls.push('closed')},
    onInputPause(){throw Error('引导不得暂停输入')},resetTransientInputState(){throw Error('引导不得清真实持有')}});
  view.openLearning();assert.equal(view.tutorialOpen,true);assert.equal(view.touchGuide.active,true);
  // 编辑器仍持有自己的暂停租约时关闭教学，不能代替保存/取消退出事务。
  view.editing=true;view.editorLeaseHeld=true;view.editorInputPaused=true;
  view.closeLearning();assert.equal(view.tutorialOpen,false);assert.equal(view.touchGuide.active,false);
  assert.equal(view.editing,true);assert.equal(view.editorLeaseHeld,true);assert.equal(view.editorInputPaused,true);
  assert.deepEqual(calls,['seen','bounds','visual','closed','bounds']);
});
/** 教学显隐回归走真实发布及确认；夹具控制Native/SDK边缘，确认、准入及绑定执行生产方法。 */
function guideSchemaContract(sourceOverrides={}) {
  const schemas=[],installedSchemas=[];
  const surface=new surfaceModel.InputSurfaceContext();
  Object.assign(surface,{provisional:false,widthPx:2560,heightPx:1440,density:2,transform:0,
    validFields:surfaceModel.INPUT_SURFACE_FIELD_RECT|surfaceModel.INPUT_SURFACE_FIELD_DENSITY});
  const pure=makePureEtsLoader({commons:{AppLogger:{warn(){}}}},sourceOverrides);
  const game=Object.assign({},layout,runtimeGeometry,...['TouchPreferences','TouchActionBindings','InputConfiguration']
    .map(name=>pure('gamecontrol/src/main/ets/'+name+'.ets')));
  let allowConfirmation=false,confirmations=0,presentations=0;
  let state={version:1,status:'idle',surface:'7',session:'3',policy:'1',schemaGeneration:'1',grabEpoch:'1',grabbed:true,
    token:'',operationId:'',candidateId:'',fenced:false,nativeTouches:0,density:2,transform:0};
  // 替身只返回原operation/candidate的回执，不计算JS Applied或替控制器分配身份。
  const native={touchPublicationState:()=>({...state}),beginTouchPublication:(operationId,candidateId)=>{
    state={...state,status:'fenced',fenced:true,operationId,candidateId,token:'native-publication-1'};return {...state};},
    publishTouchSchema:schema=>{installedSchemas.push(structuredClone(schema));state={...state,status:'committed'};return {...state};},
    confirmTouchPublication:(operationId,token)=>{
      assert.equal(operationId,state.operationId);assert.equal(token,state.token);confirmations++;
      if(!allowConfirmation)return false;state={...state,status:'idle',fenced:false};return true;}};
  const env=environment({imports:{gamecontrol:game,'libentry.so':{__esModule:true,default:native}}});
  const {TouchSurfaceController,TouchSurfaceCandidate}=env.load('entry/src/main/ets/components/TouchSurfaceController.ets');
  const maintenance=env.load('entry/src/main/ets/components/EntryTouchInputMaintenance.ets');
  const originLease=maintenance.startEntryTouchInputMaintenance();
  const view=component('entry/src/main/ets/components/GameControls.ets','GameControls',
    ['sendControlSchema','addUiBlock','clampEntryRect','guideToolbarX',
      'presentTouchCandidate_','confirmTouchLayout_','touchNodeId_','touchMarkerId_',
      'retireHiddenMouse_','mouseEntryVisible_','mouseEntryPresented_','closeMouse'],{
      ControlType:layout.ControlType,effectiveKeys:layout.effectiveKeys,DEFAULT_JOYSTICK_DEAD_ZONE:.18,
      cloneLayout:layout.cloneLayout,...runtimeGeometry,layoutCapabilityIssue:load('gamecontrol/src/main/ets/LayoutCandidate.ets').layoutCapabilityIssue,
      TouchControlRect:controlGeometry.TouchControlRect,
      TouchSurfaceCandidate,getInputSurfaceContextStore:()=>({snapshot:()=>surface}),
      hasEntryTouchModal:()=>false,releaseEntryTouchModal:()=>true,
      hilog:{error:()=>{},warn:()=>{}},GAME_CONTROLS_TAG:'test'
    },sourceOverrides);
  const profile=layout.getDefaultLayout();
  // 真实Store保存后的方案带这两个字段；为冻结候选赋合法固定身份，完成断言同时核实来源修订。
  profile.profileId='touch-basics-confirmed';profile.profileRevision=1;
  Object.assign(view,{schemaActive:true,compWidth:1280,compHeight:720,density:2,profile,drawerOpen:new Map(),
    desiredProfile:profile,guiState:new gui.GameGuiState(),globalVisMode:0,
    mounted:true,pageActive:true,layoutObserverRegistered:true,appearanceGeneration:1,profileVer:0,
    uiPublicationToken:'',presentedCandidateId:'',unresolvedSurfaceModal:undefined,syncMouseBounds(){},syncGuideBounds(){},
    isGrabbed:true,tutorialOpen:false,guiHint:false,editing:false,realGameVersion:'26.4-snapshot-1',
    displayedControls:()=>profile.controls,isControlVisible:()=>true,
    itemX:item=>controlGeometry.touchControlX(item,1280),itemY:item=>controlGeometry.touchControlY(item,720),
    itemW:item=>controlGeometry.touchControlWidth(item,profile),itemH:item=>controlGeometry.touchControlHeight(item,profile),
    triggerCode:()=>0
  });
  // 原Session的绑定采用与纯schema投影逐字执行；原维护scope由生产模块创建，不能返回假current。
  view.touchSession=component('entry/src/main/ets/components/EntryTouchSession.ets','EntryTouchSession',
    ['schemaOptions','adoptConfirmedTouchBindings','actionKeys','setRuntimeContext','setGuiViewport','setTouchAdmission'],
    {...game,isEntryTouchInputMaintenanceCurrent:maintenance.isEntryTouchInputMaintenanceCurrent},sourceOverrides);
  Object.assign(view.touchSession,{bindings:new game.TouchBindingSnapshot(),follow:false,bindingActivation:'',originLease,
    bindingOptionsText:'key_key.forward:key.keyboard.r',touchAdmitted:true});
  view.getUIContext=()=>({vp2px:n=>n*2,getComponentUtils:()=>({getRectangleById:id=>{
    if(id===view.touchMarkerId_())return {size:{width:2,height:2}};
    const entry=view.runtimeLayout.entries.find(item=>view.touchNodeId_(item.item.id)===id);assert.ok(entry,id);
    return {size:{width:entry.rectPx.width,height:entry.rectPx.height},localOffset:{x:entry.rectPx.x,y:entry.rectPx.y}};
  }})});
  view.touchSurface=new TouchSurfaceController((candidate,token)=>{
    presentations++;view.presentTouchCandidate_(candidate,token);
  },()=>0,()=>{});
  // 只观察真实控制器入口，原request及其this完整转发；相同schema不重复安装仍须逐次比较请求值。
  const request=view.touchSurface.request;
  view.touchSurface.request=function(candidate){schemas.push(structuredClone(candidate.schema));return request.call(this,candidate);};
  assert.equal(view.sendControlSchema(),false,'Native安装后仍等待原UI确认');
  assert.deepEqual([view.touchSession.guiWidth,view.touchSession.guiHeight,view.touchSession.rotation,view.touchSession.guiVersion],
    [2560,1440,0,'26.4-snapshot-1'],'原Session的视口setter采用本候选真实px及版本');
  const completion=view.touchSurface.status();
  assert.equal(completion.reason,'UiConfirmation');assert.equal(view.touchSurface.admits(completion.token),false);
  assert.equal(view.touchSession.bindingActivation,'','候选请求不能提前采用绑定');
  view.confirmTouchLayout_();assert.equal(confirmations,1);assert.equal(view.touchSession.bindingActivation,'',
    'Native确认失败不能采用绑定');
  allowConfirmation=true;view.confirmTouchLayout_();assert.equal(confirmations,2);
  assert.equal(view.touchSession.actionKeys()[0],82,'CONFIRMED_BINDINGS_ADOPTED');
  assert.deepEqual(JSON.parse(view.touchSession.bindingActivation),
    [profile.profileId,profile.profileRevision,completion.operationId,completion.desiredCandidateId,completion.token]);
  assert.equal(view.touchSurface.admits(completion.token),true);
  // 已确认的等价请求才可同步成功；教学开关不得申请新发布、退休owner或借新token换绑定。
  view.tutorialOpen=true;assert.equal(view.sendControlSchema(),true);
  view.tutorialOpen=false;assert.equal(view.sendControlSchema(),true);
  // 原生生产回归另证实真正的schema变化会释放旧owner；这里约束真实UI不能把教学显隐冒充布局变化。
  assert.deepEqual(schemas[1],schemas[0]);assert.deepEqual(schemas[2],schemas[0]);
  assert.equal(schemas.length,3);assert.equal(installedSchemas.length,1);assert.equal(presentations,1);assert.equal(confirmations,2);
  assert.equal(view.touchSurface.token(),completion.token);
  assert.equal(view.touchSurface.status().desiredCandidateId,completion.desiredCandidateId);
  assert.equal(view.touchSession.actionKeys()[0],82);
  maintenance.stopEntryTouchInputMaintenance(originLease);
}
check('引导显隐不改变真实游戏schema，避免仅关闭提示就退休已按住或锁定的控件',()=>guideSchemaContract());
check('撤回真实UI确认的绑定采用必须命中行为断言，不能由等价请求补成假成功',()=>{
  const file='entry/src/main/ets/components/GameControls.ets',text=fs.readFileSync(path.join(root,file),'utf8');
  const before='this.touchSession.adoptConfirmedTouchBindings(candidate.profile,candidate.schema.touch,completedOperation,candidate.id,token)';
  assert.equal(text.split(before).length-1,1,'负控只撤回唯一原确认接点');
  const withdrawn=text.replace(before,'void candidate');
  assert.throws(()=>guideSchemaContract({[file]:withdrawn}),error=>error instanceof assert.AssertionError&&
    error.message.includes('CONFIRMED_BINDINGS_ADOPTED'),'必须编译成功并在确认后的绑定断言失败');
});
check('引导组件销毁仅停止动画，不能调用游戏输入或控制器释放',()=>{
  const calls=[];
  const view=component('entry/src/main/ets/components/TouchLearningView.ets','TouchLearningView',
    ['aboutToDisappear','stopAnimation'],{clearInterval:id=>calls.push(id)});
  view.mounted=true;view.timer=5;view.aboutToDisappear();view.aboutToDisappear();
  assert.equal(view.mounted,false);assert.equal(view.timer,-1);assert.deepEqual(calls,[5]);
});
check('菜单准备没有虚构指针，只有实际移动示范开启动画时钟',()=>{
  const view=component('entry/src/main/ets/components/TouchLearningView.ets','TouchLearningView',
    ['validTarget','pointAtTarget','needsAnimation'],{TouchGuideStep});
  Object.assign(view,{target:{width:500,height:300},step:TouchGuideStep.Menu,grabbed:false});
  assert.equal(view.pointAtTarget(),false);assert.equal(view.needsAnimation(),false);
  view.grabbed=true;assert.equal(view.pointAtTarget(),true);assert.equal(view.needsAnimation(),false);
  view.step=TouchGuideStep.Scroll;view.grabbed=false;
  assert.equal(view.pointAtTarget(),true);assert.equal(view.needsAnimation(),true);
  view.step=TouchGuideStep.Hotbar;assert.equal(view.needsAnimation(),false);
  view.target.width=0;assert.equal(view.pointAtTarget(),false);
});
check('帮助结束无需修改或保存用户布局',()=>{
  const guide=new TouchGuide(),feedback=new TouchGuideFeedback();guide.active=true;guide.step=TouchGuideStep.Mouse;
  guide.skip(feedback);assert.equal(guide.step,TouchGuideStep.Done);
});
check('原生复位经真实控制面清空鼠标持有，面板同步取消且不补发输入',()=>{
  // Native账本已经退休的边界由平台替身表示；实际控制面方法与鼠标模型都取生产源码。
  const sent=[];
  const model=new VirtualMouseModel({move:()=>true,wheel:()=>true,button:(owner,code,down)=>{sent.push([owner,code,down]);return true;},cancel:()=>true});
  model.toggle(-1);model.startPad(4,0,0);
  const controls=component('entry/src/main/ets/components/GameControls.ets','GameControls',['dropHeldCacheAfterNativeReset']);
  Object.assign(controls,{mouseController:{model},mouseResetRevision:0,btnPressedVer:0,
    controlClient:{dropAfterNativeReset(){}},cancelDirectionLatch(){},activeKeys:new Set(),longPressFired:new Set(),
    toggleStates:new Set(),accessibilityToggleStates:new Map()});
  for(const name of ['buttonFingerIds','arktsButtonOutputs','btnVisMap','longPressTimers','lastTapAt',
    'scrollFingerIds','scrollAccumDy','scrollLastY','hotbarFingerId','hotbarLastSlot','dragLookFinger','dragLookLastX','dragLookLastY']) controls[name]=new Map();
  controls.dropHeldCacheAfterNativeReset();
  assert.equal(model.locked(-1),false);assert.equal(model.movePad(4,12,0),false);
  assert.equal(controls.mouseResetRevision,1);assert.equal(sent.length,1,'已退休owner不得再发一次UP');
  const panel=component('entry/src/main/ets/components/VirtualMousePanel.ets','VirtualMousePanel',['onModelReset','refreshHeld']);
  Object.assign(panel,{model,leftDown:true,rightDown:true,shiftLock:true});
  panel.onModelReset();assert.equal(model.activeContacts(),false);assert.equal(panel.leftDown,false);assert.equal(panel.shiftLock,false);
  assert.equal(sent.length,1);
});
check('解除与取消的真实选择器结果不同，显式未绑定可保存且不回退旧键',()=>{
  const picker=component('entry/src/main/ets/components/KeyPickerSheet.ets','KeyPickerSheet',['confirmChoice']);
  let result='unset';picker.onPick=value=>{result=value;};picker.pickedKeys=[];picker.confirmChoice();assert.deepEqual(result,[]);
  const p=layout.getDefaultLayout();const item=p.controls.find(c=>c.type===layout.ControlType.BUTTON&&!c.systemAction);
  const editor=component('entry/src/main/ets/components/LayoutEditor.ets','LayoutEditor',['applyKeys'],
    {glfwKeyName:String,MAX_LAYOUT_CONTROL_KEYS:layout.MAX_LAYOUT_CONTROL_KEYS});
  editor.selectedItem=()=>item;editor.pushUndo=()=>{};editor.refreshControls=()=>{};editor.applyKeys([]);
  assert.equal(item.keyOrMouse,0);assert.deepEqual(layout.effectiveKeys(item),[]);assert.ok(layout.validateAndNormalizeLayout(p));
  item.keys=undefined;assert.equal(layout.validateAndNormalizeLayout(p),null,'missing output must not silently become unbound');
});
check('低高度横屏的编辑器与改键弹窗保留可达的保存/取消区域',()=>{
  const editor=component('entry/src/main/ets/components/LayoutEditor.ets','LayoutEditor',
    ['compactPanel','panelChromeH','panelMinContentH','panelTopBase','panelContentMaxH']);
  for(const height of [180,240,320,360,480,720]) {
    Object.assign(editor,{screenHeight:height,panelY:12,panelDragDy:0});
    assert.ok(editor.panelTopBase()+editor.panelChromeH()+editor.panelContentMaxH()+8<=height,
      `编辑器底栏超出${height}vp视口`);
  }
  const picker=component('entry/src/main/ets/components/KeyPickerSheet.ets','KeyPickerSheet',['panelW','panelH']);
  for(const [width,height] of [[240,180],[360,240],[720,360],[1280,720]]) {
    Object.assign(picker,{availableWidth:width,availableHeight:height});
    assert.ok(picker.panelW()<=width-24&&picker.panelH()<=height-24,'改键弹窗越出视口');
  }
});
/**
 * 执行摇杆Builder登记的真实onTouch闭包。仅替换SDK事件值和Native视觉读取出口，
 * 不复制分支；高采样率MOVE必须依靠已有快照时钟，不能触发同样多次同步跨语言读取。
 */
function nativeJoystickVisualBudget(rewrite=text=>text) {
  const file='entry/src/main/ets/components/GameControls.ets';
  const text=rewrite(fs.readFileSync(path.join(root,file),'utf8'));
  const ast=compiler.createSourceFile(file,text,compiler.ScriptTarget.Latest,true);
  const owner=ast.statements.find(node=>node.name?.getText(ast)==='GameControls');
  const builder=owner.members.find(node=>node.name?.getText(ast)==='JoystickView');
  let callback;
  const visit=node=>{
    if(compiler.isCallExpression(node)&&compiler.isPropertyAccessExpression(node.expression)&&
      node.expression.name.getText(ast)==='onTouch') callback=node.arguments[0].getText(ast);
    compiler.forEachChild(node,visit);
  };
  visit(builder);assert.ok(callback,'必须找到生产摇杆事件入口');
  const output=compiler.transpileModule('module.exports='+callback+';',{
    compilerOptions:{target:compiler.ScriptTarget.ES2020,module:compiler.ModuleKind.CommonJS},reportDiagnostics:true});
  assert.equal((output.diagnostics??[]).filter(d=>d.category===compiler.DiagnosticCategory.Error).length,0);
  let reads=0;
  const view={isPointerSourcedTouch:()=>false,admitTouchUi_:()=>true,cOwnsJoystick:()=>true,
    touchSession:{refreshVisual:()=>reads++}};
  const TouchType={Down:0,Up:1,Move:2,Cancel:3},module={exports:{}};
  new Function('module','TouchType','$$',output.outputText).call(view,module,TouchType,{token:'presented',groupEpoch:'1',
    item:layout.getDefaultLayout().controls.find(item=>item.type===layout.ControlType.JOYSTICK)});
  module.exports({type:TouchType.Down});assert.equal(reads,1);
  for(let i=0;i<240;i++)module.exports({type:TouchType.Move});
  assert.equal(reads,1,'NATIVE_MOVE_MUST_NOT_POLL_VISUAL');
  module.exports({type:TouchType.Up});assert.equal(reads,2,'终止边沿保留即时视觉回读');
}
check('Native摇杆240次MOVE不额外读取视觉，DOWN/UP仍及时反馈',()=>{
  nativeJoystickVisualBudget();
  assert.throws(()=>nativeJoystickVisualBudget(text=>text.replace(
    'if (event.type !== TouchType.Move) this.touchSession.refreshVisual()',
    'this.touchSession.refreshVisual()')),/NATIVE_MOVE_MUST_NOT_POLL_VISUAL/);
});
/**
 * 从真实组件链式回调/子组件入参取原箭头，只在宿主替换平台边缘；回调正文不复制进测试。
 * 这使选择器是否传错allowCombo、Slider是否丢弃mode都进入回归范围，而非只测一个孤立辅助函数。
 */
function originalComponentCallback(file,type,memberName,predicate,subject,dependencies={}) {
  const ast=compiler.createSourceFile(file,fs.readFileSync(path.join(root,file),'utf8'),compiler.ScriptTarget.Latest,true);
  const owner=ast.statements.find(node=>node.name?.getText(ast)===type);
  const member=owner.members.find(node=>node.name?.getText(ast)===memberName);
  assert.ok(member,memberName);let selected;
  const visit=node=>{if(predicate(node,ast))selected=node;compiler.forEachChild(node,visit);};visit(member);
  assert.ok(selected,'必须找到真实生产回调');
  const source=selected.getText(ast);
  const compiled=compiler.transpileModule('module.exports='+source+';',{
    compilerOptions:{target:compiler.ScriptTarget.ES2020,module:compiler.ModuleKind.CommonJS},reportDiagnostics:true});
  assert.equal((compiled.diagnostics??[]).filter(item=>item.category===compiler.DiagnosticCategory.Error).length,0);
  const module={exports:{}};new Function('module',...Object.keys(dependencies),compiled.outputText)
    .call(subject,module,...Object.values(dependencies));return module.exports;
}
const editorFile='entry/src/main/ets/components/LayoutEditor.ets';
const settingsFile='entry/src/main/ets/components/InputSettingsEditor.ets';
const pickerFile='entry/src/main/ets/components/KeyPickerSheet.ets';
const sliderModes={Begin:0,Moving:1,End:2,Click:3};

check('普通组合第7键即时拒绝并保留合法6键，宿主异常回调也不污染整份草稿',()=>{
  const p=layout.getDefaultLayout(),item=p.controls.find(c=>c.type===layout.ControlType.BUTTON&&!c.systemAction);
  const editor=component(editorFile,'LayoutEditor',['applyKeys'],
    {glfwKeyName:String,MAX_LAYOUT_CONTROL_KEYS:layout.MAX_LAYOUT_CONTROL_KEYS});
  Object.assign(editor,{selectedItem:()=>item,pushUndo(){},refreshControls(){}});
  const picker=component(pickerFile,'KeyPickerSheet',['toggleKey','confirmChoice'],
    {MAX_LAYOUT_CONTROL_KEYS:layout.MAX_LAYOUT_CONTROL_KEYS});
  let confirmations=0;Object.assign(picker,{allowCombo:true,comboMode:true,pickedKeys:[],onPick:keys=>{confirmations++;editor.applyKeys(keys);}});
  for(const key of [65,66,67,68,69,70,71])picker.toggleKey(key);
  assert.deepEqual(picker.pickedKeys,[65,66,67,68,69,70]);assert.match(picker.selectionMessage,/最多支持6/);
  picker.confirmChoice();assert.equal(confirmations,1);assert.ok(layout.validateAndNormalizeLayout(p));
  const oldKeys=[...item.keys];editor.applyKeys([65,66,67,68,69,70,71]);assert.deepEqual(item.keys,oldKeys);
  assert.match(editor.statusMsg,/最多支持6/);assert.ok(layout.validateAndNormalizeLayout(p));
  picker.pickedKeys=[65,66,67,68,69,70,71];picker.confirmChoice();assert.equal(confirmations,1);
  picker.toggleKey(66);picker.toggleKey(71);assert.equal(picker.pickedKeys.length,5);
  picker.toggleKey(72);picker.confirmChoice();assert.equal(confirmations,2);assert.ok(layout.validateAndNormalizeLayout(p));
});

check('手柄改键真实入参禁组合且真实回调拒绝多键，单键与解绑仍能保存',()=>{
  const source=fs.readFileSync(path.join(root,settingsFile),'utf8'),ast=compiler.createSourceFile(settingsFile,source,compiler.ScriptTarget.Latest,true);
  let properties;
  const visit=node=>{if(compiler.isCallExpression(node)&&node.expression.getText(ast)==='KeyPickerSheet'&&
    node.arguments[0]?.getText(ast).includes('gamepadBtnCurrentKeys'))properties=node.arguments[0];compiler.forEachChild(node,visit);};visit(ast);
  assert.equal(properties.properties.find(node=>node.name?.getText(ast)==='allowCombo')?.initializer.getText(ast),'false');
  const editor=component(settingsFile,'InputSettingsEditor',['applyGamepadKey','ensureButtonMap','gamepadBtnDisplayName','gamepadActionLabel'],
    {glfwKeyName:String,defaultGamepadButtonMap:layout.defaultGamepadButtonMap});
  Object.assign(editor,{gamepad:layout.defaultGamepadConfig(),gamepadBtnPicker:'A',pushUndo(){},cloneGamepad:value=>structuredClone(value)});
  const onPick=originalComponentCallback(settingsFile,'InputSettingsEditor','build',(node,tree)=>
    compiler.isArrowFunction(node)&&node.getText(tree).includes('const button: string=this.gamepadBtnPicker'),editor);
  const before=structuredClone(editor.gamepad.buttonMap.A);onPick([341,81]);assert.deepEqual(editor.gamepad.buttonMap.A,before);
  assert.equal(editor.gamepadBtnPicker,'A');assert.match(editor.statusMsg,/只支持单键/);
  onPick([81]);assert.deepEqual(editor.gamepad.buttonMap.A,{kind:'key',code:81});assert.equal(editor.gamepadBtnPicker,'');
  editor.gamepadBtnPicker='A';onPick([]);assert.deepEqual(editor.gamepad.buttonMap.A,{kind:'none'});assert.equal(editor.statusMsg,'A → 无');
});

check('Pojav抽屉孩子保留菜单场景，强隐与解绑不再进入投影占用热区',()=>{
  const importer=load('gamecontrol/src/main/ets/ExternalLayoutImporter.ets');
  const candidates=load('gamecontrol/src/main/ets/LayoutCandidate.ets');
  const source={mDrawerDataList:[{properties:{name:'drawer',width:48,height:48,x:200,y:120,displayInGame:true,displayInMenu:true},
    buttonProperties:[{name:'menu Q',width:48,height:48,x:200,y:120,keycodes:[81],displayInGame:false,displayInMenu:true}]}]};
  const review=importer.analyzeExternalLayout(JSON.stringify(source),'drawer',720,360);assert.ok(review.profile,review.reason);
  const checked=candidates.buildLayoutCandidate(review.profile);assert.ok(checked.profile,checked.reason);
  const profile=checked.profile,parent=profile.controls.find(c=>c.type===layout.ControlType.DRAWER),child=parent.children[0];
  const context=new runtimeGeometry.RuntimeTouchContext();Object.assign(context,{valid:true,density:2,widthPx:1440,heightPx:720});
  const frame=(p,grabbed)=>runtimeGeometry.projectRuntimeTouchLayout(p,context,new gui.GameGuiState(),grabbed,0,new Map([[parent.id,true]]));
  assert.equal(child.menuOnly,true);assert.equal(frame(profile,true).find(child.id),undefined);assert.ok(frame(profile,false).find(child.id));
  for(const patch of [{visibilityOverride:'force_hide'},{keys:[],keyOrMouse:0}]) {
    const copy=layout.cloneLayout(profile);Object.assign(copy.controls.find(c=>c.id===parent.id).children[0],patch);
    assert.ok(candidates.buildLayoutCandidate(copy).profile);assert.equal(frame(copy,false).find(child.id),undefined);
  }
});

check('强显覆盖场景和全局档，显式隐藏与解绑及菜单不支持的专用控件仍无热区',()=>{
  const profile=layout.getDefaultLayout(),button=profile.controls.find(c=>c.type===layout.ControlType.BUTTON&&!c.systemAction);
  button.grabbedOnly=true;button.menuOnly=false;button.visibilityOverride='auto';
  assert.equal(runtimeGeometry.runtimeTouchControlVisible(button,false,0),false);
  button.visibilityOverride='force_show';assert.equal(runtimeGeometry.runtimeTouchControlVisible(button,false,0),true);
  assert.equal(runtimeGeometry.runtimeTouchControlVisible(button,true,2),true);
  button.hidden=true;assert.equal(runtimeGeometry.runtimeTouchControlVisible(button,true,2),false);button.hidden=false;
  button.keys=[];button.keyOrMouse=0;assert.equal(runtimeGeometry.runtimeTouchControlVisible(button,true,2),false);
  for(const type of [layout.ControlType.JOYSTICK,layout.ControlType.HOTBAR_SELECTOR,layout.ControlType.SCROLL_WHEEL]) {
    button.type=type;assert.equal(runtimeGeometry.runtimeTouchControlVisible(button,false,0),false);
  }
});

check('普通抽屉按钮交给Native解释，ArkUI不重复发送键与视角',()=>{
  const view=component('entry/src/main/ets/components/GameControls.ets','GameControls',
    ['handleDrawerChildTouch','handleButtonTouch','touchInItem','cOwnsButton','releaseControlInputs'],
    {ControlType:layout.ControlType,TouchType:{Down:0,Up:1,Move:2,Cancel:3}});
  const item={...layout.getDefaultLayout().controls.find(c=>c.type===layout.ControlType.BUTTON&&!c.systemAction),id:'drawer-child',dragLook:true};
  const effects=[];Object.assign(view,{isPointerSourcedTouch:()=>false,schemaActive:true,schemaTakeoverButtons:true,isGrabbed:true,
    profile:{controls:[]},runtimeLayout:{find:id=>({handledBy:0})},itemW:()=>48,itemH:()=>48,buttonAddFinger:(_item,id)=>effects.push(['down',id]),
    buttonRemoveFinger:(_item,id)=>effects.push(['up',id]),emitDragLookVp:(...args)=>effects.push(['look',...args])});
  for(const name of ['dragLookFinger','dragLookLastX','dragLookLastY','buttonFingerIds','longPressTimers',
    'arktsButtonOutputs','accessibilityToggleStates','lastTapAt','btnVisMap'])view[name]=new Map();
  view.toggleStates=new Set();view.longPressFired=new Set();
  view.handleDrawerChildTouch(item,{type:0,changedTouches:[{id:7,x:10,y:10}],touches:[{id:7,x:10,y:10}]});
  // touches[0]刻意是另一根手指；真实按钮方法必须只用DOWN时的7号触指计算位移。
  view.handleDrawerChildTouch(item,{type:2,changedTouches:[{id:8,x:1,y:1}],touches:[{id:8,x:1,y:1},{id:7,x:25,y:30}],timestamp:400});
  view.handleDrawerChildTouch(item,{type:1,changedTouches:[{id:7,x:25,y:30}],touches:[]});
  assert.deepEqual(effects,[]);assert.equal(view.dragLookFinger.has(item.id),false);
  view.handleDrawerChildTouch(item,{type:0,changedTouches:[{id:9,x:10,y:10}],touches:[]});
  view.releaseControlInputs(item.id);assert.equal(view.dragLookFinger.has(item.id),false);
  assert.equal(view.dragLookLastX.has(item.id),false);assert.equal(view.dragLookLastY.has(item.id),false);
});

check('单个与批量复制超视口合法大控件都保持零下界且整份布局可保存',()=>{
  for(const bulk of [false,true]) {
    const profile=layout.getDefaultLayout();profile.controls=profile.controls.filter(c=>c.type===layout.ControlType.BUTTON&&!c.systemAction).slice(0,1);
    Object.assign(profile.controls[0],{baseWidth:200,baseHeight:200,itemScale:2,xPct:0,yPct:0});profile.globalScale=2;
    assert.ok(layout.validateAndNormalizeLayout(profile));
    const editor=component(editorFile,'LayoutEditor',['duplicateSelected','batchDuplicate','selectedItem','itemW','itemH'],
      {cloneItemWithFreshIds:layout.cloneItemWithFreshIds});
    Object.assign(editor,{controls:profile.controls,selectedIdx:0,globalScale:2,screenWidth:720,screenHeight:360,pushUndo(){},refreshControls(){},
      multiSelectedItems:()=>[profile.controls[0]]});
    if(bulk)editor.batchDuplicate();else editor.duplicateSelected();
    assert.equal(editor.controls.length,2);assert.equal(editor.controls[1].xPct,0);assert.equal(editor.controls[1].yPct,0);
    assert.ok(layout.validateAndNormalizeLayout(profile));
  }
});

check('真实全局缩放Slider两次拖动分两步撤销，同值End和离散Click正确收口',()=>{
  const editor=component(editorFile,'LayoutEditor',['beginSliderUndo','prepareSliderChange'],{SliderChangeMode:sliderModes});
  const snapshots=[];Object.assign(editor,{sliderUndoKey:'',globalScale:1,refreshControls(){},pushUndo(){snapshots.push(this.globalScale);this.sliderUndoKey='';}});
  const onChange=originalComponentCallback(editorFile,'LayoutEditor','EditTabContent',(node,tree)=>
    compiler.isArrowFunction(node)&&node.getText(tree).includes("prepareSliderChange('globalScale'"),editor);
  onChange(100,sliderModes.Begin);onChange(80,sliderModes.Moving);onChange(80,sliderModes.End);
  onChange(80,sliderModes.Begin);onChange(60,sliderModes.Moving);onChange(60,sliderModes.End);
  assert.deepEqual(snapshots,[1,.8]);assert.equal(editor.globalScale,.6);assert.equal(editor.sliderUndoKey,'');
  onChange(70,sliderModes.Click);onChange(90,sliderModes.Click);assert.deepEqual(snapshots,[1,.8,.6,.7]);
  onChange(90,sliderModes.End);assert.equal(snapshots.length,4);
});

check('触控选项原Slider阶段贯通至宿主，重复值结束不丢下一手势撤销点',()=>{
  const touch=load('gamecontrol/src/main/ets/TouchPreferences.ets');
  const editor=component(settingsFile,'InputSettingsEditor',['applyTouchChange','prepareSliderChange','beginSliderUndo'],
    {normalizeTouchPreferences:touch.normalizeTouchPreferences,SliderChangeMode:sliderModes});
  const snapshots=[];Object.assign(editor,{touch:new touch.TouchConfiguration(),sliderUndoKey:'',pushUndo(){snapshots.push(this.touch.menuSensitivity);this.sliderUndoKey='';}});
  const panel=component('entry/src/main/ets/components/TouchOptionsEditor.ets','TouchOptionsEditor',['number','commit'],
    {normalizeTouchPreferences:touch.normalizeTouchPreferences,TouchConfiguration:touch.TouchConfiguration});
  Object.assign(panel,{value:editor.touch,onChange:(value,key,mode)=>{editor.applyTouchChange(value,key,mode);panel.value=editor.touch;}});
  const widget={onChange:(value,mode)=>panel.number('menuSpeed',value,mode)};
  const onChange=originalComponentCallback('entry/src/main/ets/components/TouchOptionsEditor.ets','TouchOptionSlider','build',
    (node,tree)=>compiler.isArrowFunction(node)&&node.getText(tree).includes('this.onChange(value,mode)'),widget);
  onChange(100,sliderModes.Begin);onChange(130,sliderModes.Moving);onChange(130,sliderModes.End);
  onChange(130,sliderModes.Begin);onChange(150,sliderModes.Moving);onChange(150,sliderModes.End);
  assert.deepEqual(snapshots,[1,1.3]);assert.equal(editor.touch.menuSensitivity,1.5);assert.equal(editor.sliderUndoKey,'');
});

check('共享指针速度选项的真实菜单分支在直接操作和触摸板模式均可达',()=>{
  const file='entry/src/main/ets/components/TouchOptionsEditor.ets';
  const ast=compiler.createSourceFile(file,fs.readFileSync(path.join(root,file),'utf8'),compiler.ScriptTarget.Latest,true);
  const owner=ast.statements.find(node=>node.name?.getText(ast)==='TouchOptionsEditor');
  const build=owner.members.find(node=>node.name?.getText(ast)==='build');let speed;
  const visit=node=>{if(compiler.isCallExpression(node)&&node.expression.getText(ast)==='TouchOptionSlider'&&
    node.arguments[0]?.getText(ast).includes("this.number('menuSpeed'"))speed=node;compiler.forEachChild(node,visit);};visit(build);
  assert.ok(speed,'必须存在真实共享指针速度控件');
  // 执行生产AST中包围此控件的条件表达式；不另写一份界面可见性判定来掩盖错误分支。
  const guards=[];for(let node=speed;node&&node!==build;node=node.parent)if(compiler.isIfStatement(node))guards.push(node.expression.getText(ast));
  const js=compiler.transpileModule('module.exports=function(){return '+guards.map(text=>'('+text+')').join('&&')+';};',
    {compilerOptions:{target:compiler.ScriptTarget.ES2020,module:compiler.ModuleKind.CommonJS}}).outputText;
  const module={exports:{}};new Function('module',js)(module);
  for(const menuMode of ['direct','touchpad'])assert.equal(module.exports.call({section:'menu',value:{menuMode}}),true);
});

console.log(`[touch-basics] PASS ${cases} production model/component groups`);
