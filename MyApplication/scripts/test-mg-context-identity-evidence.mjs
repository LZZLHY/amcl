/** 两个真实Linux production owner正例/旧owner阴性，及轻量报告字段毒化控制。
 * 不执行GPU或重写原fixtures；poison保持pass/footer来证明薄门独立核原始字段。
 */
import fs from 'node:fs';
import { createHash } from 'node:crypto';
import { auditMgContextIdentityRows,loadMgContextIdentityContract } from './lib/mg-context-identity-evidence.mjs';
const root=new URL('fixtures/mg-context-identity-evidence/',import.meta.url);
const source=JSON.parse(fs.readFileSync(new URL('source.json',root)));
const contract=loadMgContextIdentityContract();
const rows=new Map(),cases=[];
const record=(name,value,expected)=>{
  const result=auditMgContextIdentityRows(value,name.includes('high'),contract);
  cases.push({name,expected,actual:result.ok,matched:result.ok===expected,issues:result.issues});
};
for(const name of ['low','high','old-low','old-high']){
  const bytes=fs.readFileSync(new URL(name+'.jsonl',root));
  if(createHash('sha256').update(bytes).digest('hex')!==source.fixtureSha256[name+'.jsonl'])throw new Error('Actual raw fixture identity differs: '+name);
  const parsed=bytes.toString().trimEnd().split('\n').map(line=>JSON.parse(line));rows.set(name,parsed);
  record(name,parsed,!name.startsWith('old-'));
}
// 字段名来自共享机器契约和真实producer，不能只变expected/pass为相同自校验算法。
const poison=[
  ['flip-independent-order',value=>{value[2].highFirst=!value[2].highFirst;}],
  ['wrong-owner-api',value=>{value[2].ownerDesktop=false;}],
  ['wrong-runtime-api',value=>{value[2].runtimeDesktop=false;}],
  ['expand-core',value=>{value[2].coreQualified=true;}],
  ['foreign-query-image',value=>{value[1].queryImage='/foreign/provider.so';}],
  ['foreign-egl-entry',value=>{value[1].eglEntries[0].owned=false;}],
  ['zero-egl-address',value=>{value[1].eglEntries[0].address='0';}],
  ['duplicate-egl-entry',value=>{value[1].eglEntries[1].name=value[1].eglEntries[0].name;}],
  ['missing-egl-table',value=>{delete value[1].eglEntries;}],
  ['null-egl-entry',value=>{value[1].eglEntries[0]=null;}],
  ['fake-production-probe',value=>{value.find(row=>row.case==='identity-production-feature-probe').probed=false;}],
  ['fake-topology',value=>{value.find(row=>row.case==='identity-production-feature-probe').auxiliaryVerified=false;}],
  ['create-alias',value=>{value.find(row=>row.case==='identity-create-high').context=value.find(row=>row.case==='identity-create-low').context;}],
  ['create-no-permit',value=>{value.find(row=>row.case==='identity-create-low').permit=0;}],
  ['duplicate-live-permits',value=>{value.find(row=>row.case==='identity-create-high').permit=value.find(row=>row.case==='identity-create-low').permit;}],
  ['operation-contradicts-desktop',value=>{value[2].operation='gles';}],
  ['same-pointer-conflicting-texts',value=>{
    const pointer=value.find(row=>row.turn===0).versionPointer;
    for(const row of value.filter(row=>row.kind==='context-identity')){
      row.versionPointer=pointer;for(const held of row.heldVersions)held.pointer=pointer;
    }
  }],
  ['same-numeric-pointer-leadingzero-conflicting-texts',value=>{
    const pointer=value.find(row=>row.slot==='low'&&row.turn!==undefined).versionPointer;
    const alias='0x0'+pointer.slice(2);
    for(const row of value.filter(row=>row.kind==='context-identity')){
      row.versionPointer=row.slot==='low'?pointer:alias;
      for(const held of row.heldVersions)held.pointer=held.slot==='low'?pointer:alias;
    }
  }],
  ['same-numeric-context-leadingzero-alias',value=>{
    const pointer=value.find(row=>row.case==='identity-create-low').context,alias='0x0'+pointer.slice(2);
    value.find(row=>row.case==='identity-create-high').context=alias;
    for(const row of value.filter(row=>row.kind==='context-identity'&&row.slot==='high'))row.context=alias;
  }],
  ['current-false',value=>{value.find(row=>row.turn===1).current=false;}],
  ['wrong-request',value=>{value.find(row=>row.turn===0).requested=[9,7];}],
  ['wrong-read-order',value=>{value.find(row=>row.turn===0).readOrder='integer-first';}],
  ['es-frontend',value=>{value.find(row=>row.turn===0).eglApi=12448;}],
  ['egl-major-mismatch',value=>{value.find(row=>row.turn===0).eglClientMajor=99;}],
  ['below-request',value=>{const row=value.find(row=>row.turn===0);row.integer=[1,0];row.stringInteger=[1,0];row.ownerInteger=[1,0];row.version='1.0';}],
  ['grant-mismatch',value=>{value.find(row=>row.turn===0).ownerInteger=[9,7];}],
  ['version-mismatch',value=>{value.find(row=>row.turn===0).version='9.7';}],
  ['profile-mismatch',value=>{value.find(row=>row.turn===0).profile=0;}],
  ['flags-mismatch',value=>{value.find(row=>row.turn===0).ownerFlags=99;}],
  ['forward-lost',value=>{const row=value.find(row=>row.slot==='low'&&row.turn!==undefined);row.flags=0;row.ownerFlags=0;}],
  ['pointer-changed',value=>{value.find(row=>row.turn===2).versionPointer='0x777';}],
  ['held-content-overwritten',value=>{value.find(row=>row.turn===1).heldVersions[0].actual='9.7';}],
  ['missing-held',value=>{value.find(row=>row.turn===1).heldVersions.pop();}],
  ['query-tail-error',value=>{value.find(row=>row.turn===0).errorCount=1;}],
  ['query-undrained',value=>{value.find(row=>row.turn===0).errorDrainComplete=false;}],
  ['wrong-owner-tid',value=>{value.find(row=>row.turn===0).ownerTid=0;}],
  ['egl-query-error',value=>{value.find(row=>row.turn===0).eglError=0x3002;}],
  ['missing-original-field',value=>{delete value.find(row=>row.turn===0).renderer;}],
  ['live-retirement',value=>{value.find(row=>row.case==='identity-retire-low').permit=999;}],
  ['retirement-not-attempted',value=>{value.find(row=>row.case==='identity-retire-low').attempted=false;}],
  ['missing-turn',value=>{value.splice(value.findIndex(row=>row.turn===2),1);}],
  ['duplicate-turn',value=>{value.splice(9,0,structuredClone(value.find(row=>row.turn===0)));}],
  ['extra-record',value=>{value.splice(2,0,{kind:'unknown'});}],
  ['duplicate-footer',value=>{value.push(structuredClone(value.at(-1)));}],
  ['truncated-footer',value=>{value.pop();}],
  ['footer-counter',value=>{value.at(-1).checks=12;}],
];
for(const order of ['low','high'])for(const [name,change]of poison){
  const altered=structuredClone(rows.get(order));change(altered);
  record(order+'-'+name,altered,false);
}
// 两个context授予同一更高版本时，规范允许相同immutable string共用地址；
// 这条完整自洽阳性防止把上述矛盾限制误写成“不同ctx必须不同pointer”。
for(const order of ['low','high']){
  const value=structuredClone(rows.get(order)),pointer=value.find(row=>row.turn===0).versionPointer;
  for(const row of value.filter(row=>row.kind==='context-identity')){
    row.integer=[4,0];row.stringInteger=[4,0];row.ownerInteger=[4,0];row.eglClientMajor=4;
    row.version='4.0 shared immutable';row.versionPointer=pointer;
    for(const held of row.heldVersions){held.pointer=pointer;held.expected=row.version;held.actual=row.version;}
  }
  record(order+'-same-pointer-same-immutable-content',value,true);
}
const failed=cases.filter(row=>!row.matched);
const summary={completed:true,passed:failed.length===0,cases:cases.length,failed,
  scope:'actual Linux raw + parser-only report controls; no device/PID/RETURN qualification',
  contractSha256:contract.contractSha256,loaderSha256:contract.loaderSha256};
console.log(JSON.stringify(summary,null,2));
process.exitCode=summary.passed?0:1;
