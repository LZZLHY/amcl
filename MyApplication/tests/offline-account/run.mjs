/**
 * 离线账号生产代码回归。
 *
 * 转译并执行真实 Account/OfflineAccount/AccountStorage/AccountManager，只替换宿主没有
 * 的 Preferences、HUKS、日志和共享库 IO 边界。测试覆盖跨账号共享、名称唯一、持久
 * 失败回滚、旧草稿冲突与提交中的引用保护；不会将手写的替代业务当作被测实现。
 * 输出只打印到 stdout，调用方把日志落到工作区 E 盘，不在工程内生成中间代码。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const argument = process.argv.indexOf('--typescript');
if (argument < 0 || !process.argv[argument + 1]) throw new Error('需要 --typescript <SDK TypeScript 包>');
const ts = require(path.resolve(process.argv[argument + 1]));
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const source = path.join(root, 'account/src/main/ets');
const cache = new Map();
let gameProcess = false;
let currentStore;
let usageGuard;
const assets = [];
const logger = { info() {}, warn() {}, error() {}, debug() {} };

/** 偏好存储替身只提供磁盘边界：真实提交/回滚顺序仍由生产 AccountStorage 执行。 */
class Preferences {
  values = new Map();
  fail = false;
  hold;
  getSync(key, fallback) { return this.values.has(key) ? this.values.get(key) : fallback; }
  putSync(key, value) { if (gameProcess) throw new Error('read-only'); this.values.set(key, value); }
  deleteSync(key) { if (gameProcess) throw new Error('read-only'); this.values.delete(key); }
  async flush() {
    if (this.hold) { const hold = this.hold; this.hold = undefined; await hold; }
    if (this.fail) { this.fail = false; throw new Error('injected flush failure'); }
  }
}

/** 注入当前库清单及删除保护回调，测试账号引用而不重复实现 PNG/文件导入。 */
const library = { init: async () => {}, list: kind => assets.filter(asset => asset.kind === kind),
  setUsageGuard: guard => { usageGuard = guard; } };
const plainCrypto = class {
  async encrypt(value) { return { iv: 'iv', tag: 'tag', ciphertext: value }; }
  async decrypt(blob) { return blob.ciphertext; }
};
const imports = {
  commons: { AppLogger: logger, LOG_DOMAIN_ACCOUNT: 0,
    ProcessPreferences: { open: () => currentStore, isGameProcess: () => gameProcess } },
  './CryptoProvider': { PlaintextCryptoProvider: plainCrypto },
  './HuksCryptoProvider': { HuksAesGcm256Provider: class { async isAvailable() { return false; } } },
  './AppearanceLibrary': { getAppearanceLibrary: () => library },
  './MicrosoftAccount': { MicrosoftAccount: class { static fromRecord() { return null; } } },
  './AuthlibInjectorAccount': { AuthlibInjectorAccount: class { static fromRecord() { return null; } } },
};

/** 编译后的模块加载器保持真实模块之间的调用，仅显式替换上方已声明的环境边界。 */
function load(name) {
  if (cache.has(name)) return cache.get(name);
  const text = fs.readFileSync(path.join(source, name + '.ets'), 'utf8');
  const compiled = ts.transpileModule(text, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020,
  } });
  const result = {};
  cache.set(name, result);
  new Function('exports', 'require', compiled.outputText)(result, id => {
    if (id in imports) return imports[id];
    if (id.startsWith('./')) return load(id.slice(2));
    throw new Error('未声明的环境依赖: ' + id);
  });
  return result;
}

const types = load('AppearanceTypes');
const { AccountType } = load('Account');
const { OfflineAccount } = load('OfflineAccount');
const { AccountManager } = load('AccountManager');
let checks = 0;
async function check(name, operation) { await operation(); checks++; process.stdout.write('PASS ' + name + '\n'); }
function asset(id, kind = 'skin', height = kind === 'skin' ? 64 : 32) {
  const digest = id.repeat(64).slice(0, 64);
  return { id: kind + '-' + digest, kind, name: '纹理 ' + id, sha256: digest,
    relativePath: 'account-textures/' + digest + '.png', width: 64, height, createdAt: 1 };
}
const a = asset('a'), b = asset('b'), cape = asset('c', 'cape');
assets.push(a, b, cape);
let manager;
async function start(store = new Preferences()) {
  currentStore = store;
  manager = new AccountManager();
  await manager.init({});
  return manager;
}

