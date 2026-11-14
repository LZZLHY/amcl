/**
 * 合法大ES256目录→生产Installer实际receipt→生产耐久intent ack/cold认领互操作回归。
 * 复用原安装器Kit/下载夹具，不手写“已安装成功”收据；Manager资格是明确边界，不称JVM验证。
 */
import fs from 'node:fs';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import path from 'node:path';
import compiler from './lib/ets-compiler.mjs';
import {makePureEtsLoader} from './lib/load-pure-ets.mjs';
import {fixture} from './lib/sideload-coordinator-fixture.mjs';
const base=JSON.parse(fs.readFileSync(new URL('../entry/src/main/resources/rawfile/runtime-catalog/builtin.json',import.meta.url),'utf8'));
let installHarness=fs.readFileSync(new URL('./test-runtime-catalog-install.mjs',import.meta.url),'utf8');
installHarness=installHarness.slice(0,installHarness.indexOf('const results=[];')).replace(/^import[^\n]+\n/gm,'');
const producer=`
reset();
const runtime=structuredClone(base.runtimes.find(r=>r.javaMajor===17));
const build=structuredClone(base.builds.find(b=>b.runtimeId===runtime.id&&b.provenance.kind==='source-build'));
runtime.minimumCatalogProtocol=2;runtime.recommendedBuildIds=['new2'];delete runtime.recommendedBuildId;delete runtime.loaderProtocol;
build.id='new2';build.requiredHostProtocol=2;build.legacyTags=[];build.validationLevel='device-matrix-tested';
build.archive={type:'zip',fileName:'runtime.zip',sizeBytes:data.length,sha256:hash(data)};
build.notes=Array.from({length:24},()=> '中'.repeat(1000));build.provenance.evidence=Array.from({length:24},()=> '证'.repeat(1000));
build.downloads=[{sourceId:'github',transport:'single-file',url:'https://github.com/test.zip'},
 {sourceId:'gitee',transport:'concat-parts',parts:Array.from({length:16},(_,i)=>({url:'https://gitee.com/fixture/'+i+'a'.repeat(1950),sizeBytes:i===15?data.length-15:1,sha256:'c'.repeat(64)}))}];
const catalog={schemaVersion:2,channel:'preview',catalogRevision:2,issuedAt:base.issuedAt,expiresAt:base.expiresAt,runtimes:[runtime],builds:[build]};
load('launch/src/main/ets/RuntimeCatalogValidation.ets').parseRuntimeCatalog(JSON.stringify(catalog),'preview');
assert.equal(await installer({...config(),tag:'new2',runtime,build,downloads:build.downloads}).downloadAndInstall(),true);
const actualReceipt=files.get('/app/jdk/17/.amcl-runtime-receipt.json').toString();
const limit=load('launch/src/main/ets/RuntimeCatalogTypes.ets').RUNTIME_INSTALL_RECEIPT_LIMIT;
assert(Buffer.byteLength(actualReceipt)>65536);assert(Buffer.byteLength(actualReceipt)<=limit);
return {actualReceipt,catalog,limit};
`;
const AsyncFunction=Object.getPrototypeOf(async function(){}).constructor;
const made=await new AsyncFunction('assert','createHash','makePureEtsLoader','base',installHarness+producer)(assert,crypto.createHash,makePureEtsLoader,base);
const pair=crypto.generateKeyPairSync('ec',{namedCurve:'prime256v1'}),header=Buffer.from(JSON.stringify({alg:'ES256',typ:'amcl-runtime-catalog+jws',kid:'test'})).toString('base64url');
const body=Buffer.from(JSON.stringify(made.catalog)).toString('base64url'),message=Buffer.from(header+'.'+body),signature=crypto.sign('sha256',message,{key:pair.privateKey,dsaEncoding:'ieee-p1363'});
assert(crypto.verify('sha256',message,{key:pair.publicKey,dsaEncoding:'ieee-p1363'},signature));
const envelopeBytes=Buffer.byteLength(JSON.stringify({protected:header,payload:body,signature:signature.toString('base64url')}));assert(envelopeBytes<1024*1024);
let intentHarness=fs.readFileSync(new URL('./test-runtime-app-dependency.mjs',import.meta.url),'utf8');
intentHarness=intentHarness.slice(0,intentHarness.indexOf('let passed=0;')).replace(/^import[^\n]+\n/gm,'');
const managerSource=fs.readFileSync(new URL('../launch/src/main/ets/JdkManager.ets',import.meta.url),'utf8'),managerAst=compiler.createSourceFile('JdkManager.ets',managerSource,compiler.ScriptTarget.Latest,true);
const managerType=managerAst.statements.find(node=>node.name?.getText(managerAst)==='JdkManager');
const managerMethods=['readStamp_','tagInputFor_'].map(name=>managerType.members.find(node=>node.name?.getText(managerAst)===name).getText(managerAst)).join('\n');
const managerCode=compiler.transpileModule('class MetadataManager {'+managerMethods+'}',{compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020}}).outputText;
const consumer=`
c.runtimes=made.catalog.runtimes;c.builds=made.catalog.builds;
const generation=confirmed(),item=api.takeIfCompatible(context,repository,'preview').items[0];
const token=api.beginDelivery(context,generation,item);
fs.mkdirSync(f.mapped('/sandbox/jdk/17'),{recursive:true});
fs.writeFileSync(f.mapped('/sandbox/jdk/17/.amcl-runtime-receipt.json'),made.actualReceipt);eligible=true;
const MetadataManager=new Function('fs','RUNTIME_INSTALL_RECEIPT_LIMIT','runtimeReceiptStamp',managerCode+';return MetadataManager;')(
  io,made.limit,load('launch/src/main/ets/RuntimeUpdatePolicy.ets').runtimeReceiptStamp);
assert.equal(new MetadataManager().tagInputFor_('17','/sandbox/jdk/17',{runtime:c.runtimes[0],build:c.builds[0],tag:'new2'}).installedTag,'new2');
assert.equal(api.completeDelivery(context,generation,item,token,repository,manager,'done'),true);assert.equal(read().phase,'complete');
const coldGeneration=confirmed();eligible=true;api.beginDelivery(context,coldGeneration,api.takeIfCompatible(context,repository,'preview').items[0]);
api.reconcileInstalled(context,repository,manager);assert.equal(read().phase,'complete');
assert.equal(api.takeIfCompatible(context,repository,'preview').kind,'none');
const overGeneration=confirmed(),overItem=api.takeIfCompatible(context,repository,'preview').items[0],overToken=api.beginDelivery(context,overGeneration,overItem);
fs.writeFileSync(f.mapped('/sandbox/jdk/17/.amcl-runtime-receipt.json'),Buffer.alloc(made.limit+1,32));eligible=true;
assert.throws(()=>api.completeDelivery(context,overGeneration,overItem,overToken,repository,manager,'done'),/未核实/);
assert.equal(read().intents[0].state,'delivering','over-budget data never becomes installation proof');
f.coordinator.setAbilityForeground(false);
return {passed:true,receiptBytes:Buffer.byteLength(made.actualReceipt),receiptLimit:made.limit,envelopeBytes,
 producer:'actual JdkInstaller',consumer:'actual RuntimeAppDependency and AtomicWriter',managerReceiptRecognized:true,directAck:true,coldReconcile:true,overBudgetRefused:true};
`;
const result=await new AsyncFunction('assert','fs','crypto','fixture','makePureEtsLoader','made','envelopeBytes','managerCode',intentHarness+consumer)(assert,fs,crypto,fixture,makePureEtsLoader,made,envelopeBytes,managerCode);
if(process.env.AMCL_TEST_OUTPUT_DIR)fs.writeFileSync(path.join(process.env.AMCL_TEST_OUTPUT_DIR,'runtime-intent-large-receipt-results.json'),JSON.stringify(result,null,2)+'\n');
console.log(JSON.stringify(result,null,2));
