/**
 * 独立安装配方的真实宿主回归。执行产品ArkTS生成的shell、真实link/fsync和多进程竞争；
 * bm/aa/hilog仅替换平台副作用，不安装任何应用。终态解析运行实际产品函数，故障日志
 * 明确是夹具，不能把这份宿主证明外推为真实设备OnFinished已经通过。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { randomUUID, createHash } from 'node:crypto';
import { execFileSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import compiler from './lib/ets-compiler.mjs';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const output=process.argv[2]&&path.resolve(process.argv[2]);
if(!output||output===root||output.startsWith(root+path.sep))throw new Error('Provide external protocol evidence directory');
fs.mkdirSync(output,{recursive:true});
function load(file, modules={}) {
  const js=compiler.transpileModule(fs.readFileSync(path.join(root,file),'utf8'),{compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020}}).outputText;
  const exports={};vm.runInNewContext(js,{exports,require:name=>{if(!(name in modules))throw new Error('Missing '+name);return modules[name];},JSON,Number,String,RegExp,Object,Uint8Array});return exports;
}
const files=load('entry/src/main/ets/sideload/SideloadFiles.ets',{'@kit.CoreFileKit':{},'@kit.CryptoArchitectureKit':{},'@kit.ArkTS':{},commons:{}});
const protocol=load('entry/src/main/ets/sideload/SideloadInstallProtocol.ets',{'./SideloadFiles':files});
const evidence=load('entry/src/main/ets/sideload/BmTerminalEvidence.ets',{'./SideloadInstallProtocol':protocol,'@kit.ArkTS':{util:{TextDecoder:{create:(encoding,options)=>({decodeToString:bytes=>new TextDecoder(encoding,options).decode(bytes)})}}}});
const P=protocol.SideloadInstallProtocol,B=evidence.BmTerminalEvidence;
// 目标能力探针复用产品配方，只产生随机目录/普通文件，调用方仍须显式选择HDC设备。
if(process.argv[3]==='--emit-device-capability') {
  const remote='/data/local/tmp/amcl-install-cap-'+randomUUID().replaceAll('-','');
  const script=path.join(output,'device-capability.sh');
  fs.writeFileSync(script,P.capabilityScript(remote));
  fs.writeFileSync(path.join(output,'device-capability-manifest.json'),JSON.stringify({remote,script,
    sha256:createHash('sha256').update(fs.readFileSync(script)).digest('hex'),callsBm:false},null,2));
  console.log('Generated harmless product capability script');process.exit(0);
}
const bytes=Buffer.from('unprivileged host candidate');
const identity={installId:'a'.repeat(32),ownerAttemptId:'b'.repeat(32),nonce:'c'.repeat(32),bundleName:'com.amcl.launcher',product:'sideload',
  beforeVersionCode:1,beforeUid:20000001,versionCode:2,expectedPayloadIdentity:'d'.repeat(40),signedPath:'/sandbox/tasks/candidate.hap',
  signedSha256:createHash('sha256').update(bytes).digest('hex')};
if(process.argv[3]==='--emit-device-clock') {
  const ticks=Number(process.argv[4]);
  const remote='/data/local/tmp/amcl-install-clock-'+randomUUID().replaceAll('-','');
  const script=path.join(output,'clock-calibration.sh');
  fs.writeFileSync(script,P.clockCalibrationScript(identity,remote,ticks));
  fs.writeFileSync(path.join(output,'clock-calibration-manifest.json'),JSON.stringify({remote,script,ticks,identity,callsRealInstall:false},null,2));
  console.log('Generated bm-help-only clock calibration');process.exit(0);
}
if(process.argv[3]==='--verify-device-clock') {
  const cal=JSON.parse(fs.readFileSync(path.join(output,'clock-calibration-manifest.json'),'utf8'));
  const actual=fs.readFileSync(path.join(output,'clock-process.json'),'utf8');
  const log=fs.readFileSync(path.join(output,'clock-axis.log'),'utf8');
  assert.equal(B.clockAligned(cal.identity,actual,log),true);
  assert.equal(B.classify(cal.identity,actual,log),undefined,'bm help never proves installation terminality');
  fs.writeFileSync(path.join(output,'clock-calibration-result.json'),JSON.stringify({clockAligned:true,realInstall:false,bmsTerminal:false,process:JSON.parse(actual)},null,2));
  console.log('PASS actual target bm-help proc startTicks/CLK_TCK/hilog-monotonic comparable; no installation terminal claimed');process.exit(0);
}
if(process.argv[3]==='--emit-device-race') {
  const ticks=Number(process.argv[4]);const remote='/data/local/tmp/amcl-install-race-'+randomUUID().replaceAll('-','');
  const uploads=[];
  for(const name of ['concurrent','revoked','bad','loser']) {
    const dir=path.join(output,name);fs.mkdirSync(dir,{recursive:true});const target=remote+'/'+name;
    fs.writeFileSync(path.join(dir,'candidate.hap'),name==='bad'||name==='loser'?'bad':bytes);
    fs.writeFileSync(path.join(dir,'claim.record'),P.record(identity,'claimed',true,2,'flock-rename'));
    fs.writeFileSync(path.join(dir,'revoke.record'),P.record(identity,'revoked',false,4,'flock-rename'));
    let recipe=P.workerScript(identity,target,ticks,'flock-rename');
    const original='exec bm install -r -p candidate.hap -w 600 -u '+Math.floor(identity.beforeUid/200000);
    assert(recipe.includes(original));
    recipe=recipe.replace(original,'printf "AMCL_NATIVE_RACE_EXEC\\n" >> execution-count; exec bm install -h')
      .replace(/aa start -b com\.amcl\.launcher[^\n]+/,'printf OBSERVED > start.log');
    fs.writeFileSync(path.join(dir,'worker.sh'),recipe);
    if(name==='revoked')fs.writeFileSync(path.join(dir,'revoke.sh'),P.revokeScript(identity,target,'revoke.record','flock-rename'));
    if(name==='loser')fs.copyFileSync(path.join(dir,'claim.record'),path.join(dir,'decision'));
    for(const file of fs.readdirSync(dir))uploads.push({local:path.join(dir,file),remote:target+'/'+file});
  }
  const probe=`set -u\ncd '${remote}/concurrent'\nfor n in $(seq 1 20); do sh worker.sh > worker-$n.log 2>&1 & done\nwait\nprintf 'CONCURRENT='; grep -c AMCL_NATIVE_RACE_EXEC execution-count\ncd '${remote}/revoked'\nsh revoke.sh >/dev/null\nsh worker.sh >/dev/null 2>&1 || true\n[ ! -e execution-count ] && printf 'REVOKED=0\\n'\ncd '${remote}/bad'\nsh worker.sh >/dev/null 2>&1 || true\n[ ! -e execution-count ] && grep -q revoked decision && printf 'DIGEST=0_REVOKED\\n'\ncd '${remote}/loser'\nsh worker.sh >/dev/null 2>&1 || true\n[ ! -e result.json ] && printf 'LOSER_NO_RESULT\\n'\n`;
  fs.writeFileSync(path.join(output,'device-race.sh'),probe);uploads.push({local:path.join(output,'device-race.sh'),remote:remote+'/probe.sh'});
  fs.writeFileSync(path.join(output,'device-race-manifest.json'),JSON.stringify({remote,uploads,mode:'flock-rename',ticks,callsRealInstall:false,callsAppStart:false},null,2));
  console.log('Generated real device CAS race with bm help only and no aa start');process.exit(0);
}
// 所有终态回归执行真实产品parser；平台日志明确是夹具，不是旧手机baseline证据。
await import('./test-bm-terminal-evidence.mjs');

if(process.platform!=='win32')throw new Error('This workspace host runner expects WSL Ubuntu; use generated recipes directly on POSIX CI');
const linux=p=>execFileSync('wsl',['-d','Ubuntu','--','wslpath','-a',p.replaceAll('\\','/')],{encoding:'utf8'}).trim();
const base=path.join(output,'protocol-'+randomUUID());fs.mkdirSync(base);const linuxBase=linux(base);
const bin=path.join(base,'bin');fs.mkdirSync(bin);
fs.writeFileSync(path.join(bin,'fsync'),'#!/usr/bin/python3\nimport os,sys\nfor p in sys.argv[1:]:\n f=os.open(p,os.O_RDONLY);os.fsync(f);os.close(f)\n');
fs.writeFileSync(path.join(bin,'bm'),'#!/bin/sh\nprintf called\\n >> "$AMCL_TEST_COUNTER"\nsleep 0.15\n');
// 记录真实生成配方何时尝试重开应用；替身不启动任何系统或设备应用。
fs.writeFileSync(path.join(bin,'aa'),'#!/bin/sh\nprintf reopened\\n >> "$AMCL_TEST_COUNTER.aa"\nexit 0\n');
const hilogFixture=['#!/bin/sh',
 'case "$AMCL_TEST_CAPTURE_MODE" in',
 ' fail) exit 9;;',
 " oversize) python3 -c 'print(\"x\"*65536)';;",
 ' post-fail) [ ! -f "$AMCL_TEST_COUNTER" ] || exit 9;;',
 ' post-hold) if [ -f "$AMCL_TEST_COUNTER" ]; then : > "$AMCL_TEST_COUNTER.post-capturing"; while [ ! -f "$AMCL_TEST_COUNTER.release-capture" ]; do sleep 0.05; done; fi;;',
 ' lost-guard) if [ -f "$AMCL_TEST_COUNTER" ]; then for ready in bm-evidence-*/reservation.ready; do read pid rest < "$ready"; kill "$pid" 2>/dev/null || true; done; sleep 0.2; fi;;',
 'esac',
 'exit 0',''].join('\n');
