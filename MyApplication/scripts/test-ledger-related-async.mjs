/** 真实账本原件验证异步导航投影：同关系/顺序/上限，损坏或取消不造关系，不改终态。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';

/** 原ledgerBegin写入隔离文件，测试不实现关系算法；同步/异步都读取同一批原manifest。 */
function fixture() {
  const runtime = evidenceRuntime();
  const ledger = runtime.load('commons/src/main/ets/utils/ActivityLedger.ets');
  const current = Date.now()-10000;
  const begin = (id, extra={}) => ledger.ledgerBegin(runtime.directory, id, {
    category: 'launch', title: String(id), gameVersionId: '26.3', mcDir: '/fixture-game', ...extra,
  });
  begin(current-1); begin(current, { parentActivityId: current-1 });
  for (let i=1;i<=12;i++) begin(current+i, { parentActivityId: current, relation: i===1?'retry':i===2?'graphics-recovery':'child' });
  for (let i=20;i<27;i++) begin(current+i);
  begin(current+30, { mcDir: '/foreign-game' });
  return { runtime, ledger, current };
}

test('异步原件读取保留同步关系、倒序和8/4上限，不制造跨实例关系或改写manifest', async () => {
  const f=fixture();
  try {
    const before=fs.readFileSync(f.runtime.directory+'/logs/ledger/'+f.current+'/manifest.json','utf8');
    const sync=f.ledger.ledgerRelatedActivities(f.runtime.directory,f.current);
    const asyncResult=await f.ledger.ledgerRelatedActivitiesAsync(f.runtime.directory,f.current,()=>false);
    assert.deepEqual(asyncResult,sync); assert.equal(asyncResult.length,12);
    assert.equal(asyncResult.filter(r=>r.relation==='同版本其他尝试').length,4);
    assert.ok(!asyncResult.some(r=>r.activityId===f.current+30));
    assert.equal(fs.readFileSync(f.runtime.directory+'/logs/ledger/'+f.current+'/manifest.json','utf8'),before);
  } finally { f.runtime.close(); }
});

test('损坏/缺失原manifest与同步读取一致，不将索引元数据当成真实关系', async () => {
  const f=fixture();
  try {
    f.runtime.write('logs/ledger/'+(f.current+12)+'/manifest.json','{broken');
    assert.deepEqual(await f.ledger.ledgerRelatedActivitiesAsync(f.runtime.directory,f.current,()=>false),
      f.ledger.ledgerRelatedActivities(f.runtime.directory,f.current));
    f.runtime.write('logs/ledger/'+f.current+'/manifest.json','{broken');
    assert.deepEqual(await f.ledger.ledgerRelatedActivitiesAsync(f.runtime.directory,f.current,()=>false),[]);
  } finally { f.runtime.close(); }
});

test('离页取消在进入和批次边界拒绝，不向页面提交一个假空关系结果', async () => {
  const f=fixture();
  try {
    await assert.rejects(()=>f.ledger.ledgerRelatedActivitiesAsync(f.runtime.directory,f.current,()=>true),/已取消/);
    let checks=0;
    await assert.rejects(()=>f.ledger.ledgerRelatedActivitiesAsync(f.runtime.directory,f.current,()=>++checks>=3),/已取消/);
    assert.equal(checks,3);
  } finally { f.runtime.close(); }
});
