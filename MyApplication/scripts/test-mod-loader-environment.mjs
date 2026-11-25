/**
 * 安装环境回归：生产解析器读取真实 NeoForge 清单，保留加载器类型/MC、继承与快照回退。
 * 已退役的具体加载器版本推断不再执行；缺少该信息不应妨碍来源 API 的明确选版。
 * 文件 IO 使用受控内存文件，断言越界父目录不会被读取；不访问真机或修改用户版本。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import crypto from 'node:crypto';
import { loader, productionPathPolicy, root, ts } from './mod-install-test-runtime.mjs';

const files = new Map();
const reads = [];
const io = { lstatSync(p) {
  if(files.has(p)) return {isFile:()=>true,isDirectory:()=>false,isSymbolicLink:()=>false,size:files.get(p).length};
  if([...files.keys()].some(key=>key.startsWith(p+'/')))return {isFile:()=>false,isDirectory:()=>true,isSymbolicLink:()=>false};
  throw Error('missing'); },readTextSync(p) { reads.push(p); if (!files.has(p)) throw new Error('ENOENT'); return files.get(p); } };
const logs = { info(){},warn(){},error(){},debug(){} };
const common = { AppLogger: logs, formatError: String, LOG_DOMAIN_DOWNLOAD: 0 };
const policy = productionPathPolicy();
const parser = loader({'@kit.CoreFileKit':{fileIo:io},commons:common,'../modloader/MavenUtils':policy})('feature_core/src/main/ets/version/VersionParser.ets').VersionParser;
const load = loader({'@kit.CoreFileKit':{fileIo:io},commons:common,
  feature_core:{...policy,VersionParser:parser,McEra:{UNKNOWN:'unknown'},detectMcEra:()=> 'unknown'}});
const installed = load('mods/src/main/ets/InstalledLoaderResolver.ets');
const versionIds = load('mods/src/main/ets/VersionIdUtils.ets');
const catalog = loader({ commons: { AppIconName: {} }, mods: { ...installed, ...versionIds } },
  { $r: id => id })('entry/src/main/ets/components/LoaderCatalog.ets');
const actual = JSON.parse(fs.readFileSync(path.join(root,'scripts/fixtures/mod-install/neoforge-26.2.version.json'),'utf8').replace(/^\uFEFF/,''));

/** 在相同产品目录模型中建立有中文名的继承版本；目录名不包含 loader 版本。 */
const put=(id,value)=>files.set('/mc/versions/'+id+'/'+id+'.json',JSON.stringify(value));
put('父实例',actual); put('自定义整合包',{id:'自定义整合包',inheritsFrom:'父实例'});
assert.equal(installed.resolveInstalledLoader('/mc','自定义整合包'),'neoforge');
assert.equal(installed.resolveInstalledMcVersion('/mc','自定义整合包'),'26.2');
put('quilt-instance',{id:'quilt-instance',clientVersion:'1.21.1',mainClass:'org.quiltmc.loader.impl.launch.knot.KnotClient',
  libraries:[{name:'org.quiltmc:quilt-loader:0.29.2'}]});
assert.equal(installed.resolveInstalledLoader('/mc','quilt-instance'),'quilt','Quilt 的 KnotClient 不可被通用 Knot 分支误认成 Fabric');
put('loop-a',{inheritsFrom:'loop-b'});put('loop-b',{inheritsFrom:'loop-a'});
assert.equal(installed.resolveInstalledLoader('/mc','loop-a'),'');
assert.equal(installed.resolveInstalledMcVersion('/mc','loop-a'),'');
put('escape',{inheritsFrom:'../../outside'});reads.length=0;
assert.equal(installed.resolveInstalledLoader('/mc','escape'),'');
installed.resolveInstalledMcVersion('/mc','escape');
assert.ok(reads.every(p=>!p.includes('..')));
// 实际选版只依赖 loader 类型和游戏版本；各家 mainClass 必须继续被准确区分。
for (const [type,mainClass,coordinate] of [
  ['fabric','net.fabricmc.loader.impl.launch.knot.KnotClient','net.fabricmc:fabric-loader:0.19.5'],
  ['forge','cpw.mods.bootstraplauncher.BootstrapLauncher','net.minecraftforge:forge:1.20.1-47.4.0'],
  ['neoforge','net.neoforged.fml.startup.Client','net.neoforged:neoforge:21.1.209'],
  ['quilt','org.quiltmc.loader.impl.launch.knot.KnotClient','org.quiltmc:quilt-loader:0.29.2'],
]) {
  const name = '实例-' + coordinate.split(':').at(-1);
  put(name,{id:name,clientVersion:'1.20.1',mainClass,libraries:[{name:coordinate}]});
  assert.equal(installed.resolveInstalledLoader('/mc',name),type);
  assert.equal(installed.resolveInstalledMcVersion('/mc',name),'1.20.1');
  assert.equal(catalog.resolveInstalledVersionCategory('/mc',name),type);
}

