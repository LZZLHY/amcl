/**
 * 复用既有整合包测试的同一平台fixture搭建，独立执行CF别名消费者，不改并行任务维护
 * 的test-modpack-install。只取其首段fixture声明和finally收尾，不复制产品安装算法。
 */
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {spawnSync} from 'node:child_process';
const scripts=path.dirname(fileURLToPath(import.meta.url));
const original=fs.readFileSync(path.join(scripts,'test-modpack-install.mjs'),'utf8').replaceAll('\r\n','\n');
const start=original.indexOf('// 格式/路径/必需文件观察必须保留');
const end=original.lastIndexOf('} catch(error) {\n  failure=error;');
assert(start>0&&end>start,'existing fixture prelude/owned teardown must remain identifiable');
const body=String.raw`
const C=load('mods/src/main/ets/CurseForgeUrls.ets');
const edge='https://edge.forgecdn.net/files/7446/117/GT%20New%20Horizons-2.8.4.zip?sig=A%2bb&x=2&x=1';
const media='https://mediafilez.forgecdn.net/files/7446/117/GT%20New%20Horizons-2.8.4.zip?sig=A%2bb&x=2&x=1';
const expected=[edge,media],plain=value=>JSON.parse(JSON.stringify(value));
const setup=()=>{archiveFormat='curseforge';archiveManifest={manifestType:'minecraftModpack',manifestVersion:1,name:'CF Alias',version:'1',
  minecraft:{version:'1.20.1',modLoaders:[{id:'forge-47.2.0',primary:true}]},files:[{projectID:252507,fileID:7446117,required:true}],overrides:'overrides'};overrides={};};
const content=Buffer.from('same official CF content');bodies.set(edge,content);bodies.set(media,content);
const resolver=async()=>({filename:'cf.jar',targetDirectory:'mods',urls:[edge],sha1:digest(content),size:content.length});
setup();
// 新归档经生产prepare，持久来源仍保原URL/空mirrors，真正Native边界必须补官方别名。
let req={...request('fresh-cf'),archivePath:undefined,archiveUrl:edge,archiveMirrors:[],officialFilesOnly:true,
  archiveSha1:digest(archiveBytes),archiveSize:archiveBytes.length,projectId:'252507',sourceVersionId:'7446117',resolveCfFile:resolver};
let before=downloaded.length;const installer=new I.ModpackInstaller();let session=await installer.prepare(req);
if(process.env.AMCL_CF_ALIAS_URLS_OUT)fs.writeFileSync(process.env.AMCL_CF_ALIAS_URLS_OUT,Array.from(downloaded[before].files[0].urls).join('\n')+'\n');
assert.deepEqual(plain(downloaded[before].files[0].urls),expected,'actual archive Native spec requires both official URLs');
assert.deepEqual(plain(downloaded[before].files[0].check),{sha1:digest(archiveBytes),size:archiveBytes.length});
passed('fresh CF archive actual Native spec retains SHA/size and two official candidates');
// 保存的旧source形状（edge/空mirrors/strict）在新进程prepare读取，不能只改列表mapper。
req={...request('old-cf-source'),archivePath:undefined,archiveUrl:edge,archiveMirrors:[],officialFilesOnly:true,
  archiveSha1:digest(archiveBytes),archiveSize:archiveBytes.length,projectId:'252507',sourceVersionId:'7446117',resolveCfFile:resolver};
const Src=Sessions;
Src.saveModpackSource(req.filesDir,{schemaVersion:1,id:req.sessionId,mcDir:req.mcDir,title:'old CF',requestedVersionName:'Old CF',
  officialFilesOnly:true,archiveUrl:edge,archiveMirrors:[],archiveSha1:req.archiveSha1,archiveSize:req.archiveSize,projectId:'252507',sourceVersionId:'7446117'});
before=downloaded.length;session=await new I.ModpackInstaller().prepare({...req,archiveUrl:'https://untrusted.invalid/ignored',officialFilesOnly:false});
assert.deepEqual(plain(downloaded[before].files[0].urls),expected,'cold old source actual archive spec must retain official alias');
const savedSource=Src.loadModpackSource(req.filesDir,req.sessionId);assert.equal(savedSource.archiveUrl,edge);assert.deepEqual(plain(savedSource.archiveMirrors),[]);
assert.equal(savedSource.officialFilesOnly,true);assert.equal(savedSource.archiveSha1,req.archiveSha1);assert.equal(savedSource.archiveSize,req.archiveSize);
passed('cold old CF source preserves identity and strict intent while actual Native boundary repairs alias');
// 已有旧session的清单文件也可能只有edge；恢复和安装后repair必须经过相同生产边界。
session.plan.files[0].urls=[edge];session.officialFilesOnly=true;Sessions.saveModpackSession(req.filesDir,session);
before=downloaded.length;const result=await new I.ModpackInstaller().installFromArchive({...req,officialFilesOnly:false});
let contentSpec=downloaded.slice(before).find(value=>value.name.startsWith('modpack-files:'));
assert(contentSpec);assert.deepEqual(plain(contentSpec.files[0].urls),expected,'cold CF manifest actual Native spec');
assert.equal(contentSpec.files[0].check.sha1,digest(content));assert.equal(contentSpec.files[0].check.size,content.length);
assert(!contentSpec.files[0].urls.some(value=>value.includes('mcimirror')));assert.equal(result.missing.length,0);
assert.equal(fs.readFileSync(req.mcDir+'/versions/Old CF/mods/cf.jar','utf8'),content.toString());
passed('old CF manifest recovery reaches two-official Native spec and final full digest/installed file');
// 已交付实例补齐仍执行原安装/收据链，不重新构建基础版本，也不能丢掉官方别名。
fs.unlinkSync(req.mcDir+'/versions/Old CF/mods/cf.jar');before=downloaded.length;const baseBefore=baseBuilds;
const repaired=await new I.ModpackInstaller().installFromArchive({...req,officialFilesOnly:false});
const repairSpec=downloaded.slice(before).find(value=>value.name.startsWith('modpack-files:'));
assert(repairSpec);assert.deepEqual(plain(repairSpec.files[0].urls),expected);assert.equal(repaired.missing.length,0);
assert.equal(baseBuilds,baseBefore);assert.equal(fs.readFileSync(req.mcDir+'/versions/Old CF/mods/cf.jar','utf8'),content.toString());
passed('installed CF repair retains both official candidates without rebuilding base');
const Compiler=load('feature_core/src/main/ets/download/DownloadManager.ets');
// 前段真实宿主IO用D盘绝对路径；Native规格编译按OHOS绝对根判定，仅映射平台路径。
const nativeInputs=repairSpec.files.map(file=>({...file,localPath:'/sandbox/'+path.basename(file.localPath),allowedRoot:'/sandbox'}));
const compiled=Compiler.compileDownloadFiles(nativeInputs);
assert.deepEqual(plain(compiled[0].urls),expected);assert.deepEqual(plain(compiled[0].check),plain(repairSpec.files[0].check));
assert.equal(compiled[0].maxConnections,repairSpec.files[0].maxConnections);
passed('actual Native spec compiler preserves official candidates, digest, size and connection limit');
const Repository=load('mods/src/main/ets/CurseForgeRepository.ets').CurseForgeRepository;
const repository=new Repository(dm,{},'fixture',()=>true,()=>false,()=>C.CurseForgeFileSourceMode.OFFICIAL_ONLY);
const mapped=repository.buildInfoFromCfFile_({id:7446117,fileName:'GT New Horizons-2.8.4.zip',downloadUrl:edge,fileLength:content.length,
  hashes:[{algo:1,value:digest(content)}]});
assert.deepEqual(plain(mapped.urls),expected);assert.equal(mapped.sha1,digest(content));assert.equal(mapped.size,content.length);
passed('real CF archive repository mapper retains exact metadata identity and official alias');
const ModInstall=load('mods/src/main/ets/ModInstaller.ets');
const updateRaw={id:7446117,modId:252507,fileName:'GT New Horizons-2.8.4.zip',displayName:'CF update',downloadUrl:edge,
  fileLength:content.length,hashes:[{algo:1,value:digest(content)}],gameVersions:['1.20.1','Forge'],releaseType:1,fileDate:'2026-01-11'};
const updateVersion=C.mapCurseForgeFileAsVersion(updateRaw,C.CurseForgeFileSourceMode.OFFICIAL_ONLY);
const updateSpec=ModInstall.buildDownloadSpec(updateVersion.files[0],'/sandbox/mods');
assert.deepEqual(plain(Compiler.compileDownloadFiles([updateSpec])[0].urls),expected);
assert.equal(updateSpec.maxConnections,16);assert.equal(updateSpec.check.sha1,digest(content));
for(const mode of [C.CurseForgeFileSourceMode.MIRROR_FIRST,C.CurseForgeFileSourceMode.OFFICIAL_FIRST]){
 const version=C.mapCurseForgeFileAsVersion(updateRaw,mode),spec=ModInstall.buildDownloadSpec(version.files[0],'/sandbox/mods');
 const mirror=C.mirrorifyCurseForgeCdn(edge);
 assert.deepEqual(plain(spec.urls),mode===C.CurseForgeFileSourceMode.MIRROR_FIRST?[mirror,edge]:[edge,mirror]);assert.equal(spec.maxConnections,16);
}
passed('ordinary CF version/update mapper and actual ModInstaller Native compiler retain official alias and old mode limits');
console.log('CF official alias consumer regression passed: '+cases.length);
`;
let source=original.slice(0,start)+body+original.slice(end);
// 与真实Native/socket case共用400B确定性归档载荷；只改fixture输入，不改产品校验。
source=source.replace("const archiveBytes=Buffer.from('controlled archive bytes');",
  'const archiveBytes=Buffer.from(Array.from({length:400},(_,index)=>(index*31)%251));');
