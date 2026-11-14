/**
 * prepare无高层计划以后出现的晚到单槽journal：执行真实Bridge/Manager/Storage/Lease，
 * legacy记录由生产ArkTS publisher实际生成；Native只替I/O恢复结果，不复制其状态机。
 * 可独立执行，也由现有plan套件调用；全部夹具在内存，句柄/真实租约语义替身逐例归还。
 */
import fs from 'node:fs';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {makePureEtsLoader} from './lib/load-pure-ets.mjs';

export async function runLateJournalRegression(){
  let harness=fs.readFileSync(new URL('./test-runtime-catalog-install.mjs',import.meta.url),'utf8');
  harness=harness.slice(0,harness.indexOf('const results=[];')).replace(/^import[^\n]+\n/gm,'');
  const body=String.raw`
const context={filesDir:'/app',cacheDir:'/cache'},target={product:'sideload',versionName:'1.0.6',versionCode:1000910,sha256:'a'.repeat(64),sourceRevision:'b'.repeat(40),runtimeHostProtocols:[1,2],runtimePlanProtocol:1};
const receiptLimit=load('launch/src/main/ets/RuntimeCatalogTypes.ets').RUNTIME_INSTALL_RECEIPT_LIMIT;
const codec=load('launch/src/main/ets/RuntimeReceiptCodec.ets');
const initialOpen=io.openSync,initialStat=io.statSync,initialRename=io.renameSync;
const lockedFiles=new Map(),warnings=[];let fault=false,nativeRecoveries=0;
io.OpenMode.READ_WRITE=8;
io.openSync=(p,flags)=>{const file=initialOpen(p,flags);file.tryLock=exclusive=>{if([...lockedFiles.values()].some(x=>x.path===p&&(exclusive||x.exclusive)))throw Error('flock busy');lockedFiles.set(file.fd,{path:p,exclusive});};file.unlock=()=>lockedFiles.delete(file.fd);return file;};
io.statSync=p=>initialStat(handles.has(p)?handles.get(p).p:p);
io.renameSync=(a,b)=>{if(fault&&b==='/app/jdk/21')throw Error('late publication/recovery I/O still failing');return initialRename(a,b);};
const constants=makePureEtsLoader()('commons/src/main/ets/common/Constants.ets');
const commons={...constants,...makePureEtsLoader()('commons/src/main/ets/common/RuntimeRequirementPolicy.ets'),ensureDirSync:ensure,removeDirRecursive:remove,stringToUtf8:v=>new Uint8Array(Buffer.from(v)),AppLogger:{warn:(...v)=>warnings.push(v),info(){},error(){},debug(){}},LogTags:{SVC_JDK:'JDK'},LOG_DOMAIN_LAUNCH:0};
const RealLease=makePureEtsLoader({'@kit.CoreFileKit':{fileIo:io},commons})('launch/src/main/ets/JdkDirectoryLease.ets').JdkDirectoryLease;
const storageLoader=makePureEtsLoader({'@kit.CoreFileKit':{fileIo:io},commons,'./JdkDirectoryLease':{JdkDirectoryLease:RealLease},'./JdkTreeValidation':{validateRuntimeTree:p=>files.has(p+'/valid')?'':'missing'}});
const Storage=storageLoader('launch/src/main/ets/JdkInstallStorage.ets').JdkInstallStorage;
const Legacy=storageLoader('launch/src/main/ets/JdkInstallJournal.ets').JdkInstallJournal;
storageLoader('launch/src/main/ets/JdkInstallStorage.ets').setJdkInstallNativeOps({
  operation(action,filesDir,major,_stage,writer,use){
    const journal=filesDir+'/jdk/.locks/'+major+'.journal';
    if(action==='pending')return files.has(journal)?'yes':'no';if(action==='collect')return '';
    if(action==='recover'){
      assert.equal(lockedFiles.get(writer)?.path,filesDir+'/jdk/.locks/'+major+'.writer');assert.equal(lockedFiles.get(use)?.path,filesDir+'/jdk/.locks/'+major+'.use');
      nativeRecoveries++;if(fault)throw Error('late native recovery I/O still failing');
      io.renameSync(filesDir+'/jdk/'+major+'.backup-late',filesDir+'/jdk/'+major);files.delete(journal);return '';
    }
    throw Error('unexpected Native boundary action '+action);
  },async extract(){return true;},async seal(){return true;}
});
// 注册表故意仅提供17；21必须从恢复后的磁盘发现，不能靠预先枚举的假Manager列表通过。
const repository={definitions:()=>[{id:'java17',javaMajor:17}],buildFor:()=>undefined,hostUpgradeReason:()=>'',snapshot:()=>({schemaVersion:2,runtimes:[],builds:[]}),recommendationUnavailableReason:()=>''};
const RealManager=makePureEtsLoader({'@kit.CoreFileKit':{fileIo:io},'@kit.PerformanceAnalysisKit':{hilog:{}},commons,mods:{},feature_core:{},
  './JdkDirectoryLease':{JdkDirectoryLease:RealLease},'./JdkInstallStorage':{JdkInstallStorage:Storage},'./JdkInstaller':{JdkInstaller:Installer},'./RuntimeCatalogRepository':{RuntimeCatalogRepository:{instance:()=>repository}},
  './RuntimeHostProtocol':{runtimeHostProtocols:()=>[1,2]},'./RuntimeHostDeclaration':{validateRuntimeHostDeclaration:()=>''},'./JdkTreeValidation':{validateRuntimeTree:p=>files.has(p+'/valid')?'':'missing'},'./LaunchJdkPolicy':{},'./RuntimeCatalogValidation':{runtimeRequiredHost:(_c,b)=>b.requiredHostProtocol}
})('launch/src/main/ets/JdkManager.ets').JdkManager;
const slotCrypto={cryptoFramework:{createMd:()=>{const h=createHash('sha256');return{updateSync:v=>h.update(v.data),digestSync:()=>({data:new Uint8Array(h.digest())})};}}};
const Bridge=makePureEtsLoader({'@kit.CoreFileKit':{fileIo:io,statfs:{getFreeSizeSync:()=>1e10}},'@kit.CryptoArchitectureKit':slotCrypto,commons,
  launch:{...codec,...makePureEtsLoader({'@kit.CoreFileKit':{fileIo:io}})('launch/src/main/ets/RuntimeHostDeclaration.ets'),RUNTIME_INSTALL_RECEIPT_LIMIT:receiptLimit,JdkManager:RealManager,JdkInstaller:Installer,JdkDirectoryLease:RealLease,JdkInstallStorage:Storage,RuntimeCatalogRepository:{instance:()=>repository},runtimeRecommendationIds:r=>r.recommendedBuildIds,runtimeRequiredHost:(_c,b)=>b.requiredHostProtocol,runtimeHostProtocols:()=>[1,2],runtimeRequiredCapabilities:()=>[]}
})('entry/src/main/ets/runtime/AppJdkUpdatePlanRuntime.ets').AppJdkUpdatePlanRuntime;
function receipt(big){const c=config();c.runtime={...c.runtime,id:'java21',javaMajor:21,loaderProtocol:2};c.build={id:'late-21',runtimeId:'java21',requiredHostProtocol:2,notes:big?Array.from({length:24},()=> '中'.repeat(1000)):[]};return codec.serializeRuntimeInstallReceipt(c.runtime,c.build,21,c.sha256,c.sizeBytes,'2026-10-31T00:00:00.000Z');}
function payload(path,big){ensure(path);files.set(path+'/valid',Buffer.from('runtime'));files.set(path+'/.amcl_release_tag',Buffer.from('late-21'));files.set(path+'/.amcl-runtime-receipt.json',Buffer.from(receipt(big)));}
function setup(){reset();ensure('/app/jdk/.locks');ensure('/cache');files.set('/app/jdk/17/.amcl_release_tag',Buffer.from('installed-host2'));files.set('/app/jdk/17/.amcl-runtime-receipt.json',Buffer.from(JSON.stringify({build:{requiredHostProtocol:2},runtime:{loaderProtocol:2}})));fault=false;warnings.length=0;}
function assertReleased(){assert.equal(lockedFiles.size,0);assert.equal(handles.size,0);}
let dispatched=false;
async function installAfterRestore(id){await Bridge.restore(context,id,target);Bridge.assertTargetDataCompatibility(context,target);dispatched=true;}
const cases=[];
for(const format of ['legacy','native'])for(const big of [false,true]){
  setup();const id='late-'+format+'-'+big;await Bridge.prepare(context,id,target);assert.equal(Bridge.pending(context),false);
  // prepare之后普通writer已结束，在两次rename之间遗留backup+journal；旧runtime目录暂缺。
  if(format==='legacy'){
    let writer=RealLease.writer('/app','21');const first='/app/jdk/.staging-late-first';payload(first,big);
    try{await Legacy.publish('/app','21',first);}finally{writer.release();}
    const second='/app/jdk/.staging-late-second';payload(second,false);fault=true;writer=RealLease.writer('/app','21');
    try{await assert.rejects(Legacy.publish('/app','21',second),/I\/O still failing/);}finally{writer.release();}
  }else{
    const writer=RealLease.writer('/app','21'),use=RealLease.publication('/app','21');
    try{payload('/app/jdk/21.backup-late',big);files.set('/app/jdk/.locks/21.journal',Buffer.from('native boundary-owned journal'));}finally{use.release();writer.release();}
    fault=true;
  }
  const journal='/app/jdk/.locks/21.'+(format==='legacy'?'publish.json':'journal'),before=files.get(journal).toString();
  assert.equal(files.has('/app/jdk/21/valid'),false);assert.deepEqual(Storage.pendingRecoveryMajors('/app'),['21']);assertReleased();
  dispatched=false;await assert.rejects(installAfterRestore(id),/I\/O still failing/);assert.equal(dispatched,false);
  assert.equal(files.get(journal).toString(),before);assert([...dirs].some(p=>p.startsWith('/app/jdk/21.backup-')));assertReleased();
  // 独立最终断言也必须先看到bank，不能由Manager吞warn再以空结构集合返回。
  assert.throws(()=>Bridge.assertTargetDataCompatibility(context,target),/单槽恢复尚未完成/);assert.equal(files.get(journal).toString(),before);assertReleased();
  fault=false;dispatched=false;
  if(big){await assert.rejects(installAfterRestore(id),/读取能力不足/);assert.equal(dispatched,false);Bridge.assertTargetDataCompatibility(context,{...target,runtimePlanProtocol:2});}
  else{await installAfterRestore(id);assert.equal(dispatched,true);}
  assert.equal(files.has('/app/jdk/21/valid'),true);assert.equal(files.has(journal),false);assert.deepEqual(Storage.pendingRecoveryMajors('/app'),[]);assertReleased();
  cases.push({format,largeReceipt:big,recoveryFailureBlockedDispatch:true,recoveredNumericSlot:true,reader1Allowed:!big,reader2Allowed:true});
}
// 未登记major、损坏记录和异常命名也不能通过“当前无物理槽”变成可安装。
for(const name of ['29.journal','21.publish.json','unknown.journal']){
  setup();files.set('/app/jdk/.locks/'+name,Buffer.from('invalid record'));assert.throws(()=>Bridge.assertTargetDataCompatibility(context,target),/单槽恢复尚未完成|无法识别/);
  assert.equal(files.get('/app/jdk/.locks/'+name).toString(),'invalid record');assertReleased();
}
return {passed:cases.length+3,cases,nativeRecoveryCalls:nativeRecoveries,productionManager:true,physicalDiscoveryAfterRecovery:true,scope:'production Bridge+Manager+Storage+Lease; real legacy journal producer/recovery; Kit filesystem and Native I/O boundaries; no device or BMS execution'};
`;
  const AsyncFunction=Object.getPrototypeOf(async function(){}).constructor;
  return new AsyncFunction('assert','createHash','makePureEtsLoader',harness+body)(assert,createHash,makePureEtsLoader);
}
if(process.argv[1]===fileURLToPath(import.meta.url))console.log(JSON.stringify(await runLateJournalRegression(),null,2));
