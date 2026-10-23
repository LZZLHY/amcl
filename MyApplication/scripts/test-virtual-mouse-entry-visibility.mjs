/**
 * 虚拟鼠标入口的显隐/生命周期回归：执行生产投影、GameControls方法、发布协调器和Entry模型。
 * Native只在真实NAPI边缘记录接收/拒收与工具前缀，不复制发布、owner、取消重试或显隐算法。
 * 回放证明宿主链路到达接口边界；不代表ArkUI真机触点捕获或游戏已经消费所有释放。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const root=path.resolve(import.meta.dirname,'..');
const file='entry/src/main/ets/components/GameControls.ets';
const pure=makePureEtsLoader({commons:{AppLogger:{warn(){}}}});
const layout=pure('gamecontrol/src/main/ets/ControlLayout.ets');
const runtime=pure('gamecontrol/src/main/ets/RuntimeTouchLayout.ets');
const surface=pure('gamecontrol/src/main/ets/InputSurfaceContext.ets');
const geometry=pure('gamecontrol/src/main/ets/TouchControlGeometry.ets');
const gui=pure('gamecontrol/src/main/ets/GameGuiGeometry.ets');
const mouse=pure('gamecontrol/src/main/ets/VirtualMouseModel.ets');
const configuration=pure('gamecontrol/src/main/ets/InputConfiguration.ets');
const capability=pure('gamecontrol/src/main/ets/LayoutCandidate.ets');
let cases=0;

/** 仅抽取真实组件方法；不运行ArkUI绘制语言，所有业务正文原样转译并核实诊断。 */
function subject(names,dependencies,sourceOverrides={}) {
  const text=sourceOverrides[file]??fs.readFileSync(path.join(root,file),'utf8');
  const ast=compiler.createSourceFile(file,text,compiler.ScriptTarget.Latest,true);
  const owner=ast.statements.find(node=>node.name?.getText(ast)==='GameControls');
  const methods=owner.members.filter(node=>names.includes(node.name?.getText(ast))).map(node=>node.getText(ast));
  assert.equal(methods.length,names.length,'所有抽取名称必须命中生产组件');
  const result=compiler.transpileModule('class Subject{'+methods.join('\n')+'}\nmodule.exports=Subject;',
    {compilerOptions:{target:compiler.ScriptTarget.ES2020,module:compiler.ModuleKind.CommonJS},reportDiagnostics:true});
  assert.equal((result.diagnostics??[]).filter(d=>d.category===compiler.DiagnosticCategory.Error).length,0,
    '原实现及撤回负控必须先编译成功，不以语法或装配失败冒充命中');
  const module={exports:{}};
  new Function('module',...Object.keys(dependencies),result.outputText)(module,...Object.values(dependencies));
  return new module.exports();
}

/** 精细鼠标按钮保留生产Builder的原回调与冻结token，模拟迟到事件时不替它读取新token。 */
function hintMouseCallback(view,token,sourceOverrides={}) {
  const text=sourceOverrides[file]??fs.readFileSync(path.join(root,file),'utf8');
  const ast=compiler.createSourceFile(file,text,compiler.ScriptTarget.Latest,true);
  const owner=ast.statements.find(node=>node.name?.getText(ast)==='GameControls');
  const builder=owner.members.find(node=>node.name?.getText(ast)==='GuiSizeHint');
  let callback;
  const visit=node=>{
    if(node.kind===compiler.SyntaxKind.ArrowFunction && node.getText(ast).includes('this.openMouse(')) callback=node;
    compiler.forEachChild(node,visit);
  };
  visit(builder);assert.ok(callback,'生产精细鼠标onClick回调');
  const result=compiler.transpileModule('module.exports='+callback.getText(ast)+';',
    {compilerOptions:{target:compiler.ScriptTarget.ES2020,module:compiler.ModuleKind.CommonJS},reportDiagnostics:true});
  assert.equal((result.diagnostics??[]).filter(d=>d.category===compiler.DiagnosticCategory.Error).length,0);
  const module={exports:{}};
  new Function('module','$$',result.outputText).call(view,module,{token});
  return module.exports;
}

