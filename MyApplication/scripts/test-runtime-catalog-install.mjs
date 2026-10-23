/**
 * 生产安装器的目录下载/发布闭环：网络与解压作为 I/O 边界注入，生产 SHA-256 分块计算、
 * 来源过滤、分卷合并、receipt 和回滚代码均真正执行。ELF/ZIP 内容验证由独立套件覆盖。
 */
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {makePureEtsLoader} from './lib/load-pure-ets.mjs';
const data=Buffer.from('PK-runtime-catalog-fixture'),hash=b=>createHash('sha256').update(b).digest('hex');
let files,dirs,handles,requests,mode,leases,withdrawn,cancelHook,nativeOwners,unsafeCleanup,ownerRelease;
function reset(){files=new Map([['/app/jdk/17/valid',Buffer.from('old')]]);dirs=new Set(['/app/jdk/17']);handles=new Map();requests=[];mode='';leases=0;withdrawn=false;cancelHook=null;nativeOwners=new Map();unsafeCleanup=[];ownerRelease=null;}
/** 原生终态与执行收敛分开建模；有活跃写者时清理目录/分卷必须被用例记录。 */
function recordCleanup(path){for(const owner of nativeOwners.values())if(!owner.settled&&(owner.path===path||owner.path.startsWith(path+'/')))unsafeCleanup.push(path);}
function remove(path){recordCleanup(path);for(const p of [...files.keys()])if(p===path||p.startsWith(path+'/'))files.delete(p);for(const p of [...dirs])if(p===path||p.startsWith(path+'/'))dirs.delete(p);}
function ensure(path){dirs.add(path);}
const io={OpenMode:{CREATE:1,WRITE_ONLY:2,TRUNC:4,READ_ONLY:0},
  statSync:p=>{if(files.has(p))return{size:files.get(p).length,isFile:()=>true};if(dirs.has(p))return{size:0,isFile:()=>false};throw Error('ENOENT');},
  listFileSync:p=>[...files.keys()].filter(x=>x.startsWith(p+'/')).map(x=>x.slice(p.length+1)),
  openSync:(p,flags)=>{if(!flags&&!files.has(p))throw Error('ENOENT');if(flags&4)files.set(p,Buffer.alloc(0));const fd=Symbol(p);handles.set(fd,{p,offset:0});return{fd};},
  readSync:(fd,buffer)=>{const h=handles.get(fd),f=files.get(h.p);const size=Math.min(buffer.byteLength,f.length-h.offset);new Uint8Array(buffer).set(f.subarray(h.offset,h.offset+size));h.offset+=size;return size;},
  writeSync:(fd,value,options)=>{const h=handles.get(fd);if(mode==='receipt'&&h.p.endsWith('receipt.json'))throw Error('receipt write failure');const b=typeof value==='string'?Buffer.from(value):Buffer.from(value).subarray(0,options?.length??value.byteLength);files.set(h.p,Buffer.concat([files.get(h.p)||Buffer.alloc(0),b]));return b.length;},
  fsyncSync:()=>{},closeSync:f=>handles.delete(f.fd??f),unlinkSync:p=>{recordCleanup(p);return files.delete(p);},
  renameSync:(a,b)=>{if(mode==='rename'&&a.includes('.staging-')&&b==='/app/jdk/17'){mode='';throw Error('rename failure');}
    if(!dirs.has(a))throw Error('missing source dir');for(const p of [...files.keys()])if(p.startsWith(a+'/')){files.set(b+p.slice(a.length),files.get(p));files.delete(p);}for(const p of [...dirs])if(p===a||p.startsWith(a+'/')){dirs.add(b+p.slice(a.length));dirs.delete(p);}}
};
class Logger{constructor(id){this.activity=id;}id(){return this.activity;}info(){}warn(){}error(){}debug(){}}
const downloadManager={initializeCaBundle:()=>{},purgeTask:id=>{
    const owner=nativeOwners.get(id);if(owner&&!owner.settled)return false;nativeOwners.delete(id);return true;
  },cancel:()=>{},
  /** 只控制Native平台释放事实，生产业务的等待位置/来源回退/目录事务不在此复制。 */
  async awaitTaskReleased(id,retainOwner){assert.equal(retainOwner,true);if(ownerRelease)await ownerRelease.promise;
    while(!downloadManager.purgeTask(id))await new Promise(resolve=>setTimeout(resolve,5));},
  createAndWait:async(spec,progress)=>{const file=spec.files[0],url=file.urls[0];requests.push(url);
    if(mode==='settling-parts'&&[...nativeOwners.values()].some(owner=>owner.path===file.localPath))throw Error('native path still owned');
    let body=url.endsWith('part1')?data.subarray(0,8):url.endsWith('part2')?data.subarray(8):data;
    if(mode==='part'&&url.endsWith('part2'))body=Buffer.alloc(body.length);
    if(mode==='settling-parts'&&url==='https://gitee.com/part2')body=Buffer.alloc(body.length);
    if(mode==='hash')body=Buffer.alloc(body.length);
    const taskId=requests.length;
    if(['settling-parts','settling-cancel','settling-timeout'].includes(mode)){
      const owner={path:file.localPath,settled:false};nativeOwners.set(taskId,owner);
      // createAndWait 已返回逻辑终态，但 curl/worker 仍短暂持有原路径。purge 是唯一释放证明。
      if(mode!=='settling-timeout')setTimeout(()=>{files.set(owner.path,body);owner.settled=true;},20);
    }
    files.set(file.localPath,body);progress({taskId:requests.length,bytesDone:body.length,speedBps:1024});cancelHook?.();
    return{taskId:requests.length,bytesDone:body.length,finished:true};}};
