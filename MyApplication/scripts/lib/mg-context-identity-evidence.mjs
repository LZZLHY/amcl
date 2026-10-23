/** MG共享身份薄门：逐项核真实query/owner/指针证据，不创建context、不复制provider表。
 * highFirst来自caller独立run输入，不能从producer自报config反推期望。
 * 本模块不证明外部PID/RETURN/HAP/copy；这些由外层本次实际交付验收独立绑定。
 */
import fs from 'node:fs';
import { createHash } from 'node:crypto';
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const object=value=>value!==null&&typeof value==='object'&&!Array.isArray(value);
const uint=value=>Number.isSafeInteger(value)&&value>=0;
const pointer=value=>typeof value==='string'&&/^0x[0-9a-f]+$/i.test(value)&&BigInt(value)!==0n;
// 地址按数值归一，大小写或leading zero不得让同一live地址伪装成两个owner。
const addressKey=value=>pointer(value)?BigInt(value).toString(16):null;
const zero=value=>value==='0'||value==='0x0';
const pair=value=>Array.isArray(value)&&value.length===2&&value.every(uint);
const same=(a,b)=>JSON.stringify(a)===JSON.stringify(b);

/** 项目根loaderSource只允许本scene目录的精确文件，函数清单来自实际ID_LOAD宏。 */
export function loadMgContextIdentityContract(){
  const root=new URL('../../',import.meta.url);
  const bytes=fs.readFileSync(new URL('tests/graphics-semantics/mg_context_identity_cases.json',root));
  const contract=JSON.parse(bytes);
  if(contract.schema!=='amcl-mg-context-identity-contract/v1'||contract.sceneVersion!==1||
      contract.loaderMacro!=='ID_LOAD'||contract.loaderSource!=='tests/graphics-semantics/mg_context_identity_scene.cpp'||
      !same(contract.counts,{checks:11,queryChecks:4,pixelChecks:0})||contract.identityCases?.length!==4||
      contract.eglOwnedEntries?.length!==16)throw new Error('Invalid shared MG identity contract');
  const source=fs.readFileSync(new URL(contract.loaderSource,root));
  const functions=[...source.toString().matchAll(/\bID_LOAD\((\w+)\)/g)]
    .map(row=>row[1]).filter(name=>name!=='member').map(name=>'gl'+name);
  if(!same(functions,['glGetString','glGetIntegerv','glGetError']))throw new Error('MG identity production loader mismatch');
  // 允许的operation取自实际生产注册与跨owner转发，不能只信report的desktop布尔。
  const ownerSource=fs.readFileSync(new URL('entry/src/main/cpp/platform/graphics_egl_context.cpp',root));
  const ownerText=ownerSource.toString();
  const names=['mobilegluesDesktop','forwardedGl'].map(variable=>{
    const found=ownerText.match(new RegExp('const EglContextOperations '+variable+'\\{"([^"]+)",\\s*true,'));
    if(!found)throw new Error('MG identity operation production source changed: '+variable);
    return found[1];
  });
  if(!ownerText.includes('{"mobileglues", &mobilegluesDesktop}'))throw new Error('MG public profile factory registration missing');
  return {...contract,functions,operationNames:names,operationSourceSha256:sha(ownerSource),
    contractSha256:sha(bytes),loaderSha256:sha(source)};
}