fs.writeFileSync(path.join(bin,'hilog'),hilogFixture);
const q=value=>"'"+value.replaceAll("'","'\\''")+"'";
// 通过stdin传配方，不让WSL命令行再次解释含空格/括号的宿主PATH或脚本引号。
const run=body=>execFileSync('wsl',['-d','Ubuntu','--','sh'],{input:`PATH=${q(linuxBase+'/bin')}:$PATH; export PATH; ${body}\n`,encoding:'utf8'});
/** 保持同一次WSL前台会话直到竞争worker完成；不能用已退出会话的后台任务冒充在途。 */
function liveRun(body) {
 const child=spawn('wsl',['-d','Ubuntu','--','sh'],{windowsHide:true,stdio:['pipe','pipe','pipe']});
 let stdout='',stderr='';child.stdout.on('data',b=>{stdout+=b;});child.stderr.on('data',b=>{stderr+=b;});
 const done=new Promise((resolve,reject)=>{child.on('error',reject);child.on('close',code=>code===0?resolve():reject(Error('Live WSL exit '+code+' '+stderr+' '+stdout)));});
 child.stdin.end(`PATH=${q(linuxBase+'/bin')}:$PATH;export PATH;${body}\n`);
 return {child,done};
}
async function waitForFixture(file) {
 const deadline=Date.now()+10000;
 while(!fs.existsSync(file)){if(Date.now()>deadline)throw Error('Fixture wait timeout: '+file);await new Promise(r=>setTimeout(r,50));}
}
run(`chmod 700 ${q(linuxBase+'/bin')}/*`);
const ticks=Number(execFileSync('wsl',['-d','Ubuntu','--','getconf','CLK_TCK'],{encoding:'utf8'}).trim());
function fixture(name,bad=false,mode='link'){const dir=path.join(base,name);fs.mkdirSync(dir);const remote=linux(dir);
  fs.writeFileSync(path.join(dir,'candidate.hap'),bad?'bad':bytes);
  fs.writeFileSync(path.join(dir,'claim.record'),P.record(identity,'claimed',true,2,mode));
  fs.writeFileSync(path.join(dir,'revoke.record'),P.record(identity,'revoked',false,4,mode));
  fs.writeFileSync(path.join(dir,'worker.sh'),P.workerScript(identity,remote,ticks,mode));return{dir,remote,mode};}
