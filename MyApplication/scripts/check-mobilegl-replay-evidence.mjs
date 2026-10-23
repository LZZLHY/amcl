/**
 * MobileGL既有replay的离线证据门。只核对实际报告、函数归属和调用方独立输入；
 * GL及SSIM仍由fork原CLI实现，结果不参与产品registry或运行时准入。
 */
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const hash = value => typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);
const object = value => value && typeof value === 'object' && !Array.isArray(value);
/** 只验证PNG容器完整性/尺寸/CRC，像素比较仍由原CLI计算；截断图不能借旧SSIM通过。 */
function completePng(bytes, expected) {
  if(bytes.length<33||!bytes.subarray(0,8).equals(Buffer.from('89504e470d0a1a0a','hex')))return false;
  let offset=8,headers=0,data=0;
  while(offset+12<=bytes.length){
    const size=bytes.readUInt32BE(offset),end=offset+12+size;
    if(end>bytes.length)return false;
    const kind=bytes.toString('ascii',offset+4,offset+8);let crc=0xffffffff;
    for(const value of bytes.subarray(offset+4,end-4)){crc^=value;for(let bit=0;bit<8;bit++)crc=(crc>>>1)^((crc&1)?0xedb88320:0);}
    if(((crc^0xffffffff)>>>0)!==bytes.readUInt32BE(end-4))return false;
    if(kind==='IHDR'){headers++;if(offset!==8||size!==13||bytes.readUInt32BE(offset+8)!==expected.case?.width||bytes.readUInt32BE(offset+12)!==expected.case?.height)return false;}
    if(kind==='IDAT')data++;
    if(kind==='IEND')return size===0&&headers===1&&data>0&&end===bytes.length;
    offset=end;
  }
  return false;
}

