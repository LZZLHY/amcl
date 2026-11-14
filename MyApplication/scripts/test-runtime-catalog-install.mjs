/**
 * 生产安装器的目录下载/发布闭环：网络与解压作为 I/O 边界注入，生产 SHA-256 分块计算、
 * 来源过滤、分卷合并、receipt 和回滚代码均真正执行。ELF/ZIP 内容验证由独立套件覆盖。
 */
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {makePureEtsLoader} from './lib/load-pure-ets.mjs';
const data=Buffer.from('PK-runtime-catalog-fixture'),hash=b=>createHash('sha256').update(b).digest('hex');
let files,dirs,handles,requests,mode,leases,withdrawn,cancelHook,nativeOwners,unsafeCleanup,ownerRelease,gateway,probeCalls,originWins;
function reset(){files=new Map([['/app/jdk/17/valid',Buffer.from('old')]]);dirs=new Set(['/app/jdk/17']);handles=new Map();requests=[];mode='';leases=0;withdrawn=false;cancelHook=null;nativeOwners=new Map();unsafeCleanup=[];ownerRelease=null;gateway=false;probeCalls=[];originWins=false;}
/** 原生终态与执行收敛分开建模；有活跃写者时清理目录/分卷必须被用例记录。 */
function recordCleanup(path){for(const owner of nativeOwners.values())if(!owner.settled&&(owner.path===path||owner.path.startsWith(path+'/')))unsafeCleanup.push(path);}
function remove(path){recordCleanup(path);for(const p of [...files.keys()])if(p===path||p.startsWith(path+'/'))files.delete(p);for(const p of [...dirs])if(p===path||p.startsWith(path+'/'))dirs.delete(p);}
function ensure(path){for(let p=path;p&&p!=='/';p=p.slice(0,p.lastIndexOf('/')))dirs.add(p);}
const io={OpenMode:{CREATE:1,WRITE_ONLY:2,TRUNC:4,READ_ONLY:0},
  statSync:p=>{if(files.has(p))return{ino:1,size:files.get(p).length,isFile:()=>true,isDirectory:()=>false};if(dirs.has(p))return{ino:1,size:0,isFile:()=>false,isDirectory:()=>true};throw Error('ENOENT');},
  listFileSync:p=>[...new Set([...files.keys(),...dirs].filter(x=>x.startsWith(p+'/')).map(x=>x.slice(p.length+1).split('/')[0]))],
  readTextSync:p=>{if(!files.has(p))throw Error('ENOENT');return files.get(p).toString();},
  openSync:(p,flags)=>{if(!flags&&!files.has(p)&&!dirs.has(p))throw Error('ENOENT');if(flags&4)files.set(p,Buffer.alloc(0));const fd=Symbol(p);handles.set(fd,{p,offset:0});return{fd};},
  readSync:(fd,buffer)=>{const h=handles.get(fd),f=files.get(h.p);const size=Math.min(buffer.byteLength,f.length-h.offset);new Uint8Array(buffer).set(f.subarray(h.offset,h.offset+size));h.offset+=size;return size;},
  writeSync:(fd,value,options)=>{const h=handles.get(fd);if(mode==='receipt'&&h.p.endsWith('receipt.json'))throw Error('receipt write failure');const b=typeof value==='string'?Buffer.from(value):Buffer.from(value).subarray(0,options?.length??value.byteLength);files.set(h.p,Buffer.concat([files.get(h.p)||Buffer.alloc(0),b]));return b.length;},
  fsyncSync:()=>{},closeSync:f=>handles.delete(f.fd??f),unlinkSync:p=>{recordCleanup(p);return files.delete(p);},
  renameSync:(a,b)=>{if(files.has(a)){files.set(b,files.get(a));files.delete(a);return;}if(mode==='rename'&&a.includes('.staging-')&&b==='/app/jdk/17'){mode='';throw Error('rename failure');}
    if(!dirs.has(a))throw Error('missing source dir');for(const p of [...files.keys()])if(p.startsWith(a+'/')){files.set(b+p.slice(a.length),files.get(p));files.delete(p);}for(const p of [...dirs])if(p===a||p.startsWith(a+'/')){dirs.add(b+p.slice(a.length));dirs.delete(p);}}
};
class Logger{constructor(id){this.activity=id;}id(){return this.activity;}info(){}warn(){}error(){}debug(){}}
const downloadManager={initializeCaBundle:()=>{},purgeTask:id=>{
    const owner=nativeOwners.get(id);if(owner&&!owner.settled)return false;nativeOwners.delete(id);return true;
  },cancel:()=>{},
  /** Native测量是平台边界；组级竞速/取消/完整SHA和落地仍执行生产代码。 */
  async probeTransfer(url,size,sample,timeout,_ua,current){assert.equal(sample,262144);assert.equal(timeout,5);assert.equal(current(),true);probeCalls.push(url);
    if(mode==='probe-cancel'||mode==='probe-switch')cancelHook?.();
    return {httpStatus:206,receivedBytes:Math.min(size,sample),elapsedMs:url.includes('gitee.com')?(originWins?1000:10):(originWins?1:100),
      ttfbMs:1,completedSample:true,rangeHonored:true,errorKind:''};},
  /** 只控制Native平台释放事实，生产业务的等待位置/来源回退/目录事务不在此复制。 */
  async awaitTaskReleased(id,retainOwner){assert.equal(retainOwner,true);if(ownerRelease)await ownerRelease.promise;
    while(!downloadManager.purgeTask(id))await new Promise(resolve=>setTimeout(resolve,5));},
  createAndWait:async(spec,progress)=>{const file=spec.files[0],url=file.urls[0];requests.push(url);
    if(mode==='source-switch-on-failure'&&url.startsWith('https://gitee.com/')){gateway=true;throw Error('first group failed after gateway enabled');}
    if(mode==='source-switch-on-failure'&&url.startsWith('https://github.com/'))throw Error('origin group unavailable');
    if(mode==='settling-parts'&&[...nativeOwners.values()].some(owner=>owner.path===file.localPath))throw Error('native path still owned');
    let body=url.endsWith('part1')?data.subarray(0,8):url.endsWith('part2')?data.subarray(8):data;
    if(mode==='part'&&url.endsWith('part2'))body=Buffer.alloc(body.length);
    if(mode==='settling-parts'&&url==='https://gitee.com/part2')body=Buffer.alloc(body.length);
    if(mode==='hash')body=Buffer.alloc(body.length);
    if(mode==='cache-corrupt'&&url.startsWith('https://amcl.lovedhy.cn/runtimes/packages/'))body=Buffer.alloc(body.length);
    const taskId=requests.length;
    if(['settling-parts','settling-cancel','settling-timeout'].includes(mode)){
      const owner={path:file.localPath,settled:false};nativeOwners.set(taskId,owner);
      // createAndWait 已返回逻辑终态，但 curl/worker 仍短暂持有原路径。purge 是唯一释放证明。
      if(mode!=='settling-timeout')setTimeout(()=>{files.set(owner.path,body);owner.settled=true;},20);
    }
    files.set(file.localPath,body);progress({taskId:requests.length,bytesDone:body.length,speedBps:1024});cancelHook?.();
    return{taskId:requests.length,bytesDone:body.length,finished:true};}};
