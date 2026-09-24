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
console.log('PASS graphics failure: native return-code binding, invalid wire, recovery guidance');
