/**
 * 核对本产品外部原生provider的真实交付链：CMake/锁定预编译输入→staging→SDK strip→HAP。
 * 不修改JAR/HAP、不签名、不接受别的产品路径。LWJGL的Maven SHA1只适用于其同批JNI
 * natives；本门为OHOS外部C provider建立独立的最终字节身份，导出面由既有module门承担。
 */
import {createHash} from 'node:crypto';
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
import {resolve,join,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {readUniqueZipEntry} from './zip-entry-buffer.mjs';
import {readSdl3ArtifactLock,resolveBundleFileLock} from './lib/sdl3-artifact-lock.mjs';

const ROOT=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const PROVIDERS=[
  ['libglfw.so','cmake'],['libopenal.so','cmake'],['libamcl_vulkan_wsi.so','cmake'],
  ['libamcl_game_dialog.so','cmake'],
  ['libamcl_lwjgl_jemalloc.so','prebuilt'],['libSDL3.so','prebuilt'],['libamcl_sdl_controller.so','controller-prebuilt'],['libfreetype.so','prebuilt'],['libshaderc.so','prebuilt'],['libspirv-cross.so','prebuilt'],
  // zstd JNI沿同一source→stage→strip→HAP字节链审核，身份来自独立版本/绑定锁。
  ['libamcl_zstdjni_std.so','zstd-prebuilt'],['libamcl_zstdjni_dh.so','zstd-prebuilt']
];
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
const requireCondition=(yes,message)=>{if(!yes)throw Error(message);};

export function lockedBundleProvider(root, modules, artifact) {
  const matches = modules.filter(({native}) =>
    native?.kind === 'bundle-file' && native.artifact === 'entry/libs/arm64-v8a/' + artifact);
  requireCondition(matches.length === 1, `${artifact}: unique locked provider required`);
  const lock = resolveBundleFileLock(root, matches[0].name, matches[0].native);
  requireCondition(/^[0-9a-f]{64}$/.test(lock.sha256), `${artifact}: locked source SHA-256 required`);
  requireCondition(Number.isSafeInteger(lock.size) && lock.size > 0, `${artifact}: locked source size required`);
  return lock;
}

/**
 * strip允许移除调试/符号等非装载节，不允许改变任何SHF_ALLOC节的类型、地址、大小、
 * 标志或字节。检查完整集合，缺节/增节/重复名都拒绝；NOBITS只比较内存形状，不读文件字节。
 * 此证明比仅比较build-id更强：即使篡改者保留旧build-id，实际代码/常量/重定位仍会失配。
 */
export function allocatedElfIdentity(bytes){
  requireCondition(bytes.length>=64&&bytes.subarray(0,4).equals(Buffer.from([127,69,76,70])),'provider is not ELF');
  requireCondition(bytes[4]===2&&bytes[5]===1&&bytes.readUInt16LE(16)===3&&bytes.readUInt16LE(18)===183,'provider must be ELF64 little-endian AArch64 DSO');
  const safe64=offset=>{const n=Number(bytes.readBigUInt64LE(offset));requireCondition(Number.isSafeInteger(n),'ELF integer out of range');return n;};
  const table=safe64(40),stride=bytes.readUInt16LE(58),count=bytes.readUInt16LE(60),strings=bytes.readUInt16LE(62);
  requireCondition(stride===64&&count>0&&count<65535&&strings<count&&table+count*stride<=bytes.length,'invalid ELF section table');
  const stringHeader=table+strings*stride,nameOffset=safe64(stringHeader+24),nameSize=safe64(stringHeader+32);
  requireCondition(nameOffset+nameSize<=bytes.length,'invalid ELF section names');
  const result=[];const names=new Set();
  for(let index=0;index<count;index++){
    const header=table+index*stride,flags=safe64(header+8);
    if(!(flags&2))continue;
    const relativeName=bytes.readUInt32LE(header),type=bytes.readUInt32LE(header+4),address=safe64(header+16),offset=safe64(header+24),size=safe64(header+32);
    requireCondition(relativeName<nameSize,'invalid allocated section name');
    const end=bytes.indexOf(0,nameOffset+relativeName);
    requireCondition(end>=nameOffset+relativeName&&end<nameOffset+nameSize,'unterminated allocated section name');
    const name=bytes.subarray(nameOffset+relativeName,end).toString('utf8');
    requireCondition(name.length>0&&!names.has(name),'duplicate/empty allocated section name');names.add(name);
    requireCondition(type===8||offset+size<=bytes.length,'allocated section exceeds file');
    result.push({name,type,flags,address,size,sha256:type===8?null:hash(bytes.subarray(offset,offset+size))});
  }
  requireCondition(result.some(x=>(x.flags&4)!==0),'provider has no executable allocated section');
  return result.sort((a,b)=>a.name.localeCompare(b.name));
}

/** 真实字节四段核对的纯核心，允许测试提供独立负控，不调用外部工具或信任文件mtime。 */
export function verifyProviderBytes({artifact,origin,staged,stripped,embedded,expectedSourceSha256,expectedSourceSize,expectedHap}){
  if(expectedSourceSize!==undefined)requireCondition(origin.length===expectedSourceSize,`${artifact}: locked prebuilt source size mismatch`);
  if(expectedSourceSha256)requireCondition(hash(origin)===expectedSourceSha256,`${artifact}: locked prebuilt source mismatch`);
  requireCondition(origin.equals(staged),`${artifact}: origin/staged bytes differ`);
  requireCondition(stripped.equals(embedded),`${artifact}: stripped/HAP bytes differ`);
  if(expectedHap)requireCondition(embedded.length===expectedHap.size && hash(embedded)===expectedHap.sha256,
    `${artifact}: locked HAP entry mismatch`);
  const before=allocatedElfIdentity(origin),after=allocatedElfIdentity(stripped);
  requireCondition(JSON.stringify(before)===JSON.stringify(after),`${artifact}: SDK strip changed allocated ELF content`);
  return {artifact,originSha256:hash(origin),stagedSha256:hash(staged),strippedSha256:hash(stripped),hapEntrySha256:hash(embedded),sizeBytes:embedded.length,allocatedImageSha256:hash(Buffer.from(JSON.stringify(after)))};
}

/**
 * 只消费本次明确产品的SDK默认路径。HAP内产品/模式和入口源码修订必须存在；调用者仍须
 * 通过项目的源码冻结、SDK配置及符号门。此处不把字节链单独升级为游戏或完整发行资格。
 */
export function checkHapNativeProviders({root=ROOT,product,mode,hapPath}){
  requireCondition(['default','sideload','store','desktop'].includes(product),'explicit known product required');
  requireCondition(['debug','release'].includes(mode),'explicit build mode required');
  const hap=resolve(hapPath),base=resolve(root,'entry/build',product),prefix=resolve(base,'outputs',product);
  requireCondition(hap===join(prefix,`entry-${product}-signed.hap`)||hap===join(prefix,`entry-${product}-unsigned.hap`),'HAP must be this product SDK output');
  const bytes=readFileSync(hap),profile=JSON.parse(readUniqueZipEntry(bytes,'resources/rawfile/product-profile.json'));
  const module=JSON.parse(readUniqueZipEntry(bytes,'module.json'));
  requireCondition(profile.name===product&&module.app.buildMode===mode,'HAP product/build mode mismatch');
  requireCondition(/^[0-9a-f]{40}$/.test(profile.sourceRevision),'HAP sourceRevision missing');
  // route日志字串来自本轮实际Native实现，旧HAP不能借新checker拿到修复资格。
  const entry=readUniqueZipEntry(bytes,'libs/arm64-v8a/libentry.so');
  requireCondition(entry.includes(Buffer.from('AMCL_HAP_NATIVE_OWNER path='))&&entry.includes(Buffer.from('AMCL_HAP_PROVIDER_BINDING mode=absolute-external')),'HAP does not contain the external provider ownership route');
  const policy=JSON.parse(readFileSync(resolve(root,'prebuilt/lwjgl3/target-manifest-coverage.json'),'utf8'));
  const providers=[];
  for(const [artifact,kind] of PROVIDERS){
    const source=kind==='cmake'?resolve(base,'intermediates/cmake',product,'obj/arm64-v8a',artifact):resolve(root,'entry/libs/arm64-v8a',artifact);
    const staged=resolve(base,'intermediates/libs',product,'arm64-v8a',artifact);
    const stripped=resolve(base,'intermediates/stripped_native_libs',product,'arm64-v8a',artifact);
    let expectedSourceSha256,expectedSourceSize,expectedHap;
    if(kind==='prebuilt'){
      const lock=lockedBundleProvider(root,policy.modules,artifact);
      expectedSourceSha256=lock.sha256;
      expectedSourceSize=lock.size;
      expectedHap=lock.hap;
    }
    // FFM 独立库不属于 LWJGL 模块，其 raw 与实际 SDK strip 身份由同一制品锁提供。
    if(kind==='controller-prebuilt'){
      const lock=readSdl3ArtifactLock(root,true);
      expectedSourceSha256=lock.get('sha256');expectedSourceSize=Number(lock.get('size'));
      expectedHap={size:Number(lock.get('hap_size')),sha256:lock.get('hap_sha256')};
    }
    if(kind==='zstd-prebuilt'){
      const lock=JSON.parse(readFileSync(resolve(root,'prebuilt/mod-natives/zstd-jni/artifacts.json'),'utf8'));
      const matches=lock.artifacts.filter(x=>x.filename===artifact);
      requireCondition(matches.length===1&&/^[0-9a-f]{64}$/.test(matches[0].sha256),`${artifact}: unique zstd provider required`);
      expectedSourceSha256=matches[0].sha256;
    }
    providers.push({...verifyProviderBytes({artifact,origin:readFileSync(source),staged:readFileSync(staged),stripped:readFileSync(stripped),embedded:readUniqueZipEntry(bytes,'libs/arm64-v8a/'+artifact),expectedSourceSha256,expectedSourceSize,expectedHap}),kind,source,staged,stripped});
  }
  return {schema:'amcl-hap-external-providers/v1',at:new Date().toISOString(),product,mode,abi:'arm64-v8a',sourceRevision:profile.sourceRevision,hap,hapSha256:hash(bytes),providers,scope:'external provider byte delivery and strip invariance; existing module-coverage gate separately verifies actual exports; no device qualification'};
}

if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  const argument=name=>{const i=process.argv.indexOf(name);return i<0?undefined:process.argv[i+1];};
  try{
    const result=checkHapNativeProviders({root:argument('--root')??ROOT,product:argument('--product'),mode:argument('--mode'),hapPath:argument('--hap')});
    const output=argument('--out');if(output){mkdirSync(dirname(resolve(output)),{recursive:true});writeFileSync(resolve(output),JSON.stringify(result,null,2)+'\n');}
    console.log(`[hap-native-providers] PASS ${result.product}/${result.mode}: ${result.providers.length} current-HAP providers, source/staged/strip/HAP bound`);
  }catch(error){console.error(`[hap-native-providers] FAIL: ${error.message}`);process.exitCode=1;}
}