const load=makePureEtsLoader({
  // 本套只隔离安装事务/网络；新的行为准入由test-runtime-compatibility使用实际App要求独立覆盖。
  './RuntimeHostProtocol':{runtimeHostProtocols:()=>[1,2],runtimeRequiredCapabilities:()=>[]},
  '@kit.CoreFileKit':{fileIo:io},'@kit.CryptoArchitectureKit':{cryptoFramework:{createMd:()=>{const h=createHash('sha256');return{updateSync:b=>h.update(b.data),digestSync:()=>({data:new Uint8Array(h.digest())})};}}},
  './JdkManager':{getJdkDownloadSource:()=> 'github',MIRROR_TEMPLATES:['https://proxy.example/{url}','{url}'],RELEASE_BASE_URL:'https://github.com/fixture/releases/download'},
  './RuntimeCatalogRepository':{RuntimeCatalogRepository:{instance:()=>({isBuildAllowed:()=>!withdrawn&&mode!=='rollback'})}},
  './JdkTreeValidation':{validateRuntimeTree:root=>files.has(root+'/valid')?'':'bad fixture'},
  './JdkDirectoryLease':{JdkDirectoryLease:{writer:()=>{leases++;return{descriptor:()=>10,release:()=>leases--};},publication:()=>{if(mode==='busy')throw Error('JDK 正在使用');leases++;return{descriptor:()=>11,release:()=>leases--};}}},
  commons:{removeDirRecursive:remove,ensureDirSync:ensure,ActivityLogger:Logger,stringToUtf8:value=>new Uint8Array(Buffer.from(value)),isJdkSlotVersion:v=>/^[1-9][0-9]{0,2}$/.test(v)&&Number(v)>=8},
  feature_core:{DownloadManager:{instance:()=>downloadManager},getRelayClient:()=>({isEnabled:()=>gateway}),formatBytes:String,formatSpeed:String,
    safeBaseName:p=>/^[a-zA-Z0-9._-]+$/.test(p)&&!p.includes('..')?p:'',safeRelPath:p=>p.includes('..')?'':p,
    decompressFile:async(_zip,root)=>{ensure(root);files.set(root+'/valid',Buffer.from('new'));if(mode==='publication-cancel'||mode==='publication-withdraw'){for(let i=0;i<64;i++)files.set(root+'/fill'+i,Buffer.from('fixture'));setTimeout(()=>{if(mode==='publication-withdraw')withdrawn=true;else cancelHook?.();},0);}}}
});
io.lstatSync=io.statSync;
// 本测试只替代 native I/O 边界；生产 ArkTS 的锁顺序、封存等待、最终撤回检查和 cleanup
// 仍真实执行。native journal/ZIP 实现由 runtime-install 的 fork + POSIX 套件独立验证。
load('launch/src/main/ets/JdkInstallStorage.ets').setJdkInstallNativeOps({
  operation(action,filesDir,major,stage,writer,use) {
    if(action==='pending')return 'no';
    if(action==='collect')return '';
    if(action==='create'){assert.equal(writer,10);const path=filesDir+'/jdk/.staging-'+major+'-native';ensure(path);return path;}
    if(action==='discard'){assert.equal(writer,10);remove(stage);return '';}
    if(action==='publish'){assert.equal(writer,10);assert.equal(use,11);
      if(mode==='rename')throw Error('native publish I/O failure');
      const target=filesDir+'/jdk/'+major;remove(target);io.renameSync(stage,target);return '';}
    throw Error('unexpected native action '+action);
  },
  async extract(_archive,root){ensure(root);files.set(root+'/valid',Buffer.from('new'));return true;},
  async seal(){if(mode==='publication-cancel'||mode==='publication-withdraw'){await new Promise(resolve=>setTimeout(resolve,0));if(mode==='publication-withdraw')withdrawn=true;else cancelHook?.();}if(mode==='seal')throw Error('native helper chmod failure');if(mode==='withdraw-at-seal')withdrawn=true;return true;}
});
const Installer=load('launch/src/main/ets/JdkInstaller.ets').JdkInstaller;
function config(){return{tag:'new-build',dataFile:'runtime.zip',dataSizeMB:1,markerFile:'release',minMcVersion:'',maxMcVersion:'',available:true,
  sha256:hash(data),sizeBytes:data.length,webEnabled:false,downloadSource:'auto',
  runtime:{id:'java17-ohos-aarch64',javaMajor:17,recommendationRevision:2},build:{id:'new-build'},
  downloads:[{sourceId:'web',transport:'single-file',url:'https://amcl.lovedhy.cn/test.zip'},
    {sourceId:'github',transport:'single-file',url:'https://github.com/test.zip'}]};}
