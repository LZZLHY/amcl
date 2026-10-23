/**
 * U02 回归：执行真实 Coordinator/Repository/Vault/候选解析及原件散列，验证本轮选择、
 * 已下载事务、签名 job 与安装执行身份持续绑定。JVM、账号及 HDC/Executor 为既有平台替身，
 * 本文件不会实际重签 HAP、覆盖安装或证明 2in1 真机产品切换。输出由 AMCL_TEST_OUTPUT_DIR 外置。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { fixture as createFixture, record, settle, deferred, target, manifest } from './lib/sideload-coordinator-fixture.mjs';

const rows = [];
const bytes = Buffer.from('unsigned candidate fixture');
const clone = value => JSON.parse(JSON.stringify(value));
/** 只旁听真实 Fence.arm 的输入，不替换 Guard、持久提交或执行器原有行为。 */
async function fixture(options) {
  const f = await createFixture(options);
  const { InstallFence } = f.load('entry/src/main/ets/sideload/InstallFence.ets');
  const arm = InstallFence.prototype.arm;
  InstallFence.prototype.arm = function(identity) { f.preparedIdentity = clone(identity); const result = arm.call(this, identity); f.afterArm?.(); return result; };
  return f;
}
/** 给真实 Repository 提供完整旧事务，所有后续转移与持久提交必须由生产方法完成。 */
function journal(phase = 'downloaded') {
  return { ...record(phase), asset: clone(target), beforeVersionCode: 1, beforeVersionName: '1.0.0',
    updateChannel: 'stable', sameVersionTest: false };
}
/** 只在平台沙箱写入既有原件，不赋 Coordinator 私有变量。 */
function seed(f, task, content = bytes) {
  fs.mkdirSync(path.dirname(f.mapped(task.unsignedPath)), { recursive: true });
  fs.writeFileSync(f.mapped(task.unsignedPath), content);
}
async function drain() { for (let index = 0; index < 12; index++) await settle(); }
/** 从实际固定路径读取签名器输入；断言签名 job 和安装执行身份都来自当前合法候选。 */
function assertSelected(f, requested = target) {
  const task = f.coordinator.state();
  assert.equal(task.asset.product, requested.product);
  for (const key of ['tag', 'versionCode', 'versionName', 'product', 'name', 'sha256', 'sizeBytes', 'url', 'websiteUrl', 'legacyUniversal'])
    assert.deepEqual(task.asset[key], requested[key], '事务目标字段 ' + key);
  const job = JSON.parse(f.kitfs.readTextSync(path.posix.dirname(task.unsignedPath) + '/job.json'));
  for (const key of ['product', 'versionCode', 'versionName', 'sha256']) assert.deepEqual(job[key], requested[key], '签名输入 ' + key);
  const fence = JSON.parse(f.kitfs.readTextSync('/sandbox/sideload-update/install-fence.json'));
  // Fence 只持有执行权标识；产品/编号取实际传入 prepare→arm 的执行身份独立核实。
  assert.equal(f.preparedIdentity.product, requested.product); assert.equal(f.preparedIdentity.versionCode, requested.versionCode);
  assert.equal(fence.ownerAttemptId, task.ownerAttemptId); assert.equal(fence.installId, task.installId);
  return task;
}
function observe(name, f, extra = {}) {
  rows.push({ name, phase: f.coordinator.state()?.phase, counters: { ...f.counters }, ...extra });
  console.log('cache-identity: ' + name);
}

// 三种可继续阶段均保留正常原件复用；Ready 若缺有效材料证明仍正常重签，不能强行沿用旧签名。
for (const phase of ['downloaded', 'awaiting-restart', 'ready']) {
  const old = journal(phase), f = await fixture({ journal: old }); seed(f, old);
  const view = f.render(); await drain();
  assert.equal(f.counters.download, 0); assert.equal(f.counters.sign, 1); assert.equal(f.counters.dispatch, 1);
  assert.equal(assertSelected(f).id, old.id); observe('same target cold ' + phase, f); view.dispose();
}

