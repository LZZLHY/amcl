/** 完整大目录的真实UI分页方法回归：每屏只读取32份payload，页尾/当前定位/删除夹取保持全部条目可达。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
const load=makePureEtsLoader(),paging=load('entry/src/main/ets/components/LayoutCatalogPaging.ets');
const names=Array.from({length:131073},(_,index)=>'layout_'+index);
const all=[];
for(let page=0;page<paging.layoutCatalogPageCount(names);page++){
  const current=paging.layoutCatalogPage(names,page);assert.ok(current.length<=32);all.push(...current);
}
assert.deepEqual(all,names);assert.equal(paging.layoutCatalogPageCount(names),4097);
assert.deepEqual(paging.layoutCatalogPage(names,Infinity),names.slice(0,32));

function component(relative,type,methods){
  const file=path.resolve(import.meta.dirname,'..',relative),source=fs.readFileSync(file,'utf8');
  const ast=compiler.createSourceFile(file,source,compiler.ScriptTarget.Latest,true),owner=ast.statements.find(n=>n.name?.getText(ast)===type);
  const members=methods.map(name=>{const m=owner.members.find(n=>n.name?.getText(ast)===name);assert.ok(m,name);return m.getText(ast);});
  const js=compiler.transpileModule('class Subject{'+members.join('\n')+'}\nmodule.exports=Subject;',
    {compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020}}).outputText;
  const module={exports:{}};new Function('module',...Object.keys(paging),js)(module,...Object.values(paging));return new module.exports();
}
// 目录管理只属于独立方案库；布局编辑器不再持有另一套目录分页状态。
for(const[relative,type]of [['entry/src/main/ets/pages/LayoutListPage.ets','LayoutListPage']]){
  const ui=component(relative,type,['profilePageNames_','profilePageCount_','moveProfilePage_','showCurrentProfilePage_']);
  Object.assign(ui,{profileNames:names,profilePage:0,profileName:names.at(-1),activeName:names.at(-1)});
  assert.equal(ui.profilePageCount_(),4097);ui.showCurrentProfilePage_();assert.equal(ui.profilePage,4096);
  assert.deepEqual(ui.profilePageNames_(),[names.at(-1)]);ui.moveProfilePage_(1);assert.equal(ui.profilePage,4096);
  ui.moveProfilePage_(-1);assert.equal(ui.profilePageNames_().length,32);
  ui.profileNames=names.slice(0,2);ui.moveProfilePage_(0);assert.equal(ui.profilePage,0);assert.deepEqual(ui.profilePageNames_(),names.slice(0,2));
}
{
  const ui=component('entry/src/main/ets/pages/LayoutListPage.ets','LayoutListPage',['columnNames','profilePageNames_']);
  const reads=[];Object.assign(ui,{profileNames:names,profilePage:4095,estimateCardHeight:name=>{reads.push(name);return 100;}});
  const left=ui.columnNames(0),right=ui.columnNames(1),expected=paging.layoutCatalogPage(names,4095);
  assert.deepEqual([...left,...right].sort(),expected.slice().sort());
  assert.ok(reads.every(name=>expected.includes(name)),'两列缩略图不能遍历页外payload');
  assert.equal(reads.length,64,'每列只对当前32条分配高度，不因完整目录而放大IO');
}
console.log('PASS real layout library paging: all 131073 entries reachable, 4097 pages, active/tail/deletion safe, only page payloads read');
