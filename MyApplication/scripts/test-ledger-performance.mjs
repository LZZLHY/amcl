/**
 * 启动/亮屏账本优化的生产实现组合门禁。
 * 只编排既有真实源码回归，SDK/文件/UI边界由各夹具明确适配；不在这里复制业务算法。
 * 宿主通过证明语义和工作量约束，不能替代HAP、实际线程或设备动画的验证。
 */
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const tests = [
  // 密码摘要边界按当前设备拒绝零字节update，确保空发布/空原件走真实空SHA-256完成路径。
  'test-evidence-empty-digest.mjs',
  // FileIO递归mkdir对已有目标仍报EEXIST；普通目录仅经lstat复用，独占临时目录保持碰撞保护。
  'test-evidence-directory.mjs',
  // 派生检查点不反馈事实清单；未变证据时间稳定，legacy原件和固定坏SHA不被覆盖/重签。
  'test-evidence-derived-boundary.mjs',
  'test-ledger-maintenance.mjs', 'test-ledger-async-capture.mjs', 'test-session-recovery-owner.mjs',
  'test-session-recovery-scheduling.mjs',
  'test-activity-list-projection.mjs', 'test-history-read-snapshot.mjs', 'test-marquee-lifecycle.mjs',
  'test-version-panel-mount.mjs', 'test-activity-pin-async.mjs', 'test-activity-storage-async.mjs',
  'test-log-retention-async.mjs', 'test-activity-delete-async.mjs', 'test-launcher-startup-ready.mjs',
  'test-launcher-idle-work.mjs',
  'test-ledger-stale-receipts.mjs', 'test-logshare-probe-async.mjs',
  'test-session-runtime-protection.mjs',
];
for (const test of tests) {
  const result = spawnSync(process.execPath, ['--test', path.join(root, 'scripts', test)], {
    cwd: root, encoding: 'utf8', stdio: 'inherit', env: process.env,
  });
  if (result.error || result.status !== 0) {
    if (result.error) console.error(result.error.message);
    process.exit(result.status || 1);
  }
}
console.log(`PASS ${tests.length} production ledger/recovery/UI suites; device validation remains separate`);
