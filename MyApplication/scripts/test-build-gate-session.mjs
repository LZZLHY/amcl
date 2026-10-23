/**
 * 分轨会话资格的永久正负回归：只创建仓外微型 Git fixture，不构建 HAP 或操作设备。
 * 合成 HAP/provenance 仅核对账本绑定，不把测试中的签名结果字符串当成实际签名验证。
 * 覆盖目标隔离、未知命令回退、延期闭包、状态收口、源/环境漂移和租约所有权。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {chooseProfile,decision,environmentIdentity,snapshot,start,event,finish} from './lib/build-gate-session.mjs';
import {assertExternalOutputPath,resolveWorkspacePath} from './lib/workspace-paths.mjs';

const index=process.argv.indexOf('--out');
if(index>=0&&!process.argv[index+1]) throw new Error('Missing --out');
let output;
if(index>=0) {
  output=assertExternalOutputPath(path.resolve(process.argv[index+1]));
  if(fs.existsSync(output)) throw new Error('Evidence directory must be new');fs.mkdirSync(output,{recursive:true});
} else {
  const parent=resolveWorkspacePath('run','gate-session-regression');fs.mkdirSync(parent,{recursive:true});output=fs.mkdtempSync(path.join(parent,'case-'));
}
const originalEnvironment={...process.env};
// 外部真实 SDK/JDK 不属于本测试输入；微型 fixture 通过专门案例验证外部目录内容。
for(const name of ['JAVA_HOME','AMCL_JVM_TEST_JAVA_HOME','AMCL_LWJGL2_INPUTS','AMCL_LWJGL2_JDK8','AMCL_NAPI_SDK_INCLUDE','OHOS_SDK_ROOT','AMCL_GATE_SESSION_SDK_ROOT','AMCL_SDL_TEST_REPO']) delete process.env[name];
process.env.AMCL_WORKSPACE_ROOT=path.join(output,'workspace');
const results=[];const digest=value=>crypto.createHash('sha256').update(value).digest('hex');
// 仅 JS 单元夹具显式注入宿主身份；生产 CLI 没有此参数，不能跳过真实 VS/SDK 扫描。
const fixtureOptions={hostToolchainProvider:()=>({state:'AVAILABLE',fixture:true})};
const fixtureSnapshot=(root,tools=[])=>snapshot(root,tools,fixtureOptions);
const allowed='entry/src/main/ets/pages/tabs/DownloadTab.ets';
const gate={id:'known',script:'scripts/known.mjs',tool:'node',kind:'behavior',domain:'input',quick:'affected',cachePolicy:'never',dependsOn:[],surfaces:['build-hap.ps1']};

/** 固定本地Git清单，不依赖主工程 HEAD/用户配置；运行资料和假产物始终在Git目录外。 */
function fixture(name,{gitRepository=true,catalog=true}={}) {
  const base=path.join(output,name), root=path.join(base,'source');fs.mkdirSync(path.join(root,'config'),{recursive:true});
  fs.mkdirSync(path.join(root,'scripts'),{recursive:true});fs.mkdirSync(path.dirname(path.join(root,allowed)),{recursive:true});
  fs.writeFileSync(path.join(root,allowed),'initial UI');fs.writeFileSync(path.join(root,'other.cpp'),'initial native');
  fs.writeFileSync(path.join(root,'build-hap.ps1'),'& node "$ProjectRoot/scripts/known.mjs"\n');
  fs.writeFileSync(path.join(root,'scripts/known.mjs'),'console.log("PASS");');
  if(catalog)fs.writeFileSync(path.join(root,'config/build-gates.json'),JSON.stringify({schema:1,gates:[gate]}));
  for(const args of gitRepository?[['init'],['-c','core.autocrlf=false','add','.']]:[]) {
    const result=spawnSync('git',['-C',root,...args],{encoding:'utf8'});assert.equal(result.status,0,result.stderr);
  }
  const hap=path.join(base,'fixture.hap'), provenance=path.join(base,'development-build-provenance-signed.json');
  fs.writeFileSync(hap,'test-only payload, not a real archive');
  const proof={schema:1,purpose:'diagnostic-build-contract',product:'default',mode:'debug',hapSha256:digest(fs.readFileSync(hap)),
    signature:{artifactKind:'signed',result:'valid-signature'}};
  fs.writeFileSync(provenance,JSON.stringify(proof));
  const quickReceipt=path.join(base,'quick-build-receipt-signed.json');
  const quickProof={schema:1,purpose:'quick-development-build',validationProfile:'quick',fullQualified:false,product:'default',mode:'debug',
    hapSha256:proof.hapSha256,hapPath:hap,hapBytes:fs.statSync(hap).size,signatureVerification:{artifactKind:'signed',result:'valid-signature'}};
  fs.writeFileSync(quickReceipt,JSON.stringify(quickProof));
  let serial=0;
  return {base,root,hap,provenance,proof,quickReceipt,quickProof,
    // 原内容审计案例显式请求DeepAudit；另有普通/noGit案例证明默认分支不触发这些provider。
    begin:(profile='full',extra={})=>{process.env.AMCL_RUN_DIR=path.join(base,'runs',String(++serial));return start({root,profile,product:'default',mode:'debug',tools:'[]','deep-audit':profile==='full',...extra},fixtureOptions);},
    beginLight:(profile='quick',extra={},options=fixtureOptions)=>{process.env.AMCL_RUN_DIR=path.join(base,'runs',String(++serial));return start({root,profile,product:'default',mode:'debug',tools:'[]',...extra},options);},
    complete:(context,success=true,options=fixtureOptions)=>finish({session:context.filename,success,artifacts:JSON.stringify(context.effective==='quick'?[hap,quickReceipt]:[hap,provenance])},options)};
}

