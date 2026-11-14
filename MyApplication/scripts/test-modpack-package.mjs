/**
 * 运行生产包装发现/ZIP预检。Python zipfile独立生成和解压真实ZIP；文件/路径/候选/预算判据
 * 都执行生产ETS。成功回收本轮亲建夹具，仅保留小型JSON收据；失败保留完整现场。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import vm from 'node:vm';
import {execFileSync} from 'node:child_process';
import {loader, fileIo, productionPathPolicy, mocks, ts} from './mod-install-test-runtime.mjs';
import {createHostTestScope} from './lib/host-test-lifecycle.mjs';
import {resolveWorkspacePath} from './lib/workspace-paths.mjs';
const parent=process.env.AMCL_TEST_OUTPUT_DIR||resolveWorkspacePath('run','modpack-package');
fs.mkdirSync(parent,{recursive:true});
const reportRoot=fs.mkdtempSync(path.join(parent,'run-'));
const scope=createHostTestScope('fixtures-',{parent:reportRoot,automatic:false});
const fixture=scope.directory.replaceAll('\\','/');
const helper=path.join(import.meta.dirname,'fixtures/modpack-package-fixtures.py');
const python=process.env.AMCL_PYTHON||'python';
const receipts=[];
let success=false;
try {
execFileSync(python,[helper,'generate',fixture],{stdio:'pipe'});
const sha1=p=>crypto.createHash('sha1').update(fs.readFileSync(p)).digest('hex');
let extracts=0, gate, entered, afterExtract, failRead=false;
const common={ensureDirSync:p=>fs.mkdirSync(p,{recursive:true}),
  removeDirRecursive(p){assert.ok(path.resolve(p).startsWith(path.resolve(fixture)+path.sep));fs.rmSync(p,{recursive:true,force:true});}};
// HarmonyOS Stat.mtime是数值；Node Date对象不能直接用引用相等模拟该接口。
const io={...fileIo,copyFile:fs.promises.copyFile,lstatSync(p){const s=fs.lstatSync(p);return {...s,mtime:s.mtimeMs,
  isFile:()=>s.isFile(),isDirectory:()=>s.isDirectory(),isSymbolicLink:()=>s.isSymbolicLink()};},
 readTextSync(p){if(failRead&&p.endsWith('/manifest.json'))throw new Error('fixture EIO');return fs.readFileSync(p,'utf8');}};
const ports={...productionPathPolicy(),
  computeFileSha1:async p=>sha1(p),async decompressFile(zip,dest){extracts++;entered?.();if(gate)await gate;
    execFileSync(python,[helper,'extract',zip,dest],{stdio:'pipe'});afterExtract?.(zip,dest);}};
const load=loader({'@kit.CoreFileKit':{fileIo:io},commons:common,feature_core:ports});
const P=load('mods/src/main/ets/ModpackPackage.ets');
const preflight=P.preflightModpackArchive;
function passed(name){receipts.push(name);console.log('PASS '+name);}
async function prepare(name,suffix=''){
  const work=fixture+'/work-'+name+suffix;fs.mkdirSync(work+'/extracted',{recursive:true});
  fs.copyFileSync(fixture+'/'+name+'.zip',work+'/archive.zip');
  preflight(work+'/archive.zip');
  execFileSync(python,[helper,'extract',work+'/archive.zip',work+'/extracted'],{stdio:'pipe'});
  return work;
}
async function discover(name){const work=await prepare(name);return {work,items:await P.discoverModpackPackages(work,()=>false)};}
let result=await discover('standard-exe');assert.equal(result.items.length,1);assert.equal(result.items[0].kind,'modrinth');
assert.equal(result.items[0].root,'extracted');assert.equal(extracts,0);passed('standard manifest with launcher remains a direct package');
for(const name of ['pcl','hmcl-stable','hmcl-main']){
 const {work,items}=await discover(name);assert.equal(items.length,1);assert.equal(items[0].kind,'modrinth');
 assert.equal(items[0].root,'payloads/p1');assert.equal(items[0].archiveChain.length,2);
 for(const source of items[0].archiveChain)assert.equal(sha1(work+'/'+source.path),source.sha1);
 const again=await P.discoverModpackPackages(work,()=>false);assert.deepEqual(again,items);
 passed(name+' inner payload is located, source-bound and stable on repeat');
}
result=await discover('deep');assert.equal(result.items[0].root,'extracted/Outer/Inner/Pack');passed('multiple directory wrappers');
result=await discover('dual');assert.equal(result.items.length,1);assert.equal(result.items[0].kind,'mcbbs');passed('MCBBS metadata owns its compatibility CF sidecar');
for(const [name,kind]of [['legacy-mcbbs','mcbbs'],['hmcl-legacy','hmcl'],['multimc','multimc']]){
 result=await discover(name);assert.equal(result.items.length,1);assert.equal(result.items[0].kind,kind);passed(name+' format discovery');}
result=await discover('full');assert.equal(result.items.length,2);assert.deepEqual(Array.from(result.items,x=>x.versionId),['A','B']);
assert.ok(result.items.every(x=>x.root==='extracted/.minecraft'));passed('all full-instance versions remain explicit choices');
result=await discover('mixed');assert.equal(result.items.length,2);assert.deepEqual(Array.from(result.items,x=>x.kind).sort(),['curseforge','instance']);passed('root manifest does not hide a full instance');
const before=extracts;result=await discover('ignore-mods');assert.equal(result.items.length,1);assert.equal(extracts,before);passed('mods and resource ZIPs are not expanded as packages');
const multipleBefore=extracts;result=await discover('multiple');assert.equal(result.items.length,2);
assert.notEqual(result.items[0].id,result.items[1].id);assert.ok(result.items.every(x=>x.kind==='archive'));
assert.equal(extracts,multipleBefore);assert.equal(fs.existsSync(result.work+'/payloads'),false);
const chosen=await P.materializeModpackPackage(result.work,result.items[1],()=>false);
assert.equal(chosen.length,1);assert.equal(chosen[0].kind,'modrinth');assert.equal(extracts,multipleBefore+1);
assert.equal(fs.existsSync(result.work+'/payloads/p2'),false);
passed('multiple inner archives stay compressed until exactly one branch is selected');
const changed=await discover('multiple');const changedSource=changed.work+'/'+changed.items[0].archivePath;
fs.appendFileSync(changedSource,'replaced while awaiting selection');const changedBefore=extracts;
await assert.rejects(P.materializeModpackPackage(changed.work,changed.items[0],()=>false),/等待选择期间发生变化/);
assert.equal(extracts,changedBefore);passed('deferred archive replacement is rejected before extraction');
const nestedBefore=extracts;const nestedChoices=await discover('nested-choices');
assert.equal(extracts,nestedBefore+1);assert.equal(nestedChoices.items.length,2);
assert.ok(nestedChoices.items.every(x=>x.kind==='archive'&&x.archiveDepth===2));
const parentSource=nestedChoices.work+'/'+nestedChoices.items[0].archivePath;const parentHash=sha1(parentSource);
const nestedSelected=await P.materializeModpackPackage(nestedChoices.work,nestedChoices.items[0],()=>false);
assert.equal(nestedSelected[0].root,'payloads/p2');assert.equal(sha1(parentSource),parentHash);
assert.equal(extracts,nestedBefore+2);passed('choosing a nested branch preserves its already-expanded source parent');
result=await discover('unrelated-zip');assert.equal(result.items.length,0);passed('unrelated ZIP is inspected without unpacking');
result=await discover('false-manifest');assert.equal(result.items.length,1);assert.equal(result.items[0].kind,'modrinth');passed('unrelated root manifest does not shadow a real child');
for(const name of ['broken-manifest','broken-manifest-inner']){
 result=await discover(name);assert.equal(result.items.length,1);assert.equal(result.items[0].kind,'modrinth');
}passed('invalid adjacent JSON is isolated from valid directories and nested packages');
let errorWork=await prepare('only-broken-manifest');await assert.rejects(P.discoverModpackPackages(errorWork,()=>false),/JSON 无效/);
errorWork=await prepare('false-manifest','-io-error');failRead=true;
await assert.rejects(P.discoverModpackPackages(errorWork,()=>false),/fixture EIO/);failRead=false;passed('all-invalid metadata stays actionable while real IO failures propagate');
for(const name of ['too-many','too-many-payloads','nested-too-deep']){
 const work=await prepare(name);await assert.rejects(P.discoverModpackPackages(work,()=>false),/超|限/);
}passed('candidate, nested payload count and archive depth budgets fail closed');
for(const name of ['traversal','symlink','duplicate'])assert.throws(()=>preflight(fixture+'/'+name+'.zip'));
passed('unsafe paths, symlinks and duplicate targets fail before extraction');
const original=fs.readFileSync(fixture+'/standard-exe.zip');
function corrupt(name,mutate){const bytes=Buffer.from(original);mutate(bytes);const target=fixture+'/'+name+'.zip';fs.writeFileSync(target,bytes);assert.throws(()=>preflight(target));}
corrupt('local-name',b=>{b[30]^=1;});
corrupt('encryption',b=>{const central=b.indexOf(Buffer.from([0x50,0x4b,1,2]));b.writeUInt16LE(b.readUInt16LE(central+8)|1,central+8);});
corrupt('huge-declared',b=>{const central=b.indexOf(Buffer.from([0x50,0x4b,1,2]));b.writeUInt32LE(0xffffffff,central+24);});
corrupt('local-size',b=>{b.writeUInt32LE(1000000,22);});
passed('local header mismatch, encrypted entries and missing ZIP64 sizes are rejected');
// 与生产ZIP64 writer互通，再由独立Python解压验证，防止只在同一个解析器里自洽。
const Z=load('feature_core/src/main/ets/export/ExportZipFormat.ets');
const name=Buffer.from('modrinth.index.json'), body=Buffer.from('{"formatVersion":1,"game":"minecraft","files":[]}');
const local=Z.exportZipLocalHeader(name,body.length), crc=Z.exportZipCrc32(0,body), descriptor=Z.exportZipDescriptor(crc,body.length);
const central=Z.exportZipCentralHeader(name,body.length,crc,0,false), offset=local.length+body.length+descriptor.length;
const zip64=fixture+'/zip64.zip';fs.writeFileSync(zip64,Buffer.concat([local,body,descriptor,central,Z.exportZipEnd(1,central.length,offset)]));
assert.equal(preflight(zip64).entries,1);execFileSync(python,[helper,'extract',zip64,fixture+'/zip64-extracted']);passed('ZIP64 STORE output interoperates with independent extraction');
const badStore=Buffer.from(fs.readFileSync(zip64));
badStore.writeBigUInt64LE(BigInt(body.length-1),30+name.length+4);
badStore.writeBigUInt64LE(BigInt(body.length-1),offset+46+name.length+4);
const badStorePath=fixture+'/store-size-mismatch.zip';fs.writeFileSync(badStorePath,badStore);
assert.throws(()=>preflight(badStorePath),/STORE/);passed('STORE cannot underdeclare expansion while keeping matching local and central fields');
// 注入更小的同一预算常量，验证跨内包隐式父目录累计；不创建二十万个磁盘目录。
function budgetedModule(relative,extra){
 const file=path.join(import.meta.dirname,'..',relative);const source=fs.readFileSync(file,'utf8');
 assert.ok(source.includes('const MAX_ENTRIES = 200000;'));
 const js=ts.transpileModule(source.replace('const MAX_ENTRIES = 200000;','const MAX_ENTRIES = 5;'),
  {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText;
 const mod={exports:{}};vm.runInNewContext(js,{module:mod,exports:mod.exports,require:n=>{
  if(n in extra)return extra[n];if(n==='feature_core')return ports;if(n==='commons')return common;
  if(n==='@kit.CoreFileKit')return {fileIo:io};if(n==='@kit.ArkTS')return mocks[n];throw new Error('Unexpected budget import '+n);
 },setTimeout,clearTimeout});return mod.exports;
}
const budgetArchive=budgetedModule('mods/src/main/ets/ModpackArchive.ets',{});
assert.equal(preflight(fixture+'/two-deep.zip').entries,6);
assert.throws(()=>budgetArchive.preflightModpackArchive(fixture+'/two-deep.zip'),/目录与文件数量超限/);
const budgetPackage=budgetedModule('mods/src/main/ets/ModpackPackage.ets',{'./ModpackArchive':budgetArchive});
const budgetWork=await prepare('implicit-parent-payloads');const budgetBefore=extracts;
const deferred=await budgetPackage.discoverModpackPackages(budgetWork,()=>false);
assert.equal(deferred.length,2);assert.equal(extracts,budgetBefore);
const selected=await budgetPackage.materializeModpackPackage(budgetWork,deferred[0],()=>false);
assert.equal(selected.length,1);assert.equal(extracts,budgetBefore+1);
passed('unselected archive expansion is excluded from cumulative budgets');
const chainWork=await prepare('implicit-parent-chain');const chainBefore=extracts;
await assert.rejects(budgetPackage.discoverModpackPackages(chainWork,()=>false),/累计解压预算/);
assert.equal(extracts-chainBefore,1,'所选链的第二层必须在解压前因累计实际目录预算被拒绝');
passed('unique implicit parents and already-selected ancestor layers remain cumulatively budgeted');
const huge=16*1024*1024*1024+1, hugeLocal=Z.exportZipLocalHeader(name,huge), hugeCentral=Z.exportZipCentralHeader(name,huge,0,0,false);
const hugeZip=fixture+'/huge.zip';fs.writeFileSync(hugeZip,Buffer.concat([hugeLocal,hugeCentral,Z.exportZipEnd(1,hugeCentral.length,hugeLocal.length)]));
assert.throws(()=>preflight(hugeZip),/16 GiB/);passed('declared expansion budget is checked before extraction');
let badWork=await prepare('pcl','-bad-extract');afterExtract=(_zip,dest)=>fs.unlinkSync(dest+'/modrinth.index.json');
await assert.rejects(P.discoverModpackPackages(badWork,()=>false),/缺失|不一致/);afterExtract=undefined;passed('missing extraction output is rejected');
badWork=await prepare('pcl','-changed-source');afterExtract=(zip)=>fs.appendFileSync(zip,'changed');
await assert.rejects(P.discoverModpackPackages(badWork,()=>false),/发生变化/);afterExtract=undefined;passed('nested source mutation is rejected before publishing candidates');
const work=await prepare('pcl','-cancel');let cancelled=false, release;
gate=new Promise(r=>release=r);const atDecompress=new Promise(r=>entered=r);let settled=false;
const pending=P.discoverModpackPackages(work,()=>cancelled).finally(()=>settled=true);await atDecompress;
cancelled=true;await new Promise(r=>setImmediate(r));assert.equal(settled,false);release();
await assert.rejects(pending,/取消/);gate=undefined;entered=undefined;passed('cancellation waits for the active decompressor to exit');
await assert.rejects(P.discoverModpackPackages(result.work,()=>true),/取消/);passed('cancellation is checked before discovery IO');
fs.writeFileSync(path.join(reportRoot,'summary.json'),JSON.stringify({completedAt:new Date().toISOString(),groups:receipts.length,passed:receipts,boundary:'Production ETS discovery/preflight; Python ZIP and platform IO/hash boundary substitutes; no device/HAP validation'},null,2));
success=true;console.log('Modpack package regression passed: '+receipts.length+' groups; '+path.join(reportRoot,'summary.json'));
}finally{await scope.close({success});}
