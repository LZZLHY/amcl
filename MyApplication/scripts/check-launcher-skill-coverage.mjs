/** 核对稳定业务行、实际方法与变更证据。业务语义最终由评审对照页面和原对象决定。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {execFileSync, spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const repo=fileURLToPath(new URL('../',import.meta.url));
const table='docs/refactor/启动器业务覆盖表.md';
const contracts='config/launcher-skill';
const read=f=>fs.readFileSync(path.join(repo,f),'utf8').replace(/^\uFEFF/,'').replaceAll('\r\n','\n');
const git=(...args)=>execFileSync('git',['-C',repo,...args],{encoding:'utf8',maxBuffer:32*1024*1024});
const split0=s=>s.split('\0').filter(Boolean);
const migrationCommit='468e461871e67a7227a0a1d1bb7c06bd7d632799';
const isCommit=id=>/^[0-9a-f]{40}$/.test(id) && !/^0+$/.test(id);
const ancestor=(a,b)=>spawnSync('git',['-C',repo,'merge-base','--is-ancestor',a,b]).status===0;
function changeBase() {
  const arg=process.argv[2];
  if (arg === undefined) return '';
  if (arg !== '--ci') {
    assert.ok(isCommit(arg),'expected complete base SHA');
    return arg;
  }
  const event=JSON.parse(fs.readFileSync(process.env.GITHUB_EVENT_PATH,'utf8'));
  if (event.pull_request) {
    assert.ok(isCommit(event.pull_request.base.sha),'invalid pull request base');
    return event.pull_request.base.sha;
  }
  if (event.before && !/^0+$/.test(event.before)) {
    assert.ok(isCommit(event.before),'invalid push base');
    return event.before;
  }
  // 首推 dev 等已存在主线的分支没有 before。用该仓默认远端分支的共同先祖覆盖整个分支差异。
  const branch=event.repository?.default_branch;
  const remoteHead=spawnSync('git',['-C',repo,'symbolic-ref','-q','refs/remotes/origin/HEAD'],{encoding:'utf8'});
  const refs=new Set([...(typeof branch==='string' && branch ? ['refs/remotes/origin/'+branch] : []),
    ...(remoteHead.status===0 ? [remoteHead.stdout.trim()] : []),'refs/remotes/origin/main','refs/remotes/origin/master']);
  for (const ref of refs) {
    const target=spawnSync('git',['-C',repo,'show-ref','--verify','--hash',ref],{encoding:'utf8'});
    if (target.status!==0) continue;
    const shared=spawnSync('git',['-C',repo,'merge-base',target.stdout.trim(),'HEAD'],{encoding:'utf8'});
    if (shared.status===0 && shared.stdout.trim()!==git('rev-parse','HEAD').trim()) return shared.stdout.trim();
  }
  if (ancestor(migrationCommit,'HEAD')) return migrationCommit;
  return '';
}
function playerSurface(file,base) {
  if (/^(?:config\/products\.json|entry\/build-profile\.json5|[^/]+\/src\/[^/]+\/(?:module\.json5|resources\/base\/profile\/main_pages\.json))$/.test(file)) return true;
  if (!/^[^/.][^/]*\/src\/[^/]+\/.*\.ets$/.test(file)) return false;
  if (/\/(?:pages|components)\//.test(file)) return true;
  const previous=spawnSync('git',['-C',repo,'show',base+':'+file],{encoding:'utf8',maxBuffer:16*1024*1024});
  const widget=/^\s*@(?:Entry|Component(?:V2)?|Builder)\b/m;
  return (fs.existsSync(path.join(repo,file)) && widget.test(read(file))) ||
    (previous.status===0 && widget.test(previous.stdout));
}
function rows(text, legacy=false) {
  const section=text.split('## 业务明细')[1]?.split('## 证据与后续维护')[0];
  assert.ok(section,'missing launcher inventory');
  const indexed=new Map(), labels=new Set();
  for (const line of section.split('\n')) {
    if (!line.startsWith('|') || line.startsWith('| 用户操作') || /^[|:\s-]+$/.test(line)) continue;
    const cells=line.slice(1,-1).split('|').map(s=>s.trim());
    assert.ok(cells.length===6 && cells.every(Boolean),'incomplete business row: '+line);
    const idMark=/^\*\*(L\d{3,})\*\*\s+/.exec(cells[0]);
    assert.ok(idMark || legacy,'missing stable ID: '+cells[0]);
    const id=idMark?.[1] ?? 'L'+String(indexed.size+1).padStart(3,'0');
    const label=cells[0].slice(idMark?.[0].length ?? 0);
    assert.ok(!indexed.has(id) && !labels.has(label),'duplicate row ID or player operation: '+id);
    labels.add(label);
    const status=/^(完整|部分|不可用)。/.exec(cells[4])?.[1];
    const methods=[...cells[4].matchAll(/`([A-Za-z][A-Za-z0-9]+)`/g)].map(m=>m[1]);
    assert.ok(status && (status!=='完整' || methods.length),id+' lacks a named business method');
    const owners=[...cells[1].matchAll(/\]\(\.\.\/\.\.\/([^()#]+)(?:#[^)]*)?\)/g)].map(m=>m[1]);
    indexed.set(id,{label,methods,status,owners,summary:[label,...cells.slice(1)].join('|')});
  }
  return indexed;
}
function catalog(sources) {
  const result=new Map();
  for (const body of sources) for (const m of JSON.parse(body.replace(/^\uFEFF/,''))) {
    assert.ok(!result.has(m.name),'duplicate method '+m.name);
    result.set(m.name,m);
  }
  return result;
}
const methods=catalog(fs.readdirSync(path.join(repo,contracts)).filter(f=>f.endsWith('.json')).map(f=>read(contracts+'/'+f)));
const active=rows(read(table));
const coverage=new Set();
for (const [id,row] of active) for (const method of row.methods) {
  assert.ok(methods.has(method),id+' unknown method '+method);
  coverage.add(method);
}
for (const method of methods.keys()) assert.ok(coverage.has(method),'method missing from inventory: '+method);
const complete=[...active.values()].filter(row=>row.status==='完整').length;
assert.ok(active.size>=105 && complete*100>active.size*95,'launcher business coverage below accepted floor');
const requestedBase=changeBase();
// 首次合入可能同时带来约 226 个已有方法。复用确切验收过的先祖作为迁移边界，
// 普通增量和独立克隆仍以自身的 PR/push 源快照比较，无须原维护者设备或目录。
const base=requestedBase && ancestor(requestedBase,migrationCommit) && ancestor(migrationCommit,'HEAD') ? migrationCommit : requestedBase;
const proofs=new Set();
const changedRelations=new Map();
if (base) {
  const changedFiles=new Set([...split0(git('diff','--name-only','--no-renames','-z',base,'--')),
    ...split0(git('ls-files','--others','--exclude-standard','-z'))]);
  const priorPaths=split0(git('ls-tree','-r','-z','--name-only',base,'--',table,contracts));
  const priorTable=priorPaths.includes(table)?git('show',base+':'+table):'';
  const baselineHasIds=/\*\*L\d+\*\*/.test(priorTable);
  const old=priorTable.includes('官方入口（代码）') || baselineHasIds ? rows(priorTable,!baselineHasIds) : new Map();
  const oldMethods=catalog(priorPaths.filter(f=>f.startsWith(contracts+'/') && f.endsWith('.json')).map(f=>git('show',base+':'+f)));
  // 首次引入这一整套门禁时，旧仓可能没有覆盖表。若有可比行，则逐个保护身份及能力归属。
  for (const id of old.keys()) assert.ok(active.has(id),'existing business ID removed: '+id);
  const changed=[...active].filter(([id,r])=>old.get(id)?.summary!==r.summary);
  for (const file of changedFiles) {
    if (!old.size || !playerSurface(file,base) || changed.some(([,row])=>row.owners.includes(file))) continue;
    // 只采信本次范围内最后修改此文件的提交或本次 PR 说明，不能继承其它文件的豁免。
    const note=git('log','-1','--format=%B',base+'..HEAD','--',file)+'\n'+(process.env.AMCL_QA_REVIEW_NOTES ?? '');
    const lines=note.split(/\r?\n/).map(line=>line.trim());
    const assigned=lines.some(line=>{
      const prefix='Launcher-QA-Row: '+file+' — ';
      return line.startsWith(prefix) && active.get(line.slice(prefix.length))?.owners.includes(file);
    });
    const excluded=['Launcher-QA-Display: ','Launcher-QA-Outside: '].some(kind=>lines.some(line=>{
      const prefix=kind+file+' — ';
      return line.startsWith(prefix) && line.slice(prefix.length).trim().length>=4;
    }));
    assert.ok(assigned || excluded,'Player-facing change needs a matching business row or scoped review note: '+file);
  }
  for (const [id,row] of changed) {
    const before=old.get(id);
    if (!before && !old.size) continue;
    const added=row.methods.filter(m=>!before?.methods.includes(m));
    const promoted=row.status==='完整' && before?.status!=='完整';
    const replaced=row.status==='完整' && before?.methods.some(m=>!row.methods.includes(m));
    if (promoted || replaced) {
      if (!added.length) added.push(...row.methods);
      changedRelations.set(id,added);
    }
    for (const m of added) {
      const owner=methods.get(m).verification?.owner;
      assert.ok(owner && row.owners.includes(owner),id+' needs the production owner and tested implementation of '+m);
      proofs.add(m);
    }
  }
  for (const [name,m] of methods) {
    const oldMethod=oldMethods.get(name);
    const shape=entry=>JSON.stringify([entry.domain,entry.args.map(a=>[a.name,a.type,a.required,a.enum]),entry.cases,
      ...(baselineHasIds ? [entry.results,entry.requiredOutput,entry.output,entry.outputCases,entry.echoArgs,entry.echoTrimArgs,entry.targetMembers,entry.disjointOutput,entry.memberOf,entry.userHandoff,entry.verification] : [])]);
    if ((old.size && (!oldMethod || shape(oldMethod)!==shape(m))) || (!old.size && m.verification)) proofs.add(name);
  }
} else {
  // 独立快照/无比较基线：执行已有的生产行为绑定，不能把静态行数当增量检查。
  for (const [name,m] of methods) if (m.verification) proofs.add(name);
}
{
  const suites=new Map();
  const rowEvidence=new Map();
  for (const name of proofs) {
    const v=methods.get(name).verification;
    assert.ok(v && /^[\w-]+\/src\/[\w-]+\/[\w/.-]+\.ets$/.test(v.owner) && !v.owner.split('/').includes('..') &&
      /^(?:qa\/device|scripts)\/test-[\w-]+\.mjs$/.test(v.test),'missing production verification for '+name);
    const owner=read(v.owner).replace(/\/\*[\s\S]*?\*\//g,'').replace(/^\s*\/\/.*$/gm,'');
    assert.ok(!v.owner.includes('SkillMethodCatalog') && !v.owner.includes('/skills/') &&
      (owner.includes("'"+name+"'") || owner.includes('"'+name+'"') ||
       owner.includes("LauncherSkillBus.bind('"+methods.get(name).domain+"'")),name+' not found in declared production owner '+v.owner);
    if (!suites.has(v.test)) suites.set(v.test,[]);
    suites.get(v.test).push(name);
  }
  for (const [test,needed] of suites) {
    const observed=Object.fromEntries(needed.map(name=>[name,methods.get(name).verification.owner]));
    const run=spawnSync(process.execPath,['--import','./scripts/lib/skill-business-check.mjs',test],{cwd:repo,encoding:'utf8',
      env:{...process.env,AMCL_VERIFY_SKILL_CASES:'1',AMCL_VERIFY_SKILL_OWNERS:JSON.stringify(observed)}});
    if (run.status!==0) throw Error(test+' failed: '+run.stdout+'\n'+run.stderr);
    const cases=run.stdout.split(/\r?\n/).filter(l=>l.startsWith('AMCL_SKILL_CASE ')).map(l=>JSON.parse(l.slice(16)));
    const passed=new Set(cases.map(item=>item.method));
    for (const item of cases) {
      if (!needed.includes(item.method) || !item.row) continue;
      if (!rowEvidence.has(item.row)) rowEvidence.set(item.row,new Set());
      rowEvidence.get(item.row).add(item.method);
    }
    for (const name of needed) assert.ok(passed.has(name),test+' did not exercise positive and rejected business paths for '+name);
  }
  // 新建完整行、升为完整或改换绑定方法，须有这个业务行自己的真实场景；不能借用别行的绿灯。
  for (const [id,names] of changedRelations) assert.ok(names.some(name=>rowEvidence.get(id)?.has(name)),id+' lacks a business case for its new mapping');
}
console.log('Launcher inventory: '+complete+'/'+active.size+' complete rows; '+methods.size+' named methods'+(base?' checked against '+base:'.'));
