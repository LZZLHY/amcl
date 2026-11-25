// 核对旧开发动作的设备会话、原请求认领与断线后不重复派发。
import assert from 'node:assert/strict';
import { actions, session, root, dir, disk, counters, context, grant, signal, installGrant, model, send, reply } from './session-fixture.mjs';

const handler = async (_action,args,id) => {
  counters.calls++;
  return JSON.stringify({status:'ok',data:{args:JSON.parse(args),id}});
};
let device = model();
installGrant({...grant, sourceRevision:'b'.repeat(40)});
assert.equal(device.activate(context,signal,false),false);
installGrant(grant);
assert.equal(device.activate(context,{},true),false);
assert.equal(disk.has(dir+'/grant.json'),false);
assert.equal(model(false).activate(context,signal,false),false);
assert.equal(device.activate(context,signal,false),true);
assert.deepEqual(JSON.parse(disk.get(root + '/hello-' + session + '.json')).actions,actions);
const id1='1'.repeat(32), id2='2'.repeat(32), id3='3'.repeat(32);
send(1,id1,'versions.list',{});
await device.tick();
assert.equal(counters.calls,0);
device.bind({},handler,handler);
send(1,id1,'versions.list',{},id2);
await device.tick();
assert.equal(counters.calls,0);
send(1,id1,'versions.list',{});
await device.tick(); await device.tick();
assert.equal(reply(1).status,'ok'); assert.equal(counters.calls,1);
send(2,id1,'game.launch',{versionId:'changed'});
await device.tick();
assert.equal(reply(2).status,'rejected');assert.equal(counters.calls,1);
send(3,id2,'raw.shell',{});
await device.tick(); assert.equal(reply(3).status,'rejected');
send(4,id3,'versions.install',{gameVersion:'demo'});
// 模拟在副作用发出后、回执落盘前崩溃。重启只能回报未知。
disk.set(dir+'/claim-4.json',JSON.stringify([id3,'versions.install',JSON.stringify({gameVersion:'demo'})]));
device=model();device.bind({},handler,handler);device.activate(context,{},true);await device.tick();
assert.equal(reply(4).status,'unknown');assert.equal(counters.calls,1);
disk.set(root + '/close-' + session + '.txt',session);
await device.tick(); assert.equal(device.sessionDirectory(),'');
assert.equal(device.activate(context,signal,false),false);
console.log('PASS: live binding, grant identity, commit barrier, one dispatch, ID collision, blocked action, durable unknown and teardown');

// 真实设备代码先发布回执，再同步目录。模拟这一小段失败而宿主已经读到第一份 OK。
for (const nextAlreadySent of [false,true]) {
  disk.clear(); disk.set(root,null); installGrant(grant); counters.calls=0;
  let fail=true;
  const modelWithFault=model(true,{after(path) {
    if (path===dir+'/reply-1.json' && fail) {fail=false;throw Error('directory sync failed after publication');}
  }});
  modelWithFault.activate(context,signal,false); modelWithFault.bind({},handler,handler);
  send(1,id1,'versions.list',{});
  await assert.rejects(modelWithFault.tick(),/after publication/);
  const first=disk.get(dir+'/reply-1.json');
  assert.equal(JSON.parse(first).status,'ok');assert.equal(counters.calls,1);
  if(nextAlreadySent) send(2,id2,'versions.list',{});
  await modelWithFault.tick();
  assert.equal(disk.get(dir+'/reply-1.json'),first);assert.equal(counters.calls,nextAlreadySent?2:1);
  if (!nextAlreadySent) {send(2,id2,'versions.list',{});await modelWithFault.tick();}
  assert.equal(reply(2).status,'ok');assert.equal(counters.calls,2);
}

// 人决定太晚时先拒绝接新任务，原在途结束后仍须依次写回执与关闭确认；时钟替身只影响本用例。
const realNow=Date.now;
try {
  let now=realNow();Date.now=()=>now;
  disk.clear(); disk.set(root,null);
  const short={...grant,expiresAt:now+500};installGrant(short);
  const slow=model();slow.activate(context,signal,false);
  let resolve;
  slow.bind({},()=>new Promise(done=>{resolve=done;}),handler);
  send(1,id1,'versions.list',{});
  const inFlight=slow.tick();
  now+=1000;await slow.tick();
  assert.equal(disk.has(dir+'/closed.json'),false);assert.equal(slow.sessionDirectory(),'');
  resolve(JSON.stringify({status:'rejected',data:{},reason:'user cancelled'}));
  await inFlight;await slow.tick();
  assert.equal(reply(1).status,'rejected');assert.equal(JSON.parse(disk.get(dir+'/closed.json')).closed,true);
  // 进程死亡且原请求已认领、未拿到结果。过期的冷恢复封存未知与关闭，不重新取得授权或派发。
  disk.clear(); disk.set(root,null);installGrant(short);disk.set(dir,null);disk.set(dir+'/grant.json',JSON.stringify(short));
  disk.set(dir+'/claim-1.json',JSON.stringify([id1,'versions.list','{}']));
  const cold=model();cold.bind({},handler,handler);const before=counters.calls;
  assert.equal(cold.activate(context,{},true),false);
  assert.equal(reply(1).status,'unknown');assert.equal(reply(1).id,id1);assert.equal(counters.calls,before);
  assert.equal(JSON.parse(disk.get(dir+'/closed.json')).session,session);
  disk.delete(dir+'/grant.json'); disk.delete(dir+'/closed.json');
  assert.equal(model().activate(context,signal,false),false);assert.equal(disk.has(dir+'/closed.json'),false);
} finally {Date.now=realNow;}
console.log('PASS published reply survives sync error, next sequence progresses and expired grants close without replay');