function installer(c=config(),target='/app/jdk/17'){return new Installer({context:{filesDir:'/app',cacheDir:'/cache'},version:'17',config:c,targetDir:target,forceReinstall:true,isInstalledFn:()=>files.has('/app/jdk/17/valid')});}
/** 同一受信归档的两种公开分发描述；第一方缓存和canonical GitHub各有真实URL标签。 */
function gatewayConfig(){const c=config();const archive={type:'zip',fileName:c.dataFile,sizeBytes:c.sizeBytes,sha256:c.sha256};
 c.downloads=[{sourceId:'web',transport:'single-file',url:'https://amcl.lovedhy.cn/runtimes/packages/runtime.zip'},
   {sourceId:'github',transport:'single-file',url:'https://github.com/LZZLHY/mc-ohos-resources/releases/download/v7/runtime.zip'},
   {sourceId:'gitee',transport:'single-file',url:'https://gitee.com/runtime.zip'}];
 c.build={...c.build,archive,downloads:c.downloads};return c;}
const results=[];
async function test(name,fn){reset();await fn();assert.equal(handles.size,0,'no leaked file handles');assert.equal(leases,0,'all leases released');results.push(name);}
await test('one receipt codec enforces exact shared UTF8 producer budget',async()=>{
  const codec=load('launch/src/main/ets/RuntimeReceiptCodec.ets'),limit=load('launch/src/main/ets/RuntimeCatalogTypes.ets').RUNTIME_INSTALL_RECEIPT_LIMIT,c=config();
  c.build.notes=[''];const initial=codec.serializeRuntimeInstallReceipt(c.runtime,c.build,17,c.sha256,c.sizeBytes,codec.RUNTIME_RECEIPT_MAX_ISO_TIMESTAMP);
  c.build.notes=['x'.repeat(limit-Buffer.byteLength(initial))];const exact=codec.serializeRuntimeInstallReceipt(c.runtime,c.build,17,c.sha256,c.sizeBytes,codec.RUNTIME_RECEIPT_MAX_ISO_TIMESTAMP);
  assert.equal(Buffer.byteLength(exact),limit);c.build.notes[0]+='x';assert.throws(()=>codec.serializeRuntimeInstallReceipt(c.runtime,c.build,17,c.sha256,c.sizeBytes,codec.RUNTIME_RECEIPT_MAX_ISO_TIMESTAMP),/UTF-8预算/);
});
await test('oversized produced receipt cannot publish unreadable installation',async()=>{
  const c=config();c.build.notes=['x'.repeat(1048576)];const task=installer(c);assert.equal(await task.downloadAndInstall(),false);
  assert.equal(files.get('/app/jdk/17/valid').toString(),'old');assert.equal(files.has('/app/jdk/17/.amcl-runtime-receipt.json'),false);assert.match(task.getFailureReason(),/UTF-8预算/);
});
await test('frozen descriptor, web default off, receipt committed with directory',async()=>{
  const c=config(),task=installer(c);c.sha256='0'.repeat(64);c.downloads[1].url='https://amcl.lovedhy.cn/unexpected';
  assert.equal(await task.downloadAndInstall(),true);assert.deepEqual(requests,['https://github.com/test.zip']);
  const receipt=JSON.parse(files.get('/app/jdk/17/.amcl-runtime-receipt.json'));
  assert.equal(receipt.archiveSha256,hash(data));assert.equal(receipt.buildId,'new-build');assert.equal(files.get('/app/jdk/17/valid').toString(),'new');
});
await test('explicit web source only after opt-in',async()=>{const c=config();c.webEnabled=true;c.downloadSource='web';assert.equal(await installer(c).downloadAndInstall(),true);assert.deepEqual(requests,['https://amcl.lovedhy.cn/test.zip']);});
await test('gateway default uses official-bound first-party cache without enabling independent web or probing mirrors',async()=>{
 gateway=true;const c=gatewayConfig();assert.equal(c.webEnabled,false);assert.equal(await installer(c).downloadAndInstall(),true);
 assert.deepEqual(requests,['https://amcl.lovedhy.cn/runtimes/packages/runtime.zip']);assert.equal(probeCalls.length,0);assert.equal(c.webEnabled,false);
});
await test('gateway cache identity failure falls back only to canonical official origin and keeps old data until verified',async()=>{
 gateway=true;mode='cache-corrupt';assert.equal(await installer(gatewayConfig()).downloadAndInstall(),true);
 assert.deepEqual(requests,['https://amcl.lovedhy.cn/runtimes/packages/runtime.zip','https://github.com/LZZLHY/mc-ohos-resources/releases/download/v7/runtime.zip']);
 assert.equal(probeCalls.length,0);assert.deepEqual(unsafeCleanup,[]);
});
await test('explicit origin with gateway off never probes or downloads cache/mirror even when independently allowed',async()=>{
 const c=gatewayConfig();c.downloadSource='github';c.webEnabled=true;assert.equal(await installer(c).downloadAndInstall(),true);
 assert.deepEqual(requests,['https://github.com/LZZLHY/mc-ohos-resources/releases/download/v7/runtime.zip']);assert.equal(probeCalls.length,0);
});
await test('cancel during real group selection creates no file download or changed runtime',async()=>{
 mode='probe-cancel';const task=installer(gatewayConfig());cancelHook=()=>task.requestCancel();
 assert.equal(await task.downloadAndInstall(),false);assert.equal(requests.length,0);assert.equal(files.get('/app/jdk/17/valid').toString(),'old');
});
await test('gateway enabled during probing revokes old mirror ranking and replans official cache once',async()=>{
 mode='probe-switch';cancelHook=()=>{gateway=true;};assert.equal(await installer(gatewayConfig()).downloadAndInstall(),true);
 assert.deepEqual(requests,['https://amcl.lovedhy.cn/runtimes/packages/runtime.zip']);assert.ok(probeCalls.length>0);
});
await test('gateway enabled after a file group failed cannot start an old third-party proxy fallback',async()=>{
 mode='source-switch-on-failure';assert.equal(await installer(gatewayConfig()).downloadAndInstall(),true);
 assert.deepEqual(requests,['https://gitee.com/runtime.zip','https://amcl.lovedhy.cn/runtimes/packages/runtime.zip']);
 assert.equal(requests.some(url=>url.startsWith('https://proxy.example/')),false);assert.deepEqual(unsafeCleanup,[]);
});
await test('automatic real sample can select Gitee parts without downloading other groups',async()=>{
  const c=config();c.webEnabled=true;c.downloads.push({sourceId:'gitee',transport:'concat-parts',parts:[
    {url:'https://gitee.com/part1',sizeBytes:8,sha256:hash(data.subarray(0,8))},
    {url:'https://gitee.com/part2',sizeBytes:data.length-8,sha256:hash(data.subarray(8))}]});
  // 输入故意让web/GitHub排在前面；来源排序、逐卷SHA、合并、发布仍由真实安装器完成。
  assert.equal(await installer(c).downloadAndInstall(),true);
  assert.deepEqual(requests,['https://gitee.com/part1','https://gitee.com/part2']);
  assert.equal(files.get('/app/jdk/17/valid').toString(),'new');
});
await test('automatic mode can select faster official source instead of a mirror without VPN detection',async()=>{
  const c=config();c.downloads.push({sourceId:'gitee',transport:'concat-parts',parts:[
    {url:'https://gitee.com/part1',sizeBytes:8,sha256:hash(data.subarray(0,8))},
    {url:'https://gitee.com/part2',sizeBytes:data.length-8,sha256:hash(data.subarray(8))}]});
  originWins=true;assert.equal(await installer(c).downloadAndInstall(),true);
  assert.deepEqual(requests,['https://github.com/test.zip']);assert.equal(probeCalls.length,2);
});
for(const failure of ['hash','receipt','rename','busy','seal','withdraw-at-seal'])await test('failure '+failure+' preserves old installation',async()=>{mode=failure;assert.equal(await installer().downloadAndInstall(),false);assert.equal(files.get('/app/jdk/17/valid').toString(),'old');assert.equal(files.has('/app/jdk/17/.amcl-runtime-receipt.json'),false);});
await test('bad Gitee part rejected, clean fallback to complete GitHub archive',async()=>{
  const c=config();c.downloads.unshift({sourceId:'gitee',transport:'concat-parts',parts:[
    {url:'https://gitee.com/part1',sizeBytes:8,sha256:hash(data.subarray(0,8))},
    {url:'https://gitee.com/part2',sizeBytes:data.length-8,sha256:hash(data.subarray(8))}]});
  mode='part';assert.equal(await installer(c).downloadAndInstall(),true);assert.deepEqual(requests,['https://gitee.com/part1','https://gitee.com/part2','https://github.com/test.zip']);
});
await test('withdrawn while downloading cannot publish',async()=>{cancelHook=()=>{withdrawn=true;};assert.equal(await installer().downloadAndInstall(),false);assert.equal(files.get('/app/jdk/17/valid').toString(),'old');});
await test('explicit rollback scope stops an in-flight affected build',async()=>{mode='rollback';assert.equal(await installer().downloadAndInstall(),false);assert.equal(files.get('/app/jdk/17/valid').toString(),'old');});
await test('cancel after download preserves old',async()=>{const task=installer();cancelHook=()=>task.requestCancel();assert.equal(await task.downloadAndInstall(),false);assert.equal(files.get('/app/jdk/17/valid').toString(),'old');});
for(const publicationMode of ['publication-cancel','publication-withdraw'])await test(publicationMode+' after yielding flush preserves old',async()=>{
  mode=publicationMode;const task=installer();cancelHook=()=>{if([...files.keys()].some(p=>p.includes('/.staging-')))task.requestCancel();};
  assert.equal(await task.downloadAndInstall(),false);assert.equal(files.get('/app/jdk/17/valid').toString(),'old');
});
await test('missing hash and slot/lease mismatch refused before network',async()=>{const c=config();delete c.sha256;assert.equal(await installer(c).downloadAndInstall(),false);assert.equal(await installer(config(),'/app/jdk/21').downloadAndInstall(),false);assert.equal(requests.length,0);});
await test('logical terminal cannot clean/reuse part paths before native execution settles',async()=>{
  const c=config();c.downloads=[...['gitee','github'].map(sourceId=>({sourceId,transport:'concat-parts',parts:[
    {url:'https://'+(sourceId==='gitee'?'gitee.com':'github.com')+'/part1',sizeBytes:8,sha256:hash(data.subarray(0,8))},
    {url:'https://'+(sourceId==='gitee'?'gitee.com':'github.com')+'/part2',sizeBytes:data.length-8,sha256:hash(data.subarray(8))}]}))];
  mode='settling-parts';const task=installer(c),ok=await task.downloadAndInstall();
  await new Promise(resolve=>setTimeout(resolve,30));
  assert.equal(ok,true,'必须在释放旧native owner后才能复用.pN路径尝试下一来源');
  assert.deepEqual(unsafeCleanup,[],'逻辑终态不能授权删除仍有原生写者的分卷或目录');
  assert.equal(nativeOwners.size,0,'成功/失败来源的owner都应通过purge屏障释放');
});
await test('cancel waits for a logically finished native writer before cleaning its directory',async()=>{
  mode='settling-cancel';const task=installer();cancelHook=()=>task.requestCancel();
  assert.equal(await task.downloadAndInstall(),false);
  assert.deepEqual(unsafeCleanup,[],'取消也不能删除仍由原生持有的文件/目录');
  assert.equal(files.get('/app/jdk/17/valid').toString(),'old');assert.equal(nativeOwners.size,0);
});
await test('unsettled native owner retains writer/action until actual release, then cleans safely',async()=>{
  // 用旧单文件路线单独检验最终owner屏障，不能让catalog逐卷的新finally替它挡住旧缺陷。
  mode='settling-timeout';const c=config();delete c.downloads;const task=installer(c);let release,settled=false;
  const originalTimer=globalThis.setTimeout,timers=[];let now=0;
  globalThis.setTimeout=(run,delay)=>{if(delay===100){timers.push({run,at:now+delay});return 0;}return originalTimer(run,delay);};
  ownerRelease={promise:new Promise(resolve=>{release=resolve;})};
  const pending=task.downloadAndInstall().then(ok=>{settled=true;return ok;});
  try {
    // 门只延迟Native释放；等待实际owner进入，不在测试重写安装器的轮询/超时策略。
    for(let turn=0;turn<100&&nativeOwners.size===0;turn++)await new Promise(resolve=>setImmediate(resolve));
    // 只推进旧生产等待的100ms定时口至31s；撤回retain修补会真实走完其多个5s窗口，
    // 而不是由用例等待新helper的进入信号，确保旧实现以业务断言失败而非永久挂起。
    for(let budget=0;budget<4000;budget++){
      for(let micro=0;micro<20;micro++)await Promise.resolve();
      const next=timers[0];if(!next||next.at>31000){now=31000;break;}timers.shift();now=next.at;next.run();
    }
    assert(nativeOwners.size>0);assert.equal(settled,false);assert.equal(task.isDownloading(),true);
    assert.equal(leases,1,'等待期间必须持有writer，不能仅保存目录却放走执行资格');
    assert.deepEqual(unsafeCleanup,[]);
    assert([...files.keys()].some(path=>path.startsWith('/cache/jdk-install-staging/')));
    assert.equal(files.get('/app/jdk/17/valid').toString(),'old');
    for(const owner of nativeOwners.values())owner.settled=true;
    release();assert.equal(await pending,true);
    assert.equal(nativeOwners.size,0);assert.deepEqual(unsafeCleanup,[]);
    assert.equal([...files.keys()].some(path=>path.startsWith('/cache/jdk-install-staging/')),false);
  }finally{globalThis.setTimeout=originalTimer;for(const owner of nativeOwners.values())owner.settled=true;release();
    // 断言失败也解除已排队的旧等待，禁止负控通过留下悬挂Promise拖住整组门禁。
    for(const timer of timers.splice(0))timer.run();await pending;}
});
console.log(JSON.stringify({passed:results.length,cases:results},null,2));