/** 返回完整裁决，坏schema也保留为FAIL；expected只来自独立宿主事务，不从报告倒填。 */
export function verifyReplayEvidence(evidence, expected) {
  const issues = [];
  const require = (condition, message) => { if (!condition) issues.push(message); };
  if (!object(expected) || !object(evidence)) return {qualified:false,verdict:'FAIL',issues:['expected/evidence schema missing']};
  require(typeof expected.sourceCommit==='string'&&/^[0-9a-f]{40}$/.test(expected.sourceCommit), 'expected source commit invalid');
  require(hash(expected.librarySha256) && hash(expected.executableSha256) && hash(expected.traceSha256) && hash(expected.goldenSha256) && hash(expected.actualPngSha256), 'expected artifact identity invalid');
  require(Number.isSafeInteger(expected.pid) && expected.pid > 0 && typeof expected.runId === 'string' && expected.runId.length > 0, 'independent PID/run identity missing');
  require(['DirectGLES','DirectVulkan'].includes(expected.backend) && typeof expected.provider === 'string' && expected.provider.length > 0, 'expected backend/provider invalid');
  require(object(expected.case) && expected.case.name === 'OpenRA', 'fixed case manifest missing');
  for(const key of ['executable','goldenPath','tracePath','backendDisplayName','rendererName'])require(typeof expected[key]==='string'&&expected[key].length>0,'expected '+key+' missing');
  if(object(expected.case)){
    for(const key of ['target_call','width','height','crop_width','crop_height'])require(Number.isSafeInteger(expected.case[key])&&expected.case[key]>0,'expected case '+key+' invalid');
    for(const key of ['crop_x','crop_y'])require(Number.isSafeInteger(expected.case[key])&&expected.case[key]>=0,'expected case '+key+' invalid');
    require(typeof expected.case.ssim_threshold==='number'&&Number.isFinite(expected.case.ssim_threshold)&&expected.case.ssim_threshold>=0&&expected.case.ssim_threshold<=1,'expected threshold invalid');
  }
  require(expected.hostDeltaSha256===null||(hash(expected.hostDeltaSha256)&&hash(expected.sourceFileSha256)),'expected host delta invalid');
  if (issues.length) return {qualified:false,verdict:'FAIL',issues};
  const invocation=evidence.invocation,result=evidence.result,events=evidence.providerEvents;
  if (!object(invocation) || !object(result) || !Array.isArray(events)) return {qualified:false,verdict:'FAIL',issues:['actual invocation/result/provider schema missing']};
  for (const [key,wanted] of Object.entries({sourceCommit:expected.sourceCommit,pid:expected.pid,runId:expected.runId,backend:expected.backend,
    providerCanonical:expected.provider,providerSha256:expected.librarySha256,executableSha256:expected.executableSha256,traceSha256:expected.traceSha256,goldenSha256:expected.goldenSha256}))
    require(invocation[key] === wanted, 'actual invocation identity mismatch: '+key);
  require(invocation.exitCode === 0 && invocation.forcedKill === false, 'process not normally completed');
  require(evidence.resultComplete === true && evidence.providerComplete === true, 'truncated actual result/provider evidence');
  require(evidence.librarySha256 === expected.librarySha256 && evidence.executableSha256 === expected.executableSha256 && evidence.traceSha256 === expected.traceSha256 && evidence.goldenSha256 === expected.goldenSha256, 'actual artifact bytes changed');
  const begins=events.filter(x=>object(x)&&x.kind==='begin'),ends=events.filter(x=>object(x)&&x.kind==='end'),records=events.filter(x=>object(x)&&x.kind==='resolve');
  require(begins.length===1 && ends.length===1 && events[0]?.kind==='begin' && events.at(-1)?.kind==='end' && events.length===records.length+2, 'missing/duplicate/unknown provider completion records');
  require(events.every(x=>object(x)&&x.pid===expected.pid&&x.runId===expected.runId),'provider process/run identity mismatch');
  if (begins.length===1 && ends.length===1) {
    const begin=begins[0],end=ends[0];
    require(begin.provider===expected.provider,'wrong independently selected provider');
    require(end.completed===true && end.resolutions===records.length && records.length>0,'empty/incomplete provider records');
    require(['foreign','fallback','missing','writeErrors'].every(k=>end[k]===0),'foreign/fallback/missing/provider IO failure');
    const nonzero=value=>typeof value==='string'&&/^0x[0-9a-f]+$/.test(value)&&BigInt(value)>0n;
    require(records.every(x=>x.verdict==='OWN'&&x.library===expected.provider&&/^(gl|egl)[A-Za-z0-9_]+$/.test(x.symbol??'')&&nonzero(x.address)&&nonzero(x.imageBase)),'actual function owner is foreign or missing');
    require(new Set(records.map(x=>x.imageBase)).size===1,'mixed provider image bases');
    const names=new Set(records.map(x=>x.symbol));
    require(['eglGetDisplay','eglCreateContext','eglCreatePbufferSurface','eglMakeCurrent','glGetString'].every(n=>names.has(n)), 'required provider bootstrap/query missing');
  }
  require(result.goldenPath===expected.goldenPath && result.matchedGoldenPath===expected.goldenPath && evidence.actualPngValid===true && evidence.actualPngSha256===expected.actualPngSha256,'fixed golden or actual pixels missing');
  require(result.tracePath===expected.tracePath && result.backend===expected.backend && Array.isArray(result.alternateGoldenPaths)&&result.alternateGoldenPaths.length===0,'actual trace/backend/oracle differs');
  require(result.passed===true&&result.statusCode===0&&typeof result.ssim==='number'&&Number.isFinite(result.ssim)&&result.ssim>=expected.case.ssim_threshold,'actual fixed-golden comparison failed');
  for (const [field,key] of [['targetCall','target_call'],['width','width'],['height','height'],['cropX','crop_x'],['cropY','crop_y'],['cropWidth','crop_width'],['cropHeight','crop_height'],['ssimThreshold','ssim_threshold']])
    require(result[field]===expected.case[key],'fixed case field differs: '+field);
  require(typeof evidence.glInfo==='string'&&evidence.glInfo.includes('MobileGL')&&evidence.glInfo.includes('GIT@'+expected.sourceCommit.slice(0,7))&&evidence.glInfo.includes(expected.backendDisplayName)&&evidence.glInfo.includes(expected.rendererName),'actual backend/renderer/source not observed');
  require(typeof evidence.loadedMaps==='string'&&evidence.loadedMaps.includes(expected.provider),'selected provider is not mapped');
  if(expected.backend==='DirectVulkan')require(hash(expected.icdSha256)&&evidence.icdSha256===expected.icdSha256&&typeof expected.icdPath==='string'&&evidence.loadedMaps.includes(expected.icdPath),'actual selected software ICD missing or changed');
  if(expected.hostDeltaSha256===null)require(!invocation.candidate,'undeclared host source delta');
  if(expected.hostDeltaSha256 !== null)require(hash(expected.hostDeltaSha256)&&invocation.candidate?.patchSha256===expected.hostDeltaSha256&&evidence.sourceFileSha256===expected.sourceFileSha256,'explicit Linux host delta identity missing or changed');
  return {qualified:issues.length===0,verdict:issues.length?'FAIL':'PASS',issues,scope:'OpenRA fixed golden host regression only; no normative GL/CTS/OHOS/device/runtime admission'};
}