await check('旧版记录恢复身份，默认不产生皮肤/披风来源', () => {
  const original = OfflineAccount.create('玩家甲');
  const record = original.serialize();
  delete record.offlineAppearance;
  record.version = 1;
  const restored = OfflineAccount.fromRecord(record);
  assert.equal(restored.id, original.id);
  assert.equal(restored.uuid, original.uuid);
  assert.equal(restored.getSkinUrl(), null);
  assert.equal(restored.getCapeUrl(), null);
});
await check('两个不同账号共享同一库资产但模型和选择互不污染', () => {
  const first = OfflineAccount.create('甲').withAppearance({ revision: 1, skin: a, model: 'SLIM' });
  const second = OfflineAccount.create('乙').withAppearance({ revision: 1, skin: a, model: 'CLASSIC' });
  const draft = first.getOfflineAppearance();
  draft.skin.name = '草稿中的改名';
  draft.model = 'CLASSIC';
  assert.equal(first.getSkinVariant(), 'SLIM');
  assert.equal(second.getSkinVariant(), 'CLASSIC');
  assert.equal(second.getOfflineAppearance().skin.name, a.name);
  assert.equal(first.getSkinUrl(), 'amcl-texture:' + a.relativePath);
  assert.notEqual(first.uuid, second.uuid);
});
await check('改名保留ID/UUID与完整外观，序列化往返不丢本地配置', () => {
  const original = OfflineAccount.create('旧名字').withAppearance({ revision: 7, skin: a, cape, model: 'SLIM' });
  const renamed = original.withUsername(' 新名字 ');
  assert.equal(renamed.username, '新名字');
  for (const field of ['id', 'uuid', 'createdAt']) assert.equal(renamed[field], original[field]);
  assert.deepEqual(OfflineAccount.fromRecord(renamed.serialize()).getOfflineAppearance(), original.getOfflineAppearance());
});
await check('坏皮肤引用单独回退，有效披风仍可独立启动；旧版皮肤固定Classic', () => {
  const corrupt = { ...a, relativePath: '../secret.png' };
  const result = types.copyOfflineAppearance({ revision: 1, skin: corrupt, cape, model: 'SLIM' });
  assert.equal(result.skin, undefined);
  assert.equal(result.cape.id, cape.id);
  assert.equal(types.copyOfflineAppearance({ revision: 1, skin: asset('d', 'skin', 32), model: 'SLIM' }).model, 'CLASSIC');
});
await check('离线名称去空格且不分大小写唯一，不影响不同名称账号', async () => {
  await start();
  const first = OfflineAccount.create('Player');
  await manager.add(first);
  await manager.add(OfflineAccount.create('Other'));
  await assert.rejects(manager.add(OfflineAccount.create(' player ')), error => error.code === 'DUPLICATE_NAME');
  assert.equal(manager.list().length, 2);
  assert.equal(JSON.parse(currentStore.getSync('accounts_list', '')).length, 2);
});
await check('名称与外观统一提交，重名/非法输入不改变原记录', async () => {
  const first = manager.list()[0], second = manager.list()[1];
  await assert.rejects(manager.editOfflineAccount(first.id, second.username, first.getOfflineAppearance()), /已存在/);
  await assert.rejects(manager.editOfflineAccount(first.id, '', first.getOfflineAppearance()), /有效/);
  const invalid = { revision: 0, model: 'CLASSIC', skin: { ...a, relativePath: '/outside.png' } };
  await assert.rejects(manager.editOfflineAccount(first.id, '新名', invalid), /无效/);
  assert.equal(manager.findById(first.id), first);
});
await check('持久失败恢复原缓存、列表与账号实例，不显示部分改名/换肤结果', async () => {
  const original = manager.list()[0];
  const before = new Map(currentStore.values);
  currentStore.fail = true;
  await assert.rejects(manager.editOfflineAccount(original.id, 'Changed', { revision: 0, skin: a, cape, model: 'SLIM' }), /保存失败/);
  assert.equal(manager.findById(original.id), original);
  assert.deepEqual(currentStore.values, before);
});
await check('成功编辑后可重新加载，稳定身份及两个账号独立选择均保持', async () => {
  const first = manager.list()[0], second = manager.list()[1];
  const edited = await manager.editOfflineAccount(first.id, 'Renamed', { revision: 0, skin: a, cape, model: 'SLIM' });
  await manager.updateOfflineAppearance(second.id, { revision: 0, skin: a, model: 'CLASSIC' });
  assert.equal(edited.id, first.id);
  assert.equal(edited.uuid, first.uuid);
  assert.equal(edited.getOfflineAppearance().revision, 1);
  const store = currentStore;
  await start(store);
  assert.equal(manager.findById(first.id).getSkinVariant(), 'SLIM');
  assert.equal(manager.findById(second.id).getSkinVariant(), 'CLASSIC');
  assert.equal(manager.findById(first.id).getCapeUrl(), 'amcl-texture:' + cape.relativePath);
});
await check('旧草稿及旧实例不能覆盖已提交的新外观', async () => {
  const original = manager.list()[0];
  const draft = original.getOfflineAppearance();
  await manager.renameOffline(original.id, 'SecondName');
  await assert.rejects(manager.updateOfflineAppearance(original.id, draft), error => error.code === 'ACCOUNT_CHANGED');
  await assert.rejects(manager.persistOne(original), error => error.code === 'ACCOUNT_CHANGED');
});
await check('提交期间新资产先被保护，删除库检查不会遗漏等待flush的选择', async () => {
  const original = manager.list()[0];
  let release;
  currentStore.hold = new Promise(resolve => { release = resolve; });
  const pending = manager.updateOfflineAppearance(original.id, { ...original.getOfflineAppearance(), skin: b });
  for (let index = 0; index < 12; index++) await Promise.resolve();
  assert.equal(usageGuard(b.id), true);
  assert.notEqual(manager.findById(original.id).getOfflineAppearance().skin.id, b.id);
  release(); await pending;
  assert.equal(manager.isAppearanceAssetUsed(b.id), true);
});
await check('添加失败不产生新账号或孤立索引；写入队列可继续重试', async () => {
  const count = manager.list().length;
  currentStore.fail = true;
  await assert.rejects(manager.add(OfflineAccount.create('Failure')), /保存失败/);
  assert.equal(manager.list().length, count);
  await manager.add(OfflineAccount.create('Success'));
  assert.equal(manager.list().length, count + 1);
});
await check('从共享库删除后的旧草稿不能重新应用失效引用', async () => {
  const original = manager.list()[0];
  const missing = asset('e');
  await assert.rejects(manager.updateOfflineAppearance(original.id, {
    revision: original.getOfflineAppearance().revision, skin: missing, model: 'CLASSIC',
  }), /共享库移除/);
});
await check('旧重复名称记录保留各自UUID，不自动合并或破坏已有存档', async () => {
  const store = new Preferences();
  const first = OfflineAccount.create('Old');
  const second = OfflineAccount.fromRecord({ ...OfflineAccount.create('Old').serialize(), uuid: '11111111-1111-4111-8111-111111111111' });
  store.values.set('accounts_list', JSON.stringify([first.id, second.id]));
  for (const account of [first, second]) store.values.set('account_' + account.id, JSON.stringify(account.serialize()));
  await start(store);
  assert.equal(manager.list().length, 2);
  assert.notEqual(manager.list()[0].uuid, manager.list()[1].uuid);
  const edited = await manager.updateOfflineAppearance(second.id, { revision: 0, skin: a, model: 'CLASSIC' });
  assert.equal(edited.uuid, second.uuid, '未改名的历史重复账号仍可独立换肤');
});