// 从真实签名形成 Ready：热恢复复用有效签名；冷启动沿用既有保守重签规则，两者均复用原件。
{
  const first = await fixture({ delaySign: true }), originView = first.render(); await drain();
  originView.onBackground(); first.signGate.resolve(); await drain();
  const ready = first.coordinator.state(); assert.equal(ready.phase, 'ready');
  originView.onForeground(); await drain();
  assert.equal(first.counters.download, 1); assert.equal(first.counters.sign, 1); assert.equal(first.counters.dispatch, 1);
  assertSelected(first); observe('genuine hot Ready retains fresh signature', first);
  const signed = fs.readFileSync(first.mapped(ready.signedPath));
  const cold = await fixture({ journal: ready }); seed(cold, ready);
  fs.writeFileSync(cold.mapped(ready.signedPath), signed);
  const view = cold.render(); await drain();
  assert.equal(cold.counters.download, 0); assert.equal(cold.counters.sign, 1); assert.equal(cold.counters.dispatch, 1);
  const current = cold.coordinator.state(); assert.equal(current.id, ready.id);
  assert.equal(cold.preparedIdentity.product, target.product); assert.equal(cold.preparedIdentity.versionCode, target.versionCode);
  assert.notEqual(current.installId, ready.installId);
  observe('genuine cold Ready reuses original and re-signs', cold); originView.dispose(); view.dispose();
}

// 每项只改变旧目标一个身份维度；同 tag/code 的旧产品与旧摘要也必须建立当前候选的新事务。
const mutations = {
  product: value => { value.product = 'desktop'; value.name = 'amcl-v2.0.0-desktop-unsigned.hap';
    value.url = 'https://github.com/LZZLHY/amcl/releases/download/v2.0.0/' + value.name;
    value.websiteUrl = 'https://amcl.lovedhy.cn/api/packages/files/' + value.sha256 + '/' + value.name; },
  sha256: value => { value.sha256 = 'a'.repeat(64); },
  name: value => { value.name = 'amcl-v2.0.0-unsigned.hap'; },
  sizeBytes: value => { value.sizeBytes++; },
  versionName: value => { value.versionName = '1.9.0'; },
  url: value => { value.url = 'https://github.com/other/repo/releases/download/v2.0.0/' + value.name; },
  websiteUrl: value => { value.websiteUrl = 'https://example.invalid/unsigned.hap'; },
  legacyUniversal: value => { value.legacyUniversal = true; }
};
for (const [field, mutate] of Object.entries(mutations)) {
  const old = journal(); mutate(old.asset); const f = await fixture({ journal: old }); seed(f, old);
  const view = f.render(); await drain();
  assert.equal(f.counters.download, 1, field + ' 改变不能复用旧目标'); assert.equal(f.counters.sign, 1); assert.equal(f.counters.dispatch, 1);
  assert.notEqual(assertSelected(f).id, old.id, field + ' 改变应分配新缓存事务');
  observe('reject stale ' + field, f); view.dispose();
}

// 已安装基线各字段不同亦不能沿用旧缓存/旧签名；真实 bundle 边界仍返回当前 1.0.0 / 1 / UID42。
for (const [field, value] of [['beforeVersionCode', 0], ['beforeVersionName', '0.9.0'], ['beforeUid', 43]]) {
  const old = journal(); old[field] = value; const f = await fixture({ journal: old }); seed(f, old);
  const view = f.render(); await drain(); assert.equal(f.counters.download, 1); assert.equal(f.counters.dispatch, 1);
  const task = assertSelected(f); assert.notEqual(task.id, old.id); assert.equal(task.beforeVersionCode, 1);
  assert.equal(task.beforeVersionName, '1.0.0'); assert.equal(task.beforeUid, 42);
  observe('reject stale baseline ' + field, f); view.dispose();
}

// 同资产在不同订阅中也必须重建事务，不把旧稳定许可变成预览许可。
{
  const old = journal(), candidate = clone(manifest); candidate.updateChannel = 'preview'; candidate.prerelease = false;
  const f = await fixture({ journal: old, candidate }); seed(f, old); const view = f.render(); await drain();
  assert.equal(f.counters.download, 1); assert.equal(f.counters.dispatch, 1); assert.notEqual(assertSelected(f).id, old.id);
  assert.equal(f.coordinator.state().updateChannel, 'preview'); observe('channel switch creates current transaction', f); view.dispose();
}

