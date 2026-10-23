/**
 * 执行真实Coordinator/Repository/Registry/VM与AtomicWriter/Vault，平台边界替换为受控宿主。
 * 所有模拟沙箱I/O先验证最终路径在本轮独占fixture目录，不能碰用户真实材料或任意路径。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import vm from 'node:vm';
import {fileURLToPath} from 'node:url';
import compiler from './ets-compiler.mjs';
import {createHostTestScope} from './host-test-lifecycle.mjs';
const project=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
// 显式输出目录只是父容器；本次导入仍新建独占运行域，成功后可安全删除整轮 case/JAR。
// 断言失败或 AMCL_KEEP_TEST_OUTPUT=1 保留整轮现场，不能清掉前序用例供失败分析的证据。
const lifecycle=createHostTestScope('sideload-owner-'),output=lifecycle.directory;
const deferred=()=>{let resolve;const promise=new Promise(r=>resolve=r);return{promise,resolve};};
const settle=async()=>{for(let i=0;i<4;i++)await new Promise(r=>setImmediate(r));};
const payload='d'.repeat(40),oldId='b'.repeat(32),oldNonce='c'.repeat(32);
const data=Buffer.from('unsigned candidate fixture'),sha=crypto.createHash('sha256').update(data).digest('hex');
const target={tag:'v2.0.0',versionCode:2,versionName:'2.0.0',product:'sideload',sha256:sha,sizeBytes:data.length,
 name:'amcl-v2.0.0-sideload-unsigned.hap',url:'https://github.com/LZZLHY/amcl/releases/download/v2.0.0/amcl-v2.0.0-sideload-unsigned.hap',legacyUniversal:false,
 websiteUrl:'https://amcl.lovedhy.cn/api/packages/files/'+sha+'/amcl-v2.0.0-sideload-unsigned.hap',
 mirrors:[{provider:'miawa',projectId:'amcl',ready:true,filePath:'amcl/v2.0.0/amcl-v2.0.0-sideload-unsigned.hap'}]};
const manifest={...target,delivery:{schema:1,ready:true,assets:[target]}};
/** 各case使用独立模块单例与虚拟Kit文件域；真实Writer仍循环写真实宿主文件。 */
async function fixture({journal,account='valid',delayDownload=false,delaySign=false,signFailure=false,delayConnect=false,delayClose=false,connectFailOnce=false,signCommitFailure=false,expireMaterialFirst=false,delayLoginBegin=false,child=0,candidate=manifest}={}){
 // 每个用例可提供独立公开清单，用同一真实流水线覆盖同 code 的预览/返回场景。
 const selectedAsset=candidate.delivery.assets[0];
 const physical=fs.mkdtempSync(path.join(output,'case-')),rows=new Map(),storage=new Map(),locks=new Set(),handles=new Map();
 const pending=new Set(),timers=new Set(),mounted=new Set();let closing=false,coordinator;
 /**
  * 只观察实际异步方法的返回 Promise，不改变业务分支、文件隔离或断言顺序。
  * finally 返回值仍把拒绝交给原调用者；不能用吞拒绝的旁路监听掩盖未处理异常。
  */
 const track=promise=>{let observed;observed=promise.finally(()=>pending.delete(observed));pending.add(observed);return observed;};
 const trackMethods=object=>{
  for(const name of Object.getOwnPropertyNames(object)){
   const descriptor=Object.getOwnPropertyDescriptor(object,name),method=descriptor?.value;
   if(typeof method==='function'&&method.constructor.name==='AsyncFunction'){
    Object.defineProperty(object,name,{...descriptor,value:function(...args){return track(method.apply(this,args));}});
   }
  }
 };
 let synthetic=1000000;
 // 核实平台边界单独计数，AA 唤醒回归必须证明调用了旧执行权裁决，而没有重走下载/签名/派发。
 const counters={download:0,sign:0,dispatch:0,prepare:0,revoke:0,observe:0,complete:0,cleanup:0,ledgerEnds:0,
  leases:0,keygen:0,authRequests:0,connections:0,closeStarted:0,closeSettled:0},faults={rename:false,shortWrite:false};
 const fetchGate=deferred(),signGate=deferred(),connectionGate=deferred(),closeGate=deferred(); let encryptionGate;
 const mapped=p=>{
  const virtual=String(p);assert(virtual==='/sandbox'||virtual.startsWith('/sandbox/'),'only fixture sandbox');
  const resolved=path.resolve(physical,virtual.slice('/sandbox'.length).replace(/^[/\\]+/,''));
  assert(resolved===physical||resolved.startsWith(physical+path.sep),'fixture path cannot escape');return resolved;
 };
 const kitfs={OpenMode:{READ_ONLY:1,READ_WRITE:2,WRITE_ONLY:4,CREATE:8,NOFOLLOW:16,TRUNC:32},
  accessSync:p=>fs.existsSync(mapped(p)),mkdirSync:(p,recursive=false)=>fs.mkdirSync(mapped(p),{recursive}),
  listFileSync:p=>fs.readdirSync(mapped(p)),statSync:p=>typeof p==='number'?(handles.get(p).directory?fs.statSync(handles.get(p).path):fs.fstatSync(p)):fs.statSync(mapped(p)),
  readTextSync:p=>fs.readFileSync(mapped(p),'utf8'),
  renameSync:(a,b)=>{if(signCommitFailure&&String(b).endsWith('/transaction.json')&&fs.readFileSync(mapped(a),'utf8').includes('\"phase\":\"signing\"'))throw Error('ENOSPC signing fixture');if(faults.rename&&String(b).endsWith('/transaction.json'))throw Error('ENOSPC fixture');fs.renameSync(mapped(a),mapped(b));},
  unlinkSync:p=>fs.unlinkSync(mapped(p)),rmdirSync:p=>fs.rmdirSync(mapped(p)),
  openSync(p,mode=1){
   const name=mapped(p);if((mode&16)&&fs.existsSync(name)&&fs.lstatSync(name).isSymbolicLink())throw Error('NOFOLLOW fixture');
   const directory=fs.existsSync(name)&&fs.statSync(name).isDirectory();
   const fd=directory?++synthetic:fs.openSync(name,(mode&2)?'a+':(mode&8)?'w':(mode&4)?'r+':'r');
   const item={fd,path:name,directory,owned:false,tryLock(){if(locks.has(name))throw Error('EWOULDBLOCK fixture');locks.add(name);item.owned=true;}};
   handles.set(fd,item);return item;
  },
  closeSync(file){const fd=typeof file==='number'?file:file.fd,h=handles.get(fd);if(h?.owned)locks.delete(h.path);if(!h?.directory)fs.closeSync(fd);handles.delete(fd);},
  writeSync(fd,bytes){const b=Buffer.from(bytes);return fs.writeSync(fd,b,0,faults.shortWrite?Math.min(4,b.length):b.length);},
  readSync:(fd,buffer,options)=>fs.readSync(fd,Buffer.from(buffer),0,options.length,null),
  read:async(fd,buffer,options)=>fs.readSync(fd,Buffer.from(buffer),0,options.length,null),
  write:async(fd,buffer)=>fs.writeSync(fd,Buffer.from(buffer)),
  fsyncSync:fd=>{if(!handles.get(fd)?.directory)fs.fsyncSync(fd);}
 };
 fs.mkdirSync(mapped('/sandbox/sideload-update'),{recursive:true});
 if(journal)fs.writeFileSync(mapped('/sandbox/sideload-update/transaction.json'),JSON.stringify(journal));
 fs.mkdirSync(mapped('/sandbox/jdk/17/lib/server'),{recursive:true});fs.writeFileSync(mapped('/sandbox/jdk/17/lib/server/libjvm.so'),'fixture');
 let generatedId='';
 const kitUtil={Base64Helper:class{encodeToStringSync(v){return Buffer.from(v).toString('base64');}},generateRandomUUID:()=>crypto.randomUUID(),TextDecoder:class{decodeWithStream(b){return new TextDecoder().decode(b);}}};
 const hashKit={createMd(){const h=crypto.createHash('sha256');return{async update(v){h.update(v.data);},async digest(){return{data:new Uint8Array(h.digest())};}};}};
 const cache=new Map();let common,core,update;
 // UID 与版本、载荷都是 bundle/resource 平台边界事实；不能直接写 Coordinator 的确认标志造成功。
 const environment={version:journal?.phase==='verified'?journal.asset.versionCode:1,versionName:journal?.phase==='verified'?journal.asset.versionName:'1.0.0',payload:journal?.phase==='verified'?payload:'old',uid:42};
 const context={filesDir:'/sandbox',resourceManager:{getRawFileContentSync(name){
  if(name==='product-profile.json')return new TextEncoder().encode(JSON.stringify({sourceRevision:environment.payload}));
  assert(['sideload/hap-sign-tool.jar','sideload/amcl-signing-runner.jar'].includes(name));
  return new Uint8Array(fs.readFileSync(path.join(project,'entry/src/main/resources/rawfile',name)));
 }}};
 storage.set('uiAbilityContext',context);
 const native={configureSideloadInstallRoot:()=>true,
  acquireSideloadFileLease:()=>{if(kitfs.accessSync('/sandbox/sideload-update/install-fence.json'))return 0;counters.leases++;return counters.leases+1;},
  releaseSideloadFileLease(){counters.leases--;return true;},mcIsRunning:()=>false,desktopGameProcessState:()=>child,cancelSideloadPow(){},
  async runJavaProcessor(_files,_jdk,_xmx,_cp,_main,args){
   if(args[0]==='--generate-key'){
    counters.keygen++;generatedId=args[1].split('/').at(-1).slice(4);
    fs.writeFileSync(mapped(args[2]),JSON.stringify({schema:1,keyAlias:'fixture',keyPassword:'test-only',storePassword:'test-only',signAlg:'SHA256withECDSA',p12Base64:Buffer.from('p12 fixture').toString('base64'),csr:'fixture CSR'}));return 0;
   }
   if(args[0]==='--inspect-hap'){
    fs.writeFileSync(mapped(args[2]),JSON.stringify({inspected:true,bundleName:'com.amcl.launcher',versionName:selectedAsset.versionName,versionCode:selectedAsset.versionCode,product:'sideload',minApi:20,deviceTypes:['phone']}));return 0;
   }
   counters.sign++;if(delaySign)await signGate.promise;if(signFailure)return 1;
   const config=JSON.parse(kitfs.readTextSync(args[0]));fs.writeFileSync(mapped(args[2]),'signed fixture');
   fs.writeFileSync(mapped(args[3]),JSON.stringify({signed:true,verified:true,payloadIdentity:payload,
    signatureValidFrom:Date.now()-60000,signatureValidUntil:Date.now()+3600000,signatureVerifiedAt:Date.now(),
    materialRevision:config.materialRevision,identityMode:'public-key',profileTrust:'installed-key'}));return 0;
  }
 };
 const key=crypto.randomBytes(32);
 /** 硬件cipher边界以真实宿主AES-GCM模拟；真实Vault的来源证明/写盘逻辑不替换。 */
 class HardwareCipher{
  async encrypt(text){if(encryptionGate)await encryptionGate.promise;const iv=crypto.randomBytes(12),c=crypto.createCipheriv('aes-256-gcm',key,iv),bytes=Buffer.concat([c.update(text,'utf8'),c.final()]);return{iv:iv.toString('base64'),ciphertext:bytes.toString('base64'),tag:c.getAuthTag().toString('base64')};}
  async decrypt(blob){const d=crypto.createDecipheriv('aes-256-gcm',key,Buffer.from(blob.iv,'base64'));d.setAuthTag(Buffer.from(blob.tag,'base64'));return Buffer.concat([d.update(Buffer.from(blob.ciphertext,'base64')),d.final()]).toString('utf8');}
 }
 // 授权平台边界逐次记录真实对象与begin。gate可控制URL返回/异常晚于关闭、重登及Runtime换代。
 let authObject,expiredCloud=false;const authBegins=[],authSessions=[];
 class Auth{
  teamIds(){return['fixture-team'];}
  async request(url,_method,_team,body){counters.authRequests++;if(expireMaterialFirst&&!expiredCloud){expiredCloud=true;this.valid=false;account='expired';throw Error('华为登录已过期，请重新登录');}if(!this.valid)throw Error('华为登录已过期，请重新登录');if(url.includes('brief-info'))return{appInfos:[{appId:'installed-app'}]};if(url.includes('/cert/list'))return{certList:[{certName:'amcl_update_'+generatedId,id:'cert',certObjectId:'cert-object'}]};if(url.includes('/device/list'))return{list:[{udid:'A'.repeat(64),id:'device'}]};if(url.includes('/provision/list'))return{list:[{provisionName:'amcl_update_'+generatedId,provisionFileUrl:'profile-object'}]};if(url.includes('/url/reapply'))return{urlsInfo:[{newUrl:'https://fixture.huawei.com/'+body.sourceUrls}]};throw Error('unexpected fixture RPC');}
  initialize(context){authObject=this;this.context=context;this.closeCount=0;authSessions.push(this);}
  async restore(){this.valid=account==='valid';return account;}
  signedIn(){return this.valid===true;}
  async begin(callback){
   this.close();const operation={auth:this,callback,gate:deferred()};authBegins.push(operation);
   if(delayLoginBegin){const result=await operation.gate.promise;if(result instanceof Error)throw result;if(typeof result==='string')return result;}
   return'https://cn.devecostudio.huawei.com/';
  }
  close(){this.valid=false;this.closeCount++;}
  static isExpired(e){return e.message==='华为登录已过期，请重新登录';}
 }
 let connectionChecks=0;class Connection{currentPort(){return 10178;}setDevicePort(){}async check(){connectionChecks++;counters.connections++;if(connectFailOnce&&connectionChecks===1)throw Error('debug disabled fixture');if(delayConnect)return connectionGate.promise;return'A'.repeat(64);}deviceUdid(){return'A'.repeat(64);}async close(){counters.closeStarted++;if(delayClose){if(delayConnect)await connectionGate.promise;await closeGate.promise;}counters.closeSettled++;}async command(){}async sendVerified(){}}
 let observation;
 /** Executor是安装平台边界；真实Fence仍持久写入，UI测试不执行设备bm。 */
 class Executor{
  constructor(){this.fence=new (load('entry/src/main/ets/sideload/InstallFence.ets').InstallFence)('/sandbox');}
  async prepare(i,g){g.assertCurrent();g.assertForeground();counters.prepare++;if(child!==0)throw Error('请先保存并退出所有游戏窗口');this.fence.arm(i);}
  async dispatch(i,commit,g){g.assertCurrent();g.assertForeground();commit();counters.dispatch++;return this.unknown(i);}
  unknown(i){return{kind:'unknown',safeToRelease:false,bmSubmitted:true,code:0,message:'待核实fixture',installId:i.installId,nonce:i.nonce};}
  async revoke(i){counters.revoke++;return this.unknown(i);}async observe(i){counters.observe++;this.proof=observation||this.unknown(i);return this.proof;}
  releaseProcessLeases(){}async cleanupPayload(){counters.cleanup++;}complete(i,p,installed){counters.complete++;assert.equal(p,this.proof);assert(p.safeToRelease);if(p.kind==='bms-success')assert(installed);this.fence.clear(i);}
 }
 // 平台替身也可能由 void 方法触发（例如 cancel 发出的 Connection.close）；同样登记其真实 Promise，
 // 避免只等生产 async 方法却漏掉连接的迟到 finally。每个 fixture 单独装饰自己的类与对象。
 for(const object of [kitfs,native,HardwareCipher.prototype,Auth.prototype,Connection.prototype,Executor.prototype])trackMethods(object);
 /** 相对导入保持真实业务源码；仅Kit/硬件/认证/JVM/HDC边界有替身。 */
 function load(file){
  if(cache.has(file))return cache.get(file);const exports={};cache.set(file,exports);
  let source=fs.readFileSync(path.join(project,file),'utf8');
  // 执行实际Content生命周期/窗口查询/连接方法；ArkUI声明式布局留给正常SDK检查与真实设备。
  // 仅去除首个@Builder之后的DSL并将struct作宿主class，窗口事件与业务方法正文不复制/改写。
  if(file==='entry/src/main/ets/components/SideloadUpdateContent.ets')source=source.slice(0,source.indexOf('  @Builder'))+'\n}\n';
  source=source.replace('export struct SideloadUpdateContent','export class SideloadUpdateContent');
  const js=compiler.transpileModule(source,{compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020,experimentalDecorators:true}}).outputText;
  vm.runInNewContext(js,{exports,require(name){
   if(name==='commons')return common;if(name==='feature_core')return core;if(name==='update')return update;
   if(name==='account')return{HuksAesGcm256Provider:HardwareCipher};if(name==='entry/ProductBuildProfile')return{ProductBuildProfile:{product:'sideload',storeChannel:false}};
   if(name==='libentry.so')return{default:native};if(name==='@kit.CoreFileKit')return{fileIo:kitfs,picker:{}};
   if(name==='@kit.ArkTS')return{util:kitUtil};if(name==='@kit.CryptoArchitectureKit')return{cryptoFramework:hashKit};
   if(name==='@kit.ArkUI')return{window:windowKit};if(name==='@kit.ArkWeb')return{webview:{WebviewController:class{}}};
   if(name==='feature_system')return{PreferenceManager:class{themeMode=0;}};
   if(name==='@kit.AbilityKit')return{ConfigurationConstant:{ColorMode:{COLOR_MODE_DARK:1}},bundleManager:{BundleFlag:{},getBundleInfoForSelfSync:()=>({name:'com.amcl.launcher',versionCode:environment.version,versionName:environment.versionName,appInfo:{uid:environment.uid},signatureInfo:{fingerprint:'F',appId:'installed-app',appIdentifier:'installed-app'}})}};
   if(name==='@kit.BasicServicesKit')return{deviceInfo:{sdkApiVersion:26,deviceType:'phone'}};if(name==='@kit.NetworkKit')return{http:{RequestMethod:{GET:'GET',POST:'POST'},HttpDataType:{ARRAY_BUFFER:1},createHttp:()=>({destroy(){},async request(url){const b=Buffer.from(url.includes('profile')?'profile fixture':'cert fixture');return{responseCode:200,result:b.buffer.slice(b.byteOffset,b.byteOffset+b.byteLength)};}})}};
   if(name==='./DeveloperAuthSession')return{DeveloperAuthSession:Auth,DeveloperAuthState:{Valid:'valid',Missing:'missing',Expired:'expired',Unavailable:'unavailable',Cancelled:'cancelled'}};
   if(name==='./SideloadConnection')return{SideloadConnection:Connection};
   if(name==='./SideloadInstallExecutor')return{SideloadInstallExecutor:Executor,...load('entry/src/main/ets/sideload/SideloadInstallProtocol.ets')};

   if(name==='./SideloadDownloadSources')return{SideloadDownloadSources:{download:async(a,active,run)=>run({label:'fixture',url:a.url})}};
   if(name.startsWith('.'))return load(path.posix.normalize(path.posix.join(path.posix.dirname(file),name))+'.ets');
   throw Error('Unmocked '+name);
  // 装饰器仅是宿主平台边缘：现有组件的Prop布局参数与State一样保留原字段初始化，不替业务赋值。
  },Observed:x=>x,Component:x=>x,State(){},Prop(){},Watch:()=>()=>{},StorageProp:()=>()=>{},AppStorage:{get:k=>storage.get(k),setOrCreate:(k,v)=>storage.set(k,v)},Uint8Array,ArrayBuffer,TextEncoder,TextDecoder,console,
   // unref 只允许进程退出，不会停止旧回调；记录真实 timer，并在本轮收尾先阻止新增与旧回调。
   setTimeout:(callback,delay,...args)=>{const t=setTimeout(()=>{timers.delete(t);if(!closing)callback(...args);},delay);t.unref();if(closing)clearTimeout(t);else timers.add(t);return t;},
   clearTimeout:t=>{timers.delete(t);clearTimeout(t);}});
  // 编译后仍执行生产方法正文；这里只登记 Promise 生命周期，确保 fire-and-forget 链也被收尾等待。
  trackMethods(exports);for(const value of Object.values(exports))if(typeof value==='function'){
   trackMethods(value);if(value.prototype)trackMethods(value.prototype);
  }
  return exports;
 }
 const windowKit={WindowStageLifecycleEventType:{SHOWN:1,RESUMED:2,PAUSED:3,HIDDEN:4},WindowEventType:{WINDOW_SHOWN:1,WINDOW_ACTIVE:2,WINDOW_INACTIVE:3,WINDOW_HIDDEN:4}};
 common={...load('commons/src/main/ets/utils/Base64Util.ets'),DiagnosticPolicy:{hasTestHooks:()=>false},formatBytes:String,UPDATE_MANIFEST_URLS:[],formatError:String,DistributionPolicy:{allowSideloadUpdates:()=>true},
  ThemeMode:{SYSTEM:0},resolveTheme:()=>({}),resolveIsDark:()=>false,
  LedgerState:{RUNNING:0,SUCCESS:1,FAILED:2,ABORTED:3,INTERRUPTED:5},AppLogger:{info(){},warn(){},error(){}},
  ledgerHas:(_d,id)=>rows.has(id),ledgerManifest:(_d,id)=>rows.get(id)||null,
  ledgerBegin:(_d,id,m)=>{rows.set(id,{activityId:id,runNonce:'fixture-'+id,...rows.get(id),...m,state:0});return true;},
  ledgerDirOf:(_d,id)=>'/sandbox/logs/ledger/'+id,
  // 调用方测试保留真实Activity/AtomicWriter/Core；只在账本端口注入等待/故障，不伪造设备writer。
  ledgerEndAsync:async(_d,id,o)=>{counters.ledgerEnds++;if(faults.ledgerGate)await faults.ledgerGate.promise;
   if(faults.ledgerEnd)throw Error('账本终态IO故障fixture');rows.set(id,{...rows.get(id),...o});}};
 Object.assign(common,load('commons/src/main/ets/utils/AtomicFileWriter.ets'));
 core=load('feature_core/src/main/ets/download/UnifiedDownloadTask.ets');Object.assign(core,load('feature_core/src/main/ets/download/DownloadTaskRegistry.ets'));
 // 默认替身的写入在返回前已同步退出；purge=true只声明这一平台事实。延迟收敛专项
 // 可覆盖此端口并注入release gate，真实Coordinator/Registry/事务仍按生产实现执行。
 core.DownloadManager={instance:()=>({getTasks:()=>[],async fetchText(){return JSON.stringify(candidate);},async createAndWait(spec,progress){counters.download++;if(delayDownload)await fetchGate.promise;fs.writeFileSync(mapped(spec.files[0].localPath),data);progress({taskId:1,bytesDone:data.length,bytesTotal:data.length,speedBps:5,finished:true});},cancel(){},purgeTask:()=>true,async awaitTaskReleased(){}})};
 update=load('update/src/main/ets/SideloadUpdateModels.ets');Object.assign(update,load('update/src/main/ets/SideloadTransactionPolicy.ets'),load('update/src/main/ets/GitHubUpdateAssetResolver.ets'),load('update/src/main/ets/AppUpdatePolicy.ets'),load('update/src/main/ets/UpdateChecker.ets'));
 const {SigningVault}=load('entry/src/main/ets/sideload/SigningVault.ets'),vault=new SigningVault(context);
 if(!expireMaterialFirst)await vault.importBundle(JSON.stringify({schema:1,keyAlias:'fixture',keyPassword:'test-only',storePassword:'test-only',signAlg:'SHA256withECDSA',
  p12Base64:Buffer.from('p12 fixture').toString('base64'),certificateBase64:Buffer.from('cert fixture').toString('base64'),profileBase64:Buffer.from('profile fixture').toString('base64')}));
 const {SideloadUpdateCoordinator:Coordinator}=load('entry/src/main/ets/sideload/SideloadUpdateCoordinator.ets');coordinator=Coordinator.get(context);
 const {SideloadUpdateViewModel:ViewModel}=load('entry/src/main/ets/sideload/SideloadUpdateViewModel.ets');
 const render=(autoStart=true)=>{const view=new ViewModel();view.initialize(context,{manifest:candidate,autoStart});coordinator.setAbilityForeground(true);view.onForeground();view.onShown();return view;};
 /** 窗口平台替身仅提供真实查询与事件；实际Content监听器自行决定如何合成前台，测试不写private gate。 */
 const mountContent=({showing=true,focused=false}={})=>{
  const events=new Map(),stageEvents=new Map(),facts={showing,focused};
  const appWindow={isWindowShowing:()=>facts.showing,isFocused:()=>facts.focused,getWindowProperties:()=>({isKeepScreenOn:false}),async setWindowKeepScreenOn(){},on:(type,listener)=>events.set(type,listener),off:type=>events.delete(type)};
  const stage={getMainWindowSync:()=>appWindow,on:(type,listener)=>stageEvents.set(type,listener),off:type=>stageEvents.delete(type)};
  const wrapper={...context,windowStage:stage};const {SideloadUpdateContent}=load('entry/src/main/ets/components/SideloadUpdateContent.ets');
  const component=new SideloadUpdateContent();component.params={manifest,autoStart:true};component.getUIContext=()=>({getHostContext:()=>wrapper});
  component.aboutToAppear();component.viewModel.onShown();mounted.add(component);
  return{component,view:component.viewModel,facts,stage(event){stageEvents.get('windowStageLifecycleEvent')?.(windowKit.WindowStageLifecycleEventType[event]);},focus(event){events.get('windowEvent')?.(windowKit.WindowEventType[event]);},retry(){component.retryConnection();},dispose(){component.aboutToDisappear();}};
 };
 lifecycle.defer(async()=>{
  // 所有断言已结束才取消宿主模拟任务；安装状态仍由原 owner 处理，清理不伪造安装成功或账本终态。
  closing=true;for(const timer of timers)clearTimeout(timer);timers.clear();
  for(const component of mounted)component.aboutToDisappear();mounted.clear();
  coordinator.setAbilityForeground(false);coordinator.cancel();coordinator.closeLogin();
  // 人工挂起的边界必须先解除，否则连接/签名/导入的真实 finally 永远没有机会释放句柄。
  fetchGate.resolve();signGate.resolve();connectionGate.resolve('A'.repeat(64));closeGate.resolve();
  encryptionGate?.resolve();faults.ledgerGate?.resolve();for(const operation of authBegins)operation.gate.resolve();
  let timeout;try{
   await Promise.race([(async()=>{while(pending.size)await Promise.allSettled([...pending]);})(),
    new Promise((_,reject)=>{timeout=setTimeout(()=>reject(new Error('fixture asynchronous teardown timed out; retained '+physical)),10000);})]);
  }finally{clearTimeout(timeout);}
  // 等待上述链完成后才关闭本 fixture 仍持有的真实文件描述符；Windows 不靠强删绕过打开句柄。
  for(const handle of [...handles.values()])kitfs.closeSync(handle);
  assert.equal(handles.size,0);assert.equal(timers.size,0);assert.equal(pending.size,0);
 });
 return{coordinator,core,load,rows,counters,faults,fetchGate,signGate,connectionGate,closeGate,authBegins,authSessions,render,mountContent,context,environment,mapped,kitfs,vault,storage,setObservation(v){observation=v;},authorize(index=authBegins.length-1){account='valid';const operation=authBegins[index];if(operation){operation.auth.valid=true;operation.callback(true,'fixture success');}else authObject.valid=true;},expireAccount(){account='expired';authObject.valid=false;},setEncryptionGate(g){encryptionGate=g;}};
}
/** 完整旧持久记录由真实Repository加载；不靠修改Coordinator private字段构造结果。 */
const record=(phase='verified')=>({schema:1,id:oldId,phase,asset:{...target,tag:'v1.5.0',versionCode:phase==='verified'?1:2,versionName:'1.5.0'},
 beforeVersionCode:0,beforeUid:42,sameVersionTest:false,expectedPayloadIdentity:payload,
 unsignedPath:'/sandbox/sideload-update/tasks/'+oldId+'/unsigned.hap',signedPath:'/sandbox/sideload-update/tasks/'+oldId+'/signed.hap',
 signedSha256:'e'.repeat(64),restartNonce:oldNonce,createdAt:1,updatedAt:2,confirmedAt:phase==='verified'?3:0,error:''});


export {fixture,record,deferred,settle,target,manifest,payload,sha};
