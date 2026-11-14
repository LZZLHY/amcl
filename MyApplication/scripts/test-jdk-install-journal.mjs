/**
 * 生产ArkTS journal的真实宿主进程死亡回归。子进程在真实文件rename后exit，父重新加载生产类恢复。
 * Windows目录fsync仅作为SDK边界记录（Node无法打开目录）；OHOS目录同步能力仍由SDK/设备验收。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {makePureEtsLoader} from './lib/load-pure-ets.mjs';
const directoryHandles=new Set();let serial=1000000;
const fakeLocks=new Map();
const io={OpenMode:{READ_ONLY:0,CREATE:1,WRITE_ONLY:2,TRUNC:4,READ_WRITE:8},
 statSync:p=>fs.statSync(p),lstatSync:p=>fs.lstatSync(p),readTextSync:p=>fs.readFileSync(p,'utf8'),listFileSync:p=>fs.readdirSync(p),
 openSync(p,mode){
   if(fs.existsSync(p)&&fs.statSync(p).isDirectory()){const fd=++serial;directoryHandles.add(fd);return{fd};}
   const fd=fs.openSync(p,mode&4?'w':mode&1?'a+':'r+');
   return{fd,tryLock(){if(fakeLocks.has(p))throw Object.assign(Error('busy'),{code:13900034});fakeLocks.set(p,fd);},unlock(){fakeLocks.delete(p);}};
 },
 writeSync:(fd,v)=>fs.writeSync(fd,v),fsyncSync:fd=>{if(!directoryHandles.has(fd))fs.fsyncSync(fd);},
 closeSync:f=>{const fd=f.fd??f;if(!directoryHandles.delete(fd))fs.closeSync(fd);},
 renameSync(a,b){fs.renameSync(a,b);if(process.env.JDK_TEST_CRASH==='journal'&&a.endsWith('.writing')||process.env.JDK_TEST_CRASH==='old'&&/[/\\]17$/.test(a)||process.env.JDK_TEST_CRASH==='new'&&a.includes('.staging-'))process.exit(73);},
 unlinkSync:p=>fs.unlinkSync(p)};
const load=()=>makePureEtsLoader({'@kit.CoreFileKit':{fileIo:io},'@kit.BasicServicesKit':{},
 commons:{ensureDirSync:p=>fs.mkdirSync(p,{recursive:true}),removeDirRecursive:p=>fs.rmSync(p,{recursive:true,force:true}),AppLogger:{warn(){}}},
 './JdkTreeValidation':{validateRuntimeTree:p=>fs.existsSync(path.join(p,'valid'))?'':'invalid fixture'}})('launch/src/main/ets/JdkInstallJournal.ets').JdkInstallJournal;
const self=fileURLToPath(import.meta.url);
if(process.argv[2]==='--worker'){
 const area=process.argv[3];await load().publish(area,'17',area+'/jdk/.staging-fixture');process.exit(0);
}
const out=process.env.AMCL_RUN_DIR;if(!out||!path.isAbsolute(out))throw Error('AMCL_RUN_DIR must explicitly name external test output');
fs.mkdirSync(out,{recursive:true});const area=fs.mkdtempSync(path.join(out,'journal-fixture-'));
const results=[];
try{
 for(const boundary of ['journal','old','new']){
   const caseRoot=path.join(area,boundary);const target=caseRoot+'/jdk/17',stage=caseRoot+'/jdk/.staging-fixture';
   for(const [dir,value]of[[target,'old'],[stage,'new']]){fs.mkdirSync(dir,{recursive:true});fs.writeFileSync(dir+'/valid',value);fs.writeFileSync(dir+'/.amcl_release_tag',value);}
   const child=spawnSync(process.execPath,[self,'--worker',caseRoot],{env:{...process.env,JDK_TEST_CRASH:boundary},encoding:'utf8'});
   assert.equal(child.status,73,child.stderr);assert(fs.existsSync(caseRoot+'/jdk/.locks/17.publish.json'));
   load().recoverWithWriter(caseRoot,'17');
   assert.equal(fs.readFileSync(target+'/valid','utf8'),boundary==='new'?'new':'old');
   assert(!fs.existsSync(caseRoot+'/jdk/.locks/17.publish.json'));assert.equal(fs.readdirSync(caseRoot+'/jdk').some(n=>n.includes('.backup-')),false);
   results.push(boundary);
 }
 // 损坏记录不能通过猜测backup名称触发删除。
 const broken=path.join(area,'broken');fs.mkdirSync(broken+'/jdk/.locks',{recursive:true});fs.writeFileSync(broken+'/jdk/.locks/17.publish.json','{}');
 assert.throws(()=>load().recoverWithWriter(broken,'17'));assert(fs.existsSync(broken+'/jdk/.locks/17.publish.json'));
 // backup被换成目录链接时，即使所指向的旧目录inode/元数据吻合，也没有恢复/删除资格。
 const linked=path.join(area,'linked');
 for(const [name,value]of[['17','old'],['.staging-fixture','new']]){const p=linked+'/jdk/'+name;fs.mkdirSync(p,{recursive:true});fs.writeFileSync(p+'/valid',value);fs.writeFileSync(p+'/.amcl_release_tag',value);}
 const child=spawnSync(process.execPath,[self,'--worker',linked],{env:{...process.env,JDK_TEST_CRASH:'old'},encoding:'utf8'});assert.equal(child.status,73,child.stderr);
 const backup=linked+'/jdk/'+fs.readdirSync(linked+'/jdk').find(n=>n.includes('.backup-'));const retained=linked+'/retained-old';fs.renameSync(backup,retained);fs.symlinkSync(retained,backup,'junction');
 assert.throws(()=>load().recoverWithWriter(linked,'17'),/目录/);assert.equal(fs.readFileSync(retained+'/valid','utf8'),'old');assert(fs.existsSync(linked+'/jdk/.locks/17.publish.json'));
 console.log(JSON.stringify({passed:results.length+2,realChildExitCheckpoints:results,linkedBackupRefused:true,scope:'production ArkTS; real disk and process death; SDK locks/directory fsync modeled; OHOS verification remains'},null,2));
 fs.rmSync(area,{recursive:true});
}catch(e){console.error('Failed fixture retained at '+area);throw e;}