// 已装显示保留官方子类，资源搜索仍沿用精简游戏版本，碰巧含加载器字样的实例名不参与判断。
put('forge-仅是昵称',{id:'forge-仅是昵称',clientVersion:'26.2-rc-2',mainClass:'net.minecraft.client.main.Main'});
assert.equal(installed.resolveInstalledMcVersion('/mc','forge-仅是昵称'),'26.2');
assert.equal(installed.resolveInstalledGameId('/mc','forge-仅是昵称'),'26.2-rc-2');
assert.equal(catalog.resolveInstalledVersionCategory('/mc','forge-仅是昵称'),'snapshot');
assert.equal(catalog.getInstalledBadgeInfoResolved('/mc','forge-仅是昵称').displayName,'快照');
put('改名的愚人节',{id:'改名的愚人节',clientVersion:'24w14potato',mainClass:'net.minecraft.client.main.Main'});
assert.equal(catalog.resolveInstalledVersionCategory('/mc','改名的愚人节'),'aprilfools');
put('AMCL-QA-Create-Fly-26.2',{id:'AMCL-QA-Create-Fly-26.2',clientVersion:'26.2',
  mainClass:'net.fabricmc.loader.impl.launch.knot.KnotClient'});
files.set('/external/versions/AMCL-QA-Create-Fly-26.2/AMCL-QA-Create-Fly-26.2.json',
  JSON.stringify({clientVersion:'26.2',mainClass:'net.minecraft.client.main.Main'}));
assert.equal(catalog.resolveInstalledVersionCategory('/external','AMCL-QA-Create-Fly-26.2'),'release');
assert.equal(catalog.resolveInstalledVersionCategory('/mc','AMCL-QA-Create-Fly-26.2'),'fabric');
assert.equal(catalog.getMediaForVersion('AMCL-QA-Create-Fly-26.2','fabric'),'app.media.loader_fabric');
assert.equal(catalog.getMediaForVersion('forge-仅是昵称','snapshot'),'app.media.block_command');

// 直接执行生产环境函数：旧实例缺少具体 loader 版本时仍保留类型/MC，允许明确匹配的安装计划。
const sourceFile=path.join(root,'mods/src/main/ets/ModInstallService.ets');
const source=ts.createSourceFile(sourceFile,fs.readFileSync(sourceFile,'utf8'),ts.ScriptTarget.Latest,true,ts.ScriptKind.TS);
const fn=source.statements.find(n=>ts.isFunctionDeclaration(n)&&n.name?.text==='installedModEnvironment');
const exports={};
vm.runInNewContext(ts.transpileModule(fn.getText(source),{compilerOptions:{module:ts.ModuleKind.CommonJS}}).outputText,
  {exports,...installed});
assert.equal(exports.installedModEnvironment('/mc','自定义整合包').loader,'neoforge');
assert.equal(exports.installedModEnvironment('/mc','自定义整合包').gameVersion,'26.2');
put('missing-version',{mainClass:'net.fabricmc.loader.impl.launch.knot.KnotClient',id:'26.2',libraries:[]});
const missingVersion = exports.installedModEnvironment('/mc','missing-version');
assert.equal(missingVersion.loader,'fabric');
assert.equal(missingVersion.gameVersion,'26.2');
assert.deepEqual(Object.keys(missingVersion).sort(),['gameVersion','loader']);
console.log('PASS: actual NeoForge JSON, four loader families, renamed inheritance, cycles, traversal and no unused loader-version admission');

