/**
 * 真实产品BMS parser回归。UTF-8/SHA由宿主平台提供，身份、前缀差分和终态判据执行原ETS。
 * 全部日志是明确夹具；格式向量模拟API26混合小数/HiTrace，不伪造旧手机baseline或安装通过。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {createHash} from 'node:crypto';
import compiler from './lib/ets-compiler.mjs';
function load(file,deps={}) {
  const exports={};const source=fs.readFileSync(new URL('../'+file,import.meta.url),'utf8');
  const js=compiler.transpileModule(source,{compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020}}).outputText;
  vm.runInNewContext(js,{exports,require:n=>{if(!(n in deps))throw Error('Unmocked '+n);return deps[n];},JSON,Number,String,RegExp,Uint8Array});return exports;
}
const files=load('entry/src/main/ets/sideload/SideloadFiles.ets',{'@kit.CoreFileKit':{},'@kit.CryptoArchitectureKit':{},commons:{}});
const protocol=load('entry/src/main/ets/sideload/SideloadInstallProtocol.ets',{'./SideloadFiles':files});
const evidence=load('entry/src/main/ets/sideload/BmTerminalEvidence.ets',{'./SideloadInstallProtocol':protocol,
  '@kit.ArkTS':{util:{TextDecoder:{create:(encoding,options)=>({decodeToString:bytes=>new TextDecoder(encoding,options).decode(bytes)})}}}});
const P=protocol.SideloadInstallProtocol,B=evidence.BmTerminalEvidence;
const identity={installId:'a'.repeat(32),ownerAttemptId:'b'.repeat(32),nonce:'c'.repeat(32),bundleName:'com.amcl.launcher',product:'sideload',
  beforeVersionCode:1,beforeUid:20000001,versionCode:2,expectedPayloadIdentity:'d'.repeat(40),signedPath:'/sandbox/tasks/candidate.hap',signedSha256:'e'.repeat(64)};
const line=(time,text,pid=88)=>time+' '+pid+' '+pid+' I C01123/bm/BMSTool: '+text;
const begin=line('10.020','[main.cpp(main:21)]bm exec start'),end=line('10.210','[main.cpp(main:24)]bm exec end');
const finished=line('10.200','[status_receiver_impl.cpp(OnFinished:43)]on finished result is 0, success');
const log=[begin,finished,end].join('\n')+'\n';
const snapshot=body=>{const bytes=new Uint8Array(Buffer.isBuffer(body)?body:Buffer.from(body,'utf8'));return{bytes,sha256:createHash('sha256').update(bytes).digest('hex')};};
function proof(baselineBody='',postBody=log,processChanges={}) {
  const baseline=snapshot(baselineBody),post=snapshot(postBody);
  const claim={...JSON.parse(P.record(identity,'claimed',true,2)),bmEvidenceVersion:1,bmPid:88,bmEvidenceDirectory:'bm-evidence-88',
    baselineBytes:baseline.bytes.byteLength,baselineSha256:baseline.sha256,bmGroup:88,bmSession:88,reservationPid:89,reservationStartTicks:1001,reservationInode:'12345'};
  const authority=P.evidenceAuthority(identity,JSON.stringify(claim),'link');
  const process={installId:identity.installId,nonce:identity.nonce,bmPid:88,startTicks:1000,clockTicks:100,bmEvidenceVersion:1,
    ...processChanges,baselineBytes:baseline.bytes.byteLength,baselineSha256:baseline.sha256,
    bmGroup:88,bmSession:88,reservationPid:89,reservationStartTicks:1001,reservationInode:'12345'};
  const receipt={protocol:2,bmEvidenceVersion:1,installId:identity.installId,nonce:identity.nonce,candidateSha256:identity.signedSha256,
    targetVersionCode:identity.versionCode,beforeUid:identity.beforeUid,bmPid:88,format:'hilog-monotonic-msec',baselineComplete:true,postComplete:true,
    baselineBytes:baseline.bytes.byteLength,baselineSha256:baseline.sha256,postBytes:post.bytes.byteLength,postSha256:post.sha256,
    pidReservationComplete:true,reservationPid:89,reservationStartTicks:1001,reservationInode:'12345'};
  return{baseline,post,authority,process,receipt,claim};
}
const classify=p=>B.classify(identity,p.authority,JSON.stringify(p.process),JSON.stringify(p.receipt),p.baseline,p.post);
assert.equal(classify(proof()).kind,'bms-success');
assert.equal(classify(proof('',log.replace('is 0,','is 9568269,'))).kind,'bms-failure');
for(const invalid of [begin+'\n'+end+'\n',finished+'\n',end+'\n',log+begin+'\n',log+finished+'\n',log+end+'\n',
  log.replace('C01123','C01124'),log.replaceAll('BMSTool','OtherTag'),log.replace('OnFinished','GetResultCode'),
  log.replaceAll('88','89'),log.replaceAll('10.','09.'),log.slice(0,-1),'x'.repeat(65536)+log,
  log.replace('[status_receiver_impl.cpp','[unknown][status_receiver_impl.cpp'),
  log.replace('[status_receiver_impl.cpp','[aa bb cc][aa bb cc][status_receiver_impl.cpp')])assert.equal(classify(proof('',invalid)),undefined);
for(const change of [{nonce:'f'.repeat(32)},{startTicks:0},{clockTicks:0},{bmPid:0},{bmEvidenceVersion:undefined}])assert.equal(classify(proof('',log,change)),undefined);
for(const change of [{baselineComplete:false},{postComplete:false},{bmEvidenceVersion:0},{baselineBytes:1},{postBytes:1},
  {baselineSha256:'f'.repeat(64)},{postSha256:'f'.repeat(64)},{candidateSha256:'f'.repeat(64)},{nonce:'f'.repeat(32)},
  {pidReservationComplete:false},{reservationPid:90},{reservationStartTicks:0},{reservationInode:'54321'}]) {
  const p=proof();Object.assign(p.receipt,change);assert.equal(classify(p),undefined);
}
for(const field of ['baseline','post','authority']){const p=proof();p[field]=undefined;assert.equal(classify(p),undefined);}
const hashMismatch=proof();hashMismatch.baseline.sha256='f'.repeat(64);assert.equal(classify(hashMismatch),undefined);
const badUtf8=proof(Buffer.from([0xff,10]),Buffer.concat([Buffer.from([0xff,10]),Buffer.from(log)]));assert.equal(classify(badUtf8),undefined);
const prior=log.replaceAll('10.','09.');
assert.equal(classify(proof(prior,prior+log)).kind,'bms-success');
assert.equal(classify(proof(prior,log)),undefined,'post without original baseline prefix cannot be fresh');
assert.equal(classify(proof(prior,prior)),undefined,'no new suffix gives no terminal');
assert.equal(classify(proof(log,log)),undefined,'same-second old PID terminal and no new logs must be unknown');
assert.equal(classify(proof(log.slice(0,-1),log)),undefined,'partial baseline line is not complete');
const mixed=[line('10.204','[main.cpp(main:21)]bm exec start'),
  line('11.524','[a92ab83a427e481 3a640de 0][status_receiver_impl.cpp(OnStatusNotify:56)]on OnStatusNotify is 5'),
  line('11.106','[a92ab83a427e481 29aeabd 0][status_receiver_impl.cpp(OnStatusNotify:56)]on OnStatusNotify is 10'),
  line('11.009','[a92ab83a427e481 fed518 0][status_receiver_impl.cpp(OnFinished:43)]on finished result is 0, [SUCCESS]'),
  line('11.009','[main.cpp(main:24)]bm exec end')].join('\n')+'\n';
assert.equal(classify(proof('',mixed,{startTicks:1070})).kind,'bms-success','format fixture with genuine baseline/reservation proof accepts hybrid fractions');
assert.equal(classify(proof(mixed,mixed,{startTicks:1070})),undefined,'same-second reuse remains unknown with valid Trace');
const future=proof('',log.replaceAll('10.','20.'));future.receipt.pidReservationComplete=false;
assert.equal(classify(future),undefined,'missing current logs + later reused PID unique terminal must fail without continuous reservation');
assert.equal(classify(proof('',log.replaceAll('10.','25.'))).kind,'bms-success','slow baseline does not invent a two-second exec deadline');
for(const trace of ['[a92ab83a427e481, fed518, 0] ','[a92ab83a427e481] '])assert.equal(classify(proof('',log.replace('[status_receiver_impl.cpp',trace+'[status_receiver_impl.cpp'))).kind,'bms-success');
assert.equal(classify(proof('',log.replace('success','成功😀'))).kind,'bms-success','raw UTF8 byte binding includes multibyte text');
assert.equal(P.evidenceAuthority(identity,P.record(identity,'claimed',true,2),'link'),undefined,'legacy v2 cannot acquire a fabricated empty baseline');
for(const change of [{bmEvidenceVersion:0},{bmEvidenceDirectory:'../escape'},{bmPid:0},{baselineBytes:65536},
  {bmGroup:89},{bmSession:89},{reservationPid:88},{reservationStartTicks:0},{reservationInode:'not-inode'}]) {
  const p=proof();Object.assign(p.claim,change);assert.equal(P.evidenceAuthority(identity,JSON.stringify(p.claim),'link'),undefined);
}
assert.equal(P.parse(identity,P.record(identity,'cli-returned',true,3)).safeToRelease,false);
assert.equal(P.parse(identity,P.record(identity,'pre-install-failed',false,4)).safeToRelease,false);
assert.equal(P.parse(identity,P.record(identity,'revoked',false,4)).safeToRelease,true);
assert.equal(P.parse({...identity,nonce:'f'.repeat(32)},P.record(identity,'revoked',false,4)).safeToRelease,false);
assert.equal(B.clockAligned(identity,JSON.stringify(proof().process),begin+'\n'+end+'\n'),true);
assert.equal(B.clockAligned(identity,JSON.stringify(proof().process),log+begin+'\n'),false);
console.log('PASS production BMS evidence: UTF8/SHA complete baseline prefix/suffix, empty vs missing, old/future PID reuse guards, hybrid monotonic fractions, strict HiTrace, legacy unknown');