await check('新增等待flush时删除旧账号，统一队列阻止记录与索引复活', async () => {
  await start();
  const first = OfflineAccount.create('First'), second = OfflineAccount.create('Second');
  await manager.add(first);
  let release;
  currentStore.hold = new Promise(resolve => { release = resolve; });
  const adding = manager.add(second);
  for (let index = 0; index < 12; index++) await Promise.resolve();
  const removing = manager.remove(first.id);
  assert.equal(manager.findById(first.id), first, '删除在确认前不提前改变内存');
  release(); await Promise.all([adding, removing]);
  assert.deepEqual(manager.list().map(account => account.id), [second.id]);
  assert.deepEqual(JSON.parse(currentStore.getSync('accounts_list', '')), [second.id]);
  assert.equal(currentStore.values.has('account_' + first.id), false);
  const savedStore = currentStore;
  await start(savedStore);
  assert.deepEqual(manager.list().map(account => account.id), [second.id], '进程重载仍没有被删除账号');
});

await check('删除失败精确恢复记录/索引/选中态，排队的新选择随后正常确认', async () => {
  const first = manager.list()[0], next = OfflineAccount.create('Next');
  await manager.add(next);
  await manager.select(first.id);
  const before = new Map(currentStore.values);
  currentStore.fail = true;
  await assert.rejects(manager.remove(first.id), /保存失败/);
  assert.equal(manager.findById(first.id), first);
  assert.equal(manager.getSelectedId(), first.id);
  assert.deepEqual(currentStore.values, before);
  let release;
  currentStore.hold = new Promise(resolve => { release = resolve; });
  const removing = manager.remove(first.id);
  for (let index = 0; index < 12; index++) await Promise.resolve();
  const selecting = manager.select(next.id);
  release(); await Promise.all([removing, selecting]);
  assert.equal(manager.getSelectedId(), next.id);
  assert.equal(currentStore.getSync('selected_account_id', ''), next.id);
});

process.stdout.write(JSON.stringify({ status: 'PASS', checks, source: 'production ETS', boundary: 'host SDK/preferences only' }) + '\n');