// 安装身份查询只取声明的基础版本与加载器 Maven 身份；对名为合法版本号的别名同样拒绝猜测。
put('1.20.4',{id:'1.20.4',mainClass:'net.minecraft.client.main.Main'});
assert.equal(installed.inspectInstalledVersion('/mc','1.20.4'),null);
put('alias',{id:'alias',clientVersion:'1.21-pre1',mainClass:'net.fabricmc.loader.impl.launch.knot.KnotClient',
 libraries:[{name:'net.fabricmc:fabric-loader:0.16.10'}]});
const alias=installed.inspectInstalledVersion('/mc','alias');assert.equal(alias.gameVersion,'1.21-pre1');
assert.equal(alias.loader,'fabric');assert.equal(alias.loaderVersion,'0.16.10');
put('child',{id:'display-name',inheritsFrom:'alias'});
assert.equal(installed.inspectInstalledVersion('/mc','child').loaderVersion,'0.16.10');
put('1.21.4',{id:'1.21.4',clientVersion:'1.20.1',mainClass:'net.minecraft.client.main.Main'});
assert.equal(installed.inspectInstalledVersion('/mc','1.21.4').gameVersion,'1.20.1');
assert.equal(installed.inspectInstalledVersion('/mc','loop-a'),null);


// 无 clientVersion 的旧原版独立使用真实产品校验路径。固定公开摘要/长度取自平板 1.12.2，
// 平台文件摘要边界默认受控，显式回放时使用设备 sha1sum 与官方已验的原始 JSON。
const evidenceRoot = process.argv[2];
const releasedJar='0f275bc1547d01fa5f56ba34bdc87d981ee12daf';
const sha1=value=>crypto.createHash('sha1').update(value).digest('hex');
const fixed={id:'1.12.2',mainClass:'net.minecraft.client.main.Main',downloads:{client:{size:10180113,sha1:releasedJar}},
  libraries:[{name:'org.lwjgl.lwjgl:lwjgl:2.9.4-nightly-20150209'}],minecraftArguments:'--gameDir ${game_directory}'};
const original=evidenceRoot?fs.readFileSync(path.join(evidenceRoot,'official-vanilla-identity/1.12.2.json'),'utf8'):JSON.stringify(fixed);
const localTxt=evidenceRoot?fs.readFileSync(path.join(evidenceRoot,'vanilla-1.12.2.json'),'utf8'):JSON.stringify(fixed,null,2);
const game=JSON.parse(localTxt);
const remoteMetaHash=sha1(original);
if(evidenceRoot)assert.equal(remoteMetaHash,JSON.parse(fs.readFileSync(path.join(evidenceRoot,'official-vanilla-identity/official-entry.json'),'utf8')).sha1);
assert.equal(game.downloads.client.sha1,releasedJar);
let actualJar=evidenceRoot?fs.readFileSync(path.join(evidenceRoot,'vanilla-1.12.2-jar.sha1'),'utf8').trim().match(/[a-fA-F0-9]{40}/)[0]:releasedJar;
assert.equal(actualJar,releasedJar);
const rawUrl='https://piston-meta.mojang.com/v1/packages/'+remoteMetaHash+'/1.12.2.json';
let digestCalls=0, network=0, touched=1, cacheBody=original, netBody=original, jarSize=game.downloads.client.size, available=true, wrongHost=false;
const api=loader({'@kit.CryptoArchitectureKit':{cryptoFramework:{createMd(alg){assert.equal(alg,'SHA1');const hash=crypto.createHash('sha1');
  return {updateSync(blob){hash.update(blob.data);},digestSync(){return {data:hash.digest()};}};}}},
  '@kit.ArkTS':{util:{TextEncoder:class{encodeInto(text){return new TextEncoder().encode(text);}}}},
  '../download/DownloadManager':{DownloadManager:{instance:()=>({async fetchTextEx(url){network++;assert.equal(url,rawUrl);return {statusCode:200,body:netBody};}})}},
  '../download/SourceProber':{canRelayPublicMcMetadata:()=>false},'../modloader/MavenUtils':policy,
  './MetadataCacheStore':{getMetadataCacheStore:()=>({isReady:()=>true,get:()=>cacheBody,put(_u,b){cacheBody=b;}})},
  './McVersionManifest':{officialVersionEntry:async id=>!available||id!=='1.12.2'?null:{id,sha1:remoteMetaHash,url:wrongHost?'https://example.org/1.12.2.json':rawUrl}}})('feature_core/src/main/ets/version/OfficialVersionMetadata.ets');
