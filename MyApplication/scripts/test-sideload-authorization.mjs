/**
 * 执行真实SideloadConnection的完整握手回路，仅替换Native/文件/时钟平台边界。
 * 虚拟时间模拟人在13/60/179秒才授权，避免真实等待三分钟；不替代真实设备安全弹窗验证。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import {fileURLToPath} from 'node:url';
import compiler from './lib/ets-compiler.mjs';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const source=fs.readFileSync(path.join(root,'entry/src/main/ets/sideload/SideloadConnection.ets'),'utf8');
const code=compiler.transpileModule(source,{compilerOptions:{module:compiler.ModuleKind.CommonJS,target:compiler.ScriptTarget.ES2020}}).outputText;

/** 仅固定虚拟沙箱字段；没有宿主/设备文件写入，回传nonce必须由真实业务核验。 */
function fixture(allowAt,holdCommand='',badNonce=false){
 let now=1000,body='',exists=false,release;
 const calls=[],writes=[],nonce='a'.repeat(32),udid='B'.repeat(64);
 const gate=new Promise(resolve=>{release=resolve;});
 const native={discoverSideloadPort:async()=>37437,startSideloadHdc:async()=>12345,stopSideloadHdc:async()=>{calls.push('stop');},
  async runSideloadHdcCommand(command,output){
   if(command.includes('\ttconn\t')){calls.push('tconn');return 0;}
   if(command.includes('printf ')){calls.push('shell');if(holdCommand==='shell')await gate;return now>=allowAt?0:-7;}
   if(command.includes('\tfile\trecv\t')){calls.push('file');if(holdCommand==='file')await gate;if(now>=allowAt){body=badNonce?'old nonce':nonce;exists=true;}return 0;}
   if(command.includes('bm get -u')){calls.push('udid');if(holdCommand==='udid')await gate;assert(output);body='udid of current device is:\n'+udid;exists=true;return 0;}
   if(command.includes('rm -f ')){calls.push('rm');return 0;}
   throw Error('Unexpected native command');
  }};
 const modules={'@kit.NetworkKit':{socket:{constructTCPSocketInstance:()=>({connect:async()=>{},close:async()=>{}})}},
  '@kit.ArkTS':{util:{generateRandomUUID:()=>nonce}},'@kit.CoreFileKit':{fileIo:{accessSync:()=>exists,statSync:()=>({size:body.length}),readTextSync:()=>body,unlinkSync:()=>{exists=false;}}},
  'libentry.so':{default:native},'./SideloadFiles':{SideloadFiles:{quote:JSON.stringify,write:(_path,value)=>writes.push(value)}}};
 const exports={};class Clock extends Date{static now(){return now;}}
 vm.runInNewContext(code,{exports,require:name=>{assert(name in modules);return modules[name];},Date:Clock,
  setTimeout(callback,delay){now+=delay;return setImmediate(callback);},console,Number,RegExp,Promise});
 return{connection:new exports.SideloadConnection('/fixture'),calls,writes,release,elapsed:()=>now-1000};
}

for(const seconds of [13,60,179]){
 const f=fixture(1000+seconds*1000),first=f.connection.check();
 assert.equal(first,f.connection.check());assert.equal(await first,'B'.repeat(64));
 assert.equal(f.calls.filter(v=>v==='tconn').length,1);assert.equal(f.calls.filter(v=>v==='udid').length,1);
 assert(f.elapsed()>=seconds*1000);assert.equal(f.writes.length,1);await f.connection.close();
}
// 超时不保存端口和UDID；返回码0本身不能构造文件证明。
for(const f of [fixture(Infinity),fixture(0,'',true)]){
 await assert.rejects(f.connection.check(),/尚未完成/);
 assert(f.elapsed()>=190000 && f.elapsed()<191000);assert.equal(f.writes.length,0);assert.equal(f.connection.deviceUdid(),'');
 assert.equal(f.calls.includes('udid'),false);await f.connection.close();
}
// 在真实await边界调用close，验证不会追加长文件接收或把晚返回的UDID保存成就绪。
for(const held of ['shell','file','udid']){
 const f=fixture(0,held),checking=f.connection.check();
 const rejected=assert.rejects(checking,/尚未完成|查询失败/);
 while(!f.calls.includes(held))await new Promise(resolve=>setImmediate(resolve));
 const closing=f.connection.close();f.release();await rejected;await closing;
 if(held==='shell')assert.equal(f.calls.includes('file'),false);
 if(held!=='udid')assert.equal(f.calls.includes('udid'),false);
 assert.equal(f.calls.includes('rm'),false);assert.equal(f.writes.length,0);assert.equal(f.connection.deviceUdid(),'');
 assert.equal(f.calls.filter(v=>v==='stop').length,1);
}
console.log('PASS real HDC authorization lifecycle: delayed human grant, bounded timeout, single session and cancellation during command');