/** 每个场景独立实例/Native事实；使用真实TouchSurfaceController核零触点、冻结和UI确认。 */
function fixture({sourceOverrides={},rejectCancel=()=>false}={}) {
  const effects={bounds:[],moves:[],buttons:[],cancels:[],schemas:[],toasts:[]};
  // 两个其它输入域故意保持按住；面板释放只能清自己的prefix，不得调用全局reset。
  const nativeHeld=new Map([['physical:shift',340],['direct:left',-1]]);
  let state={version:1,status:'idle',surface:'7',session:'3',policy:'1',schemaGeneration:'1',grabEpoch:'1',
    grabbed:false,token:'',operationId:'',candidateId:'',fenced:false,nativeTouches:0,density:2,transform:0};
  let nextToken=0;
  const native={
    touchPublicationState:()=>({...state}),
    beginTouchPublication:(operationId,candidateId)=>{
      state={...state,status:'fenced',fenced:true,operationId,candidateId,token:'native-'+(++nextToken)};
      return {...state};
    },
    publishTouchSchema:schema=>{
      effects.schemas.push(structuredClone(schema));state={...state,status:'committed'};return {...state};
    },
    confirmTouchPublication:(operationId,token)=>{
      assert.equal(operationId,state.operationId);assert.equal(token,state.token);
      state={...state,status:'idle',fenced:false};return true;
    },
    isTouchPublicationCurrent:token=>!state.fenced&&token===state.token,
    setTouchMenuMouseBounds:(...args)=>{effects.bounds.push(args);return true;},
    moveTouchMenuPointer:(...args)=>{effects.moves.push(args);return true;},
    touchMenuScroll:()=>true,
    touchMenuButton:(owner,code,down,token)=>{
      effects.buttons.push([owner,code,down,token]);
      if(down) nativeHeld.set(owner,code);else nativeHeld.delete(owner);
      return true;
    },
    cancelTouchMenuMouse:prefix=>{
      effects.cancels.push(prefix);
      if(rejectCancel(prefix,effects.cancels.length))return false;
      for(const owner of nativeHeld.keys())if(owner.startsWith(prefix))nativeHeld.delete(owner);
      return true;
    },
  };
  const game={...layout,...runtime,...mouse,...configuration};
  const load=makePureEtsLoader({commons:{AppLogger:{warn(){}}},gamecontrol:game,
    'libentry.so':{__esModule:true,default:native}},sourceOverrides);
  const {EntryVirtualMouse}=load('entry/src/main/ets/components/EntryVirtualMouse.ets');
  const {TouchSurfaceController,TouchSurfaceCandidate}=load('entry/src/main/ets/components/TouchSurfaceController.ets');
  const context=new surface.InputSurfaceContext();
  Object.assign(context,{provisional:false,widthPx:1600,heightPx:1200,density:2,transform:0,
    validFields:surface.INPUT_SURFACE_FIELD_RECT|surface.INPUT_SURFACE_FIELD_DENSITY});
  const view=subject(['mouseEntryVisible_','mouseEntryPresented_','canOpenMouse_','mousePanelVisible_',
    'retireHiddenMouse_','openMouse','closeMouse','mouseFrame','syncMouseBounds','registerRegions',
    'sendControlSchema','presentTouchCandidate_','confirmTouchLayout_','touchNodeId_','touchMarkerId_',
    'cycleVisMode','collapseHiddenDrawers','admitTouchAction_','reconcileTouchSurface_','reconcileGroupRestore_','arktsTouchContactCount_',
    'triggerCode','addUiBlock','clampEntryRect'],{
      ...layout,...runtime,...capability,...geometry,TouchSurfaceCandidate,testNapi:native,
      getInputSurfaceContextStore:()=>({snapshot:()=>context}),hasEntryTouchModal:()=>false,
      reconcileEntryTouchModals(){},releaseEntryTouchModal:()=>true,
    },sourceOverrides);
  const profile=layout.getDefaultLayout();
  profile.controls=profile.controls.filter(item=>item.systemAction==='mouse'||item.systemAction==='visibility');
  assert.ok(profile.controls.some(item=>item.systemAction==='mouse'),'真实默认布局必须有鼠标入口');
  Object.assign(view,{mounted:true,pageActive:true,isGrabbed:false,editing:false,imeOpen:false,fieldImeOpen:false,
    profile,desiredProfile:layout.cloneLayout(profile),runtimeLayout:new runtime.RuntimeTouchLayout(),
    uiPublicationToken:'',presentedCandidateId:'',profileVer:0,globalVisMode:0,drawerOpen:new Map(),
    guiState:new gui.GameGuiState(),guiHint:false,tutorialOpen:false,editorTrialing:false,appearanceGeneration:1,
    compWidth:800,compHeight:600,density:2,menuGeometryX:600,menuGeometryY:400,mouseGeometry:new mouse.FloatingMouseFrame(),
    mouseController:new EntryVirtualMouse(),mouseOpen:false,layoutObserverRegistered:true,
    buttonFingerIds:new Map(),scrollFingerIds:new Map(),hotbarFingerId:new Map(),dragLookFinger:new Map(),
    blockedUiFingers:new Set(),joystickFingerId:-1,unresolvedSurfaceModal:undefined,
    touchSession:{setRuntimeContext(){},setGuiViewport(){},schemaOptions:()=>undefined,setTouchAdmission(){}},
    syncGuideBounds(){},ensureTouchLayoutObserver_(){},ensureTouchFeedback_(){},
  });
  view.getUIContext=()=>({vp2px:value=>value*2,getPromptAction:()=>({showToast:args=>effects.toasts.push(args)}),
    getComponentUtils:()=>({getRectangleById:id=>{
      if(id===view.touchMarkerId_())return {size:{width:2,height:2}};
      const entry=view.runtimeLayout.entries.find(e=>view.touchNodeId_(e.item.id)===id);
      assert.ok(entry,id);return {size:{width:entry.rectPx.width,height:entry.rectPx.height},
        localOffset:{x:entry.rectPx.x,y:entry.rectPx.y}};
    }})});
  view.touchSurface=new TouchSurfaceController((candidate,token)=>view.presentTouchCandidate_(candidate,token),
    ()=>view.arktsTouchContactCount_(),message=>{throw new Error(message);});
  view.registerRegions();view.confirmTouchLayout_();
  assert.equal(view.touchSurface.admits(view.uiPublicationToken),true,'夹具先完成原Native/UI确认');
  return {view,effects,nativeHeld,model:view.mouseController.model,
    confirm:()=>view.confirmTouchLayout_(),tick:()=>view.reconcileTouchSurface_(),
    setDesired:next=>{view.desiredProfile=layout.cloneLayout(next);return view.registerRegions();}};
}