// 当前已经装到候选版本时，旧 beforeVersionCode 不得授予重复升级或同发行覆盖资格。
{
  const old = journal(), f = await fixture({ journal: old }); seed(f, old);
  f.environment.version = target.versionCode; f.environment.versionName = target.versionName;
  const view = f.render(); await drain(); assert.equal(f.counters.sign, 0); assert.equal(f.counters.dispatch, 0);
  assert.equal(f.counters.download, 0); observe('already installed candidate rejects old baseline', f); view.dispose();
}

// 同身份的文件损坏或尺寸变化不得绕过真实摘要；内层可保留同一事务目录并重新下载正确字节。
for (const content of [Buffer.from('x'.repeat(bytes.length)), Buffer.concat([bytes, Buffer.from('x')])]) {
  const old = journal(), f = await fixture({ journal: old }); seed(f, old, content);
  const view = f.render(); await drain(); assert.equal(f.counters.download, 1); assert.equal(f.counters.dispatch, 1);
  assertSelected(f); observe('invalid cached original ' + content.length, f); view.dispose();
}

// 当前候选的新摘要若没有对应字节，下载校验必须失败，绝不能回退使用旧原件生成旧 job。
{
  const old = journal(), changed = clone(manifest); changed.updateChannel = 'stable';
  changed.delivery.assets[0].sha256 = 'a'.repeat(64);
  changed.delivery.assets[0].websiteUrl = 'https://amcl.lovedhy.cn/api/packages/files/' + 'a'.repeat(64) + '/' + target.name;
  const f = await fixture({ journal: old, candidate: changed }); seed(f, old);
  const view = f.render(); await drain(); assert.equal(f.counters.download > 0, true);
  assert.equal(f.counters.sign, 0); assert.equal(f.counters.dispatch, 0); assert.equal(f.coordinator.state().phase, 'failed');
  observe('new hash never signs old bytes', f); view.dispose();
}

// 镜像运输健康与内容身份独立：候选的合法镜像定位变更不会强制相同原件重新下载。
{
  const old = journal(), changed = clone(manifest);
  changed.delivery.assets[0].mirrors = [{ provider: 'fyhub', projectId: 'amcl', ready: true, assetId: 'fixture-new-mirror' }];
  const f = await fixture({ journal: old, candidate: changed }); seed(f, old); const view = f.render(); await drain();
  assert.equal(f.counters.download, 0); assert.equal(f.counters.dispatch, 1); assertSelected(f);
  observe('transport mirror differs same original reused', f); view.dispose();
}

// 手动导入从真实预检取得内部令牌和精确官网收据，旧 desktop 事务不能替代 sideload 本地原件。
{
  const old = journal(); mutations.product(old.asset); const f = await fixture({ journal: old }); seed(f, old);
  fs.writeFileSync(f.mapped('/sandbox/picked.hap'), bytes);
  const prepared = await f.coordinator.preparePickedPackage('/sandbox/picked.hap', 'stable');
  const { SideloadUpdateViewModel: ViewModel } = f.load('entry/src/main/ets/sideload/SideloadUpdateViewModel.ets');
  const view = new ViewModel(); view.initialize(f.context, { manifest: prepared.manifest, importToken: prepared.token, autoStart: true });
  f.coordinator.setAbilityForeground(true); view.onForeground(); view.onShown(); await drain();
  assert.equal(f.counters.download, 0, '本地原件通过正常队列有界复制，无需远程下载');
  assert.equal(f.counters.sign, 1); assert.equal(f.counters.dispatch, 1); assert.notEqual(assertSelected(f).id, old.id);
  observe('manual import binds selected product', f); view.dispose();
}

// 用户输入清单在授权等待期间被外部改写，不得改变冻结副本或派发产品。
{
  const candidate = clone(manifest), f = await fixture({ candidate, account: 'missing' }), view = f.render(); await drain();
  candidate.delivery.assets[0].product = 'desktop'; candidate.delivery.assets[0].sha256 = 'a'.repeat(64);
  candidate.versionName = '9.9.9'; candidate.updateChannel = 'preview'; f.authorize(); await drain();
  assert.equal(f.counters.sign, 1); assert.equal(f.counters.dispatch, 1); assertSelected(f);
  observe('caller manifest mutation cannot retarget', f); view.dispose();
}

