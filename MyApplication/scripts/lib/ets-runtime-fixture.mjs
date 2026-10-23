/** 生产ArkTS模块/组件宿主装载器：只替换显式平台边界，缓存与计时器按fixture隔离。 */
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import compiler from './ets-compiler.mjs';
const root=path.resolve(import.meta.dirname,'../..');
const noop=()=>{};
const flush=async()=>{for(let i=0;i<8;i++)await Promise.resolve();};
export function environment(options={}) {
  const cache=new Map(), timer=new Map();let nextTimer=1;
  const fakeSetTimeout=(fn,delay=0)=>{const id=nextTimer++;timer.set(id,{fn,delay});return id;};
  // 进程宿主回归可以显式注入AppStorage等系统边缘；默认行为和其它组件fixture保持一致。
  const globals={setTimeout:fakeSetTimeout,clearTimeout:id=>timer.delete(id),AppStorage:{get:()=>undefined},...options.globals};
  const commons={AppLogger:{warn:noop,error:noop,info:noop},ProcessPreferences:{isGameProcess:()=>false},...options.commons};
  const boundaries={commons,'@kit.PerformanceAnalysisKit':{hilog:{info:noop,warn:noop,error:noop}},
    '@kit.AbilityKit':{},'@kit.CoreFileKit':{},'@kit.ArkTS':{util:{generateRandomUUID:randomUUID}},'@kit.ArkUI':{display:{getDefaultDisplaySync:()=>({width:1200,height:800,densityPixels:1})}},
    '@kit.BasicServicesKit':{deviceInfo:{deviceType:'tablet'}},...options.imports};
  function load(relative,component=false) {
    if(cache.has(relative)) return cache.get(relative);
    // 测试提取层先归一逻辑换行，负控定位可同时处理Main CRLF和WT LF；不写回产品原字节。
    // 原mutation必须仍命中并改变正文，转译诊断与行为断言保持，不能把找不到needle当负控通过。
    const absolute=path.join(root,relative);let source=fs.readFileSync(absolute,'utf8').replaceAll('\r\n','\n');
    // 负向对照只改内存副本，必须命中原文；语法错误不能被算作成功识别行为回归。
    const mutation=options.sourceOverrides?.[relative];
    if(mutation){const changed=mutation(source);assert.notEqual(changed,source,'mutation anchor '+relative);source=changed;}
    if(component) {
      // 保留整个非UI类（字段初始化、所有生命周期和方法），仅去掉ArkUI build/Builder。
      const ast=compiler.createSourceFile(relative,source,compiler.ScriptTarget.Latest,true);
      const owner=ast.statements.find(n=>n.members?.some(m=>m.name?.getText(ast)==='aboutToAppear'));
      assert.ok(owner,'component class: '+relative);
      const imports=ast.statements.filter(n=>n.kind===compiler.SyntaxKind.ImportDeclaration).map(n=>n.getText(ast)).join('\n');
      const constants=ast.statements.filter(n=>n.kind===compiler.SyntaxKind.VariableStatement).map(n=>n.getText(ast)).join('\n');
      const overrides=options.memberOverrides?.[relative]??{};
      for(const name of Object.keys(overrides))assert.ok(owner.members.some(m=>m.name?.getText(ast)===name),relative+': override target '+name);
      const members=owner.members.filter(m=>m.name?.getText(ast)!=='build'&&!m.getText(ast).includes('@Builder'))
        .map(m=>{const name=m.name?.getText(ast),text=m.getText(ast),o=overrides[name];
          if(o===undefined)return text;const next=typeof o==='function'?o(text):o;assert.notEqual(next,text,'override must change '+name);return next;})
        .map(text=>text.replace(/@(Prop|State|Watch|StorageProp|Link|ObjectLink|BuilderParam)(\([^\n]*?\))?\s*/g,''));
      source=imports+'\n'+constants+'\nexport class '+owner.name.getText(ast)+' {\n'+members.join('\n')+'\n}';
    }
    const compiled=compiler.transpileModule(source,{fileName:relative.replace(/\.ets$/,'.ts'),compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020},reportDiagnostics:true});
    assert.equal((compiled.diagnostics??[]).filter(d=>d.category===compiler.DiagnosticCategory.Error).length,0,relative);
    const module={exports:{}};cache.set(relative,module.exports);
    const req=name=>{
      if(Object.hasOwn(boundaries,name))return boundaries[name];
      // 包括生产原attach回调围栏；组件回归必须运行同一个实现，不能用假的当前lease检查。
      if(name==='gamecontrol')return Object.assign({},...['GlfwKeys','OhosKeyCodes','KeyMap','PhysicalKeyEdge','PhysicalHeldKeyTracker','ControlLayout','LookPreferences','InputDeviceConnectionLease','GamepadManager','ImeActivationGate','TextInputSessionCoordinator','ImeCallbackLease','InputSourceRegistry','InputConfiguration','SourceControlClient','InputSessionCoordinator','RuntimeTouchLayout'].map(n=>load('gamecontrol/src/main/ets/'+n+'.ets')));
      if(name.startsWith('.'))return load(path.relative(root,path.resolve(path.dirname(absolute),name+'.ets')).replaceAll('\\','/'));
      throw new Error('unmocked system boundary '+name);
    };
    new Function('require','module','exports',...Object.keys(globals),compiled.outputText)(req,module,module.exports,...Object.values(globals));
    cache.set(relative,module.exports);return module.exports;
  }
  return {load,timer,drainZero:async()=>{for(let i=0;i<10;i++){const items=[...timer].filter(([,t])=>t.delay===0);if(!items.length)break;for(const[id,t]of items){timer.delete(id);t.fn();}await flush();}},runTimers:()=>{const items=[...timer];timer.clear();for(const[,t]of items)t.fn();}};
}