const load=makePureEtsLoader({
  '@kit.CoreFileKit':{fileIo:io},'@kit.CryptoArchitectureKit':{cryptoFramework:{createMd:()=>{const h=createHash('sha256');return{updateSync:b=>h.update(b.data),digestSync:()=>({data:new Uint8Array(h.digest())})};}}},
  './JdkManager':{getJdkDownloadSource:()=> 'github',MIRROR_TEMPLATES:['{url}'],RELEASE_BASE_URL:'https://github.com/fixture/releases/download'},
  './RuntimeCatalogRepository':{RuntimeCatalogRepository:{instance:()=>({isBuildAllowed:()=>!withdrawn&&mode!=='rollback'})}},
  './JdkTreeValidation':{validateRuntimeTree:root=>files.has(root+'/valid')?'':'bad fixture'},
  './JdkDirectoryLease':{JdkDirectoryLease:{writer:()=>{leases++;return{release:()=>leases--};},publication:()=>{if(mode==='busy')throw Error('JDK 正在使用');leases++;return{release:()=>leases--};}}},
  commons:{removeDirRecursive:remove,ensureDirSync:ensure,ActivityLogger:Logger,isJdkSlotVersion:v=>/^[1-9][0-9]{0,2}$/.test(v)&&Number(v)>=8},
  feature_core:{DownloadManager:{instance:()=>downloadManager},formatBytes:String,formatSpeed:String,
    safeBaseName:p=>/^[a-zA-Z0-9._-]+$/.test(p)&&!p.includes('..')?p:'',safeRelPath:p=>p.includes('..')?'':p,
    decompressFile:async(_zip,root)=>{ensure(root);files.set(root+'/valid',Buffer.from('new'));}}
});
const Installer=load('launch/src/main/ets/JdkInstaller.ets').JdkInstaller;
function config(){return{tag:'new-build',dataFile:'runtime.zip',dataSizeMB:1,markerFile:'release',minMcVersion:'',maxMcVersion:'',available:true,
  sha256:hash(data),sizeBytes:data.length,webEnabled:false,downloadSource:'auto',
  runtime:{id:'java17-ohos-aarch64',javaMajor:17,recommendationRevision:2},build:{id:'new-build'},
  downloads:[{sourceId:'web',transport:'single-file',url:'https://amcl.lovedhy.cn/test.zip'},
    {sourceId:'github',transport:'single-file',url:'https://github.com/test.zip'}]};}
function installer(c=config(),target='/app/jdk/17'){return new Installer({context:{filesDir:'/app',cacheDir:'/cache'},version:'17',config:c,targetDir:target,forceReinstall:true,isInstalledFn:()=>files.has('/app/jdk/17/valid')});}
const results=[];
async function test(name,fn){reset();await fn();assert.equal(handles.size,0,'no leaked file handles');assert.equal(leases,0,'all leases released');results.push(name);}
await test('frozen descriptor, web default off, receipt committed with directory',async()=>{
  const c=config(),task=installer(c);c.sha256='0'.repeat(64);c.downloads[1].url='https://amcl.lovedhy.cn/unexpected';
  assert.equal(await task.downloadAndInstall(),true);assert.deepEqual(requests,['https://github.com/test.zip']);
  const receipt=JSON.parse(files.get('/app/jdk/17/.amcl-runtime-receipt.json'));
  assert.equal(receipt.archiveSha256,hash(data));assert.equal(receipt.buildId,'new-build');assert.equal(files.get('/app/jdk/17/valid').toString(),'new');
});
await test('explicit web source only after opt-in',async()=>{const c=config();c.webEnabled=true;c.downloadSource='web';assert.equal(await installer(c).downloadAndInstall(),true);assert.deepEqual(requests,['https://amcl.lovedhy.cn/test.zip']);});
for(const failure of ['hash','receipt','rename','busy'])await test('failure '+failure+' preserves old installation',async()=>{mode=failure;assert.equal(await installer().downloadAndInstall(),false);assert.equal(files.get('/app/jdk/17/valid').toString(),'old');assert.equal(files.has('/app/jdk/17/.amcl-runtime-receipt.json'),false);});
await test('bad Gitee part rejected, clean fallback to complete GitHub archive',async()=>{
  const c=config();c.downloads.unshift({sourceId:'gitee',transport:'concat-parts',parts:[
    {url:'https://gitee.com/part1',sizeBytes:8,sha256:hash(data.subarray(0,8))},
    {url:'https://gitee.com/part2',sizeBytes:data.length-8,sha256:hash(data.subarray(8))}]});
  mode='part';assert.equal(await installer(c).downloadAndInstall(),true);assert.deepEqual(requests,['https://gitee.com/part1','https://gitee.com/part2','https://github.com/test.zip']);
});
await test('withdrawn while downloading cannot publish',async()=>{cancelHook=()=>{withdrawn=true;};assert.equal(await installer().downloadAndInstall(),false);assert.equal(files.get('/app/jdk/17/valid').toString(),'old');});
await test('explicit rollback scope stops an in-flight affected build',async()=>{mode='rollback';assert.equal(await installer().downloadAndInstall(),false);assert.equal(files.get('/app/jdk/17/valid').toString(),'old');});
await test('cancel after download preserves old',async()=>{const task=installer();cancelHook=()=>task.requestCancel();assert.equal(await task.downloadAndInstall(),false);assert.equal(files.get('/app/jdk/17/valid').toString(),'old');});
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
