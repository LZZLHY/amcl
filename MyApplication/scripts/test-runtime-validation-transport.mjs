/** 执行真实entry传输适配与夹具解析；JDK业务、签名和文件校验不在测试侧复制。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';
import {makePureEtsLoader} from './lib/load-pure-ets.mjs';
const source=fs.readFileSync(new URL('../entry/src/main/ets/runtime/ProcessRuntime.ets',import.meta.url),'utf8');
const ast=compiler.createSourceFile('ProcessRuntime.ets',source,compiler.ScriptTarget.Latest,true);
const cls=ast.statements.find(node=>node.name?.getText(ast)==='EntryDownloadEngine');assert(cls);
const manager=fs.readFileSync(new URL('../feature_core/src/main/ets/download/DownloadManager.ets',import.meta.url),'utf8');
const managerAst=compiler.createSourceFile('DownloadManager.ets',manager,compiler.ScriptTarget.Latest,true);
const copy=managerAst.statements.find(node=>node.name?.getText(managerAst)==='copyDownloadFileSpec');assert(copy);
const js=compiler.transpileModule(copy.getText(managerAst)+'\n'+cls.getText(ast),{compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020}}).outputText;
let allowed=false,reads=0;const calls=[];
const policy={hasTestHooks:()=>allowed};
const native={downloadFetchText(...args){calls.push(['text',args]);return Promise.resolve({success:true,statusCode:200,body:'test'});},downloadCreateTask(spec){calls.push(['task',spec]);return 7;},downloadProbeTransfer(...args){calls.push(['probe',args]);return Promise.resolve({});}};
const exports={};new Function('exports','testNapi','DiagnosticPolicy',js)(exports,native,policy);
const Engine=exports.EntryDownloadEngine;
const sourceUrl='https://raw.githubusercontent.com/LZZLHY/mc-ohos-resources/main/catalog/v2/stable.json';
let body=JSON.stringify({schema:1,nonce:'validation-1111',port:18881,routes:[{url:sourceUrl,relativePath:'catalog/v2/stable.json'}]});
const fixture=makePureEtsLoader({'@kit.CoreFileKit':{fileIo:{accessSync(){reads++;return true;},statSync:()=>({isFile:()=>true,size:body.length}),readTextSync:()=>body}},commons:{DiagnosticPolicy:policy,AppLogger:{info(){}}}})('entry/src/main/ets/devtools/RuntimeDownloadValidation.ets');
let engine=new Engine();fixture.installRuntimeDownloadValidation({filesDir:'/sandbox'},engine);assert.equal(reads,0);
assert.throws(()=>engine.installValidationTransport(value=>value),/不允许/);
allowed=true;engine=new Engine();fixture.installRuntimeDownloadValidation({filesDir:'/sandbox'},engine);
await engine.fetchText(sourceUrl,[],10,{},1000,true);assert.equal(calls.at(-1)[1][0],'http://127.0.0.1:18881/catalog/v2/stable.json');assert.equal(calls.at(-1)[1][5],false);
assert.throws(()=>engine.installValidationTransport(value=>value),/不允许/);
assert.throws(()=>engine.fetchText(sourceUrl,[],10,{Authorization:'must-not-forward'}),/授权请求/);
const original={name:'same business task',activityId:123,files:[{localPath:'/app/a',allowedRoot:'/app',urls:[sourceUrl],check:{size:456}}]};
engine.createTask(original);assert.equal(original.files[0].urls[0],sourceUrl);assert.equal(calls.at(-1)[1].files[0].check.size,456);assert.equal(calls.at(-1)[1].activityId,123);
assert.throws(()=>engine.createTask({...original,files:[{...original.files[0],bearerToken:'must-not-forward'}]}),/授权下载/);
for(const url of ['https://accounts.example/login','file:///private','https://amcl.lovedhy.cn/api/admin']){
  body=JSON.stringify({schema:1,nonce:'validation-1111',port:18881,routes:[{url,relativePath:'catalog/v2/stable.json'}]});engine=new Engine();
  assert.throws(()=>fixture.installRuntimeDownloadValidation({filesDir:'/sandbox'},engine),/路径无效/);assert.throws(()=>engine.createTask(original),/夹具无效/);
}
console.log('PASS entry-only runtime validation transport: shipping gate, fixed sources/loopback, no credentials, unchanged integrity/path/activity facts, malformed fixture fails closed');