/** 每项断言失败立即停止，避免把场景只执行一半记录成通过。 */
function check(name,run){run();cases++;console.log('PASS '+name);}
/** Native工具域的剩余持有，排除特意留住的physical/direct对照。 */
function toolHolds(f){return [...f.nativeHeld].filter(([owner])=>owner.startsWith('mouse-panel-'));}

check('入口遵循全显/仅菜单/全隐和scene/hidden/force覆盖，恢复入口仍可用',()=>{
  const profile=layout.getDefaultLayout(),entry=profile.controls.find(item=>item.systemAction==='mouse');
  const restore=profile.controls.find(item=>item.systemAction==='visibility');
  for(const grabbed of [true,false])for(const mode of [0,1,2])
    assert.equal(runtime.runtimeTouchControlVisible(entry,grabbed,mode),mode!==2,'ENTRY_GLOBAL_VISIBILITY');
  assert.equal(runtime.runtimeTouchControlVisible(restore,true,2),true);
  entry.hidden=true;assert.equal(runtime.runtimeTouchControlVisible(entry,false,0),false);entry.hidden=false;
  entry.visibilityOverride='force_hide';assert.equal(runtime.runtimeTouchControlVisible(entry,false,0),false);
  entry.visibilityOverride='force_show';assert.equal(runtime.runtimeTouchControlVisible(entry,false,2),true);
  entry.visibilityOverride='auto';entry.grabbedOnly=true;
  assert.equal(runtime.runtimeTouchControlVisible(entry,false,0),false);
});