/** 批次请求由宿主参数提供；每条实际证据必须与该行backend/control及独占目录互绑。 */
export function verifyReplayBundle(rows, required) {
  const issues=[];
  if(!Array.isArray(required)||required.length===0||new Set(required).size!==required.length||required.some(x=>typeof x!=='string'))return {accepted:false,issues:['Independent required runs invalid'],runs:[]};
  if(!Array.isArray(rows)||rows.some(x=>!object(x)||!object(x.row)))return {accepted:false,issues:['Actual replay bundle schema missing'],runs:[]};
  const ids=rows.map(x=>x.row.backend+'/'+x.row.control),directories=rows.map(x=>x.row.directory);
  if(ids.length!==required.length||new Set(ids).size!==ids.length||required.some(x=>!ids.includes(x)))issues.push('Actual bundle missing/duplicate/unexpected required case');
  if(directories.some(x=>typeof x!=='string'||x.length===0)||new Set(directories).size!==directories.length)issues.push('Actual bundle missing/duplicate evidence directory');
  const checked=rows.map(({row,evidence,expected})=>{
    const result=verifyReplayEvidence(evidence,expected),normal=row.control==='none';
    const local=[];
    // 即使expected文件本身看似完整，也不能借另一后端或另一进程的成功报告填补必需项。
    if(!object(expected)||expected.backend!==row.backend||expected.case?.name!=='OpenRA'||row.processExitCode!==evidence?.invocation?.exitCode)local.push('Bundle row does not match actual expected/invocation');
    if(!['none','no-golden','wrong-golden','wrong-provider'].includes(row.control))local.push('Unknown requested control');
    const wanted=row.control==='wrong-golden'?'comparison failed':row.control==='no-golden'?'golden':'provider';
    const accepted=local.length===0&&(normal?result.qualified:!result.qualified&&result.issues.some(x=>x.includes(wanted))&&
      (row.control==='wrong-golden'?row.processExitCode!==0:row.processExitCode===0));
    return {...row,accepted,qualification:result,bundleIssues:local};
  });
  return {accepted:issues.length===0&&checked.every(x=>x.accepted),issues,runs:checked};
}

