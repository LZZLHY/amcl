/** 用独立 Git 小仓运行真实增量门，覆盖 UI 漏接、换行借用和目录空实现；测试成功回收本轮亲建目录。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {createHostTestScope} from './lib/host-test-lifecycle.mjs';

const scope=createHostTestScope('launcher-coverage-');
const repo=path.join(scope.directory,'source');
fs.mkdirSync(repo);
const table='docs/refactor/启动器业务覆盖表.md';
const owner='feature/src/main/ets/AccountPanel.ets';
const suite='scripts/test-account.mjs';
const gate='scripts/check-launcher-skill-coverage.mjs';
const catalog='config/launcher-skill/players.json';
const event=path.join(scope.directory,'event.json');
function write(file,body) {
  const dest=path.join(repo,file);
  fs.mkdirSync(path.dirname(dest),{recursive:true});
  fs.writeFileSync(dest,body);
}
function command(exe,args,extra={}) {
  const env={...process.env,AMCL_QA_REVIEW_NOTES:'',AMCL_VERIFY_SKILL_OWNERS:'',GITHUB_EVENT_PATH:event,...extra};
  const p=spawnSync(exe,args,{cwd:repo,encoding:'utf8',env});
  if(p.error) throw p.error;
  return {status:p.status,text:p.stdout+p.stderr};
}
function git(...args) {
  const p=command('git',args);assert.equal(p.status,0,p.text);return p.text.trim();
}
function commit(message) { git('add','--all');git('commit','--no-gpg-sign','-qm',message);return git('rev-parse','HEAD'); }
function check(base,error,extra) {
  const p=command(process.execPath,[gate,base],extra);
  if (error) {assert.notEqual(p.status,0,p.text);assert.match(p.text,error);}
  else assert.equal(p.status,0,p.text);
}
function row(i,method=i===104?'otherAction':'knownAction',status=i===105?'部分':'完整') {
  const id='L'+String(i).padStart(3,'0');
  return '| **'+id+'** 业务 '+i+' | [页面](../../'+owner+') | 现有 QA | 执行 | '+status+'。`'+method+'` | 原对象状态 |';
}
const lines=Array.from({length:105},(_,i)=>row(i+1));
function tableText(rows=lines) {
  return ['## 业务明细','| 用户操作 | 页面 | QA | 设计 | 官方入口（代码） | 观察 |','|---|---|---|---|---|---|',...rows,'## 证据与后续维护'].join('\n');
}
const methods=['knownAction','otherAction'].map(name=>({name,domain:'players',args:[],results:['ready'],verification:{owner,test:suite}}));
const source="export function run(method,allowed){if(!allowed)return {state:'failed'};switch(method){case 'knownAction':case 'otherAction':return {state:'ready',value:7};default:return {state:'unavailable'};}}";
const pageText='// @Component 标记仅用于测试夹具\n'+source+'\n@Component\n';
const runner=`import fs from 'node:fs';
import {verifySkillCases} from './lib/skill-business-check.mjs';
const source=fs.readFileSync('${owner}','utf8').split('export function')[1].split('\\n@Component')[0];
const {run}=await import('data:text/javascript,'+encodeURIComponent('export function'+source));
for(const m of ['knownAction','otherAction'])verifySkillCases(m,run(m,true),run(m,false));
`;
git('init','--quiet');git('config','user.name','coverage fixture');git('config','user.email','fixture@example.invalid');
git('config','core.autocrlf','false');write('README.md','Independent snapshot');const empty=commit('initialize');
for(const file of [gate,'scripts/lib/skill-business-check.mjs'])write(file,fs.readFileSync(new URL('../'+file,import.meta.url)));
write(table,tableText());write(owner,pageText);write(suite,runner);
const legacy=methods.map(({verification,...method})=>method);
write(catalog,JSON.stringify(legacy));const oldContract=commit('existing operations before behavior evidence');
for (const change of [{userHandoff:true},{outputCases:[{when:{state:'ready'},require:['operationRef']}]}]) {
  write(catalog,JSON.stringify([{...legacy[0],...change},legacy[1]]));
  check(oldContract,/verification/);
}
write(catalog,JSON.stringify(methods));
const base=commit('initial inventory');check(empty);
// 提交一只手工按钮后再提交独立文字，门禁仍能通过 PR 或 push 的完整基线看见前一个提交。
write(owner,pageText+"// Button('复制版本').onClick(copyVersion)\n");const button=commit('add human button');
write('README.md','Next commit');commit('unrelated text');
for(const payload of [{pull_request:{base:{sha:base}}},{before:base}]) {
  fs.writeFileSync(event,JSON.stringify(payload));check('--ci',/matching business row/);
}
check(base,/matching business row/,{AMCL_QA_REVIEW_NOTES:'Launcher-QA-Display: another/file — 仅调整颜色'});
check(base,undefined,{AMCL_QA_REVIEW_NOTES:'Launcher-QA-Display: '+owner+' — 仅调整字体颜色'});
check(base,undefined,{AMCL_QA_REVIEW_NOTES:'Launcher-QA-Row: '+owner+' — L001'});
// 正常独立克隆即使没有私有源仓锚点，也可以从自己的表增量验收；初次无 before 时检查当前快照。
fs.writeFileSync(event,JSON.stringify({before:'0'.repeat(40)}));check('--ci');
// 独立仓的首推只有目标分支的 before 为空；只要该仓默认远端分支有共同先祖就不能退回静态检查。
git('update-ref','refs/remotes/origin/trunk',base);
fs.writeFileSync(event,JSON.stringify({before:'0'.repeat(40),repository:{default_branch:'trunk'}}));
check('--ci',/matching business row/);
const profile='entry/build-profile.json5';
write(profile,'{"targets":[{"name":"store","source":{"pages":"changed"}}]}');
check(button,/matching business row or scoped review note: entry\/build-profile\.json5/);
fs.unlinkSync(path.join(repo,profile));
write(table,tableText([...lines.slice(1),row(106)]));check(button,/existing business ID removed/);
write(table,tableText([...lines.slice(1),row(2)]));check(button,/duplicate row/);
const replaced=[...lines];replaced[104]=row(105,'otherAction','完整');
write(table,tableText(replaced));check(button,/L105 lacks a business case/);
write(suite,runner+"verifySkillCases('otherAction',run('otherAction',true),run('otherAction',false),'L105');\n");check(button);
write(suite,runner);write(table,tableText([...lines.slice(0,103),row(104,'otherAction').replace('`otherAction`','`otherAction`、`ghostAction`'),lines[104]]));
write(catalog,JSON.stringify([...methods,{name:'ghostAction',domain:'players',args:[],results:['ready']}]));
check(button,/production owner|verification/);
const ghost={...methods[0],name:'ghostAction'};
write(catalog,JSON.stringify([...methods,ghost]));check(button,/not found in declared production owner/);
write(owner,pageText.replace("case 'otherAction':","case 'otherAction':case 'ghostAction':"));
check(button,/did not exercise.*ghostAction/);
write(suite,runner.replace("['knownAction','otherAction']","['knownAction','otherAction','ghostAction']"));
check(button);console.log('PASS independent snapshot, multi-commit PR/push, scoped notes, stable rows, mapped behavior and unimplemented catalog action');