check('真实cycle全显到仅菜单保面板，全隐收起并撤范围，恢复只恢复入口',()=>{
  const f=fixture(),v=f.view;
  v.openMouse();assert.equal(v.mousePanelVisible_(),true);
  v.cycleVisMode();f.confirm();assert.equal(v.mousePanelVisible_(),true);
  v.cycleVisMode();assert.equal(v.mouseOpen,false,'HIDDEN_PANEL_RETIRED');f.confirm();
  assert.equal(v.runtimeLayout.controls.some(item=>item.systemAction==='mouse'),false);
  assert.equal(f.effects.schemas.at(-1).controls.some(item=>item.id==='sys_mouse'),false);
  assert.deepEqual(f.effects.bounds.at(-1).slice(2,4),[0,0]);
  v.cycleVisMode();f.confirm();assert.equal(v.mouseEntryPresented_(),true);assert.equal(v.mouseOpen,false);
  v.openMouse();assert.equal(v.mouseOpen,true,'恢复后显式新点击仍能打开');
});

check('双指左右键和Shift锁定在隐藏时一起退休，只释放本面板前缀',()=>{
  const f=fixture(),v=f.view;v.openMouse();
  assert.equal(f.model.toggle(340),true);
  assert.equal(f.model.beginContact(1,'left',100,100,1),true);
  assert.equal(f.model.beginContact(2,'right',200,100,2),true);
  assert.equal(toolHolds(f).length,3);
  v.globalVisMode=1;v.cycleVisMode();f.confirm();
  assert.equal(v.mouseOpen,false);assert.equal(f.model.activeContacts(),false);
  for(const code of [-1,-2,340])assert.equal(f.model.down(code),false);
  assert.equal(toolHolds(f).length,0);assert.deepEqual([...f.nativeHeld],[['physical:shift',340],['direct:left',-1]]);
  const before=f.effects.moves.length;
  assert.equal(f.model.moveContact(1,120,120,1),false);f.model.endContact(1,1);
  assert.equal(f.effects.moves.length,before,'隐藏后的旧事件不能补移动或重新建立持有');
});

check('取消首次拒收保留真实持有，原心跳重试后归零并完成隐藏发布',()=>{
  let reject=false;const f=fixture({rejectCancel:()=>reject}),v=f.view;v.openMouse();
  f.model.toggle(340);f.model.beginContact(1,'left',100,100,1);f.model.beginContact(2,'move',200,200,2);
  reject=true;const before=f.effects.cancels.length;v.globalVisMode=1;v.cycleVisMode();
  assert.equal(v.mouseOpen,false);assert.equal(f.model.activeContacts(),true);
  assert.equal(f.model.down(-1),true);assert.equal(f.model.locked(340),true);
  assert.equal(f.model.isCancellationPending(),true);assert.equal(v.touchSurface.status().reason,'ContactsEnding');
  assert.equal(f.effects.cancels.length,before+1,'关闭发布入口不递归取消');
  f.tick();assert.equal(f.model.activeContacts(),true,'拒收不得伪造成功');
  reject=false;f.tick();assert.equal(f.model.activeContacts(),false);assert.equal(toolHolds(f).length,0);
  f.tick();f.confirm();assert.equal(v.touchSurface.admits(v.uiPublicationToken),true);
  assert.equal(v.mouseEntryPresented_(),false);assert.deepEqual(f.effects.bounds.at(-1).slice(2,4),[0,0]);
});