function add(context, id, state='PASS', exitCode=0,argv=[]) {
  event({session:context.filename,event:JSON.stringify({id,state,exitCode,durationMs:1,completedAt:new Date().toISOString(),reason:'fixture',
    executable:process.execPath,argv,phase:'fixture'})});
}
function coverage(context,{omit,extra}={}) {
  const session=JSON.parse(fs.readFileSync(context.filename)),profile=session.profile;
  const hap=path.join(path.dirname(session.root),'fixture.hap'),proof=path.join(path.dirname(session.root),'development-build-provenance-signed.json');
  let audits=0;
  for(const id of ['sdk-clean','sdk-arkts-unit-command','check-hvigor-test-log','sdk-assemble-hap','check-product-tu-syntax','check-product-contract',
    'check-diagnostics-contract','check-diagnostics-contract','check-diagnostics-contract']) {
    if(id===omit) continue;
    const argv=id==='check-diagnostics-contract'?[['--hap',hap],['--hap',hap,'--write-provenance',proof],['--hap',hap,'--verify-provenance',proof]][audits++]:[];
    add(context,id,id==='sdk-clean'&&profile==='quick'?'DEFERRED':'PASS',0,argv);
  }
  if(extra) add(context,extra.id,extra.state,extra.exitCode??0);
}
function quickCoverage(item,context) {
  add(context,'sdk-assemble-hap');
  add(context,'check-quick-hap','PASS',0,['--hap',item.hap,'--receipt',item.quickReceipt]);
}
async function check(name,body) {
  try {await body();results.push({name,state:'PASS'});console.log('PASS gate session: '+name);}
  catch(error) {results.push({name,state:'FAIL',error:error.stack});throw error;}
}

