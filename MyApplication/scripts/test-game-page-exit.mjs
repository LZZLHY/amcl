/**
 * 前端终局接线回归：执行真实McGamePage.doExit，证明图形结局最后采集后只委托稳定会话。
 * 前台归还/ACK/拒绝/重复/无前端退出的实际生产合同由test-game-session-host完整执行。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';
const source=fs.readFileSync(new URL('../entry/src/main/ets/pages/McGamePage.ets',import.meta.url),'utf8');
const ast=compiler.createSourceFile('McGamePage.ets',source,compiler.ScriptTarget.Latest,true);
const owner=ast.statements.find(n=>n.members?.some(m=>m.name?.getText(ast)==='doExit'));
assert.ok(owner);
const text=owner.members.find(m=>m.name?.getText(ast)==='doExit').getText(ast);
const compiled=compiler.transpileModule('class Probe {\n'+text+'\n}\nreturn Probe;',
  {compilerOptions:{target:compiler.ScriptTarget.ES2020}}).outputText;
const Probe=new Function(compiled)();
const subject=new Probe(),events=[];
let finish;
subject.navigatedAway=false;
subject.pollGraphicsFailure_=value=>events.push(['failure',value]);
subject.collectGraphicsMetrics_=value=>events.push(['metrics',value]);
subject.sessionHost={requestExit:()=>{events.push(['session-exit']);return new Promise(resolve=>{finish=resolve;});}};
const pending=subject.doExit();
assert.deepEqual(events,[['failure',false],['metrics',true],['session-exit']]);
assert.equal(subject.navigatedAway,true,'前端先关闭重复请求，不等平台异步完成');
await subject.doExit();assert.equal(events.length,3,'重复前端请求不得重采集/重启动终局');
finish();await pending;
assert.match(source,/private requestExit_\(\): void[\s\S]*?this\.doExit\(\)\.catch/);
assert.equal(source.includes('private startLogPoll_()'),false,'生产退出轮询已经归会话');
console.log('PASS frontend exit: final graphics evidence precedes one session handoff; runtime exit no longer page-owned');
