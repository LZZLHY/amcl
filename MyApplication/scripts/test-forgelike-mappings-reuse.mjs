/**
 * 执行生产preDownloadMappings→真实ProcessorRunner的单个官方DOWNLOAD_MOJMAPS步骤。
 * 官方profile/JAR/mappings由显式外部夹具提供；文件和SHA均为真实字节。仅替换Native传输、
 * OHOS解压和JVM入口的平台边界，负控入口真实执行上游Java类并在HTTPS流处受控中断。
 * 不跑手机、不改用户实例、不把这一个步骤的成功称为完整NeoForge安装成功。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { environment } from './lib/ets-runtime-fixture.mjs';
import { cryptoFramework } from './mod-install-test-runtime.mjs';
import { createHostTestScope } from './lib/host-test-lifecycle.mjs';
import { assertExternalOutputPath } from './lib/workspace-paths.mjs';

/** 所有大输入和输出显式外置；JDK只执行已有工具，不安装依赖或改全局环境。 */
function argument(name) { const i=process.argv.indexOf(name); if(i<0||!process.argv[i+1])throw new Error('需要'+name);return path.resolve(process.argv[i+1]); }
const fixtures=argument('--fixture-dir'), output=assertExternalOutputPath(argument('--output-dir')), javaHome=argument('--java-home');
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const profile=JSON.parse(fs.readFileSync(path.join(fixtures,'install_profile.21.1.209.json'),'utf8'));
const version=JSON.parse(fs.readFileSync(path.join(fixtures,'mojang-1.21.1.json'),'utf8'));
const mappingSource=path.join(fixtures,'client-1.21.1-mappings.txt'), mapping=version.downloads.client_mappings;
const sha=target=>createHash('sha1').update(fs.readFileSync(target)).digest('hex');
assert.equal(fs.statSync(mappingSource).size,mapping.size);assert.equal(sha(mappingSource),mapping.sha1);
const processor=profile.processors.find(p=>p.args?.includes('DOWNLOAD_MOJMAPS'));
assert.ok(processor);const smallProfile={...profile,processors:[processor]};
const runnerPath='feature_core/src/main/ets/modloader/ForgelikeProcessorRunner.ets';
const baseline=execFileSync('git',['-C',repo,'show','f92f5b5f5b60003a5b20482dae6f87e0833c12d4:'+runnerPath],{encoding:'utf8'});
fs.mkdirSync(output,{recursive:true});
const scope=createHostTestScope('mappings-reuse-',{parent:output,automatic:false});
const classes=path.join(scope.directory,'classes');fs.mkdirSync(classes);
const dependencies=JSON.parse(fs.readFileSync(path.join(fixtures,'java-duplicate-probe.json'),'utf8')).dependencies;
const classpath=dependencies.map(d=>d.path).join(path.delimiter);
for(const dependency of dependencies)assert.equal(sha(dependency.path),dependency.sha1);

// Java只替换URL流边界，不改上游DownloadMojmaps。参数仍来自生产Runner实际解析结果。
const javaSource=`import java.io.*;import java.net.*;import java.util.*;import net.neoforged.installertools.DownloadMojmaps;
/** 真实上游处理器的受控网络边界；任何新请求以固定非零状态返回，不能伪装安装成功。 */
public class MojmapsNetworkBoundary {
 public static void main(String[] args)throws Exception {
  URL.setURLStreamHandlerFactory(p->"https".equals(p)?new URLStreamHandler(){protected URLConnection openConnection(URL u){return new URLConnection(u){public void connect(){}public InputStream getInputStream()throws IOException{System.out.println("UPSTREAM_NETWORK "+u);throw new IOException("CONTROLLED_NETWORK_STOP");}};}}:null);
  if(args.length<2||!args[0].equals("--task")||!args[1].equals("DOWNLOAD_MOJMAPS"))throw new IllegalArgumentException("unexpected task");
  try{new DownloadMojmaps().process(Arrays.copyOfRange(args,2,args.length));}catch(IOException e){if(e.getMessage().equals("CONTROLLED_NETWORK_STOP"))System.exit(17);throw e;}
 }
}`;
const javaFile=path.join(scope.directory,'MojmapsNetworkBoundary.java');fs.writeFileSync(javaFile,javaSource);
execFileSync(path.join(javaHome,'bin','javac.exe'),['-encoding','UTF-8','-cp',classpath,'-d',classes,javaFile]);
const cases=[];
const io={OpenMode:{READ_ONLY:0},statSync:fs.statSync,lstatSync:fs.lstatSync,readTextSync:p=>fs.readFileSync(p,'utf8'),
 mkdirSync:p=>fs.mkdirSync(p,{recursive:true}),listFileSync:fs.readdirSync,
 openSync:p=>({fd:fs.openSync(p,'r')}),closeSync:f=>fs.closeSync(typeof f==='number'?f:f.fd),
 readSync:(fd,b,o={})=>fs.readSync(fd,Buffer.from(b),0,o.length??b.byteLength,o.offset??null)};