try {
  await check('ordinary quick and full require neither Git/catalog/baseline nor snapshot/host/SDK providers',()=>{
    for(const profile of ['quick','full']) {
      const item=fixture('ordinary-no-git-'+profile,{gitRepository:false,catalog:false});let calls=0;
      const forbidden=()=>{calls++;throw new Error('ordinary build must not enter an input scanner');};
      const options={snapshotProvider:forbidden,hostToolchainProvider:forbidden,sdkFingerprintProvider:forbidden};
      const context=item.beginLight(profile,{},options);assert.equal(context.effective,profile);
      fs.appendFileSync(path.join(item.root,'other.cpp'),' normal saved edit');
      const saved=process.env.CXX;process.env.CXX='changed compiler selection; SDK decides actual rebuild';
      try {
        if(profile==='quick')quickCoverage(item,context);else coverage(context);
        const result=item.complete(context,true,options);assert.equal(result.state,'PASS');assert.equal(result.fullQualified,profile==='full');
      } finally {if(saved===undefined)delete process.env.CXX;else process.env.CXX=saved;}
      assert.equal(calls,0);const state=JSON.parse(fs.readFileSync(context.filename));
      assert.equal(state.deepAudit,false);assert.equal(state.deepAuditState,'NOT_RUN');assert.equal(state.snapshotDurationMs,0);
      assert.ok(!Object.hasOwn(state,'snapshot'));assert.ok(!Object.hasOwn(state,'environmentInputs'));
      assert.ok(!fs.existsSync(path.join(state.runRoot,'snapshot-progress.jsonl')));
      assert.ok(!fs.existsSync(path.join(state.runRoot,'final-snapshot-progress.jsonl')));
      if(profile==='quick'){assert.deepEqual(state.events.map(row=>row.id),['sdk-assemble-hap','check-quick-hap']);assert.ok(state.notRun.includes('full-regression-suite'));}
    }
  });
  await check('quick rejects missing/failed actual checks and receipts that claim full or bind another package',()=>{
    for(const mode of ['missing-check','failed-assemble','bad-hash','fake-full','wrong-event']) {
      const item=fixture('quick-failure-'+mode,{gitRepository:false,catalog:false}),context=item.beginLight();
      add(context,'sdk-assemble-hap',mode==='failed-assemble'?'FAIL':'PASS',mode==='failed-assemble'?13:0);
      if(mode!=='missing-check')add(context,'check-quick-hap','PASS',0,['--hap',mode==='wrong-event'?item.hap+'.other':item.hap,'--receipt',item.quickReceipt]);
      if(mode==='bad-hash')item.quickProof.hapSha256='0'.repeat(64);
      if(mode==='fake-full')item.quickProof.fullQualified=true;
      fs.writeFileSync(item.quickReceipt,JSON.stringify(item.quickProof));assert.throws(()=>item.complete(context),/Quick/);
      const state=JSON.parse(fs.readFileSync(context.filename));assert.equal(state.state,'FAIL');assert.equal(state.fullQualified,false);assert.ok(!fs.existsSync(state.lock));
    }
  });
  await check('pooled hash buffer preserves exact large, short, empty and truncated file bytes',()=>{
    const item=fixture('pooled-hash'), cases=[Buffer.alloc(1024*1024+37,0xa5),Buffer.from('短文件'),Buffer.alloc(0),Buffer.from('x')];
    const filename=path.join(item.root,'other.cpp');
    // 同一个缓冲区先处理跨块大文件再处理短/空文件，实际摘要必须等于独立 SHA-256。
    for(const bytes of cases) {fs.writeFileSync(filename,bytes);assert.equal(fixtureSnapshot(item.root).files['other.cpp'],digest(bytes));}
  });
  await check('tree metadata optimization preserves exact member, empty-directory and internal-link identity',()=>{
    const item=fixture('tree-metadata'),tree=path.join(item.base,'tree');fs.mkdirSync(path.join(tree,'alpha'),{recursive:true});
    const payload=Buffer.from([0,1,255,12,0,42]);fs.writeFileSync(path.join(tree,'alpha','empty.h'),Buffer.alloc(0));
    fs.writeFileSync(path.join(tree,'alpha','payload.h'),payload);fs.mkdirSync(path.join(tree,'empty-directory'));
    fs.mkdirSync(path.join(tree,'.git'));fs.writeFileSync(path.join(tree,'.git','ignored'),'excluded metadata');
    const alias=path.join(tree,'internal-alias');fs.symlinkSync(path.join(tree,'alpha'),alias,process.platform==='win32'?'junction':'dir');
    const emptyHash=digest(Buffer.alloc(0)),payloadHash=digest(payload);
    const expected=['/','/alpha/','/alpha/empty.h:'+emptyHash,'/alpha/payload.h:'+payloadHash,'/empty-directory/',
      '/internal-alias@link:'+fs.readlinkSync(alias),'/internal-alias/','/internal-alias/empty.h:'+emptyHash,'/internal-alias/payload.h:'+payloadHash];
    process.env.AMCL_NAPI_SDK_INCLUDE=tree;
    try {
      const actual=fixtureSnapshot(item.root).external.AMCL_NAPI_SDK_INCLUDE;
      assert.equal(actual,digest(expected.join('\n')));assert.equal(fixtureSnapshot(item.root).external.AMCL_NAPI_SDK_INCLUDE,actual);
    } finally {delete process.env.AMCL_NAPI_SDK_INCLUDE;}
    for(const kind of ['escape','cycle']) {
      const directory=path.join(item.base,kind);fs.mkdirSync(directory);
      const target=kind==='escape'?path.join(item.base,'outside'):directory;
      if(kind==='escape'){fs.mkdirSync(target);fs.writeFileSync(path.join(target,'private.h'),'outside declared root');}
      fs.symlinkSync(target,path.join(directory,'link'),process.platform==='win32'?'junction':'dir');
      process.env.AMCL_NAPI_SDK_INCLUDE=directory;
      try {assert.throws(()=>fixtureSnapshot(item.root),kind==='escape'?/escapes/:/cycle/);}
      finally {delete process.env.AMCL_NAPI_SDK_INCLUDE;}
    }
  });
  await check('profiles are explicit and history/tools cannot silently change quick to full',()=>{
    const current={files:{[allowed]:'a'},external:{},environment:'env'};
    const previous={state:'PASS',profile:'full',product:'store',mode:'release',snapshot:current};
    assert.equal(chooseProfile({requested:'quick',fresh:false,product:'default',mode:'debug',previous,current,allowedChangedFiles:[allowed]}).effective,'quick');
    assert.throws(()=>chooseProfile({requested:'quik',product:'default',mode:'debug'}),/Unknown/);
    assert.throws(()=>chooseProfile({requested:'quick',product:'default',mode:'auto'}),/Unknown/);
    assert.throws(()=>chooseProfile({requested:'quick',deepAudit:true,mode:'debug'}),/full-only/);
    const unavailable={...current,external:{'@windows-host-toolchain':{state:'UNAVAILABLE',reason:'unresolved fixture toolchain'}}};
    assert.equal(chooseProfile({requested:'quick',product:'default',mode:'debug',current:unavailable}).effective,'quick');
  });

  await check('untracked/native changes no longer impose a quick baseline or trigger fallback',()=>{
    const item=fixture('pilot'), context=item.begin();coverage(context);assert.equal(item.complete(context).state,'PASS');
    const previous=JSON.parse(fs.readFileSync(path.join(JSON.parse(fs.readFileSync(context.filename)).stateRoot,'last-full.json')));
    fs.writeFileSync(path.join(item.root,allowed),'new UI');
    const current=fixtureSnapshot(item.root);
    assert.equal(chooseProfile({requested:'quick',product:'default',mode:'debug',previous,current,allowedChangedFiles:[allowed]}).effective,'quick');
    fs.writeFileSync(path.join(item.root,'untracked.h'),'new header');
    assert.equal(chooseProfile({requested:'quick',product:'default',mode:'debug',previous,current:fixtureSnapshot(item.root),allowedChangedFiles:[allowed]}).effective,'quick');
  });

  await check('ordinary selected commands run directly and DeepAudit never defers behavior gates',()=>{
    const session={profile:'quick'};
    assert.equal(decision(session,gate,[]).action,'RUN');
    for(const script of ['scripts/test-immersive-light.mjs','scripts/test-unified-actions.mjs','scripts/test-tablet-ui.mjs']) {
      assert.equal(decision(session,{...gate,script},[]).action,'RUN');
    }
    for(const id of ['test-ledger-performance','test-game-export-lifecycle']) {
      assert.equal(decision(session,{...gate,id,quickPilot:'download-tab'},[]).action,'RUN');
    }
    for(const id of ['test-game-layout-v2','test-control-groups-storage','test-gyro-policy-activation',
      'test-gamepad-analog-stability','test-owner-layout-source','test-virtual-mouse-wheel']) {
      const isolated={...gate,id,script:'scripts/'+id+'.mjs',quickPilot:'download-tab'};
      assert.equal(decision(session,isolated,[]).action,'RUN');
      assert.equal(decision({profile:'full'},isolated,[]).action,'RUN');
      assert.equal(decision(session,isolated,['--hap','current.hap']).action,'RUN');
      assert.equal(decision(session,{...isolated,quickPilot:undefined},[]).action,'RUN');
    }
    const python={...gate,tool:'python',script:'scripts/test-unrelated.py'};
    assert.equal(decision(session,python,[]).action,'RUN');
    assert.equal(decision(session,python,['--hap','current.hap']).action,'RUN');
    assert.equal(decision(session,python,['--verify-signature']).action,'RUN');
    const pure={...gate,kind:'static',deterministic:true,cachePolicy:'pass',environmentKeys:[]};
    assert.equal(decision(session,pure,[]).action,'RUN');
    assert.equal(decision({profile:'full',deepAudit:true},pure,[]).action,'CACHE');
    assert.equal(decision(session,pure,['--hap','current.hap']).action,'RUN');
    const missing={...pure};delete missing.environmentKeys;assert.equal(decision(session,missing,[]).action,'RUN');
  });

  await check('unknown HAP scripts do not auto-upgrade an explicitly requested quick',()=>{
    const item=fixture('unknown-command');
    fs.appendFileSync(path.join(item.root,'build-hap.ps1'),'& python "$ProjectRoot/scripts/new-unregistered.py"\n');
    const full=item.begin();coverage(full);item.complete(full);
    const quick=item.begin('quick');assert.equal(quick.effective,'quick');item.complete(quick,false);
  });

  await check('mandatory current SDK/TU gates cannot be absent or replaced by reused PASS',()=>{
    const item=fixture('missing-gate'), context=item.begin();coverage(context,{omit:'sdk-assemble-hap'});
    assert.throws(()=>item.complete(context),/Required current gate missing/);
    const state=JSON.parse(fs.readFileSync(context.filename));assert.equal(state.state,'FAIL');assert.ok(!fs.existsSync(state.lock));
    const quick=item.begin('quick');assert.equal(quick.effective,'quick');item.complete(quick,false);
  });

  await check('ABORTED or RUNNING events cannot be converted into full PASS',()=>{
    for(const state of ['ABORTED','RUNNING']) {
      const item=fixture('invalid-state-'+state.toLowerCase()), context=item.begin();coverage(context,{extra:{id:'interrupted-gate',state}});
      assert.throws(()=>item.complete(context),/Incomplete or failed gate/);
    }
  });

  await check('repeated gate IDs retain unique invocations, serial order and catalog dependency references',()=>{
    const item=fixture('event-chain'), catalogPath=path.join(item.root,'config/build-gates.json');
    const catalog=JSON.parse(fs.readFileSync(catalogPath));catalog.gates.push({...gate,id:'dependent',script:'scripts/dependent.mjs',dependsOn:['known']});
    fs.writeFileSync(catalogPath,JSON.stringify(catalog));
    const context=item.begin();add(context,'known','PASS',0,['known.mjs']);add(context,'dependent','PASS',0,['dependent.mjs']);add(context,'known','PASS',0,['known.mjs','again']);
    const rows=JSON.parse(fs.readFileSync(context.filename)).events;
    assert.deepEqual(rows.map(row=>row.sequence),[1,2,3]);assert.equal(new Set(rows.map(row=>row.invocationId)).size,3);
    assert.equal(rows[1].previousEventId,rows[0].invocationId);assert.ok(rows[1].dependsOn.includes(rows[0].invocationId));
    assert.deepEqual(rows[1].declaredDependencies,['known']);assert.equal(rows[2].previousEventId,rows[1].invocationId);
    assert.deepEqual(rows[2].argv,['known.mjs','again']);item.complete(context,false);
  });

  await check('provenance verify must follow a distinct write invocation',()=>{
    const item=fixture('audit-order'),context=item.begin();coverage(context,{omit:'check-diagnostics-contract'});
    add(context,'check-diagnostics-contract','PASS',0,['--verify-provenance','fixture.json']);
    add(context,'check-diagnostics-contract','PASS',0,['--write-provenance','fixture.json']);
    add(context,'check-diagnostics-contract','PASS',0,['--hap','fixture.hap']);
    assert.throws(()=>item.complete(context),/write must precede/);
  });

  await check('three ordinary audits or write/verify against another artifact cannot close current provenance',()=>{
    for(const mode of ['ordinary','wrong-proof','wrong-hap']) {
      const item=fixture('audit-binding-'+mode),context=item.begin();coverage(context);
      const state=JSON.parse(fs.readFileSync(context.filename));
      for(const row of state.events.filter(row=>row.id==='check-diagnostics-contract')) {
        if(mode==='ordinary') row.argv=['--hap',item.hap];
        else if(mode==='wrong-proof') {
          for(const flag of ['--write-provenance','--verify-provenance']) {const index=row.argv.indexOf(flag);if(index>=0) row.argv[index+1]=item.provenance+'.other';}
        } else {const index=row.argv.indexOf('--hap');row.argv[index+1]=item.hap+'.other';}
      }
      fs.writeFileSync(context.filename,JSON.stringify(state));
      assert.throws(()=>item.complete(context),/write must precede|current HAP and provenance paths/);
    }
  });

  await check('provenance must bind this HAP, target and a completed signature audit',()=>{
    for(const [name,change] of [['hap',proof=>proof.hapSha256='0'.repeat(64)],['mode',proof=>proof.mode='release'],['signature',proof=>proof.signature.result='not-requested']]) {
      const item=fixture('artifact-'+name), context=item.begin();coverage(context);change(item.proof);fs.writeFileSync(item.provenance,JSON.stringify(item.proof));
      assert.throws(()=>item.complete(context),/Provenance|signature/);
    }
  });

  await check('known internal environment assignments preserve initial identity; unexpected changes fail',()=>{
    const saved=process.env.AMCL_DIAGNOSTICS;
    const item=fixture('internal-environment'), context=item.begin();coverage(context);process.env.AMCL_DIAGNOSTICS='tests';
    try {
      assert.equal(item.complete(context).state,'PASS');
      const state=JSON.parse(fs.readFileSync(context.filename));assert.ok(state.internalEnvironmentChanges.includes('AMCL_DIAGNOSTICS'));
      assert.ok(state.snapshotDurationMs>=0);
      const initial=fs.readFileSync(path.join(state.runRoot,'snapshot-progress.jsonl'),'utf8').trim().split('\n').map(line=>JSON.parse(line));
      const final=fs.readFileSync(path.join(state.runRoot,'final-snapshot-progress.jsonl'),'utf8').trim().split('\n').map(line=>JSON.parse(line));
      assert.ok(initial.some(row=>row.stage==='sourceGit'));assert.ok(final.some(row=>row.stage==='sourceGit'));
      assert.ok([...initial,...final].every(row=>row.milliseconds>=0&&Number.isFinite(Date.parse(row.completedAt))));
    } finally {if(saved===undefined) delete process.env.AMCL_DIAGNOSTICS;else process.env.AMCL_DIAGNOSTICS=saved;}
    const bad=fixture('external-environment'), other=bad.begin();coverage(other);process.env.AMCL_UNDECLARED_SESSION_CHANGE='changed';
    try {assert.throws(()=>bad.complete(other),/environment drift/);} finally {delete process.env.AMCL_UNDECLARED_SESSION_CHANGE;}
  });

  await check('exact host call nonce is non-semantic after case normalization; SDK/compiler/PATH and unknown CODEX fields remain inputs',()=>{
    const semantic={DEVECO_SDK_HOME:'sdk-A',OHOS_SDK_ROOT:'ohos-A',CC:'clang-A',CXX:'clang++-A',PATH:'tool-path-A'};
    const first=environmentIdentity({...semantic,CODEX_TOOL_CALL_ID:'call-first'});
    for(const telemetry of [{CODEX_TOOL_CALL_ID:'call-second'},{codex_tool_call_id:'call-third'},{Codex_Tool_Call_Id:'call-fourth'}]) {
      const current={files:{[allowed]:'same-UI'},external:{fixture:'unchanged'},environment:environmentIdentity({...semantic,...telemetry})};
      const previous={state:'PASS',profile:'full',product:'default',mode:'debug',snapshot:{...current,environment:first}};
      assert.equal(current.environment,first);
      assert.equal(chooseProfile({requested:'quick',product:'default',mode:'debug',previous,current,allowedChangedFiles:[allowed]}).effective,'quick');
    }
    for(const name of [...Object.keys(semantic),'CODEX_UNDECLARED_COMPILER_FLAGS']) {
      const before={...semantic,[name]:'initial',CODEX_TOOL_CALL_ID:'call-first'};
      const current={files:{[allowed]:'same-UI'},external:{fixture:'unchanged'},environment:environmentIdentity({...before,[name]:'changed',CODEX_TOOL_CALL_ID:'call-second'})};
      const previous={state:'PASS',profile:'full',product:'default',mode:'debug',snapshot:{...current,environment:environmentIdentity(before)}};
      assert.notEqual(current.environment,previous.snapshot.environment,name);
      assert.equal(chooseProfile({requested:'quick',product:'default',mode:'debug',previous,current,allowedChangedFiles:[allowed]}).effective,'quick',name);
    }
  });

  await check('real session tolerates only tool-call nonce changes; SDK/CC/CXX/PATH drift still rejects completion',()=>{
    const nonce=process.env.CODEX_TOOL_CALL_ID;
    try {
      process.env.CODEX_TOOL_CALL_ID='session-call-first';
      const item=fixture('telemetry-call-id'),context=item.begin();coverage(context);
      process.env.CODEX_TOOL_CALL_ID='session-call-second';assert.equal(item.complete(context).state,'PASS');
      const state=JSON.parse(fs.readFileSync(context.filename));assert.ok(!Object.hasOwn(state.environmentInputs,'CODEX_TOOL_CALL_ID'));
      process.env.CODEX_TOOL_CALL_ID='session-call-third';
      const quick=item.begin('quick');assert.equal(quick.effective,'quick');item.complete(quick,false);
    } finally {if(nonce===undefined) delete process.env.CODEX_TOOL_CALL_ID;else process.env.CODEX_TOOL_CALL_ID=nonce;}
    for(const name of ['CC','CXX','PATH','OHOS_SDK_ROOT']) {
      const saved=process.env[name],item=fixture('semantic-environment-'+name.toLowerCase());
      try {
        if(name==='OHOS_SDK_ROOT') {
          const before=path.join(item.base,'sdk-before'),after=path.join(item.base,'sdk-after');
          for(const directory of [before,after]) {fs.mkdirSync(directory);fs.writeFileSync(path.join(directory,'header.h'),'fixture SDK');}
          process.env[name]=before;
          const context=item.begin();coverage(context);process.env[name]=after;
          assert.throws(()=>item.complete(context),/environment drift|input drift/,name);
        } else {
          const context=item.begin();coverage(context);
          process.env[name]=name==='PATH'?(saved??'')+path.delimiter+path.join(item.base,'unselected-tools'):'changed-fixture-compiler';
          assert.throws(()=>item.complete(context),/environment drift/,name);
        }
      } finally {if(saved===undefined) delete process.env[name];else process.env[name]=saved;}
    }
  });

  await check('source bytes and external directory members remain identity inputs',()=>{
    const item=fixture('source-drift'), context=item.begin();coverage(context);fs.appendFileSync(path.join(item.root,'other.cpp'),' drift');
    assert.throws(()=>item.complete(context),/input drift/);
    const external=path.join(item.base,'external-jdk');fs.mkdirSync(external);fs.writeFileSync(path.join(external,'release'),'v1');process.env.JAVA_HOME=external;
    try {const before=fixtureSnapshot(item.root);fs.writeFileSync(path.join(external,'new.h'),'new member');assert.notDeepEqual(fixtureSnapshot(item.root).external,before.external);}
    finally {delete process.env.JAVA_HOME;}
    const tool=path.join(item.base,'tool.bin');fs.writeFileSync(tool,'tool version A');
    const selected=[{name:'compiler',path:tool},{name:'optional-java',path:null}];
    const toolBefore=fixtureSnapshot(item.root,selected);assert.equal(toolBefore.external['tool:optional-java'].state,'MISSING');
    fs.writeFileSync(tool,'tool version B');assert.notDeepEqual(fixtureSnapshot(item.root,selected).external,toolBefore.external);
    assert.throws(()=>fixtureSnapshot(item.root,[{name:'compiler',path:tool},{name:'compiler',path:null}]),/duplicate/);
    const ignored='entry/src/main/cpp/openal/openal-soft';fs.writeFileSync(path.join(item.root,'.gitignore'),ignored+'/\n');
    fs.mkdirSync(path.join(item.root,ignored),{recursive:true});fs.writeFileSync(path.join(item.root,ignored,'audio.c'),'audio A');
    const ignoredBefore=fixtureSnapshot(item.root);fs.writeFileSync(path.join(item.root,ignored,'audio.c'),'audio B');
    assert.notEqual(fixtureSnapshot(item.root).files['@ignored-native/'+ignored],ignoredBefore.files['@ignored-native/'+ignored]);
    process.env.OHOS_SDK_ROOT=external;process.env.AMCL_GATE_SESSION_SDK_ROOT=external;
    try {
      let reads=0;const stages=[];
      const sdkFingerprintProvider=selected=>{reads++;return {state:'AVAILABLE',identity:{state:'AVAILABLE',root:selected,key:'fixture-only-sdk'},qualification:{state:'AVAILABLE'}};};
      const bound=snapshot(item.root,[],{...fixtureOptions,sdkFingerprintProvider,onStage:row=>stages.push(row)});
      assert.equal(reads,1);assert.equal(bound.external.AMCL_GATE_SESSION_SDK_ROOT.root,fs.realpathSync(external));
      assert.deepEqual(bound.external.AMCL_GATE_SESSION_SDK_ROOT,bound.external.OHOS_SDK_ROOT);
      assert.equal(stages.find(row=>row.name==='AMCL_GATE_SESSION_SDK_ROOT').reused,true);
      assert.deepEqual(bound.sdkQualifications.AMCL_GATE_SESSION_SDK_ROOT,{state:'AVAILABLE'});
    } finally {delete process.env.OHOS_SDK_ROOT;delete process.env.AMCL_GATE_SESSION_SDK_ROOT;}

  });

  await check('extra DeepAudit may observe Native graph qualification without imposing it on ordinary quick',()=>{
    const item=fixture('sdk-first-graph'),sdk=path.join(item.base,'sdk');fs.mkdirSync(sdk);
    process.env.AMCL_GATE_SESSION_SDK_ROOT=sdk;
    let state='UNAVAILABLE';
    fixtureOptions.sdkFingerprintProvider=selected=>({state,identity:{state:'AVAILABLE',root:selected,key:'unchanged SDK content'},
      qualification:{state,...(state==='UNAVAILABLE'?{reason:'missing initial Native graph'}:{})}});
    try {
      const first=item.begin();coverage(first);state='AVAILABLE';assert.equal(item.complete(first).state,'PASS');
      const rejected=item.begin('quick');assert.equal(rejected.effective,'quick');item.complete(rejected,false);
      const full=item.begin();coverage(full);assert.equal(item.complete(full).state,'PASS');
      const quick=item.begin('quick');assert.equal(quick.effective,'quick');quickCoverage(item,quick);
      state='UNAVAILABLE';assert.equal(item.complete(quick).state,'PASS');
    } finally {delete process.env.AMCL_GATE_SESSION_SDK_ROOT;delete fixtureOptions.sdkFingerprintProvider;}
  });

  await check('explicit DeepAudit conservatively hashes unknown SDK content; ordinary quick remains independent',()=>{
    const item=fixture('sdk-content-fallback'),bundle=path.join(item.base,'bundle'),sdk=path.join(bundle,'openharmony'),hms=path.join(bundle,'hms');
    fs.mkdirSync(sdk,{recursive:true});fs.mkdirSync(hms);fs.writeFileSync(path.join(sdk,'header.h'),'header A');fs.writeFileSync(path.join(hms,'compiler.exe'),'compiler A');
    process.env.AMCL_GATE_SESSION_SDK_ROOT=sdk;
    fixtureOptions.sdkFingerprintProvider=()=>({state:'UNAVAILABLE',identity:{state:'UNAVAILABLE',reason:'unsupported fixture scope'},
      qualification:{state:'UNAVAILABLE',reason:'unsupported fixture scope'}});
    try {
      const first=item.begin();coverage(first);
      const initial=JSON.parse(fs.readFileSync(first.filename));assert.equal(initial.snapshot.external.AMCL_GATE_SESSION_SDK_ROOT.state,'FULL_TREE_CONTENT');
      assert.equal(initial.snapshot.external.AMCL_GATE_SESSION_SDK_ROOT.root,bundle);
      fs.writeFileSync(path.join(hms,'compiler.exe'),'compiler B');assert.throws(()=>item.complete(first),/input drift/);
      const full=item.begin();coverage(full);assert.equal(item.complete(full).state,'PASS');
      const quick=item.begin('quick');assert.equal(quick.effective,'quick');item.complete(quick,false);
    } finally {delete process.env.AMCL_GATE_SESSION_SDK_ROOT;delete fixtureOptions.sdkFingerprintProvider;}
  });

  await check('nested empty gitlinks never borrow parent HEAD and legal checkout aliases are hashed separately',()=>{
    const item=fixture('nested-empty-submodule'), vendor=path.join(item.root,'vendor'), empty=path.join(vendor,'3rdparty','empty');
    fs.mkdirSync(empty,{recursive:true});fs.writeFileSync(path.join(vendor,'owner.c'),'vendor owner');
    const run=(root,args)=>{const result=spawnSync('git',['-C',root,...args],{encoding:'utf8'});assert.equal(result.status,0,result.stderr);return result.stdout.trim();};
    run(vendor,['init']);run(vendor,['add','owner.c']);
    const nestedPin='1'.repeat(40);
    run(vendor,['update-index','--add','--cacheinfo','160000,'+nestedPin+',3rdparty/empty']);
    run(vendor,['-c','user.name=fixture','-c','user.email=fixture@example.invalid','commit','-m','nested empty fixture']);
    const vendorPin=run(vendor,['rev-parse','HEAD']);
    run(item.root,['update-index','--add','--cacheinfo','160000,'+vendorPin+',vendor']);
    assert.equal(fs.realpathSync(run(empty,['rev-parse','--show-toplevel'])),fs.realpathSync(vendor));
    const before=fixtureSnapshot(item.root);
    assert.equal(before.files['vendor/3rdparty/empty/@gitlink'],nestedPin+':UNINITIALIZED');
    const oldTree=before.files['vendor/3rdparty/empty/@uninitialized-tree'];
    fs.writeFileSync(path.join(empty,'existing.h'),'uninitialized directory member');
    assert.notEqual(fixtureSnapshot(item.root).files['vendor/3rdparty/empty/@uninitialized-tree'],oldTree);
    const alias=path.join(item.root,'vendor-alias');fs.symlinkSync(vendor,alias,process.platform==='win32'?'junction':'dir');
    run(item.root,['update-index','--add','--cacheinfo','160000,'+vendorPin+',vendor-alias']);
    const aliased=fixtureSnapshot(item.root);
    assert.equal(aliased.files['vendor/owner.c'],aliased.files['vendor-alias/owner.c']);
    assert.equal(aliased.files['vendor/3rdparty/empty/@uninitialized-tree'],aliased.files['vendor-alias/3rdparty/empty/@uninitialized-tree']);
    fs.unlinkSync(path.join(empty,'existing.h'));fs.rmdirSync(empty);
    assert.equal(fixtureSnapshot(item.root).files['vendor/3rdparty/empty/@uninitialized-tree'],'MISSING');
  });

  await check('startup context sidecar succeeds, and failed sidecar cannot leave PASS or a live lock',()=>{
    const item=fixture('context-report'), report=path.join(item.base,'context.json'), context=item.begin('full',{'context-report':report});
    assert.equal(JSON.parse(fs.readFileSync(report)).filename,context.filename);item.complete(context,false);
    assert.throws(()=>item.begin('full',{'context-report':report}),/new external file/);
    const state=JSON.parse(fs.readFileSync(context.filename));assert.ok(!fs.existsSync(state.lock));
  });

  await check('stale or foreign lease cannot finish another session or remove its lock',()=>{
    const item=fixture('foreign-lease'), context=item.begin();const state=JSON.parse(fs.readFileSync(context.filename));
    const foreign={owner:'different-writer',runRoot:'different-root'};fs.writeFileSync(state.lock,JSON.stringify(foreign));
    assert.throws(()=>item.complete(context,false),/ownership mismatch/);
    assert.deepEqual(JSON.parse(fs.readFileSync(state.lock)),foreign);
  });
} finally {
  for(const name of Object.keys(process.env)) if(!Object.hasOwn(originalEnvironment,name)) delete process.env[name];
  Object.assign(process.env,originalEnvironment);
  // 汇总和进程必须使用同一结论；新增用例后不得出现 summary FAIL 而退出码仍为0。
  // 用例数量随实际注册增长，不另维护易遗漏的硬编码总数；空运行仍不能通过。
  const state=results.length>0&&results.every(row=>row.state==='PASS')?'PASS':'FAIL';
  fs.writeFileSync(path.join(output,'summary.json'),JSON.stringify({completedAt:new Date().toISOString(),state,cases:results},null,2)+'\n');
  if(state!=='PASS')process.exitCode=1;
}