/** 文件CLI将实取字节与调用方expected结合；不容许报告自己的摘要验证自己。 */
export function readReplayEvidence(directory, expected, hostFiles={}) {
  const read=name=>fs.readFileSync(path.join(directory,name));
  const resultBytes=read('output/result.json'),providerBytes=read('provider.jsonl');
  const png=read('output/actual.png');
  return {invocation:JSON.parse(read('invocation.json')),result:JSON.parse(resultBytes),
    providerEvents:providerBytes.toString('utf8').trim().split('\n').map(line=>JSON.parse(line)),
    resultComplete:resultBytes.at(-1)===10,providerComplete:providerBytes.at(-1)===10,
    librarySha256:sha(fs.readFileSync(hostFiles.provider??expected.provider)),executableSha256:sha(fs.readFileSync(hostFiles.executable??expected.executable)),
    traceSha256:sha(fs.readFileSync(hostFiles.trace??expected.tracePath)),goldenSha256:sha(fs.readFileSync(hostFiles.golden??expected.goldenPath)),
    actualPngValid:completePng(png,expected),actualPngSha256:sha(png),
    glInfo:read('output/retrace.log').toString('utf8'),loadedMaps:read('loaded-maps.txt').toString('utf8'),
    sourceFileSha256:expected.sourceFile?sha(fs.readFileSync(hostFiles.sourceFile??expected.sourceFile)):null,
    icdSha256:expected.icdPath?sha(fs.readFileSync(hostFiles.icd??expected.icdPath)):null};
}
function cli(){
  try {
    const flag=name=>{const i=process.argv.indexOf(name);if(i<0||!process.argv[i+1])throw Error(name+' required');return process.argv[i+1]};
    if(process.argv.includes('--bundle')){
      const root=flag('--bundle'),summaryPath=path.join(root,'results.json');
      const summary=JSON.parse(fs.readFileSync(summaryPath,'utf8'));
      const required=JSON.parse(flag('--required-runs'));
      // 宿主独立选择的原生制品/源码输入保留在容器之外；不能只重新相信capture snapshot摘要。
      const artifacts=flag('--host-artifacts'),source=flag('--host-source'),sourceCommit=flag('--expected-source');
      if(!/^[0-9a-f]{40}$/.test(sourceCommit))throw Error('Independent source commit invalid');
      const proofBytes=fs.readFileSync(path.join(artifacts,'build-source.json'));
      if(sha(proofBytes)!==flag('--host-proof-sha'))throw Error('Independent host artifact proof differs');
      const proof=JSON.parse(proofBytes);
      if(proof.sourceCommit!==sourceCommit||proof.hostDeltaSha256!==sha(fs.readFileSync(new URL('../tests/mobilegl-replay-host/host-glx-display.patch',import.meta.url))))throw Error('Independent host source/delta differs');
      if(!Array.isArray(summary.runs))throw Error('Actual replay bundle has no required runs');
      const captured=[];
      for(const row of summary.runs){
        // 容器绝对路径仅为声明；宿主按本bundle目录与唯一case目录读取实际小型证据。
        if(!object(row)||typeof row.directory!=='string')throw Error('Actual case directory missing');
        const directory=path.join(root,path.basename(row.directory));
        const expected=JSON.parse(fs.readFileSync(path.join(directory,'expected.json'),'utf8'));
        if(expected.sourceCommit!==sourceCommit||expected.librarySha256!==proof.files?.['libMobileGL.so']?.sha256||expected.executableSha256!==proof.files?.mobilegl_trace_replay?.sha256||expected.sourceFileSha256!==proof.sourceFileSha256)throw Error('Per-case identity differs from independent host source/artifact proof');
        if(typeof expected.case?.trace_file!=='string'||path.basename(expected.case.trace_file)!==expected.case.trace_file||typeof expected.case?.golden!=='string'||path.basename(expected.case.golden)!==expected.case.golden)throw Error('Pinned corpus filenames invalid');
        const hostFiles={provider:path.join(artifacts,'libMobileGL.so'),executable:path.join(artifacts,'mobilegl_trace_replay'),trace:path.join(directory,'input',expected.case.trace_file),golden:path.join(source,'tools/trace_replay/fixtures',expected.case.golden),sourceFile:path.join(source,'MobileGL/MG_Impl/GLXImpl/GLXImpl.cpp')};
        if(expected.icdPath)hostFiles.icd=flag('--host-icd');
        const evidence=readReplayEvidence(directory,expected,hostFiles);
        captured.push({row:{...row,directory},expected,evidence});
      }
      const checked=verifyReplayBundle(captured,required);
      for(const row of checked.runs)fs.writeFileSync(path.join(row.directory,'qualification.json'),JSON.stringify(row.qualification,null,2)+'\n');
      fs.writeFileSync(path.join(root,'qualified-results.json'),JSON.stringify({scope:summary.scope,...checked},null,2)+'\n');
      console.log('MobileGL replay bundle '+(checked.accepted?'PASS':'FAIL')+': '+checked.runs.length+' actual runs; '+checked.issues.join('; '));
      process.exitCode=checked.accepted?0:1;
      return;
    }
    const expected=JSON.parse(fs.readFileSync(flag('--expected'),'utf8'));
    const result=verifyReplayEvidence(readReplayEvidence(flag('--directory'),expected),expected);
    if(process.argv.includes('--out'))fs.writeFileSync(flag('--out'),JSON.stringify(result,null,2)+'\n');
    console.log('MobileGL replay evidence '+result.verdict+': '+result.issues.join('; '));process.exitCode=result.qualified?0:1;
  } catch(error){console.error('MobileGL replay evidence ERROR: '+error.message);process.exitCode=2;}
}

if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))cli();
