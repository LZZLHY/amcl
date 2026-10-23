/** 活动页真实生命周期回归：同次首次进入只发起一轮读取，路由返回仍刷新，隐藏停止可见标记。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';

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
  Object.assign(subject, { hostVisible: false, applyTheme_() { themes++; }, refreshRecords() { reads++; return Promise.resolve(); } });
  return { subject, reads: () => reads, themes: () => themes };
}

test('实际首次appear→show只有一轮记录刷新', async () => {
  const f = fixture(); f.subject.aboutToAppear();
  // 框架可能在两个生命周期间处理已就绪Promise，必须仍保持首次读取只有一轮。
  await Promise.resolve(); f.subject.onPageShow(); await Promise.resolve();
  assert.equal(f.themes(), 1); assert.equal(f.reads(), 1); assert.equal(f.subject.hostVisible, true);
});

test('隐藏再返回仍执行真实显示刷新入口，不把首屏去重变成永久跳过读取', () => {
  const f = fixture(); f.subject.aboutToAppear(); f.subject.onPageShow(); f.subject.onPageHide();
  assert.equal(f.subject.hostVisible, false);
  f.subject.onPageShow(); assert.equal(f.reads(), 2); assert.equal(f.subject.hostVisible, true);
});
