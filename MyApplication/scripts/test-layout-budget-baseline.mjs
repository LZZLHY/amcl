/** 固定HEAD真实旧serializer与当前生产candidate比较，报告规范化/系统补齐/identity成本，不复制校验算法。 */
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
// 默认绑定本轮修复前实际旧生产提交；后来HEAD已修复时不能误把新编辑命令当旧serializer。
// 独立克隆可显式传入另一份已核实旧生产commit，缺少该历史对象时git给出明确读取失败。
const commit = execFileSync('git', ['rev-parse', process.argv[2] ?? 'f39fd0902f431e775d6db333da492a0199c25b6f'], { encoding: 'utf8' }).trim();
const files = ['gamecontrol/src/main/ets/LayoutStore.ets', 'gamecontrol/src/main/ets/ControlLayout.ets'];
const originals = Object.fromEntries(files.map(file => [file, execFileSync('git', ['show', commit + ':' + file], { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 })]));
function environment(overrides = {}) {
  const data = new Map();
  const preference = { get: async (key, fallback) => data.get(key) ?? fallback, getSync: (key, fallback) => data.get(key) ?? fallback,
    put: async (key, value) => data.set(key, value), putSync: (key, value) => data.set(key, value), flush: async () => {} };
  const commons = { AppLogger: { info() {}, warn() {}, error() {} }, ProcessPreferences: { isGameProcess: () => false, open: () => preference },
    OwnerLayoutSourceRepository: { open: () => null } };
  const deps = { commons, '@kit.AbilityKit': {}, '@kit.ArkTS': { util: { generateRandomUUID: randomUUID } }, '@kit.CoreFileKit': { fileIo: {} },
    '@kit.ArkUI': { display: { getDefaultDisplaySync: () => ({ width: 1280, height: 720, densityPixels: 1 }) } },
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {}, error() {} } }, '@kit.BasicServicesKit': { deviceInfo: {} } };
  const load = makePureEtsLoader(deps, overrides);
  Object.assign(commons, load('commons/src/main/ets/utils/PreferenceSnapshot.ets'));
  return { load, data, store: new (load(files[0]).LayoutStore)() };
}
const old = environment(originals), current = environment();
await old.store.init({});
assert.equal(await old.store.saveProfile({ name: 'a', globalScale: 1, controls: [], isPreset: false }), true);
const serialized = old.store.getActiveProfile();
const legacyBytes = Buffer.byteLength(JSON.stringify(serialized));
const normalized = current.store.normalizeWithInjections(serialized, 'minimal', { secondPassReverted: [] });
assert.ok(normalized); normalized.profileId = 'p_' + randomUUID().replaceAll('-', ''); normalized.profileRevision = 1;
const canonicalBytes = Buffer.byteLength(JSON.stringify(normalized));
const countBound = Math.floor((16 * 1024 * 1024 - 2) / (legacyBytes + 1));
const newUpperForRepeatedMinimum = 2 + countBound * (canonicalBytes + 256 + 1);
// 名称最多256 UTF-8 bytes，使用最短旧名称估算额外最坏姓名增长，避免只测默认布局误认为容量上界。
assert.ok(newUpperForRepeatedMinimum < 32 * 1024 * 1024);
console.log(JSON.stringify({ evidence: 'legacy-production-serializer-budget', sourceCommit: commit,
  sourceFiles: files, legacyMinimumBytes: legacyBytes, canonicalWithHotbarSystemAndIdentityBytes: canonicalBytes,
  repeatedMinimumCountAt16MiB: countBound, conservativeBytesWith256ByteNameAllowance: newUpperForRepeatedMinimum,
  legacyControls: serialized.controls.length, canonicalControls: normalized.controls.length,
  maxRssKiB: process.resourceUsage().maxRSS,
  limitation: '验证固定HEAD实际serializer输出的最小空草稿保存结果；不能证明更早版本/手工原始JSON的全部膨胀上界' }));
