/** 安装fence killpoint回归：运行真实Fence/Executor，平台FS/HDC边界隔离，不安装应用。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import compiler from './lib/ets-compiler.mjs';
import {workspaceTempRoot} from './lib/workspace-paths.mjs';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
function load(file,modules) {const exports={};const js=compiler.transpileModule(fs.readFileSync(path.join(root,file),'utf8'),{compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020}}).outputText;
  vm.runInNewContext(js,{exports,require:n=>{if(!(n in modules))throw new Error('Missing '+n);return modules[n];},JSON,Number,String,RegExp,Object,Date,Set,Map});return exports;}
const base='/sandbox',fencePath=base+'/sideload-update/install-fence.json';
const disk=new Map();let fsyncFailure=false,fsyncCount=0,commandCount=0,gateFailure=false,gateAcquireCount=0,gateReleaseCount=0;
const descriptors=new Map();let descriptorNext=10,shortReadFailure=false,mutateSnapshotOnClose=false;
// HarmonyOS HCF拒绝空DataBlob；Node摘要允许空update，必须在平台边界保留这个实测限制。
let mdUpdateCalls=0;
let realReceiveRoot;
const physical=virtual=>path.join(realReceiveRoot,virtual.slice(base.length));
const raw=p=>Buffer.isBuffer(disk.get(p))?disk.get(p):Buffer.from(disk.get(p)||'');
const fileIo={OpenMode:{READ_ONLY:1},accessSync:p=>disk.has(p),statSync:p=>{if(!disk.has(p))throw Error('missing');return{isFile:()=>true,size:raw(p).length};},readTextSync:p=>raw(p).toString('utf8'),
  unlinkSync:p=>disk.delete(p),openSync:p=>{const fd=descriptorNext++;descriptors.set(fd,{path:p,position:0});return{fd};},
  readSync(fd,buffer,{length}){if(shortReadFailure)return 0;const d=descriptors.get(fd),bytes=raw(d.path),count=Math.min(3,length,bytes.length-d.position);new Uint8Array(buffer).set(bytes.subarray(d.position,d.position+count));d.position+=count;return count;},
  closeSync(file){const fd=typeof file==='object'?file.fd:file,d=descriptors.get(fd);if(mutateSnapshotOnClose&&d?.path.includes('/snapshot-'))disk.set(d.path,Buffer.from('changed after original read'));descriptors.delete(fd);},
  fsyncSync(){fsyncCount++;if(fsyncFailure)throw new Error('directory sync failed');}};
class AtomicWriteError extends Error {constructor(published){super('atomic');this.kind=published?'durability-unknown':'not-committed';}}
const files={SideloadFiles:{write:(p,text)=>disk.set(p,text),ensureDirectory(p){if(realReceiveRoot)fs.mkdirSync(physical(p),{recursive:true});},quote:x=>"'"+x+"'"}};
const protocol=load('entry/src/main/ets/sideload/SideloadInstallProtocol.ets',{'./SideloadFiles':files});
const fenceModule=load('entry/src/main/ets/sideload/InstallFence.ets',{'@kit.CoreFileKit':{fileIo},'libentry.so':{default:{configureSideloadInstallRoot:()=>true}},commons:{AtomicWriteError},'./SideloadFiles':files,'./SideloadInstallProtocol':protocol});
const {InstallFence}=fenceModule;
const identity={installId:'a'.repeat(32),ownerAttemptId:'b'.repeat(32),nonce:'c'.repeat(32),bundleName:'com.amcl.launcher',product:'sideload',beforeVersionCode:1,beforeUid:42,
  versionCode:2,expectedPayloadIdentity:'d'.repeat(40),signedPath:base+'/sideload-update/tasks/'+ 'e'.repeat(32)+'/signed.hap',signedSha256:'f'.repeat(64),protocol:2};
const {SideloadInstallExecutor:Executor}=load('entry/src/main/ets/sideload/SideloadInstallExecutor.ets',{
  '@kit.CoreFileKit':{fileIo},'@kit.ArkTS':{util:{generateRandomUUID:()=> 'e'.repeat(32)}},'libentry.so':{default:{}},'./SideloadConnection':{},'./SideloadFiles':files,
  '@kit.CryptoArchitectureKit':{cryptoFramework:{createMd:()=>{const parts=[];return{async update(input){mdUpdateCalls++;if(input.data.byteLength===0)throw new Error('HCF rejects empty DataBlob');parts.push(Buffer.from(input.data));},async digest(){return{data:new Uint8Array(createHash('sha256').update(Buffer.concat(parts)).digest())};}};}}},
  './UpdateInstallGate':{UpdateInstallGate:class{acquire(){gateAcquireCount++;if(gateFailure)throw new Error('game shared lease active');}release(){gateReleaseCount++;}}},'./InstallFence':fenceModule,'./BmTerminalEvidence':{},'./SideloadInstallProtocol':protocol});
const connection={async check(){commandCount++;throw new Error('offline');},async close(){},async command(){commandCount++;}};
// arm刚持久后断电：新Executor没有内存certificate，但Preparing仍是未安排执行请求的证明。
let fence=new InstallFence(base);fence.arm(identity);assert.equal(fence.preparing(identity),true);
let executor=new Executor(base,connection);let proof=await executor.revoke(identity);assert.equal(proof.safeToRelease,true);assert.equal(commandCount,0);
// mode持久后、dispatch前断电依然可证明未安排请求，不能因有worker字节便误作已派发。
fence.setMode(identity,'flock-rename');executor=new Executor(base,connection);proof=await executor.revoke(identity);assert.equal(proof.safeToRelease,true);assert.equal(commandCount,0);
// markDispatching是唯一进入外部请求窗口的durable步骤，冷启动不得恢复NoInvocation。
fence.markDispatching(identity);assert.equal(fence.preparing(identity),false);executor=new Executor(base,connection);proof=await executor.revoke(identity);assert.equal(proof.safeToRelease,false);assert.equal(commandCount,1);
assert.throws(()=>fence.setMode(identity,'link'));
// 旧schema1/no-state即使同nonce也没有新Preparing证明。
disk.set(fencePath,JSON.stringify({schema:1,protocol:2,installId:identity.installId,nonce:identity.nonce,ownerAttemptId:identity.ownerAttemptId,createdAt:1}));
assert.equal(new InstallFence(base).preparing(identity),false);
// unlink后目录同步失败，重试缺文件仍须fsync，不能缺文件直接成功。
disk.set(fencePath,JSON.stringify({schema:2,protocol:2,state:'preparing',installId:identity.installId,nonce:identity.nonce,ownerAttemptId:identity.ownerAttemptId,createdAt:1}));
fsyncFailure=true;assert.throws(()=>fence.clear(identity),e=>e.kind==='durability-unknown');assert.equal(disk.has(fencePath),false);
const before=fsyncCount;fsyncFailure=false;fence.clear(identity);assert.equal(fsyncCount,before+1);
// legacy安装未知与损坏journal启动均保留阻断，不能补造新的no-dispatch状态。
disk.set(base+'/sideload-update/transaction.json','{broken');assert.equal(InstallFence.init(base),true);assert.equal(new InstallFence(base).preparing(identity),false);
// 从未prepare的冷Executor没有默认NoInvocation，不能把“内存false”当旧派发的证明。
disk.clear();executor=new Executor(base,connection);const coldCommands=commandCount;proof=await executor.revoke(identity);
assert.equal(proof.safeToRelease,false);assert.equal(commandCount,coldCommands+1);
// guards在EX/fence之前失败：证书只归本次新identity，收尾不抢EX、不访问HDC。
const current={assertCurrent(){throw new Error('cancelled');},assertForeground(){}};
executor=new Executor(base,connection);const preGuardCommands=commandCount,preGuardAcquires=gateAcquireCount;
await assert.rejects(executor.prepare(identity,current),e=>e.kind==='cancelled');assert.equal(disk.has(fencePath),false);
proof=await executor.revoke(identity);assert.equal(proof.safeToRelease,true);executor.complete(identity,proof,false);await executor.cleanupPayload(identity);
assert.equal(gateAcquireCount,preGuardAcquires);assert.equal(commandCount,preGuardCommands);
// 游戏SH使EX失败也从未派发；游戏继续存活时仍可收尾并立即允许新identity准备。
const next={...identity,installId:'1'.repeat(32),nonce:'2'.repeat(32)},guards={assertCurrent(){},assertForeground(){}};
gateFailure=true;const preGateAcquires=gateAcquireCount;await assert.rejects(executor.prepare(next,guards),/game shared lease active/);
proof=await executor.revoke(next);assert.equal(proof.safeToRelease,true);executor.complete(next,proof,false);await executor.cleanupPayload(next);
assert.equal(gateAcquireCount,preGateAcquires+1);assert.equal(commandCount,preGuardCommands);assert.equal(disk.has(fencePath),false);
await assert.rejects(executor.prepare(next,guards),e=>e.kind==='outcome-unknown'); // 完结nonce永久不可重用。
gateFailure=false;const retry={...identity,installId:'3'.repeat(32),nonce:'4'.repeat(32)};
await assert.rejects(executor.prepare(retry,guards),/offline/);assert.equal(new InstallFence(base).preparing(retry),true);
proof=await executor.revoke(retry);assert.equal(proof.safeToRelease,true);const beforeClear=gateAcquireCount;executor.complete(retry,proof,false);
assert.equal(gateAcquireCount,beforeClear+1);assert.equal(disk.has(fencePath),false);assert.ok(gateReleaseCount>0);
// 旧fence拒绝本次登记：未进入prepare effect的新identity绝不能据此获得清旧保护许可。
new InstallFence(base).arm(identity);executor=new Executor(base,connection);
await assert.rejects(executor.prepare(next,guards),e=>e.kind==='outcome-unknown');proof=await executor.revoke(next);assert.equal(proof.safeToRelease,false);
assert.equal(new InstallFence(base).preparing(identity),true);
// 读取真实Executor私有快照方法：平台文件短读/消失/并发修改只替换边界，摘要仍由同份bytes生成。
let transfer=Buffer.from('完整 UTF8 snapshot😀\n'),transferMissing=false;
realReceiveRoot=fs.mkdtempSync(path.join(workspaceTempRoot(),'bm-evidence-read-'));
const snapshotConnection={async command(args){if(transferMissing)throw Error('receive failed');
  // 真实写入边界不替接收路径造父目录：旧observed-UUID-remoteName含/时必然ENOENT。
  fs.writeFileSync(physical(args[3]),transfer);disk.set(args[3],Buffer.from(transfer));}};
const snapshotExecutor=new Executor(base,snapshotConnection);
transfer=Buffer.from('{"bmPid":88}');
assert.equal(await snapshotExecutor.read(identity,'bm-evidence-88/bm-process.json',2048),'{"bmPid":88}');
assert.equal(await snapshotExecutor.read(identity,'bm-evidence-88/bm-log-evidence.json',4096),'{"bmPid":88}');
transfer=Buffer.from('完整 UTF8 snapshot😀\n');
mutateSnapshotOnClose=true;let actual=await snapshotExecutor.readSnapshot(identity,'proof/log');mutateSnapshotOnClose=false;
assert.deepEqual(Buffer.from(actual.bytes),transfer);assert.equal(actual.sha256,createHash('sha256').update(transfer).digest('hex'));
assert.equal(descriptors.size,0);
const beforeEmptyMdUpdates=mdUpdateCalls;
transfer=Buffer.alloc(0);actual=await snapshotExecutor.readSnapshot(identity,'proof/empty');assert.equal(actual.bytes.length,0);
assert.equal(actual.sha256,createHash('sha256').update('').digest('hex'));
assert.equal(mdUpdateCalls,beforeEmptyMdUpdates,'真实0B文件直接digest，不向HarmonyOS HCF传空update');
transferMissing=true;assert.equal(await snapshotExecutor.readSnapshot(identity,'proof/missing'),undefined);transferMissing=false;
transfer=Buffer.from('short');shortReadFailure=true;assert.equal(await snapshotExecutor.readSnapshot(identity,'proof/short'),undefined);shortReadFailure=false;
transfer=Buffer.alloc(65536);assert.equal(await snapshotExecutor.readSnapshot(identity,'proof/oversize'),undefined);assert.equal(descriptors.size,0);
// 此目录由本测试独占创建，只有本测试接收件；保留其他宿主/设备证据。
assert(fs.realpathSync(realReceiveRoot).startsWith(fs.realpathSync(workspaceTempRoot())+path.sep),'cleanup stays within verified host test root');
fs.rmSync(realReceiveRoot,{recursive:true,force:true});realReceiveRoot=undefined;
console.log('PASS actual Executor snapshot: short reads, exact UTF8 bytes/SHA, close-time mutation cannot swap digest, missing vs genuine empty, size bounds and descriptor cleanup');
console.log('PASS production fence killpoints: arm/no-mode, mode/pre-dispatch, dispatch boundary, legacy no-fake-proof, post-unlink durability retry, corrupt journal blocks, cold no-certificate, guard/gate failure no ghost ownership, retry fresh identity, old fence isolation');