/** 每case独立真实文件及模块状态；传输边界验证生产强check后复制真实官方mappings。 */
function harness(name,{old=false,unfinished=false,failNative=false,processorJar,alterJar=false}={}) {
 // 用短目录名避免Windows归档解压路径上限；完整语义名称只进入收据，不改变被测业务。
 const root=path.join(scope.directory,'c'+cases.length).replaceAll('\\','/'),lib=root+'/libraries';fs.mkdirSync(lib,{recursive:true});
 const currentProcessor={...processor,jar:processorJar??processor.jar};
 const profilePath=root+'/install_profile.json';fs.writeFileSync(profilePath,JSON.stringify({...smallProfile,processors:[currentProcessor]}));
 const nativeCalls=[],specs=[];let releases=0,releaseGate;
 const releasePromise=new Promise(resolve=>{releaseGate=resolve;});
 const manager={async fetchText(url){return url.includes('version_manifest')?JSON.stringify({versions:[{id:'1.21.1',url:'https://piston-meta.mojang.com/fixture/1.21.1.json'}]}):JSON.stringify(version);},
  async createAndWait(spec,callback){
   specs.push(spec);const file=spec.files[0];assert.deepEqual(file.check,{sha1:mapping.sha1,size:mapping.size});assert.equal(file.allowedRoot,lib);
   if(failNative)throw new Error('Native transfer failed');
   fs.mkdirSync(path.dirname(file.localPath),{recursive:true});fs.copyFileSync(mappingSource,file.localPath);
   assert.equal(sha(file.localPath),file.check.sha1);const view={taskId:7001,finished:!unfinished,aborted:false};callback?.(view);return view;
  },async awaitTaskReleased(){releases++;await releasePromise;},cancel(){throw new Error('unexpected cancel');}};
 const bridge={async runJavaProcessor(_files,_jdk,_xmx,cp,main,args){
  assert.ok(cp.includes('installertools-2.1.2.jar'));assert.equal(main,'net.neoforged.installertools.ConsoleTool');
  const task=args[args.indexOf('--task')+1];
  if(task!=='DOWNLOAD_MOJMAPS'){nativeCalls.push({main,args,nonMapping:true});return 17;}
  const run=spawnSync(path.join(javaHome,'bin','java.exe'),['-cp',classes+path.delimiter+classpath,'MojmapsNetworkBoundary',...args],{encoding:'utf8',timeout:15000});
  nativeCalls.push({main,args,exitCode:run.status,stdout:run.stdout,stderr:run.stderr});assert.equal(run.status,17);assert.match(run.stdout,/UPSTREAM_NETWORK/);return run.status;
 }};
 const load=environment({commons:{BMCLAPI_BASE:'https://bmclapi2.bangbang93.com',BMCLAPI_HOST:'bmclapi2.bangbang93.com',MOJANG_META:'https://piston-meta.mojang.com',LogTags:{MOD_FORGE_INSTALLER:'ForgeInstallerUtils',MOD_MAVEN:'MavenUtils'},LOG_DOMAIN_MODLOADER:0,
  formatError:e=>e?.message??String(e),DiagnosticPolicy:{isDeveloperBuild:()=>false},
  fileExistsAndNonEmpty:p=>{try{return fs.statSync(p).size>0;}catch{return false;}},removeDirRecursive:p=>fs.rmSync(p,{recursive:true,force:true})},
  imports:{'@kit.CoreFileKit':{fileIo:io},'@kit.CryptoArchitectureKit':{cryptoFramework},'@kit.NetworkKit':{http:{}},
   '@kit.BasicServicesKit':{zlib:{decompressFile(zip,target,callback){try{
    execFileSync('python',['-c','import sys,zipfile;zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])',zip,target]);callback(undefined);
   }catch(error){callback(error);}}}},
   '../download/DownloadManager':{DownloadManager:{instance:()=>manager}},
   // 此套件只控制公开metadata输入；三模式与allowRelay断言由实际SourceProber矩阵执行。
   '../download/SourceProber':{buildSortedUrls:(...urls)=>[...new Set(urls)],selectMcSourceUrls:urls=>urls,
    fetchPublicMcMetadata:urls=>manager.fetchText(urls[0]),useOrderedMcDownload:()=>false},
   './MavenSpecBuilder':{},'./ForgelikeNative':{forgeNative:()=>bridge}},
  sourceOverrides:old?{[runnerPath]:()=>baseline}:{}}).load;
 const utils=load('feature_core/src/main/ets/modloader/ForgeInstallerUtils.ets');
 const maven=load('feature_core/src/main/ets/modloader/MavenUtils.ets');
 const relative=maven.mavenToRelativePath(profile.data.MOJMAPS.client.slice(1,-1));
 const target=lib+'/'+relative;
 const ownJar=lib+'/'+maven.mavenToRelativePath(currentProcessor.jar);fs.mkdirSync(path.dirname(ownJar),{recursive:true});
 const jar=dependencies.find(d=>d.name==='net.neoforged.installertools:installertools:2.1.2');fs.copyFileSync(jar.path,ownJar);
 // 同坐标但不同内容仍是合法ZIP，必须由真实工件SHA拒绝复用，不能靠解压失败制造负例。
 if(alterJar)execFileSync('python',['-c','import sys,zipfile;z=zipfile.ZipFile(sys.argv[1],"a");z.writestr("custom-implementation-marker.txt","custom variant");z.close()',ownJar]);
 const runner=load(runnerPath).ForgelikeProcessorRunner;
 return{root,lib,target,specs,nativeCalls,get releases(){return releases;},release:releaseGate,
  prefetch:()=>utils.preDownloadMappings(profilePath,'1.21.1',lib),
  run:(proof,callback)=>runner.run(profilePath,root,root,lib,root,'1.21.1','21',1024,'NeoForge',callback,proof)};
}