// Runtime 换代依旧只保留同一 Attempt 的冻结目标。旧异步结果收敛后重新签名，不重下载原件。
{
  const old = journal(), f = await fixture({ journal: old, account: 'missing' }); seed(f, old);
  const first = f.render(); await drain(); const attempt = f.coordinator.snapshot().attemptId;
  const next = { ...f.context }; f.storage.set('uiAbilityContext', next); f.coordinator.bindRuntime(next);
  const { SideloadUpdateViewModel: ViewModel } = f.load('entry/src/main/ets/sideload/SideloadUpdateViewModel.ets');
  const view = new ViewModel(); view.initialize(next, { manifest, autoStart: false });
  f.coordinator.setAbilityForeground(true); view.onForeground(); view.onShown(); await drain(); f.authorize(); await drain();
  assert.equal(f.coordinator.snapshot().attemptId, attempt); assert.equal(f.counters.download, 0);
  assert.equal(f.counters.sign, 1); assert.equal(f.counters.dispatch, 1); assertSelected(f);
  observe('runtime rebind retains frozen target', f); first.dispose(); view.dispose();
}

// 候选尚在解析/原件散列时 Runtime 换代：新 epoch 重做只读核验并继续原 Attempt；
// 迟到的旧结果不得接管 Owner、二次签名或派发。只延迟真实边界，不赋 Coordinator 私有状态。
for (const boundary of ['resolve', 'hash']) {
  const old = journal(), f = await fixture({ journal: old }); seed(f, old);
  const gate = deferred(); let held = false;
  if (boundary === 'hash') {
    const { SideloadFiles } = f.load('entry/src/main/ets/sideload/SideloadFiles.ets');
    const hash = SideloadFiles.sha256;
    SideloadFiles.sha256 = async function(file) {
      if (file === old.unsignedPath && !held) { held = true; await gate.promise; }
      return hash.call(this, file);
    };
  } else {
    const { GitHubUpdateAssetResolver } = f.load('update/src/main/ets/GitHubUpdateAssetResolver.ets');
    const resolve = GitHubUpdateAssetResolver.resolve;
    GitHubUpdateAssetResolver.resolve = async function(...args) {
      if (!held) { held = true; await gate.promise; }
      return resolve.apply(this, args);
    };
  }
  const first = f.render(); await drain(); assert.equal(held, true); const attempt = f.coordinator.snapshot().attemptId;
  const next = { ...f.context }; f.storage.set('uiAbilityContext', next); f.coordinator.bindRuntime(next);
  const { SideloadUpdateViewModel: ViewModel } = f.load('entry/src/main/ets/sideload/SideloadUpdateViewModel.ets');
  const view = new ViewModel(); view.initialize(next, { manifest, autoStart: false });
  f.coordinator.setAbilityForeground(true); view.onForeground(); view.onShown(); await drain();
  assert.equal(f.coordinator.snapshot().attemptId, attempt); assert.equal(f.counters.download, 0);
  assert.equal(f.counters.sign, 1); assert.equal(f.counters.dispatch, 1); assertSelected(f);
  const committed = clone(f.coordinator.state()); gate.resolve(); await drain();
  assert.deepEqual(clone(f.coordinator.state()), committed, '旧 ' + boundary + ' 返回不得写入新 Runtime 事务');
  assert.equal(f.counters.sign, 1); assert.equal(f.counters.dispatch, 1);
  observe('runtime rebind during pending target ' + boundary, f); first.dispose(); view.dispose();
}

// 签名异步期间实际安装基线变化：旧 Java 结果只能失败收尾，不能提交 Ready 或派发安装。
{
  const f = await fixture({ delaySign: true }), view = f.render(); await drain();
  assert.equal(f.counters.sign, 1); f.environment.uid = 43; f.signGate.resolve(); await drain();
  assert.equal(f.counters.dispatch, 0); assert.equal(f.coordinator.state().phase, 'failed');
  assert.equal(f.kitfs.accessSync('/sandbox/sideload-update/install-fence.json'), false);
  observe('baseline changes during signing cannot dispatch', f); view.dispose();
}

