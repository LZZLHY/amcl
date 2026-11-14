/**
 * 生产Index→真实Registry→生产JdkInstallTask→耐久intent互操作。Installer和Manager的
 * JVM/结构资格为显式port；不把Kit夹具的文件称作真实JDK。子进程直接退出覆盖预约前后交接。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import {spawnSync} from 'node:child_process';
import compiler from './lib/ets-compiler.mjs';
import {fixture,settle,deferred} from './lib/sideload-coordinator-fixture.mjs';
import {createHostTestScope} from './lib/host-test-lifecycle.mjs';
function methods(file,owner,names){const text=fs.readFileSync(new URL('../'+file,import.meta.url),'utf8'),ast=compiler.createSourceFile(file,text,compiler.ScriptTarget.Latest,true);
  const type=ast.statements.find(value=>value.name?.getText(ast)===owner);return names.map(name=>{const member=type.members.find(value=>value.name?.getText(ast)===name);assert(member,name);return member.getText(ast);}).join('\n');}
const indexMethods=methods('entry/src/main/ets/pages/Index.ets','Index',['resumeRuntimeDependency_','showLegacyRuntimeIntent_','showUnusableRuntimeIntent_','checkRuntimeUpdates_']);
const factoryMethod=methods('launch/src/main/ets/JdkManager.ets','JdkManager',['createInstaller']);
const compile=text=>compiler.transpileModule(text,{compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020}}).outputText;
async function harness({initialIntent,initialReceipt,crash,gate,drift=false,cancelled=false}={}){
  const f=await fixture({initialIntent,initialEnvironment:{hostProtocols:[1]}}),api=f.load('launch/src/main/ets/RuntimeAppDependency.ets').RuntimeAppDependency;
  const c={schemaVersion:2,channel:'preview',runtimes:[{id:'java17',javaMajor:17,recommendedBuildIds:['new2']}],builds:[{id:'new2',runtimeId:'java17',requiredHostProtocol:2,status:'available',archive:{sha256:'a'.repeat(64),sizeBytes:100}}]};
  const repository={snapshot:()=>structuredClone(c),recommendationUnavailableReason:()=>'',isBuildAllowed:id=>c.builds.some(b=>b.id===id&&b.status==='available'),
    buildFor:()=>c.builds[0],async configure(){},async refresh(){return{ok:true};},hostUpgradeReason:()=>''};
  let starts=0,created=0;const config={available:true,tag:'new2',runtime:c.runtimes[0],build:c.builds[0],sha256:'a'.repeat(64),sizeBytes:100};
  const receiptFile='/sandbox/jdk/17/.amcl-runtime-receipt.json';
  function putReceipt(){fs.writeFileSync(f.mapped(receiptFile),JSON.stringify({schemaVersion:1,origin:'catalog',javaMajor:17,runtimeId:'java17',buildId:'new2',archiveSha256:config.sha256,archiveSizeBytes:100}));}
  if(initialReceipt)fs.writeFileSync(f.mapped(receiptFile),initialReceipt);
  const checkpoint=()=>crash?.({intent:f.kitfs.readTextSync('/sandbox/runtime-app-intent.json'),receipt:f.kitfs.accessSync(receiptFile)?f.kitfs.readTextSync(receiptFile):undefined,starts});
  class Installer {
    constructor(options){created++;this.options=options;if(crash?.point==='factory')checkpoint();}
    setDownloadCallback(callback){this.callback=callback;}
    async downloadAndInstall(){starts++;if(gate)await gate.promise;if(cancelled){taskAdapter.cancelRequested_=true;return true;}putReceipt();if(crash?.point==='installed')checkpoint();return true;}
  }
  const configs={'17':config},managerExports={};vm.runInNewContext(compile('class Manager {'+factoryMethod+'}\nexports.Manager=Manager;'),{
    exports:managerExports,JDK_VERSIONS:configs,JdkInstaller:Installer,AppLogger:{warn(){}},TAG:'intent-test',JSON});
  const manager=new managerExports.Manager();Object.assign(manager,{context:f.context,synchronizeCatalog(){if(drift)configs['17']={...config,sha256:'f'.repeat(64)};},
    getJdkDir:()=>'/sandbox/jdk/17',isInstalled:()=>f.kitfs.accessSync(receiptFile)});
  const {JdkInstallTask:Task}=f.load('launch/src/main/ets/JdkInstallTask.ets');let taskAdapter;
  class ObservedTask extends Task{constructor(...args){super(...args);taskAdapter=this;}}
  const exported={};vm.runInNewContext(compile('class Page {'+indexMethods+'}\nexports.Page=Page;'),{
    exports:exported,RuntimeAppDependency:api,RuntimeCatalogRepository:{instance:()=>repository},JdkInstallTask:ObservedTask,
    UnifiedTaskState:f.core.UnifiedTaskState,AppStorage:{get:()=>true},Promise,Date});
  const registry=f.core.DownloadTaskRegistry.instance(),dialogs=[];
  function page(){const page=new exported.Page();Object.assign(page,{context:f.context,registry,jdkChannel:'preview',jdkSource:'github',jdkWebEnabled:false,
    runtimeDependencyResuming_:false,startupAlive_:true,jdkChecking:false,showPrivacy:false,theme:{actionText:'#000',textSecondary:'#777'},
    getJdkManager_:()=>manager,updateJdkReadyState(){},showRuntimeDependencyRecovery_:result=>dialogs.push(result),
    getUIContext:()=>({getPromptAction:()=>({showDialog:async()=>({index:0})})})});return page;}
  function remember(){f.environment.hostProtocols=[1];const generation=api.remember(f.context,repository,api.requirements(repository,['17']));
    const binding={transactionId:'b'.repeat(32),assetSha256:'c'.repeat(64),product:'sideload',versionName:'2.0.0',versionCode:2};
    api.bindApp(f.context,generation,binding);api.markAppVerified(f.context,{...binding,installId:'d'.repeat(32),uid:42,sourceRevision:'e'.repeat(40),verifiedAt:Date.now()+1,runtimeIntentId:generation});
    f.environment.hostProtocols=[1,2];return generation;}
  if(!initialIntent)remember();else f.environment.hostProtocols=[1,2];
  return {f,api,c,repository,manager,registry,page,dialogs,remember,read:()=>JSON.parse(f.kitfs.readTextSync('/sandbox/runtime-app-intent.json')),counts:()=>({starts,created})};
}

if(process.argv[2]==='--child'){
  const directory=path.resolve(process.argv[3]),input=JSON.parse(fs.readFileSync(path.join(directory,'input.json'),'utf8'));
  const crash=value=>{fs.writeFileSync(path.join(directory,'checkpoint.json'),JSON.stringify(value));process.exit(77);};crash.point=input.point;
  const h=await harness({crash});await h.page().resumeRuntimeDependency_(true);throw Error('intent checkpoint was not reached');
}else{
  let passed=0;const scope=createHostTestScope('intent-admission-');
  {
    const h=await harness(),release=h.registry.acquireReplacementLease(),page=h.page();await page.resumeRuntimeDependency_(true);
    assert.equal(h.counts().starts,0);assert.equal(h.read().intents[0].state,'retry');release();
    await page.resumeRuntimeDependency_(true,true);assert.equal(h.dialogs.length,1);assert.equal(h.counts().starts,0);
    h.api.retryInterrupted(h.f.context,h.read().generation,['17']);await page.resumeRuntimeDependency_(true);
    assert.equal(h.counts().starts,1);assert.equal(h.read().phase,'complete');h.f.coordinator.setAbilityForeground(false);passed++;
  }
  {
    const h=await harness({drift:true});await h.page().resumeRuntimeDependency_(true);assert.equal(h.counts().created,0);assert.equal(h.counts().starts,0);
    assert.equal(h.read().intents[0].state,'retry');h.f.coordinator.setAbilityForeground(false);passed++;
  }
  {
    const h=await harness({cancelled:true});await h.page().resumeRuntimeDependency_(true);assert.equal(h.read().intents[0].state,'cancelled');
    await h.page().resumeRuntimeDependency_(true);assert.equal(h.counts().starts,1,'ABORTED resolve never reopens automatically');h.f.coordinator.setAbilityForeground(false);passed++;
  }
  {
    const gate=deferred(),h=await harness({gate}),first=h.page().resumeRuntimeDependency_(true);await settle();
    const second=h.page().resumeRuntimeDependency_(true);await settle();assert.equal(h.counts().starts,1);gate.resolve();await Promise.all([first,second]);
    assert.equal(h.read().phase,'complete');h.f.coordinator.setAbilityForeground(false);passed++;
  }
  {
    const h=await harness(),gate=deferred(),view=new h.f.core.UnifiedTaskView();
    Object.assign(view,{id:'jdk:17',title:'旧的不同构建任务',category:h.f.core.TaskCategory.JDK,state:h.f.core.UnifiedTaskState.PREPARING});
    const other={view,async start(){await gate.promise;fs.writeFileSync(h.f.mapped('/sandbox/jdk/17/.amcl-runtime-receipt.json'),JSON.stringify({schemaVersion:1,origin:'catalog',javaMajor:17,runtimeId:'java17',buildId:'other',archiveSha256:'f'.repeat(64),archiveSizeBytes:100}));view.state=h.f.core.UnifiedTaskState.DONE;},async cancel(){}};
    const existing=h.registry.enqueue(other);await settle();await h.page().resumeRuntimeDependency_(true);
    assert.equal(h.counts().created,0);assert.equal(h.read().intents[0].state,'pending','unknown active task is never treated as our admission');
    gate.resolve();await existing;await h.page().resumeRuntimeDependency_(true);assert.equal(h.counts().starts,1);assert.equal(h.read().phase,'complete');h.f.coordinator.setAbilityForeground(false);passed++;
  }
  {
    const gate=deferred(),h=await harness({gate}),old=h.page().resumeRuntimeDependency_(true);await settle();const fresh=h.remember();
    gate.resolve();await old;assert.equal(h.read().generation,fresh);assert.equal(h.read().intents[0].state,'pending','old callback cannot ack same SHA in new generation');
    await h.page().resumeRuntimeDependency_(true);assert.equal(h.counts().starts,1,'new generation reconciles its own already-installed payload');assert.equal(h.read().phase,'complete');h.f.coordinator.setAbilityForeground(false);passed++;
  }
  for(const point of ['factory','installed']){
    const directory=path.join(scope.directory,point);fs.mkdirSync(directory);fs.writeFileSync(path.join(directory,'input.json'),JSON.stringify({point}));
    const child=spawnSync(process.execPath,[import.meta.filename,'--child',directory],{env:{...process.env,AMCL_TEST_OUTPUT_DIR:directory},encoding:'utf8',timeout:30000});
    assert.equal(child.status,77,point+'\n'+child.stdout+'\n'+child.stderr);const saved=JSON.parse(fs.readFileSync(path.join(directory,'checkpoint.json'),'utf8'));
    const h=await harness({initialIntent:saved.intent,initialReceipt:saved.receipt}),page=h.page();await page.resumeRuntimeDependency_(true);
    if(point==='factory'){assert.equal(h.read().intents[0].state,'delivering');assert.equal(h.counts().starts,0);await page.resumeRuntimeDependency_(true,true);assert.equal(h.dialogs.length,1);
      h.api.retryInterrupted(h.f.context,h.read().generation,['17']);await page.resumeRuntimeDependency_(true);assert.equal(h.counts().starts,1);}
    else {assert.equal(h.read().phase,'complete');assert.equal(h.counts().starts,0,'actual installed receipt prevents crash replay');}
    h.f.coordinator.setAbilityForeground(false);passed++;
  }
  {
    const h=await harness(),raw=JSON.stringify({schemaVersion:1,channel:'preview',createdAt:Date.now(),appVerified:false,intents:[{major:'17',buildId:'new2',sha256:'a'.repeat(64),requiredHostProtocol:2}]});
    fs.writeFileSync(h.f.mapped('/sandbox/runtime-app-intent.json'),raw);assert.equal(h.api.requirements(h.repository,['17']).length,0,'current host already supports original requirement');
    const page=h.page();await page.checkRuntimeUpdates_(true);const archived=h.read();assert.equal(archived.phase,'archived-legacy');
    assert.equal(h.f.kitfs.readTextSync('/sandbox/'+archived.legacyArchive),raw);assert.equal(h.api.hasVerifiedIntent(h.f.context),false);assert.equal(h.counts().starts,0);
    await page.resumeRuntimeDependency_(true);assert(!String(page.jdkCatalogStatus).includes('等待：旧JDK'));h.remember();
    assert.throws(()=>h.api.archiveLegacy(h.f.context,raw),/改变/);assert.equal(h.read().phase,'active','late legacy confirmation never archives a new generation');
    h.f.coordinator.setAbilityForeground(false);passed++;
  }
  {
    const h=await harness(),original=h.f.kitfs.readTextSync('/sandbox/runtime-app-intent.json');
    h.c.builds[0].id='new3';h.c.runtimes[0].recommendedBuildIds=['new3'];
    assert.equal(h.api.requirements(h.repository,['17']).length,0,'already compatible App cannot reach remember through host-upgrade dialog');
    await h.page().resumeRuntimeDependency_(true,true);const archived=h.read();assert.equal(archived.phase,'archived');
    assert.equal(h.f.kitfs.readTextSync('/sandbox/'+archived.legacyArchive),original);assert.equal(h.api.hasVerifiedIntent(h.f.context),false);assert.equal(h.counts().starts,0);
    h.remember();assert.throws(()=>h.api.archiveUnusable(h.f.context,original),/改变/);assert.equal(h.read().phase,'active');
    h.f.coordinator.setAbilityForeground(false);passed++;
  }
  {
    const h=await harness(),unconfirmed=h.read();delete unconfirmed.completion;fs.writeFileSync(h.f.mapped('/sandbox/runtime-app-intent.json'),JSON.stringify(unconfirmed));
    const original=h.f.kitfs.readTextSync('/sandbox/runtime-app-intent.json');await h.page().checkRuntimeUpdates_(true);
    const marker=h.read();assert.equal(marker.phase,'archived');assert.equal(h.f.kitfs.readTextSync('/sandbox/'+marker.legacyArchive),original);
    assert.equal(h.counts().starts,0,'manual abandonment of an unconfirmed permission never dispatches its target');h.f.coordinator.setAbilityForeground(false);passed++;
  }
  console.log(JSON.stringify({passed,scope:'production Index, Registry, JdkInstallTask, precise factory and durable intent; installer/JVM qualification ports, two actual child exits'},null,2));
}