check('普通布局publication等待仅关新DOWN，既有两指MOVE/UP和Shift锁存保留',()=>{
  const f=fixture(),v=f.view;v.openMouse();f.model.toggle(340);
  f.model.beginContact(1,'left',100,100,1);f.model.beginContact(2,'move',200,200,2);
  const before=f.effects.cancels.length;
  const next=layout.cloneLayout(v.desiredProfile);next.controls.find(item=>item.systemAction==='mouse').xPct=.7;
  f.setDesired(next);f.tick();assert.equal(v.touchSurface.status().reason,'ContactsEnding');
  assert.equal(v.mousePanelVisible_(),true);assert.equal(f.effects.cancels.length,before,'PENDING_KEEPS_CONTACTS');
  assert.equal(f.model.beginContact(3,'move',300,300,3),false);
  assert.equal(f.model.moveContact(2,207,211,2),true);assert.deepEqual(f.effects.moves.at(-1).slice(0,2),[14,22]);
  f.model.endContact(2,2);assert.equal(f.model.down(-1),true);
  f.model.moveContact(1,104,105,1);f.model.endContact(1,1);f.tick();f.confirm();
  assert.equal(v.mouseOpen,true);assert.equal(f.model.locked(340),true);assert.equal(f.model.down(-1),false);
});

check('用户切换到隐藏入口的定义立即收口，重新显示不恢复面板或旧Shift',()=>{
  const f=fixture(),v=f.view;v.openMouse();f.model.toggle(340);f.model.beginContact(1,'left',100,100,1);
  const original=layout.cloneLayout(v.desiredProfile),hidden=layout.cloneLayout(original);
  hidden.controls.find(item=>item.systemAction==='mouse').hidden=true;
  f.setDesired(hidden);assert.equal(v.mouseOpen,false);f.confirm();assert.equal(v.mouseEntryPresented_(),false);
  f.setDesired(original);f.confirm();assert.equal(v.mouseEntryPresented_(),true);assert.equal(v.mouseOpen,false);
  assert.equal(f.model.locked(340),false);
});

check('旧GUI提示token和隐藏状态的新回调都不能重开或误关提示，恢复后新回调有效',()=>{
  const f=fixture(),v=f.view,old=hintMouseCallback(v,v.uiPublicationToken);
  v.globalVisMode=1;v.cycleVisMode();f.confirm();v.guiHint=true;old();
  assert.equal(v.mouseOpen,false);assert.equal(v.guiHint,true,'旧回调不能借新token关闭提示');
  hintMouseCallback(v,v.uiPublicationToken)();assert.equal(v.mouseOpen,false);assert.equal(v.guiHint,true);
  v.guiHint=false;v.cycleVisMode();f.confirm();v.guiHint=true;
  old();assert.equal(v.mouseOpen,false,'旧token即使恢复可见也失效');
  hintMouseCallback(v,v.uiPublicationToken)();assert.equal(v.mouseOpen,true);assert.equal(v.guiHint,false);
});

check('直接打开也核当前入口资格，隐藏定义不能由后来回调复活mouseOpen',()=>{
  const f=fixture(),v=f.view,oldToken=v.uiPublicationToken;
  v.globalVisMode=1;v.cycleVisMode();f.confirm();
  v.openMouse(v.uiPublicationToken);assert.equal(v.mouseOpen,false,'HIDDEN_OPEN_REJECTED');
  v.cycleVisMode();f.confirm();
  v.openMouse(oldToken);assert.equal(v.mouseOpen,false,'旧token不借后来可见定义重新打开');
  v.openMouse(v.uiPublicationToken);assert.equal(v.mouseOpen,true);
});