// 真实 prepare 建立 fence 后基线变化：Guard 必须拒绝派发，unknown 平台终态保留原 fence/执行身份。
{
  const f = await fixture(); f.afterArm = () => { f.environment.uid = 43; };
  const view = f.render(); await drain();
  assert.equal(f.counters.prepare, 1); assert.equal(f.counters.dispatch, 0); assert.equal(f.counters.complete, 0);
  assert.equal(f.coordinator.state().phase, 'confirmation-pending');
  assert.equal(f.kitfs.accessSync('/sandbox/sideload-update/install-fence.json'), true);
  assert.equal(f.coordinator.state().installId, f.preparedIdentity.installId);
  observe('baseline changes after prepare keeps unknown fence', f); view.dispose();
}

// 原件可复用也不能越过游戏占用或已有未知 fence；两者都不得以换目标理由清除。
{
  const old = journal(), f = await fixture({ journal: old, child: 1 }); seed(f, old);
  const view = f.render(); await drain(); assert.equal(f.counters.sign, 0); assert.equal(f.counters.dispatch, 0);
  assert.equal(f.counters.download, 0); assert.equal(f.coordinator.state().ownerAttemptId, old.ownerAttemptId ?? old.id);
  observe('cached target respects game guard', f); view.dispose();
}
{
  const old = journal(), f = await fixture({ journal: old }); seed(f, old);
  const content = JSON.stringify({ schema: 1, installId: 'unknown', nonce: '', ownerAttemptId: '', protocol: 1, createdAt: Date.now() });
  fs.writeFileSync(f.mapped('/sandbox/sideload-update/install-fence.json'), content);
  const view = f.render(); await drain(); assert.equal(f.counters.sign, 0); assert.equal(f.counters.dispatch, 0);
  assert.equal(f.counters.download, 0); assert.equal(f.counters.complete, 0);
  assert.equal(f.kitfs.readTextSync('/sandbox/sideload-update/install-fence.json'), content);
  observe('unknown fence blocks new candidate unchanged', f); view.dispose();
}

// 安装执行权进入 pending 后，任何新产品/摘要都只能核实原执行权；不能清 fence 或开启第二次安装。
for (const phase of ['installing', 'confirmation-pending', 'dispatch-intent']) {
  const old = journal(phase); old.schema = 2; old.revision = 1; old.ownerAttemptId = 'e'.repeat(32);
  old.installId = 'a'.repeat(32); old.installProtocol = 2; old.createdAt = Date.now() - 2000; old.updatedAt = Date.now() - 1000;
  mutations.product(old.asset); const f = await fixture({ journal: old }); const before = f.coordinator.state();
  const view = f.render(); await drain();
  assert.equal(f.counters.download, 0); assert.equal(f.counters.sign, 0); assert.equal(f.counters.dispatch, 0);
  const after = f.coordinator.state();
  for (const key of ['id', 'ownerAttemptId', 'installId', 'asset', 'restartNonce']) assert.deepEqual(after[key], before[key]);
  assert.equal(f.counters.complete, 0); observe('pending execution unchanged ' + phase, f); view.dispose();
}

const result = { executedAt: new Date().toISOString(), scope: '真实 ArkTS 宿主业务回归；JVM/HDC/BMS 为平台替身，无真机安装',
  sourceSha256: crypto.createHash('sha256').update(fs.readFileSync(path.resolve(path.dirname(fileURLToPath(import.meta.url)),
    '../entry/src/main/ets/sideload/SideloadUpdateCoordinator.ets'))).digest('hex'), cases: rows };
if (process.env.AMCL_TEST_OUTPUT_DIR) fs.writeFileSync(path.join(process.env.AMCL_TEST_OUTPUT_DIR, 'cache-identity-results.json'), JSON.stringify(result, null, 2) + '\n');
console.log('cache-identity: ' + rows.length + ' scenarios passed');