/** 等待真实模块到达释放屏障，不用sleep或伪造成功证据；该Promise结束后才允许消费proof。 */
async function prefetch(h) {let returned=false;const pending=h.prefetch().then(v=>{returned=true;return v;});for(let i=0;i<8;i++)await Promise.resolve();assert.equal(h.releases,1);assert.equal(returned,false);h.release();return pending;}
async function check(name,options,change,expectSkip) {
 const h=harness(name,options);let proof=await prefetch(h);if(change)proof=await change(h,proof);
 const result=await h.run(proof);assert.equal(h.nativeCalls.length,expectSkip?0:1);
 if(expectSkip){assert.equal(result.success,true);assert.equal(result.ranCount,0);assert.equal(sha(h.target),mapping.sha1);}
 else assert.equal(result.success,false);
 cases.push({name,expectedSkip:expectSkip,result,nativeCalls:h.nativeCalls,specs:h.specs});console.log('PASS '+name);
}
let success=false;
try {
 // 组合宿主仍须保留取消契约。复用不创建JVM，但fresh检查之后的进度回调抛错
 // 必须中止该步骤；不能因“无需启动processor”把已到达的取消误报为安装成功。
 const cancelled=harness('cancel-after-fresh-mapping-hash',{});
 const fresh=await prefetch(cancelled);let progressChecks=0;
 const cancelledResult=await cancelled.run(fresh,()=>{if(++progressChecks===3)throw new Error('CANCEL_AFTER_MAPPING_HASH');});
 assert.equal(progressChecks,3);assert.equal(cancelledResult.success,false);assert.match(cancelledResult.error,/CANCEL_AFTER_MAPPING_HASH/);assert.equal(cancelled.nativeCalls.length,0);
 cases.push({name:'cancel-after-fresh-mapping-hash',result:cancelledResult,nativeCalls:cancelled.nativeCalls});console.log('PASS cancel-after-fresh-mapping-hash');
 await check('fixed-git-runner-redownloads-native-verified-file',{old:true},undefined,false);
 await check('current-fresh-native-success-skips-only-network-processor',{},undefined,true);
 await check('no-proof-keeps-original-upstream-execution',{},()=>undefined,false);
 await check('unfinished-native-task-cannot-publish-proof',{unfinished:true},undefined,false);
 await check('missing-mappings-keeps-original-upstream-execution',{},(h,p)=>{fs.unlinkSync(h.target);return p;},false);
 await check('same-size-corruption-keeps-original-upstream-execution',{},(h,p)=>{const b=fs.readFileSync(h.target);b[0]^=1;fs.writeFileSync(h.target,b);return p;},false);
 await check('another-owner-proof-is-rejected',{},(_h,p)=>({...p,libraryDir:p.libraryDir+'-other-owner'}),false);
 await check('another-version-proof-is-rejected',{},(_h,p)=>({...p,gameVersion:'1.20.1'}),false);
 await check('another-output-proof-is-rejected',{},(_h,p)=>({...p,path:p.path+'.other'}),false);
 await check('custom-processor-with-same-task-is-not-skipped',{processorJar:'org.example:custom-tool:2.1.2'},undefined,false);
 await check('unverified-future-version-is-not-skipped',{processorJar:'net.neoforged.installertools:installertools:2.1.3'},undefined,false);
 await check('same-coordinate-different-jar-content-is-not-skipped',{alterJar:true},undefined,false);
 const failed=harness('failed-native-transfer',{failNative:true});await assert.rejects(failed.prefetch(),/Native transfer failed/);assert.equal(failed.releases,0);console.log('PASS failed-native-transfer-has-no-proof');cases.push({name:'failed-native-transfer-has-no-proof'});
 fs.writeFileSync(path.join(output,'mappings-reuse-result.json'),JSON.stringify({status:'passed',recordedAt:new Date().toISOString(),mapping,caseCount:cases.length,cases,limits:'真实生产Utils/Runner与真实上游Java，Native传输及OHOS解压/JVM为显式宿主边界；不替代手机/SDK'},null,2));success=true;
} finally {await scope.close({success});}
