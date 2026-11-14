/**
 * SDK之外的侧载宿主测试输入准备器。只接收显式外置输出，公开工具来自仓库锁定pin；
 * 本机可提供只读原件以免重复下载，CI使用固定公开URL。准备和测试分开，测试本身不联网。
 */
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { assertExternalOutputPath } from './lib/workspace-paths.mjs';

const project=path.resolve(import.meta.dirname,'..');
const maximum=48*1024*1024;
const sha=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');

/** 普通文件有界读取；符号链接或过大输入不能冒充固定工具原件。 */
function readBounded(filename,maxBytes=maximum) {
  const stat=fs.lstatSync(filename);
  if(stat.isSymbolicLink()||!stat.isFile()||stat.size<1||stat.size>maxBytes)throw Error('Invalid bounded sideload input: '+filename);
  const bytes=fs.readFileSync(filename);
  if(bytes.length<1||bytes.length>maxBytes||bytes.length!==stat.size)throw Error('Sideload input changed while reading');
  return bytes;
}

/**
 * 固定摘要的下载边界，单独导出供小型内存Response负控。CLI始终使用仓库pin，不能从参数
 * 覆盖SHA或URL；流式累计上限同时防伪造Content-Length和无长度响应，超界立即取消reader。
 */
export async function receivePinnedTool(pin,{source,request=fetch,maxBytes=maximum}={}) {
  if(!/^[0-9a-f]{64}$/.test(pin.sha256)||!pin.url.startsWith('https://raw.githubusercontent.com/openharmony/'))throw Error('Invalid signer pin');
  let bytes;
  if(source)bytes=readBounded(source,maxBytes);
  else {
    const response=await request(pin.url,{signal:AbortSignal.timeout(90000)});
    if(!response.ok||!response.body){await response.body?.cancel().catch(()=>{});throw Error('Pinned signer request failed');}
    const length=Number(response.headers.get('content-length')??0);
    if(!Number.isSafeInteger(length)||length<0||length>maxBytes){await response.body.cancel().catch(()=>{});throw Error('Pinned signer size exceeds limit');}
    const reader=response.body.getReader(),parts=[];let total=0;
    try {for(;;){const chunk=await reader.read();if(chunk.done)break;total+=chunk.value.byteLength;
      if(total>maxBytes)throw Error('Pinned signer stream exceeds limit');parts.push(Buffer.from(chunk.value));}}
    catch(error){await reader.cancel().catch(()=>{});throw error;}
    finally{reader.releaseLock();}
    bytes=Buffer.concat(parts,total);
  }
  if(bytes.length<1||sha(bytes)!==pin.sha256)throw Error('Pinned signer SHA-256 mismatch');
  return bytes;
}

/** 只写本次独占pending文件；旧完整原件不因失败而先被截断，句柄在rename前关闭。 */
function writeAtomic(filename,bytes) {
  const pending=filename+'.'+crypto.randomUUID()+'.pending';let fd;
  try {fd=fs.openSync(pending,'wx');let offset=0;while(offset<bytes.length){const count=fs.writeSync(fd,bytes,offset,bytes.length-offset);if(count<=0)throw Error('Short sideload input write');offset+=count;}
    fs.fsyncSync(fd);fs.closeSync(fd);fd=undefined;fs.renameSync(pending,filename);
  } finally {if(fd!==undefined)fs.closeSync(fd);if(fs.existsSync(pending))fs.unlinkSync(pending);}
}

/**
 * 按同一固定pin准备真实工具与当前tracked runner，保留小型来源收据。已存在的工具仍核SHA；
 * 目录只由显式output确定，源树、SDK和用户全局TEMP不被改写，现有坏缓存不会被当成功。
 */
export async function prepareSideloadHostInputs({output,sourceRoot,request=fetch}) {
  if(!output||!path.isAbsolute(output))throw Error('--output must be an absolute external raw root');
  const directory=assertExternalOutputPath(output),resources=assertExternalOutputPath(path.join(directory,'sideload'));
  fs.mkdirSync(resources,{recursive:true});
  const pin=JSON.parse(fs.readFileSync(path.join(project,'prebuilt/hap-sign-tool/pin.json'),'utf8'));
  const tool=path.join(resources,'hap-sign-tool.jar'),runner=path.join(resources,'amcl-signing-runner.jar');
  let toolBytes,source='cached-pin';
  if(fs.existsSync(tool)){toolBytes=readBounded(tool);if(sha(toolBytes)!==pin.sha256)throw Error('Prepared signer cache is corrupt; preserve it and choose a fresh output');}
  else {source=sourceRoot?'local-pin':'public-pin';toolBytes=await receivePinnedTool(pin,{request,source:sourceRoot?path.join(sourceRoot,'sideload/hap-sign-tool.jar'):undefined});writeAtomic(tool,toolBytes);}
  const runnerSource=path.join(project,'entry/src/main/resources/rawfile/sideload/amcl-signing-runner.jar');
  const runnerBytes=readBounded(runnerSource);writeAtomic(runner,runnerBytes);
  const receipt={schema:1,preparedAt:new Date().toISOString(),tool:{url:pin.url,revision:pin.revision,sha256:sha(toolBytes),sizeBytes:toolBytes.length,source},
    runner:{source:runnerSource,sha256:sha(runnerBytes),sizeBytes:runnerBytes.length},rawRoot:directory};
  writeAtomic(path.join(directory,'sideload-host-inputs.json'),Buffer.from(JSON.stringify(receipt,null,2)+'\n'));
  return receipt;
}

if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  const options={};for(let index=2;index<process.argv.length;index+=2){const key=process.argv[index];
    if(!['--output','--source-root'].includes(key)||!process.argv[index+1])throw Error('Usage: --output <externalRawRoot> [--source-root <readOnlyRawRoot>]');options[key]=process.argv[index+1];}
  const receipt=await prepareSideloadHostInputs({output:options['--output'],sourceRoot:options['--source-root']});
  console.log(JSON.stringify(receipt));
}
