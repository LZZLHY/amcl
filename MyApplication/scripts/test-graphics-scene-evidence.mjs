/** 真实共享JSONL配受控外层身份夹具；此测试只证明薄门，不能授予设备/driver资格。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createHash } from 'node:crypto';
import { auditGraphicsSceneEvidence } from './check-graphics-scene-evidence.mjs';
import { loadMobileGlProgramContract } from './lib/mobilegl-program-evidence.mjs';
import { loadMgContextIdentityContract } from './lib/mg-context-identity-evidence.mjs';
const sha=value=>createHash('sha256').update(value).digest('hex');
const library=Buffer.alloc(64);Buffer.from('7f454c460201','hex').copy(library);library.writeUInt16LE(183,18);

// 最小stored ZIP用于唯一entry/身份读回测试；不造目标HAP或虚构签名资格。
function zip(entries) {
  const locals=[],central=[];let offset=0;
  for(const [nameText,bytes]of entries) {
    const name=Buffer.from(nameText),local=Buffer.alloc(30),row=Buffer.alloc(46);
    local.writeUInt32LE(0x04034b50);local.writeUInt32LE(bytes.length,18);local.writeUInt32LE(bytes.length,22);local.writeUInt16LE(name.length,26);
    row.writeUInt32LE(0x02014b50);row.writeUInt32LE(bytes.length,20);row.writeUInt32LE(bytes.length,24);row.writeUInt16LE(name.length,28);row.writeUInt32LE(offset,42);
    const block=Buffer.concat([local,name,bytes]);locals.push(block);central.push(row,name);offset+=block.length;
  }
  const directory=Buffer.concat(central),end=Buffer.alloc(22);end.writeUInt32LE(0x06054b50);end.writeUInt16LE(entries.length,8);end.writeUInt16LE(entries.length,10);
  end.writeUInt32LE(directory.length,12);end.writeUInt32LE(offset,16);return Buffer.concat([...locals,directory,end]);
}
const sourceHead='a'.repeat(40),driver={deviceName:'controlled-GPU',vendorId:123,shaderFloat64:false};
let positive=0,negative=0;
for(const probe of ['mobilegl-program','mg-context-low-first','mg-context-high-first']) {
  const mobileGlProgram=probe==='mobilegl-program',high=probe==='mg-context-high-first';
  const fixture=new URL(mobileGlProgram?'./fixtures/mobilegl-program-evidence/gles.jsonl':
    './fixtures/mg-context-identity-evidence/'+(high?'high':'low')+'.jsonl',import.meta.url);
  const rows=fs.readFileSync(fixture,'utf8');
  const contract=mobileGlProgram?loadMobileGlProgramContract():loadMgContextIdentityContract();
  // identity fixture来自真实host原件，其PID由配置原行读取；不改场景原文。
  const config=mobileGlProgram?null:rows.split('\n').filter(Boolean).map(JSON.parse).find(row=>row.kind==='context-identity-config');
  const pid=mobileGlProgram?123:config.processPid,runId=pid+'-456';
  const lib=mobileGlProgram?'libmobilegl.so':'libamcl_gl_host.so';
  // identity内层原host映像原样保留；语法外层采用同一路径只测一致性，仍非OHOS装载证据。
  const image=mobileGlProgram?'/data/storage/el1/bundle/libs/arm64/'+lib:
    rows.split('\n').filter(Boolean).map(JSON.parse).find(row=>row.case==='identity-provider-owned').image;
  const hap=zip([['libs/arm64-v8a/'+lib,library],['resources/rawfile/product-profile.json',Buffer.from(JSON.stringify({sourceRevision:sourceHead}))]]);
  const expected={pid,runId,probe,sourceHead,hapSha256:sha(hap),librarySha256:sha(library),driver};
  const funcs=mobileGlProgram?['glGetString',...contract.functions]:contract.functions;
  const lines=[`GRAPHICS_SCENE_RUN probe=${probe} runId=${runId} processPid=${pid} startUnixNs=789 startSteadyNs=456`,
    `IMAGE_COPY library=${lib} bytes=64 path=/data/storage/el2/base/haps/entry/files/graphics-semantic-probes/${runId}/loaded-${lib}`,
    `PROVIDER image=${image} implementation=controlled-parser-fixture factory=${mobileGlProgram?'mobilegl-desktop-gl':'mobileglues-desktop-gl'}`,
    ...['eglCreateContext','eglMakeCurrent','eglQueryContext','eglGetCurrentContext'].map(name=>`EGL_FUNCTION name=${name} owned=1 image=${image}`),
    ...funcs.map((name,index)=>`FUNCTION name=${name} address=0x${(4096+index).toString(16)} owned=1 image=${image}`),
    ...(mobileGlProgram?['BACKEND_PUBLICATION value=DirectVulkan source=production-cold-publisher',`DRIVER_FACTS ${JSON.stringify({...driver,baseFeaturesQueried:true})}`,
      'CALLER_EXPECTATION Float64=Unsupported source=actual-system-Vulkan-baseFeatures fullCoreQualified=0',
      'ACTUAL_GL renderer="Magma controlled-GPU" version="4.3 fixture" requested=4.3 actualMajor=4 actualMinor=3']:[]),rows.trimEnd()];
  const counts=mobileGlProgram?contract.branches.Unsupported.counts:contract.counts;
  lines.push(`${contract.hostMarker} sceneVersion=1 completed=1 checks=${counts.checks} queryChecks=${counts.queryChecks} pixelChecks=${counts.pixelChecks} failures=0 evidenceComplete=1 `+
    (mobileGlProgram?'resolved=59 ownerRetired=1 fullCoreQualified=0 coreFP64Qualified=0 retiredError=""':`highFirst=${Number(high)} coreQualified=0`),
    `RESOLUTION resolved=${funcs.length} rejected=0`,`GRAPHICS_SCENE_END probe=${probe} runId=${runId} processPid=${pid} restartRequired=1 verdict=PASS_SCOPE`);
  const text=lines.join('\n')+'\n',report=Buffer.from(text);
  const marker=bytes=>Buffer.from(`GRAPHICS_SCENE_RETURN probe=${probe} runId=${runId} processPid=${pid} reportBytes=${bytes.length} returned=1 verdict=PASS_SCOPE\n`);
  const check=(bytes=report,returned=marker(bytes),copy=library,wanted=expected,packageBytes=hap)=>auditGraphicsSceneEvidence(bytes,returned,copy,packageBytes,wanted);
  const good=check();assert.equal(good.ok,true,probe+': '+good.issues.join('\n'));++positive;
  // 变更报告时生成匹配长度marker，保证每个关键反例不是仅由长度不同挡住。
  const reject=transform=>{const changed=Buffer.from(transform(text));assert.equal(check(changed).ok,false,probe);++negative;};
  reject(value=>value.slice(0,-1));reject(value=>value.replace(/GRAPHICS_SCENE_END[^\n]+\n/,''));
  reject(value=>value.replace('verdict=PASS_SCOPE','verdict=NOT_RUN'));
  reject(value=>value.replace('restartRequired=1','restartRequired=0'));
  reject(value=>value.replace('bytes=64','bytes=63'));
  reject(value=>value.replace('/'+runId+'/loaded-','/stale-run/loaded-'));
  reject(value=>value.replace('factory='+ (mobileGlProgram?'mobilegl-desktop-gl':'mobileglues-desktop-gl'),'factory=gles'));
  reject(value=>value.replace(/EGL_FUNCTION[^\n]+\n/,''));reject(value=>value.replace(/FUNCTION[^\n]+\n/,''));
  reject(value=>value.replace('owned=1','owned=0'));
  reject(value=>value.replace(/(FUNCTION name=[^ ]+ address=)0x[0-9a-f]+/,'$10x0'));
  reject(value=>value.replace('RESOLUTION resolved=','RESOLUTION resolved=999'));
  reject(value=>value.replace('evidenceComplete=1','evidenceComplete=0'));
  reject(value=>value.replace('GRAPHICS_SCENE_END ','UNEXPECTED_PASS\nGRAPHICS_SCENE_END '));
  reject(value=>value.replace('"pass":true','"pass":false'));
  for(const [returned,copy,wanted]of [[Buffer.from('host force-stop'),library,expected],
    [Buffer.concat([marker(report),marker(report)]),library,expected],
    [marker(report),Buffer.alloc(64),expected],[marker(report),library,{...expected,pid:pid+1}],
    [marker(report),library,{...expected,sourceHead:'b'.repeat(40)}],[marker(report),library,{...expected,hapSha256:'b'.repeat(64)}],
    [marker(report),library,{...expected,librarySha256:'b'.repeat(64)}]]) {
    assert.equal(check(report,returned,copy,wanted).ok,false);++negative;
  }
  if(mobileGlProgram) {
    reject(value=>value.replace(/BACKEND_PUBLICATION[^\n]+\n/,''));
    reject(value=>value.replace('BACKEND_PUBLICATION value=DirectVulkan','BACKEND_PUBLICATION value=DirectGLES'));
    reject(value=>value.replace('"shaderFloat64":false','"shaderFloat64":true'));
    reject(value=>value.replace('renderer="Magma controlled-GPU"','renderer="llvmpipe"'));
    assert.equal(check(report,marker(report),library,{...expected,driver:{...driver,shaderFloat64:true}}).ok,false);++negative;
  }
}
console.log(`Graphics scene outer evidence PASS positive=${positive} negative=${negative} scope=parser-fixtures-only`);
