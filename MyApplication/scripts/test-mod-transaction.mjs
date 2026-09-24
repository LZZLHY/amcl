import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import {loader,productionPathPolicy} from './mod-install-test-runtime.mjs';

const files=new Map(),dirs=new Set(['/virtual','/virtual/game','/virtual/game/mods']);
const descriptors=new Map();let nextFd=1,renameFault=null,writeFault=null,unlinkFault=null,removeFault=null;
const parent=p=>p.slice(0,p.lastIndexOf('/'));
const hash=b=>crypto.createHash('sha1').update(b).digest('hex');
const put=(p,body)=>files.set(p,Buffer.from(body));
const stats=p=>{if(!files.has(p)&&!dirs.has(p))throw new Error('ENOENT '+p);return {size:files.get(p)?.length??0,isFile:()=>files.has(p),isDirectory:()=>dirs.has(p),isSymbolicLink:()=>false};};
const io={OpenMode:{CREATE:1,WRITE_ONLY:2,TRUNC:4},
  statSync:stats,lstatSync:stats,
  mkdirSync(p){if(dirs.has(p))throw new Error('EEXIST');for(let q=p;q.length;q=parent(q))dirs.add(q);},
  listFileSync:p=>[...files.keys(),...dirs].filter(n=>parent(n)===p).map(n=>n.slice(n.lastIndexOf('/')+1)),
  openSync(p){if(writeFault?.(p))throw new Error('ENOSPC');put(p,'');const fd=nextFd++;descriptors.set(fd,p);return {fd};},
  writeSync(fd,data){put(descriptors.get(fd),data);return Buffer.byteLength(data);},
  fsyncSync(){},closeSync(f){descriptors.delete(f.fd??f);},readTextSync:p=>files.get(p).toString(),
  renameSync(a,b){if(renameFault?.(a,b))throw new Error('injected rename failure');if(!files.has(a))throw new Error('ENOENT '+a);files.set(b,files.get(a));files.delete(a);},
  unlinkSync(p){if(unlinkFault?.(p))throw new Error('injected unlink failure');if(!files.delete(p))throw new Error('ENOENT '+p);},
};
const remove=p=>{if(removeFault?.(p))return;for(const n of [...files.keys()])if(n===p||n.startsWith(p+'/'))files.delete(n);for(const n of [...dirs])if(n===p||n.startsWith(p+'/'))dirs.delete(n);};
const tx=loader({'@kit.CoreFileKit':{fileIo:io},feature_core:{...productionPathPolicy(),computeFileSha1:async p=>{if(!files.has(p))throw new Error('ENOENT');return hash(files.get(p));}},commons:{removeDirRecursive:remove,AppLogger:{warn(){}},LOG_DOMAIN_DOWNLOAD:0}})('mods/src/main/ets/ModInstallTransaction.ets');
const dir='/virtual/game/mods';
tx.ensureModDirectory(dir);
tx.ensureModDirectory(dir);
function setup(name='a.jar',oldNames=[name],body='new'){
  const staging=tx.createModStaging(dir);io.mkdirSync(staging+'/download/0');put(staging+'/download/0/a.jar',body);
  return {staging,changes:[{newName:name,oldNames,stagedRelative:'download/0/a.jar',sha1:hash(body)}]};
}
put(dir+'/a.jar','old');let s=setup();await tx.commitModFiles(dir,s.staging,s.changes);assert.equal(files.get(dir+'/a.jar').toString(),'new');
put(dir+'/a.jar','old');s=setup();writeFault=p=>p.endsWith('.tmp');await assert.rejects(tx.commitModFiles(dir,s.staging,s.changes),/ENOSPC/);writeFault=null;assert.equal(files.get(dir+'/a.jar').toString(),'old');
s=setup();renameFault=(a,b)=>a.includes('/download/')&&b===dir+'/a.jar';await assert.rejects(tx.commitModFiles(dir,s.staging,s.changes));renameFault=null;assert.equal(files.get(dir+'/a.jar').toString(),'old');assert.equal(files.has(dir+'/.amcl-mod-transaction.json'),false);
put(dir+'/a.jar.disabled','disabled-old');files.delete(dir+'/a.jar');s=setup('a.jar.disabled');await tx.commitModFiles(dir,s.staging,s.changes);assert.equal(files.get(dir+'/a.jar.disabled').toString(),'new');assert.equal(files.has(dir+'/a.jar'),false);
put(dir+'/old.jar','old-version');s=setup('new.jar',['old.jar']);await tx.commitModFiles(dir,s.staging,s.changes);assert.equal(files.has(dir+'/old.jar'),false);assert.equal(files.get(dir+'/new.jar').toString(),'new');
put(dir+'/one.jar','one-old');put(dir+'/two.jar','two-old');s=setup('one.jar');io.mkdirSync(s.staging+'/download/1');put(s.staging+'/download/1/two.jar','two-new');s.changes.push({newName:'two.jar',oldNames:['two.jar'],stagedRelative:'download/1/two.jar',sha1:hash('two-new')});
renameFault=(a,b)=>a.includes('/download/')&&b===dir+'/two.jar';await assert.rejects(tx.commitModFiles(dir,s.staging,s.changes));renameFault=null;assert.equal(files.get(dir+'/one.jar').toString(),'one-old');assert.equal(files.get(dir+'/two.jar').toString(),'two-old');
// Keep recovery evidence when both activation and immediate rollback fail.
s=setup('one.jar');renameFault=(a,b)=>a.includes('/download/')||a.includes('/backup/');await assert.rejects(tx.commitModFiles(dir,s.staging,s.changes),/恢复尚未完成/);assert.equal(tx.modTransactionPending(dir),true);renameFault=null;await tx.recoverModTransaction(dir);assert.equal(files.get(dir+'/one.jar').toString(),'one-old');assert.equal(tx.modTransactionPending(dir),false);
let release;const gate=new Promise(r=>release=r),order=[];
const first=tx.withModDirectoryLock(dir,async()=>{order.push('first');await gate;});
const second=tx.withModDirectoryLock(dir,async()=>{order.push('second');});
const other=tx.withModDirectoryLock('/virtual/other/mods',async()=>{order.push('other');});
await other;assert.equal(order.includes('second'),false);release();await Promise.all([first,second]);assert.deepEqual(order,['first','other','second']);
// A completed commit remains successful if only journal deletion fails.
put(dir+'/cleanup.jar','old');s=setup('cleanup.jar');unlinkFault=p=>p.endsWith('.amcl-mod-transaction.json');
await tx.commitModFiles(dir,s.staging,s.changes);assert.equal(files.get(dir+'/cleanup.jar').toString(),'new');assert.equal(files.has(dir+'/.amcl-mod-transaction.json'),true);
unlinkFault=null;await tx.recoverModTransaction(dir);assert.equal(files.get(dir+'/cleanup.jar').toString(),'new');assert.equal(tx.hasModRecoveryJournal(dir),false);
// Cleanup can partially remove staging. A persisted restored state prevents a second rollback.
put(dir+'/restore.jar','old');s=setup('restore.jar');renameFault=(a,b)=>a.includes('/download/')&&b===dir+'/restore.jar';removeFault=()=>true;
await assert.rejects(tx.commitModFiles(dir,s.staging,s.changes));renameFault=null;
assert.equal(files.get(dir+'/restore.jar').toString(),'old');assert.equal(tx.hasModRecoveryJournal(dir),true);
files.delete(s.staging+'/download/0/a.jar');removeFault=null;
await tx.recoverModTransaction(dir);assert.equal(files.get(dir+'/restore.jar').toString(),'old');assert.equal(tx.hasModRecoveryJournal(dir),false);
console.log('PASS: same/different filename and disabled updates, disk-full before mutation, activation failure, multi-file rollback, retained recovery journal, terminal cleanup failures, idempotent recovery and directory concurrency');
