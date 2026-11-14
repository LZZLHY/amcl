/**
 * 执行实际生成 ArkTS 与产物审核函数，证明同 code 发行不能借远程字段扩大宿主支持。
 * 本套零磁盘输出；修改单一输入构造反例，避免测试只镜像实现中的字符串判断。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { readRuntimeHostConfiguration, validateRuntimeHostConfiguration, assertRuntimeHostMirror,
  runtimeHostSource, releaseKindForVersion, validateRuntimeHostMetadata } from './runtime-host-contract.mjs';

const configuration = assertRuntimeHostMirror();
const requirements = {runtimeCatalogProtocol:configuration.runtimeCatalogProtocol,runtimeRequiredCapabilities:configuration.requiredRuntimeCapabilities,runtimeRequiredMajors:configuration.requiredRuntimeMajors};
// 已整合协议2实现；断言真实源码集合，同时继续拒绝未声明的新协议。
assert.deepEqual(configuration.supportedProtocols, [1, 2]);
const compiled = makePureEtsLoader()('launch/src/main/ets/RuntimeHostCapabilities.ets').RuntimeHostCapabilities;
assert.deepEqual([...compiled.supportedProtocols()], configuration.supportedProtocols);
assert.equal(compiled.planProtocol(), configuration.runtimePlanProtocol);
assert.equal(compiled.planProtocol(), 2, '新恢复读取能力不能继续冒用旧64KiB/无耐久交接的协议1');
assert.equal(compiled.catalogProtocol(),2,'目录读取能力必须由真实编译镜像明确声明');
// 固定Native ABI与恢复reader都仍为2，只降低目录reader，真实解析器必须拒绝v2。
// 该负控证明三个协议各自约束实际消费者，而不只是元数据字段的互相比对。
const reader1=makePureEtsLoader({}, {'launch/src/main/ets/RuntimeHostCapabilities.ets':runtimeHostSource({...configuration,runtimeCatalogProtocol:1})})
  ('launch/src/main/ets/RuntimeCatalogValidation.ets');
const shipping=fs.readFileSync(new URL('../entry/src/main/resources/rawfile/runtime-catalog/builtin.json',import.meta.url),'utf8');
assert.throws(()=>reader1.parseRuntimeCatalog(shipping,'stable'),/schemaVersion/);
const mutable = compiled.supportedProtocols(); mutable.push(99);
assert.deepEqual([...compiled.supportedProtocols()], [1, 2]);
assert.equal(runtimeHostSource(), runtimeHostSource(readRuntimeHostConfiguration()));
const validConfiguration = { schemaVersion: 1, supportedProtocols: [1], runtimePlanProtocol: 1 };
for (const value of [null, {}, { ...validConfiguration, schemaVersion: 2 }, { ...validConfiguration, supportedProtocols: [] },
  { ...validConfiguration, supportedProtocols: [1, 1] }, { ...validConfiguration, supportedProtocols: [2, 1] },
  { ...validConfiguration, supportedProtocols: [0] }, { ...validConfiguration, runtimePlanProtocol: 0 },
  { ...validConfiguration, remoteOverride: true }]) {
  assert.throws(() => validateRuntimeHostConfiguration(value), /Invalid/);
}
for (const [version, kind] of [['1.0.6', 'stable'], ['1.0.7-pre1', 'preview'], ['1.0.7-dev2', 'developer'], ['1.0.0-beta.4', 'preview']]) {
  assert.equal(releaseKindForVersion(version), kind);
  validateRuntimeHostMetadata({ ...requirements,runtimeHostProtocols: configuration.supportedProtocols, runtimePlanProtocol: configuration.runtimePlanProtocol, releaseKind: kind }, version, configuration);
}
for (const version of ['1.0', '1.0.7-dev0', '1.0.7-dev', '1.0.7-pre0', 'arbitrary']) assert.throws(() => releaseKindForVersion(version));
const validMetadata = { ...requirements,runtimeHostProtocols: configuration.supportedProtocols, runtimePlanProtocol: configuration.runtimePlanProtocol, releaseKind: 'stable' };
assert.throws(()=>validateRuntimeHostMetadata({...validMetadata,runtimeRequiredCapabilities:[]},'1.0.6',configuration),/requirements/);
assert.deepEqual([...compiled.requiredCapabilities()],requirements.runtimeRequiredCapabilities);
assert.deepEqual([...compiled.requiredMajors()],requirements.runtimeRequiredMajors);
for (const [metadata, reason] of [[{ ...validMetadata, runtimeHostProtocols: [1] }, /host protocols/],
  [{ ...validMetadata, releaseKind: 'preview' }, /release kind/], [{ ...validMetadata, runtimePlanProtocol: 0 }, /plan protocol/],
  [{ ...validMetadata, runtimePlanProtocol: 1 }, /plan protocol/],
  [{ ...validMetadata, runtimeCatalogProtocol: undefined }, /catalog protocol/],
  [{ ...validMetadata, runtimeCatalogProtocol: 1 }, /catalog protocol/],
  [{ ...validMetadata, runtimeHostProtocols: undefined }, /host protocols/], [{ ...validMetadata, releaseKind: undefined }, /release kind/]]) {
  assert.throws(() => validateRuntimeHostMetadata(metadata, '1.0.6', configuration), reason);
}
console.log('PASS runtime host: actual compiled capability, source/metadata parity and stable/preview/developer identity');
