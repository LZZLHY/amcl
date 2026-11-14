/** 活动页真实生命周期回归：同次首次进入只发起一轮读取，路由返回仍刷新，隐藏停止可见标记。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
const { LayerRetreatPolicy } = makePureEtsLoader()('entry/src/main/ets/components/LayerRetreatPolicy.ets');

/** 执行生产生命周期回调；替换的刷新命令只记录调用次数，不伪造应用记录或账本内容。 */
function fixture() {
  const source = fs.readFileSync(new URL('../entry/src/main/ets/pages/DownloadHistoryPage.ets', import.meta.url), 'utf8');
  const start = source.indexOf('  aboutToAppear() {');
  const end = source.indexOf('\n  private applyTheme_()', start);
  assert.ok(start > 0 && end > start);
  const code = compiler.transpileModule('class Probe {\n' + source.slice(start, end)
    + '\n}\nmodule.exports = Probe;', { compilerOptions: { target: compiler.ScriptTarget.ES2022 } }).outputText;
  const module = { exports: {} }; new Function('module', code)(module);
  const subject = new module.exports();
  let reads = 0, themes = 0;
  Object.assign(subject, { hostVisible: false, refreshGeneration_: 0, clearGeneration_: 0,
    // 离页必须执行真实策略reset；普通身份字段显式初始化，避免undefined自增隐藏夹具缺口。
    retreatPolicy_: new LayerRetreatPolicy(), retreatAnimationEpoch_: 0,
    applyTheme_() { themes++; }, refreshRecords() { reads++; return Promise.resolve(); } });
  return { subject, reads: () => reads, themes: () => themes };
}

test('实际首次appear→show只有一轮记录刷新', async () => {
  const f = fixture(); f.subject.aboutToAppear();
  assert.equal(f.themes(), 1); assert.equal(f.reads(), 0, 'appear只初始化主题，不提前读取');
  // 框架可能在两个生命周期间处理已就绪Promise，必须仍保持首次读取只有一轮。
  await Promise.resolve(); f.subject.onPageShow(); await Promise.resolve();
  // 每次show都重新应用当前主题，首次读取仍只有一次；主题刷新不能被当成一次目录读取。
  assert.equal(f.themes(), 2); assert.equal(f.reads(), 1); assert.equal(f.subject.hostVisible, true);
});

test('隐藏再返回仍执行真实显示刷新入口，不把首屏去重变成永久跳过读取', () => {
  const f = fixture(); f.subject.aboutToAppear(); f.subject.onPageShow(); f.subject.onPageHide();
  assert.equal(f.subject.hostVisible, false);
  f.subject.onPageShow(); assert.equal(f.themes(), 3); assert.equal(f.reads(), 2); assert.equal(f.subject.hostVisible, true);
});
