/**
 * 执行生产弹窗几何策略，验证普通状态的固定外框与真实窗口变化的收缩边界。
 * 只验证数值与共享策略，不把宿主结果描述成 ArkUI 像素或真机无跳变证明。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import compiler from './lib/ets-compiler.mjs';

const source = fs.readFileSync(new URL('../entry/src/main/ets/components/UpdateDialogLayout.ets', import.meta.url), 'utf8');
const javascript = compiler.transpileModule(source, {
  compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 }
}).outputText;
const exports = {};
vm.runInNewContext(javascript, { exports, Number, Math });
const resolve = exports.resolveUpdateDialogLayout;

/** 同一可用窗口的所有业务状态必须复用固定数值，不用阶段或内容长度参与测量。 */
const expected = { width: 320, height: 464, compact: false };
for (const [width, height, top, bottom] of [[360, 780, 0, 0], [390, 844, 32, 24], [1280, 800, 40, 24]]) {
  assert.deepEqual(JSON.parse(JSON.stringify(resolve(width, height, top, bottom))), expected);
}

/** 窄屏、矮横屏和避让区变化只压缩可用空间，并启用内部紧凑排版。 */
assert.deepEqual(JSON.parse(JSON.stringify(resolve(320, 640, 24, 24))), { width: 280, height: 464, compact: true });
assert.deepEqual(JSON.parse(JSON.stringify(resolve(780, 360, 24, 16))), { width: 320, height: 280, compact: true });
assert.equal(resolve(360, 780, 200, 100).height, 440);
assert.equal(resolve(360, 780, -10, -10).height, 464);

/** 宿主首次尚未发布、无效数字及极端避让不把 NaN、负数或无穷传给布局。 */
for (const width of [0, -1, NaN, Infinity, 1, 320, 360, 10000]) {
  for (const height of [0, -1, NaN, Infinity, 1, 280, 780, 10000]) {
    const frame = resolve(width, height, NaN, -3);
    assert(Number.isFinite(frame.width) && frame.width > 0 && frame.width <= 320);
    assert(Number.isFinite(frame.height) && frame.height > 0 && frame.height <= 464);
  }
}
assert.equal(resolve(360, 780, 800, 800).height, 1);
console.log('PASS production update dialog layout: fixed R3 frame, compact viewport, safe-area and invalid-value bounds; no device visual claim.');
