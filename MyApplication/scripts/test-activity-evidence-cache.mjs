/**
 * 对真实详情服务验证固定原始收据的有界复用：完整/封账/高精度且打开前后稳定才跳过正文hash。
 * 文件、SDK适配和缓存均为独占runtime，成功或失败finally关闭，不发网络、不持有后台任务。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';

/** 只提供合法固定原件/收据，实际枚举、hash、缓存和错误判定全部由生产服务执行。 */
function fixture() {
  const runtime = evidenceRuntime();
  const root = runtime.directory, body = 'fixed original first\nfixed original second\n';
  const path = runtime.write('logs/ledger/100/game/logs/latest.log', body);
  runtime.write('logs/ledger/100/manifest.json', JSON.stringify({ activityId: 100, category: 'launch', startedAt: 100,
    endedAt: 200, state: 1, files: [] }));
  const plan = { schema: 1, activityId: 100, startedAt: 100, endedAt: 200, gameDir: '', filesDir: root,
    appFilesDir: '', jdk: '', sources: [{ source: path, destination: 'game/logs/latest.log', baseline: '',
      baselineDigest: '', captured: 'fixed-receipt', capturedSha256: createHash('sha256').update(body).digest('hex'),
      capturedBytes: Buffer.byteLength(body), state: 'complete', reason: '', attribution: 'exact', mode: 'snapshot', sealed: true }] };
  runtime.write('logs/ledger/100/capture-sources.json', JSON.stringify(plan));
  const service = runtime.load('entry/src/main/ets/components/ActivityEvidenceService.ets');
  const originalRead = runtime.kitFs.read; let reads = 0;
  runtime.kitFs.read = (...args) => { reads++; return originalRead(...args); };
  return { runtime, path, body, root, plan, readCount: () => reads,
    load: async () => (await service.loadActivityEvidence(root, 100, () => false)).find(file => file.path === 'game/logs/latest.log') };
}

test('已封账原件首次真实hash，完全稳定的第二次详情不读正文；同大小改写拒绝旧cache', async () => {
  const f = fixture();
  try {
    assert.equal((await f.load()).verification, 'verified'); const first = f.readCount(); assert.ok(first > 0);
    assert.equal((await f.load()).verification, 'verified'); assert.equal(f.readCount(), first);
    fs.writeFileSync(f.path, 'X' + f.body.slice(1));
    const changed = await f.load(); assert.equal(changed.verification, 'unverified'); assert.equal(changed.state, 'partial');
    assert.ok(f.readCount() > first);
  } finally { f.runtime.close(); }
});

test('无纳秒精度、运行中和partial文件每次真实hash，不复用封账高精度cache', async () => {
  for (const mode of ['low-precision', 'running', 'partial']) {
    const f = fixture();
    try {
      await f.load();
      if (mode === 'low-precision') for (const key of ['stat', 'lstat']) {
        const original = f.runtime.kitFs[key];
        f.runtime.kitFs[key] = async p => { const stat = await original(p); delete stat.mtimeNs; delete stat.ctimeNs; return stat; };
      }
      if (mode === 'running') f.runtime.write('logs/ledger/100/manifest.json', JSON.stringify({ activityId: 100, category: 'launch', state: 0 }));
      if (mode === 'partial') {
        f.plan.sources[0].state = 'partial'; f.plan.sources[0].reason = 'explicit partial';
        f.runtime.write('logs/ledger/100/capture-sources.json', JSON.stringify(f.plan));
      }
      const before = f.readCount(); await f.load(); const after = f.readCount(); await f.load();
      assert.ok(after > before, mode); assert.ok(f.readCount() > after, mode);
    } finally { f.runtime.close(); }
  }
});

test('命中候选后路径原位改写仍被打开后复核拒绝，文件消失不保留verified', async () => {
  const f = fixture();
  try {
    await f.load(); const lstat = f.runtime.kitFs.lstat; let changed = false;
    f.runtime.kitFs.lstat = async p => {
      const value = await lstat(p);
      if (path.resolve(p) === path.resolve(f.path) && !changed) { changed = true; fs.writeFileSync(f.path, 'Y' + f.body.slice(1)); }
      return value;
    };
    assert.equal((await f.load()).verification, 'unverified');
    assert.equal(changed, true, '故障注入必须真实到达同一原件的lstat边界');
    fs.unlinkSync(f.path); assert.equal((await f.load()).verification, 'unverified');
  } finally { f.runtime.close(); }
});