const oldIo={...io,lstatSync(p){if(p.endsWith('.jar')) return {isFile:()=>true,isSymbolicLink:()=>false,size:jarSize,ino:3,mtime:touched,ctime:touched};return io.lstatSync(p);}};
let beforeDigestReturn=async()=>{};
const fileHash={async hash(file,algorithm){
  assert(file.endsWith('.jar'));assert.equal(algorithm,'sha1');digestCalls++;
  await beforeDigestReturn();
  return actualJar.toUpperCase();
}};
const {inspectLegacyVanilla}=loader({'@kit.CoreFileKit':{fileIo:oldIo,hash:fileHash},commons:common,
 feature_core:{...policy,VersionParser:parser,verifiedVanillaMetadata:api.verifiedVanillaMetadata,
   McEra:{UNKNOWN:'unknown'},detectMcEra:()=> 'unknown'}})('mods/src/main/ets/InstalledLoaderResolver.ets');
files.set('/mc/versions/1.12.2/1.12.2.json',localTxt);
assert.equal((await inspectLegacyVanilla('/mc','1.12.2')).gameVersion,'1.12.2');assert.equal(network,0);
put('renamed',{...game,id:'renamed'});assert.equal(await inspectLegacyVanilla('/mc','renamed'),null);
assert.equal((await inspectLegacyVanilla('/mc','renamed','1.12.2')).loader,'vanilla');
assert.equal(await inspectLegacyVanilla('/mc','renamed','1.12.1'),null);
put('1.12.2',{...game,mainClass:'custom.forged.Main'});assert.equal(await inspectLegacyVanilla('/mc','1.12.2'),null);
put('1.12.2',{...game,extraLauncherField:true});assert.equal(await inspectLegacyVanilla('/mc','1.12.2'),null);
put('1.12.2',{...game,downloads:{...game.downloads,client:{...game.downloads.client,sha1:'0'.repeat(40)}}});
assert.equal(await inspectLegacyVanilla('/mc','1.12.2'),null);
files.set('/mc/versions/1.12.2/1.12.2.json',localTxt);
jarSize++;assert.equal(await inspectLegacyVanilla('/mc','1.12.2'),null);jarSize--;
actualJar='1'.repeat(40);assert.equal(await inspectLegacyVanilla('/mc','1.12.2'),null);actualJar=releasedJar;
available=false;assert.equal(await inspectLegacyVanilla('/mc','1.12.2'),null);available=true;
wrongHost=true;assert.equal(await inspectLegacyVanilla('/mc','1.12.2'),null);wrongHost=false;
cacheBody='{}';netBody='{}';assert.equal(await inspectLegacyVanilla('/mc','1.12.2'),null);
cacheBody=null;netBody=original;assert.equal((await inspectLegacyVanilla('/mc','1.12.2')).gameVersion,'1.12.2');assert.equal(network,2);
// 哈希未完成时页面事件循环仍可前进，文件在等待中被替换或文件服务读取失败均须拒绝身份。
let releaseDigest,announceDigest;
const arrival=new Promise(resolve=>{announceDigest=resolve;});
const wait=new Promise(resolve=>{releaseDigest=resolve;});
beforeDigestReturn=()=>{announceDigest();return wait;};
const pending=inspectLegacyVanilla('/mc','1.12.2');
await arrival;
await new Promise(resolve=>setImmediate(resolve));
touched++;
releaseDigest();
assert.equal(await pending,null);
beforeDigestReturn=async()=>{throw new Error('file service read failed');};
assert.equal(await inspectLegacyVanilla('/mc','1.12.2'),null);
assert(digestCalls>=6);
console.log('PASS legacy vanilla: authoritative JSON, renamed copy, origin/digest/size/JAR failures, cold cache, payload field substitution'+(evidenceRoot?', replayed tablet metadata and recorded device client digest':''));
