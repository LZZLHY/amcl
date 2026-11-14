/**
 * 真实Coordinator/Repository产生完整schema2 superseded事务，再交实际C++ reader/SH。
 * Kit替身只用于驱动ArkTS生产者，不用其Native lease stub宣称文件准入成功。
 * Linux直接使用真实POSIX；Windows明确通过WSL，不把缺工具或编译失败当跳过/PASS。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {fixture,record,payload} from './lib/sideload-coordinator-fixture.mjs';
import {createHostTestScope} from './lib/host-test-lifecycle.mjs';

const project=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const args=process.argv.slice(2);
assert(args.length===0||(args.length===1&&args[0]==='--current-only'),'only explicit --current-only is supported');
// 常态门不能把作者手工负控的“拒绝符合预期”当本版准入成功。遇继承负控变量直接
// 失败，不静默删除环境或悄悄切换样本；作者明确direct调用才可启用旧头负控。
if(args[0]==='--current-only'){
  assert(!Object.hasOwn(process.env,'AMCL_SIDELOAD_NATIVE_OLD_HEADER')&&
    !Object.hasOwn(process.env,'AMCL_SIDELOAD_NATIVE_EXPECT_REJECT'),
    'current-only gate rejects inherited negative-header/expected-reject overrides');
}
const scope=createHostTestScope('sideload-native-terminal-',{parent:process.env.AMCL_SIDELOAD_NATIVE_BUILD_ROOT});
const binary=path.join(scope.directory,'lease-test');
const windows=process.platform==='win32';
/** 参数逐项交进程API，不经shell拼接；wslpath给出当前发行版实际盘符映射。 */
function nativePath(value){
  if(!windows)return value;
  const converted=spawnSync('wsl.exe',['-e','wslpath','-a','-u',value],{encoding:'utf8',timeout:10000});
  assert.equal(converted.error,undefined,'wslpath must execute');assert.equal(converted.status,0,converted.stderr);
  return converted.stdout.trim();
}
function runNative(command,args,timeout=10000){
  const result=spawnSync(windows?'wsl.exe':command,windows?['-e',command,...args]:args,{encoding:'utf8',timeout,maxBuffer:1024*1024});
  assert.equal(result.error,undefined,'real POSIX process must execute: '+(result.error?.message??''));
  return result;
}
const compile=['-std=c++17','-O0','-pthread'];
// 仅定向负控可绑定精确旧头；常态gate永远编译当前生产头，不从Git猜旧版本或造假parser。
if(process.env.AMCL_SIDELOAD_NATIVE_OLD_HEADER)compile.push('-DAMCL_SIDELOAD_LEASE_HEADER="'+nativePath(path.resolve(process.env.AMCL_SIDELOAD_NATIVE_OLD_HEADER))+'"');
compile.push(nativePath(path.join(project,'entry/src/main/cpp/tests/host/sideload_install_lease_test.cpp')),'-o',nativePath(binary));
const built=runNative('g++',compile,60000);assert.equal(built.status,0,built.stdout+built.stderr);
const reject=process.env.AMCL_SIDELOAD_NATIVE_EXPECT_REJECT==='1';
assert(!reject||process.env.AMCL_SIDELOAD_NATIVE_OLD_HEADER,'expected rejection requires explicit old header');
let cases=0;
/** 原字节直接交Native；只输出摘要/裁决，不打印可能含设备路径或签名URL的journal正文。 */
function checkJournal(label,journal){
  const bytes=fs.readFileSync(journal),root=path.join(scope.directory,'case-'+cases++);
  const actual=runNative(nativePath(binary),[nativePath(root),nativePath(journal)]);
  if(reject){
    assert.equal(actual.status,1,'old header must fail business assertion after successful compilation');
    assert.match(actual.stdout,/LEASE_INPUT bytes=\d+ permits=0 acquired=0/,'old reader must actually deny same producer bytes');
    assert.match(actual.stderr,/实际生产合法终态必须经完整Native reader取得SH/);
  }else{assert.equal(actual.status,0,actual.stdout+actual.stderr);assert.match(actual.stdout,/permits=1 acquired=1/);}
  console.log(JSON.stringify({case:label,bytes:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex'),
    nativeExit:actual.status,expectedOldHeaderRejection:reject,nativeEvidence:actual.stdout.trim().split('\n')}));
}
for(const [label,targetCode,currentCode,uid,product] of [
  ['phone-higher-code',1000690,1000910,20020376,'default'],
  ['tablet-equal-code-new-source',1000910,1000910,20020237,'sideload']]){
  const old=record('verified');Object.assign(old,{schema:2,revision:1,ownerAttemptId:old.id,installProtocol:2,
    installId:'a'.repeat(32),beforeVersionCode:targetCode-1,beforeUid:uid,installedIdentityVerified:true});
  old.asset={...old.asset,versionCode:targetCode,versionName:'1.0.6'};delete old.asset.sourceRevision;
  const owner=await fixture({journal:old,initialEnvironment:{version:currentCode,versionName:'1.0.6',payload:'f'.repeat(40),uid,product}});
  const migrated=owner.coordinator.state();assert.equal(migrated.schema,2);assert.equal(migrated.phase,'superseded');
  assert(migrated.legacySuperseded);assert.equal(migrated.completion,undefined);assert.equal(migrated.runtimeIntentId,undefined);
  assert.equal(migrated.expectedPayloadIdentity,payload);
  const journal=owner.mapped('/sandbox/sideload-update/transaction.json');
  assert.deepEqual(JSON.parse(fs.readFileSync(journal,'utf8')),JSON.parse(JSON.stringify(migrated)),'consume actual durable row, not reconstructed state');
  checkJournal(label,journal);owner.coordinator.setAbilityForeground(false);
}
// 可选真机私有取证输入仅在本轮明确传入；它从不进入源码/CI，也不能替代上面的实际生产者。
if(process.env.AMCL_SIDELOAD_NATIVE_PHONE_JOURNAL){
  const journal=path.resolve(process.env.AMCL_SIDELOAD_NATIVE_PHONE_JOURNAL);
  assert.equal(crypto.createHash('sha256').update(fs.readFileSync(journal)).digest('hex'),process.env.AMCL_SIDELOAD_NATIVE_PHONE_SHA256);
  checkJournal('phone-original-bytes',journal);
}
console.log(reject
  ? 'PASS expected old production header rejects actual ArkTS/phone bytes after successful compilation, cases='+cases
  : 'PASS real ArkTS durable superseded -> Native full reader/SH; locks/fence/restart/malformed boundaries, cases='+cases);
