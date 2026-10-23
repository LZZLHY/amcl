/** 真实成功报告的薄资格负例：只污染内存，不重跑GL，不把fixture当GPU证据。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { readReplayEvidence, verifyReplayEvidence, verifyReplayBundle } from './check-mobilegl-replay-evidence.mjs';
const fixture=JSON.parse(fs.readFileSync(new URL('../tests/mobilegl-replay-host/replay-positive.json',import.meta.url)));
const clone=()=>structuredClone(fixture);
test('actual captured report satisfies the thin contract',()=>assert.equal(verifyReplayEvidence(fixture.evidence,fixture.expected).qualified,true));
const negative=(name,change,reason)=>test(name,()=>{const f=clone();change(f);const result=verifyReplayEvidence(f.evidence,f.expected);assert.equal(result.qualified,false);assert.ok(result.issues.some(x=>x.includes(reason)),result.issues.join('; '));});
negative('missing actual result',f=>f.evidence.result=null,'schema missing');
negative('bad expected case',f=>f.expected.case=null,'manifest missing');
negative('truncated result',f=>f.evidence.resultComplete=false,'truncated');
negative('old independently observed PID',f=>f.expected.pid++,'identity mismatch');
negative('old run ID',f=>f.evidence.invocation.runId='old','identity mismatch');
negative('strong kill cannot qualify',f=>f.evidence.invocation.forcedKill=true,'normally completed');
negative('no golden pass cannot qualify',f=>f.evidence.result.matchedGoldenPath='','golden');
negative('NaN score cannot qualify',f=>f.evidence.result.ssim=NaN,'comparison failed');
negative('boolean score cannot qualify',f=>f.evidence.result.ssim=true,'comparison failed');
negative('missing provider end',f=>f.evidence.providerEvents.pop(),'completion records');
negative('duplicate provider begin',f=>f.evidence.providerEvents.splice(1,0,f.evidence.providerEvents[0]),'completion records');
negative('foreign functions',f=>f.evidence.providerEvents[1].verdict='FOREIGN','function owner');
negative('fallback address is not provider evidence',f=>f.evidence.providerEvents.at(-1).fallback=1,'fallback');
negative('missing required bootstrap',f=>f.evidence.providerEvents=f.evidence.providerEvents.filter(x=>x.symbol!=='eglGetDisplay'),'bootstrap/query');
negative('wrong actual source bytes',f=>f.evidence.sourceFileSha256='0'.repeat(64),'delta identity');
negative('undeclared host delta',f=>f.expected.hostDeltaSha256=null,'undeclared');
negative('wrong loaded library bytes',f=>f.evidence.librarySha256='0'.repeat(64),'artifact bytes');
negative('wrong fixed targetcall',f=>f.evidence.result.targetCall=1,'case field');
negative('missing actual image mapping',f=>f.evidence.loadedMaps='','not mapped');
negative('untrusted expected source shape',f=>f.expected.sourceCommit=null,'source commit invalid');
negative('empty runtime provider',f=>f.expected.provider='','backend/provider');
negative('zero resolver address cannot qualify',f=>f.evidence.providerEvents[1].address='0x0','function owner');
// 批次薄门只使用真实报告fixture的内存副本；它不冒充第二后端的实际重放。
const bundle=()=>{const f=clone();return [{row:{backend:'DirectGLES',control:'none',processExitCode:0,directory:'/actual/DirectGLES'},...f}];};
test('one independently requested captured run closes',()=>assert.equal(verifyReplayBundle(bundle(),['DirectGLES/none']).accepted,true));
test('required Vulkan run cannot be omitted',()=>assert.equal(verifyReplayBundle(bundle(),['DirectGLES/none','DirectVulkan/none']).accepted,false));
test('duplicate actual case cannot fill required count',()=>{const rows=bundle();rows.push(structuredClone(rows[0]));assert.equal(verifyReplayBundle(rows,['DirectGLES/none','DirectVulkan/none']).accepted,false);});
test('borrowed GLES report cannot satisfy Vulkan row',()=>{const rows=bundle();rows[0].row.backend='DirectVulkan';const result=verifyReplayBundle(rows,['DirectVulkan/none']);assert.equal(result.accepted,false);assert.ok(result.runs[0].bundleIssues.some(x=>x.includes('does not match')));});
test('duplicate directory cannot fill separate control',()=>{const rows=bundle();rows.push({...structuredClone(rows[0]),row:{...rows[0].row,control:'no-golden'}});assert.equal(verifyReplayBundle(rows,['DirectGLES/none','DirectGLES/no-golden']).accepted,false);});
test('row process code must equal Popen observation',()=>{const rows=bundle();rows[0].row.processExitCode=7;assert.equal(verifyReplayBundle(rows,['DirectGLES/none']).accepted,false);});
test('negative control cannot borrow a passing report',()=>{const rows=bundle();rows[0].row.control='wrong-provider';assert.equal(verifyReplayBundle(rows,['DirectGLES/wrong-provider']).accepted,false);});
test('bad bundle schema fails closed',()=>{assert.equal(verifyReplayBundle([null],['DirectGLES/none']).accepted,false);assert.equal(verifyReplayBundle(bundle(),null).accepted,false);});
negative('replaced PNG cannot borrow captured SSIM',f=>f.evidence.actualPngSha256='0'.repeat(64),'pixels missing');

// 原文件读取接缝在仓外临时树验证；1x1容器只供CRC/schema测试，不用它声称任何绘制正确性。
test('raw reports are re-read even when a passing snapshot remains',()=>{
  const temporaryRoot=path.resolve(process.env.AMCL_RUN_DIR||os.tmpdir());
  const directory=fs.mkdtempSync(path.join(temporaryRoot,'mobilegl-raw-'));
  const f=clone(),write=(name,value)=>{const target=path.join(directory,name);fs.mkdirSync(path.dirname(target),{recursive:true});fs.writeFileSync(target,value);};
  const bytes=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=','base64');
  const digest=value=>createHash('sha256').update(value).digest('hex');
  f.expected.case.width=1;f.expected.case.height=1;f.expected.actualPngSha256=digest(bytes);
  write('invocation.json',JSON.stringify(f.evidence.invocation));write('output/result.json',JSON.stringify(f.evidence.result)+'\n');
  const provider=f.evidence.providerEvents.map(x=>JSON.stringify(x)).join('\n')+'\n';write('provider.jsonl',provider);
  write('output/actual.png',bytes);write('output/retrace.log',f.evidence.glInfo);write('loaded-maps.txt',f.evidence.loadedMaps);
  const hostFiles={};for(const key of ['provider','executable','trace','golden','sourceFile']){hostFiles[key]=path.join(directory,key);fs.writeFileSync(hostFiles[key],key);}
  write('evidence.json',JSON.stringify(f.evidence));
  try{
    const actual=readReplayEvidence(directory,f.expected,hostFiles);assert.equal(actual.actualPngValid,true);assert.equal(actual.actualPngSha256,digest(bytes));
    write('provider.jsonl',provider.trimEnd());assert.equal(readReplayEvidence(directory,f.expected,hostFiles).providerComplete,false);
    write('provider.jsonl',provider);write('output/result.json',JSON.stringify(f.evidence.result));assert.equal(readReplayEvidence(directory,f.expected,hostFiles).resultComplete,false);
    write('output/actual.png',bytes.subarray(0,bytes.length-1));assert.equal(readReplayEvidence(directory,f.expected,hostFiles).actualPngValid,false);
    write('output/actual.png',bytes);const corrupted=Buffer.from(bytes);corrupted[corrupted.length-1]^=1;write('output/actual.png',corrupted);assert.equal(readReplayEvidence(directory,f.expected,hostFiles).actualPngValid,false);
    assert.equal(JSON.parse(fs.readFileSync(path.join(directory,'evidence.json'))).actualPngValid,true);
  }finally{
    // 测试只清理自己刚创建的唯一目录，绝不枚举或清理其他任务。
    assert.equal(path.dirname(path.resolve(directory)),temporaryRoot);assert.match(path.basename(directory),/^mobilegl-raw-/);
    fs.rmSync(directory,{recursive:true,force:true});
  }
});