/** 完整性和原始数值同时核对。poisoned pass/footer、字段缺失和旧合法GLES owner均拒。 */
export function auditMgContextIdentityRows(rows,highFirst,contract=loadMgContextIdentityContract()){
  const issues=[];const reject=value=>issues.push(value);
  const result={ok:false,issues,qualificationScope:'MG frontend identity/owner only',coreQualified:false,
    contractSha256:contract.contractSha256,loaderSha256:contract.loaderSha256};
  if(typeof highFirst!=='boolean'||!Array.isArray(rows)||rows.some(row=>!object(row)))return {...result,issues:['MG identity rows/independent order invalid']};
  const first=highFirst?'high':'low',second=highFirst?'low':'high';
  const expected=[
    ['setup','identity-runtime-ready'],['setup','identity-provider-owned'],['setup','identity-create-'+first],
    ['setup','identity-production-feature-probe'],['setup','identity-create-'+second],
    ...contract.identityCases.map(name=>['context-identity',name]),
    ...contract.cleanupCases.map(name=>['cleanup',name])];
  const checks=rows.filter(row=>Object.hasOwn(row,'pass'));
  if(checks.length!==11||checks.some((row,index)=>row.pass!==true||row.kind!==expected[index]?.[0]||row.case!==expected[index]?.[1]))
    reject('MG identity checks missing/reordered/duplicated/failing');
  if(rows.length!==13)reject('MG identity original row count mismatch');
  const config=rows[2],end=rows.at(-1);
  if(config?.kind!=='context-identity-config'||config.sceneVersion!==1||config.highFirst!==highFirst||
      !uint(config.ownerTid)||!config.ownerTid||!uint(config.processPid)||!config.processPid||
      config.runtimeDesktop!==true||config.ownerDesktop!==true||!contract.operationNames.includes(config.operation)||
      config.scope!=='frontend-identity-only'||config.coreQualified!==false)reject('MG identity config/order/owner contract mismatch');
  if(rows.filter(row=>row.kind==='context-identity-config').length!==1||rows.filter(row=>row.kind===contract.terminalKind).length!==1||
      end?.kind!==contract.terminalKind||end.completed!==true)reject('MG identity config/footer missing/duplicate/not final');
  const counts={checks:checks.length,queryChecks:checks.filter(row=>row.kind==='context-identity').length,
    pixelChecks:0,failures:checks.filter(row=>row.pass!==true).length};
  for(const [key,value]of Object.entries({...contract.counts,failures:0}))
    if(counts[key]!==value||end?.[key]!==value)reject('MG identity count mismatch: '+key);
  const at=name=>checks.find(row=>row.case===name);
  const provider=at('identity-provider-owned');
  if(!provider||typeof provider.image!=='string'||!provider.image.startsWith('/')||!pointer(provider.imageBase)||
      !pointer(provider.queryAddress)||provider.queryImage!==provider.image||!Array.isArray(provider.eglEntries))reject('MG actual provider identity incomplete');
  else{
    const entries=provider.eglEntries;
    if(entries.length!==16||!same(entries.map(row=>row?.name),contract.eglOwnedEntries)||new Set(entries.map(row=>row?.name)).size!==16||
        entries.some(row=>!object(row)||!pointer(row.address)||row.owned!==true||row.image!==provider.image))reject('MG EGL same-image table incomplete/foreign');
  }
  const probe=at('identity-production-feature-probe');
  if(!probe||probe.probed!==true||probe.auxiliaryVerified!==true)reject('MG second context bypassed production topology qualification');
  const created=new Map(),permits=new Map();
  for(const slot of ['low','high']){
    const row=at('identity-create-'+slot),request=contract.requests[slot];
    if(!row||!same(row.requested,[request.major,request.minor])||row.error!==''||!pointer(row.context)||!uint(row.permit)||!row.permit)
      reject('MG production create evidence incomplete: '+slot);
    else {created.set(slot,addressKey(row.context));permits.set(slot,row.permit);}
  }
  if(created.size===2&&created.get('low')===created.get('high'))reject('MG independent owners alias one live context');
  // ReserveGraphicsContext生产nextContextPermit单调分配；两个同时live的owner不共permit。
  if(permits.size===2&&permits.get('low')===permits.get('high'))reject('MG independent live owners alias one production permit');
  const remembered=new Map();
  for(let turn=0;turn<4;turn++){
    const row=at(contract.identityCases[turn]),slot=turn%2?second:first,wanted=contract.requests[slot];
    if(!row){reject('MG identity turn absent: '+turn);continue;}
    if(contract.requiredFields.some(key=>!Object.hasOwn(row,key)))reject('MG identity original field absent: '+turn);
    if(row.turn!==turn||row.slot!==slot||row.readOrder!==(turn%2?'integer-first':'string-first')||
        !same(row.requested,[wanted.major,wanted.minor])||row.requestedProfile!==wanted.profile||row.requestedForward!==wanted.forward||
        addressKey(row.context)!==created.get(slot))reject('MG identity turn/source request mismatch: '+turn);
    if(!pair(row.integer)||!pair(row.stringInteger)||!pair(row.ownerInteger)||!same(row.integer,row.stringInteger)||!same(row.integer,row.ownerInteger))
      reject('MG GL/string/owner grant mismatch: '+turn);
    else if(row.integer[0]<wanted.major||(row.integer[0]===wanted.major&&row.integer[1]<wanted.minor)||
        row.eglClientMajor!==row.integer[0])reject('MG granted version below request/EGL override mismatch: '+turn);
    // 一般desktop EGL CLIENT_VERSION不表示actualGL；这里只核已绑定的MG wrapper override。
    if(row.eglApi!==contract.eglIdentity.clientApi||row.profile!==contract.profileMask||row.ownerProfile!==wanted.profile||
        !uint(row.flags)||row.ownerFlags!==row.flags||(wanted.forward&&!(row.flags&contract.flagsForwardBit)))
      reject('MG frontend API/profile/flags mismatch: '+turn);
    const version=typeof row.version==='string'?row.version.match(/^(\d+)\.(\d+)(?:\.|\s|$)/):null;
    if(!version||!same([Number(version[1]),Number(version[2])],row.integer)||typeof row.renderer!=='string'||!row.renderer||
        typeof row.glsl!=='string'||!row.glsl)reject('MG actual original version/renderer/GLSL absent: '+turn);
    if(row.current!==true||row.ownerTid!==config?.ownerTid||row.error!==0||row.errorCount!==0||row.errorDrainComplete!==true||row.eglError!==0x3000)
      reject('MG current/thread/query error evidence invalid: '+turn);
    if(!pointer(row.versionPointer)||row.pointerStable!==true||row.heldPointersStable!==true)reject('MG version pointer invalid/unstable: '+turn);
    const prior=remembered.get(slot);
    if(prior&&(prior.pointer!==addressKey(row.versionPointer)||prior.version!==row.version))reject('MG switched context immutable version changed: '+turn);
    if(!prior)remembered.set(slot,{pointer:addressKey(row.versionPointer),version:row.version});
    // GL允许相同不可变文本共享地址，但同一live地址不能同时声明不同文本。
    // 仅逐slot自洽会漏掉所有pointer统一而保留两套文字的矛盾报告。
    const contentsByPointer=new Map();
    for(const value of remembered.values()){
      if(contentsByPointer.has(value.pointer)&&contentsByPointer.get(value.pointer)!==value.version)
        reject('MG one retained live version pointer claims conflicting contents: '+turn);
      contentsByPointer.set(value.pointer,value.version);
    }
    const held=row.heldVersions,slots=['low','high'].filter(name=>remembered.has(name));
    if(!Array.isArray(held)||!same(held.map(value=>value?.slot),slots))reject('MG retained pointer set incomplete/duplicate: '+turn);
    else for(const value of held){
      const saved=remembered.get(value.slot);
      if(!object(value)||addressKey(value.pointer)!==saved?.pointer||value.expected!==saved?.version||value.actual!==saved?.version)
        reject('MG old pointer content changed while another context current: '+turn);
    }
  }
  for(const name of contract.cleanupCases){
    const row=at(name);
    if(!row||row.attempted!==true||row.error!==''||row.permit!==0||!zero(row.context)||!zero(row.surface)||!zero(row.parking))
      reject('MG production owner not actually retired: '+name);
  }
  return {...result,ok:issues.length===0,counts,highFirst,operationSourceSha256:contract.operationSourceSha256};
}
