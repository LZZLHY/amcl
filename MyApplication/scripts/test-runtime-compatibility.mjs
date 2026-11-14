/** 执行生产能力、包内声明、双向选包与旧槽识别；不复制被测兼容判断。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {makePureEtsLoader} from './lib/load-pure-ets.mjs';
import {legacyRuntimeCatalogText} from './lib/legacy-runtime-catalog-fixture.mjs';

const files=new Map();
const fileIo={statSync(path){if(!files.has(path)){const error=Error('ENOENT');error.code='ENOENT';throw error;}return{isFile:()=>true,size:Buffer.byteLength(files.get(path))};},readTextSync:path=>files.get(path)};
const load=makePureEtsLoader({'@kit.CoreFileKit':{fileIo}});
const {runtimeRequiredCapabilities}=load('launch/src/main/ets/RuntimeHostProtocol.ets');
const {declaredRuntimeCapabilities}=load('launch/src/main/ets/RuntimeCapabilityContract.ets');
const {validateRuntimeHostDeclaration,validateRuntimeForHost}=load('launch/src/main/ets/RuntimeHostDeclaration.ets');
const {runtimeBuildForHost}=load('launch/src/main/ets/RuntimeCatalogValidation.ets');
const {parseAppRuntimeRequirements}=load('commons/src/main/ets/common/RuntimeRequirementPolicy.ets');
assert.deepEqual(runtimeRequiredCapabilities(),['zipfs-transaction-v1']);
assert.match(validateRuntimeHostDeclaration('/jdk/17'),/ZIP\/JAR/,'无包内修复声明的旧安装必须阻断危险启动');
assert.equal(validateRuntimeForHost('/jdk/17',[1],[]),'','旧目标没有新要求，不追认行为变化');
const metadata={schema:1,build:{patches:{'0019-zipfs-permission-copy-transaction.patch':'a'.repeat(64),'0025-ohos-javasound-duplex-host-callbacks.patch':'b'.repeat(64)}}};
files.set('/jdk/17/amcl-runtime.json',JSON.stringify(metadata));
assert.equal(validateRuntimeHostDeclaration('/jdk/17'),'', '现有冻结新候选可由构建来源表达能力');
assert.match(validateRuntimeForHost('/jdk/17',[1],[]),/不兼容/,'新JDK不能因具有修复就越过旧宿主ABI');
assert.match(validateRuntimeHostDeclaration('/jdk/17',1),/冻结目录不一致/);
assert.throws(()=>declaredRuntimeCapabilities({schema:1,build:{patches:{'0019-zipfs-permission-copy-transaction.patch':'bad'}}}));
// 真机首次普通下载暴露的旧schema1字段冲突：描述映射不能作为新标签数组读取。
const frozenManifests=JSON.parse(fs.readFileSync(new URL('./fixtures/runtime-compatibility/frozen-manifests.json',import.meta.url),'utf8'));
assert.deepEqual(frozenManifests.map(item=>item.javaMajor),[8,17,21,25]);
for(const fixture of frozenManifests){
  assert.match(fixture.manifestSha256,/^[a-f0-9]{64}$/);
  files.set('/jdk/17/amcl-runtime.json',JSON.stringify(fixture.metadata));
  assert.equal(validateRuntimeHostDeclaration('/jdk/17',2,['zipfs-transaction-v1']),'',fixture.buildId);
  assert.match(validateRuntimeForHost('/jdk/17',[1],[]),/不兼容/,fixture.buildId+'仍需新宿主');
}
for(const capabilities of [null,17,{awt:17},{'invalid/key':'x'}])assert.throws(()=>declaredRuntimeCapabilities({schema:1,capabilities}));
assert.throws(()=>declaredRuntimeCapabilities({schema:2,capabilities:{awt:'headless'}}));
assert.deepEqual(declaredRuntimeCapabilities({schema:1,capabilities:{'zipfs-transaction-v1':'implemented'}}),[],
  '旧描述映射即使同名也不授予新能力');
files.clear();files.set('/jdk/17/.amcl-runtime-receipt.json',JSON.stringify({build:{capabilities:['zipfs-transaction-v1']}}));
assert.match(validateRuntimeHostDeclaration('/jdk/17'),/ZIP\/JAR/,'ZIP自带的receipt不能代替包内来源');
// 旧包回退仍执行原 v1 输入；当前正式目录另逐槽验证，不能通过改坏正式 builtin 让旧断言变绿。
const source=JSON.parse(legacyRuntimeCatalogText());
const runtime=source.runtimes.find(r=>r.javaMajor===17),old=source.builds.find(b=>b.id===runtime.recommendedBuildId);
assert.equal(runtimeBuildForHost(source,runtime,[1,2],runtimeRequiredCapabilities()),undefined,'新App回落v1也不能选旧问题包');
assert.equal(runtimeBuildForHost(source,runtime,[1],[]).id,old.id);
const current={...structuredClone(old),id:'fixed-17',requiredHostProtocol:2,capabilities:['zipfs-transaction-v1']};
const modern={...source,schemaVersion:2,builds:[{...old,requiredHostProtocol:1},current]},slot={...runtime,recommendedBuildIds:[old.id,current.id]};
assert.equal(runtimeBuildForHost(modern,slot,[1,2],runtimeRequiredCapabilities()).id,'fixed-17');
assert.equal(runtimeBuildForHost(modern,slot,[1],[]).id,old.id);
assert.equal(runtimeBuildForHost(modern,{...slot,recommendedBuildIds:['fixed-17']},[1],[]),undefined);
const shipping=JSON.parse(fs.readFileSync(new URL('../entry/src/main/resources/rawfile/runtime-catalog/builtin.json',import.meta.url),'utf8'));
assert.equal(shipping.schemaVersion,2);
assert.equal(shipping.channel,'stable');
assert.deepEqual(shipping.runtimes.map(item=>item.javaMajor),[8,17,21,25]);
for(const item of shipping.runtimes){
  const build=runtimeBuildForHost(shipping,item,[1,2],runtimeRequiredCapabilities());
  assert(build, '正式内置目录必须为每个 JDK 槽提供满足本 App 能力要求的稳定包');
  assert.equal(build.requiredHostProtocol,2);
  assert(build.capabilities.includes('zipfs-transaction-v1'));
  const legacy=runtimeBuildForHost(shipping,item,[1],[]);
  assert(legacy&&legacy.requiredHostProtocol===1&&legacy.provenance.kind==='legacy','旧宿主只得到兼容旧正式包，不能强行选择新 JDK');
  assert.notEqual(legacy.id,build.id);
}
assert.deepEqual(parseAppRuntimeRequirements(),{runtimeRequiredCapabilities:[],runtimeRequiredMajors:[]});
for(const [caps,majors] of [[null,[]],[['x','x'],[17]],[['x'],[]],[[],[17,17]],[[],['17']]])assert.throws(()=>parseAppRuntimeRequirements(caps,majors));
console.log('PASS runtime compatibility: real new-App requirements, old-host rejection, v1 fallback, metadata provenance and typed HAP requirements');