for(const mode of ['link','flock-rename']) {
const concurrent=fixture('concurrent-'+mode,false,mode);
run(`AMCL_TEST_COUNTER=${q(concurrent.remote+'/count')};export AMCL_TEST_COUNTER; for n in $(seq 1 20); do sh ${q(concurrent.remote+'/worker.sh')} >/dev/null 2>&1 & done; wait`);
assert.equal(fs.readFileSync(path.join(concurrent.dir,'count'),'utf8').match(/called/g).length,1);
assert.equal(JSON.parse(fs.readFileSync(path.join(concurrent.dir,'result.json'),'utf8')).kind,'cli-returned');
const decision=fs.readFileSync(path.join(concurrent.dir,'decision'),'utf8'),winner=P.evidenceAuthority(identity,decision,mode);
assert.ok(winner);assert.equal(winner.baselineBytes,0);
assert.equal(winner.baselineSha256,createHash('sha256').update('').digest('hex'));
const winnerDir=path.join(concurrent.dir,winner.directory);
assert.equal(fs.statSync(path.join(winnerDir,'bm-before.log')).size,0);
const sealed=JSON.parse(fs.readFileSync(path.join(winnerDir,'bm-log-evidence.json'),'utf8'));
assert.equal(sealed.baselineComplete,true);assert.equal(sealed.postComplete,true);assert.equal(sealed.pidReservationComplete,true);
assert.equal(sealed.bmPid,winner.pid);assert.equal(sealed.reservationPid,winner.reservationPid);
// 完整封账后重复观察必须保留原字节，不能借另一观察者覆写已发布的post或receipt。
const observeMapped=(item,authority,body)=>P.observeEvidenceScript(identity,authority,body)
 .replace('cd '+q(P.remote(identity)),'cd '+q(item.remote));
const sealedBytes=fs.readFileSync(path.join(winnerDir,'bm-log-evidence.json'));
const postBytes=fs.readFileSync(path.join(winnerDir,'bm-terminal.log'));
run(`for n in $(seq 1 10); do sh -c ${q(observeMapped(concurrent,winner,decision))} >/dev/null 2>&1 & done; wait`);
assert.deepEqual(fs.readFileSync(path.join(winnerDir,'bm-log-evidence.json')),sealedBytes);
assert.deepEqual(fs.readFileSync(path.join(winnerDir,'bm-terminal.log')),postBytes);
// 在worker确实持锁且停在post采集时发出另一观察，忙者必须退出而不能改post/封账。
const racing=fixture('seal-race-'+mode,false,mode);
const live=liveRun(`AMCL_TEST_COUNTER=${q(racing.remote+'/count')}; AMCL_TEST_CAPTURE_MODE=post-hold;export AMCL_TEST_COUNTER AMCL_TEST_CAPTURE_MODE;sh ${q(racing.remote+'/worker.sh')} >${q(racing.remote+'/worker.log')} 2>&1 & wait`);
try {
 await waitForFixture(path.join(racing.dir,'count.post-capturing'));
 const raceDecision=fs.readFileSync(path.join(racing.dir,'decision'),'utf8'),raceAuthority=P.evidenceAuthority(identity,raceDecision,mode);
 assert.ok(raceAuthority);
 run(`code=0;sh -c ${q(observeMapped(racing,raceAuthority,raceDecision))} >/dev/null 2>&1 || code=$?;test "$code" -ne 0`);
 assert.equal(fs.existsSync(path.join(racing.dir,raceAuthority.directory,'bm-log-evidence.json')),false);
 fs.writeFileSync(path.join(racing.dir,'count.release-capture'),'release test capture');
 await live.done;
 assert.equal(JSON.parse(fs.readFileSync(path.join(racing.dir,raceAuthority.directory,'bm-log-evidence.json'),'utf8')).pidReservationComplete,true);
} finally {
 // 仅释放本宿主替身暂停点；不触及手机、原事务或产品decision。
 fs.writeFileSync(path.join(racing.dir,'count.release-capture'),'fixture finally');
 await live.done;
}
const revoked=fixture('revoked-'+mode,false,mode);run(P.revokeScript(identity,revoked.remote,'revoke.record',mode));
run(`AMCL_TEST_COUNTER=${q(revoked.remote+'/count')};export AMCL_TEST_COUNTER; sh ${q(revoked.remote+'/worker.sh')} >/dev/null 2>&1 || true`);
assert.equal(fs.existsSync(path.join(revoked.dir,'count')),false);
const bad=fixture('bad-'+mode,true,mode);run(`AMCL_TEST_COUNTER=${q(bad.remote+'/count')};export AMCL_TEST_COUNTER; sh ${q(bad.remote+'/worker.sh')} >/dev/null 2>&1 || true`);
assert.equal(fs.existsSync(path.join(bad.dir,'count')),false);assert.equal(JSON.parse(fs.readFileSync(path.join(bad.dir,'decision'),'utf8')).kind,'revoked');
const loser=fixture('loser-'+mode,true,mode);fs.copyFileSync(path.join(loser.dir,'claim.record'),path.join(loser.dir,'decision'));
run(`AMCL_TEST_COUNTER=${q(loser.remote+'/count')};export AMCL_TEST_COUNTER; sh ${q(loser.remote+'/worker.sh')} >/dev/null 2>&1 || true`);
assert.equal(fs.existsSync(path.join(loser.dir,'result.json')),false,'preflight loser cannot seal winner failure');
// 真实shell证明失败/超界baseline在CLAIM前撤销，post失败不伪终态，丢失PID预留也不能封账。
for(const captureMode of ['fail','oversize','post-fail','lost-guard']) {
 const damaged=fixture('capture-'+captureMode+'-'+mode,false,mode);
 const body='AMCL_TEST_CAPTURE_MODE='+q(captureMode)+';AMCL_TEST_COUNTER='+q(damaged.remote+'/count')+
   ';export AMCL_TEST_CAPTURE_MODE AMCL_TEST_COUNTER;sh '+q(damaged.remote+'/worker.sh')+' >/dev/null 2>&1 || true';
 run(body);
 const decision=fs.readFileSync(path.join(damaged.dir,'decision'),'utf8'),row=JSON.parse(decision);
 if(captureMode==='fail'||captureMode==='oversize') {
  assert.equal(fs.existsSync(path.join(damaged.dir,'count')),false);assert.equal(row.kind,'revoked');
  assert.equal(JSON.parse(fs.readFileSync(path.join(damaged.dir,'result.json'),'utf8')).kind,'pre-install-failed');
 } else {
  const authority=P.evidenceAuthority(identity,decision,mode);assert.ok(authority);
  const directory=path.join(damaged.dir,authority.directory);
  assert.equal(fs.existsSync(path.join(directory,'bm-log-evidence.json')),false,'post failure/lost guard must remain unsealed');
  assert.equal(JSON.parse(fs.readFileSync(path.join(damaged.dir,'result.json'),'utf8')).kind,'cli-returned');
  assert.equal(fs.readFileSync(path.join(damaged.dir,'count.aa'),'utf8').includes('reopened'),true,'unknown post still attempts original app reopen without granting terminality');
  if(captureMode==='post-fail') {
   // 只映射平台文件根；正式观察脚本所有保护、采集和封账步骤原样执行。
   const observed=P.observeEvidenceScript(identity,authority,decision),fixedRoot=q(P.remote(identity));
   assert(observed.includes('cd '+fixedRoot));
   const mapped=observed.replace('cd '+fixedRoot,'cd '+q(damaged.remote));
   run('AMCL_TEST_CAPTURE_MODE=normal;export AMCL_TEST_CAPTURE_MODE;sh -c '+q(mapped));
   assert.equal(JSON.parse(fs.readFileSync(path.join(directory,'bm-log-evidence.json'),'utf8')).pidReservationComplete,true);
  }
  // 这里只清本宿主虚构平台fixture的guard，不触及设备或产品的unknown执行权。
  fs.writeFileSync(path.join(directory,'release-reservation'),'fixture cleanup');
 }
}
console.log(`PASS real POSIX ${mode}: 20 duplicate workers invoke once, revoke defeats delayed claim, digest failure seals revocation, loser cannot seal winner`);
}
fs.writeFileSync(path.join(output,'protocol-host-result.json'),JSON.stringify({fixture:base,ticks,backends:['link','flock-rename'],concurrentWorkers:20,bmCallsPerBackend:1,realSystemInstall:false},null,2));
