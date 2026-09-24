/** 执行生产 ArkTS wire 解码与恢复提示；不初始化设备、游戏或文件存储。 */
import assert from 'node:assert/strict';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
const { parseGraphicsLaunchFailure: parse, graphicsLaunchFailureMessage: message } =
  makePureEtsLoader()('entry/src/main/ets/runtime/GraphicsLaunchFailure.ets');
const valid = { schemaVersion: 1, returnCode: -5, stage: 'admission', code: 'vulkan_capability_rejected',
  profile: 'minecraft-vulkan', restartRequired: true };
const decoded = parse(JSON.stringify(valid), -5);
assert.equal(decoded.profile, 'minecraft-vulkan');
assert.equal(decoded.restartRequired, true);
assert.match(message('设备能力不足', decoded), /^设备能力不足\n请返回启动器/);
for (const wire of ['', '{}', 'null', '[]', 'broken', 'x'.repeat(4097)]) assert.equal(parse(wire, -5), undefined);
for (const change of [{ schemaVersion: 2 }, { returnCode: -7 }, { stage: 'future' }, { code: '' },
  { profile: 7 }, { restartRequired: 'true' }, { code: 'x'.repeat(257) }]) {
  assert.equal(parse(JSON.stringify({ ...valid, ...change }), -5), undefined);
}
assert.equal(parse(JSON.stringify(valid), 0), undefined);
assert.equal(message('原始错误', undefined), '原始错误');
assert.match(message('参数冲突', parse(JSON.stringify({ ...valid, stage: 'plan', restartRequired: false }), -5)), /检查图形后端设置/);
// bootstrap 错误必须直指参数或运行库；不能把所有后端共用的故障引导成更换图形后端。
for (const restartRequired of [true, false]) {
  const parameter = parse(JSON.stringify({ ...valid, stage: 'bootstrap', code: 'runtime_property_conflict', restartRequired }), -5);
  const status = '运行库启动契约冲突: runtime_property_conflict:jna.tmpdir';
  const text = message(status, parameter);
  assert.ok(text.startsWith(status + '\n'), '保留原始 native 诊断');
  assert.match(text, /JNA 临时目录参数/);
  assert.match(text, /全局及此版本/);
  assert.match(text, /移除 jna.tmpdir/);
  assert.doesNotMatch(text, /更换图形后端|检查图形后端设置/);
  assert.equal(text.includes('请返回启动器后重新启动游戏'), restartRequired);
}
const bootstrap = { ...valid, stage: 'bootstrap', code: 'runtime_property_conflict' };
assert.match(message('runtime_property_conflict:org.lwjgl.opengl.libname', parse(JSON.stringify(bootstrap), -5)), /运行库配置冲突/);
assert.match(message('runtime_path_override:java.library.path', parse(JSON.stringify(bootstrap), -5)), /移除冲突项/);
assert.match(message('runtime_invocation_hook_override', parse(JSON.stringify(bootstrap), -5)), /exit、abort 或 vfprintf/);
assert.match(message('参数冲突', parse(JSON.stringify({ ...bootstrap, code: 'runtime_property_conflict:jna.tmpdir' }), -5)), /JNA 临时目录参数/);
for (const stage of ['bootstrap', 'artifacts', 'runtime']) {
  const jna = parse(JSON.stringify({ ...valid, stage, code: 'jna_native_version_mismatch' }), -5);
  assert.match(message('JNA 版本不匹配', jna), /JNA Java 依赖与原生运行库/);
  assert.doesNotMatch(message('JNA 版本不匹配', jna), /更换图形后端/);
}
const missingJna = parse(JSON.stringify({ ...valid, stage: 'bootstrap', code: 'jna_runtime_artifact_missing' }), -5);
assert.match(message('缺少 JNA 原生库', missingJna), /缺少当前游戏需要的 JNA 原生运行库/);
assert.match(message('缺少 JNA 原生库', missingJna), /完整的启动器安装包/);
assert.doesNotMatch(message('缺少 JNA 原生库', missingJna), /更换图形后端/);
// 不能只凭任意状态文本中的词语改分类，结构化阶段仍是恢复建议的依据。
assert.match(message('jna.tmpdir', decoded), /更换图形后端/);
console.log('PASS graphics failure: native return-code binding, invalid wire, stage-specific parameter/JNA guidance, restart boundary');
