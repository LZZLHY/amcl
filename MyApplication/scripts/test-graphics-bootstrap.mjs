/** 执行实际Hvigor插件回调，验证四产品继承AppScope启动环境且没有后期覆盖。
 * 只替换Hvigor提供的配置对象；TS编译器、插件正文、产品表和校验器均为现役输入。
 * 正反例不通过静默修正配置实现：缺失、零值和重复项必须由真实回调拒绝。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import compiler from './lib/ets-compiler.mjs';
import { parseJson5 } from './product-contract.mjs';
import { graphicsBootstrapIssues } from './graphics-bootstrap-contract.mjs';
import { stripComments } from './lib/source-noise.mjs';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const app=parseJson5(fs.readFileSync(path.join(root,'AppScope/app.json5'),'utf8'));
assert.deepEqual(graphicsBootstrapIssues(app.app),[]);
const source=fs.readFileSync(path.join(root,'hvigorfile.ts'),'utf8');
const js=compiler.transpileModule(source,{compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020}}).outputText;
function execute(product,config){
  const module={exports:{}};
  const dependencies={'@ohos/hvigor-ohos-plugin':{appTasks:{},OhosPluginId:{OHOS_APP_PLUGIN:'app'}},
    'node:fs':fs,'node:path':path,'./scripts/graphics-bootstrap-contract.mjs':{graphicsBootstrapIssues}};
  new Function('require','module','exports','__dirname','process',js)(name=>{
    if(!Object.hasOwn(dependencies,name))throw new Error('unexpected dependency '+name);
    return dependencies[name];
  },module,module.exports,root,{argv:['node','hvigor','product='+product],env:{}});
  let evaluated;
  const plugins=module.exports.default.plugins;
  assert.ok(plugins.length>0);
  for(const plugin of plugins)plugin.apply({afterNodeEvaluate:callback=>{evaluated=callback;}});
  assert.equal(typeof evaluated,'function');
  evaluated({getContext:()=>({getAppJsonOpt:()=>config,setAppJsonOpt:()=>{throw new Error('bootstrap validator must not mutate source');}})});
}
for(const product of ['default','desktop','sideload','store']){
  const config=structuredClone(app);
  config.app.appEnvironments.push({name:'AMCL_UNRELATED_FIXTURE',value:'preserve'});
  const before=structuredClone(config);execute(product,config);assert.deepEqual(config,before);
  for(const mutate of [c=>delete c.app.appEnvironments,c=>c.app.appEnvironments=[],
    c=>c.app.appEnvironments[0].value='0',c=>c.app.appEnvironments.push({name:'NEED_OPENGL',value:'1'})]){
    const invalid=structuredClone(app);mutate(invalid);
    assert.throws(()=>execute(product,invalid),/startup NEED_OPENGL=1/);
  }
}
assert.throws(()=>execute('desktopLegacy',structuredClone(app)),/Unknown or retired product/);
// 专门防止曾出现的profile→NEED_OPENGL晚改写复发；真正时序由官方EGL+生产探针测试覆盖。
const launcher=stripComments(fs.readFileSync(path.join(root,'entry/src/main/cpp/jvm/mc_launcher.cpp'),'utf8'),'cpp');
assert.doesNotMatch(launcher,/(?:setenv|unsetenv|putenv|_putenv_s)\s*\(\s*"NEED_OPENGL"/);
console.log('Graphics bootstrap PASS: actual Hvigor callback, four products, authoritative startup environment, invalid/duplicate rejection, no late profile rewrite');
