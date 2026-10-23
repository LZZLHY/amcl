/**
 * 直接执行EntryTouchSession的GUI来源接线。替换的仅是Native/传感器/时钟边界；Native
 * queue/resource/restore算法另由真实stock JNI组合测试证明。这里证明构造冻结原scope、
 * 停止精确撤自身、视觉关闭不撤来源，以及GUI端口异常不能阻断基本触控维护/清理。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import compiler from './lib/ets-compiler.mjs';
import {makePureEtsLoader} from './lib/load-pure-ets.mjs';
const file='entry/src/main/ets/components/EntryTouchSession.ets';
const original=fs.readFileSync(path.resolve(import.meta.dirname,'..',file),'utf8').replace(/\r\n/g,'\n');
function fixture(rewrite=source=>source){
  const modelLoad=makePureEtsLoader({commons:{AppLogger:{warn(){}}}});
  const models=Object.assign({},...['ControlLayout','TouchPreferences','TouchActionBindings','TouchGyroscope','TouchGuide','GameGuiGeometry','InputConfiguration','RuntimeTouchLayout']
    .map(name=>modelLoad('gamecontrol/src/main/ets/'+name+'.ets')));
  // 只提取生产Store薄接线，定义/回执计算仍执行原InputConfigurationDelivery，避免旧fixture漏当前gyro域。
  const storeSource=fs.readFileSync(path.resolve(import.meta.dirname,'../gamecontrol/src/main/ets/LayoutStore.ets'),'utf8');
  const ast=compiler.createSourceFile('store.ets',storeSource,compiler.ScriptTarget.Latest,true);
  const owner=ast.statements.find(n=>n.name?.getText(ast)==='LayoutStore');
  const names=['addInputConfigurationListener','removeInputConfigurationListener','addInputConfigurationDefinitionListener',
    'removeInputConfigurationDefinitionListener','publishInputConfiguration','reconcileInputConfiguration','invalidateInputConfiguration'];
  const bodies=names.map(name=>owner.members.find(m=>m.name?.getText(ast)===name).getText(ast)).join('\n');
  const compiled=compiler.transpileModule('class Store{'+bodies+'}\nmodule.exports=Store;',
    {compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020},reportDiagnostics:true});
  assert.equal((compiled.diagnostics??[]).filter(d=>d.category===compiler.DiagnosticCategory.Error).length,0);
  const module={exports:{}};new Function('module',compiled.outputText)(module);const store=new module.exports();
  store._ready=true;store.inputConfigurationDelivery=new models.InputConfigurationDelivery();
  store.getActiveProfile=()=>models.getDefaultLayout();models.getLayoutStore=()=>store;
  const events=[],timers=new Map(),sensorCallbacks=[],sensorOff=[];let scope=20,next=100,maintenance=0,failAttach=false,failRetire=false;
  const raw=[2,2,2,1920,1080,960,540,1,5,1,0,0,0,0,0,0,0,0,0];
  const native={
    maintainTouchInput:()=>{maintenance++;return true;},touchInteractionVisual:()=>Array(14).fill(0),
    gameGuiCaptureSession:()=>scope,
    gameGuiAttachSource:origin=>{events.push(['attach',origin]);if(failAttach)throw Error('GUI attach failure');return origin===scope?++next:0;},
    gameGuiRetireSource:id=>{events.push(['retire',id]);if(failRetire)throw Error('GUI retire failure');return true;},
    gameGuiStateForSource:(...args)=>{events.push(['read',...args]);return raw.slice();},
    gameGuiState:()=>{throw Error('unscoped production GUI read');},
    restoreGameGuiScaleForSource:(...args)=>{events.push(['restore',...args]);return 777;},
    restoreGameGuiScale:()=>{throw Error('unscoped production GUI restore');}
  };
  // 原正例与全部撤回使用完整Session的明确诊断结果；只有成功转译后才能运行行为合同。
  const changed=rewrite(original),sessionCompiled=compiler.transpileModule(changed,{fileName:file,
    compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020},reportDiagnostics:true});
  assert.equal((sessionCompiled.diagnostics??[]).filter(d=>d.category===compiler.DiagnosticCategory.Error).length,0);
  const load=makePureEtsLoader({gamecontrol:models,'libentry.so':{__esModule:true,default:native},
    '@ohos.file.fs':{__esModule:true,default:{readTextSync:()=>'',statSync:()=>({mtime:1,size:0})}},
    '@kit.PerformanceAnalysisKit':{hilog:{warn(){},info(){}}},
    '@kit.ArkUI':{display:{getDefaultDisplaySync:()=>({rotation:0})}},
    '@kit.SensorServiceKit':{sensor:{SensorId:{GYROSCOPE:2},on:(_id,cb)=>sensorCallbacks.push(cb),off:(_id,cb)=>sensorOff.push(cb)}}}, {[file]:changed});
  const sessionModule=load(file),host=sessionModule.startEntryTouchInputMaintenance();
  return {module:sessionModule,models,store,sensorCallbacks,sensorOff,host,events,timers,raw,native,
    maintenanceModule:load('entry/src/main/ets/components/EntryTouchInputMaintenance.ets'),
    maintenance:()=>maintenance,setScope:value=>scope=value,
    failAttach:()=>failAttach=true,failRetire:()=>failRetire=true};
}
const set=globalThis.setInterval,clear=globalThis.clearInterval;let activeTimers;
globalThis.setInterval=fn=>{const id=activeTimers.size+1;activeTimers.set(id,fn);return id;};
globalThis.clearInterval=id=>activeTimers.delete(id);
/** 正例与撤回冻结负例都执行同一原scope合同；负例须由合同断言失败，不能只跑替身。 */
function frozenScopeContract(rewrite=source=>source){
  const f=fixture(rewrite);activeTimers=f.timers;const old=new f.module.EntryTouchSession();f.setScope(21);
  try {
    old.start(()=>{},true,()=>{});assert.deepEqual(f.events[0],['attach',20],'原前端不能自动取后来current GUI scope');
    assert.equal(old.restoreGui(3,5),0);
  } finally {old.stop();}
}
try {
  {
    const f=fixture();activeTimers=f.timers;const session=new f.module.EntryTouchSession(),gui=[];
    session.setGuiViewport(1920,1080,'1.21.11');session.start(()=>{},true,state=>gui.push(state));
    const source=f.events.find(event=>event[0]==='attach');assert.deepEqual(source,['attach',20]);
    session.refreshVisual();const read=f.events.find(event=>event[0]==='read');assert.equal(read[1],101);
    assert.equal(session.restoreGui(3,5),777);assert.deepEqual(f.events.at(-1),['restore',101,3,5]);
    session.setActive(false);assert.equal(gui.at(-1).requestId,777);assert.equal(gui.at(-1).result,3,'原source退休必须结束原前端票等待');
    assert.equal(gui.at(-1).valid,false,'撤票不授予新恢复/几何能力');
    session.setActive(true);const retiredBefore=f.events.filter(event=>event[0]==='retire').length;
    session.unsubscribeVisual();const prior=f.maintenance();for(const tick of f.timers.values())tick();
    assert.ok(f.maintenance()>prior);assert.equal(f.events.filter(event=>event[0]==='retire').length,retiredBefore,'撤观察者不撤仍属本前端的来源/在途恢复');
    session.stop();assert.deepEqual(f.events.at(-1),['retire',102]);assert.equal(f.timers.size,0);assert.equal(session.restoreGui(3,5),0);
  }
  /** 实际GUI读取/纯hotbar投影与菜单几何均继续；撤回原early-return必须击中行为断言。 */
  function geometryContract(rewrite=source=>source) {
    const f=fixture(rewrite);activeTimers=f.timers;const session=new f.module.EntryTouchSession(),gui=[],points=[],visual=[];
    const originalNow=Date.now;let now=1000;Date.now=()=>now;
    try {
      session.setGuiViewport(1920,1080,'1.21.11');session.start(s=>visual.push(s),true,s=>gui.push(s),(x,y)=>points.push([x,y]));
      f.native.touchInteractionVisual=()=>[20,30,...Array(12).fill(0)];session.refreshVisual();
      const source=session.sourceLease,timer=session.timer;session.unsubscribeVisual();now=2000;
      f.raw[1]=4;f.raw[2]=4;f.raw[5]=480;f.raw[6]=270;
      f.native.touchInteractionVisual=()=>[60,70,...Array(12).fill(0)];for(const tick of f.timers.values())tick();
      assert.equal(gui.at(-1).effective,4,'NECESSARY_GUI_CONTINUES_WITH_VISUAL_OFF');
      assert.deepEqual(points.at(-1),[60,70],'NECESSARY_MENU_GEOMETRY_CONTINUES_WITH_VISUAL_OFF');
      assert.equal(visual.length,1);assert.equal(session.sourceLease,source);assert.equal(session.timer,timer);
      const count=session.observationSnapshot();assert.equal(count.guiReads,2);assert.equal(count.geometryDeliveries,2);
      session.subscribeVisual(s=>visual.push(s));session.refreshVisual();assert.equal(visual.length,2,'恢复只交当前快照');
      assert.equal(session.sourceLease,source);assert.equal(session.timer,timer);
      f.module.stopEntryTouchInputMaintenance(f.host);now=3000;const reads=session.observationSnapshot().guiReads;
      session.refreshVisual();assert.equal(session.observationSnapshot().guiReads,reads,'RETIRED_SOURCE_MUST_NOT_READ_NEW_GUI');
      return count;
    } finally {Date.now=originalNow;session.stop();}
  }
  geometryContract();
  assert.throws(()=>geometryContract(source=>source.replace('if (guiReceive===undefined && geometryReceive===undefined && receive===undefined) return',
    'if (receive===undefined) return')),/NECESSARY_GUI_CONTINUES_WITH_VISUAL_OFF/);
  assert.throws(()=>geometryContract(source=>source.replace('if (!this.active || !this.hasCurrentSource()) return','if (false) return')
    .replace('return this.active && lease!==undefined && this.sourceLease===lease && isEntryTouchInputMaintenanceCurrent(lease)','return true')),
    /RETIRED_SOURCE_MUST_NOT_READ_NEW_GUI/);
  frozenScopeContract();
  {
    const f=fixture();activeTimers=f.timers;const session=new f.module.EntryTouchSession();f.failAttach();
    session.start(()=>{},true,()=>{});assert.equal(f.timers.size,1,'可关闭GUI失败不能阻断必要16ms来源时钟');
    const before=f.maintenance();for(const tick of f.timers.values())tick();assert.ok(f.maintenance()>before);session.stop();
  }
  {
    const f=fixture();activeTimers=f.timers;const session=new f.module.EntryTouchSession();session.start(()=>{},true,()=>{});
    f.failRetire();assert.throws(()=>session.stopSources(),/GUI retire failure/);assert.equal(f.timers.size,0,'GUI失败仍清原触控timer');
    assert.equal(session.restoreGui(3,5),0,'GUI端口抛错前本地lease已经退休');
  }
  {
    const f=fixture();activeTimers=f.timers;const session=new f.module.EntryTouchSession(),points=[];
    session.setGuiViewport(1920,1080,'1.21.11');session.start(()=>{throw Error('optional visual failure');},true,()=>{},
      (x,y)=>points.push([x,y]));f.native.gameGuiStateForSource=()=>{throw Error('GUI read failed');};
    f.native.touchInteractionVisual=()=>[44,55,...Array(12).fill(0)];for(const tick of f.timers.values())tick();
    assert.deepEqual(points.at(-1),[44,55],'GUI/可选显示异常不能夺走必要菜单几何');assert.ok(f.maintenance()>0);
    f.failRetire();assert.throws(()=>session.stop(),/GUI retire failure/);
    const stopped=session.observationSnapshot();assert.equal(stopped.timerActive,false);assert.equal(stopped.sourceCurrent,false);
    assert.equal(stopped.guiSubscribed,false);assert.equal(stopped.geometrySubscribed,false);assert.equal(stopped.visualSubscribed,false,
      '完整退休即使Native GUI异常也清所有原组件闭包');
  }
  {
    const f=fixture();activeTimers=f.timers;const session=new f.module.EntryTouchSession(),gui=[];
    session.start(()=>{},true,state=>gui.push(state));assert.equal(session.restoreGui(3,5),777);
    session.unsubscribeVisual();session.setActive(false);session.setActive(true);
    session.subscribeVisual(()=>{},state=>gui.push(state));assert.equal(gui.at(-1).requestId,777);assert.equal(gui.at(-1).result,3,
      '观察关闭时退休仍保存原票有限结束，重订阅不靠新source缓存补造ACK');session.stop();
  }
  {
    const f=fixture();activeTimers=f.timers;const session=new f.module.EntryTouchSession(),gui=[];
    session.setGuiViewport(1920,1080,'1.21.11');session.start(()=>{},true,state=>gui.push(state));
    f.raw[0]=0;f.raw[10]=777;f.raw[11]=3;session.refreshVisual();
    assert.equal(gui.at(-1).valid,false);assert.equal(gui.at(-1).requestId,777);assert.equal(gui.at(-1).result,3,'退休几何仍结束原Native票据，不能假装即时恢复能力');session.stop();
  }
  const before="private readonly guiOriginScope: number = typeof testNapi.gameGuiCaptureSession === 'function' ? testNapi.gameGuiCaptureSession() : 0";
  assert.ok(original.includes(before));
  assert.throws(()=>frozenScopeContract(source=>source.replace(before,
    "private get guiOriginScope(): number { return testNapi.gameGuiCaptureSession() }")),/原前端不能自动取后来current GUI scope/);
  console.log('PASS production GUI source lease: scope freeze/typed source read+restore/visual independence/optional failure cleanup/cancelled ACK; negative current-scope rebinding observed');
} finally {globalThis.setInterval=set;globalThis.clearInterval=clear;}