check('撤回发布前隐藏收口必须命中mouseOpen和零触点行为断言',()=>{
  const text=fs.readFileSync(path.join(root,file),'utf8'),needle='    this.retireHiddenMouse_()';
  // 组回执也调用同一个收口方法；负控只撤回原registerRegions接点，不能误改另一路生产调用。
  const ast=compiler.createSourceFile(file,text,compiler.ScriptTarget.Latest,true);
  const owner=ast.statements.find(node=>node.name?.getText(ast)==='GameControls');
  const method=owner.members.find(node=>node.name?.getText(ast)==='registerRegions');
  const original=method.getText(ast);
  assert.equal(original.split(needle).length-1,1,'仅撤回registerRegions的真实接点');
  const withdrawn=text.slice(0,method.getStart(ast))+original.replace(needle,'    void 0')+text.slice(method.end);
  assert.throws(()=>{
    const f=fixture({sourceOverrides:{[file]:withdrawn}}),v=f.view;v.openMouse();
    f.model.beginContact(1,'left',100,100,1);v.globalVisMode=1;v.cycleVisMode();
    assert.equal(v.mouseOpen,false,'HIDDEN_PANEL_RETIRED');
  },error=>error instanceof assert.AssertionError&&error.message.includes('HIDDEN_PANEL_RETIRED'));
});

check('把pending错误并入生命周期必须命中既有触点保持的行为反例',()=>{
  const text=fs.readFileSync(path.join(root,file),'utf8');
  const needle='this.mouseController.configure(active,this.density,this.touchSurface.admits(this.uiPublicationToken))';
  assert.equal(text.split(needle).length-1,1);
  const withdrawn=text.replace(needle,
    'this.mouseController.configure(active && this.touchSurface.admits(this.uiPublicationToken),this.density)');
  assert.throws(()=>{
    const f=fixture({sourceOverrides:{[file]:withdrawn}}),v=f.view;v.openMouse();
    f.model.beginContact(1,'left',100,100,1);f.model.beginContact(2,'move',200,200,2);
    const next=layout.cloneLayout(v.desiredProfile);next.controls.find(item=>item.systemAction==='mouse').xPct=.6;
    f.setDesired(next);f.tick();assert.equal(f.model.activeContacts(),true,'PENDING_KEEPS_CONTACTS');
  },error=>error instanceof assert.AssertionError&&error.message.includes('PENDING_KEEPS_CONTACTS'));
});

check('撤回mouse恒显特例必须在同一真实投影断言命中行为差异',()=>{
  const key='gamecontrol/src/main/ets/RuntimeTouchLayout.ets',text=fs.readFileSync(path.join(root,key),'utf8');
  const needle='export function runtimeTouchControlVisible(item: ControlItem, grabbed: boolean, visibility: number): boolean {';
  assert.equal(text.split(needle).length-1,1);
  const withdrawn=text.replace(needle,needle+"\n  if(item.systemAction==='mouse')return true");
  const old=makePureEtsLoader({}, {[key]:withdrawn})(key),entry=layout.getDefaultLayout().controls.find(i=>i.systemAction==='mouse');
  assert.throws(()=>assert.equal(old.runtimeTouchControlVisible(entry,false,2),false,'ENTRY_GLOBAL_VISIBILITY'),
    error=>error instanceof assert.AssertionError&&error.message.includes('ENTRY_GLOBAL_VISIBILITY'));
});

/** 合法一层抽屉的系统鼠标孩子：隐藏独立根入口，防止根入口掩盖孩子资格漏检。 */
function drawerMouseFixture({sourceOverrides={},opened=true,parentHidden=false,childForceShow=false}={}) {
  const f=fixture({sourceOverrides}),v=f.view,next=layout.cloneLayout(v.desiredProfile);
  const rootMouse=next.controls.find(item=>item.systemAction==='mouse');
  const child=layout.cloneItem(rootMouse);child.id='drawer-mouse-child';child.hidden=false;
  child.visibilityOverride=childForceShow?'force_show':'auto';
  const drawer=layout.cloneItem(rootMouse);drawer.id='mouse-tools-drawer';drawer.type=layout.ControlType.DRAWER;
  drawer.systemAction=undefined;drawer.hidden=parentHidden;drawer.visibilityOverride='auto';
  drawer.grabbedOnly=false;drawer.menuOnly=false;drawer.children=[child];rootMouse.hidden=true;
  next.controls.push(drawer);
  // 直接使用生产validator和能力检查，证明是被支持的导入树，不用虚构绕过校验的控件。
  const checked=layout.validateAndNormalizeLayoutWithReason(next);
  assert.ok(checked.profile,'合法drawer BUTTON/systemAction=mouse导入：'+checked.reason);
  assert.equal(capability.layoutCapabilityIssue(checked.profile),'');
  v.drawerOpen.set(drawer.id,opened);f.setDesired(checked.profile);f.confirm();
  return {...f,drawerId:drawer.id,childId:child.id};
}

