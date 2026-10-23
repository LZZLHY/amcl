/**
 * TestHooks后续场景的外部证据门。共享场景拥有语义oracle；本层核原字节完整性、
 * 冷进程身份、真实加载文件与最终HAP、外部函数返回，以及独立driver预期。
 * expected由动作前HDC/UI/冻结包观测提供，不从待审报告或其副本反推。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { readUniqueZipEntry } from './zip-entry-buffer.mjs';
import { assertExternalOutputPath } from './lib/workspace-paths.mjs';
import { auditMobileGlProgramRows, loadMobileGlProgramContract } from './lib/mobilegl-program-evidence.mjs';
import { auditMgContextIdentityRows, loadMgContextIdentityContract } from './lib/mg-context-identity-evidence.mjs';

const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const hex40=value=>typeof value==='string'&&/^[0-9a-f]{40}$/.test(value);
const hex64=value=>typeof value==='string'&&/^[0-9a-f]{64}$/.test(value);
// key=value含JSON字符串时仍完整读取；重复字段/未消费尾文本直接拒绝。
function fields(line,prefix) {
  if(!line.startsWith(prefix+' '))throw new Error('Missing '+prefix);
  const result={};let rest=line.slice(prefix.length+1);
  while(rest.length) {
    const match=/^([A-Za-z][A-Za-z0-9]*)=("(?:[^"\\]|\\.)*"|[^\s]+)(?:\s+|$)/.exec(rest);
    if(!match||Object.hasOwn(result,match[1]))throw new Error('Malformed/duplicate metadata '+prefix);
    result[match[1]]=match[2].startsWith('"')?JSON.parse(match[2]):match[2];rest=rest.slice(match[0].length);
  }return result;
}
function one(lines,prefix){const rows=lines.filter(line=>line.startsWith(prefix+' '));if(rows.length!==1)throw new Error('Expected one '+prefix);return fields(rows[0],prefix);}

/** loadedCopy是实际沙箱映像副本，returnLog是独立原UI文本/日志；函数完成不是自然退出。 */
export function auditGraphicsSceneEvidence(report,returnLog,loadedCopy,hap,expected) {
  const issues=[];const fail=value=>issues.push(value);
  const result={ok:false,issues,reportSha256:sha(report),returnSha256:sha(returnLog),loadedSha256:sha(loadedCopy),hapSha256:sha(hap)};
  try {
    if(!expected||!Number.isSafeInteger(expected.pid)||expected.pid<=0||!new RegExp('^'+expected.pid+'-\\d+$').test(expected.runId)||
       !hex64(expected.librarySha256)||!hex64(expected.hapSha256)||!hex40(expected.sourceHead))throw new Error('Independent PID/run/HAP/source/library identity required');
    if(result.hapSha256!==expected.hapSha256)fail('Final HAP differs from pre-action frozen package');
    const profile=JSON.parse(readUniqueZipEntry(hap,'resources/rawfile/product-profile.json'));
    if(profile.sourceRevision!==expected.sourceHead)fail('Final HAP source differs from independent frozen source');
    const mobileGlProgram=expected.probe==='mobilegl-program';
    const identity=expected.probe==='mg-context-low-first'||expected.probe==='mg-context-high-first';
    if(!mobileGlProgram&&!identity)throw new Error('Unsupported explicit scene probe');
    const library=mobileGlProgram?'libmobilegl.so':'libamcl_gl_host.so';
    const payload=readUniqueZipEntry(hap,'libs/arm64-v8a/'+library);
    if(sha(payload)!==expected.librarySha256||result.loadedSha256!==expected.librarySha256||!loadedCopy.equals(payload))fail('Actual loaded-file copy/frozen library/HAP member differ');
    if(payload.length<64||payload.toString('hex',0,6)!=='7f454c460201'||payload.readUInt16LE(18)!==183)fail('Payload is not AArch64 ELF64');
    const text=report.toString('utf8');if(!Buffer.from(text).equals(report)||!text.endsWith('\n'))throw new Error('Report UTF8/trailing newline incomplete');
    const lines=text.slice(0,-1).split('\n');if(lines.some(line=>!line.length))throw new Error('Empty evidence record');
    const header=one(lines,'GRAPHICS_SCENE_RUN'),end=one(lines,'GRAPHICS_SCENE_END');
    if(!lines[0].startsWith('GRAPHICS_SCENE_RUN ')||!lines.at(-1).startsWith('GRAPHICS_SCENE_END '))fail('Run header/end are not original boundary records');
    for(const value of [header,end])if(value.probe!==expected.probe||value.runId!==expected.runId||value.processPid!==String(expected.pid))fail('Original process/run identity differs from action observation');
    if(!/^\d+$/.test(header.startUnixNs??'')||header.startSteadyNs!==expected.runId.split('-')[1]||end.restartRequired!=='1'||end.verdict!=='PASS_SCOPE')fail('Run did not complete in claimed restart-required process');
    // 原UI行没有前缀，原hilog行有时间/tag；只剥离marker前的日志元数据，
    // marker本身必须由原字节唯一出现，不能从文件END或expected补写。
    const returns=returnLog.toString('utf8').split(/\r?\n/).filter(line=>line.includes('GRAPHICS_SCENE_RETURN ')&&line.includes('runId='+expected.runId+' '))
      .map(line=>line.slice(line.indexOf('GRAPHICS_SCENE_RETURN ')));
    if(returns.length!==1)throw new Error('Independent original UI/log RETURN missing/duplicated');
    const returned=fields(returns[0],'GRAPHICS_SCENE_RETURN');
    if(returned.probe!==expected.probe||returned.processPid!==String(expected.pid)||returned.returned!=='1'||returned.verdict!=='PASS_SCOPE'||returned.reportBytes!==String(report.length))fail('External function-return/report byte boundary invalid');
    const copy=one(lines,'IMAGE_COPY'),provider=one(lines,'PROVIDER'),resolution=one(lines,'RESOLUTION');
    const directory='/data/storage/el2/base/haps/entry/files/graphics-semantic-probes/'+expected.runId;
    if(copy.library!==library||copy.path!==directory+'/loaded-'+library||copy.bytes!==String(payload.length))fail('Actual image copy run/path/size invalid');
    if(!provider.image.endsWith('/'+library)||provider.factory!==(mobileGlProgram?'mobilegl-desktop-gl':'mobileglues-desktop-gl'))fail('Production provider/factory identity invalid');
    const egl=lines.filter(line=>line.startsWith('EGL_FUNCTION ')).map(line=>fields(line,'EGL_FUNCTION'));
    const requiredEgl=['eglCreateContext','eglMakeCurrent','eglQueryContext','eglGetCurrentContext'];
    if(egl.length!==requiredEgl.length||egl.some((row,index)=>row.name!==requiredEgl[index]||row.owned!=='1'||row.image!==provider.image))fail('Production EGL path is incomplete/foreign');
    const contract=mobileGlProgram?loadMobileGlProgramContract():loadMgContextIdentityContract();
    const names=mobileGlProgram?['glGetString',...contract.functions]:contract.functions;
    const functions=lines.filter(line=>line.startsWith('FUNCTION ')).map(line=>fields(line,'FUNCTION'));
    if(functions.length!==names.length||functions.some((row,index)=>row.name!==names[index]||row.owned!=='1'||row.image!==provider.image||
       !/^0x[0-9a-f]+$/i.test(row.address)||BigInt(row.address)===0n))fail('Actual scene function resolution is missing/foreign');
    if(resolution.resolved!==String(names.length)||resolution.rejected!=='0')fail('Resolver completion mismatch');
    const rows=lines.filter(line=>line.startsWith('{')).map(line=>JSON.parse(line));
    result.scene=mobileGlProgram?auditMobileGlProgramRows(rows,'Unsupported',contract):auditMgContextIdentityRows(rows,expected.probe==='mg-context-high-first',contract);
    // 逐条保留共享薄门理由，避免只借producer summary。
    if(!result.scene.ok)for(const issue of result.scene.issues)fail(issue);
    if(identity) {
      const config=rows.find(row=>row.kind==='context-identity-config');
      const owner=rows.find(row=>row.case==='identity-provider-owned');
      if(config?.processPid!==expected.pid||config?.operation!==provider.factory||owner?.image!==provider.image||owner?.queryImage!==provider.image||
         owner?.eglEntries?.some(row=>row.image!==provider.image))fail('Inner identity scene and outer actual process/provider differ');
    }
    if(mobileGlProgram) {
      const publication=one(lines,'BACKEND_PUBLICATION');
      if(publication.value!=='DirectVulkan'||publication.source!=='production-cold-publisher')fail('MGL production cold transport publication missing');
      const driverLines=lines.filter(line=>line.startsWith('DRIVER_FACTS '));
      if(driverLines.length!==1)throw new Error('One actual driver fact record required');
      const facts=JSON.parse(driverLines[0].slice('DRIVER_FACTS '.length));
      if(!expected.driver||expected.driver.shaderFloat64!==false||facts.baseFeaturesQueried!==true||facts.shaderFloat64!==false||
         facts.deviceName!==expected.driver.deviceName||!facts.deviceName||facts.vendorId!==expected.driver.vendorId)fail('Physical driver features differ from independently captured device facts');
      const expectation=one(lines,'CALLER_EXPECTATION'),actual=one(lines,'ACTUAL_GL');
      if(expectation.Float64!=='Unsupported'||expectation.source!=='actual-system-Vulkan-baseFeatures'||expectation.fullCoreQualified!=='0')fail('Precision oracle expectation is not independent physical fact');
      if(!actual.renderer.includes('Magma')||!actual.renderer.includes(facts.deviceName)||!actual.version||actual.requested!=='4.3'||Number(actual.actualMajor)<4)fail('Actual tested MGL transport/device mismatch');
    }
    const summary=one(lines,contract.hostMarker);
    const counts=mobileGlProgram?contract.branches.Unsupported.counts:contract.counts;
    for(const [key,value]of Object.entries(counts))if(summary[key]!==String(value))fail('Original summary count mismatch: '+key);
    if(summary.sceneVersion!==String(contract.sceneVersion)||summary.completed!=='1'||summary.evidenceComplete!=='1'||summary.failures!=='0')fail('Original scene completion invalid');
    if(mobileGlProgram&&(summary.ownerRetired!=='1'||summary.resolved!=='59'||summary.fullCoreQualified!=='0'||summary.coreFP64Qualified!=='0'))fail('MGL owner retirement/scope incomplete');
    if(identity&&(summary.highFirst!==String(Number(expected.probe==='mg-context-high-first'))||summary.coreQualified!=='0'))fail('MG identity order/scope mismatch');
    const acceptedPrefixes=['GRAPHICS_SCENE_RUN ','GRAPHICS_SCENE_END ','IMAGE_COPY ','PROVIDER ','EGL_FUNCTION ','FUNCTION ','RESOLUTION ',contract.hostMarker+' ',
      ...(mobileGlProgram?['BACKEND_PUBLICATION ','DRIVER_FACTS ','CALLER_EXPECTATION ','ACTUAL_GL ']:[])];
    if(lines.some(line=>!line.startsWith('{')&&!acceptedPrefixes.some(prefix=>line.startsWith(prefix))))fail('Unknown/FAIL/NOT_RUN original evidence record');
    result.verdict='PASS_SCOPE';result.coreQualified=false;result.functionReturned=true;result.processNaturallyExited='NOT_CLAIMED';
  }catch(error){fail(error.message);}
  result.ok=issues.length===0;if(!result.ok)result.verdict='FAIL';return result;
}

// CLI只读取原材料，输出必须显式仓外；缺参数不形成默认PASS或借本报告推期望。
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  const args={};for(let i=2;i<process.argv.length;i+=2)args[process.argv[i].replace(/^--/,'')]=process.argv[i+1];
  try {
    for(const key of ['report','return-marker-file','loaded-library','hap','expected','output'])if(!args[key])throw new Error('Missing --'+key);
    assertExternalOutputPath(args.output);
    const result=auditGraphicsSceneEvidence(...['report','return-marker-file','loaded-library','hap'].map(name=>fs.readFileSync(args[name])),JSON.parse(fs.readFileSync(args.expected,'utf8')));
    fs.writeFileSync(args.output,JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify(result));process.exitCode=result.ok?0:1;
  }catch(error){console.error(error.message);process.exitCode=2;}
}