source=source.replace('feature_core:core,commons:common,',"feature_core:core,'@kit.NetworkKit':{http:{RequestMethod:{GET:'GET'}}},commons:common,");
if(process.env.AMCL_CF_ALIAS_OLD_SOURCE_DIR){
  // 作者明确负控：只替换两份精确旧产品模块，其余prepare/session/installer/spec编译正文
  // 仍运行同一源码。原件不回写工作树，首个实际Native规格已在业务断言前输出。
  const legacy=String.raw`
const legacyCache=new Map();
function legacyModule(name){
 if(legacyCache.has(name))return legacyCache.get(name);
 const exports={};legacyCache.set(name,exports);
 const text=fs.readFileSync(path.join(process.env.AMCL_CF_ALIAS_OLD_SOURCE_DIR,name+'.ets'),'utf8');
 vm.runInNewContext(ts.transpileModule(text,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText,
  {exports,require:key=>['./CurseForgeUrls','./ModpackDownloadUrls'].includes(key)?legacyModule(key.slice(2)):coreLoad('mods/src/main/ets/'+key.slice(2)+'.ets')});
 return exports;
}
const legacyOverrides={'./CurseForgeUrls':legacyModule('CurseForgeUrls'),'./ModpackDownloadUrls':legacyModule('ModpackDownloadUrls')};
`;
  source=source.replace('const load=loader({feature_core:core,',legacy+'\nconst load=loader({...legacyOverrides,feature_core:core,');
}
source=source.replace(/from '(\.\/[^']+)'/g,(_all,relative)=>'from '+JSON.stringify(pathToFileURL(path.join(scripts,relative)).href));
const child=spawnSync(process.execPath,['--input-type=module','--eval',source],{cwd:path.dirname(scripts),encoding:'utf8',maxBuffer:4*1024*1024});
process.stdout.write(child.stdout??'');process.stderr.write(child.stderr??'');
if(child.error)throw child.error;
assert.equal(child.status,0,'actual installer consumer business assertions must pass');