check('隐藏root入口但展开合法mouse孩子时可打开并保持面板和两指',()=>{
  const f=drawerMouseFixture(),v=f.view;
  assert.equal(v.runtimeLayout.controls.some(item=>item.id===f.childId),false,'孩子不属于roots controls');
  assert.equal(v.runtimeLayout.entries.some(entry=>entry.item.id===f.childId),true);
  assert.equal(v.canOpenMouse_(v.uiPublicationToken),true,'CHILD_MOUSE_AVAILABLE');
  v.openMouse();assert.equal(v.mousePanelVisible_(),true);
  f.model.toggle(340);f.model.beginContact(1,'left',100,100,1);f.model.beginContact(2,'move',200,200,2);
  const before=f.effects.cancels.length;f.tick();
  assert.equal(v.mousePanelVisible_(),true);assert.equal(f.model.activeContacts(),true);
  assert.equal(f.effects.cancels.length,before);assert.equal(f.model.moveContact(2,204,205,2),true);
});

check('收起抽屉或隐藏父项立即退休孩子打开的面板，释放工具持有',()=>{
  for(const action of ['collapse','hide-parent']) {
    const f=drawerMouseFixture(),v=f.view;v.openMouse();
    assert.equal(v.mouseOpen,true,'CHILD_MOUSE_AVAILABLE');
    f.model.toggle(340);f.model.beginContact(1,'left',100,100,1);f.model.beginContact(2,'move',200,200,2);
    if(action==='collapse') {
      // 真实toggleDrawer负责改变展开态和请求发布；本样本的系统孩子没有普通按键输出，
      // unrelated普通孩子的releaseDrawerChildren在本夹具为空边界，工具释放仍由实际模型执行。
      v.toggleDrawer=subject(['toggleDrawer'],{}).toggleDrawer;v.releaseDrawerChildren=()=>{};
      v.toggleDrawer(v.profile.controls.find(item=>item.id===f.drawerId));
    } else {
      const next=layout.cloneLayout(v.desiredProfile);next.controls.find(item=>item.id===f.drawerId).hidden=true;
      f.setDesired(next);
    }
    assert.equal(v.mouseOpen,false);assert.equal(f.model.activeContacts(),false);
    assert.equal(f.model.locked(340),false);assert.equal(toolHolds(f).length,0);f.confirm();
    assert.equal(v.runtimeLayout.entries.some(entry=>entry.item.id===f.childId),false);
    assert.deepEqual(f.effects.bounds.at(-1).slice(2,4),[0,0]);
  }
});

check('抽屉未展开时mouse孩子不取得打开资格或热区',()=>{
  const f=drawerMouseFixture({opened:false}),v=f.view;
  assert.equal(v.mouseEntryVisible_(v.desiredProfile),false);
  assert.equal(v.mouseEntryPresented_(),false);v.openMouse();assert.equal(v.mouseOpen,false);
  assert.equal(v.runtimeLayout.entries.some(entry=>entry.item.id===f.childId),false);
});

check('mouse孩子force_show不越过父抽屉hidden资格',()=>{
  const f=drawerMouseFixture({parentHidden:true,childForceShow:true}),v=f.view;
  assert.equal(v.mouseEntryVisible_(v.desiredProfile),false);
  assert.equal(v.mouseEntryPresented_(),false);v.openMouse();assert.equal(v.mouseOpen,false);
  assert.equal(v.runtimeLayout.entries.some(entry=>entry.item.id===f.childId),false);
});

console.log('virtual mouse entry visibility: '+cases+' production scenarios passed');
